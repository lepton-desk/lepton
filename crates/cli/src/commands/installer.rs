//! Windows Installer packages (`.msi`), written in Rust — no WiX.
//!
//! WiX v3–v5 are out of community support and v6+ carry the Open Source Maintenance Fee
//! with an EULA to accept before every build (FireGiant, 2026). A framework that called
//! WiX would hand that obligation to every company packaging a Lepton application, so the
//! database is written here (`installer_db.rs`, on the `cfb` crate) and the files go into
//! one MSZIP cabinet written with `cab` (MIT), embedded as a stream — the same "every byte
//! chosen in one place" rule as the `.deb`, Arch and `.zip` writers. The `msi` crate only
//! reads (`installer_read.rs`): its writer sorts rows by text and Windows refuses the
//! result (measured, see `installer_db.rs`).
//!
//! ## What the package does
//!
//! A per-user install, no elevation (Word Count bit 3): the bundle tree goes to
//! `%LOCALAPPDATA%\Programs\<product>`, one component per file with the file as its key
//! path, one feature. Uninstall from Settings → Apps or `msiexec /x` removes it. Measured on
//! Windows 10 22H2: install 1.2 s, exit 0; the installed program opened its page; removal
//! 1.1 s, exit 0, nothing left.
//!
//! ## Reproducible identities
//!
//! No GUID is stored anywhere. The UpgradeCode is derived from the application's
//! identifier, so every version of one application shares it; the ProductCode from the
//! identifier and version; each ComponentId from the identifier and the file's path; the
//! PackageCode (summary revision) from the package's contents. All are name-based UUIDs
//! over SHA-256 — the same inputs give the same `.msi`.

use std::io::Write as _;
use std::path::Path;

use sha2::Digest as _;

use super::CliError;
use super::archive::{io, publish, refuse_foreign, sorted_entries};
use super::installer_db::{Database, Property, summary};
use super::installer_names::ShortNames;
use super::installer_tables::{rows, tables};

pub use super::installer_read::extract;

/// The cabinet's stream name, and `Media.Cabinet` (`#` = embedded).
pub(super) const CABINET: &str = "lepton.cab";
/// Component attribute: a 64-bit component (`msidbComponentAttributes64bit`).
pub(super) const COMPONENT_64BIT: i32 = 256;
/// Word Count: compressed source (2) + no elevation needed (8).
const WORD_COUNT: i32 = 2 | 8;
/// Windows Installer 5.0 (Windows 7+); an x64 package needs at least 200.
const SCHEMA: i32 = 500;
/// English (United States), the package's and the product's language.
pub(super) const LANGUAGE: u16 = 1033;

/// What one installer is made of.
pub struct Installer<'a> {
    /// The bundle tree (`bin/`, `share/`).
    pub bundle: &'a Path,
    pub skip: &'a [&'a str],
    /// The application's identifier (`lepton.config.json` `identifier`).
    pub identifier: &'a str,
    pub product: &'a str,
    pub version: &'a str,
    /// The publisher shown in Settings → Apps.
    pub manufacturer: &'a str,
    /// The program's file name under `bin/` (`notes.exe`), for the Start menu shortcut.
    pub program: &'a str,
    /// `bundle.icon`, for the shortcut and Settings → Apps; the program's own icon without.
    pub icon: Option<&'a Path>,
    /// `deepLinks`: URL schemes registered for the user, opening the program with the link.
    pub schemes: &'a [String],
    pub mtime: u64,
    pub out: &'a Path,
}

/// What the installer adds beside the files.
pub(super) struct Extras {
    /// The program's File key, the shortcut's target.
    pub program: String,
    /// The shortcut's `short|long` name in the Start menu.
    pub shortcut: String,
    /// The `.ico` bytes: `bundle.icon`, else Lepton's mark.
    pub icon: Option<Vec<u8>>,
    /// `deepLinks`.
    pub schemes: Vec<String>,
}

/// One directory of the install, as the Directory table holds it.
pub(super) struct Directory {
    pub key: String,
    pub parent: String,
    pub name: String,
}

/// One file of the install.
pub(super) struct File {
    pub key: String,
    pub component: String,
    pub directory: String,
    pub name: String,
    pub relative: String,
    pub bytes: Vec<u8>,
}

/// Writes `<out>` and its `.sha256`; returns the digest.
pub fn write(spec: &Installer<'_>) -> Result<String, CliError> {
    refuse_foreign(spec.out)?;
    let version = product_version(spec.version)?;
    let (directories, files) = layout(spec)?;
    let cabinet = cabinet(&files, spec.mtime, spec.out)?;

    let upgrade = name_uuid("upgrade", &[spec.identifier]);
    let product = name_uuid("product", &[spec.identifier, &version]);
    let mut digest = sha2::Sha256::new();
    digest.update(&cabinet);
    digest.update(spec.product.as_bytes());
    digest.update(version.as_bytes());
    let package_code = uuid_from(&digest.finalize());

    // The program the Start menu shortcut starts: `bin/<name>.exe` in the bundle.
    let target = format!("bin/{}", spec.program);
    let program = files
        .iter()
        .find(|file| file.relative == target)
        .map(|file| file.key.clone())
        .ok_or_else(|| {
            CliError::Invalid(format!(
                "the bundle has no {target} for the Start menu shortcut"
            ))
        })?;
    let shortcut = ShortNames::default().named("ProgramMenuFolder", spec.product);
    let icon = match spec.icon {
        Some(path) => {
            let bytes = std::fs::read(path).map_err(|error| io(path, "read the icon", &error))?;
            // An .ico starts with reserved 0 and type 1 (`ICONDIR`).
            if bytes.get(..4) != Some(&[0, 0, 1, 0][..]) {
                return Err(CliError::Invalid(format!(
                    "{} is not an .ico file",
                    path.display()
                )));
            }
            Some(bytes)
        }
        // Lepton's own mark rather than Windows' blank one.
        None => Some(super::desktop_entry::DEFAULT_ICO.to_vec()),
    };
    let extras = Extras {
        program,
        shortcut,
        icon,
        schemes: spec.schemes.to_vec(),
    };

    let mut texts: Vec<&str> = vec![spec.product, spec.manufacturer, &extras.shortcut];
    texts.extend(directories.iter().map(|dir| dir.name.as_str()));
    texts.extend(files.iter().map(|file| file.name.as_str()));
    let codepage = codepage_for(&texts).ok_or_else(|| {
        CliError::Invalid(format!(
            "no Windows code page holds every name in {} (the product, publisher and file names); Windows Installer has no UTF-8",
            spec.out.display()
        ))
    })?;

    let failed = |error: std::io::Error| io(spec.out, "write", &error);
    let mut db = Database::new(codepage);
    db.summary(
        summary::TITLE,
        Property::Text(String::from("Installation Database")),
    );
    db.summary(summary::SUBJECT, Property::Text(spec.product.to_owned()));
    db.summary(
        summary::AUTHOR,
        Property::Text(spec.manufacturer.to_owned()),
    );
    db.summary(summary::KEYWORDS, Property::Text(String::from("Installer")));
    db.summary(
        summary::COMMENTS,
        Property::Text(format!("{} {version}, packaged by Lepton", spec.product)),
    );
    db.summary(summary::TEMPLATE, Property::Text(format!("x64;{LANGUAGE}")));
    db.summary(
        summary::REVISION,
        Property::Text(format!(
            "{{{}}}",
            package_code.hyphenated().to_string().to_ascii_uppercase()
        )),
    );
    db.summary(summary::PAGE_COUNT, Property::I4(SCHEMA));
    db.summary(summary::WORD_COUNT, Property::I4(WORD_COUNT));
    db.summary(
        summary::CREATING_APP,
        Property::Text(String::from("Lepton (lepton package)")),
    );
    // 2: read-only recommended, as a finished package is.
    db.summary(summary::SECURITY, Property::I4(2));
    tables(&mut db, extras.icon.is_some());
    rows(
        &mut db,
        spec,
        &version,
        (&upgrade, &product),
        (&directories, &files),
        extras,
    )
    .map_err(failed)?;
    db.stream(CABINET, cabinet);
    let bytes = db.finish().map_err(failed)?;

    let partial = spec.out.with_extension("part");
    std::fs::write(&partial, &bytes).map_err(|error| io(&partial, "write", &error))?;
    publish(&partial, spec.out)
}

/// The Windows code pages tried, Western first, then the other single-byte ones, then
/// the East Asian double-byte ones.
const CODEPAGES: [::msi::CodePage; 13] = [
    ::msi::CodePage::Windows1252,
    ::msi::CodePage::Windows1254,
    ::msi::CodePage::Windows1250,
    ::msi::CodePage::Windows1251,
    ::msi::CodePage::Windows1253,
    ::msi::CodePage::Windows1257,
    ::msi::CodePage::Windows1255,
    ::msi::CodePage::Windows1256,
    ::msi::CodePage::Windows1258,
    ::msi::CodePage::Windows932,
    ::msi::CodePage::Windows936,
    ::msi::CodePage::Windows949,
    ::msi::CodePage::Windows950,
];

/// The first code page that carries every one of `texts` unchanged.
///
/// Measured: the `msi` crate's default, UTF-8 (65001), is a database Windows Installer
/// cannot open — `msiexec` answered 1620, `OpenDatabase` failed, and the summary's strings
/// read back empty with the code page as -535. A Turkish product name needs 1254.
pub fn codepage_for(texts: &[&str]) -> Option<::msi::CodePage> {
    CODEPAGES.into_iter().find(|page| {
        texts
            .iter()
            .all(|text| page.decode(&page.encode(text)) == *text)
    })
}

/// `1.2.3` from `1.2.3`, `1.2.3-beta.1` or `v1.2`: Windows Installer takes up to three
/// numeric fields (major ≤ 255, minor ≤ 255, build ≤ 65535) and compares only those.
pub fn product_version(version: &str) -> Result<String, CliError> {
    let core = version
        .trim_start_matches('v')
        .split(['-', '+'])
        .next()
        .unwrap_or_default();
    let fields: Vec<&str> = core.split('.').collect();
    let limits = [255_u32, 255, 65_535];
    if fields.is_empty() || fields.len() > 3 {
        return Err(CliError::Invalid(format!(
            "an MSI version has one to three numbers (major.minor.build); \"version\" is {version:?}"
        )));
    }
    let mut kept = Vec::with_capacity(3);
    for (field, limit) in fields.iter().zip(limits) {
        let number: u32 = field.parse().map_err(|_| {
            CliError::Invalid(format!(
                "\"version\" {version:?} is not numeric enough for an MSI"
            ))
        })?;
        if number > limit {
            return Err(CliError::Invalid(format!(
                "\"version\" {version:?}: an MSI allows at most 255.255.65535"
            )));
        }
        kept.push(number.to_string());
    }
    while kept.len() < 3 {
        kept.push(String::from("0"));
    }
    Ok(kept.join("."))
}

/// The install's directories and files, keyed for the database, in the bundle's order.
fn layout(spec: &Installer<'_>) -> Result<(Vec<Directory>, Vec<File>), CliError> {
    let entries = sorted_entries(spec.bundle, Path::new(""), spec.skip)?;
    let mut directories = vec![
        Directory {
            key: "TARGETDIR".into(),
            parent: String::new(),
            name: "SourceDir".into(),
        },
        Directory {
            key: "LocalAppDataFolder".into(),
            parent: "TARGETDIR".into(),
            name: "LocalApp".into(),
        },
        // The user's Start menu programs folder, for the shortcut.
        Directory {
            key: "ProgramMenuFolder".into(),
            parent: "TARGETDIR".into(),
            name: ".".into(),
        },
        Directory {
            key: "ProgramsDir".into(),
            parent: "LocalAppDataFolder".into(),
            name: "Programs".into(),
        },
    ];
    let mut short = ShortNames::default();
    let product_dir = short.named("ProgramsDir", spec.product);
    directories.push(Directory {
        key: "INSTALLDIR".into(),
        parent: "ProgramsDir".into(),
        name: product_dir,
    });

    let mut keys: Vec<(String, String)> = vec![(String::new(), "INSTALLDIR".into())];
    let mut files = Vec::new();
    for entry in &entries {
        let relative = slashed(&entry.path);
        let (parent_path, leaf) = match relative.rsplit_once('/') {
            Some((parent, leaf)) => (parent.to_owned(), leaf.to_owned()),
            None => (String::new(), relative.clone()),
        };
        let parent = keys
            .iter()
            .find(|(path, _)| *path == parent_path)
            .map(|(_, key)| key.clone())
            .ok_or_else(|| {
                CliError::Invalid(format!("{relative}: its directory was not laid out first"))
            })?;
        if entry.directory {
            let key = format!("d{}", directories.len());
            let name = short.named(&parent, &leaf);
            directories.push(Directory {
                key: key.clone(),
                parent,
                name,
            });
            keys.push((relative, key));
        } else {
            let index = files.len() + 1;
            let bytes =
                std::fs::read(&entry.source).map_err(|error| io(&entry.source, "read", &error))?;
            files.push(File {
                key: format!("f{index}"),
                component: format!("c{index}"),
                name: short.named(&parent, &leaf),
                directory: parent,
                relative,
                bytes,
            });
        }
    }
    if files.is_empty() {
        return Err(CliError::Invalid(format!(
            "{} has no files to install",
            spec.bundle.display()
        )));
    }
    Ok((directories, files))
}

/// One MSZIP folder holding every file under its File key, in Sequence order.
fn cabinet(files: &[File], mtime: u64, out: &Path) -> Result<Vec<u8>, CliError> {
    let failed = |error: std::io::Error| io(out, "write the cabinet for", &error);
    let stamp = time::OffsetDateTime::from_unix_timestamp(i64::try_from(mtime).unwrap_or(0))
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH);
    let when = time::PrimitiveDateTime::new(stamp.date(), stamp.time());
    let mut builder = cab::CabinetBuilder::new();
    let folder = builder.add_folder(cab::CompressionType::MsZip);
    for file in files {
        folder.add_file(file.key.clone()).set_datetime(when);
    }
    let mut writer = builder
        .build(std::io::Cursor::new(Vec::new()))
        .map_err(failed)?;
    let mut index = 0;
    while let Some(mut next) = writer.next_file().map_err(failed)? {
        let file = files.get(index).ok_or_else(|| {
            CliError::Invalid(String::from(
                "the cabinet asked for more files than it was given",
            ))
        })?;
        next.write_all(&file.bytes).map_err(failed)?;
        index += 1;
    }
    Ok(writer.finish().map_err(failed)?.into_inner())
}

fn slashed(path: &Path) -> String {
    path.components()
        .map(|part| part.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

/// A name-based UUID (RFC 9562 version 8, SHA-256 of `kind` and `parts`), braced and in
/// upper case as the database's GUID columns want it.
pub fn name_uuid(kind: &str, parts: &[&str]) -> String {
    let mut digest = sha2::Sha256::new();
    digest.update(b"lepton-msi\0");
    digest.update(kind.as_bytes());
    for part in parts {
        digest.update(b"\0");
        digest.update(part.as_bytes());
    }
    format!(
        "{{{}}}",
        uuid_from(&digest.finalize())
            .hyphenated()
            .to_string()
            .to_ascii_uppercase()
    )
}

fn uuid_from(digest: &[u8]) -> uuid::Uuid {
    let mut bytes = [0_u8; 16];
    for (slot, byte) in bytes.iter_mut().zip(digest) {
        *slot = *byte;
    }
    uuid::Builder::from_custom_bytes(bytes).into_uuid()
}

#[cfg(test)]
mod tests {
    use super::super::installer_names::{ShortNames, is_short};
    use super::super::installer_read::{embedded_cabinet, properties};
    use super::{Installer, codepage_for, name_uuid, product_version, write};
    use lepton_orchestrator::testing::{Failure, Scratch};
    use lepton_orchestrator::{assert_eq, assert_ok, ensure};

    #[test]
    fn the_code_page_is_the_first_that_holds_every_name() -> Result<(), Failure> {
        use ::msi::CodePage;
        assert_eq!(
            codepage_for(&["Notes", "index.html"]),
            Some(CodePage::Windows1252)
        );
        assert_eq!(
            codepage_for(&["Not Defteri", "Şık"]),
            Some(CodePage::Windows1254)
        );
        assert_eq!(codepage_for(&["メモ"]), Some(CodePage::Windows932));
        assert_eq!(codepage_for(&["Notes 📝"]), None::<CodePage>);
        Ok(())
    }

    #[test]
    fn versions_become_three_msi_fields() -> Result<(), Failure> {
        assert_eq!(assert_ok!(product_version("1.2.3"), "plain"), "1.2.3");
        assert_eq!(
            assert_ok!(product_version("0.2.0-beta.1"), "pre-release"),
            "0.2.0"
        );
        assert_eq!(assert_ok!(product_version("2.1"), "two fields"), "2.1.0");
        ensure!(product_version("256.0.0").is_err(), "major over 255");
        ensure!(product_version("1.2.3.4").is_err(), "four fields");
        ensure!(product_version("one").is_err(), "not a number");
        Ok(())
    }

    #[test]
    fn identities_are_stable_and_distinct() -> Result<(), Failure> {
        let upgrade = name_uuid("upgrade", &["style.lepton.notes"]);
        assert_eq!(upgrade, name_uuid("upgrade", &["style.lepton.notes"]));
        ensure!(
            upgrade != name_uuid("upgrade", &["style.lepton.other"]),
            "another app, another code"
        );
        ensure!(
            name_uuid("product", &["style.lepton.notes", "1.0.0"])
                != name_uuid("product", &["style.lepton.notes", "1.0.1"]),
            "each version is its own product"
        );
        ensure!(
            upgrade.len() == 38 && upgrade.starts_with('{') && upgrade.ends_with('}'),
            "braced: {upgrade}"
        );
        ensure!(
            upgrade == upgrade.to_ascii_uppercase(),
            "upper case: {upgrade}"
        );
        Ok(())
    }

    #[test]
    fn long_names_get_unique_short_forms() -> Result<(), Failure> {
        ensure!(
            is_short("index.js") && is_short("BIN") && !is_short("index-BaFzhsZS.js"),
            "8.3 rules"
        );
        let mut names = ShortNames::default();
        assert_eq!(names.named("d1", "bin"), "bin");
        assert_eq!(
            names.named("d1", "index-BaFzhsZS.js"),
            "INDEXB~1.JS|index-BaFzhsZS.js"
        );
        assert_eq!(
            names.named("d1", "index-DeNq-cW0.js"),
            "INDEXD~1.JS|index-DeNq-cW0.js"
        );
        assert_eq!(
            names.named("d1", "index-BaXXXXXX.js"),
            "INDEXB~2.JS|index-BaXXXXXX.js"
        );
        assert_eq!(
            names.named("d2", "index-BaFzhsZS.js"),
            "INDEXB~1.JS|index-BaFzhsZS.js"
        );
        Ok(())
    }

    #[test]
    fn a_bundle_becomes_the_same_installer_twice() -> Result<(), Failure> {
        let scratch = Scratch::new("msi-twice")?;
        scratch.write("tree/bin/notes.exe", "MZ notes")?;
        scratch.write(
            "tree/share/notes/dist/index.html",
            &"<p>notes</p>\n".repeat(100),
        )?;
        scratch.write("tree/.lepton-package", "skip")?;
        let tree = scratch.path().join("tree");
        let (one, two) = (
            scratch.path().join("one.msi"),
            scratch.path().join("two.msi"),
        );
        // An `ICONDIR` header is all the writer checks; the bytes go in as they are.
        let icon = scratch.path().join("notes.ico");
        std::fs::write(&icon, [0, 0, 1, 0, 1, 0, 16, 16])
            .map_err(|error| lepton_orchestrator::testing::fail("the icon", error))?;
        let schemes = vec![String::from("notes")];
        let make = |out| Installer {
            bundle: &tree,
            skip: &[".lepton-package"],
            identifier: "style.lepton.notes",
            product: "Notes",
            version: "1.2.3",
            manufacturer: "Lepton",
            program: "notes.exe",
            icon: Some(&icon),
            schemes: &schemes,
            mtime: 0,
            out,
        };
        let first = assert_ok!(write(&make(&one)), "first");
        let second = assert_ok!(write(&make(&two)), "second");
        assert_eq!(first, second);

        let mut package = assert_ok!(::msi::open(&one), "reads back");
        for table in [
            "Shortcut",
            "MsiShortcutProperty",
            "Registry",
            "Upgrade",
            "LaunchCondition",
            "CustomAction",
            "Icon",
        ] {
            ensure!(package.has_table(table), "{table} is written");
        }
        ensure!(
            package.has_stream("Icon.product.ico"),
            "the icon's bytes are the Icon row's stream"
        );
        let target = assert_ok!(
            package.select_rows(::msi::Select::table("Shortcut")),
            "shortcut"
        )
        .map(|row| row[4].as_str().unwrap_or_default().to_owned())
        .collect::<Vec<_>>();
        assert_eq!(target, vec![String::from("[#f1]")]);
        let aumid = assert_ok!(
            package.select_rows(::msi::Select::table("MsiShortcutProperty")),
            "aumid"
        )
        .map(|row| row[3].as_str().unwrap_or_default().to_owned())
        .collect::<Vec<_>>();
        assert_eq!(aumid, vec![String::from("style.lepton.notes")]);
        // `deepLinks`: notes:// opens the program with the link.
        let opens = assert_ok!(
            package.select_rows(::msi::Select::table("Registry")),
            "registry"
        )
        .filter(|row| {
            row[2]
                .as_str()
                .is_some_and(|key| key.ends_with("\\shell\\open\\command"))
        })
        .map(|row| {
            (
                row[2].as_str().unwrap_or_default().to_owned(),
                row[4].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect::<Vec<_>>();
        assert_eq!(
            opens,
            vec![(
                String::from("Software\\Classes\\notes\\shell\\open\\command"),
                String::from("\"[#f1]\" \"%1\"")
            )]
        );

        // Laid out again from its own tables and cabinet, as `--verify` does.
        let unpacked = scratch.path().join("unpacked");
        let root = assert_ok!(super::extract(&one, &unpacked), "extract");
        ensure!(
            root.join("bin/notes.exe").is_file(),
            "the program is in bin"
        );
        let page = std::fs::read_to_string(root.join("share/notes/dist/index.html"))
            .map_err(|error| lepton_orchestrator::testing::fail("the page", error))?;
        ensure!(page.starts_with("<p>notes</p>"), "the page came back whole");

        let read = assert_ok!(properties(&scratch.path().join("one.msi")), "properties");
        let value = |name: &str| {
            read.iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        };
        assert_eq!(value("ProductName").as_deref(), Some("Notes"));
        assert_eq!(value("ProductVersion").as_deref(), Some("1.2.3"));
        assert_eq!(
            value("UpgradeCode"),
            Some(name_uuid("upgrade", &["style.lepton.notes"]))
        );
        let cabinet = assert_ok!(embedded_cabinet(&scratch.path().join("one.msi")), "cabinet");
        let reader = assert_ok!(
            cab::Cabinet::new(std::io::Cursor::new(cabinet)),
            "a cabinet"
        );
        let names: Vec<String> = reader
            .folder_entries()
            .flat_map(|folder| folder.file_entries())
            .map(|file| file.name().to_owned())
            .collect();
        assert_eq!(names, vec![String::from("f1"), String::from("f2")]);
        Ok(())
    }
}
