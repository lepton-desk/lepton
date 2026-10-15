# @lepton-desk/plugin-os

Facts about the machine, from a Lepton core: `platform()`, `arch()`, `family()`,
`version()`, `hostname()`, `locale()`, `exeExtension()` — the names Tauri's
`@tauri-apps/plugin-os` uses.

```bash
npm install @lepton-desk/plugin-os   # or: pnpm add, yarn add, bun add
```

```ts
import { arch, locale, platform } from "@lepton-desk/plugin-os";
console.log(await platform(), await arch(), await locale()); // "linux" "x86_64" "tr-TR"
```

Grant what the page uses in `lepton.config.json` — each command by name, no wildcards:

```json
{ "permissions": ["os.platform", "os.arch", "os.locale"] }
```

An unlisted command rejects with `InvokeError` reason `denied`.

## How a plugin is put together

The package carries both halves. `package.json` points at the Zig side —
`"lepton": { "plugin": "zig/plugin.zig" }` — and `lepton build`/`run`/`dev` find it among
the project's dependencies and compile it into the core (`-Dplugins`). `zig/plugin.zig`
exports `commands` (`core.webviewRegistry.PluginCommand`); `zig/os.zig` holds the facts
and is tested alone (`zig test zig/os.zig -lc`). Requires `lepton` 0.1.2 or newer.
