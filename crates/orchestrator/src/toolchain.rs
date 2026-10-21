//! What the machine this CLI runs on can actually do.
//!
//! Lepton's developer experience depends on a Zig toolchain, a Node package
//! manager, and a display server. All three are facts about the machine, and all
//! three are discovered by running the real tool and reading what it says — never
//! by checking whether a file exists at a guessed path.
//!
//! The distinction matters more here than it looks. A `zig` binary at
//! `/usr/local/bin/zig` is not necessarily on `PATH`, and a `PATH` entry is not
//! necessarily a working compiler. Asking the tool for its version is the only
//! check that cannot pass on a machine where the tool is broken.

use std::fmt;
use std::process::Command;

use crate::process::describe_status;

/// A tool the CLI needs, and what the machine reported about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolStatus {
    /// The name the CLI refers to it by.
    pub name: &'static str,
    /// The executable that was actually invoked, when one was found.
    pub path: Option<String>,
    /// The version string the tool printed, trimmed of its banner.
    pub version: Option<String>,
    /// Why the tool could not be used, when it could not be.
    pub problem: Option<ToolProblem>,
}

impl Default for ToolStatus {
    /// A tool nobody has heard of yet. Used where a toolchain is being built up
    /// field by field rather than probed, as in tests.
    fn default() -> Self {
        Self {
            name: "unknown",
            path: None,
            version: None,
            problem: Some(ToolProblem::NotFound),
        }
    }
}

impl ToolStatus {
    /// True when the tool ran and reported a version.
    pub fn is_usable(&self) -> bool {
        self.version.is_some()
    }

    /// One line for a terminal: the tool, its version, or the reason it is out.
    pub fn describe(&self) -> String {
        match (&self.version, &self.problem) {
            (Some(version), _) => format!("{} {}", self.name, version),
            (None, Some(problem)) => format!("{} {}", self.name, problem),
            (None, None) => format!("{} not found", self.name),
        }
    }
}

/// Why a tool could not be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolProblem {
    /// Nothing on `PATH` goes by that name.
    NotFound,
    /// The tool exists but could not be run: wrong architecture, missing loader,
    /// or a permissions problem.
    NotExecutable,
    /// The tool ran and failed, which means it is broken rather than absent.
    Failed { status: String },
    /// The tool runs, but as a version Lepton does not build with (`zig.rs`).
    WrongVersion { found: String, needed: &'static str },
}

impl fmt::Display for ToolProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => write!(f, "not found on PATH"),
            Self::NotExecutable => write!(f, "found but could not be executed"),
            Self::Failed { status } => write!(f, "failed to run ({status})"),
            Self::WrongVersion { found, needed } => write!(
                f,
                "{found}; Lepton builds with Zig {needed}: put one on PATH as zig, zig-0.17 or zig-0.16 (Arch: zig0.16-bin), or set LEPTON_ZIG to it"
            ),
        }
    }
}

/// The tools Lepton needs, and what this machine reported about each.
///
/// Collected in one pass so `lepton info` does not have to re-run the same probe
/// for every line it prints, and so the answer to "can I build here?" is computed
/// once rather than per question.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Toolchain {
    pub zig: ToolStatus,
    pub node: ToolStatus,
    pub package_manager: ToolStatus,
    pub display: DisplayStatus,
}

impl Toolchain {
    /// Probes every tool the CLI depends on.
    pub fn detect() -> Self {
        // The package manager is pnpm when present, npm otherwise, because Lepton's
        // templates are developed with pnpm and a machine without it should still
        // work rather than be told it is unsupported.
        let package_manager = match probe("pnpm", &["--version"]) {
            status if status.is_usable() => status,
            _ => probe("npm", &["--version"]),
        };

        Self {
            zig: crate::zig::probe(),
            node: probe("node", &["--version"]),
            package_manager,
            // Unprobed, not headless: this layer cannot answer the question without
            // guessing, and a report that guesses wrong is worse than one that says
            // it did not look.
            // Windows has one desktop protocol, Win32, in every signed-in session: nothing
            // to probe and nothing to guess.
            display: if cfg!(windows) {
                DisplayStatus::win32()
            } else {
                DisplayStatus::unprobed()
            },
        }
    }

    /// Probes one program by name (`<name> --version`): the project's package manager,
    /// which may be another than the one [`detect`](Self::detect) found.
    pub fn probe_program(name: &'static str) -> ToolStatus {
        probe(name, &["--version"])
    }

    /// The tools a given command needs, and the first one that is missing.
    ///
    /// Reported as a single blocker rather than a list, because the thing a
    /// developer needs is the thing to fix, and three blockers where only the
    /// first matters is three times the work.
    ///
    /// The order of the returned list is the order a developer would install in,
    /// which is also the order the single blocker is chosen from: reporting "node
    /// is missing" when both node and pnpm are absent sends them to install node,
    /// fail again, and install pnpm.
    pub fn blocker(&self, needs: ToolRequirement) -> Option<&ToolProblem> {
        match needs {
            ToolRequirement::Build => first_unusable([&self.zig, &self.package_manager]),
            ToolRequirement::Develop => {
                first_unusable([&self.zig, &self.node, &self.package_manager])
            }
            ToolRequirement::Scaffold => first_unusable([&self.package_manager]),
        }
    }

    /// Every tool, in the order a developer would install them.
    pub fn all(&self) -> [&ToolStatus; 3] {
        [&self.zig, &self.node, &self.package_manager]
    }
}

/// The first tool in the list that cannot be used, and why.
///
/// Takes the list by value so the caller's array can be a temporary: borrowing a
/// slice of a temporary is a borrow that ends too early, and the alternative —
/// returning a slice — ties every caller's lifetime to this function's.
fn first_unusable<const N: usize>(tools: [&ToolStatus; N]) -> Option<&ToolProblem> {
    tools
        .into_iter()
        .find(|tool| !tool.is_usable())
        .and_then(|tool| tool.problem.as_ref())
}

/// Which set of tools a command needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolRequirement {
    /// Creating a new project: only a package manager is involved.
    Scaffold,
    /// Running a development loop: the core, Node and a package manager.
    Develop,
    /// Producing a release: the core and a package manager.
    Build,
}

/// Runs a tool and records what it said about itself.
fn probe(name: &'static str, args: &[&str]) -> ToolStatus {
    probe_at(name, name, args)
}

/// [`probe`] running `program`, which may be a path, for the tool called `name`.
pub(crate) fn probe_at(name: &'static str, program: &str, args: &[&str]) -> ToolStatus {
    let output = Command::new(crate::program::resolve(program))
        .args(args)
        .output();

    match output {
        Ok(output) => {
            // A tool that ran but failed is broken, not missing. The two are
            // reported differently because they are fixed differently.
            if !output.status.success() {
                return ToolStatus {
                    name,
                    path: None,
                    version: None,
                    problem: Some(ToolProblem::Failed {
                        status: format!("exit {}", describe_status(&output.status)),
                    }),
                };
            }

            let printed = String::from_utf8_lossy(&output.stdout);
            let version = printed
                .lines()
                .next()
                .map(str::trim)
                .filter(|line| !line.is_empty());

            ToolStatus {
                name,
                path: None,
                version: version.map(ToOwned::to_owned),
                problem: None,
            }
        }
        Err(error) => {
            // `NotFound` is the only error that means "install it"; everything else
            // means it is there and cannot be run, which is a different problem with
            // a different fix.
            let problem = if error.kind() == std::io::ErrorKind::NotFound {
                ToolProblem::NotFound
            } else {
                ToolProblem::NotExecutable
            };
            ToolStatus {
                name,
                path: None,
                version: None,
                problem: Some(problem),
            }
        }
    }
}

/// The display server this session has.
///
/// Filled in by the caller from the core's probe rather than probed here: the core
/// is the only thing that can answer this without guessing, because it speaks both
/// protocols. Shelling out to `xdpyinfo` or stat-ing a socket from the CLI would
/// mean two more ways to be wrong, and neither would survive a compositor that
/// changed its socket name.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DisplayStatus {
    /// `wayland`, `x11`, `win32`, or `none`.
    pub session: Option<String>,
    /// Screen width in pixels, when the server reported it.
    pub width: Option<u32>,
    /// Screen height in pixels.
    pub height: Option<u32>,
    /// Why no display could be found, when none was.
    pub problem: Option<ToolProblem>,
}

impl DisplayStatus {
    /// A machine with no display server, which is a legitimate state — a build
    /// machine, or a container.
    ///
    /// Distinct from `unprobed` because the two produce different sentences: this one
    /// has been established, and the report can say so.
    pub fn headless() -> Self {
        Self {
            session: None,
            width: None,
            height: None,
            problem: Some(ToolProblem::NotFound),
        }
    }

    /// A machine nobody has asked.
    ///
    /// The default for the CLI, which probes tools by running them but cannot probe a
    /// display without either shelling out to a second program or stat-ing a socket at
    /// a guessed path. Both are ways to be wrong, and being wrong here would print
    /// "opening a window does not work" on a machine where it obviously does.
    pub fn unprobed() -> Self {
        Self {
            session: None,
            width: None,
            height: None,
            problem: None,
        }
    }

    /// The Windows desktop: always Win32.
    pub fn win32() -> Self {
        Self {
            session: Some(String::from("win32")),
            width: None,
            height: None,
            problem: None,
        }
    }

    pub fn is_available(&self) -> bool {
        self.session.is_some()
    }

    /// Whether anyone has looked.
    ///
    /// A `None` session means two different things — nothing found, and nothing
    /// asked — and a caller that renders it must be able to tell which.
    pub fn is_probed(&self) -> bool {
        self.session.is_some() || self.problem.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::{DisplayStatus, ToolProblem, ToolRequirement, ToolStatus, Toolchain, probe};
    use crate::testing::Failure;
    use crate::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    /// A tool that is present and reports a version.
    fn usable(name: &'static str, version: &str) -> ToolStatus {
        ToolStatus {
            name,
            path: None,
            version: Some(version.to_owned()),
            problem: None,
        }
    }

    /// A tool that is missing.
    fn missing(name: &'static str) -> ToolStatus {
        ToolStatus {
            name,
            path: None,
            version: None,
            problem: Some(ToolProblem::NotFound),
        }
    }

    #[test]
    fn a_real_tool_reports_its_real_version() -> Result<(), Failure> {
        // `cargo` is what is running these tests, so asking it its version is a
        // question this machine can answer for certain.
        let status = probe("cargo", &["--version"]);

        ensure!(
            status.is_usable(),
            "cargo should be usable: {}",
            status.describe()
        );
        let version = status.version.unwrap_or_default();
        ensure!(
            version.starts_with("cargo "),
            "expected a cargo version, got {version:?}"
        );
        Ok(())
    }

    #[test]
    fn a_missing_tool_is_reported_as_missing_rather_than_broken() -> Result<(), Failure> {
        let status = probe("lepton-definitely-not-a-real-tool", &["--version"]);

        ensure!(!status.is_usable(), "a nonexistent tool cannot be usable");
        assert_eq!(status.problem, Some(ToolProblem::NotFound));
        assert_eq!(
            status.describe(),
            "lepton-definitely-not-a-real-tool not found on PATH"
        );
        Ok(())
    }

    #[test]
    fn a_broken_tool_is_reported_as_broken_rather_than_missing() -> Result<(), Failure> {
        // A tool that exists and rejects its arguments is broken, not absent, and
        // the difference decides whether the fix is "install it" or "repair it".
        let status = probe("cargo", &["--this-flag-does-not-exist"]);

        ensure!(!status.is_usable(), "a rejecting tool cannot be usable");
        ensure!(
            matches!(status.problem, Some(ToolProblem::Failed { .. })),
            "expected a failure, got {:?}",
            status.problem
        );
        Ok(())
    }

    #[test]
    fn a_toolchain_reports_only_the_first_missing_tool() -> Result<(), Failure> {
        let chain = Toolchain {
            zig: usable("zig", "0.16.0"),
            node: missing("node"),
            package_manager: missing("pnpm"),
            display: DisplayStatus::headless(),
        };

        // `Develop` needs all three, and `node` comes before the package manager,
        // so `node` is the one thing worth reporting first: fixing it alone would
        // not be enough, but it is where the list starts.
        assert_eq!(
            chain.blocker(ToolRequirement::Develop),
            Some(&ToolProblem::NotFound)
        );
        // `Build` skips Node but still needs the package manager, which is also
        // missing here — so the blocker is the same, for a different reason.
        assert_eq!(
            chain.blocker(ToolRequirement::Build),
            Some(&ToolProblem::NotFound)
        );
        assert_eq!(
            chain.blocker(ToolRequirement::Scaffold),
            Some(&ToolProblem::NotFound)
        );
        Ok(())
    }

    #[test]
    fn a_complete_toolchain_has_no_blocker() -> Result<(), Failure> {
        let chain = Toolchain {
            zig: usable("zig", "0.16.0"),
            node: usable("node", "v26.10.0"),
            package_manager: usable("pnpm", "12.5.1"),
            display: DisplayStatus {
                session: Some("wayland".to_owned()),
                width: Some(1920),
                height: Some(1080),
                problem: None,
            },
        };

        for requirement in [
            ToolRequirement::Scaffold,
            ToolRequirement::Develop,
            ToolRequirement::Build,
        ] {
            assert_eq!(chain.blocker(requirement), None::<&ToolProblem>);
        }
        ensure!(chain.display.is_available(), "a session was described");
        Ok(())
    }

    #[test]
    fn a_headless_machine_is_not_an_error() -> Result<(), Failure> {
        let headless = DisplayStatus::headless();

        ensure!(!headless.is_available(), "no session means no display");
        // A build machine has no display and that is fine; only opening a window
        // needs one.
        assert_eq!(headless.session, None::<String>);
        Ok(())
    }

    #[test]
    fn every_tool_describes_itself_in_one_line() -> Result<(), Failure> {
        assert_eq!(usable("zig", "0.16.0").describe(), "zig 0.16.0");
        assert_eq!(missing("zig").describe(), "zig not found on PATH");
        assert_eq!(Toolchain::default().all().len(), 3);
        Ok(())
    }

    #[test]
    fn a_failed_tool_names_the_exit_status_it_reported() -> Result<(), Failure> {
        let status = probe("cargo", &["--this-flag-does-not-exist"]);

        match status.problem {
            Some(ToolProblem::Failed { status }) => {
                assert_contains!(&status, "exit ");
            }
            other => {
                return Err(crate::testing::Failure {
                    claim: "a rejecting tool should report a failure".to_owned(),
                    actual: format!("{other:?}"),
                });
            }
        }
        Ok(())
    }

    #[test]
    fn a_result_is_unwrapped_by_the_helper_not_by_the_language() -> Result<(), Failure> {
        let value = assert_ok!(Ok::<&str, &str>("value"), "a string is fine");
        assert_eq!(value, "value");

        let error = assert_err!(Err::<&str, &str>("no"), "an err is an err");
        assert_eq!(error, "no");
        Ok(())
    }
}
