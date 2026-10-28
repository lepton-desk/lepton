//! The AppImage: AppImage's own type-2 runtime, followed by the AppDir (`appdir.rs`) as a
//! squashfs. One file that runs where it is put; the runtime mounts the file system with
//! its statically linked FUSE and starts `AppRun`.
//!
//! The runtime is not built or downloaded here: `@lepton-desk/appimage-runtime-linux-x64`
//! carries type2-runtime release 20251108's `runtime-x86_64` unchanged, the project
//! installs it as a dev dependency, and this refuses any other bytes (its SHA-256 is
//! fixed below). The squashfs is gzip-compressed — the runtime reads gzip and zstd, and
//! gzip is pure Rust through `flate2` — with every owner root, every time the release's
//! (`SOURCE_DATE_EPOCH`) and entries in sorted order, so the same AppDir gives the same
//! AppImage.

use std::path::{Path, PathBuf};

use backhand::compression::Compressor;
use backhand::{FilesystemCompressor, FilesystemWriter, NodeHeader};

use super::CliError;
use super::archive::{self, io};
use super::package::MARKER;

/// The runtime's release (AppImage/type2-runtime).
pub const RUNTIME_RELEASE: &str = "20251108";

/// The npm package that carries the runtime, and the file in it.
pub const RUNTIME_PACKAGE: &str = "@lepton-desk/appimage-runtime-linux-x64";
pub const RUNTIME_FILE: &str = "runtime-x86_64";

/// `runtime-x86_64` of release 20251108, as GitHub's release API gives its digest.
pub const RUNTIME_SHA256: &str = "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d";

/// `<binary>-<version>-<arch>.AppImage`, as AppImage names its files.
pub fn file_name(binary: &str, version: &str) -> String {
    format!("{binary}-{version}-{}.AppImage", std::env::consts::ARCH)
}

/// The runtime from the project's dependencies, its SHA-256 checked.
pub fn runtime(root: &Path) -> Result<Vec<u8>, CliError> {
    if std::env::consts::ARCH != "x86_64" {
        return Err(CliError::Invalid(format!(
            "an AppImage is made for x86-64 only so far; this machine is {}",
            std::env::consts::ARCH
        )));
    }
    let path = root
        .join("node_modules")
        .join(RUNTIME_PACKAGE)
        .join(RUNTIME_FILE);
    let bytes = std::fs::read(&path).map_err(|_| {
        CliError::Invalid(format!(
            "an AppImage needs AppImage's runtime: install it with `npm install -D {RUNTIME_PACKAGE}@{version}` (or pnpm add -D); {} is missing",
            path.display(),
            version = env!("CARGO_PKG_VERSION")
        ))
    })?;
    let digest = sha256(&bytes);
    if digest != RUNTIME_SHA256 {
        return Err(CliError::Invalid(format!(
            "{} has SHA-256 {digest}, not type2-runtime {RUNTIME_RELEASE}'s {RUNTIME_SHA256}; reinstall {RUNTIME_PACKAGE}",
            path.display()
        )));
    }
    Ok(bytes)
}

fn sha256(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Writes `runtime` and `appdir` as a squashfs into `out/<name>`, executable, with its
/// `.sha256`. Returns the file and its digest.
pub fn write(
    appdir: &Path,
    runtime: &[u8],
    out: &Path,
    name: &str,
    mtime: u64,
) -> Result<(PathBuf, String), CliError> {
    let target = out.join(name);
    archive::refuse_foreign(&target)?;
    let time = u32::try_from(mtime).map_err(|_| {
        CliError::Invalid(format!(
            "SOURCE_DATE_EPOCH {mtime} is past what squashfs can hold (2106)"
        ))
    })?;
    let failed = |what: &str, error: backhand::BackhandError| {
        CliError::Invalid(format!(
            "could not {what} the AppImage's file system: {error}"
        ))
    };

    let mut image = FilesystemWriter::default();
    image.set_compressor(
        FilesystemCompressor::new(Compressor::Gzip, None)
            .map_err(|error| failed("set up", error))?,
    );
    image.set_time(time);
    image.set_root_mode(0o755);
    image.set_root_uid(0);
    image.set_root_gid(0);
    for entry in archive::sorted_entries(appdir, Path::new(""), &[MARKER])? {
        if entry.directory {
            image
                .push_dir(&entry.path, NodeHeader::new(0o755, 0, 0, time))
                .map_err(|error| failed("lay out", error))?;
        } else {
            let mode = if entry.executable { 0o755 } else { 0o644 };
            image
                .push_file_from_path(
                    &entry.source,
                    &entry.path,
                    NodeHeader::new(mode, 0, 0, time),
                )
                .map_err(|error| failed("lay out", error))?;
        }
    }
    let mut squashfs = std::io::Cursor::new(Vec::new());
    image
        .write(&mut squashfs)
        .map_err(|error| failed("write", error))?;

    let partial = target.with_extension("part");
    let mut bytes = Vec::with_capacity(runtime.len() + squashfs.get_ref().len());
    bytes.extend_from_slice(runtime);
    bytes.extend_from_slice(squashfs.get_ref());
    std::fs::write(&partial, &bytes).map_err(|error| io(&partial, "write", &error))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&partial, std::fs::Permissions::from_mode(0o755))
            .map_err(|error| io(&partial, "chmod", &error))?;
    }
    let digest = archive::publish(&partial, &target)?;
    Ok((target, digest))
}

#[cfg(all(test, unix))]
mod tests {
    use super::write;
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_eq, assert_ok, ensure};

    #[test]
    fn the_runtime_comes_first_and_the_same_appdir_gives_the_same_file() -> Result<(), Failure> {
        let scratch = Scratch::new("appimage")?;
        scratch.write("app.AppDir/AppRun", "#!/bin/sh\n")?;
        scratch.write("app.AppDir/usr/bin/notes", "program")?;
        scratch.write("app.AppDir/.lepton-package", "marker\n")?;
        let runtime = b"\x7fELF a runtime stand-in";
        let appdir = scratch.path().join("app.AppDir");
        let (first, digest) = assert_ok!(
            write(
                &appdir,
                runtime,
                scratch.path(),
                "a.AppImage",
                1_793_145_600
            ),
            "first"
        );
        let (second, again) = assert_ok!(
            write(
                &appdir,
                runtime,
                scratch.path(),
                "b.AppImage",
                1_793_145_600
            ),
            "second"
        );
        assert_eq!(digest, again);
        let bytes = assert_ok!(std::fs::read(&first), "read");
        ensure!(
            bytes.starts_with(runtime),
            "the runtime is the file's start"
        );
        // squashfs v4's magic, `hsqs`, right after it.
        assert_eq!(
            bytes.get(runtime.len()..runtime.len() + 4),
            Some(&b"hsqs"[..])
        );
        ensure!(second.is_file(), "the second file was written");
        Ok(())
    }
}
