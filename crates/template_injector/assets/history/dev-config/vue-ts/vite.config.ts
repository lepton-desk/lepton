import vue from "@vitejs/plugin-vue";
import { defineConfig } from "vite";

// As `npm create vite` writes it (create-vite 9.2.1), plus the output directory `lepton`
// installs beside the binary.
export default defineConfig({
  plugins: [vue()],
  build: { outDir: "dist", emptyOutDir: true },
});
