#!/usr/bin/env node
// `npm create lepton-app`, `pnpm create lepton-app`, `yarn create lepton-app`,
// `bun create lepton-app`: checks the machine and
// hands the rest to `lepton new` from `@lepton-desk/cli` — the same native binary the
// project will use, so there is nothing else to download and no postinstall script.
// `lepton new` asks for the name, the frontend, the render path and the plugins, writes the
// project, installs its dependencies with the manager that started this command, and
// says what to type next.
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { coloured, missing, newArguments, parse } from "../lib/plan.js";

const require = createRequire(import.meta.url);
const launcher = require.resolve("@lepton-desk/cli/bin/lepton.js");

/** `lepton …` through the CLI package's launcher, which finds the platform binary. */
function lepton(args, options) {
  return [process.execPath, [launcher, ...args], options];
}

const parsed = parse(process.argv.slice(2));

// The machine first: a project that cannot be built here is better learned about now.
const [program, infoArgs] = lepton(["info", "--json"]);
const info = spawnSync(program, infoArgs, { encoding: "utf8" });
if (info.status === 0) {
  const lines = missing(info.stdout);
  if (lines.length > 0) {
    const amber = coloured(process.env, process.stdout.isTTY === true)
      ? (text) => `\x1b[38;5;214m${text}\x1b[0m`
      : (text) => text;
    process.stdout.write(`\n  ${amber("!")} This machine cannot run a Lepton window yet:\n`);
    for (const line of lines) process.stdout.write(`      ${line}\n`);
    process.stdout.write("    The app is created anyway; `lepton info` checks again later.\n");
  }
}

const [binary, args, options] = lepton(newArguments(parsed.name, parsed), {
  stdio: "inherit",
});
const child = spawn(binary, args, options);
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    if (child.exitCode === null && child.signalCode === null) child.kill(signal);
  });
}
child.on("exit", (code, signal) => {
  if (signal !== null) {
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
