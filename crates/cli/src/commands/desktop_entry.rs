//! The desktop entry that lets a shell recognise the running application.
//!
//! On Wayland a panel, dock or task switcher matches a window to an application by its
//! `app_id`, looking for `<app_id>.desktop` in the XDG applications directories. With no
//! such file the window has no name or icon of its own, and some shells (measured on
//! COSMIC) leave it out of the app list altogether. Lepton sets the `app_id` from
//! `identifier` in `lepton.config.json`, so this writes the matching entry next to the
//! user's other applications — after `run` and `dev` build, so it always points at the
//! binary that was just built.

use std::path::{Path, PathBuf};

use super::CliError;

/// The text of the entry, per the Desktop Entry Specification.
///
/// `StartupWMClass` repeats the `app_id`: some shells match on it rather than on the file
/// name, and it costs nothing to be matched both ways. `Icon` names the icon theme entry
/// `install_icon` writes under the same `app_id`.
///
/// With `schemes` (`deepLinks`), the entry handles them (`MimeType`) and takes the link as
/// its argument (`%u`).
pub fn entry_text(app_id: &str, name: &str, exec: &Path, schemes: &[String]) -> String {
    let (field_code, mime) = if schemes.is_empty() {
        (String::new(), String::new())
    } else {
        let kinds: String = schemes
            .iter()
            .map(|scheme| format!("x-scheme-handler/{scheme};"))
            .collect();
        (" %u".to_owned(), format!("MimeType={kinds}\n"))
    };
    format!(
        "[Desktop Entry]\nType=Application\nVersion=1.5\nName={name}\nExec={exec}{field_code}\nIcon={app_id}\nTerminal=false\nStartupWMClass={app_id}\nCategories=Development;\n{mime}X-Lepton-Generated=true\n",
        name = escape_value(name),
        exec = quote_exec(&exec.to_string_lossy()),
        // Escaped too: a newline in it once added keys of its own (`Exec=…`) to the entry.
        app_id = escape_value(app_id),
    )
}

/// Where entries go: `$XDG_DATA_HOME/applications`, else `~/.local/share/applications`.
///
/// Taken as arguments rather than read here, so the rule is testable without changing the
/// test process's environment.
pub fn applications_dir(xdg_data_home: Option<&str>, home: Option<&str>) -> Option<PathBuf> {
    match xdg_data_home {
        Some(dir) if !dir.is_empty() && Path::new(dir).is_absolute() => {
            Some(Path::new(dir).join("applications"))
        }
        _ => home
            .filter(|dir| !dir.is_empty())
            .map(|dir| Path::new(dir).join(".local/share/applications")),
    }
}

/// Writes the entry into `dir` and returns its path.
///
/// Refuses to overwrite an entry Lepton did not write: an `app_id` that collides with an
/// installed application must not replace that application's launcher.
pub fn install(dir: &Path, app_id: &str, text: &str) -> Result<PathBuf, CliError> {
    if app_id.is_empty() || app_id.contains('/') || app_id.chars().any(char::is_control) {
        return Err(CliError::Invalid(format!(
            "identifier {app_id:?} cannot name a desktop entry"
        )));
    }
    let path = dir.join(format!("{app_id}.desktop"));
    if let Ok(existing) = std::fs::read_to_string(&path)
        && !existing.contains("X-Lepton-Generated=true")
    {
        return Err(CliError::Invalid(format!(
            "{} exists and was not written by Lepton; change `identifier` in lepton.config.json",
            path.display()
        )));
    }
    std::fs::create_dir_all(dir).map_err(|error| {
        CliError::Invalid(format!("could not create {}: {error}", dir.display()))
    })?;
    std::fs::write(&path, text).map_err(|error| {
        CliError::Invalid(format!("could not write {}: {error}", path.display()))
    })?;
    Ok(path)
}

/// Lepton's own mark, the icon of a project that has none (`src-lepton/icon.svg`).
pub const DEFAULT_SVG: &str = include_str!("../../assets/icon.svg");
/// The same mark for Windows installers, 16 to 256 px.
pub const DEFAULT_ICO: &[u8] = include_bytes!("../../assets/icon.ico");

/// The project's Linux icon: the `.svg` in `bundle.icon`, else `src-lepton/icon.svg`, else
/// Lepton's own. A configured icon that cannot be read is an error, not Lepton's mark in
/// its place.
pub fn project_icon(root: &Path) -> Result<String, CliError> {
    let config =
        std::fs::read_to_string(root.join(lepton_orchestrator::CONFIG_FILE)).unwrap_or_default();
    let configured = lepton_template_injector::parse_bundle(&config)
        .ok()
        .and_then(|bundle| bundle.svg_icon);
    if let Some(relative) = configured {
        let path = root.join(&relative);
        return std::fs::read_to_string(&path).map_err(|error| {
            CliError::Invalid(format!(
                "bundle.icon names {}, which could not be read: {error}",
                path.display()
            ))
        });
    }
    Ok(
        std::fs::read_to_string(root.join("src-lepton").join("icon.svg"))
            .unwrap_or_else(|_| DEFAULT_SVG.to_owned()),
    )
}

/// Writes `svg` as the `app_id` icon under `share` (`icons/hicolor/scalable/apps/`), the
/// name the entry's `Icon` gives. Call after `install`, which refuses an `app_id` another
/// application's entry holds, so this never replaces that application's icon.
pub fn install_icon(share: &Path, app_id: &str, svg: &str) -> Result<PathBuf, CliError> {
    let dir = share.join("icons/hicolor/scalable/apps");
    std::fs::create_dir_all(&dir).map_err(|error| {
        CliError::Invalid(format!("could not create {}: {error}", dir.display()))
    })?;
    let path = dir.join(format!("{app_id}.svg"));
    std::fs::write(&path, svg).map_err(|error| {
        CliError::Invalid(format!("could not write {}: {error}", path.display()))
    })?;
    Ok(path)
}

/// Installs the entry for a freshly built project in the user's applications directory,
/// with the project's icon beside it.
pub fn register(root: &Path, app_id: &str, name: &str, exec: &Path) -> Result<PathBuf, CliError> {
    let xdg = std::env::var("XDG_DATA_HOME").ok();
    let home = std::env::var("HOME").ok();
    let dir = applications_dir(xdg.as_deref(), home.as_deref()).ok_or_else(|| {
        CliError::Invalid(String::from(
            "neither XDG_DATA_HOME nor HOME is set; no place for a desktop entry",
        ))
    })?;
    let schemes = super::deep_links::read(root)?;
    let entry = install(&dir, app_id, &entry_text(app_id, name, exec, &schemes))?;
    if let Some(share) = dir.parent() {
        install_icon(share, app_id, &project_icon(root)?)?;
    }
    for line in super::deep_links::register_handlers(app_id, &schemes) {
        super::report::Report::new().fact("deep link", &line);
    }
    Ok(entry)
}

/// Registers the entry and says where, or why not, without stopping the run.
///
/// A missing entry costs the application its name in the dock, not its window, so a
/// failure is reported and the command carries on.
pub fn announce(root: &Path, app_id: &str, name: &str, exec: &Path) {
    // XDG desktop entries are a Linux desktop's; Windows and macOS find applications otherwise.
    if !cfg!(target_os = "linux") {
        return;
    }
    match register(root, app_id, name, exec) {
        Ok(path) => {
            super::report::Report::new().fact("desktop entry", &super::report::home_short(&path))
        }
        Err(error) => {
            super::report::Report::new().warn("desktop entry", &format!("not written: {error}"))
        }
    }
}

/// A string value: newlines and backslashes are the only characters the format reserves.
fn escape_value(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

/// The program path as one `Exec` argument.
///
/// Always quoted, so a space in a path (a home directory, a project folder) stays one
/// argument; inside quotes the specification reserves `"`, `` ` ``, `$` and `\`. `%` is
/// a field code everywhere and is doubled.
fn quote_exec(program: &str) -> String {
    // Bare when nothing in it needs quoting: `xdg-open` without a desktop of its own
    // (COSMIC, for one) takes `Exec`'s first word as the command with its quotes on, finds
    // no such program and hands the link to the browser instead (measured: a quoted path
    // sent `myapp://` to Firefox).
    let plain = |ch: char| ch.is_ascii_alphanumeric() || "/._-+".contains(ch);
    if !program.is_empty() && program.chars().all(plain) {
        return program.to_owned();
    }
    let mut quoted = String::with_capacity(program.len() + 2);
    quoted.push('"');
    for ch in program.chars() {
        match ch {
            '"' | '`' | '$' | '\\' => {
                quoted.push('\\');
                quoted.push(ch);
            }
            '%' => quoted.push_str("%%"),
            _ => quoted.push(ch),
        }
    }
    quoted.push('"');
    // The value is then a string value, whose own escaping doubles every backslash.
    escape_value(&quoted)
}

// The entries and their paths are Linux's (`announce`).
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::{applications_dir, entry_text, install};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};
    use std::path::{Path, PathBuf};

    #[test]
    fn the_entry_is_matched_by_the_app_id() -> Result<(), Failure> {
        let text = entry_text(
            "run-app",
            "run-app",
            Path::new("/opt/run-app/bin/run-app"),
            &[],
        );
        assert_contains!(&text, "[Desktop Entry]\n");
        assert_contains!(&text, "StartupWMClass=run-app\n");
        assert_contains!(&text, "Exec=/opt/run-app/bin/run-app\n");
        assert_contains!(&text, "Icon=run-app\n");
        Ok(())
    }

    #[test]
    fn a_deep_link_scheme_is_handled_and_passed_as_the_argument() -> Result<(), Failure> {
        let text = entry_text("a", "a", Path::new("/opt/a"), &["myapp".to_owned()]);
        assert_contains!(&text, "Exec=/opt/a %u\n");
        assert_contains!(&text, "MimeType=x-scheme-handler/myapp;\n");
        Ok(())
    }

    #[test]
    fn a_path_with_spaces_and_reserved_characters_stays_one_argument() -> Result<(), Failure> {
        let text = entry_text("a", "a", Path::new("/home/x/My Apps/100% $cash/app"), &[]);
        // Quoted, `$` escaped inside quotes, `%` doubled, and the escaping backslash
        // itself doubled by the string-value rule.
        assert_contains!(&text, "Exec=\"/home/x/My Apps/100%% \\\\$cash/app\"\n");
        Ok(())
    }

    #[test]
    fn xdg_data_home_wins_and_home_is_the_fallback() -> Result<(), Failure> {
        assert_eq!(
            applications_dir(Some("/data"), Some("/home/u")),
            Some(PathBuf::from("/data/applications"))
        );
        // A relative XDG_DATA_HOME is invalid per the base-directory spec and ignored.
        assert_eq!(
            applications_dir(Some("rel"), Some("/home/u")),
            Some(PathBuf::from("/home/u/.local/share/applications"))
        );
        assert_eq!(applications_dir(None, None), None::<PathBuf>);
        Ok(())
    }

    #[test]
    fn an_entry_is_written_and_rewritten_by_lepton() -> Result<(), Failure> {
        let scratch = Scratch::new("desktop-write")?;
        let dir = scratch.path().join("applications");

        let first = assert_ok!(
            install(&dir, "notes", "X-Lepton-Generated=true\nv1\n"),
            "first write"
        );
        assert_eq!(first, dir.join("notes.desktop"));
        assert_ok!(
            install(&dir, "notes", "X-Lepton-Generated=true\nv2\n"),
            "rewrite of our own entry"
        );
        assert_contains!(&scratch.read("applications/notes.desktop")?, "v2");
        Ok(())
    }

    #[test]
    fn someone_elses_entry_is_never_replaced() -> Result<(), Failure> {
        let scratch = Scratch::new("desktop-foreign")?;
        scratch.write(
            "applications/firefox.desktop",
            "[Desktop Entry]\nName=Firefox\n",
        )?;

        let error = assert_err!(
            install(
                &scratch.path().join("applications"),
                "firefox",
                "X-Lepton-Generated=true\n"
            ),
            "a foreign launcher must survive"
        );
        assert_contains!(&error.to_string(), "identifier");
        ensure!(
            scratch
                .read("applications/firefox.desktop")?
                .contains("Firefox"),
            "the foreign entry was modified"
        );
        Ok(())
    }

    #[test]
    fn an_identifier_with_a_slash_is_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("desktop-slash")?;
        let _ = assert_err!(install(scratch.path(), "../evil", "x"), "path escape");
        Ok(())
    }
}
