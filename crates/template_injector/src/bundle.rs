//! The `bundle` section of `lepton.config.json`: which release formats `lepton package`
//! writes.
//!
//! Every format packages the same tree — the build's `zig-out` prefix — so the section
//! only names formats; it never describes contents. The list is explicit and ordered:
//! a release is reproducible only when what it produces is written down, so a missing
//! section means the one format that needs nothing from the machine — `tar.gz` on Linux,
//! `zip` on Windows — never "whatever this machine can make".

use serde_json::Value;

use crate::manifest::ManifestError;

const SOURCE: &str = "lepton.config.json";

/// One release format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BundleTarget {
    /// `<name>-<version>-linux-<arch>.tar.gz`: the install prefix, unpackable anywhere.
    TarGz,
    /// An Arch Linux package (`.pkg.tar.zst`).
    Arch,
    /// A Debian package (`.deb`).
    Deb,
    /// `<name>-<version>-windows-<arch>.zip`: the install prefix, for Windows.
    Zip,
    /// A Windows Installer package (`.msi`), written without WiX: a per-user install.
    Msi,
}

impl BundleTarget {
    /// Every format, in the spelling the configuration uses.
    pub const ALL: [Self; 5] = [Self::TarGz, Self::Arch, Self::Deb, Self::Zip, Self::Msi];

    /// The spelling in `bundle.targets`.
    pub fn name(self) -> &'static str {
        match self {
            Self::TarGz => "tar.gz",
            Self::Arch => "arch",
            Self::Deb => "deb",
            Self::Zip => "zip",
            Self::Msi => "msi",
        }
    }

    /// Whether the format is a Linux package (Arch, Debian): only a Linux build can be one.
    pub fn linux_only(self) -> bool {
        matches!(self, Self::Arch | Self::Deb)
    }

    /// Whether the format installs on Windows only (it carries a Windows build).
    pub fn windows_only(self) -> bool {
        matches!(self, Self::Msi)
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|target| target.name() == text)
    }
}

/// What `lepton package` produces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
    pub targets: Vec<BundleTarget>,
    /// `bundle.maintainer`, as `Name <email>`. Debian policy makes the field mandatory, so
    /// the `.deb` format refuses to run without it rather than invent one.
    pub maintainer: Option<String>,
    /// `bundle.deb.depends`: Debian package names, for a machine with no `dpkg-query` to
    /// ask. Debian names cannot be derived from a library name on another distribution
    /// (`libglib-2.0.so.0` is `libglib2.0-0t64` since the 64-bit time transition), so they
    /// are read from dpkg or written down — never guessed.
    pub deb_depends: Option<Vec<String>>,
    /// `bundle.icon`: an `.ico` file, relative to the project, for the Windows installer's
    /// Start menu shortcut and its Settings → Apps entry. Without it both show the
    /// program's own icon.
    pub icon: Option<String>,
}

impl Default for Bundle {
    fn default() -> Self {
        Self::for_system(cfg!(windows))
    }
}

impl Bundle {
    /// No section: the plain archive of the system the build is for — `zip` for a
    /// Windows build, `tar.gz` for a Linux one, wherever it is packaged.
    pub fn for_system(windows: bool) -> Self {
        Self {
            targets: vec![if windows {
                BundleTarget::Zip
            } else {
                BundleTarget::TarGz
            }],
            maintainer: None,
            deb_depends: None,
            icon: None,
        }
    }
}

/// Reads the `bundle` section of a configuration file's text, for a build of this system.
pub fn parse_bundle(text: &str) -> Result<Bundle, ManifestError> {
    parse_bundle_for(text, cfg!(windows))
}

/// Reads the `bundle` section of a configuration file's text, for a Windows build when
/// `windows` (`lepton package --windows` on Linux), else a Linux one.
///
/// Strict: an unknown format, a repeated one or an empty list is an error naming the
/// file, because a release that silently skips a format is found out by a user.
pub fn parse_bundle_for(text: &str, windows: bool) -> Result<Bundle, ManifestError> {
    let root: Value = serde_json::from_str(text).map_err(|error| ManifestError {
        reason: format!("{SOURCE} is not valid JSON: {error}"),
    })?;
    let section = match root.get("bundle") {
        None => return Ok(Bundle::for_system(windows)),
        Some(section @ Value::Object(_)) => section,
        Some(_) => return Err(invalid("\"bundle\" must be an object")),
    };
    let targets = match section.get("targets") {
        None => Bundle::for_system(windows).targets,
        Some(list) => targets(list)?,
    };
    let maintainer = match section.get("maintainer") {
        None => None,
        Some(Value::String(text)) if !text.trim().is_empty() => Some(text.trim().to_owned()),
        Some(_) => return Err(invalid("\"bundle.maintainer\" must be a non-empty string")),
    };
    let deb_depends = match section.get("deb") {
        None => None,
        Some(deb @ Value::Object(_)) => match deb.get("depends") {
            None => None,
            Some(list) => Some(strings(list, "bundle.deb.depends")?),
        },
        Some(_) => return Err(invalid("\"bundle.deb\" must be an object")),
    };
    let icon = match section.get("icon") {
        None => None,
        // Inside the project: the icon is copied into the installer, and a cloned project's
        // configuration should not reach a file elsewhere on the machine.
        Some(Value::String(text))
            if text.trim().to_ascii_lowercase().ends_with(".ico")
                && inside_project(text.trim()) =>
        {
            Some(text.trim().to_owned())
        }
        Some(_) => {
            return Err(invalid(
                "\"bundle.icon\" must be the path of an .ico file inside the project",
            ));
        }
    };
    Ok(Bundle {
        targets,
        maintainer,
        deb_depends,
        icon,
    })
}

/// A relative path that stays below the project: no root, drive or `..`, with either
/// separator.
fn inside_project(path: &str) -> bool {
    !path.starts_with(['/', '\\'])
        && !path.contains(':')
        && path.split(['/', '\\']).all(|part| part != "..")
}

fn targets(list: &Value) -> Result<Vec<BundleTarget>, ManifestError> {
    let names = strings(list, "bundle.targets")?;
    if names.is_empty() {
        return Err(invalid(
            "\"bundle.targets\" is empty; name at least one format",
        ));
    }
    let mut targets = Vec::with_capacity(names.len());
    for text in &names {
        let target = BundleTarget::parse(text).ok_or_else(|| {
            let known: Vec<&str> = BundleTarget::ALL.iter().map(|t| t.name()).collect();
            invalid(&format!(
                "\"bundle.targets\" has {text:?}; known formats: {}",
                known.join(", ")
            ))
        })?;
        if targets.contains(&target) {
            return Err(invalid(&format!("\"bundle.targets\" lists {text:?} twice")));
        }
        targets.push(target);
    }
    Ok(targets)
}

/// An array of strings at `key`.
fn strings(value: &Value, key: &str) -> Result<Vec<String>, ManifestError> {
    let Value::Array(list) = value else {
        return Err(invalid(&format!("\"{key}\" must be an array of strings")));
    };
    list.iter()
        .map(|item| match item {
            Value::String(text) => Ok(text.clone()),
            _ => Err(invalid(&format!("\"{key}\" must be an array of strings"))),
        })
        .collect()
}

fn invalid(reason: &str) -> ManifestError {
    ManifestError {
        reason: format!("{SOURCE}: {reason}"),
    }
}

#[cfg(test)]
mod tests {
    use super::{Bundle, BundleTarget, parse_bundle, parse_bundle_for};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn the_icon_stays_inside_the_project() -> Result<(), Failure> {
        for good in ["icon.ico", "assets/app.ico", "assets\\app.ico"] {
            let text = format!(
                r#"{{"bundle":{{"icon":"{}"}}}}"#,
                good.replace('\\', "\\\\")
            );
            assert_ok!(parse_bundle(&text), "an icon inside the project");
        }
        for bad in [
            "/etc/x.ico",
            "../x.ico",
            "a/../../x.ico",
            "C:x.ico",
            "\\\\server\\x.ico",
        ] {
            let text = format!(r#"{{"bundle":{{"icon":"{}"}}}}"#, bad.replace('\\', "\\\\"));
            assert_err!(parse_bundle(&text), "an icon outside the project");
        }
        Ok(())
    }

    #[test]
    fn no_section_means_the_hosts_plain_archive() -> Result<(), Failure> {
        let bundle = assert_ok!(parse_bundle(r#"{"productName":"Notes"}"#), "parses");
        assert_eq!(bundle, Bundle::default());
        let expected = if cfg!(windows) {
            BundleTarget::Zip
        } else {
            BundleTarget::TarGz
        };
        assert_eq!(bundle.targets, vec![expected]);
        Ok(())
    }

    #[test]
    fn no_section_follows_the_system_the_build_is_for() -> Result<(), Failure> {
        let windows = assert_ok!(parse_bundle_for(r#"{"bundle":{}}"#, true), "parses");
        assert_eq!(windows.targets, vec![BundleTarget::Zip]);
        let linux = assert_ok!(
            parse_bundle_for(r#"{"productName":"Notes"}"#, false),
            "parses"
        );
        assert_eq!(linux.targets, vec![BundleTarget::TarGz]);
        Ok(())
    }

    #[test]
    fn targets_keep_the_written_order() -> Result<(), Failure> {
        let bundle = assert_ok!(
            parse_bundle(r#"{"bundle":{"targets":["deb","tar.gz","arch"]}}"#),
            "parses"
        );
        assert_eq!(
            bundle.targets,
            vec![BundleTarget::Deb, BundleTarget::TarGz, BundleTarget::Arch]
        );
        Ok(())
    }

    #[test]
    fn an_unknown_format_names_the_known_ones() -> Result<(), Failure> {
        let error = assert_err!(
            parse_bundle(r#"{"bundle":{"targets":["appimage"]}}"#),
            "unknown format"
        );
        assert_contains!(&error.reason, "\"appimage\"");
        assert_contains!(&error.reason, "tar.gz, arch, deb, zip, msi");
        Ok(())
    }

    #[test]
    fn repeated_empty_and_mistyped_lists_are_refused() -> Result<(), Failure> {
        let twice = assert_err!(
            parse_bundle(r#"{"bundle":{"targets":["deb","deb"]}}"#),
            "twice"
        );
        assert_contains!(&twice.reason, "twice");
        let empty = assert_err!(parse_bundle(r#"{"bundle":{"targets":[]}}"#), "empty");
        assert_contains!(&empty.reason, "empty");
        let number = assert_err!(parse_bundle(r#"{"bundle":{"targets":[1]}}"#), "number");
        assert_contains!(&number.reason, "array of strings");
        let flat = assert_err!(parse_bundle(r#"{"bundle":"deb"}"#), "string section");
        assert_contains!(&flat.reason, "must be an object");
        Ok(())
    }

    #[test]
    fn maintainer_and_debian_depends_are_read_when_written() -> Result<(), Failure> {
        let bundle = assert_ok!(
            parse_bundle(
                r#"{"bundle":{"targets":["deb"],"maintainer":"Ada <ada@example.org>","deb":{"depends":["libc6","libwpewebkit-2.0-1"]}}}"#
            ),
            "parses"
        );
        assert_eq!(bundle.maintainer.as_deref(), Some("Ada <ada@example.org>"));
        assert_eq!(
            bundle.deb_depends,
            Some(vec![
                String::from("libc6"),
                String::from("libwpewebkit-2.0-1")
            ])
        );
        let blank = assert_err!(parse_bundle(r#"{"bundle":{"maintainer":" "}}"#), "blank");
        assert_contains!(&blank.reason, "non-empty");
        Ok(())
    }
}
