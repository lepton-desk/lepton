/**
 * The bytes of built-in commands and events: window state bits, a native menu, download
 * and permission events. Internal, for the public modules beside it; their layouts are
 * the core's (`menu.zig`, `downloads.zig`, `permissions.zig`) and may change with it.
 *
 * @module
 */

import type { DownloadEvent } from "./download.ts";
import type { LeptonEvent } from "./event.ts";
import type { PermissionKind, PermissionRequest } from "./permission.ts";
import type { MenuItem, WindowState } from "./window.ts";
import { wireLayout } from "./wire.ts";

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

const kinds = {
  "download.started": "started",
  "download.progress": "progress",
  "download.finished": "finished",
  "download.failed": "failed",
} as const;

/** Reads one `download.*` event's payload; `undefined` for any other event. */
export function decodeDownload(event: LeptonEvent): DownloadEvent | undefined {
  const kind = kinds[event.name as keyof typeof kinds];
  if (kind === undefined) return undefined;
  const bytes = event.payload;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const id = view.getUint32(0, true);
  if (kind === "progress") {
    return {
      kind,
      id,
      received: Number(view.getBigUint64(8, true)),
      expected: Number(view.getBigUint64(16, true)),
    };
  }
  const text = new TextDecoder().decode(bytes.subarray(4));
  if (kind === "started") return { kind, id, name: text };
  if (kind === "finished") return { kind, id, path: text };
  return { kind, id, message: text };
}

/** The four `download.*` event names. */
export const downloadEvents = Object.keys(kinds) as (keyof typeof kinds)[];

/** Reads a `permission.request` event; `undefined` for any other event. */
export function decodePermissionRequest(event: LeptonEvent): PermissionRequest | undefined {
  if (event.name !== "permission.request") return undefined;
  const bytes = event.payload;
  const id = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
  const text = new TextDecoder().decode(bytes.subarray(4));
  return { id, kinds: text.split(",") as PermissionKind[] };
}
