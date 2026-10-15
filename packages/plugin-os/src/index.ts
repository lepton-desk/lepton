/**
 * `@lepton-desk/plugin-os` — facts about the machine, from the core.
 *
 * Familiar from Tauri's `@tauri-apps/plugin-os`: `platform()`, `arch()`, `family()`,
 * `version()`, `hostname()`, `locale()`, `exeExtension()`. Each is one `invoke` of a
 * command the plugin's Zig side registers (`zig/plugin.zig`), so each must be listed
 * under `permissions` in `lepton.config.json` — `os.platform`, `os.arch`, … — or it
 * rejects with reason `denied`.
 *
 * @module
 */

import { invoke } from "@lepton-desk/api/core";

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "os.platform": true;
    "os.arch": true;
    "os.family": true;
    "os.version": true;
    "os.hostname": true;
    "os.locale": true;
    "os.exe_extension": true;
  }
}

/** Every command this plugin adds, for `permissions`. */
export const commands = [
  "os.platform",
  "os.arch",
  "os.family",
  "os.version",
  "os.hostname",
  "os.locale",
  "os.exe_extension",
] as const;

const utf8 = new TextDecoder();

async function text(command: (typeof commands)[number]): Promise<string> {
  return utf8.decode(await invoke(command));
}

/** The platform the application was built for: `linux`, `windows`, `macos`, … */
export function platform(): Promise<string> {
  return text("os.platform");
}

/** The CPU architecture: `x86_64`, `aarch64`, … */
export function arch(): Promise<string> {
  return text("os.arch");
}

/** `unix` or `windows`. */
export function family(): Promise<string> {
  return text("os.family");
}

/** The kernel release, as `uname -r` reports it. */
export function version(): Promise<string> {
  return text("os.version");
}

/** The machine's host name. */
export function hostname(): Promise<string> {
  return text("os.hostname");
}

/** The user's locale as a BCP 47 tag (`tr-TR`), or `null` when none is set. */
export async function locale(): Promise<string | null> {
  const tag = await text("os.locale");
  return tag === "" ? null : tag;
}

/** `.exe` on Windows, empty elsewhere. */
export function exeExtension(): Promise<string> {
  return text("os.exe_extension");
}
