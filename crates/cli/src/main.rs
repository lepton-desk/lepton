//! The Lepton command surface.
//!
//! Four commands, described as data. The derive API is used rather than the builder
//! one because a command surface this wide *is* a data structure: keeping the flags
//! in a struct and the parsing generated from it means a flag and the field holding
//! it cannot drift apart, which is the usual way a CLI rots.
//!
//! Every command returns a `Result` and every error is reported as text with a
//! non-zero exit. Nothing here unwinds: a tool that panics mid-build leaves a
//! developer with a backtrace and no idea which step failed.

mod commands;
mod style;

use std::process::ExitCode;

use clap::Parser as _;

use crate::commands::Command;

/// The exit code a usage error produces.
///
/// `clap`'s default for a usage error is 2, which is distinct from 1 for a command
/// that ran and failed. A script can therefore tell "you typed it wrong" from "it
/// did not work", which is the difference between fixing a flag and filing a bug.
pub const USAGE_EXIT_CODE: u8 = 2;

/// The command line, as a description of what Lepton can be asked to do.
#[derive(Debug, clap::Parser)]
#[command(
    name = lepton_orchestrator::CLI_NAME,
    version,
    about = "Build desktop applications with a Zig core and a web front end.",
    disable_help_subcommand = true
)]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

/// Runs the CLI and reports the exit code.
///
/// Returns `ExitCode` rather than calling `exit`, so the whole program is one
/// expression and nothing is torn down in an order nobody wrote down.
pub fn run() -> ExitCode {
    let cli = match Cli::try_parse_from(std::env::args()) {
        Ok(cli) => cli,
        Err(error) => return report_parse(&error),
    };

    // Read before the command is moved: the name is what the failure report leads
    // with, and a CI log line that does not say which command failed is a line
    // somebody has to guess about.
    let name = cli.command.name();
    // The tools `lepton` streams colour exactly when `lepton` does (`colour.rs`).
    lepton_orchestrator::colour::set_level(match style::depth() {
        style::Depth::None => 0,
        style::Depth::Basic => 1,
        style::Depth::Extended => 2,
        style::Depth::True => 3,
    });

    match dispatch(cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // The report is the whole output for a failure: every error type in this
            // workspace writes what went wrong and, where it knows one, what to do,
            // and the causes are chained under it.
            eprintln!("{}", error.report(name));
            ExitCode::FAILURE
        }
    }
}

/// Prints a parse failure and turns it into an exit code.
///
/// `--help` and `--version` arrive on this path too, rendered by clap as an error
/// carrying a success exit code. Distinguishing them keeps `lepton --help` from
/// reporting failure, which would break every script that probes the binary.
fn report_parse(error: &clap::Error) -> ExitCode {
    let _ = error.print();

    match error.kind() {
        clap::error::ErrorKind::DisplayHelp
        | clap::error::ErrorKind::DisplayVersion
        | clap::error::ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => ExitCode::SUCCESS,
        _ => ExitCode::from(USAGE_EXIT_CODE),
    }
}

/// The process entry point.
///
/// Written as a one-line delegation rather than as the body itself: everything that
/// can fail returns an error, so there is nothing for `main` to do but hand the exit
/// code to the operating system.
fn main() -> std::process::ExitCode {
    run()
}

/// Runs one parsed command.
fn dispatch(command: Command) -> commands::Outcome {
    match command {
        Command::Info(flags) => flags.run(),
        Command::New(flags) => flags.run(),
        Command::Build(flags) => flags.run(),
        Command::Dev(flags) => flags.run(),
        Command::Run(flags) => flags.run(),
        Command::Package(flags) => flags.run(),
        Command::Record(flags) => flags.run(),
        Command::Replay(flags) => flags.run(),
        Command::Update(flags) => flags.run(),
    }
}

#[cfg(test)]
mod tests {
    use super::{Cli, USAGE_EXIT_CODE, commands, dispatch, report_parse, run};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};
    use std::process::ExitCode;

    use clap::Parser as _;

    /// Parses an argument list the way the binary does, without exiting.
    fn parse(args: &[&str]) -> Result<Cli, clap::Error> {
        let mut full = vec!["lepton"];
        full.extend_from_slice(args);
        Cli::try_parse_from(full)
    }

    #[test]
    fn every_command_parses_from_its_documented_flags() -> Result<(), Failure> {
        // The flags here are the ones the project's own brief promises: `lepton
        // dev`, `lepton build --linux --servo`, `lepton build --native`, `lepton
        // info`. If one of these stops parsing, the promise is broken.
        for args in [
            vec!["info"],
            vec!["info", "--json"],
            vec!["dev"],
            vec!["dev", "--port", "5173"],
            vec!["build"],
            vec!["build", "--linux"],
            vec!["build", "--linux", "--servo"],
            vec!["build", "--native"],
            vec!["build", "--windows"],
            vec!["build", "--macos"],
            vec!["new", "Ledger"],
            vec!["new", "Ledger", "--template", "react"],
            vec![
                "new",
                "Ledger",
                "--template",
                "vanilla-ts",
                "--target",
                "native",
            ],
        ] {
            if let Err(error) = parse(&args) {
                return Err(Failure {
                    claim: format!("`lepton {}` should parse", args.join(" ")),
                    actual: format!("{error}"),
                });
            }
        }
        Ok(())
    }

    #[test]
    fn a_help_request_exits_successfully() -> Result<(), Failure> {
        // If `--help` took the failure path, every script that probes the binary
        // would conclude the tool is broken.
        let error = parse(&["--help"]).err().ok_or(Failure {
            claim: "--help should be renderable".to_owned(),
            actual: String::from("parsed successfully"),
        })?;

        ensure!(
            matches!(error.kind(), clap::error::ErrorKind::DisplayHelp),
            "--help should be a help request, got {:?}",
            error.kind()
        );
        assert_eq!(report_parse(&error), ExitCode::SUCCESS);
        Ok(())
    }

    #[test]
    fn a_version_request_exits_successfully() -> Result<(), Failure> {
        let error = parse(&["--version"]).err().ok_or(Failure {
            claim: "--version should be renderable".to_owned(),
            actual: String::from("parsed successfully"),
        })?;

        ensure!(
            matches!(error.kind(), clap::error::ErrorKind::DisplayVersion),
            "--version should be a version request, got {:?}",
            error.kind()
        );
        assert_eq!(report_parse(&error), ExitCode::SUCCESS);
        Ok(())
    }

    #[test]
    fn an_unknown_command_is_refused() -> Result<(), Failure> {
        ensure!(
            parse(&["fly"]).is_err(),
            "an unknown command must be refused"
        );
        Ok(())
    }

    #[test]
    fn a_missing_required_argument_is_refused() -> Result<(), Failure> {
        // `new` without a name is accepted — the wizard asks for one, and
        // `--non-interactive` refuses it when the command runs — but a flag without its
        // value is still a usage error.
        ensure!(parse(&["new"]).is_ok(), "`new` alone opens the wizard");
        ensure!(
            parse(&["new", "Notes", "--template"]).is_err(),
            "`--template` without a value must be refused"
        );
        Ok(())
    }

    #[test]
    fn a_usage_error_has_its_own_exit_code() -> Result<(), Failure> {
        // 2 for "you typed it wrong", 1 for "it did not work". A script that cannot
        // tell them apart has to guess which failure to retry.
        assert_eq!(USAGE_EXIT_CODE, 2);
        Ok(())
    }

    #[test]
    fn a_usage_error_is_not_a_success() -> Result<(), Failure> {
        // Checked separately from the exit code so a future edit that makes every
        // parse error "succeed" fails here rather than passing on the constant.
        let error = parse(&["nonsense"]).err().ok_or(Failure {
            claim: "an unknown command should not parse".to_owned(),
            actual: String::from("parsed successfully"),
        })?;

        ensure!(
            report_parse(&error) != ExitCode::SUCCESS,
            "a usage error must not report success"
        );
        Ok(())
    }

    #[test]
    fn the_entry_points_have_the_shapes_main_needs() {
        // Taken for its signature only: running either would parse the test
        // harness's own arguments and end the test binary.
        let _ = run as fn() -> ExitCode;
        let _ = dispatch as fn(commands::Command) -> commands::Outcome;
    }
}
