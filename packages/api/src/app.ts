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
 * @module
 */

import { invoke } from "./core.ts";
import { listen, type UnlistenFn } from "./event.ts";

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
