# @lepton-desk/plugin-clipboard

The system clipboard as text, from a Lepton core: `writeText(text)` and `readText()` —
the names Tauri's `@tauri-apps/plugin-clipboard-manager` uses.

```bash
pnpm add @lepton-desk/plugin-clipboard
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

**Focus.** The compositor shares the selection only with the focused window, and ignores a
selection set by a window that has not had input. So, like `navigator.clipboard`, both
functions reject with a `NotAllowedError` `DOMException` while `document.hasFocus()` is
false — at page load the window usually does not have focus yet (measured: it arrives
~30 ms later). After focus, the selection itself arrives a moment later (80–160 ms
measured); a read in that moment answers `""`.

Text containing a NUL character rejects with `InvokeError` reason `failed`, as do both
commands in a native (non-webview) application. Requires `lepton` 0.1.2 or newer.
