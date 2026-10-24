//! The installer's tables: the standard ones it uses, with the Windows Installer schema's
//! column types (`installer_db.rs` writes them), and their rows.

use super::installer::{COMPONENT_64BIT, Directory, Extras, File, Installer, LANGUAGE, name_uuid};
use super::installer_db::{Cell, Column, Database, Kind, text};

/// The standard tables this package uses, as the Windows Installer SDK defines them — type,
/// category, range, foreign key and set (the SDK schema's `_Validation`), so ICE checks the
/// rows against what the tables mean.
pub(super) fn tables(db: &mut Database, icon: bool) {
    let s = |name, len| Column::new(name, Kind::Str(len));
    let i2 = |name| Column::new(name, Kind::Int16);
    let i4 = |name| Column::new(name, Kind::Int32);
    let id = |name| s(name, 72).cat("Identifier");
    db.table(
        "Property",
        vec![
            id("Property").key(),
            s("Value", 0).localizable().cat("Text"),
        ],
    );
    db.table(
        "Directory",
        vec![
            id("Directory").key(),
            id("Directory_Parent").nullable().refers("Directory", 1),
            s("DefaultDir", 255).localizable().cat("DefaultDir"),
        ],
    );
    db.table(
        "Component",
        vec![
            id("Component").key(),
            s("ComponentId", 38).nullable().cat("Guid"),
            id("Directory_").refers("Directory", 1),
            i2("Attributes"),
            s("Condition", 255).nullable().cat("Condition"),
            id("KeyPath")
                .nullable()
                .refers("File;Registry;ODBCDataSource", 1),
        ],
    );
    db.table(
        "Feature",
        vec![
            s("Feature", 38).key().cat("Identifier"),
            s("Feature_Parent", 38)
                .nullable()
                .cat("Identifier")
                .refers("Feature", 1),
            s("Title", 64).nullable().localizable().cat("Text"),
            s("Description", 255).nullable().localizable().cat("Text"),
            i2("Display").nullable().range(0, 32767),
            i2("Level").range(0, 32767),
            s("Directory_", 72)
                .nullable()
                .cat("UpperCase")
                .refers("Directory", 1),
            i2("Attributes").set(
                "0;1;2;4;5;6;8;9;10;16;17;18;20;21;22;24;25;26;32;33;34;36;37;38;48;49;50;52;53;54",
            ),
        ],
    );
    db.table(
        "FeatureComponents",
        vec![
            s("Feature_", 38)
                .key()
                .cat("Identifier")
                .refers("Feature", 1),
            id("Component_").key().refers("Component", 1),
        ],
    );
    db.table(
        "File",
        vec![
            id("File").key(),
            id("Component_").refers("Component", 1),
            s("FileName", 255).localizable().cat("Filename"),
            i4("FileSize").range(0, 2_147_483_647),
            s("Version", 72).nullable().cat("Version").refers("File", 1),
            s("Language", 20).nullable().cat("Language"),
            i2("Attributes").nullable().range(0, 32767),
            i4("Sequence").range(1, 2_147_483_647),
        ],
    );
    db.table(
        "Media",
        vec![
            i2("DiskId").key().range(1, 32767),
            i4("LastSequence").range(0, 2_147_483_647),
            s("DiskPrompt", 64).nullable().localizable().cat("Text"),
            s("Cabinet", 255).nullable().cat("Cabinet"),
            s("VolumeLabel", 32).nullable().cat("Text"),
            s("Source", 72).nullable().cat("Property"),
        ],
    );
    // The Start menu shortcut, its AppUserModelID, and the HKCU values that are the key
    // paths of every component (a per-user component must have one — ICE38).
    db.table(
        "Shortcut",
        vec![
            id("Shortcut").key(),
            id("Directory_").refers("Directory", 1),
            s("Name", 128).localizable().cat("Filename"),
            id("Component_").refers("Component", 1),
            s("Target", 72).cat("Shortcut"),
            s("Arguments", 255).nullable().cat("Formatted"),
            s("Description", 255).nullable().localizable().cat("Text"),
            i2("Hotkey").nullable().range(0, 32767),
            id("Icon_").nullable().refers("Icon", 1),
            i2("IconIndex").nullable().range(-32767, 32767),
            i2("ShowCmd").nullable().set("1;3;7"),
            id("WkDir").nullable(),
        ],
    );
    db.table(
        "MsiShortcutProperty",
        vec![
            id("MsiShortcutProperty").key(),
            id("Shortcut_").refers("Shortcut", 1),
            s("PropertyKey", 0).cat("Formatted"),
            s("PropVariantValue", 0).cat("Formatted"),
            i2("Sequence").nullable().range(0, 32767),
        ],
    );
    db.table(
        "Registry",
        vec![
            id("Registry").key(),
            i2("Root").range(-1, 3),
            s("Key", 255).localizable().cat("RegPath"),
            s("Name", 255).nullable().localizable().cat("Formatted"),
            s("Value", 0).nullable().localizable().cat("Formatted"),
            id("Component_").refers("Component", 1),
        ],
    );
    // The folders this package makes in the profile, removed when it goes (ICE64).
    db.table(
        "RemoveFile",
        vec![
            id("FileKey").key(),
            id("Component_").refers("Component", 1),
            s("FileName", 255)
                .nullable()
                .localizable()
                .cat("WildCardFilename"),
            id("DirProperty"),
            i2("InstallMode").set("1;2;3"),
        ],
    );
    // A newer version installed refuses this one; an older one is removed first.
    db.table(
        "Upgrade",
        vec![
            s("UpgradeCode", 38).key().cat("Guid"),
            s("VersionMin", 20).nullable().key().cat("Text"),
            s("VersionMax", 20).nullable().key().cat("Text"),
            s("Language", 255).nullable().key().cat("Language"),
            i4("Attributes").key().range(0, 2_147_483_647),
            s("Remove", 255).nullable().cat("Formatted"),
            s("ActionProperty", 72).cat("UpperCase"),
        ],
    );
    db.table(
        "LaunchCondition",
        vec![
            s("Condition", 255).key().cat("Condition"),
            s("Description", 255).localizable().cat("Formatted"),
        ],
    );
    db.table(
        "CustomAction",
        vec![
            id("Action").key(),
            i2("Type").range(1, 32767),
            s("Source", 72).nullable().cat("CustomSource"),
            s("Target", 255).nullable().cat("Formatted"),
            i4("ExtendedType").nullable().range(0, 2_147_483_647),
        ],
    );
    if icon {
        db.table(
            "Icon",
            vec![id("Name").key(), Column::new("Data", Kind::Binary)],
        );
    }
    for sequence in ["InstallExecuteSequence", "InstallUISequence"] {
        db.table(
            sequence,
            vec![
                id("Action").key(),
                s("Condition", 255).nullable().cat("Condition"),
                i2("Sequence").nullable().range(-4, 32767),
            ],
        );
    }
}

/// The icon's name in the Icon table; the extension tells Windows what it is.
const ICON: &str = "product.ico";

/// The standard actions, in the numbers the Windows Installer SDK's sequence tables use.
const EXECUTE: [(&str, i32); 25] = [
    ("FindRelatedProducts", 25),
    ("LaunchConditions", 100),
    ("CostInitialize", 800),
    ("FileCost", 900),
    ("CostFinalize", 1000),
    ("SetARPINSTALLLOCATION", 1001),
    ("MigrateFeatureStates", 1200),
    ("InstallValidate", 1400),
    // Right after validation: the older version goes before anything of this one lands.
    ("RemoveExistingProducts", 1401),
    ("InstallInitialize", 1500),
    ("ProcessComponents", 1600),
    ("UnpublishFeatures", 1800),
    ("RemoveRegistryValues", 2600),
    ("RemoveShortcuts", 3200),
    ("RemoveFiles", 3500),
    ("RemoveFolders", 3600),
    ("CreateFolders", 3700),
    ("InstallFiles", 4000),
    ("CreateShortcuts", 4500),
    ("WriteRegistryValues", 5000),
    ("RegisterUser", 6000),
    ("RegisterProduct", 6100),
    ("PublishFeatures", 6300),
    ("PublishProduct", 6400),
    ("InstallFinalize", 6600),
];
const UI: [(&str, i32); 7] = [
    ("FindRelatedProducts", 25),
    ("LaunchConditions", 100),
    ("CostInitialize", 800),
    ("FileCost", 900),
    ("CostFinalize", 1000),
    ("MigrateFeatureStates", 1200),
    ("ExecuteAction", 1300),
];

pub(super) fn rows(
    db: &mut Database,
    spec: &Installer<'_>,
    version: &str,
    codes: (&str, &str),
    (directories, files): (&[Directory], &[File]),
    extras: Extras,
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
        // The upgrade rows' properties, kept when the install runs elevated.
        (
            "SecureCustomProperties",
            String::from("NEWERFOUND;UPGRADEFOUND"),
        ),
    ];
    let mut properties: Vec<(&str, String)> = properties.to_vec();
    if extras.icon.is_some() {
        properties.push(("ARPPRODUCTICON", String::from(ICON)));
    }
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
    // Every file is in the profile, so every component's key path is an HKCU value, one per
    // component under `Software\<identifier>\Components` (ICE38); the file is still the
    // component's only file, and the value goes with it.
    let components_key = format!("Software\\{}\\Components", spec.identifier);
    db.rows(
        "Component",
        files
            .iter()
            .map(|file| {
                vec![
                    text(&file.component),
                    text(&name_uuid("component", &[spec.identifier, &file.relative])),
                    text(&file.directory),
                    Cell::Int(COMPONENT_64BIT | 4),
                    Cell::Null,
                    text(&format!("r_{}", file.component)),
                ]
            })
            .collect(),
    )?;
    db.rows(
        "Registry",
        files
            .iter()
            .map(|file| {
                vec![
                    text(&format!("r_{}", file.component)),
                    Cell::Int(1),
                    text(&components_key),
                    text(&file.component),
                    text("#1"),
                    text(&file.component),
                ]
            })
            .collect(),
    )?;
    // The folders made in the profile go on uninstall (ICE64): the program's own and every
    // one below it, and `%LOCALAPPDATA%\Programs` when nothing else is left in it.
    let profile = ["TARGETDIR", "LocalAppDataFolder", "ProgramMenuFolder"];
    db.rows(
        "RemoveFile",
        directories
            .iter()
            .filter(|dir| !profile.contains(&dir.key.as_str()))
            .map(|dir| {
                vec![
                    text(&format!("rm_{}", dir.key)),
                    text("shortcut"),
                    Cell::Null,
                    text(&dir.key),
                    Cell::Int(2),
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
    // The shortcut's own component, in the Start menu folder, kept by an HKCU value.
    let registry_key = format!("Software\\{}", spec.identifier);
    db.rows(
        "Component",
        vec![vec![
            text("shortcut"),
            text(&name_uuid(
                "component",
                &[spec.identifier, "start menu shortcut"],
            )),
            text("ProgramMenuFolder"),
            // 64-bit, key path in the registry (`msidbComponentAttributesRegistryKeyPath`).
            Cell::Int(COMPONENT_64BIT | 4),
            Cell::Null,
            text("shortcut_installed"),
        ]],
    )?;
    db.rows(
        "Registry",
        vec![vec![
            text("shortcut_installed"),
            Cell::Int(1),
            text(&registry_key),
            text("installed"),
            text("#1"),
            text("shortcut"),
        ]],
    )?;
    // `deepLinks`: each scheme opens the program with the link as its argument, for this
    // user (`HKCU\Software\Classes`), kept with the shortcut's component.
    let mut scheme_rows = Vec::new();
    for (index, scheme) in extras.schemes.iter().enumerate() {
        let key = format!("Software\\Classes\\{scheme}");
        scheme_rows.push(vec![
            text(&format!("scheme{index}")),
            Cell::Int(1),
            text(&key),
            Cell::Null,
            text(&format!("URL:{}", spec.product)),
            text("shortcut"),
        ]);
        // Windows reads only that the value exists.
        scheme_rows.push(vec![
            text(&format!("scheme{index}_protocol")),
            Cell::Int(1),
            text(&key),
            text("URL Protocol"),
            text("1"),
            text("shortcut"),
        ]);
        scheme_rows.push(vec![
            text(&format!("scheme{index}_open")),
            Cell::Int(1),
            text(&format!("{key}\\shell\\open\\command")),
            Cell::Null,
            text(&format!("\"[#{}]\" \"%1\"", extras.program)),
            text("shortcut"),
        ]);
    }
    // The name Windows shows on the program's notifications: the core writes it at run time
    // (`webview2/notifications.zig`); written here as well, it is removed with the program.
    scheme_rows.push(vec![
        text("notification_name"),
        Cell::Int(1),
        text(&format!(
            "Software\\Classes\\AppUserModelId\\{}",
            spec.identifier
        )),
        text("DisplayName"),
        text(spec.product),
        text("shortcut"),
    ]);
    // Its icon: a path to the `.ico` the template installs as `share/<name>/icon.ico`;
    // without one Windows draws a blank placeholder beside the name (measured).
    if let Some(icon) = notification_icon(files) {
        scheme_rows.push(vec![
            text("notification_icon"),
            Cell::Int(1),
            text(&format!(
                "Software\\Classes\\AppUserModelId\\{}",
                spec.identifier
            )),
            text("IconUri"),
            text(&format!("[#{}]", icon.key)),
            // The file's own component, which a reference to it must share (ICE69).
            text(&icon.component),
        ]);
    }
    db.rows("Registry", scheme_rows)?;
    // The shortcut belongs to its target's component (ICE69): it comes and goes with the
    // program, whose key path is an HKCU value (ICE43).
    let program_component = files
        .iter()
        .find(|file| file.key == extras.program)
        .map_or("shortcut", |file| file.component.as_str());
    db.rows(
        "Shortcut",
        vec![vec![
            text("start_menu"),
            text("ProgramMenuFolder"),
            text(&extras.shortcut),
            text(program_component),
            text(&format!("[#{}]", extras.program)),
            Cell::Null,
            text(spec.product),
            Cell::Null,
            if extras.icon.is_some() {
                text(ICON)
            } else {
                Cell::Null
            },
            if extras.icon.is_some() {
                Cell::Int(0)
            } else {
                Cell::Null
            },
            Cell::Null,
            text("INSTALLDIR"),
        ]],
    )?;
    // `PKEY_AppUserModel_ID`: the identifier the running program also claims
    // (`webview2/view.zig`), so the taskbar groups its windows under the shortcut.
    db.rows(
        "MsiShortcutProperty",
        vec![vec![
            text("aumid"),
            text("start_menu"),
            text("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3} 5"),
            text(spec.identifier),
            Cell::Null,
        ]],
    )?;
    db.rows(
        "Upgrade",
        vec![
            // Older versions: found, and removed by RemoveExistingProducts.
            vec![
                text(upgrade),
                Cell::Null,
                text(version),
                Cell::Null,
                Cell::Int(0),
                Cell::Null,
                text("UPGRADEFOUND"),
            ],
            // Newer ones: only detected (2), to refuse the downgrade below.
            vec![
                text(upgrade),
                text(version),
                Cell::Null,
                Cell::Null,
                Cell::Int(2),
                Cell::Null,
                text("NEWERFOUND"),
            ],
        ],
    )?;
    db.rows(
        "LaunchCondition",
        vec![vec![
            text("NOT NEWERFOUND"),
            text("A newer version of [ProductName] is already installed."),
        ]],
    )?;
    // Type 51 sets a property: the folder Settings → Apps shows as the location.
    db.rows(
        "CustomAction",
        vec![vec![
            text("SetARPINSTALLLOCATION"),
            Cell::Int(51),
            text("ARPINSTALLLOCATION"),
            text("[INSTALLDIR]"),
            Cell::Null,
        ]],
    )?;
    if let Some(bytes) = extras.icon {
        db.rows("Icon", vec![vec![text(ICON), Cell::Bytes(bytes)]])?;
    }
    db.rows(
        "FeatureComponents",
        files
            .iter()
            .map(|file| vec![text("Main"), text(&file.component)])
            .chain(std::iter::once(vec![text("Main"), text("shortcut")]))
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

/// The `.ico` the template installs for the program's notifications: `share/<name>/icon.ico`.
fn notification_icon(files: &[File]) -> Option<&File> {
    files.iter().find(|file| {
        let parts: Vec<&str> = file.relative.split('/').collect();
        matches!(parts.as_slice(), ["share", name, "icon.ico"] if !name.is_empty())
    })
}

#[cfg(test)]
mod tests {
    use super::{File, notification_icon};

    fn file(key: &str, relative: &str) -> File {
        File {
            key: key.into(),
            component: String::new(),
            directory: String::new(),
            name: String::new(),
            relative: relative.into(),
            bytes: Vec::new(),
        }
    }

    #[test]
    fn the_notification_icon_is_the_one_beside_the_frontend() {
        let files = [
            file("f1", "bin/notes.exe"),
            file("f2", "share/notes/dist/icon.ico"),
            file("f3", "share/notes/icon.ico"),
        ];
        assert_eq!(notification_icon(&files).map(|icon| icon.key.as_str()), Some("f3"));
        assert!(notification_icon(&files[..2]).is_none());
    }
}
