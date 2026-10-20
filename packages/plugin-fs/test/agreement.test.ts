// The TypeScript side and the Zig side must agree on names and numbers: a command the
// core never registered is `unknown_command`, and a base directory with a different
// number is a different directory.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BaseDirectory } from "../src/index.ts";

/** The Zig Lepton builds with, as the CLI picks it: `LEPTON_ZIG`, else `zig-0.16`, else `zig`. */
function zig(): string {
  if (process.env.LEPTON_ZIG) return process.env.LEPTON_ZIG;
  try {
    execFileSync("zig-0.16", ["version"], { stdio: "ignore" });
    return "zig-0.16";
  } catch {
    return "zig";
  }
}

/** Linux tests link through LLD: Zig 0.16's own linker stops at glibc 2.44's `.sframe`. */
const lld = process.platform === "linux" ? ["-fllvm", "-flld"] : [];

const here = (path: string): string => fileURLToPath(new URL(path, import.meta.url));
const source = readFileSync(here("../src/index.ts"), "utf8");

test("every TypeScript command is registered in plugin.zig, and only those", () => {
  const zig = readFileSync(here("../zig/plugin.zig"), "utf8");
  const registered = [...zig.matchAll(/\.name = "([^"]+)"/g)].map((match) => match[1]);
  const list = /export const commands = \[([^\]]*)\]/s.exec(source)?.[1] ?? "";
  const declared = [...list.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(declared, registered);
  for (const name of registered) assert.match(source, new RegExp(`"${name}": true;`));
});

test("BaseDirectory numbers are the core's paths.Base", () => {
  const paths = readFileSync(here("../../../zig/src/platform/linux/paths.zig"), "utf8");
  const zigNumbers = Object.fromEntries(
    [...paths.matchAll(/^ {4}(\w+) = (\d+),/gm)].map((match) => [match[1], Number(match[2])]),
  );
  const names: Record<keyof typeof BaseDirectory, string> = {
    AppData: "app_data",
    AppConfig: "app_config",
    AppCache: "app_cache",
    Home: "home",
    Document: "document",
    Download: "download",
    Desktop: "desktop",
    Picture: "picture",
    Music: "music",
    Video: "video",
  };
  for (const [ts, zig] of Object.entries(names)) {
    assert.equal(BaseDirectory[ts as keyof typeof BaseDirectory], zigNumbers[zig], ts);
  }
});

test("entry kinds and flags match the Zig side", () => {
  const fs = readFileSync(here("../zig/fs.zig"), "utf8");
  assert.match(
    fs,
    /pub const Kind = enum\(u8\) \{ other = 0, file = 1, directory = 2, symlink = 3 \};/,
  );
  assert.match(source, /const kind = \{ file: 1, directory: 2, symlink: 3 \} as const;/);
  const plugin = readFileSync(here("../zig/plugin.zig"), "utf8");
  assert.match(plugin, /pub const append: u8 = 1;/);
  assert.match(plugin, /pub const recursive: u8 = 1;/);
  assert.match(plugin, /pub const ranged: u8 = 2;/);
  assert.match(source, /const flag = \{ append: 1, recursive: 1, ranged: 2 \} as const;/);
});

test("the Zig file operations pass their own tests, escapes included", () => {
  const output = execFileSync(zig(), ["test", here("../zig/fs.zig"), "-lc", ...lld], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(typeof output, "string");
});
