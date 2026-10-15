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

use lepton_orchestrator::{Step, Toolchain, run_streaming};

use super::{CliError, Outcome};

/// The package manager a frontend step runs through.
///
/// pnpm when the probe found a usable one, npm otherwise: npm ships with Node, so a
/// machine that passed the `Develop`/`Build` requirement has it.
pub fn package_manager(chain: &Toolchain) -> &'static str {
    if chain.package_manager.is_usable() && chain.package_manager.name == "pnpm" {
        "pnpm"
    } else {
        "npm"
    }
}

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
        return Ok(());
    };
    for step in steps.iter_mut() {
        if is_core_build(step) {
            step.args.push(format!("-Dpermissions={}", names.join(",")));
        }
    }
    Ok(())
}

fn is_core_build(step: &Step) -> bool {
    step.args.first().is_some_and(|arg| arg == "build")
        && step
            .cwd
            .as_ref()
            .is_some_and(|dir| dir.ends_with(super::build::CORE_DIR))
}

/// Tells every core build where the bundler wrote the frontend, when a plan bundles one.
///
/// The core's build installs it to `share/<name>/dist` beside the binary, which is where
/// the binary looks first; a plan with no `run build` step has no bundle to hand over.
pub fn hand_over_frontend(steps: &mut [Step], root: &Path) {
    let bundles = steps
        .iter()
        .any(|step| step.args.len() >= 2 && step.args[0] == "run" && step.args[1] == "build");
    if !bundles {
        return;
    }
    let dist = root.join("dist");
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
        // No extension and a regular file: on Linux and macOS that is the executable;
        // debug-info sidecars (`.pdb`, `.dSYM`) carry an extension and are skipped.
        if path.extension().is_none() && path.is_file() {
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

/// Starts the application in the foreground and waits until its window closes.
///
/// The executable is looked up by the name the build was given; `find_application`'s
/// scan is the fallback for a build that predates naming, so an existing project's
/// `zig-out` still runs.
pub fn launch(tool: &'static str, bin: &Path, binary: &str) -> Outcome {
    let named = bin.join(binary);
    let program = if named.is_file() {
        named
    } else {
        find_application(bin)?
    };
    let step = Step::new(tool, program.to_string_lossy().as_ref());
    run_streaming(&step).map_err(CliError::from)
}

#[cfg(test)]
mod tests {
    use super::find_application;
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn the_extensionless_file_is_the_application() -> Result<(), Failure> {
        let scratch = Scratch::new("launch-one")?;
        scratch.write("bin/app", "")?;
        scratch.write("bin/app.pdb", "")?;

        let found = assert_ok!(
            find_application(&scratch.path().join("bin")),
            "one executable should be found"
        );

        assert_eq!(found, scratch.path().join("bin").join("app"));
        Ok(())
    }

    #[test]
    fn a_directory_is_not_mistaken_for_the_application() -> Result<(), Failure> {
        // `zig-out/bin` can hold a directory of the same shape as a binary name
        // (a macOS bundle's parent, a leftover cache); starting it fails far from here.
        let scratch = Scratch::new("launch-dir")?;
        scratch.write("bin/app", "")?;
        scratch.write("bin/nested/keep", "")?;

        let found = assert_ok!(
            find_application(&scratch.path().join("bin")),
            "the directory should be skipped"
        );

        assert_eq!(found, scratch.path().join("bin").join("app"));
        Ok(())
    }

    #[test]
    fn two_executables_are_refused_by_name() -> Result<(), Failure> {
        let scratch = Scratch::new("launch-two")?;
        scratch.write("bin/app", "")?;
        scratch.write("bin/old-name", "")?;

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
    use super::{binary_name, grant_permissions, name_core};
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

        super::hand_over_frontend(&mut steps, &root);

        ensure!(
            steps[1]
                .args
                .iter()
                .any(|arg| arg == "-Dfrontend-dist=/project/dist"),
            "the core must install the bundle: {:?}",
            steps[1].args
        );
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

        super::hand_over_frontend(&mut steps, &root);

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
