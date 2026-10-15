#!/usr/bin/env node
// `lepton` from npm: finds the native binary for this machine and runs it.
//
// The binary ships in a platform package (`@lepton-desk/cli-<os>-<arch>`), listed as an
// optional dependency so the package manager installs only the one that fits — no
// postinstall script, no download. This file does three things and nothing else: find
// that binary, pass the arguments through unchanged, and end the way the binary ended.
//
// Signals are forwarded. Measured on `lepton` itself: `timeout 60 lepton dev` that killed
// only the parent left the dev server and the window running. A launcher that died on
// SIGTERM without passing it on would bring that back one level up.
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { join } from "node:path";

const require = createRequire(import.meta.url);

/** The platform package for this machine, e.g. `@lepton-desk/cli-linux-x64`. */
function platformPackage() {
  return `@lepton-desk/cli-${process.platform}-${process.arch}`;
}

/** The binary to run: `LEPTON_BINARY` when set, otherwise the platform package's. */
function binaryPath() {
  const override = process.env.LEPTON_BINARY;
  if (override !== undefined && override !== "") return override;
  const name = platformPackage();
  let manifest;
  try {
    manifest = require.resolve(`${name}/package.json`);
  } catch {
    process.stderr.write(
      `lepton: no native binary for ${process.platform}-${process.arch}.\n` +
        `  expected the package ${name}, which the package manager installs as an optional\n` +
        "  dependency. Reinstall without --no-optional / --omit=optional, or build the CLI\n" +
        "  from source (cargo build --release --bin lepton) and set LEPTON_BINARY.\n",
    );
    process.exit(1);
  }
  const executable = process.platform === "win32" ? "lepton.exe" : "lepton";
  return join(manifest, "..", "bin", executable);
}

const child = spawn(binaryPath(), process.argv.slice(2), { stdio: "inherit" });

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    if (child.exitCode === null && child.signalCode === null) child.kill(signal);
  });
}

child.on("error", (error) => {
  process.stderr.write(`lepton: could not start the native binary: ${error.message}\n`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal !== null) {
    // End the same way, so a caller sees the signal and not a made-up exit code.
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
