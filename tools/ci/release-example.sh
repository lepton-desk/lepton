#!/usr/bin/env bash
# One example app for the release (.github/workflows/release.yml), made from this
# checkout: `lepton new` with the template, its Lepton packages linked to the checkout's
# (`file:`, as windows.yml does, so the app is the tag's and not whatever npm holds), the
# release's version, then `lepton package` for the system. The packages land in <out>.
#
#   tools/ci/release-example.sh <lepton> <template> <version> linux|debian|windows <out>
#
# `linux` writes the tar.gz and the Arch package (on Arch, whose pacman names the
# depends), `debian` the .deb (on Debian, whose dpkg names them), `windows` the zip and msi.
set -euo pipefail

lepton=$1 template=$2 version=$3 system=$4 out=$5
checkout=$(pwd)
name="lepton-${template%-ts}"

case "$system" in
  linux) targets='["tar.gz", "arch"]' flag=--linux ;;
  debian) targets='["deb"]' flag=--linux ;;
  windows) targets='["zip", "msi"]' flag=--windows ;;
  *) echo "release-example: system is linux, debian or windows, not $system" >&2; exit 2 ;;
esac

pnpm --dir packages/api install --frozen-lockfile
pnpm --dir packages/api run build

work=$(mktemp -d)
cd "$work"
"$lepton" new "$name" --template "$template" --target webview --package-manager npm \
  --owner lepton-desk --non-interactive
cd "$name"
CHECKOUT="$checkout" VERSION="$version" TARGETS="$targets" node -e '
  const fs = require("fs");
  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
  for (const group of ["dependencies", "devDependencies"]) {
    for (const lib of ["api", "cli"]) {
      if (pkg[group]?.[`@lepton-desk/${lib}`]) pkg[group][`@lepton-desk/${lib}`] = `file:${process.env.CHECKOUT}/packages/${lib}`;
    }
  }
  pkg.version = process.env.VERSION;
  fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2));
  const config = JSON.parse(fs.readFileSync("lepton.config.json", "utf8"));
  config.version = process.env.VERSION;
  // A .deb needs a maintainer (Debian policy; deb.rs refuses one without).
  config.bundle = { targets: JSON.parse(process.env.TARGETS), maintainer: "Lepton <lepton-framework@protonmail.com>" };
  fs.writeFileSync("lepton.config.json", JSON.stringify(config, null, 2));
'
npm install --no-audit --no-fund
"$lepton" package "$flag"

# The packages only: lepton package's own `.sha256` sidecars are made again, for every
# file alike, by the release job.
mkdir -p "$out"
find src-lepton/bundle -maxdepth 1 -type f \
  \( -name '*.tar.gz' -o -name '*.pkg.tar.zst' -o -name '*.deb' -o -name '*.zip' -o -name '*.msi' \) \
  -exec cp {} "$out/" \;
ls -l "$out"
