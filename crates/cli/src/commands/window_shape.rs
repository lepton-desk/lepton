//! The window's shape beyond its size, handed to every core build from
//! `lepton.config.json`:
//!
//! - `window.decorations: false` → `-Dwindow-decorations=false`: no title bar, the page
//!   draws its own (Windows and Servo; Linux WPE keeps its title bar for now).
//! - `window.frameRate: "unlimited"` → `-Dframe-rate=unlimited`: the native path draws as
//!   fast as the machine can instead of at the display's refresh (`"display"`, the default).
//!   `LEPTON_FRAME_RATE` overrides it when the program runs.
//! - `bundle.icon` → `-Dicon=<path>`, for a Windows build only: the Windows program's
//!   icon — its title bar, taskbar button and Explorer icon. Without it, Lepton's own
//!   (written into the build cache).
//!
//! A project whose `src-lepton/build.zig` predates an option keeps building without it
//! and is told what it misses, as `size_window` does for the size.

use std::path::Path;

use serde_json::Value;

use super::CliError;
use super::launch::is_core_build;
use lepton_orchestrator::Step;

/// What the configuration asks for, read and checked.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Shape {
    pub decorated: bool,
    /// `window.frameRate` is `"unlimited"`.
    pub unlimited: bool,
    /// The project's `.ico`, absolute.
    pub icon: Option<std::path::PathBuf>,
}

/// Reads `window.decorations` (a boolean, `true` when absent) and `bundle.icon`.
pub fn read(root: &Path, text: &str) -> Result<Shape, CliError> {
    let config: Value = serde_json::from_str(text).map_err(|error| {
        CliError::Invalid(format!("lepton.config.json is not valid JSON: {error}"))
    })?;
    let decorated = match config
        .get("window")
        .and_then(|window| window.get("decorations"))
    {
        None => true,
        Some(Value::Bool(value)) => *value,
        Some(_) => {
            return Err(CliError::Invalid(
                "\"window.decorations\" must be true or false".to_owned(),
            ));
        }
    };
    let unlimited = match config
        .get("window")
        .and_then(|window| window.get("frameRate"))
    {
        None => false,
        Some(Value::String(value)) if value == "display" => false,
        Some(Value::String(value)) if value == "unlimited" => true,
        Some(_) => {
            return Err(CliError::Invalid(
                "\"window.frameRate\" must be \"display\" or \"unlimited\"".to_owned(),
            ));
        }
    };
    let bundle = lepton_template_injector::parse_bundle(text)
        .map_err(|error| CliError::Invalid(error.reason))?;
    Ok(Shape {
        decorated,
        unlimited,
        icon: bundle.icon.map(|icon| root.join(icon)),
    })
}

/// Adds the shape to every core build in `steps`.
pub fn shape_window(steps: &mut [Step], root: &Path) -> Result<(), CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;
    let shape = read(root, &text)?;
    let build = std::fs::read_to_string(root.join(super::build::CORE_DIR).join("build.zig"))
        .unwrap_or_default();
    let mut args = Vec::new();
    if !shape.decorated {
        if build.contains("\"window-decorations\"") {
            args.push("-Dwindow-decorations=false".to_owned());
        } else {
            eprintln!(
                "lepton: src-lepton/build.zig predates window.decorations; the window keeps its title bar (recreate the project with a current `lepton new`)"
            );
        }
    }
    if shape.unlimited {
        if build.contains("\"frame-rate\"") {
            args.push("-Dframe-rate=unlimited".to_owned());
        } else {
            eprintln!(
                "lepton: src-lepton/build.zig predates window.frameRate; frames stay at the display's refresh (recreate the project with a current `lepton new`)"
            );
        }
    }
    // The icon is a Windows resource: a build for Linux was handed one, and the default
    // `.ico` written, for a program that never read it.
    let icon = if build.contains("\"icon\"")
        && steps
            .iter()
            .any(|step| is_core_build(step) && targets_windows(step))
    {
        Some(match &shape.icon {
            Some(icon) => icon.clone(),
            None => default_icon(root)?,
        })
    } else {
        None
    };
    for step in steps.iter_mut() {
        if is_core_build(step) {
            step.args.extend(args.iter().cloned());
            if let Some(icon) = icon.as_ref().filter(|_| targets_windows(step)) {
                step.args.push(format!("-Dicon={}", icon.display()));
            }
        }
    }
    Ok(())
}

/// Whether a core build makes a Windows program: its `-Dtarget`, or this machine without one.
pub(super) fn targets_windows(step: &Step) -> bool {
    match step
        .args
        .iter()
        .find_map(|arg| arg.strip_prefix("-Dtarget="))
    {
        Some(triple) => triple.contains("windows"),
        None => cfg!(windows),
    }
}

/// Lepton's own icon, written into the core's build cache (not into the project, which
/// names its own with `bundle.icon`), rewritten only when it changed.
fn default_icon(root: &Path) -> Result<std::path::PathBuf, CliError> {
    let dir = root.join(super::build::CORE_DIR).join(".zig-cache");
    let path = dir.join("lepton-icon.ico");
    let icon = super::desktop_entry::DEFAULT_ICO;
    if std::fs::read(&path).ok().as_deref() != Some(icon) {
        std::fs::create_dir_all(&dir)
            .and_then(|()| std::fs::write(&path, icon))
            .map_err(|error| {
                CliError::Invalid(format!("could not write {}: {error}", path.display()))
            })?;
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::{Shape, read, targets_windows};
    use lepton_orchestrator::Step;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, assert_err, assert_ok};
    use std::path::Path;

    #[test]
    fn a_window_is_decorated_unless_the_configuration_says_otherwise() -> Result<(), Failure> {
        let root = Path::new("project");
        assert_eq!(
            assert_ok!(read(root, "{}"), "an empty configuration"),
            Shape {
                decorated: true,
                unlimited: false,
                icon: None
            }
        );
        let frameless = assert_ok!(
            read(
                root,
                r#"{"window":{"decorations":false},"bundle":{"icon":"app.ico"}}"#
            ),
            "frameless with an icon"
        );
        assert_eq!(frameless.decorated, false);
        assert_eq!(frameless.icon, Some(root.join("app.ico")));
        assert_err!(
            read(root, r#"{"window":{"decorations":"no"}}"#),
            "a string is not a boolean"
        );
        Ok(())
    }

    #[test]
    fn only_a_windows_build_is_handed_the_icon() -> Result<(), Failure> {
        let build = |target: Option<&str>| {
            let mut step = Step::new("core", "zig").arg("build");
            if let Some(triple) = target {
                step = step.arg(format!("-Dtarget={triple}"));
            }
            step
        };
        assert_eq!(targets_windows(&build(Some("x86_64-windows-gnu"))), true);
        assert_eq!(targets_windows(&build(Some("x86_64-linux-gnu"))), false);
        assert_eq!(targets_windows(&build(None)), cfg!(windows));
        Ok(())
    }

    #[test]
    fn frames_follow_the_display_unless_unlimited_is_asked_for() -> Result<(), Failure> {
        let root = Path::new("project");
        let read_rate = |text: &str| read(root, text).map(|shape| shape.unlimited);
        assert_eq!(assert_ok!(read_rate("{}"), "absent"), false);
        assert_eq!(
            assert_ok!(
                read_rate(r#"{"window":{"frameRate":"display"}}"#),
                "display"
            ),
            false
        );
        assert_eq!(
            assert_ok!(
                read_rate(r#"{"window":{"frameRate":"unlimited"}}"#),
                "unlimited"
            ),
            true
        );
        assert_err!(
            read_rate(r#"{"window":{"frameRate":144}}"#),
            "a number is not a pacing"
        );
        assert_err!(
            read_rate(r#"{"window":{"frameRate":"fast"}}"#),
            "an unknown name is refused"
        );
        Ok(())
    }
}
