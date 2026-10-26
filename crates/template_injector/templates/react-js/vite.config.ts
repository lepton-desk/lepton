import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import lepton from "./lepton.config.json" with { type: "json" };

// `wasm.threads` in lepton.config.json: under `lepton dev` the page is cross-origin
// isolated, as the core makes it in a built app, so WebAssembly threads work in both.
const config: { identifier: string; wasm?: { threads?: boolean } } = lepton;
const isolation = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

// Nothing else is needed. Vite 8 transforms through oxc rather than esbuild, and the
// React plugin already arranges the automatic JSX runtime — an `esbuild: { jsx }` block
// here is not merely redundant, it is reported as a conflicting option on every build.
export default defineConfig({
  plugins: [react()],
  server: { headers: config.wasm?.threads ? isolation : {} },
  build: { outDir: "dist", emptyOutDir: true },
});
