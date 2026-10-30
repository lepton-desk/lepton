#!/usr/bin/env bash
# Everything that must be true before `npm publish` of the @lepton-desk packages.
#
# Builds, tests and packs; publishes nothing. Exits non-zero at the first failure, so a
# clean run is the go-ahead. Run from anywhere: `tools/npm-preflight.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
plugins=(plugin-os plugin-clipboard plugin-fs plugin-dialog)
packages=(cli-linux-x64 cli-win32-x64 cli api "${plugins[@]}" create-lepton-app servo-linux-x64 appimage-runtime-linux-x64 setup-windows-x64)
# Published from Windows first (docs/yayin.md): the Windows binary, and the packages with
# no Linux-only half. plugin-os and plugin-fs have one each (`uname`, `openat2`), which
# their prepublish tests only here, so they, the Linux binary, `cli` and create-lepton-app
# go from here.
from_windows=(cli-win32-x64 api plugin-clipboard plugin-dialog)
step() { printf '\n== %s\n' "$*"; }
fail() { printf 'preflight: %s\n' "$*" >&2; exit 1; }

step "versions agree"
version="$(sed -n '/^\[workspace.package\]/,/^\[/ s/^version = "\(.*\)"/\1/p' "$root/Cargo.toml")"
[ -n "$version" ] || fail "no [workspace.package] version in Cargo.toml"
for package in api cli "${plugins[@]}" create-lepton-app; do
  have="$(node -p "require('$root/packages/$package/package.json').version")"
  [ "$have" = "$version" ] || fail "packages/$package is $have, the CLI is $version"
done
wanted="$(node -p "require('$root/packages/create-lepton-app/package.json').dependencies['@lepton-desk/cli']")"
[ "$wanted" = "$version" ] || fail "create-lepton-app depends on @lepton-desk/cli $wanted, not $version"
for plugin in "${plugins[@]}"; do
  peer="$(node -p "require('$root/packages/$plugin/package.json').peerDependencies['@lepton-desk/api']")"
  # `^0.1.6` does not admit `0.2.0-beta.1`: a plugin must name the API it ships with.
  [ "$peer" = "^$version" ] || fail "packages/$plugin wants @lepton-desk/api $peer, not ^$version"
done
for staged in servo-linux-x64 appimage-runtime-linux-x64 setup-windows-x64; do
  have="$(node -p "require('$root/packages/$staged/package.json').version")"
  [ "$have" = "$version" ] || fail "packages/$staged is $have, the CLI is $version"
done
for platform in cli-linux-x64 cli-win32-x64; do
  wanted="$(node -p "require('$root/packages/cli/package.json').optionalDependencies['@lepton-desk/$platform']")"
  [ "$wanted" = "$version" ] || fail "@lepton-desk/cli wants $platform $wanted, not $version"
  have="$(node -p "require('$root/packages/$platform/package.json').version")"
  [ "$have" = "$version" ] || fail "packages/$platform is $have, the CLI is $version"
done
echo "all at $version"

step "the template history is what this version ships"
# `lepton update` tells a project's own edits from the template by comparing with
# `assets/history/<version>/`, written when the version was set (`release-version.mjs`). A
# template changed after that and published unsynced makes every untouched project look
# edited on the next update (beta.2's copies were two changes behind, found 2026-10-23).
assets="$root/crates/template_injector/assets"
cmp -s "$assets/main.zig" "$assets/history/$version/main.zig" ||
  fail "assets/history/$version/main.zig differs from assets/main.zig: copy it before publishing"
cmp -s "$assets/lepton-build.zig" "$assets/history/$version/build.zig" ||
  fail "assets/history/$version/build.zig differs from assets/lepton-build.zig: copy it before publishing"
echo "history/$version matches the templates"

step "dist-tag"
# Plain versions are `latest`, `-beta.N` is `beta` (0.2.0), `-rc.N` is `next` (1.0.0); npm 11
# refuses a prerelease without `--tag`, and a beta under `latest` would reach every install.
case "$version" in
  *-beta.[0-9]*) tag=beta ;;
  *-rc.[0-9]*) tag=next ;;
  *-*) fail "$version is a prerelease but neither -beta.N nor -rc.N" ;;
  *) tag=latest ;;
esac
echo "$version publishes under $tag"

step "not already published"
for package in "${packages[@]}"; do
  name="$(node -p "require('$root/packages/$package/package.json').name" 2>/dev/null || echo "@lepton-desk/$package")"
  if published="$(npm view "$name@$version" version 2>/dev/null)" && [ -n "$published" ]; then
    if [[ " ${from_windows[*]} " == *" $package "* ]]; then
      echo "$name@$version: published from Windows"
      continue
    fi
    fail "$name@$version is already on npm; bump the version"
  fi
  echo "$name@$version: free"
done

step "licence texts"
licences=("$root"/LICENSE*)
[ -e "${licences[0]}" ] || fail "no LICENSE file at the repository root; the packages say \"MIT OR Apache-2.0\" and must ship the texts (LICENSE-MIT, LICENSE-APACHE)"
for package in "${packages[@]}"; do
  cp "${licences[@]}" "$root/packages/$package/"
done
echo "copied ${#licences[@]} file(s) into each package"

step "CLI: build, test, lint"
(cd "$root" && cargo build --release --bin lepton && cargo test --quiet && cargo clippy --workspace --all-targets -- -D warnings)

step "stage the linux-x64 binary"
node "$root/packages/cli/scripts/stage.mjs"

step "core tool the SDK tests talk to"
(cd "$root/zig" && zig build invoke-check)

step "@lepton-desk/api: install, build, check, test"
(cd "$root/packages/api" && pnpm install --frozen-lockfile && pnpm run build && pnpm run check && pnpm test)

for plugin in "${plugins[@]}"; do
  step "@lepton-desk/$plugin: install, build, check, test"
  (cd "$root/packages/$plugin" && pnpm install --frozen-lockfile && pnpm run build && pnpm run check && pnpm test)
done

step "create-lepton-app: test, lint"
(cd "$root/packages/create-lepton-app" && LEPTON_BINARY="$root/target/release/lepton" node --test "test/*.test.*" && "$root/packages/api/node_modules/.bin/biome" check .)

step "@lepton-desk/cli: test, lint"
(cd "$root/packages/cli" && node --test "test/*.test.*" && "$root/packages/api/node_modules/.bin/biome" check .)

# Servo is built in CI (`servo-bridge`, ~11 minutes there; far longer here) and staged
# from its `liblepton_servo` artifact: `node tools/stage-servo.mjs liblepton_servo.so.xz`.
step "the Servo library"
[ -f "$root/packages/servo-linux-x64/lib/liblepton_servo.so" ] || fail "packages/servo-linux-x64/lib has no liblepton_servo.so: download the servo-bridge run's liblepton_servo artifact and run node tools/stage-servo.mjs on it"
[ -f "$root/packages/servo-linux-x64/LICENSE-MPL" ] || fail "packages/servo-linux-x64 has no LICENSE-MPL (stage-servo.mjs copies it)"
echo "staged"

# AppImage's runtime, unchanged from type2-runtime 20251108 and checked by its SHA-256:
# `node tools/stage-appimage-runtime.mjs runtime-x86_64`.
step "the AppImage runtime"
runtime="$root/packages/appimage-runtime-linux-x64/runtime-x86_64"
[ -f "$runtime" ] || fail "packages/appimage-runtime-linux-x64 has no runtime-x86_64: download it from https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 and run node tools/stage-appimage-runtime.mjs on it"
[ "$(sha256sum "$runtime" | cut -d' ' -f1)" = 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ] || fail "$runtime is not type2-runtime 20251108's runtime-x86_64"
echo "staged"

# setup.exe's program, built from `zig/src/setup/`: `node tools/stage-setup-program.mjs`
# (or with the `windows` run's `setup-program` artifact).
step "the setup program"
setup="$root/packages/setup-windows-x64/setup.exe"
[ -f "$setup" ] || fail "packages/setup-windows-x64 has no setup.exe: run node tools/stage-setup-program.mjs"
[ "$(head -c 2 "$setup")" = MZ ] || fail "$setup is not a Windows program"
echo "staged"

step "what each tarball will contain"
for package in "${packages[@]}"; do
  echo "-- $package"
  (cd "$root/packages/$package" && npm pack --dry-run 2>&1 | grep -E 'npm notice ([0-9.]+[kMG]?B |package size|total files)')
done

# The Windows binary is built and staged on Windows (MSVC): `cargo build --release --bin
# lepton`, then `node packages/cli/scripts/stage.mjs` there. It is published before
# @lepton-desk/cli, which names it, like the Linux one.
step "the win32-x64 binary"
if [ -f "$root/packages/cli-win32-x64/bin/lepton.exe" ]; then
  echo "staged here"
elif [ "$(npm view "@lepton-desk/cli-win32-x64@$version" version 2>/dev/null)" = "$version" ]; then
  echo "already on npm"
else
  fail "@lepton-desk/cli-win32-x64@$version is neither staged here nor on npm: on Windows, run \`cargo build --release --bin lepton\` and \`node packages/cli/scripts/stage.mjs\`, then publish it there before @lepton-desk/cli (docs/yayin.md)"
fi

if [ "$tag" = latest ]; then
  printf '\npreflight: ready to publish %s (npm publish)\n' "$version"
else
  printf '\npreflight: ready to publish %s (npm publish --tag %s)\n' "$version" "$tag"
fi
