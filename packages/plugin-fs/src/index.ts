/**
 * `@lepton-desk/plugin-fs` — files inside the directories the application allows.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-fs`: `readTextFile`, `writeTextFile`,
 * `readFile`, `writeFile`, `readDir`, `mkdir`, `remove`, `rename`, `stat`, `exists`, and
 * `BaseDirectory` for paths relative to `$APPDATA`, `$DOCUMENT`, ….
 *
 * Two lists in `lepton.config.json` decide what a page may do. `permissions` names the
 * commands (`fs.read_file`, `fs.write_file`, …), and `"plugins": { "fs": { "scope": [...] } }`
 * names the directories — `"$APPDATA"`, `"$DOCUMENT/notes"` — with no wildcards. A path
 * outside every scope directory rejects with `InvokeError` reason `denied`, including one
 * reached through a symbolic link: the core opens every path with the kernel's
 * `RESOLVE_BENEATH`, so a link inside an allowed directory cannot lead out of it.
 *
 * One call carries at most 64 KiB (the core's request and reply limit). `readFile` reads a
 * larger file in pieces; `writeFile` writes one in pieces under a temporary name
 * (`<name>.lepton-save`) and renames it over the old file, so a write cut short leaves
 * the old file whole. Set `"chosen": true` in the `fs` settings and a folder or file the
 * user picks in `@lepton-desk/plugin-dialog` joins the scope, remembered across runs.
 *
 * @module
 */

import { InvokeError, invoke } from "@lepton-desk/api/core";

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "fs.read_file": true;
    "fs.write_file": true;
    "fs.read_dir": true;
    "fs.mkdir": true;
    "fs.remove": true;
    "fs.stat": true;
    "fs.exists": true;
    "fs.rename": true;
  }
}

/** Every command this plugin adds, for `permissions`. */
export const commands = [
  "fs.read_file",
  "fs.write_file",
  "fs.read_dir",
  "fs.mkdir",
  "fs.remove",
  "fs.stat",
  "fs.exists",
  "fs.rename",
] as const;

/** Directories a path may be relative to; the numbers are the core's (`core.paths.Base`). */
export const BaseDirectory = {
  /** `$XDG_DATA_HOME/<identifier>` — created on first use. */
  AppData: 1,
  /** `$XDG_CONFIG_HOME/<identifier>` — created on first use. */
  AppConfig: 2,
  /** `$XDG_CACHE_HOME/<identifier>` — created on first use. */
  AppCache: 3,
  Home: 4,
  /** The user's documents directory, as `user-dirs.dirs` names it (it may be localised). */
  Document: 5,
  Download: 6,
  Desktop: 7,
  Picture: 8,
  Music: 9,
  Video: 10,
} as const;
export type BaseDirectory = (typeof BaseDirectory)[keyof typeof BaseDirectory];

export interface PathOptions {
  /** The directory `path` is relative to; without it `path` must be absolute. */
  readonly baseDir?: BaseDirectory;
  readonly signal?: AbortSignal;
}

export interface WriteOptions extends PathOptions {
  /** Add to the end of the file instead of replacing it. */
  readonly append?: boolean;
}

export interface MkdirOptions extends PathOptions {
  /** Make missing parents too; an existing directory is then not an error. */
  readonly recursive?: boolean;
}

export interface DirEntry {
  readonly name: string;
  readonly isFile: boolean;
  readonly isDirectory: boolean;
  readonly isSymlink: boolean;
}

export interface FileInfo {
  readonly isFile: boolean;
  readonly isDirectory: boolean;
  readonly isSymlink: boolean;
  /** Bytes. */
  readonly size: number;
  readonly mtime: Date;
}

/** `Kind` in `zig/fs.zig`. */
const kind = { file: 1, directory: 2, symlink: 3 } as const;
/** `Flag` in `zig/plugin.zig`. */
const flag = { append: 1, recursive: 1, ranged: 2 } as const;

/**
 * Bytes sent in one `fs.write_file`: a request frame holds 64 KiB with its headers and the
 * path, so larger data goes in pieces of this size.
 */
const writePiece = 60 * 1024;

/** The temporary name a large file is written under before it replaces the real one. */
const savingSuffix = ".lepton-save";

const utf8 = new TextEncoder();

/** `[base u8][flags u8][path length u16 LE][path][body]` — `parse` in `zig/plugin.zig`. */
function request(path: string, options: PathOptions, flags = 0, body?: Uint8Array): Uint8Array {
  const encoded = utf8.encode(path);
  if (encoded.length > 0xffff) throw new RangeError("path is longer than 65535 bytes");
  const frame = new Uint8Array(4 + encoded.length + (body?.length ?? 0));
  const view = new DataView(frame.buffer);
  view.setUint8(0, options.baseDir ?? 0);
  view.setUint8(1, flags);
  view.setUint16(2, encoded.length, true);
  frame.set(encoded, 4);
  if (body !== undefined) frame.set(body, 4 + encoded.length);
  return frame;
}

function call(
  command: (typeof commands)[number],
  frame: Uint8Array,
  options: PathOptions,
): Promise<Uint8Array> {
  return invoke(command, frame, options.signal === undefined ? {} : { signal: options.signal });
}

/**
 * The file's bytes. A file larger than one reply (about 64 KiB) is read in pieces from
 * successive offsets, until a piece comes back empty.
 */
export async function readFile(path: string, options: PathOptions = {}): Promise<Uint8Array> {
  try {
    return await call("fs.read_file", request(path, options), options);
  } catch (error) {
    if (!(error instanceof InvokeError) || error.reason !== "too_large") throw error;
  }
  const pieces: Uint8Array[] = [];
  let offset = 0n;
  for (;;) {
    const at = new Uint8Array(8);
    new DataView(at.buffer).setBigUint64(0, offset, true);
    const piece = await call("fs.read_file", request(path, options, flag.ranged, at), options);
    if (piece.length === 0) break;
    pieces.push(piece);
    offset += BigInt(piece.length);
  }
  const whole = new Uint8Array(Number(offset));
  let filled = 0;
  for (const piece of pieces) {
    whole.set(piece, filled);
    filled += piece.length;
  }
  return whole;
}

/** The file's text, decoded as UTF-8. */
export async function readTextFile(path: string, options: PathOptions = {}): Promise<string> {
  return new TextDecoder().decode(await readFile(path, options));
}

/** Writes `data`, creating the file; replaces its contents unless `append`. */
export async function writeFile(
  path: string,
  data: Uint8Array,
  options: WriteOptions = {},
): Promise<void> {
  const append = options.append === true;
  if (data.length <= writePiece) {
    await call("fs.write_file", request(path, options, append ? flag.append : 0, data), options);
    return;
  }
  // Appending goes straight on; replacing writes a new file and renames it over the old,
  // so a write cut short leaves the old file whole.
  const target = append ? path : `${path}${savingSuffix}`;
  for (let at = 0; at < data.length; at += writePiece) {
    const piece = data.subarray(at, at + writePiece);
    const flags = append || at > 0 ? flag.append : 0;
    await call("fs.write_file", request(target, options, flags, piece), options);
  }
  if (!append) await rename(target, path, options);
}

/** Writes `text` as UTF-8, creating the file; replaces its contents unless `append`. */
export function writeTextFile(
  path: string,
  text: string,
  options: WriteOptions = {},
): Promise<void> {
  return writeFile(path, utf8.encode(text), options);
}

/** The directory's entries, sorted by name, without `.` and `..`. */
export async function readDir(path: string, options: PathOptions = {}): Promise<DirEntry[]> {
  const bytes = await call("fs.read_dir", request(path, options), options);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const decoder = new TextDecoder();
  const entries: DirEntry[] = [];
  for (let at = 0; at + 3 <= bytes.length; ) {
    const type = view.getUint8(at);
    const length = view.getUint16(at + 1, true);
    entries.push({
      name: decoder.decode(bytes.subarray(at + 3, at + 3 + length)),
      isFile: type === kind.file,
      isDirectory: type === kind.directory,
      isSymlink: type === kind.symlink,
    });
    at += 3 + length;
  }
  return entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/** Makes the directory. */
export async function mkdir(path: string, options: MkdirOptions = {}): Promise<void> {
  const flags = options.recursive === true ? flag.recursive : 0;
  await call("fs.mkdir", request(path, options, flags), options);
}

export interface RemoveOptions extends PathOptions {
  /** A directory with everything in it. Symbolic links inside are removed, not followed. */
  readonly recursive?: boolean;
}

/** Removes a file, a symbolic link (not its target) or a directory (empty, unless `recursive`). */
export async function remove(path: string, options: RemoveOptions = {}): Promise<void> {
  const flags = options.recursive === true ? flag.recursive : 0;
  await call("fs.remove", request(path, options, flags), options);
}

/**
 * Renames `from` to `to`, both relative to `options.baseDir` and inside one scope
 * directory; an existing file at `to` is replaced in one step.
 */
export async function rename(from: string, to: string, options: PathOptions = {}): Promise<void> {
  await call("fs.rename", request(from, options, 0, utf8.encode(to)), options);
}

/** What is at `path`; symbolic links inside the scope are followed. */
export async function stat(path: string, options: PathOptions = {}): Promise<FileInfo> {
  const bytes = await call("fs.stat", request(path, options), options);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const type = view.getUint8(0);
  return {
    isFile: type === kind.file,
    isDirectory: type === kind.directory,
    isSymlink: type === kind.symlink,
    size: Number(view.getBigUint64(1, true)),
    mtime: new Date(Number(view.getBigInt64(9, true))),
  };
}

/**
 * Whether something is at `path`. A path outside the scope rejects with `denied` rather
 * than answering `false`: the answer would tell the page what exists where it may not look.
 */
export async function exists(path: string, options: PathOptions = {}): Promise<boolean> {
  const bytes = await call("fs.exists", request(path, options), options);
  return bytes[0] === 1;
}
