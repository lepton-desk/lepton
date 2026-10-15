//! Lepton plugins among a project's npm dependencies.
//!
//! A plugin is an npm package whose `package.json` says where its Zig side is:
//! `"lepton": { "plugin": "zig/plugin.zig" }`. The package carries both halves — the
//! TypeScript the page imports and the Zig the core compiles — so installing it is the
//! whole installation. `lepton` finds those packages among `dependencies` and
//! `devDependencies` and hands the core build `-Dplugins=<module>=<path>,…`; the project's
//! `build.zig` makes each a module and `main.zig` registers their commands, which still
//! run only when `permissions` lists them.
//!
//! A plugin that takes settings names them in `"lepton": { "settings": "fs" }`; the
//! application gives them in `lepton.config.json` → `"plugins": { "fs": { … } }`, and the
//! core build gets them flattened to `key=value` lines as `-Dplugin-config`.

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
    /// The `plugins.<name>` section of `lepton.config.json` it reads, if any.
    pub settings: Option<String>,
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
        let settings = package
            .get("lepton")
            .and_then(|lepton| lepton.get("settings"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        found.push(Plugin {
            package: name.to_owned(),
            module: module_name(name),
            root: plugin_root,
            settings,
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

/// Adds `-Dplugins=…` and `-Dplugin-config=…` to every core build step, when the project's
/// build takes them and there is at least one plugin. An older project's `build.zig`
/// declares no such options, and `zig build` refuses an unknown one.
pub fn pass_to_core(steps: &mut [Step], root: &Path) -> Result<Vec<Plugin>, CliError> {
    let plugins = discover(root)?;
    let config_path = root.join(lepton_orchestrator::CONFIG_FILE);
    let config: Value = match std::fs::read_to_string(&config_path) {
        Ok(text) => serde_json::from_str(&text).map_err(|error| {
            CliError::Invalid(format!(
                "{} is not valid JSON: {error}",
                config_path.display()
            ))
        })?,
        Err(_) => Value::Null,
    };
    let settings = settings_text(&config, &plugins)?;
    if plugins.is_empty() {
        return Ok(plugins);
    }
    let build = root.join(super::build::CORE_DIR).join("build.zig");
    let build_text = std::fs::read_to_string(&build).unwrap_or_default();
    let names = || {
        plugins
            .iter()
            .map(|plugin| plugin.package.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    };
    if !build_text.contains("\"plugins\"") {
        return Err(CliError::Invalid(format!(
            "{} is installed, but this project's src-lepton/build.zig predates plugins; recreate it with a current `lepton new`",
            names()
        )));
    }
    let takes_settings = build_text.contains("\"plugin-config\"");
    let needs_settings =
        config.get("plugins").is_some() || plugins.iter().any(|plugin| plugin.settings.is_some());
    if needs_settings && !takes_settings {
        return Err(CliError::Invalid(format!(
            "{} takes settings, but this project's src-lepton/build.zig predates plugin settings; recreate it with a current `lepton new`",
            names()
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
            if takes_settings {
                step.args.push(format!("-Dplugin-config={settings}"));
            }
        }
    }
    Ok(plugins)
}

/// `lepton.config.json`'s `plugins` section as `key=value` lines — `"fs": { "scope":
/// ["$APPDATA", "$DOCUMENT"] }` gives `fs.scope=$APPDATA` and `fs.scope=$DOCUMENT` — after
/// `app.identifier=<identifier>`. Each section must belong to an installed plugin, so a
/// misspelt one is an error rather than settings nobody reads.
pub fn settings_text(config: &Value, plugins: &[Plugin]) -> Result<String, CliError> {
    let invalid = |reason: String| CliError::Invalid(format!("lepton.config.json: {reason}"));
    let mut lines = Vec::new();
    if let Some(identifier) = config.get("identifier").and_then(Value::as_str) {
        lines.push(format!("app.identifier={identifier}"));
    }
    let Some(section) = config.get("plugins") else {
        return Ok(lines.join("\n"));
    };
    let Value::Object(sections) = section else {
        return Err(invalid(
            "\"plugins\" must be an object of plugin settings".to_owned(),
        ));
    };
    for (name, fields) in sections {
        if !plugins
            .iter()
            .any(|plugin| plugin.settings.as_deref() == Some(name.as_str()))
        {
            let readers: Vec<&str> = plugins
                .iter()
                .filter_map(|plugin| plugin.settings.as_deref())
                .collect();
            return Err(invalid(format!(
                "\"plugins.{name}\" is read by no installed plugin (plugins taking settings: {})",
                if readers.is_empty() {
                    "none".to_owned()
                } else {
                    readers.join(", ")
                }
            )));
        }
        let Value::Object(fields) = fields else {
            return Err(invalid(format!("\"plugins.{name}\" must be an object")));
        };
        for (field, value) in fields {
            if !plain_word(field) {
                return Err(invalid(format!(
                    "\"plugins.{name}.{field}\": a setting name is lowercase letters, digits and _"
                )));
            }
            let items: Vec<&Value> = match value {
                Value::Array(items) => items.iter().collect(),
                other => vec![other],
            };
            for item in items {
                let Value::String(text) = item else {
                    return Err(invalid(format!(
                        "\"plugins.{name}.{field}\" must be a string or an array of strings"
                    )));
                };
                if text.contains('\n') || text.contains('\0') {
                    return Err(invalid(format!(
                        "\"plugins.{name}.{field}\" has a line break or NUL in {text:?}"
                    )));
                }
                lines.push(format!("{name}.{field}={text}"));
            }
        }
    }
    Ok(lines.join("\n"))
}

/// `[a-z][a-z0-9_]*`.
pub fn plain_word(word: &str) -> bool {
    let mut chars = word.chars();
    chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
}

#[cfg(test)]
mod tests {
    use super::{discover, module_name, pass_to_core, settings_text};
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

    fn fs_plugin(scratch: &Scratch, build: &str, config: &str) -> Result<(), Failure> {
        scratch.write(
            "package.json",
            r#"{"dependencies":{"@lepton-desk/plugin-fs":"^0.1.3"}}"#,
        )?;
        scratch.write(
            "node_modules/@lepton-desk/plugin-fs/package.json",
            r#"{"lepton":{"plugin":"zig/plugin.zig","settings":"fs"}}"#,
        )?;
        scratch.write("node_modules/@lepton-desk/plugin-fs/zig/plugin.zig", "\n")?;
        scratch.write("src-lepton/build.zig", build)?;
        scratch.write("lepton.config.json", config)
    }

    fn core_step(scratch: &Scratch) -> Vec<lepton_orchestrator::Step> {
        vec![
            lepton_orchestrator::Step::new("lepton", "zig")
                .arg("build")
                .in_dir(scratch.path().join("src-lepton")),
        ]
    }

    #[test]
    fn plugin_settings_reach_the_core_as_lines() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-settings")?;
        fs_plugin(
            &scratch,
            r#""plugins" "plugin-config""#,
            r#"{"identifier":"style.notes","plugins":{"fs":{"scope":["$APPDATA","$DOCUMENT/notlar"]}}}"#,
        )?;
        let mut steps = core_step(&scratch);
        let plugins = assert_ok!(pass_to_core(&mut steps, scratch.path()), "passes");
        assert_eq!(plugins[0].settings.as_deref(), Some("fs"));
        let setting = steps[0]
            .args
            .iter()
            .find(|arg| arg.starts_with("-Dplugin-config="));
        assert_eq!(
            setting.map(String::as_str),
            Some(
                "-Dplugin-config=app.identifier=style.notes\nfs.scope=$APPDATA\nfs.scope=$DOCUMENT/notlar"
            )
        );
        Ok(())
    }

    #[test]
    fn a_settings_section_no_plugin_reads_is_an_error() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-settings-typo")?;
        fs_plugin(
            &scratch,
            r#""plugins" "plugin-config""#,
            r#"{"plugins":{"fss":{"scope":["$APPDATA"]}}}"#,
        )?;
        let error = assert_err!(
            pass_to_core(&mut core_step(&scratch), scratch.path()),
            "typo"
        );
        assert_contains!(
            &error.to_string(),
            "\"plugins.fss\" is read by no installed plugin"
        );
        assert_contains!(&error.to_string(), "fs");
        Ok(())
    }

    #[test]
    fn settings_need_a_build_file_that_takes_them() -> Result<(), Failure> {
        let scratch = Scratch::new("plugins-settings-old")?;
        fs_plugin(
            &scratch,
            r#""plugins""#,
            r#"{"plugins":{"fs":{"scope":["$APPDATA"]}}}"#,
        )?;
        let error = assert_err!(
            pass_to_core(&mut core_step(&scratch), scratch.path()),
            "old"
        );
        assert_contains!(&error.to_string(), "predates plugin settings");
        Ok(())
    }

    #[test]
    fn setting_values_are_strings_without_line_breaks() -> Result<(), Failure> {
        let fs = vec![super::Plugin {
            package: "@lepton-desk/plugin-fs".to_owned(),
            module: "lepton_desk_plugin_fs".to_owned(),
            root: std::path::PathBuf::from("/p/zig/plugin.zig"),
            settings: Some("fs".to_owned()),
        }];
        for (config, expected) in [
            (
                r#"{"plugins":{"fs":{"scope":[1]}}}"#,
                "must be a string or an array of strings",
            ),
            (r#"{"plugins":{"fs":{"scope":["a\nb"]}}}"#, "line break"),
            (
                r#"{"plugins":{"fs":{"Scope":"x"}}}"#,
                "a setting name is lowercase",
            ),
            (r#"{"plugins":["fs"]}"#, "must be an object"),
        ] {
            let value: serde_json::Value = assert_ok!(serde_json::from_str(config), "json");
            let error = assert_err!(settings_text(&value, &fs), "{}", config);
            assert_contains!(&error.to_string(), expected);
        }
        let single: serde_json::Value = assert_ok!(
            serde_json::from_str(r#"{"plugins":{"fs":{"mode":"strict"}}}"#),
            "json"
        );
        assert_eq!(
            assert_ok!(settings_text(&single, &fs), "single"),
            "fs.mode=strict"
        );
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
