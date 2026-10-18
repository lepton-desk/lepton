// Generated from `lit/main.ts` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The entry: defines `<measures-screen>` and puts it in `#app`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `measures-screen.ts` with
 * your own elements and keep it.
 */
import "./measures-screen.js";
import "./lepton-sdk.css";

const host = document.getElementById("app");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #app element to mount into");
}
host.append(document.createElement("measures-screen"));
