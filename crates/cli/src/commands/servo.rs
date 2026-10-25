//! Where `--servo` finds Servo.
//!
//! Servo renders through `liblepton_servo.so`, the bridge built from `servo/bridge` in
//! the Lepton repository (in CI: Servo's ~750 crates take about 11 minutes there, far
//! longer on a small machine). A build with `--servo` links the core to it
//! (`-Dservo-lib=<dir>`, `zig/src/build_servo.zig`). The library comes with the npm
//! package `@lepton-desk/servo-linux-x64` (CI builds it; `tools/stage-servo.mjs` puts it in),
//! installed as a dev dependency of the project; `LEPTON_SERVO_LIB` names another directory.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use super::CliError;

/// The library a Servo build links.
pub const LIBRARY: &str = "liblepton_servo.so";

/// Libraries [`LIBRARY`] opens at run time (`dlopen`), which no `DT_NEEDED` names: surfman's
/// EGL (measured with `LD_DEBUG=files` on a packaged app). A package carrying Servo
/// depends on them too.
pub const LOADED: [&str; 1] = ["libEGL.so.1"];

/// The variable naming the directory that holds [`LIBRARY`].
pub const ENV: &str = "LEPTON_SERVO_LIB";

/// Where the npm platform package will put it, inside a project.
pub const PACKAGE_DIR: &str = "node_modules/@lepton-desk/servo-linux-x64/lib";

/// `--servo` is Linux's: Servo is built for linux-x64 only.
pub fn require_linux() -> Result<(), CliError> {
    if cfg!(target_os = "linux") {
        Ok(())
    } else {
        Err(CliError::Invalid(
            "--servo: Servo is built for Linux only for now".to_owned(),
        ))
    }
}

/// `lepton package --servo` needs the project's build file to install Servo's library
/// beside the binary (`-Dservo-bundle`); an older one is refused before anything builds.
pub fn require_bundle_option(root: &Path) -> Result<(), CliError> {
    let path = root.join(super::build::CORE_DIR).join("build.zig");
    let text = std::fs::read_to_string(&path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;
    if text.contains("\"servo-bundle\"") {
        return Ok(());
    }
    Err(CliError::Invalid(format!(
        "--servo: {} cannot put Servo into a package yet; run `lepton update` first",
        path.display()
    )))
}

/// Puts the libraries a package carries beside its binary: each `DT_NEEDED` library the
/// build installed in `<prefix>/lib/<binary>/` (Servo's) goes to `<bundle>/lib/<binary>/`.
///
/// Refuses a binary that looks for libraries in an absolute directory: a development
/// build records where it linked Servo from (the project's `node_modules`), so its package
/// would start only on the machine that built it. `--no-build` after `lepton build
/// --servo` lays out exactly that binary, hence the check on every Linux package.
pub fn carry(prefix: &Path, binary: &str, bundle: &Path) -> Result<(), CliError> {
    let program = bundle.join("bin").join(binary);
    let outside: Vec<String> = super::depends::search_path(&program)?
        .into_iter()
        .filter(|dir| !dir.starts_with("$ORIGIN"))
        .collect();
    if !outside.is_empty() {
        return Err(CliError::Invalid(format!(
            "{binary} looks for libraries in {}, which only this machine has; package a Servo build with `lepton package --linux --servo`",
            outside.join(":")
        )));
    }
    let from = prefix.join("lib").join(binary);
    let to = bundle.join("lib").join(binary);
    for name in super::depends::needed(&program)? {
        let library = from.join(&name);
        if !library.is_file() {
            if name == LIBRARY {
                return Err(CliError::Invalid(format!(
                    "{binary} needs {LIBRARY}, and the build did not install it in {}; package with `lepton package --linux --servo`",
                    from.display()
                )));
            }
            continue;
        }
        std::fs::create_dir_all(&to).map_err(|error| {
            CliError::Invalid(format!("could not create {}: {error}", to.display()))
        })?;
        std::fs::copy(&library, to.join(&name)).map_err(|error| {
            CliError::Invalid(format!("could not copy {}: {error}", library.display()))
        })?;
    }
    Ok(())
}

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
        "--servo: no {LIBRARY} found. Servo is experimental; install its library with \
         `npm install -D @lepton-desk/servo-linux-x64@{version}` (or pnpm add -D), or set {ENV} \
         to a directory that holds one built from servo/bridge.",
        version = env!("CARGO_PKG_VERSION")
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
    use super::{LIBRARY, PACKAGE_DIR, carry, find, require_bundle_option};
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
            Err(error) => assert_contains!(
                &error.to_string(),
                "npm install -D @lepton-desk/servo-linux-x64@"
            ),
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

    #[test]
    fn a_servo_package_needs_a_build_file_that_carries_the_library() -> Result<(), Failure> {
        let scratch = assert_ok!(Scratch::new("servo-bundle-option"), "scratch");
        scratch.write(
            "src-lepton/build.zig",
            "b.option([]const u8, \"servo-lib\", \"\")\n",
        )?;
        match require_bundle_option(scratch.path()) {
            Err(error) => assert_contains!(&error.to_string(), "lepton update"),
            Ok(()) => {
                return Err(Failure {
                    claim: "a build file without servo-bundle is refused".into(),
                    actual: "accepted".into(),
                });
            }
        }
        scratch.write(
            "src-lepton/build.zig",
            "b.option(bool, \"servo-bundle\", \"\")\n",
        )?;
        assert_ok!(require_bundle_option(scratch.path()), "accepted");
        Ok(())
    }

    #[test]
    fn a_library_the_build_installed_goes_beside_the_binary() -> Result<(), Failure> {
        // The test binary needs libc: a copy under the build's `lib/<name>/` stands in for
        // Servo's library. Libraries the build did not install stay the system's.
        let scratch = assert_ok!(Scratch::new("servo-carry"), "scratch");
        let exe = std::env::current_exe()
            .map_err(|error| lepton_orchestrator::testing::fail("exe", error))?;
        let Some(libc) = super::super::depends::locate("libc.so.6") else {
            return Err(lepton_orchestrator::testing::fail("libc.so.6", "not found"));
        };
        let copy = |from: &std::path::Path, to: std::path::PathBuf| -> Result<(), Failure> {
            if let Some(dir) = to.parent() {
                std::fs::create_dir_all(dir)
                    .map_err(|error| lepton_orchestrator::testing::fail("mkdir", error))?;
            }
            std::fs::copy(from, &to)
                .map(|_| ())
                .map_err(|error| lepton_orchestrator::testing::fail("copy", error))
        };
        copy(&exe, scratch.path().join("bundle/bin/notes"))?;
        copy(&libc, scratch.path().join("zig-out/lib/notes/libc.so.6"))?;
        assert_ok!(
            carry(
                &scratch.path().join("zig-out"),
                "notes",
                &scratch.path().join("bundle")
            ),
            "carried"
        );
        ensure!(
            scratch.path().join("bundle/lib/notes/libc.so.6").is_file(),
            "libc beside the binary"
        );
        Ok(())
    }
}
