#!/usr/bin/env bash
# The `lepton` CLI as an Arch package (.github/workflows/release.yml), made by makepkg in
# an Arch container from the release's own Linux archive. Laid out as the AUR packages
# are (/usr/bin/lepton-desk: Dropbox's JPEG compressor owns /usr/bin/lepton), but on
# Arch's own `zig`: the CLI builds with 0.16 and 0.17 (crates/orchestrator/src/zig.rs),
# so the package installs with pacman alone. makepkg refuses root, so it runs as `builder`.
#
#   tools/ci/cli-pacman.sh <lepton-<version>-linux-x64.tar.gz> <version> <out>
set -euo pipefail

archive=$1 version=$2 out=$3
# pkgver allows no `-` (it separates pkgrel): 0.1.9-beta.3 → 0.1.9beta.3, as arch.rs.
pkgver=${version/-/}
work=$(mktemp -d)
cp "$archive" "$work/"
sum=$(sha256sum "$archive" | cut -d' ' -f1)
name=$(basename "$archive")

cat > "$work/PKGBUILD" <<EOF
# Maintainer: Lepton <lepton-framework@protonmail.com>
pkgname=lepton-desk
pkgver=$pkgver
pkgrel=1
pkgdesc="Desktop app framework with a Zig core and a web frontend on WPE WebKit (CLI)"
arch=('x86_64')
url="https://github.com/lepton-desk/lepton"
license=('MIT OR Apache-2.0')
depends=('glibc' 'libgcc' 'zig' 'pkgconf' 'wpewebkit>=2.54')
optdepends=(
  'nodejs: frontend builds for npm, pnpm and Yarn projects'
  'pnpm: the default package manager when installed'
  'bun: Bun projects'
)
provides=('lepton-desk')
conflicts=('lepton-desk-bin')
source=("$name")
sha256sums=('$sum')
options=('!strip' '!debug')

package() {
  install -Dm755 "lepton-$version-linux-x64/lepton" "\$pkgdir/usr/bin/lepton-desk"
  install -Dm644 "lepton-$version-linux-x64/LICENSE-MIT" "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE-MIT"
  install -Dm644 "lepton-$version-linux-x64/LICENSE-APACHE" "\$pkgdir/usr/share/licenses/\$pkgname/LICENSE-APACHE"
}
EOF

id builder >/dev/null 2>&1 || useradd -m builder
chown -R builder "$work"
# --nodeps: zig and wpewebkit are the package's run-time needs, not this build's.
su builder -c "cd '$work' && SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) makepkg --nodeps --noconfirm"
mkdir -p "$out"
cp "$work"/lepton-desk-*.pkg.tar.zst "$out/"
pacman -Qip "$out"/lepton-desk-*.pkg.tar.zst
