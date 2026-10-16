//! How `lepton` looks in a terminal: the wordmark, the prompt theme and the step lines of
//! `lepton new`.
//!
//! Colour only where it can be seen: never when `NO_COLOR` is set (no-color.org) or when
//! stdout is not a terminal (a pipe, a CI log), always when `FORCE_COLOR` is. The depth
//! follows what the terminal says it can do — 24-bit with `COLORTERM=truecolor`, 256
//! colours with a `*-256color` `TERM`, the 16 basic ones otherwise — so the wordmark's
//! gradient degrades to two plain colours rather than to garbage.

use std::io::IsTerminal;

/// What the terminal can show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Depth {
    None,
    Basic,
    Extended,
    True,
}

/// Decides the depth from the environment, as a pure function so it is tested.
pub fn depth_from(
    no_color: bool,
    force: bool,
    terminal: bool,
    colorterm: &str,
    term: &str,
) -> Depth {
    if no_color {
        return Depth::None;
    }
    if !terminal && !force {
        return Depth::None;
    }
    if term == "dumb" && !force {
        return Depth::None;
    }
    if colorterm == "truecolor" || colorterm == "24bit" {
        Depth::True
    } else if term.contains("256color") {
        Depth::Extended
    } else {
        Depth::Basic
    }
}

/// The depth for this process's stdout.
pub fn depth() -> Depth {
    let get = |name: &str| std::env::var(name).unwrap_or_default();
    depth_from(
        std::env::var_os("NO_COLOR").is_some_and(|value| !value.is_empty()),
        std::env::var_os("FORCE_COLOR").is_some_and(|value| !value.is_empty() && value != "0"),
        std::io::stdout().is_terminal(),
        &get("COLORTERM"),
        &get("TERM"),
    )
}

/// A colour, given at full depth and with its 256-colour and basic stand-ins.
#[derive(Debug, Clone, Copy)]
pub struct Colour {
    pub rgb: (u8, u8, u8),
    pub extended: u8,
    pub basic: u8,
}

/// The palette: a lepton is an electron's family, so cold electric colours.
pub const CYAN: Colour = Colour {
    rgb: (34, 211, 238),
    extended: 45,
    basic: 36,
};
pub const VIOLET: Colour = Colour {
    rgb: (167, 139, 250),
    extended: 141,
    basic: 35,
};
pub const GREEN: Colour = Colour {
    rgb: (52, 211, 153),
    extended: 79,
    basic: 32,
};
pub const AMBER: Colour = Colour {
    rgb: (251, 191, 36),
    extended: 214,
    basic: 33,
};
pub const RED: Colour = Colour {
    rgb: (248, 113, 113),
    extended: 210,
    basic: 31,
};
pub const DIM: Colour = Colour {
    rgb: (128, 136, 150),
    extended: 245,
    basic: 90,
};

/// Paints with one depth decision for the whole run.
#[derive(Debug, Clone, Copy)]
pub struct Painter {
    pub depth: Depth,
}

impl Painter {
    pub fn detect() -> Self {
        Self { depth: depth() }
    }

    pub fn on(self) -> bool {
        self.depth != Depth::None
    }

    fn open(self, colour: Colour) -> String {
        match self.depth {
            Depth::None => String::new(),
            Depth::Basic => format!("\x1b[{}m", colour.basic),
            Depth::Extended => format!("\x1b[38;5;{}m", colour.extended),
            Depth::True => {
                let (r, g, b) = colour.rgb;
                format!("\x1b[38;2;{r};{g};{b}m")
            }
        }
    }

    pub fn paint(self, colour: Colour, text: &str) -> String {
        if !self.on() {
            return text.to_owned();
        }
        format!("{}{text}\x1b[0m", self.open(colour))
    }

    pub fn bold(self, text: &str) -> String {
        if !self.on() {
            return text.to_owned();
        }
        format!("\x1b[1m{text}\x1b[0m")
    }

    pub fn dim(self, text: &str) -> String {
        self.paint(DIM, text)
    }

    /// `lepton`, cyan into violet letter by letter at full depth; two colours below it.
    pub fn wordmark(self) -> String {
        let word = "lepton";
        match self.depth {
            Depth::None => word.to_owned(),
            Depth::True => {
                let count = word.chars().count().saturating_sub(1).max(1);
                let mut out = String::from("\x1b[1m");
                for (index, ch) in word.chars().enumerate() {
                    let mix = |a: u8, b: u8| {
                        let (a, b) = (f32::from(a), f32::from(b));
                        let at = index as f32 / count as f32;
                        (a + (b - a) * at).round() as u8
                    };
                    let (r, g, b) = (
                        mix(CYAN.rgb.0, VIOLET.rgb.0),
                        mix(CYAN.rgb.1, VIOLET.rgb.1),
                        mix(CYAN.rgb.2, VIOLET.rgb.2),
                    );
                    out.push_str(&format!("\x1b[38;2;{r};{g};{b}m{ch}"));
                }
                out.push_str("\x1b[0m");
                out
            }
            _ => format!(
                "\x1b[1m{}{}\x1b[0m",
                self.paint(CYAN, "lep"),
                self.paint(VIOLET, "ton")
            ),
        }
    }

    /// `  ◉ lepton  <what> · v0.1.5`
    pub fn header(self, what: &str) -> String {
        format!(
            "\n  {} {}  {} {}\n",
            self.paint(CYAN, "◉"),
            self.wordmark(),
            what,
            self.dim(&format!("· v{}", env!("CARGO_PKG_VERSION")))
        )
    }

    /// `  ◆ Frontend    Solid · TypeScript` — a question already answered.
    pub fn answered(self, label: &str, value: &str) -> String {
        let answer = if self.on() {
            format!("\x1b[1m{}", self.paint(CYAN, value))
        } else {
            value.to_owned()
        };
        format!("  {} {label:<11} {answer}", self.paint(VIOLET, "◆"))
    }

    /// `  ✔ Scaffolded the Solid frontend        8 files`
    pub fn done(self, what: &str, detail: &str) -> String {
        let pad = 48usize.saturating_sub(what.chars().count());
        format!(
            "  {} {what}{}{}",
            self.paint(GREEN, "✔"),
            " ".repeat(pad.max(2)),
            self.dim(detail)
        )
    }

    /// `  ◌ Installing dependencies with npm…`, replaced in place by the result line on a
    /// terminal.
    pub fn working(self, what: &str) -> String {
        format!("  {} {what}…", self.paint(AMBER, "◌"))
    }

    /// Moves back over a [`working`](Self::working) line so the result replaces it; on a
    /// pipe both lines stay, which reads fine in a log.
    pub fn replace_line(self) -> &'static str {
        if self.on() { "\x1b[1A\x1b[2K" } else { "" }
    }

    pub fn failed(self, what: &str) -> String {
        format!("  {} {what}", self.paint(RED, "✖"))
    }

    /// A command to type and what it does.
    pub fn command(self, command: &str, meaning: &str) -> String {
        if meaning.is_empty() {
            return format!("    {}", self.paint(CYAN, command));
        }
        let pad = 24usize.saturating_sub(command.chars().count());
        format!(
            "    {}{}{}",
            self.paint(CYAN, command),
            " ".repeat(pad.max(2)),
            self.dim(meaning)
        )
    }

    /// The prompts' theme: the same marks and colours as the lines around them.
    pub fn prompt_theme(self) -> inquire::ui::RenderConfig<'static> {
        use inquire::ui::{Attributes, Color, RenderConfig, StyleSheet, Styled};
        if !self.on() {
            return RenderConfig::empty()
                .with_prompt_prefix(Styled::new("  ◆"))
                .with_answered_prompt_prefix(Styled::new("  ◆"));
        }
        let rgb = |colour: Colour| {
            let (r, g, b) = colour.rgb;
            match self.depth {
                Depth::True => Color::Rgb { r, g, b },
                Depth::Extended => Color::AnsiValue(colour.extended),
                _ => match colour.basic {
                    36 => Color::DarkCyan,
                    35 => Color::DarkMagenta,
                    32 => Color::DarkGreen,
                    33 => Color::DarkYellow,
                    31 => Color::DarkRed,
                    _ => Color::DarkGrey,
                },
            }
        };
        RenderConfig::default()
            .with_prompt_prefix(Styled::new("  ◆").with_fg(rgb(VIOLET)))
            .with_answered_prompt_prefix(Styled::new("  ◆").with_fg(rgb(VIOLET)))
            .with_highlighted_option_prefix(Styled::new("›").with_fg(rgb(CYAN)))
            .with_selected_checkbox(Styled::new("◉").with_fg(rgb(GREEN)))
            .with_unselected_checkbox(Styled::new("○").with_fg(rgb(DIM)))
            .with_selected_option(Some(StyleSheet::new().with_fg(rgb(CYAN))))
            .with_answer(
                StyleSheet::new()
                    .with_fg(rgb(CYAN))
                    .with_attr(Attributes::BOLD),
            )
            .with_help_message(StyleSheet::new().with_fg(rgb(DIM)))
            .with_default_value(StyleSheet::new().with_fg(rgb(DIM)))
    }
}

#[cfg(test)]
mod tests {
    use super::{Depth, Painter, depth_from};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};

    #[test]
    fn colour_only_where_it_can_be_seen() -> Result<(), Failure> {
        assert_eq!(
            depth_from(true, true, true, "truecolor", "xterm-256color"),
            Depth::None
        );
        assert_eq!(
            depth_from(false, false, false, "truecolor", "xterm-256color"),
            Depth::None
        );
        assert_eq!(depth_from(false, true, false, "", "xterm"), Depth::Basic);
        assert_eq!(depth_from(false, false, true, "", "dumb"), Depth::None);
        assert_eq!(
            depth_from(false, false, true, "truecolor", "xterm-kitty"),
            Depth::True
        );
        assert_eq!(
            depth_from(false, false, true, "", "xterm-256color"),
            Depth::Extended
        );
        assert_eq!(depth_from(false, false, true, "", "linux"), Depth::Basic);
        Ok(())
    }

    #[test]
    fn without_colour_the_text_is_plain() -> Result<(), Failure> {
        let plain = Painter { depth: Depth::None };
        assert_eq!(plain.wordmark(), "lepton");
        ensure!(
            !plain.done("Added the core", "70 files").contains('\x1b'),
            "no escapes"
        );
        assert_eq!(plain.replace_line(), "");
        let lit = Painter { depth: Depth::True };
        ensure!(lit.wordmark().contains("38;2;34;211;238"), "starts cyan");
        ensure!(lit.wordmark().contains("38;2;167;139;250"), "ends violet");
        Ok(())
    }
}
