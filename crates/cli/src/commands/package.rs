//! `lepton package` — a release build laid out as an installable tree.
//!
//! The build already installs into `src-lepton/zig-out` in the layout a system uses:
//! `bin/<name>` and, for a webview project, `share/<name>/dist`. The binary finds its
//! frontend from its own location (`<exe>/../share/<name>/dist`), so the same tree runs
//! unpacked anywhere, from `~/.local`, or from `/usr`. Packaging is therefore a copy, not
//! a rewrite: the build's tree plus the desktop entry a shell needs to show the
//! application by name, into `src-lepton/bundle/<name>-<version>-linux-<arch>/`.
//!
//! Written in Rust, file by file, with no `tar` or package-manager subprocess: what goes
//! into a release is decided in one place, and every file in it is one this code chose.

use std::path::{Path, PathBuf};

use super::build::{CORE_DIR, read_manifest};
use super::{CliError, Outcome};

/// The file that marks a directory as one this command wrote, and may therefore replace.
pub const MARKER: &str = ".lepton-package";

/// Flags for `lepton package`.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Flags {
    /// Packages the native render path even if the configuration says webview.
    #[arg(long, conflicts_with = "webview")]
    pub native: bool,

    /// Packages the webview render path even if the configuration says native.
    #[arg(long)]
    pub webview: bool,

    /// Lays out the last build without building again.
    #[arg(long)]
    pub no_build: bool,

    /// Unpacks every written package into an empty directory, starts the application
    /// from there, measures it and closes it; fails if it does not stay up.
    #[arg(long)]
    pub verify: bool,
}

/// What one bundle is made of.
#[derive(Debug, Clone)]
pub struct Spec {
    /// The build's install prefix (`src-lepton/zig-out`).
    pub prefix: PathBuf,
    /// The executable's name, as the build was given it.
    pub binary: String,
    /// The `app_id`, which names the desktop entry.
    pub app_id: String,
    /// The name a shell shows.
    pub product: String,
    pub version: String,
    /// The directory bundles are written under.
    pub out: PathBuf,
}

impl Flags {
    /// Packages the project in the current directory.
    pub fn run(self) -> Outcome {
        let root = std::env::current_dir().map_err(|error| {
            CliError::Invalid(format!("could not read the working directory: {error}"))
        })?;
        super::report::Report::new().header("package");
        self.package_in(&root)
    }

    /// Builds (unless told not to) and lays out the project rooted at `root`.
    pub fn package_in(&self, root: &Path) -> Outcome {
        // Every format here is a Linux package of a Linux build; elsewhere it would be a
        // wrongly named archive of the wrong binary.
        if !cfg!(target_os = "linux") {
            return Err(CliError::Invalid(format!(
                "lepton package builds Linux packages and runs on Linux only for now (this is {})",
                std::env::consts::OS
            )));
        }
        lepton_orchestrator::require_project(root)?;
        // A SIGTERM to `lepton` ends the build or the application it started.
        lepton_orchestrator::supervise::install();
        let manifest = read_manifest(root)?;

        if !self.no_build {
            let build = super::build::Flags {
                native: self.native,
                webview: self.webview,
                ..Default::default()
            };
            build.build_in(root)?;
        }

        let spec = Spec {
            prefix: root.join(CORE_DIR).join("zig-out"),
            binary: super::launch::binary_name(&manifest.product_name),
            app_id: manifest.identifier.clone(),
            product: manifest.product_name.clone(),
            version: manifest.version.clone(),
            out: root.join(CORE_DIR).join("bundle"),
        };
        let bundle = assemble(&spec)?;
        let report = super::report::Report::new();
        report.fact("packaged", &super::report::shown(&bundle));

        let depends = report_dependencies(&bundle.join("bin").join(&spec.binary));

        let formats = read_bundle(root)?;
        let mut written = Vec::with_capacity(formats.targets.len());
        for target in &formats.targets {
            let (artifact, line) = write_target(&spec, &bundle, *target, &depends, &formats)?;
            report.fact(target.name(), &super::report::shown_text(&line));
            written.push((*target, artifact));
        }
        if self.verify {
            for (target, artifact) in &written {
                let report = super::verify::verify(artifact, *target, &spec.binary)?;
                super::report::Report::new()
                    .fact(&format!("verify {}", target.name()), &report.summary());
            }
        }
        Ok(())
    }
}

/// Prints the packages the binary needs at run time, from its own `DT_NEEDED` list.
///
/// Informational for the `.tar.gz` (which declares nothing); the Arch and Debian formats
/// will write the same list into their metadata. A failure to read it is printed, not
/// fatal, because the directory and archive are correct without it.
fn report_dependencies(binary: &Path) -> Vec<String> {
    match super::depends::resolve(binary) {
        Ok(found) => {
            let packages = super::depends::packages(&found);
            super::report::Report::new().fact("depends", &packages.join(" "));
            let unowned = super::depends::unowned(&found);
            if !unowned.is_empty() {
                super::report::Report::new().warn("no package owns", &unowned.join(" "));
            }
            packages
        }
        Err(error) => {
            super::report::Report::new().warn("depends", &format!("unknown: {error}"));
            Vec::new()
        }
    }
}

/// The Debian packages owning the binary's `DT_NEEDED` libraries, per `dpkg-query`.
///
/// Every library must have an owner: a `.deb` that leaves one out installs on a machine
/// that cannot start it. Off Debian there is no dpkg to ask, and the names are listed in
/// `bundle.deb.depends` instead.
fn debian_depends(binary: &Path) -> Result<Vec<String>, CliError> {
    let mut packages = Vec::new();
    let mut missing = Vec::new();
    for soname in super::depends::needed(binary)? {
        match super::depends::locate(&soname).and_then(|path| super::deb::dpkg_owner(&path)) {
            Some(owner) => packages.push(owner),
            None => missing.push(soname),
        }
    }
    if !missing.is_empty() {
        return Err(CliError::Invalid(format!(
            "no Debian package found for {} (is this a Debian system with dpkg?); build the .deb on Debian/Ubuntu or list the packages in \"bundle.deb.depends\"",
            missing.join(", ")
        )));
    }
    packages.sort();
    packages.dedup();
    Ok(packages)
}

/// The `bundle` section of the project's configuration.
fn read_bundle(root: &Path) -> Result<lepton_template_injector::Bundle, CliError> {
    let path = root.join(lepton_orchestrator::CONFIG_FILE);
    let text = std::fs::read_to_string(&path).map_err(|error| io(&path, "read", &error))?;
    lepton_template_injector::parse_bundle(&text).map_err(|error| CliError::Invalid(error.reason))
}

/// Writes one release format from the bundle directory and describes what it wrote.
///
/// A format that is not built yet is an error, never a skip: a release that quietly
/// lacks a listed format is found out by the user who needed it.
pub fn write_target(
    spec: &Spec,
    bundle: &Path,
    target: lepton_template_injector::BundleTarget,
    depends: &[String],
    formats: &lepton_template_injector::Bundle,
) -> Result<(PathBuf, String), CliError> {
    use lepton_template_injector::BundleTarget;
    match target {
        BundleTarget::TarGz => {
            let name = bundle_name(spec);
            let out = spec.out.join(format!("{name}.tar.gz"));
            let digest = super::archive::tar_gz(
                bundle,
                &name,
                &[MARKER],
                &out,
                super::archive::release_time(),
            )?;
            let size = std::fs::metadata(&out)
                .map_err(|error| io(&out, "inspect", &error))?
                .len();
            Ok((
                out.clone(),
                format!("{}  {} bytes  sha256 {digest}", out.display(), size),
            ))
        }
        BundleTarget::Arch => {
            if depends.is_empty() {
                // A package that declares nothing installs on a machine that cannot run it.
                return Err(CliError::Invalid(String::from(
                    "the Arch package needs the binary's dependencies, and none were resolved",
                )));
            }
            let (out, digest) = super::arch::write(&super::arch::Package {
                bundle,
                skip: &[MARKER],
                name: &spec.binary,
                version: &spec.version,
                description: &spec.product,
                depends,
                mtime: super::archive::release_time(),
                out: &spec.out,
            })?;
            let size = std::fs::metadata(&out)
                .map_err(|error| io(&out, "inspect", &error))?
                .len();
            Ok((
                out.clone(),
                format!("{}  {} bytes  sha256 {digest}", out.display(), size),
            ))
        }
        BundleTarget::Deb => {
            let maintainer = formats.maintainer.as_deref().ok_or_else(|| {
                CliError::Invalid(String::from(
                    "a .deb needs \"bundle.maintainer\" (\"Name <email>\") in lepton.config.json; Debian policy makes it mandatory",
                ))
            })?;
            let debian = match &formats.deb_depends {
                Some(listed) => listed.clone(),
                None => debian_depends(&bundle.join("bin").join(&spec.binary))?,
            };
            let (out, digest) = super::deb::write(&super::deb::Package {
                bundle,
                skip: &[MARKER],
                name: &spec.binary,
                version: &spec.version,
                description: &spec.product,
                maintainer,
                depends: &debian,
                mtime: super::archive::release_time(),
                out: &spec.out,
            })?;
            let size = std::fs::metadata(&out)
                .map_err(|error| io(&out, "inspect", &error))?
                .len();
            Ok((
                out.clone(),
                format!("{}  {} bytes  sha256 {digest}", out.display(), size),
            ))
        }
    }
}

/// The bundle's directory name: `<binary>-<version>-linux-<arch>`.
pub fn bundle_name(spec: &Spec) -> String {
    format!(
        "{}-{}-{}-{}",
        spec.binary,
        spec.version,
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

/// Lays the build out as a bundle and returns its directory.
///
/// A previous bundle of the same name is replaced only when it carries [`MARKER`]: a
/// directory this command did not write is never deleted on its behalf.
pub fn assemble(spec: &Spec) -> Result<PathBuf, CliError> {
    let program = spec.prefix.join("bin").join(&spec.binary);
    if !program.is_file() {
        return Err(CliError::Invalid(format!(
            "no built executable at {}; run `lepton build` first or drop --no-build",
            program.display()
        )));
    }

    let bundle = spec.out.join(bundle_name(spec));
    if bundle.exists() {
        if !bundle.join(MARKER).is_file() {
            return Err(CliError::Invalid(format!(
                "{} exists and was not written by `lepton package`; move it away first",
                bundle.display()
            )));
        }
        std::fs::remove_dir_all(&bundle).map_err(|error| io(&bundle, "remove", &error))?;
    }

    // `fs::copy` carries the permission bits, so the executable stays executable.
    let bin = bundle.join("bin");
    make_dir(&bin)?;
    copy_file(&program, &bin.join(&spec.binary))?;

    let share = spec.prefix.join("share").join(&spec.binary);
    if share.is_dir() {
        copy_tree(&share, &bundle.join("share").join(&spec.binary))?;
    }

    let applications = bundle.join("share").join("applications");
    // A bare `Exec`: installed, the binary is on `PATH`; the entry is for an install, not
    // for this directory.
    let entry =
        super::desktop_entry::entry_text(&spec.app_id, &spec.product, Path::new(&spec.binary));
    super::desktop_entry::install(&applications, &spec.app_id, &entry)?;

    write(&bundle.join(MARKER), &format!("{}\n", bundle_name(spec)))?;
    Ok(bundle)
}

/// Copies a directory tree, refusing anything that is neither a file nor a directory.
///
/// A symbolic link in a frontend bundle could point anywhere on the build machine, and
/// copying its target into a release would ship a file nobody chose.
fn copy_tree(from: &Path, to: &Path) -> Result<(), CliError> {
    make_dir(to)?;
    let entries = std::fs::read_dir(from).map_err(|error| io(from, "list", &error))?;
    for entry in entries {
        let entry = entry.map_err(|error| io(from, "list", &error))?;
        let kind = entry
            .file_type()
            .map_err(|error| io(&entry.path(), "inspect", &error))?;
        let target = to.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            copy_file(&entry.path(), &target)?;
        } else {
            return Err(CliError::Invalid(format!(
                "{} is not a regular file; a release ships only files it chose",
                entry.path().display()
            )));
        }
    }
    Ok(())
}

fn copy_file(from: &Path, to: &Path) -> Result<(), CliError> {
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|error| io(to, "write", &error))
}

fn make_dir(dir: &Path) -> Result<(), CliError> {
    std::fs::create_dir_all(dir).map_err(|error| io(dir, "create", &error))
}

fn write(path: &Path, text: &str) -> Result<(), CliError> {
    std::fs::write(path, text).map_err(|error| io(path, "write", &error))
}

fn io(path: &Path, verb: &str, error: &std::io::Error) -> CliError {
    CliError::Invalid(format!("could not {verb} {}: {error}", path.display()))
}

// Packaging runs on Linux only (`package_in`).
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::{MARKER, Spec, assemble, bundle_name, write_target};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_err, assert_ok, ensure};
    use lepton_template_injector::{Bundle, BundleTarget};
    use std::os::unix::fs::PermissionsExt as _;

    fn spec(scratch: &Scratch) -> Spec {
        Spec {
            prefix: scratch.path().join("zig-out"),
            binary: String::from("notes"),
            app_id: String::from("dev.example.notes"),
            product: String::from("Notes"),
            version: String::from("1.2.0"),
            out: scratch.path().join("bundle"),
        }
    }

    /// A build tree as the core's build leaves it, with an executable binary.
    fn built(scratch: &Scratch, frontend: bool) -> Result<(), Failure> {
        scratch.write("zig-out/bin/notes", "#!/bin/sh\n")?;
        let program = scratch.path().join("zig-out/bin/notes");
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755))
            .map_err(|error| lepton_orchestrator::testing::fail("chmod", error))?;
        if frontend {
            scratch.write("zig-out/share/notes/dist/index.html", "<!doctype html>\n")?;
            scratch.write("zig-out/share/notes/dist/assets/app.js", "export {};\n")?;
        }
        Ok(())
    }

    #[test]
    fn a_webview_bundle_carries_binary_frontend_and_entry() -> Result<(), Failure> {
        let scratch = Scratch::new("package-webview")?;
        built(&scratch, true)?;
        let spec = spec(&scratch);

        let bundle = assert_ok!(assemble(&spec), "a built project packages");
        let name = bundle_name(&spec);

        ensure!(
            bundle.ends_with(&name),
            "bundle named {name}: {}",
            bundle.display()
        );
        // The layout the binary resolves its frontend from: `<exe>/../share/<name>/dist`.
        ensure!(
            bundle.join("share/notes/dist/index.html").is_file(),
            "index missing"
        );
        ensure!(
            bundle.join("share/notes/dist/assets/app.js").is_file(),
            "nested asset missing"
        );
        let entry = scratch.read(&format!(
            "bundle/{name}/share/applications/dev.example.notes.desktop"
        ))?;
        assert_contains!(&entry, "Exec=\"notes\"\n");
        assert_contains!(&entry, "Name=Notes\n");
        Ok(())
    }

    #[test]
    fn the_executable_stays_executable() -> Result<(), Failure> {
        let scratch = Scratch::new("package-mode")?;
        built(&scratch, false)?;

        let bundle = assert_ok!(assemble(&spec(&scratch)), "packages");
        let mode = std::fs::metadata(bundle.join("bin/notes"))
            .map_err(|error| lepton_orchestrator::testing::fail("stat", error))?
            .permissions()
            .mode();
        ensure!(mode & 0o111 != 0, "mode {mode:o} lost the execute bits");
        ensure!(
            !bundle.join("share/notes").exists(),
            "a native bundle has no frontend"
        );
        Ok(())
    }

    #[test]
    fn a_rebuild_replaces_its_own_bundle_and_drops_stale_files() -> Result<(), Failure> {
        let scratch = Scratch::new("package-again")?;
        built(&scratch, true)?;
        let spec = spec(&scratch);
        let first = assert_ok!(assemble(&spec), "first");
        std::fs::write(first.join("share/notes/dist/stale.js"), "old")
            .map_err(|error| lepton_orchestrator::testing::fail("write", error))?;

        let second = assert_ok!(assemble(&spec), "second");
        ensure!(
            !second.join("share/notes/dist/stale.js").exists(),
            "stale file survived"
        );
        ensure!(second.join(MARKER).is_file(), "marker missing");
        Ok(())
    }

    #[test]
    fn a_directory_it_did_not_write_is_never_deleted() -> Result<(), Failure> {
        let scratch = Scratch::new("package-foreign")?;
        built(&scratch, false)?;
        let spec = spec(&scratch);
        scratch.write(
            &format!("bundle/{}/precious.txt", bundle_name(&spec)),
            "keep",
        )?;

        let error = assert_err!(assemble(&spec), "a foreign directory must survive");
        assert_contains!(&error.to_string(), "not written by `lepton package`");
        ensure!(
            scratch.exists(&format!("bundle/{}/precious.txt", bundle_name(&spec))),
            "the foreign file was deleted"
        );
        Ok(())
    }

    #[test]
    fn the_tarball_unpacks_to_the_bundle_without_its_marker() -> Result<(), Failure> {
        let scratch = Scratch::new("package-targz")?;
        built(&scratch, true)?;
        let spec = spec(&scratch);
        let bundle = assert_ok!(assemble(&spec), "packages");
        let (_, line) = assert_ok!(
            write_target(&spec, &bundle, BundleTarget::TarGz, &[], &Bundle::default()),
            "writes the tarball"
        );
        let name = bundle_name(&spec);
        assert_contains!(&line, &format!("{name}.tar.gz"));

        let file = std::fs::File::open(spec.out.join(format!("{name}.tar.gz")))
            .map_err(|error| lepton_orchestrator::testing::fail("open", error))?;
        let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(file));
        let unpacked = scratch.path().join("unpacked");
        archive
            .unpack(&unpacked)
            .map_err(|error| lepton_orchestrator::testing::fail("unpack", error))?;
        ensure!(
            unpacked.join(&name).join("bin/notes").is_file(),
            "binary missing"
        );
        ensure!(
            unpacked
                .join(&name)
                .join("share/notes/dist/index.html")
                .is_file(),
            "frontend missing"
        );
        ensure!(
            unpacked
                .join(&name)
                .join("share/applications/dev.example.notes.desktop")
                .is_file(),
            "desktop entry missing"
        );
        ensure!(
            !unpacked.join(&name).join(MARKER).exists(),
            "marker shipped"
        );
        Ok(())
    }

    #[test]
    fn a_deb_without_a_maintainer_is_refused_not_invented() -> Result<(), Failure> {
        let scratch = Scratch::new("package-deb")?;
        built(&scratch, false)?;
        let spec = spec(&scratch);
        let bundle = assert_ok!(assemble(&spec), "packages");
        let error = assert_err!(
            write_target(&spec, &bundle, BundleTarget::Deb, &[], &Bundle::default()),
            "deb"
        );
        assert_contains!(&error.to_string(), "bundle.maintainer");
        Ok(())
    }

    #[test]
    fn a_deb_with_listed_depends_is_written() -> Result<(), Failure> {
        let scratch = Scratch::new("package-deb-listed")?;
        built(&scratch, false)?;
        let spec = spec(&scratch);
        let bundle = assert_ok!(assemble(&spec), "packages");
        let formats = Bundle {
            targets: vec![BundleTarget::Deb],
            maintainer: Some(String::from("Ada <ada@example.org>")),
            deb_depends: Some(vec![String::from("libc6")]),
        };
        let (_, line) = assert_ok!(
            write_target(&spec, &bundle, BundleTarget::Deb, &[], &formats),
            "writes the deb"
        );
        assert_contains!(&line, "notes_1.2.0_");
        assert_contains!(&line, ".deb");
        Ok(())
    }

    #[test]
    fn no_build_means_no_bundle() -> Result<(), Failure> {
        let scratch = Scratch::new("package-unbuilt")?;
        let error = assert_err!(assemble(&spec(&scratch)), "nothing to package");
        assert_contains!(&error.to_string(), "lepton build");
        Ok(())
    }

    #[test]
    fn a_symlink_in_the_frontend_is_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("package-link")?;
        built(&scratch, true)?;
        std::os::unix::fs::symlink(
            "/etc/passwd",
            scratch.path().join("zig-out/share/notes/dist/leak"),
        )
        .map_err(|error| lepton_orchestrator::testing::fail("symlink", error))?;

        let error = assert_err!(
            assemble(&spec(&scratch)),
            "a link must not be followed into a release"
        );
        assert_contains!(&error.to_string(), "not a regular file");
        Ok(())
    }
}
