//! The web engine on this machine, and how to get it when it is missing.
//!
//! Read the way the core's build reads it (`zig/build.zig`), so `lepton info` and a
//! webview build cannot disagree: WPE WebKit through its WPEPlatform API (stable and on
//! by default since 2.54), or through the older libwpe API when the engine was built with
//! it and libwpe with WPEBackend-fdo is installed. Arch builds WebKit without the libwpe
//! API and no longer packages libwpe or WPEBackend-fdo, so neither is asked for on the
//! platform path (they were, and a fresh Arch install could not build a webview app).
//!
//! When the engine is missing, the distribution's own package manager is asked what it
//! can install, rather than this file remembering versions that go stale: on 2026-10-17
//! Arch and openSUSE Tumbleweed carried 2.54.1, Debian 2.54.1 only in testing and
//! unstable (trixie 2.48.3), Ubuntu nothing after 22.04, and Fedora had retired the
//! package.
//!
//! On Windows the engine is WebView2: the runtime Windows installs, found where the core
//! finds it (`EdgeUpdate\ClientState\{F3017226-…}` → `EBWebView`, machine-wide then
//! per-user; `zig/src/render/webview/webview2/runtime.zig`), read with `reg query`.

use std::process::Command;

/// The WebView2 runtime's registry keys (stable channel): machine-wide, then per-user.
const WEBVIEW2_KEYS: [&str; 2] = [
    r"HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    r"HKCU\Software\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
];

/// Where Microsoft hands out the Evergreen runtime.
const WEBVIEW2_DOWNLOAD: &str = "https://developer.microsoft.com/microsoft-edge/webview2/";

/// The version WPEPlatform became stable in, which the core's platform path is written for.
const MINIMUM: (u32, u32) = (2, 54);

/// What a webview build on this machine would find.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Engine {
    /// `pkg-config --modversion wpe-webkit-2.0`, when it answers.
    pub webkit: Option<String>,
    /// `wpe-platform-2.0`: the API the core uses whenever it is there.
    pub platform: bool,
    /// The engine was built with its libwpe API and libwpe with its backend is installed.
    pub legacy: bool,
    pub cairo: bool,
    pub xcb: bool,
    /// Windows: the WebView2 runtime's version, when one is installed.
    pub webview2: Option<String>,
}

impl Engine {
    /// Reads this machine.
    pub fn probe() -> Self {
        if cfg!(windows) {
            return Self {
                webkit: None,
                platform: false,
                legacy: false,
                cairo: false,
                xcb: false,
                webview2: webview2_version(),
            };
        }
        let webkit =
            pkg_config(&["--modversion", "wpe-webkit-2.0"]).map(|out| out.trim().to_owned());
        let legacy = webkit.is_some()
            && pkg_config(&["--print-requires", "wpe-webkit-2.0"]).is_some_and(|out| {
                out.lines()
                    .any(|line| line.split_whitespace().next() == Some("wpe-1.0"))
            })
            && exists("wpe-1.0")
            && exists("wpebackend-fdo-1.0");
        Self {
            platform: webkit.is_some() && exists("wpe-platform-2.0"),
            webkit,
            legacy,
            cairo: exists("cairo"),
            xcb: exists("xcb"),
            webview2: None,
        }
    }

    /// Whether a webview build can link here.
    pub fn ready(&self) -> bool {
        if cfg!(windows) {
            return self.webview2.is_some();
        }
        self.webkit.is_some() && (self.platform || self.legacy) && self.cairo && self.xcb
    }

    /// The rows `lepton info` prints, label then value.
    pub fn rows(&self) -> Vec<(&'static str, String)> {
        if cfg!(windows) {
            return vec![(
                "WebView2",
                self.webview2
                    .clone()
                    .unwrap_or_else(|| String::from("not installed")),
            )];
        }
        let found = |present: bool, missing: &str| {
            if present {
                String::from("present")
            } else {
                format!("missing — {missing}")
            }
        };
        vec![
            (
                "WPE WebKit",
                self.webkit
                    .clone()
                    .unwrap_or_else(|| String::from("not installed")),
            ),
            (
                "engine API",
                match (self.platform, self.legacy) {
                    (true, _) => String::from("WPEPlatform"),
                    (false, true) => String::from("libwpe (older engine)"),
                    (false, false) if self.webkit.is_some() => {
                        String::from("missing — wpe-platform-2.0")
                    }
                    (false, false) => String::from("comes with WPE WebKit"),
                },
            ),
            ("type rasterisation", found(self.cairo, "cairo")),
            ("X11 windows", found(self.xcb, "xcb")),
        ]
    }

    /// The same facts as JSON fields, for `lepton info --json`.
    pub fn json(&self) -> String {
        format!(
            "{{\"webkit\": {}, \"platform\": {}, \"legacy\": {}, \"cairo\": {}, \"xcb\": {}, \"webview2\": {}, \"ready\": {}}}",
            self.webkit.as_deref().map_or_else(
                || String::from("null"),
                lepton_template_injector::manifest::json_string
            ),
            self.platform,
            self.legacy,
            self.cairo,
            self.xcb,
            self.webview2.as_deref().map_or_else(
                || String::from("null"),
                lepton_template_injector::manifest::json_string
            ),
            self.ready()
        )
    }
}

/// A distribution's package manager, and what it offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    /// The distribution's name as it calls itself (`PRETTY_NAME`).
    pub system: String,
    /// The command that installs the engine, when the version offered is new enough.
    pub install: Option<Vec<String>>,
    /// What the package manager said it can install, e.g. `2.54.1-2`.
    pub version: Option<String>,
}

/// Which package manager a system uses, from `/etc/os-release`'s `ID` and `ID_LIKE`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Family {
    Arch,
    Debian,
    Fedora,
    Suse,
}

fn family(os_release: &str) -> Option<Family> {
    let field = |key: &str| {
        os_release
            .lines()
            .find_map(|line| {
                line.strip_prefix(key)
                    .and_then(|rest| rest.strip_prefix('='))
            })
            .map(|value| value.trim_matches('"').to_ascii_lowercase())
            .unwrap_or_default()
    };
    let names = format!("{} {}", field("ID"), field("ID_LIKE"));
    let has = |word: &str| names.split_whitespace().any(|name| name == word);
    if has("arch") || has("endeavouros") || has("manjaro") {
        Some(Family::Arch)
    } else if has("debian") || has("ubuntu") {
        Some(Family::Debian)
    } else if has("fedora") || has("rhel") {
        Some(Family::Fedora)
    } else if has("suse") || has("opensuse") || names.contains("opensuse") {
        Some(Family::Suse)
    } else {
        None
    }
}

impl Family {
    /// The development package carrying `wpe-webkit-2.0.pc` and `wpe-platform-2.0.pc`.
    fn package(self) -> &'static str {
        match self {
            Self::Arch => "wpewebkit",
            Self::Debian => "libwpewebkit-2.0-dev",
            Self::Fedora | Self::Suse => "wpewebkit-devel",
        }
    }

    /// Asks the package manager which version it would install, if any.
    fn available(self) -> Option<String> {
        let package = self.package();
        let (program, args): (&str, Vec<&str>) = match self {
            Self::Arch => ("pacman", vec!["-Si", package]),
            Self::Debian => ("apt-cache", vec!["policy", package]),
            Self::Fedora => (
                "dnf",
                vec!["-q", "repoquery", "--qf", "%{version}\n", package],
            ),
            Self::Suse => (
                "zypper",
                vec!["--non-interactive", "--no-refresh", "info", package],
            ),
        };
        let output = Command::new(program)
            .args(args)
            .env("LC_ALL", "C")
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let value = |prefix: &str| {
            text.lines().find_map(|line| {
                line.trim()
                    .strip_prefix(prefix)
                    .map(|rest| rest.trim_start_matches([' ', ':']).trim().to_owned())
            })
        };
        let version = match self {
            Self::Arch | Self::Suse => value("Version"),
            Self::Debian => value("Candidate").filter(|version| version != "(none)"),
            Self::Fedora => text
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .map(str::to_owned),
        };
        version.filter(|version| !version.is_empty())
    }

    fn install(self) -> Vec<String> {
        let words: &[&str] = match self {
            Self::Arch => &["sudo", "pacman", "-S", "--needed", "wpewebkit"],
            Self::Debian => &["sudo", "apt", "install", "libwpewebkit-2.0-dev"],
            Self::Fedora => &["sudo", "dnf", "install", "wpewebkit-devel"],
            Self::Suse => &["sudo", "zypper", "install", "wpewebkit-devel"],
        };
        words.iter().map(|word| (*word).to_owned()).collect()
    }
}

/// What this machine's distribution can do about a missing engine.
pub fn offer() -> Option<Offer> {
    let os_release = std::fs::read_to_string("/etc/os-release").ok()?;
    let family = family(&os_release)?;
    let system = os_release
        .lines()
        .find_map(|line| line.strip_prefix("PRETTY_NAME="))
        .map_or_else(
            || String::from("this system"),
            |name| name.trim_matches('"').to_owned(),
        );
    let version = family.available();
    let install = version
        .as_deref()
        .filter(|version| new_enough(version))
        .map(|_| family.install());
    Some(Offer {
        system,
        install,
        version,
    })
}

/// `2.54.1-2`, `2.54.1-1.1`, `1:2.54.1-1` → at least 2.54?
fn new_enough(version: &str) -> bool {
    let bare = version.rsplit(':').next().unwrap_or(version);
    let mut parts = bare
        .split(['.', '-', '+', '~'])
        .map(|part| part.parse::<u32>().ok());
    match (parts.next().flatten(), parts.next().flatten()) {
        (Some(major), Some(minor)) => (major, minor) >= MINIMUM,
        _ => false,
    }
}

/// The lines that say what to do, for `lepton info` and a blocked build alike: short,
/// with the one command to run when there is one, and the native path either way.
pub fn advice(offer: Option<&Offer>) -> Vec<String> {
    if cfg!(windows) {
        return vec![
            String::from("Install the WebView2 Runtime (Evergreen) from Microsoft:"),
            format!("  {WEBVIEW2_DOWNLOAD}"),
            String::from("Windows 11 and an up-to-date Windows 10 already have it."),
        ];
    }
    let native = String::from("Or leave the engine out for now: `--native` draws without one.");
    match offer {
        Some(Offer {
            install: Some(command),
            system,
            ..
        }) => vec![
            format!("{system} has it, one command away:"),
            format!("  {}", command.join(" ")),
            native,
        ],
        Some(Offer {
            system,
            version: Some(version),
            ..
        }) => vec![
            format!(
                "{system} offers WPE WebKit {version}; Lepton needs {}.{} or newer.",
                MINIMUM.0, MINIMUM.1
            ),
            String::from("A newer release of the distribution, or its testing branch, has it."),
            native,
        ],
        Some(Offer { system, .. }) => vec![
            format!("{system}'s repositories have no WPE WebKit package Lepton can use."),
            native,
        ],
        None => vec![
            format!(
                "Install WPE WebKit {}.{} or newer with its WPEPlatform API (pkg-config: wpe-webkit-2.0, wpe-platform-2.0).",
                MINIMUM.0, MINIMUM.1
            ),
            native,
        ],
    }
}

/// Before a webview build: nothing when the engine is here; otherwise the advice, and on a
/// terminal the offer to run the install command now. The command runs attached to the
/// terminal, so `sudo` asks for the password itself; nothing is installed without a yes.
pub fn ensure() -> Result<(), super::CliError> {
    if Engine::probe().ready() {
        return Ok(());
    }
    let offer = offer();
    eprintln!("lepton: this machine has no web engine for a webview build yet.");
    for line in advice(offer.as_ref()) {
        eprintln!("  {line}");
    }
    let command = offer.and_then(|offer| offer.install);
    if let Some(command) = command.filter(|_| std::io::IsTerminal::is_terminal(&std::io::stdin())) {
        let yes = inquire::Confirm::new("Install it now?")
            .with_default(true)
            .prompt()
            .unwrap_or(false);
        if yes {
            let (program, args) = command
                .split_first()
                .ok_or_else(|| super::CliError::Invalid(String::from("empty install command")))?;
            let status = Command::new(program).args(args).status().map_err(|error| {
                super::CliError::Invalid(format!("could not run {program}: {error}"))
            })?;
            if status.success() && Engine::probe().ready() {
                eprintln!("lepton: WPE WebKit is in. Carrying on.");
                return Ok(());
            }
        }
    }
    Err(super::CliError::Invalid(String::from(if cfg!(windows) {
        "the webview path needs the WebView2 runtime; install it as above"
    } else {
        "the webview path needs WPE WebKit; install it as above, or build with --native"
    })))
}

/// The installed WebView2 runtime's version: the last component of its `EBWebView` path.
fn webview2_version() -> Option<String> {
    WEBVIEW2_KEYS.iter().find_map(|key| {
        let output = Command::new("reg")
            .args(["query", key, "/v", "EBWebView"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        version_from_reg(&String::from_utf8_lossy(&output.stdout))
    })
}

/// `    EBWebView    REG_SZ    C:\…\Application\155.0.4283.62` → `155.0.4283.62`.
fn version_from_reg(text: &str) -> Option<String> {
    let line = text.lines().find(|line| line.contains("REG_SZ"))?;
    let path = line.split("REG_SZ").nth(1)?.trim();
    let version = path.rsplit('\\').next()?;
    version
        .chars()
        .next()
        .is_some_and(|first| first.is_ascii_digit())
        .then(|| version.to_owned())
}

fn exists(package: &str) -> bool {
    Command::new("pkg-config")
        .arg("--exists")
        .arg(package)
        .status()
        .is_ok_and(|status| status.success())
}

fn pkg_config(args: &[&str]) -> Option<String> {
    let output = Command::new("pkg-config").args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    #[cfg(not(windows))]
    use super::Offer;
    use super::{Family, advice, family, new_enough, version_from_reg};

    #[test]
    fn the_webview2_version_is_the_last_component_of_its_path() {
        // `reg query … /v EBWebView` as it printed on Windows 10 22H2 (2026-10-19).
        let printed = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}\r\n    EBWebView    REG_SZ    C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\155.0.4283.62\r\n\r\n";
        assert_eq!(version_from_reg(printed).as_deref(), Some("155.0.4283.62"));
        assert_eq!(
            version_from_reg(
                "ERROR: The system was unable to find the specified registry key or value."
            ),
            None
        );
    }

    #[test]
    fn systems_are_read_from_id_and_id_like() {
        // Real os-release files, cut to the two fields read.
        assert_eq!(family("ID=endeavouros\nID_LIKE=arch\n"), Some(Family::Arch));
        assert_eq!(family("ID=arch\n"), Some(Family::Arch));
        assert_eq!(family("ID=ubuntu\nID_LIKE=debian\n"), Some(Family::Debian));
        assert_eq!(family("ID=debian\n"), Some(Family::Debian));
        assert_eq!(family("ID=fedora\n"), Some(Family::Fedora));
        assert_eq!(
            family("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n"),
            Some(Family::Suse)
        );
        assert_eq!(family("ID=nixos\n"), None);
    }

    #[test]
    fn versions_from_every_package_manager_are_compared() {
        assert!(new_enough("2.54.1-2"));
        assert!(new_enough("2.54.1-1.1"));
        assert!(new_enough("1:2.56.0-1"));
        assert!(new_enough("3.0"));
        assert!(!new_enough("2.48.3-1"));
        assert!(!new_enough("2.38.6-1~deb11u1"));
        assert!(!new_enough("(none)"));
    }

    #[test]
    #[cfg(windows)]
    fn windows_advice_names_the_runtime_and_where_it_comes_from() {
        let text = advice(None).join("\n");
        assert!(text.contains("WebView2 Runtime"), "{text}");
        assert!(text.contains(super::WEBVIEW2_DOWNLOAD), "{text}");
        assert!(
            !text.contains("--native"),
            "no native path on Windows yet: {text}"
        );
    }

    /// The distribution package managers' advice; Windows has its own (above).
    #[test]
    #[cfg(not(windows))]
    fn advice_names_the_command_only_when_there_is_one() {
        let arch = Offer {
            system: String::from("EndeavourOS"),
            install: Some(vec![
                String::from("sudo"),
                String::from("pacman"),
                String::from("-S"),
                String::from("--needed"),
                String::from("wpewebkit"),
            ]),
            version: Some(String::from("2.54.1-2")),
        };
        let lines = advice(Some(&arch)).join("\n");
        assert!(
            lines.contains("sudo pacman -S --needed wpewebkit"),
            "{lines}"
        );

        let trixie = Offer {
            system: String::from("Debian GNU/Linux 13 (trixie)"),
            install: None,
            version: Some(String::from("2.48.3-1")),
        };
        let lines = advice(Some(&trixie)).join("\n");
        assert!(
            lines.contains("2.48.3-1") && lines.contains("2.54") && !lines.contains("sudo"),
            "{lines}"
        );

        let ubuntu = Offer {
            system: String::from("Ubuntu 24.04 LTS"),
            install: None,
            version: None,
        };
        let lines = advice(Some(&ubuntu)).join("\n");
        assert!(
            lines.contains("no WPE WebKit") && lines.contains("--native"),
            "{lines}"
        );
    }
}
