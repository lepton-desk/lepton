//! Colour for the tools Lepton streams.
//!
//! Their output reaches the terminal through a pipe (`run_streaming` reads it line by
//! line; handing them the terminal itself let a process the application started hold
//! `lepton run`'s streams open), and a tool writing to a pipe turns its colour off:
//! Vite's build table and pnpm's script line came out plain where Tauri's are coloured.
//! When `lepton` itself colours — its stdout a terminal, no `NO_COLOR` — the streamed
//! tools are told to colour too: `FORCE_COLOR` (Vite, Yarn, Bun, Node's own, and the tools a
//! package script runs), `CLICOLOR_FORCE` (Zig 0.16's `std.Io` reads it, as do many other
//! tools), and the package managers' own colour setting, which their own output follows
//! instead of `FORCE_COLOR`: measured 2026-10-18 by counting escapes in `pnpm install`
//! through a pipe — 0 with `FORCE_COLOR=3`, 5 with `pnpm_config_color=always` (pnpm 12);
//! npm 0 and 1 the same way with `npm_config_color=always`. `lepton update`'s install
//! came out plain before this.

use std::process::Command;
use std::sync::atomic::{AtomicU8, Ordering};

/// 0: no colour; 1: 16 colours; 2: 256; 3: full colour. `FORCE_COLOR`'s own levels.
static LEVEL: AtomicU8 = AtomicU8::new(0);

/// Set once by the CLI from its own decision about the terminal.
pub fn set_level(level: u8) {
    LEVEL.store(level.min(3), Ordering::Relaxed);
}

/// The variables a streamed tool gets, empty when `lepton` itself does not colour.
pub fn variables() -> Vec<(&'static str, String)> {
    match LEVEL.load(Ordering::Relaxed) {
        0 => Vec::new(),
        level => vec![
            ("FORCE_COLOR", level.to_string()),
            ("CLICOLOR_FORCE", String::from("1")),
            ("pnpm_config_color", String::from("always")),
            ("npm_config_color", String::from("always")),
        ],
    }
}

/// Adds [`variables`] to `command`, leaving any a step sets itself.
pub fn apply(command: &mut Command, explicit: &[(String, String)]) {
    for (name, value) in variables() {
        if !explicit.iter().any(|(set, _)| set == name) {
            command.env(name, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{set_level, variables};
    use crate::{assert_eq, testing::Failure};

    #[test]
    fn streamed_tools_colour_only_when_lepton_does() -> Result<(), Failure> {
        set_level(0);
        assert_eq!(variables().len(), 0);
        set_level(3);
        let set = variables();
        assert_eq!(
            set.iter()
                .find(|(name, _)| *name == "FORCE_COLOR")
                .map(|(_, v)| v.as_str()),
            Some("3")
        );
        assert_eq!(
            set.iter()
                .any(|(name, value)| *name == "CLICOLOR_FORCE" && value == "1"),
            true
        );
        for manager in ["pnpm_config_color", "npm_config_color"] {
            assert_eq!(
                set.iter()
                    .any(|(name, value)| *name == manager && value == "always"),
                true
            );
        }
        set_level(0);
        Ok(())
    }
}
