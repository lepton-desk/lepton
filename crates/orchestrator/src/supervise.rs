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

use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

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

/// Sends SIGTERM to `pid`. Gone already is not an error: that is the outcome wanted.
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
fn alive(pid: u32) -> bool {
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
        let outcome = ctrlc::set_handler(|| {
            INTERRUPTED.store(true, std::sync::atomic::Ordering::SeqCst);
            let left = terminate_all();
            if left > 0 {
                eprintln!("lepton: {left} child process(es) did not exit within {GRACE:?}");
            }
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
    use super::{terminate_all, track, untrack};
    use crate::testing::{Failure, fail};
    use crate::{assert_eq, ensure};
    use std::os::unix::process::ExitStatusExt as _;
    use std::process::Command;
    use std::sync::{Mutex, PoisonError};

    /// The registry is process-wide, so tests that signal "every tracked child" would
    /// otherwise end each other's children when run in parallel.
    static SERIAL: Mutex<()> = Mutex::new(());

    #[test]
    fn a_tracked_child_is_ended_with_sigterm() -> Result<(), Failure> {
        let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        let mut child = Command::new("sleep")
            .arg("30")
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
        let mut child = Command::new("sleep")
            .arg("30")
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
