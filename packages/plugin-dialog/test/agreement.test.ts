// The TypeScript side and the Zig side must agree on names and numbers.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

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

test("flags and outcomes match the Zig side", () => {
  const request = readFileSync(here("../zig/request.zig"), "utf8");
  assert.match(request, /pub const multiple: u8 = 1;/);
  assert.match(request, /pub const directory: u8 = 2;/);
  assert.match(source, /const flag = \{ multiple: 1, directory: 2 \} as const;/);
  const portal = readFileSync(here("../../../zig/src/platform/linux/portal.zig"), "utf8");
  assert.match(
    portal,
    /pub const Outcome = enum\(u8\) \{ chosen = 0, cancelled = 1, failed = 2 \};/,
  );
  assert.match(source, /const outcome = \{ chosen: 0, cancelled: 1 \} as const;/);
});

test("the request decoder passes its own tests", () => {
  const output = execFileSync("zig", ["test", here("../zig/request.zig")], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(typeof output, "string");
});
