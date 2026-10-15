//! Merging JSON into JSON.
//!
//! Only used for `package.json`, and only because that is the one file two tools
//! both have an opinion about: the scaffolder wrote the framework's scripts and
//! dependencies, and Lepton adds its own. Replacing the file would delete the first;
//! string-editing it would be a second JSON parser written with `replace`.
//!
//! The rule is one line: **the incoming value wins, except that two objects are
//! merged rather than replaced.** That is what lets a new key be added to
//! `devDependencies` without taking `vite` with it, and it is why the developer's
//! own edits to scripts survive a re-scaffold.

use serde_json::{Map, Value};

/// Merges `addition` into `existing`, both JSON text, and returns pretty text.
///
/// Refuses rather than guessing when either side is not an object at the top level.
/// A JSON array or a bare number in `package.json` is not something this function
/// can sensibly merge into, and producing output anyway would mean inventing a shape.
pub fn into(existing: &str, addition: &str) -> Result<String, String> {
    let mut target = parse(existing, "the existing file")?;
    let incoming = parse(addition, "the injected content")?;

    // Both sides were checked to be objects, so this is an object-to-object merge
    // rather than a value replace. The checks above are what make the `ok_or` here
    // impossible rather than merely unlikely.
    if let (Value::Object(existing), Value::Object(added)) = (&mut target, &incoming) {
        merge_objects(existing, added);
    }

    // Two-space indent and a trailing newline: what `npm` and every editor's
    // "format document" produce, so the merge does not show up as a diff.
    let mut out = serde_json::to_string_pretty(&target)
        .map_err(|error| format!("the merged file could not be rendered: {error}"))?;
    out.push('\n');

    Ok(out)
}

/// Parses one side, naming which side failed.
///
/// The distinction matters because the two have different fixes: a broken existing
/// file is the developer's to repair, a broken injection is Lepton's to ship.
fn parse(text: &str, which: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(text)
        .map_err(|error| format!("{which} is not valid JSON: {error}"))?;

    if !value.is_object() {
        return Err(format!(
            "{which} must be a JSON object at the top level, found {}",
            describe(&value)
        ));
    }

    Ok(value)
}

/// Merges `incoming` into `target`, recursing into objects.
fn merge_objects(target: &mut Map<String, Value>, incoming: &Map<String, Value>) {
    for (key, value) in incoming {
        let merged = match (target.get(key), value) {
            // Both sides are objects: merge them key by key, so a new dependency
            // joins the existing ones instead of deleting them.
            (Some(Value::Object(existing)), Value::Object(_)) => {
                let mut nested = existing.clone();
                if let Value::Object(more) = value {
                    merge_objects(&mut nested, more);
                }
                Value::Object(nested)
            }
            // Anything else: the incoming value replaces. Arrays included — merging
            // two lists of plugins element-wise would produce a list nobody asked for.
            _ => value.clone(),
        };

        target.insert(key.clone(), merged);
    }
}

/// What a JSON value is, for an error message.
fn describe(value: &Value) -> &'static str {
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
    use super::into;
    use lepton_orchestrator::testing::{Failure, balanced};
    use lepton_orchestrator::{
        assert_absent, assert_contains, assert_eq, assert_err, assert_ok, ensure,
    };

    #[test]
    fn an_added_key_arrives_without_taking_the_others() -> Result<(), Failure> {
        let merged = assert_ok!(
            into(
                "{\"scripts\": {\"dev\": \"vite\", \"build\": \"tsc && vite build\"}}",
                "{\"scripts\": {\"lepton:dev\": \"lepton dev\"}}",
            ),
            "two script maps should merge"
        );

        assert_contains!(&merged, "\"dev\": \"vite\"");
        assert_contains!(&merged, "\"build\": \"tsc && vite build\"");
        assert_contains!(&merged, "\"lepton:dev\": \"lepton dev\"");
        balanced(&merged, '{', '}')
    }

    #[test]
    fn a_replaced_key_takes_the_incoming_value() -> Result<(), Failure> {
        // The documented rule, stated as a test so it cannot change silently: the
        // incoming value wins, so a re-scaffold is idempotent rather than a fight.
        let merged = assert_ok!(
            into("{\"name\": \"old\"}", "{\"name\": \"new\"}"),
            "a scalar should be replaced"
        );

        assert_contains!(&merged, "\"new\"");
        assert_absent!(&merged, "old");
        Ok(())
    }

    #[test]
    fn nested_objects_merge_all_the_way_down() -> Result<(), Failure> {
        let merged = assert_ok!(
            into(
                "{\"devDependencies\": {\"vite\": \"^8.3.0\", \"typescript\": \"~6.0.2\"}}",
                "{\"devDependencies\": {\"@biomejs/biome\": \"2.0.0\"}}",
            ),
            "dependency maps should merge"
        );

        // The whole point: adding one dependency must not delete the other two.
        for kept in ["vite", "typescript", "@biomejs/biome"] {
            assert_contains!(&merged, kept);
        }
        Ok(())
    }

    #[test]
    fn arrays_are_replaced_rather_than_appended() -> Result<(), Failure> {
        // Merging two lists element-wise would produce a list nobody asked for, and a
        // duplicated plugin is a hard failure to diagnose later.
        let merged = assert_ok!(
            into("{\"files\": [\"a\", \"b\"]}", "{\"files\": [\"c\"]}"),
            "an array should be replaced"
        );

        assert_contains!(&merged, "\"c\"");
        assert_absent!(&merged, "\"b\"");
        Ok(())
    }

    #[test]
    fn the_output_is_pretty_and_ends_with_a_newline() -> Result<(), Failure> {
        // The merged file is read and edited by humans; a one-line blob would show up
        // as a whole-file diff the next time anything changed it.
        let merged = assert_ok!(into("{\"a\": 1}", "{\"b\": 2}"), "a merge should succeed");

        ensure!(
            merged.ends_with('\n'),
            "the output should end with a newline"
        );
        ensure!(
            merged.contains("\n  \"a\": 1"),
            "the output should be indented:\n{merged}"
        );
        Ok(())
    }

    #[test]
    fn a_broken_existing_file_is_refused_and_named() -> Result<(), Failure> {
        let error = assert_err!(
            into("not json", "{\"a\": 1}"),
            "an unparseable existing file must be refused"
        );

        assert_contains!(&error, "the existing file");
        Ok(())
    }

    #[test]
    fn a_broken_injection_is_refused_and_named_separately() -> Result<(), Failure> {
        // The two sides have different owners, so the message has to distinguish
        // them: one is the developer's to repair, the other is Lepton's to ship.
        let error = assert_err!(
            into("{\"a\": 1}", "not json"),
            "an unparseable injection must be refused"
        );

        assert_contains!(&error, "the injected content");
        Ok(())
    }

    #[test]
    fn a_top_level_array_is_refused_rather_than_wrapped() -> Result<(), Failure> {
        // Wrapping it in an object would invent a shape. Refusing says what is wrong.
        let error = assert_err!(into("[]", "{\"a\": 1}"), "an array must be refused");

        assert_contains!(&error, "an array");
        Ok(())
    }

    #[test]
    fn merging_nothing_leaves_the_file_readable() -> Result<(), Failure> {
        // An empty injection is what a preset with nothing to add produces. The file
        // must still come out as the same JSON, reformatted at worst.
        let merged = assert_ok!(into("{\"a\": 1}", "{}"), "an empty merge should succeed");

        assert_contains!(&merged, "\"a\": 1");
        Ok(())
    }

    #[test]
    fn the_merge_is_idempotent() -> Result<(), Failure> {
        // `lepton new` may be re-run on an existing project. A merge that is not
        // idempotent would grow the file on every run.
        let once = assert_ok!(
            into(
                "{\"scripts\": {\"dev\": \"vite\"}}",
                "{\"scripts\": {\"lepton:dev\": \"lepton dev\"}}"
            ),
            "the first merge should succeed"
        );
        let twice = assert_ok!(
            into(&once, "{\"scripts\": {\"lepton:dev\": \"lepton dev\"}}"),
            "the second merge should succeed"
        );

        assert_eq!(once, twice);
        Ok(())
    }
}
