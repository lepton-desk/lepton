# @lepton-desk/plugin-clipboard

The system clipboard as text, from a Lepton core: `writeText(text)` and `readText()` —
the names Tauri's `@tauri-apps/plugin-clipboard-manager` uses.

```bash
npm install @lepton-desk/plugin-clipboard   # or: pnpm add, yarn add, bun add
```

```ts
import { readText, writeText } from "@lepton-desk/plugin-clipboard";
await writeText("copied from Lepton");
console.log(await readText()); // "copied from Lepton"
```

Grant what the page uses in `lepton.config.json` — each command by name, no wildcards:

```json
{ "permissions": ["clipboard.read_text", "clipboard.write_text"] }
```

An unlisted command rejects with `InvokeError` reason `denied`.

On Linux the clipboard is WPE's (`WPEClipboardWayland` under Wayland), so text written here
is what other applications paste, and what they copy is read here.

**Focus.** The compositor tells a window what the selection is only once it has focus,
and ignores a selection set by a window without it — at page load the window usually has
no focus yet. So `writeText` waits until the window has focus, and `readText` waits until
the compositor has told the window what the selection is (it follows focus by tens of
milliseconds; measured, a read at page load answered after 71–162 ms). Once that has
happened neither waits. Pass `{ signal }` (an `AbortSignal`) to stop waiting.

On Windows the clipboard is the system's own: `writeText` writes at once, focused or not.

**Reading needs the user.** `readText` answers only just after the user pressed a key or
button in the window (on Windows: within 5 seconds, while one of the application's windows
is in front); otherwise it rejects with a `NotAllowedError` `DOMException`, as browsers do.
`"plugins": { "clipboard": { "read": "always" } }` lifts that for an application that
needs it.

Text containing a NUL character rejects with `InvokeError` reason `failed`, as do both
commands in a native (non-webview) application. Requires `lepton` 0.1.2 or newer.
