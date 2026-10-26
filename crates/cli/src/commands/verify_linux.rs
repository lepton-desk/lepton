//! `lepton package --verify` on Linux: the run, the measurement and the close.
//!
//! The tree is read from `/proc/<pid>/task/<tid>/children`, memory as PSS from
//! `smaps_rollup` (summed RSS double-counts WebKit's shared pages), and the end is
//! SIGTERM. Windows does the same with its own means (`verify_windows.rs`).

use std::path::Path;
use std::time::{Duration, Instant};

use super::CliError;
use super::archive::io;
use super::verify::{GRACE, Report, SETTLE, tail};

const SAMPLE: Duration = Duration::from_millis(200);

/// Starts `program`, requires it to stay up for [`SETTLE`] while sampling memory, then
/// ends it with SIGTERM and requires it and its descendants gone within [`GRACE`].
pub fn run_and_measure(program: &Path, workdir: &Path) -> Result<Report, CliError> {
    if !program.is_file() {
        return Err(CliError::Invalid(format!(
            "the package has no executable at {}",
            program.strip_prefix(workdir).unwrap_or(program).display()
        )));
    }
    let log_path = workdir.join(".verify-stderr");
    let log = std::fs::File::create(&log_path).map_err(|error| io(&log_path, "create", &error))?;
    let mut child = std::process::Command::new(program)
        .current_dir(workdir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(log)
        .spawn()
        .map_err(|error| io(program, "start", &error))?;
    let pid = child.id();
    lepton_orchestrator::supervise::track(pid);

    let mut report = Report {
        unpacked: 0,
        peak_app: 0,
        peak_tree: 0,
        processes: 0,
        closed_in: Duration::ZERO,
    };
    let mut seen = Vec::new();
    let started = Instant::now();
    while started.elapsed() < SETTLE {
        if let Ok(Some(status)) = child.try_wait() {
            lepton_orchestrator::supervise::untrack(pid);
            return Err(CliError::Invalid(format!(
                "the application ended after {:.1} s ({}); stderr:\n{}",
                started.elapsed().as_secs_f64(),
                describe(status),
                tail(&log_path)
            )));
        }
        let tree = descendants(pid);
        report.peak_app = report.peak_app.max(resident(pid));
        report.peak_tree = report
            .peak_tree
            .max(tree.iter().map(|&p| proportional(p)).sum::<u64>());
        report.processes = report.processes.max(tree.len());
        for p in tree {
            if !seen.contains(&p) {
                seen.push(p);
            }
        }
        std::thread::sleep(SAMPLE);
    }

    lepton_orchestrator::supervise::terminate(pid);
    let asked = Instant::now();
    let status = loop {
        if let Ok(Some(status)) = child.try_wait() {
            break status;
        }
        if asked.elapsed() > GRACE {
            let _ = child.kill();
            let _ = child.wait();
            lepton_orchestrator::supervise::untrack(pid);
            return Err(CliError::Invalid(format!(
                "the application did not end within {:.0} s of SIGTERM; stderr:\n{}",
                GRACE.as_secs_f64(),
                tail(&log_path)
            )));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    lepton_orchestrator::supervise::untrack(pid);
    if signal_of(status).is_none() && status.code() != Some(0) {
        return Err(CliError::Invalid(format!(
            "the application failed on SIGTERM ({}); stderr:\n{}",
            describe(status),
            tail(&log_path)
        )));
    }

    // Children must follow the application out; one that does not is an orphan the user
    // would find in their task manager.
    let leftovers = loop {
        let left: Vec<u32> = seen
            .iter()
            .copied()
            .filter(|&p| p != pid && running(p))
            .collect();
        if left.is_empty() || asked.elapsed() > GRACE {
            break left;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    report.closed_in = asked.elapsed();
    if !leftovers.is_empty() {
        for &p in &leftovers {
            lepton_orchestrator::supervise::terminate(p);
        }
        return Err(CliError::Invalid(format!(
            "{} process(es) outlived the application: {:?}",
            leftovers.len(),
            leftovers
        )));
    }
    Ok(report)
}

/// `pid` and every process below it, from `/proc/<pid>/task/<tid>/children`.
pub fn descendants(pid: u32) -> Vec<u32> {
    let mut all = vec![pid];
    let mut index = 0;
    while let Some(&current) = all.get(index) {
        index += 1;
        let Ok(tasks) = std::fs::read_dir(format!("/proc/{current}/task")) else {
            continue;
        };
        for task in tasks.flatten() {
            let Ok(text) = std::fs::read_to_string(task.path().join("children")) else {
                continue;
            };
            for child in text.split_whitespace().filter_map(|p| p.parse().ok()) {
                if !all.contains(&child) {
                    all.push(child);
                }
            }
        }
    }
    all
}

/// `VmRSS` of `pid` in bytes; 0 when it is gone.
pub fn resident(pid: u32) -> u64 {
    std::fs::read_to_string(format!("/proc/{pid}/status"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("VmRSS:"))
                .and_then(|value| value.split_whitespace().next())
                .and_then(|kib| kib.parse::<u64>().ok())
        })
        .map_or(0, |kib| kib * 1024)
}

/// `Pss` of `pid` in bytes from `/proc/<pid>/smaps_rollup`; 0 when it is gone.
pub fn proportional(pid: u32) -> u64 {
    std::fs::read_to_string(format!("/proc/{pid}/smaps_rollup"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("Pss:"))
                .and_then(|value| value.split_whitespace().next())
                .and_then(|kib| kib.parse::<u64>().ok())
        })
        .map_or(0, |kib| kib * 1024)
}

/// Whether `pid` exists and is not a zombie.
fn running(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|stat| {
        stat.rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().next())
            .is_some_and(|state| state != "Z")
    })
}

fn describe(status: std::process::ExitStatus) -> String {
    match (status.code(), signal_of(status)) {
        (Some(code), _) => format!("exit code {code}"),
        (None, Some(signal)) => format!("signal {signal}"),
        (None, None) => String::from("unknown status"),
    }
}

#[cfg(unix)]
fn signal_of(status: std::process::ExitStatus) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt as _;
    status.signal()
}
