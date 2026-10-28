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
    /// The `.ico` in `bundle.icon`, relative to the project, for the Windows installer's
    /// Start menu shortcut and its Settings → Apps entry. Without it both show the
    /// program's own icon.
    pub icon: Option<String>,
    /// The `.svg` in `bundle.icon`, relative to the project: the Linux desktop entry's and
    /// package's icon (`icons/hicolor/scalable/apps`). Without it, `src-lepton/icon.svg`.
    pub svg_icon: Option<String>,
    /// What the packages say about the application (`bundle.description` and the rest).
    pub details: Details,
}

/// What a package tells the system and its stores about the application, each optional:
/// `description` (one line), `longDescription`, `license` (an SPDX expression),
/// `homepage` (http or https), `copyright` (one line) and `category` (one of the
/// freedesktop.org main categories, as the desktop entry's `Categories` takes it).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Details {
    pub description: Option<String>,
    pub long_description: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
    pub copyright: Option<String>,
    pub category: Option<String>,
}

/// The desktop entry specification's main categories (Desktop Menu Specification, A.1).
pub const CATEGORIES: [&str; 13] = [
    "AudioVideo",
    "Audio",
    "Video",
    "Development",
    "Education",
    "Game",
    "Graphics",
    "Network",
    "Office",
    "Science",
    "Settings",
    "System",
    "Utility",
];

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
            svg_icon: None,
            details: Details::default(),
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
    // One path, or a list of them: an `.ico` for Windows, an `.svg` for Linux, one of each
    // at most. Inside the project: the icon is copied into the package, and a cloned
    // project's configuration should not reach a file elsewhere on the machine.
    let paths = match section.get("icon") {
        None => Vec::new(),
        Some(Value::String(text)) => vec![text.trim().to_owned()],
        Some(list @ Value::Array(_)) => strings(list, "bundle.icon")?,
        Some(_) => return Err(invalid(ICON_RULE)),
    };
    let mut icon = None;
    let mut svg_icon = None;
    for path in paths {
        let lower = path.to_ascii_lowercase();
        let slot = if lower.ends_with(".ico") {
            &mut icon
        } else if lower.ends_with(".svg") {
            &mut svg_icon
        } else {
            return Err(invalid(ICON_RULE));
        };
        if !inside_project(&path) || slot.is_some() {
            return Err(invalid(ICON_RULE));
        }
        *slot = Some(path);
    }
    Ok(Bundle {
        targets,
        maintainer,
        deb_depends,
        icon,
        svg_icon,
        details: details(section)?,
    })
}

fn details(section: &Value) -> Result<Details, ManifestError> {
    let line = |key: &str| text(section, key, false);
    let homepage = line("homepage")?;
    if let Some(url) = &homepage
        && !(url.starts_with("https://") || url.starts_with("http://"))
    {
        return Err(invalid(
            "\"bundle.homepage\" must be an http:// or https:// address",
        ));
    }
    let category = line("category")?;
    if let Some(name) = &category
        && !CATEGORIES.contains(&name.as_str())
    {
        return Err(invalid(&format!(
            "\"bundle.category\" is {name:?}; one of {}",
            CATEGORIES.join(", ")
        )));
    }
    Ok(Details {
        description: line("description")?,
        long_description: text(section, "longDescription", true)?,
        license: line("license")?,
        homepage,
        copyright: line("copyright")?,
        category,
    })
}

/// A non-empty string at `bundle.<key>`, trimmed. No control characters: these values are
/// written into control files and desktop entries, where a newline starts a field of its
/// own; `longDescription` alone may hold newlines (`multiline`), each written as the
/// format wants it.
fn text(section: &Value, key: &str, multiline: bool) -> Result<Option<String>, ManifestError> {
    let rule = if multiline {
        "a non-empty string, without control characters other than newlines"
    } else {
        "a non-empty string on one line"
    };
    match section.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => {
            let value = value.trim();
            let refused = value.is_empty()
                || value
                    .chars()
                    .any(|ch| ch.is_control() && !(multiline && ch == '\n'));
            if refused {
                return Err(invalid(&format!("\"bundle.{key}\" must be {rule}")));
            }
            Ok(Some(value.to_owned()))
        }
        Some(_) => Err(invalid(&format!("\"bundle.{key}\" must be {rule}"))),
    }
}

const ICON_RULE: &str = "\"bundle.icon\" must be a path inside the project, or a list of them: an .ico for Windows and an .svg for Linux, one of each at most (Linux icons are scalable: a .png would need one file per size)";

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
    use super::{Bundle, BundleTarget, Details, parse_bundle, parse_bundle_for};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn the_details_are_read_and_checked() -> Result<(), Failure> {
        let text = r#"{"bundle":{"description":" Take notes ","longDescription":"Notes.\nOffline.","license":"MIT OR Apache-2.0","homepage":"https://example.com","copyright":"© 2026 Example","category":"Office"}}"#;
        let bundle = assert_ok!(parse_bundle(text), "every detail");
        assert_eq!(
            bundle.details,
            Details {
                description: Some("Take notes".to_owned()),
                long_description: Some("Notes.\nOffline.".to_owned()),
                license: Some("MIT OR Apache-2.0".to_owned()),
                homepage: Some("https://example.com".to_owned()),
                copyright: Some("© 2026 Example".to_owned()),
                category: Some("Office".to_owned()),
            }
        );
        assert_eq!(
            assert_ok!(parse_bundle("{}"), "none").details,
            Details::default()
        );
        for (bad, says) in [
            (
                r#"{"bundle":{"description":"two\nlines"}}"#,
                "bundle.description",
            ),
            (r#"{"bundle":{"description":"  "}}"#, "bundle.description"),
            (r#"{"bundle":{"license":7}}"#, "bundle.license"),
            (
                r#"{"bundle":{"homepage":"example.com"}}"#,
                "http:// or https://",
            ),
            (r#"{"bundle":{"category":"Productivity"}}"#, "AudioVideo"),
            (
                r#"{"bundle":{"longDescription":"tab\there"}}"#,
                "bundle.longDescription",
            ),
        ] {
            let error = assert_err!(parse_bundle(bad), "{bad}");
            assert_contains!(&error.to_string(), says);
        }
        Ok(())
    }

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
    fn an_ico_and_an_svg_are_one_icon_each_system() -> Result<(), Failure> {
        let both = assert_ok!(
            parse_bundle(r#"{"bundle":{"icon":["assets/app.ico","assets/app.svg"]}}"#),
            "a list"
        );
        assert_eq!(both.icon.as_deref(), Some("assets/app.ico"));
        assert_eq!(both.svg_icon.as_deref(), Some("assets/app.svg"));
        let svg = assert_ok!(
            parse_bundle(r#"{"bundle":{"icon":"app.svg"}}"#),
            "an svg alone"
        );
        assert_eq!(svg.icon, None::<String>);
        assert_eq!(svg.svg_icon.as_deref(), Some("app.svg"));
        assert_err!(
            parse_bundle(r#"{"bundle":{"icon":["a.ico","b.ico"]}}"#),
            "two .ico files"
        );
        assert_err!(parse_bundle(r#"{"bundle":{"icon":"app.png"}}"#), "a png");
        assert_err!(
            parse_bundle(r#"{"bundle":{"icon":["../x.svg"]}}"#),
            "outside"
        );
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
