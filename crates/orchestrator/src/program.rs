//! The file a program name starts.
//!
//! On Windows `Command::new("npm")` looks only for `npm.exe`, and Node's own installer
//! gives npm as `npm.cmd` — as is pnpm when npm installs it. A runner with a plain
//! Node install had `lepton new` stop with "`npm` is not found on PATH" while npm was
//! there (measured, `windows-2025`); a machine whose npm is an `.exe` shim never showed
//! it. So a bare name is looked up on `PATH` the way the shell does, by `PATHEXT`
//! order, and the program is started by its full path: Rust runs a `.cmd` given that
//! way through `cmd.exe`, quoting its arguments for it.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// The extensions `cmd.exe` tries for a bare name when `PATHEXT` is not set.
const DEFAULT_EXTENSIONS: &str = ".COM;.EXE;.BAT;.CMD";

/// What to start for `name` on this machine: the name itself off Windows.
pub fn resolve(name: &str) -> OsString {
    resolve_in(
        name,
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("PATHEXT").as_deref(),
        cfg!(windows),
    )
}

/// [`resolve`] against the given `PATH` and `PATHEXT`, as Windows would when `windows`.
///
/// A name with a directory or an extension is used as written; a name found nowhere
/// is returned unchanged, so starting it fails as "not found" and says so.
pub fn resolve_in(
    name: &str,
    path: Option<&OsStr>,
    extensions: Option<&OsStr>,
    windows: bool,
) -> OsString {
    let written = Path::new(name);
    if !windows || written.components().count() != 1 || written.extension().is_some() {
        return OsString::from(name);
    }
    let extensions = extensions
        .and_then(OsStr::to_str)
        .filter(|list| !list.trim().is_empty())
        .unwrap_or(DEFAULT_EXTENSIONS);
    let Some(path) = path else {
        return OsString::from(name);
    };
    for dir in std::env::split_paths(path) {
        for extension in extensions.split(';').filter(|item| item.starts_with('.')) {
            let candidate: PathBuf = dir.join(format!("{name}{}", extension.to_lowercase()));
            if candidate.is_file() {
                return candidate.into_os_string();
            }
        }
    }
    OsString::from(name)
}

#[cfg(test)]
mod tests {
    use super::resolve_in;
    use crate::testing::{Failure, Scratch};
    use crate::{assert_eq, ensure};
    use std::ffi::OsString;

    fn path_of(dirs: &[&std::path::Path]) -> Result<OsString, Failure> {
        std::env::join_paths(dirs).map_err(|error| crate::testing::fail("join PATH", error))
    }

    #[test]
    fn a_cmd_tool_is_found_by_its_full_path_on_windows() -> Result<(), Failure> {
        let scratch = Scratch::new("program-cmd")?;
        scratch.write("node/npm.cmd", "@echo off\r\n")?;
        let path = path_of(&[&scratch.path().join("empty"), &scratch.path().join("node")])?;
        let found = resolve_in(
            "npm",
            Some(&path),
            Some(".COM;.EXE;.BAT;.CMD".as_ref()),
            true,
        );
        assert_eq!(
            found,
            scratch.path().join("node").join("npm.cmd").into_os_string()
        );
        Ok(())
    }

    #[test]
    fn an_exe_comes_before_a_cmd_as_pathext_orders_them() -> Result<(), Failure> {
        let scratch = Scratch::new("program-order")?;
        scratch.write("bin/pnpm.cmd", "@echo off\r\n")?;
        scratch.write("bin/pnpm.exe", "MZ")?;
        let path = path_of(&[&scratch.path().join("bin")])?;
        let found = resolve_in("pnpm", Some(&path), None, true);
        assert_eq!(
            found,
            scratch.path().join("bin").join("pnpm.exe").into_os_string()
        );
        Ok(())
    }

    #[test]
    fn a_written_path_an_extension_a_missing_tool_and_unix_are_left_alone() -> Result<(), Failure> {
        let scratch = Scratch::new("program-alone")?;
        scratch.write("bin/npm.cmd", "@echo off\r\n")?;
        let path = path_of(&[&scratch.path().join("bin")])?;
        for name in ["npm.exe", "nothing-here", "./npm"] {
            assert_eq!(
                resolve_in(name, Some(&path), None, true),
                OsString::from(name)
            );
        }
        ensure!(
            resolve_in("npm", Some(&path), None, false) == "npm",
            "off Windows the name is started as written"
        );
        Ok(())
    }
}
