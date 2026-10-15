/**
 * `@lepton-desk/api/core` — call the core from the page.
 *
 * Familiar from Tauri: `invoke(command, args)` returns a promise of the result. Different
 * underneath: nothing is JSON. A request is one binary `wire` frame POSTed to the core's
 * own origin, and the reply is one binary frame back; arguments and results are bytes.
 * Every offset, kind number, command id and status name used here comes from the core's
 * Zig structs at the moment it built the page's transport (`globalThis.__lepton.layout`),
 * so this module cannot write a frame the core does not read.
 *
 * @module
 */

import { type BuiltinCommands, type StatusName, statusNames } from "./commands.gen.ts";

export { type BuiltinCommands, type StatusName, statusNames } from "./commands.gen.ts";

/**
 * An application's own commands, registered in its `main.zig`. Empty here; an
 * application adds its names by augmentation:
 *
 * ```ts
 * declare module "@lepton-desk/api/core" {
 *   interface AppCommands { "notes.save": true }
 * }
 * ```
 */
// biome-ignore lint/suspicious/noEmptyInterface: filled in by applications through declaration merging.
export interface AppCommands {}

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

/** A command name: the core's built-ins (generated from Zig) or the application's own. */
export type Command = keyof BuiltinCommands | keyof AppCommands;

/** Arguments are bytes; encode structured data yourself or with a typed helper. */
export type InvokeArgs = Uint8Array | ArrayBuffer;

export interface InvokeOptions {
  readonly signal?: AbortSignal;
}

/** Marks an `InvokeError` from any copy of this package (`Symbol.for` is global). */
const invokeErrorBrand: unique symbol = Symbol.for("@lepton-desk/api:InvokeError") as never;

/**
 * A reply whose status was not success, or a request the core never answered.
 *
 * `instanceof InvokeError` holds for an error thrown by any copy of this package. A
 * project with a linked plugin loads two copies (the plugin resolves its own), and a
 * class-identity check then said "no" — measured: a page waiting for `denied` from a
 * plugin's command never saw it. The check is a global brand instead.
 */
export class InvokeError extends Error {
  readonly command: string;
  /** The core's status number, or `-1` when no reply arrived. */
  readonly status: number;
  /** The status by name — `denied` when `permissions` does not list the command. */
  readonly reason: StatusName | "no_reply";
  readonly [invokeErrorBrand] = true;

  constructor(command: string, status: number, reason: StatusName | "no_reply", detail = "") {
    super(`${command}: ${reason}${detail === "" ? "" : ` (${detail})`}`);
    this.name = "InvokeError";
    this.command = command;
    this.status = status;
    this.reason = reason;
  }

  static [Symbol.hasInstance](value: unknown): boolean {
    return typeof value === "object" && value !== null && invokeErrorBrand in value;
  }
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

/** Whether this page is running inside a Lepton window with `invoke` available. */
export function isLepton(): boolean {
  return wireLayout() !== undefined;
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

let nextSequence = 1n;

/**
 * Calls `command` in the core with `args` and resolves with the result bytes.
 *
 * Rejects with {@link InvokeError} when the core answers with a failure status, when the
 * command is unknown to this core, or when no reply arrives.
 */
export async function invoke(
  command: Command,
  args: InvokeArgs = new Uint8Array(0),
  options: InvokeOptions = {},
): Promise<Uint8Array> {
  const layout = wireLayout();
  if (layout === undefined) {
    throw new InvokeError(command, -1, "no_reply", "not running inside a Lepton window");
  }
  const id = commandId(command);
  if (id === undefined) {
    throw new InvokeError(command, -1, "unknown_command", "not registered in this application");
  }
  const sequence = nextSequence;
  nextSequence += 1n;
  const bytes = args instanceof Uint8Array ? args : new Uint8Array(args);
  const frame = encodeRequest(layout, id, sequence, bytes);

  let answer: Response;
  try {
    // No `Content-Type`: a body-only POST is a CORS "simple" request, so a page on the
    // dev server reaches the core without a preflight the scheme handler would see.
    answer = await fetch(layout.invoke.url, {
      method: "POST",
      body: frame,
      cache: "no-store",
      signal: options.signal ?? null,
    });
  } catch (error) {
    throw new InvokeError(command, -1, "no_reply", String(error));
  }
  if (!answer.ok)
    throw new InvokeError(command, -1, "no_reply", `transport answered ${answer.status}`);

  const reply = decodeReply(layout, new Uint8Array(await answer.arrayBuffer()));
  if (reply.sequence !== sequence) {
    throw new InvokeError(command, -1, "no_reply", "reply belongs to another request");
  }
  if (reply.status !== 0) {
    const name = layout.invoke.statuses[String(reply.status)];
    throw new InvokeError(command, reply.status, isStatusName(name) ? name : "failed", name);
  }
  return reply.result;
}

const knownStatuses: ReadonlySet<string> = new Set(statusNames);

function isStatusName(name: string | undefined): name is StatusName {
  return name !== undefined && knownStatuses.has(name);
}
