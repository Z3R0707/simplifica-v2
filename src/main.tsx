import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./app";
import "./estilos.css";

createRoot(document.getElementById("app")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
