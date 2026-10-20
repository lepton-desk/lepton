//! Reading `lepton.config.json` back.
//!
//! Separate from `manifest.rs` because that module owns writing: the renderer is
//! small and fixed, and this reader has to cope with a file a developer has since
//! edited, reordered, or reformatted. Keeping them apart means the writer can stay
//! a straight-line function while the reader absorbs the mess.
//!
//! The reader is deliberately strict about the fields the core depends on and
//! tolerant about everything else. A configuration file grows — a developer's own
//! keys must survive a round trip through the CLI — so an unknown key is not an
//! error, but a missing window size is, because a core built without it has no way
//! to open anything.
//!
//! `serde_json` is used here (and in `bundle.rs`, which reads its own section) and nowhere else in the workspace. The IPC path is
//! zero-copy binary and will stay that way; this file is the one place JSON is
//! genuinely the format, because a human is meant to read and edit it.

use serde_json::Value;

use crate::manifest::{Manifest, ManifestError, RenderPath, Target, identifier_for};

/// The name of the file this module reads, mentioned in every error.
///
/// Repeated in the message so a failure that arrives from four frames down says
/// which file to open.
const SOURCE: &str = "lepton.config.json";

/// Parses a configuration file's text into a manifest.
pub fn parse_config(text: &str) -> Result<Manifest, ManifestError> {
    let root: Value = serde_json::from_str(text).map_err(|error| ManifestError {
        reason: format!("{SOURCE} is not valid JSON: {error}"),
    })?;

    if !root.is_object() {
        return Err(ManifestError {
            reason: format!("{SOURCE} must contain a JSON object at the top level"),
        });
    }

    let product_name = string(&root, "productName")?;

    let manifest = Manifest {
        language: crate::manifest::Language::default(),
        product_name: product_name.clone(),
        identifier: optional_string(&root, "identifier")?
            .unwrap_or_else(|| identifier_for(&product_name)),
        version: optional_string(&root, "version")?.unwrap_or_else(|| String::from("0.1.0")),
        render_path: enum_field(&root, "renderPath", RenderPath::parse, RenderPath::Webview)?,
        target: enum_field(&root, "target", Target::parse, Target::VanillaTs)?,
        window_title: sub_string(&root, "window", "title")?.unwrap_or_else(|| product_name.clone()),
        window_width: sub_u32(&root, "window", "width")?.unwrap_or(1200),
        window_height: sub_u32(&root, "window", "height")?.unwrap_or(800),
        channel_name: sub_string(&root, "channel", "name")?
            .unwrap_or_else(|| format!("/lepton-{}", identifier_for(&product_name))),
        sdk_scope: optional_string(&root, "sdkScope")?
            .unwrap_or_else(|| String::from("@lepton-desk")),
        plugins: Vec::new(),
    };

    // Validated after parsing, so the same rules apply to a file that was hand-edited
    // as to one this CLI wrote. A configuration that passes here is one the core can
    // actually open a window for.
    crate::manifest::validate(&manifest)?;
    Ok(manifest)
}

/// A top-level string field.
fn string(root: &Value, key: &str) -> Result<String, ManifestError> {
    optional_string(root, key)?.ok_or_else(|| ManifestError {
        reason: format!("{SOURCE} needs a \"{key}\" string"),
    })
}

/// A top-level string field, if present and a string.
fn optional_string(root: &Value, key: &str) -> Result<Option<String>, ManifestError> {
    match root.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(ManifestError {
            reason: format!(
                "{SOURCE}: \"{key}\" must be a string, found {}",
                kind(other)
            ),
        }),
    }
}

/// A string inside a nested object.
fn sub_string(root: &Value, group: &str, key: &str) -> Result<Option<String>, ManifestError> {
    let nested = nested(root, group)?;
    let Some(nested) = nested else {
        // A missing group is not an error: every field in it has a default, and a
        // configuration written by hand may legitimately omit `channel`.
        return Ok(None);
    };

    match nested.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(ManifestError {
            reason: format!(
                "{SOURCE}: \"{group}.{key}\" must be a string, found {}",
                kind(other)
            ),
        }),
    }
}

/// An unsigned field inside a nested object.
fn sub_u32(root: &Value, group: &str, key: &str) -> Result<Option<u32>, ManifestError> {
    let Some(nested) = nested(root, group)? else {
        return Ok(None);
    };

    match nested.get(key) {
        None => Ok(None),
        // `as_u64` rather than `as_u64().try_into()`: a negative or fractional width
        // is a mistake worth naming, and `as_u64` returning `None` is how serde says
        // exactly that. Reinterpreting it as zero would turn a typo into a window
        // nobody can see.
        Some(value) => value
            .as_u64()
            .and_then(|number| u32::try_from(number).ok())
            .map(Some)
            .ok_or_else(|| ManifestError {
                reason: format!(
                    "{SOURCE}: \"{group}.{key}\" must be a whole number of pixels, found {value}"
                ),
            }),
    }
}

/// The nested object under `group`, when it is one.
fn nested<'a>(root: &'a Value, group: &str) -> Result<Option<&'a Value>, ManifestError> {
    match root.get(group) {
        None => Ok(None),
        Some(value @ Value::Object(_)) => Ok(Some(value)),
        Some(other) => Err(ManifestError {
            reason: format!(
                "{SOURCE}: \"{group}\" must be an object, found {}",
                kind(other)
            ),
        }),
    }
}

/// A field rendered as one of two words, with a default when absent.
///
/// The two spellings are named in the error rather than left implicit: a
/// configuration that says `"renderPath": "web"` should be corrected by the
/// developer, not silently downgraded to the default.
fn enum_field<T>(
    root: &Value,
    key: &str,
    parse: fn(&str) -> Option<T>,
    default: T,
) -> Result<T, ManifestError>
where
    T: Copy,
{
    match optional_string(root, key)? {
        None => Ok(default),
        Some(text) => parse(&text).ok_or_else(|| ManifestError {
            reason: format!(
                "{SOURCE}: \"{key}\" is {text:?}, which is not one of the known values"
            ),
        }),
    }
}

/// What a JSON value is, in words a developer can act on.
fn kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use super::parse_config;
    use crate::manifest::{Manifest, RenderPath, Target, render_manifest};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    #[test]
    fn a_configuration_round_trips_through_its_own_renderer() -> Result<(), Failure> {
        // The strongest guarantee available without a real project: what the CLI
        // writes, it can read back to the same value.
        let mut original = Manifest::new("Ledger");
        original.render_path = RenderPath::Native;
        original.target = Target::React;
        original.window_title = String::from("Ledger — live");
        original.window_width = 1440;
        original.window_height = 900;
        original.sdk_scope = String::from("@lepton-desk");

        let parsed = assert_ok!(
            parse_config(&render_manifest(&original)),
            "the CLI's own file must parse"
        );

        assert_eq!(parsed, original);
        Ok(())
    }

    #[test]
    fn an_unknown_key_is_ignored_so_a_projects_own_settings_survive() -> Result<(), Failure> {
        // A configuration file belongs to the developer as much as to the CLI. A key
        // the CLI does not know must not stop it from reading the rest.
        let text = concat!(
            "{\n",
            "  \"productName\": \"Ledger\",\n",
            "  \"authorNote\": \"ask before deleting anything\",\n",
            "  \"window\": { \"width\": 1440 }\n",
            "}\n"
        );

        let parsed = assert_ok!(parse_config(text), "an unknown key should be tolerated");

        assert_eq!(parsed.window_width, 1440);
        // The height is absent, so the default applies rather than the window being
        // refused — a partially specified window is still a usable one.
        assert_eq!(parsed.window_height, 800);
        assert_eq!(parsed.product_name, "Ledger");
        Ok(())
    }

    #[test]
    fn key_order_does_not_matter() -> Result<(), Failure> {
        // A developer who reformats their configuration by hand will reorder it. The
        // reader must not care: it looks keys up, it does not count lines.
        let text = "{\n  \"window\": { \"height\": 640 },\n  \"productName\": \"Ledger\"\n}\n";

        let parsed = assert_ok!(parse_config(text), "reordered keys should still parse");

        assert_eq!(parsed.window_height, 640);
        assert_eq!(parsed.window_width, 1200);
        Ok(())
    }

    #[test]
    fn a_missing_product_name_is_refused_by_name() -> Result<(), Failure> {
        let error = assert_err!(
            parse_config("{ \"window\": {} }"),
            "a nameless project is refused"
        );

        // The message has to name the key, because the file is one the developer
        // wrote and the only way to fix it is to add that key.
        assert_contains!(&error.to_string(), "productName");
        assert_contains!(&error.to_string(), "lepton.config.json");
        Ok(())
    }

    #[test]
    fn a_malformed_file_says_where_it_broke() -> Result<(), Failure> {
        let error = assert_err!(parse_config("{ not json"), "malformed JSON is refused");

        // serde's own message carries the line and column, which is the difference
        // between a two-second fix and a hunt through the file.
        assert_contains!(&error.to_string(), "line");
        Ok(())
    }

    #[test]
    fn a_top_level_array_is_refused_with_its_actual_shape() -> Result<(), Failure> {
        let error = assert_err!(parse_config("[]"), "a non-object is refused");

        assert_contains!(&error.to_string(), "object");
        Ok(())
    }

    #[test]
    fn a_negative_window_size_is_refused_rather_than_becoming_zero() -> Result<(), Failure> {
        // `as_u64` returns `None` for a negative number. Reading it as zero instead
        // would produce a window nobody can see and a validation error three steps
        // later; refusing here names the actual mistake.
        let text = "{ \"productName\": \"Ledger\", \"window\": { \"width\": -3 } }";

        let error = assert_err!(parse_config(text), "a negative width is refused");

        assert_contains!(&error.to_string(), "pixels");
        Ok(())
    }

    #[test]
    fn a_group_that_is_not_an_object_is_refused() -> Result<(), Failure> {
        let text = "{ \"productName\": \"Ledger\", \"window\": 800 }";

        let error = assert_err!(parse_config(text), "a scalar window group is refused");

        assert_contains!(&error.to_string(), "window");
        assert_contains!(&error.to_string(), "object");
        Ok(())
    }

    #[test]
    fn an_unknown_render_path_names_the_field() -> Result<(), Failure> {
        let text = "{ \"productName\": \"Ledger\", \"renderPath\": \"web\" }";

        let error = assert_err!(parse_config(text), "an unknown render path is refused");

        assert_contains!(&error.to_string(), "renderPath");
        assert_contains!(&error.to_string(), "\"web\"");
        Ok(())
    }

    #[test]
    fn an_unknown_target_names_the_field() -> Result<(), Failure> {
        let text = "{ \"productName\": \"Ledger\", \"target\": \"ember\" }";

        let error = assert_err!(parse_config(text), "an unknown target is refused");

        assert_contains!(&error.to_string(), "target");
        Ok(())
    }

    #[test]
    fn an_identifier_and_channel_left_for_derived_are_derived() -> Result<(), Failure> {
        // A configuration with only a name is still a valid one; the identifier and
        // the channel name follow from it rather than being required twice.
        let parsed = assert_ok!(
            parse_config("{ \"productName\": \"My App\" }"),
            "a bare manifest should parse"
        );

        ensure!(
            parsed.identifier == "my-app",
            "identifier should be derived, got {}",
            parsed.identifier
        );
        ensure!(
            parsed.channel_name == "/lepton-my-app",
            "channel should be derived, got {}",
            parsed.channel_name
        );
        Ok(())
    }

    #[test]
    fn a_hand_written_zero_sized_window_is_still_refused() -> Result<(), Failure> {
        // The reader defers to the same validation the writer uses, so an edit that
        // makes the window invisible is refused at the same point a bad manifest is.
        let text = "{ \"productName\": \"Ledger\", \"window\": { \"height\": 0 } }";

        let error = assert_err!(parse_config(text), "a zero-height window is refused");

        assert_contains!(&error.to_string(), "non-zero");
        Ok(())
    }

    #[test]
    fn a_title_with_quotes_survives_and_one_with_a_newline_is_refused() -> Result<(), Failure> {
        // The escaping the renderer does has to be the escaping the reader undoes, or a
        // project with a quote in its title would come back with a different one.
        let mut original = Manifest::new("Ledger");
        original.window_title = String::from("Ledger \"live\" \\ now");
        let parsed = assert_ok!(
            parse_config(&render_manifest(&original)),
            "a title with quotes and a backslash must survive"
        );
        assert_eq!(parsed.window_title, original.window_title);

        // A control character is refused: a newline once reached `main.zig` as a line of
        // its own (audit, 2026-10-20).
        original.window_title = String::from("Ledger\nnow");
        assert_err!(
            parse_config(&render_manifest(&original)),
            "a newline in the title is refused"
        );
        Ok(())
    }

    #[test]
    fn a_channel_name_without_a_leading_slash_is_refused() -> Result<(), Failure> {
        // POSIX requires the leading slash, and the core would fail much later with a
        // kernel error that names neither the project nor the field.
        let text = "{ \"productName\": \"Ledger\", \"channel\": { \"name\": \"lepton\" } }";

        let error = assert_err!(parse_config(text), "a bare channel name is refused");

        assert_contains!(&error.to_string(), "separator");
        Ok(())
    }
}
