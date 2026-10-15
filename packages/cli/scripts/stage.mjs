// Puts the built `lepton` binary into this machine's platform package,
// `packages/cli-<os>-<arch>/`, and writes that package's manifest.
//
// Run after `cargo build --release --bin lepton`, on each platform the CLI ships for (CI
// does the others). Refuses a binary whose `--version` is not this package's version, so
// a stale build can never be published under a new number.
import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const launcher = JSON.parse(readFileSync(here("../package.json"), "utf8"));
const version = launcher.version;
const os = process.platform;
const cpu = process.arch;
const name = `@lepton-desk/cli-${os}-${cpu}`;
if (!(name in launcher.optionalDependencies)) {
  // Listed only once staged: an optional dependency on a package that was never
  // published is a 404 at every install.
  throw new Error(
    `add "${name}": "${launcher.version}" to @lepton-desk/cli's optionalDependencies`,
  );
}

const executable = os === "win32" ? "lepton.exe" : "lepton";
const built = here(`../../../target/release/${executable}`);
const reported = execFileSync(built, ["--version"], { encoding: "utf8" }).trim();
if (reported !== `lepton ${version}`) {
  throw new Error(`the built binary says "${reported}", the package is ${version}; rebuild it`);
}

const target = here(`../../cli-${os}-${cpu}/`);
mkdirSync(`${target}bin`, { recursive: true });
copyFileSync(built, `${target}bin/${executable}`);
chmodSync(`${target}bin/${executable}`, 0o755);

const manifest = {
  name,
  version,
  description: `The Lepton CLI binary for ${os}-${cpu}. Installed by @lepton-desk/cli; not used directly.`,
  license: launcher.license,
  repository: { ...launcher.repository, directory: `packages/cli-${os}-${cpu}` },
  os: [os],
  cpu: [cpu],
  ...(os === "linux" ? { libc: ["glibc"] } : {}),
  // `LICENSE-MIT` is not one of the names npm always includes (`LICENSE`, `LICENSE.*`).
  files: ["bin", "LICENSE*"],
  preferUnplugged: true,
  publishConfig: { access: "public" },
};
writeFileSync(`${target}package.json`, `${JSON.stringify(manifest, null, 2)}\n`);

const bytes = statSync(`${target}bin/${executable}`).size;
console.log(`staged ${name}@${version}: bin/${executable}, ${bytes} bytes`);
