/**
 * The document every page shares. Next.js renders it at build time into `out/`.
 */

import type { Metadata } from "next";
import type { JSX, ReactNode } from "react";

/** The window's title: the window shows the page's `<title>`. */
export const metadata: Metadata = { title: "{title}" };

export default function RootLayout({ children }: { children: ReactNode }): JSX.Element {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
