// The TypeScript names and the Zig registrations must be the same list: a command the
// page asks for by a name the core never registered is `unknown_command` at run time.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = (path: string): string => fileURLToPath(new URL(path, import.meta.url));

test("every TypeScript command is registered in plugin.zig, and only those", () => {
  const zig = readFileSync(here("../zig/plugin.zig"), "utf8");
  const registered = [...zig.matchAll(/\.name = "([^"]+)"/g)].map((match) => match[1]);
  const source = readFileSync(here("../src/index.ts"), "utf8");
  const list = /export const commands = \[([^\]]*)\]/s.exec(source)?.[1] ?? "";
  const declared = [...list.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(declared, registered);
  for (const name of registered) assert.match(source, new RegExp(`"${name}": true;`));
});

test("the Zig facts pass their own tests", () => {
  const output = execFileSync("zig", ["test", here("../zig/os.zig"), "-lc"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  assert.equal(typeof output, "string");
});
