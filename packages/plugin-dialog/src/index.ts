/**
 * `@lepton-desk/plugin-dialog` — the desktop's own file dialogs.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-dialog`: `open(options)` and `save(options)`
 * resolve with the chosen path(s), or `null` when the user cancels. The dialog is drawn by
 * the desktop through xdg-desktop-portal (COSMIC, GNOME, KDE each have one), so it looks
 * like the rest of the desktop and needs no toolkit in the application. The promise stays
 * pending while the dialog is open — for as long as the user takes.
 *
 * List `dialog.open` and `dialog.save` under `permissions` in `lepton.config.json`.
 *
 * A chosen path is not thereby readable through `@lepton-desk/plugin-fs`: that plugin
 * still answers only inside its own `scope`.
 *
 * @module
 */

import { invoke } from "@lepton-desk/api/core";

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "dialog.open": true;
    "dialog.save": true;
  }
}

/** Every command this plugin adds, for `permissions`. */
export const commands = ["dialog.open", "dialog.save"] as const;

export interface DialogFilter {
  /** Shown in the dialog: `"Images"`. */
  readonly name: string;
  /** File extensions without the dot: `["png", "jpg"]`. `"*"` matches everything. */
  readonly extensions: readonly string[];
}

interface CommonOptions {
  readonly title?: string;
  /** The folder the dialog starts in, absolute. */
  readonly defaultPath?: string;
  readonly filters?: readonly DialogFilter[];
  /** The accept button's label; the desktop's own when absent. */
  readonly acceptLabel?: string;
  readonly signal?: AbortSignal;
}

export interface OpenDialogOptions extends CommonOptions {
  /** Let the user choose several. The promise then resolves with an array. */
  readonly multiple?: boolean;
  /** Choose directories instead of files. */
  readonly directory?: boolean;
}

export interface SaveDialogOptions extends CommonOptions {
  /** The proposed file name. */
  readonly defaultName?: string;
}

/** `Flag` in `zig/request.zig`. */
const flag = { multiple: 1, directory: 2 } as const;
/** `Outcome` in the core's `portal.zig`: the first byte of the reply. */
const outcome = { chosen: 0, cancelled: 1 } as const;

const utf8 = new TextEncoder();

/** The request `zig/request.zig` decodes. */
function encode(flags: number, options: CommonOptions, currentName: string): Uint8Array {
  const parts: number[] = [flags];
  const string = (text: string): void => {
    const bytes = utf8.encode(text);
    if (bytes.length > 0xffff) throw new RangeError("a dialog string is longer than 65535 bytes");
    parts.push(bytes.length & 0xff, bytes.length >> 8, ...bytes);
  };
  string(options.title ?? "");
  string(options.acceptLabel ?? "");
  string(currentName);
  string(options.defaultPath ?? "");
  const filters = options.filters ?? [];
  if (filters.length > 16) throw new RangeError("at most 16 filters");
  parts.push(filters.length);
  for (const filter of filters) {
    if (filter.extensions.length === 0 || filter.extensions.length > 16) {
      throw new RangeError(`filter "${filter.name}" needs 1 to 16 extensions`);
    }
    string(filter.name);
    parts.push(filter.extensions.length);
    for (const extension of filter.extensions) string(extension === "*" ? "*" : `*.${extension}`);
  }
  return Uint8Array.from(parts);
}

/** The chosen paths, or `null` for a cancelled dialog. */
function decode(reply: Uint8Array): string[] | null {
  if (reply[0] === outcome.cancelled) return null;
  if (reply[0] !== outcome.chosen) throw new Error("the desktop's file dialog failed");
  const text = new TextDecoder().decode(reply.subarray(1));
  return text.split("\0").filter((path) => path !== "");
}

function run(
  command: (typeof commands)[number],
  frame: Uint8Array,
  signal: AbortSignal | undefined,
): Promise<Uint8Array> {
  return invoke(command, frame, signal === undefined ? {} : { signal });
}

/** Asks for files (or directories) to open. */
export async function open(
  options: OpenDialogOptions & { readonly multiple: true },
): Promise<string[] | null>;
export async function open(options?: OpenDialogOptions): Promise<string | null>;
export async function open(options: OpenDialogOptions = {}): Promise<string | string[] | null> {
  const flags =
    (options.multiple === true ? flag.multiple : 0) |
    (options.directory === true ? flag.directory : 0);
  const paths = decode(await run("dialog.open", encode(flags, options, ""), options.signal));
  if (paths === null) return null;
  return options.multiple === true ? paths : (paths[0] ?? null);
}

/** Asks where to save; the file itself is the application's to write. */
export async function save(options: SaveDialogOptions = {}): Promise<string | null> {
  const paths = decode(
    await run("dialog.save", encode(0, options, options.defaultName ?? ""), options.signal),
  );
  return paths?.[0] ?? null;
}
