import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { manager, missing, newArguments, parse } from "../lib/plan.js";

test("the first bare word is the name; flag values are not", () => {
  const parsed = parse(["--template", "vue-ts", "Notes", "--plugins", "os,fs", "--no-install"]);
  assert.equal(parsed.name, "Notes");
  assert.equal(parsed.install, false);
  assert.deepEqual(parsed.rest, ["--template", "vue-ts", "--plugins", "os,fs"]);
  assert.deepEqual(newArguments("Notes", parsed), [
    "new",
    "Notes",
    "--template",
    "vue-ts",
    "--plugins",
    "os,fs",
  ]);
});

test("install is the default and not repeated", () => {
  const parsed = parse(["Notes"]);
  assert.deepEqual(newArguments("Notes", parsed), ["new", "Notes", "--install"]);
  const explicit = parse(["Notes", "--install"]);
  assert.deepEqual(newArguments("Notes", explicit), ["new", "Notes", "--install"]);
  assert.equal(parse([]).name, undefined);
});

test("what lepton info reports missing is listed, and nothing when ready", () => {
  const ready = JSON.stringify({
    tools: [{ name: "zig", version: "0.16.0", problem: null }],
    engine: [
      {
        label: "web engine (WPE WebKit)",
        package: "wpe-webkit-2.0",
        present: true,
      },
    ],
  });
  assert.deepEqual(missing(ready), []);
  const lacking = JSON.stringify({
    tools: [{ name: "zig", version: null, problem: "Missing" }],
    engine: [
      {
        label: "web engine (WPE WebKit)",
        package: "wpe-webkit-2.0",
        present: false,
      },
      { label: "X11 windows", package: "xcb", present: false },
    ],
  });
  assert.deepEqual(missing(lacking), [
    "zig: not usable (Missing)",
    "web engine (WPE WebKit): pkg-config cannot find wpe-webkit-2.0",
  ]);
  assert.equal(missing("not json").length, 1);
});

test("the manager that started the command is named", () => {
  assert.equal(manager("yarn/1.22.22 npm/? node/v26.11.1 linux x64"), "yarn");
  assert.equal(manager("bun/1.4.4 npm/? node/v24"), "bun");
  assert.equal(manager(undefined), "npm");
});

test("the flags passed through are the ones lepton new accepts", () => {
  // Every valued flag `parse` knows must exist on the real CLI, or a value would be
  // taken for the project name on one side and refused on the other.
  const binary = process.env.LEPTON_BINARY;
  if (binary === undefined) return;
  const help = execFileSync(binary, ["new", "--help"], { encoding: "utf8" });
  const source = readFileSync(fileURLToPath(new URL("../lib/plan.js", import.meta.url)), "utf8");
  const listed = /const valued = new Set\(\[([^\]]*)\]/s.exec(source)?.[1] ?? "";
  for (const flag of listed.matchAll(/"(--[a-z-]+)"/g)) assert.match(help, new RegExp(flag[1]));
});
