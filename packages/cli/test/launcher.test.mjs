// The launcher against real programs: the shipped `lepton` binary (via LEPTON_BINARY) and,
// for signals, a real `sleep`. Nothing is stood in for.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const launcher = fileURLToPath(new URL("../bin/lepton.js", import.meta.url));
const binary = process.platform === "win32" ? "lepton.exe" : "lepton";
const built = fileURLToPath(new URL(`../../../target/release/${binary}`, import.meta.url));

function run(args, env = {}) {
  return spawnSync(process.execPath, [launcher, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test("arguments reach the binary and its output comes back", { skip: !existsSync(built) }, () => {
  const result = run(["--version"], { LEPTON_BINARY: built });
  assert.equal(result.status, 0);
  assert.match(result.stdout, /^lepton \d+\.\d+\.\d+/);
});

test("the binary's exit code is the launcher's", { skip: !existsSync(built) }, () => {
  const result = run(["no-such-command"], { LEPTON_BINARY: built });
  assert.notEqual(result.status, 0);
  assert.equal(result.status, spawnSync(built, ["no-such-command"]).status);
});

test("a missing platform package is explained, not a stack trace", () => {
  const result = run(["--version"], { LEPTON_BINARY: "" });
  // In this checkout no platform package is installed under node_modules.
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no native binary for/);
  assert.match(result.stderr, /@lepton-desk\/cli-/);
});

// Linux only: it reads the process tree from /proc, and Windows has no SIGTERM to forward
// (`kill` there ends the launcher outright).
test("SIGTERM to the launcher ends the child too", {
  skip: process.platform !== "linux",
}, async () => {
  const launched = spawn(process.execPath, [launcher, "30"], {
    env: { ...process.env, LEPTON_BINARY: "/usr/bin/sleep" },
  });
  await new Promise((resolve) => setTimeout(resolve, 300));
  const children = readFileSync(`/proc/${launched.pid}/task/${launched.pid}/children`, "utf8")
    .trim()
    .split(/\s+/)
    .filter((pid) => pid !== "");
  assert.equal(children.length, 1, "one child: the binary");
  const ended = new Promise((resolve) => launched.on("exit", (_code, signal) => resolve(signal)));
  launched.kill("SIGTERM");
  assert.equal(await ended, "SIGTERM");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(
    existsSync(`/proc/${children[0]}`),
    false,
    "the binary did not outlive the launcher",
  );
});

test("the package's version is the CLI's", () => {
  const cargo = readFileSync(new URL("../../../Cargo.toml", import.meta.url), "utf8");
  const workspace = /\[workspace\.package\][^[]*?version = "([^"]+)"/s.exec(cargo)?.[1];
  const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  assert.equal(manifest.version, workspace);
  for (const [name, version] of Object.entries(manifest.optionalDependencies)) {
    assert.equal(version, workspace, `${name} is pinned to the CLI's own version`);
  }
});

test("every optional dependency is a platform package that has been staged", () => {
  // Publishing a pointer to a package that does not exist makes every install 404 on it.
  // A package is staged on its own system (the Windows one on Windows, with `lepton.exe`)
  // and published from there first, so from another system it must already be on npm.
  const manifest = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  for (const name of Object.keys(manifest.optionalDependencies)) {
    const dir = new URL(`../../${name.replace("@lepton-desk/", "")}/`, import.meta.url);
    const staged = JSON.parse(readFileSync(new URL("package.json", dir), "utf8"));
    assert.equal(staged.name, name);
    assert.equal(staged.version, manifest.version);
    const executable = staged.os.includes("win32") ? "lepton.exe" : "lepton";
    if (existsSync(new URL(`bin/${executable}`, dir))) continue;
    const published = (() => {
      try {
        return execFileSync("npm", ["view", `${name}@${manifest.version}`, "version"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        }).trim();
      } catch {
        return "";
      }
    })();
    assert.equal(
      published,
      manifest.version,
      `${name} has no bin/${executable} here and ${manifest.version} is not on npm: stage and publish it on its own system first (docs/yayin.md)`,
    );
  }
});
