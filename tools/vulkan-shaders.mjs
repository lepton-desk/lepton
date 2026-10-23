#!/usr/bin/env node
// Compiles the Vulkan shaders (`zig/src/render/gpu/vulkan/*.vert|frag`) to the SPIR-V the core
// embeds, with Khronos's glslang. As with the Direct3D 11 shaders (`tools/d3d11-shaders.mjs`)
// the SPIR-V is kept in the repository beside its source: no shader compiler is needed to
// build Lepton, and none at run time. `--check` compiles into a temporary directory and fails
// if any file differs from the one in the repository (the windows workflow runs it).
//
//   node tools/vulkan-shaders.mjs [--check]
//   GLSLANG=<path to glslang> overrides `glslang` on PATH. Pinned: glslang 16.6.0 (the
//   release the kept SPIR-V was made with; another version may emit other bytes).
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const shaders = join(root, "zig/src/render/gpu/vulkan");
const check = process.argv.includes("--check");
const compiler = process.env.GLSLANG ?? "glslang";

/// Each output: the source and the file the core embeds. Vulkan 1.0's SPIR-V (1.0), the
/// floor the renderer is written for.
const outputs = [
	{ source: "scene.vert", output: "scene_vert.spv" },
	{ source: "scene.frag", output: "scene_frag.spv" },
];

function fail(message) {
	console.error(`vulkan-shaders: ${message}`);
	process.exit(1);
}

const into = check ? mkdtempSync(join(tmpdir(), "lepton-spirv-")) : shaders;
let differ = 0;
try {
	for (const { source, output } of outputs) {
		const target = join(into, output);
		// No `-g`: without debug information the bytes depend only on the source text and
		// these flags, not on the path it was compiled from.
		try {
			execFileSync(compiler, ["-V", "--target-env", "vulkan1.0", "-o", target, join(shaders, source)], {
				stdio: ["ignore", "ignore", "inherit"],
			});
		} catch (error) {
			fail(`${compiler} failed on ${source}: ${error.message}`);
		}
		const bytes = readFileSync(target);
		if (check) {
			const kept = join(shaders, output);
			const same = existsSync(kept) && Buffer.compare(readFileSync(kept), bytes) === 0;
			if (!same) differ += 1;
			console.log(`${same ? "same  " : "DIFFER"} ${output} (${bytes.length} bytes)`);
		} else {
			console.log(`wrote ${output}: ${bytes.length} bytes`);
		}
	}
} finally {
	if (check) rmSync(into, { recursive: true, force: true });
}
if (differ > 0) fail(`${differ} shader(s) differ from their source: run node tools/vulkan-shaders.mjs`);
