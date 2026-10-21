//! `lepton update`'s npm side: the project's `@lepton-desk/*` dependencies brought to a
//! release, and the release that is newest on the registry.
//!
//! Found on 0.1.7's release day: `pnpm lepton update` in a 0.1.6 project answered
//! "unrecognized subcommand 'update'". The project's lockfile held `@lepton-desk/cli`
//! 0.1.6 (its `^0.1.6` admits 0.1.7, but an install keeps what the lockfile says), and the
//! CLI that runs is the project's own — so a project could never reach a newer core by
//! itself. `lepton update` now moves the dependencies first, installs, and hands over to the
//! newly installed CLI, which carries the newer core and templates.

use std::path::Path;
use std::process::Command;

use serde_json::Value;

use super::package_manager::PackageManager;

/// The scope every Lepton package is published under.
pub const SCOPE: &str = "@lepton-desk/";

/// `x.y.z` with an optional `-beta.N` / `-rc.N`, ordered as semver orders them: a
/// prerelease comes before its release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    core: (u64, u64, u64),
    pre: Option<String>,
}

impl Version {
    pub fn parse(text: &str) -> Option<Self> {
        let (core, pre) = match text.split_once('-') {
            Some((core, pre)) => (core, Some(pre.to_owned())),
            None => (text, None),
        };
        // The registry's answer is written into `package.json`: a pre-release is semver's
        // dot-separated `[0-9A-Za-z-]` words and nothing that could leave the JSON string.
        if let Some(pre) = &pre {
            let word = |part: &str| {
                !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            };
            if !pre.split('.').all(word) {
                return None;
            }
        }
        let mut parts = core.split('.').map(str::parse::<u64>);
        let major = parts.next()?.ok()?;
        let minor = parts.next()?.ok()?;
        let patch = parts.next()?.ok()?;
        if parts.next().is_some() {
            return None;
        }
        Some(Self {
            core: (major, minor, patch),
            pre,
        })
    }

    /// The npm dist-tag this version is published under, as `tools/npm-preflight.sh`
    /// chooses it: `beta` for `-beta.N`, `next` for `-rc.N`, `latest` otherwise.
    pub fn dist_tag(&self) -> &'static str {
        match self.pre.as_deref() {
            Some(pre) if pre.starts_with("beta") => "beta",
            Some(pre) if pre.starts_with("rc") => "next",
            _ => "latest",
        }
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (major, minor, patch) = self.core;
        write!(f, "{major}.{minor}.{patch}")?;
        if let Some(pre) = &self.pre {
            write!(f, "-{pre}")?;
        }
        Ok(())
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.core
            .cmp(&other.core)
            .then_with(|| match (&self.pre, &other.pre) {
                (None, None) => std::cmp::Ordering::Equal,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (Some(_), None) => std::cmp::Ordering::Less,
                (Some(a), Some(b)) => prerelease_order(a, b),
            })
    }
}

/// `beta.2` before `beta.10`: numeric fields compare as numbers.
fn prerelease_order(a: &str, b: &str) -> std::cmp::Ordering {
    for (left, right) in a.split('.').zip(b.split('.')) {
        let order = match (left.parse::<u64>(), right.parse::<u64>()) {
            (Ok(x), Ok(y)) => x.cmp(&y),
            _ => left.cmp(right),
        };
        if order != std::cmp::Ordering::Equal {
            return order;
        }
    }
    a.split('.').count().cmp(&b.split('.').count())
}

/// One dependency moved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub name: String,
    pub from: String,
    pub to: String,
}

/// The dependency sections a project's `package.json` can name a Lepton package in.
const SECTIONS: [&str; 3] = ["dependencies", "devDependencies", "optionalDependencies"];

/// `manifest` with every `@lepton-desk/*` dependency older than `to` moved to it, keeping
/// its range prefix (`^0.1.6` → `^0.1.8`, `0.1.6` → `0.1.8`), and what moved.
///
/// Edited as text, not re-serialised, so the file keeps its own layout and key order. A
/// `link:`, `file:`, `workspace:` or `npm:` dependency is a checkout or an alias the
/// developer chose (the repository's own examples use `link:`) and is left as it is.
pub fn bump(manifest: &str, to: &Version) -> Result<(String, Vec<Change>), String> {
    let json: Value =
        serde_json::from_str(manifest).map_err(|error| format!("package.json: {error}"))?;
    let mut changes = Vec::new();
    for section in SECTIONS {
        let Some(entries) = json.get(section).and_then(Value::as_object) else {
            continue;
        };
        for (name, spec) in entries {
            let Some(spec) = spec.as_str() else { continue };
            if !name.starts_with(SCOPE) || spec.contains(':') {
                continue;
            }
            let prefix: String = spec
                .chars()
                .take_while(|c| *c == '^' || *c == '~')
                .collect();
            let Some(current) = Version::parse(&spec[prefix.len()..]) else {
                continue;
            };
            if current < *to {
                changes.push(Change {
                    name: name.clone(),
                    from: spec.to_owned(),
                    to: format!("{prefix}{to}"),
                });
            }
        }
    }
    let mut text = manifest.to_owned();
    for change in &changes {
        text = replace_spec(&text, &change.name, &change.from, &change.to);
    }
    Ok((text, changes))
}

/// Replaces `"name": "from"` (any spacing around the colon) with `"name": "to"`.
fn replace_spec(text: &str, name: &str, from: &str, to: &str) -> String {
    let key = format!("\"{name}\"");
    let value = format!("\"{from}\"");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(&key) {
        let (before, after_key) = rest.split_at(at + key.len());
        out.push_str(before);
        let gap = after_key.len()
            - after_key
                .trim_start_matches(|c: char| c.is_whitespace() || c == ':')
                .len();
        let (spacing, tail) = after_key.split_at(gap);
        if spacing.contains(':') && tail.starts_with(&value) {
            out.push_str(spacing);
            out.push_str(&format!("\"{to}\""));
            rest = &tail[value.len()..];
        } else {
            rest = after_key;
        }
    }
    out.push_str(rest);
    out
}

/// What the registry answers, its version line found among any notices printed with it.
pub fn version_in(output: &str) -> Option<Version> {
    output
        .lines()
        .rev()
        .map(str::trim)
        .find_map(|line| Version::parse(line.trim_matches('"')))
}

/// The `@lepton-desk/cli` under `tag` on the registry the project installs from, asked
/// through its own manager (so `.npmrc` registries apply), then npm; `None` when neither
/// answers. `latest` is the release; a beta CLI also asks `beta`, or a project on
/// `0.1.9-beta.0` would never hear of `0.1.9-beta.1` (`latest` stays at the last release).
pub fn latest(root: &Path, manager: PackageManager, tag: &str) -> Option<Version> {
    let package = format!("{SCOPE}cli@{tag}");
    let mut attempts: Vec<(&str, Vec<String>)> = vec![match manager {
        PackageManager::Npm | PackageManager::Pnpm => (
            manager.program(),
            vec!["view".into(), package.clone(), "version".into()],
        ),
        PackageManager::Bun => (
            "bun",
            vec![
                "pm".into(),
                "view".into(),
                package.clone(),
                "version".into(),
            ],
        ),
        PackageManager::Yarn => (
            "yarn",
            vec![
                "info".into(),
                package.clone(),
                "version".into(),
                "--silent".into(),
            ],
        ),
    }];
    if manager != PackageManager::Npm {
        attempts.push(("npm", vec!["view".into(), package, "version".into()]));
    }
    attempts.into_iter().find_map(|(program, args)| {
        let output = Command::new(lepton_orchestrator::program::resolve(program))
            .args(&args)
            .current_dir(root)
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        version_in(&String::from_utf8_lossy(&output.stdout))
    })
}

#[cfg(test)]
mod tests {
    use super::{Change, Version, bump, version_in};
    use lepton_orchestrator::testing::{Failure, fail};
    use lepton_orchestrator::{assert_eq, ensure};

    fn version(text: &str) -> Result<Version, Failure> {
        Version::parse(text).ok_or_else(|| fail("a version", text))
    }

    #[test]
    fn a_prerelease_names_the_tag_it_is_published_under() -> Result<(), Failure> {
        assert_eq!(version("0.1.9-beta.0")?.dist_tag(), "beta");
        assert_eq!(version("1.0.0-rc.2")?.dist_tag(), "next");
        assert_eq!(version("0.1.8")?.dist_tag(), "latest");
        Ok(())
    }

    #[test]
    fn versions_order_as_semver_does() -> Result<(), Failure> {
        ensure!(version("0.1.7")? < version("0.1.8")?, "patch");
        ensure!(version("0.1.10")? > version("0.1.9")?, "numeric, not text");
        ensure!(
            version("0.2.0-beta.1")? < version("0.2.0")?,
            "a prerelease before its release"
        );
        ensure!(
            version("0.2.0-beta.2")? < version("0.2.0-beta.10")?,
            "beta.2 before beta.10"
        );
        ensure!(
            version("0.2.0-beta.1")? > version("0.1.9")?,
            "0.2 beta after 0.1"
        );
        ensure!(
            Version::parse("0.1").is_none() && Version::parse("x.1.2").is_none(),
            "refused"
        );
        assert_eq!(version("0.2.0-rc.1")?.to_string(), "0.2.0-rc.1");
        Ok(())
    }

    #[test]
    fn older_lepton_dependencies_move_and_nothing_else_does() -> Result<(), Failure> {
        let manifest = r#"{
  "name": "torchila",
  "dependencies": {
    "@lepton-desk/api": "^0.1.6",
    "@lepton-desk/plugin-fs": "0.1.6",
    "@lepton-desk/plugin-os": "link:../plugin-os",
    "react": "^19.3.0"
  },
  "devDependencies": {
    "@lepton-desk/cli":"~0.1.7",
    "@biomejs/biome": "2.5.15"
  }
}
"#;
        let (text, changes) = bump(manifest, &version("0.1.8")?).map_err(|e| fail("a bump", e))?;
        assert_eq!(changes.len(), 3);
        ensure!(
            changes.contains(&Change {
                name: "@lepton-desk/cli".into(),
                from: "~0.1.7".into(),
                to: "~0.1.8".into()
            }),
            "the range prefix is kept"
        );
        assert_eq!(
            text,
            manifest
                .replace("\"^0.1.6\"", "\"^0.1.8\"")
                .replace("\"0.1.6\"", "\"0.1.8\"")
                .replace("\"~0.1.7\"", "\"~0.1.8\"")
        );
        Ok(())
    }

    #[test]
    fn a_project_already_there_is_left_alone() -> Result<(), Failure> {
        let manifest = r#"{"dependencies": {"@lepton-desk/api": "^0.1.9"}}"#;
        let (text, changes) = bump(manifest, &version("0.1.8")?).map_err(|e| fail("a bump", e))?;
        assert_eq!(changes.len(), 0);
        assert_eq!(text, manifest);
        Ok(())
    }

    #[test]
    fn the_version_line_is_found_among_notices() -> Result<(), Failure> {
        assert_eq!(
            version_in("npm notice something\n0.1.7\n"),
            Some(version("0.1.7")?)
        );
        assert_eq!(
            version_in("\"0.2.0-beta.1\"\n"),
            Some(version("0.2.0-beta.1")?)
        );
        assert_eq!(version_in("npm error 404\n"), None::<Version>);
        assert_eq!(Version::parse("1.0.0-beta\",\"x"), None::<Version>);
        assert_eq!(Version::parse("1.0.0-beta..1"), None::<Version>);
        Ok(())
    }
}
