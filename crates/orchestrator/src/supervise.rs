//! Children that end when Lepton ends, however it ends.
//!
//! `lepton dev` and `lepton run` start processes that outlive nothing on their own: the
//! dev server, `zig build`, the application. Measured on 2026-10-15: `timeout 60 lepton
//! dev` sent SIGTERM to `lepton` alone, which died at once and left Vite on port 5173 and
//! the application holding its channel name; the next `lepton dev` failed with `error:
//! Held` and "port in use". Ctrl-C hid it, because a terminal signals the whole group.
//!
//! Every child this crate starts is registered here. On SIGINT, SIGTERM or SIGHUP each
//! one is sent **SIGTERM** — not SIGKILL, so a package manager can pass it on to the
//! server it started — given a moment to go, and then this process exits. SIGKILL to
//! `lepton` itself cannot be caught; that limit is the kernel's.
//!
//! Windows has no SIGTERM. Measured on 2026-10-18 with `cmd /c node`: `Child::kill` ended
//! `cmd` and left node running; `taskkill /T` without `/F` refuses console processes;
//! `taskkill /T /F` ended the tree. So a tracked child is ended with its tree there, and
//! [`install`] also puts `lepton` in a kill-on-close job object, which its children join:
//! when `lepton` ends — even by `Stop-Process -Force`, which no handler sees — the kernel
//! closes the job and ends them (measured). `ctrlc` reports Ctrl-C, Ctrl-Break, a closed
//! console and logoff alike.

use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use platform::{alive, contain};

/// The exit code after a handled termination signal (128 + SIGINT, by convention).
pub const INTERRUPTED_EXIT: i32 = 130;

/// How long children get to finish after SIGTERM before Lepton stops waiting.
const GRACE: Duration = Duration::from_secs(2);

fn registry() -> &'static Mutex<Vec<u32>> {
    static PIDS: OnceLock<Mutex<Vec<u32>>> = OnceLock::new();
    PIDS.get_or_init(|| Mutex::new(Vec::new()))
}

/// Registers a child so a termination signal reaches it.
pub fn track(pid: u32) {
    registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(pid);
}

/// Forgets a child that has been waited for. Its pid may be reused by the system.
pub fn untrack(pid: u32) {
    registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|&p| p != pid);
}

/// Asks `pid` to end: SIGTERM on Unix, the whole tree on Windows. Gone already is not an
/// error: that is the outcome wanted.
pub fn terminate(pid: u32) {
    platform::terminate(pid);
}

#[cfg(unix)]
mod platform {
    use nix::sys::signal::{Signal, kill};
    use nix::unistd::Pid;

    pub fn terminate(pid: u32) {
        if let Ok(raw) = i32::try_from(pid) {
            let _ = kill(Pid::from_raw(raw), Signal::SIGTERM);
        }
    }

    /// Whether `pid` is still running.
    ///
    /// Signal 0 alone is not enough: a child that has exited but not been reaped is a zombie,
    /// and `kill(pid, 0)` still succeeds on it. Measured — the first version waited the full
    /// grace period for a process that had already gone. The state letter in
    /// `/proc/<pid>/stat` (after the parenthesised name) says `Z` for those.
    pub fn alive(pid: u32) -> bool {
        let Ok(raw) = i32::try_from(pid) else {
            return false;
        };
        if kill(Pid::from_raw(raw), None).is_err() {
            return false;
        }
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => stat
                .rfind(')')
                .and_then(|end| stat[end + 1..].split_whitespace().next())
                .is_none_or(|state| state != "Z"),
            Err(_) => false,
        }
    }

    /// Nothing to do: the signal handler is the whole mechanism here.
    pub fn contain() -> Result<(), String> {
        Ok(())
    }
}

#[cfg(windows)]
mod platform {
    use std::process::{Command, Stdio};
    use std::sync::OnceLock;

    /// `/T` takes the tree, `/F` is required for console processes (refused without it).
    pub fn terminate(pid: u32) {
        let _ = Command::new("taskkill")
            .args(["/T", "/F", "/PID", &pid.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    /// Whether `pid` is still running, from `tasklist`'s CSV row (its other messages are
    /// translated; the quoted pid is not).
    pub fn alive(pid: u32) -> bool {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).contains(&format!(",\"{pid}\",")))
    }

    /// Puts this process in a kill-on-close job; children started afterwards join it. The
    /// job lives as long as the process: dropping it would close the handle and end us.
    pub fn contain() -> Result<(), String> {
        static JOB: OnceLock<win32job::Job> = OnceLock::new();
        let job = win32job::Job::create().map_err(|error| error.to_string())?;
        let mut info = job
            .query_extended_limit_info()
            .map_err(|error| error.to_string())?;
        info.limit_kill_on_job_close();
        job.set_extended_limit_info(&info)
            .map_err(|error| error.to_string())?;
        job.assign_current_process()
            .map_err(|error| error.to_string())?;
        let _ = JOB.set(job);
        Ok(())
    }
}

/// SIGTERM to every registered child, then wait up to `GRACE` for them to go.
///
/// Returns how many were still alive when the wait ended.
pub fn terminate_all() -> usize {
    let pids: Vec<u32> = registry()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    for &pid in &pids {
        terminate(pid);
    }
    let deadline = Instant::now() + GRACE;
    loop {
        let living = pids.iter().filter(|&&pid| alive(pid)).count();
        if living == 0 || Instant::now() >= deadline {
            return living;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

static INTERRUPTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

static FOREGROUND: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Marks a child the main thread waits for and reports on (the application under `lepton
/// run` and `lepton dev`) for as long as the guard lives. On a termination signal the
/// handler ends the children and then waits, up to `GRACE`, for every guard to drop, so
/// that report is printed before the process exits. Measured: the handler's exit raced
/// it, and one Ctrl+C in four ended `lepton run` with 130 and no `✔ app` line.
pub fn foreground() -> Foreground {
    FOREGROUND.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    Foreground(())
}

/// See [`foreground`].
pub struct Foreground(());

impl Drop for Foreground {
    fn drop(&mut self) {
        FOREGROUND.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Waits until no [`Foreground`] guard is alive or `limit` has passed; true when none is.
fn wait_for_foreground(limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        if FOREGROUND.load(std::sync::atomic::Ordering::SeqCst) == 0 {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Whether a termination signal has arrived. The handler ends the children first, so the
/// main thread sees a child "fail"; it must not report that as an error and exit before
/// the handler finishes (measured: the receipt was lost to "`dev` failed (signal 15)").
pub fn interrupted() -> bool {
    INTERRUPTED.load(std::sync::atomic::Ordering::SeqCst)
}

/// Blocks the calling thread for good; the signal handler ends the process.
pub fn await_exit() -> ! {
    loop {
        std::thread::park();
    }
}

type Hook = Box<dyn Fn() + Send + Sync>;

fn hook() -> &'static Mutex<Option<Hook>> {
    static HOOK: OnceLock<Mutex<Option<Hook>>> = OnceLock::new();
    HOOK.get_or_init(|| Mutex::new(None))
}

/// Registers what to do after the children are ended and before the process exits on a
/// signal — `lepton dev` prints its session receipt here. A later call replaces it.
pub fn on_interrupt(action: impl Fn() + Send + Sync + 'static) {
    *hook().lock().unwrap_or_else(PoisonError::into_inner) = Some(Box::new(action));
}

/// Runs the registered action, if any. Public so it can be tested without a signal.
pub fn run_interrupt_hook() {
    if let Some(action) = hook()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
    {
        action();
    }
}

/// Installs the handler once per process. Later calls are no-ops.
pub fn install() {
    static INSTALLED: OnceLock<()> = OnceLock::new();
    INSTALLED.get_or_init(|| {
        if let Err(error) = contain() {
            // Not fatal either: children are still ended on a handled signal.
            eprintln!("lepton: could not tie child processes to this one: {error}");
        }
        let outcome = ctrlc::set_handler(|| {
            INTERRUPTED.store(true, std::sync::atomic::Ordering::SeqCst);
            let left = terminate_all();
            if left > 0 {
                eprintln!("lepton: {left} child process(es) did not exit within {GRACE:?}");
            }
            wait_for_foreground(GRACE);
            run_interrupt_hook();
            std::process::exit(INTERRUPTED_EXIT);
        });
        if let Err(error) = outcome {
            // Not fatal: the command still works, it just cannot clean up after a signal.
            eprintln!("lepton: could not watch for termination signals: {error}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::{foreground, terminate_all, track, untrack, wait_for_foreground};
    use crate::testing::{Failure, fail};
    use crate::{assert_eq, ensure};
    use std::process::Command;
    use std::sync::{Mutex, PoisonError};

    /// The registry is process-wide, so tests that signal "every tracked child" would
    /// otherwise end each other's children when run in parallel.
    static SERIAL: Mutex<()> = Mutex::new(());

    /// A child that waits about 30 s and then ends by itself.
    fn waiting() -> Command {
        if cfg!(windows) {
            let mut command = Command::new("ping");
            command
                .args(["-n", "30", "127.0.0.1"])
                .stdout(std::process::Stdio::null());
            command
        } else {
            let mut command = Command::new("sleep");
            command.arg("30");
            command
        }
    }

    #[test]
    fn the_handler_waits_for_the_foreground_report() -> Result<(), Failure> {
        use std::time::{Duration, Instant};
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let guard = foreground();
        let began = Instant::now();
        let reporter = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            drop(guard);
        });
        ensure!(
            wait_for_foreground(Duration::from_secs(5)),
            "the wait ends when the guard drops"
        );
        ensure!(
            began.elapsed() >= Duration::from_millis(150),
            "the wait lasts until the report is out"
        );
        reporter
            .join()
            .map_err(|_| fail("the reporter thread", "panicked"))?;

        let held = foreground();
        ensure!(
            !wait_for_foreground(Duration::from_millis(50)),
            "a guard still alive ends the wait at its limit"
        );
        drop(held);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn a_tracked_child_is_ended_with_sigterm() -> Result<(), Failure> {
        use std::os::unix::process::ExitStatusExt as _;
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let mut child = waiting()
            .spawn()
            .map_err(|error| fail("sleep starts", error))?;
        track(child.id());

        let left = terminate_all();
        let status = child
            .wait()
            .map_err(|error| fail("the child is reaped", error))?;
        untrack(child.id());

        assert_eq!(left, 0);
        // SIGTERM, not SIGKILL: a package manager must be able to pass it on.
        assert_eq!(status.signal(), Some(15));
        Ok(())
    }

    /// `cmd /c ping` is the shape of `pnpm.cmd run dev` → node: ending `cmd` alone left
    /// the grandchild running (measured), so the grandchild is what is checked.
    #[cfg(windows)]
    #[test]
    fn a_tracked_childs_tree_is_ended() -> Result<(), Failure> {
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let mut child = Command::new("cmd")
            .args(["/c", "ping -n 30 127.0.0.1 >nul"])
            .spawn()
            .map_err(|error| fail("cmd starts", error))?;
        let Some(grandchild) = child_of(child.id())? else {
            let _ = child.kill();
            return Err(fail("ping is started under cmd", "no child process found"));
        };
        track(child.id());

        let left = terminate_all();
        let _ = child.wait();
        untrack(child.id());

        assert_eq!(left, 0);
        ensure!(
            !super::alive(grandchild),
            "the grandchild must end with the tracked child"
        );
        Ok(())
    }

    /// The first child of `parent`, waited for up to 5 s (Windows has no `/proc` to read).
    #[cfg(windows)]
    fn child_of(parent: u32) -> Result<Option<u32>, Failure> {
        let query =
            format!("(Get-CimInstance Win32_Process -Filter 'ParentProcessId={parent}').ProcessId");
        for _ in 0..50 {
            let out = Command::new("powershell")
                .args(["-NoProfile", "-Command", &query])
                .output()
                .map_err(|error| fail("powershell lists the children", error))?;
            let found = String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .find_map(|pid| pid.parse::<u32>().ok());
            if found.is_some() {
                return Ok(found);
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        Ok(None)
    }

    /// Run as its own process by `a_lepton_killed_outright_takes_its_children_along`: joins
    /// the job as `install` does, starts a tree, prints its pid and waits to be killed.
    #[cfg(windows)]
    #[test]
    fn contained_helper() -> Result<(), Failure> {
        if std::env::var_os("LEPTON_CONTAIN_HELPER").is_none() {
            return Ok(());
        }
        super::contain().map_err(|error| fail("joins a kill-on-close job", error))?;
        let child = Command::new("cmd")
            .args(["/c", "ping -n 30 127.0.0.1 >nul"])
            .spawn()
            .map_err(|error| fail("cmd starts", error))?;
        println!("child {}", child.id());
        std::thread::sleep(std::time::Duration::from_secs(30));
        Ok(())
    }

    /// `TerminateProcess` (`taskkill /F` without `/T`, `Stop-Process -Force`) reaches no
    /// handler; only the job ends the children then.
    #[cfg(windows)]
    #[test]
    fn a_lepton_killed_outright_takes_its_children_along() -> Result<(), Failure> {
        use std::io::BufRead as _;
        let exe = std::env::current_exe().map_err(|error| fail("the test binary", error))?;
        let mut helper = Command::new(exe)
            .args([
                "--exact",
                "supervise::tests::contained_helper",
                "--nocapture",
            ])
            .env("LEPTON_CONTAIN_HELPER", "1")
            .stdout(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| fail("the helper starts", error))?;
        let stdout = helper
            .stdout
            .take()
            .ok_or_else(|| fail("the helper's stdout", "not piped"))?;
        let child = std::io::BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .find_map(|line| {
                line.strip_prefix("child ")
                    .and_then(|pid| pid.parse::<u32>().ok())
            });
        let Some(child) = child else {
            let _ = helper.kill();
            return Err(fail("the helper reports its child", "no pid printed"));
        };
        let grandchild = child_of(child)?;

        let _ = helper.kill(); // TerminateProcess: no handler runs
        let _ = helper.wait();
        std::thread::sleep(std::time::Duration::from_millis(500));

        ensure!(!super::alive(child), "cmd must end with the killed process");
        ensure!(
            grandchild.is_some_and(|pid| !super::alive(pid)),
            "ping under cmd must end too: {grandchild:?}"
        );
        Ok(())
    }

    #[test]
    fn the_interrupt_hook_runs_what_was_registered() -> Result<(), Failure> {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let ran = Arc::new(AtomicBool::new(false));
        let seen = Arc::clone(&ran);
        super::on_interrupt(move || seen.store(true, Ordering::SeqCst));
        super::run_interrupt_hook();
        ensure!(ran.load(Ordering::SeqCst), "the registered action must run");
        Ok(())
    }

    #[test]
    fn an_untracked_child_is_left_alone() -> Result<(), Failure> {
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let mut child = waiting()
            .spawn()
            .map_err(|error| fail("sleep starts", error))?;
        track(child.id());
        untrack(child.id());

        let _ = terminate_all();
        let still_running = child
            .try_wait()
            .map_err(|error| fail("try_wait", error))?
            .is_none();
        let _ = child.kill();
        let _ = child.wait();

        ensure!(
            still_running,
            "a child no longer tracked must not be signalled"
        );
        Ok(())
    }
}
