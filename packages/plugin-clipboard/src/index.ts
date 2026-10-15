/**
 * `@lepton-desk/plugin-clipboard` — the system clipboard as text, from the core.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-clipboard-manager`: `writeText(text)` and
 * `readText()`. Unlike `navigator.clipboard`, neither needs a user gesture or a
 * permission prompt in the page: the application grants them instead, by listing
 * `clipboard.read_text` and `clipboard.write_text` under `permissions` in
 * `lepton.config.json`; an unlisted one rejects with reason `denied`.
 *
 * Like `navigator.clipboard`, both reject with a `NotAllowedError` `DOMException` while
 * the window is not focused. That is the compositor's rule, not this plugin's: Wayland
 * tells only the focused window what the selection is, and ignores a selection set
 * without a recent input from the window — measured, a write made before the window had
 * focus reported success and never reached another application.
 *
 * @module
 */

import { invoke } from "@lepton-desk/api/core";

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "clipboard.read_text": true;
    "clipboard.write_text": true;
  }
}

/** Every command this plugin adds, for `permissions`. */
export const commands = ["clipboard.read_text", "clipboard.write_text"] as const;

function requireFocus(): void {
  if (!document.hasFocus()) {
    throw new DOMException(
      "the window is not focused, and the compositor shares the clipboard only with the focused window",
      "NotAllowedError",
    );
  }
}

/**
 * Puts `text` on the system clipboard, where other applications can paste it.
 * Rejects with reason `failed` for text containing a NUL character, or in a native
 * (non-webview) application.
 */
export async function writeText(text: string): Promise<void> {
  requireFocus();
  await invoke("clipboard.write_text", new TextEncoder().encode(text));
}

/**
 * The clipboard's text, or `""` when it holds none (an image, or nothing at all).
 *
 * The compositor sends the selection a moment after the window gains focus (80–160 ms,
 * measured on COSMIC); a read inside that moment also answers `""`.
 */
export async function readText(): Promise<string> {
  requireFocus();
  return new TextDecoder().decode(await invoke("clipboard.read_text"));
}
