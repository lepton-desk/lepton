//! The panel's arithmetic, run for real.
//!
//! `measures.ts` is the one place every frontend formats a measurement, and the
//! JavaScript a project receives is generated from it. These tests execute that
//! generated `assets/js/measures.js` in Node — the same bytes a JavaScript project
//! ships — and compare against figures measured on a running Lepton process.
//!
//! Written after the panel showed a 67.4 MiB process as "672.0 MiB" and a 1.9 µs round
//! trip as "19.0 µs": `trim` divided hundredths by ten. A Rust-side reimplementation
//! would have tested a copy; this tests the code.

use std::path::PathBuf;
use std::process::Command;

use lepton_orchestrator::testing::{Failure, fail};

/// Runs `body` as an ES module with `m` bound to the generated `measures.js`, and returns
/// what it printed.
fn run_measures(body: &str) -> Result<String, Failure> {
    let module = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/js/measures.js");
    let script = format!(
        "const m = await import({:?});\n{body}",
        format!("file://{}", module.display())
    );
    let output = Command::new("node")
        .args(["--input-type=module", "-e", &script])
        .output()
        .map_err(|error| fail("node runs (it is a development requirement)", error))?;
    if !output.status.success() {
        return Err(fail(
            "the generated module evaluates",
            String::from_utf8_lossy(&output.stderr),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn check(expression: &str, expected: &str) -> Result<(), Failure> {
    let got = run_measures(&format!("console.log({expression});"))?;
    if got != expected {
        return Err(fail(format!("{expression} prints {expected}"), got));
    }
    Ok(())
}

#[test]
fn a_measured_resident_set_reads_at_its_real_size() -> Result<(), Failure> {
    // `ps` on the packaged webview app: VmRSS 69020 kB.
    check("m.bytes(70676480n)", "67.4 MiB")?;
    check("m.bytes(1024n)", "1 KiB")?;
    check("m.bytes(1536n)", "1.5 KiB")?;
    check("m.bytes(512n)", "512 B")
}

#[test]
fn durations_read_at_their_real_size() -> Result<(), Failure> {
    check("m.duration(9200000000n)", "9.2 s")?;
    check("m.duration(1900n)", "1.9 µs")?;
    check("m.duration(1000n)", "1 µs")?;
    check("m.duration(999n)", "999 ns")
}

#[test]
fn the_second_decimal_is_truncated_not_rounded() -> Result<(), Failure> {
    // 1.99 µs reads 1.9: a latency that reads high would hide a problem, one that reads
    // low by a hundredth hides nothing.
    check("m.duration(1999n)", "1.9 µs")
}
