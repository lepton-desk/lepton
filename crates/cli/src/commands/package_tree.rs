//! The bundle directory `lepton package` lays out from `src-lepton/zig-out`, before any
//! format is written from it.

use std::path::{Path, PathBuf};

use super::CliError;
use super::package::{MARKER, Spec, io};
use crate::platform::System;

/// The bundle's directory name: `<binary>-<version>-<os>-<arch>`.
pub fn bundle_name(spec: &Spec) -> String {
    format!(
        "{}-{}-{}-{}",
        spec.binary,
        spec.version,
        spec.system.bundle_os(),
        std::env::consts::ARCH
    )
}

/// Lays the build out as a bundle and returns its directory.
///
/// A previous bundle of the same name is replaced only when it carries [`MARKER`]: a
/// directory this command did not write is never deleted on its behalf.
pub fn assemble(spec: &Spec) -> Result<PathBuf, CliError> {
    let executable = spec.system.executable(&spec.binary);
    let program = spec.prefix.join("bin").join(&executable);
    if !program.is_file() {
        return Err(CliError::Invalid(format!(
            "no built executable at {}; run `lepton build` first or drop --no-build",
            program.display()
        )));
    }

    let bundle = spec.out.join(bundle_name(spec));
    if bundle.exists() {
        if !bundle.join(MARKER).is_file() {
            return Err(CliError::Invalid(format!(
                "{} exists and was not written by `lepton package`; move it away first",
                bundle.display()
            )));
        }
        std::fs::remove_dir_all(&bundle).map_err(|error| io(&bundle, "remove", &error))?;
    }

    // `fs::copy` carries the permission bits, so the executable stays executable.
    let bin = bundle.join("bin");
    make_dir(&bin)?;
    copy_file(&program, &bin.join(&executable))?;

    let share = spec.prefix.join("share").join(&spec.binary);
    if share.is_dir() {
        copy_tree(&share, &bundle.join("share").join(&spec.binary))?;
    }

    // A desktop entry is a Linux desktop's way to name an application; Windows has none in
    // a portable tree (a Start menu entry belongs to an installer, MSI).
    if spec.system == System::Linux {
        let applications = bundle.join("share").join("applications");
        // A bare `Exec`: installed, the binary is on `PATH`; the entry is for an install,
        // not for this directory.
        let root = spec
            .prefix
            .parent()
            .and_then(Path::parent)
            .unwrap_or(&spec.prefix);
        let schemes = super::deep_links::read(root)?;
        let entry = super::desktop_entry::entry_text(
            &spec.app_id,
            &spec.product,
            Path::new(&spec.binary),
            &schemes,
        );
        super::desktop_entry::install(&applications, &spec.app_id, &entry)?;
        let svg = super::desktop_entry::project_icon(root)?;
        super::desktop_entry::install_icon(&bundle.join("share"), &spec.app_id, &svg)?;
        // PNGs beside the SVG: some desktops and stores read no SVG, and the AppImage's
        // `.DirIcon` must be one.
        for (size, png) in super::icon::hicolor_pngs(root, &svg)? {
            let apps = bundle
                .join("share/icons/hicolor")
                .join(format!("{size}x{size}"))
                .join("apps");
            make_dir(&apps)?;
            write(&apps.join(format!("{}.png", spec.app_id)), png)?;
        }
    }

    write(&bundle.join(MARKER), format!("{}\n", bundle_name(spec)))?;
    Ok(bundle)
}

/// Copies a directory tree, refusing anything that is neither a file nor a directory.
///
/// A symbolic link in a frontend bundle could point anywhere on the build machine, and
/// copying its target into a release would ship a file nobody chose.
fn copy_tree(from: &Path, to: &Path) -> Result<(), CliError> {
    make_dir(to)?;
    let entries = std::fs::read_dir(from).map_err(|error| io(from, "list", &error))?;
    for entry in entries {
        let entry = entry.map_err(|error| io(from, "list", &error))?;
        let kind = entry
            .file_type()
            .map_err(|error| io(&entry.path(), "inspect", &error))?;
        let target = to.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            copy_file(&entry.path(), &target)?;
        } else {
            return Err(CliError::Invalid(format!(
                "{} is not a regular file; a release ships only files it chose",
                entry.path().display()
            )));
        }
    }
    Ok(())
}

fn copy_file(from: &Path, to: &Path) -> Result<(), CliError> {
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|error| io(to, "write", &error))
}

fn make_dir(dir: &Path) -> Result<(), CliError> {
    std::fs::create_dir_all(dir).map_err(|error| io(dir, "create", &error))
}

fn write(path: &Path, contents: impl AsRef<[u8]>) -> Result<(), CliError> {
    std::fs::write(path, contents).map_err(|error| io(path, "write", &error))
}
