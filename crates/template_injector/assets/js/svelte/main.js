// Generated from `svelte/main.ts` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The entry: mounts the Svelte screen into `#app`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `App.svelte` with your
 * own application and keep it.
 */
import { mount } from "svelte";
import App from "./App.svelte";
import "./lepton-sdk.css";

const host = document.getElementById("app");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #app element to mount into");
}
export default mount(App, { target: host });
