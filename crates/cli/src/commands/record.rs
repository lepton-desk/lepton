//! `lepton record` and `lepton replay` — a session's `invoke` traffic written to a file,
//! and that file run again against the core with no window.
//!
//! Recording is the core's (`zig/src/render/webview/record.zig`): `LEPTON_RECORD=<file>`
//! makes any webview build append every request and reply as it passes. This command
//! builds as `run` does, names the file and starts the application with it. A private
//! command (a file's bytes, the clipboard, a chosen path) is recorded without its bytes
//! unless `--unmasked`.
//!
//! `replay` starts the same binary with `LEPTON_REPLAY=<file>`: every recorded request
//! goes to the real handler and the replies are compared byte for byte. Its home and XDG
//! directories are an empty directory of its own, so a recorded `fs.remove` cannot reach
//! the user's files.

use std::path::{Path, PathBuf};

use lepton_orchestrator::OrchestratorError;

use super::build::CORE_DIR;
use super::run::{self, Built};
use super::{CliError, Outcome};

/// Flags for `lepton record`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct RecordFlags {
    /// The file to write. `recording-<unix seconds>.lrec` in the project by default.
    #[arg(long, short)]
    pub output: Option<PathBuf>,

    /// Also records private commands' bytes: file contents, the clipboard, chosen paths.
    #[arg(long)]
    pub unmasked: bool,

    /// Builds the core with the optimisation `lepton build` ships.
    #[arg(long)]
    pub release: bool,

    /// Prints the steps instead of running them.
    #[arg(long)]
    pub print_plan: bool,
}

/// Flags for `lepton replay`.
#[derive(Debug, Clone, clap::Args)]
pub struct ReplayFlags {
    /// The recording `lepton record` wrote.
    pub recording: PathBuf,

    /// Builds the core with the optimisation `lepton build` ships, to time a release.
    #[arg(long)]
    pub release: bool,

    /// Opens the window and answers the page's calls from the recording instead.
    #[arg(long)]
    pub page: bool,

    /// With `--page`: ends by itself once the recording has been played, for a test.
    #[arg(long, requires = "page")]
    pub close: bool,

    /// Prints the steps instead of running them.
    #[arg(long)]
    pub print_plan: bool,
}

fn working_directory() -> Result<PathBuf, CliError> {
    std::env::current_dir().map_err(|error| {
        CliError::Invalid(format!("could not read the working directory: {error}"))
    })
}

/// `run`'s build, always the webview path: only a page invokes commands.
fn build(root: &Path, release: bool, print_plan: bool) -> Result<Built, CliError> {
    run::Flags {
        native: false,
        webview: true,
        release,
        print_plan,
    }
    .build_in(root)
}

/// What a command needs from the project's core and `main.zig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Needs {
    Record,
    Replay,
    PageReplay,
}

/// A project made before recordings has a core that ignores `LEPTON_RECORD` and a
/// `main.zig` that opens the window under `LEPTON_REPLAY`: refused, never half done.
fn require_support(root: &Path, needs: Needs) -> Result<(), CliError> {
    let core = root
        .join(CORE_DIR)
        .join(lepton_core_vendoring::VENDORED_CORE)
        .join("src/render/webview/record.zig");
    if !core.is_file() {
        return Err(CliError::Invalid(
            "this project's core predates recordings; run `lepton update`".to_owned(),
        ));
    }
    let main = std::fs::read_to_string(root.join(CORE_DIR).join("main.zig")).unwrap_or_default();
    match needs {
        Needs::Record => {}
        Needs::Replay if !main.contains("webviewReplay") => {
            return Err(CliError::Invalid(
                "src-lepton/main.zig predates replays: it would open the window. Run `lepton update`".to_owned(),
            ));
        }
        Needs::Replay => {}
        Needs::PageReplay if !core.with_file_name("page_replay.zig").is_file() => {
            return Err(CliError::Invalid(
                "this project's core predates page replays; run `lepton update`".to_owned(),
            ));
        }
        Needs::PageReplay if !main.contains("pageReplayPassed") => {
            return Err(CliError::Invalid(
                "src-lepton/main.zig predates page replays: it would not report the verdict. Run `lepton update`".to_owned(),
            ));
        }
        Needs::PageReplay => {}
    }
    Ok(())
}

/// `--close` needs a core whose page replay reads `LEPTON_REPLAY_PAGE_CLOSE`; an older one
/// would leave the window open and the test waiting.
fn require_closing(root: &Path) -> Result<(), CliError> {
    let page_replay = root
        .join(CORE_DIR)
        .join(lepton_core_vendoring::VENDORED_CORE)
        .join("src/render/webview/page_replay.zig");
    let text = std::fs::read_to_string(page_replay).unwrap_or_default();
    if text.contains("LEPTON_REPLAY_PAGE_CLOSE") {
        Ok(())
    } else {
        Err(CliError::Invalid(
            "this project's core cannot end a page replay by itself; run `lepton update`"
                .to_owned(),
        ))
    }
}

/// Where a recording goes: `output` against the working directory, or a new name in it.
pub fn recording_path(root: &Path, output: Option<&Path>, now_seconds: u64) -> PathBuf {
    match output {
        Some(path) if path.is_absolute() => path.to_path_buf(),
        Some(path) => root.join(path),
        None => root.join(format!("recording-{now_seconds}.lrec")),
    }
}

/// The variables that make the application record into `file`.
pub fn record_environment(file: &Path, unmasked: bool) -> Vec<(&'static str, String)> {
    let mut env = vec![("LEPTON_RECORD", file.display().to_string())];
    if unmasked {
        env.push(("LEPTON_RECORD_UNMASKED", "1".to_owned()));
    }
    env
}

/// The variables that make the application replay `file` — in the core, or with its
/// page — with every directory a command could write to inside `home`.
pub fn replay_environment(file: &Path, home: &Path, page: bool) -> Vec<(&'static str, String)> {
    let at = |name: &str| home.join(name).display().to_string();
    let variable = if page {
        "LEPTON_REPLAY_PAGE"
    } else {
        "LEPTON_REPLAY"
    };
    vec![
        (variable, file.display().to_string()),
        ("HOME", home.display().to_string()),
        ("XDG_DATA_HOME", at(".local/share")),
        ("XDG_CONFIG_HOME", at(".config")),
        ("XDG_CACHE_HOME", at(".cache")),
        ("XDG_STATE_HOME", at(".local/state")),
    ]
}

fn print_launch(built: &Built, env: &[(&str, String)]) {
    let mut step =
        lepton_orchestrator::Step::new("app", built.bin.join(&built.binary).display().to_string());
    for (name, value) in env {
        step = step.env(*name, value.clone());
    }
    println!("{}", lepton_orchestrator::display(&step));
}

impl RecordFlags {
    pub fn run(self) -> Outcome {
        let root = working_directory()?;
        lepton_orchestrator::require_project(&root)?;
        require_support(&root, Needs::Record)?;
        let seconds = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or_default();
        let file = recording_path(&root, self.output.as_deref(), seconds);
        let env = record_environment(&file, self.unmasked);
        let built = build(&root, self.release, self.print_plan)?;
        if self.print_plan {
            print_launch(&built, &env);
            return Ok(());
        }
        super::launch::launch_with("record", &built.bin, &built.binary, &env)?;
        println!("\nRecorded to {}", file.display());
        println!("Replay it with: lepton replay {}", file.display());
        Ok(())
    }
}

impl ReplayFlags {
    pub fn run(self) -> Outcome {
        let root = working_directory()?;
        lepton_orchestrator::require_project(&root)?;
        let needs = if self.page {
            Needs::PageReplay
        } else {
            Needs::Replay
        };
        require_support(&root, needs)?;
        let file = if self.recording.is_absolute() {
            self.recording.clone()
        } else {
            root.join(&self.recording)
        };
        if !file.is_file() && !self.print_plan {
            return Err(CliError::Invalid(format!(
                "no recording at {}",
                file.display()
            )));
        }
        let home = std::env::temp_dir().join(format!("lepton-replay-{}", std::process::id()));
        let mut env = replay_environment(&file, &home, self.page);
        if self.close {
            require_closing(&root)?;
            env.push(("LEPTON_REPLAY_PAGE_CLOSE", "1".to_owned()));
        }
        let built = build(&root, self.release, self.print_plan)?;
        if self.print_plan {
            print_launch(&built, &env);
            return Ok(());
        }
        std::fs::create_dir_all(&home).map_err(|error| {
            CliError::Invalid(format!("could not create {}: {error}", home.display()))
        })?;
        let replayed = super::launch::launch_with("replay", &built.bin, &built.binary, &env);
        let _ = std::fs::remove_dir_all(&home);
        replayed.map_err(verdict)
    }
}

/// The application's exit code, as the replay's verdict; its report is already printed.
fn verdict(error: CliError) -> CliError {
    match &error {
        CliError::Toolchain(OrchestratorError::ToolFailed { status, .. }) if status == "1" => {
            CliError::Invalid("the replay differs from the recording (see above)".to_owned())
        }
        CliError::Toolchain(OrchestratorError::ToolFailed { status, .. }) if status == "2" => {
            CliError::Invalid("the recording could not be replayed (see above)".to_owned())
        }
        _ => error,
    }
}

#[cfg(test)]
mod tests {
    use super::{Needs, record_environment, recording_path, replay_environment, require_support};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};
    use std::path::Path;

    #[test]
    fn a_recording_is_named_in_the_project_unless_given() -> Result<(), Failure> {
        let root = Path::new("/p");
        assert_eq!(
            recording_path(root, None, 42),
            Path::new("/p/recording-42.lrec")
        );
        assert_eq!(
            recording_path(root, Some(Path::new("bug.lrec")), 42),
            Path::new("/p/bug.lrec")
        );
        assert_eq!(
            recording_path(root, Some(Path::new("/tmp/x.lrec")), 42),
            Path::new("/tmp/x.lrec")
        );
        Ok(())
    }

    #[test]
    fn private_bytes_are_recorded_only_when_asked() -> Result<(), Failure> {
        let masked = record_environment(Path::new("/p/a.lrec"), false);
        assert_eq!(masked, vec![("LEPTON_RECORD", "/p/a.lrec".to_owned())]);
        let unmasked = record_environment(Path::new("/p/a.lrec"), true);
        ensure!(
            unmasked.contains(&("LEPTON_RECORD_UNMASKED", "1".to_owned())),
            "unmasked: {unmasked:?}"
        );
        Ok(())
    }

    #[test]
    fn a_replay_writes_nowhere_but_its_own_directory() -> Result<(), Failure> {
        let env = replay_environment(Path::new("/p/a.lrec"), Path::new("/tmp/r"), false);
        let page = replay_environment(Path::new("/p/a.lrec"), Path::new("/tmp/r"), true);
        ensure!(
            page.contains(&("LEPTON_REPLAY_PAGE", "/p/a.lrec".to_owned()))
                && !page.iter().any(|(name, _)| *name == "LEPTON_REPLAY"),
            "a page replay must not divert main.zig into the core replay: {page:?}"
        );
        for (name, value) in &env {
            if *name != "LEPTON_REPLAY" {
                ensure!(
                    value.starts_with("/tmp/r"),
                    "{name}={value} escapes the replay's home"
                );
            }
        }
        for needed in ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"] {
            ensure!(
                env.iter().any(|(name, _)| *name == needed),
                "{needed} is not set"
            );
        }
        Ok(())
    }

    #[test]
    fn a_project_from_before_recordings_is_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("record-old")?;
        scratch.write("src-lepton/main.zig", "pub fn main() void {}\n")?;
        let error = assert_err!(require_support(scratch.path(), Needs::Record), "old core");
        assert_contains!(&error.to_string(), "predates recordings");

        scratch.write(
            "src-lepton/vendor/lepton-core/src/render/webview/record.zig",
            "",
        )?;
        assert_ok!(
            require_support(scratch.path(), Needs::Record),
            "a current core records"
        );
        let error = assert_err!(
            require_support(scratch.path(), Needs::Replay),
            "old main.zig"
        );
        assert_contains!(&error.to_string(), "would open the window");

        scratch.write("src-lepton/main.zig", "core.webviewReplay.requested()\n")?;
        assert_ok!(
            require_support(scratch.path(), Needs::Replay),
            "a current main.zig replays"
        );

        let error = assert_err!(
            require_support(scratch.path(), Needs::PageReplay),
            "no page_replay.zig"
        );
        assert_contains!(&error.to_string(), "predates page replays");
        scratch.write(
            "src-lepton/vendor/lepton-core/src/render/webview/page_replay.zig",
            "",
        )?;
        let error = assert_err!(
            require_support(scratch.path(), Needs::PageReplay),
            "no verdict"
        );
        assert_contains!(&error.to_string(), "would not report the verdict");
        scratch.write(
            "src-lepton/main.zig",
            "core.webviewReplay.requested()\nview.bridge.pageReplayPassed()\n",
        )?;
        assert_ok!(
            require_support(scratch.path(), Needs::PageReplay),
            "a current main.zig reports a page replay"
        );
        Ok(())
    }
}
