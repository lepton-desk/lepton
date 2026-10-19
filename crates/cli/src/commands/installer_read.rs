//! Reading an `.msi` this code wrote: its tables, its cabinet, and its install laid out
//! without `msiexec` — for `lepton package --verify` and the tests.

use std::io::Read as _;
use std::path::Path;

use super::CliError;
use super::archive::io;
use super::installer::CABINET;

/// Reads a written `.msi` back: its properties, for the tests.
#[cfg(test)]
pub fn properties(path: &Path) -> Result<Vec<(String, String)>, CliError> {
    let mut package = ::msi::open(path).map_err(|error| io(path, "read", &error))?;
    let rows = package
        .select_rows(::msi::Select::table("Property"))
        .map_err(|error| io(path, "read", &error))?;
    Ok(rows
        .filter(|row| row.len() >= 2)
        .map(|row| {
            let name = row[0].as_str().unwrap_or_default().to_owned();
            let value = row[1].as_str().unwrap_or_default().to_owned();
            (name, value)
        })
        .collect())
}

/// Lays a written `.msi`'s install out under `into` from its own tables and cabinet, as
/// `msiexec` would under `INSTALLDIR`, and returns that directory. Registers nothing: this
/// is `--verify`'s way in, and a check must not install an application on the machine.
pub fn extract(artifact: &Path, into: &Path) -> Result<std::path::PathBuf, CliError> {
    let bad = |what: &str| {
        CliError::Invalid(format!(
            "{} is not an installer this code wrote: {what}",
            artifact.display()
        ))
    };
    let mut package = ::msi::open(artifact).map_err(|error| io(artifact, "read", &error))?;
    let mut table = |name: &str| -> Result<Vec<Vec<String>>, CliError> {
        let rows = package
            .select_rows(::msi::Select::table(name))
            .map_err(|error| io(artifact, "read", &error))?;
        Ok(rows
            .map(|row| {
                (0..row.len())
                    .map(|at| row[at].as_str().unwrap_or_default().to_owned())
                    .collect()
            })
            .collect())
    };
    let directories = table("Directory")?;
    let components = table("Component")?;
    let files = table("File")?;
    let long = |name: &str| name.rsplit('|').next().unwrap_or(name).to_owned();

    // Each directory's path below INSTALLDIR, found by walking its parents.
    let path_of = |key: &str| -> Option<std::path::PathBuf> {
        let mut parts = Vec::new();
        let mut at = key.to_owned();
        while at != "INSTALLDIR" {
            let row = directories
                .iter()
                .find(|row| row.first().is_some_and(|k| *k == at))?;
            parts.push(long(row.get(2)?));
            at = row.get(1)?.clone();
        }
        let mut path = std::path::PathBuf::new();
        for part in parts.iter().rev() {
            path.push(part);
        }
        Some(path)
    };
    let product_dir = directories
        .iter()
        .find(|row| row.first().is_some_and(|key| key == "INSTALLDIR"))
        .and_then(|row| row.get(2))
        .map(|name| long(name))
        .ok_or_else(|| bad("no INSTALLDIR"))?;
    let root = into.join(product_dir);

    let cabinet = embedded_cabinet(artifact)?;
    let mut reader = cab::Cabinet::new(std::io::Cursor::new(cabinet))
        .map_err(|error| io(artifact, "read the cabinet of", &error))?;
    for file in &files {
        let (Some(key), Some(component), Some(name)) = (file.first(), file.get(1), file.get(2))
        else {
            return Err(bad("a short File row"));
        };
        let directory = components
            .iter()
            .find(|row| row.first().is_some_and(|c| c == component))
            .and_then(|row| row.get(2))
            .ok_or_else(|| bad(&format!("{key} has no component")))?;
        let relative = path_of(directory)
            .ok_or_else(|| bad(&format!("{directory} is not under INSTALLDIR")))?;
        let leaf = long(name);
        if leaf.contains(['/', '\\', ':']) || leaf == ".." {
            return Err(bad(&format!("{leaf:?} is not a file name")));
        }
        let target = root.join(&relative).join(&leaf);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| io(parent, "create", &error))?;
        }
        let mut bytes = Vec::new();
        reader
            .read_file(key)
            .and_then(|mut stream| stream.read_to_end(&mut bytes))
            .map_err(|error| io(artifact, &format!("read {key} from"), &error))?;
        std::fs::write(&target, &bytes).map_err(|error| io(&target, "write", &error))?;
    }
    Ok(root)
}

/// The cabinet's bytes, read back from a written `.msi`.
pub fn embedded_cabinet(path: &Path) -> Result<Vec<u8>, CliError> {
    let mut package = ::msi::open(path).map_err(|error| io(path, "read", &error))?;
    let mut stream = package
        .read_stream(CABINET)
        .map_err(|error| io(path, "read", &error))?;
    let mut bytes = Vec::new();
    stream
        .read_to_end(&mut bytes)
        .map_err(|error| io(path, "read", &error))?;
    Ok(bytes)
}
