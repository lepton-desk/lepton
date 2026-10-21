// Added to the template app by the `windows` workflow (measure.ps1), which drives it from
// outside with real input and reads the answers from the window's title:
// - a second start with `leptonci://theme/<name>` reaches this page as `app.opened` (the
//   single instance); the page sets its theme-color and names it in its title;
// - a 32 px bar along the top is the page's own title bar (`dragRegion`): a press moves
//   the window, a double click maximizes or restores it;
// - a right click opens the system's menu (`popupMenu`); the choice goes into the title.
import { onOpened } from "@lepton-desk/api/app";
import { dragRegion, type MenuItem, popupMenu } from "@lepton-desk/api/window";

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

const bar = document.createElement("div");
bar.id = "ci-bar";
bar.style.cssText =
  "position:fixed;top:0;left:0;right:0;height:32px;z-index:2147483647;background:#2b2d30;";
document.body.append(bar);
dragRegion(bar);

// Down, Down, Enter chooses 9: the separator is skipped and the disabled item is not
// reached. Esc chooses nothing.
const items: readonly MenuItem[] = [
  { id: 7, label: "Seven" },
  { separator: true },
  { id: 9, label: "Nine" },
  { id: 11, label: "Eleven", disabled: true },
];

addEventListener("contextmenu", (event) => {
  event.preventDefault();
  popupMenu(items).then(
    (chosen) => {
      document.title = `ci menu ${chosen ?? "none"}`;
    },
    (error: unknown) => {
      document.title = `ci menu error ${error instanceof Error ? error.message : String(error)}`;
    },
  );
});
