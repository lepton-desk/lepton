//! Waiting for the dev server before the window opens.
//!
//! The core loads its page from the server the moment its window exists. `lepton dev` used
//! to start the window as soon as the core was built, and with a cached core (385 ms) the
//! window asked Astro 7 before it listened: the load failed, the page stayed at origin
//! `null`, and every call to the core was refused by CORS for the rest of the session
//! (measured 2026-10-19). Vite usually won that race only because the core build was slower.

use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

use super::CliError;

/// How long a server may take to listen. Next.js and Angular compile before they listen;
/// on the reference machine (i3-2120) none took more than a few seconds.
pub const LIMIT: Duration = Duration::from_secs(90);

/// Between two attempts to connect.
const PAUSE: Duration = Duration::from_millis(100);

/// Returns once something accepts a connection at `address`, or fails with why not.
///
/// `exited` reports a server that has already ended (its status, as text), so a server
/// that stopped — a taken port, a syntax error in its configuration — is named at once
/// rather than after the whole limit.
pub fn wait_for(
    address: SocketAddr,
    limit: Duration,
    mut exited: impl FnMut() -> Option<String>,
) -> Result<Duration, CliError> {
    let began = Instant::now();
    loop {
        if TcpStream::connect_timeout(&address, PAUSE).is_ok() {
            return Ok(began.elapsed());
        }
        if let Some(status) = exited() {
            return Err(CliError::Invalid(format!(
                "the dev server ended ({status}) before listening on {address}; its output is above"
            )));
        }
        if began.elapsed() >= limit {
            return Err(CliError::Invalid(format!(
                "the dev server did not listen on {address} within {} s; check `frontend.devArgs` in lepton.config.json",
                limit.as_secs()
            )));
        }
        std::thread::sleep(PAUSE);
    }
}

#[cfg(test)]
mod tests {
    use super::wait_for;
    use lepton_orchestrator::testing::{Failure, fail};
    use lepton_orchestrator::{assert_contains, assert_err, assert_ok, ensure};
    use std::net::{SocketAddr, TcpListener};
    use std::time::Duration;

    /// A port nothing listens on: bound, read, and released.
    fn free_address() -> Result<SocketAddr, Failure> {
        let listener =
            TcpListener::bind("127.0.0.1:0").map_err(|error| fail("a local socket", error))?;
        listener
            .local_addr()
            .map_err(|error| fail("a local socket", error))
    }

    #[test]
    fn a_listening_server_is_found_at_once() -> Result<(), Failure> {
        let listener =
            TcpListener::bind("127.0.0.1:0").map_err(|error| fail("a local socket", error))?;
        let address = listener
            .local_addr()
            .map_err(|error| fail("a local socket", error))?;
        let waited = assert_ok!(
            wait_for(address, Duration::from_secs(5), || None),
            "listening"
        );
        ensure!(waited < Duration::from_secs(1), "took {waited:?}");
        Ok(())
    }

    #[test]
    fn a_server_that_listens_late_is_waited_for() -> Result<(), Failure> {
        let address = free_address()?;
        let late = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(400));
            let listener = TcpListener::bind(address).ok();
            std::thread::sleep(Duration::from_secs(2));
            drop(listener);
        });
        let waited = assert_ok!(wait_for(address, Duration::from_secs(10), || None), "late");
        ensure!(
            waited >= Duration::from_millis(300),
            "returned before the server: {waited:?}"
        );
        late.join()
            .map_err(|_| fail("the listening thread", "panicked"))?;
        Ok(())
    }

    #[test]
    fn a_server_that_ended_is_reported_without_waiting_out_the_limit() -> Result<(), Failure> {
        let address = free_address()?;
        let began = std::time::Instant::now();
        let error = assert_err!(
            wait_for(address, Duration::from_secs(60), || Some(String::from(
                "exit status: 1"
            ))),
            "ended"
        );
        assert_contains!(&error.to_string(), "ended (exit status: 1)");
        ensure!(
            began.elapsed() < Duration::from_secs(5),
            "waited {:?}",
            began.elapsed()
        );
        Ok(())
    }

    #[test]
    fn a_server_that_never_listens_fails_at_the_limit() -> Result<(), Failure> {
        let address = free_address()?;
        let error = assert_err!(
            wait_for(address, Duration::from_millis(300), || None),
            "never"
        );
        assert_contains!(&error.to_string(), "frontend.devArgs");
        Ok(())
    }
}
