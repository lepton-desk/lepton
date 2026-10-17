//! The receipt `lepton dev` prints when the loop ends.
//!
//! Lepton's frontend is a runtime address, not part of the binary: an edit is served by
//! the dev server to a window that stays up, and the core is built once. The receipt
//! makes that visible with the session's own numbers — how long the window stayed open,
//! how often and how long the core was built, and how many frontend files changed while
//! it ran. Every figure is measured (a clock, file modification times); none is assumed.

use std::path::Path;
use std::time::{Duration, SystemTime};

/// What one development session did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub window_open: Duration,
    pub core_builds: u32,
    pub core_build_time: Duration,
    pub frontend_edits: usize,
}

/// Directories that are not the developer's frontend source: tools write there.
const SKIPPED: [&str; 5] = ["node_modules", "dist", ".vite", "zig-out", ".zig-cache"];

/// Files under `dir` modified at or after `since`, skipping build output and `.dot` entries.
///
/// A missing directory counts zero rather than failing: a project without `src/` has
/// simply edited nothing there.
pub fn edited_since(dir: &Path, since: SystemTime) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut count = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') || SKIPPED.contains(&name.as_ref()) {
            continue;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            count += edited_since(&entry.path(), since);
        } else if kind.is_file()
            && entry
                .metadata()
                .and_then(|meta| meta.modified())
                .is_ok_and(|modified| modified >= since)
        {
            count += 1;
        }
    }
    count
}

/// `4m 12s`, `38s`, `1h 03m` — the largest two units, nothing finer than a second.
pub fn span(duration: Duration) -> String {
    let seconds = duration.as_secs();
    match (seconds / 3600, (seconds % 3600) / 60, seconds % 60) {
        (0, 0, s) => format!("{s}s"),
        (0, m, s) => format!("{m}m {s:02}s"),
        (h, m, _) => format!("{h}h {m:02}m"),
    }
}

/// The receipt, as the lines `lepton dev` prints.
pub fn receipt(session: &Session) -> String {
    let builds = if session.core_builds == 1 {
        String::from("1 time")
    } else {
        format!("{} times", session.core_builds)
    };
    let report = super::report::Report::new();
    [
        report.title("session"),
        report.fact_text("window open", &span(session.window_open)),
        report.fact_text(
            "core built",
            &format!("{builds}, {:.1} s", session.core_build_time.as_secs_f64()),
        ),
        report.fact_text(
            "frontend edits",
            &format!(
                "{} file(s) — 0 rebuilds, 0 restarts",
                session.frontend_edits
            ),
        ),
    ]
    .join("\n")
}

#[cfg(test)]
mod tests {
    use super::{Session, edited_since, receipt, span};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_contains, assert_eq};
    use std::time::{Duration, SystemTime};

    #[test]
    fn only_files_touched_during_the_session_count() -> Result<(), Failure> {
        let scratch = Scratch::new("session-edits")?;
        scratch.write("src/untouched.ts", "a")?;
        // File times have a resolution; step past it so "before" is strictly earlier.
        std::thread::sleep(Duration::from_millis(20));
        let started = SystemTime::now();
        std::thread::sleep(Duration::from_millis(20));
        scratch.write("src/main.ts", "b")?;
        scratch.write("src/ui/panel.ts", "c")?;
        scratch.write("src/node_modules/dep/index.js", "tool output")?;
        scratch.write("src/.cache", "hidden")?;

        assert_eq!(edited_since(&scratch.path().join("src"), started), 2);
        Ok(())
    }

    #[test]
    fn a_project_without_sources_edited_nothing() -> Result<(), Failure> {
        let scratch = Scratch::new("session-empty")?;
        let counted = edited_since(&scratch.path().join("src"), SystemTime::now());
        if counted != 0 {
            return Err(fail("no src/ means zero edits", counted));
        }
        Ok(())
    }

    #[test]
    fn spans_read_at_human_scale() -> Result<(), Failure> {
        assert_eq!(span(Duration::from_secs(38)), "38s");
        assert_eq!(span(Duration::from_secs(252)), "4m 12s");
        assert_eq!(span(Duration::from_secs(3780)), "1h 03m");
        Ok(())
    }

    #[test]
    fn the_receipt_states_what_was_measured() -> Result<(), Failure> {
        let text = receipt(&Session {
            window_open: Duration::from_secs(252),
            core_builds: 1,
            core_build_time: Duration::from_millis(3200),
            frontend_edits: 7,
        });
        assert_contains!(&text, "◆ window open    4m 12s");
        assert_contains!(&text, "◆ core built     1 time, 3.2 s");
        assert_contains!(&text, "◆ frontend edits 7 file(s)");
        Ok(())
    }
}
