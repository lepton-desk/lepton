//! `lepton update` — an existing project's core brought to this version.
//!
//! Only `lepton new` vendors the core and writes `src-lepton/`, so a fix made after a
//! project was created never reached it. This command replaces `src-lepton/vendor/
//! lepton-core` (the framework's alone) and brings `main.zig`, `build.zig` and
//! `lepton-commands.zig` up to today's template, keeping the developer's edits by a
//! three-way merge (`lepton_template_injector::update`).
//!
//! All or nothing: when a file conflicts, nothing is written but `<file>.merge` beside it,
//! with the markers, and the command fails — a new core under an old `main.zig` would not
//! build. A vendored core that is a symbolic link (a project inside this repository) is
//! already current and left alone.

use std::path::{Path, PathBuf};

use lepton_template_injector::update::{Decision, Part, Values, decide};

use super::build::CORE_DIR;
use super::report::{Report, shown};
use super::{CliError, Outcome};

/// Flags for `lepton update`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Flags {
    /// Says what would change and writes nothing.
    #[arg(long)]
    pub dry_run: bool,
}

/// What happens to the vendored core.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Vendor {
    Current,
    /// A symbolic link: whatever it points at is the core.
    Linked,
    /// `changed` files differ or are missing, `stale` are no longer part of the core.
    Replace {
        changed: usize,
        stale: usize,
    },
}

fn invalid(what: &str, path: &Path, error: impl std::fmt::Display) -> CliError {
    CliError::Invalid(format!("could not {what} {}: {error}", path.display()))
}

/// The template's values from `lepton.config.json`, as `lepton new` derived them.
fn values(root: &Path) -> Result<Values, CliError> {
    let path = root.join("lepton.config.json");
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!(
            "{} is not a Lepton project: {error}",
            root.display()
        ))
    })?;
    let config: serde_json::Value =
        serde_json::from_str(&text).map_err(|error| invalid("parse", &path, error))?;
    let text_at = |pointer: &str| {
        config
            .pointer(pointer)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    };
    let number_at = |pointer: &str, fallback: u32| {
        config
            .pointer(pointer)
            .and_then(serde_json::Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(fallback)
    };
    let product = text_at("/productName")
        .ok_or_else(|| CliError::Invalid(format!("{} has no productName", path.display())))?;
    let identifier = text_at("/identifier")
        .unwrap_or_else(|| lepton_template_injector::manifest::identifier_for(&product));
    Ok(Values {
        channel: text_at("/channel/name").unwrap_or_else(|| format!("/lepton-{identifier}")),
        title: text_at("/window/title").unwrap_or_else(|| product.clone()),
        width: number_at("/window/width", 1024),
        height: number_at("/window/height", 640),
        product,
        identifier,
    })
}

/// Every regular file under `dir`, relative to it.
fn walk(dir: &Path, base: &Path, out: &mut Vec<PathBuf>) -> Result<(), CliError> {
    let entries = std::fs::read_dir(dir).map_err(|error| invalid("read", dir, error))?;
    for entry in entries {
        let entry = entry.map_err(|error| invalid("read", dir, error))?;
        let path = entry.path();
        let kind = entry
            .file_type()
            .map_err(|error| invalid("read", &path, error))?;
        if kind.is_dir() {
            walk(&path, base, out)?;
        } else if let Ok(relative) = path.strip_prefix(base) {
            out.push(relative.to_path_buf());
        }
    }
    Ok(())
}

fn vendor_decision(vendor: &Path) -> Result<Vendor, CliError> {
    if std::fs::symlink_metadata(vendor).is_ok_and(|meta| meta.file_type().is_symlink()) {
        return Ok(Vendor::Linked);
    }
    let carried = lepton_core_vendoring::files();
    let changed = carried
        .iter()
        .filter(|(relative, contents)| {
            std::fs::read_to_string(vendor.join(relative))
                .ok()
                .as_deref()
                != Some(*contents)
        })
        .count();
    let mut present = Vec::new();
    if vendor.is_dir() {
        walk(vendor, vendor, &mut present)?;
    }
    let stale = present
        .iter()
        .filter(|path| {
            !carried
                .iter()
                .any(|(relative, _)| Path::new(relative) == *path)
        })
        .count();
    Ok(if changed == 0 && stale == 0 {
        Vendor::Current
    } else {
        Vendor::Replace { changed, stale }
    })
}

fn write(path: &Path, text: &str) -> Result<(), CliError> {
    std::fs::write(path, text).map_err(|error| invalid("write", path, error))
}

impl Flags {
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;
        self.run_in(&root)
    }

    pub fn run_in(&self, root: &Path) -> Outcome {
        let values = values(root)?;
        if !root.join(CORE_DIR).is_dir() {
            return Err(CliError::Invalid(format!(
                "{} has no {CORE_DIR}/ to update",
                root.display()
            )));
        }
        let report = Report::new();
        report.header("update");

        let mut decisions = Vec::new();
        for part in Part::ALL {
            let path = root.join(part.path());
            let existing = std::fs::read_to_string(&path).ok();
            decisions.push((part, path, decide(part, &values, existing.as_deref())));
        }
        let vendor_dir = root
            .join(CORE_DIR)
            .join(lepton_core_vendoring::VENDORED_CORE);
        let vendor = vendor_decision(&vendor_dir)?;

        for (part, _, decision) in &decisions {
            let label = match part {
                Part::Entry => "main.zig",
                Part::Build => "build.zig",
                Part::Commands => "command list",
            };
            match decision {
                Decision::Current => report.fact(label, "current"),
                Decision::Added(_) => report.fact(label, "added"),
                Decision::Replaced { from, .. } => {
                    report.fact(label, &format!("replaced (untouched since {from})"));
                }
                Decision::Merged { from, .. } => {
                    report.fact(label, &format!("merged: your changes kept (since {from})"));
                }
                Decision::Conflict { from, .. } => {
                    report.warn(
                        label,
                        &format!("conflicts with your changes (since {from})"),
                    );
                }
            }
        }
        match vendor {
            Vendor::Current => report.fact("core", "current"),
            Vendor::Linked => report.fact("core", "a link, left as it is"),
            Vendor::Replace { changed, stale } => report.fact(
                "core",
                &format!(
                    "replaced: {changed} file{} new or changed, {stale} removed",
                    if changed == 1 { "" } else { "s" }
                ),
            ),
        }

        let conflicts: Vec<_> = decisions
            .iter()
            .filter_map(|(_, path, decision)| match decision {
                Decision::Conflict { text, .. } => Some((path, text)),
                _ => None,
            })
            .collect();
        if !conflicts.is_empty() {
            let mut written = Vec::new();
            for (path, text) in &conflicts {
                let merge = path.with_extension("zig.merge");
                if !self.dry_run {
                    write(&merge, text)?;
                }
                written.push(shown(&merge));
            }
            return Err(CliError::Invalid(format!(
                "nothing was updated: your edits overlap the template's. {} {} the merge with \
                 markers (`ours` is yours, `theirs` the new template); resolve it into the file, \
                 delete the .merge and run `lepton update` again",
                written.join(", "),
                if written.len() == 1 { "holds" } else { "hold" }
            )));
        }

        let changes = decisions
            .iter()
            .any(|(_, _, decision)| *decision != Decision::Current)
            || matches!(vendor, Vendor::Replace { .. });
        if !changes {
            return Ok(());
        }
        if self.dry_run {
            report.fact("dry run", "nothing written");
            return Ok(());
        }
        for (_, path, decision) in &decisions {
            match decision {
                Decision::Added(text)
                | Decision::Replaced { text, .. }
                | Decision::Merged { text, .. } => write(path, text)?,
                Decision::Current | Decision::Conflict { .. } => {}
            }
        }
        if let Vendor::Replace { .. } = vendor {
            if vendor_dir.exists() {
                std::fs::remove_dir_all(&vendor_dir)
                    .map_err(|error| invalid("remove", &vendor_dir, error))?;
            }
            lepton_core_vendoring::write_into(&vendor_dir)?;
        }
        report.fact("next", "lepton build");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Flags, Vendor, vendor_decision};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, ensure};
    use lepton_template_injector::update::{Part, RELEASES, Values};

    const CONFIG: &str = r#"{"productName":"Ledger","identifier":"com.example.ledger",
        "channel":{"name":"/lepton-com.example.ledger"},
        "window":{"title":"Ledger","width":1024,"height":640}}"#;

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

    /// A project as 0.1.6's `lepton new` left it, with an old file in its core.
    fn old_project(tag: &str) -> Result<Scratch, Failure> {
        let scratch = Scratch::new(tag)?;
        scratch.write("lepton.config.json", CONFIG)?;
        let release = RELEASES
            .iter()
            .find(|release| release.version == "0.1.6")
            .ok_or_else(|| lepton_orchestrator::testing::fail("0.1.6", "missing"))?;
        let entry = lepton_template_injector::assets::fill(
            release.entry,
            &[
                ("{product}", "Ledger"),
                ("{channel}", "/lepton-com.example.ledger"),
                ("{title}", "Ledger"),
                ("{identifier}", "com.example.ledger"),
                ("{width}", "1024"),
                ("{height}", "640"),
            ],
        );
        scratch.write("src-lepton/main.zig", &entry)?;
        scratch.write("src-lepton/build.zig", release.build)?;
        scratch.write(
            "src-lepton/lepton-commands.zig",
            &Part::Commands.current(&values()),
        )?;
        scratch.write(
            "src-lepton/vendor/lepton-core/src/gone.zig",
            "// removed since",
        )?;
        Ok(scratch)
    }

    fn decided(vendor: &std::path::Path) -> Result<Vendor, Failure> {
        vendor_decision(vendor)
            .map_err(|error| lepton_orchestrator::testing::fail("a decision", error))
    }

    #[test]
    fn an_old_project_gets_todays_core_and_template() -> Result<(), Failure> {
        let scratch = old_project("update-old")?;
        let vendor = scratch.path().join("src-lepton/vendor/lepton-core");
        ensure!(
            matches!(decided(&vendor)?, Vendor::Replace { stale: 1, .. }),
            "the old core is replaced"
        );
        Flags { dry_run: false }
            .run_in(scratch.path())
            .map_err(|error| lepton_orchestrator::testing::fail("an update", error))?;
        assert_eq!(
            scratch.read("src-lepton/main.zig")?,
            Part::Entry.current(&values())
        );
        assert_eq!(decided(&vendor)?, Vendor::Current);
        ensure!(
            !scratch.exists("src-lepton/vendor/lepton-core/src/gone.zig"),
            "a file the core no longer has is gone"
        );
        Ok(())
    }

    #[test]
    fn a_conflict_writes_only_the_merge_file() -> Result<(), Failure> {
        let scratch = old_project("update-conflict")?;
        let entry = scratch.read("src-lepton/main.zig")?;
        let edited = entry.replacen(
            "while (!view.bridge.close_requested and !view.closed) {",
            "while (!view.bridge.close_requested and !view.closed and !quit) {",
            1,
        );
        scratch.write("src-lepton/main.zig", &edited)?;
        let outcome = Flags { dry_run: false }.run_in(scratch.path());
        let Err(error) = outcome else {
            return Err(lepton_orchestrator::testing::fail("a refusal", "success"));
        };
        assert_contains!(&error.to_string(), "main.zig.merge");
        assert_eq!(scratch.read("src-lepton/main.zig")?, edited);
        assert_contains!(&scratch.read("src-lepton/main.zig.merge")?, "<<<<<<< ours");
        ensure!(
            scratch.exists("src-lepton/vendor/lepton-core/src/gone.zig"),
            "the core is untouched when a file conflicts"
        );
        Ok(())
    }

    #[test]
    fn a_dry_run_writes_nothing() -> Result<(), Failure> {
        let scratch = old_project("update-dry")?;
        let before = scratch.read("src-lepton/main.zig")?;
        Flags { dry_run: true }
            .run_in(scratch.path())
            .map_err(|error| lepton_orchestrator::testing::fail("a dry run", error))?;
        assert_eq!(scratch.read("src-lepton/main.zig")?, before);
        Ok(())
    }
}
