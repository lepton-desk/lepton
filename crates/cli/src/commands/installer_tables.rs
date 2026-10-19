//! The installer's tables: the standard ones it uses, with the Windows Installer schema's
//! column types (`installer_db.rs` writes them), and their rows.

use super::installer::{COMPONENT_64BIT, Directory, File, Installer, LANGUAGE, name_uuid};
use super::installer_db::{Cell, Column, Database, Kind, text};

/// The standard tables this package uses, as the Windows Installer SDK defines them.
pub(super) fn tables(db: &mut Database) {
    let s = |name, len| Column::new(name, Kind::Str(len));
    db.table(
        "Property",
        vec![s("Property", 72).key(), s("Value", 0).localizable()],
    );
    db.table(
        "Directory",
        vec![
            s("Directory", 72).key(),
            s("Directory_Parent", 72).nullable(),
            s("DefaultDir", 255).localizable(),
        ],
    );
    db.table(
        "Component",
        vec![
            s("Component", 72).key(),
            s("ComponentId", 38).nullable(),
            s("Directory_", 72),
            Column::new("Attributes", Kind::Int16),
            s("Condition", 255).nullable(),
            s("KeyPath", 72).nullable(),
        ],
    );
    db.table(
        "Feature",
        vec![
            s("Feature", 38).key(),
            s("Feature_Parent", 38).nullable(),
            s("Title", 64).nullable().localizable(),
            s("Description", 255).nullable().localizable(),
            Column::new("Display", Kind::Int16).nullable(),
            Column::new("Level", Kind::Int16),
            s("Directory_", 72).nullable(),
            Column::new("Attributes", Kind::Int16),
        ],
    );
    db.table(
        "FeatureComponents",
        vec![s("Feature_", 38).key(), s("Component_", 72).key()],
    );
    db.table(
        "File",
        vec![
            s("File", 72).key(),
            s("Component_", 72),
            s("FileName", 255).localizable(),
            Column::new("FileSize", Kind::Int32),
            s("Version", 72).nullable(),
            s("Language", 20).nullable(),
            Column::new("Attributes", Kind::Int16).nullable(),
            Column::new("Sequence", Kind::Int32),
        ],
    );
    db.table(
        "Media",
        vec![
            Column::new("DiskId", Kind::Int16).key(),
            Column::new("LastSequence", Kind::Int32),
            s("DiskPrompt", 64).nullable().localizable(),
            s("Cabinet", 255).nullable(),
            s("VolumeLabel", 32).nullable(),
            s("Source", 72).nullable(),
        ],
    );
    for sequence in ["InstallExecuteSequence", "InstallUISequence"] {
        db.table(
            sequence,
            vec![
                s("Action", 72).key(),
                s("Condition", 255).nullable(),
                Column::new("Sequence", Kind::Int16).nullable(),
            ],
        );
    }
}

/// The standard actions, in the numbers the Windows Installer SDK's sequence tables use.
const EXECUTE: [(&str, i32); 16] = [
    ("CostInitialize", 800),
    ("FileCost", 900),
    ("CostFinalize", 1000),
    ("InstallValidate", 1400),
    ("InstallInitialize", 1500),
    ("ProcessComponents", 1600),
    ("UnpublishFeatures", 1800),
    ("RemoveFiles", 3500),
    ("RemoveFolders", 3600),
    ("CreateFolders", 3700),
    ("InstallFiles", 4000),
    ("RegisterUser", 6000),
    ("RegisterProduct", 6100),
    ("PublishFeatures", 6300),
    ("PublishProduct", 6400),
    ("InstallFinalize", 6600),
];
const UI: [(&str, i32); 4] = [
    ("CostInitialize", 800),
    ("FileCost", 900),
    ("CostFinalize", 1000),
    ("ExecuteAction", 1300),
];

pub(super) fn rows(
    db: &mut Database,
    spec: &Installer<'_>,
    version: &str,
    codes: (&str, &str),
    directories: &[Directory],
    files: &[File],
) -> std::io::Result<()> {
    let (upgrade, product) = codes;
    let properties = [
        ("ProductCode", product.to_owned()),
        ("UpgradeCode", upgrade.to_owned()),
        ("ProductName", spec.product.to_owned()),
        ("ProductVersion", version.to_owned()),
        ("ProductLanguage", LANGUAGE.to_string()),
        ("Manufacturer", spec.manufacturer.to_owned()),
        // Settings → Apps offers Uninstall only; there is nothing to modify or repair.
        ("ARPNOMODIFY", String::from("1")),
        ("ARPNOREPAIR", String::from("1")),
    ];
    db.rows(
        "Property",
        properties
            .iter()
            .map(|(name, value)| vec![text(name), text(value)])
            .collect(),
    )?;
    db.rows(
        "Directory",
        directories
            .iter()
            .map(|dir| {
                let parent = if dir.parent.is_empty() {
                    Cell::Null
                } else {
                    text(&dir.parent)
                };
                vec![text(&dir.key), parent, text(&dir.name)]
            })
            .collect(),
    )?;
    let sequence_of = |index: usize| i32::try_from(index + 1).unwrap_or(i32::MAX);
    db.rows(
        "Component",
        files
            .iter()
            .map(|file| {
                vec![
                    text(&file.component),
                    text(&name_uuid("component", &[spec.identifier, &file.relative])),
                    text(&file.directory),
                    Cell::Int(COMPONENT_64BIT),
                    Cell::Null,
                    text(&file.key),
                ]
            })
            .collect(),
    )?;
    db.rows(
        "Feature",
        vec![vec![
            text("Main"),
            Cell::Null,
            text(spec.product),
            Cell::Null,
            Cell::Int(1),
            Cell::Int(1),
            text("INSTALLDIR"),
            Cell::Int(0),
        ]],
    )?;
    db.rows(
        "FeatureComponents",
        files
            .iter()
            .map(|file| vec![text("Main"), text(&file.component)])
            .collect(),
    )?;
    db.rows(
        "File",
        files
            .iter()
            .enumerate()
            .map(|(index, file)| {
                vec![
                    text(&file.key),
                    text(&file.component),
                    text(&file.name),
                    Cell::Int(i32::try_from(file.bytes.len()).unwrap_or(i32::MAX)),
                    Cell::Null,
                    Cell::Null,
                    Cell::Int(0),
                    Cell::Int(sequence_of(index)),
                ]
            })
            .collect(),
    )?;
    db.rows(
        "Media",
        vec![vec![
            Cell::Int(1),
            Cell::Int(sequence_of(files.len().saturating_sub(1))),
            Cell::Null,
            text(&format!("#{}", super::installer::CABINET)),
            Cell::Null,
            Cell::Null,
        ]],
    )?;
    db.rows(
        "InstallExecuteSequence",
        EXECUTE
            .iter()
            .map(|(action, at)| vec![text(action), Cell::Null, Cell::Int(*at)])
            .collect(),
    )?;
    db.rows(
        "InstallUISequence",
        UI.iter()
            .map(|(action, at)| vec![text(action), Cell::Null, Cell::Int(*at)])
            .collect(),
    )?;
    Ok(())
}
