/**
 * `__lepton.app`, read for `app.info()` and `window.title()`. Not one of the package's
 * entry points: the shape belongs to the core (`transport.zig` `writeApplication`).
 *
 * @module
 */

/** What the core writes into the page at start-up. */
export interface Identity {
  readonly name: string;
  readonly version: string;
  readonly identifier: string;
  /** `window.title`: the window's name while the page has no `document.title`. */
  readonly title: string;
}

/** The running core's `__lepton.app`, or `undefined` outside a Lepton window or under a
 * core from before it (0.1.9-beta.2 and older). */
export function identity(): Identity | undefined {
  const lepton: unknown = Reflect.get(globalThis, "__lepton");
  if (typeof lepton !== "object" || lepton === null) return undefined;
  const app: unknown = Reflect.get(lepton, "app");
  if (typeof app !== "object" || app === null) return undefined;
  const fields = ["name", "version", "identifier", "title"] as const;
  if (!fields.every((field) => typeof Reflect.get(app, field) === "string")) return undefined;
  return app as Identity;
}
