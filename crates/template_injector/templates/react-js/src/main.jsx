import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";

const host = document.querySelector("#root");

if (host) {
  createRoot(host).render(
    <StrictMode>
      <p>{{project_name}}</p>
    </StrictMode>,
  );
}
