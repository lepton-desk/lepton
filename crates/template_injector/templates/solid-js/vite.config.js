import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// As `npm create vite` writes it (create-vite 9.2.1), plus the output directory `lepton`
// installs beside the binary.
export default defineConfig({
  plugins: [solid()],
  build: { outDir: "dist", emptyOutDir: true },
});
