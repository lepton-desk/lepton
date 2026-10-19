/**
 * Subscribes to the channel and holds the current reading.
 *
 * Its own module because `lepton.ts` attaches to the window's channel as it loads, and
 * Next.js renders every page once at build time, where there is no window: `app/page.tsx`
 * loads this file only in the window (`ssr: false`).
 */

import { type JSX, useEffect, useState } from "react";
import { App } from "./App.tsx";
import { channel, measures } from "./lepton.ts";
import "./lepton-sdk.css";

export default function Screen(): JSX.Element {
  const [reading, setReading] = useState(channel.latest().measures);

  useEffect(() => measures.subscribe(setReading), []);

  return <App reading={reading} />;
}
