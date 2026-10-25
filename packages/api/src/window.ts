/**
 * `@lepton-desk/api/window` — the application's window.
 *
 * Every function is an `invoke` of a built-in command, so each must be listed under
 * `permissions` in `lepton.config.json` (`window.close`, `window.minimize`,
 * `window.maximize`, `window.unmaximize`, `window.state`, `window.title`,
 * `window.start_drag`, `window.menu`). Listening to events needs no permission.
 *
 * @module
 */

import { invoke } from "./core.ts";
import { listen, type UnlistenFn } from "./event.ts";
import { decodeState, encodeMenu } from "./payloads.ts";

/**
 * The window's name now, as the system's title bar shows it: the page's `document.title`,
 * or `window.title` from `lepton.config.json` (the product's name without one) while the
 * page has none. The core keeps it, whatever the engine, so a title bar the page draws
 * itself can show it. Needs `window.title` under `permissions`.
 */
export async function title(): Promise<string> {
  return new TextDecoder().decode(await invoke("window.title"));
}

/**
 * Calls `handler` with the window's new name ({@link title}) whenever it changes: the page
 * set `document.title`, or cleared it. Resolves with a function that stops listening.
 */
export function onTitleChanged(handler: (title: string) => void): Promise<UnlistenFn> {
  return listen("window.title", (event) => handler(new TextDecoder().decode(event.payload)));
}

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
 * move (Linux WPE for now; Windows and Servo move it).
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
  const interactive =
    "button, a, input, select, textarea, [contenteditable], [data-no-drag], [data-window-control]";
  const press = (event: MouseEvent): void => {
    if (event.button !== 0 || (event.target as Element | null)?.closest(interactive)) return;
    // A window that cannot move or maximize from the page (WPE today) answers `failed`:
    // a press there is a press and nothing more, not an unhandled rejection each time.
    if (event.detail === 2) {
      toggleMaximize().catch(() => undefined);
      return;
    }
    startDragging().catch(() => undefined);
  };
  element.addEventListener("mousedown", press);
  return () => element.removeEventListener("mousedown", press);
}

/** What a `data-window-control` button does. */
export type WindowControl = "minimize" | "maximize" | "close";

/**
 * The three buttons of a title bar the page draws itself: every element under `root` with
 * `data-window-control="minimize"`, `"maximize"` or `"close"` minimizes, maximizes or
 * restores, or closes the window when clicked. `root` carries `data-maximized` while the
 * window is maximized, so CSS can show the restore icon then. Inside a `dragRegion` the
 * buttons stay buttons: a press on one does not move the window. Needs `window.minimize`,
 * `window.maximize`, `window.unmaximize`, `window.state` and `window.close` under
 * `permissions`. Returns a function that undoes this.
 */
export function windowControls(root: HTMLElement): () => void {
  const actions: Record<WindowControl, () => Promise<void>> = {
    minimize,
    maximize: toggleMaximize,
    close,
  };
  const click = (event: MouseEvent): void => {
    const control = (event.target as Element | null)?.closest<HTMLElement>("[data-window-control]");
    if (control === null || control === undefined || !root.contains(control)) return;
    const action = actions[control.dataset.windowControl as WindowControl];
    if (action === undefined) return;
    event.preventDefault();
    void action();
  };
  const show = (current: WindowState): void => {
    root.toggleAttribute("data-maximized", current.maximized);
  };
  root.addEventListener("click", click);
  let unlisten: UnlistenFn | undefined;
  let undone = false;
  void state().then(show, () => undefined);
  void onStateChanged(show).then((stop) => {
    if (undone) stop();
    else unlisten = stop;
  });
  return () => {
    undone = true;
    root.removeEventListener("click", click);
    unlisten?.();
  };
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
