//! `lepton package --verify`: a release is checked the way a user meets it.
//!
//! Each written package is unpacked into a new, empty directory by this code (not by
//! the package manager), the application is started from there and must stay up for
//! [`SETTLE`]; meanwhile the resident memory of its whole process tree (WebKit runs its
//! web and network processes as children) is sampled. It is then sent SIGTERM and must
//! end, with every process it started, within [`GRACE`]. Running from the unpacked tree
//! also proves the binary finds its frontend relative to itself, not from the build
//! directory.

use std::io::Read as _;
use std::os::unix::process::ExitStatusExt as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lepton_template_injector::BundleTarget;

use super::CliError;
use super::archive::io;

/// How long the application must stay up.
pub const SETTLE: Duration = Duration::from_secs(3);
/// How long it may take to end after SIGTERM, children included.
pub const GRACE: Duration = Duration::from_secs(5);
const SAMPLE: Duration = Duration::from_millis(200);

/// What one run measured.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    /// Bytes of regular files after unpacking.
    pub unpacked: u64,
    /// Peak resident set of the application process alone, in bytes.
    pub peak_app: u64,
    /// Peak proportional set size (PSS) summed over the application and its descendants.
    ///
    /// PSS, not RSS: WebKit's processes map the same libraries, and summed RSS counted
    /// those pages once per process — measured 330 MB RSS against 196 MB PSS for one tree.
    pub peak_tree: u64,
    /// Most processes seen in the tree at once.
    pub processes: usize,
    /// Time from SIGTERM until the application and its descendants were gone.
    pub closed_in: Duration,
}

impl Report {
    pub fn summary(&self) -> String {
        format!(
            "ok: up {:.1} s, {} process(es), app RSS {}, tree PSS {}, unpacked {}, closed in {:.2} s",
            SETTLE.as_secs_f64(),
            self.processes,
            megabytes(self.peak_app),
            megabytes(self.peak_tree),
            megabytes(self.unpacked),
            self.closed_in.as_secs_f64()
        )
    }
}

/// Unpacks `artifact`, runs the application from it, and removes the directory again.
pub fn verify(artifact: &Path, target: BundleTarget, binary: &str) -> Result<Report, CliError> {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() && std::env::var_os("DISPLAY").is_none() {
        return Err(CliError::Invalid(String::from(
            "--verify opens the application's window and needs a graphical session (WAYLAND_DISPLAY or DISPLAY)",
        )));
    }
    let scratch = fresh_dir(target)?;
    let result = unpack(artifact, target, &scratch).and_then(|prefix| {
        let unpacked = tree_size(&scratch)?;
        let mut report = run_and_measure(&prefix.join("bin").join(binary), &scratch)?;
        report.unpacked = unpacked;
        Ok(report)
    });
    let _ = std::fs::remove_dir_all(&scratch);
    result
}

/// A new directory nobody else uses.
fn fresh_dir(target: BundleTarget) -> Result<PathBuf, CliError> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "lepton-verify-{}-{}-{stamp}",
        std::process::id(),
        target.name()
    ));
    // `create_dir`, not `create_dir_all`: an existing directory is an error, so the
    // application is never started among files a previous run left.
    std::fs::create_dir(&dir).map_err(|error| io(&dir, "create", &error))?;
    Ok(dir)
}

/// Unpacks `artifact` into `into` and returns the install prefix (the directory holding
/// `bin/`).
pub fn unpack(artifact: &Path, target: BundleTarget, into: &Path) -> Result<PathBuf, CliError> {
    let file = std::fs::File::open(artifact).map_err(|error| io(artifact, "read", &error))?;
    match target {
        BundleTarget::TarGz => {
            extract(flate2::read::GzDecoder::new(file), artifact, into)?;
            let top = artifact
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".tar.gz"))
                .ok_or_else(|| {
                    CliError::Invalid(format!("{} is not a .tar.gz", artifact.display()))
                })?;
            Ok(into.join(top))
        }
        BundleTarget::Arch => {
            let decoder = ruzstd::decoding::StreamingDecoder::new(file).map_err(|error| {
                CliError::Invalid(format!("{} is not zstd: {error}", artifact.display()))
            })?;
            extract(decoder, artifact, into)?;
            Ok(into.join("usr"))
        }
        BundleTarget::Deb => {
            let mut bytes = Vec::new();
            std::io::BufReader::new(file)
                .read_to_end(&mut bytes)
                .map_err(|error| io(artifact, "read", &error))?;
            let data = super::deb::ar_member(&bytes, "data.tar.gz").ok_or_else(|| {
                CliError::Invalid(format!("{} has no data.tar.gz", artifact.display()))
            })?;
            extract(flate2::read::GzDecoder::new(data), artifact, into)?;
            Ok(into.join("usr"))
        }
    }
}

/// `tar::Archive::unpack` refuses members that would land outside `into` (`..`, absolute
/// paths), so a damaged package cannot write elsewhere.
fn extract(reader: impl std::io::Read, artifact: &Path, into: &Path) -> Result<(), CliError> {
    let mut archive = tar::Archive::new(reader);
    archive.set_preserve_permissions(true);
    archive
        .unpack(into)
        .map_err(|error| io(artifact, "unpack", &error))
}

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
                "the application did not end within {:.0} s of SIGTERM",
                GRACE.as_secs_f64()
            )));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    lepton_orchestrator::supervise::untrack(pid);
    if status.signal().is_none() && status.code() != Some(0) {
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

fn tree_size(dir: &Path) -> Result<u64, CliError> {
    let mut total = 0;
    let listing = std::fs::read_dir(dir).map_err(|error| io(dir, "list", &error))?;
    for entry in listing.flatten() {
        let meta = std::fs::symlink_metadata(entry.path())
            .map_err(|error| io(&entry.path(), "inspect", &error))?;
        if meta.is_dir() {
            total += tree_size(&entry.path())?;
        } else if meta.is_file() {
            total += meta.len();
        }
    }
    Ok(total)
}

fn describe(status: std::process::ExitStatus) -> String {
    match (status.code(), status.signal()) {
        (Some(code), _) => format!("exit code {code}"),
        (None, Some(signal)) => format!("signal {signal}"),
        (None, None) => String::from("unknown status"),
    }
}

/// The last lines of the application's stderr, for a failure message.
fn tail(path: &Path) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines
        .get(lines.len().saturating_sub(12)..)
        .unwrap_or_default()
        .join("\n")
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_000_000.0)
}

#[cfg(test)]
mod tests {
    use super::{descendants, proportional, resident, run_and_measure, unpack};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_contains, assert_err, assert_ok, ensure};
    use lepton_template_injector::BundleTarget;
    use std::os::unix::fs::PermissionsExt as _;

    /// A real executable: a shell script that does what the test says.
    fn program(
        scratch: &Scratch,
        relative: &str,
        script: &str,
    ) -> Result<std::path::PathBuf, Failure> {
        scratch.write(relative, script)?;
        let path = scratch.path().join(relative);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
            .map_err(|error| fail("chmod", error))?;
        Ok(path)
    }

    #[test]
    fn this_process_has_memory_and_is_its_own_tree_root() -> Result<(), Failure> {
        let pid = std::process::id();
        ensure!(resident(pid) > 0, "VmRSS of the test process");
        ensure!(proportional(pid) > 0, "Pss of the test process");
        ensure!(
            proportional(pid) <= resident(pid) + 4096,
            "PSS never exceeds RSS"
        );
        ensure!(descendants(pid).first() == Some(&pid), "root first");
        Ok(())
    }

    #[test]
    fn a_program_that_stays_up_and_ends_on_sigterm_passes() -> Result<(), Failure> {
        let scratch = Scratch::new("verify-up")?;
        let app = program(&scratch, "bin/app", "#!/bin/sh\nexec sleep 30\n")?;
        let report = assert_ok!(run_and_measure(&app, scratch.path()), "passes");
        ensure!(report.peak_app > 0, "sampled memory");
        ensure!(
            report.processes == 1,
            "one process, saw {}",
            report.processes
        );
        Ok(())
    }

    #[test]
    fn a_program_that_exits_early_fails_with_its_stderr() -> Result<(), Failure> {
        let scratch = Scratch::new("verify-early")?;
        let app = program(
            &scratch,
            "bin/app",
            "#!/bin/sh\necho 'no display' >&2\nexit 3\n",
        )?;
        let error = assert_err!(run_and_measure(&app, scratch.path()), "exits early");
        let text = error.to_string();
        assert_contains!(&text, "exit code 3");
        assert_contains!(&text, "no display");
        Ok(())
    }

    #[test]
    fn a_child_that_outlives_the_application_is_reported() -> Result<(), Failure> {
        let scratch = Scratch::new("verify-orphan")?;
        // The shell dies on SIGTERM; its background `sleep` does not.
        let app = program(&scratch, "bin/app", "#!/bin/sh\nsleep 30 &\nwait\n")?;
        let error = assert_err!(run_and_measure(&app, scratch.path()), "orphan");
        assert_contains!(&error.to_string(), "outlived the application");
        Ok(())
    }

    #[test]
    fn each_format_unpacks_to_a_prefix_with_the_binary() -> Result<(), Failure> {
        let scratch = Scratch::new("verify-unpack")?;
        program(&scratch, "b/bin/notes", "#!/bin/sh\n")?;
        scratch.write("b/share/notes/dist/index.html", "<!doctype html>\n")?;
        let bundle = scratch.path().join("b");
        let out = scratch.path().join("out");
        std::fs::create_dir_all(&out).map_err(|error| fail("mkdir", error))?;

        let tarball = out.join("notes-1.0.0-linux-x.tar.gz");
        assert_ok!(
            super::super::archive::tar_gz(&bundle, "notes-1.0.0-linux-x", &[], &tarball, 0),
            "tar.gz"
        );
        let depends = [String::from("glibc")];
        let (arch, _) = assert_ok!(
            super::super::arch::write(&super::super::arch::Package {
                bundle: &bundle,
                skip: &[],
                name: "notes",
                version: "1.0.0",
                description: "Notes",
                depends: &depends,
                mtime: 0,
                out: &out,
            }),
            "arch"
        );
        let (deb, _) = assert_ok!(
            super::super::deb::write(&super::super::deb::Package {
                bundle: &bundle,
                skip: &[],
                name: "notes",
                version: "1.0.0",
                description: "Notes",
                maintainer: "Ada <ada@example.org>",
                depends: &[],
                mtime: 0,
                out: &out,
            }),
            "deb"
        );

        for (artifact, target) in [
            (tarball, BundleTarget::TarGz),
            (arch, BundleTarget::Arch),
            (deb, BundleTarget::Deb),
        ] {
            let into = scratch.path().join(format!("u-{}", target.name()));
            std::fs::create_dir_all(&into).map_err(|error| fail("mkdir", error))?;
            let prefix = assert_ok!(
                unpack(&artifact, target, &into),
                "unpacks {}",
                target.name()
            );
            let binary = prefix.join("bin/notes");
            let mode = std::fs::metadata(&binary)
                .map_err(|error| fail(format!("{} binary", target.name()), error))?
                .permissions()
                .mode();
            ensure!(mode & 0o111 != 0, "{} binary not executable", target.name());
            ensure!(
                prefix.join("share/notes/dist/index.html").is_file(),
                "{} frontend missing",
                target.name()
            );
        }
        Ok(())
    }
}
