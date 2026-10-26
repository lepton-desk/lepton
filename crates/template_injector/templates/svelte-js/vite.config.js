import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";
import lepton from "./lepton.config.json" with { type: "json" };

// `wasm.threads` in lepton.config.json: under `lepton dev` the page is cross-origin
// isolated, as the core makes it in a built app, so WebAssembly threads work in both.
const isolation = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

// As `npm create vite` writes it (create-vite 9.2.1), plus the dev server's headers and the
// output directory `lepton` installs beside the binary.
export default defineConfig({
  plugins: [svelte()],
  server: { headers: lepton.wasm?.threads ? isolation : {} },
  build: { outDir: "dist", emptyOutDir: true },
});
