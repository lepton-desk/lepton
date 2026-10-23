//! Carrying the Zig core inside the CLI.
//!
//! A project created by `lepton new` has to build on a machine that has never heard
//! of Lepton: no checkout beside it, no network, no global package cache. The way to
//! get that is for the core to travel inside the binary that scaffolds it, and for
//! this crate to be the place that puts it down.
//!
//! ## Why a separate crate
//!
//! The template injector writes frontend files; this writes a Zig package. They have
//! nothing in common but the word "project", and a build script that walks a
//! filesystem tree has no business sitting next to a JSON merger. Splitting them also
//! keeps `lepton new`'s plan a plan: what it writes is decided in one place, and what
//! the CLI carries is put down in another.
//!
//! ## What a vendored package contains
//!
//! Exactly what the core's own build needs and nothing more:
//!
//! * `build.zig` — because a project calls the core's `configureCore` rather than
//!   repeating it, and that function lives there.
//! * `src/` — the modules themselves.
//! * `protocols/` — the vendored xdg-shell XML. These are read by `wayland-scanner`
//!   at build time, and a project whose Wayland path silently skipped them would
//!   produce a core that creates surfaces the compositor ignores.
//!
//! Nothing else. Build caches and editor scratch are excluded, so the vendor
//! directory is about the size of the source and nothing more.

#![forbid(unsafe_code)]

include!(concat!(env!("OUT_DIR"), "/carried.rs"));

use std::path::{Path, PathBuf};

/// Where the core lives, relative to a core build directory.
///
/// Deliberately relative to *that* and not to the project root: the project's build
/// file runs from `src-lepton`, and `@import` in a Zig build file is resolved against
/// the build's own directory. A path written relative to the project root would be
/// one level off here and wrong in a way that only shows as a missing file.
///
/// Named rather than repeated at each call site because two places depend on it and
/// neither can import the other: the CLI that writes the package, and the build file
/// a project is given.
pub const VENDORED_CORE: &str = "vendor/lepton-core";

/// How many files this build carries.
///
/// A test asserts this is not zero. A build script that silently walked an empty
/// directory would otherwise produce a crate that compiles, links, and vendors
/// nothing — and the failure would appear as a project that will not build, a long
/// way from here.
pub const COUNT: usize = CARRIED.len();

/// Why a package could not be written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A file could not be created or written.
    Write { path: PathBuf, reason: String },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Write { path, reason } => {
                write!(f, "could not write {}: {reason}", path.display())
            }
        }
    }
}

impl std::error::Error for Error {}

/// Writes the whole core under `package_root`.
///
/// Every file is written before any directory that only it needs, and the walk
/// creates parents as it goes. A failure part way through leaves a partial package,
/// which the caller reports rather than hides: a project whose vendor directory is
/// incomplete will fail to build with an error that names a `.zig` file and not the
/// directory, so the message here is the only place that can connect the two.
///
/// The caller is expected to run this into an empty directory, which is what
/// `lepton new` does after refusing to scaffold over anything.
pub fn write_into(package_root: &Path) -> Result<Vec<PathBuf>, Error> {
    let mut written = Vec::with_capacity(CARRIED.len());

    for (relative, contents) in CARRIED {
        let target = package_root.join(relative);

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| Error::Write {
                path: parent.to_path_buf(),
                reason: error.to_string(),
            })?;
        }

        std::fs::write(&target, contents).map_err(|error| Error::Write {
            path: target.clone(),
            reason: error.to_string(),
        })?;

        written.push(target);
    }

    Ok(written)
}

/// The core's files as `(relative path, contents)`, in the order they are written.
///
/// Exposed for the same reason the table is sorted: a caller that wants to describe
/// what a project now contains should see the same list in the same order every time.
pub fn files() -> Vec<(&'static str, &'static [u8])> {
    CARRIED.to_vec()
}

#[cfg(test)]
mod tests {
    use super::{CARRIED, COUNT, Error, VENDORED_CORE, files, write_into};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};

    /// The core's own root, found the way `build.rs` found it: two directories above
    /// this crate's manifest.
    fn core_root() -> std::path::PathBuf {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest
            .parent()
            .and_then(std::path::Path::parent)
            .map(|workspace| workspace.join("zig"))
            .unwrap_or_default()
    }

    #[test]
    fn the_core_is_carried_and_not_empty() -> Result<(), Failure> {
        // A build script that walked an empty directory would produce a crate that
        // compiles, links, and vendors nothing. The failure would then appear as a
        // project that will not build, far from here.
        ensure!(COUNT > 0, "the core table is empty");

        ensure!(
            CARRIED.iter().any(|(path, _)| *path == "src/root.zig"),
            "the core's root module must be carried"
        );
        ensure!(
            CARRIED.iter().any(|(path, _)| *path == "build.zig"),
            "the core's build file must be carried: a project calls configureCore"
        );
        Ok(())
    }

    #[test]
    fn the_wayland_protocol_xml_is_carried() -> Result<(), Failure> {
        // Read by `wayland-scanner` at build time. A project without them still
        // compiles on Linux — and creates surfaces the compositor ignores, which is the
        // one failure that looks exactly like a compositor bug.
        let protocols: Vec<&str> = CARRIED
            .iter()
            .map(|(path, _)| *path)
            .filter(|path| path.starts_with("protocols/"))
            .collect();

        ensure!(!protocols.is_empty(), "no protocol XML was carried");
        ensure!(
            protocols.iter().any(|path| path.ends_with("xdg-shell.xml")),
            "xdg-shell is required for the Wayland path, got {protocols:?}"
        );
        Ok(())
    }

    #[test]
    fn no_build_cache_travels_with_the_core() -> Result<(), Failure> {
        // A vendored package carrying a build cache would be as large as the
        // repository's, and every project would pay for it.
        for (path, _) in CARRIED {
            for banned in [".zig-cache", "zig-cache", "zig-out", ".git", "node_modules"] {
                ensure!(
                    !path.split('/').any(|segment| segment == banned),
                    "{path} is inside a {banned}"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn the_table_is_sorted_so_two_builds_agree() -> Result<(), Failure> {
        // A table whose order depends on the filesystem makes every build look like a
        // real change, and the diff is noise.
        let paths: Vec<&str> = CARRIED.iter().map(|(path, _)| *path).collect();

        for pair in paths.windows(2) {
            ensure!(
                pair[0] < pair[1],
                "{} should sort before {}",
                pair[0],
                pair[1]
            );
        }
        Ok(())
    }

    #[test]
    fn every_carried_path_is_relative_and_uses_forward_slashes() -> Result<(), Failure> {
        // The paths land inside a Zig build file that runs on three operating
        // systems, and only one separator is valid in all three.
        for (path, _) in CARRIED {
            ensure!(!path.starts_with('/'), "{path} is absolute");
            ensure!(!path.contains('\\'), "{path} carries a backslash");
            ensure!(!path.contains(".."), "{path} climbs out of the package");
        }
        Ok(())
    }

    #[test]
    fn every_carried_file_is_non_empty() -> Result<(), Failure> {
        // A zero-byte `.zig` is a compile error a long way from here, and an empty XML
        // is a scanner error. Both are cheaper to catch at the boundary.
        for (path, contents) in CARRIED {
            ensure!(!contents.is_empty(), "{path} is empty");
        }
        Ok(())
    }

    #[test]
    fn writing_produces_a_tree_that_matches_the_core() -> Result<(), Failure> {
        // The strongest statement available without building a project: the vendored
        // tree is the core's tree, file for file.
        let scratch = assert_ok!(
            Scratch::new("vendor"),
            "the scratch directory should be creatable"
        );
        let written = assert_ok!(write_into(scratch.path()), "the core should be written");

        assert_eq!(written.len(), COUNT);
        for (relative, _) in CARRIED {
            ensure!(
                scratch.exists(relative),
                "{relative} should have been written"
            );
        }
        Ok(())
    }

    #[test]
    fn the_written_tree_matches_the_core_on_disk() -> Result<(), Failure> {
        // Compared against the real repository, not against the table: a table that
        // disagreed with the tree it claims to carry is exactly the drift this crate
        // exists to prevent.
        let scratch = assert_ok!(
            Scratch::new("vendor-diff"),
            "the scratch directory should be creatable"
        );
        assert_ok!(write_into(scratch.path()), "the core should be written");

        for (relative, contents) in CARRIED {
            let original = core_root().join(relative);
            let actual = std::fs::read(scratch.path().join(relative)).map_err(|error| Failure {
                claim: format!("{relative} should be readable"),
                actual: format!("{error}"),
            })?;

            ensure!(
                original.is_file(),
                "{relative} is carried but is not in the core: {}",
                original.display()
            );

            // The bytes are compared, not the length. A table that carried a
            // truncated copy has the right length on the first line and is still
            // wrong, and a length check would pass it.
            assert_eq!(actual.as_slice(), *contents);
        }
        Ok(())
    }

    #[test]
    fn writing_twice_produces_the_same_tree() -> Result<(), Failure> {
        // `lepton new` refuses to scaffold over anything, so this only happens when a
        // developer re-runs it deliberately. It must not corrupt what is there.
        let scratch = assert_ok!(
            Scratch::new("vendor-twice"),
            "the scratch directory should be creatable"
        );

        let first = assert_ok!(write_into(scratch.path()), "the first write should succeed");
        let before: Vec<Vec<u8>> = first
            .iter()
            .map(|path| std::fs::read(path).unwrap_or_default())
            .collect();

        assert_ok!(
            write_into(scratch.path()),
            "the second write should succeed"
        );

        for (path, original) in first.iter().zip(&before) {
            let again = std::fs::read(path).map_err(|error| Failure {
                claim: format!("{} should still be readable", path.display()),
                actual: format!("{error}"),
            })?;
            ensure!(
                again == *original,
                "{} changed on the second write",
                path.display()
            );
        }
        Ok(())
    }

    #[test]
    fn writing_reports_the_path_it_could_not_write() -> Result<(), Failure> {
        // The message is the only place that can connect "a `.zig` file is missing" to
        // "the vendor directory is incomplete", because the second message never
        // appears anywhere else.
        let scratch = assert_ok!(
            Scratch::new("vendor-blocked"),
            "the scratch directory should be creatable"
        );
        // A regular file where `src/` has to go, so creating that directory fails with
        // a name that is already taken. `build.zig` would not have worked: it is a
        // single file at the package's root and would simply have been overwritten.
        std::fs::write(scratch.path().join("src"), "in the way").map_err(|error| Failure {
            claim: "the obstacle should be writable".to_owned(),
            actual: format!("{error}"),
        })?;

        let error = assert_err!(
            write_into(scratch.path()),
            "writing over an obstacle must fail"
        );

        // The message first, before anything is moved out of it.
        assert_contains!(&error.to_string(), "could not write");

        match error {
            // Matched rather than destructured inline so the fields can be checked
            // one at a time. `Error` has one variant today; a second one that a caller
            // has to understand would then be a compile error here rather than a
            // silently ignored arm.
            Error::Write { path, reason } => {
                ensure!(
                    path.starts_with(scratch.path()),
                    "the error names the path it failed on: {}",
                    path.display()
                );
                ensure!(
                    !reason.is_empty(),
                    "the error carries the system's own reason"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn the_vendored_location_is_the_one_a_projects_build_file_names() -> Result<(), Failure> {
        // Two places name this directory: the CLI that writes it and the build file
        // that imports from it. They cannot import each other, so the string is
        // asserted here instead of left to a comment.
        assert_eq!(VENDORED_CORE, "vendor/lepton-core");
        Ok(())
    }

    #[test]
    fn the_public_listing_matches_the_written_files() -> Result<(), Failure> {
        let listed = files();
        ensure!(
            listed.len() == COUNT,
            "the listing disagrees with the count"
        );

        for (relative, contents) in listed {
            let carried = CARRIED
                .iter()
                .find(|(path, _)| *path == relative)
                .map(|(_, body)| *body);

            ensure!(carried.is_some(), "{relative} is listed but not carried");
            ensure!(
                carried == Some(contents),
                "{relative} differs between the listing and the table"
            );
        }
        Ok(())
    }
}
