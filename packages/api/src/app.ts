/**
 * `@lepton-desk/api/app` — what the application was opened with.
 *
 * An application runs once per user. A second start (a deep link such as
 * `myapp://open/7`, a file opened from the desktop) hands its arguments to the running
 * copy and ends; the running copy's page hears of it through {@link onOpened}. The
 * arguments of this start are {@link launchArgs}.
 *
 * Both are an `invoke` of `app.args`, which must be listed under `permissions` in
 * `lepton.config.json` (a new project lists it; a recording keeps its bytes masked). A
 * scheme the application opens is listed under `deepLinks`.
 *
 * Who the application is — its name, version and identifier — is {@link info}.
 *
 * @module
 */

import { invoke } from "./core.ts";
import { listen, type UnlistenFn } from "./event.ts";
import { identity } from "./identity.ts";

/** Who the application is, from `lepton.config.json`. */
export interface AppInfo {
  /** `productName`: the name a title bar the page draws itself shows. */
  readonly name: string;
  /** `version`. */
  readonly version: string;
  /** `identifier`, as the desktop knows the application. */
  readonly identifier: string;
}

/**
 * Who the application is. Fixed for the run: the core writes it into the page before
 * the page's own scripts run, so this asks nothing, needs no permission and returns at
 * once. Throws outside a Lepton window, and under a core from before it (`lepton update`
 * brings the project's core and `main.zig` up to date).
 */
export function info(): AppInfo {
  const app = identity();
  if (app === undefined) {
    throw new Error(
      "info() needs a Lepton window whose core writes __lepton.app (0.1.9-beta.3 or newer)",
    );
  }
  return Object.freeze({ name: app.name, version: app.version, identifier: app.identifier });
}

/** NUL-ended arguments, as the core packs them. */
function unpack(bytes: Uint8Array): string[] {
  const text = new TextDecoder().decode(bytes);
  const parts = text.split("\0");
  parts.pop();
  return parts;
}

/** The arguments this start was given after the program's own. */
export async function launchArgs(): Promise<string[]> {
  return unpack(await invoke("app.args"));
}

/**
 * Calls `handler` with the arguments of every later start of the application, from now
 * on. Resolves with a function that stops listening.
 */
export async function onOpened(handler: (args: string[]) => void): Promise<UnlistenFn> {
  return listen("app.opened", (event) => {
    void invoke("app.args", event.payload).then(
      (bytes) => handler(unpack(bytes)),
      () => undefined,
    );
  });
}
