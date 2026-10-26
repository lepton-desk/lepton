import { defineConfig } from "astro/config";
import lepton from "./lepton.config.json" with { type: "json" };

// `wasm.threads` in lepton.config.json: under `lepton dev` the page is cross-origin
// isolated, as the core makes it in a built app, so WebAssembly threads work in both.
const isolation = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
};

export default defineConfig({
  server: { headers: lepton.wasm?.threads ? isolation : {} },
  // `lepton dev` has already told the core this port: a taken one must stop the server
  // rather than move it to the next one, where the window would never look.
  vite: { server: { strictPort: true } },
});
