//! The checks a manifest passes before it is written or read: each field that reaches
//! generated source, a desktop entry or package metadata, and the window and channel.

use crate::manifest::Manifest;

/// A manifest that could not be rendered because it is not valid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError {
    pub reason: String,
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.reason)
    }
}

impl std::error::Error for ManifestError {}

/// A display name (`productName`, `window.title`): it reaches generated Zig source, a
/// desktop entry, package metadata and an install folder's name, so no control character
/// (a newline once ended a line of `main.zig` and started another; audit, 2026-10-20) and
/// no path separator.
pub fn check_name(field: &str, value: &str) -> Result<(), ManifestError> {
    if let Some(bad) = value
        .chars()
        .find(|c| c.is_control() || *c == '/' || *c == '\\')
    {
        return Err(ManifestError {
            reason: format!("{field} may not contain {bad:?}, got {value:?}"),
        });
    }
    // It names the Windows install folder (`%LOCALAPPDATA%\\Programs\\<product>`).
    if matches!(value.trim(), "." | "..") {
        return Err(ManifestError {
            reason: format!("{field} cannot be {value:?}"),
        });
    }
    Ok(())
}

/// The window's title: shown, and written into `main.zig` as an escaped literal, never a
/// path, so only control characters are refused.
pub fn check_title(value: &str) -> Result<(), ManifestError> {
    if let Some(bad) = value.chars().find(|c| c.is_control()) {
        return Err(ManifestError {
            reason: format!("window.title may not contain {bad:?}, got {value:?}"),
        });
    }
    Ok(())
}

/// The application identifier: one directory name in every platform's data folders, a
/// window class, a desktop entry's name. ASCII letters, digits, `.`, `_`, `-`; not `.`
/// or `..`, which would name the folder above.
pub fn check_identifier(value: &str) -> Result<(), ManifestError> {
    let fine = !value.is_empty()
        && value != "."
        && value != ".."
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    if fine {
        Ok(())
    } else {
        Err(ManifestError {
            reason: format!(
                "identifier must be ASCII letters, digits, `.`, `_` or `-` (not `.` or `..`), got {value:?}"
            ),
        })
    }
}

/// The version: part of package file names and package metadata, so a version string
/// and nothing else (digits, letters, `.`, `+`, `~`, `-`).
pub fn check_version(value: &str) -> Result<(), ManifestError> {
    let fine = !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '+' | '~' | '-'))
        && !value.starts_with('.');
    if fine {
        Ok(())
    } else {
        Err(ManifestError {
            reason: format!("version must be letters, digits, `.`, `+`, `~` or `-`, got {value:?}"),
        })
    }
}

/// The npm scope Lepton's own packages are published under, unless `sdkScope` names another
/// (a mirror or fork that publishes them as `@acme/api`, `@acme/cli`, …).
pub const SDK_SCOPE: &str = "@lepton-desk";

/// `sdkScope`: an npm scope, `@` and a lower-case name of letters, digits, `-`, `.` and `_`
/// (npm's rules for a scope; it becomes part of every Lepton package name).
pub fn check_scope(value: &str) -> Result<(), ManifestError> {
    let name = value.strip_prefix('@').unwrap_or("");
    let fine = !name.is_empty()
        && !name.starts_with(['.', '_'])
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '.' | '_'));
    if fine {
        Ok(())
    } else {
        Err(ManifestError {
            reason: format!(
                "sdkScope must be an npm scope such as \"@lepton-desk\", got {value:?}"
            ),
        })
    }
}

/// Checks a manifest before it is written, so a bad project is refused at the
/// point the developer can still fix it.
///
/// The window size is checked because a zero-sized window cannot be opened, and
/// the channel name because POSIX requires exactly one leading slash and no other
/// path separator — both of which would otherwise surface much later as a kernel
/// error with no useful context.
pub fn validate(manifest: &Manifest) -> Result<(), ManifestError> {
    if manifest.product_name.trim().is_empty() {
        return Err(ManifestError {
            reason: "a project needs a name".to_owned(),
        });
    }
    check_name("productName", &manifest.product_name)?;
    check_title(&manifest.window_title)?;
    check_identifier(&manifest.identifier)?;
    check_version(&manifest.version)?;
    check_scope(&manifest.sdk_scope)?;
    if manifest.window_width == 0 || manifest.window_height == 0 {
        return Err(ManifestError {
            reason: format!(
                "a window needs a non-zero size, got {}x{}",
                manifest.window_width, manifest.window_height
            ),
        });
    }
    if !manifest.channel_name.starts_with('/') || manifest.channel_name[1..].contains('/') {
        return Err(ManifestError {
            reason: format!(
                "a shared-memory name must start with `/` and contain no other separator, got {:?}",
                manifest.channel_name
            ),
        });
    }
    Ok(())
}
