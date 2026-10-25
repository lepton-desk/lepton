// Generated from the core's `invoke.Command` and `invoke.Status` by
// `lepton-invoke-check types`. Do not edit; `pnpm run generate` rewrites it.

/** The core's built-in commands. */
export interface BuiltinCommands {
  "core.ping": true;
  "core.protocol": true;
  "window.close": true;
  "window.minimize": true;
  "window.maximize": true;
  "window.unmaximize": true;
  "window.state": true;
  "permission.respond": true;
  "app.args": true;
  "window.start_drag": true;
  "window.menu": true;
  "window.title": true;
}

/** The events the core itself emits. */
export interface BuiltinEvents {
  "window.state": true;
  "window.resized": true;
  "download.started": true;
  "download.progress": true;
  "download.finished": true;
  "download.failed": true;
  "permission.request": true;
  "app.opened": true;
  "window.title": true;
}

/** Every status, by name; `ok` is success. */
export const statusNames = [
  "ok",
  "malformed",
  "unknown_command",
  "too_large",
  "denied",
  "failed",
] as const;

/** Why a call failed, by name. */
export type StatusName = (typeof statusNames)[number];
