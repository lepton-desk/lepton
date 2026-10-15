/**
 * `@lepton-desk/api/event` — events from the core.
 *
 * Familiar from Tauri: `listen(name, handler)` resolves with a function that stops
 * listening. Different underneath: each event is a binary `wire` frame (`notice`) with a
 * name and bytes, read from the core's numbered event log by one long-held request at a
 * time — nothing is polled on a timer, and nothing is JSON. Listening starts at "now": the
 * first request asks the core where its log stands, so earlier events are not replayed and
 * none written in between is missed. A reader that fell more than the log's capacity
 * behind sees the gap in `sequence`.
 *
 * Built-in events: `window.state` (state bits, `u32` LE — see `@lepton-desk/api/window`)
 * and `window.resized` (width, height: two `u32` LE).
 *
 * @module
 */

import type { BuiltinEvents } from "./commands.gen.ts";
import { type WireLayout, wireLayout } from "./core.ts";

export type { BuiltinEvents } from "./commands.gen.ts";

/**
 * An application's own events, declared in its `main.zig`
 * (`core.webviewEvents.Declared(&.{ "notes.saved" })`). Filled in by the generated
 * `src/lepton-commands.d.ts`; empty here.
 */
// biome-ignore lint/suspicious/noEmptyInterface: filled in by applications through declaration merging.
export interface AppEvents {}

/** An event name: the core's built-ins (generated from Zig) or the application's own. */
export type EventName = keyof BuiltinEvents | keyof AppEvents;

/** One event, as the core wrote it. */
export interface LeptonEvent {
  readonly name: string;
  readonly payload: Uint8Array;
  /** The event's number in the core's log; increases by one per event. */
  readonly sequence: bigint;
}

export type EventCallback = (event: LeptonEvent) => void;
export type UnlistenFn = () => void;

/** Reads back-to-back `notice` frames, refusing anything malformed. */
export function decodeEvents(layout: WireLayout, bytes: Uint8Array): LeptonEvent[] {
  const shape = layout.events;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const names = new TextDecoder();
  const out: LeptonEvent[] = [];
  let at = 0;
  while (at < bytes.byteLength) {
    if (at + layout.wireHeaderBytes + shape.noticeBytes > bytes.byteLength) {
      throw new RangeError("event frame shorter than its header");
    }
    if (view.getUint16(at + layout.wireProtocolOffset, true) !== layout.protocol) {
      throw new RangeError("event speaks another wire protocol version");
    }
    if (view.getUint16(at + layout.wireKindOffset, true) !== shape.kindNotice) {
      throw new RangeError("frame is not an event");
    }
    const payloadLen = view.getUint32(at + layout.invoke.headerPayloadLenOffset, true);
    const sequence = view.getBigUint64(at + layout.invoke.headerSequenceOffset, true);
    const body = at + layout.wireHeaderBytes;
    const nameLen = view.getUint16(body + shape.noticeNameLenOffset, true);
    const dataLen = view.getUint32(body + shape.noticeDataLenOffset, true);
    const nameAt = body + shape.noticeBytes;
    const end = body + payloadLen;
    if (end > bytes.byteLength || nameAt + nameLen + dataLen > end) {
      throw new RangeError("event runs past its frame");
    }
    out.push({
      name: names.decode(bytes.subarray(nameAt, nameAt + nameLen)),
      payload: bytes.subarray(nameAt + nameLen, nameAt + nameLen + dataLen),
      sequence,
    });
    at = end;
  }
  return out;
}

const listeners = new Map<string, Set<EventCallback>>();
let pumping = false;

/** Calls `handler` for every `name` event from now on. */
export async function listen(name: EventName, handler: EventCallback): Promise<UnlistenFn> {
  const layout = wireLayout();
  if (layout === undefined) throw new Error("not running inside a Lepton window");
  let set = listeners.get(name);
  if (set === undefined) {
    set = new Set();
    listeners.set(name, set);
  }
  set.add(handler);
  if (!pumping) {
    pumping = true;
    await startPump(layout);
  }
  return () => {
    const current = listeners.get(name);
    current?.delete(handler);
    if (current?.size === 0) listeners.delete(name);
  };
}

/** Learns where the log stands, then keeps one request open until the last listener goes. */
async function startPump(layout: WireLayout): Promise<void> {
  const latest = await fetch(`${layout.events.url}?after=latest`, { cache: "no-store" });
  const bytes = new Uint8Array(await latest.arrayBuffer());
  let after = new DataView(bytes.buffer).getBigUint64(0, true);
  void (async () => {
    while (listeners.size > 0) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), layout.events.holdMs);
      try {
        const answer = await fetch(`${layout.events.url}?after=${after}`, {
          cache: "no-store",
          signal: controller.signal,
        });
        for (const event of decodeEvents(layout, new Uint8Array(await answer.arrayBuffer()))) {
          after = event.sequence;
          for (const handler of listeners.get(event.name) ?? []) handler(event);
        }
      } catch {
        // An abort is the hold expiring; anything else is the core going away — wait
        // a moment rather than spin.
        if (!controller.signal.aborted) await new Promise((wake) => setTimeout(wake, 1000));
      } finally {
        clearTimeout(timer);
      }
    }
    pumping = false;
  })();
}
