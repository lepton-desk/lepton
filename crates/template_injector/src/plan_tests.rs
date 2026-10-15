//! Tests for the plan and for applying one.
//!
//! A sibling file rather than a `mod tests` at the bottom of `plan.rs`, because that
//! file's production half plus its assertions together crossed the workspace's
//! 800-line ceiling. The tests are kept whole rather than split: a test suite cut in
//! half is two suites that each forget half the behaviour.

use crate::manifest::{Manifest, RenderPath};
use lepton_orchestrator::testing::{Failure, Scratch, balanced};
use lepton_orchestrator::{
    assert_absent, assert_contains, assert_eq, assert_err, assert_ok, ensure,
};
use std::path::Path;

use super::{Injection, InjectionError, Mode, Plan, apply, plan, resolve};

/// The plan for a fresh project, or a failure describing why there is none.
fn planned_for(manifest: &Manifest) -> Result<Plan, Failure> {
    plan(manifest).map_err(|error| Failure {
        claim: "a valid manifest should plan".to_owned(),
        actual: format!("{error}"),
    })
}

/// The contents the plan would write for one path.
fn contents_of<'a>(planned: &'a Plan, path: &str) -> Result<&'a str, Failure> {
    planned
        .files
        .iter()
        .find(|file| file.path == path)
        .map(|file| file.contents.as_str())
        .ok_or(Failure {
            claim: format!("the plan should include {path}"),
            actual: format!(
                "it includes {:?}",
                planned
                    .files
                    .iter()
                    .map(|file| &file.path)
                    .collect::<Vec<_>>()
            ),
        })
}

#[test]
fn a_plan_covers_the_configuration_the_sdk_and_the_core_entry_points() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;
    let paths: Vec<&str> = planned
        .files
        .iter()
        .map(|file| file.path.as_str())
        .collect();

    for required in [
        "lepton.config.json",
        "package.json",
        "biome.json",
        "index.html",
        "src/lepton.ts",
        "src/lepton-sdk.css",
        "src/main.ts",
        // The core lives beside the frontend, not inside it: mixing Zig into
        // `src/` would make the frontend's own watcher try to compile it.
        "src-lepton/main.zig",
        "src-lepton/build.zig",
    ] {
        ensure!(
            paths.contains(&required),
            "plan is missing {required}: {paths:?}"
        );
    }
    Ok(())
}

#[test]
fn the_scaffolders_package_manifest_is_merged_not_replaced() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;
    let package = planned
        .files
        .iter()
        .find(|file| file.path == "package.json")
        .ok_or(Failure {
            claim: "the plan should touch package.json".to_owned(),
            actual: String::from("no package.json"),
        })?;

    // A whole-file write here would delete the `dev`, `build` and `preview`
    // scripts the scaffolder wrote, and the project would stop starting.
    assert_eq!(package.mode, Mode::MergeJson);
    Ok(())
}

#[test]
fn only_the_package_manifest_is_merged() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for file in &planned.files {
        if file.path == "package.json" {
            continue;
        }
        ensure!(
            !matches!(file.mode, Mode::MergeJson),
            "{} should be written whole or removed, not merged",
            file.path
        );
    }
    Ok(())
}

#[test]
fn the_scaffolders_demo_files_are_removed_rather_than_left_behind() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for path in [
        "src/counter.ts",
        "src/style.css",
        "public/favicon.svg",
        "src/assets/vite.svg",
    ] {
        let file = planned
            .files
            .iter()
            .find(|file| file.path == path)
            .ok_or(Failure {
                claim: format!("the plan should account for {path}"),
                actual: String::from("it is not in the plan"),
            })?;
        ensure!(file.mode == Mode::Remove, "{path} should be removed");
        // A removal carries no contents, so a plan cannot look like it is about to
        // write something at a path it also removes.
        assert_eq!(file.contents, "");
    }
    Ok(())
}

#[test]
fn no_file_is_both_written_and_removed() -> Result<(), Failure> {
    // The plan is a list, so a path appearing twice with different modes would
    // apply in order and leave the project in whichever state came last.
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for (index, first) in planned.files.iter().enumerate() {
        for second in planned.files.iter().skip(index + 1) {
            ensure!(
                first.path != second.path,
                "{} appears twice in one plan",
                first.path
            );
        }
    }
    Ok(())
}

#[test]
fn applying_a_plan_removes_the_files_it_names() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("remove"),
        "the scratch directory should be creatable"
    );
    scratch
        .write("src/style.css", "body {}")
        .map_err(|error| Failure {
            claim: "the demo file should be writable".to_owned(),
            actual: format!("{error}"),
        })?;
    scratch
        .write("src/main.ts", "/* the starter */")
        .map_err(|error| Failure {
            claim: "the starter screen should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

    let planned = planned_for(&Manifest::new("Ledger"))?;
    assert_ok!(apply(scratch.path(), &planned), "the plan should apply");

    ensure!(
        !scratch.exists("src/style.css"),
        "the demo stylesheet should be gone"
    );
    ensure!(
        !scratch.exists("public/favicon.svg"),
        "a removal of something absent should not fail the plan"
    );
    ensure!(
        scratch.exists("src/main.ts"),
        "the replacement screen should be there"
    );
    Ok(())
}

#[test]
fn an_invalid_manifest_is_refused_before_anything_is_written() -> Result<(), Failure> {
    let mut manifest = Manifest::new("Ledger");
    manifest.window_height = 0;

    let error = assert_err!(plan(&manifest), "a zero-height window must be refused");

    // Matched rather than inspected through `matches!` so the reason can be
    // asserted on: the reason is the only thing the developer will see.
    match error {
        InjectionError::InvalidManifest { reason } => {
            assert_contains!(&reason, "1200x0");
        }
        other => {
            return Err(Failure {
                claim: "an invalid manifest should be refused as such".to_owned(),
                actual: format!("{other:?}"),
            });
        }
    }
    Ok(())
}

#[test]
fn the_zig_entry_point_carries_the_manifests_own_values() -> Result<(), Failure> {
    // A template that hardcoded a channel name or a window size would ship a
    // project whose configuration file lies.
    let mut manifest = Manifest::new("Ledger");
    manifest.render_path = RenderPath::Native;
    manifest.window_width = 1024;
    manifest.window_height = 640;

    let planned = planned_for(&manifest)?;
    let zig = contents_of(&planned, "src-lepton/main.zig")?;

    assert_contains!(zig, manifest.channel_name.as_str());
    assert_contains!(zig, "1024");
    assert_contains!(zig, "640");
    assert_contains!(zig, "Ledger");

    // Braces must balance, or the file a developer opens first is a syntax error.
    balanced(zig, '{', '}')
}

#[test]
fn every_typescript_binding_a_template_exports_is_explicitly_typed() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for file in &planned.files {
        if !file.path.ends_with(".ts") {
            continue;
        }
        // Exports are the contract a developer reads, so an exported binding has
        // to say what it is. Internal bindings are left to inference, which
        // TypeScript does correctly.
        for (number, line) in file.contents.lines().enumerate() {
            let trimmed = line.trim_start();
            if !trimmed.starts_with("export const ") {
                continue;
            }
            // An object literal is exempt: every member of it carries its own
            // signature, which is the annotation pushed one level in and is
            // stronger than a single `as`-cast over the whole object would be.
            // Demanding a redundant annotation here would train a reader to
            // write one and then stop reading the members.
            if trimmed.ends_with("= {") {
                continue;
            }
            ensure!(
                trimmed.contains(':') || trimmed.contains("as const"),
                "{}:{} exports a binding with no explicit type: {}",
                file.path,
                number + 1,
                trimmed
            );
        }
    }
    Ok(())
}

#[test]
fn no_template_file_reaches_for_any() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for file in &planned.files {
        for banned in [": any", "as any", "any[]"] {
            ensure!(
                !file.contents.contains(banned),
                "{} contains {banned:?}",
                file.path
            );
        }
    }
    Ok(())
}

#[test]
fn no_planned_path_is_absolute_or_climbs_out_of_the_project() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for file in &planned.files {
        ensure!(!file.path.starts_with('/'), "{} is absolute", file.path);
        ensure!(!file.path.contains(".."), "{} climbs out", file.path);
    }
    Ok(())
}

#[test]
fn a_planning_run_is_deterministic() -> Result<(), Failure> {
    // The same manifest must produce byte-identical files, or a rebuild would
    // churn the working tree for no reason.
    let manifest = Manifest::new("Ledger");
    let first = planned_for(&manifest)?;
    let second = planned_for(&manifest)?;

    assert_eq!(first, second);
    Ok(())
}

#[test]
fn a_native_manifest_names_the_native_path_in_its_config() -> Result<(), Failure> {
    let mut manifest = Manifest::new("Ledger");
    manifest.render_path = RenderPath::Native;

    let planned = planned_for(&manifest)?;

    assert_contains!(
        contents_of(&planned, crate::CONFIG_PATH)?,
        "\"renderPath\": \"native\""
    );
    Ok(())
}

#[test]
fn the_sdk_entry_point_names_its_only_native_obligation() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;
    let ts = contents_of(&planned, "src/lepton.ts")?;

    // The binding reads the mapped region the native side installs and nothing
    // else. One narrow interface is what lets a Servo binding, a WebView2 bridge
    // and a native render path all satisfy the same frontend.
    assert_contains!(ts, "ChannelTransport");
    assert_contains!(ts, "__lepton");
    // And it reaches no further: an `import` of anything would be a dependency
    // the template cannot promise to resolve.
    assert_absent!(ts, "import ");
    Ok(())
}

#[test]
fn the_package_manifest_pins_the_biome_the_configuration_was_checked_against() -> Result<(), Failure>
{
    // A caret range would let a formatter land under a developer between two
    // saves, which is worse than having no formatter at all.
    let planned = planned_for(&Manifest::new("Ledger"))?;
    let package = contents_of(&planned, "package.json")?;

    assert_contains!(package, crate::assets::BIOME_VERSION);
    assert_absent!(package, "^");
    Ok(())
}

#[test]
fn no_template_reaches_the_network() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    for file in &planned.files {
        for banned in ["http://", "https://fonts.", "cdn.", "unpkg", "jsdelivr"] {
            ensure!(
                !file.contents.contains(banned),
                "{} reaches the network via {banned:?}",
                file.path
            );
        }
    }
    Ok(())
}

#[test]
fn every_html_braces_balance() -> Result<(), Failure> {
    let planned = planned_for(&Manifest::new("Ledger"))?;

    balanced(contents_of(&planned, "index.html")?, '<', '>')
}

#[test]
fn applying_a_plan_writes_every_file_and_leaves_the_rest_alone() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("apply"),
        "the scratch directory should be creatable"
    );
    scratch
        .write("src/main.ts", "// the scaffolder's own file\n")
        .map_err(|error| Failure {
            claim: "the frontend's file should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

    let planned = planned_for(&Manifest::new("Ledger"))?;
    let written = assert_ok!(apply(scratch.path(), &planned), "the plan should apply");

    // Only the writes are reported back. A removal is an absence, and listing it
    // alongside the paths that exist would make the summary a list of files a
    // developer then has to check for.
    // Only writes are reported back. A removal is an absence, and listing it among the
    // paths that exist would make the summary a list a developer then has to check.
    let writes = planned
        .files
        .iter()
        .filter(|file| matches!(file.mode, Mode::Write | Mode::MergeJson))
        .count();

    assert_eq!(written.len(), writes);
    for path in &written {
        ensure!(path.is_file(), "{} should exist", path.display());
    }
    ensure!(
        scratch.exists("src/main.ts"),
        "the overwritten file should exist"
    );
    ensure!(
        scratch.exists("src-lepton/build.zig"),
        "the core build should exist"
    );

    // The whole-file write replaced the frontend's file, which is the point: this
    // file is Lepton's.
    ensure!(
        !scratch.read("src/main.ts")?.contains("the scaffolder"),
        "src/main.ts is Lepton's and should be replaced"
    );
    Ok(())
}

#[test]
fn a_merge_keeps_the_scaffolders_scripts() -> Result<(), Failure> {
    // The real shape `create-vite` writes, so this test fails if the merge stops
    // preserving it rather than only if the merge stops working.
    let scratch = assert_ok!(
        Scratch::new("merge"),
        "the scratch directory should be creatable"
    );
    scratch
        .write(
            "package.json",
            "{\n  \"name\": \"ledger\",\n  \"scripts\": {\n    \"dev\": \"vite\",\n    \"build\": \"tsc && vite build\"\n  },\n  \"devDependencies\": {\n    \"typescript\": \"~6.0.2\",\n    \"vite\": \"^8.3.0\"\n  }\n}\n",
        )
        .map_err(|error| Failure {
            claim: "the scaffolder's manifest should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

    let planned = planned_for(&Manifest::new("Ledger"))?;
    assert_ok!(apply(scratch.path(), &planned), "the plan should apply");

    let merged = scratch.read("package.json")?;

    assert_contains!(&merged, "\"dev\"");
    assert_contains!(&merged, "\"vite\"");
    // And Lepton's own additions arrived alongside them.
    assert_contains!(&merged, "biome");
    assert_contains!(&merged, "lepton:dev");
    // `@lepton-desk/api` is deliberately absent: it is not published, and a
    // dependency that cannot resolve would make the first thing a new project
    // does fail.
    assert_absent!(&merged, "@lepton-desk/api");
    Ok(())
}

#[test]
fn a_merge_into_an_unparseable_file_is_refused_rather_than_guessed() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("badjson"),
        "the scratch directory should be creatable"
    );
    scratch
        .write("package.json", "this is not json")
        .map_err(|error| Failure {
            claim: "the file should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

    let planned = planned_for(&Manifest::new("Ledger"))?;
    let error = assert_err!(
        apply(scratch.path(), &planned),
        "a merge into an unparseable file must be refused"
    );

    match error {
        InjectionError::Merge { path, reason } => {
            ensure!(
                path.ends_with("package.json"),
                "the error names the file: {path:?}"
            );
            assert_contains!(&reason, "not valid JSON");
        }
        other => {
            return Err(Failure {
                claim: "the failure should be a merge failure".to_owned(),
                actual: format!("{other:?}"),
            });
        }
    }

    // And the file is untouched: a refused merge must not leave a truncated file.
    assert_eq!(scratch.read("package.json")?, "this is not json");
    Ok(())
}

#[test]
fn a_merge_into_a_missing_file_creates_it() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("nofile"),
        "the scratch directory should be creatable"
    );

    let planned = planned_for(&Manifest::new("Ledger"))?;
    assert_ok!(apply(scratch.path(), &planned), "the plan should apply");

    balanced(&scratch.read("package.json")?, '{', '}')
}

#[test]
fn an_escaping_path_is_refused_before_anything_is_written() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("escape"),
        "the scratch directory should be creatable"
    );

    let hostile = Plan {
        files: vec![
            Injection {
                path: "src/first.ts".to_owned(),
                contents: String::from("// fine"),
                mode: Mode::Write,
            },
            Injection {
                path: "../outside.ts".to_owned(),
                contents: String::from("// not fine"),
                mode: Mode::Write,
            },
        ],
    };

    let error = assert_err!(
        apply(scratch.path(), &hostile),
        "an escaping path must be refused"
    );

    assert_contains!(&error.to_string(), "outside the project");
    // The first file was not written: the whole plan is checked before any of it
    // runs, which is the difference between a refusal and a mess to clean up.
    ensure!(
        !scratch.exists("src/first.ts"),
        "nothing should be written when the plan is refused"
    );
    Ok(())
}

#[test]
fn a_path_that_returns_to_the_root_is_allowed() -> Result<(), Failure> {
    // `a/../b` stays inside the project and is not an escape; refusing it would
    // reject a legitimate path a developer might write.
    let resolved = assert_ok!(
        resolve(
            Path::new("/tmp/project"),
            &Injection {
                path: "src/../index.html".to_owned(),
                contents: String::new(),
                mode: Mode::Write,
            }
        ),
        "a path returning to the root is fine"
    );

    assert_eq!(resolved, Path::new("/tmp/project/index.html"));
    Ok(())
}

#[test]
fn a_leading_current_directory_component_is_dropped_rather_than_made_a_name() -> Result<(), Failure>
{
    // `./src/main.ts` is a path, not a directory called `.`. Treating the component
    // as a name would create a hidden directory and write the file inside it.
    let resolved = assert_ok!(
        resolve(
            Path::new("/tmp/project"),
            &Injection {
                path: "./src/main.ts".to_owned(),
                contents: String::new(),
                mode: Mode::Write,
            }
        ),
        "a leading `./` resolves"
    );

    assert_eq!(resolved, Path::new("/tmp/project/src/main.ts"));
    Ok(())
}

#[test]
fn an_empty_plan_writes_nothing_and_succeeds() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("empty-plan"),
        "the scratch directory should be creatable"
    );

    let written = assert_ok!(
        apply(scratch.path(), &Plan { files: Vec::new() }),
        "an empty plan should apply"
    );

    assert_eq!(written.len(), 0);
    Ok(())
}

#[test]
fn an_absolute_path_is_refused() -> Result<(), Failure> {
    let scratch = assert_ok!(
        Scratch::new("abs"),
        "the scratch directory should be creatable"
    );

    let error = assert_err!(
        resolve(
            scratch.path(),
            &Injection {
                path: "/etc/passwd".to_owned(),
                contents: String::new(),
                mode: Mode::Write,
            }
        ),
        "an absolute path must be refused"
    );

    assert_contains!(&error.to_string(), "outside the project");
    Ok(())
}
