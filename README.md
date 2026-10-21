# Lepton

A desktop application framework: a **Zig core** (window, rendering, zero-copy IPC over
shared memory) and a **Rust CLI** (`lepton new | dev | run | build | package`). Your
frontend is a Vite project (or Astro, Next.js, Angular); Lepton puts it in a native window.
No browser ships with the app: it uses the system's web engine.

- **No JSON on the IPC path**: page ↔ core calls are binary `wire` frames, and their
  layout reaches TypeScript from the Zig structs at compile time.
- **Permissions are explicit**: a page may call only the commands listed in
  `lepton.config.json` (`"permissions"`), and an unknown name fails the build.
- **Pure native mode** (Linux): GLES with an shm/Cairo fallback, no web engine.

> **Status: beta.** Stable is **0.1.8** (Linux). **0.1.9** (in beta, `@beta` on npm) adds
> Windows. macOS is planned, not built. What was measured, and where, is in
> [`docs/durum.md`](docs/durum.md).

## Platforms

| | Linux | Windows 10 / 11 *0.1.9 beta* |
|---|---|---|
| Web engine | WPE WebKit 2.54+ (`wpe-platform`; never WebKitGTK). Servo, experimental, with `--servo` | WebView2, the runtime that comes with Windows (no `WebView2Loader.dll`) |
| Native render path | yes | not yet |
| Packages | `.tar.gz`, `.deb`, Arch `.pkg.tar.zst` | `.zip`, `.msi` (per user, no admin, written without WiX) |
| Plugins | `os`, `fs`, `clipboard`, `dialog` | the same four, measured end to end |
| Single instance, deep links (`deepLinks`) | yes (a unix socket; the desktop entry claims the scheme) | yes (a named pipe; the scheme is registered per user) |
| Your own title bar (`window.decorations: false`), moving it, native menus | Servo's X11 window; WPE: not yet (Lepton's own WPE platform, next) | yes: resize borders, snap and shadow stay |
| System title bar follows the page's `theme-color` / `color-scheme` | no (no compositor protocol for it) | dark/light on Windows 10; the colour itself on Windows 11 (measured on Server 2025, build 26100, by the `windows` workflow) |
| Small screens (1280 × 800 and below) | the window is centred (X11; Wayland places it itself) | the window is fitted to the work area and centred |

Windows 8.1, 8 and 7 are not supported: WebView2 stopped at 109 there and gets no
security fixes.

## Requirements

- Rust (stable), only to build the CLI from a checkout; npm ships it prebuilt.
- Zig **0.16 or 0.17**: the CLI takes `LEPTON_ZIG`, else the first of `zig`, `zig-0.17`,
  `zig-0.16` that is one of them (0.1.8 and older: 0.16 only).
- Node 20+ and any of npm, pnpm, Yarn or Bun.
- **Linux:** WPE WebKit 2.54+ with `wpe-platform` (`pkg-config wpe-webkit-2.0`) and
  libsoup 3, for webview apps. `lepton info` says what your distribution can install.
- **Windows:** the WebView2 runtime (part of Windows 10 and 11). Zig 0.16 or 0.17,
  for example through [zvm](https://github.com/tristanisham/zvm).

`lepton info` checks all of it.

### Arch Linux

The CLI is packaged for Arch as `lepton-desk` (built from source) and `lepton-desk-bin`
(the npm binary). Until they are on the AUR (new AUR accounts are closed for now), build
them from this repository. The packaged release (0.1.8) builds with Zig 0.16 only and Arch's
`zig` is 0.17, so the packages depend on the AUR's `zig0.16-bin`, installed beside the system Zig (`makepkg`
does not fetch AUR dependencies itself); pacman pulls in WPE WebKit:

```bash
paru -S zig0.16-bin
git clone https://github.com/lepton-desk/lepton.git
cd lepton/packaging/aur/lepton-desk-bin && makepkg -si
```

The command is installed as `lepton-desk` (`lepton-desk new my-app`), because the AUR's
`lepton` is Dropbox's JPEG compressor and owns `/usr/bin/lepton`. Inside a project the
`lepton` script runs the project's own CLI from `node_modules`, as with any install.

## Start

```bash
npm create lepton-app@latest     # 0.1.8, Linux
npm create lepton-app@beta       # 0.1.9 beta, Linux and Windows
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

Templates: `vanilla`, `react`, `vue`, `svelte`, `solid`, `preact`, `lit`, `astro` and
`next`, each `-ts` or `-js`, and `angular-ts`.

| command | what it does |
|---|---|
| `lepton dev` | the dev server with HMR + the core built once; frontend edits need no rebuild |
| `lepton run` | release build of the frontend and core, then the application |
| `lepton build` | the same, without starting it (`--windows` cross-compiles from Linux) |
| `lepton package` | the formats in `bundle.targets`; `--verify` unpacks and runs each |
| `lepton record` | opens the application and writes every command the page calls, and its reply, to a file |
| `lepton replay <file>` | runs a recording against the core again, with no window, and compares every reply |
| `lepton replay --page <file>` | opens the application and answers the page's calls from the recording |
| `lepton info` | the toolchain, the web engine and the display, and what is missing |

`lepton package --windows` on Linux writes the same `.zip` and `.msi` Windows does (both
writers are plain Rust). It is in the beta and not yet measured on Linux; a Windows
package is verified on Windows, never claimed from Linux.

## Recording a session

```bash
lepton record -o bug.lrec        # use the app, close it
lepton replay bug.lrec           # exit 1 if any reply changed
lepton replay --page bug.lrec    # the user's session again: the page live, the answers recorded
```

The page's calls are fixed-layout binary frames, so a recording replays byte for byte.
Commands that carry the user's data (file contents and paths, the clipboard, the host
name, the start arguments) are recorded with their sizes only; `--unmasked` keeps their
bytes too. A replay skips what it cannot run again — a masked command, a dialog the user
answered, a window command — and keeps the recorded reply. It gives the application an
empty home directory of its own, so a recorded `fs.remove` cannot reach your files.

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
import { dragRegion, maximize, popupMenu } from "@lepton-desk/api/window";

const name = new TextDecoder().decode(await invoke("app.name"));
await listen("window.state", (event) => console.log(event.payload));
await maximize();
const bar = document.querySelector<HTMLElement>("#titlebar");
if (bar) dragRegion(bar); // with "window": { "decorations": false }
const chosen = await popupMenu([{ id: 1, label: "Copy" }, { separator: true }, { id: 2, label: "Delete" }]);
```

Application commands and events are declared in `src-lepton/main.zig`; their names are
generated into `src/lepton-commands.d.ts` on every build, so a typo is a type error.
See [`packages/api`](packages/api/README.md).

## Repository

| path | |
|---|---|
| `zig/` | the core: IPC (`ipc/`), windows (`window/linux/`), rendering (`render/`), the engines (`render/webview/`: WPE, `webview2/`, `servo/`), the system layer (`platform/linux`, `platform/windows`) |
| `crates/cli` | the `lepton` command; `platform.rs` is the one place Linux and Windows differ |
| `crates/template_injector` | the templates and what Lepton adds to them |
| `crates/orchestrator` | toolchain discovery, process supervision |
| `crates/core_vendoring` | embeds the core into the CLI, so a new project builds offline |
| `packages/api` | `@lepton-desk/api` |
| `packages/cli`, `packages/cli-*` | `@lepton-desk/cli` (`npx lepton`) and its prebuilt binaries (`linux-x64`, `win32-x64`) |
| `packages/create-lepton-app` | `npm create lepton-app` |
| `packages/plugin-*` | plugins: `plugin-os`, `plugin-clipboard`, `plugin-fs`, `plugin-dialog` (TypeScript + Zig in one npm package, Linux and Windows halves) |
| `packages/servo-linux-x64` | the experimental Servo engine's library (built in CI) |
| `servo/` | Lepton's Servo bridge and the patches it carries |
| `.github/workflows` | `zig` (core and plugins on Zig 0.16 and 0.17), `servo-bridge`, `windows` (a template app built, measured, packaged and installed on Windows Server 2025) |

```bash
cargo test && cargo clippy --workspace --all-targets
(cd zig && zig build test && zig build test -Drender=native)   # Linux
```

On Windows, `zig build test` runs `zig/src/windows_tests.zig` (the native path is Linux
only); PowerShell 5.1 has no `&&`, so run the two commands one by one.

## License

MIT or Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE).
