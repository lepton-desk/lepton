#!/usr/bin/env bash
# Everything that must be true before `npm publish` of the @lepton-desk packages.
#
# Builds, tests and packs; publishes nothing. Exits non-zero at the first failure, so a
# clean run is the go-ahead. Run from anywhere: `tools/npm-preflight.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
packages=(cli-linux-x64 cli api)
step() { printf '\n== %s\n' "$*"; }
fail() { printf 'preflight: %s\n' "$*" >&2; exit 1; }

step "versions agree"
version="$(sed -n '/^\[workspace.package\]/,/^\[/ s/^version = "\(.*\)"/\1/p' "$root/Cargo.toml")"
[ -n "$version" ] || fail "no [workspace.package] version in Cargo.toml"
for package in api cli; do
  have="$(node -p "require('$root/packages/$package/package.json').version")"
  [ "$have" = "$version" ] || fail "packages/$package is $have, the CLI is $version"
done
echo "all at $version"

step "not already published"
for package in "${packages[@]}"; do
  name="$(node -p "require('$root/packages/$package/package.json').name" 2>/dev/null || echo "@lepton-desk/$package")"
  if published="$(npm view "$name@$version" version 2>/dev/null)" && [ -n "$published" ]; then
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

step "@lepton-desk/cli: test, lint"
(cd "$root/packages/cli" && node --test test/ && "$root/packages/api/node_modules/.bin/biome" check .)

step "what each tarball will contain"
for package in "${packages[@]}"; do
  echo "-- $package"
  (cd "$root/packages/$package" && npm pack --dry-run 2>&1 | grep -E 'npm notice ([0-9.]+[kMG]?B |package size|total files)')
done

printf '\npreflight: ready to publish %s\n' "$version"
