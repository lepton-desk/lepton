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
import { commandId, decodeReply, encodeRequest, wireLayout } from "./wire.ts";

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

/** Whether this page is running inside a Lepton window with `invoke` available. */
export function isLepton(): boolean {
  return wireLayout() !== undefined;
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
