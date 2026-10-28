#!/usr/bin/env node
import { execFileSync } from "node:child_process";
// Puts a CI-built `liblepton_servo.so` into `packages/servo-linux-x64/lib/` before
// `npm publish` (docs/yayin.md). The library comes from the `servo-bridge` workflow's
// `liblepton_servo` artifact (stripped, then xz-compressed); this checks it is an ELF
// shared object for x86-64 and names its size and SHA-256.
//
//   node tools/stage-servo.mjs <path to liblepton_servo.so or .so.xz>
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = process.argv[2];
if (!source) {
  console.error("usage: node tools/stage-servo.mjs <liblepton_servo.so[.xz]>");
  process.exit(2);
}
const lib = join(root, "packages/servo-linux-x64/lib");
mkdirSync(lib, { recursive: true });
const target = join(lib, "liblepton_servo.so");
if (source.endsWith(".xz")) {
  writeFileSync(target, execFileSync("xz", ["-dc", source], { maxBuffer: 1 << 30 }));
} else {
  copyFileSync(source, target);
}
chmodSync(target, 0o755);
const bytes = readFileSync(target);
// ELF, 64-bit, little-endian, ET_DYN, x86-64.
const elf = bytes.subarray(0, 4).toString("latin1") === "\x7fELF";
if (
  !elf ||
  bytes[4] !== 2 ||
  bytes[5] !== 1 ||
  bytes.readUInt16LE(16) !== 3 ||
  bytes.readUInt16LE(18) !== 62
) {
  console.error(`${source} is not an x86-64 ELF shared object`);
  process.exit(1);
}
const servo = join(root, "packages/servo-linux-x64");
copyFileSync(join(root, "servo/LICENSE-MPL"), join(servo, "LICENSE-MPL"));
const digest = createHash("sha256").update(bytes).digest("hex");
console.log(`staged ${target}: ${bytes.length} bytes, sha256 ${digest}`);
