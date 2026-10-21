/**
 * `@lepton-desk/api/window` — the application's window.
 *
 * Every function is an `invoke` of a built-in command, so each must be listed under
 * `permissions` in `lepton.config.json` (`window.close`, `window.minimize`,
 * `window.maximize`, `window.unmaximize`, `window.state`, `window.start_drag`, `window.menu`).
 *
 * @module
 */

import { invoke, wireLayout } from "./core.ts";
import { listen, type UnlistenFn } from "./event.ts";

/** The window's state, from WPE's toplevel state bits. */
export interface WindowState {
  readonly maximized: boolean;
  readonly fullscreen: boolean;
  /** The window has the focus. */
  readonly active: boolean;
}

/** Asks the application to close, as the titlebar's close button does. */
export async function close(): Promise<void> {
  await invoke("window.close");
}

/** Minimizes the window. On Wayland only the user can restore it. */
export async function minimize(): Promise<void> {
  await invoke("window.minimize");
}

export async function maximize(): Promise<void> {
  await invoke("window.maximize");
}

export async function unmaximize(): Promise<void> {
  await invoke("window.unmaximize");
}

/** Maximizes or restores, from the window's current state. */
export async function toggleMaximize(): Promise<void> {
  if ((await state()).maximized) await unmaximize();
  else await maximize();
}

/** Turns state bits into a `WindowState`, with the bit values the core supplies. */
export function decodeState(bits: number): WindowState {
  const layout = wireLayout();
  if (layout === undefined) throw new Error("not running inside a Lepton window");
  const shape = layout.events.windowState;
  return {
    maximized: (bits & shape.maximized) !== 0,
    fullscreen: (bits & shape.fullscreen) !== 0,
    active: (bits & shape.active) !== 0,
  };
}

export async function state(): Promise<WindowState> {
  const bytes = await invoke("window.state");
  return decodeState(new DataView(bytes.buffer, bytes.byteOffset).getUint32(0, true));
}

/** Calls `handler` whenever the window is maximized, restored, focused or unfocused. */
export function onStateChanged(handler: (state: WindowState) => void): Promise<UnlistenFn> {
  return listen("window.state", (event) =>
    handler(
      decodeState(new DataView(event.payload.buffer, event.payload.byteOffset).getUint32(0, true)),
    ),
  );
}

/** Calls `handler` with the window's new size, in logical pixels. */
export function onResized(
  handler: (size: { width: number; height: number }) => void,
): Promise<UnlistenFn> {
  return listen("window.resized", (event) => {
    const view = new DataView(
      event.payload.buffer,
      event.payload.byteOffset,
      event.payload.byteLength,
    );
    handler({ width: view.getUint32(0, true), height: view.getUint32(4, true) });
  });
}

/**
 * Starts moving the window with the mouse, as a press on a title bar does. For a page
 * that draws its own title bar (`"window": { "decorations": false }`): call it from a
 * `mousedown` while the button is down. Needs `window.start_drag` under `permissions`.
 * Rejects with reason `failed` where the platform does not let a window start its own
 * move (Linux for now).
 */
export async function startDragging(): Promise<void> {
  await invoke("window.start_drag");
}

/**
 * Makes `element` a title bar: a press on it (not on a button, link or field inside it)
 * moves the window, and a double click maximizes or restores it. Returns a function
 * that undoes this.
 */
export function dragRegion(element: HTMLElement): () => void {
  const interactive = "button, a, input, select, textarea, [contenteditable], [data-no-drag]";
  const press = (event: MouseEvent): void => {
    if (event.button !== 0 || (event.target as Element | null)?.closest(interactive)) return;
    if (event.detail === 2) {
      void toggleMaximize();
      return;
    }
    void startDragging();
  };
  element.addEventListener("mousedown", press);
  return () => element.removeEventListener("mousedown", press);
}

/** One entry of a native menu. */
export type MenuItem =
  | {
      /** What `popupMenu` resolves with when this item is chosen; 1 to 65535. */
      readonly id: number;
      readonly label: string;
      readonly disabled?: boolean;
      readonly checked?: boolean;
    }
  | { readonly separator: true };

const menuFlag = { separator: 1, disabled: 2, checked: 4 } as const;

/** The items as the core reads them (`zig/src/render/webview/menu.zig`). */
export function encodeMenu(items: readonly MenuItem[]): Uint8Array {
  if (items.length === 0 || items.length > 64) throw new RangeError("a menu has 1 to 64 items");
  const utf8 = new TextEncoder();
  const parts: number[] = [items.length];
  for (const item of items) {
    if ("separator" in item) {
      parts.push(0, 0, menuFlag.separator, 0, 0);
      continue;
    }
    if (!Number.isInteger(item.id) || item.id < 1 || item.id > 0xffff) {
      throw new RangeError(`menu item "${item.label}" needs an id from 1 to 65535`);
    }
    const label = utf8.encode(item.label);
    if (label.length === 0 || label.length > 256) {
      throw new RangeError("a menu label is 1 to 256 bytes");
    }
    const flags = (item.disabled ? menuFlag.disabled : 0) | (item.checked ? menuFlag.checked : 0);
    parts.push(
      item.id & 0xff,
      item.id >> 8,
      flags,
      label.length & 0xff,
      label.length >> 8,
      ...label,
    );
  }
  return Uint8Array.from(parts);
}

/**
 * Shows the system's own menu at the pointer — a context menu that looks and behaves like
 * every other application's — and resolves with the chosen item's `id`, or `null` when
 * the user dismissed it. Call it from a `contextmenu` handler after `preventDefault()`.
 * Needs `window.menu` under `permissions`. On Windows `&` before a letter makes it the
 * item's access key. Rejects with reason `failed` where there is no native menu (Linux
 * for now: draw the menu in the page there).
 */
export async function popupMenu(items: readonly MenuItem[]): Promise<number | null> {
  const reply = await invoke("window.menu", encodeMenu(items));
  const id = new DataView(reply.buffer, reply.byteOffset).getUint16(0, true);
  return id === 0 ? null : id;
}
