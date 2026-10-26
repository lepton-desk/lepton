import { PHASE_DEVELOPMENT_SERVER } from "next/constants.js";
import lepton from "./lepton.config.json" with { type: "json" };

// `wasm.threads` in lepton.config.json: under `lepton dev` the page is cross-origin
// isolated, as the core makes it in a built app, so WebAssembly threads work in both.
const isolation = [
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
];

/** @type {(phase: string) => import("next").NextConfig} */
export default function config(phase) {
  return {
    // A static export: the window loads files from the binary's `share/<name>/dist`, and no
    // server runs beside it. `out/` is what `lepton.config.json` names as `frontend.dist`.
    output: "export",
    // The image optimiser is a server; an export has none.
    images: { unoptimized: true },
    // `next dev` only: an export has no server to send them, and a build warns about them.
    ...(phase === PHASE_DEVELOPMENT_SERVER && lepton.wasm?.threads
      ? { headers: async () => [{ source: "/:path*", headers: isolation }] }
      : {}),
  };
}
