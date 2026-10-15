import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Nothing else is needed. Vite 8 transforms through oxc rather than esbuild, and the
// React plugin already arranges the automatic JSX runtime — an `esbuild: { jsx }` block
// here is not merely redundant, it is reported as a conflicting option on every build.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
});
