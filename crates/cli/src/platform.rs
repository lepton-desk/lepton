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

/// The system a build is for — this one unless `--windows`/`--linux` named another.
/// What a package holds follows it, not the machine writing the package.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum System {
    Linux,
    Windows,
}

impl System {
    /// The system `lepton` itself runs on.
    pub fn host() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    /// `binary` as the file a build for this system installs: `<binary>.exe` on Windows.
    pub fn executable(self, binary: &str) -> String {
        match self {
            Self::Windows => format!("{binary}.exe"),
            Self::Linux => binary.to_owned(),
        }
    }

    /// The system name in a bundle's file name: `linux`, `windows`.
    pub fn bundle_os(self) -> &'static str {
        match self {
            Self::Windows => "windows",
            Self::Linux => "linux",
        }
    }
}

/// Why a native build for Windows is refused. The core's native path is Linux's window
/// layer (Wayland, X11) and EGL; the Windows one is being written, and until it runs a
/// native project made or built there would fail deep inside `zig build`.
pub const NATIVE_ON_WINDOWS: &str = "the native render path does not run on Windows yet (it is \
     being built: a Win32 window with DirectWrite text); use the webview path, WebView2: \
     \"renderPath\": \"webview\" in lepton.config.json, or --webview";

/// Whether a build for `system` can take the native render path; the reason when not.
pub fn native_path(system: System) -> Result<(), &'static str> {
    match system {
        System::Linux => Ok(()),
        System::Windows => Err(NATIVE_ON_WINDOWS),
    }
}

/// `binary` as the file the build installs here: `<binary>.exe` on Windows.
pub fn executable(binary: &str) -> String {
    System::host().executable(binary)
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

/// Whether a build for `system` can be packaged as `target` on this machine.
///
/// The MSI carries a Windows build: written for one wherever it is packaged — its writer
/// is plain Rust (`installer_db.rs` on `cfb` and `cab`), so Linux writes the same file
/// (`lepton package --windows`). The Arch and Debian formats carry a Linux build, and
/// their dependencies are asked of this machine's `pacman`/`dpkg-query`: only on Linux,
/// for Linux.
pub fn packages_as(
    target: lepton_template_injector::BundleTarget,
    system: System,
) -> Result<(), String> {
    if target.windows_only() && system != System::Windows {
        return Err(format!(
            "\"{}\" installs a Windows build and this build is for {}; package with --windows",
            target.name(),
            system.bundle_os()
        ));
    }
    if target.linux_only() && (system != System::Linux || !cfg!(target_os = "linux")) {
        return Err(format!(
            "\"{}\" is a Linux package, made on Linux for a Linux build; list \"zip\" in \"bundle.targets\" for {}",
            target.name(),
            system.bundle_os()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{System, executable, isolated_home, native_path, packages_as};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, ensure};
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
        for system in [System::Linux, System::Windows] {
            ensure!(
                packages_as(BundleTarget::Zip, system).is_ok(),
                "a zip is made anywhere"
            );
        }
        ensure!(
            packages_as(BundleTarget::TarGz, System::host()).is_ok(),
            "a tarball is made anywhere"
        );
        let deb = packages_as(BundleTarget::Deb, System::host());
        ensure!(
            deb.is_ok() == cfg!(target_os = "linux"),
            "a .deb only on Linux: {deb:?}"
        );
        let windows_deb = packages_as(BundleTarget::Deb, System::Windows);
        ensure!(windows_deb.is_err(), "a .deb never holds a Windows build");
        Ok(())
    }

    #[test]
    fn an_msi_is_written_for_a_windows_build_on_any_machine() -> Result<(), Failure> {
        ensure!(
            packages_as(BundleTarget::Msi, System::Windows).is_ok(),
            "Linux writes the same MSI for a --windows build"
        );
        let linux = assert_err!(
            packages_as(BundleTarget::Msi, System::Linux),
            "an MSI of a Linux build"
        );
        assert_contains!(&linux, "--windows");
        Ok(())
    }

    #[test]
    fn the_native_path_is_linux_only_for_now_and_says_what_to_use() -> Result<(), Failure> {
        ensure!(native_path(System::Linux).is_ok(), "Linux draws natively");
        let windows = assert_err!(native_path(System::Windows), "not on Windows yet");
        assert_contains!(&windows, "webview");
        Ok(())
    }

    #[test]
    fn a_build_names_its_own_system_not_the_hosts() -> Result<(), Failure> {
        assert_eq!(System::Windows.executable("notes"), "notes.exe");
        assert_eq!(System::Linux.executable("notes"), "notes");
        assert_eq!(System::Windows.bundle_os(), "windows");
        assert_eq!(System::Linux.bundle_os(), "linux");
        Ok(())
    }
}
