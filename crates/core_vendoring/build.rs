//! Turning the Zig core into a list of files this crate can carry.
//!
//! A build script rather than a runtime walk for one reason: `lepton new` has to work
//! from an installed binary. The `lepton` a developer gets from a package manager has
//! no Lepton checkout beside it, so asking "where is the core?" at run time would
//! find nothing on exactly the machines that need it most.
//!
//! So the tree is walked here, at compile time, and the result is emitted as a table
//! of `include_bytes!`s. The binary carries the core; the project it creates does not
//! depend on anything outside itself.
//!
//! ## What is carried
//!
//! Five roots: the build file, `src`, `protocols`, `webview2` (Microsoft's header) and
//! `servo` (the Servo bridge's header). Anything else in the core's
//! directory is a build artefact or an editor's scratch file, and shipping one would
//! mean every project's vendor directory grows with the size of the repository's
//! cache.
//!
//! The roots are named rather than derived from "everything here", because
//! `zig-cache` and `.zig-cache` differ by a dot and by three releases, and a rule
//! that tries to exclude both will eventually exclude a source directory by mistake.
//! A new *root* is one line in [`ROOTS`]; a new *file* inside a root needs nothing,
//! which is the direction that matters, because forgetting to add a file to a list is
//! the failure that ships.
//!
//! ## Failing
//!
//! A build script's `main` cannot return a `Result`, so a failure here prints its own
//! message and exits non-zero. It is written that way rather than with `panic!`
//! because the workspace denies panics everywhere: a panic prints a backtrace and a
//! thread number, and the developer reading a failed `cargo build` needs to be told
//! which directory was missing, not where the unwind happened.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

/// The roots carried into a scaffolded project.
///
/// A file, then three directories. Written in this order because a project reads its
/// build file before anything it names exists, and a vendored core that arrives in
/// alphabetical order makes the directory listing look like it is missing something.
const ROOTS: &[(&str, Root)] = &[
    ("build.zig", Root::File),
    ("src", Root::Tree),
    ("protocols", Root::Tree),
    // Microsoft's WebView2 header and its licence: the Windows webview path compiles
    // against it (`src/render/webview/webview2/c.zig`).
    ("webview2", Root::Tree),
    // The Servo bridge's C ABI, imported by the experimental Servo engine
    // (`src/render/webview/servo/c.zig`) when a project builds with `-Dservo-lib`.
    ("servo", Root::Tree),
];

/// Which of the two shapes a root has.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Root {
    /// One file, carried as itself.
    File,
    /// A directory, walked.
    Tree,
}

/// Directory names never carried, whatever they are under.
///
/// Matched on the file name alone, so a cache nested three levels down is excluded
/// as well as one at the top. `zig-cache` is here alongside `.zig-cache` because a
/// checkout that has run the core's own build leaves both, under different releases.
const EXCLUDED: &[&str] = &[".zig-cache", "zig-cache", "zig-out", ".git", "node_modules"];

fn main() {
    let core = core_root();
    let mut carried: Vec<(String, PathBuf)> = Vec::new();

    for (relative, shape) in ROOTS {
        let start = core.join(relative);

        if !start.exists() {
            fail(&format!(
                "the core has no {relative}, so a scaffolded project would not build.\n\
                 looked in {}\n\
                 this crate carries the Zig core inside the CLI and must be built from a\n\
                 checkout that has one",
                start.display()
            ));
        }

        match shape {
            Root::File => carried.push(((*relative).to_owned(), start)),
            Root::Tree => walk(&core, &start, &mut carried),
        }
    }

    // Sorted so two builds of the same core produce the same table. The order a
    // filesystem hands entries back differs between machines, and a table that
    // changes order makes every build look like a real change.
    carried.sort_by(|first, second| first.0.cmp(&second.0));

    emit(&core, &carried);
}

/// The core's directory: the workspace two levels above this member.
///
/// Resolved from the manifest rather than the working directory so the crate builds
/// from anywhere, which is the whole reason a build script exists here.
fn core_root() -> PathBuf {
    let manifest = match std::env::var("CARGO_MANIFEST_DIR") {
        Ok(manifest) => PathBuf::from(manifest),
        Err(error) => fail(&format!("cargo did not set CARGO_MANIFEST_DIR: {error}")),
    };

    match manifest.parent().and_then(Path::parent) {
        Some(workspace) => workspace.join("zig"),
        None => fail(&format!(
            "could not find the workspace above {}: the path has no parent",
            manifest.display()
        )),
    }
}

/// Walks `root`, recording each file's path relative to the core's directory.
///
/// The core's own root is passed alongside rather than recovered from the path by
/// counting components: a path like `/home/user/repo/zig/src/x.zig` has one more
/// leading component than the number of directories in `zig`, and counting is exactly
/// the kind of arithmetic that stays right until somebody's checkout is one level
/// deeper than the last one.
fn walk(core: &Path, root: &Path, carried: &mut Vec<(String, PathBuf)>) {
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => fail(&format!("could not read {}: {error}", root.display())),
    };

    let mut paths: Vec<PathBuf> = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => paths.push(entry.path()),
            Err(error) => fail(&format!(
                "could not read an entry in {}: {error}",
                root.display()
            )),
        }
    }
    paths.sort();

    for path in paths {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            // A name that is not valid UTF-8 cannot appear in a Zig `@import`, so it
            // cannot be part of the core. Skipped rather than guessed at.
            continue;
        };

        if EXCLUDED.contains(&name) {
            continue;
        }

        if path.is_dir() {
            walk(core, &path, carried);
        } else if name.ends_with(".test.mjs") {
            // A test of the core's JavaScript (`cookie_shim.test.mjs`), run in the core's
            // checkout; no project's build reads it.
            continue;
        } else {
            carried.push((relative_to_core(core, &path), path));
        }
    }
}

/// A file's path relative to the core's directory.
fn relative_to_core(core: &Path, path: &Path) -> String {
    let relative = match path.strip_prefix(core) {
        Ok(relative) => relative,
        Err(error) => fail(&format!(
            "{} is not inside {}, so it cannot be vendored: {error}",
            path.display(),
            core.display()
        )),
    };

    // Forward slashes, because this string ends up inside a Zig build file on Linux,
    // macOS and Windows, and only one separator is valid in all three.
    relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

/// Writes the generated table, and tells cargo what to watch.
fn emit(core: &Path, carried: &[(String, PathBuf)]) {
    let out_dir = match std::env::var("OUT_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(error) => fail(&format!("cargo did not set OUT_DIR: {error}")),
    };
    let generated = out_dir.join("carried.rs");

    let mut source = String::with_capacity(carried.len() * 200);
    source.push_str("// Generated by `build.rs`. Do not edit: this table is the core, embedded.\n");
    source.push_str("//\n");
    source.push_str(
        "// Every path is absolute because this file lives in the build output directory,\n",
    );
    source.push_str("// and a relative path from there would point into `target/`.\n");
    source.push_str(
        "/// Every file of the Zig core, paired with its path inside a vendored package.\n",
    );
    // Bytes, not text: the core carries files that are not UTF-8 (the Direct3D 11 shaders'
    // DXBC), and `include_str!` refused them (measured on CI).
    source.push_str("pub const CARRIED: &[(&str, &[u8])] = &[\n");

    for (relative, absolute) in carried {
        let _ = writeln!(
            source,
            "    ({relative:?}, include_bytes!({:?})),",
            absolute.display().to_string()
        );
    }

    source.push_str("];\n");

    if let Err(error) = std::fs::write(&generated, source) {
        fail(&format!("could not write {}: {error}", generated.display()));
    }

    println!("cargo:rerun-if-changed=build.rs");
    for (_, absolute) in carried {
        println!("cargo:rerun-if-changed={}", absolute.display());
    }

    // The roots are watched as well as the files, which is what makes a deletion a
    // rebuild: a watcher on the surviving files alone would not notice a file leaving
    // the core, and the table would keep carrying it.
    for (relative, _) in ROOTS {
        let root = core.join(relative);
        if root.is_dir() {
            println!("cargo:rerun-if-changed={}", root.display());
        }
    }
}

/// Stops the build with a message a developer can act on.
///
/// `!` rather than a return type, so it reads as terminal at every call site without
/// a `return`.
fn fail(message: &str) -> ! {
    eprintln!("lepton-core-vendoring: {message}");
    std::process::exit(1);
}
