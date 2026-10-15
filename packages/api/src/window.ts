/**
 * `@lepton-desk/api/window` — the application's window.
 *
 * Every function is an `invoke` of a built-in command, so each must be listed under
 * `permissions` in `lepton.config.json` (`window.close`, `window.minimize`,
 * `window.maximize`, `window.unmaximize`, `window.state`).
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
