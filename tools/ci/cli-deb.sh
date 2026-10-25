#!/usr/bin/env bash
# The `lepton` CLI as a Debian package (.github/workflows/release.yml), on a system with
# dpkg. The binary is installed as /usr/bin/lepton-desk, as in the Arch packages
# (packaging/aur/). Its Depends are the owners of the libraries the binary itself needs
# (`dpkg -S` of each DT_NEEDED), never a hand-kept list. Zig and WPE WebKit are what the CLI
# builds an app with, not what it links; Debian packages no Zig, so they are named in the
# description instead.
#
#   tools/ci/cli-deb.sh <lepton binary> <version> <out>
set -euo pipefail

binary=$1 version=$2 out=$3
# The pre-release dash becomes `~`, which sorts before the release (as deb.rs does).
debver=${version/-/\~}
root=$(mktemp -d)

install -Dm755 "$binary" "$root/usr/bin/lepton-desk"
install -Dm644 LICENSE-MIT "$root/usr/share/doc/lepton-desk/LICENSE-MIT"
install -Dm644 LICENSE-APACHE "$root/usr/share/doc/lepton-desk/LICENSE-APACHE"

depends=()
for soname in $(objdump -p "$binary" | awk '$1 == "NEEDED" { print $2 }'); do
  path=$(ldconfig -p | awk -v so="$soname" '$1 == so && /x86-64/ { print $NF; exit }')
  if [ -z "$path" ]; then
    echo "cli-deb: $soname is not on this system" >&2
    exit 1
  fi
  owner=$(dpkg -S "$path" 2>/dev/null || dpkg -S "$(readlink -f "$path")")
  depends+=("${owner%%:*}")
done
depends_line=$(printf '%s\n' "${depends[@]}" | sort -u | paste -sd, | sed 's/,/, /g')

mkdir -p "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: lepton-desk
Version: $debver
Architecture: amd64
Maintainer: Lepton <lepton-framework@protonmail.com>
Depends: $depends_line
Section: devel
Priority: optional
Homepage: https://github.com/lepton-desk/lepton
Description: Desktop app framework with a Zig core and a web frontend
 The lepton CLI (as /usr/bin/lepton-desk). Building an app needs Zig 0.16 or 0.17
 (from ziglang.org; set LEPTON_ZIG if it is not on PATH) and, for the web view on
 Linux, WPE WebKit 2.54 or newer; `lepton-desk info` says what is missing.
EOF

mkdir -p "$out"
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) \
  dpkg-deb --root-owner-group -Zxz --build "$root" "$out/lepton-desk_${debver}_amd64.deb"
dpkg-deb --info "$out/lepton-desk_${debver}_amd64.deb"
