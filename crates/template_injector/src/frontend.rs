//! The `frontend` section of `lepton.config.json`: where the bundler writes the built
//! page, and how its development server is told the port and address `lepton dev` chose.
//!
//! Without the section a project is a Vite project, as every project before 0.1.9 was:
//! `dist/`, and Vite's own flags. Other frameworks name theirs — measured 2026-10-19:
//! Next.js 16 exports to `out/` and takes `--hostname`; Astro 7 takes `--ignore-lock`, or
//! under an AI agent it moves its server into the background and `lepton dev` loses it;
//! Angular 22 writes `dist/` once `outputPath` says so. The flags are a list with `{port}`
//! and `{host}` in it rather than a framework name, so a framework Lepton has never heard
//! of needs a line of configuration, not a release.

use serde_json::Value;

use crate::manifest::ManifestError;

const SOURCE: &str = "lepton.config.json";

/// Replaced by the port `lepton dev` picked.
pub const PORT: &str = "{port}";
/// Replaced by the address the core loads the page from.
pub const HOST: &str = "{host}";

/// How a project's frontend is built and served.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frontend {
    /// `frontend.dist`: the bundler's output directory, relative to the project.
    pub dist: String,
    /// `frontend.devArgs`: the flags after `<manager> run dev`, with [`PORT`] and [`HOST`].
    pub dev_args: Vec<String>,
}

impl Default for Frontend {
    fn default() -> Self {
        Self {
            dist: String::from("dist"),
            dev_args: [
                "--port",
                PORT,
                // A taken port is an error rather than the next free one: the core has
                // already been told this one.
                "--strict-port",
                "--host",
                HOST,
                // Vite clears the terminal when it starts, which wiped `lepton dev`'s own
                // lines above it (seen in a pseudo-terminal: `ESC[1;1H ESC[0J`).
                "--clearScreen",
                "false",
            ]
            .map(String::from)
            .to_vec(),
        }
    }
}

impl Frontend {
    /// The dev server's flags for this port and address.
    pub fn dev_args_for(&self, port: u16, host: &str) -> Vec<String> {
        let port = port.to_string();
        self.dev_args
            .iter()
            .map(|arg| arg.replace(PORT, &port).replace(HOST, host))
            .collect()
    }
}

/// Reads the `frontend` section of a configuration file's text.
///
/// Strict: the core loads the page from the port and address it was given, so flags that
/// never pass `{port}` or `{host}` would open a window on a server that is somewhere else.
pub fn parse_frontend(text: &str) -> Result<Frontend, ManifestError> {
    let root: Value = serde_json::from_str(text).map_err(|error| ManifestError {
        reason: format!("{SOURCE} is not valid JSON: {error}"),
    })?;
    let section = match root.get("frontend") {
        None => return Ok(Frontend::default()),
        Some(section @ Value::Object(_)) => section,
        Some(_) => return Err(invalid("\"frontend\" must be an object")),
    };
    let dist = match section.get("dist") {
        None => Frontend::default().dist,
        Some(Value::String(text)) => relative_dir(text)?,
        Some(_) => return Err(invalid("\"frontend.dist\" must be a string")),
    };
    let dev_args = match section.get("devArgs") {
        None => Frontend::default().dev_args,
        Some(list) => dev_args(list)?,
    };
    Ok(Frontend { dist, dev_args })
}

/// A directory inside the project: not empty, not absolute, never above the root.
fn relative_dir(text: &str) -> Result<String, ManifestError> {
    let trimmed = text.trim().trim_end_matches(['/', '\\']);
    let escapes = trimmed
        .split(['/', '\\'])
        .any(|part| part == ".." || part.is_empty());
    let absolute = trimmed.starts_with(['/', '\\']) || trimmed.contains(':');
    if trimmed.is_empty() || escapes || absolute {
        return Err(invalid(&format!(
            "\"frontend.dist\" is {text:?}; name a directory inside the project, such as \"dist\" or \"out\""
        )));
    }
    Ok(trimmed.to_owned())
}

fn dev_args(list: &Value) -> Result<Vec<String>, ManifestError> {
    let Value::Array(items) = list else {
        return Err(invalid("\"frontend.devArgs\" must be an array of strings"));
    };
    let args = items
        .iter()
        .map(|item| match item {
            Value::String(text) => Ok(text.clone()),
            _ => Err(invalid("\"frontend.devArgs\" must be an array of strings")),
        })
        .collect::<Result<Vec<_>, _>>()?;
    for placeholder in [PORT, HOST] {
        if !args.iter().any(|arg| arg.contains(placeholder)) {
            return Err(invalid(&format!(
                "\"frontend.devArgs\" never passes {placeholder}; the core loads the page from the port and address `lepton dev` gives the server"
            )));
        }
    }
    Ok(args)
}

fn invalid(reason: &str) -> ManifestError {
    ManifestError {
        reason: format!("{SOURCE}: {reason}"),
    }
}

#[cfg(test)]
mod tests {
    use super::{Frontend, parse_frontend};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok};

    #[test]
    fn no_section_is_a_vite_project_as_before() -> Result<(), Failure> {
        let frontend = assert_ok!(parse_frontend(r#"{"productName":"Notes"}"#), "parses");
        assert_eq!(frontend, Frontend::default());
        assert_eq!(frontend.dist, "dist");
        assert_eq!(
            frontend.dev_args_for(5173, "127.0.0.1").join(" "),
            "--port 5173 --strict-port --host 127.0.0.1 --clearScreen false"
        );
        Ok(())
    }

    #[test]
    fn a_next_project_names_its_directory_and_flags() -> Result<(), Failure> {
        let frontend = assert_ok!(
            parse_frontend(
                r#"{"frontend":{"dist":"out/","devArgs":["--port","{port}","--hostname","{host}"]}}"#
            ),
            "parses"
        );
        assert_eq!(frontend.dist, "out");
        assert_eq!(
            frontend.dev_args_for(3001, "127.0.0.1"),
            vec![
                String::from("--port"),
                String::from("3001"),
                String::from("--hostname"),
                String::from("127.0.0.1")
            ]
        );
        Ok(())
    }

    #[test]
    fn a_placeholder_inside_a_flag_is_replaced_too() -> Result<(), Failure> {
        let frontend = assert_ok!(
            parse_frontend(r#"{"frontend":{"devArgs":["--listen={host}:{port}"]}}"#),
            "parses"
        );
        assert_eq!(
            frontend.dev_args_for(8080, "127.0.0.1"),
            vec![String::from("--listen=127.0.0.1:8080")]
        );
        Ok(())
    }

    #[test]
    fn flags_without_the_port_or_the_address_are_refused() -> Result<(), Failure> {
        let no_port = assert_err!(
            parse_frontend(r#"{"frontend":{"devArgs":["--host","{host}"]}}"#),
            "no port"
        );
        assert_contains!(&no_port.reason, "{port}");
        let no_host = assert_err!(
            parse_frontend(r#"{"frontend":{"devArgs":["--port","{port}"]}}"#),
            "no host"
        );
        assert_contains!(&no_host.reason, "{host}");
        let mistyped = assert_err!(
            parse_frontend(r#"{"frontend":{"devArgs":"--port {port}"}}"#),
            "string"
        );
        assert_contains!(&mistyped.reason, "array of strings");
        Ok(())
    }

    #[test]
    fn a_directory_outside_the_project_is_refused() -> Result<(), Failure> {
        for dist in ["", "/srv/www", "../site", "out/../..", "C:\\\\site", "a//b"] {
            let text = format!(r#"{{"frontend":{{"dist":{}}}}}"#, serde_json::json!(dist));
            let error = assert_err!(parse_frontend(&text), "outside");
            assert_contains!(&error.reason, "inside the project");
        }
        let nested = assert_ok!(
            parse_frontend(r#"{"frontend":{"dist":"dist/app/browser"}}"#),
            "nested"
        );
        assert_eq!(nested.dist, "dist/app/browser");
        Ok(())
    }
}
