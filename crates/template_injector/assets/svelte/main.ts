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
