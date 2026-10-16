//! The plugins `lepton new` can add to a project, with the commands each one registers.
//!
//! A new project that chooses a plugin gets the npm dependency, every one of its commands
//! under `permissions`, and — for `fs` — a scope of the application's own `$APPDATA`. The
//! command lists must be the plugins' own; a test reads `packages/plugin-*/src/index.ts`
//! and fails when they drift.

/// One plugin `lepton new` knows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Plugin {
    /// What a developer types: `--plugins os,fs`.
    pub name: &'static str,
    pub package: &'static str,
    /// Shown in the wizard.
    pub summary: &'static str,
    pub commands: &'static [&'static str],
}

pub const CATALOG: [Plugin; 4] = [
    Plugin {
        name: "os",
        package: "@lepton-desk/plugin-os",
        summary: "platform, architecture, kernel version, host name, locale",
        commands: &[
            "os.platform",
            "os.arch",
            "os.family",
            "os.version",
            "os.hostname",
            "os.locale",
            "os.exe_extension",
        ],
    },
    Plugin {
        name: "clipboard",
        package: "@lepton-desk/plugin-clipboard",
        summary: "read and write the system clipboard as text",
        commands: &["clipboard.read_text", "clipboard.write_text"],
    },
    Plugin {
        name: "fs",
        package: "@lepton-desk/plugin-fs",
        summary: "files inside allowed directories (starts with $APPDATA)",
        commands: &[
            "fs.read_file",
            "fs.write_file",
            "fs.read_dir",
            "fs.mkdir",
            "fs.remove",
            "fs.stat",
            "fs.exists",
            "fs.rename",
        ],
    },
    Plugin {
        name: "dialog",
        package: "@lepton-desk/plugin-dialog",
        summary: "the desktop's own open and save dialogs",
        commands: &["dialog.open", "dialog.save"],
    },
];

pub fn find(name: &str) -> Option<&'static Plugin> {
    CATALOG.iter().find(|plugin| plugin.name == name)
}

/// `os,fs` → the plugins, in catalog order, each once; an unknown name is an error naming
/// the choices.
pub fn parse_list(list: &str) -> Result<Vec<&'static str>, String> {
    let mut chosen = Vec::new();
    for word in list
        .split(',')
        .map(str::trim)
        .filter(|word| !word.is_empty())
    {
        let plugin = find(word).ok_or_else(|| {
            format!(
                "no plugin named `{word}`; choose from {}",
                CATALOG.map(|plugin| plugin.name).join(", ")
            )
        })?;
        if !chosen.contains(&plugin.name) {
            chosen.push(plugin.name);
        }
    }
    chosen.sort_by_key(|name| CATALOG.iter().position(|plugin| plugin.name == *name));
    Ok(chosen)
}

#[cfg(test)]
mod tests {
    use super::{CATALOG, parse_list};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn the_catalog_matches_each_plugins_own_command_list() -> Result<(), Failure> {
        let packages = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packages");
        for plugin in CATALOG {
            let folder = plugin.package.trim_start_matches("@lepton-desk/");
            let source = std::fs::read_to_string(packages.join(folder).join("src/index.ts"))
                .map_err(|error| Failure {
                    claim: format!("{folder}/src/index.ts should be readable"),
                    actual: error.to_string(),
                })?;
            let start = source
                .find("export const commands = [")
                .ok_or_else(|| Failure {
                    claim: format!("{folder} exports a command list"),
                    actual: "none".to_owned(),
                })?;
            let list = &source[start..];
            let list = &list[..list.find(']').unwrap_or(list.len())];
            let names: Vec<&str> = list.split('"').skip(1).step_by(2).collect();
            assert_eq!(names, plugin.commands.to_vec());
            let manifest = std::fs::read_to_string(packages.join(folder).join("package.json"))
                .unwrap_or_default();
            assert_contains!(&manifest, &format!("\"name\": \"{}\"", plugin.package));
        }
        Ok(())
    }

    #[test]
    fn lists_are_parsed_in_catalog_order_once() -> Result<(), Failure> {
        assert_eq!(
            assert_ok!(parse_list("fs, os,fs"), "parses"),
            vec!["os", "fs"]
        );
        assert_eq!(assert_ok!(parse_list(""), "empty"), Vec::<&str>::new());
        let error = assert_err!(parse_list("os,shell"), "unknown");
        assert_contains!(&error, "no plugin named `shell`");
        Ok(())
    }
}
