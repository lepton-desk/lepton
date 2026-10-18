/**
 * The entry: defines `<measures-screen>` and puts it in `#app`.
 *
 * `lepton.ts` is the binding that gets you the channel; replace `measures-screen.ts` with
 * your own elements and keep it.
 */

import "./measures-screen.ts";
import "./lepton-sdk.css";

const host = document.getElementById("app");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #app element to mount into");
}

host.append(document.createElement("measures-screen"));
