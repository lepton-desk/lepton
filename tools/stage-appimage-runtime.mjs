#!/usr/bin/env node
// Puts the AppImage type-2 runtime into `packages/appimage-runtime-linux-x64/` before
// `npm publish` (docs/yayin.md). The file is AppImage/type2-runtime release 20251108's
// `runtime-x86_64`, unchanged; it is refused unless its SHA-256 is that release's, the
// same digest `lepton package` checks (crates/cli/src/commands/appimage.rs).
//
//   node tools/stage-appimage-runtime.mjs <path to runtime-x86_64>
//
// The file is at https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SHA256 = "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = process.argv[2];
if (!source) {
  console.error("usage: node tools/stage-appimage-runtime.mjs <runtime-x86_64>");
  process.exit(2);
}
const bytes = readFileSync(source);
const digest = createHash("sha256").update(bytes).digest("hex");
if (digest !== SHA256) {
  console.error(`${source} has SHA-256 ${digest}, not type2-runtime 20251108's ${SHA256}`);
  process.exit(1);
}
const target = join(root, "packages/appimage-runtime-linux-x64/runtime-x86_64");
copyFileSync(source, target);
chmodSync(target, 0o755);
console.log(`staged ${target}: ${bytes.length} bytes, sha256 ${digest}`);
