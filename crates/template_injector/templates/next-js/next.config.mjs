/** @type {import("next").NextConfig} */
const config = {
  // A static export: the window loads files from the binary's `share/<name>/dist`, and no
  // server runs beside it. `out/` is what `lepton.config.json` names as `frontend.dist`.
  output: "export",
  // The image optimiser is a server; an export has none.
  images: { unoptimized: true },
};

export default config;
