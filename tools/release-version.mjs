#!/usr/bin/env node
/**
 * Moves every version in the repository to one release, in one command.
 *
 *   node tools/release-version.mjs 0.1.7       before publishing: bump everything
 *   node tools/release-version.mjs aur          after publishing: the AUR checksums
 *
 * The CLI itself reads its version from `Cargo.toml` at build time (`lepton --version`,
 * the `◉ lepton new · v0.1.7` header, the `@lepton-desk/*` versions a new project gets), so
 * that file is the source. What cannot read it is written here:
 *
 * - every npm package's `version`, `@lepton-desk/cli`'s exact `cli-linux-x64` and
 *   `cli-win32-x64` dependencies,
 *   each plugin's `^<version>` peer on `@lepton-desk/api` (`^0.1.6` does not admit
 *   `0.2.0-beta.1`) and `create-lepton-app`'s exact `@lepton-desk/cli`;
 * - `lepton update`'s template history: the templates this version ships, copied to
 *   `assets/history/<version>/` and listed in `RELEASES`, so the next version can tell an
 *   untouched project of this one from an edited one;
 * - the AUR packages' `pkgver` (`pkgrel` back to 1) and the source package's commit,
 *   which is HEAD when this runs: commit the bump, then run `aur` after publishing;
 * - `Cargo.lock` (`cargo update --workspace`) and the current version in `docs/yayin.md`.
 *
 * `tools/npm-preflight.sh` then checks that all of it agrees. Publishes nothing.
 */

import { execFileSync } from "node:child_process";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	readFileSync,
	writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const at = (...parts) => join(root, ...parts);
const read = (path) => readFileSync(path, "utf8");
const plugins = ["plugin-os", "plugin-clipboard", "plugin-fs", "plugin-dialog"];
const npmPackages = [
	"api",
	"cli",
	"cli-linux-x64",
	"cli-win32-x64",
	...plugins,
	"create-lepton-app",
	"servo-linux-x64",
];

function fail(message) {
	console.error(`release-version: ${message}`);
	process.exit(1);
}

/** Replaces exactly one match of `pattern` in `path`, or fails naming the file. */
function replaceOnce(path, pattern, replacement) {
	const text = read(path);
	const matches = text.match(
		new RegExp(pattern.source, `${pattern.flags.replace("g", "")}g`),
	);
	if (matches === null || matches.length !== 1) {
		fail(
			`${path}: expected one match of ${pattern}, found ${matches === null ? 0 : matches.length}`,
		);
	}
	writeFileSync(path, text.replace(pattern, replacement));
}

/** Edits a package.json in place, keeping its two-space layout and final newline. */
function editPackage(name, edit) {
	const path = at("packages", name, "package.json");
	const manifest = JSON.parse(read(path));
	edit(manifest);
	writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`);
}

function cargoVersion() {
	const match = read(at("Cargo.toml")).match(
		/\[workspace\.package\]\nversion = "([^"]+)"/,
	);
	if (match === null) fail("no [workspace.package] version in Cargo.toml");
	return match[1];
}

function bump(version) {
	if (!/^\d+\.\d+\.\d+(-(beta|rc)\.\d+)?$/.test(version)) {
		fail(`${version} is not x.y.z, x.y.z-beta.N or x.y.z-rc.N`);
	}
	const previous = cargoVersion();
	if (previous === version) fail(`Cargo.toml is already ${version}`);

	replaceOnce(
		at("Cargo.toml"),
		/(\[workspace\.package\]\nversion = ")[^"]+(")/,
		`$1${version}$2`,
	);
	for (const name of npmPackages) {
		editPackage(name, (manifest) => {
			manifest.version = version;
			if (name === "cli")
				for (const platform of ["cli-linux-x64", "cli-win32-x64"])
					manifest.optionalDependencies[`@lepton-desk/${platform}`] = version;
			if (name === "create-lepton-app")
				manifest.dependencies["@lepton-desk/cli"] = version;
			if (plugins.includes(name))
				manifest.peerDependencies["@lepton-desk/api"] = `^${version}`;
		});
	}

	// The templates this version ships, for the next version's `lepton update`.
	const assets = at("crates", "template_injector", "assets");
	const history = join(assets, "history", version);
	if (existsSync(history)) fail(`${history} already exists`);
	mkdirSync(history, { recursive: true });
	copyFileSync(join(assets, "main.zig"), join(history, "main.zig"));
	copyFileSync(join(assets, "lepton-build.zig"), join(history, "build.zig"));
	replaceOnce(
		at("crates", "template_injector", "src", "update.rs"),
		/(pub const RELEASES: &\[Release\] = &\[\n[\s\S]*?)(\n\];)/,
		`$1\n    Release {\n        version: "${version}",\n        entry: include_str!("../assets/history/${version}/main.zig"),\n        build: include_str!("../assets/history/${version}/build.zig"),\n    },$2`,
	);

	// The AUR packages follow releases only: pacman refuses a `-` in `pkgver`, and a beta
	// would reach everyone who installed the stable package.
	const prerelease = version.includes("-");
	if (!prerelease) {
		for (const name of ["lepton-desk", "lepton-desk-bin"]) {
			const path = at("packaging", "aur", name, "PKGBUILD");
			replaceOnce(path, /^pkgver=.*$/m, `pkgver=${version}`);
			replaceOnce(path, /^pkgrel=.*$/m, "pkgrel=1");
		}
	}

	replaceOnce(
		at("docs", "yayin.md"),
		/Şu anki sürüm: \*\*[^*]+\*\*/,
		`Şu anki sürüm: **${version}**`,
	);
	// The previous version is the newest one already on npm.
	replaceOnce(
		at("docs", "yayin.md"),
		/\(0\.1\.0–[^ ]+ yayımlandı/,
		`(0.1.0–${previous} yayımlandı`,
	);
	execFileSync("cargo", ["update", "--workspace", "--quiet"], {
		cwd: root,
		stdio: "inherit",
	});

	console.log(`release-version: ${previous} -> ${version}`);
	console.log(
		`  Cargo.toml, Cargo.lock, ${npmPackages.length} npm packages, template history, ${prerelease ? "" : "AUR pkgver, "}docs/yayin.md`,
	);
	if (prerelease)
		console.log("  AUR left at the last release: a prerelease is not packaged there");
	console.log(
		"  next: tools/npm-preflight.sh, commit, publish, then `node tools/release-version.mjs aur`",
	);
}

/** After publishing: the AUR packages point at the published binary and the release commit. */
function aur() {
	const version = cargoVersion();
	if (version.includes("-"))
		fail(`${version} is a prerelease; the AUR packages follow releases only`);
	const integrity = execFileSync(
		"npm",
		["view", `@lepton-desk/cli-linux-x64@${version}`, "dist.integrity"],
		{
			encoding: "utf8",
		},
	).trim();
	if (!integrity.startsWith("sha512-"))
		fail(`@lepton-desk/cli-linux-x64@${version} is not on npm yet`);
	const hex = Buffer.from(integrity.slice("sha512-".length), "base64").toString(
		"hex",
	);
	const commit = execFileSync("git", ["rev-parse", "HEAD"], {
		cwd: root,
		encoding: "utf8",
	}).trim();

	replaceOnce(
		at("packaging", "aur", "lepton-desk-bin", "PKGBUILD"),
		/^sha512sums=\('[0-9a-f]+'\)$/m,
		`sha512sums=('${hex}')`,
	);
	replaceOnce(
		at("packaging", "aur", "lepton-desk", "PKGBUILD"),
		/^_commit=[0-9a-f]+$/m,
		`_commit=${commit}`,
	);
	for (const name of ["lepton-desk", "lepton-desk-bin"]) {
		const dir = at("packaging", "aur", name);
		writeFileSync(
			join(dir, ".SRCINFO"),
			execFileSync("makepkg", ["--printsrcinfo"], {
				cwd: dir,
				encoding: "utf8",
			}),
		);
	}
	console.log(
		`release-version: AUR packages at ${version} (npm sha512, commit ${commit.slice(0, 7)}), .SRCINFO written`,
	);
}

const [argument] = process.argv.slice(2);
if (argument === undefined) fail("usage: release-version.mjs <version> | aur");
if (argument === "aur") aur();
else bump(argument);
