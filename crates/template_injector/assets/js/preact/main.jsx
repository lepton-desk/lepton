// Generated from `preact/main.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The Preact entry point: bind to the channel, render the screen.
 *
 * React's entry in Preact's terms: one subscription, one piece of state, and the reading
 * handed down. `lepton.ts` and `measures.ts` are shared with every other frontend, so
 * Preact changes how the screen is expressed and nothing about what it measures.
 */
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { App } from "./App.jsx";
import { channel, measures } from "./lepton.js";
import "./lepton-sdk.css";

/** Subscribes to the channel for as long as the screen is mounted. */
function Screen() {
  const [reading, setReading] = useState(channel.latest().measures);
  useEffect(() => measures.subscribe(setReading), []);
  return <App reading={reading} />;
}
const host = document.querySelector("#root");
if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("lepton: no #root element to mount into");
}
render(<Screen />, host);
