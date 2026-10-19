//! The template files a project is built from.
//!
//! Each asset lives as a real file under `assets/` and is embedded at compile
//! time. Keeping them as files rather than as string literals in Rust buys three
//! things a literal cannot: the CSS can be read and checked as CSS, the Zig can be
//! compiled by `zig fmt`, and a reviewer diffing a template change sees the change
//! to the template rather than to a string literal inside a function.
//!
//! Embedding rather than copying is deliberate: the files ship inside the CLI's
//! binary, so `lepton new` works with no network and no templates directory beside
//! the binary.

/// The starter stylesheet, in the world's own material.
pub const STYLESHEET: &str = include_str!("../assets/lepton-sdk.css");

/// The TypeScript entry point that binds the SDK to the window.
pub const SDK_ENTRY: &str = include_str!("../assets/lepton.ts");

/// The screen the project starts with: this machine, read through the channel.
pub const MAIN_ENTRY: &str = include_str!("../assets/main.ts");

/// The arithmetic the measures screen is built from, shared by every frontend.
///
/// Framework-neutral on purpose: `duration` and `bytes` decide what a number means, and
/// that does not change when the screen is written in React. See the file for why this is
/// a separate module rather than part of a view.
pub const MEASURES: &str = include_str!("../assets/measures.ts");

/// The React view over `MEASURES`, and the entry that mounts it.
pub const REACT_SCREEN: &str = include_str!("../assets/react/App.tsx");
pub const REACT_ENTRY: &str = include_str!("../assets/react/main.tsx");

/// The JavaScript forms of every injected source, generated from the TypeScript above.
///
/// Committed rather than produced on demand because the CLI must scaffold a project
/// without a Node toolchain — that is the property this framework cares most about, and
/// a build step that needs `tsc` would trade it for a convenience. `tools/transpile-assets.mjs`
/// is what writes them, and it can also check them, which is what keeps the two forms
/// from drifting.
pub const JS_SDK_ENTRY: &str = include_str!("../assets/js/lepton.js");
pub const JS_MEASURES: &str = include_str!("../assets/js/measures.js");
pub const JS_MAIN_ENTRY: &str = include_str!("../assets/js/main.js");
pub const JS_REACT_SCREEN: &str = include_str!("../assets/js/react/App.jsx");
pub const JS_REACT_ENTRY: &str = include_str!("../assets/js/react/main.jsx");

/// The document the bundler's entry script is loaded into.
///
/// Taken apart rather than used whole because the entry script's extension depends on the
/// project's language: a document that loads `/src/main.ts` into a JavaScript project
/// points at a file that was never written, and the failure is a blank window rather
/// than a build error.
const INDEX_HTML_TEMPLATE: &str = include_str!("../assets/index.html");

/// The document for a project, naming the host element and entry its framework expects,
/// titled `title` — the window shows the page's title, so a fixed "Lepton" here named
/// every application's window "Lepton" (measured).
///
/// Both follow the framework rather than the language. React mounts into `#root` and
/// everyone else into `#app`, and React's entry carries JSX so it is `.tsx` or `.jsx`
/// rather than `.ts` or `.js`. Getting either wrong does not fail the build — it opens a
/// window with nothing in it — so it is decided here once rather than per template.
pub fn index_html(
    target: crate::manifest::Target,
    language: crate::manifest::Language,
    title: &str,
) -> String {
    let (host, extension) = match target {
        crate::manifest::Target::React
        | crate::manifest::Target::Solid
        | crate::manifest::Target::Preact => (
            "root",
            match language {
                crate::manifest::Language::TypeScript => "tsx",
                crate::manifest::Language::JavaScript => "jsx",
            },
        ),
        _ => ("app", language.extension()),
    };

    let escaped = title
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    INDEX_HTML_TEMPLATE
        .replace("/src/main.ts", &format!("/src/main.{extension}"))
        .replace("id=\"app\"", &format!("id=\"{host}\""))
        .replace("{title}", &escaped)
}

/// The linter and formatter, pre-configured.
///
/// Present as a real file rather than as a string because it is the one asset a
/// developer edits, and a file is something an editor can complete and a diff can
/// show. Its schema is checked by the Biome the template installs, not by a claim
/// made here.
pub const BIOME_CONFIG: &str = include_str!("../assets/biome.json");

/// The core's build file.
///
/// Assembled here rather than shipped whole because it has to import the vendored
/// core's own build logic, and the path to that core is the one thing about a project
/// that is not known until the project exists.
pub const ZIG_BUILD: &str = include_str!("../assets/lepton-build.zig");

/// The Vue, Svelte and Solid screens and entries: the same measures screen as React's,
/// in each framework's own idiom, over the same `measures.ts` and `lepton-sdk.css`.
pub const VUE_ENTRY: &str = include_str!("../assets/vue/main.ts");
pub const VUE_SCREEN: &str = include_str!("../assets/vue/App.vue");
pub const SVELTE_ENTRY: &str = include_str!("../assets/svelte/main.ts");
pub const SVELTE_SCREEN: &str = include_str!("../assets/svelte/App.svelte");
pub const SOLID_ENTRY: &str = include_str!("../assets/solid/main.tsx");
pub const SOLID_SCREEN: &str = include_str!("../assets/solid/App.tsx");

/// Their JavaScript forms, generated by `tools/transpile-assets.mjs`.
pub const JS_VUE_ENTRY: &str = include_str!("../assets/js/vue/main.js");
pub const JS_VUE_SCREEN: &str = include_str!("../assets/js/vue/App.vue");
pub const JS_SVELTE_ENTRY: &str = include_str!("../assets/js/svelte/main.js");
pub const JS_SVELTE_SCREEN: &str = include_str!("../assets/js/svelte/App.svelte");
pub const JS_SOLID_ENTRY: &str = include_str!("../assets/js/solid/main.jsx");
pub const JS_SOLID_SCREEN: &str = include_str!("../assets/js/solid/App.jsx");

/// Preact's screen is React's with Preact's imports; Lit's is a `<measures-screen>` element.
pub const PREACT_ENTRY: &str = include_str!("../assets/preact/main.tsx");
pub const PREACT_SCREEN: &str = include_str!("../assets/preact/App.tsx");
pub const JS_PREACT_ENTRY: &str = include_str!("../assets/js/preact/main.jsx");
pub const JS_PREACT_SCREEN: &str = include_str!("../assets/js/preact/App.jsx");
pub const LIT_ENTRY: &str = include_str!("../assets/lit/main.ts");
pub const LIT_SCREEN: &str = include_str!("../assets/lit/measures-screen.ts");
pub const JS_LIT_ENTRY: &str = include_str!("../assets/js/lit/main.js");
pub const JS_LIT_SCREEN: &str = include_str!("../assets/js/lit/measures-screen.js");

/// Frameworks with their own pages and server (`frame_pages.rs`). Astro's page loads the
/// plain-DOM screen; Next.js renders React's `App` from a page loaded in the window only;
/// Angular's is a component. `{title}` is filled per project.
pub const ASTRO_PAGE: &str = include_str!("../assets/astro/index.astro");
pub const NEXT_LAYOUT: &str = include_str!("../assets/next/layout.tsx");
pub const NEXT_PAGE: &str = include_str!("../assets/next/page.tsx");
pub const NEXT_SCREEN: &str = include_str!("../assets/next/Screen.tsx");
pub const JS_NEXT_LAYOUT: &str = include_str!("../assets/js/next/layout.jsx");
pub const JS_NEXT_PAGE: &str = include_str!("../assets/js/next/page.jsx");
pub const JS_NEXT_SCREEN: &str = include_str!("../assets/js/next/Screen.jsx");
pub const ANGULAR_ENTRY: &str = include_str!("../assets/angular/main.ts");
pub const ANGULAR_SCREEN: &str = include_str!("../assets/angular/app.ts");
pub const ANGULAR_INDEX: &str = include_str!("../assets/angular/index.html");

/// The generator `build.zig` runs to write the TypeScript names of the application's
/// commands (`zig-out/lepton-commands.d.ts`).
pub const COMMAND_TYPES: &str = include_str!("../assets/lepton-commands.zig");

/// Biome's version, pinned.
///
/// The exact version the template's `biome.json` was checked against, not a range:
/// Biome's configuration schema changes between majors and a formatter that moves
/// under a developer mid-file is worse than no formatter. A project's own upgrade is
/// one `package.json` edit away, and the schema is validated by the tool itself.
pub const BIOME_VERSION: &str = "2.5.15";

/// What Lepton adds to a project's `package.json`.
///
/// Returned as JSON rather than merged here because the file itself belongs to the
/// frontend: `create-vite` wrote it first, and this content goes into it through
/// `crate::merge`, which is the one place that knows how to add a key without
/// deleting the ones already there.
///
/// `@lepton-desk/api` is the page's SDK (`invoke`, `listen`, the window); `@lepton-desk/cli`
/// is a dev dependency so `pnpm lepton:dev` runs the CLI from `node_modules` on a machine
/// without a global install. Both are pinned to a range that starts at this CLI's own
/// version: the generated `lepton-commands.d.ts` and the core's frame layout are this
/// version's, and an older SDK would read neither.
pub fn package_manifest(plugins: &[&str]) -> String {
    let mut dependencies = format!(
        "    \"@lepton-desk/api\": \"^{}\"",
        env!("CARGO_PKG_VERSION")
    );
    for name in plugins {
        if let Some(plugin) = crate::plugin_catalog::find(name) {
            dependencies.push_str(&format!(
                ",\n    \"{}\": \"^{}\"",
                plugin.package,
                env!("CARGO_PKG_VERSION")
            ));
        }
    }
    format!(
        concat!(
            "{{\n",
            "  \"scripts\": {{\n",
            // One script, as Tauri's `"tauri": "tauri"`: `npm run lepton dev`,
            // `pnpm lepton build`, `yarn lepton record`, … — every command, not two.
            "    \"lepton\": \"lepton\",\n",
            "    \"check\": \"biome check .\",\n",
            "    \"format\": \"biome format --write .\"\n",
            "  }},\n",
            "  \"dependencies\": {{\n",
            "{dependencies}\n",
            "  }},\n",
            "  \"devDependencies\": {{\n",
            "    \"@biomejs/biome\": \"{biome}\",\n",
            "    \"@lepton-desk/cli\": \"^{version}\"\n",
            "  }}\n",
            "}}\n"
        ),
        biome = BIOME_VERSION,
        dependencies = dependencies,
        version = env!("CARGO_PKG_VERSION"),
    )
}

/// The Zig entry point, with its placeholders filled from a project's manifest.
///
/// The asset carries `{product}`, `{channel}`, `{title}` and `{identifier}` as
/// literal placeholders rather than a template engine's
/// syntax: a reader opening `assets/main.zig` sees exactly what will be replaced
/// and where, which a mini-language would hide.
const ZIG_ENTRY_TEMPLATE: &str = include_str!("../assets/main.zig");

/// Fills the Zig entry point's placeholders from a manifest.
///
/// The walk is left to right and never rescans what it has already written. That is
/// the whole reason this is hand-written: a chain of `replace` calls would rescan its
/// own output, so a project whose title contains a brace would have the following
/// placeholder eaten as well.
///
/// ## Braces
///
/// A Zig struct literal is full of braces and every one of them would otherwise look
/// like the start of a placeholder. The asset writes them doubled — `.{{` for `.{` —
/// and this function collapses each pair. The doubling lives here rather than in the
/// asset's own text because the asset is a real `.zig` file: it is read by whoever
/// opens it, and a file full of doubled braces is neither valid Zig nor what a reader
/// expects to see.
pub fn zig_entry(
    product_name: &str,
    channel_name: &str,
    window_title: &str,
    identifier: &str,
) -> String {
    // The window size is not among them: it reaches the core as a build option
    // (`-Dwindow-width`), so `lepton.config.json` stays the source after `lepton new`.
    let values: [(&str, &str); 4] = [
        ("{product}", product_name),
        ("{channel}", channel_name),
        ("{title}", window_title),
        ("{identifier}", identifier),
    ];
    fill(ZIG_ENTRY_TEMPLATE, &values)
}

/// [`zig_entry`]'s walk over any entry template: the current one, or a released one that
/// `lepton update` compares a project against (those also carry `{width}` and `{height}`).
/// A placeholder missing from `values` is copied through as written.
pub fn fill(template: &str, values: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len() + 256);
    let mut rest = template;

    'scan: while !rest.is_empty() {
        let Some(open) = rest.find('{') else {
            out.push_str(rest);
            break;
        };
        let tail = &rest[open..];

        // A placeholder first, so `{title}` is never mistaken for an escaped brace.
        for &(placeholder, value) in values {
            if let Some(after) = tail.strip_prefix(placeholder) {
                out.push_str(&rest[..open]);
                out.push_str(value);
                rest = after;
                continue 'scan;
            }
        }

        // An escaped brace: one brace written, and the second consumed with it.
        if let Some(after) = tail.strip_prefix("{{") {
            out.push_str(&rest[..open]);
            out.push('{');
            rest = after;
            continue 'scan;
        }

        // A brace that starts no placeholder and no escape is literal text, and is
        // copied through. Swallowing it would quietly corrupt the file.
        out.push_str(&rest[..open + 1]);
        rest = &rest[open + 1..];
    }

    // The closing braces are collapsed afterwards rather than inside the loop: there is
    // nothing for them to be confused with, and folding them in would mean scanning
    // for a character that is not a marker.
    let mut collapsed = out.replace("}}", "}");

    // Returned rather than written back: `replace` builds a new `String`, and writing
    // it back would leave two buffers where one was needed.
    collapsed.shrink_to_fit();
    collapsed
}

#[cfg(test)]
mod tests {
    use super::{
        BIOME_CONFIG, COMMAND_TYPES, INDEX_HTML_TEMPLATE, MAIN_ENTRY, SDK_ENTRY, SOLID_ENTRY,
        SOLID_SCREEN, STYLESHEET, SVELTE_ENTRY, SVELTE_SCREEN, VUE_ENTRY, VUE_SCREEN, ZIG_BUILD,
        index_html, zig_entry,
    };
    #[test]
    fn no_generated_javascript_carries_typescript_syntax() -> Result<(), Failure> {
        // The generated JavaScript is what a `vanilla-js` or `react-js` project actually
        // runs, and a `import type` left in it is a parse error at build time — which is
        // how the JavaScript variants were found broken. This is the cheapest guard that
        // catches it without a JavaScript toolchain in the test suite.
        //
        // Byte-equality with the sources is the other half, and it needs `tsc`; that is
        // what `tools/transpile-assets.mjs --check` is for, and it runs in continuous
        // integration rather than here.
        for source in [
            super::JS_SDK_ENTRY,
            super::JS_MEASURES,
            super::JS_MAIN_ENTRY,
            super::JS_REACT_SCREEN,
            super::JS_REACT_ENTRY,
        ] {
            // Narrower than it looks: the compiler keeps comments, and a comment
            // naturally contains the English words "as" and "string", so a list of bare
            // type keywords would fail on prose. These four are the shapes a
            // transpile cannot leave behind by accident.
            for banned in ["export interface", "import type", "satisfies ", "as const"] {
                assert_absent!(source, banned);
            }
        }
        Ok(())
    }

    #[test]
    fn every_generated_file_names_the_source_it_came_from() -> Result<(), Failure> {
        // A developer who opens `src/lepton.js` in a JavaScript project deserves to know
        // it is generated, because the obvious thing to do with a generated file is edit
        // it — and the edit would vanish on the next run without warning.
        for (source, from) in [
            (super::JS_SDK_ENTRY, "lepton.ts"),
            (super::JS_MEASURES, "measures.ts"),
            (super::JS_MAIN_ENTRY, "main.ts"),
            (super::JS_REACT_SCREEN, "react/App.tsx"),
            (super::JS_REACT_ENTRY, "react/main.tsx"),
        ] {
            assert_contains!(source, "Generated from");
            assert_contains!(source, from);
        }
        Ok(())
    }

    #[test]
    fn the_generated_javascript_points_at_javascript() -> Result<(), Failure> {
        // The compiler leaves import specifiers as written, so a `./lepton.ts` in the
        // source would have become a `./lepton.ts` in the JavaScript — pointing at a file
        // the JavaScript variant does not contain. Resolution failure at run time, not
        // at build time, which is worse.
        for source in [
            super::JS_SDK_ENTRY,
            super::JS_MAIN_ENTRY,
            super::JS_MEASURES,
            super::JS_REACT_SCREEN,
            super::JS_REACT_ENTRY,
        ] {
            assert_absent!(source, ".ts\"");
            assert_absent!(source, ".tsx\"");
        }
        Ok(())
    }

    #[test]
    fn the_document_names_the_host_and_entry_its_framework_actually_wrote() -> Result<(), Failure> {
        // A document that loads `/src/main.ts` into a JavaScript project, or that hands
        // React an `#app` it does not mount into, points at nothing that was written — and
        // the failure is a blank window rather than a build error, which is the worst
        // place for a mismatch to live.
        use crate::manifest::{Language, Target};

        for (target, language, host, entry) in [
            (
                Target::VanillaTs,
                Language::TypeScript,
                "id=\"app\"",
                "/src/main.ts",
            ),
            (
                Target::VanillaTs,
                Language::JavaScript,
                "id=\"app\"",
                "/src/main.js",
            ),
            (
                Target::React,
                Language::TypeScript,
                "id=\"root\"",
                "/src/main.tsx",
            ),
            (
                Target::React,
                Language::JavaScript,
                "id=\"root\"",
                "/src/main.jsx",
            ),
        ] {
            let document = index_html(target, language, "Notes");
            assert_contains!(&document, host);
            assert_contains!(&document, entry);
        }
        Ok(())
    }

    #[test]
    fn the_document_is_titled_with_the_window_title() -> Result<(), Failure> {
        // The window follows the page's title: a fixed one renamed every window.
        use crate::manifest::{Language, Target};

        let document = index_html(Target::VanillaTs, Language::TypeScript, "Rec <Notes> & Co");
        assert_contains!(&document, "<title>Rec &lt;Notes&gt; &amp; Co</title>");
        assert_absent!(&document, "Lepton</title>");
        Ok(())
    }

    #[test]
    fn a_react_document_never_names_the_plain_dom_entry() -> Result<(), Failure> {
        // The mistake this guards against is quiet in both directions: a React project
        // given `/src/main.ts` builds, runs and mounts nothing.
        use crate::manifest::{Language, Target};

        let document = index_html(Target::React, Language::TypeScript, "Notes");
        // Compared as the whole attribute, not as a substring: `/src/main.ts` is a
        // prefix of `/src/main.tsx`, so the loose form would fail on a correct document.
        assert_absent!(&document, "src=\"/src/main.ts\"");
        assert_absent!(&document, "id=\"app\"");
        Ok(())
    }

    use lepton_orchestrator::testing::{Failure, balanced};
    use lepton_orchestrator::{assert_absent, assert_contains, assert_eq, assert_ok, ensure};

    /// Fills the Zig entry point the way the plan does.
    fn entry() -> String {
        zig_entry("Ledger", "/lepton-ledger", "Ledger", "com.example.ledger")
    }

    #[test]
    fn every_asset_is_embedded_and_non_empty() -> Result<(), Failure> {
        for (name, asset) in [
            ("the stylesheet", STYLESHEET),
            ("the channel binding", SDK_ENTRY),
            ("the screen", MAIN_ENTRY),
            ("the document", INDEX_HTML_TEMPLATE),
            ("the Biome configuration", BIOME_CONFIG),
            ("the core build file", ZIG_BUILD),
            ("the command types generator", COMMAND_TYPES),
            ("the Vue entry", VUE_ENTRY),
            ("the Vue screen", VUE_SCREEN),
            ("the Svelte entry", SVELTE_ENTRY),
            ("the Svelte screen", SVELTE_SCREEN),
            ("the Solid entry", SOLID_ENTRY),
            ("the Solid screen", SOLID_SCREEN),
        ] {
            ensure!(asset.len() > 100, "{name} should not be empty");
            ensure!(asset.ends_with('\n'), "{name} should end with a newline");
        }
        Ok(())
    }

    #[test]
    fn the_zig_entry_has_no_placeholders_left_after_substitution() -> Result<(), Failure> {
        let rendered = entry();

        for placeholder in [
            "{product}",
            "{channel}",
            "{title}",
            "{identifier}",
            "{width}",
            "{height}",
        ] {
            assert_absent!(&rendered, placeholder);
        }
        assert_contains!(&rendered, "/lepton-ledger");
        // The size comes from the build, never from numbers written here once.
        assert_contains!(&rendered, "options.window_width");
        balanced(&rendered, '{', '}')
    }

    #[test]
    fn a_value_containing_a_brace_does_not_break_the_substitution() -> Result<(), Failure> {
        // The failure this guards is a silent one. A title of `{identifier}` puts a brace
        // into the output at exactly the place a `replace`-based substitution would
        // rescan, and the identifier that follows would then be filled with the title's
        // text instead of the real one.
        let rendered = zig_entry("Ledger", "{channel}", "{identifier}", "com.example");

        // The value survives verbatim, which is correct: it is the developer's text.
        // Asserted through the channel name rather than the window title, because the
        // channel is the first substituted value in the entry point and a brace in it
        // lands earlier — before any escaping has had a chance to run.
        assert_contains!(&rendered, "\"{channel}\"");
        // And the placeholder after it was filled from the real argument, which is the
        // property that a rescan would have destroyed.
        assert_contains!(&rendered, "\"com.example\"");
        balanced(&rendered, '{', '}')
    }

    #[test]
    fn the_rendered_entry_point_is_valid_zig() -> Result<(), Failure> {
        // `zig fmt` parses the file and rewrites it, so a syntax error is reported
        // rather than ignored. This is the check that catches a placeholder or an
        // escaped brace left behind: both produce a file that compiles in every other
        // respect and fails at the first token.
        let scratch = assert_ok!(
            lepton_orchestrator::testing::Scratch::new("zig-entry"),
            "the scratch directory should be creatable"
        );
        let path = scratch.path().join("main.zig");
        std::fs::write(&path, entry()).map_err(|error| Failure {
            claim: "the rendered entry point should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        // A formatter this build cannot find is reported rather than skipped: a test
        // that quietly does nothing when a tool is missing is a test that stops
        // testing without saying so.
        let mut step = lepton_orchestrator::Step::capturing("zig", "zig");
        step = step
            .arg("fmt")
            .arg("--check")
            .arg(path.display().to_string());

        let outcome = lepton_orchestrator::run(&step);
        match outcome {
            Ok(captured) => {
                ensure!(
                    captured.stderr.is_empty(),
                    "zig fmt reported something:\n{}",
                    captured.stderr
                );
                Ok(())
            }
            Err(error) => Err(Failure {
                claim: "the rendered entry point should be valid Zig".to_owned(),
                actual: format!("{error}\n{}", entry()),
            }),
        }
    }

    #[test]
    fn the_rendered_entry_point_has_no_escaped_brace_left() -> Result<(), Failure> {
        // The doubled braces are the asset's convention, not the file's. One left
        // behind is `= .{` followed by `{`, which is a syntax error two tokens later
        // and reads as though the struct literal were nested.
        let rendered = entry();

        assert_absent!(&rendered, "{{");
        assert_absent!(&rendered, "}}");
        Ok(())
    }

    #[test]
    fn a_braces_only_title_is_substituted_verbatim() -> Result<(), Failure> {
        let rendered = zig_entry("Ledger", "/ch", "{}", "com.example");

        // The braces in the value must survive: a template engine that rescans its
        // output would eat them.
        assert_contains!(&rendered, "{}");
        Ok(())
    }

    #[test]
    fn the_stylesheet_defines_the_four_roles_and_uses_the_spot_once() -> Result<(), Failure> {
        for role in ["--lp-bed", "--lp-face", "--lp-groove", "--lp-spot"] {
            ensure!(STYLESHEET.contains(role), "{role} should be defined");
        }
        // The variable is read once. A second reader would give the panel's only
        // accent two meanings, which is the same as having none.
        assert_eq!(STYLESHEET.matches("var(--lp-spot)").count(), 1);
        Ok(())
    }

    #[test]
    fn the_stylesheet_references_no_network_resource() -> Result<(), Failure> {
        // A CDN in a template would make a built desktop application fail the moment
        // it went offline, which for a desktop app is not an edge case.
        for forbidden in ["https://", "http://", "fonts.googleapis", "cdn."] {
            assert_absent!(STYLESHEET, forbidden);
        }
        Ok(())
    }

    #[test]
    fn the_stylesheet_names_a_real_face_rather_than_a_system_default() -> Result<(), Failure> {
        // A face declared from a `url()` is a request the project has to satisfy, and
        // a template whose request 404s teaches the developer that a starter is allowed
        // to arrive broken. So the type is set from faces already on the machine.
        // Checked for the declaration, not the word: the sheet explains in a comment
        // why there is no `@font-face`, and asserting on the bare word would forbid
        // the explanation too.
        assert_absent!(STYLESHEET, "@font-face {");
        assert_absent!(STYLESHEET, ".woff2");
        for banned in ["Inter", "Roboto", "system-ui", "Arial", "ui-monospace"] {
            assert_absent!(STYLESHEET, banned);
        }
        // A serif and a mono, so the sheet's two roles are actually distinct.
        ensure!(STYLESHEET.contains("Charter"), "a text face must be named");
        ensure!(
            STYLESHEET.contains("DejaVu Sans Mono"),
            "a mono face must be named"
        );
        Ok(())
    }

    #[test]
    fn the_stylesheet_themes_what_the_browser_owns_by_default() -> Result<(), Failure> {
        // Selection and the scrollbar ship with no design system of their own; left
        // alone they are the brightest thing on a cold ground.
        ensure!(
            STYLESHEET.contains("::selection"),
            "selection must be themed"
        );
        ensure!(
            STYLESHEET.contains("scrollbar-color"),
            "the scrollbar must be themed"
        );
        ensure!(
            STYLESHEET.contains("prefers-reduced-motion"),
            "a motion query is mandatory"
        );
        ensure!(
            STYLESHEET.contains("font-variant-numeric: tabular-nums"),
            "measure numerals must be tabular"
        );
        Ok(())
    }

    #[test]
    fn the_stylesheet_balances() -> Result<(), Failure> {
        balanced(STYLESHEET, '{', '}')
    }

    #[test]
    fn the_typescript_assets_carry_no_any() -> Result<(), Failure> {
        // A template is the first thing a developer copies. An `any` in one teaches
        // the reader the one thing the framework's type system exists to prevent.
        for asset in [SDK_ENTRY, MAIN_ENTRY] {
            assert_absent!(asset, ": any");
            assert_absent!(asset, "as any");
            assert_absent!(asset, "any[]");
        }
        Ok(())
    }

    #[test]
    fn the_binding_covers_every_field_the_cores_sample_carries() -> Result<(), Failure> {
        // One for each field of `wire.zig`'s `Sample`. A field the core publishes and
        // the binding does not declare is a measurement nobody can read, and the
        // omission is invisible until someone goes looking for it.
        for field in [
            "timestampNs",
            "rssBytes",
            "heapHighWaterBytes",
            "heapInUseBytes",
            "ringFreeCells",
            "ringCapacityCells",
            "roundTripNs",
            "roundTripMaxNs",
        ] {
            ensure!(SDK_ENTRY.contains(field), "{field} should be declared");
        }
        Ok(())
    }

    #[test]
    fn the_binding_states_the_layout_it_reads() -> Result<(), Failure> {
        // The offsets come from the core (`transport.zig` derives them from the structs
        // it writes); the binding must read them from the transport and must not grow a
        // hand-written copy again — the first one guessed a layout no core ever wrote.
        for marker in [
            "ChannelLayout",
            "transport.layout",
            "layout.sample",
            "layout.cellSeqOffset",
            "getBigUint64",
        ] {
            ensure!(SDK_ENTRY.contains(marker), "{marker} should be present");
        }
        for stale in [
            "HEADER_BYTES",
            "KIND_SAMPLE",
            "PROTOCOL_VERSION",
            "slotCount",
        ] {
            ensure!(
                !SDK_ENTRY.contains(stale),
                "{stale} is a hand-written layout and must not return"
            );
        }
        Ok(())
    }

    #[test]
    fn no_asset_reaches_the_network() -> Result<(), Failure> {
        // A desktop application that fails the moment it goes offline is not a desktop
        // application. The one `https://` allowed is a JSON schema an editor reads.
        for (name, asset) in [
            ("the stylesheet", STYLESHEET),
            ("the channel binding", SDK_ENTRY),
            ("the screen", MAIN_ENTRY),
            ("the document", INDEX_HTML_TEMPLATE),
        ] {
            for banned in [
                "http://",
                "https://",
                "fonts.googleapis",
                "unpkg",
                "jsdelivr",
            ] {
                ensure!(
                    !asset.contains(banned),
                    "{name} reaches the network via {banned:?}"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn the_screen_reports_a_missing_core_rather_than_zeroes() -> Result<(), Failure> {
        // The failure this guards is the whole point of the screen: a number on it
        // that no measurement produced.
        for asset in [SDK_ENTRY, MAIN_ENTRY] {
            assert_absent!(asset, "timestampNs: 0n,");
        }
        ensure!(
            SDK_ENTRY.contains("measures: sample"),
            "a missing reading should be null, not a zero-filled struct"
        );
        Ok(())
    }
}
