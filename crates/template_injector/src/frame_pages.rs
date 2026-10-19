//! The files of a framework that brings its own pages and server: Astro, Next.js, Angular.
//!
//! A Vite template gets `index.html` and `src/main.*`; these frameworks have no such pair.
//! Astro renders `src/pages/*.astro`, Next.js `app/`, Angular `src/index.html` with a
//! bootstrapped component. Each still gets every Lepton file a Vite project gets —
//! `lepton.ts`, `measures.ts`, the stylesheet, `src-lepton/` — and the same screen, in its
//! own form (measured in a window, 2026-10-19: the table filled from the shared channel
//! under `lepton run` and `lepton dev` for all three).

use crate::manifest::{Language, Manifest, Target, json_string};
use crate::plan::{Injection, Mode};

/// Whether `target` brings its own pages: no `index.html` is written for it.
pub fn own_pages(target: Target) -> bool {
    target.frontend().is_some()
}

/// Whether the plain-DOM `src/main.*` entry is part of the project. Astro's page loads it;
/// Next.js and Angular start from their own files.
pub fn uses_plain_entry(target: Target) -> bool {
    !matches!(target, Target::Next | Target::Angular)
}

/// The framework's own files for `manifest`, or nothing for a Vite template.
pub fn injections(manifest: &Manifest) -> Vec<Injection> {
    let javascript = manifest.language == Language::JavaScript;
    let title = &manifest.window_title;
    let files: Vec<(String, String)> = match manifest.target {
        Target::Astro => vec![(
            String::from("src/pages/index.astro"),
            crate::assets::ASTRO_PAGE
                // The frontmatter's string, not the `{title}` expression in `<title>`.
                .replace("\"{title}\"", &json_string(title))
                .replace(
                    "\"../main.ts\"",
                    &format!("\"../main.{}\"", manifest.language.extension()),
                ),
        )],
        Target::Next => {
            let (jsx, layout, page, screen, app) = if javascript {
                (
                    "jsx",
                    crate::assets::JS_NEXT_LAYOUT,
                    crate::assets::JS_NEXT_PAGE,
                    crate::assets::JS_NEXT_SCREEN,
                    crate::assets::JS_REACT_SCREEN,
                )
            } else {
                (
                    "tsx",
                    crate::assets::NEXT_LAYOUT,
                    crate::assets::NEXT_PAGE,
                    crate::assets::NEXT_SCREEN,
                    crate::assets::REACT_SCREEN,
                )
            };
            vec![
                (
                    format!("app/layout.{jsx}"),
                    layout.replace("\"{title}\"", &json_string(title)),
                ),
                (format!("app/page.{jsx}"), page.to_owned()),
                (format!("src/Screen.{jsx}"), screen.to_owned()),
                // React's screen, as the React template has it.
                (format!("src/App.{jsx}"), app.to_owned()),
            ]
        }
        Target::Angular => vec![
            (
                String::from("src/index.html"),
                crate::assets::ANGULAR_INDEX.replace("{title}", &escape_html(title)),
            ),
            (
                String::from("src/main.ts"),
                crate::assets::ANGULAR_ENTRY.to_owned(),
            ),
            (
                String::from("src/app/app.ts"),
                crate::assets::ANGULAR_SCREEN.to_owned(),
            ),
        ],
        _ => Vec::new(),
    };
    files
        .into_iter()
        .map(|(path, contents)| Injection {
            path,
            contents,
            mode: Mode::Write,
        })
        .collect()
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::{injections, own_pages, uses_plain_entry};
    use crate::manifest::{Language, Manifest, Target};
    use crate::plan::plan;
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_ok, ensure};

    fn manifest(target: Target, language: Language, title: &str) -> Manifest {
        let mut manifest = Manifest::new("notes");
        manifest.target = target;
        manifest.language = language;
        manifest.window_title = title.to_owned();
        manifest
    }

    fn paths(manifest: &Manifest) -> Result<Vec<String>, Failure> {
        let planned = assert_ok!(plan(manifest), "plans");
        Ok(planned
            .files
            .into_iter()
            .filter(|file| file.mode == crate::plan::Mode::Write)
            .map(|file| file.path)
            .collect())
    }

    #[test]
    fn a_framework_with_its_own_pages_gets_no_index_html() -> Result<(), Failure> {
        for (target, language, page) in [
            (Target::Astro, Language::TypeScript, "src/pages/index.astro"),
            (Target::Astro, Language::JavaScript, "src/pages/index.astro"),
            (Target::Next, Language::TypeScript, "app/page.tsx"),
            (Target::Next, Language::JavaScript, "app/page.jsx"),
            (Target::Angular, Language::TypeScript, "src/app/app.ts"),
        ] {
            ensure!(own_pages(target), "{target:?} has its own pages");
            let written = paths(&manifest(target, language, "Notes"))?;
            ensure!(
                !written.iter().any(|path| path == "index.html"),
                "{target:?}: {written:?}"
            );
            ensure!(
                written.iter().any(|path| path == page),
                "{target:?} lacks {page}: {written:?}"
            );
            ensure!(
                written.iter().any(|path| path.starts_with("src/lepton.")),
                "{target:?} lacks the binding: {written:?}"
            );
        }
        Ok(())
    }

    #[test]
    fn only_astro_keeps_the_plain_entry() -> Result<(), Failure> {
        let astro = paths(&manifest(Target::Astro, Language::JavaScript, "Notes"))?;
        ensure!(astro.iter().any(|path| path == "src/main.js"), "{astro:?}");
        ensure!(uses_plain_entry(Target::React), "a Vite template keeps it");
        let next = paths(&manifest(Target::Next, Language::TypeScript, "Notes"))?;
        ensure!(
            !next.iter().any(|path| path.starts_with("src/main.")),
            "{next:?}"
        );
        let angular = assert_ok!(
            plan(&manifest(Target::Angular, Language::TypeScript, "N")),
            "plans"
        );
        let entry = angular
            .files
            .iter()
            .filter(|file| file.path == "src/main.ts")
            .collect::<Vec<_>>();
        ensure!(
            entry.len() == 1,
            "one Angular entry, not two: {}",
            entry.len()
        );
        ensure!(
            entry
                .iter()
                .all(|file| file.contents.contains("bootstrapApplication")),
            "the Angular entry, not the plain one"
        );
        Ok(())
    }

    #[test]
    fn the_title_is_escaped_for_each_page() -> Result<(), Failure> {
        let title = "Notes & \"Tasks\" <beta>";
        let astro = injections(&manifest(Target::Astro, Language::TypeScript, title));
        let page = &astro[0].contents;
        assert_contains!(page, r#"const title = "Notes & \"Tasks\" <beta>";"#);
        // Astro's own expression is left for Astro.
        assert_contains!(page, "<title>{title}</title>");
        assert_contains!(page, "import \"../main.ts\";");
        let astro_js = injections(&manifest(Target::Astro, Language::JavaScript, title));
        assert_contains!(&astro_js[0].contents, "import \"../main.js\";");

        let next = injections(&manifest(Target::Next, Language::JavaScript, title));
        assert_contains!(&next[0].contents, r#"title: "Notes & \"Tasks\" <beta>""#);

        let angular = injections(&manifest(Target::Angular, Language::TypeScript, title));
        assert_contains!(
            &angular[0].contents,
            "<title>Notes &amp; \"Tasks\" &lt;beta&gt;</title>"
        );
        Ok(())
    }
}
