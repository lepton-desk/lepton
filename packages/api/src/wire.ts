/**
 * The transport's own shapes: where the core puts each field of a `wire` frame
 * (`globalThis.__lepton.layout`, written by the core from its Zig structs) and how a
 * request, a reply and an event are read and written. Internal: not one of the package's
 * entry points, so the shape can follow the transport — a page in a web view reaches the
 * core over its own scheme today, a native app's script (0.2.0) will not — without
 * changing `invoke` or `listen`.
 *
 * @module
 */

import type { LeptonEvent } from "./event.ts";

/** Where a request frame's fields are, as the core lays them out. */
export interface InvokeLayout {
  readonly url: string;
  readonly maxRequest: number;
  readonly kindRequest: number;
  readonly kindReply: number;
  readonly headerPayloadLenOffset: number;
  readonly headerSequenceOffset: number;
  readonly requestBytes: number;
  readonly requestCommandOffset: number;
  readonly requestArgumentLenOffset: number;
  readonly requestArgumentOffOffset: number;
  readonly replyBytes: number;
  readonly replySequenceOffset: number;
  readonly replyStatusOffset: number;
  readonly replyResultLenOffset: number;
  readonly replyResultOffOffset: number;
  /** Command name → id. */
  readonly commands: Readonly<Record<string, number>>;
  /** Status number → name; `0` is success. */
  readonly statuses: Readonly<Record<string, string>>;
}

/** Where an event frame's fields are, and the window-state bits events carry. */
export interface EventsLayout {
  readonly url: string;
  /** How long one events request stays open before the page asks again. */
  readonly holdMs: number;
  readonly kindNotice: number;
  readonly noticeBytes: number;
  readonly noticeNameLenOffset: number;
  readonly noticeDataLenOffset: number;
  readonly windowState: {
    readonly fullscreen: number;
    readonly maximized: number;
    readonly active: number;
  };
}

/** The part of the transport's layout this package reads. */
export interface WireLayout {
  readonly wireHeaderBytes: number;
  readonly wireProtocolOffset: number;
  readonly wireKindOffset: number;
  readonly protocol: number;
  readonly invoke: InvokeLayout;
  readonly events: EventsLayout;
}

interface LeptonGlobal {
  readonly layout: WireLayout;
  /** The application's command names and ids, written by the core at start-up. */
  readonly appCommands?: Readonly<Record<string, number>>;
}

/** The id of `command` in the running core: built-in from the layout, or the app's. */
export function commandId(command: string): number | undefined {
  const lepton: unknown = Reflect.get(globalThis, "__lepton");
  if (typeof lepton !== "object" || lepton === null) return undefined;
  const { layout, appCommands } = lepton as LeptonGlobal;
  return layout.invoke.commands[command] ?? appCommands?.[command];
}

/** The layout of the running core, or `undefined` outside a Lepton window. */
export function wireLayout(): WireLayout | undefined {
  const lepton: unknown = Reflect.get(globalThis, "__lepton");
  if (typeof lepton !== "object" || lepton === null) return undefined;
  const layout: unknown = Reflect.get(lepton, "layout");
  if (typeof layout !== "object" || layout === null || !("invoke" in layout)) return undefined;
  return (lepton as LeptonGlobal).layout;
}

/** Builds one request frame: `wire.Header`, `wire.Request`, argument bytes. */
export function encodeRequest(
  layout: WireLayout,
  command: number,
  sequence: bigint,
  args: Uint8Array,
): Uint8Array<ArrayBuffer> {
  const shape = layout.invoke;
  const payloadLen = shape.requestBytes + args.byteLength;
  const frame = new Uint8Array(layout.wireHeaderBytes + payloadLen);
  if (frame.byteLength > shape.maxRequest) {
    throw new RangeError(`request of ${frame.byteLength} bytes exceeds ${shape.maxRequest}`);
  }
  const view = new DataView(frame.buffer);
  view.setUint16(layout.wireProtocolOffset, layout.protocol, true);
  view.setUint16(layout.wireKindOffset, shape.kindRequest, true);
  view.setUint32(shape.headerPayloadLenOffset, payloadLen, true);
  view.setBigUint64(shape.headerSequenceOffset, sequence, true);
  const body = layout.wireHeaderBytes;
  view.setUint32(body + shape.requestCommandOffset, command, true);
  view.setUint32(body + shape.requestArgumentLenOffset, args.byteLength, true);
  view.setUint32(body + shape.requestArgumentOffOffset, shape.requestBytes, true);
  frame.set(args, body + shape.requestBytes);
  return frame;
}

/** A decoded reply frame. */
export interface Reply {
  readonly sequence: bigint;
  readonly status: number;
  readonly result: Uint8Array;
}

/** Reads one reply frame, refusing anything that is not a well-formed reply. */
export function decodeReply(layout: WireLayout, frame: Uint8Array): Reply {
  const shape = layout.invoke;
  if (frame.byteLength < layout.wireHeaderBytes + shape.replyBytes) {
    throw new RangeError(`reply of ${frame.byteLength} bytes is shorter than its header`);
  }
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  if (view.getUint16(layout.wireProtocolOffset, true) !== layout.protocol) {
    throw new RangeError("reply speaks another wire protocol version");
  }
  if (view.getUint16(layout.wireKindOffset, true) !== shape.kindReply) {
    throw new RangeError("frame is not a reply");
  }
  const body = layout.wireHeaderBytes;
  const resultLen = view.getUint32(body + shape.replyResultLenOffset, true);
  const resultOff = view.getUint32(body + shape.replyResultOffOffset, true);
  const start = body + resultOff;
  if (start + resultLen > frame.byteLength) {
    throw new RangeError("reply result runs past the frame");
  }
  return {
    sequence: view.getBigUint64(body + shape.replySequenceOffset, true),
    status: view.getUint32(body + shape.replyStatusOffset, true),
    result: frame.subarray(start, start + resultLen),
  };
}

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
