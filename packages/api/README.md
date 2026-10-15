# @lepton-desk/api

Call a Lepton core from the page. Familiar if you know `@tauri-apps/api`; different
underneath: **no JSON**. A request is one binary `wire` frame, the reply is one binary
frame, and every offset, command id and status name comes from the running core.

Zero dependencies, ESM only, explicit subpaths.

## `@lepton-desk/api/core`

```ts
import { invoke, InvokeError, isLepton } from "@lepton-desk/api/core";

const echoed = await invoke("core.ping", new TextEncoder().encode("hello"));
const protocol = await invoke("core.protocol"); // u32, little-endian
```

- `invoke(command, args?, options?) → Promise<Uint8Array>` — `args` is a `Uint8Array` or
  `ArrayBuffer`; `options.signal` aborts the request.
- Rejects with `InvokeError` (`command`, `status`): the core's status number and name
  (`malformed`, `unknown_command`, `too_large`), or `-1` when no reply arrived or the page
  is not in a Lepton window.
- `isLepton()` — whether `invoke` is available here.
- `encodeRequest` / `decodeReply` — the frame codec, exported for tests and tools.

| command | argument | result |
|---|---|---|
| `core.ping` | any bytes | the same bytes |
| `core.protocol` | none | wire protocol version, `u32` LE |
| `window.close` | none | none; the application closes |
| `window.minimize` / `window.maximize` / `window.unmaximize` | none | none |
| `window.state` | none | state bits, `u32` LE |

Every command — built-in or the application's own — runs only if it is listed under
`permissions` in `lepton.config.json`; otherwise it rejects with reason `denied`.
Application commands are registered in `src-lepton/main.zig` and their names reach
TypeScript through the generated `src/lepton-commands.d.ts`.

Requests are at most 64 KiB; larger data belongs on the shared-memory channel.

## `@lepton-desk/api/event`

```ts
import { listen } from "@lepton-desk/api/event";
const unlisten = await listen("app.saved", (event) => {
  console.log(event.name, event.sequence, event.payload); // payload: Uint8Array
});
unlisten();
```

Events come from the core's numbered log through one long-held request (no timer
polling, no JSON). Listening starts at "now". Built-in: `window.state`, `window.resized`.
The application declares its own in `src-lepton/main.zig` and emits them from Zig:

```zig
pub const events = core.webviewEvents.Declared(&.{"app.saved"});
_ = try events.emit(&view.bridge, "app.saved", bytes); // an undeclared name does not compile
```

Their names reach TypeScript in the generated `src/lepton-commands.d.ts`, so
`listen("app.svaed", …)` is a type error.

## `@lepton-desk/api/window`

```ts
import { maximize, onStateChanged, state, toggleMaximize } from "@lepton-desk/api/window";
await onStateChanged((s) => console.log(s.maximized, s.active));
await toggleMaximize();
```

`close`, `minimize`, `maximize`, `unmaximize`, `toggleMaximize`, `state()`,
`onStateChanged`, `onResized`.

## How it travels

`fetch("lepton://localhost/__lepton/invoke", { method: "POST", body: frame })`, answered
by the core's scheme handler. No `Content-Type` is sent, so a page served by the dev
server makes a CORS simple request and needs no preflight.

## Develop

```bash
cd ../../zig && zig build invoke-check   # the real handler the tests talk to
pnpm install && pnpm test && pnpm run check && pnpm run build
```
