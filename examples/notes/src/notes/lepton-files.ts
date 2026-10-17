/**
 * The vault's files layer on `@lepton-desk/plugin-fs`, the app's settings, and the
 * dialogs and clipboard the screens use.
 *
 * A folder comes from `@lepton-desk/plugin-dialog`; with `"chosen": true` in
 * `lepton.config.json` the core adds it to the fs scope and remembers it across runs, so
 * a recent vault reopens without asking again. The paths below are absolute and reach
 * only what the user picked (and `$APPDATA`, where the settings live).
 */

import { writeText } from "@lepton-desk/plugin-clipboard";
import { open, save } from "@lepton-desk/plugin-dialog";
import {
  BaseDirectory,
  exists,
  mkdir,
  readDir,
  readTextFile,
  remove,
  rename,
  writeTextFile,
} from "@lepton-desk/plugin-fs";
import { rememberRecent } from "./helpers.ts";
import type { Files } from "./vault.ts";

export const leptonFiles: Files = {
  readDir: (path) => readDir(path),
  readTextFile: (path) => readTextFile(path),
  writeTextFile: (path, text) => writeTextFile(path, text),
  mkdir: (path, recursive) => mkdir(path, { recursive }),
  remove: (path, recursive) => remove(path, { recursive }),
  rename: (from, to) => rename(from, to),
  exists: (path) => exists(path),
};

export interface Settings {
  /** The vault open last, absolute. */
  readonly root: string | null;
  /** Vaults opened before, newest first, `root` included. */
  readonly recent: readonly string[];
}

/** `$APPDATA/vault.json`. */
const settingsFile = "vault.json";
const appData = { baseDir: BaseDirectory.AppData } as const;

const absolute = (value: unknown): value is string =>
  typeof value === "string" && value.startsWith("/");

/** The settings, or empty ones on the first run or when the file is unreadable. */
export async function loadSettings(): Promise<Settings> {
  const empty: Settings = { root: null, recent: [] };
  if (!(await exists(settingsFile, appData))) return empty;
  try {
    const parsed: unknown = JSON.parse(await readTextFile(settingsFile, appData));
    if (typeof parsed !== "object" || parsed === null) return empty;
    const { root, recent } = parsed as { root?: unknown; recent?: unknown };
    const list = Array.isArray(recent) ? recent.filter(absolute) : [];
    return absolute(root)
      ? { root, recent: rememberRecent(list, root) }
      : { root: null, recent: list };
  } catch {
    // An unreadable settings file is the same as none: the user picks the folder again.
    return empty;
  }
}

/** Records `root` as the open vault, first among the recent ones. */
export async function rememberRoot(root: string): Promise<Settings> {
  const settings: Settings = { root, recent: rememberRecent((await loadSettings()).recent, root) };
  await writeTextFile(settingsFile, `${JSON.stringify(settings)}\n`, appData);
  return settings;
}

/** Drops `root` from the recent list (it was moved, or its grant forgotten). */
export async function forgetRoot(root: string): Promise<Settings> {
  const before = await loadSettings();
  const settings: Settings = {
    root: before.root === root ? null : before.root,
    recent: before.recent.filter((other) => other !== root),
  };
  await writeTextFile(settingsFile, `${JSON.stringify(settings)}\n`, appData);
  return settings;
}

/** Asks for a vault folder; null when the dialog is cancelled. */
export function pickFolder(): Promise<string | null> {
  return open({ directory: true, title: "Choose the notes folder" });
}

/**
 * Asks where to save `text` and writes it there. The chosen file joins the scope through
 * the same `"chosen"` grant as a folder. Null when cancelled.
 */
export async function saveAs(defaultName: string, text: string): Promise<string | null> {
  const path = await save({
    title: "Export",
    defaultName,
    filters: [{ name: "HTML", extensions: ["html"] }],
  });
  if (path === null) return null;
  await writeTextFile(path, text);
  return path;
}

export function copyText(text: string): Promise<void> {
  return writeText(text);
}
