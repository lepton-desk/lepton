//! A release's runtime dependencies, read from the binary itself.
//!
//! The executable's ELF `.dynamic` section lists every shared library the loader must find
//! (`DT_NEEDED`). Those names are the dependency list: nothing is guessed from the render
//! path or a hand-kept table, so a dependency added to the core's build shows up in the
//! next package without anyone remembering to list it. Each library is then found on this
//! machine and its owning package asked of the package manager (`pacman -Qqo`); the
//! package manager resolves the transitive ones itself.
//!
//! Only 64-bit little-endian ELF is read — every target Lepton builds for on Linux today.
//! Anything else is an error rather than an empty list: a release with no dependencies is
//! a claim, and it has to be true.

use std::path::{Path, PathBuf};

use super::CliError;

const SHT_DYNAMIC: u32 = 6;
const DT_NULL: u64 = 0;
const DT_NEEDED: u64 = 1;

/// The `DT_NEEDED` names of an ELF executable, in file order, without repeats.
pub fn needed(path: &Path) -> Result<Vec<String>, CliError> {
    let bytes = std::fs::read(path).map_err(|error| {
        CliError::Invalid(format!("could not read {}: {error}", path.display()))
    })?;
    needed_in(&bytes).map_err(|reason| {
        CliError::Invalid(format!(
            "{} is not a readable ELF file: {reason}",
            path.display()
        ))
    })
}

/// [`needed`] over the file's bytes. Every read is bounds-checked; a truncated or hostile
/// file is an error, never a panic.
pub fn needed_in(bytes: &[u8]) -> Result<Vec<String>, &'static str> {
    if bytes.get(..4) != Some(b"\x7fELF".as_slice()) {
        return Err("no ELF magic");
    }
    if bytes.get(4) != Some(&2) {
        return Err("not a 64-bit ELF file");
    }
    if bytes.get(5) != Some(&1) {
        return Err("not little-endian");
    }

    let section_offset = u64_at(bytes, 0x28)?;
    let section_size = u64::from(u16_at(bytes, 0x3A)?);
    let section_count = u64::from(u16_at(bytes, 0x3C)?);
    if section_size < 64 {
        return Err("section headers are too small");
    }

    let header = |index: u64| -> Result<usize, &'static str> {
        index
            .checked_mul(section_size)
            .and_then(|offset| offset.checked_add(section_offset))
            .and_then(|offset| usize::try_from(offset).ok())
            .ok_or("section header offset overflows")
    };

    let mut names = Vec::new();
    let mut found = false;
    for index in 0..section_count {
        let at = header(index)?;
        if u32_at(bytes, at + 4)? != SHT_DYNAMIC {
            continue;
        }
        found = true;
        let dynamic = slice(bytes, u64_at(bytes, at + 24)?, u64_at(bytes, at + 32)?)?;
        // `sh_link` of `.dynamic` names its string table (`.dynstr`).
        let strings_at = header(u64::from(u32_at(bytes, at + 40)?))?;
        let strings = slice(
            bytes,
            u64_at(bytes, strings_at + 24)?,
            u64_at(bytes, strings_at + 32)?,
        )?;

        for entry in dynamic.chunks_exact(16) {
            let tag = u64_at(entry, 0)?;
            if tag == DT_NULL {
                break;
            }
            if tag != DT_NEEDED {
                continue;
            }
            let start =
                usize::try_from(u64_at(entry, 8)?).map_err(|_| "string offset overflows")?;
            let tail = strings.get(start..).ok_or("string offset out of range")?;
            let end = tail
                .iter()
                .position(|&byte| byte == 0)
                .ok_or("unterminated string")?;
            let name = std::str::from_utf8(tail.get(..end).ok_or("string out of range")?)
                .map_err(|_| "library name is not UTF-8")?;
            if !names.iter().any(|known: &String| known == name) {
                names.push(name.to_owned());
            }
        }
    }
    if !found {
        // A static executable has no `.dynamic` section; Lepton's core always links the
        // system's graphics and web libraries, so this is a build that is not one.
        return Err("no dynamic section (a static or stripped-of-sections binary)");
    }
    Ok(names)
}

/// Where the loader would find `soname` among the system library directories.
pub fn locate(soname: &str) -> Option<PathBuf> {
    const DIRS: [&str; 6] = [
        "/usr/lib",
        "/usr/lib64",
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/lib",
        "/lib64",
    ];
    DIRS.iter()
        .map(|dir| Path::new(dir).join(soname))
        .find(|candidate| candidate.exists())
}

/// One library and, when the package manager knows it, the package that owns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dependency {
    pub soname: String,
    pub package: Option<String>,
}

/// The package that owns `library`, per `pacman -Qqo`; `None` when pacman is absent or
/// no package owns the file.
pub fn pacman_owner(library: &Path) -> Option<String> {
    let output = std::process::Command::new("pacman")
        .arg("-Qqo")
        .arg(library)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let name = String::from_utf8(output.stdout).ok()?;
    let name = name.lines().next()?.trim();
    (!name.is_empty()).then(|| name.to_owned())
}

/// Every `DT_NEEDED` library of `binary`, each with its owning Arch package.
pub fn resolve(binary: &Path) -> Result<Vec<Dependency>, CliError> {
    Ok(needed(binary)?
        .into_iter()
        .map(|soname| {
            let package = locate(&soname).and_then(|path| pacman_owner(&path));
            Dependency { soname, package }
        })
        .collect())
}

/// The distinct package names, sorted; libraries no package owns are left out here and
/// reported by [`unowned`].
pub fn packages(dependencies: &[Dependency]) -> Vec<String> {
    let mut names: Vec<String> = dependencies
        .iter()
        .filter_map(|dependency| dependency.package.clone())
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Libraries the package manager could not attribute to a package.
pub fn unowned(dependencies: &[Dependency]) -> Vec<&str> {
    dependencies
        .iter()
        .filter(|dependency| dependency.package.is_none())
        .map(|dependency| dependency.soname.as_str())
        .collect()
}

fn slice(bytes: &[u8], offset: u64, size: u64) -> Result<&[u8], &'static str> {
    let start = usize::try_from(offset).map_err(|_| "offset overflows")?;
    let end = offset
        .checked_add(size)
        .and_then(|end| usize::try_from(end).ok())
        .ok_or("size overflows")?;
    bytes.get(start..end).ok_or("section out of range")
}

fn u16_at(bytes: &[u8], at: usize) -> Result<u16, &'static str> {
    let raw: [u8; 2] = bytes
        .get(at..at + 2)
        .and_then(|raw| raw.try_into().ok())
        .ok_or("truncated")?;
    Ok(u16::from_le_bytes(raw))
}

fn u32_at(bytes: &[u8], at: usize) -> Result<u32, &'static str> {
    let raw: [u8; 4] = bytes
        .get(at..at + 4)
        .and_then(|raw| raw.try_into().ok())
        .ok_or("truncated")?;
    Ok(u32::from_le_bytes(raw))
}

fn u64_at(bytes: &[u8], at: usize) -> Result<u64, &'static str> {
    let raw: [u8; 8] = bytes
        .get(at..at + 8)
        .and_then(|raw| raw.try_into().ok())
        .ok_or("truncated")?;
    Ok(u64::from_le_bytes(raw))
}

// The tests read this test binary's own ELF and the system's libc: Linux only.
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::{Dependency, locate, needed, needed_in, packages, pacman_owner, unowned};
    use lepton_orchestrator::testing::{Failure, fail};
    use lepton_orchestrator::{assert_eq, assert_err, assert_ok, ensure};

    /// The running test binary is a real dynamically linked ELF built by this toolchain.
    fn this_binary() -> Result<std::path::PathBuf, Failure> {
        std::env::current_exe().map_err(|error| fail("current_exe", error))
    }

    #[test]
    fn the_test_binary_needs_libc() -> Result<(), Failure> {
        let names = assert_ok!(needed(&this_binary()?), "reads its own ELF");
        ensure!(
            names.iter().any(|name| name == "libc.so.6"),
            "names {names:?}"
        );
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        ensure!(sorted.len() == names.len(), "repeats in {names:?}");
        Ok(())
    }

    #[test]
    fn non_elf_and_truncated_input_are_errors_not_panics() -> Result<(), Failure> {
        assert_err!(needed_in(b"#!/bin/sh\n"), "script");
        let bytes = std::fs::read(this_binary()?).map_err(|error| fail("read", error))?;
        for cut in [5, 0x30, 0x40, 4096] {
            if let Some(head) = bytes.get(..cut) {
                assert_err!(needed_in(head), "truncated at {cut}");
            }
        }
        let mut wrong_class = bytes.get(..64).map(<[u8]>::to_vec).unwrap_or_default();
        if let Some(class) = wrong_class.get_mut(4) {
            *class = 1;
        }
        assert_err!(needed_in(&wrong_class), "32-bit");
        Ok(())
    }

    #[test]
    fn libc_is_found_and_owned_by_a_package_on_this_machine() -> Result<(), Failure> {
        let Some(path) = locate("libc.so.6") else {
            return Err(fail("libc.so.6 in a system library directory", "not found"));
        };
        // Only where pacman exists: on Arch it must name glibc.
        if std::path::Path::new("/usr/bin/pacman").exists() {
            assert_eq!(pacman_owner(&path), Some(String::from("glibc")));
        }
        ensure!(
            locate("libdoes-not-exist.so.9").is_none(),
            "phantom library"
        );
        Ok(())
    }

    #[test]
    fn packages_are_sorted_distinct_and_unowned_ones_are_named() -> Result<(), Failure> {
        let deps = [
            Dependency {
                soname: "libm.so.6".into(),
                package: Some("glibc".into()),
            },
            Dependency {
                soname: "libz.so.1".into(),
                package: Some("zlib".into()),
            },
            Dependency {
                soname: "libc.so.6".into(),
                package: Some("glibc".into()),
            },
            Dependency {
                soname: "libown.so".into(),
                package: None,
            },
        ];
        assert_eq!(
            packages(&deps),
            vec![String::from("glibc"), String::from("zlib")]
        );
        assert_eq!(unowned(&deps), vec!["libown.so"]);
        Ok(())
    }
}
