//! The platforms `lepton build` can target, and the Zig triple each is built with.

/// The platforms a build can target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Windows,
    MacOs,
}

impl Platform {
    /// This machine's platform, as Lepton names it.
    ///
    /// Read from the target's own OS rather than probed: it is a compile-time fact
    /// about the binary and nothing about the machine can change it. A function rather
    /// than a constant because matching on a string is not allowed in a `const`.
    pub fn host() -> Self {
        match std::env::consts::OS {
            "macos" => Self::MacOs,
            "windows" => Self::Windows,
            _ => Self::Linux,
        }
    }

    /// The Zig target triple for building this platform on another machine.
    ///
    /// Written out rather than looked up: a triple is a string with no API behind it,
    /// and a wrong one produces a linker error a long way from the mistake. `None` for
    /// the host, because a build for the machine doing the building does not name a
    /// target at all.
    pub fn cross_triple(self) -> Option<&'static str> {
        if self == Self::host() {
            return None;
        }

        Some(match self {
            Self::Linux => "x86_64-linux-gnu",
            Self::Windows => "x86_64-windows-gnu",
            Self::MacOs => "aarch64-macos",
        })
    }

    /// The `-Dtarget` a core build for this platform passes.
    ///
    /// Linux and macOS: only from another machine. Naming the host's own triple turns a
    /// native build into a cross-compile, and a cross-compile does not consult
    /// pkg-config: the display libraries the core was just probed for stop being
    /// findable, and the failure names `-lxcb-randr` rather than the flag that caused it.
    ///
    /// Windows: always, with the oldest Windows the program is for. Zig's native target
    /// there is the building machine's own version, and the standard library chooses code
    /// by it: on Windows 11 24H2 the program carried unix-socket support (Windows 10 1803
    /// and later) and was 68 096 bytes larger than the same app built from Linux
    /// (measured: 1 307 136 against 1 239 040 bytes, the same split reproduced by
    /// cross-building for `win10_rs4` and `win10_rs3`). A web view needs WebView2, so
    /// Windows 10; a native app keeps Windows 7 SP1 in reach (`docs/plans/windows.md`).
    pub fn build_target(self, native: bool) -> Option<&'static str> {
        match self {
            Self::Windows if native => Some("x86_64-windows.win7-gnu"),
            Self::Windows => Some("x86_64-windows.win10-gnu"),
            _ => self.cross_triple(),
        }
    }

    /// The triple this platform is built with, host or not.
    ///
    /// For a message a developer reads and for `--dry-run`, where naming the host's
    /// triple is more useful than naming nothing even though the build itself does not
    /// pass one.
    pub fn describe(self) -> String {
        match self.cross_triple() {
            Some(triple) => triple.to_string(),
            // Said rather than left blank: an empty target column in a dry run reads as
            // a bug in the tool rather than as "this machine".
            None => format!("{} (this machine)", self.zig_triple()),
        }
    }

    /// The triple this platform is built with, host or not.
    fn zig_triple(self) -> &'static str {
        match self {
            Self::Linux => "x86_64-linux-gnu",
            Self::Windows => "x86_64-windows-gnu",
            Self::MacOs => "aarch64-macos",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Platform;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};

    #[test]
    fn each_platform_names_its_own_triple() -> Result<(), Failure> {
        // A triple is a plain string with no API behind it, so these three are
        // asserted rather than trusted.
        assert_eq!(Platform::Linux.zig_triple(), "x86_64-linux-gnu");
        assert_eq!(Platform::Windows.zig_triple(), "x86_64-windows-gnu");
        assert_eq!(Platform::MacOs.zig_triple(), "aarch64-macos");
        Ok(())
    }

    #[test]
    fn a_build_for_this_machine_names_no_target() -> Result<(), Failure> {
        // The failure this guards is invisible until the linker runs: naming the
        // host's own triple makes Zig cross-compile, and a cross-compile does not
        // consult pkg-config, so the display libraries the core just probed for stop
        // being findable and the error names `-lxcb-randr` instead of the flag.
        ensure!(
            Platform::host().cross_triple().is_none(),
            "the host should not be given a triple"
        );

        for platform in [Platform::Linux, Platform::Windows, Platform::MacOs] {
            if platform != Platform::host() {
                ensure!(
                    platform.cross_triple().is_some(),
                    "{platform:?} is not the host and needs a triple"
                );
            }
        }
        Ok(())
    }
}
