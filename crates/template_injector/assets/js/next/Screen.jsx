// Generated from `next/Screen.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * Subscribes to the channel and holds the current reading.
 *
 * Its own module because `lepton.ts` attaches to the window's channel as it loads, and
 * Next.js renders every page once at build time, where there is no window: `app/page.tsx`
 * loads this file only in the window (`ssr: false`).
 */
import { useEffect, useState } from "react";
import { App } from "./App.jsx";
import { channel, measures } from "./lepton.js";
import "./lepton-sdk.css";
export default function Screen() {
  const [reading, setReading] = useState(channel.latest().measures);
  useEffect(() => measures.subscribe(setReading), []);
  return <App reading={reading} />;
}
