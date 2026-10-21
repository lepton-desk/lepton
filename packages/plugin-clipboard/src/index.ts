/**
 * `@lepton-desk/plugin-clipboard` — the system clipboard as text, from the core.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-clipboard-manager`: `writeText(text)` and
 * `readText()`. The application grants them by listing `clipboard.read_text` and
 * `clipboard.write_text` under `permissions` in `lepton.config.json`; an unlisted one
 * rejects with reason `denied`.
 *
 * **Reading needs the user.** As with `navigator.clipboard`, `readText` answers only
 * within five seconds of the user pressing a key or button in the window; otherwise it
 * rejects with a `NotAllowedError` `DOMException`. The core decides this from the input it
 * sees, so a script that got into the page cannot read what the user copied elsewhere. An
 * application that must read without that, a clipboard manager, sets
 * `"plugins": { "clipboard": { "read": "always" } }`.
 *
 * **Focus.** Wayland tells a window what the selection is only once it has focus, and
 * ignores a selection set by a window without it. Measured: at page load the window has
 * no focus yet (it arrives ~30 ms later), a write made then reported success and never
 * reached another application, and a read answered `""` although another application
 * owned text. So both functions wait instead: `writeText` until the window has focus,
 * `readText` until the compositor has told the window what the selection is. Neither
 * waits once that has happened. Pass `{ signal }` to stop waiting.
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

export interface ClipboardOptions {
  /** Stops waiting for focus or for the selection; the call rejects with its reason. */
  readonly signal?: AbortSignal;
}

/** The first byte of a `clipboard.read_text` reply (`Known` in `zig/plugin.zig`). */
const notYet = 0;
const noInput = 2;
/** How long a focused window waits for the selection before giving up (measured: ≤ 160 ms). */
const selectionDeadlineMs = 2000;
const retryMs = 20;

function aborted(signal: AbortSignal | undefined): Promise<never> | undefined {
  if (signal?.aborted) return Promise.reject(signal.reason);
  return undefined;
}

/**
 * Whether the page runs in WebView2, which always gives it `chrome.webview`. The Windows
 * clipboard takes a write from a window without focus; Wayland ignores one (measured), which
 * is the only reason to wait.
 */
function inWebView2(): boolean {
  const chrome = (globalThis as { chrome?: { webview?: unknown } }).chrome;
  return typeof chrome?.webview === "object" && chrome.webview !== null;
}

/**
 * Resolves once `document.hasFocus()` is true — at once when it already is, or when the
 * system's clipboard does not need it (WebView2).
 */
function focused(signal: AbortSignal | undefined): Promise<void> {
  if (document.hasFocus() || inWebView2()) return Promise.resolve();
  return (
    aborted(signal) ??
    new Promise((resolve, reject) => {
      const done = (): void => {
        signal?.removeEventListener("abort", stop);
        resolve();
      };
      const stop = (): void => {
        window.removeEventListener("focus", done);
        reject(signal?.reason);
      };
      window.addEventListener("focus", done, { once: true });
      signal?.addEventListener("abort", stop, { once: true });
    })
  );
}

function pause(ms: number, signal: AbortSignal | undefined): Promise<void> {
  return (
    aborted(signal) ??
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        signal?.removeEventListener("abort", stop);
        resolve();
      }, ms);
      const stop = (): void => {
        clearTimeout(timer);
        reject(signal?.reason);
      };
      signal?.addEventListener("abort", stop, { once: true });
    })
  );
}

/**
 * Puts `text` on the system clipboard, where other applications can paste it. On Linux it
 * waits for the window to have focus first; on Windows it writes at once. Rejects with
 * reason `failed` for text containing a NUL
 * character, or in a native (non-webview) application.
 */
export async function writeText(text: string, options: ClipboardOptions = {}): Promise<void> {
  await focused(options.signal);
  await invoke("clipboard.write_text", new TextEncoder().encode(text), options);
}

/**
 * The clipboard's text, or `""` when it holds none (an image, or nothing at all).
 *
 * Until the compositor has told the window what the selection is, waits — for focus, and
 * then for the selection, which follows focus by tens of milliseconds. A focused window
 * that is not told within two seconds rejects with a `NotReadableError` `DOMException`.
 * Once told, a read answers at once, focused or not, with the last selection the window
 * saw.
 */
export async function readText(options: ClipboardOptions = {}): Promise<string> {
  let waited = 0;
  for (;;) {
    const reply = await invoke("clipboard.read_text", undefined, options);
    if (reply[0] === noInput) {
      throw new DOMException(
        "reading the clipboard needs the user to have just pressed a key or button in the window",
        "NotAllowedError",
      );
    }
    if (reply[0] !== notYet) return new TextDecoder().decode(reply.subarray(1));
    if (!document.hasFocus()) {
      await focused(options.signal);
      waited = 0;
    } else if (waited >= selectionDeadlineMs) {
      throw new DOMException(
        "the window has focus, but the compositor has not sent the clipboard's selection",
        "NotReadableError",
      );
    } else {
      await pause(retryMs, options.signal);
      waited += retryMs;
    }
  }
}
