/**
 * `@lepton-desk/api/download` — files the page downloads.
 *
 * The core writes every download to the user's download directory (`~/Downloads`,
 * `~/İndirilenler`, …) under the server's file name, made safe and unique, and reports
 * it with four events. No permission is needed to listen.
 *
 * @module
 */

import { listen, type UnlistenFn } from "./event.ts";
import { decodeDownload, downloadEvents } from "./payloads.ts";

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

/** Calls `handler` for every download event: started, progress, finished, failed. */
export async function onDownload(handler: (event: DownloadEvent) => void): Promise<UnlistenFn> {
  const stops = await Promise.all(
    downloadEvents.map((name) =>
      listen(name, (event) => {
        const decoded = decodeDownload(event);
        if (decoded !== undefined) handler(decoded);
      }),
    ),
  );
  return () => {
    for (const stop of stops) stop();
  };
}
