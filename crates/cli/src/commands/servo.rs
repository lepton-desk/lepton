//! Where `--servo` finds Servo.
//!
//! Servo renders through `liblepton_servo.so`, the bridge built from `servo/bridge` in
//! the Lepton repository (in CI: Servo's ~750 crates take about 11 minutes there, far
//! longer on a small machine). A build with `--servo` links the core to it
//! (`-Dservo-lib=<dir>`, `zig/src/build_servo.zig`). Until the library is published as
//! `@lepton-desk/servo-linux-x64`, its directory is named with `LEPTON_SERVO_LIB`.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use super::CliError;

/// The library a Servo build links.
pub const LIBRARY: &str = "liblepton_servo.so";

/// The variable naming the directory that holds [`LIBRARY`].
pub const ENV: &str = "LEPTON_SERVO_LIB";

/// Where the npm platform package will put it, inside a project.
pub const PACKAGE_DIR: &str = "node_modules/@lepton-desk/servo-linux-x64/lib";

/// The directory holding the library for the project at `root`, from the environment.
pub fn library(root: &Path) -> Result<PathBuf, CliError> {
    find(root, std::env::var_os(ENV).as_deref())
}

/// The directory holding the library: `explicit` (the variable's value) when given,
/// otherwise the platform package's. Absolute, because the core's rpath records it.
pub fn find(root: &Path, explicit: Option<&OsStr>) -> Result<PathBuf, CliError> {
    if let Some(dir) = explicit.filter(|value| !value.is_empty()) {
        let dir = absolute(root, Path::new(dir));
        if dir.join(LIBRARY).is_file() {
            return Ok(dir);
        }
        return Err(CliError::Invalid(format!(
            "--servo: {ENV} is {}, which has no {LIBRARY}",
            dir.display()
        )));
    }
    let packaged = root.join(PACKAGE_DIR);
    if packaged.join(LIBRARY).is_file() {
        return Ok(absolute(root, &packaged));
    }
    Err(CliError::Invalid(format!(
        "--servo: no {LIBRARY} found. Servo is experimental and its library is not published \
         yet: build it from servo/bridge in the Lepton repository (`cargo build --release`) \
         and set {ENV} to the directory that holds it."
    )))
}

fn absolute(root: &Path, dir: &Path) -> PathBuf {
    let joined = if dir.is_absolute() {
        dir.to_path_buf()
    } else {
        root.join(dir)
    };
    joined.canonicalize().unwrap_or(joined)
}

#[cfg(test)]
mod tests {
    use super::{LIBRARY, PACKAGE_DIR, find};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_ok, ensure};
    use std::ffi::OsStr;

    #[test]
    fn the_variable_names_a_directory_that_must_hold_the_library() -> Result<(), Failure> {
        let scratch = assert_ok!(Scratch::new("servo-lib-env"), "scratch");
        scratch.write("lib/placeholder", "")?;
        let empty = find(scratch.path(), Some(OsStr::new("lib")));
        match empty {
            Err(error) => assert_contains!(&error.to_string(), "has no liblepton_servo.so"),
            Ok(dir) => {
                return Err(Failure {
                    claim: "a directory without the library is refused".into(),
                    actual: dir.display().to_string(),
                });
            }
        }
        scratch.write(&format!("lib/{LIBRARY}"), "")?;
        let found = assert_ok!(find(scratch.path(), Some(OsStr::new("lib"))), "found");
        ensure!(
            found.is_absolute() && found.join(LIBRARY).is_file(),
            "absolute: {found:?}"
        );
        Ok(())
    }

    #[test]
    fn without_the_variable_the_platform_package_is_used_or_the_reason_given() -> Result<(), Failure>
    {
        let scratch = assert_ok!(Scratch::new("servo-lib-package"), "scratch");
        match find(scratch.path(), None) {
            Err(error) => assert_contains!(&error.to_string(), "not published yet"),
            Ok(dir) => {
                return Err(Failure {
                    claim: "no library anywhere is refused with the reason".into(),
                    actual: dir.display().to_string(),
                });
            }
        }
        scratch.write(&format!("{PACKAGE_DIR}/{LIBRARY}"), "")?;
        let found = assert_ok!(find(scratch.path(), None), "found in the package");
        ensure!(
            found.ends_with("lib"),
            "the package's lib directory: {found:?}"
        );
        Ok(())
    }
}
