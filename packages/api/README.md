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
| `window.start_drag` | none | none; the window follows the mouse (Windows, Servo; `failed` on Linux WPE for now) |
| `window.menu` | menu items (`encodeMenu`) | chosen id, `u16` LE, 0 dismissed (Windows, Servo; `failed` on Linux WPE for now) |
| `app.args` | none, or an `app.opened` number | arguments, each NUL-ended |

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
`onStateChanged`, `onResized`, `startDragging`, `dragRegion`, `windowControls`, `popupMenu`,
`title()`, `onTitleChanged`.

**Your own title bar.** `"window": { "decorations": false }` in `lepton.config.json`
removes the system's (Windows, where the window keeps its resize borders, shadow and snap;
Servo's X11 window, moved from the page; Linux WPE keeps its title bar for now):

```ts
import { close, dragRegion, minimize, toggleMaximize } from "@lepton-desk/api/window";
dragRegion(document.querySelector("#titlebar")); // press to move, double-click to maximize
```

Buttons inside the bar stay clickable; mark anything else that should not drag with
`data-no-drag`. CSS `app-region: drag` works too, in WebView2 (Windows) only.

The bar's three buttons — minimize, maximize/restore, close — are one call:

```html
<header id="titlebar">
  <span>My app</span>
  <button data-window-control="minimize">–</button>
  <button data-window-control="maximize">□</button>
  <button data-window-control="close">×</button>
</header>
```

```ts
import { dragRegion, windowControls } from "@lepton-desk/api/window";
const bar = document.querySelector<HTMLElement>("#titlebar");
if (bar) { dragRegion(bar); windowControls(bar); }
```

The application's name in the bar: `info()` (`@lepton-desk/api/app`) is `productName`,
`version` and `identifier`; `title()` is the window's name — `document.title`, or
`window.title` while the page has none, as the system's title bar shows it — and
`onTitleChanged` follows it. None of them needs a permission or waits: the core writes them
into the page before its scripts run.

```ts
import { info } from "@lepton-desk/api/app";
import { onTitleChanged, title } from "@lepton-desk/api/window";
const show = (name: string) => (label.textContent = `${info().name} — ${name}`);
show(title());
await onTitleChanged(show);
```

The bar carries `data-maximized` while the window is maximized (`#titlebar[data-maximized]`
for the restore icon). Needs `window.minimize`, `window.maximize`, `window.unmaximize`,
`window.state` and `window.close` under `permissions`. Measured on Windows 10 with real
clicks: each button minimizes, maximizes and restores, and closes (exit 0); the same run
clicks the system's own three buttons in a decorated window.

**Your own context menu.** A shipped application shows no browser menu: draw one in the
page from a `contextmenu` handler, or ask for the system's (Windows; Servo draws its own; Linux
WPE answers `failed` for now). `&` marks the access key on Windows; elsewhere it is
dropped, and `&&` is one `&`:

```ts
addEventListener("contextmenu", async (event) => {
  event.preventDefault();
  const id = await popupMenu([{ id: 1, label: "&Kopyala" }, { separator: true }, { id: 2, label: "Sil" }]);
});
```

**A title bar that follows the page.** Nothing to call: the system title bar takes the
page's `<meta name="theme-color">` and CSS `color-scheme` as they change — dark or
light on Windows 10, the colour itself on Windows 11.

## `@lepton-desk/api/app`

```ts
import { info, launchArgs, onOpened } from "@lepton-desk/api/app";
const { name, version, identifier } = info(); // from lepton.config.json, no waiting
const args = await launchArgs(); // needs app.args under permissions
await onOpened((later) => console.log(later)); // a second start's arguments
```

## `@lepton-desk/api/download`

```ts
import { onDownload } from "@lepton-desk/api/download";
await onDownload((d) => {
  if (d.kind === "finished") console.log("saved to", d.path);
});
```

A download goes to the user's download directory under the server's file name, made
safe and unique (`report (1).pdf`). Events: `started` (name), `progress` (received,
expected; at most four a second), `finished` (path), `failed` (message).

## `@lepton-desk/api/permission`

```json
"permissions": ["permission.respond"],
"webPermissions": { "notifications": "ask", "camera": "deny", "geolocation": "allow" }
```

```ts
import { onPermissionRequest } from "@lepton-desk/api/permission";
await onPermissionRequest(async ({ kinds }) => askInYourOwnDialog(kinds));
```

`webPermissions` decides what a page may ask the engine for: `allow`, `deny`, or `ask`,
which hands the request to `onPermissionRequest`. A kind not listed is denied, and a
request nobody answers is denied after a minute. Allowed notifications are shown by the
desktop. WebKit asks again on each request: remember an answer in the page if you want
to.

## How it travels

`fetch("lepton://localhost/__lepton/invoke", { method: "POST", body: frame })`, answered
by the core's scheme handler. No `Content-Type` is sent, so a page served by the dev
server makes a CORS simple request and needs no preflight.

## Develop

```bash
cd ../../zig && zig build invoke-check   # the real handler the tests talk to
pnpm install && pnpm test && pnpm run check && pnpm run build
```
