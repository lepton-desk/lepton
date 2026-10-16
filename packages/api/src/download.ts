/**
 * `@lepton-desk/api/download` — files the page downloads.
 *
 * The core writes every download to the user's download directory (`~/Downloads`,
 * `~/İndirilenler`, …) under the server's file name, made safe and unique, and reports
 * it with four events. No permission is needed to listen.
 *
 * @module
 */

import { type LeptonEvent, listen, type UnlistenFn } from "./event.ts";

export type DownloadEvent =
  | { readonly kind: "started"; readonly id: number; readonly name: string }
  | {
      readonly kind: "progress";
      readonly id: number;
      readonly received: number;
      /** Zero when the server did not say how large the file is. */
      readonly expected: number;
    }
  | { readonly kind: "finished"; readonly id: number; readonly path: string }
  | { readonly kind: "failed"; readonly id: number; readonly message: string };

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

/** Calls `handler` for every download event: started, progress, finished, failed. */
export async function onDownload(handler: (event: DownloadEvent) => void): Promise<UnlistenFn> {
  const stops = await Promise.all(
    Object.keys(kinds).map((name) =>
      listen(name as keyof typeof kinds, (event) => {
        const decoded = decodeDownload(event);
        if (decoded !== undefined) handler(decoded);
      }),
    ),
  );
  return () => {
    for (const stop of stops) stop();
  };
}
