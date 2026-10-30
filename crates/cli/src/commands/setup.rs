//! `setup.exe`: Lepton's own Windows installer, the program from
//! `@lepton-desk/setup-windows-x64` followed by the application as a `.zip`.
//!
//! The program (`zig/src/setup/`) is the same for every application and is not built
//! here: it is Win32 only, no web engine, and reads the zip after itself. What it installs
//! is the bundle tree as the MSI installs it (`bin\`, `share\`) into
//! `%LOCALAPPDATA%\Programs\<product>`, with `.lepton-setup` beside them saying what it is:
//! the identifier, product, version, publisher, program, icon and schemes, the same values
//! the MSI writes (`installer.rs`), so both install the same application. The zip is
//! `zip.rs`'s, so the same bundle gives the same setup.exe.
//!
//! The program comes from the project's dependencies, at the CLI's own version, or from
//! `LEPTON_SETUP_PROGRAM` (a path) — what CI uses to try one built from this checkout.

use std::path::{Path, PathBuf};

use super::CliError;
use super::archive::{io, publish, refuse_foreign};
use super::package::{MARKER, Spec};

/// The npm package that carries the program, and the file in it.
pub const PROGRAM_PACKAGE: &str = "@lepton-desk/setup-windows-x64";
pub const PROGRAM_FILE: &str = "setup.exe";
/// A path to the program instead of the package's.
pub const PROGRAM_ENV: &str = "LEPTON_SETUP_PROGRAM";

/// The manifest's name in the zip (`payload.zig`'s `manifest_name`).
const MANIFEST: &str = ".lepton-setup";

/// `<bundle>-setup.exe`.
pub fn file_name(bundle_name: &str) -> String {
    format!("{bundle_name}-setup.exe")
}

/// The setup program: `LEPTON_SETUP_PROGRAM`, else the project's dependency at this CLI's
/// version.
pub fn program(root: &Path) -> Result<Vec<u8>, CliError> {
    let (path, from_package) = match std::env::var_os(PROGRAM_ENV) {
        Some(path) => (PathBuf::from(path), false),
        None => (
            root.join("node_modules")
                .join(PROGRAM_PACKAGE)
                .join(PROGRAM_FILE),
            true,
        ),
    };
    let version = env!("CARGO_PKG_VERSION");
    let bytes = std::fs::read(&path).map_err(|_| {
        CliError::Invalid(format!(
            "setup.exe needs Lepton's setup program: install it with `npm install -D {PROGRAM_PACKAGE}@{version}` (or pnpm add -D); {} is missing",
            path.display()
        ))
    })?;
    if from_package {
        // The program reads what this CLI writes: the two come from one release.
        let manifest = path.with_file_name("package.json");
        let text =
            std::fs::read_to_string(&manifest).map_err(|error| io(&manifest, "read", &error))?;
        let found = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|json| json.get("version")?.as_str().map(str::to_owned))
            .unwrap_or_default();
        if found != version {
            return Err(CliError::Invalid(format!(
                "{PROGRAM_PACKAGE} is {found}, this CLI is {version}: install {PROGRAM_PACKAGE}@{version}"
            )));
        }
    }
    if !bytes.starts_with(b"MZ") {
        return Err(CliError::Invalid(format!(
            "{} is not a Windows program",
            path.display()
        )));
    }
    Ok(bytes)
}

/// What `.lepton-setup` says.
pub struct Manifest<'a> {
    pub identifier: &'a str,
    pub product: &'a str,
    pub version: &'a str,
    pub publisher: &'a str,
    /// `bin/notes.exe`.
    pub program: &'a str,
    /// `share/notes/icon.ico`, when the bundle has it.
    pub icon: Option<&'a str>,
    pub schemes: &'a [String],
}

impl Manifest<'_> {
    /// `key=value` lines, `scheme` once per scheme. The values are checked here as the
    /// program checks them again (`payload.zig`): the product names a folder and a shortcut.
    pub fn text(&self) -> Result<String, CliError> {
        let refused = |what: &str, value: &str| {
            CliError::Invalid(format!("setup.exe cannot use {what} {value:?}"))
        };
        if self.product.is_empty()
            || self.product.chars().count() > 120
            || self.product.starts_with(' ')
            || self.product.ends_with(['.', ' '])
            || self
                .product
                .chars()
                .any(|ch| ch.is_control() || "<>:\"/\\|?*".contains(ch))
        {
            return Err(refused(
                "the product name (it names a folder and a shortcut)",
                self.product,
            ));
        }
        for (name, value) in [
            ("identifier", self.identifier),
            ("version", self.version),
            ("publisher", self.publisher),
        ] {
            if value.contains(['\n', '\r']) {
                return Err(refused(name, value));
            }
        }
        let mut lines = vec![
            format!("identifier={}", self.identifier),
            format!("product={}", self.product),
            format!("version={}", self.version),
            format!("publisher={}", self.publisher),
            format!("program={}", self.program),
        ];
        if let Some(icon) = self.icon {
            lines.push(format!("icon={icon}"));
        }
        lines.extend(self.schemes.iter().map(|scheme| format!("scheme={scheme}")));
        let mut text = lines.join("\n");
        text.push('\n');
        Ok(text)
    }
}

/// Lays out `<bundle>.setup\`: the bundle tree and `.lepton-setup`. A previous one is
/// replaced only when it carries [`MARKER`].
pub fn lay_out(
    spec: &Spec,
    bundle: &Path,
    bundle_name: &str,
    manifest: &str,
) -> Result<PathBuf, CliError> {
    let dir = spec.out.join(format!("{bundle_name}.setup"));
    if dir.exists() {
        if !dir.join(MARKER).is_file() {
            return Err(CliError::Invalid(format!(
                "{} exists and was not written by `lepton package`; move it away first",
                dir.display()
            )));
        }
        std::fs::remove_dir_all(&dir).map_err(|error| io(&dir, "remove", &error))?;
    }
    super::package_tree::copy_tree_skipping(bundle, &dir, &[MARKER])?;
    std::fs::write(dir.join(MANIFEST), manifest)
        .map_err(|error| io(&dir.join(MANIFEST), "write", &error))?;
    std::fs::write(dir.join(MARKER), format!("{bundle_name}\n"))
        .map_err(|error| io(&dir.join(MARKER), "write", &error))?;
    Ok(dir)
}

/// Writes `program` and `dir` as a zip under `top` into `out/<name>`, with its `.sha256`.
pub fn write(
    program: &[u8],
    dir: &Path,
    top: &str,
    out: &Path,
    name: &str,
    mtime: u64,
) -> Result<(PathBuf, String), CliError> {
    let target = out.join(name);
    refuse_foreign(&target)?;
    let zip = super::zip::bytes(dir, top, &[MARKER], &target, mtime)?;
    let partial = target.with_extension("part");
    let mut bytes = Vec::with_capacity(program.len() + zip.len());
    bytes.extend_from_slice(program);
    bytes.extend_from_slice(&zip);
    std::fs::write(&partial, &bytes).map_err(|error| io(&partial, "write", &error))?;
    let digest = publish(&partial, &target)?;
    Ok((target, digest))
}

#[cfg(test)]
mod tests {
    use super::{Manifest, write};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_ok, ensure};

    fn manifest<'a>(product: &'a str, schemes: &'a [String]) -> Manifest<'a> {
        Manifest {
            identifier: "dev.example.notes",
            product,
            version: "1.2.0-beta.3",
            publisher: "Example",
            program: "bin/notes.exe",
            icon: Some("share/notes/icon.ico"),
            schemes,
        }
    }

    #[test]
    fn the_manifest_names_what_the_program_installs() -> Result<(), Failure> {
        let schemes = vec![String::from("notes"), String::from("notes-dev")];
        let text = assert_ok!(manifest("Notes", &schemes).text(), "manifest");
        assert_eq!(
            text,
            "identifier=dev.example.notes\nproduct=Notes\nversion=1.2.0-beta.3\npublisher=Example\nprogram=bin/notes.exe\nicon=share/notes/icon.ico\nscheme=notes\nscheme=notes-dev\n"
        );
        for bad in ["No:tes", "Notes.", " Notes", "", "a/b"] {
            ensure!(
                manifest(bad, &schemes).text().is_err(),
                "product {bad:?} refused"
            );
        }
        Ok(())
    }

    #[test]
    fn the_zip_after_the_program_unpacks_and_the_same_tree_gives_the_same_file()
    -> Result<(), Failure> {
        let scratch = Scratch::new("setup")?;
        scratch.write("app.setup/bin/notes.exe", "MZ the program")?;
        scratch.write("app.setup/.lepton-setup", "identifier=a\n")?;
        scratch.write("app.setup/.lepton-package", "marker\n")?;
        let program = b"MZ setup's own program";
        let dir = scratch.path().join("app.setup");
        let (first, digest) = assert_ok!(
            write(program, &dir, "app", scratch.path(), "a-setup.exe", 0),
            "first"
        );
        let (_, again) = assert_ok!(
            write(program, &dir, "app", scratch.path(), "b-setup.exe", 0),
            "second"
        );
        assert_eq!(digest, again);
        let bytes = assert_ok!(std::fs::read(&first), "read");
        ensure!(bytes.starts_with(program), "the program comes first");

        let into = scratch.path().join("unpacked");
        assert_ok!(std::fs::create_dir(&into), "create");
        assert_ok!(super::super::zip::unpack(&first, &into), "unpack");
        let unpacked = assert_ok!(
            std::fs::read_to_string(into.join("app/bin/notes.exe")),
            "read program"
        );
        assert_contains!(&unpacked, "MZ the program");
        ensure!(
            !into.join("app/.lepton-package").exists(),
            "the marker stays out"
        );
        Ok(())
    }
}
