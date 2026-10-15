//! The Debian package (`.deb`), written in Rust with no `dpkg-deb`.
//!
//! A `.deb` is an `ar` archive of three members, in this order: `debian-binary`
//! (`2.0\n`), `control.tar.gz` (the `control` file) and `data.tar.gz` (the files, under
//! `usr/` exactly as in the Arch package). Like every Lepton archive the result is
//! reproducible: sorted entries, `root:root`, one time stamp in every header.
//!
//! Dependencies are Debian package names, which cannot be derived from a library name on
//! another distribution: they come from `dpkg-query -S` where dpkg exists, or from
//! `bundle.deb.depends`, and the format refuses to run with neither.

use std::fmt::Write as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use super::CliError;
use super::archive::{self, io};

/// What one Debian package is made of.
pub struct Package<'a> {
    pub bundle: &'a Path,
    pub skip: &'a [&'a str],
    /// The executable's name; mapped to Debian's package-name rules by [`package_name`].
    pub name: &'a str,
    pub version: &'a str,
    pub description: &'a str,
    pub maintainer: &'a str,
    pub depends: &'a [String],
    pub mtime: u64,
    pub out: &'a Path,
}

/// Debian's architecture name for the machine Lepton is building on.
pub fn architecture() -> Result<&'static str, CliError> {
    match std::env::consts::ARCH {
        "x86_64" => Ok("amd64"),
        "aarch64" => Ok("arm64"),
        other => Err(CliError::Invalid(format!(
            "no Debian architecture name is known for {other}"
        ))),
    }
}

/// A package name as Debian allows it: lowercase `[a-z0-9+.-]`, so `_` becomes `-`.
pub fn package_name(name: &str) -> String {
    name.chars()
        .map(|ch| match ch {
            'a'..='z' | '0'..='9' | '+' | '.' | '-' => ch,
            'A'..='Z' => ch.to_ascii_lowercase(),
            _ => '-',
        })
        .collect()
}

/// A semver version as a Debian upstream version: the pre-release dash becomes `~`,
/// which Debian sorts *before* the release (`1.0.0~beta.1` < `1.0.0`), and build
/// metadata is dropped as semver gives it no precedence.
pub fn version(semver: &str) -> String {
    let core = semver.split('+').next().unwrap_or(semver);
    core.replacen('-', "~", 1)
}

/// `<package>_<version>_<arch>.deb`.
pub fn file_name(name: &str, semver: &str) -> Result<String, CliError> {
    Ok(format!(
        "{}_{}_{}.deb",
        package_name(name),
        version(semver),
        architecture()?
    ))
}

/// The package that owns `library` per `dpkg-query -S`; `None` without dpkg or an owner.
///
/// On a merged-`/usr` system dpkg may know a library only under `/lib`, so both spellings
/// are asked.
pub fn dpkg_owner(library: &Path) -> Option<String> {
    let mut candidates = vec![library.to_path_buf()];
    if let Ok(short) = library.strip_prefix("/usr") {
        candidates.push(Path::new("/").join(short));
    }
    candidates.into_iter().find_map(|path| {
        let output = std::process::Command::new("dpkg-query")
            .arg("-S")
            .arg(&path)
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        // `libc6:amd64: /usr/lib/x86_64-linux-gnu/libc.so.6`
        let text = String::from_utf8(output.stdout).ok()?;
        let owner = text.lines().next()?.split(": ").next()?;
        let owner = owner.split(':').next()?.trim();
        (!owner.is_empty()).then(|| owner.to_owned())
    })
}

/// Writes the package and returns its path and SHA-256.
pub fn write(package: &Package<'_>) -> Result<(PathBuf, String), CliError> {
    let out = package.out.join(file_name(package.name, package.version)?);
    archive::refuse_foreign(&out)?;

    let mut entries = vec![archive::Entry {
        path: PathBuf::from("usr"),
        source: package.bundle.to_path_buf(),
        directory: true,
        executable: false,
    }];
    entries.extend(archive::sorted_entries(
        package.bundle,
        Path::new("usr"),
        package.skip,
    )?);
    let installed: u64 = entries
        .iter()
        .filter(|entry| !entry.directory)
        .map(|entry| std::fs::metadata(&entry.source).map(|meta| meta.len()))
        .sum::<Result<u64, _>>()
        .map_err(|error| io(package.bundle, "inspect", &error))?;

    let control = control(package, installed)?;
    let mut control_tar = tar::Builder::new(gzip());
    let mut head = archive::header(false, false, control.len() as u64, package.mtime);
    control_tar
        .append_data(&mut head, "control", control.as_bytes())
        .map_err(|error| io(&out, "write", &error))?;
    let control_gz = finish(control_tar, &out)?;

    let mut data_tar = tar::Builder::new(gzip());
    archive::append_entries(&mut data_tar, &entries, package.mtime, &out)?;
    let data_gz = finish(data_tar, &out)?;

    let mut deb = Vec::with_capacity(control_gz.len() + data_gz.len() + 256);
    deb.extend_from_slice(b"!<arch>\n");
    member(&mut deb, "debian-binary", b"2.0\n", package.mtime)?;
    member(&mut deb, "control.tar.gz", &control_gz, package.mtime)?;
    member(&mut deb, "data.tar.gz", &data_gz, package.mtime)?;

    let partial = out.with_extension("part");
    let mut file =
        std::fs::File::create(&partial).map_err(|error| io(&partial, "create", &error))?;
    file.write_all(&deb)
        .and_then(|()| file.flush())
        .map_err(|error| io(&partial, "write", &error))?;
    drop(file);
    let digest = archive::publish(&partial, &out)?;
    Ok((out, digest))
}

/// The `control` file.
pub fn control(package: &Package<'_>, installed: u64) -> Result<String, CliError> {
    let mut text = String::new();
    let _ = writeln!(text, "Package: {}", package_name(package.name));
    let _ = writeln!(text, "Version: {}", version(package.version));
    let _ = writeln!(text, "Architecture: {}", architecture()?);
    let _ = writeln!(text, "Maintainer: {}", one_line(package.maintainer));
    let _ = writeln!(text, "Installed-Size: {}", installed.div_ceil(1024));
    if !package.depends.is_empty() {
        let _ = writeln!(text, "Depends: {}", package.depends.join(", "));
    }
    let _ = writeln!(text, "Section: misc");
    let _ = writeln!(text, "Priority: optional");
    let _ = writeln!(text, "Description: {}", one_line(package.description));
    Ok(text)
}

fn gzip() -> flate2::write::GzEncoder<Vec<u8>> {
    flate2::GzBuilder::new().write(Vec::new(), flate2::Compression::best())
}

fn finish(
    builder: tar::Builder<flate2::write::GzEncoder<Vec<u8>>>,
    out: &Path,
) -> Result<Vec<u8>, CliError> {
    builder
        .into_inner()
        .and_then(flate2::write::GzEncoder::finish)
        .map_err(|error| io(out, "write", &error))
}

/// One `ar` member: a 60-byte header, the bytes, and a `\n` pad to an even offset.
///
/// The header is fixed-width ASCII: name (16), mtime (12), uid (6), gid (6), octal mode
/// (8), size (10), then the magic "`\n". Names are written as dpkg writes them, without
/// GNU's trailing `/`.
fn member(into: &mut Vec<u8>, name: &str, bytes: &[u8], mtime: u64) -> Result<(), CliError> {
    let header = format!(
        "{name:<16}{mtime:<12}{:<6}{:<6}{:<8}{:<10}`\n",
        0,
        0,
        "100644",
        bytes.len()
    );
    if header.len() != 60 {
        return Err(CliError::Invalid(format!(
            "ar member {name} does not fit a 60-byte header"
        )));
    }
    into.extend_from_slice(header.as_bytes());
    into.extend_from_slice(bytes);
    if bytes.len() % 2 == 1 {
        into.push(b'\n');
    }
    Ok(())
}

/// The bytes of the `ar` member called `name`, if the archive is well-formed and has one.
pub fn ar_member<'a>(deb: &'a [u8], name: &str) -> Option<&'a [u8]> {
    if !deb.starts_with(b"!<arch>\n") {
        return None;
    }
    let mut at = 8_usize;
    while at < deb.len() {
        let header = deb.get(at..at.checked_add(60)?)?;
        if !header.ends_with(b"`\n") {
            return None;
        }
        let member = std::str::from_utf8(header.get(..16)?).ok()?.trim_end();
        let member = member.strip_suffix('/').unwrap_or(member);
        let size: usize = std::str::from_utf8(header.get(48..58)?)
            .ok()?
            .trim()
            .parse()
            .ok()?;
        let start = at + 60;
        let end = start.checked_add(size)?;
        if member == name {
            return deb.get(start..end);
        }
        at = end + size % 2;
    }
    None
}

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::{Package, dpkg_owner, file_name, package_name, version, write};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_contains, assert_eq, assert_ok, ensure};
    use std::io::Read as _;
    use std::os::unix::fs::PermissionsExt as _;

    fn bundle(scratch: &Scratch) -> Result<(), Failure> {
        scratch.write("b/bin/notes_app", "#!/bin/sh\n")?;
        std::fs::set_permissions(
            scratch.path().join("b/bin/notes_app"),
            std::fs::Permissions::from_mode(0o755),
        )
        .map_err(|error| fail("chmod", error))?;
        scratch.write("b/share/notes_app/dist/index.html", "<!doctype html>\n")?;
        scratch.write("b/.lepton-package", "marker\n")
    }

    fn package<'a>(
        bundle: &'a std::path::Path,
        out: &'a std::path::Path,
        depends: &'a [String],
    ) -> Package<'a> {
        Package {
            bundle,
            skip: &[".lepton-package"],
            name: "notes_app",
            version: "1.2.0-beta.1+build.7",
            description: "Notes\n app",
            maintainer: "Ada <ada@example.org>",
            depends,
            mtime: 0,
            out,
        }
    }

    /// The `ar` members as (name, bytes), parsed independently of the writer.
    fn members(deb: &[u8]) -> Result<Vec<(String, Vec<u8>)>, Failure> {
        ensure!(deb.starts_with(b"!<arch>\n"), "ar magic");
        let mut at = 8;
        let mut out = Vec::new();
        while at < deb.len() {
            let header = deb.get(at..at + 60).ok_or_else(|| fail("header", at))?;
            ensure!(header.ends_with(b"`\n"), "header magic at {at}");
            let name = String::from_utf8_lossy(&header[..16]).trim_end().to_owned();
            let size: usize = String::from_utf8_lossy(&header[48..58])
                .trim()
                .parse()
                .map_err(|error| fail("size", error))?;
            let body = deb
                .get(at + 60..at + 60 + size)
                .ok_or_else(|| fail("body", &name))?;
            out.push((name, body.to_vec()));
            at += 60 + size + size % 2;
        }
        Ok(out)
    }

    fn tar_names(gz: &[u8]) -> Result<Vec<(String, Vec<u8>)>, Failure> {
        let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(gz));
        let mut out = Vec::new();
        for entry in archive.entries().map_err(|error| fail("entries", error))? {
            let mut entry = entry.map_err(|error| fail("entry", error))?;
            let name = entry
                .path()
                .map_err(|error| fail("path", error))?
                .to_string_lossy()
                .into_owned();
            let mut bytes = Vec::new();
            entry
                .read_to_end(&mut bytes)
                .map_err(|error| fail("read", error))?;
            out.push((name, bytes));
        }
        Ok(out)
    }

    #[test]
    fn names_and_versions_follow_debian_rules() -> Result<(), Failure> {
        assert_eq!(package_name("notes_app"), "notes-app");
        assert_eq!(version("1.2.0-beta.1+build.7"), "1.2.0~beta.1");
        assert_eq!(version("1.2.0"), "1.2.0");
        assert_contains!(
            &assert_ok!(file_name("notes_app", "1.2.0"), "name"),
            "notes-app_1.2.0_"
        );
        Ok(())
    }

    #[test]
    fn the_ar_holds_three_members_in_dpkg_order() -> Result<(), Failure> {
        let scratch = Scratch::new("deb-members")?;
        bundle(&scratch)?;
        let depends = [String::from("libc6"), String::from("libwayland-client0")];
        let bundle_dir = scratch.path().join("b");
        let (path, _) = assert_ok!(
            write(&package(&bundle_dir, scratch.path(), &depends)),
            "writes"
        );
        let deb = std::fs::read(&path).map_err(|error| fail("read", error))?;
        let members = members(&deb)?;
        let names: Vec<&str> = members.iter().map(|member| member.0.as_str()).collect();
        assert_eq!(
            names,
            vec!["debian-binary", "control.tar.gz", "data.tar.gz"]
        );
        assert_eq!(members[0].1, b"2.0\n".to_vec());

        let control = tar_names(&members[1].1)?;
        assert_eq!(control.len(), 1);
        let text = String::from_utf8_lossy(&control[0].1).into_owned();
        assert_contains!(&text, "Package: notes-app\n");
        assert_contains!(&text, "Version: 1.2.0~beta.1\n");
        assert_contains!(&text, "Maintainer: Ada <ada@example.org>\n");
        assert_contains!(&text, "Depends: libc6, libwayland-client0\n");
        // 10 B + 16 B rounds up to one KiB.
        assert_contains!(&text, "Installed-Size: 1\n");
        assert_contains!(&text, "Description: Notes app\n");

        let data: Vec<String> = tar_names(&members[2].1)?
            .into_iter()
            .map(|entry| entry.0)
            .collect();
        assert_eq!(
            data,
            vec![
                "usr/",
                "usr/bin/",
                "usr/bin/notes_app",
                "usr/share/",
                "usr/share/notes_app/",
                "usr/share/notes_app/dist/",
                "usr/share/notes_app/dist/index.html",
            ]
        );
        Ok(())
    }

    #[test]
    fn two_writes_are_byte_identical() -> Result<(), Failure> {
        let scratch = Scratch::new("deb-repro")?;
        bundle(&scratch)?;
        let bundle_dir = scratch.path().join("b");
        let (_, first) = assert_ok!(write(&package(&bundle_dir, scratch.path(), &[])), "first");
        let (_, second) = assert_ok!(write(&package(&bundle_dir, scratch.path(), &[])), "second");
        assert_eq!(first, second);
        Ok(())
    }

    /// Runs only where dpkg exists (Debian, Ubuntu, CI); there libc must be `libc6`.
    #[test]
    fn dpkg_names_the_owner_of_libc_where_it_exists() -> Result<(), Failure> {
        let Some(libc) = super::super::depends::locate("libc.so.6") else {
            return Err(fail("libc.so.6", "not found"));
        };
        if std::process::Command::new("dpkg-query")
            .arg("--version")
            .output()
            .is_err()
        {
            ensure!(dpkg_owner(&libc).is_none(), "no dpkg, no owner");
            return Ok(());
        }
        assert_eq!(dpkg_owner(&libc), Some(String::from("libc6")));
        Ok(())
    }
}
