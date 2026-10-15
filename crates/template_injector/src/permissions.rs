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
