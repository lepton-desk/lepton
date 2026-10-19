//! `lepton package --verify`: a release is checked the way a user meets it.
//!
//! Each written package is unpacked into a new, empty directory by this code (not by
//! the package manager), the application is started from there and must stay up for
//! [`SETTLE`]; meanwhile the resident memory of its whole process tree (WebKit runs its
//! web and network processes as children) is sampled. It is then sent SIGTERM and must
//! end, with every process it started, within [`GRACE`]. Running from the unpacked tree
//! also proves the binary finds its frontend relative to itself, not from the build
//! directory.
//!
//! Windows runs the same check its own way (`verify_windows.rs`): a job object for the
//! tree, the private working set for memory, `WM_CLOSE` for the end.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use lepton_template_injector::BundleTarget;

use super::CliError;
use super::archive::io;

/// How long the application must stay up.
pub const SETTLE: Duration = Duration::from_secs(3);
/// How long it may take to end after SIGTERM, children included.
pub const GRACE: Duration = Duration::from_secs(5);

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
        if cfg!(windows) {
            return format!(
                "ok: up {:.1} s, {} process(es), app peak working set {}, tree private working set {}, unpacked {}, closed in {:.2} s",
                SETTLE.as_secs_f64(),
                self.processes,
                megabytes(self.peak_app),
                megabytes(self.peak_tree),
                megabytes(self.unpacked),
                self.closed_in.as_secs_f64()
            );
        }
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
    crate::platform::graphical_session().map_err(|why| {
        CliError::Invalid(format!("--verify opens the application's window and {why}"))
    })?;
    let scratch = fresh_dir(target)?;
    let result = unpack(artifact, target, &scratch).and_then(|prefix| {
        let unpacked = tree_size(&scratch)?;
        let program = prefix.join("bin").join(crate::platform::executable(binary));
        #[cfg(windows)]
        let mut report = super::verify_windows::run_and_measure(&program, &scratch)?;
        #[cfg(unix)]
        let mut report = super::verify_linux::run_and_measure(&program, &scratch)?;
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
        BundleTarget::Msi => {
            // The installed tree, laid out from the package's own tables and cabinet —
            // without `msiexec`, so a verify registers nothing on this machine.
            super::installer::extract(artifact, into)
        }
        BundleTarget::Zip => {
            super::zip::unpack(artifact, into)?;
            let top = artifact
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_suffix(".zip"))
                .ok_or_else(|| {
                    CliError::Invalid(format!("{} is not a .zip", artifact.display()))
                })?;
            Ok(into.join(top))
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

/// The last lines of the application's stderr, for a failure message.
pub(super) fn tail(path: &Path) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines
        .get(lines.len().saturating_sub(12)..)
        .unwrap_or_default()
        .join("\n")
}

pub(super) fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_000_000.0)
}

// Packaging runs on Linux only (`package.rs`).
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::super::verify_linux::{descendants, proportional, resident, run_and_measure};
    use super::unpack;
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
