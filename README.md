# Lepton

A desktop application framework: a **Zig core** (window, rendering, zero-copy IPC over
shared memory) and a **Rust CLI** (`lepton new | dev | run | build | package`). Your
frontend is a Vite project; Lepton puts it in a native window.

- **Linux webview: WPE WebKit**, through its `wpe-platform` API (2.54+). WebKitGTK is not used.
  Servo is planned as an optional second engine.
- **Pure native mode**: GLES with an shm/Cairo fallback, no web engine.
- **No JSON on the IPC path**: page ↔ core calls are binary `wire` frames, and their
  layout reaches TypeScript from the Zig structs at compile time.
- **Permissions are explicit**: a page may call only the commands listed in
  `lepton.config.json` (`"permissions"`), and an unknown name fails the build.

> Status: early. Linux (Wayland, X11 window) is the platform that works today; Windows
> and macOS back ends do not exist yet.

## Requirements (Linux)

- Rust (stable) and Zig 0.16
- WPE WebKit 2.54+ with `wpe-platform` (`pkg-config wpe-webkit-2.0`), libsoup 3
- Node 20+ and any of npm, pnpm, Yarn or Bun, for the frontend

## Start

```bash
npm create lepton-app@latest
```

`pnpm create lepton-app`, `yarn create lepton-app` and `bun create lepton-app` work the
same. The project uses the package manager you created it with, and so do `lepton dev`,
`lepton build` and `lepton run`: they read the lockfile.

A project has one script, `"lepton": "lepton"`, so every command runs through it:
`pnpm lepton dev`, `yarn lepton build`, `bun lepton record`, `npm run lepton dev`.
**With npm, put `--` before any flag**: `npm run lepton -- build --release`. npm keeps
flags for itself — an unknown one stops it ("Unknown cli flag"), and one it knows, like
`--json`, it takes silently, so `lepton` never sees it. pnpm, Yarn and Bun pass flags on.

From a checkout:

```bash
cargo build --release --bin lepton
./target/release/lepton new my-app --template vue-ts --target webview --plugins os,fs --install
```

Templates: `vanilla-ts`, `vanilla-js`, `react-ts`, `react-js`, `vue-ts`, `svelte-ts`,
`solid-ts`.

| command | what it does |
|---|---|
| `lepton dev` | Vite with HMR + the core built once; frontend edits need no rebuild |
| `lepton run` | release build of the frontend and core, then the application |
| `lepton build` | the same, without starting it |
| `lepton package` | `.tar.gz`, Arch `.pkg.tar.zst`, `.deb` from `bundle.targets`; `--verify` unpacks and runs each |
| `lepton record` | opens the application and writes every command the page calls, and its reply, to a file |
| `lepton replay <file>` | runs a recording against the core again, with no window, and compares every reply |
| `lepton replay --page <file>` | opens the application and answers the page's calls from the recording |

## Recording a session

```bash
lepton record -o bug.lrec        # use the app, close it
lepton replay bug.lrec           # exit 1 if any reply changed
lepton replay --page bug.lrec    # the user's session again: the page live, the answers recorded
```

The page's calls are fixed-layout binary frames, so a recording replays byte for byte.
Commands that carry the user's data (file contents and paths, the clipboard, the host
name) are recorded with their sizes only; `--unmasked` keeps their bytes too. A replay
skips what it cannot run again — a masked command, a dialog the user answered, a window
command — and keeps the recorded reply. It gives the application an empty home directory
of its own, so a recorded `fs.remove` cannot reach your files.

`--page` turns it around: the page runs live and each call gets the recorded answer — the
Nth call of a command the Nth recorded one, a dialog after its recorded delay, the events
the command emitted sent again. Window commands, masked calls and calls the recording
cannot answer run for real; a call with another argument, one more than recorded, or a
recorded call the page never made fails the replay. An application's event data is masked
like a private command's, so replay a page that waits for its events from an `--unmasked`
recording. The same binary records with `LEPTON_RECORD=<file>`, so a user can send you
a recording from a release build.

## Calling the core from the page

```ts
import { invoke } from "@lepton-desk/api/core";
import { listen } from "@lepton-desk/api/event";
import { maximize } from "@lepton-desk/api/window";

const name = new TextDecoder().decode(await invoke("app.name"));
await listen("window.state", (event) => console.log(event.payload));
await maximize();
```

Application commands and events are declared in `src-lepton/main.zig`; their names are
generated into `src/lepton-commands.d.ts` on every build, so a typo is a type error.
See [`packages/api`](packages/api/README.md).

## Repository

| path | |
|---|---|
| `zig/` | the core: IPC (`ipc/`), windows (`window/linux/`), rendering and the WPE bridge (`render/`) |
| `crates/cli` | the `lepton` command |
| `crates/template_injector` | the templates and what Lepton adds to them |
| `crates/orchestrator` | toolchain discovery, process supervision |
| `packages/api` | `@lepton-desk/api` |
| `packages/cli` | `@lepton-desk/cli` (`npx lepton`) |
| `packages/create-lepton-app` | `npm create lepton-app` |
| `packages/plugin-*` | plugins: `plugin-os`, `plugin-clipboard`, `plugin-fs`, `plugin-dialog` (TypeScript + Zig in one npm package) |

```bash
cargo test && cargo clippy --workspace --all-targets
(cd zig && zig build test && zig build test -Drender=native)
```

## License

MIT or Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE).
