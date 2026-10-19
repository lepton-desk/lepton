//! Running the tools Lepton drives, and reporting honestly when they fail.
//!
//! Every build step in Lepton shells out to a real tool: `zig build` for the core,
//! a package manager for the frontend. This crate owns that boundary — spawning,
//! streaming output, and turning a failure into an error that names the cause
//! rather than a generic "build failed".
//!
//! Two rules hold throughout:
//!
//! * A child process's output is streamed to the developer's terminal as it
//!   arrives, never buffered to be printed afterwards. A build that takes a minute
//!   should look like a build that takes a minute.
//! * No step is allowed to fail silently. A tool that exits non-zero is an error
//!   carrying its exit status, because a CLI that reports success over a failed
//!   build is worse than one that crashes.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};

use crate::toolchain::{ToolProblem, ToolRequirement, Toolchain};

/// Something that went wrong, with enough detail to act on.
#[derive(Debug)]
pub enum OrchestratorError {
    /// A tool the command needs is missing or broken on this machine.
    ToolUnavailable {
        /// Which tool, by the name the CLI refers to it by.
        tool: &'static str,
        /// What is wrong with it.
        problem: ToolProblem,
    },
    /// A tool ran and reported failure.
    ToolFailed {
        /// Which tool.
        tool: &'static str,
        /// The exit status, rendered so a signal is distinguishable from a code.
        status: String,
    },
    /// A tool could not be spawned at all, for a reason other than being absent.
    Spawn {
        /// Which tool.
        tool: &'static str,
        /// The operating system's own description of the failure.
        reason: String,
        /// The working directory it was pointed at, when one was set. Both the OS
        /// message and the reason a spawn fails are identical for a missing program
        /// and a missing directory, so the directory is carried here to be named.
        directory: Option<std::path::PathBuf>,
    },
    /// The project on disk is not something the requested command can act on.
    NotLeptonProject { path: std::path::PathBuf },
    /// The build could not find the Zig core this CLI belongs to.
    CoreMissing { expected: std::path::PathBuf },
}

impl std::fmt::Display for OrchestratorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ToolUnavailable { tool, problem } => {
                write!(f, "`{tool}` is {problem}. Install it, then run this again.")
            }
            Self::ToolFailed { tool, status } => {
                write!(f, "`{tool}` failed ({status}).")
            }
            Self::Spawn {
                tool,
                reason,
                directory,
            } => {
                // The directory is named when there was one, because the operating
                // system's message is the same for a missing program and a missing
                // working directory, and only one of those is fixed by installing
                // something.
                match directory {
                    Some(directory) => write!(
                        f,
                        "`{tool}` could not be started in {}: {reason}.",
                        directory.display()
                    ),
                    None => write!(f, "`{tool}` could not be started: {reason}."),
                }
            }
            Self::NotLeptonProject { path } => write!(
                f,
                "{} is not a Lepton project: it has no lepton.config.json.",
                path.display()
            ),
            Self::CoreMissing { expected } => write!(
                f,
                "the Lepton core was not found at {}. Build it with `zig build` in the zig directory.",
                expected.display()
            ),
        }
    }
}

impl std::error::Error for OrchestratorError {}

/// The result of an orchestration step.
pub type Result<T> = std::result::Result<T, OrchestratorError>;

/// How a child process's output should be handled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Output {
    /// Both streams go to the developer's terminal, unbuffered.
    ///
    /// The default, because a build is something you watch. Line buffering means
    /// progress that a tool emits incrementally reaches the terminal as it happens
    /// rather than in a lump at the end.
    Inherit,
    /// Both streams are captured and returned, for steps whose output is data
    /// rather than narration — probing a version, for instance.
    Capture,
}

/// A tool to run, described well enough to run and to name in an error.
#[derive(Debug, Clone)]
pub struct Step {
    pub tool: &'static str,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<std::path::PathBuf>,
    pub output: Output,
    /// Variables set for this step only, on top of the inherited environment.
    pub env: Vec<(String, String)>,
}

impl Step {
    /// A step whose output belongs to the developer.
    pub fn new(tool: &'static str, program: impl Into<String>) -> Self {
        Self {
            tool,
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            output: Output::Inherit,
            env: Vec::new(),
        }
    }

    /// A step whose output is data to be read.
    pub fn capturing(tool: &'static str, program: impl Into<String>) -> Self {
        Self {
            output: Output::Capture,
            ..Self::new(tool, program)
        }
    }

    #[must_use]
    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    #[must_use]
    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    #[must_use]
    pub fn env(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.push((name.into(), value.into()));
        self
    }

    #[must_use]
    pub fn in_dir(mut self, dir: impl Into<std::path::PathBuf>) -> Self {
        self.cwd = Some(dir.into());
        self
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.program);
        command.args(&self.args);
        command.envs(self.env.iter().map(|(name, value)| (name, value)));
        // An empty directory means "here", not "the directory whose name is the empty
        // string". `Path::parent` on a bare relative name returns exactly that, and
        // `setCurrentDir("")` fails with `ENOENT`, which surfaces as the program
        // itself not being found — a message that sends the reader looking at the
        // toolchain when the toolchain is fine.
        if let Some(dir) = self
            .cwd
            .as_deref()
            .filter(|path| !path.as_os_str().is_empty())
        {
            command.current_dir(dir);
        }
        command
    }
}

/// What a captured step produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Captured {
    /// Standard output, trimmed of the trailing newline.
    pub stdout: String,
    /// Standard error, kept separate because a tool may write warnings there
    /// while succeeding, and merging the two would turn a warning into an error.
    pub stderr: String,
}

/// Runs a step to completion and returns its captured output.
///
/// A non-zero exit is an error carrying the status, never an `Ok` with the output
/// attached: a caller that ignores the exit code would then be reading a failed
/// build's output as if it were good.
pub fn run(step: &Step) -> Result<Captured> {
    let output = step
        .command()
        .stdin(Stdio::inherit())
        .output()
        .map_err(|error| OrchestratorError::Spawn {
            tool: step.tool,
            reason: error.to_string(),
            directory: step.cwd.clone(),
        })?;

    if !output.status.success() {
        // The streams are shown before the error is returned. A developer who has
        // just seen "zig failed" needs the compiler's own words above it, not
        // buried in a struct.
        let _ = std::io::stdout().write_all(&output.stdout);
        let _ = std::io::stderr().write_all(&output.stderr);
        return Err(OrchestratorError::ToolFailed {
            tool: step.tool,
            status: describe_status(&output.status),
        });
    }

    Ok(Captured {
        stdout: String::from_utf8_lossy(&output.stdout)
            .trim_end()
            .to_owned(),
        stderr: String::from_utf8_lossy(&output.stderr)
            .trim_end()
            .to_owned(),
    })
}

/// Runs a step, streaming its output to the terminal as it arrives.
///
/// Output is copied line by line on a thread while the child runs, so a tool that
/// reports progress incrementally shows that progress. This is what a build needs:
/// buffering it and printing at the end would turn a working build into a frozen
/// one that looks hung.
pub fn run_streaming(step: &Step) -> Result<()> {
    let mut command = step.command();
    // Streamed through a pipe, so told to colour when `lepton` does (`colour.rs`).
    crate::colour::apply(&mut command, &step.env);
    let mut child = command
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| OrchestratorError::Spawn {
            tool: step.tool,
            reason: error.to_string(),
            directory: step.cwd.clone(),
        })?;

    // Registered for as long as it runs, so a SIGTERM to `lepton` reaches it too.
    crate::supervise::track(child.id());
    let readers = start_pumps(&mut child);
    // The child first, then its output: a process the child started may keep the pipes
    // open long after the child is gone (a browser an application launched did, and the
    // application stayed an unreaped zombie behind a read that never ended).
    let waited = child.wait();
    crate::supervise::untrack(child.id());
    finish_pumps(readers, DRAIN_AFTER_EXIT, step.cwd.clone())?;

    let status = waited.map_err(|error| OrchestratorError::Spawn {
        tool: step.tool,
        reason: error.to_string(),
        directory: step.cwd.clone(),
    })?;

    if !status.success() {
        return Err(OrchestratorError::ToolFailed {
            tool: step.tool,
            status: describe_status(&status),
        });
    }
    Ok(())
}

/// How long the output of a process that has exited may still arrive: what it wrote just
/// before it ended is in the pipe, and reading it takes far less than this.
const DRAIN_AFTER_EXIT: std::time::Duration = std::time::Duration::from_millis(500);

/// The threads copying a child's streams, and the channel each reports its end on.
struct Readers {
    threads: Vec<std::thread::JoinHandle<()>>,
    ended: std::sync::mpsc::Receiver<()>,
}

/// Starts copying both of a child's streams to this process's.
///
/// Two reader threads, one per stream, because a tool that fills one pipe while
/// nobody drains it blocks forever — the classic deadlock of a build that hangs
/// with no output.
fn start_pumps(child: &mut Child) -> Readers {
    let (sender, ended) = std::sync::mpsc::channel();
    let mut threads = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        threads.push(pump_one(stdout, sender.clone(), |line| {
            let _ = writeln!(io::stdout(), "{line}");
        }));
    }
    if let Some(stderr) = child.stderr.take() {
        threads.push(pump_one(stderr, sender, |line| {
            let _ = writeln!(io::stderr(), "{line}");
        }));
    }
    Readers { threads, ended }
}

/// After the child exited: waits up to `drain` for the readers to reach the end of the
/// streams. A reader still blocked then is reading a pipe some other process holds; it
/// is left behind rather than waited on, since what the child wrote has been read.
fn finish_pumps(
    readers: Readers,
    drain: std::time::Duration,
    directory: Option<std::path::PathBuf>,
) -> Result<()> {
    let deadline = std::time::Instant::now() + drain;
    let mut finished = 0;
    while finished < readers.threads.len() {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match readers.ended.recv_timeout(left) {
            Ok(()) => finished += 1,
            Err(_) => return Ok(()),
        }
    }
    for thread in readers.threads {
        if thread.join().is_err() {
            // The thread's own panic payload is deliberately not forwarded: it is a
            // `Box<dyn Any>` with no `Display`, and rendering it would either need a
            // downcast that can fail or print a debug representation a developer
            // cannot act on. The fact that it panicked is the report.
            return Err(OrchestratorError::Spawn {
                tool: "output reader",
                reason: String::from("the thread reading a child's output panicked"),
                directory,
            });
        }
    }
    Ok(())
}

/// Reads one stream a line at a time, calling `emit` for each complete line.
///
/// A trailing fragment with no newline is emitted too: a tool that ends its last
/// line without one is not broken, and dropping that line would hide the message
/// most worth reading.
fn pump_one<R: Read + Send + 'static>(
    reader: R,
    ended: std::sync::mpsc::Sender<()>,
    emit: impl Fn(&str) + Send + 'static,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        // Reports the end however the thread ends, a panic included.
        struct Ended(std::sync::mpsc::Sender<()>);
        impl Drop for Ended {
            fn drop(&mut self) {
                let _ = self.0.send(());
            }
        }
        let _ended = Ended(ended);
        let mut reader = BufReader::new(reader);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    let trimmed = line.trim_end_matches(['\r', '\n']);
                    emit(trimmed);
                }
            }
        }
    })
}

/// The command line a step will run, as a developer would type it.
///
/// Used in error messages and in `--verbose`, so a reported failure can be
/// reproduced by hand instead of only being described.
pub fn display(step: &Step) -> String {
    let mut parts: Vec<String> = step
        .env
        .iter()
        .map(|(name, value)| format!("{name}={}", quote_arg(value)))
        .collect();
    parts.push(quote_arg(&step.program));
    parts.extend(step.args.iter().map(|arg| quote_arg(arg)));
    parts.join(" ")
}

/// Quotes one argument if it would otherwise be re-split by a shell.
///
/// A command line reported without this cannot be pasted back into a terminal and
/// produce the same command — which is the only reason to report one at all. An
/// argument with nothing ambiguous in it is left alone, so the common case stays
/// readable.
fn quote_arg(arg: &str) -> String {
    let needs_quotes = arg.is_empty()
        || arg
            .chars()
            .any(|character| character.is_whitespace() || character == '\'');

    if !needs_quotes {
        return arg.to_owned();
    }

    // Single quotes suppress every shell meaning, so the only character needing
    // care is the single quote itself, which is closed, escaped and reopened.
    let mut quoted = String::with_capacity(arg.len() + 2);
    quoted.push('\'');
    for character in arg.chars() {
        if character == '\'' {
            quoted.push_str("'\\''");
        } else {
            quoted.push(character);
        }
    }
    quoted.push('\'');
    quoted
}

/// Checks the machine can do what a command needs, before it starts doing it.
///
/// Failing here rather than half-way through means a missing tool is named in one
/// line instead of after a scaffold has already been half-written.
pub fn require(chain: &Toolchain, needs: ToolRequirement) -> Result<()> {
    match chain.blocker(needs) {
        Some(problem) => Err(OrchestratorError::ToolUnavailable {
            tool: match needs {
                ToolRequirement::Build => "zig",
                ToolRequirement::Develop => "zig",
                ToolRequirement::Scaffold => "npm",
            },
            problem: problem.clone(),
        }),
        None => Ok(()),
    }
}

/// Renders an exit status so that a signal is distinguishable from a code.
///
/// A process killed by a signal has no exit code. Printing `exit 0` for a crash
/// would be precisely the sort of thing this tool exists to prevent.
pub(crate) fn describe_status(status: &ExitStatus) -> String {
    match status.code() {
        Some(code) => code.to_string(),
        None => describe_signal(status),
    }
}

#[cfg(unix)]
fn describe_signal(status: &ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt as _;
    match status.signal() {
        Some(signal) => format!("signal {signal}"),
        None => "unknown".to_owned(),
    }
}

/// Windows always has a code: a process ended with `TerminateProcess` gets the one it was given.
#[cfg(not(unix))]
fn describe_signal(_: &ExitStatus) -> String {
    "unknown".to_owned()
}

#[cfg(test)]
mod tests {
    use super::{Output, Step};
    use crate::testing::{Failure, Scratch};
    use crate::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    /// `/bin/sh` with one script, which is the shortest way to make a child produce
    /// a known stream, exit code, and side effect without inventing a binary.
    #[cfg(unix)]
    fn shell(script: &str) -> Step {
        Step::capturing("sh", "sh").args(["-c", script])
    }

    /// `cmd /c` on Windows, which has no `sh`. Its `echo` ends lines with `\r\n`, which is
    /// what a `.cmd` tool prints there too.
    #[cfg(windows)]
    fn shell(script: &str) -> Step {
        Step::capturing("cmd", "cmd").args(["/c", script])
    }

    /// The `sh` script on Unix, the `cmd` one on Windows.
    fn either(unix: &'static str, windows: &'static str) -> &'static str {
        if cfg!(windows) { windows } else { unix }
    }

    #[test]
    fn a_step_runs_and_returns_its_stdout() -> Result<(), Failure> {
        let captured = assert_ok!(
            crate::run(&shell(either("printf hello", "echo hello"))),
            "the step should run"
        );

        assert_eq!(captured.stdout, "hello");
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn a_step_sets_its_own_variables_and_shows_them() -> Result<(), Failure> {
        let step = shell("printf %s \"$LEPTON_STEP_TEST\"").env("LEPTON_STEP_TEST", "a b");
        let captured = assert_ok!(crate::run(&step), "the step should run");

        assert_eq!(captured.stdout, "a b");
        assert_eq!(
            super::display(&step),
            "LEPTON_STEP_TEST='a b' sh -c 'printf %s \"$LEPTON_STEP_TEST\"'"
        );
        Ok(())
    }

    #[test]
    fn a_step_ends_when_its_process_does_even_if_a_child_keeps_the_pipes() -> Result<(), Failure> {
        // A launched browser kept an application's stdout open, and `lepton run` waited on
        // the pipe forever with the application a zombie. The background `sleep` here holds
        // the pipe the same way, for five seconds (`start /b ping` on Windows).
        let step = if cfg!(windows) {
            Step::new("cmd", "cmd").args(["/c", "start /b ping -n 6 127.0.0.1 & echo started"])
        } else {
            Step::new("sh", "sh").args(["-c", "sleep 5 & echo started"])
        };
        let began = std::time::Instant::now();
        assert_ok!(crate::run_streaming(&step), "the step should succeed");
        let took = began.elapsed();
        ensure!(
            took < std::time::Duration::from_secs(3),
            "run_streaming waited {took:?} for a pipe its process no longer held"
        );
        Ok(())
    }

    #[test]
    fn a_non_zero_exit_is_an_error_carrying_the_status() -> Result<(), Failure> {
        // Not an `Ok` with the output attached: a caller that ignored the exit code
        // would be reading a failed build's output as if it were good.
        let error = assert_err!(
            crate::run(&shell(either(
                "printf 'half a line' >&2; exit 3",
                "1>&2 echo half a line& exit 3"
            ))),
            "a failing step must be an error"
        );

        match error {
            super::OrchestratorError::ToolFailed { status, .. } => assert_eq!(status, "3"),
            other => {
                return Err(Failure {
                    claim: "a non-zero exit should be a tool failure".to_owned(),
                    actual: format!("{other:?}"),
                });
            }
        }
        Ok(())
    }

    /// Windows has no signals: a process ended from outside exits with the code it was given.
    #[cfg(unix)]
    #[test]
    fn a_killed_child_is_reported_without_inventing_an_exit_code() -> Result<(), Failure> {
        // A crash is not `exit 0`, and a status that says "signal 9" is the difference
        // between a timeout and a segfault at three in the morning.
        let error = assert_err!(
            crate::run(&shell("kill -9 $$")),
            "a killed child must be an error"
        );

        match error {
            super::OrchestratorError::ToolFailed { status, .. } => {
                ensure!(status.starts_with("signal"), "got {status:?}");
            }
            other => {
                return Err(Failure {
                    claim: "a signalled child should be a tool failure".to_owned(),
                    actual: format!("{other:?}"),
                });
            }
        }
        Ok(())
    }

    #[test]
    fn the_two_streams_are_kept_apart() -> Result<(), Failure> {
        // Merging them would turn a warning into an error, because a caller that
        // checks stderr for content cannot then tell a warning from a failure.
        let captured = assert_ok!(
            crate::run(&shell(either(
                "printf out; printf err >&2",
                "echo out& 1>&2 echo err"
            ))),
            "the step should run"
        );

        assert_eq!(captured.stdout, "out");
        assert_eq!(captured.stderr, "err");
        Ok(())
    }

    #[test]
    fn trailing_newlines_are_trimmed_from_captured_output() -> Result<(), Failure> {
        // So that a version string read from a tool compares equal to the version the
        // tool's own documentation prints.
        let captured = assert_ok!(
            crate::run(&shell(either("printf '1.2.3\n\n'", "echo 1.2.3& echo."))),
            "the step should run"
        );

        assert_eq!(captured.stdout, "1.2.3");
        Ok(())
    }

    #[test]
    fn interior_whitespace_is_left_alone() -> Result<(), Failure> {
        // Only the ends are touched. A tool whose output is a table has interior
        // newlines, and trimming those would destroy the table.
        let captured = assert_ok!(
            crate::run(&shell(either("printf 'a\nb\n'", "echo a& echo b"))),
            "the step should run"
        );

        assert_eq!(captured.stdout, either("a\nb", "a\r\nb"));
        Ok(())
    }

    #[test]
    fn a_program_that_is_not_there_is_named_in_the_error() -> Result<(), Failure> {
        let step = Step::capturing("lepton-nonexistent-tool", "lepton-nonexistent-tool");

        let error = assert_err!(crate::run(&step), "a missing program must be an error");

        // The tool's name is what the reader searches for; the OS message alone sends
        // them looking at the wrong program.
        assert_contains!(&error.to_string(), "lepton-nonexistent-tool");
        Ok(())
    }

    #[test]
    fn the_working_directory_is_applied() -> Result<(), Failure> {
        let scratch = assert_ok!(
            Scratch::new("cwd"),
            "the scratch directory should be creatable"
        );
        scratch
            .write("marker.txt", "here")
            .map_err(|error| Failure {
                claim: "the marker should be writable".to_owned(),
                actual: format!("{error}"),
            })?;

        // The file exists only in the scratch directory, so seeing it is the proof the
        // working directory was applied rather than ignored.
        let captured = assert_ok!(
            crate::run(&shell(either("ls marker.txt", "dir /b marker.txt")).in_dir(scratch.path())),
            "the step should run in the given directory"
        );

        assert_eq!(captured.stdout, "marker.txt");
        Ok(())
    }

    #[test]
    fn an_empty_working_directory_means_here() -> Result<(), Failure> {
        // `Path::parent` on a bare relative name returns `Some("")`, and
        // `setCurrentDir("")` fails with `ENOENT` — which is reported as the program
        // not being found, sending the reader at the toolchain instead.
        let captured = assert_ok!(
            crate::run(
                &shell(either("printf here", "echo here")).in_dir(std::path::PathBuf::from(""))
            ),
            "an empty directory should be ignored"
        );

        assert_eq!(captured.stdout, "here");
        Ok(())
    }

    #[test]
    fn a_working_directory_that_is_not_there_is_reported() -> Result<(), Failure> {
        // Not silently ignored: a step pointed at a directory that does not exist is a
        // mistake in the command, and running it somewhere else would be worse.
        let step = shell("printf x").in_dir("/tmp/lepton-no-such-directory-9d2f");

        let error = assert_err!(crate::run(&step), "a missing directory must be an error");

        assert_contains!(&error.to_string(), "lepton-no-such-directory-9d2f");
        Ok(())
    }

    #[test]
    fn a_streaming_step_reaches_the_terminal_and_returns_nothing() -> Result<(), Failure> {
        // The return type is the assertion: a streaming step produces no `Captured`,
        // because its output was already the developer's to read.
        let outcome: crate::Result<()> =
            crate::run_streaming(&shell(either("printf streamed", "echo streamed")));

        assert_ok!(outcome, "a streaming step should succeed");
        Ok(())
    }

    #[test]
    fn a_streaming_step_reports_failure_too() -> Result<(), Failure> {
        let outcome = crate::run_streaming(&shell("exit 4"));

        let error = assert_err!(outcome, "a failing streaming step must be an error");

        match error {
            super::OrchestratorError::ToolFailed { status, .. } => assert_eq!(status, "4"),
            other => {
                return Err(Failure {
                    claim: "a failing streaming step should be a tool failure".to_owned(),
                    actual: format!("{other:?}"),
                });
            }
        }
        Ok(())
    }

    #[test]
    fn streaming_and_capture_are_different_modes() -> Result<(), Failure> {
        // A build is something you watch; a version string is data. Getting this
        // wrong in either direction is visible immediately, so it is pinned here.
        assert_eq!(Step::new("t", "x").output, Output::Inherit);
        assert_eq!(Step::capturing("t", "x").output, Output::Capture);
        Ok(())
    }

    /// `echo` is a program on Unix only; on Windows it is a `cmd` built-in.
    #[cfg(unix)]
    #[test]
    fn arguments_reach_the_child_as_separate_words() -> Result<(), Failure> {
        // No shell, so a name containing a space stays one word. This is what makes a
        // project called `My App` buildable at all.
        let captured = assert_ok!(
            crate::run(&Step::capturing("echo", "echo").args(["a b", "c"])),
            "the step should run"
        );

        // Two arguments in, two words out: `a b` stayed one word, which is the whole
        // reason a project called `My App` builds at all.
        assert_eq!(captured.stdout, "a b c");
        Ok(())
    }

    #[test]
    fn a_command_line_is_shown_the_way_it_would_be_typed() -> Result<(), Failure> {
        // Printed by `--dry-run` and by a failure report, so it has to be
        // copy-pasteable: quoting a word only when it needs quoting is the
        // difference between a line a developer runs and a line they retype.
        let plain = crate::display(&Step::new("zig", "zig").arg("build"));
        assert_eq!(plain, "zig build");

        let spaced = crate::display(
            &Step::new("pnpm", "pnpm")
                .args(["run", "lepton:build"])
                .arg("--flag"),
        );
        assert_eq!(spaced, "pnpm run lepton:build --flag");

        // Quoted, because the alternative is a line the reader cannot paste. The exact
        // quoting style is pinned so a change to it is a deliberate one.
        let quoted = crate::display(&Step::new("ls", "ls").arg("My App"));
        assert_eq!(quoted, "ls 'My App'");

        let empty = crate::display(&Step::new("zig", "zig"));
        assert_eq!(empty, "zig");
        Ok(())
    }
}
