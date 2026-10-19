"use client";

/**
 * The page the window opens.
 *
 * The screen is loaded in the window only (`ssr: false`): `src/lepton.ts` attaches to the
 * window's channel as it loads, and Next.js also renders every page once at build time,
 * where there is no window and no channel.
 */

import dynamic from "next/dynamic";
import type { JSX } from "react";

const Screen = dynamic(() => import("../src/Screen.tsx"), { ssr: false });

export default function Page(): JSX.Element {
  return <Screen />;
}
