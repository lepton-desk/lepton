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

    for (name, relative) in entries() {
        // The shared TypeScript layer goes first so a per-template file of the same name
        // wins, which is the ordering a template author expects and the reason
        // `tsconfig.json` can be overridden per template without editing every sibling.
        let wanted = if template.ends_with("-ts") && name.starts_with("shared-ts/") {
            true
        } else {
            name.starts_with(&format!("{template}/"))
        };
        if !wanted {
            continue;
        }
        let Some(bytes) = BaseFrontend::get(&name) else {
            continue;
        };
        write_one(root, &relative, &bytes.data, bindings, &mut written)?;
    }

    written.sort();
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
