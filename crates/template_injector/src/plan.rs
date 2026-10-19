//! Deciding what an injection writes, and writing it.
//!
//! Two kinds of file exist in a scaffolded project, and conflating them is how a
//! template destroys a developer's work. A file Lepton owns is written whole. A file
//! the frontend owns — `package.json`, `index.html` — is *merged*, because the
//! scaffolder put something there first and a whole-file write would throw it away.
//!
//! That distinction is a field on `Injection` rather than a naming convention,
//! because a convention is invisible at the call site where the mistake happens.

use std::path::{Path, PathBuf};

use crate::manifest::{Manifest, validate};
use crate::merge;

/// One file the plan will write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Injection {
    /// Path relative to the project root. Never absolute, and never able to climb
    /// above the root — `apply` refuses both.
    pub path: String,
    pub contents: String,
    /// Whether `contents` replaces the file or is merged into it.
    pub mode: Mode,
}

/// How an injection treats a file that already exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The file is Lepton's; write it whole.
    ///
    /// Re-running replaces it, which is what makes `lepton new` on an existing
    /// project idempotent for the files the framework owns.
    Write,
    /// The file is the frontend's; merge `contents` into it as JSON.
    ///
    /// Refuses rather than replaces when the existing file is not valid JSON,
    /// because a merge into an unparseable file is a guess and a guess about a
    /// developer's manifest is how a project stops installing.
    MergeJson,
    /// A file the scaffolder wrote for the screen this injection replaces.
    ///
    /// Removing it is part of writing the replacement. Leaving it behind means a
    /// project opens full of files nothing imports, and the linter then reports
    /// problems in files the framework itself decided were dead — which teaches a
    /// developer that the starter arrives broken.
    ///
    /// `contents` is unused, and the plan records the path rather than a list kept
    /// somewhere else so that the set of removals is readable next to the set of
    /// writes instead of being a second thing to keep in step.
    Remove,
    /// A directory the removals above leave empty.
    ///
    /// Named rather than swept up afterwards, because a sweep would delete a directory
    /// the developer created between scaffolding and injection — which for `src` is
    /// every directory a developer has ever put in a project.
    RemoveDir,
}

/// Every file the injection will write.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Plan {
    pub files: Vec<Injection>,
}

/// Why a plan could not be produced or applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InjectionError {
    /// The manifest describes something that cannot be written.
    InvalidManifest { reason: String },
    /// A file could not be written.
    Write { path: PathBuf, reason: String },
    /// A planned path pointed outside the project.
    Escapes { path: String },
    /// A merge target was not the JSON the merge expected.
    Merge { path: PathBuf, reason: String },
}

impl std::fmt::Display for InjectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidManifest { reason } => write!(f, "{reason}"),
            Self::Write { path, reason } => {
                write!(f, "could not write {}: {reason}", path.display())
            }
            Self::Escapes { path } => {
                write!(
                    f,
                    "refusing to write {path:?}: it points outside the project"
                )
            }
            Self::Merge { path, reason } => {
                write!(f, "could not merge into {}: {reason}", path.display())
            }
        }
    }
}

impl std::error::Error for InjectionError {}

/// Decides what the injection will write, without writing it.
pub fn plan(manifest: &Manifest) -> Result<Plan, InjectionError> {
    validate(manifest).map_err(|error| InjectionError::InvalidManifest {
        reason: error.reason,
    })?;

    let mut files = vec![
        Injection {
            path: crate::CONFIG_PATH.to_owned(),
            contents: crate::render_manifest(manifest),
            mode: Mode::Write,
        },
        // The frontend's manifest, merged: the scaffolder wrote `dev`, `build`
        // and `preview`, and Lepton adds `devDependencies` and its own scripts
        // beside them rather than replacing them.
        Injection {
            path: "package.json".to_owned(),
            contents: crate::assets::package_manifest(&manifest.plugins),
            mode: Mode::MergeJson,
        },
        Injection {
            path: "biome.json".to_owned(),
            contents: crate::assets::BIOME_CONFIG.to_owned(),
            mode: Mode::Write,
        },
        Injection {
            path: format!("src/lepton.{}", manifest.language.extension()),
            contents: binding_for(manifest).to_owned(),
            mode: Mode::Write,
        },
        Injection {
            path: "src/lepton-sdk.css".to_owned(),
            contents: crate::assets::STYLESHEET.to_owned(),
            mode: Mode::Write,
        },
        Injection {
            path: "src-lepton/main.zig".to_owned(),
            contents: crate::assets::zig_entry(
                &manifest.product_name,
                &manifest.channel_name,
                &manifest.window_title,
                &manifest.identifier,
            ),
            mode: Mode::Write,
        },
        Injection {
            path: "src-lepton/build.zig".to_owned(),
            contents: crate::assets::ZIG_BUILD.to_owned(),
            mode: Mode::Write,
        },
        Injection {
            path: "src-lepton/lepton-commands.zig".to_owned(),
            contents: crate::assets::COMMAND_TYPES.to_owned(),
            mode: Mode::Write,
        },
        // What the scaffolder wrote for the screen above, which nothing imports
        // any more. Named explicitly rather than swept up by a directory walk: a
        // sweep would delete a file the developer added between scaffolding and
        // injection, which is the one thing a new project must never do.
        Injection {
            path: format!("src/counter.{}", manifest.language.extension()),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "src/style.css".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "public/favicon.svg".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "public/icons.svg".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "src/assets/hero.png".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "src/assets/typescript.svg".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        Injection {
            path: "src/assets/vite.svg".to_owned(),
            contents: String::new(),
            mode: Mode::Remove,
        },
        // The two directories those files were the whole of. Left behind they read
        // as "something was here and someone forgot", which is a worse thing for a
        // developer to find in a brand new project than not having them at all.
        Injection {
            path: "src/assets".to_owned(),
            contents: String::new(),
            mode: Mode::RemoveDir,
        },
        Injection {
            path: "public".to_owned(),
            contents: String::new(),
            mode: Mode::RemoveDir,
        },
    ];
    // A Vite project's document and entry. Astro, Next.js and Angular bring their own
    // pages instead (`frame_pages.rs`); Astro's page still loads the plain entry.
    if !crate::frame_pages::own_pages(manifest.target) {
        files.insert(
            3,
            Injection {
                path: "index.html".to_owned(),
                contents: crate::assets::index_html(
                    manifest.target,
                    manifest.language,
                    &manifest.window_title,
                ),
                mode: Mode::Write,
            },
        );
    }
    if crate::frame_pages::uses_plain_entry(manifest.target) {
        // The screen, expressed in whatever the project's framework is. Writing the
        // plain-DOM entry into a React project would leave the framework unmounted and
        // its own components dead — a project that builds, runs, and does nothing.
        files.push(Injection {
            path: format!("src/main.{}", entry_extension(manifest)),
            contents: entry_contents(manifest).to_owned(),
            mode: Mode::Write,
        });
    }
    files.extend(extra_injections(manifest));
    files.extend(crate::frame_pages::injections(manifest));
    Ok(Plan { files })
}

/// Applies a plan to a directory, creating directories and files as needed.
///
/// Every path in the plan is resolved and checked *before* anything is written. A
/// plan is applied whole or not at all: a template whose third file pointed outside
/// the project would otherwise leave the first two written, which is exactly the
/// half-finished state a developer has to diagnose by hand.
pub fn apply(root: &Path, plan: &Plan) -> Result<Vec<PathBuf>, InjectionError> {
    let targets: Vec<PathBuf> = plan
        .files
        .iter()
        .map(|injection| resolve(root, injection))
        .collect::<Result<Vec<_>, _>>()?;

    let mut written = Vec::with_capacity(targets.len());
    for (injection, path) in plan.files.iter().zip(&targets) {
        match injection.mode {
            Mode::Remove | Mode::RemoveDir => {
                // Both refuse to act on something already gone, and both refuse to act
                // on a directory with contents. A `remove_dir` that fails on the first
                // because someone put a file in it is not an error worth failing a
                // scaffold over: the goal was that the directory not be here, and if it
                // now holds a developer's file then it should be here.
                let outcome = match injection.mode {
                    Mode::Remove => std::fs::remove_file(path),
                    _ => std::fs::remove_dir(path),
                };

                match outcome {
                    Ok(()) => {}
                    Err(error)
                        if error.kind() == std::io::ErrorKind::NotFound
                            || error.kind() == std::io::ErrorKind::DirectoryNotEmpty =>
                    {
                        // Left in place, and deliberately not reported.
                    }
                    Err(error) => {
                        return Err(InjectionError::Write {
                            path: path.clone(),
                            reason: error.to_string(),
                        });
                    }
                }
                continue;
            }
            Mode::Write | Mode::MergeJson => {}
        }

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| InjectionError::Write {
                path: parent.to_path_buf(),
                reason: error.to_string(),
            })?;
        }

        let final_contents = match injection.mode {
            Mode::Write => injection.contents.clone(),
            Mode::MergeJson => match std::fs::read_to_string(path) {
                // No file yet is not a conflict: the merge target does not exist, so
                // the merge content becomes the whole file.
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    injection.contents.clone()
                }
                Err(error) => {
                    return Err(InjectionError::Write {
                        path: path.clone(),
                        reason: error.to_string(),
                    });
                }
                Ok(existing) => merge::into(&existing, &injection.contents).map_err(|reason| {
                    InjectionError::Merge {
                        path: path.clone(),
                        reason,
                    }
                })?,
            },
            // Handled above, before any directory is created. Matched so that adding a
            // mode is a compile error here rather than a file written on the way past.
            Mode::Remove | Mode::RemoveDir => String::new(),
        };

        std::fs::write(path, &final_contents).map_err(|error| InjectionError::Write {
            path: path.clone(),
            reason: error.to_string(),
        })?;
        written.push(path.clone());
    }

    Ok(written)
}

/// Resolves one planned path inside the root, or refuses it.
fn resolve(root: &Path, injection: &Injection) -> Result<PathBuf, InjectionError> {
    let relative = Path::new(&injection.path);

    // Two separate refusals because they are two different mistakes. An absolute path
    // is someone who meant a path on this machine; `..` is someone who meant a path
    // somewhere else. Both are refused before any write happens.
    if relative.is_absolute() {
        return Err(InjectionError::Escapes {
            path: injection.path.clone(),
        });
    }

    let mut resolved = root.to_path_buf();
    // Depth below the root, so a `..` is judged by where it lands rather than by its
    // presence. `a/../b` stays inside the project and is a legitimate path; `../b` and
    // `a/../../b` do not. Refusing every `..` would reject a path a developer might
    // reasonably write; allowing every one would write wherever it pointed.
    let mut depth: usize = 0;

    for component in relative.components() {
        match component {
            std::path::Component::Normal(part) => {
                resolved.push(part);
                depth += 1;
            }
            // `.` names nothing, so it is dropped rather than becoming a directory
            // called `.` — which would be hidden and would not resolve.
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if depth == 0 {
                    return Err(InjectionError::Escapes {
                        path: injection.path.clone(),
                    });
                }
                depth -= 1;
                resolved.pop();
            }
            // A prefix or a root cannot appear in a path that already passed
            // `is_absolute` on every platform this runs on, so this is unreachable
            // rather than merely unlikely. Treated as an escape so that if it ever
            // became reachable, it is refused rather than joined.
            _ => {
                return Err(InjectionError::Escapes {
                    path: injection.path.clone(),
                });
            }
        }
    }

    Ok(resolved)
}

#[cfg(test)]
#[path = "plan_tests.rs"]
mod plan_tests;

/// The extension a project's entry script carries.
///
/// React and Solid need `.tsx`, because a component written in them has JSX in it and
/// the file has to say so. Everything else follows the language.
fn entry_extension(manifest: &Manifest) -> &'static str {
    match manifest.target {
        crate::manifest::Target::React
        | crate::manifest::Target::Solid
        | crate::manifest::Target::Preact => match manifest.language {
            crate::manifest::Language::TypeScript => "tsx",
            crate::manifest::Language::JavaScript => "jsx",
        },
        _ => manifest.language.extension(),
    }
}

/// The channel binding, in the project's language.
///
/// The JavaScript form is not the TypeScript source with its types removed by hand: it
/// is generated from it, because a binding that had two independently-edited versions
/// would read a frame layout one version understood and the other did not — and the
/// symptom would be a screen showing numbers that were subtly not the core's.
fn binding_for(manifest: &Manifest) -> &'static str {
    match manifest.language {
        crate::manifest::Language::JavaScript => crate::assets::JS_SDK_ENTRY,
        crate::manifest::Language::TypeScript => crate::assets::SDK_ENTRY,
    }
}

/// The entry script for a project's framework, in the project's language.
fn entry_contents(manifest: &Manifest) -> &'static str {
    match (manifest.target, manifest.language) {
        (crate::manifest::Target::React, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_REACT_ENTRY
        }
        (crate::manifest::Target::React, crate::manifest::Language::TypeScript) => {
            crate::assets::REACT_ENTRY
        }
        (crate::manifest::Target::Vue, crate::manifest::Language::TypeScript) => {
            crate::assets::VUE_ENTRY
        }
        (crate::manifest::Target::Svelte, crate::manifest::Language::TypeScript) => {
            crate::assets::SVELTE_ENTRY
        }
        (crate::manifest::Target::Solid, crate::manifest::Language::TypeScript) => {
            crate::assets::SOLID_ENTRY
        }
        (crate::manifest::Target::Vue, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_VUE_ENTRY
        }
        (crate::manifest::Target::Svelte, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_SVELTE_ENTRY
        }
        (crate::manifest::Target::Solid, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_SOLID_ENTRY
        }
        (crate::manifest::Target::Preact, crate::manifest::Language::TypeScript) => {
            crate::assets::PREACT_ENTRY
        }
        (crate::manifest::Target::Preact, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_PREACT_ENTRY
        }
        (crate::manifest::Target::Lit, crate::manifest::Language::TypeScript) => {
            crate::assets::LIT_ENTRY
        }
        (crate::manifest::Target::Lit, crate::manifest::Language::JavaScript) => {
            crate::assets::JS_LIT_ENTRY
        }
        (_, crate::manifest::Language::JavaScript) => crate::assets::JS_MAIN_ENTRY,
        (_, crate::manifest::Language::TypeScript) => crate::assets::MAIN_ENTRY,
    }
}

/// The screens a project's framework needs, beyond its entry.
///
/// React gets a component because its entry mounts one; the plain-DOM screen has no
/// equivalent split. `measures.ts` is added for every project because it is the
/// arithmetic, and a screen that formatted its own numbers would be a second
/// implementation of them.
fn extra_injections(manifest: &Manifest) -> Vec<Injection> {
    let extension = manifest.language.extension();
    let measures = match manifest.language {
        crate::manifest::Language::JavaScript => crate::assets::JS_MEASURES,
        crate::manifest::Language::TypeScript => crate::assets::MEASURES,
    };

    let mut out = vec![Injection {
        path: format!("src/measures.{extension}"),
        contents: measures.to_owned(),
        mode: Mode::Write,
    }];

    // Vue, Svelte and Solid's screen is a component file the entry imports, in the
    // framework's own file type and the project's language.
    let javascript = manifest.language == crate::manifest::Language::JavaScript;
    let screen = match manifest.target {
        crate::manifest::Target::Vue if javascript => {
            Some(("src/App.vue", crate::assets::JS_VUE_SCREEN))
        }
        crate::manifest::Target::Vue => Some(("src/App.vue", crate::assets::VUE_SCREEN)),
        crate::manifest::Target::Svelte if javascript => {
            Some(("src/App.svelte", crate::assets::JS_SVELTE_SCREEN))
        }
        crate::manifest::Target::Svelte => Some(("src/App.svelte", crate::assets::SVELTE_SCREEN)),
        crate::manifest::Target::Solid if javascript => {
            Some(("src/App.jsx", crate::assets::JS_SOLID_SCREEN))
        }
        crate::manifest::Target::Solid => Some(("src/App.tsx", crate::assets::SOLID_SCREEN)),
        crate::manifest::Target::Preact if javascript => {
            Some(("src/App.jsx", crate::assets::JS_PREACT_SCREEN))
        }
        crate::manifest::Target::Preact => Some(("src/App.tsx", crate::assets::PREACT_SCREEN)),
        crate::manifest::Target::Lit if javascript => {
            Some(("src/measures-screen.js", crate::assets::JS_LIT_SCREEN))
        }
        crate::manifest::Target::Lit => Some(("src/measures-screen.ts", crate::assets::LIT_SCREEN)),
        _ => None,
    };
    if let Some((path, screen)) = screen {
        out.push(Injection {
            path: path.to_owned(),
            contents: screen.to_owned(),
            mode: Mode::Write,
        });
    }

    if manifest.target == crate::manifest::Target::React {
        let screen = match manifest.language {
            crate::manifest::Language::JavaScript => crate::assets::JS_REACT_SCREEN,
            crate::manifest::Language::TypeScript => crate::assets::REACT_SCREEN,
        };
        out.push(Injection {
            path: format!("src/App.{}", entry_extension(manifest)),
            contents: screen.to_owned(),
            mode: Mode::Write,
        });
    }
    out
}
