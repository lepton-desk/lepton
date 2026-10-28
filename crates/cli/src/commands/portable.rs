//! The portable Windows zip's layout: the program at the top, as a Windows user expects to
//! find it after unpacking, its icon as `<name>.ico`, `share\` beside it and a `README.txt`
//! that says what it is.
//!
//! The bundle keeps the install layout (`bin\<name>.exe`, `share\<name>\…`) for the MSI; this
//! lays out `<bundle>.portable\` from it with `<name>.exe` at the top. The program finds its
//! front end and its notification icon in either layout (the template's `main.zig`,
//! `webview2/notifications.zig`).

use std::path::{Path, PathBuf};

use super::CliError;
use super::package::{MARKER, Spec, io};

/// The portable directory, beside the bundle.
pub fn dir_name(bundle_name: &str) -> String {
    format!("{bundle_name}.portable")
}

/// Lays `bundle` out for the zip under `spec.out` and returns its directory. A previous one
/// is replaced only when it carries [`MARKER`].
pub fn lay_out(spec: &Spec, bundle: &Path, bundle_name: &str) -> Result<PathBuf, CliError> {
    let dir = spec.out.join(dir_name(bundle_name));
    if dir.exists() {
        if !dir.join(MARKER).is_file() {
            return Err(CliError::Invalid(format!(
                "{} exists and was not written by `lepton package`; move it away first",
                dir.display()
            )));
        }
        std::fs::remove_dir_all(&dir).map_err(|error| io(&dir, "remove", &error))?;
    }
    std::fs::create_dir_all(&dir).map_err(|error| io(&dir, "create", &error))?;
    let program = spec.system.executable(&spec.binary);
    std::fs::copy(bundle.join("bin").join(&program), dir.join(&program))
        .map_err(|error| io(&bundle.join("bin").join(&program), "copy", &error))?;
    let share = bundle.join("share");
    if share.is_dir() {
        super::package_tree::copy_tree_skipping(&share, &dir.join("share"), &[])?;
    }
    // The program's own icon: the one its build embedded and installed as
    // `share\<name>\icon.ico` (`lepton-build.zig`), else Lepton's mark.
    let icon = dir.join(format!("{}.ico", spec.binary));
    let built = share.join(&spec.binary).join("icon.ico");
    if built.is_file() {
        std::fs::copy(&built, &icon).map_err(|error| io(&built, "copy", &error))?;
    } else {
        std::fs::write(&icon, super::desktop_entry::DEFAULT_ICO)
            .map_err(|error| io(&icon, "write", &error))?;
    }
    let readme = dir.join("README.txt");
    std::fs::write(&readme, readme_text(spec, &program))
        .map_err(|error| io(&readme, "write", &error))?;
    std::fs::write(dir.join(MARKER), format!("{bundle_name}\n"))
        .map_err(|error| io(&dir.join(MARKER), "write", &error))?;
    Ok(dir)
}

/// What the folder is, with Windows line endings (Notepad on Windows 10 before 1809 shows
/// a bare `\n` as nothing).
pub fn readme_text(spec: &Spec, program: &str) -> String {
    let lines = [
        format!("{} {}", spec.product, spec.version),
        String::new(),
        format!("Run {program}. This folder is the whole application and needs no install:"),
        "it can live anywhere, a folder of yours or a USB stick. Keep the share folder".to_owned(),
        "beside the program; it holds the application's pages.".to_owned(),
        String::new(),
        "To install it instead, with a Start menu entry and an uninstaller, use the .msi of"
            .to_owned(),
        "the same release.".to_owned(),
        String::new(),
        format!(
            "The application keeps its web data in %LOCALAPPDATA%\\{} and its own files in",
            spec.app_id
        ),
        format!(
            "%APPDATA%\\{}; deleting those folders makes it forget everything.",
            spec.app_id
        ),
    ];
    let mut text = lines.join("\r\n");
    text.push_str("\r\n");
    text
}
