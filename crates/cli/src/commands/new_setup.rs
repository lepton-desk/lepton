//! What `lepton new` does around the scaffold: which plugins and which package manager,
//! the one file a package manager needs before its first install, the install itself, and
//! the next steps spelled in that manager's own commands.

use std::path::Path;

use lepton_orchestrator::{Step, Toolchain};
use lepton_template_injector::plugin_catalog::{self, CATALOG};

use super::CliError;
use super::package_manager::PackageManager;

/// `--plugins os,fs`, checked against the catalog.
pub fn plugins_from_flag(list: Option<&str>) -> Result<Vec<&'static str>, CliError> {
    match list {
        Some(list) => plugin_catalog::parse_list(list).map_err(CliError::Invalid),
        None => Ok(Vec::new()),
    }
}

/// The wizard's plugin question: none chosen unless the developer picks some.
pub fn ask_plugins() -> Result<Vec<&'static str>, CliError> {
    let choices: Vec<String> = CATALOG
        .iter()
        .map(|plugin| format!("{:<10} {}", plugin.name, plugin.summary))
        .collect();
    let picked = inquire::MultiSelect::new("Plugins (space to choose, enter to go on)", choices)
        .prompt()
        .map_err(|failure| {
            CliError::Invalid(format!("could not read the plugin choice: {failure}"))
        })?;
    let names: Vec<&str> = picked
        .iter()
        .filter_map(|line| line.split_whitespace().next())
        .collect();
    plugin_catalog::parse_list(&names.join(",")).map_err(CliError::Invalid)
}

/// `--package-manager`, else the tool that started `lepton`, else pnpm when installed,
/// else npm. A new directory has no lockfile to ask.
pub fn choose_manager(flag: Option<&str>, chain: &Toolchain) -> Result<PackageManager, CliError> {
    if let Some(name) = flag {
        return PackageManager::from_name(name).ok_or_else(|| {
            CliError::Invalid(format!(
                "--package-manager `{name}`: choose npm, pnpm, yarn or bun"
            ))
        });
    }
    let agent = std::env::var("npm_config_user_agent").ok();
    let pnpm = chain.package_manager.is_usable() && chain.package_manager.name == "pnpm";
    Ok(super::package_manager::detect(Path::new("/nonexistent"), agent.as_deref(), pnpm).0)
}

/// Files a manager needs before its first install. Yarn 2+ installs without
/// `node_modules` by default (Plug'n'Play), but `lepton` finds plugins — and the core
/// compiles their Zig — from `node_modules/<package>`, so a Yarn project asks for it.
/// Yarn 1 does not read `.yarnrc.yml` and installs `node_modules` anyway.
pub fn prepare_for(root: &Path, manager: PackageManager) -> Result<(), CliError> {
    if manager == PackageManager::Yarn {
        let path = root.join(".yarnrc.yml");
        std::fs::write(&path, "nodeLinker: node-modules\n").map_err(|error| {
            CliError::Invalid(format!("could not write {}: {error}", path.display()))
        })?;
    }
    Ok(())
}

/// Runs the manager's install in the new project. Returns whether it ran.
pub fn install(root: &Path, manager: PackageManager) -> Result<bool, CliError> {
    if !Toolchain::probe_program(manager.program()).is_usable() {
        println!(
            "\n{} is not installed; skipping the install",
            manager.program()
        );
        return Ok(false);
    }
    println!("\ninstalling with {}", manager.install_command());
    let step = Step::new("new", manager.program())
        .arg("install")
        .in_dir(root.to_path_buf());
    lepton_orchestrator::run_streaming(&step).map_err(CliError::from)?;
    Ok(true)
}

/// What to type next, in the project's own manager.
pub fn next_steps(root: &Path, manager: PackageManager, installed: bool) {
    println!("\nnext: cd {}", root.display());
    if !installed {
        println!("      {}", manager.install_command());
    }
    println!("      {}", manager.run_command("lepton:dev"));
}

#[cfg(test)]
mod tests {
    use super::{choose_manager, plugins_from_flag, prepare_for};
    use crate::commands::package_manager::PackageManager;
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    #[test]
    fn a_named_manager_is_taken_and_an_unknown_one_refused() -> Result<(), Failure> {
        let chain = lepton_orchestrator::Toolchain::default();
        assert_eq!(
            assert_ok!(choose_manager(Some("bun"), &chain), "bun"),
            PackageManager::Bun
        );
        let error = assert_err!(choose_manager(Some("deno"), &chain), "deno");
        assert_contains!(&error.to_string(), "choose npm, pnpm, yarn or bun");
        Ok(())
    }

    #[test]
    fn a_yarn_project_asks_for_node_modules_and_others_get_nothing() -> Result<(), Failure> {
        let yarn = Scratch::new("new-yarn")?;
        assert_ok!(prepare_for(yarn.path(), PackageManager::Yarn), "yarn");
        let text = std::fs::read_to_string(yarn.path().join(".yarnrc.yml")).unwrap_or_default();
        assert_eq!(text, "nodeLinker: node-modules\n");
        let npm = Scratch::new("new-npm")?;
        assert_ok!(prepare_for(npm.path(), PackageManager::Npm), "npm");
        ensure!(
            !npm.path().join(".yarnrc.yml").exists(),
            "npm gets no yarnrc"
        );
        Ok(())
    }

    #[test]
    fn plugin_flags_are_checked() -> Result<(), Failure> {
        assert_eq!(
            assert_ok!(plugins_from_flag(Some("dialog,os")), "ok"),
            vec!["os", "dialog"]
        );
        assert_eq!(
            assert_ok!(plugins_from_flag(None), "none"),
            Vec::<&str>::new()
        );
        ensure!(plugins_from_flag(Some("nope")).is_err(), "unknown plugin");
        Ok(())
    }
}
