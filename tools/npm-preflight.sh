#!/usr/bin/env bash
# Everything that must be true before `npm publish` of the @lepton-desk packages.
#
# Builds, tests and packs; publishes nothing. Exits non-zero at the first failure, so a
# clean run is the go-ahead. Run from anywhere: `tools/npm-preflight.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
plugins=(plugin-os plugin-clipboard plugin-fs plugin-dialog)
packages=(cli-linux-x64 cli-win32-x64 cli api "${plugins[@]}" create-lepton-app)
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
for platform in cli-linux-x64 cli-win32-x64; do
  wanted="$(node -p "require('$root/packages/cli/package.json').optionalDependencies['@lepton-desk/$platform']")"
  [ "$wanted" = "$version" ] || fail "@lepton-desk/cli wants $platform $wanted, not $version"
  have="$(node -p "require('$root/packages/$platform/package.json').version")"
  [ "$have" = "$version" ] || fail "packages/$platform is $have, the CLI is $version"
done
echo "all at $version"

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
    # The Windows binary goes out first, from Windows; the rest follow from here.
    if [ "$package" = cli-win32-x64 ]; then
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
(cd "$root/packages/create-lepton-app" && LEPTON_BINARY="$root/target/release/lepton" node --test test/ && "$root/packages/api/node_modules/.bin/biome" check .)

step "@lepton-desk/cli: test, lint"
(cd "$root/packages/cli" && node --test test/ && "$root/packages/api/node_modules/.bin/biome" check .)

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
