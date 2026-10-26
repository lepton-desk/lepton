//! `lepton package --verify` on Windows: the run, the measurement and the close.
//!
//! The counterpart of `verify::run_and_measure`'s Linux body, with Windows' own means:
//!
//! - **The tree** is the application's own job object. Children inherit the job, so
//!   `QueryInformationJobObject`'s process list (through `win32job`) is every process
//!   the application started — WebView2's browser, GPU, renderer and utility processes —
//!   without walking parent ids.
//! - **Memory** is the private working set (Task Manager's "Memory" column; Linux uses
//!   PSS), read once at the end of [`SETTLE`] from the `PerfProc_Process` counters for the
//!   whole list, plus the application's own peak working set. Sampling the counters every
//!   200 ms as Linux samples `/proc` would cost a PowerShell start each time.
//! - **The close** is `WM_CLOSE` posted to the application's visible windows
//!   ([`close_windows`]), what the user's close button sends: the application must end with code 0 and the job must be empty within
//!   [`GRACE`]. The job kills whatever is left when it goes, so a failed verify leaves no
//!   process behind either.

use std::os::windows::io::AsRawHandle as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use super::CliError;
use super::archive::io;
use super::verify::{GRACE, Report, SETTLE, tail};

const SAMPLE: Duration = Duration::from_millis(200);

fn job_error(error: win32job::JobError) -> CliError {
    CliError::Invalid(format!(
        "could not watch the application's processes: {error}"
    ))
}

/// Starts `program`, requires it to stay up for [`SETTLE`], measures it, closes it with
/// `WM_CLOSE` and requires it and everything it started gone within [`GRACE`].
pub fn run_and_measure(program: &Path, workdir: &Path) -> Result<Report, CliError> {
    if !program.is_file() {
        return Err(CliError::Invalid(format!(
            "the package has no executable at {}",
            program.strip_prefix(workdir).unwrap_or(program).display()
        )));
    }
    let mut limits = win32job::ExtendedLimitInfo::new();
    limits.limit_kill_on_job_close();
    let job = win32job::Job::create_with_limit_info(&limits).map_err(job_error)?;

    let log_path = workdir.join(".verify-stderr");
    let log = std::fs::File::create(&log_path).map_err(|error| io(&log_path, "create", &error))?;
    let mut child = Command::new(program)
        .current_dir(workdir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log)
        .spawn()
        .map_err(|error| io(program, "start", &error))?;
    let pid = child.id();
    let handle = child.as_raw_handle() as isize;
    if let Err(error) = job.assign_process(handle) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(job_error(error));
    }
    lepton_orchestrator::supervise::track(pid);

    let mut report = Report {
        unpacked: 0,
        peak_app: 0,
        peak_tree: 0,
        processes: 0,
        closed_in: Duration::ZERO,
    };
    let started = Instant::now();
    while started.elapsed() < SETTLE {
        if let Ok(Some(status)) = child.try_wait() {
            lepton_orchestrator::supervise::untrack(pid);
            return Err(CliError::Invalid(format!(
                "the application ended after {:.1} s ({status}); stderr:\n{}",
                started.elapsed().as_secs_f64(),
                tail(&log_path)
            )));
        }
        let members = job.query_process_id_list().map_err(job_error)?;
        report.processes = report.processes.max(members.len());
        std::thread::sleep(SAMPLE);
    }
    let members = job.query_process_id_list().map_err(job_error)?;
    report.processes = report.processes.max(members.len());
    report.peak_tree = private_working_set(&members)?;
    report.peak_app = win32job::utils::get_process_memory_info(handle)
        .map(|counters| counters.peak_working_set_size as u64)
        .unwrap_or(0);

    let posted = match close_windows(pid, workdir) {
        Ok(posted) => posted,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            lepton_orchestrator::supervise::untrack(pid);
            return Err(error);
        }
    };
    if posted == 0 {
        let _ = child.kill();
        let _ = child.wait();
        lepton_orchestrator::supervise::untrack(pid);
        return Err(CliError::Invalid(
            "the application has no visible window to close".to_owned(),
        ));
    }
    // From the request reaching the windows: PowerShell's own start (about a second, to
    // compile the script) is not the application's time to close.
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
                "the application did not end within {:.0} s of its window being closed; stderr:\n{}",
                GRACE.as_secs_f64(),
                tail(&log_path)
            )));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    lepton_orchestrator::supervise::untrack(pid);
    if status.code() != Some(0) {
        return Err(CliError::Invalid(format!(
            "the application failed when its window was closed ({status}); stderr:\n{}",
            tail(&log_path)
        )));
    }

    // WebView2's processes must follow it out; the job lists any that did not.
    let leftovers = loop {
        let left = job.query_process_id_list().map_err(job_error)?;
        if left.is_empty() || asked.elapsed() > GRACE {
            break left;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    report.closed_in = asked.elapsed();
    if !leftovers.is_empty() {
        // Dropping the job (kill-on-close) ends them.
        return Err(CliError::Invalid(format!(
            "{} process(es) outlived the application: {leftovers:?}",
            leftovers.len()
        )));
    }
    Ok(report)
}

/// Posts `WM_CLOSE` to every visible, unowned top-level window of process `pid` — what
/// the user's close button sends — and returns how many it reached.
///
/// Not `taskkill /PID`: it answered SUCCESS for the native template app on Windows, which
/// ran on, while `WM_CLOSE` posted to its `LeptonWindow` ended it with code 0 (CI,
/// 2026-10-26). That process also owns a visible, untitled `MicrosoftWindowsTooltip`
/// window, listed before its own. `unsafe` is forbidden here, so the calls are
/// PowerShell's (`Add-Type`), as for the memory counters.
fn close_windows(pid: u32, workdir: &Path) -> Result<usize, CliError> {
    let script_path = workdir.join(".verify-close.ps1");
    std::fs::write(&script_path, CLOSE_SCRIPT)
        .map_err(|error| io(&script_path, "write", &error))?;
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&script_path)
        .arg(pid.to_string())
        .stdin(Stdio::null())
        .output()
        .map_err(|error| {
            CliError::Invalid(format!(
                "could not ask Windows to close the application: {error}"
            ))
        })?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.trim().parse().map_err(|_| {
        CliError::Invalid(format!(
            "could not ask Windows to close the application ({:?}, {:?})",
            text.trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    })
}

const CLOSE_SCRIPT: &str = r#"param([uint32]$id)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LeptonVerifyClose {
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    public static int Close(uint id) {
        int posted = 0;
        EnumWindows((window, data) => {
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            const uint owner = 4, close = 0x0010;
            if (pid == id && IsWindowVisible(window) && GetWindow(window, owner) == IntPtr.Zero
                && PostMessage(window, close, IntPtr.Zero, IntPtr.Zero)) posted++;
            return true;
        }, IntPtr.Zero);
        return posted;
    }
}
'@
[LeptonVerifyClose]::Close($id)
"#;

/// The summed private working set of `pids`, in bytes, from the `PerfProc_Process`
/// performance counters (PowerShell's CIM query: no API call needs `unsafe` here).
pub fn private_working_set(pids: &[usize]) -> Result<u64, CliError> {
    if pids.is_empty() {
        return Ok(0);
    }
    let list: Vec<String> = pids.iter().map(usize::to_string).collect();
    let script = format!(
        "$ids = @({}); (Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object {{ $ids -contains $_.IDProcess }} | Measure-Object WorkingSetPrivate -Sum).Sum",
        list.join(",")
    );
    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|error| {
            CliError::Invalid(format!(
                "could not ask Windows for memory counters: {error}"
            ))
        })?;
    let text = String::from_utf8_lossy(&output.stdout);
    parse_bytes(&text).ok_or_else(|| {
        CliError::Invalid(format!(
            "Windows gave no memory counters for the application's processes ({:?})",
            text.trim()
        ))
    })
}

/// PowerShell's sum, printed as an integer.
fn parse_bytes(text: &str) -> Option<u64> {
    text.trim().parse().ok()
}

#[cfg(test)]
mod tests {
    use super::{parse_bytes, private_working_set};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, assert_ok, ensure};

    #[test]
    fn the_counter_sum_is_read_as_bytes() -> Result<(), Failure> {
        assert_eq!(parse_bytes("101068800\r\n"), Some(101_068_800));
        assert_eq!(parse_bytes(""), None::<u64>);
        Ok(())
    }

    #[test]
    fn this_process_has_a_private_working_set() -> Result<(), Failure> {
        // A real reading of a real process: the test runner itself.
        let bytes = assert_ok!(
            private_working_set(&[std::process::id() as usize]),
            "counters"
        );
        ensure!(
            bytes > 1_000_000,
            "a running process holds more than a megabyte: {bytes}"
        );
        Ok(())
    }
}
