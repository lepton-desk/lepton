#!/usr/bin/env node
// Compiles the Direct3D 11 shaders (`zig/src/render/gpu/d3d11/*.hlsl`) to the DXBC the core
// embeds, with the Windows SDK's fxc. The DXBC is kept in the repository beside its source
// (docs/plans/windows.md): no shader compiler is needed to build Lepton, and none at run
// time. `--check` compiles into a temporary directory and fails if any file differs from
// the one in the repository (the windows workflow runs it).
//
//   node tools/d3d11-shaders.mjs [--check]
//   FXC=<path to fxc.exe> overrides the newest one under the Windows SDK.
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const shaders = join(root, "zig/src/render/gpu/d3d11");
const check = process.argv.includes("--check");

/// Each output: the source, its entry point, the profile (shader model 4.0: feature level
/// 10_0, the floor that keeps Vista in reach), and the file the core embeds.
const outputs = [
  { source: "scene.hlsl", entry: "vs_main", profile: "vs_4_0", output: "scene_vs.dxbc" },
  { source: "scene.hlsl", entry: "ps_main", profile: "ps_4_0", output: "scene_ps.dxbc" },
];

function fxc() {
  if (process.env.FXC) return process.env.FXC;
  const kits = "C:\\Program Files (x86)\\Windows Kits\\10\\bin";
  if (!existsSync(kits)) fail(`no Windows SDK under ${kits}; set FXC to fxc.exe`);
  const versions = readdirSync(kits)
    .filter(
      (name) => /^10\.\d+\.\d+\.\d+$/.test(name) && existsSync(join(kits, name, "x64", "fxc.exe")),
    )
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  if (versions.length === 0) fail(`no x64\\fxc.exe under ${kits}; set FXC to fxc.exe`);
  return join(kits, versions[versions.length - 1], "x64", "fxc.exe");
}

function fail(message) {
  console.error(`d3d11-shaders: ${message}`);
  process.exit(1);
}

const compiler = fxc();
const into = check ? mkdtempSync(join(tmpdir(), "lepton-dxbc-")) : shaders;
let differ = 0;
try {
  for (const { source, entry, profile, output } of outputs) {
    const target = join(into, output);
    // Stripped of debug data and reflection: the bytes then depend only on the source
    // and these flags, not on the path the source was compiled from.
    execFileSync(
      compiler,
      [
        "/nologo",
        "/O3",
        "/Qstrip_debug",
        "/Qstrip_reflect",
        "/T",
        profile,
        "/E",
        entry,
        "/Fo",
        target,
        join(shaders, source),
      ],
      {
        stdio: ["ignore", "ignore", "inherit"],
      },
    );
    const bytes = readFileSync(target);
    if (check) {
      const kept = join(shaders, output);
      const same = existsSync(kept) && Buffer.compare(readFileSync(kept), bytes) === 0;
      if (!same) differ += 1;
      console.log(`${same ? "same  " : "DIFFER"} ${output} (${bytes.length} bytes)`);
    } else {
      console.log(`wrote ${output}: ${bytes.length} bytes (${profile} ${entry})`);
    }
  }
} finally {
  if (check) rmSync(into, { recursive: true, force: true });
}
if (differ > 0)
  fail(`${differ} shader(s) differ from their source: run node tools/d3d11-shaders.mjs`);
