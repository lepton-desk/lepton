//! The AppDir a Linux `.tar.gz` (and later the AppImage) is made of: the bundle as `usr/`,
//! and what lets it run and install from wherever it is unpacked.
//!
//! The AppImage specification's AppDir: `AppRun` (the entry point, a script here),
//! exactly one `<id>.desktop`, the icon named as its `Icon=` (`<id>.svg`) and `.DirIcon`,
//! a PNG (the 256 px one), all at the top; the bundle itself under `usr/`, where the
//! program finds its front end as `<exe>/../share/<name>/dist`. Beside them `install.sh`
//! and `uninstall.sh`: per user into `~/.local`, or with `--system` into `/usr/local`, and
//! out again file by file from the list the install wrote — the app's own data
//! (`~/.local/share/<identifier>`) is never touched.
//!
//! The scripts name only the binary (`[a-z0-9_-]`) and the identifier (`[A-Za-z0-9._-]`),
//! both safe unquoted in a shell; the product's name never reaches them.

use std::path::{Path, PathBuf};

use super::CliError;
use super::package::{MARKER, Spec, io};

/// The executable scripts at the AppDir's top. On Windows, which keeps no execute bit, the
/// archive marks them by these names (`archive.rs`).
pub const SCRIPTS: [&str; 3] = ["AppRun", "install.sh", "uninstall.sh"];

/// The AppDir's directory, beside the bundle: `<bundle>.AppDir`.
pub fn dir_name(bundle_name: &str) -> String {
    format!("{bundle_name}.AppDir")
}

/// Lays `bundle` out as an AppDir under `spec.out` and returns its directory. A previous one
/// is replaced only when it carries [`MARKER`].
pub fn lay_out(spec: &Spec, bundle: &Path, bundle_name: &str) -> Result<PathBuf, CliError> {
    let dir = spec.out.join(dir_name(bundle_name));
    if dir.exists() {
        if !dir.join(MARKER).is_file() {
            return Err(CliError::Invalid(format!(
                "{} exists and was not written by `lepton package`; move it away first",
                dir.display()
            )));
        }
        std::fs::remove_dir_all(&dir).map_err(|error| io(&dir, "remove", &error))?;
    }
    super::package_tree::copy_tree_skipping(bundle, &dir.join("usr"), &[MARKER])?;

    let share = dir.join("usr/share");
    let id = &spec.app_id;
    copy(
        &share.join("applications").join(format!("{id}.desktop")),
        &dir.join(format!("{id}.desktop")),
    )?;
    copy(
        &share
            .join("icons/hicolor/scalable/apps")
            .join(format!("{id}.svg")),
        &dir.join(format!("{id}.svg")),
    )?;
    // A copy, not a link: Lepton's archives carry only regular files and directories.
    copy(
        &share
            .join("icons/hicolor/256x256/apps")
            .join(format!("{id}.png")),
        &dir.join(".DirIcon"),
    )?;
    script(&dir.join("AppRun"), &app_run(&spec.binary))?;
    script(&dir.join("install.sh"), &install(&spec.binary, id))?;
    script(&dir.join("uninstall.sh"), &uninstall(&spec.binary, id))?;
    std::fs::write(dir.join(MARKER), format!("{bundle_name}\n"))
        .map_err(|error| io(&dir.join(MARKER), "write", &error))?;
    Ok(dir)
}

fn copy(from: &Path, to: &Path) -> Result<(), CliError> {
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|error| io(from, "copy", &error))
}

fn script(path: &Path, text: &str) -> Result<(), CliError> {
    std::fs::write(path, text).map_err(|error| io(path, "write", &error))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .map_err(|error| io(path, "chmod", &error))?;
    }
    Ok(())
}

/// `AppRun`: the program, from the directory this script is in.
pub fn app_run(binary: &str) -> String {
    format!(
        "#!/bin/sh\n\
         # Starts {binary} from this directory, wherever it was unpacked.\n\
         here=$(dirname \"$(readlink -f \"$0\")\")\n\
         exec \"$here/usr/bin/{binary}\" \"$@\"\n"
    )
}

/// The prefix the scripts take: `~/.local`, or `/usr/local` with `--system`.
const PREFIX: &str = "prefix=\"$HOME/.local\"\n\
case \"${1:-}\" in\n\
  --system) prefix=/usr/local ;;\n\
  \"\") ;;\n\
  *) echo \"usage: $0 [--system]\" >&2; exit 2 ;;\n\
esac\n";

/// The caches a desktop keeps of entries and icons, refreshed where the tools exist.
const CACHES: &str = "if command -v update-desktop-database >/dev/null 2>&1; then\n\
  update-desktop-database -q \"$prefix/share/applications\" || true\n\
fi\n\
if command -v gtk-update-icon-cache >/dev/null 2>&1; then\n\
  gtk-update-icon-cache -q -t \"$prefix/share/icons/hicolor\" || true\n\
fi\n";

/// `install.sh`: every file under `usr/` copied into the prefix, and the desktop entry's
/// `Exec` made absolute (a bare one needs the prefix's `bin` on `PATH`, which `~/.local/bin`
/// often is not). Two lists are kept for `uninstall.sh`: the files written, and the
/// directories that did not exist before (`share/icons/hicolor/48x48/apps` in a fresh home),
/// so that it removes those and leaves the ones that were there.
pub fn install(binary: &str, id: &str) -> String {
    format!(
        "#!/bin/sh\n\
         # Installs {binary} for this user (~/.local), or for everyone with --system\n\
         # (/usr/local). uninstall.sh removes exactly the files and directories this writes.\n\
         set -eu\n\
         {PREFIX}\
         here=$(dirname \"$(readlink -f \"$0\")\")\n\
         list=\"$prefix/share/{binary}/installed-files\"\n\
         dirs=\"$prefix/share/{binary}/installed-dirs\"\n\
         if [ -f \"$list\" ]; then\n\
         \x20 echo \"{binary} is already installed in $prefix; run uninstall.sh first\" >&2\n\
         \x20 exit 1\n\
         fi\n\
         files=$(mktemp)\n\
         made=$(mktemp)\n\
         trap 'rm -f \"$files\" \"$made\"' EXIT\n\
         cd \"$here/usr\"\n\
         find . -type f | sort | while IFS= read -r file; do\n\
         \x20 target=\"$prefix/${{file#./}}\"\n\
         \x20 dir=$(dirname \"$target\")\n\
         \x20 while [ ! -d \"$dir\" ]; do\n\
         \x20   printf '%s\\n' \"$dir\" >>\"$made\"\n\
         \x20   dir=$(dirname \"$dir\")\n\
         \x20 done\n\
         \x20 mkdir -p \"$(dirname \"$target\")\"\n\
         \x20 cp -p \"$file\" \"$target\"\n\
         \x20 printf '%s\\n' \"$target\" >>\"$files\"\n\
         done\n\
         entry=\"$prefix/share/applications/{id}.desktop\"\n\
         sed \"s|^Exec={binary}|Exec=\\\"$prefix/bin/{binary}\\\"|\" \"$entry\" >\"$entry.new\"\n\
         mv \"$entry.new\" \"$entry\"\n\
         printf '%s\\n%s\\n' \"$list\" \"$dirs\" >>\"$files\"\n\
         cp \"$files\" \"$list\"\n\
         sort -u \"$made\" >\"$dirs\"\n\
         {CACHES}\
         echo \"{binary} installed in $prefix\"\n"
    )
}

/// `uninstall.sh`: the files `install.sh` listed, then the directories it made, deepest
/// first and only once empty.
pub fn uninstall(binary: &str, id: &str) -> String {
    format!(
        "#!/bin/sh\n\
         # Removes what install.sh wrote for {binary}, and nothing else: directories that were\n\
         # there before stay, and so does the app's own data (~/.local/share/{id}).\n\
         set -eu\n\
         {PREFIX}\
         list=\"$prefix/share/{binary}/installed-files\"\n\
         dirs=\"$prefix/share/{binary}/installed-dirs\"\n\
         if [ ! -f \"$list\" ]; then\n\
         \x20 echo \"{binary} is not installed in $prefix\" >&2\n\
         \x20 exit 1\n\
         fi\n\
         made=$(mktemp)\n\
         trap 'rm -f \"$made\"' EXIT\n\
         if [ -f \"$dirs\" ]; then\n\
         \x20 sort -r \"$dirs\" >\"$made\"\n\
         fi\n\
         while IFS= read -r file; do\n\
         \x20 rm -f \"$file\"\n\
         done <\"$list\"\n\
         {CACHES}\
         # A child sorts after its parent, so in reverse it is removed first. A desktop cache\n\
         # left alone in a directory install.sh made was written for this app only.\n\
         while IFS= read -r dir; do\n\
         \x20 for cache in mimeinfo.cache icon-theme.cache; do\n\
         \x20   if [ \"$(ls -A \"$dir\" 2>/dev/null)\" = \"$cache\" ]; then\n\
         \x20     rm -f \"$dir/$cache\"\n\
         \x20   fi\n\
         \x20 done\n\
         \x20 rmdir \"$dir\" 2>/dev/null || true\n\
         done <\"$made\"\n\
         echo \"{binary} removed from $prefix\"\n"
    )
}

#[cfg(test)]
mod tests {
    use super::{app_run, install, uninstall};
    use lepton_orchestrator::assert_contains;
    use lepton_orchestrator::testing::Failure;

    #[test]
    fn the_scripts_name_the_binary_and_the_identifier() -> Result<(), Failure> {
        let run = app_run("notes");
        assert_contains!(&run, "#!/bin/sh\n");
        assert_contains!(&run, "exec \"$here/usr/bin/notes\" \"$@\"\n");
        let put = install("notes", "dev.example.notes");
        assert_contains!(&put, "list=\"$prefix/share/notes/installed-files\"\n");
        assert_contains!(
            &put,
            "entry=\"$prefix/share/applications/dev.example.notes.desktop\"\n"
        );
        assert_contains!(&put, "--system) prefix=/usr/local ;;");
        assert_contains!(&put, "dirs=\"$prefix/share/notes/installed-dirs\"\n");
        let take = uninstall("notes", "dev.example.notes");
        assert_contains!(&take, "done <\"$list\"\n");
        assert_contains!(&take, "sort -r \"$dirs\" >\"$made\"\n");
        assert_contains!(&take, "own data (~/.local/share/dev.example.notes).");
        Ok(())
    }
}
