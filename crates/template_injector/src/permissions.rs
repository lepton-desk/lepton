//! The `permissions` list of `lepton.config.json`: the commands a page may call.
//!
//! Nothing is granted that is not named. The list is checked here for what the CLI can
//! know — shape, spelling, wildcards, repeats — and again by the core at compile time
//! against the commands that actually exist, which only the application's own build
//! knows (its `main.zig` registers them).

use serde_json::Value;

use crate::manifest::ManifestError;

const SOURCE: &str = "lepton.config.json";

/// The listed commands, or `None` when the configuration has no `permissions` field (an
/// older project, whose core build takes no such option).
pub fn parse_permissions(text: &str) -> Result<Option<Vec<String>>, ManifestError> {
    let root: Value = serde_json::from_str(text).map_err(|error| ManifestError {
        reason: format!("{SOURCE} is not valid JSON: {error}"),
    })?;
    let Some(value) = root.get("permissions") else {
        return Ok(None);
    };
    let Value::Array(items) = value else {
        return Err(invalid("\"permissions\" must be an array of command names"));
    };
    let mut names: Vec<String> = Vec::with_capacity(items.len());
    for item in items {
        let Value::String(name) = item else {
            return Err(invalid("\"permissions\" must be an array of command names"));
        };
        if name.contains('*') {
            return Err(invalid(&format!(
                "\"permissions\" has {name:?}: wildcards are not allowed; name each command"
            )));
        }
        if !valid_name(name) {
            return Err(invalid(&format!(
                "\"permissions\" has {name:?}: a command is `<group>.<name>` in lowercase"
            )));
        }
        if names.contains(name) {
            return Err(invalid(&format!("\"permissions\" lists {name:?} twice")));
        }
        names.push(name.clone());
    }
    Ok(Some(names))
}

/// `<group>.<name>[.<more>]`, each part `[a-z][a-z0-9_]*` — the core's `validName`.
pub fn valid_name(name: &str) -> bool {
    let parts: Vec<&str> = name.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|part| {
            let mut chars = part.chars();
            chars.next().is_some_and(|first| first.is_ascii_lowercase())
                && chars.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
        })
}

fn invalid(reason: &str) -> ManifestError {
    ManifestError {
        reason: format!("{SOURCE}: {reason}"),
    }
}

/// What a page may ask the engine for, by the name `webPermissions` uses — the requests
/// WebKit 2.54 (WPE) raises. Anything not listed is denied. (The missing-media-plugins
/// request is not in this build's library, so it is not offered.) The core's
/// `permissions.zig` lists the same names.
pub const WEB_PERMISSION_KINDS: [&str; 9] = [
    "notifications",
    "camera",
    "microphone",
    "geolocation",
    "pointer-lock",
    "device-info",
    "media-keys",
    "storage-access",
    "xr",
];

/// The command a page answers an `ask` with.
pub const PERMISSION_ANSWER: &str = "permission.respond";

/// `webPermissions`: `{ "notifications": "ask", "camera": "deny", … }` as `(kind,
/// policy)` pairs, or `None` when the field is absent (everything denied, as before).
/// An `ask` needs `permission.respond` in `permissions`, or the page could never answer.
pub fn parse_web_permissions(text: &str) -> Result<Option<Vec<(String, String)>>, ManifestError> {
    let root: Value = serde_json::from_str(text).map_err(|error| ManifestError {
        reason: format!("{SOURCE} is not valid JSON: {error}"),
    })?;
    let Some(value) = root.get("webPermissions") else {
        return Ok(None);
    };
    let Value::Object(entries) = value else {
        return Err(invalid(
            "\"webPermissions\" must be an object: { \"notifications\": \"ask\", … }",
        ));
    };
    let mut pairs = Vec::with_capacity(entries.len());
    for (kind, policy) in entries {
        if !WEB_PERMISSION_KINDS.contains(&kind.as_str()) {
            return Err(invalid(&format!(
                "\"webPermissions\" has {kind:?}; the engine asks for {}",
                WEB_PERMISSION_KINDS.join(", ")
            )));
        }
        let Some(policy) = policy
            .as_str()
            .filter(|p| matches!(*p, "allow" | "deny" | "ask"))
        else {
            return Err(invalid(&format!(
                "\"webPermissions\".{kind} must be \"allow\", \"deny\" or \"ask\""
            )));
        };
        pairs.push((kind.clone(), policy.to_owned()));
    }
    let asks = pairs.iter().any(|(_, policy)| policy == "ask");
    if asks {
        let granted = parse_permissions(text)?.unwrap_or_default();
        if !granted.iter().any(|name| name == PERMISSION_ANSWER) {
            return Err(invalid(&format!(
                "\"webPermissions\" asks the page, so \"permissions\" must list \"{PERMISSION_ANSWER}\" for it to answer"
            )));
        }
    }
    Ok(Some(pairs))
}

#[cfg(test)]
mod tests {
    use super::{parse_permissions, valid_name};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn a_missing_field_is_none_and_an_empty_list_grants_nothing() -> Result<(), Failure> {
        assert_eq!(
            assert_ok!(parse_permissions(r#"{"productName":"A"}"#), "parses"),
            None::<Vec<String>>
        );
        assert_eq!(
            assert_ok!(parse_permissions(r#"{"permissions":[]}"#), "parses"),
            Some(Vec::<String>::new())
        );
        Ok(())
    }

    #[test]
    fn listed_commands_keep_their_order() -> Result<(), Failure> {
        let names = assert_ok!(
            parse_permissions(r#"{"permissions":["window.close","notes.save"]}"#),
            "parses"
        );
        assert_eq!(
            names,
            Some(vec![
                String::from("window.close"),
                String::from("notes.save")
            ])
        );
        Ok(())
    }

    #[test]
    fn wildcards_typos_repeats_and_wrong_types_are_refused() -> Result<(), Failure> {
        let star = assert_err!(parse_permissions(r#"{"permissions":["core.*"]}"#), "star");
        assert_contains!(&star.reason, "wildcards are not allowed");
        let bare = assert_err!(parse_permissions(r#"{"permissions":["*"]}"#), "bare star");
        assert_contains!(&bare.reason, "wildcards");
        let upper = assert_err!(
            parse_permissions(r#"{"permissions":["Notes.save"]}"#),
            "case"
        );
        assert_contains!(&upper.reason, "lowercase");
        let twice = assert_err!(
            parse_permissions(r#"{"permissions":["core.ping","core.ping"]}"#),
            "twice"
        );
        assert_contains!(&twice.reason, "twice");
        let object = assert_err!(
            parse_permissions(r#"{"permissions":{"core.ping":true}}"#),
            "object"
        );
        assert_contains!(&object.reason, "array");
        Ok(())
    }

    #[test]
    fn names_follow_the_cores_rule() -> Result<(), Failure> {
        assert_eq!(valid_name("notes.save"), true);
        assert_eq!(valid_name("a.b_2.c"), true);
        assert_eq!(valid_name("notes"), false);
        assert_eq!(valid_name("notes..save"), false);
        assert_eq!(valid_name("2d.draw"), false);
        Ok(())
    }
}

#[cfg(test)]
mod web_tests {
    use super::parse_web_permissions;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn web_permissions_are_kinds_with_a_policy() -> Result<(), Failure> {
        let absent: Option<Vec<(String, String)>> = None;
        assert_eq!(assert_ok!(parse_web_permissions("{}"), "absent"), absent);
        let pairs = assert_ok!(
            parse_web_permissions(
                r#"{"permissions":["permission.respond"],"webPermissions":{"notifications":"ask","camera":"deny","geolocation":"allow"}}"#
            ),
            "valid"
        );
        assert_eq!(
            pairs,
            // In the order `serde_json` keeps an object: by name. The order means nothing.
            Some(vec![
                ("camera".to_owned(), "deny".to_owned()),
                ("geolocation".to_owned(), "allow".to_owned()),
                ("notifications".to_owned(), "ask".to_owned()),
            ])
        );
        Ok(())
    }

    #[test]
    fn unknown_kinds_policies_and_unanswerable_asks_are_refused() -> Result<(), Failure> {
        let unknown = assert_err!(
            parse_web_permissions(r#"{"webPermissions":{"usb":"allow"}}"#),
            "kind"
        );
        assert_contains!(&unknown.reason, "usb");
        let policy = assert_err!(
            parse_web_permissions(r#"{"webPermissions":{"camera":"yes"}}"#),
            "policy"
        );
        assert_contains!(&policy.reason, "\"allow\", \"deny\" or \"ask\"");
        let unanswerable = assert_err!(
            parse_web_permissions(
                r#"{"permissions":["app.name"],"webPermissions":{"camera":"ask"}}"#
            ),
            "ask without permission.respond"
        );
        assert_contains!(&unanswerable.reason, "permission.respond");
        Ok(())
    }
}
