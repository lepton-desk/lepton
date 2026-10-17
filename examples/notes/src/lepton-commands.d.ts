// Generated from this application's commands (`main.zig`) by its core build.
// Do not edit: `lepton build`, `run` and `dev` rewrite it.

declare module "@lepton-desk/api/core" {
  interface AppCommands {
    "app.name": true;
    "clipboard.read_text": true;
    "clipboard.write_text": true;
    "dialog.open": true;
    "dialog.save": true;
    "fs.read_file": true;
    "fs.write_file": true;
    "fs.read_dir": true;
    "fs.mkdir": true;
    "fs.remove": true;
    "fs.stat": true;
    "fs.exists": true;
    "fs.rename": true;
  }
}

declare module "@lepton-desk/api/event" {
  interface AppEvents {}
}

export {};
