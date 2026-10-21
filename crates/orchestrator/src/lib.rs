//! Running the toolchain a Lepton project needs.
//!
//! The orchestrator is the only place in Lepton that starts another program. It
//! answers two questions and nothing else: what can this machine do, and how do
//! I run the tool that does it.
//!
//! It deliberately knows nothing about Vite, about templates, or about what a
//! project contains. Those belong to the crates above it. Keeping this crate to
//! process control is what lets the CLI stay a thin argument parser and lets the
//! build pipeline be tested without a frontend on disk.

#![forbid(unsafe_code)]

pub mod colour;
mod process;
/// The file a program name starts (`npm` is `npm.cmd` on Windows).
pub mod program;
pub mod supervise;
mod toolchain;

/// Assertions that report failure by returning it.
///
/// Shared across the workspace rather than duplicated per crate: one definition
/// means one rule about how a test reports a failure, and a second copy would be
/// free to drift into unwinding again.
pub mod testing;

/// Which Zig builds a project's core: Lepton builds with one release series.
pub mod zig;

pub use process::{
    Captured, OrchestratorError, Output, Result, Step, display, require, run, run_streaming,
};
pub use toolchain::{DisplayStatus, ToolProblem, ToolRequirement, ToolStatus, Toolchain};

/// The name the CLI introduces itself with.
pub const CLI_NAME: &str = "lepton";

/// The configuration file that marks a directory as a Lepton project.
///
/// The name is the contract: a project is a Lepton project because this file is
/// there, not because something else said so.
pub const CONFIG_FILE: &str = "lepton.config.json";

/// Whether `dir` holds a Lepton project.
///
/// Checked by the file's presence rather than by parsing it, because the question
/// here is "is this the right directory", not "is the configuration valid" — the
/// second is a different failure with a different message.
pub fn is_project(dir: &std::path::Path) -> bool {
    dir.join(CONFIG_FILE).is_file()
}

/// Confirms `dir` is a Lepton project, or explains that it is not.
///
/// The error names the file that is missing and the directory it was expected in,
/// because "not a Lepton project" on its own leaves the developer guessing which
/// of the two files in front of them is the one wanted.
pub fn require_project(dir: &std::path::Path) -> Result<()> {
    if is_project(dir) {
        Ok(())
    } else {
        Err(OrchestratorError::NotLeptonProject {
            path: dir.to_path_buf(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{CLI_NAME, CONFIG_FILE, OrchestratorError, is_project, require_project};
    use crate::testing::{Failure, Scratch};
    use crate::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    #[test]
    fn an_empty_directory_is_not_a_lepton_project() -> Result<(), Failure> {
        let dir = assert_ok!(
            Scratch::new("empty"),
            "the scratch directory should be creatable"
        );
        ensure!(
            !is_project(dir.path()),
            "an empty directory holds no config"
        );
        Ok(())
    }

    #[test]
    fn a_directory_with_the_config_file_is_a_project() -> Result<(), Failure> {
        let dir = assert_ok!(
            Scratch::new("config"),
            "the scratch directory should be creatable"
        );
        dir.write(CONFIG_FILE, "{}").map_err(|error| Failure {
            claim: "the config file should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        ensure!(is_project(dir.path()), "the config file marks the project");
        require_project(dir.path()).map_err(|error| Failure {
            claim: "the project should be accepted".to_owned(),
            actual: format!("{error:?}"),
        })
    }

    #[test]
    fn a_directory_lacking_the_config_is_rejected_by_name_and_path() -> Result<(), Failure> {
        let dir = assert_ok!(
            Scratch::new("missing"),
            "the scratch directory should be creatable"
        );
        let error = assert_err!(
            require_project(dir.path()),
            "an empty directory is not a project"
        );

        match &error {
            OrchestratorError::NotLeptonProject { path } => {
                assert_eq!(path, &dir.path());
                // The message is what a developer reads, so its substance is checked
                // here rather than trusted: it has to name the file they should add.
                assert_contains!(&error.to_string(), CONFIG_FILE);
            }
            other => {
                return Err(Failure {
                    claim: "a missing config should be reported as a missing project".to_owned(),
                    actual: format!("{other:?}"),
                });
            }
        }
        Ok(())
    }

    #[test]
    fn the_cli_name_is_the_one_the_project_uses() -> Result<(), Failure> {
        // The npm scope is `@lepton-desk`, so the command is `lepton`; a mismatch
        // would show up as a command nobody can type.
        assert_eq!(CLI_NAME, "lepton");
        Ok(())
    }

    #[test]
    fn requiring_a_project_is_idempotent() -> Result<(), Failure> {
        let dir = assert_ok!(
            Scratch::new("idempotent"),
            "the scratch directory should be creatable"
        );
        dir.write(CONFIG_FILE, "{}").map_err(|error| Failure {
            claim: "the config file should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        require_project(dir.path()).map_err(|error| Failure {
            claim: "the first check should pass".to_owned(),
            actual: format!("{error:?}"),
        })?;
        require_project(dir.path()).map_err(|error| Failure {
            claim: "the second check should pass".to_owned(),
            actual: format!("{error:?}"),
        })
    }
}
