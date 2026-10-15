#!/usr/bin/env node
// `npm create lepton-app`, `pnpm create lepton-app`, `yarn create lepton-app`,
// `bun create lepton-app`: checks the machine, asks for a name when none was given, and
// hands the rest to `lepton new` from `@lepton-desk/cli` — the same native binary the
// project will use, so there is nothing else to download and no postinstall script.
// `lepton new` asks for the frontend, the render path and the plugins, writes the
// project, installs its dependencies with the manager that started this command, and
// says what to type next.
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { createInterface } from "node:readline/promises";
import { manager, missing, newArguments, parse } from "../lib/plan.js";

const require = createRequire(import.meta.url);
const launcher = require.resolve("@lepton-desk/cli/bin/lepton.js");

/** `lepton …` through the CLI package's launcher, which finds the platform binary. */
function lepton(args, options) {
  return [process.execPath, [launcher, ...args], options];
}

async function askName() {
  if (!process.stdin.isTTY) {
    process.stderr.write(
      "create-lepton-app: give the project a name, e.g. `create-lepton-app Notes`\n",
    );
    process.exit(1);
  }
  const prompt = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const answer = (await prompt.question("Project name (lepton-app): ")).trim();
  prompt.close();
  return answer === "" ? "lepton-app" : answer;
}

const parsed = parse(process.argv.slice(2));

// The machine first: a project that cannot be built here is better learned about now.
const [program, infoArgs] = lepton(["info", "--json"]);
const info = spawnSync(program, infoArgs, { encoding: "utf8" });
if (info.status === 0) {
  const lines = missing(info.stdout);
  if (lines.length > 0) {
    process.stdout.write("This machine is not ready to run a Lepton window yet:\n");
    for (const line of lines) process.stdout.write(`  - ${line}\n`);
    process.stdout.write("The project is created anyway; `lepton info` checks again later.\n\n");
  }
}

const name = parsed.name ?? (await askName());
process.stdout.write(`Creating ${name} with ${manager(process.env.npm_config_user_agent)}\n\n`);
const [binary, args, options] = lepton(newArguments(name, parsed), {
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
