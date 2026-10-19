//! A Windows Installer database, written directly: string pool, tables, catalog, summary.
//!
//! Why not the `msi` crate's writer, which the first version used: it keeps a table's rows
//! in a map keyed by their *text*, and writes `_Tables` in table-name order. Windows
//! Installer reads every table as sorted by the stored values — string references by
//! their pool index — and refuses a database where the two orders differ. Measured with
//! one-table databases: a table named `aaa` opened, the same table named `Property` did
//! not (`OpenDatabase` failed, `msiexec` 1620, "Error 2219: Invalid Installer database
//! format"), because `"_Validation"` takes string 1 at creation and `P` sorts before `_`.
//! The crate still reads databases (`installer_read.rs`); reading has no order to keep.
//!
//! The format (Wine's `msi.dll`, msitools, and the `msi` crate's MIT-licensed reader are
//! the references): a compound file whose root class is `000C1084-…-46`; every table a
//! stream named with the 0x3800–0x4840 encoding and the table prefix U+4840, holding its
//! rows column by column — strings as 2-byte pool references, integers stored with the top
//! bit flipped, 0 for null; `_StringPool`/`_StringData` holding the strings once each in
//! the database's code page; `_Tables` and `_Columns` describing the tables;
//! `\u{5}SummaryInformation` an OLE property set; `_Validation` describing every column for
//! the ICE checks (the installer itself does not read it).

use std::collections::HashMap;
use std::io::Write as _;

/// One column's storage and flags.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Int16,
    Int32,
    /// A string column with its maximum length (0 = unlimited).
    Str(u8),
    /// A stream column (`Icon.Data`): the table stores 1, the bytes are the stream
    /// `<table>.<key>` (read from a real database: `!Icon` held `1e 06 01 00`, the bytes
    /// were in `Icon.ARPIco`).
    Binary,
}

#[derive(Debug, Clone)]
pub struct Column {
    pub name: &'static str,
    pub kind: Kind,
    pub key: bool,
    pub nullable: bool,
    pub localizable: bool,
    /// What `_Validation` says of the column — the Windows Installer SDK's schema — for the
    /// ICE checks (ICE03 refuses a column with no row there). The installer itself does not
    /// read `_Validation`.
    pub category: Option<&'static str>,
    pub range: Option<(i32, i32)>,
    pub refers: Option<(&'static str, i16)>,
    pub set: Option<&'static str>,
}

impl Column {
    pub const fn new(name: &'static str, kind: Kind) -> Self {
        Self {
            name,
            kind,
            key: false,
            nullable: false,
            localizable: false,
            category: None,
            range: None,
            refers: None,
            set: None,
        }
    }
    /// The value's category (`Identifier`, `Text`, `Guid`, …).
    pub const fn cat(mut self, category: &'static str) -> Self {
        self.category = Some(category);
        self
    }
    pub const fn range(mut self, min: i32, max: i32) -> Self {
        self.range = Some((min, max));
        self
    }
    /// A foreign key: the table(s) (`;`-separated) and the 1-based key column.
    pub const fn refers(mut self, table: &'static str, column: i16) -> Self {
        self.refers = Some((table, column));
        self
    }
    /// The allowed values, `;`-separated.
    pub const fn set(mut self, values: &'static str) -> Self {
        self.set = Some(values);
        self
    }
    pub const fn key(mut self) -> Self {
        self.key = true;
        self
    }
    pub const fn nullable(mut self) -> Self {
        self.nullable = true;
        self
    }
    pub const fn localizable(mut self) -> Self {
        self.localizable = true;
        self
    }

    /// `_Columns.Type`: the field size, then the valid, localizable, non-binary, string,
    /// nullable and key bits (`msi.h`'s `MSITYPE_*`).
    fn type_bits(&self) -> i32 {
        let base = match self.kind {
            Kind::Int16 => 0x2 | 0x400,
            Kind::Int32 => 0x4,
            Kind::Str(len) => 0x800 | 0x400 | i32::from(len),
            Kind::Binary => 0x800,
        };
        let mut bits = base | 0x100;
        if self.localizable {
            bits |= 0x200;
        }
        if self.nullable {
            bits |= 0x1000;
        }
        if self.key {
            bits |= 0x2000;
        }
        bits
    }
}

/// One cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cell {
    Null,
    Int(i32),
    Str(String),
    /// A stream column's bytes.
    Bytes(Vec<u8>),
}

pub fn text(value: &str) -> Cell {
    Cell::Str(value.to_owned())
}

struct Table {
    name: String,
    columns: Vec<Column>,
    rows: Vec<Vec<Cell>>,
}

/// A database being assembled; [`Database::finish`] writes it.
pub struct Database {
    codepage: ::msi::CodePage,
    tables: Vec<Table>,
    streams: Vec<(String, Vec<u8>)>,
    summary: Vec<(u32, Property)>,
}

/// A summary information value.
pub enum Property {
    I2(i16),
    I4(i32),
    Text(String),
}

/// Summary information property ids (`MSI` "Summary Information Stream Property Set").
pub mod summary {
    pub const CODEPAGE: u32 = 1;
    pub const TITLE: u32 = 2;
    pub const SUBJECT: u32 = 3;
    pub const AUTHOR: u32 = 4;
    pub const KEYWORDS: u32 = 5;
    pub const COMMENTS: u32 = 6;
    pub const TEMPLATE: u32 = 7;
    pub const REVISION: u32 = 9;
    pub const PAGE_COUNT: u32 = 14;
    pub const WORD_COUNT: u32 = 15;
    pub const CREATING_APP: u32 = 18;
    pub const SECURITY: u32 = 19;
}

/// The class id of an installer database's root storage, `000C1084-0000-0000-C000-000000000046`.
const INSTALLER_CLSID: [u8; 16] = [
    0x84, 0x10, 0x0c, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46,
];
/// `FMTID_SummaryInformation`, `F29F85E0-4FF9-1068-AB91-08002B27B3D9`, as stored.
const SUMMARY_FMTID: [u8; 16] = [
    0xe0, 0x85, 0x9f, 0xf2, 0xf9, 0x4f, 0x68, 0x10, 0xab, 0x91, 0x08, 0x00, 0x2b, 0x27, 0xb3, 0xd9,
];

impl Database {
    pub fn new(codepage: ::msi::CodePage) -> Self {
        Self {
            codepage,
            tables: Vec::new(),
            streams: Vec::new(),
            summary: vec![(summary::CODEPAGE, Property::I2(codepage.id() as i16))],
        }
    }

    pub fn table(&mut self, name: &str, columns: Vec<Column>) {
        self.tables.push(Table {
            name: name.to_owned(),
            columns,
            rows: Vec::new(),
        });
    }

    /// Adds rows to `name`; each must have one cell per column of the right kind.
    pub fn rows(&mut self, name: &str, rows: Vec<Vec<Cell>>) -> std::io::Result<()> {
        let invalid = |why: String| std::io::Error::new(std::io::ErrorKind::InvalidInput, why);
        let table = self
            .tables
            .iter_mut()
            .find(|table| table.name == name)
            .ok_or_else(|| invalid(format!("no table {name}")))?;
        for row in &rows {
            if row.len() != table.columns.len() {
                return Err(invalid(format!(
                    "{name}: {} cells for {} columns",
                    row.len(),
                    table.columns.len()
                )));
            }
            for (cell, column) in row.iter().zip(&table.columns) {
                let fits = match (cell, column.kind) {
                    (Cell::Null, _) => column.nullable,
                    (Cell::Int(value), Kind::Int16) => {
                        i16::try_from(*value).is_ok_and(|v| v != i16::MIN)
                    }
                    (Cell::Int(value), Kind::Int32) => *value != i32::MIN,
                    (Cell::Bytes(_), Kind::Binary) => true,
                    (Cell::Str(text), Kind::Str(len)) => {
                        !text.is_empty() && (len == 0 || text.chars().count() <= usize::from(len))
                    }
                    _ => false,
                };
                if !fits {
                    return Err(invalid(format!(
                        "{name}.{}: {cell:?} does not fit",
                        column.name
                    )));
                }
            }
        }
        table.rows.extend(rows);
        Ok(())
    }

    pub fn summary(&mut self, id: u32, value: Property) {
        self.summary.retain(|(known, _)| *known != id);
        self.summary.push((id, value));
    }

    /// `_Validation`: one row per column of every table, itself included, from each
    /// column's category, range, foreign key and set.
    fn validation(&mut self) -> std::io::Result<()> {
        let s = |name, len| Column::new(name, Kind::Str(len));
        let columns = vec![
            s("Table", 32).key().cat("Identifier"),
            s("Column", 32).key().cat("Identifier"),
            s("Nullable", 4).set("Y;N"),
            Column::new("MinValue", Kind::Int32).nullable().range(-2_147_483_647, 2_147_483_647),
            Column::new("MaxValue", Kind::Int32).nullable().range(-2_147_483_647, 2_147_483_647),
            s("KeyTable", 255).nullable().cat("Identifier"),
            Column::new("KeyColumn", Kind::Int16).nullable().range(1, 32),
            s("Category", 32).nullable().set(
                "Text;Formatted;Template;Condition;Guid;Path;Version;Language;Identifier;Binary;UpperCase;LowerCase;Filename;Paths;AnyPath;WildCardFilename;RegPath;CustomSource;Property;Cabinet;Shortcut;FormattedSDDLText;Integer;DoubleInteger;TimeDate;DefaultDir",
            ),
            s("Set", 255).nullable().cat("Text"),
            s("Description", 255).nullable().cat("Text"),
        ];
        self.table("_Validation", columns);
        let mut rows = Vec::new();
        for table in &self.tables {
            for column in &table.columns {
                let optional = |value: Option<&str>| value.map_or(Cell::Null, text);
                rows.push(vec![
                    text(&table.name),
                    text(column.name),
                    text(if column.nullable { "Y" } else { "N" }),
                    column.range.map_or(Cell::Null, |(min, _)| Cell::Int(min)),
                    column.range.map_or(Cell::Null, |(_, max)| Cell::Int(max)),
                    optional(column.refers.map(|(table, _)| table)),
                    column
                        .refers
                        .map_or(Cell::Null, |(_, at)| Cell::Int(i32::from(at))),
                    optional(column.category.or(match column.kind {
                        Kind::Binary => Some("Binary"),
                        _ => None,
                    })),
                    optional(column.set),
                    Cell::Null,
                ]);
            }
        }
        self.rows("_Validation", rows)
    }

    /// An embedded stream (a cabinet), under its plain name.
    pub fn stream(&mut self, name: &str, bytes: Vec<u8>) {
        self.streams.push((name.to_owned(), bytes));
    }

    /// The whole database as compound-file bytes.
    pub fn finish(mut self) -> std::io::Result<Vec<u8>> {
        self.validation()?;
        let mut pool = Pool::default();
        // Ids are handed out in the order strings are met; every sort below is by id.
        for table in &self.tables {
            pool.add(&table.name);
            for column in &table.columns {
                pool.add(column.name);
            }
        }
        for table in &self.tables {
            for row in &table.rows {
                for cell in row {
                    if let Cell::Str(text) = cell {
                        pool.add(text);
                    }
                }
            }
        }

        let mut comp = cfb::CompoundFile::create(std::io::Cursor::new(Vec::new()))?;
        comp.set_storage_clsid("/", uuid::Uuid::from_bytes_le(INSTALLER_CLSID))?;

        let catalog_tables = Table {
            name: String::from("_Tables"),
            columns: vec![Column::new("Name", Kind::Str(64)).key()],
            rows: self
                .tables
                .iter()
                .map(|table| vec![text(&table.name)])
                .collect(),
        };
        let mut columns_rows = Vec::new();
        for table in &self.tables {
            for (number, column) in table.columns.iter().enumerate() {
                columns_rows.push(vec![
                    text(&table.name),
                    Cell::Int(i32::try_from(number + 1).unwrap_or(i32::MAX)),
                    text(column.name),
                    Cell::Int(column.type_bits()),
                ]);
            }
        }
        let catalog_columns = Table {
            name: String::from("_Columns"),
            columns: vec![
                Column::new("Table", Kind::Str(64)).key(),
                Column::new("Number", Kind::Int16).key(),
                Column::new("Name", Kind::Str(64)),
                Column::new("Type", Kind::Int16),
            ],
            rows: columns_rows,
        };
        for table in [&catalog_tables, &catalog_columns]
            .into_iter()
            .chain(self.tables.iter())
        {
            for row in &table.rows {
                for cell in row {
                    if let Cell::Str(text) = cell {
                        pool.count(text);
                    }
                }
            }
            if table.rows.is_empty() {
                continue;
            }
            let bytes = table_stream(table, &pool)?;
            comp.create_stream(stream_name(&table.name, true))?
                .write_all(&bytes)?;
        }

        let (pool_bytes, data_bytes) = pool.write(self.codepage);
        comp.create_stream(stream_name("_StringPool", true))?
            .write_all(&pool_bytes)?;
        comp.create_stream(stream_name("_StringData", true))?
            .write_all(&data_bytes)?;
        comp.create_stream("\u{5}SummaryInformation")?
            .write_all(&summary_stream(self.summary, self.codepage))?;
        // Stream columns: `<table>.<key>[.<key>…]`, beside the table.
        for table in &self.tables {
            for row in &table.rows {
                for cell in row {
                    let Cell::Bytes(bytes) = cell else { continue };
                    let key: Vec<String> = table
                        .columns
                        .iter()
                        .zip(row)
                        .filter(|(column, _)| column.key)
                        .map(|(_, cell)| match cell {
                            Cell::Str(text) => text.clone(),
                            Cell::Int(number) => number.to_string(),
                            _ => String::new(),
                        })
                        .collect();
                    let name = format!("{}.{}", table.name, key.join("."));
                    comp.create_stream(stream_name(&name, false))?
                        .write_all(bytes)?;
                }
            }
        }
        for (name, bytes) in &self.streams {
            comp.create_stream(stream_name(name, false))?
                .write_all(bytes)?;
        }
        comp.flush()?;
        Ok(comp.into_inner().into_inner())
    }
}

/// Strings once each, in the order they were met; ids from 1.
#[derive(Default)]
struct Pool {
    strings: Vec<(String, u16)>,
    ids: HashMap<String, u32>,
}

impl Pool {
    fn add(&mut self, text: &str) {
        if !self.ids.contains_key(text) {
            self.strings.push((text.to_owned(), 0));
            self.ids.insert(
                text.to_owned(),
                u32::try_from(self.strings.len()).unwrap_or(u32::MAX),
            );
        }
    }

    fn id(&self, text: &str) -> u32 {
        self.ids.get(text).copied().unwrap_or(0)
    }

    fn count(&mut self, text: &str) {
        let id = self.id(text);
        if let Some(entry) = usize::try_from(id)
            .ok()
            .and_then(|id| id.checked_sub(1))
            .and_then(|at| self.strings.get_mut(at))
        {
            entry.1 = entry.1.saturating_add(1);
        }
    }

    /// `_StringPool` (code page, then length and reference count per id) and
    /// `_StringData` (the strings back to back, in the code page).
    fn write(&self, codepage: ::msi::CodePage) -> (Vec<u8>, Vec<u8>) {
        let mut pool = Vec::new();
        let mut data = Vec::new();
        pool.extend_from_slice(&u32::try_from(codepage.id()).unwrap_or(1252).to_le_bytes());
        for (text, refs) in &self.strings {
            let bytes = codepage.encode(text);
            let length = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
            match u16::try_from(length) {
                Ok(short) => {
                    pool.extend_from_slice(&short.to_le_bytes());
                    pool.extend_from_slice(&refs.to_le_bytes());
                }
                Err(_) => {
                    // A string past 64 KiB: length 0, then the real length as a u32.
                    pool.extend_from_slice(&0_u16.to_le_bytes());
                    pool.extend_from_slice(&refs.to_le_bytes());
                    pool.extend_from_slice(&length.to_le_bytes());
                }
            }
            data.extend_from_slice(&bytes);
        }
        (pool, data)
    }
}

/// A table's rows, sorted by their stored key values, written column by column.
fn table_stream(table: &Table, pool: &Pool) -> std::io::Result<Vec<u8>> {
    let stored = |cell: &Cell, kind: Kind| -> u32 {
        match (cell, kind) {
            (Cell::Null, _) => 0,
            (Cell::Int(value), Kind::Int16) => u32::from((*value as u16) ^ 0x8000),
            (Cell::Int(value), _) => (*value as u32) ^ 0x8000_0000,
            (Cell::Str(text), _) => pool.id(text),
            (Cell::Bytes(_), _) => 1,
        }
    };
    let keys: Vec<usize> = table
        .columns
        .iter()
        .enumerate()
        .filter(|(_, column)| column.key)
        .map(|(at, _)| at)
        .collect();
    let mut order: Vec<&Vec<Cell>> = table.rows.iter().collect();
    order.sort_by_key(|row| {
        keys.iter()
            .filter_map(|&at| Some(stored(row.get(at)?, table.columns.get(at)?.kind)))
            .collect::<Vec<u32>>()
    });
    for pair in order.windows(2) {
        if let [a, b] = pair
            && keys.iter().all(|&at| a.get(at) == b.get(at))
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("{}: two rows share a key", table.name),
            ));
        }
    }
    let mut out = Vec::new();
    for (at, column) in table.columns.iter().enumerate() {
        for row in &order {
            let value = row.get(at).map_or(0, |cell| stored(cell, column.kind));
            match column.kind {
                Kind::Int16 => out.extend_from_slice(&(value as u16).to_le_bytes()),
                Kind::Int32 => out.extend_from_slice(&value.to_le_bytes()),
                Kind::Str(_) | Kind::Binary => out.extend_from_slice(&(value as u16).to_le_bytes()),
            }
        }
    }
    Ok(out)
}

/// A stream's name in the compound file: pairs of `[0-9A-Za-z._]` packed into one
/// character of 0x3800–0x47FF, a lone one into 0x4800–0x483F, anything else kept; tables
/// carry the prefix U+4840.
pub fn stream_name(name: &str, table: bool) -> String {
    let b64 = |ch: char| -> Option<u32> {
        match ch {
            '0'..='9' => Some(ch as u32 - '0' as u32),
            'A'..='Z' => Some(10 + ch as u32 - 'A' as u32),
            'a'..='z' => Some(36 + ch as u32 - 'a' as u32),
            '.' => Some(62),
            '_' => Some(63),
            _ => None,
        }
    };
    let mut out = String::new();
    if table {
        out.push('\u{4840}');
    }
    let mut chars = name.chars().peekable();
    while let Some(first) = chars.next() {
        let Some(low) = b64(first) else {
            out.push(first);
            continue;
        };
        let packed = match chars.peek().copied().and_then(b64) {
            Some(high) => {
                chars.next();
                0x3800 + (high << 6) + low
            }
            None => 0x4800 + low,
        };
        out.extend(char::from_u32(packed));
    }
    out
}

/// The summary information as an OLE property set: one section, properties by id.
fn summary_stream(mut properties: Vec<(u32, Property)>, codepage: ::msi::CodePage) -> Vec<u8> {
    properties.sort_by_key(|(id, _)| *id);
    let mut values: Vec<Vec<u8>> = Vec::new();
    for (_, value) in &properties {
        let mut bytes = Vec::new();
        match value {
            Property::I2(number) => {
                bytes.extend_from_slice(&2_u32.to_le_bytes());
                bytes.extend_from_slice(&number.to_le_bytes());
            }
            Property::I4(number) => {
                bytes.extend_from_slice(&3_u32.to_le_bytes());
                bytes.extend_from_slice(&number.to_le_bytes());
            }
            Property::Text(text) => {
                let mut encoded = codepage.encode(text);
                encoded.push(0);
                bytes.extend_from_slice(&30_u32.to_le_bytes());
                bytes.extend_from_slice(&u32::try_from(encoded.len()).unwrap_or(0).to_le_bytes());
                bytes.extend_from_slice(&encoded);
            }
        }
        while bytes.len() % 4 != 0 {
            bytes.push(0);
        }
        values.push(bytes);
    }
    let count = u32::try_from(properties.len()).unwrap_or(0);
    let mut section = Vec::new();
    let mut offset = 8 + 8 * count;
    let mut index = Vec::new();
    for ((id, _), value) in properties.iter().zip(&values) {
        index.extend_from_slice(&id.to_le_bytes());
        index.extend_from_slice(&offset.to_le_bytes());
        offset += u32::try_from(value.len()).unwrap_or(0);
    }
    section.extend_from_slice(&offset.to_le_bytes());
    section.extend_from_slice(&count.to_le_bytes());
    section.extend_from_slice(&index);
    for value in values {
        section.extend_from_slice(&value);
    }

    let mut out = Vec::new();
    out.extend_from_slice(&0xfffe_u16.to_le_bytes()); // byte order
    out.extend_from_slice(&0_u16.to_le_bytes()); // format version
    out.extend_from_slice(&10_u16.to_le_bytes()); // OS version
    out.extend_from_slice(&2_u16.to_le_bytes()); // Win32
    out.extend_from_slice(&[0; 16]); // class id
    out.extend_from_slice(&1_u32.to_le_bytes()); // one section
    out.extend_from_slice(&SUMMARY_FMTID);
    out.extend_from_slice(&48_u32.to_le_bytes());
    out.extend_from_slice(&section);
    out
}

#[cfg(test)]
mod tests {
    use super::{Cell, Column, Database, Kind, stream_name, text};
    use lepton_orchestrator::testing::Failure;
    use lepton_orchestrator::{assert_eq, ensure};

    #[test]
    fn stream_names_pack_like_the_installer() -> Result<(), Failure> {
        // `_StringPool`, as a real database names it (read from C:\Windows\Installer).
        assert_eq!(
            stream_name("_StringPool", true),
            "\u{4840}\u{3f3f}\u{4577}\u{446c}\u{3e6a}\u{44b2}\u{482f}"
        );
        assert_eq!(stream_name("lepton.cab", false).chars().count(), 5);
        Ok(())
    }

    #[test]
    fn rows_are_sorted_by_string_id_not_by_text() -> Result<(), Failure> {
        // The defect that made the `msi` crate's databases unreadable: "Property" sorts
        // before "_Validation" as text, after it by id. Here ids follow first use.
        let mut db = Database::new(::msi::CodePage::Windows1252);
        db.table("T", vec![Column::new("K", Kind::Str(72)).key()]);
        db.rows("T", vec![vec![text("zeta")], vec![text("Alpha")]])
            .map_err(|error| lepton_orchestrator::testing::fail("rows", error))?;
        let bytes = db
            .finish()
            .map_err(|error| lepton_orchestrator::testing::fail("finish", error))?;
        let package = ::msi::Package::open(std::io::Cursor::new(bytes))
            .map_err(|error| lepton_orchestrator::testing::fail("read back", error))?;
        ensure!(package.has_table("T"), "the table reads back");
        Ok(())
    }

    #[test]
    fn a_cell_that_does_not_fit_is_refused() -> Result<(), Failure> {
        let mut db = Database::new(::msi::CodePage::Windows1252);
        db.table(
            "T",
            vec![
                Column::new("K", Kind::Str(4)).key(),
                Column::new("N", Kind::Int16),
            ],
        );
        ensure!(
            db.rows("T", vec![vec![text("toolong"), Cell::Int(1)]])
                .is_err(),
            "over the length"
        );
        ensure!(
            db.rows("T", vec![vec![text("ok"), Cell::Int(70_000)]])
                .is_err(),
            "over i16"
        );
        ensure!(
            db.rows("T", vec![vec![Cell::Null, Cell::Int(1)]]).is_err(),
            "null in a non-nullable column"
        );
        ensure!(
            db.rows("T", vec![vec![text("ok"), Cell::Int(1)]]).is_ok(),
            "a row that fits"
        );
        Ok(())
    }
}
