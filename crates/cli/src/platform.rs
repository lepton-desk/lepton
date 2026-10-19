//! What differs between the systems `lepton` runs on, in one place.
//!
//! The commands are the same on Linux and Windows; the facts under them are not — where
//! the user's home is, what an executable is called, what isolates an application's data
//! for a replay, which package formats a build can be, how a graphical session is known.
//! Each answer lives here, decided at compile time from the target the CLI was built for,
//! so a command reads one function instead of carrying its own `cfg!`.

use std::path::{Path, PathBuf};

/// The user's home directory: `HOME` on Linux, `USERPROFILE` on Windows.
pub fn home() -> Option<PathBuf> {
    let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(variable)
        .filter(|value| value.len() > 1)
        .map(PathBuf::from)
}

/// `binary` as the file the build installs: `<binary>.exe` on Windows.
pub fn executable(binary: &str) -> String {
    format!("{binary}{}", std::env::consts::EXE_SUFFIX)
}

/// The system name in a bundle's file name: `linux`, `windows`.
pub fn bundle_os() -> &'static str {
    std::env::consts::OS
}

/// Whether a window can open here; the reason when it cannot.
///
/// Linux: a Wayland or X11 session announces itself in the environment. Windows: an
/// interactive desktop is always there for a signed-in user.
pub fn graphical_session() -> Result<(), &'static str> {
    if cfg!(windows)
        || std::env::var_os("WAYLAND_DISPLAY").is_some()
        || std::env::var_os("DISPLAY").is_some()
    {
        Ok(())
    } else {
        Err("needs a graphical session (WAYLAND_DISPLAY or DISPLAY)")
    }
}

/// The variables that put every directory an application could write to inside `home`,
/// for `lepton replay`.
///
/// Linux: `HOME` and the XDG base directories. Windows: the profile and its two
/// application-data folders — the core keeps WebView2's data in `%LOCALAPPDATA%\<id>`,
/// so a replay without these would write into the user's real profile.
pub fn isolated_home(home: &Path) -> Vec<(&'static str, String)> {
    let at = |name: &str| home.join(name).display().to_string();
    if cfg!(windows) {
        vec![
            ("USERPROFILE", home.display().to_string()),
            ("APPDATA", at(r"AppData\Roaming")),
            ("LOCALAPPDATA", at(r"AppData\Local")),
        ]
    } else {
        vec![
            ("HOME", home.display().to_string()),
            ("XDG_DATA_HOME", at(".local/share")),
            ("XDG_CONFIG_HOME", at(".config")),
            ("XDG_CACHE_HOME", at(".cache")),
            ("XDG_STATE_HOME", at(".local/state")),
        ]
    }
}

/// The directories [`isolated_home`] names, made so the application finds them.
pub fn isolated_directories(home: &Path) -> Vec<PathBuf> {
    isolated_home(home)
        .into_iter()
        .map(|(_, path)| PathBuf::from(path))
        .collect()
}

/// Whether this system's build can be packaged as `target`: the Arch and Debian formats
/// carry a Linux build and are refused elsewhere, as the MSI (a Windows build) is off
/// Windows.
pub fn packages_as(target: lepton_template_injector::BundleTarget) -> Result<(), String> {
    if target.windows_only() && !cfg!(windows) {
        return Err(format!(
            "\"{}\" installs a Windows build and this is {}; package it on Windows",
            target.name(),
            std::env::consts::OS
        ));
    }
    if target.linux_only() && !cfg!(target_os = "linux") {
        return Err(format!(
            "\"{}\" is a Linux package and this is {}; list \"zip\" in \"bundle.targets\" here",
            target.name(),
            std::env::consts::OS
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{executable, isolated_home, packages_as};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};
    use lepton_template_injector::BundleTarget;
    use std::path::Path;

    #[test]
    fn the_executable_carries_this_systems_suffix() -> Result<(), Failure> {
        let expected = if cfg!(windows) { "notes.exe" } else { "notes" };
        assert_eq!(executable("notes"), expected);
        Ok(())
    }

    #[test]
    fn a_replay_home_moves_every_writable_directory() -> Result<(), Failure> {
        let home = Path::new("replay-home");
        let variables = isolated_home(home);
        let names: Vec<&str> = variables.iter().map(|(name, _)| *name).collect();
        let needed: &[&str] = if cfg!(windows) {
            &["USERPROFILE", "APPDATA", "LOCALAPPDATA"]
        } else {
            &["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]
        };
        for name in needed {
            ensure!(names.contains(name), "{name} must be moved: {names:?}");
        }
        for (name, value) in &variables {
            ensure!(
                value.starts_with("replay-home"),
                "{name} left the replay home: {value}"
            );
        }
        Ok(())
    }

    #[test]
    fn linux_packages_are_refused_off_linux() -> Result<(), Failure> {
        ensure!(
            packages_as(BundleTarget::Zip).is_ok(),
            "a zip is made anywhere"
        );
        ensure!(
            packages_as(BundleTarget::TarGz).is_ok(),
            "a tarball is made anywhere"
        );
        let deb = packages_as(BundleTarget::Deb);
        ensure!(
            deb.is_ok() == cfg!(target_os = "linux"),
            "a .deb only on Linux: {deb:?}"
        );
        let msi = packages_as(BundleTarget::Msi);
        ensure!(
            msi.is_ok() == cfg!(windows),
            "an .msi only on Windows: {msi:?}"
        );
        Ok(())
    }
}
