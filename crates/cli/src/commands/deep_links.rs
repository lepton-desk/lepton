//! `deepLinks` in `lepton.config.json`: the URL schemes the application opens
//! (`"deepLinks": ["myapp"]` → `myapp://…`).
//!
//! On Linux the desktop entry says so (`MimeType=x-scheme-handler/myapp;`, `Exec … %u`);
//! `lepton dev` and `lepton run` also make the entry the scheme's default handler, unless
//! another application already is. On Windows the installer registers the scheme under
//! `HKCU\Software\Classes`. The link reaches the running copy through the core's single
//! instance (`app.opened`, `@lepton-desk/api/app`).

use std::path::Path;

use serde_json::Value;

use super::CliError;

/// Schemes another program owns: claiming one would take the user's browser, mail or
/// files from them.
const RESERVED: [&str; 9] = [
    "http",
    "https",
    "file",
    "mailto",
    "ftp",
    "data",
    "javascript",
    "about",
    "lepton",
];

/// The project's schemes, checked: RFC 3986's `[a-z][a-z0-9+.-]*`, lowercase, none
/// reserved, none twice.
pub fn read(root: &Path) -> Result<Vec<String>, CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(Vec::new());
    };
    let config: Value = serde_json::from_str(&text)
        .map_err(|error| CliError::Invalid(format!("{}: {error}", path.display())))?;
    parse(&config)
}

pub fn parse(config: &Value) -> Result<Vec<String>, CliError> {
    let invalid = |reason: String| CliError::Invalid(format!("lepton.config.json: {reason}"));
    let Some(value) = config.get("deepLinks") else {
        return Ok(Vec::new());
    };
    let Value::Array(items) = value else {
        return Err(invalid(
            "\"deepLinks\" must be a list of URL schemes".to_owned(),
        ));
    };
    let mut schemes: Vec<String> = Vec::new();
    for item in items {
        let Some(scheme) = item.as_str() else {
            return Err(invalid(
                "\"deepLinks\" must be a list of URL schemes".to_owned(),
            ));
        };
        let well_formed = scheme.len() <= 64
            && scheme.starts_with(|c: char| c.is_ascii_lowercase())
            && scheme
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "+.-".contains(c));
        if !well_formed {
            return Err(invalid(format!(
                "deep link scheme {scheme:?} must be lowercase letters, digits, + . or -, starting with a letter"
            )));
        }
        if RESERVED.contains(&scheme) {
            return Err(invalid(format!(
                "deep link scheme {scheme:?} belongs to another program"
            )));
        }
        if !schemes.iter().any(|known| known == scheme) {
            schemes.push(scheme.to_owned());
        }
    }
    Ok(schemes)
}

/// Makes the entry `app_id` the default handler of each scheme with `xdg-mime`, unless
/// another entry already is: the user's choice is not taken. Returns what was done, one
/// line per scheme, for the report.
pub fn register_handlers(app_id: &str, schemes: &[String]) -> Vec<String> {
    let entry = format!("{app_id}.desktop");
    let mut lines = Vec::new();
    for scheme in schemes {
        let kind = format!("x-scheme-handler/{scheme}");
        let current = std::process::Command::new("xdg-mime")
            .args(["query", "default", &kind])
            .output();
        let Ok(current) = current else {
            lines.push(format!("{scheme}: xdg-mime not found; not registered"));
            continue;
        };
        let current = String::from_utf8_lossy(&current.stdout).trim().to_owned();
        if !current.is_empty() && current != entry {
            lines.push(format!("{scheme}: left to {current}"));
            continue;
        }
        let set = std::process::Command::new("xdg-mime")
            .args(["default", &entry, &kind])
            .status();
        lines.push(match set {
            Ok(status) if status.success() => format!("{scheme}:// opens this app"),
            _ => format!("{scheme}: xdg-mime could not register it"),
        });
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::parse;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, assert_err, assert_ok};
    use serde_json::json;

    #[test]
    fn schemes_are_checked() -> Result<(), Failure> {
        let schemes = assert_ok!(
            parse(&json!({"deepLinks": ["myapp", "my-app+x.y", "myapp"]})),
            "valid schemes"
        );
        assert_eq!(schemes, vec!["myapp".to_owned(), "my-app+x.y".to_owned()]);
        assert_eq!(assert_ok!(parse(&json!({})), "none"), Vec::<String>::new());
        for bad in [
            json!({"deepLinks": ["https"]}),
            json!({"deepLinks": ["MyApp"]}),
            json!({"deepLinks": ["1app"]}),
            json!({"deepLinks": ["my app"]}),
            json!({"deepLinks": "myapp"}),
        ] {
            assert_err!(parse(&bad), "a refused scheme");
        }
        Ok(())
    }
}
