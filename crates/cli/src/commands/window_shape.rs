//! The window's shape beyond its size, handed to every core build from
//! `lepton.config.json`:
//!
//! - `window.decorations: false` → `-Dwindow-decorations=false`: no title bar, the page
//!   draws its own (Windows and Servo; Linux WPE keeps its title bar for now).
//! - `window.frameRate: "unlimited"` → `-Dframe-rate=unlimited`: the native path draws as
//!   fast as the machine can instead of at the display's refresh (`"display"`, the default).
//!   `LEPTON_FRAME_RATE` overrides it when the program runs.
//! - `window.contextMenu: false` → `-Dcontext-menu=false`: no default right-click menu
//!   (Cut, Copy, Paste, Select All; Inspect in a developer's build).
//! - `wasm.threads: true` → `-Dwasm-threads=true`: the page is cross-origin isolated
//!   (`Cross-Origin-Opener-Policy`/`-Embedder-Policy` on every core answer) and, on WPE,
//!   JavaScriptCore's `SharedArrayBuffer` is on, so WebAssembly threads work.
//! - `bundle.icon` → `-Dicon=<path>`, for a Windows build only: the Windows program's
//!   icon — its title bar, taskbar button and Explorer icon. Without it, Lepton's own
//!   (written into the build cache).
//! - `identifier`, `productName`, `channel.name`, `window.title`, `version` →
//!   `-Didentifier=…`, `-Dproduct=…`, `-Dchannel=…`, `-Dtitle=…`, `-Dapp-version=…`: who
//!   the application is, so an edit after `lepton new` reaches the program (and the page,
//!   through `@lepton-desk/api/app` `info()`).
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
    /// `window.contextMenu` (`true` when absent).
    pub context_menu: bool,
    /// `wasm.threads` (`false` when absent).
    pub wasm_threads: bool,
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
    let context_menu = match config
        .get("window")
        .and_then(|window| window.get("contextMenu"))
    {
        None => true,
        Some(Value::Bool(value)) => *value,
        Some(_) => {
            return Err(CliError::Invalid(
                "\"window.contextMenu\" must be true or false".to_owned(),
            ));
        }
    };
    let wasm_threads = match config.get("wasm").and_then(|wasm| wasm.get("threads")) {
        None => false,
        Some(Value::Bool(value)) => *value,
        Some(_) => {
            return Err(CliError::Invalid(
                "\"wasm.threads\" must be true or false".to_owned(),
            ));
        }
    };
    let bundle = lepton_template_injector::parse_bundle(text)
        .map_err(|error| CliError::Invalid(error.reason))?;
    Ok(Shape {
        decorated,
        unlimited,
        context_menu,
        wasm_threads,
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
    if !shape.context_menu {
        if build.contains("\"context-menu\"") {
            args.push("-Dcontext-menu=false".to_owned());
        } else {
            eprintln!(
                "lepton: src-lepton/build.zig predates window.contextMenu; the default right-click menu stays (run `lepton update`)"
            );
        }
    }
    if shape.wasm_threads {
        // Servo 0.6 has neither `crossOriginIsolated` nor `SharedArrayBuffer`, headers or
        // not, and a shared `WebAssembly.Memory` is a `LinkError` (CI, servo-bridge
        // 40341622993). The build goes on (user's decision); the page runs without threads.
        if steps
            .iter()
            .any(|step| is_core_build(step) && renders_in_servo(step))
        {
            eprintln!(
                "lepton: wasm.threads: Servo has no WebAssembly threads (no SharedArrayBuffer); the page runs without them"
            );
        }
        if build.contains("\"wasm-threads\"") {
            args.push("-Dwasm-threads=true".to_owned());
        } else {
            eprintln!(
                "lepton: src-lepton/build.zig predates wasm.threads; WebAssembly threads stay off (run `lepton update`)"
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
        Some(match (&shape.icon, super::icon::project_ico(root)) {
            (Some(icon), _) => icon.clone(),
            (None, Some(icon)) => icon,
            (None, None) => default_icon(root)?,
        })
    } else {
        None
    };
    // Who the application is (`identifier`, `productName`, `channel.name`, `window.title`):
    // a build option, so an edit reaches the program, and Zig 0.17's cached configuration
    // with it. An older `build.zig` has the values written into `main.zig` instead.
    if build.contains("\"identifier\"") {
        args.extend(identity_args(&text, build.contains("\"app-version\""))?);
    }
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

/// `-Didentifier=…`, `-Dproduct=…`, and `-Dchannel=…` / `-Dtitle=…` / `-Dapp-version=…`
/// when the configuration names them (the template derives them otherwise, as `lepton new`
/// does). `-Dapp-version` only for a `build.zig` that takes it (`versioned`).
fn identity_args(text: &str, versioned: bool) -> Result<Vec<String>, CliError> {
    let config: Value = serde_json::from_str(text).map_err(|error| {
        CliError::Invalid(format!("lepton.config.json is not valid JSON: {error}"))
    })?;
    let at = |path: &[&str]| {
        path.iter()
            .try_fold(&config, |value, key| value.get(key))
            .and_then(Value::as_str)
    };
    let identifier = at(&["identifier"])
        .ok_or_else(|| CliError::Invalid("lepton.config.json has no \"identifier\"".to_owned()))?;
    let mut args = vec![format!("-Didentifier={identifier}")];
    if let Some(product) = at(&["productName"]) {
        args.push(format!("-Dproduct={product}"));
    }
    if let Some(channel) = at(&["channel", "name"]) {
        args.push(format!("-Dchannel={channel}"));
    }
    if let Some(title) = at(&["window", "title"]) {
        args.push(format!("-Dtitle={title}"));
    }
    if let Some(version) = at(&["version"]).filter(|_| versioned) {
        args.push(format!("-Dapp-version={version}"));
    }
    Ok(args)
}

/// Whether a core build renders pages in Servo (`-Dservo-lib`, `build.rs`).
fn renders_in_servo(step: &Step) -> bool {
    step.args.iter().any(|arg| arg.starts_with("-Dservo-lib="))
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
    use super::{Shape, read, renders_in_servo, targets_windows};
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
                context_menu: true,
                wasm_threads: false,
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
    fn the_default_context_menu_is_on_unless_turned_off() -> Result<(), Failure> {
        let root = Path::new("project");
        let off = assert_ok!(
            read(root, r#"{"window":{"contextMenu":false}}"#),
            "turned off"
        );
        assert_eq!(off.context_menu, false);
        assert_err!(
            read(root, r#"{"window":{"contextMenu":"no"}}"#),
            "a string is not a boolean"
        );
        Ok(())
    }

    #[test]
    fn wasm_threads_are_off_unless_turned_on() -> Result<(), Failure> {
        let root = Path::new("project");
        let on = assert_ok!(read(root, r#"{"wasm":{"threads":true}}"#), "turned on");
        assert_eq!(on.wasm_threads, true);
        assert_err!(
            read(root, r#"{"wasm":{"threads":1}}"#),
            "a number is not a boolean"
        );
        Ok(())
    }

    #[test]
    fn a_servo_build_is_told_apart() -> Result<(), Failure> {
        let servo = Step::new("build", "zig")
            .arg("build")
            .arg("-Dservo-lib=/opt/servo");
        let wpe = Step::new("build", "zig").arg("build");
        assert_eq!(renders_in_servo(&servo), true);
        assert_eq!(renders_in_servo(&wpe), false);
        Ok(())
    }

    #[test]
    fn the_build_is_handed_who_the_application_is() -> Result<(), Failure> {
        let args = assert_ok!(
            super::identity_args(
                r#"{"identifier":"dev.lepton.notes","productName":"Notes","version":"1.2.3","channel":{"name":"/lepton-dev.lepton.notes"},"window":{"title":"My Notes"}}"#,
                true
            ),
            "a full configuration"
        );
        assert_eq!(
            args,
            vec![
                "-Didentifier=dev.lepton.notes".to_owned(),
                "-Dproduct=Notes".to_owned(),
                "-Dchannel=/lepton-dev.lepton.notes".to_owned(),
                "-Dtitle=My Notes".to_owned(),
                "-Dapp-version=1.2.3".to_owned(),
            ]
        );
        // A `build.zig` from before `-Dapp-version` would refuse the option.
        assert_eq!(
            assert_ok!(
                super::identity_args(r#"{"identifier":"a.b","version":"1.2.3"}"#, false),
                "an older build.zig"
            ),
            vec!["-Didentifier=a.b".to_owned()]
        );
        assert_eq!(
            assert_ok!(
                super::identity_args(r#"{"identifier":"a.b"}"#, true),
                "only the identifier"
            ),
            vec!["-Didentifier=a.b".to_owned()]
        );
        assert_err!(super::identity_args("{}", true), "no identifier");
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
