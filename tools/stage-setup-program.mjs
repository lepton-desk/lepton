#!/usr/bin/env node
// Puts setup.exe's program into `packages/setup-windows-x64/` before `npm publish`
// (docs/yayin.md): built from `zig/src/setup/` with `zig build setup-exe`, or the file
// given, such as the `setup-program` artifact of a `windows` CI run.
//
//   node tools/stage-setup-program.mjs [path to setup.exe]
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
let source = process.argv[2];
if (!source) {
  const zig = execFileSync("zig", ["version"], { encoding: "utf8" }).trim();
  console.log(`building with zig ${zig}`);
  execFileSync("zig", ["build", "setup-exe"], { cwd: join(root, "zig"), stdio: "inherit" });
  source = join(root, "zig/zig-out/setup/setup.exe");
}
const bytes = readFileSync(source);
if (bytes.subarray(0, 2).toString("latin1") !== "MZ") {
  console.error(`${source} is not a Windows program`);
  process.exit(1);
}
const target = join(root, "packages/setup-windows-x64/setup.exe");
copyFileSync(source, target);
const digest = createHash("sha256").update(bytes).digest("hex");
console.log(`staged ${target}: ${bytes.length} bytes, sha256 ${digest}`);
