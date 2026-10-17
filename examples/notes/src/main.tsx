/**
 * The React entry point for Notes.
 */

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.tsx";
import "./notes.css";

const host = document.querySelector("#root");

if (host === null) {
  // A missing host is a mistake in `index.html`, and saying so beats a blank window.
  throw new Error("notes: no #root element to mount into");
}

createRoot(host).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
