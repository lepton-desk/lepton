/**
 * The entry: renders the Solid screen into `#root`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `App.tsx` with your own
 * application and keep it.
 */

import { render } from "solid-js/web";
import { App } from "./App.tsx";
import "./lepton-sdk.css";

const host = document.getElementById("root");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #root element to mount into");
}

render(() => <App />, host);
