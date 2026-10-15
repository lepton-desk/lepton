//! `lepton info` — what this machine can build, and what is missing.
//!
//! The command answers one question honestly: if you ran `lepton build` here, what
//! would happen? Every line it prints is a fact read from the machine, and a fact
//! that could not be read is reported as absent rather than left blank.
//!
//! This is also the command a bug report starts with, so its output is meant to be
//! pasted whole. That is why the format is a stable, greppable list rather than a
//! table that reflows to fit the terminal.
//!
//! The report is rendered into a `String` and returned rather than printed as it is
//! produced, so the exact text a developer sees can be asserted on in a test without
//! capturing the test harness's own output.

use lepton_orchestrator::{DisplayStatus, ToolProblem, ToolRequirement, ToolStatus, Toolchain};

use super::Outcome;

/// Flags for `lepton info`.
#[derive(Debug, Clone, Copy, Default, clap::Args)]
pub struct Flags {
    /// Prints the same facts as JSON, for a script or an issue template.
    #[arg(long)]
    pub json: bool,
}

impl Flags {
    /// Reports the machine's capabilities.
    pub fn run(self) -> Outcome {
        let chain = Toolchain::detect();

        let report = if self.json {
            render_json(&chain)
        } else {
            render_text(&chain)
        };
        print!("{report}");

        Ok(())
    }
}

/// The readiness rows, in the order a developer works down them.
///
/// One table rather than three literals so the text report and the JSON report can
/// never disagree about which commands exist or what they are called.
const READINESS: [(ToolRequirement, &str); 3] = [
    (ToolRequirement::Scaffold, "lepton new"),
    (ToolRequirement::Build, "lepton build"),
    (ToolRequirement::Develop, "lepton dev"),
];

/// The report, as a person reads it.
fn render_text(chain: &Toolchain) -> String {
    let mut out = String::with_capacity(1024);

    out.push_str("lepton\n");
    out.push_str("  toolchain\n");
    for tool in chain.all() {
        out.push_str(&format!("    {:<8} {}\n", tool.name, tool_status(tool)));
    }

    out.push_str("  display\n");
    out.push_str(&format!(
        "    {:<8} {}\n",
        "session",
        match &chain.display.session {
            Some(session) => session.clone(),
            // Two different sentences for one `None`, because they mean opposite
            // things: a display server was looked for and is not there, versus nobody
            // looked. Printing the first for the second would tell a developer on a
            // working desktop that windows cannot open.
            None if !chain.display.is_probed() => {
                String::from("not probed — the core is the only layer that can answer this")
            }
            None => String::from("none found — building works, opening a window does not"),
        }
    ));
    if let (Some(width), Some(height)) = (chain.display.width, chain.display.height) {
        out.push_str(&format!("    {:<8} {width}x{height}\n", "screen"));
    }

    out.push_str(&engine_section());

    out.push_str("  readiness\n");
    for (requirement, label) in READINESS {
        match chain.blocker(requirement) {
            // Ready. Printed as the bare word, because a line saying "ready" on
            // every row of a green report is noise the reader has to look past.
            None => out.push_str(&format!("    {label:<13} ready\n")),
            Some(problem) => out.push_str(&format!(
                "    {label:<13} blocked — {}\n",
                blocker_phrase(requirement, problem)
            )),
        }
    }

    out
}

/// The libraries a render path needs, and what a build on this machine would get.
///
/// Probed rather than remembered, because the whole point of this report is to tell a
/// developer whether a build will work before they run one. Each row names a package
/// the build genuinely requires and nothing else: a row for a library no build reads
/// would be a row that cannot change the answer.
const ENGINE_PACKAGES: [(&str, &str); 4] = [
    ("wpe-webkit-2.0", "web engine (WPE WebKit)"),
    ("wpebackend-fdo-1.0", "platform backend"),
    ("cairo", "type rasterisation"),
    ("xcb", "X11 windows"),
];

/// The engine section, as a person reads it.
fn engine_section() -> String {
    let mut out = String::from("  engine\n");

    let mut missing = 0usize;
    for (package, label) in ENGINE_PACKAGES {
        if pkg_config_exists(package) {
            out.push_str(&format!("    {label:<24} present\n"));
        } else {
            missing += 1;
            out.push_str(&format!("    {label:<24} missing — {package}\n"));
        }
    }

    // The consequence, in one sentence, because the rows above are facts and a
    // developer needs the reading of them. `-Drender=native` is named as the way
    // through, since a missing engine does not block a native build.
    if missing > 0 {
        out.push_str(&format!(
            "    {:<24} {missing} missing; build with --native\n",
            "consequence"
        ));
    } else {
        out.push_str(&format!("    {:<24} webview builds here\n", "consequence"));
    }

    out
}

/// Whether `pkg-config` can find `package`.
///
/// Runs the real query rather than looking for a file. A `.pc` present on disk can
/// name an include directory that was removed, and a header directory present can hold
/// headers a removed library no longer exports; only the query answers the question the
/// build will actually ask.
fn pkg_config_exists(package: &str) -> bool {
    std::process::Command::new("pkg-config")
        .arg("--exists")
        .arg(package)
        .status()
        .is_ok_and(|status| status.success())
}

/// What is stopping one command, in words that name the fix.
///
/// The tool's own line above already says which tool is missing; repeating the tool
/// name here would make the two lines drift apart the first time a requirement
/// changes. This says what has to happen.
fn blocker_phrase(requirement: ToolRequirement, problem: &ToolProblem) -> String {
    match requirement {
        ToolRequirement::Scaffold => match problem {
            ToolProblem::Failed { status } => format!("the package manager is broken ({status})"),
            _ => String::from("install a package manager (pnpm, or npm)"),
        },
        // Zig is first in both requirements, so "install Zig" is the honest answer
        // for a build failure; the package manager is named too because a broken
        // pnpm after a good Zig is the failure this line most often describes.
        ToolRequirement::Build => match problem {
            ToolProblem::Failed { status } => format!("the first build tool failed ({status})"),
            _ => String::from("install Zig and a package manager"),
        },
        ToolRequirement::Develop => match problem {
            ToolProblem::Failed { status } => format!("a development tool failed ({status})"),
            _ => String::from("install Zig, Node and a package manager"),
        },
    }
}

/// How one tool's status reads on its own line.
fn tool_status(tool: &ToolStatus) -> String {
    match (&tool.version, &tool.problem) {
        (Some(version), _) => version.clone(),
        (None, Some(problem)) => problem.to_string(),
        (None, None) => format!("{} not found", tool.name),
    }
}

/// The report, as a machine reads it.
fn render_json(chain: &Toolchain) -> String {
    let mut out = String::with_capacity(1024);
    out.push_str("{\n  \"tools\": [\n");

    let rendered: Vec<String> = chain
        .all()
        .iter()
        .map(|tool| {
            format!(
                "    {{\"name\": {}, \"version\": {}, \"problem\": {}}}",
                quote(tool.name),
                match &tool.version {
                    Some(version) => quote(version),
                    None => String::from("null"),
                },
                match &tool.problem {
                    Some(problem) => quote(&problem.to_string()),
                    None => String::from("null"),
                },
            )
        })
        .collect();
    out.push_str(&rendered.join(",\n"));
    out.push_str("\n  ],\n");

    out.push_str(&format!(
        "  \"display\": {},\n",
        display_json(&chain.display)
    ));

    // The same four packages the text report rows come from, read once and rendered
    // both ways, so the two reports cannot disagree about whether a build will work.
    let engine: Vec<String> = ENGINE_PACKAGES
        .iter()
        .map(|(package, label)| {
            format!(
                "    {{\"label\": {}, \"package\": {}, \"present\": {}}}",
                quote(label),
                quote(package),
                pkg_config_exists(package),
            )
        })
        .collect();
    out.push_str(&format!("  \"engine\": [\n{}\n  ],\n", engine.join(",\n")));

    out.push_str("  \"ready\": {\n");
    let rows: Vec<String> = READINESS
        .iter()
        .map(|(requirement, label)| {
            format!(
                "    {}: {}",
                quote(label.strip_prefix("lepton ").unwrap_or(label)),
                chain.blocker(*requirement).is_none()
            )
        })
        .collect();
    out.push_str(&rows.join(",\n"));
    out.push_str("\n  }\n}\n");

    out
}

/// The display section, which carries a problem when there is no server at all.
fn display_json(display: &DisplayStatus) -> String {
    // Deliberately left unclosed: the fields below are appended one at a time, and
    // closing the object here would put the rest of them outside it.
    let mut out = format!(
        "{{\"session\": {}",
        match &display.session {
            Some(session) => quote(session),
            None => String::from("null"),
        }
    );

    for (key, value) in [("width", display.width), ("height", display.height)] {
        out.push_str(&format!(
            ", \"{key}\": {}",
            match value {
                Some(value) => value.to_string(),
                None => String::from("null"),
            }
        ));
    }
    out.push_str(&format!(
        ", \"problem\": {}",
        match &display.problem {
            Some(problem) => quote(&problem.to_string()),
            None => String::from("null"),
        }
    ));
    out.push('}');
    out
}

/// A JSON string literal.
///
/// Handed to the injector rather than reimplemented: escaping a value is exactly
/// the kind of thing two implementations disagree about, and the one place the
/// escaping already exists is the one that writes a project's configuration file.
fn quote(value: &str) -> String {
    lepton_template_injector::manifest::json_string(value)
}

#[cfg(test)]
mod tests {
    use super::{
        ENGINE_PACKAGES, Flags, engine_section, pkg_config_exists, quote, render_json, render_text,
        tool_status,
    };
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{
        DisplayStatus, ToolProblem, ToolStatus, Toolchain, assert_contains, assert_eq, assert_ok,
        ensure,
    };

    /// A toolchain with everything present, built rather than probed.
    ///
    /// The assertions below are about the report's shape, not about this machine, so
    /// they must not depend on what happens to be installed here.
    fn complete() -> Toolchain {
        Toolchain {
            zig: usable("zig", "0.16.0"),
            node: usable("node", "v26.10.0"),
            package_manager: usable("pnpm", "12.5.1"),
            display: DisplayStatus {
                session: Some(String::from("wayland")),
                width: Some(1366),
                height: Some(768),
                problem: None,
            },
        }
    }

    /// A tool that ran and reported a version.
    fn usable(name: &'static str, version: &str) -> ToolStatus {
        ToolStatus {
            name,
            path: None,
            version: Some(version.to_owned()),
            problem: None,
        }
    }

    #[test]
    fn the_text_report_lists_every_tool_with_its_real_version() -> Result<(), Failure> {
        let report = render_text(&complete());

        for tool in ["zig", "node", "pnpm"] {
            ensure!(report.contains(tool), "{tool} should appear in:\n{report}");
        }
        assert_contains!(&report, "0.16.0");
        assert_contains!(&report, "v26.10.0");
        assert_contains!(&report, "12.5.1");
        Ok(())
    }

    #[test]
    fn a_complete_machine_is_ready_for_every_command() -> Result<(), Failure> {
        let report = render_text(&complete());

        for command in ["lepton new", "lepton build", "lepton dev"] {
            ensure!(report.contains(command), "{command} should be reported");
        }
        // No row may say blocked on a machine that has everything; if one did, the
        // report would train the reader to distrust the whole thing.
        assert_absent_text(&report, "blocked")?;
        Ok(())
    }

    #[test]
    fn a_missing_tool_names_the_fix_on_the_blocked_row() -> Result<(), Failure> {
        let mut chain = complete();
        chain.node.version = None;
        chain.node.problem = Some(ToolProblem::NotFound);

        let report = render_text(&chain);

        // `build` does not need Node, so a machine without it still builds. Saying
        // otherwise would send someone to install something they do not need.
        assert_contains!(&report, "not found on PATH");
        ensure!(
            report.contains("lepton dev"),
            "the dev row should be present:\n{report}"
        );
        ensure!(
            report.contains("install Zig, Node and a package manager"),
            "the dev row should name the fix:\n{report}"
        );

        // Counted rather than merely searched for, because "lepton dev" also
        // appears nowhere else and a row that reported both states would pass a
        // containment check.
        let blocked = report
            .lines()
            .filter(|line| line.contains("blocked"))
            .count();
        assert_eq!(blocked, 1);
        Ok(())
    }

    #[test]
    fn a_broken_tool_is_distinguished_from_an_absent_one() -> Result<(), Failure> {
        // "Not found" means install it. "Failed to run" means the install is wrong,
        // and telling someone to reinstall a package that is already there wastes
        // an afternoon.
        let mut chain = complete();
        chain.zig.version = None;
        chain.zig.problem = Some(ToolProblem::Failed {
            status: String::from("exit 1"),
        });

        let report = render_text(&chain);

        assert_contains!(&report, "failed to run");
        assert_absent_text(&report, "install Zig and a package manager")?;
        Ok(())
    }

    #[test]
    fn an_unprobed_display_is_not_reported_as_a_missing_one() -> Result<(), Failure> {
        // The failure this guards is the tool lying: "opening a window does not work"
        // printed on a machine where it does, because nobody had looked yet.
        let mut chain = complete();
        chain.display = DisplayStatus::unprobed();

        let report = render_text(&chain);

        assert_contains!(&report, "not probed");
        assert_absent_text(&report, "opening a window does not")?;
        Ok(())
    }

    #[test]
    fn a_headless_machine_is_reported_without_pretending_otherwise() -> Result<(), Failure> {
        // A build machine is a legitimate place to be. The report says a window
        // cannot open rather than implying something is wrong with the machine.
        let mut chain = complete();
        chain.display = DisplayStatus::headless();

        let report = render_text(&chain);

        assert_contains!(&report, "none found");
        assert_contains!(&report, "building works, opening a window does not");
        // The screen line is dropped rather than printed as zeroes.
        assert_absent_text(&report, "screen")?;
        Ok(())
    }

    #[test]
    fn a_screen_size_is_reported_when_the_server_knows_it() -> Result<(), Failure> {
        let report = render_text(&complete());

        assert_contains!(&report, "1366x768");
        assert_contains!(&report, "wayland");
        Ok(())
    }

    #[test]
    fn the_json_report_is_balanced_and_carries_readiness() -> Result<(), Failure> {
        let json = render_json(&complete());

        // Braces balance and the braces inside string literals are counted too, so
        // this also catches an escaping bug that emits a raw quote.
        lepton_orchestrator::testing::balanced(&json, '{', '}')?;
        assert_contains!(&json, "\"ready\"");
        assert_contains!(&json, "\"new\": true");
        assert_contains!(&json, "\"build\": true");
        assert_contains!(&json, "\"dev\": true");
        Ok(())
    }

    #[test]
    fn the_json_report_marks_a_missing_tool_with_nulls() -> Result<(), Failure> {
        let mut chain = complete();
        chain.zig.version = None;
        chain.zig.problem = Some(ToolProblem::NotFound);

        let json = render_json(&chain);

        // `null` rather than an empty string: a consumer branching on the value must
        // not have to guess whether the tool reported "" or the CLI ran out of facts.
        assert_contains!(&json, "\"version\": null");
        assert_contains!(&json, "\"build\": false");
        assert_contains!(&json, "\"dev\": false");
        assert_contains!(&json, "\"new\": true");
        Ok(())
    }

    #[test]
    fn a_tool_status_reads_as_a_version_or_a_reason() -> Result<(), Failure> {
        assert_eq!(tool_status(&usable("zig", "0.16.0")), "0.16.0");

        let absent = ToolStatus {
            name: "zig",
            path: None,
            version: None,
            problem: Some(ToolProblem::NotFound),
        };
        assert_eq!(tool_status(&absent), "not found on PATH");

        // A tool with neither a version nor a stated problem is a contradiction, but
        // it is rendered as absence rather than as a blank the reader has to guess at.
        let silent = ToolStatus {
            name: "zig",
            path: None,
            version: None,
            problem: None,
        };
        assert_eq!(tool_status(&silent), "zig not found");
        Ok(())
    }

    #[test]
    fn the_engine_section_names_a_package_that_is_genuinely_absent() -> Result<(), Failure> {
        // A package no build reads, so its absence is a fact about this machine rather
        // than about the report: the assertion is that a missing library is *named*
        // with the thing to install, not merely counted.
        assert!(!pkg_config_exists("lepton-nonexistent-package"));
        Ok(())
    }

    #[test]
    fn both_reports_agree_on_which_packages_are_present() -> Result<(), Failure> {
        // The text and JSON reports read the same table, and this is what would catch a
        // future edit that added a row to one and not the other.
        for (package, label) in ENGINE_PACKAGES {
            let probe = quote(package);
            let expected = if pkg_config_exists(package) {
                "true"
            } else {
                "false"
            };

            // The text report names what the package is for; the JSON report names the
            // package, because a machine reading it needs the identifier to install.
            let text = engine_section();
            if !text.contains(label) {
                return Err(Failure {
                    claim: "the text report should name every library it probes".to_owned(),
                    actual: text,
                });
            }

            let json = render_json(&Toolchain::detect());
            let wanted = format!("\"package\": {probe}, \"present\": {expected}");
            if !json.contains(&wanted) {
                return Err(Failure {
                    claim: "the JSON report should carry the same verdict as the text one"
                        .to_owned(),
                    actual: json,
                });
            }
        }
        Ok(())
    }

    #[test]
    fn running_info_writes_a_report_and_succeeds() -> Result<(), Failure> {
        // The command itself, run for real on this machine: it must not fail even
        // when a tool is absent, because reporting that absence is its job.
        assert_ok!(Flags::default().run(), "info should succeed on any machine");
        assert_ok!(
            Flags { json: true }.run(),
            "the JSON form should succeed too"
        );
        Ok(())
    }

    #[test]
    fn a_scratch_directory_is_available_for_a_future_report() -> Result<(), Failure> {
        // Not a report test: a guard that the isolation helper stays reachable, so a
        // later test cannot silently lose its directory.
        let scratch = assert_ok!(
            Scratch::new("info"),
            "the scratch directory should be creatable"
        );
        ensure!(
            scratch.path().is_dir(),
            "the scratch directory should exist"
        );
        Ok(())
    }

    /// The inverse of `assert_contains!`, wrapped so a failure prints the report.
    fn assert_absent_text(report: &str, needle: &str) -> Result<(), Failure> {
        if report.contains(needle) {
            return Err(Failure {
                claim: format!("the report should not contain {needle:?}"),
                actual: report.to_owned(),
            });
        }
        Ok(())
    }
}
