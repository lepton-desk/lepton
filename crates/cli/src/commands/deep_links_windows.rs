//! `deepLinks` for `lepton dev` and `lepton run` on Windows: each scheme registered for this
//! user under `HKCU\Software\Classes\<scheme>`, as the installer registers it, so a link opens
//! the program just built. Linux does the same with the desktop entry (`desktop_entry.rs`).
//!
//! Written with `reg.exe` (the workspace forbids `unsafe`, so no registry calls of its own).
//! A scheme another program already handles is left to it, as on Linux: the key Lepton
//! writes carries `LeptonGenerated`, and a key without it is not Lepton's to replace.

use std::path::Path;
use std::process::Command;

const MARKER: &str = "LeptonGenerated";

/// What happened to one scheme.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Registered,
    /// Another program's: its command, left as it was.
    Taken(String),
    Failed(String),
}

/// Registers each of `schemes` to open `exec` with the link as its argument.
pub fn register(schemes: &[String], product: &str, exec: &Path) -> Vec<(String, Outcome)> {
    schemes
        .iter()
        .map(|scheme| (scheme.clone(), register_one(scheme, product, exec)))
        .collect()
}

fn register_one(scheme: &str, product: &str, exec: &Path) -> Outcome {
    let key = format!("HKCU\\Software\\Classes\\{scheme}");
    let command_key = format!("{key}\\shell\\open\\command");
    let command = open_command(exec);
    if let Some(existing) = query(&command_key, None)
        && existing != command
        && query(&key, Some(MARKER)).is_none()
    {
        return Outcome::Taken(existing);
    }
    let writes: [(&str, Option<&str>, &str); 4] = [
        (&key, None, &format!("URL:{product}")),
        (&key, Some("URL Protocol"), ""),
        (&key, Some(MARKER), "1"),
        (&command_key, None, &command),
    ];
    for (at, name, data) in writes {
        if let Err(reason) = add(at, name, data) {
            return Outcome::Failed(reason);
        }
    }
    Outcome::Registered
}

/// `"<exe>" "%1"`: the program, and the link as one argument.
pub fn open_command(exec: &Path) -> String {
    format!("\"{}\" \"%1\"", exec.display())
}

/// A value of `key` (its default with `None`), or `None` when the key or value is absent.
fn query(key: &str, name: Option<&str>) -> Option<String> {
    let mut command = Command::new("reg");
    command.arg("query").arg(key);
    match name {
        Some(value) => command.arg("/v").arg(value),
        None => command.arg("/ve"),
    };
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_query(&String::from_utf8_lossy(&output.stdout))
}

/// The data of the one value `reg query` printed: `    <name>    REG_SZ    <data>`.
pub fn parse_query(text: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (_, rest) = line.split_once("REG_SZ")?;
        Some(rest.trim().to_owned())
    })
}

fn add(key: &str, name: Option<&str>, data: &str) -> Result<(), String> {
    let mut command = Command::new("reg");
    command.arg("add").arg(key);
    match name {
        Some(value) => command.arg("/v").arg(value),
        None => command.arg("/ve"),
    };
    let output = command
        .arg("/t")
        .arg("REG_SZ")
        .arg("/d")
        .arg(data)
        .arg("/f")
        .output()
        .map_err(|error| format!("could not run reg: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::{open_command, parse_query};
    use lepton_orchestrator::assert_eq;
    use lepton_orchestrator::testing::Failure;
    use std::path::Path;

    #[test]
    fn a_query_answer_is_its_data_and_the_command_quotes_both_arguments() -> Result<(), Failure> {
        let printed = "\r\nHKEY_CURRENT_USER\\Software\\Classes\\notes\\shell\\open\\command\r\n    (Default)    REG_SZ    \"C:\\Notes\\notes.exe\" \"%1\"\r\n\r\n";
        assert_eq!(
            parse_query(printed).as_deref(),
            Some("\"C:\\Notes\\notes.exe\" \"%1\"")
        );
        assert_eq!(
            parse_query("ERROR: The system was unable to find the key"),
            None::<String>
        );
        assert_eq!(
            open_command(Path::new("C:\\My Apps\\notes.exe")),
            "\"C:\\My Apps\\notes.exe\" \"%1\""
        );
        Ok(())
    }
}
