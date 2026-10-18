// Generated from `react/main.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The React entry point: bind to the channel, render the screen.
 *
 * The same job the plain-DOM entry does, in the shape React expects — one subscription,
 * one piece of state, and the reading handed down. `lepton.ts` and `measures.ts` are
 * shared with every other frontend, so switching to React changed how the screen is
 * expressed and nothing about what it measures.
 */
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import { channel, measures } from "./lepton.js";
import "./lepton-sdk.css";
import { useEffect, useState } from "react";

/**
 * Subscribes to the channel and holds the current reading.
 *
 * A component rather than a `useState` at the top level so the subscription is tied to
 * the component's lifetime: StrictMode mounts, unmounts and remounts in development, and
 * a subscription made outside the tree survives that and leaks a listener per remount.
 */
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
createRoot(host).render(
  <StrictMode>
    <Screen />
  </StrictMode>,
);
