//! Which package manager a project uses: npm, pnpm, Yarn or Bun.
//!
//! Decided per project, never per machine: a project with a `yarn.lock` is a Yarn
//! project on a machine that also has pnpm, and running pnpm there would ignore the lock
//! and install different versions. The order is the order of how deliberately it was
//! chosen:
//!
//! 1. `package.json` → `"packageManager": "yarn@4.5.0"` (Corepack's field);
//! 2. the lockfile in the project root;
//! 3. the tool that started `lepton` — `npm run`, `pnpm`, `yarn`, `bun run` and their
//!    `create` commands all set `npm_config_user_agent` (`pnpm/12.10.1 npm/? node/…`);
//! 4. pnpm when it is installed, npm otherwise (npm ships with Node).
//!
//! The managers also differ in how a script receives extra arguments: npm needs `--`
//! before them; pnpm passes a literal `--` on to the script (measured: Vite then ignored
//! `--port` and `--strict-port`), and Yarn and Bun forward without one.

use std::path::Path;

use lepton_orchestrator::Toolchain;
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackageManager {
    Npm,
    Pnpm,
    Yarn,
    Bun,
}

/// Why this manager was chosen, for the message when it is not installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    Field(String),
    Lockfile(&'static str),
    Invoked,
    Default,
}

impl PackageManager {
    pub const ALL: [Self; 4] = [Self::Npm, Self::Pnpm, Self::Yarn, Self::Bun];

    pub fn program(self) -> &'static str {
        match self {
            Self::Npm => "npm",
            Self::Pnpm => "pnpm",
            Self::Yarn => "yarn",
            Self::Bun => "bun",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|manager| manager.program() == name)
    }

    /// `pnpm/12.10.1 npm/? node/v26.11.1 linux x64` → pnpm.
    pub fn from_user_agent(agent: &str) -> Option<Self> {
        let first = agent.split_whitespace().next()?;
        Self::from_name(first.split('/').next()?)
    }

    /// The lockfile each manager writes, newest format first.
    fn lockfiles(self) -> &'static [&'static str] {
        match self {
            Self::Npm => &["package-lock.json"],
            Self::Pnpm => &["pnpm-lock.yaml"],
            Self::Yarn => &["yarn.lock"],
            Self::Bun => &["bun.lock", "bun.lockb"],
        }
    }

    /// `run <script>` with `extra` arguments reaching the script itself.
    pub fn run_script(self, script: &str, extra: &[String]) -> Vec<String> {
        let mut args = vec!["run".to_owned(), script.to_owned()];
        if self == Self::Npm && !extra.is_empty() {
            args.push("--".to_owned());
        }
        args.extend(extra.iter().cloned());
        args
    }

    /// The flag that runs the manager as if started in another directory.
    pub fn directory_flag(self) -> &'static str {
        match self {
            Self::Npm => "--prefix",
            Self::Pnpm => "--dir",
            Self::Yarn | Self::Bun => "--cwd",
        }
    }

    /// The command a developer types to install dependencies.
    pub fn install_command(self) -> &'static str {
        match self {
            Self::Npm => "npm install",
            Self::Pnpm => "pnpm install",
            Self::Yarn => "yarn",
            Self::Bun => "bun install",
        }
    }

    /// The command that runs `lepton <words>` through the project's `"lepton"` script.
    ///
    /// npm passes plain words on but takes every flag for its own and stops at one it
    /// does not know (measured, npm 12.2: `npm run lepton build --release` → "Unknown cli
    /// flag"), so with a flag npm gets `--` first; pnpm, Yarn and Bun pass everything.
    pub fn lepton_command(self, words: &[&str]) -> String {
        let joined = words.join(" ");
        match self {
            Self::Npm if words.iter().any(|word| word.starts_with('-')) => {
                format!("npm run lepton -- {joined}")
            }
            Self::Npm => format!("npm run lepton {joined}"),
            other => format!("{} lepton {joined}", other.program()),
        }
    }
}

/// The project's manager and why, from its own files and how `lepton` was started.
pub fn detect(
    root: &Path,
    user_agent: Option<&str>,
    pnpm_installed: bool,
) -> (PackageManager, Reason) {
    if let Ok(text) = std::fs::read_to_string(root.join("package.json"))
        && let Ok(json) = serde_json::from_str::<Value>(&text)
        && let Some(field) = json.get("packageManager").and_then(Value::as_str)
        && let Some(manager) = field.split('@').next().and_then(PackageManager::from_name)
    {
        return (manager, Reason::Field(field.to_owned()));
    }
    for manager in PackageManager::ALL {
        for lockfile in manager.lockfiles() {
            if root.join(lockfile).is_file() {
                return (manager, Reason::Lockfile(lockfile));
            }
        }
    }
    if let Some(manager) = user_agent.and_then(PackageManager::from_user_agent) {
        return (manager, Reason::Invoked);
    }
    let fallback = if pnpm_installed {
        PackageManager::Pnpm
    } else {
        PackageManager::Npm
    };
    (fallback, Reason::Default)
}

/// [`detect`] for this process: its environment and the probed toolchain.
pub fn for_project(root: &Path, chain: &Toolchain) -> PackageManager {
    let agent = std::env::var("npm_config_user_agent").ok();
    let pnpm = chain.package_manager.is_usable() && chain.package_manager.name == "pnpm";
    detect(root, agent.as_deref(), pnpm).0
}

/// Fails with a message naming the reason when the project's manager is not installed,
/// rather than letting a step fail with "program not found".
pub fn ensure_installed(root: &Path, chain: &Toolchain) -> Result<PackageManager, super::CliError> {
    let agent = std::env::var("npm_config_user_agent").ok();
    let pnpm = chain.package_manager.is_usable() && chain.package_manager.name == "pnpm";
    let (manager, reason) = detect(root, agent.as_deref(), pnpm);
    if Toolchain::probe_program(manager.program()).is_usable() {
        return Ok(manager);
    }
    let why = match reason {
        Reason::Field(field) => format!("package.json says \"packageManager\": \"{field}\""),
        Reason::Lockfile(lockfile) => format!("the project has {lockfile}"),
        Reason::Invoked => "lepton was started through it".to_owned(),
        Reason::Default => "it is the default".to_owned(),
    };
    Err(super::CliError::Invalid(format!(
        "this project uses {} ({why}), but `{}` is not installed",
        manager.program(),
        manager.program()
    )))
}

#[cfg(test)]
mod tests {
    use super::{PackageManager, Reason, detect};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_eq, ensure};

    #[test]
    fn the_field_wins_over_the_lockfile_and_the_lockfile_over_the_caller() -> Result<(), Failure> {
        let scratch = Scratch::new("pm-order")?;
        scratch.write("package.json", r#"{"name":"a"}"#)?;
        assert_eq!(
            detect(scratch.path(), None, true),
            (PackageManager::Pnpm, Reason::Default)
        );
        assert_eq!(
            detect(scratch.path(), None, false),
            (PackageManager::Npm, Reason::Default)
        );
        assert_eq!(
            detect(
                scratch.path(),
                Some("yarn/1.22.22 npm/? node/v26.11.1 linux x64"),
                true
            ),
            (PackageManager::Yarn, Reason::Invoked)
        );
        scratch.write("bun.lock", "{}")?;
        assert_eq!(
            detect(scratch.path(), Some("yarn/1.22.22 npm/? node/v26"), true),
            (PackageManager::Bun, Reason::Lockfile("bun.lock"))
        );
        scratch.write("package.json", r#"{"packageManager":"npm@12.2.0"}"#)?;
        assert_eq!(
            detect(scratch.path(), None, true),
            (PackageManager::Npm, Reason::Field("npm@12.2.0".to_owned()))
        );
        Ok(())
    }

    #[test]
    fn every_lockfile_names_its_manager() -> Result<(), Failure> {
        for (file, manager) in [
            ("package-lock.json", PackageManager::Npm),
            ("pnpm-lock.yaml", PackageManager::Pnpm),
            ("yarn.lock", PackageManager::Yarn),
            ("bun.lockb", PackageManager::Bun),
        ] {
            let scratch = Scratch::new("pm-lock")?;
            scratch.write(file, "")?;
            assert_eq!(detect(scratch.path(), None, true).0, manager);
        }
        Ok(())
    }

    #[test]
    fn only_npm_puts_a_separator_before_script_arguments() -> Result<(), Failure> {
        let extra = vec!["--port".to_owned(), "5199".to_owned()];
        assert_eq!(
            PackageManager::Npm.run_script("dev", &extra),
            ["run", "dev", "--", "--port", "5199"]
        );
        for manager in [
            PackageManager::Pnpm,
            PackageManager::Yarn,
            PackageManager::Bun,
        ] {
            assert_eq!(
                manager.run_script("dev", &extra),
                ["run", "dev", "--port", "5199"]
            );
        }
        assert_eq!(
            PackageManager::Npm.run_script("build", &[]),
            ["run", "build"]
        );
        Ok(())
    }

    #[test]
    fn user_agents_and_commands() -> Result<(), Failure> {
        assert_eq!(
            PackageManager::from_user_agent("bun/1.4.4 npm/? node/v24"),
            Some(PackageManager::Bun)
        );
        assert_eq!(
            PackageManager::from_user_agent("npm/12.2.0 node/v26"),
            Some(PackageManager::Npm)
        );
        ensure!(
            PackageManager::from_user_agent("deno/2").is_none(),
            "unknown"
        );
        ensure!(PackageManager::from_user_agent("").is_none(), "empty");
        assert_eq!(
            PackageManager::Yarn.lepton_command(&["dev"]),
            "yarn lepton dev"
        );
        assert_eq!(
            PackageManager::Pnpm.lepton_command(&["build", "--release"]),
            "pnpm lepton build --release"
        );
        assert_eq!(
            PackageManager::Npm.lepton_command(&["dev"]),
            "npm run lepton dev"
        );
        assert_eq!(
            PackageManager::Npm.lepton_command(&["build", "--release"]),
            "npm run lepton -- build --release"
        );
        assert_eq!(PackageManager::Bun.install_command(), "bun install");
        Ok(())
    }
}
