// Generated from `solid/main.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The entry: renders the Solid screen into `#root`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `App.tsx` with your own
 * application and keep it.
 */
import { render } from "solid-js/web";
import { App } from "./App.jsx";
import "./lepton-sdk.css";

const host = document.getElementById("root");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #root element to mount into");
}
render(() => <App />, host);
