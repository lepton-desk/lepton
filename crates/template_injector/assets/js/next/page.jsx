// Generated from `next/page.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

"use client";
/**
 * The page the window opens.
 *
 * The screen is loaded in the window only (`ssr: false`): `src/lepton.ts` attaches to the
 * window's channel as it loads, and Next.js also renders every page once at build time,
 * where there is no window and no channel.
 */
import dynamic from "next/dynamic";

const Screen = dynamic(() => import("../src/Screen.jsx"), { ssr: false });
export default function Page() {
  return <Screen />;
}
