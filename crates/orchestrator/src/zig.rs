//! Which Zig builds a project's core.
//!
//! The core and every project's `build.zig` build with Zig 0.16 and 0.17: Zig's standard
//! library and build API change between releases, and the differences are kept in one
//! place each (`compat.zig`, `build_support.zig`'s `zig_017`, C headers translated by the
//! build since 0.17 has no `@cImport`). Any other series is refused rather than tried.
//!
//! So the Zig is chosen, not assumed: `LEPTON_ZIG` when set (and only it), otherwise the
//! first of `zig`, `zig-0.17` and `zig-0.16` (the names Arch's `zig0.17-bin` and
//! `zig0.16-bin` install) that reports a series Lepton builds with. Every step whose
//! program is `zig` runs the chosen one ([`program`]).

use std::sync::OnceLock;

use crate::toolchain::{ToolProblem, ToolStatus, probe_at};

/// The release series Lepton builds with.
pub const SERIES: [&str; 2] = ["0.16", "0.17"];

/// The series named in a message: "0.16 or 0.17".
pub const SERIES_TEXT: &str = "0.16 or 0.17";

/// Names tried on `PATH`, in order, when `LEPTON_ZIG` is not set.
pub const NAMES: [&str; 3] = ["zig", "zig-0.17", "zig-0.16"];

/// The environment variable that names the Zig to use, as a path or a name on `PATH`.
pub const OVERRIDE: &str = "LEPTON_ZIG";

/// The Zig this machine offers Lepton, with the program that was run as its `path`.
pub fn probe() -> ToolStatus {
    let explicit = std::env::var(OVERRIDE)
        .ok()
        .filter(|value| !value.trim().is_empty());
    choose(explicit.as_deref(), |program| {
        probe_at("zig", program, &["version"])
    })
}

/// The program to run for a step named `zig`: the chosen Zig, or `zig` when none fits,
/// so the step fails with the tool's own error rather than a different one. Probed once.
pub fn program() -> String {
    static CHOSEN: OnceLock<String> = OnceLock::new();
    CHOSEN
        .get_or_init(|| match probe() {
            ToolStatus {
                path: Some(path),
                problem: None,
                ..
            } => path,
            _ => String::from("zig"),
        })
        .clone()
}

/// Whether a printed version is of a series Lepton builds with (`0.16.1`, `0.17.0`).
pub fn fits(version: &str) -> bool {
    SERIES.iter().any(|series| {
        version
            .strip_prefix(series)
            .is_some_and(|rest| rest.starts_with('.'))
    })
}

/// The choice itself, with the running of each candidate passed in so it is tested.
pub fn choose(explicit: Option<&str>, run: impl Fn(&str) -> ToolStatus) -> ToolStatus {
    let candidates: Vec<&str> = match explicit {
        Some(program) => vec![program],
        None => NAMES.to_vec(),
    };
    let mut first: Option<ToolStatus> = None;
    let mut wrong: Option<String> = None;
    for program in candidates {
        let status = run(program);
        match status.version.as_deref() {
            Some(version) if fits(version) => {
                return ToolStatus {
                    path: Some(program.to_owned()),
                    ..status
                };
            }
            Some(version) if wrong.is_none() => {
                wrong = Some(format!("{version} ({program})"));
            }
            _ => {}
        }
        if first.is_none() {
            first = Some(status);
        }
    }
    match wrong {
        Some(found) => ToolStatus {
            name: "zig",
            path: None,
            version: None,
            problem: Some(ToolProblem::WrongVersion {
                found,
                needed: SERIES_TEXT,
            }),
        },
        None => first.unwrap_or(ToolStatus {
            name: "zig",
            ..ToolStatus::default()
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::{choose, fits};
    use crate::testing::Failure;
    use crate::toolchain::{ToolProblem, ToolStatus};
    use crate::{assert_contains, assert_eq, ensure};

    fn found(version: &str) -> ToolStatus {
        ToolStatus {
            name: "zig",
            path: None,
            version: Some(version.to_owned()),
            problem: None,
        }
    }

    fn absent() -> ToolStatus {
        ToolStatus {
            name: "zig",
            path: None,
            version: None,
            problem: Some(ToolProblem::NotFound),
        }
    }

    #[test]
    fn the_0_16_and_0_17_series_fit() -> Result<(), Failure> {
        ensure!(
            fits("0.16.0") && fits("0.16.1") && fits("0.17.0"),
            "0.16.x and 0.17.x fit"
        );
        ensure!(
            !fits("0.18.0") && !fits("0.160.0") && !fits("0.15.2") && !fits("0.170.1"),
            "others do not"
        );
        Ok(())
    }

    #[test]
    fn a_0_16_zig_on_path_is_used_as_it_is() -> Result<(), Failure> {
        let chosen = choose(None, |_| found("0.16.0"));
        assert_eq!(chosen.path.as_deref(), Some("zig"));
        ensure!(chosen.is_usable(), "usable");
        Ok(())
    }

    #[test]
    fn the_zig_on_path_is_used_whether_0_16_or_0_17() -> Result<(), Failure> {
        // Arch on 2026-10-20: `zig` is 0.17.0, `zig0.16-bin` installs `zig-0.16`.
        let chosen = choose(None, |program| match program {
            "zig" => found("0.17.0"),
            "zig-0.16" => found("0.16.0"),
            _ => absent(),
        });
        assert_eq!(chosen.path.as_deref(), Some("zig"));
        assert_eq!(chosen.version.as_deref(), Some("0.17.0"));
        Ok(())
    }

    #[test]
    fn after_another_series_a_side_by_side_one_is_found() -> Result<(), Failure> {
        let chosen = choose(None, |program| match program {
            "zig" => found("0.18.0"),
            "zig-0.16" => found("0.16.0"),
            _ => absent(),
        });
        assert_eq!(chosen.path.as_deref(), Some("zig-0.16"));
        Ok(())
    }

    #[test]
    fn only_another_series_is_refused_by_name_and_version() -> Result<(), Failure> {
        let chosen = choose(None, |program| match program {
            "zig" => found("0.18.0"),
            _ => absent(),
        });
        ensure!(!chosen.is_usable(), "a 0.18 Zig is not usable");
        let text = chosen.describe();
        assert_contains!(&text, "0.18.0 (zig)");
        assert_contains!(&text, "0.16 or 0.17");
        assert_contains!(&text, "LEPTON_ZIG");
        Ok(())
    }

    #[test]
    fn no_zig_at_all_is_reported_as_missing() -> Result<(), Failure> {
        let chosen = choose(None, |_| absent());
        assert_eq!(chosen.problem, Some(ToolProblem::NotFound));
        Ok(())
    }

    #[test]
    fn lepton_zig_is_the_only_one_tried_when_set() -> Result<(), Failure> {
        let chosen = choose(Some("/opt/zig0.16/zig"), |program| match program {
            "/opt/zig0.16/zig" => found("0.16.0"),
            _ => found("0.16.0"),
        });
        assert_eq!(chosen.path.as_deref(), Some("/opt/zig0.16/zig"));
        let wrong = choose(Some("/usr/bin/zig"), |_| found("0.18.0"));
        assert_contains!(&wrong.describe(), "0.18.0 (/usr/bin/zig)");
        Ok(())
    }
}
