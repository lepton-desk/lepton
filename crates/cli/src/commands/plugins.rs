//! Lepton plugins among a project's npm dependencies.
//!
//! A plugin is an npm package whose `package.json` says where its Zig side is:
//! `"lepton": { "plugin": "zig/plugin.zig" }`. The package carries both halves — the
//! TypeScript the page imports and the Zig the core compiles — so installing it is the
//! whole installation. `lepton` finds those packages among `dependencies` and
//! `devDependencies` and hands the core build `-Dplugins=<module>=<path>,…`; the project's
//! `build.zig` makes each a module and `main.zig` registers their commands, which still
//! run only when `permissions` lists them.

use std::path::{Path, PathBuf};

use lepton_orchestrator::Step;
use serde_json::Value;

use super::CliError;

/// One plugin found in `node_modules`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plugin {
    /// The npm name, e.g. `@lepton-desk/plugin-os`.
    pub package: String,
    /// The Zig module name the build gives it: the npm name with every character that is
    /// not a letter or digit turned into `_` (`lepton_desk_plugin_os`).
    pub module: String,
    /// The plugin's Zig root, resolved and inside the package.
    pub root: PathBuf,
}

/// The plugins among the project's dependencies, sorted by package name.
pub fn discover(root: &Path) -> Result<Vec<Plugin>, CliError> {
    let manifest = root.join("package.json");
    let Ok(text) = std::fs::read_to_string(&manifest) else {
        return Ok(Vec::new());
    };
    let json: Value = serde_json::from_str(&text).map_err(|error| {
        CliError::Invalid(format!("{} is not valid JSON: {error}", manifest.display()))
    })?;
    let mut names: Vec<&str> = ["dependencies", "devDependencies"]
        .iter()
        .filter_map(|group| json.get(group).and_then(Value::as_object))
        .flat_map(|deps| deps.keys().map(String::as_str))
        .collect();
    names.sort_unstable();
    names.dedup();

    let mut found = Vec::new();
    for name in names {
        let directory = root.join("node_modules").join(name);
        let Ok(package_text) = std::fs::read_to_string(directory.join("package.json")) else {
            continue; // not installed yet: `pnpm install` has not run
        };
        let Ok(package) = serde_json::from_str::<Value>(&package_text) else {
            continue;
        };
        let Some(relative) = package
            .get("lepton")
            .and_then(|lepton| lepton.get("plugin"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        let directory = std::fs::canonicalize(&directory).map_err(|error| {
            CliError::Invalid(format!(
                "could not resolve {}: {error}",
                directory.display()
            ))
        })?;
        let plugin_root = std::fs::canonicalize(directory.join(relative)).map_err(|error| {
            CliError::Invalid(format!(
                "{name} declares the plugin \"{relative}\", which could not be found: {error}"
            ))
        })?;
        // A plugin's Zig is compiled into the application; it must be the package's own.
        if !plugin_root.starts_with(&directory) || !plugin_root.is_file() {
            return Err(CliError::Invalid(format!(
                "{name} declares the plugin \"{relative}\", which is not a file inside the package"
            )));
        }
        found.push(Plugin {
            package: name.to_owned(),
            module: module_name(name),
            root: plugin_root,
        });
    }
    Ok(found)
}

/// `@lepton-desk/plugin-os` → `lepton_desk_plugin_os`.
pub fn module_name(package: &str) -> String {
    package
        .trim_start_matches('@')
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' })
        .collect()
}

/// Adds `-Dplugins=…` to every core build step, when the project's build takes it and
/// there is at least one plugin. An older project's `build.zig` declares no such option,
/// and `zig build` refuses an unknown one.
pub fn pass_to_core(steps: &mut [Step], root: &Path) -> Result<Vec<Plugin>, CliError> {
    let plugins = discover(root)?;
    if plugins.is_empty() {
        return Ok(plugins);
    }
    let build = root.join(super::build::CORE_DIR).join("build.zig");
    let takes_option =
        std::fs::read_to_string(&build).is_ok_and(|text| text.contains("\"plugins\""));
    if !takes_option {
        return Err(CliError::Invalid(format!(
            "{} is installed, but this project's src-lepton/build.zig predates plugins; recreate it with a current `lepton new`",
            plugins
                .iter()
                .map(|plugin| plugin.package.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )));
    }
    let value = plugins
        .iter()
        .map(|plugin| format!("{}={}", plugin.module, plugin.root.display()))
        .collect::<Vec<_>>()
        .join(",");
    for step in steps.iter_mut() {
        if super::launch::is_core_build(step) {
            step.args.push(format!("-Dplugins={value}"));
        }
    }
    Ok(plugins)
}

#[cfg(test)]
mod tests {
    use super::{discover, module_name, pass_to_core};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    fn project(scratch: &Scratch, build_takes_plugins: bool) -> Result<(), Failure> {
        scratch.write(
            "package.json",
            r#"{"dependencies":{"@lepton-desk/plugin-os":"^0.1.0","vue":"^3"},"devDependencies":{"vite":"^8"}}"#,
        )?;
        scratch.write("node_modules/vue/package.json", r#"{"name":"vue"}"#)?;
        scratch.write(
            "node_modules/@lepton-desk/plugin-os/package.json",
            r#"{"name":"@lepton-desk/plugin-os","lepton":{"plugin":"zig/plugin.zig"}}"#,
        )?;
        scratch.write(
            "node_modules/@lepton-desk/plugin-os/zig/plugin.zig",
            "pub const commands = .{};\n",
        )?;
        let option = if build_takes_plugins {
            "b.option([]const u8, \"plugins\", \"…\")"
        } else {
            ""
        };
        scratch.write("src-lepton/build.zig", option)
    }

    #[test]
    fn a_package_with_a_lepton_plugin_field_is_found() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-found")?;
        project(&scratch, true)?;
        let plugins = assert_ok!(discover(scratch.path()), "discovers");
        assert_eq!(plugins.len(), 1);
        assert_eq!(plugins[0].package, "@lepton-desk/plugin-os");
        assert_eq!(plugins[0].module, "lepton_desk_plugin_os");
        ensure!(
            plugins[0].root.ends_with("zig/plugin.zig"),
            "root {:?}",
            plugins[0].root
        );
        Ok(())
    }

    #[test]
    fn the_core_build_gets_the_option_and_nothing_else_does() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-option")?;
        project(&scratch, true)?;
        let mut steps = vec![
            lepton_orchestrator::Step::new("lepton", "pnpm")
                .args(["run", "build"])
                .in_dir(scratch.path().to_path_buf()),
            lepton_orchestrator::Step::new("lepton", "zig")
                .arg("build")
                .in_dir(scratch.path().join("src-lepton")),
        ];
        assert_ok!(pass_to_core(&mut steps, scratch.path()), "passes");
        ensure!(
            !steps[0].args.iter().any(|arg| arg.starts_with("-Dplugins")),
            "bundler untouched"
        );
        let option = steps[1]
            .args
            .iter()
            .find(|arg| arg.starts_with("-Dplugins="));
        ensure!(
            option.is_some_and(|arg| arg.starts_with("-Dplugins=lepton_desk_plugin_os=")
                && arg.ends_with("zig/plugin.zig")),
            "core args {:?}",
            steps[1].args
        );
        Ok(())
    }

    #[test]
    fn an_older_build_file_is_named_rather_than_handed_an_unknown_option() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-old")?;
        project(&scratch, false)?;
        let error = assert_err!(
            pass_to_core(&mut Vec::new(), scratch.path()),
            "old build.zig"
        );
        assert_contains!(&error.to_string(), "predates plugins");
        Ok(())
    }

    #[test]
    fn a_plugin_path_outside_its_package_is_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-escape")?;
        project(&scratch, true)?;
        scratch.write("outside.zig", "\n")?;
        scratch.write(
            "node_modules/@lepton-desk/plugin-os/package.json",
            r#"{"lepton":{"plugin":"../../../outside.zig"}}"#,
        )?;
        let error = assert_err!(discover(scratch.path()), "escape");
        assert_contains!(&error.to_string(), "not a file inside the package");
        Ok(())
    }

    #[test]
    fn module_names_are_identifiers() -> Result<(), Failure> {
        assert_eq!(
            module_name("@lepton-desk/plugin-os"),
            "lepton_desk_plugin_os"
        );
        assert_eq!(module_name("lepton-plugin.x"), "lepton_plugin_x");
        Ok(())
    }
}
