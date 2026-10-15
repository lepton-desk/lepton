import "./style.css";

const root = document.querySelector<HTMLDivElement>("#app");

if (root) {
  root.textContent = "{{project_name}}";
}
