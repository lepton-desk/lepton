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
- Node 20+ and pnpm, for the frontend

## Start

```bash
cargo build --release --bin lepton
./target/release/lepton new my-app --template vue-ts --target webview
cd my-app && pnpm install && ../target/release/lepton dev
```

Templates: `vanilla-ts`, `vanilla-js`, `react-ts`, `react-js`, `vue-ts`, `svelte-ts`,
`solid-ts`.

| command | what it does |
|---|---|
| `lepton dev` | Vite with HMR + the core built once; frontend edits need no rebuild |
| `lepton run` | release build of the frontend and core, then the application |
| `lepton build` | the same, without starting it |
| `lepton package` | `.tar.gz`, Arch `.pkg.tar.zst`, `.deb` from `bundle.targets`; `--verify` unpacks and runs each |

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
| `packages/plugin-*` | plugins: `plugin-os`, `plugin-clipboard` (TypeScript + Zig in one npm package) |

```bash
cargo test && cargo clippy --workspace --all-targets
(cd zig && zig build test && zig build test -Drender=native)
```

## License

MIT or Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE).
