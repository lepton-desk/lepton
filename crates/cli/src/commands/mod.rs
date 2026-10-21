//! The commands the CLI dispatches to.
//!
//! Each command is its own module-level type holding its flags and its behaviour,
//! so a command that grows is split rather than appended to. Nothing here does work
//! directly: `Info` asks the orchestrator what the machine can do, `New` asks the
//! template injector what to write, and `Build` and `Dev` ask the orchestrator to
//! run something. A command that reached past those boundaries would make the CLI
//! untestable without a machine.

pub mod arch;
pub mod archive;
pub mod build;
pub mod command_types;
pub mod deb;
pub mod deep_links;
pub mod depends;
pub mod desktop_entry;
pub mod dev;
pub mod dev_ready;
pub mod engine;
pub mod info;
pub mod installer;
pub mod installer_db;
pub mod installer_names;
pub mod installer_read;
pub mod installer_tables;
pub mod launch;
pub mod linked;
pub mod new;
pub mod new_setup;
pub mod new_view;
pub mod package;
pub mod package_manager;
pub mod plugins;
pub mod record;
pub mod report;
pub mod run;
pub mod servo;
pub mod session;
pub mod update;
pub mod update_packages;
pub mod verify;
#[cfg(unix)]
pub mod verify_linux;
#[cfg(windows)]
pub mod verify_windows;
pub mod window_shape;
pub mod zip;

use std::error::Error;
use std::fmt::Display;

/// What running a command produced.
///
/// `Result<(), CliError>` rather than `Box<dyn Error>`: the concrete error type is
/// what lets the top level print a useful chain, and a boxed error erases which
/// failure it was at the moment that matters.
pub type Outcome = Result<(), CliError>;

/// Anything a command can fail with.
#[derive(Debug)]
pub enum CliError {
    /// The machine cannot do what was asked.
    Toolchain(lepton_orchestrator::OrchestratorError),
    /// A template could not be produced or written.
    Injection(lepton_template_injector::InjectionError),
    /// The Zig core could not be put into a new project.
    Vendoring(lepton_core_vendoring::Error),
    /// The arguments describe a project that cannot exist.
    Invalid(String),
}

impl Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Toolchain(error) => write!(f, "{error}"),
            Self::Injection(error) => write!(f, "{error}"),
            Self::Vendoring(error) => write!(f, "the Zig core could not be written: {error}"),
            Self::Invalid(reason) => write!(f, "{reason}"),
        }
    }
}

impl std::error::Error for CliError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Toolchain(error) => Some(error),
            Self::Injection(error) => Some(error),
            Self::Vendoring(error) => Some(error),
            Self::Invalid(_) => None,
        }
    }
}

impl CliError {
    /// The error and everything that caused it, one per line.
    ///
    /// Written by hand rather than with `Error::sources`, which is still unstable:
    /// a developer's only view of a failure is this text, so the chain is walked here
    /// rather than behind an API that might not compile next month.
    ///
    /// The command's name is part of the first line. A developer who ran `lepton
    /// build` and saw an error did not need to be told which of four commands they
    /// used — but they do need it once the output is in a CI log among three others.
    pub fn report(&self, command: &str) -> String {
        // Collected as lines and joined at the end, because a cause's own `Display`
        // may contain newlines: appending to one string would make it impossible to
        // tell where one level ended and the next began.
        let mut lines = vec![format!("lepton {command}: {self}")];

        let mut current = self.source();
        while let Some(cause) = current {
            lines.push(format!("  caused by: {cause}"));
            current = cause.source();
        }

        lines.join("\n")
    }
}

impl From<lepton_orchestrator::OrchestratorError> for CliError {
    fn from(error: lepton_orchestrator::OrchestratorError) -> Self {
        Self::Toolchain(error)
    }
}

impl From<lepton_template_injector::InjectionError> for CliError {
    fn from(error: lepton_template_injector::InjectionError) -> Self {
        Self::Injection(error)
    }
}

impl From<lepton_core_vendoring::Error> for CliError {
    fn from(error: lepton_core_vendoring::Error) -> Self {
        Self::Vendoring(error)
    }
}

/// The command line as a tagged tree.
#[derive(Debug, clap::Subcommand)]
pub enum Command {
    /// Reports what this machine can build, and what is missing.
    Info(info::Flags),

    /// Creates a new project and wires Lepton into it.
    New(new::Flags),

    /// Produces a release build.
    Build(build::Flags),

    /// Runs the development loop.
    Dev(dev::Flags),

    /// Builds once and opens the application, reading its frontend from disk.
    Run(run::Flags),

    /// Builds a release and lays it out as an installable tree with a desktop entry.
    Package(package::Flags),

    /// Opens the application and records every command the page calls, to a file.
    Record(record::RecordFlags),

    /// Runs a recording against the core again, with no window, and compares the replies.
    Replay(record::ReplayFlags),

    /// Brings an existing project's core and `src-lepton/` files to this version.
    Update(update::Flags),
}

impl Command {
    /// The name this command is invoked by, for a usage message.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Info(_) => "info",
            Self::New(_) => "new",
            Self::Build(_) => "build",
            Self::Dev(_) => "dev",
            Self::Run(_) => "run",
            Self::Package(_) => "package",
            Self::Record(_) => "record",
            Self::Replay(_) => "replay",
            Self::Update(_) => "update",
        }
    }
}

/// `std::fs::canonicalize`, but `C:\…` rather than `\\?\C:\…` on Windows: the verbatim form
/// is what `canonicalize` returns there (measured), and it reaches `zig`/`pnpm` arguments and
/// printed plans. Only a plain drive path is unwrapped; a network or device path is kept.
pub fn resolve(path: &std::path::Path) -> std::io::Result<std::path::PathBuf> {
    let resolved = std::fs::canonicalize(path)?;
    if cfg!(windows)
        && let Some(rest) = resolved
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        && rest.as_bytes().get(1) == Some(&b':')
    {
        return Ok(std::path::PathBuf::from(rest));
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::{CliError, Command};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, ensure};
    use std::error::Error as _;

    #[test]
    fn every_error_names_itself_in_the_message() -> Result<(), Failure> {
        // The message is the whole report: a developer sees the error line and
        // nothing else, so a message that does not name the tool names nothing.
        let unavailable = CliError::from(lepton_orchestrator::OrchestratorError::ToolUnavailable {
            tool: "zig",
            problem: lepton_orchestrator::ToolProblem::NotFound,
        });
        assert_contains!(&unavailable.to_string(), "zig");
        assert_contains!(&unavailable.to_string(), "Install it");

        let invalid = CliError::Invalid("a project needs a name".to_owned());
        assert_eq!(invalid.to_string(), "a project needs a name");

        let escapes = CliError::from(lepton_template_injector::InjectionError::Escapes {
            path: "../elsewhere".to_owned(),
        });
        assert_contains!(&escapes.to_string(), "outside the project");
        Ok(())
    }

    #[test]
    fn a_wrapped_error_keeps_its_cause_for_the_chain() -> Result<(), Failure> {
        // The top level prints a cause chain, which only works if `source` is
        // implemented rather than defaulted.
        let wrapped = CliError::from(lepton_orchestrator::OrchestratorError::NotLeptonProject {
            path: std::path::PathBuf::from("/tmp/nowhere"),
        });

        let source = wrapped.source().ok_or(Failure {
            claim: "a wrapped error should keep its cause".to_owned(),
            actual: "None".to_owned(),
        })?;

        ensure!(
            source.to_string().contains("lepton.config.json"),
            "the cause should name the file"
        );
        Ok(())
    }

    #[test]
    fn the_report_prints_the_cause_chain_one_line_each() -> Result<(), Failure> {
        // The report is the whole output a developer sees for a failure, so the chain
        // has to appear: "not a Lepton project" alone does not say which directory.
        let wrapped = CliError::from(lepton_orchestrator::OrchestratorError::NotLeptonProject {
            path: std::path::PathBuf::from("/tmp/nowhere"),
        });

        let report = wrapped.report("build");

        assert_contains!(&report, "lepton build: ");
        assert_contains!(&report, "caused by: ");
        assert_contains!(&report, "/tmp/nowhere");
        // A leaf error has exactly one line per level: no blank, no trailing cause.
        assert_eq!(report.lines().count(), 2);
        Ok(())
    }

    #[test]
    fn a_leaf_error_reports_one_line_and_no_cause() -> Result<(), Failure> {
        let report = CliError::Invalid("a project needs a name".to_owned()).report("new");

        assert_eq!(report.lines().count(), 1);
        ensure!(
            !report.contains("caused by"),
            "a leaf error has no cause: {report}"
        );
        Ok(())
    }

    #[test]
    fn a_command_reports_the_name_it_is_invoked_by() -> Result<(), Failure> {
        // A usage message that names a command wrongly sends the developer looking
        // for a flag that does not exist.
        // Every subcommand's name comes from the enum variant, so checking the four
        // names against the parser is checking the mapping a usage message uses.
        use clap::Parser as _;

        /// The same subcommand slot the binary uses, so this test parses through the
        /// real wiring rather than a second description of it.
        #[derive(Debug, clap::Parser)]
        struct Probe {
            #[command(subcommand)]
            command: Command,
        }

        for name in ["info", "build", "dev"] {
            let parsed = Probe::try_parse_from(["lepton", name])
                .map(|probe| probe.command)
                .map_err(|error| Failure {
                    claim: format!("`lepton {name}` should parse"),
                    actual: format!("{error}"),
                })?;
            assert_eq!(parsed.name(), name);
        }

        // `new` needs a name, so it is parsed with one here; the flag surface itself
        // is checked in `main.rs`.
        let with_arg = Probe::try_parse_from(["lepton", "new", "Ledger"])
            .map(|probe| probe.command)
            .map_err(|error| Failure {
                claim: "`lepton new Ledger` should parse".to_owned(),
                actual: format!("{error}"),
            })?;
        assert_eq!(with_arg.name(), "new");
        Ok(())
    }
}
