// Added to the template app by the `windows` workflow (measure.ps1). A second start with
// `leptonci://theme/<name>` reaches this page as `app.opened` (the single instance); the
// page then sets its theme-color and names it in its title, which measure.ps1 waits for
// before it reads the title bar.
import { onOpened } from "@lepton-desk/api/app";

const colours: Record<string, string> = {
  gold: "#ffd700",
  dark: "rgb(27 29 28)",
  light: "#ffffff",
};

function themeColor(): HTMLMetaElement {
  const found = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
  if (found) return found;
  const made = document.createElement("meta");
  made.name = "theme-color";
  document.head.append(made);
  return made;
}

void onOpened((args) => {
  for (const arg of args) {
    const name = /^leptonci:\/\/theme\/([a-z]+)/.exec(arg)?.[1];
    const colour = name === undefined ? undefined : colours[name];
    if (colour === undefined) continue;
    themeColor().content = colour;
    document.title = `ci ${name}`;
  }
});
