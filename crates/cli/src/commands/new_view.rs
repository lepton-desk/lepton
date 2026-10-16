//! How `lepton new` reads on screen: the names it shows for templates and render paths,
//! the answered-question lines, the step lines, and the closing next steps.
//!
//! The words are chosen for someone creating their first app: what each step did and how
//! much, never the internal detail (the channel name, the vendored path) unless asked
//! with `--verbose`.

use std::path::{Path, PathBuf};

use lepton_template_injector::Manifest;

use super::new::RenderMode;
use super::package_manager::PackageManager;
use crate::style::Painter;

/// Width of the question labels, so answers line up whether the wizard or a flag gave them.
pub const LABEL: usize = 11;

/// A prompt's message, padded like [`Painter::answered`] pads its label.
pub fn question(label: &str) -> String {
    format!("{label:<LABEL$}")
}

/// The wizard's order: TypeScript first, then the frameworks by how often they start a
/// desktop app, vanilla leading as in other app creators; anything new goes last.
pub fn wizard_order(available: &[String]) -> Vec<String> {
    const ORDER: [&str; 5] = ["vanilla", "react", "vue", "svelte", "solid"];
    let mut sorted = available.to_vec();
    sorted.sort_by_key(|name| {
        let (framework, language) = name.rsplit_once('-').unwrap_or((name, ""));
        let rank = ORDER
            .iter()
            .position(|known| *known == framework)
            .unwrap_or(ORDER.len());
        (usize::from(language != "ts"), rank, name.clone())
    });
    sorted
}

/// `solid-ts` → `Solid · TypeScript`.
pub fn template_label(template: &str) -> String {
    let (framework, language) = template.rsplit_once('-').unwrap_or((template, ""));
    let framework = match framework {
        "vanilla" => "Vanilla",
        "react" => "React",
        "vue" => "Vue",
        "svelte" => "Svelte",
        "solid" => "Solid",
        "angular" => "Angular",
        other => other,
    };
    let language = match language {
        "ts" => "TypeScript",
        "js" => "JavaScript",
        other => other,
    };
    format!("{framework} · {language}")
}

pub fn render_label(mode: RenderMode) -> &'static str {
    match mode {
        RenderMode::Webview => "webview · your page in WPE WebKit",
        RenderMode::Native => "native · drawn by the core, no web engine",
    }
}

pub fn plugins_label(plugins: &[&str]) -> String {
    if plugins.is_empty() {
        "none".to_owned()
    } else {
        plugins.join(", ")
    }
}

/// The lines for questions a flag answered, in the wizard's order.
pub fn answered_by_flags(
    paint: Painter,
    template: &str,
    mode: RenderMode,
    plugins: &[&str],
    identifier: &str,
) {
    println!("{}", paint.answered("Frontend", &template_label(template)));
    println!("{}", paint.answered("Render", render_label(mode)));
    if mode == RenderMode::Webview {
        println!("{}", paint.answered("Plugins", &plugins_label(plugins)));
    }
    println!("{}", paint.answered("Identifier", identifier));
}

/// What was written, as steps; every file only with `--verbose`.
/// What `lepton new` wrote, counted for the step lines.
pub struct Written<'a> {
    pub vendored: &'a [PathBuf],
    pub base: &'a [String],
    pub files: &'a [PathBuf],
}

pub fn steps(
    paint: Painter,
    template: &str,
    root: &Path,
    manifest: &Manifest,
    written: &Written<'_>,
    verbose: bool,
) {
    let (vendored, base) = (written.vendored, written.base);
    let written = written.files;
    println!();
    println!(
        "{}",
        paint.done(
            &format!("Scaffolded the {} frontend", template_label(template)),
            &format!("{} files", base.len())
        )
    );
    println!(
        "{}",
        paint.done(
            "Added the Lepton core",
            &format!("{} files", vendored.len())
        )
    );
    println!(
        "{}",
        paint.done(
            "Wired the window, commands and permissions",
            &format!("{} files", written.len())
        )
    );
    if !manifest.plugins.is_empty() {
        let commands: usize = manifest
            .plugins
            .iter()
            .filter_map(|name| lepton_template_injector::plugin_catalog::find(name))
            .map(|plugin| plugin.commands.len())
            .sum();
        println!(
            "{}",
            paint.done(
                &format!("Granted {}", plugins_label(&manifest.plugins)),
                &format!("{commands} commands")
            )
        );
    }
    if verbose {
        println!(
            "{}",
            paint.dim(&format!("    channel {}", manifest.channel_name))
        );
        for path in written {
            let relative = path.strip_prefix(root).unwrap_or(path);
            println!("{}", paint.dim(&format!("    {}", relative.display())));
        }
    }
}

/// The closing block: where the app is and what to type, in the project's own manager.
pub fn next_steps(
    paint: Painter,
    template: &str,
    root: &Path,
    manager: PackageManager,
    installed: bool,
    manifest: &Manifest,
) {
    println!(
        "\n  {} {}\n",
        paint.bold("Your app is ready in"),
        paint.paint(crate::style::CYAN, &root.display().to_string())
    );
    println!("{}", paint.command(&format!("cd {}", root.display()), ""));
    if !installed {
        println!(
            "{}",
            paint.command(manager.install_command(), "install the dependencies")
        );
    }
    println!(
        "{}",
        paint.command(
            &manager.lepton_command(&["dev"]),
            "open the window, with hot reload"
        )
    );
    println!(
        "{}",
        paint.command(
            &manager.lepton_command(&["build"]),
            "build a release binary"
        )
    );
    if manifest.render_path == lepton_template_injector::RenderPath::Native {
        println!(
            "\n  {}",
            paint.dim(&format!(
                "native: the core draws the window and the {} page is not loaded.",
                template_label(template)
            ))
        );
        println!(
            "  {}",
            paint.dim("Set \"renderPath\": \"webview\" in lepton.config.json to load it.")
        );
    }
    println!(
        "\n  {}\n",
        paint.dim("docs  https://github.com/lepton-desk/lepton")
    );
}

#[cfg(test)]
mod tests {
    use super::{plugins_label, question, template_label};
    use lepton_orchestrator::assert_eq;
    use lepton_orchestrator::testing::Failure;

    #[test]
    fn names_read_as_words() -> Result<(), Failure> {
        assert_eq!(template_label("solid-ts"), "Solid · TypeScript");
        assert_eq!(template_label("react-js"), "React · JavaScript");
        assert_eq!(plugins_label(&[]), "none");
        assert_eq!(plugins_label(&["os", "fs"]), "os, fs");
        assert_eq!(question("Render"), "Render     ");
        let order = super::wizard_order(&[
            "react-js".into(),
            "solid-ts".into(),
            "vanilla-ts".into(),
            "vue-ts".into(),
            "vanilla-js".into(),
        ]);
        assert_eq!(
            order,
            ["vanilla-ts", "vue-ts", "solid-ts", "vanilla-js", "react-js"]
        );
        Ok(())
    }
}
