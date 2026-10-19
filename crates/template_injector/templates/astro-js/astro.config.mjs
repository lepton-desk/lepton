import { defineConfig } from "astro/config";

export default defineConfig({
  // `lepton dev` has already told the core this port: a taken one must stop the server
  // rather than move it to the next one, where the window would never look.
  vite: { server: { strictPort: true } },
});
