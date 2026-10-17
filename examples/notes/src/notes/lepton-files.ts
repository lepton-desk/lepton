/**
 * The vault's files layer on `@lepton-desk/plugin-fs`, and the one setting the app keeps:
 * which folder the vault is.
 *
 * The folder comes from `@lepton-desk/plugin-dialog`; with `"chosen": true` in
 * `lepton.config.json` the core adds it to the fs scope and remembers it across runs, so
 * the paths below are absolute and reach only what the user picked (and `$APPDATA`).
 */

import { open } from "@lepton-desk/plugin-dialog";
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

/** `$APPDATA/vault.json`: `{ "root": "/home/…/Notes" }`. */
const settingsFile = "vault.json";

/** The folder picked last time, or null on the first run or after it was forgotten. */
export async function rememberedRoot(): Promise<string | null> {
  if (!(await exists(settingsFile, { baseDir: BaseDirectory.AppData }))) return null;
  try {
    const parsed: unknown = JSON.parse(
      await readTextFile(settingsFile, { baseDir: BaseDirectory.AppData }),
    );
    if (typeof parsed === "object" && parsed !== null && "root" in parsed) {
      const root = (parsed as { root: unknown }).root;
      return typeof root === "string" && root.startsWith("/") ? root : null;
    }
  } catch {
    // An unreadable settings file is the same as none: the user picks the folder again.
  }
  return null;
}

/** Asks for the vault folder and remembers it; null when the dialog is cancelled. */
export async function pickRoot(): Promise<string | null> {
  const root = await open({ directory: true, title: "Choose the notes folder" });
  if (root === null) return null;
  await writeTextFile(settingsFile, `${JSON.stringify({ root })}\n`, {
    baseDir: BaseDirectory.AppData,
  });
  return root;
}
