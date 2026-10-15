# @lepton-desk/plugin-fs

Files inside the directories the application allows, from a Lepton core:
`readTextFile`, `writeTextFile`, `readFile`, `writeFile`, `readDir`, `mkdir`, `remove`,
`stat`, `exists` and `BaseDirectory` — the names Tauri's `@tauri-apps/plugin-fs` uses.

```bash
npm install @lepton-desk/plugin-fs   # or: pnpm add, yarn add, bun add
```

```ts
import { BaseDirectory, mkdir, readTextFile, writeTextFile } from "@lepton-desk/plugin-fs";
const app = { baseDir: BaseDirectory.AppData };
await mkdir("notes", { ...app, recursive: true });
await writeTextFile("notes/today.txt", "merhaba", app);
console.log(await readTextFile("notes/today.txt", app));
```

`lepton.config.json` grants two things: the commands, each by name, and the directories:

```json
{
  "permissions": ["fs.read_file", "fs.write_file", "fs.mkdir"],
  "plugins": { "fs": { "scope": ["$APPDATA", "$DOCUMENT/notes"] } }
}
```

A scope entry is a base directory — `$APPDATA` `$APPCONFIG` `$APPCACHE` `$HOME` `$DOCUMENT`
`$DOWNLOAD` `$DESKTOP` `$PICTURE` `$MUSIC` `$VIDEO` — optionally followed by plain names
below it. No wildcards, no `..`: a scope that breaks these rules fails the build. Without a
scope every path is refused.

- `$APPDATA`, `$APPCONFIG`, `$APPCACHE` are `$XDG_*_HOME/<identifier>`, created (mode 0700)
  on first use. The user directories come from `user-dirs.dirs`, so `$DOCUMENT` is
  `~/Belgeler` on a Turkish desktop.
- A path outside every scope directory rejects with `InvokeError` reason `denied` — also
  one that leaves through a symbolic link. Every path is opened with the kernel's
  `openat2(RESOLVE_BENEATH)`, so a link inside an allowed directory cannot lead out of it.
  `exists` answers `denied` there too, rather than telling the page what lies outside.
- One call moves at most 64 KiB; a larger file rejects with reason `too_large`.

Requires `lepton` 0.1.3 or newer (plugin settings) and Linux 5.6 or newer (`openat2`).
