//! Keeps `src/lepton-commands.d.ts` in step with the application's commands.
//!
//! The core build generates the file from `main.zig`'s own command list and installs it
//! as `src-lepton/zig-out/lepton-commands.d.ts`. After every core build `lepton build`,
//! `run` and `dev` copy it into `src/`, where the page's TypeScript sees it: a command
//! added in Zig becomes a name `invoke` accepts, a removed one a type error.
//!
//! The copy never replaces a file it did not write: an existing `src/lepton-commands.d.ts`
//! must start with the generator's header, or it is left alone and the developer is told.

use std::path::Path;

use super::CliError;

/// Where the page's code finds the names.
pub const TARGET: &str = "src/lepton-commands.d.ts";
/// What the core build installs.
pub const GENERATED: &str = "zig-out/lepton-commands.d.ts";
/// The first line the generator writes; the mark of a file this command may replace.
pub const HEADER: &str = "// Generated from this application's commands (`main.zig`)";

/// What [`sync`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Synced {
    /// The core build produced no file (an older project, or a cross build).
    NothingGenerated,
    /// `src/` already had the same text.
    Unchanged,
    /// Written or replaced.
    Written,
    /// A file without the generator's header is there; left as it was.
    Foreign,
}

/// Copies the generated declarations from `core_dir` into the project at `root`.
pub fn sync(root: &Path, core_dir: &Path) -> Result<Synced, CliError> {
    let generated = core_dir.join(GENERATED);
    let Ok(text) = std::fs::read_to_string(&generated) else {
        return Ok(Synced::NothingGenerated);
    };
    let target = root.join(TARGET);
    match std::fs::read_to_string(&target) {
        Ok(existing) if existing == text => return Ok(Synced::Unchanged),
        Ok(existing) if !existing.starts_with(HEADER) => return Ok(Synced::Foreign),
        _ => {}
    }
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).map_err(|error| {
            CliError::Invalid(format!("could not create {}: {error}", dir.display()))
        })?;
    }
    std::fs::write(&target, text).map_err(|error| {
        CliError::Invalid(format!("could not write {}: {error}", target.display()))
    })?;
    Ok(Synced::Written)
}

/// Puts `zig build commands` — the core build's own step with its flags, asked only for
/// the declarations — at the front of `steps`, so the frontend's type check sees the
/// commands `main.zig` registers on the very first build. Measured without it: a new
/// project whose page called `app.name` failed `vue-tsc` with TS2345 on its first
/// `lepton run`, because the file was written only by the core build that came after.
///
/// Only for a project whose core has the generator (`lepton-commands.zig`); call before
/// `name_core`/`grant_permissions` so the step gets the same `-D` options as the build.
pub fn types_first(steps: &mut Vec<lepton_orchestrator::Step>, root: &Path) {
    if !root
        .join(super::build::CORE_DIR)
        .join("lepton-commands.zig")
        .is_file()
    {
        return;
    }
    let Some(core) = steps
        .iter()
        .find(|step| super::launch::is_core_build(step))
        .cloned()
    else {
        return;
    };
    let mut types = core;
    types.args.insert(1, String::from("commands"));
    steps.insert(0, types);
}

/// [`sync`], reporting what a developer needs to know and never failing the build over it.
pub fn sync_and_report(root: &Path) {
    let core_dir = root.join(super::build::CORE_DIR);
    match sync(root, &core_dir) {
        Ok(Synced::Written) => println!("commands     {TARGET} updated"),
        Ok(Synced::Foreign) => println!(
            "commands     {TARGET} was not written by lepton; left as is (delete it to regenerate)"
        ),
        Ok(Synced::NothingGenerated | Synced::Unchanged) => {}
        Err(error) => println!("commands     {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::{GENERATED, HEADER, Synced, TARGET, sync, types_first};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_eq, assert_ok};

    fn generated(text: &str) -> String {
        format!("{HEADER} by its core build.\n{text}")
    }

    #[test]
    fn a_new_list_is_written_then_left_alone_until_it_changes() -> Result<(), Failure> {
        let scratch = Scratch::new("command-types")?;
        let core = scratch.path().join("src-lepton");
        scratch.write(
            &format!("src-lepton/{GENERATED}"),
            &generated("\"app.name\": true;\n"),
        )?;

        assert_eq!(
            assert_ok!(sync(scratch.path(), &core), "first"),
            Synced::Written
        );
        assert_eq!(scratch.read(TARGET)?, generated("\"app.name\": true;\n"));
        assert_eq!(
            assert_ok!(sync(scratch.path(), &core), "again"),
            Synced::Unchanged
        );

        scratch.write(
            &format!("src-lepton/{GENERATED}"),
            &generated("\"notes.save\": true;\n"),
        )?;
        assert_eq!(
            assert_ok!(sync(scratch.path(), &core), "changed"),
            Synced::Written
        );
        assert_eq!(scratch.read(TARGET)?, generated("\"notes.save\": true;\n"));
        Ok(())
    }

    #[test]
    fn the_declarations_step_comes_first_and_copies_the_core_builds_flags() -> Result<(), Failure> {
        let scratch = Scratch::new("command-types-first")?;
        scratch.write("src-lepton/lepton-commands.zig", "// generator\n")?;
        let core_dir = scratch.path().join(super::super::build::CORE_DIR);
        let mut steps = vec![
            lepton_orchestrator::Step::new("lepton", "pnpm")
                .args(["run", "build"])
                .in_dir(scratch.path().to_path_buf()),
            lepton_orchestrator::Step::new("lepton", "zig")
                .args(["build", "--release=safe", "-Doptimize=ReleaseSmall"])
                .in_dir(core_dir),
        ];
        types_first(&mut steps, scratch.path());
        assert_eq!(steps.len(), 3);
        assert_eq!(
            steps[0].args,
            vec![
                "build",
                "commands",
                "--release=safe",
                "-Doptimize=ReleaseSmall"
            ]
        );
        assert_eq!(steps[1].args, vec!["run", "build"]);
        Ok(())
    }

    #[test]
    fn an_older_core_without_the_generator_gets_no_step() -> Result<(), Failure> {
        let scratch = Scratch::new("command-types-old")?;
        let mut steps = vec![
            lepton_orchestrator::Step::new("lepton", "zig")
                .arg("build")
                .in_dir(scratch.path().join(super::super::build::CORE_DIR)),
        ];
        types_first(&mut steps, scratch.path());
        assert_eq!(steps.len(), 1);
        Ok(())
    }

    #[test]
    fn a_hand_written_file_is_never_replaced() -> Result<(), Failure> {
        let scratch = Scratch::new("command-types-foreign")?;
        let core = scratch.path().join("src-lepton");
        scratch.write(&format!("src-lepton/{GENERATED}"), &generated("x\n"))?;
        scratch.write(TARGET, "// mine\n")?;
        assert_eq!(
            assert_ok!(sync(scratch.path(), &core), "foreign"),
            Synced::Foreign
        );
        assert_eq!(scratch.read(TARGET)?, "// mine\n");
        Ok(())
    }

    #[test]
    fn no_generated_file_changes_nothing() -> Result<(), Failure> {
        let scratch = Scratch::new("command-types-none")?;
        let core = scratch.path().join("src-lepton");
        assert_eq!(
            assert_ok!(sync(scratch.path(), &core), "none"),
            Synced::NothingGenerated
        );
        assert_eq!(scratch.exists(TARGET), false);
        Ok(())
    }
}
