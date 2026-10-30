//! `.zip` release archives, written and read in Rust with `flate2`'s raw deflate.
//!
//! The Windows counterpart of the `.tar.gz` (`archive.rs`) and held to the same rules:
//! entries sorted by path under one top directory, one time stamp for all of them
//! (`SOURCE_DATE_EPOCH`, else 0 — which a DOS date cannot hold, so it becomes the format's
//! own epoch, 1980-01-01), modes reduced to 0755/0644, names in UTF-8 (flag bit 11), no
//! extra fields. The same bundle therefore zips to the same bytes every time. Archives
//! past 4 GiB would need ZIP64 and are refused.
//!
//! The reader is for `lepton package --verify`, which unpacks what this module wrote: it
//! refuses a member that would land outside the target (absolute, `..`, a drive, a
//! backslash) and checks every member's CRC-32.

use std::io::Write as _;
use std::path::{Component, Path};

use super::CliError;
use super::archive::{Entry, io, publish, refuse_foreign, sorted_entries};

const LOCAL: u32 = 0x0403_4b50;
const CENTRAL: u32 = 0x0201_4b50;
const END: u32 = 0x0605_4b50;
/// 2.0: deflate and directories.
const VERSION: u16 = 20;
/// Made on Unix (3), so readers take the mode from the upper external attributes.
const MADE_BY: u16 = (3 << 8) | VERSION;
/// General purpose flag bit 11: the name is UTF-8.
const UTF8: u16 = 1 << 11;
const STORED: u16 = 0;
const DEFLATED: u16 = 8;

/// Writes `<dir>` as `<out>` (`.zip`), every entry under `<top>/`, skipping names in
/// `skip`. Returns the archive's SHA-256 in hex.
pub fn write(
    dir: &Path,
    top: &str,
    skip: &[&str],
    out: &Path,
    mtime: u64,
) -> Result<String, CliError> {
    refuse_foreign(out)?;
    let archive = bytes(dir, top, skip, out, mtime)?;
    let partial = out.with_extension("part");
    std::fs::write(&partial, &archive).map_err(|error| io(&partial, "write", &error))?;
    publish(&partial, out)
}

/// The archive [`write`] writes, as bytes; `out` names it in errors. setup.exe carries one
/// after its program (`setup.rs`).
pub fn bytes(
    dir: &Path,
    top: &str,
    skip: &[&str],
    out: &Path,
    mtime: u64,
) -> Result<Vec<u8>, CliError> {
    let entries = sorted_entries(dir, Path::new(top), skip)?;
    let (time, date) = dos_stamp(mtime);

    let mut archive = Vec::new();
    let mut central = Vec::new();
    let mut count: u16 = 0;
    let top_entry = Entry {
        path: Path::new(top).to_path_buf(),
        source: dir.to_path_buf(),
        directory: true,
        executable: false,
    };
    for entry in std::iter::once(&top_entry).chain(entries.iter()) {
        let name = member_name(&entry.path, entry.directory, out)?;
        let (method, crc, data, size) = if entry.directory {
            (STORED, 0, Vec::new(), 0)
        } else {
            let bytes =
                std::fs::read(&entry.source).map_err(|error| io(&entry.source, "read", &error))?;
            let mut crc = flate2::Crc::new();
            crc.update(&bytes);
            let mut encoder =
                flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
            encoder
                .write_all(&bytes)
                .map_err(|error| io(out, "compress", &error))?;
            let packed = encoder
                .finish()
                .map_err(|error| io(out, "compress", &error))?;
            (DEFLATED, crc.sum(), packed, bytes.len())
        };
        let offset = fits(archive.len(), out)?;
        let packed = fits(data.len(), out)?;
        let unpacked = fits(size, out)?;
        let name_len = u16::try_from(name.len()).map_err(|_| too_big(out))?;
        let mode: u32 = if entry.directory || entry.executable {
            0o755
        } else {
            0o644
        };
        let kind: u32 = if entry.directory {
            0o040_000
        } else {
            0o100_000
        };
        let attributes = ((kind | mode) << 16) | (u32::from(entry.directory) * 0x10);

        put32(&mut archive, LOCAL);
        put16(&mut archive, VERSION);
        put16(&mut archive, UTF8);
        put16(&mut archive, method);
        put16(&mut archive, time);
        put16(&mut archive, date);
        put32(&mut archive, crc);
        put32(&mut archive, packed);
        put32(&mut archive, unpacked);
        put16(&mut archive, name_len);
        put16(&mut archive, 0);
        archive.extend_from_slice(name.as_bytes());
        archive.extend_from_slice(&data);

        put32(&mut central, CENTRAL);
        put16(&mut central, MADE_BY);
        put16(&mut central, VERSION);
        put16(&mut central, UTF8);
        put16(&mut central, method);
        put16(&mut central, time);
        put16(&mut central, date);
        put32(&mut central, crc);
        put32(&mut central, packed);
        put32(&mut central, unpacked);
        put16(&mut central, name_len);
        put16(&mut central, 0); // extra
        put16(&mut central, 0); // comment
        put16(&mut central, 0); // disk
        put16(&mut central, 0); // internal attributes
        put32(&mut central, attributes);
        put32(&mut central, offset);
        central.extend_from_slice(name.as_bytes());
        count = count.checked_add(1).ok_or_else(|| too_big(out))?;
    }
    let central_at = fits(archive.len(), out)?;
    let central_len = fits(central.len(), out)?;
    archive.extend_from_slice(&central);
    put32(&mut archive, END);
    put16(&mut archive, 0);
    put16(&mut archive, 0);
    put16(&mut archive, count);
    put16(&mut archive, count);
    put32(&mut archive, central_len);
    put32(&mut archive, central_at);
    put16(&mut archive, 0);
    Ok(archive)
}

/// Unpacks a `.zip` this module wrote into `into`, or the one at the end of a setup.exe.
pub fn unpack(artifact: &Path, into: &Path) -> Result<(), CliError> {
    let bytes = std::fs::read(artifact).map_err(|error| io(artifact, "read", &error))?;
    let bad = |what: &str| {
        CliError::Invalid(format!(
            "{} is not a usable .zip: {what}",
            artifact.display()
        ))
    };
    let end = (0..bytes.len().saturating_sub(21))
        .rev()
        .find(|&at| read32(&bytes, at) == Some(END))
        .ok_or_else(|| bad("no end of central directory"))?;
    let count = read16(&bytes, end + 10).ok_or_else(|| bad("short end record"))?;
    let central_len = read32(&bytes, end + 12).ok_or_else(|| bad("short end record"))? as usize;
    let central_at = read32(&bytes, end + 16).ok_or_else(|| bad("short end record"))? as usize;
    // Where the zip starts in the file: 0 for a `.zip`, the program's length for setup.exe,
    // whose offsets count from the zip's own start.
    let base = end
        .checked_sub(central_len)
        .and_then(|at| at.checked_sub(central_at))
        .ok_or_else(|| bad("the central directory is out of place"))?;
    let mut at = base + central_at;
    for _ in 0..count {
        if read32(&bytes, at) != Some(CENTRAL) {
            return Err(bad("a central directory entry is damaged"));
        }
        let field =
            |offset: usize| read16(&bytes, at + offset).ok_or_else(|| bad("short central entry"));
        let method = field(10)?;
        let crc = read32(&bytes, at + 16).ok_or_else(|| bad("short central entry"))?;
        let packed = read32(&bytes, at + 20).ok_or_else(|| bad("short central entry"))? as usize;
        let size = read32(&bytes, at + 24).ok_or_else(|| bad("short central entry"))? as usize;
        let name_len = usize::from(field(28)?);
        let extra_len = usize::from(field(30)?);
        let comment_len = usize::from(field(32)?);
        let local =
            base + read32(&bytes, at + 42).ok_or_else(|| bad("short central entry"))? as usize;
        let name = bytes
            .get(at + 46..at + 46 + name_len)
            .and_then(|raw| std::str::from_utf8(raw).ok())
            .ok_or_else(|| bad("a name is not UTF-8"))?;
        at += 46 + name_len + extra_len + comment_len;

        let target = confined(into, name)
            .ok_or_else(|| bad(&format!("{name:?} would land outside the directory")))?;
        if name.ends_with('/') {
            std::fs::create_dir_all(&target).map_err(|error| io(&target, "create", &error))?;
            continue;
        }
        if read32(&bytes, local) != Some(LOCAL) {
            return Err(bad("a local header is damaged"));
        }
        let local_name =
            usize::from(read16(&bytes, local + 26).ok_or_else(|| bad("short local header"))?);
        let local_extra =
            usize::from(read16(&bytes, local + 28).ok_or_else(|| bad("short local header"))?);
        let start = local + 30 + local_name + local_extra;
        let data = bytes
            .get(start..start + packed)
            .ok_or_else(|| bad("a member runs past the end"))?;
        let content = match method {
            STORED => data.to_vec(),
            DEFLATED => {
                let mut decoder = flate2::write::DeflateDecoder::new(Vec::with_capacity(size));
                decoder
                    .write_all(data)
                    .map_err(|error| io(artifact, "inflate", &error))?;
                decoder
                    .finish()
                    .map_err(|error| io(artifact, "inflate", &error))?
            }
            _ => return Err(bad("a member uses a compression this reader does not know")),
        };
        let mut check = flate2::Crc::new();
        check.update(&content);
        if content.len() != size || check.sum() != crc {
            return Err(bad(&format!("{name} does not match its size or CRC-32")));
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| io(parent, "create", &error))?;
        }
        std::fs::write(&target, &content).map_err(|error| io(&target, "write", &error))?;
    }
    Ok(())
}

/// `into/name`, or `None` for a name that is absolute, has a drive, a `..` or a backslash.
fn confined(into: &Path, name: &str) -> Option<std::path::PathBuf> {
    if name.contains('\\') || name.contains(':') {
        return None;
    }
    let relative = Path::new(name.trim_end_matches('/'));
    if relative
        .components()
        .all(|part| matches!(part, Component::Normal(_)))
    {
        Some(into.join(relative))
    } else {
        None
    }
}

/// The member name: `/`-separated, a directory's ending in `/`.
fn member_name(path: &Path, directory: bool, out: &Path) -> Result<String, CliError> {
    let mut parts = Vec::new();
    for part in path.components() {
        match part {
            Component::Normal(text) => parts.push(text.to_str().ok_or_else(|| {
                CliError::Invalid(format!("{} has a name that is not UTF-8", out.display()))
            })?),
            _ => {
                return Err(CliError::Invalid(format!(
                    "{} is not a relative member path",
                    path.display()
                )));
            }
        }
    }
    let mut name = parts.join("/");
    if directory {
        name.push('/');
    }
    Ok(name)
}

/// A Unix time as a DOS (time, date) pair, in UTC. Before 1980 the format has no date, so
/// the earliest one it has is used.
pub fn dos_stamp(unix: u64) -> (u16, u16) {
    const DOS_EPOCH: u64 = 315_532_800; // 1980-01-01T00:00:00Z
    if unix < DOS_EPOCH {
        return (0, (1 << 5) | 1);
    }
    let days = unix / 86_400;
    let seconds = unix % 86_400;
    let (year, month, day) = civil(days);
    let year = year.clamp(1980, 2107);
    let date = ((year - 1980) << 9) | (month << 5) | day;
    let time = ((seconds / 3600) << 11) | (((seconds % 3600) / 60) << 5) | ((seconds % 60) / 2);
    (time as u16, date as u16)
}

/// Days since 1970-01-01 → (year, month, day), proleptic Gregorian (Howard Hinnant's
/// `civil_from_days`).
fn civil(days: u64) -> (u64, u64, u64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);
    (year, month, day)
}

fn fits(value: usize, out: &Path) -> Result<u32, CliError> {
    u32::try_from(value).map_err(|_| too_big(out))
}

fn too_big(out: &Path) -> CliError {
    CliError::Invalid(format!(
        "{} would need ZIP64 (over 4 GiB or 65535 entries)",
        out.display()
    ))
}

fn put16(into: &mut Vec<u8>, value: u16) {
    into.extend_from_slice(&value.to_le_bytes());
}

fn put32(into: &mut Vec<u8>, value: u32) {
    into.extend_from_slice(&value.to_le_bytes());
}

fn read16(bytes: &[u8], at: usize) -> Option<u16> {
    let raw: [u8; 2] = bytes.get(at..at + 2)?.try_into().ok()?;
    Some(u16::from_le_bytes(raw))
}

fn read32(bytes: &[u8], at: usize) -> Option<u32> {
    let raw: [u8; 4] = bytes.get(at..at + 4)?.try_into().ok()?;
    Some(u32::from_le_bytes(raw))
}

#[cfg(test)]
mod tests {
    use super::{confined, dos_stamp, unpack, write};
    use lepton_orchestrator::testing::{Failure, Scratch, fail};
    use lepton_orchestrator::{assert_eq, assert_ok, ensure};
    use std::path::Path;

    #[test]
    fn dos_dates_count_from_1980() -> Result<(), Failure> {
        // Before the format's epoch: its first day.
        assert_eq!(dos_stamp(0), (0, 0x21));
        // 2026-10-19T12:34:56Z.
        let (time, date) = dos_stamp(1_792_413_296);
        assert_eq!(date >> 9, 46);
        assert_eq!((date >> 5) & 0xf, 10);
        assert_eq!(date & 0x1f, 19);
        assert_eq!(time >> 11, 12);
        assert_eq!((time >> 5) & 0x3f, 34);
        assert_eq!((time & 0x1f) * 2, 56);
        Ok(())
    }

    #[test]
    fn a_bundle_round_trips_and_zips_to_the_same_bytes() -> Result<(), Failure> {
        let scratch = Scratch::new("zip-round")?;
        scratch.write("tree/bin/app.exe", "MZ binary")?;
        scratch.write(
            "tree/share/app/dist/index.html",
            &"<p>lepton</p>\n".repeat(200),
        )?;
        scratch.write("tree/.lepton-package", "skip me")?;
        let tree = scratch.path().join("tree");
        let first = scratch.path().join("one.zip");
        let second = scratch.path().join("two.zip");
        let digest = assert_ok!(
            write(&tree, "app-1.0", &[".lepton-package"], &first, 0),
            "zip"
        );
        let again = assert_ok!(
            write(&tree, "app-1.0", &[".lepton-package"], &second, 0),
            "zip again"
        );
        assert_eq!(digest, again);

        let out = scratch.path().join("out");
        assert_ok!(unpack(&first, &out), "unzip");
        let html = std::fs::read_to_string(out.join("app-1.0/share/app/dist/index.html"))
            .map_err(|error| fail("the unpacked page", error))?;
        ensure!(
            html.starts_with("<p>lepton</p>"),
            "the page came back whole"
        );
        ensure!(
            out.join("app-1.0/bin/app.exe").is_file(),
            "the program came back"
        );
        ensure!(
            !out.join("app-1.0/.lepton-package").exists(),
            "skipped names stay out"
        );
        Ok(())
    }

    #[test]
    fn a_member_cannot_land_outside_the_directory() -> Result<(), Failure> {
        let into = Path::new("unpacked");
        ensure!(
            confined(into, "app/bin/app.exe").is_some(),
            "a plain path is kept"
        );
        for name in [
            "../evil",
            "/etc/passwd",
            "C:/Windows/x",
            "app\\..\\evil",
            "app/../../evil",
        ] {
            ensure!(confined(into, name).is_none(), "{name} must be refused");
        }
        Ok(())
    }
}
