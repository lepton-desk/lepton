//! The base frontend layer, compiled into this binary.
//!
//! ## Why this exists
//!
//! Tauri documents two ways to start a project: `create-tauri-app`, which is itself a Rust
//! binary published on crates.io, or — in its manual-setup guide — `npm create vite`. We
//! took the first path's shape and rejected the second's mechanism: this framework
//! scaffolds a project without spawning a package manager, so `lepton new` produces a
//! project on a machine with no Node installed and no network, and produces the *same*
//! bytes every time.
//!
//! That is a deliberate difference from Tauri rather than a missing feature. Tauri can
//! lean on `npm create vite` because a Tauri project needs Node anyway; a Lepton project
//! in `--native` mode does not need Node at all, and a scaffolder that requires it would
//! put a Node install in front of the one thing this project exists to avoid.
//!
//! ## Two layers, kept apart
//!
//! Everything under `templates/` is the **base frontend**: what `npm create vite` would
//! have written, and nothing else. Lepton's own files live in `assets/` and are added by
//! the injector, which is a separate crate for the same reason the layers are separate —
//! the base must stay a project a developer recognises, and a framework that wrote its
//! own runtime into `index.html` would make it unrecognisable.
//!
//! `shared-ts/` holds what is identical across every TypeScript template, so twelve
//! templates cannot disagree about a compiler flag.
//!
//! ## Placeholders
//!
//! `{{project_name}}` and `{{app_id}}` are substituted as each file is written. They are
//! written doubled-brace on purpose: an HTML attribute or a CSS rule has a single brace,
//! and a single-brace scanner cannot tell `{{` from a real brace pair. A template
//! containing `{ font: 12px }` would otherwise be half-eaten.

use std::path::Path;

use rust_embed::RustEmbed;

/// The base frontend templates, embedded at compile time.
#[derive(RustEmbed)]
#[folder = "templates/"]
pub struct BaseFrontend;

/// Why a project could not be scaffolded from the embedded templates.
#[derive(Debug, PartialEq, Eq)]
pub enum TemplateError {
    /// No template is embedded under this name.
    ///
    /// Carries the list, because the useful answer to a wrong `--template` is "here is
    /// what exists", not a refusal.
    NotEmbedded {
        requested: String,
        available: Vec<String>,
    },
    /// A file could not be written. The path is included because the developer needs to
    /// know which one, not merely that one was wrong.
    WriteFailed { path: String, reason: String },
}

/// The values substituted into a template as it is written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bindings {
    pub project_name: String,
    pub app_id: String,
    pub render_mode: String,
}

impl Bindings {
    /// Substitutes the placeholders in `text`.
    ///
    /// Order matters only in that every placeholder is distinct; there is no nesting, so
    /// a substituted value can never contain another placeholder.
    pub fn render(&self, text: &str) -> String {
        text.replace("{{project_name}}", &self.project_name)
            .replace("{{app_id}}", &self.app_id)
            .replace("{{render_mode}}", &self.render_mode)
    }
}

/// The templates this binary carries, sorted.
///
/// Sorted because the order a `read_dir` returns is the order the filesystem feels like,
/// and a list that reorders itself between two runs makes "did I add that one?" a question
/// with two answers.
pub fn available() -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for entry in BaseFrontend::iter() {
        let Some(first) = entry.split('/').next() else {
            continue;
        };
        if first == "shared-ts" {
            continue;
        }
        let owned = first.to_owned();
        if !names.contains(&owned) {
            names.push(owned);
        }
    }
    names.sort();
    names
}

/// Whether `name` is embedded.
pub fn contains(name: &str) -> bool {
    available().iter().any(|candidate| candidate == name)
}

/// Writes the base frontend for `template` under `root`.
///
/// The shared TypeScript layer is written first so a per-template file of the same name
/// would win — which is the ordering a template author expects, and the reason
/// `tsconfig.json` can be overridden per template without editing every sibling.
pub fn write(
    template: &str,
    root: &Path,
    bindings: &Bindings,
) -> Result<Vec<String>, TemplateError> {
    if !contains(template) {
        return Err(TemplateError::NotEmbedded {
            requested: template.to_owned(),
            available: available(),
        });
    }

    let mut written = Vec::new();

    // Two passes: the shared TypeScript layer, then the template, so a per-template file of
    // the same name wins. One pass in the embed's order wrote `react-ts/` before
    // `shared-ts/` (alphabetical), and the shared `tsconfig.json` replaced React's own.
    let shared = template.ends_with("-ts");
    let own = format!("{template}/");
    let layers = [shared.then_some("shared-ts/"), Some(own.as_str())];
    for prefix in layers.into_iter().flatten() {
        for (name, relative) in entries() {
            if !name.starts_with(prefix) {
                continue;
            }
            let Some(bytes) = BaseFrontend::get(&name) else {
                continue;
            };
            write_one(root, &relative, &bytes.data, bindings, &mut written)?;
        }
    }
    // A file both layers carry was written twice; it is one file.
    written.sort();
    written.dedup();
    Ok(written)
}

/// Every embedded file, with its path relative to its own template directory.
///
/// Owned strings because rust-embed iterates over borrowed `Cow`s and the two paths have
/// to be compared and sliced; doing that on borrows would put the iterator's lifetime on
/// the public signature for no benefit.
fn entries() -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for entry in BaseFrontend::iter() {
        let name: String = entry.as_ref().to_owned();
        let Some((_, rest)) = name.split_once('/') else {
            continue;
        };
        let relative: String = rest.to_owned();
        out.push((name, relative));
    }
    out
}

fn write_one(
    root: &Path,
    relative: &str,
    bytes: &[u8],
    bindings: &Bindings,
    written: &mut Vec<String>,
) -> Result<(), TemplateError> {
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| TemplateError::WriteFailed {
            path: parent.display().to_string(),
            reason: error.to_string(),
        })?;
    }

    // Text through the binding substitution; anything that is not valid UTF-8 goes across
    // untouched rather than being mangled by a lossy guess.
    match std::str::from_utf8(bytes) {
        Ok(text) => std::fs::write(&path, bindings.render(text)).map_err(|error| {
            TemplateError::WriteFailed {
                path: path.display().to_string(),
                reason: error.to_string(),
            }
        })?,
        Err(_) => std::fs::write(&path, bytes).map_err(|error| TemplateError::WriteFailed {
            path: path.display().to_string(),
            reason: error.to_string(),
        })?,
    }

    written.push(relative.to_owned());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Bindings, available, write};
    use lepton_orchestrator::ensure;
    use lepton_orchestrator::testing::{Failure, Scratch};

    /// Every TypeScript template whose sources hold JSX must tell `tsc` how to read it.
    /// react-ts had no `tsconfig.json` of its own and inherited the shared one, which has
    /// no `jsx`: `vite build` passed and `tsc --noEmit` failed on every new React project
    /// (measured 2026-10-17, exit 2, TS17004 on `App.tsx`).
    #[test]
    fn a_template_with_jsx_sets_jsx_for_tsc() -> Result<(), Failure> {
        let bindings = Bindings {
            project_name: String::from("probe"),
            app_id: String::from("dev.lepton.probe"),
            render_mode: String::from("webview"),
        };
        for template in available().iter().filter(|name| name.ends_with("-ts")) {
            let scratch = Scratch::new(&format!("base-{template}"))?;
            let written = write(template, scratch.path(), &bindings)
                .map_err(|error| lepton_orchestrator::testing::fail("the template is written", format!("{error:?}")))?;
            if !written.iter().any(|path| path.ends_with(".tsx")) {
                continue;
            }
            let configs: String = written
                .iter()
                .filter(|path| path.starts_with("tsconfig") && path.ends_with(".json"))
                .map(|path| std::fs::read_to_string(scratch.path().join(path)).unwrap_or_default())
                .collect();
            ensure!(
                configs.contains("\"jsx\""),
                "{template} writes .tsx files but no tsconfig sets \"jsx\""
            );
        }
        Ok(())
    }
}
