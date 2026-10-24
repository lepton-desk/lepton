//! Finding and starting the application a build produced.
//!
//! Shared by `dev` and `run`, which differ in what they build and agree on what
//! happens after: the core's build installs exactly one executable into
//! `src-lepton/zig-out/bin`, and the command starts that file and waits for it.
//!
//! The core is built with `zig build`, never `zig build run`. The template's `run`
//! step builds *and opens* the window, so a command that ran it and then started the
//! binary itself opened the application twice — the second window appearing the
//! moment the developer closed the first.

use std::path::{Path, PathBuf};

use lepton_orchestrator::{Step, run_streaming};

use super::{CliError, Outcome};

/// The executable's name for a product, as `zig build -Dname=` receives it.
///
/// The name a process carries is what a system monitor and `ps` list. Every project
/// used to build an executable called `app`, so two Lepton applications were
/// indistinguishable in a task manager and neither said what it was. Lowercase ASCII
/// letters, digits, `-` and `_` survive; any other run of characters becomes one `-`.
pub fn binary_name(product: &str) -> String {
    let mut name = String::with_capacity(product.len());
    for ch in product.chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() || lower == '_' || lower == '-' {
            name.push(lower);
        } else if !name.ends_with('-') {
            name.push('-');
        }
    }
    let trimmed = name.trim_matches('-');
    if trimmed.is_empty() {
        String::from("app")
    } else {
        trimmed.to_owned()
    }
}

/// Names the executable on every `zig build` step of a plan.
pub fn name_core(steps: &mut [Step], binary: &str) {
    for step in steps.iter_mut() {
        if step.args.first().is_some_and(|arg| arg == "build")
            && step
                .cwd
                .as_ref()
                .is_some_and(|dir| dir.ends_with(super::build::CORE_DIR))
        {
            step.args.push(format!("-Dname={binary}"));
        }
    }
}

/// Hands `lepton.config.json`'s `permissions` to every core build as `-Dpermissions=a,b`.
///
/// Only when the configuration has the field: an older project's core build declares no
/// such option and `zig build` would refuse an unknown one. Present but empty is passed
/// as empty — nothing granted, said explicitly.
pub fn grant_permissions(steps: &mut [Step], root: &Path) -> Result<(), CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;
    let Some(names) = lepton_template_injector::parse_permissions(&text)
        .map_err(|error| CliError::Invalid(error.reason))?
    else {
        return grant_web_permissions(steps, root, &text);
    };
    for step in steps.iter_mut() {
        if is_core_build(step) {
            step.args.push(format!("-Dpermissions={}", names.join(",")));
        }
    }
    grant_web_permissions(steps, root, &text)
}

/// `webPermissions` as `-Dweb-permissions=kind=policy,…`; nothing when the field is absent.
fn grant_web_permissions(steps: &mut [Step], root: &Path, config: &str) -> Result<(), CliError> {
    let Some(pairs) = lepton_template_injector::parse_web_permissions(config)
        .map_err(|error| CliError::Invalid(error.reason))?
    else {
        return Ok(());
    };
    // A project from before this has a build that rejects an unknown option.
    let build = std::fs::read_to_string(root.join(super::build::CORE_DIR).join("build.zig"))
        .unwrap_or_default();
    if !build.contains("\"web-permissions\"") {
        return Err(CliError::Invalid(
            "lepton.config.json has \"webPermissions\", but this project's src-lepton/build.zig predates them; recreate it with a current `lepton new`".to_owned(),
        ));
    }
    let joined: Vec<String> = pairs
        .iter()
        .map(|(kind, policy)| format!("{kind}={policy}"))
        .collect();
    let for_windows = steps
        .iter()
        .any(|step| is_core_build(step) && super::window_shape::targets_windows(step));
    if for_windows {
        for kind in inert_on_windows(&pairs) {
            eprintln!(
                "lepton: webPermissions \"{kind}\" has no counterpart in WebView2 (Windows): the page is not asked for it there, so allow or ask changes nothing"
            );
        }
    }
    for step in steps.iter_mut() {
        if is_core_build(step) {
            step.args
                .push(format!("-Dweb-permissions={}", joined.join(",")));
        }
    }
    Ok(())
}

/// The kinds WebView2 has no permission for (`COREWEBVIEW2_PERMISSION_KIND`, WebView2.h:
/// camera, microphone, geolocation and notifications are the four Lepton's kinds share),
/// given anything but `deny`: a policy Windows would accept and never read.
fn inert_on_windows<K: AsRef<str>, P: AsRef<str>>(pairs: &[(K, P)]) -> Vec<String> {
    const WITHOUT: [&str; 5] = [
        "pointer-lock",
        "device-info",
        "media-keys",
        "storage-access",
        "xr",
    ];
    pairs
        .iter()
        .filter(|(kind, policy)| WITHOUT.contains(&kind.as_ref()) && policy.as_ref() != "deny")
        .map(|(kind, _)| kind.as_ref().to_owned())
        .collect()
}

/// Hands `lepton.config.json`'s `window.width`/`window.height` to every core build as
/// `-Dwindow-width`/`-Dwindow-height`.
///
/// `lepton new` once wrote the size into `main.zig` and nothing read the configuration
/// again, so a project changed to 800×600 still opened at 1200×800 (measured). A project
/// from before this has that `main.zig` and a build that rejects the option: it keeps
/// building at its written size, and is told so rather than left to wonder.
pub fn size_window(steps: &mut [Step], root: &Path, width: u32, height: u32) {
    let build = std::fs::read_to_string(root.join(super::build::CORE_DIR).join("build.zig"))
        .unwrap_or_default();
    if !build.contains("\"window-width\"") {
        eprintln!(
            "lepton: src-lepton/build.zig predates the configured window size; the window keeps the size written in src-lepton/main.zig (recreate the project with a current `lepton new` to use lepton.config.json's)"
        );
        return;
    }
    for step in steps.iter_mut() {
        if is_core_build(step) {
            step.args.push(format!("-Dwindow-width={width}"));
            step.args.push(format!("-Dwindow-height={height}"));
        }
    }
}

pub(super) fn is_core_build(step: &Step) -> bool {
    step.args.first().is_some_and(|arg| arg == "build")
        && step
            .cwd
            .as_ref()
            .is_some_and(|dir| dir.ends_with(super::build::CORE_DIR))
}

/// The `frontend` section of the project's configuration: Vite's `dist` and flags without it.
pub fn read_frontend(root: &Path) -> Result<lepton_template_injector::Frontend, CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;
    lepton_template_injector::parse_frontend(&text).map_err(|error| CliError::Invalid(error.reason))
}

/// Tells every core build where the bundler wrote the frontend, when a plan bundles one.
///
/// `dist` is `frontend.dist` (`out` for Next.js). The core's build installs it to
/// `share/<name>/dist` beside the binary whatever it was called, which is where the binary
/// looks first; a plan with no `run build` step has no bundle to hand over.
pub fn hand_over_frontend(steps: &mut [Step], root: &Path, dist: &str) {
    let bundles = steps
        .iter()
        .any(|step| step.args.len() >= 2 && step.args[0] == "run" && step.args[1] == "build");
    if !bundles {
        return;
    }
    let dist = root.join(dist);
    for step in steps.iter_mut() {
        if step.args.first().is_some_and(|arg| arg == "build")
            && step
                .cwd
                .as_ref()
                .is_some_and(|dir| dir.ends_with(super::build::CORE_DIR))
        {
            step.args
                .push(format!("-Dfrontend-dist={}", dist.display()));
        }
    }
}

/// Empties the frontend a previous build installed, before a core build that is handed a
/// new one installs it.
///
/// The bundler empties `dist/` each time, but the core's build copies it to
/// `zig-out/share/<name>/dist` and Zig's directory install only adds and replaces: files
/// of earlier bundles stayed and went into every package (measured: an older build's
/// `index-*.js` beside the current one in a Windows `.zip`). Only that directory, which
/// the core's build made, and only for a step that installs a bundle.
pub fn clear_installed_frontend(step: &Step) -> Result<(), CliError> {
    let installs = step
        .args
        .iter()
        .any(|arg| arg.starts_with("-Dfrontend-dist="));
    let name = step.args.iter().find_map(|arg| arg.strip_prefix("-Dname="));
    let (true, Some(name), Some(core)) = (installs && is_core_build(step), name, step.cwd.as_ref())
    else {
        return Ok(());
    };
    if name.is_empty() || name == "." || name == ".." || name.contains(['/', '\\']) {
        return Ok(());
    }
    let installed = core.join("zig-out").join("share").join(name).join("dist");
    match std::fs::remove_dir_all(&installed) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(CliError::Invalid(
            format!("could not empty {}: {error}", installed.display()),
        )),
        _ => Ok(()),
    }
}

/// The one executable the core's build installed under `bin`.
///
/// Refuses rather than picks when there is more than one: a stale binary from a
/// renamed project would otherwise be started in place of the fresh one, and the
/// developer would debug code they had already changed.
pub fn find_application(bin: &Path) -> Result<PathBuf, CliError> {
    let entries = std::fs::read_dir(bin).map_err(|error| {
        CliError::Invalid(format!(
            "no application binary in {}: {error}",
            bin.display()
        ))
    })?;

    let mut found = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| {
            CliError::Invalid(format!("could not list {}: {error}", bin.display()))
        })?;
        let path = entry.path();
        // No extension (Linux, macOS) or `.exe` (Windows), and a regular file: that is the
        // executable; debug-info sidecars (`.pdb`, `.dSYM`) are skipped.
        if is_executable_name(&path) && path.is_file() {
            found.push(path);
        }
    }

    match (found.pop(), found.is_empty()) {
        (Some(only), true) => Ok(only),
        (None, _) => Err(CliError::Invalid(format!(
            "no application binary in {} after the build",
            bin.display()
        ))),
        (Some(last), false) => {
            found.push(last);
            found.sort();
            let names: Vec<String> = found
                .iter()
                .map(|path| path.display().to_string())
                .collect();
            Err(CliError::Invalid(format!(
                "more than one executable in {}; remove the stale ones: {}",
                bin.display(),
                names.join(", ")
            )))
        }
    }
}

/// Whether `path`'s name is an executable's on this system.
fn is_executable_name(path: &Path) -> bool {
    match std::env::consts::EXE_EXTENSION {
        "" => path.extension().is_none(),
        wanted => path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case(wanted)),
    }
}

/// Starts the application in the foreground and waits until its window closes.
///
/// The executable is looked up by the name the build was given; `find_application`'s
/// scan is the fallback for a build that predates naming, so an existing project's
/// `zig-out` still runs.
pub fn launch(tool: &'static str, bin: &Path, binary: &str) -> Outcome {
    launch_with(tool, bin, binary, &[])
}

/// [`launch`] with variables set for the application only (`LEPTON_RECORD`, …).
pub fn launch_with(
    tool: &'static str,
    bin: &Path,
    binary: &str,
    env: &[(&str, String)],
) -> Outcome {
    let named = bin.join(format!("{binary}{}", std::env::consts::EXE_SUFFIX));
    let program = if named.is_file() {
        named
    } else {
        find_application(bin)?
    };
    let mut step = Step::new(tool, program.to_string_lossy().as_ref());
    for (name, value) in env {
        step = step.env(*name, value.clone());
    }
    let report = super::report::Report::new();
    let started = report.start("app", &super::report::shown(&program));
    // A termination signal's handler waits for this report (`supervise::foreground`)…
    let reporting = lepton_orchestrator::supervise::foreground();
    let outcome = run_streaming(&step);
    report.finished(&started, outcome.is_ok());
    drop(reporting);
    if lepton_orchestrator::supervise::interrupted() {
        // …and then ends the process (130, after `lepton dev`'s receipt), whichever
        // thread got here first.
        lepton_orchestrator::supervise::await_exit();
    }
    outcome.map_err(CliError::from)
}

#[cfg(test)]
mod tests {
    use super::find_application;
    use lepton_orchestrator::testing::{Failure, Scratch};

    /// `bin/<name>`, with `.exe` on Windows.
    fn exe(name: &str) -> String {
        format!("bin/{name}{}", std::env::consts::EXE_SUFFIX)
    }
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn the_extensionless_file_is_the_application() -> Result<(), Failure> {
        let scratch = Scratch::new("launch-one")?;
        scratch.write(&exe("app"), "")?;
        scratch.write("bin/app.pdb", "")?;

        let found = assert_ok!(
            find_application(&scratch.path().join("bin")),
            "one executable should be found"
        );

        assert_eq!(found, scratch.path().join(exe("app")));
        Ok(())
    }

    #[test]
    fn a_directory_is_not_mistaken_for_the_application() -> Result<(), Failure> {
        // `zig-out/bin` can hold a directory of the same shape as a binary name
        // (a macOS bundle's parent, a leftover cache); starting it fails far from here.
        let scratch = Scratch::new("launch-dir")?;
        scratch.write(&exe("app"), "")?;
        scratch.write("bin/nested/keep", "")?;

        let found = assert_ok!(
            find_application(&scratch.path().join("bin")),
            "the directory should be skipped"
        );

        assert_eq!(found, scratch.path().join(exe("app")));
        Ok(())
    }

    #[test]
    fn two_executables_are_refused_by_name() -> Result<(), Failure> {
        let scratch = Scratch::new("launch-two")?;
        scratch.write(&exe("app"), "")?;
        scratch.write(&exe("old-name"), "")?;

        let error = assert_err!(
            find_application(&scratch.path().join("bin")),
            "a stale binary must not be picked silently"
        );

        let text = error.to_string();
        assert_contains!(&text, "app");
        assert_contains!(&text, "old-name");
        Ok(())
    }

    #[test]
    fn a_missing_build_says_where_it_looked() -> Result<(), Failure> {
        let scratch = Scratch::new("launch-none")?;

        let error = assert_err!(
            find_application(&scratch.path().join("bin")),
            "no build means no application"
        );

        assert_contains!(&error.to_string(), "bin");
        Ok(())
    }
}

#[cfg(test)]
mod naming_tests {
    use super::{binary_name, grant_permissions, inert_on_windows, name_core, size_window};
    use crate::commands::build::CORE_DIR;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{Step, assert_eq, ensure};

    #[test]
    fn a_product_name_becomes_a_process_name() -> Result<(), Failure> {
        assert_eq!(binary_name("run-app"), "run-app");
        assert_eq!(binary_name("My Notes App"), "my-notes-app");
        assert_eq!(binary_name("  Ünïcode / Tool  "), "n-code-tool");
        Ok(())
    }

    #[test]
    fn a_name_with_nothing_usable_falls_back_rather_than_empty() -> Result<(), Failure> {
        // `-Dname=` with an empty value would be a build error far from its cause.
        assert_eq!(binary_name("???"), "app");
        Ok(())
    }

    #[test]
    fn a_bundled_frontend_is_handed_to_the_core_build() -> Result<(), Failure> {
        let root = std::path::PathBuf::from("/project");
        let mut steps = vec![
            Step::new("run", "pnpm")
                .args(["run", "build"])
                .in_dir(root.clone()),
            Step::new("run", "zig")
                .arg("build")
                .in_dir(root.join(CORE_DIR)),
        ];

        super::hand_over_frontend(&mut steps, &root, "dist");

        ensure!(
            steps[1]
                .args
                .iter()
                .any(|arg| *arg == format!("-Dfrontend-dist={}", root.join("dist").display())),
            "the core must install the bundle: {:?}",
            steps[1].args
        );
        Ok(())
    }

    #[test]
    fn the_configured_output_directory_is_the_one_handed_over() -> Result<(), Failure> {
        // Next.js exports to `out/`: handing over `dist` would install an empty frontend.
        let root = std::path::PathBuf::from("/project");
        let mut steps = bundle_then_core(&root);

        super::hand_over_frontend(&mut steps, &root, "out");

        assert_eq!(
            steps[1]
                .args
                .iter()
                .find(|arg| arg.starts_with("-Dfrontend-dist="))
                .cloned(),
            Some(format!("-Dfrontend-dist={}", root.join("out").display()))
        );
        Ok(())
    }

    #[test]
    fn a_core_build_handed_a_bundle_empties_the_one_installed_before() -> Result<(), Failure> {
        let scratch = lepton_orchestrator::testing::Scratch::new("installed-frontend")?;
        let installed = format!("{CORE_DIR}/zig-out/share/notes/dist/assets/index-old.js");
        scratch.write(&installed, "old")?;
        scratch.write(&format!("{CORE_DIR}/zig-out/share/notes/icon.ico"), "icon")?;
        let core = Step::new("run", "zig")
            .args(["build", "-Dname=notes"])
            .in_dir(scratch.path().join(CORE_DIR));

        // No bundle handed over (a native build, `lepton dev`): nothing is touched.
        lepton_orchestrator::assert_ok!(super::clear_installed_frontend(&core), "no bundle");
        ensure!(
            scratch.path().join(&installed).exists(),
            "kept without a bundle"
        );

        let handed = core.clone().arg("-Dfrontend-dist=/project/dist");
        lepton_orchestrator::assert_ok!(super::clear_installed_frontend(&handed), "cleared");
        ensure!(
            !scratch.path().join(&installed).exists(),
            "the old bundle must go"
        );
        ensure!(
            scratch
                .path()
                .join(format!("{CORE_DIR}/zig-out/share/notes/icon.ico"))
                .exists(),
            "only the bundle's directory goes"
        );
        // Already gone is fine.
        lepton_orchestrator::assert_ok!(super::clear_installed_frontend(&handed), "again");
        Ok(())
    }

    #[test]
    fn a_plan_without_a_bundle_hands_nothing_over() -> Result<(), Failure> {
        // A native build, or a dev loop served by Vite: no `dist` exists to install.
        let root = std::path::PathBuf::from("/project");
        let mut steps = vec![
            Step::new("run", "zig")
                .arg("build")
                .in_dir(root.join(CORE_DIR)),
        ];

        super::hand_over_frontend(&mut steps, &root, "dist");

        ensure!(
            !steps[0]
                .args
                .iter()
                .any(|arg| arg.starts_with("-Dfrontend-dist")),
            "nothing to install: {:?}",
            steps[0].args
        );
        Ok(())
    }

    fn bundle_then_core(root: &std::path::Path) -> Vec<Step> {
        vec![
            Step::new("run", "pnpm")
                .args(["run", "build"])
                .in_dir(root.to_path_buf()),
            Step::new("run", "zig")
                .arg("build")
                .in_dir(root.join(CORE_DIR)),
        ]
    }

    #[test]
    fn listed_permissions_reach_only_the_core_build() -> Result<(), Failure> {
        let scratch = lepton_orchestrator::testing::Scratch::new("permissions-listed")?;
        scratch.write(
            "lepton.config.json",
            r#"{"productName":"Notes","permissions":["window.close","notes.save"]}"#,
        )?;
        let mut steps = bundle_then_core(scratch.path());
        lepton_orchestrator::assert_ok!(grant_permissions(&mut steps, scratch.path()), "grants");
        ensure!(
            !steps[0]
                .args
                .iter()
                .any(|arg| arg.starts_with("-Dpermissions")),
            "bundler got permissions: {:?}",
            steps[0].args
        );
        ensure!(
            steps[1]
                .args
                .iter()
                .any(|arg| arg == "-Dpermissions=window.close,notes.save"),
            "core args: {:?}",
            steps[1].args
        );
        Ok(())
    }

    #[test]
    fn no_field_passes_no_option_and_a_wildcard_stops_the_build() -> Result<(), Failure> {
        let scratch = lepton_orchestrator::testing::Scratch::new("permissions-absent")?;
        scratch.write("lepton.config.json", r#"{"productName":"Notes"}"#)?;
        let mut steps = bundle_then_core(scratch.path());
        lepton_orchestrator::assert_ok!(grant_permissions(&mut steps, scratch.path()), "absent");
        ensure!(
            !steps[1]
                .args
                .iter()
                .any(|arg| arg.starts_with("-Dpermissions")),
            "an older project's core takes no such option: {:?}",
            steps[1].args
        );

        scratch.write(
            "lepton.config.json",
            r#"{"productName":"Notes","permissions":["*"]}"#,
        )?;
        let error = lepton_orchestrator::assert_err!(
            grant_permissions(&mut steps, scratch.path()),
            "wildcard"
        );
        lepton_orchestrator::assert_contains!(&error.to_string(), "wildcards are not allowed");
        Ok(())
    }

    #[test]
    fn the_kinds_webview2_cannot_ask_for_are_named_unless_denied() -> Result<(), Failure> {
        let pairs = [
            ("camera", "allow"),
            ("pointer-lock", "allow"),
            ("xr", "ask"),
            ("media-keys", "deny"),
        ];
        assert_eq!(
            inert_on_windows(&pairs),
            vec![String::from("pointer-lock"), String::from("xr")]
        );
        Ok(())
    }

    #[test]
    fn web_permissions_reach_a_current_core_and_stop_an_old_one() -> Result<(), Failure> {
        let scratch = lepton_orchestrator::testing::Scratch::new("web-permissions")?;
        scratch.write(
            "lepton.config.json",
            r#"{"productName":"Notes","webPermissions":{"notifications":"allow","camera":"deny"}}"#,
        )?;
        scratch.write("src-lepton/build.zig", "const x = \"permissions\";\n")?;
        let mut steps = bundle_then_core(scratch.path());
        let error = lepton_orchestrator::assert_err!(
            grant_permissions(&mut steps, scratch.path()),
            "an old build.zig"
        );
        lepton_orchestrator::assert_contains!(&error.to_string(), "predates them");

        scratch.write(
            "src-lepton/build.zig",
            "b.option([]const u8, \"web-permissions\", \"\")\n",
        )?;
        let mut steps = bundle_then_core(scratch.path());
        lepton_orchestrator::assert_ok!(grant_permissions(&mut steps, scratch.path()), "current");
        ensure!(
            steps[1]
                .args
                .iter()
                .any(|arg| arg == "-Dweb-permissions=camera=deny,notifications=allow"),
            "core args: {:?}",
            steps[1].args
        );
        ensure!(
            !steps[0].args.iter().any(|arg| arg.starts_with("-Dweb-")),
            "bundler got web permissions: {:?}",
            steps[0].args
        );
        Ok(())
    }

    #[test]
    fn the_configured_window_size_reaches_a_current_core_only() -> Result<(), Failure> {
        let scratch = lepton_orchestrator::testing::Scratch::new("window-size")?;
        scratch.write("src-lepton/build.zig", "const x = \"permissions\";\n")?;
        let mut steps = bundle_then_core(scratch.path());
        size_window(&mut steps, scratch.path(), 800, 600);
        ensure!(
            !steps[1].args.iter().any(|arg| arg.starts_with("-Dwindow-")),
            "an older core takes no such option: {:?}",
            steps[1].args
        );

        // The build file `lepton new` writes today, not a stand-in: a template that
        // stopped declaring the option would leave the configuration unread again.
        scratch.write("src-lepton/build.zig", lepton_template_injector::ZIG_BUILD)?;
        let mut steps = bundle_then_core(scratch.path());
        size_window(&mut steps, scratch.path(), 800, 600);
        ensure!(
            steps[1].args.iter().any(|arg| arg == "-Dwindow-width=800")
                && steps[1].args.iter().any(|arg| arg == "-Dwindow-height=600"),
            "core args: {:?}",
            steps[1].args
        );
        ensure!(
            !steps[0].args.iter().any(|arg| arg.starts_with("-Dwindow-")),
            "bundler got the window size: {:?}",
            steps[0].args
        );
        Ok(())
    }

    #[test]
    fn only_the_core_build_is_named() -> Result<(), Failure> {
        let root = std::path::PathBuf::from("/project");
        let mut steps = vec![
            Step::new("run", "pnpm")
                .args(["run", "build"])
                .in_dir(root.clone()),
            Step::new("run", "zig")
                .arg("build")
                .in_dir(root.join(CORE_DIR)),
        ];

        name_core(&mut steps, "notes");

        ensure!(
            !steps[0].args.iter().any(|arg| arg.starts_with("-Dname")),
            "the bundler must not be named: {:?}",
            steps[0].args
        );
        ensure!(
            steps[1].args.iter().any(|arg| arg == "-Dname=notes"),
            "the core must be named: {:?}",
            steps[1].args
        );
        Ok(())
    }
}
