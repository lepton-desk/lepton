/**
 * `@lepton-desk/api/permission` — answering what the page asks the engine for.
 *
 * When `lepton.config.json` sets a kind to `"ask"` in `webPermissions`
 * (`"webPermissions": { "camera": "ask" }`), the request comes here instead of being
 * decided: show your own prompt and return whether to allow it. `"allow"` and `"deny"`
 * never reach the page, and a kind not listed is denied. Answering needs
 * `permission.respond` in `permissions`; a request nobody answers is denied after a
 * minute.
 *
 * @module
 */

import { invoke } from "./core.ts";
import { type LeptonEvent, listen, type UnlistenFn } from "./event.ts";

/** What `webPermissions` can name. */
export type PermissionKind =
  | "notifications"
  | "camera"
  | "microphone"
  | "geolocation"
  | "pointer-lock"
  | "device-info"
  | "media-keys"
  | "storage-access"
  | "xr";

export interface PermissionRequest {
  readonly id: number;
  /** One kind, or two for a page asking for camera and microphone at once. */
  readonly kinds: readonly PermissionKind[];
}

/** Reads a `permission.request` event; `undefined` for any other event. */
export function decodePermissionRequest(event: LeptonEvent): PermissionRequest | undefined {
  if (event.name !== "permission.request") return undefined;
  const bytes = event.payload;
  const id = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
  const text = new TextDecoder().decode(bytes.subarray(4));
  return { id, kinds: text.split(",") as PermissionKind[] };
}

/** Answers request `id`. Rejects with `failed` when it is no longer waiting. */
export async function respond(id: number, allow: boolean): Promise<void> {
  const argument = new Uint8Array(5);
  new DataView(argument.buffer).setUint32(0, id, true);
  argument[4] = allow ? 1 : 0;
  await invoke("permission.respond", argument);
}

/** Calls `decide` for every request set to `"ask"` and answers with what it returns. */
export function onPermissionRequest(
  decide: (request: PermissionRequest) => boolean | Promise<boolean>,
): Promise<UnlistenFn> {
  return listen("permission.request", (event) => {
    const request = decodePermissionRequest(event);
    if (request === undefined) return;
    void Promise.resolve(decide(request)).then((allow) => respond(request.id, allow));
  });
}
