/**
 * `@lepton-desk/plugin-fs` — files inside the directories the application allows.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-fs`: `readTextFile`, `writeTextFile`,
 * `readFile`, `writeFile`, `readDir`, `mkdir`, `remove`, `stat`, `exists`, and
 * `BaseDirectory` for paths relative to `$APPDATA`, `$DOCUMENT`, ….
 *
 * Two lists in `lepton.config.json` decide what a page may do. `permissions` names the
 * commands (`fs.read_file`, `fs.write_file`, …), and `"plugins": { "fs": { "scope": [...] } }`
 * names the directories — `"$APPDATA"`, `"$DOCUMENT/notes"` — with no wildcards. A path
 * outside every scope directory rejects with `InvokeError` reason `denied`, including one
 * reached through a symbolic link: the core opens every path with the kernel's
 * `RESOLVE_BENEATH`, so a link inside an allowed directory cannot lead out of it.
 *
 * Each call carries at most 64 KiB (the core's request and reply limit); a larger file
 * rejects with reason `too_large`.
 *
 * @module
 */

import { invoke } from "@lepton-desk/api/core";

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "fs.read_file": true;
    "fs.write_file": true;
    "fs.read_dir": true;
    "fs.mkdir": true;
    "fs.remove": true;
    "fs.stat": true;
    "fs.exists": true;
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
const flag = { append: 1, recursive: 1 } as const;

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

/** The file's bytes. */
export function readFile(path: string, options: PathOptions = {}): Promise<Uint8Array> {
  return call("fs.read_file", request(path, options), options);
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
  const flags = options.append === true ? flag.append : 0;
  await call("fs.write_file", request(path, options, flags, data), options);
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

/** Removes a file, a symbolic link (not its target) or an empty directory. */
export async function remove(path: string, options: PathOptions = {}): Promise<void> {
  await call("fs.remove", request(path, options), options);
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
