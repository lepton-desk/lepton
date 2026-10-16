//! `lepton new` — creating a project.
//!
//! Three real steps, in an order that cannot be rearranged:
//!
//! 1. The frontend scaffolder produces a working Vite project. It runs first because
//!    its structure is what the injection adapts to; imposing our own structure
//!    first would mean rewriting every file it wrote.
//! 2. The manifest is rendered from the flags, so the developer can see what they
//!    asked for before it is committed to disk.
//! 3. The injection adds the Lepton layer into the structure that now exists.
//!
//! Step 1 is the only one that reaches the network, and it is the reason `new` needs
//! a package manager while `build` does not.

use std::path::{Path, PathBuf};

use lepton_orchestrator::{ToolRequirement, Toolchain, require};
use lepton_template_injector::{Manifest, RenderPath, Target};

use super::{CliError, Outcome};

/// Flags for `lepton new`.
#[derive(Debug, Clone, clap::Args)]
pub struct Flags {
    /// The project's name, as a developer would say it: `Ledger`, not `ledger-app`.
    /// Omitted: the wizard asks (`lepton-app` by default).
    pub name: Option<String>,

    /// Which frontend to scaffold, as `<framework>-<language>`.
    ///
    /// A string rather than an enum on purpose: the list of what this binary carries is a
    /// property of what was embedded at build time, and an enum would put a second,
    /// hand-maintained list in the source that could disagree with the first. The set is
    /// read from `lepton_template_injector::base::available()`, so adding a template is
    /// adding a directory.
    ///
    /// Omitted means the wizard asks, which is what makes `lepton new Ledger` useful
    /// with no flags at all.
    #[arg(long, short = 't')]
    pub template: Option<String>,

    /// How the project renders. Omitted: the wizard asks (webview first), and
    /// `--non-interactive` takes `native`.
    #[arg(long, value_enum)]
    pub target: Option<RenderMode>,

    /// Plugins to add, comma-separated: `os`, `clipboard`, `fs`, `dialog`. Each becomes a
    /// dependency with its commands under `permissions`; `fs` starts with `$APPDATA` as
    /// its scope. Omitted: the wizard asks.
    #[arg(long, value_name = "LIST")]
    pub plugins: Option<String>,

    /// The package manager the project will use: `npm`, `pnpm`, `yarn` or `bun`. Omitted:
    /// the one that started this command (`npm create`, `pnpm create`, …), else pnpm when
    /// installed, else npm.
    #[arg(long, value_name = "NAME")]
    pub package_manager: Option<String>,

    /// Installs the dependencies once the project is written.
    #[arg(long)]
    pub install: bool,

    /// Lists every file written, and the channel name.
    #[arg(long)]
    pub verbose: bool,

    /// Never asks anything; fails instead.
    ///
    /// For scripts and for continuous integration, where a prompt is a hang rather than
    /// a question.
    #[arg(long)]
    pub non_interactive: bool,

    /// The window's width in physical pixels.
    #[arg(long, default_value_t = 1200)]
    pub width: u32,

    /// The window's height in physical pixels.
    #[arg(long, default_value_t = 800)]
    pub height: u32,

    /// Overrides the reverse-DNS identifier derived from the name.
    #[arg(long)]
    pub identifier: Option<String>,

    /// Creates the project here rather than in a directory named after it.
    #[arg(long)]
    pub directory: Option<PathBuf>,
}

impl Flags {
    /// Creates the project.
    pub fn run(mut self) -> Outcome {
        let chain = Toolchain::detect();
        require(&chain, ToolRequirement::Scaffold)?;

        // Asked before anything is written, and only when there is something to ask. A
        // command line that already says everything never opens a prompt, which is what
        // makes `lepton new Ledger --template vanilla-ts --target native` usable in a
        // script on a machine with no terminal at all.
        let paint = crate::style::Painter::detect();
        inquire::set_global_render_config(paint.prompt_theme());
        println!("{}", paint.header("create an app"));
        match &self.name {
            Some(name) => println!("{}", paint.answered("Project", name)),
            None if self.non_interactive => {
                return Err(CliError::Invalid(
                    "--non-interactive needs the project's name".to_owned(),
                ));
            }
            None => {
                let name = inquire::Text::new(&super::new_view::question("Project"))
                    .with_default("lepton-app")
                    .prompt()
                    .map_err(|failure| {
                        CliError::Invalid(format!("could not read the name: {failure}"))
                    })?;
                self.name = Some(name);
            }
        }
        let resolved = match self.template.clone() {
            Some(_) => Resolved {
                template: self.template.clone().unwrap_or_default(),
                target: self.target.unwrap_or(RenderMode::Native),
                plugins: super::new_setup::plugins_from_flag(self.plugins.as_deref())?,
                identifier: self.identifier.clone().unwrap_or_else(|| {
                    lepton_template_injector::manifest::identifier_for(self.name())
                }),
            },
            None if self.non_interactive => {
                return Err(CliError::Invalid(
                    "--non-interactive needs --template: there is nothing to fall back on"
                        .to_owned(),
                ));
            }
            None => wizard(&self, paint)?,
        };
        if self.template.is_some() {
            super::new_view::answered_by_flags(
                paint,
                &resolved.template,
                resolved.target,
                &resolved.plugins,
                &resolved.identifier,
            );
        }

        let manager = super::new_setup::choose_manager(self.package_manager.as_deref(), &chain)?;
        let manifest = self.manifest_for(&resolved)?;
        let root = self.root()?;

        // Checked before anything is written: `create-vite` is happy to write into an
        // existing directory, which means a typo would scatter files across a
        // directory the developer already has things in.
        refuse_existing(&root)?;

        // The core is written to a staging directory beside the project and moved
        // into place afterwards. Writing it straight into the project would make the
        // directory non-empty, and `create-vite` refuses a directory that already
        // holds files — so the two steps would each have been correct and the pair
        // impossible.
        //
        // Staging rather than simply reversing the order because a move is atomic: a
        // failure anywhere before it leaves nothing behind, rather than a project with
        // a frontend and no way to build a window in it.
        let staging = Staging::beside(&root)?;

        let vendored = match vendor_core(&staging.path) {
            Ok(vendored) => vendored,
            Err(error) => return Err(staging.discard(error)),
        };

        let bindings = lepton_template_injector::Bindings {
            project_name: kebab(self.name()),
            app_id: resolved.identifier.clone(),
            render_mode: resolved.target.as_str().to_owned(),
        };

        let base_files = match scaffold(&root, &resolved.template, &bindings) {
            Ok(files) => files,
            Err(error) => return Err(staging.discard(error)),
        };
        let _ = chain;
        let _ = &base_files;

        let planned = lepton_template_injector::plan(&manifest).map_err(CliError::from)?;
        let written = match lepton_template_injector::apply(&root, &planned) {
            Ok(written) => written,
            Err(error) => return Err(staging.discard(CliError::from(error))),
        };

        // The one step whose failure is not cleaned up: `commit` removes the staging
        // directory itself, because by the time it fails there is nothing left to tidy.
        staging.commit(&root)?;
        super::new_setup::prepare_for(&root, manager)?;

        super::new_view::steps(
            paint,
            &resolved.template,
            &root,
            &manifest,
            &super::new_view::Written {
                vendored: &vendored,
                base: &base_files,
                files: &written,
            },
            self.verbose,
        );
        let installed = self.install && super::new_setup::install(&root, manager, paint)?;
        super::new_view::next_steps(
            paint,
            &resolved.template,
            &root,
            manager,
            installed,
            &manifest,
        );
        Ok(())
    }

    /// The project's name, once asked for when the command line did not give it.
    fn name(&self) -> &str {
        self.name.as_deref().unwrap_or("lepton-app")
    }

    /// The manifest these flags describe.
    fn manifest_for(&self, resolved: &Resolved) -> Result<Manifest, CliError> {
        let mut manifest = Manifest::new(self.name());

        manifest.target = target_of(&resolved.template)?;
        manifest.language = language_of(&resolved.template)?;
        manifest.render_path = match resolved.target {
            RenderMode::Native => RenderPath::Native,
            RenderMode::Webview => RenderPath::Webview,
        };
        manifest.plugins = resolved.plugins.clone();
        manifest.window_width = self.width;
        manifest.window_height = self.height;

        if self.identifier.is_none() {
            manifest.identifier = resolved.identifier.clone();
            // The channel name is namespaced by the identifier, so overriding one
            // without the other would leave the core publishing to a name no front end
            // is looking for.
            manifest.channel_name = format!("/lepton-{}", resolved.identifier);
        }

        Ok(manifest)
    }

    /// Where the project will live.
    fn root(&self) -> Result<PathBuf, CliError> {
        match &self.directory {
            Some(directory) => Ok(directory.clone()),
            // The directory is named after the identifier, not the product name: a
            // name may contain spaces and capital letters, and a path is neither.
            None => Ok(PathBuf::from(
                lepton_template_injector::manifest::identifier_for(self.name()),
            )),
        }
    }
}

/// Puts the Zig core under `into`, where the core's build file expects to find it.
///
/// The location comes from the vendoring crate rather than from a string here, because
/// this command and the build file a project is handed both name that directory and
/// neither can import the other.
fn vendor_core(into: &Path) -> Result<Vec<PathBuf>, CliError> {
    lepton_core_vendoring::write_into(into).map_err(CliError::from)
}

/// A directory on the same filesystem as the project, removed unless it is claimed.
///
/// Beside the project rather than inside it, because the last step is a rename and a
/// rename only stays atomic within one filesystem. A staging directory inside the
/// project would work for the move and break for everything else.
struct Staging {
    path: PathBuf,
}

impl Staging {
    /// Creates a staging directory beside `root`.
    ///
    /// Named after the project and marked with a leading dot so a developer looking at
    /// the directory mid-run sees one hidden entry rather than a plausible-looking
    /// half-project.
    fn beside(root: &Path) -> Result<Self, CliError> {
        let name = root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            // A root given as `.` or as a path with no final component. The generic
            // name is fine: there is nothing about it to guess from.
            .unwrap_or_else(|| String::from("lepton"));

        let beside = root.parent().unwrap_or_else(|| Path::new("."));
        let path = beside.join(format!(".lepton-vendor-{name}"));

        // A leftover from a previous run is removed rather than reused: its contents
        // would be from a different CLI build, and a project that mixes two is worse
        // than one that takes a moment longer.
        if path.exists() {
            std::fs::remove_dir_all(&path).map_err(|error| {
                CliError::Invalid(format!(
                    "could not clear the staging directory {}: {error}",
                    path.display()
                ))
            })?;
        }
        std::fs::create_dir_all(&path).map_err(|error| {
            CliError::Invalid(format!(
                "could not stage the core in {}: {error}",
                path.display()
            ))
        })?;

        Ok(Self { path })
    }

    /// Removes the staging directory and hands the reason back.
    ///
    /// The reason wins over the cleanup: a failure to write the core is what the
    /// developer has to fix, and a directory that could not be deleted is a second
    /// message worth having but not the one worth losing.
    fn discard(self, reason: CliError) -> CliError {
        let _ = std::fs::remove_dir_all(&self.path);
        reason
    }

    /// Moves the staged core under the project's core directory.
    ///
    /// The constant names a path relative to a core build directory, so it is joined
    /// onto that directory rather than onto the project root. Joining it onto the root
    /// would put the package one level too high, and the project's build file would
    /// fail to import it with a message that names a file rather than the mistake.
    fn commit(self, root: &Path) -> Result<(), CliError> {
        let destination = root
            .join(super::build::CORE_DIR)
            .join(lepton_core_vendoring::VENDORED_CORE);

        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|error| {
                CliError::Invalid(format!("could not create {}: {error}", parent.display()))
            })?;
        }

        std::fs::rename(&self.path, &destination).map_err(|error| {
            let _ = std::fs::remove_dir_all(&self.path);
            CliError::Invalid(format!(
                "could not move the Zig core into {}: {error}",
                destination.display()
            ))
        })
    }
}

/// Refuses to write into a directory that already holds something.
fn refuse_existing(root: &Path) -> Result<(), CliError> {
    let Ok(entries) = std::fs::read_dir(root) else {
        // A directory that does not exist yet is the good case, and `read_dir`'s
        // error is the only way to know which of the two this is without guessing.
        return Ok(());
    };

    if entries.count() == 0 {
        return Ok(());
    }

    Err(CliError::Invalid(format!(
        "{} already exists and is not empty. Choose another directory with --directory, or remove it first.",
        root.display()
    )))
}

/// Writes the base frontend under `root` from the templates compiled into this binary.
///
/// No package manager is spawned. That is the whole point of embedding the templates: a
/// Lepton project in `--target native` needs no Node at all, and a scaffolder that
/// insisted on one would put an npm install in front of the thing this project exists to
/// avoid. It also means the bytes are identical on every machine, which is what makes a
/// scaffold reproducible.
fn scaffold(
    root: &Path,
    template: &str,
    bindings: &lepton_template_injector::Bindings,
) -> Result<Vec<String>, CliError> {
    lepton_template_injector::base::write(template, root, bindings).map_err(|error| match error {
        lepton_template_injector::TemplateError::NotEmbedded {
            requested,
            available,
        } => CliError::Invalid(format!(
            "no template named `{requested}` is built into this binary. available: {}",
            available.join(", ")
        )),
        lepton_template_injector::TemplateError::WriteFailed { path, reason } => {
            CliError::Invalid(format!("could not write {path}: {reason}"))
        }
    })
}

/// Asks for whatever the command line did not say.
///
/// Two steps, in the order that decides the least: what to build the interface with, then
/// what draws it. Every answer is defaulted, so pressing enter repeatedly produces the
/// same project a script would.
fn wizard(flags: &Flags, paint: crate::style::Painter) -> Result<Resolved, CliError> {
    use super::new_view::{plugins_label, question, render_label, template_label};
    let available = lepton_template_injector::base::available();

    let template = match flags.template.clone() {
        Some(name) => {
            if !available.iter().any(|candidate| candidate == &name) {
                return Err(CliError::Invalid(format!(
                    "no template named `{name}` is built into this binary. available: {}",
                    available.join(", ")
                )));
            }
            println!("{}", paint.answered("Frontend", &template_label(&name)));
            name
        }
        None => {
            let ordered = super::new_view::wizard_order(&available);
            let labels: Vec<String> = ordered.iter().map(|name| template_label(name)).collect();
            let picked = inquire::Select::new(&question("Frontend"), labels.clone())
                .with_help_message("↑↓ to move, enter to choose")
                .prompt()
                .map_err(|failure| {
                    CliError::Invalid(format!("could not read the frontend choice: {failure}"))
                })?;
            let index = labels
                .iter()
                .position(|label| label == &picked)
                .unwrap_or(0);
            ordered.get(index).cloned().unwrap_or_default()
        }
    };

    let target = match flags.target {
        Some(target) => {
            println!("{}", paint.answered("Render", render_label(target)));
            target
        }
        None => {
            let choices = vec![
                render_label(RenderMode::Webview),
                render_label(RenderMode::Native),
            ];
            let picked = inquire::Select::new(&question("Render"), choices)
                .prompt()
                .map_err(|failure| {
                    CliError::Invalid(format!("could not read the render choice: {failure}"))
                })?;
            if picked.starts_with("webview") {
                RenderMode::Webview
            } else {
                RenderMode::Native
            }
        }
    };
    let plugins = match flags.plugins.as_deref() {
        Some(list) => {
            let chosen = super::new_setup::plugins_from_flag(Some(list))?;
            println!("{}", paint.answered("Plugins", &plugins_label(&chosen)));
            chosen
        }
        None if target == RenderMode::Webview => super::new_setup::ask_plugins()?,
        None => Vec::new(),
    };

    let default_identifier = lepton_template_injector::manifest::identifier_for(flags.name());
    let identifier = inquire::Text::new(&question("Identifier"))
        .with_default(&default_identifier)
        .prompt()
        .map_err(|failure| {
            CliError::Invalid(format!("could not read the identifier: {failure}"))
        })?;

    Ok(Resolved {
        template,
        target,
        identifier,
        plugins,
    })
}

/// What the wizard produced, or what the command line already said.
struct Resolved {
    template: String,
    target: RenderMode,
    identifier: String,
    plugins: Vec<&'static str>,
}

/// The directory-safe spelling of a project name.
///
/// Lower-cased and hyphenated, because it goes into a `package.json` name, a directory
/// path and a channel name, and those three disagree about capitals.
fn kebab(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut previous_was_dash = false;
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            out.push(character.to_ascii_lowercase());
            previous_was_dash = false;
        } else if !previous_was_dash && !out.is_empty() {
            out.push('-');
            previous_was_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// The framework recorded in the manifest, derived from the template's name.
///
/// Read from the embedded template rather than from an enum, so the two cannot drift:
/// adding `<dir>/svelte-ts` is enough to make `svelte` a valid manifest target.
fn target_of(template: &str) -> Result<Target, CliError> {
    let framework = framework_of(template)?;
    match framework {
        "vanilla" => Ok(Target::VanillaTs),
        "react" => Ok(Target::React),
        "vue" => Ok(Target::Vue),
        "svelte" => Ok(Target::Svelte),
        "solid" => Ok(Target::Solid),
        "angular" => Ok(Target::Angular),
        other => Err(CliError::Invalid(format!(
            "`{template}` names a framework this build does not know: {other}"
        ))),
    }
}

/// The framework half of a template's name.
fn framework_of(template: &str) -> Result<&str, CliError> {
    template
        .rsplit_once('-')
        .map(|(head, _)| head)
        .ok_or_else(|| CliError::Invalid(format!("`{template}` is not a framework-language pair")))
}

/// The language a template's name ends in.
///
/// Read from the name rather than asked for, because a template is one directory and a
/// developer who typed `--template vanilla-js` has already answered this. Getting it wrong
/// injects `main.ts` into a JavaScript project whose `index.html` loads `main.js`.
fn language_of(template: &str) -> Result<lepton_template_injector::Language, CliError> {
    match template.rsplit_once('-').map(|(_, tail)| tail) {
        Some("js") => Ok(lepton_template_injector::Language::JavaScript),
        Some("ts") => Ok(lepton_template_injector::Language::TypeScript),
        _ => Err(CliError::Invalid(format!(
            "`{template}` does not end in a language: expected `-ts` or `-js`"
        ))),
    }
}

/// How a scaffolded project renders.
///
/// A flag rather than part of the template because it changes what gets compiled in, not
/// which library draws the interface: a native project is still a Vite project, it simply
/// never loads an engine. Kept as its own word — `--target native` — because a script
/// reads better than two mutually-exclusive booleans.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum RenderMode {
    /// Draw straight to the window with no engine. The default, and the one that is
    /// verified on every machine this project is built on.
    Native,
    /// Load a page through the platform's web engine. Works where WPE WebKit is
    /// installed; not yet verified end to end, which is why it is not the default.
    Webview,
}

impl RenderMode {
    /// The value written into the project as `{{render_mode}}`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Webview => "webview",
        }
    }
}
