//! The lines `lepton build`, `run`, `dev` and `package` print around the tools they run.
//!
//! The same marks and colours as `lepton new` (`style.rs`): a header, then each tool's
//! own output framed by what it is and how long it took, and the facts after (where the
//! desktop entry went, what was packaged) as aligned `◆ label  value` lines. Plain text on
//! a pipe or with `NO_COLOR`, which a log reads just as well.
//!
//! ```text
//!   ◉ lepton  run · v0.1.7
//!
//!   ▸ frontend  pnpm run build
//!   …Vite's own output, in its colours…
//!   ✔ frontend  0.9 s
//!   ◆ desktop entry  ~/.local/share/applications/dev.lepton.notes.desktop
//! ```

use std::time::{Duration, Instant};

use lepton_orchestrator::{Step, display};

use crate::style::{AMBER, CYAN, GREEN, Painter, RED, VIOLET};

/// What a step is, in the word the frame shows.
pub fn label(step: &Step) -> &'static str {
    let first = step.args.first().map(String::as_str);
    match (step.program.as_str(), first) {
        ("zig", Some("build")) if step.args.get(1).map(String::as_str) == Some("commands") => {
            "types"
        }
        ("zig", _) => "core",
        (_, Some("--dir")) => "package",
        (_, Some("install")) => "install",
        // `lepton update` handing over to the project's newer CLI.
        (program, Some("update")) if program.ends_with("lepton") => "newer CLI",
        (_, _) if step.args.iter().any(|arg| arg == "dev") => "dev server",
        _ => "frontend",
    }
}

/// The command, shortened: the core's build carries every permission on one line.
fn short(step: &Step, width: usize) -> String {
    let full = display(step);
    if full.chars().count() <= width {
        return full;
    }
    let cut: String = full.chars().take(width.saturating_sub(1)).collect();
    format!("{}…", cut.trim_end())
}

/// `1.2 s`, `48 ms`, `2 min 05 s`.
pub fn took(elapsed: Duration) -> String {
    let seconds = elapsed.as_secs_f64();
    if seconds < 1.0 {
        format!("{} ms", elapsed.as_millis())
    } else if seconds < 60.0 {
        format!("{seconds:.1} s")
    } else {
        format!(
            "{} min {:02} s",
            elapsed.as_secs() / 60,
            elapsed.as_secs() % 60
        )
    }
}

/// The paths a reader recognises: `~` for the home directory.
pub fn home_short(path: &std::path::Path) -> String {
    home_text(&path.display().to_string())
}

/// A path as a reader in the project sees it: relative when it is under the working
/// directory, `~/…` when it is under the home directory, whole otherwise.
pub fn shown(path: &std::path::Path) -> String {
    match std::env::current_dir().ok().and_then(|here| {
        path.strip_prefix(here)
            .ok()
            .map(std::path::Path::to_path_buf)
    }) {
        Some(relative) if !relative.as_os_str().is_empty() => relative.display().to_string(),
        _ => home_short(path),
    }
}

/// [`shown`] for a line that holds paths among other words.
pub fn shown_text(text: &str) -> String {
    // `/` and, on Windows, `\`: a path the CLI joined carries the system's separator.
    let relative = match std::env::current_dir() {
        Ok(here) => text.replace(&format!("{}/", here.display()), "").replace(
            &format!("{}{}", here.display(), std::path::MAIN_SEPARATOR),
            "",
        ),
        Err(_) => text.to_owned(),
    };
    home_text(&relative)
}

/// [`home_short`] for a line that holds paths among other words.
pub fn home_text(text: &str) -> String {
    match crate::platform::home() {
        Some(home) => text.replace(home.to_string_lossy().as_ref(), "~"),
        None => text.to_owned(),
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Report {
    painter: Painter,
}

/// A step under way, for [`Report::finished`].
pub struct Started {
    label: &'static str,
    at: Instant,
}

impl Default for Report {
    fn default() -> Self {
        Self::new()
    }
}

impl Report {
    pub fn new() -> Self {
        Self {
            painter: Painter::detect(),
        }
    }

    /// A report that never paints, whatever stdout is: for text compared in tests.
    #[cfg(test)]
    pub fn plain() -> Self {
        Self {
            painter: Painter {
                depth: crate::style::Depth::None,
            },
        }
    }

    /// `  ◉ lepton  run · v0.1.7` and a blank line.
    pub fn header(&self, what: &str) {
        println!("{}", self.painter.header(what));
    }

    /// `  ▸ frontend  pnpm run build`, before the tool's own output.
    pub fn step(&self, step: &Step) -> Started {
        self.start(label(step), &short(step, 64))
    }

    /// `  ▸ <label>  <detail>` for anything that is not a planned step (the application).
    pub fn start(&self, label: &'static str, detail: &str) -> Started {
        println!(
            "  {} {} {}",
            self.painter.paint(CYAN, "▸"),
            self.painter.bold(&format!("{label:<14}")),
            self.painter.dim(detail)
        );
        Started {
            label,
            at: Instant::now(),
        }
    }

    /// `  ✔ frontend  0.9 s`, or `  ✖ core  failed after 3.2 s`.
    pub fn finished(&self, started: &Started, ok: bool) {
        let elapsed = took(started.at.elapsed());
        if ok {
            println!(
                "  {} {:<14} {}",
                self.painter.paint(GREEN, "✔"),
                started.label,
                self.painter.dim(&elapsed)
            );
        } else {
            eprintln!(
                "  {} {:<14} {}",
                self.painter.paint(RED, "✖"),
                started.label,
                self.painter.paint(RED, &format!("failed after {elapsed}"))
            );
        }
    }

    /// Runs `step` framed by [`step`](Self::step) and [`finished`](Self::finished).
    pub fn run(&self, step: &Step) -> lepton_orchestrator::Result<()> {
        let started = self.step(step);
        let outcome = lepton_orchestrator::run_streaming(step);
        self.finished(&started, outcome.is_ok());
        outcome
    }

    /// `  ◆ desktop entry  ~/.local/share/applications/…` — a fact, aligned.
    pub fn fact(&self, label: &str, value: &str) {
        println!("{}", self.fact_line(label, value, None));
    }

    /// A fact whose value is a warning: the value in amber.
    pub fn warn(&self, label: &str, value: &str) {
        eprintln!("{}", self.fact_line(label, value, Some(AMBER)));
    }

    /// The text of a [`fact`](Self::fact) line, for output assembled elsewhere.
    pub fn fact_text(&self, label: &str, value: &str) -> String {
        self.fact_line(label, value, None)
    }

    /// `  ◉ session` — a heading for a group of facts.
    pub fn title(&self, what: &str) -> String {
        format!(
            "  {} {}",
            self.painter.paint(CYAN, "◉"),
            self.painter.bold(what)
        )
    }

    fn fact_line(&self, label: &str, value: &str, tone: Option<crate::style::Colour>) -> String {
        let value = match tone {
            Some(colour) => self.painter.paint(colour, value),
            None => value.to_owned(),
        };
        format!(
            "  {} {} {value}",
            self.painter.paint(VIOLET, "◆"),
            self.painter.dim(&format!("{label:<14}"))
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{label, took};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{Step, assert_eq};
    use std::time::Duration;

    fn step(program: &str, args: &[&str]) -> Step {
        let mut step = Step::new("run", program);
        step.args = args.iter().map(|arg| (*arg).to_owned()).collect();
        step
    }

    #[test]
    fn each_step_is_named_by_what_it_builds() -> Result<(), Failure> {
        assert_eq!(
            label(&step("zig", &["build", "commands", "-Doptimize=Debug"])),
            "types"
        );
        assert_eq!(label(&step("zig", &["build", "-Doptimize=Debug"])), "core");
        assert_eq!(label(&step("pnpm", &["run", "build"])), "frontend");
        assert_eq!(
            label(&step("pnpm", &["--dir", "/x/packages/api", "run", "build"])),
            "package"
        );
        assert_eq!(
            label(&step("pnpm", &["run", "dev", "--port", "5173"])),
            "dev server"
        );
        assert_eq!(label(&step("pnpm", &["install"])), "install");
        assert_eq!(
            label(&step("/p/node_modules/.bin/lepton", &["update"])),
            "newer CLI"
        );
        Ok(())
    }

    #[test]
    fn durations_read_at_a_glance() -> Result<(), Failure> {
        assert_eq!(took(Duration::from_millis(48)), "48 ms");
        assert_eq!(took(Duration::from_millis(1234)), "1.2 s");
        assert_eq!(took(Duration::from_secs(125)), "2 min 05 s");
        Ok(())
    }
}
