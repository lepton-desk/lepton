//! Release archives, written in Rust with no `tar` or `gzip` subprocess.
//!
//! An archive of one bundle directory is byte-identical every time it is written: entries
//! are sorted by path, owned by `root:root` (uid/gid 0), and stamped with one time —
//! `SOURCE_DATE_EPOCH` when the environment sets it, as reproducible-build tooling
//! expects, otherwise 0. File modes keep only whether a file is executable (0755/0644),
//! so a umask on the build machine never leaks into a release. Beside every archive goes
//! `<archive>.sha256` in `sha256sum` format, which also marks the archive as one this
//! code wrote and may therefore replace.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

use sha2::Digest as _;

use super::CliError;

/// The time stamped on every entry, from `SOURCE_DATE_EPOCH` or 0.
pub fn release_time() -> u64 {
    std::env::var("SOURCE_DATE_EPOCH")
        .ok()
        .and_then(|text| text.trim().parse().ok())
        .unwrap_or(0)
}

/// One entry, relative to the archive's top directory.
pub(super) struct Entry {
    pub path: PathBuf,
    pub source: PathBuf,
    pub directory: bool,
    pub executable: bool,
}

/// Writes `<dir>` as `<out>` (`.tar.gz`), every entry under `<top>/`, skipping names in
/// `skip`. Returns the archive's SHA-256 in hex.
pub fn tar_gz(
    dir: &Path,
    top: &str,
    skip: &[&str],
    out: &Path,
    mtime: u64,
) -> Result<String, CliError> {
    refuse_foreign(out)?;
    let entries = sorted_entries(dir, Path::new(top), skip)?;

    let partial = out.with_extension("part");
    let file = std::fs::File::create(&partial).map_err(|error| io(&partial, "create", &error))?;
    // `GzBuilder` writes mtime 0 and no file name into the gzip header unless told to.
    let gzip = flate2::GzBuilder::new().write(file, flate2::Compression::best());
    let mut builder = tar::Builder::new(gzip);

    let mut top_header = header(true, false, 0, mtime);
    builder
        .append_data(
            &mut top_header,
            directory_name(Path::new(top)),
            std::io::empty(),
        )
        .map_err(|error| io(out, "write", &error))?;
    append_entries(&mut builder, &entries, mtime, out)?;
    let gzip = builder
        .into_inner()
        .map_err(|error| io(out, "write", &error))?;
    let mut file = gzip.finish().map_err(|error| io(out, "write", &error))?;
    file.flush().map_err(|error| io(out, "write", &error))?;
    drop(file);
    publish(&partial, out)
}

/// Refuses to replace `out` unless its `.sha256` sidecar says this code wrote it.
pub(super) fn refuse_foreign(out: &Path) -> Result<(), CliError> {
    if out.exists() && !sidecar_of(out).is_file() {
        return Err(CliError::Invalid(format!(
            "{} exists and was not written by `lepton package`; move it away first",
            out.display()
        )));
    }
    Ok(())
}

/// Every entry under `dir`, prefixed with `prefix`, in byte order of the path — not the
/// directory listing's order, which differs between file systems.
pub(super) fn sorted_entries(
    dir: &Path,
    prefix: &Path,
    skip: &[&str],
) -> Result<Vec<Entry>, CliError> {
    let mut entries = Vec::new();
    collect(dir, prefix, skip, &mut entries)?;
    entries.sort_by(|a, b| a.path.as_os_str().cmp(b.path.as_os_str()));
    Ok(entries)
}

/// Appends `entries` with fixed owners, modes and time.
pub(super) fn append_entries<W: std::io::Write>(
    builder: &mut tar::Builder<W>,
    entries: &[Entry],
    mtime: u64,
    out: &Path,
) -> Result<(), CliError> {
    for entry in entries {
        if entry.directory {
            let mut head = header(true, false, 0, mtime);
            builder
                .append_data(&mut head, directory_name(&entry.path), std::io::empty())
                .map_err(|error| io(out, "write", &error))?;
        } else {
            let file = std::fs::File::open(&entry.source)
                .map_err(|error| io(&entry.source, "read", &error))?;
            let size = file
                .metadata()
                .map_err(|error| io(&entry.source, "inspect", &error))?
                .len();
            let mut head = header(false, entry.executable, size, mtime);
            builder
                .append_data(&mut head, &entry.path, file)
                .map_err(|error| io(out, "write", &error))?;
        }
    }
    Ok(())
}

/// A directory's member name ends in `/`, as `bsdtar` and GNU tar write it.
///
/// Measured: without it `pacman -U` printed "file not found in file list … skipping
/// extraction of usr/bin" for every directory — its file list names them `usr/bin/`.
fn directory_name(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push("/");
    PathBuf::from(name)
}

/// Renames the finished `partial` file to `out` and writes its `.sha256` sidecar.
///
/// Archives are written beside the target and renamed into place, so an interrupted run
/// never leaves a truncated archive under the real name.
pub(super) fn publish(partial: &Path, out: &Path) -> Result<String, CliError> {
    std::fs::rename(partial, out).map_err(|error| io(out, "write", &error))?;
    let digest = sha256_file(out)?;
    let name = out
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let sidecar = sidecar_of(out);
    std::fs::write(&sidecar, format!("{digest}  {name}\n"))
        .map_err(|error| io(&sidecar, "write", &error))?;
    Ok(digest)
}

/// `<archive>.sha256`.
pub fn sidecar_of(archive: &Path) -> PathBuf {
    let mut name = archive.as_os_str().to_owned();
    name.push(".sha256");
    PathBuf::from(name)
}

/// The SHA-256 of a file, in lowercase hex.
pub fn sha256_file(path: &Path) -> Result<String, CliError> {
    let mut file = std::fs::File::open(path).map_err(|error| io(path, "read", &error))?;
    let mut hasher = sha2::Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| io(path, "read", &error))?;
        let Some(chunk) = buffer.get(..read) else {
            break;
        };
        if chunk.is_empty() {
            break;
        }
        hasher.update(chunk);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub(super) fn header(directory: bool, executable: bool, size: u64, mtime: u64) -> tar::Header {
    let mut head = tar::Header::new_gnu();
    head.set_entry_type(if directory {
        tar::EntryType::Directory
    } else {
        tar::EntryType::Regular
    });
    head.set_mode(if directory || executable {
        0o755
    } else {
        0o644
    });
    head.set_size(size);
    head.set_mtime(mtime);
    head.set_uid(0);
    head.set_gid(0);
    // Names are fixed strings that fit the field; a failure here would be a bug in
    // `tar`, and the numeric ids above already say the same thing.
    let _ = head.set_username("root");
    let _ = head.set_groupname("root");
    head
}

/// Everything under `dir`, refusing anything that is neither a file nor a directory.
fn collect(
    dir: &Path,
    prefix: &Path,
    skip: &[&str],
    into: &mut Vec<Entry>,
) -> Result<(), CliError> {
    let listing = std::fs::read_dir(dir).map_err(|error| io(dir, "list", &error))?;
    for entry in listing {
        let entry = entry.map_err(|error| io(dir, "list", &error))?;
        let name = entry.file_name();
        if skip.iter().any(|skipped| name == *skipped) {
            continue;
        }
        let source = entry.path();
        let path = prefix.join(&name);
        // `symlink_metadata`: a link is refused, never followed into the release.
        let meta =
            std::fs::symlink_metadata(&source).map_err(|error| io(&source, "inspect", &error))?;
        if meta.is_dir() {
            into.push(Entry {
                path: path.clone(),
                source: source.clone(),
                directory: true,
                executable: false,
            });
            collect(&source, &path, &[], into)?;
        } else if meta.is_file() {
            let executable = executable(&meta, &path);
            into.push(Entry {
                path,
                source,
                directory: false,
                executable,
            });
        } else {
            return Err(CliError::Invalid(format!(
                "{} is not a regular file; a release ships only files it chose",
                source.display()
            )));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn executable(meta: &std::fs::Metadata, _: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    meta.permissions().mode() & 0o111 != 0
}

/// Windows keeps no execute bit, so the archive's member is marked by where it sits: the
/// program is `bin/<name>` in every bundle (`package.rs`). A `tar.gz` made on Windows
/// otherwise unpacked on Linux with a program that would not start.
#[cfg(not(unix))]
fn executable(_: &std::fs::Metadata, path: &Path) -> bool {
    marked_executable(path)
}

/// Whether `path` (inside the bundle) is the program: a file directly under a `bin` folder.
#[cfg_attr(unix, allow(dead_code))]
fn marked_executable(path: &Path) -> bool {
    path.parent()
        .and_then(Path::file_name)
        .is_some_and(|folder| folder == "bin")
}

pub(super) fn io(path: &Path, verb: &str, error: &std::io::Error) -> CliError {
    CliError::Invalid(format!("could not {verb} {}: {error}", path.display()))
}

// The tests set Unix file modes; packaging runs on Linux only (`package.rs`).
#[cfg(all(test, unix))]
mod tests {
    use super::{sha256_file, sidecar_of, tar_gz};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_err, assert_ok, ensure};
    use std::os::unix::fs::PermissionsExt as _;

    fn tree(scratch: &Scratch) -> Result<(), Failure> {
        scratch.write("app/bin/notes", "#!/bin/sh\n")?;
        std::fs::set_permissions(
            scratch.path().join("app/bin/notes"),
            std::fs::Permissions::from_mode(0o700),
        )
        .map_err(|error| fail("chmod", error))?;
        scratch.write("app/share/notes/dist/index.html", "<!doctype html>\n")?;
        scratch.write("app/share/notes/dist/assets/a.js", "export {};\n")?;
        scratch.write("app/.lepton-package", "marker\n")
    }

    /// (path, mode, mtime, uid, size) of one entry.
    type Listed = (String, u32, u64, u64, u64);

    /// Every entry, in archive order.
    fn listing(archive: &std::path::Path) -> Result<Vec<Listed>, Failure> {
        let file = std::fs::File::open(archive).map_err(|error| fail("open", error))?;
        let mut reader = tar::Archive::new(flate2::read::GzDecoder::new(file));
        let mut out = Vec::new();
        for entry in reader.entries().map_err(|error| fail("entries", error))? {
            let entry = entry.map_err(|error| fail("entry", error))?;
            let head = entry.header();
            out.push((
                entry
                    .path()
                    .map_err(|error| fail("path", error))?
                    .to_string_lossy()
                    .into_owned(),
                head.mode().map_err(|error| fail("mode", error))?,
                head.mtime().map_err(|error| fail("mtime", error))?,
                head.uid().map_err(|error| fail("uid", error))?,
                head.size().map_err(|error| fail("size", error))?,
            ));
        }
        Ok(out)
    }

    #[test]
    fn two_writes_of_one_tree_are_byte_identical() -> Result<(), Failure> {
        let scratch = Scratch::new("archive-repro")?;
        tree(&scratch)?;
        let out = scratch.path().join("notes.tar.gz");
        let first = assert_ok!(
            tar_gz(
                &scratch.path().join("app"),
                "notes/",
                &[".lepton-package"],
                &out,
                0
            ),
            "first"
        );
        // A different umask-looking mode on the source must not change the archive.
        std::fs::set_permissions(
            scratch.path().join("app/bin/notes"),
            std::fs::Permissions::from_mode(0o755),
        )
        .map_err(|error| fail("chmod", error))?;
        let second = assert_ok!(
            tar_gz(
                &scratch.path().join("app"),
                "notes/",
                &[".lepton-package"],
                &out,
                0
            ),
            "second"
        );
        assert_eq!(first, second);
        assert_eq!(assert_ok!(sha256_file(&out), "hash"), first);
        let sidecar = std::fs::read_to_string(sidecar_of(&out)).map_err(|e| fail("sidecar", e))?;
        assert_eq!(sidecar, format!("{first}  notes.tar.gz\n"));
        Ok(())
    }

    #[test]
    fn entries_are_sorted_owned_by_root_and_stamped_once() -> Result<(), Failure> {
        let scratch = Scratch::new("archive-entries")?;
        tree(&scratch)?;
        let out = scratch.path().join("notes.tar.gz");
        assert_ok!(
            tar_gz(
                &scratch.path().join("app"),
                "notes/",
                &[".lepton-package"],
                &out,
                1_700_000_000
            ),
            "writes"
        );
        let entries = listing(&out)?;
        let paths: Vec<&str> = entries.iter().map(|entry| entry.0.as_str()).collect();
        assert_eq!(
            paths,
            vec![
                "notes/",
                "notes/bin/",
                "notes/bin/notes",
                "notes/share/",
                "notes/share/notes/",
                "notes/share/notes/dist/",
                "notes/share/notes/dist/assets/",
                "notes/share/notes/dist/assets/a.js",
                "notes/share/notes/dist/index.html",
            ]
        );
        for (path, mode, mtime, uid, _) in &entries {
            ensure!(*mtime == 1_700_000_000, "{path} mtime {mtime}");
            ensure!(*uid == 0, "{path} uid {uid}");
            let expected = if path.ends_with(".js") || path.ends_with(".html") {
                0o644
            } else {
                0o755
            };
            ensure!(*mode == expected, "{path} mode {mode:o}");
        }
        Ok(())
    }

    #[test]
    fn a_file_it_did_not_write_is_never_replaced() -> Result<(), Failure> {
        let scratch = Scratch::new("archive-foreign")?;
        tree(&scratch)?;
        scratch.write("notes.tar.gz", "someone else's")?;
        let error = assert_err!(
            tar_gz(
                &scratch.path().join("app"),
                "notes/",
                &[],
                &scratch.path().join("notes.tar.gz"),
                0
            ),
            "foreign archive"
        );
        assert_contains!(&error.to_string(), "not written by `lepton package`");
        assert_eq!(scratch.read("notes.tar.gz")?, "someone else's");
        Ok(())
    }

    #[test]
    fn a_symlink_is_refused() -> Result<(), Failure> {
        let scratch = Scratch::new("archive-link")?;
        tree(&scratch)?;
        std::os::unix::fs::symlink("/etc/passwd", scratch.path().join("app/leak"))
            .map_err(|error| fail("symlink", error))?;
        let error = assert_err!(
            tar_gz(
                &scratch.path().join("app"),
                "notes/",
                &[],
                &scratch.path().join("notes.tar.gz"),
                0
            ),
            "link"
        );
        assert_contains!(&error.to_string(), "not a regular file");
        Ok(())
    }
}

#[cfg(test)]
mod marking {
    use super::marked_executable;
    use lepton_orchestrator::assert_eq;
    use lepton_orchestrator::testing::Failure;
    use std::path::Path;

    #[test]
    fn the_program_under_bin_is_executable_and_nothing_else() -> Result<(), Failure> {
        assert_eq!(marked_executable(Path::new("notes-0.1.0/bin/notes")), true);
        assert_eq!(marked_executable(Path::new("notes-0.1.0/bin/notes.exe")), true);
        assert_eq!(marked_executable(Path::new("notes-0.1.0/share/notes/dist/index.html")), false);
        assert_eq!(marked_executable(Path::new("notes-0.1.0/bin")), false);
        Ok(())
    }
}
