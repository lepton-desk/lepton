//! What `lepton update` writes into an existing project's `src-lepton/`.
//!
//! `lepton new` writes the core's files once; a fix to the template after that (the page
//! woken by `published()`, the window size from `lepton.config.json`, the coloured start-up
//! lines, the channel unlinked on SIGTERM) reached an existing project only by hand. The
//! framework's files there are `main.zig`, `build.zig` and `lepton-commands.zig`, and
//! `main.zig` is also the developer's: their commands, state and events live in it. So a
//! file is never just overwritten: it is compared with the template it was made from — the
//! released templates are kept in `assets/history/` — and
//!
//! * the same as today's template: nothing to do;
//! * the same as a released one: never edited, today's template replaces it;
//! * edited: a three-way merge of the release it is closest to (the ancestor), the file
//!   (the developer's changes) and today's template (the framework's); a clean merge keeps
//!   both, a conflict is handed back with markers and nothing is written.

use crate::assets::{COMMAND_TYPES, ZIG_BUILD, fill, zig_entry};

/// A released template set, as `lepton new` of that version wrote it.
pub struct Release {
    /// The last version that shipped these files.
    pub version: &'static str,
    /// `src-lepton/main.zig`, placeholders unfilled.
    pub entry: &'static str,
    /// `src-lepton/build.zig`.
    pub build: &'static str,
}

/// Oldest first. Add the outgoing version's files here at each release (`docs/yayin.md`);
/// a test fails while the version being built has no entry.
pub const RELEASES: &[Release] = &[
    Release {
        version: "0.1.3",
        entry: include_str!("../assets/history/0.1.3/main.zig"),
        build: include_str!("../assets/history/0.1.3/build.zig"),
    },
    Release {
        version: "0.1.4",
        entry: include_str!("../assets/history/0.1.4/main.zig"),
        build: include_str!("../assets/history/0.1.4/build.zig"),
    },
    // 0.1.5 shipped the same files.
    Release {
        version: "0.1.6",
        entry: include_str!("../assets/history/0.1.6/main.zig"),
        build: include_str!("../assets/history/0.1.6/build.zig"),
    },
];

/// What `lepton.config.json` gives the entry template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Values {
    pub product: String,
    pub channel: String,
    pub title: String,
    pub identifier: String,
    /// Only the releases before 0.1.7 wrote the size into `main.zig`.
    pub width: u32,
    pub height: u32,
}

impl Values {
    fn released_entry(&self, template: &str) -> String {
        let width = self.width.to_string();
        let height = self.height.to_string();
        fill(
            template,
            &[
                ("{product}", &self.product),
                ("{channel}", &self.channel),
                ("{title}", &self.title),
                ("{identifier}", &self.identifier),
                ("{width}", &width),
                ("{height}", &height),
            ],
        )
    }
}

/// One framework file under `src-lepton/`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Part {
    Entry,
    Build,
    Commands,
}

impl Part {
    pub const ALL: [Part; 3] = [Part::Entry, Part::Build, Part::Commands];

    /// The file, relative to the project.
    pub fn path(self) -> &'static str {
        match self {
            Self::Entry => "src-lepton/main.zig",
            Self::Build => "src-lepton/build.zig",
            Self::Commands => "src-lepton/lepton-commands.zig",
        }
    }

    /// Today's file for this project.
    pub fn current(self, values: &Values) -> String {
        match self {
            Self::Entry => zig_entry(
                &values.product,
                &values.channel,
                &values.title,
                &values.identifier,
            ),
            Self::Build => ZIG_BUILD.to_owned(),
            Self::Commands => COMMAND_TYPES.to_owned(),
        }
    }

    /// Each release's file for this project, oldest first.
    fn released(self, values: &Values) -> Vec<(&'static str, String)> {
        RELEASES
            .iter()
            .map(|release| {
                let text = match self {
                    Self::Entry => values.released_entry(release.entry),
                    Self::Build => release.build.to_owned(),
                    // Unchanged since it was added.
                    Self::Commands => COMMAND_TYPES.to_owned(),
                };
                (release.version, text)
            })
            .collect()
    }
}

/// What happens to one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Already today's template, or already carries every change of it.
    Current,
    /// Not there: today's template is written.
    Added(String),
    /// Untouched since `from`: replaced with today's template.
    Replaced { from: &'static str, text: String },
    /// Edited since `from`; the developer's changes and the framework's, together.
    Merged { from: &'static str, text: String },
    /// Edited where the framework changed too: the file with conflict markers
    /// (`<<<<<<< ours` is the developer's, `>>>>>>> theirs` today's template).
    Conflict { from: &'static str, text: String },
}

/// Lines that differ between `a` and `b`.
fn distance(a: &str, b: &str) -> usize {
    diffy::create_patch(a, b)
        .hunks()
        .iter()
        .flat_map(|hunk| hunk.lines())
        .filter(|line| !matches!(line, diffy::Line::Context(_)))
        .count()
}

/// Decides one file, from what the project has (`None`: missing).
pub fn decide(part: Part, values: &Values, existing: Option<&str>) -> Decision {
    let today = part.current(values);
    let Some(existing) = existing else {
        return Decision::Added(today);
    };
    if existing == today {
        return Decision::Current;
    }
    let released = part.released(values);
    // Newest first, so a file equal to two releases is named by the later one.
    if let Some((version, _)) = released.iter().rev().find(|(_, text)| text == existing) {
        return Decision::Replaced {
            from: version,
            text: today,
        };
    }
    // Only an `Entry` and a `Build` reach here with a choice of ancestor; the nearest one
    // leaves the fewest lines looking like the developer's own changes.
    let Some((from, ancestor)) = released
        .iter()
        .rev()
        .min_by_key(|(_, text)| distance(text, existing))
    else {
        return Decision::Current;
    };
    match diffy::merge(ancestor, existing, &today) {
        Ok(merged) if merged == existing => Decision::Current,
        Ok(text) => Decision::Merged { from, text },
        Err(text) => Decision::Conflict { from, text },
    }
}

#[cfg(test)]
mod tests {
    use super::{Decision, Part, RELEASES, Values, decide};
    use lepton_orchestrator::testing::{Failure, fail};
    use lepton_orchestrator::{assert_contains, assert_eq, ensure};

    fn values() -> Values {
        Values {
            product: "Ledger".to_owned(),
            channel: "/lepton-com.example.ledger".to_owned(),
            title: "Ledger".to_owned(),
            identifier: "com.example.ledger".to_owned(),
            width: 1024,
            height: 640,
        }
    }

    fn released_entry(version: &str) -> Result<String, Failure> {
        let release = RELEASES
            .iter()
            .find(|release| release.version == version)
            .ok_or_else(|| fail("a release", version))?;
        Ok(values().released_entry(release.entry))
    }

    #[test]
    fn the_version_being_built_is_kept_for_the_next_update() -> Result<(), Failure> {
        // At a release the outgoing template must be added, or the next version cannot
        // tell an untouched project of this one from an edited one.
        let built = env!("CARGO_PKG_VERSION");
        ensure!(
            RELEASES.iter().any(|release| release.version == built),
            "assets/history has no {built}"
        );
        Ok(())
    }

    #[test]
    fn todays_file_is_left_alone_and_a_missing_one_is_written() -> Result<(), Failure> {
        let today = Part::Entry.current(&values());
        assert_eq!(
            decide(Part::Entry, &values(), Some(&today)),
            Decision::Current
        );
        ensure!(
            matches!(decide(Part::Build, &values(), None), Decision::Added(_)),
            "a missing build.zig is written"
        );
        Ok(())
    }

    #[test]
    fn an_untouched_release_is_replaced_and_named() -> Result<(), Failure> {
        let old = released_entry("0.1.6")?;
        assert_eq!(
            decide(Part::Entry, &values(), Some(&old)),
            Decision::Replaced {
                from: "0.1.6",
                text: Part::Entry.current(&values())
            }
        );
        Ok(())
    }

    #[test]
    fn the_developers_command_survives_the_frameworks_changes() -> Result<(), Failure> {
        // A command added to a 0.1.6 project, the way the template's comment says to.
        let old = released_entry("0.1.6")?;
        let anchor = "        .{ .name = \"app.name\", .run = &appName },\n";
        ensure!(old.contains(anchor), "the 0.1.6 entry has no app.name line");
        let edited = old.replacen(
            anchor,
            &format!("{anchor}        .{{ .name = \"ledger.total\", .run = &total }},\n"),
            1,
        );
        let Decision::Merged { from, text } = decide(Part::Entry, &values(), Some(&edited)) else {
            return Err(fail("a clean merge", "another decision"));
        };
        assert_eq!(from, "0.1.6");
        assert_contains!(&text, "ledger.total");
        // And today's changes, which 0.1.6 did not have.
        assert_contains!(&text, "core.termination.catchSignals()");
        assert_contains!(&text, "view.bridge.published()");
        Ok(())
    }

    #[test]
    fn an_edit_where_the_framework_changed_is_a_conflict_not_a_guess() -> Result<(), Failure> {
        let old = released_entry("0.1.6")?;
        // The loop condition is exactly what today's template changed.
        let loop_line = "    while (!view.bridge.close_requested and !view.closed) {\n";
        ensure!(old.contains(loop_line), "the 0.1.6 entry has no loop line");
        let edited = old.replacen(
            loop_line,
            "    while (!view.bridge.close_requested and !view.closed and !quit) {\n",
            1,
        );
        let Decision::Conflict { text, .. } = decide(Part::Entry, &values(), Some(&edited)) else {
            return Err(fail("a conflict", "another decision"));
        };
        assert_contains!(&text, "<<<<<<< ours");
        assert_contains!(&text, "!quit");
        assert_contains!(&text, "core.termination.requested()");
        Ok(())
    }
}
