# @lepton-desk/plugin-dialog

The desktop's own file dialogs, from a Lepton core: `open(options)` and `save(options)` —
the names Tauri's `@tauri-apps/plugin-dialog` uses.

```bash
pnpm add @lepton-desk/plugin-dialog
```

```ts
import { open, save } from "@lepton-desk/plugin-dialog";
const file = await open({ title: "Open notes", filters: [{ name: "Text", extensions: ["txt", "md"] }] });
const files = await open({ multiple: true }); // string[] | null
const target = await save({ defaultName: "notes.txt" });
```

Each resolves with the chosen path(s), or `null` when the user cancels. The promise stays
pending while the dialog is open, for as long as the user takes; `{ signal }` stops waiting.
`save` only asks where — writing the file is the application's job.

List the commands in `lepton.config.json`:

```json
{ "permissions": ["dialog.open", "dialog.save"] }
```

The dialog is drawn by the desktop through xdg-desktop-portal (`FileChooser`), so it looks
like the rest of the desktop and the application links no toolkit. Up to eight dialogs may
be open at once. In a native (non-webview) application both commands reject with `failed`.

A chosen path is not thereby readable through `@lepton-desk/plugin-fs`, which still answers
only inside its own `scope`.

Known: on COSMIC (`xdg-desktop-portal-cosmic` 1.9.0) a dialog stays open after its
application exits — the backend answers the portal's `Request.Close` with `UnknownObject`.
Lepton sends the close; the backend does not act on it.

Requires `lepton` 0.1.3 or newer.
