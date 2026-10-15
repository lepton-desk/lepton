// Compiled by `pnpm run check`, never run: the type rules an application relies on.
import { type Command, invoke } from "../src/core.ts";

declare module "../src/core.ts" {
  interface AppCommands {
    "notes.save": true;
  }
}

export const builtin: Command = "core.ping";
export const own: Command = "notes.save";
// @ts-expect-error — a name neither the core nor the application registered.
export const typo: Command = "notes.sav";

export function calls(): Promise<Uint8Array>[] {
  return [invoke("window.close"), invoke("notes.save", new Uint8Array(1))];
}

declare module "../src/event.ts" {
  interface AppEvents {
    "notes.saved": true;
  }
}

import { type EventName, listen } from "../src/event.ts";

export const builtinEvent: EventName = "window.resized";
export const ownEvent: EventName = "notes.saved";
// @ts-expect-error — an event neither the core nor the application declared.
export const eventTypo: EventName = "notes.svaed";

export function listens(): Promise<() => void> {
  return listen("notes.saved", () => undefined);
}
