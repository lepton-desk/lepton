import preact from "@preact/preset-vite";
import { defineConfig } from "vite";

// As `npm create vite` writes it (create-vite 9.2.1), plus the output directory `lepton`
// installs beside the binary.
export default defineConfig({
  plugins: [preact()],
  build: { outDir: "dist", emptyOutDir: true },
});
