//! What `lepton update` does for the development server's headers (`wasm.threads`).
//!
//! From 0.1.9-beta.3 every template's dev server configuration reads `wasm.threads` from
//! `lepton.config.json` and, when it is on, sends `Cross-Origin-Opener-Policy` and
//! `Cross-Origin-Embedder-Policy`: under `lepton dev` the page comes from that server, not
//! from the core, so the core's own headers never reach it. The file is the developer's,
//! so an older project's is replaced only when it is still the one a template wrote (the
//! released versions are kept in `assets/history/dev-config/`); an edited one is left
//! alone and the lines to add are shown instead. Lit had no configuration file: one is
//! added. Angular's lives in `angular.json`, which cannot read another file.

use crate::base::BaseFrontend;

/// A dev server configuration file a template wrote, as it was released: the template it
/// came from, its name in the project, and its text.
struct Released {
    template: &'static str,
    file: &'static str,
    text: &'static str,
}

macro_rules! released {
    ($template:literal, $dir:literal, $file:literal) => {
        Released {
            template: $template,
            file: $file,
            text: include_str!(concat!("../assets/history/dev-config/", $dir, "/", $file)),
        }
    };
}

const RELEASED: [Released; 17] = [
    released!("vanilla-ts", "vanilla-ts", "vite.config.ts"),
    released!("vanilla-js", "vanilla-js", "vite.config.js"),
    released!("react-ts", "react-ts", "vite.config.ts"),
    released!("react-js", "react-js", "vite.config.ts"),
    released!("react-js", "react-js-older", "vite.config.ts"),
    released!("vue-ts", "vue-ts", "vite.config.ts"),
    released!("vue-js", "vue-js", "vite.config.js"),
    released!("svelte-ts", "svelte-ts", "vite.config.ts"),
    released!("svelte-js", "svelte-js", "vite.config.js"),
    released!("solid-ts", "solid-ts", "vite.config.ts"),
    released!("solid-js", "solid-js", "vite.config.js"),
    released!("preact-ts", "preact-ts", "vite.config.ts"),
    released!("preact-js", "preact-js", "vite.config.js"),
    released!("astro-ts", "astro-ts", "astro.config.mjs"),
    released!("astro-js", "astro-js", "astro.config.mjs"),
    released!("next-ts", "next-ts", "next.config.ts"),
    released!("next-js", "next-js", "next.config.mjs"),
];

/// The files a dev server configuration can be, in the order they are looked for.
const FILES: [&str; 5] = [
    "vite.config.ts",
    "vite.config.js",
    "astro.config.mjs",
    "next.config.ts",
    "next.config.mjs",
];

/// What a Vite or Astro configuration needs, for a developer to add by hand.
const VITE_LINES: &str = r#"import lepton from "./lepton.config.json" with { type: "json" };
// in defineConfig({ … }):
  server: {
    headers: lepton.wasm?.threads
      ? { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" }
      : {},
  },"#;

/// What a Next.js configuration needs (`next dev` only; an export has no server).
const NEXT_LINES: &str = r#"import { PHASE_DEVELOPMENT_SERVER } from "next/constants.js";
import lepton from "./lepton.config.json" with { type: "json" };
// export a function of the phase, and in its config:
  ...(phase === PHASE_DEVELOPMENT_SERVER && lepton.wasm?.threads
    ? { headers: async () => [{ source: "/:path*", headers: [
        { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
        { key: "Cross-Origin-Embedder-Policy", value: "require-corp" } ] }] }
    : {}),"#;

/// What an update does with the project's dev server configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DevHeaders {
    /// The file reads `wasm.threads` already, or the project has none Lepton knows.
    Current,
    /// `file` is written with `text`: a template's file never edited, or Lit's new one.
    Write { file: &'static str, text: String },
    /// `file` was edited: these lines are for the developer to add.
    Show {
        file: &'static str,
        lines: &'static str,
    },
}

/// Decides from the project's files, read by `read` (a path relative to the project).
pub fn decide(read: impl Fn(&str) -> Option<String>) -> DevHeaders {
    for file in FILES {
        let Some(text) = read(file) else { continue };
        if text.contains("Cross-Origin-Embedder-Policy") {
            return DevHeaders::Current;
        }
        let template = RELEASED
            .iter()
            .find(|released| released.file == file && released.text == text)
            .map(|released| released.template);
        return match template.and_then(|template| current(template, file)) {
            Some(text) => DevHeaders::Write { file, text },
            None => DevHeaders::Show {
                file,
                lines: if file.starts_with("next.") {
                    NEXT_LINES
                } else {
                    VITE_LINES
                },
            },
        };
    }
    // Lit: Vite with no configuration of its own.
    let lit = read("package.json").is_some_and(|text| text.contains("\"lit\""));
    if lit {
        let (template, file) = if read("tsconfig.json").is_some() {
            ("lit-ts", "vite.config.ts")
        } else {
            ("lit-js", "vite.config.js")
        };
        if let Some(text) = current(template, file) {
            return DevHeaders::Write { file, text };
        }
    }
    DevHeaders::Current
}

/// An Angular project's `lepton.config.json` with `{isolation}` added to `frontend.devArgs`
/// (`frontend::ISOLATION`); `None` unless the list is the one `lepton new` wrote before it.
/// Compared as JSON and changed in place, so a file laid out by hand or by Biome keeps
/// its layout.
pub fn angular_dev_args(config: &str) -> Option<String> {
    let root: serde_json::Value = serde_json::from_str(config).ok()?;
    let args = root.pointer("/frontend/devArgs")?.as_array()?;
    let before = ["--port", "{port}", "--host", "{host}"];
    if args.len() != before.len() || args.iter().zip(before).any(|(arg, old)| arg != old) {
        return None;
    }
    let key = config.find("\"devArgs\"")?;
    let close = key + config[key..].find(']')?;
    let last = config[..close].rfind('"')? + 1;
    Some(format!(
        "{}, \"{{isolation}}\"{}",
        &config[..last],
        &config[last..]
    ))
}

/// Today's file of `template`, as `lepton new` writes it.
fn current(template: &str, file: &str) -> Option<String> {
    let embedded = BaseFrontend::get(&format!("{template}/{file}"))?;
    String::from_utf8(embedded.data.into_owned()).ok()
}

#[cfg(test)]
mod tests {
    use super::{DevHeaders, RELEASED, current, decide};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};
    use std::collections::HashMap;

    fn project(files: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let files: HashMap<String, String> = files
            .iter()
            .map(|(name, text)| ((*name).to_owned(), (*text).to_owned()))
            .collect();
        move |name| files.get(name).cloned()
    }

    #[test]
    fn every_released_file_becomes_todays_template() -> Result<(), Failure> {
        for released in RELEASED {
            let Some(today) = current(released.template, released.file) else {
                return Err(Failure {
                    claim: format!("{} has a {}", released.template, released.file),
                    actual: "nothing embedded".to_owned(),
                });
            };
            let expected = DevHeaders::Write {
                file: released.file,
                text: today,
            };
            assert_eq!(decide(project(&[(released.file, released.text)])), expected);
        }
        Ok(())
    }

    #[test]
    fn todays_templates_are_current() -> Result<(), Failure> {
        for released in RELEASED {
            let today = current(released.template, released.file).unwrap_or_default();
            ensure!(
                today.contains("Cross-Origin-Embedder-Policy"),
                "{} sends the headers",
                released.template
            );
            assert_eq!(
                decide(project(&[(released.file, &today)])),
                DevHeaders::Current
            );
        }
        Ok(())
    }

    #[test]
    fn an_edited_file_is_left_alone_with_the_lines_to_add() -> Result<(), Failure> {
        let edited = format!("{}// mine\n", RELEASED[0].text);
        let decision = decide(project(&[("vite.config.ts", &edited)]));
        ensure!(
            matches!(decision, DevHeaders::Show { file: "vite.config.ts", lines } if lines.contains("wasm?.threads")),
            "an edited Vite file is shown the lines, got {decision:?}"
        );
        let next = decide(project(&[("next.config.mjs", "export default {};\n")]));
        ensure!(
            matches!(next, DevHeaders::Show { lines, .. } if lines.contains("PHASE_DEVELOPMENT_SERVER")),
            "Next gets its own lines, got {next:?}"
        );
        Ok(())
    }

    #[test]
    fn an_angular_projects_flags_get_the_placeholder_once() -> Result<(), Failure> {
        let mut manifest = crate::manifest::Manifest::new("Ledger");
        manifest.target = crate::manifest::Target::Angular;
        let today = crate::manifest::render_manifest(&manifest);
        ensure!(today.contains("{isolation}"), "a new project has it");
        let before = today.replace(r#", "{isolation}""#, "");
        assert_eq!(super::angular_dev_args(&before), Some(today.clone()));
        assert_eq!(super::angular_dev_args(&today), None::<String>);
        let spread = before.replace(
            r#""devArgs": ["--port", "{port}", "--host", "{host}"]"#,
            "\"devArgs\": [\n      \"--port\",\n      \"{port}\",\n      \"--host\",\n      \"{host}\"\n    ]",
        );
        ensure!(spread != before, "the list was spread over lines");
        let added = super::angular_dev_args(&spread).unwrap_or_default();
        ensure!(
            added.contains("\"{host}\", \"{isolation}\"\n    ]"),
            "added in place, layout kept: {added}"
        );
        Ok(())
    }

    #[test]
    fn lit_gets_a_configuration_and_angular_nothing() -> Result<(), Failure> {
        let lit = decide(project(&[
            ("package.json", r#"{"dependencies":{"lit":"^3.3.3"}}"#),
            ("tsconfig.json", "{}"),
        ]));
        ensure!(
            matches!(&lit, DevHeaders::Write { file: "vite.config.ts", text } if text.contains("Cross-Origin-Opener-Policy")),
            "a Lit project gets vite.config.ts, got {lit:?}"
        );
        assert_eq!(
            decide(project(&[(
                "package.json",
                r#"{"dependencies":{"@angular/core":"^22"}}"#
            )])),
            DevHeaders::Current
        );
        Ok(())
    }
}
