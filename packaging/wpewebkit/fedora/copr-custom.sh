#!/bin/sh
# COPR "custom" source method: COPR runs this in an empty directory and builds the SRPM
# from the spec and sources it leaves there. Needs only curl (--script-builddeps curl).
set -eu
curl -fLO https://wpewebkit.org/releases/wpewebkit-2.54.1.tar.xz
# The md5 Debian's signed .dsc and wpewebkit.org's own sums give for this tarball.
echo "834129000777bef051f2587ab069a6b5  wpewebkit-2.54.1.tar.xz" | md5sum -c -
curl -fLO https://raw.githubusercontent.com/lepton-desk/lepton/trunk/packaging/wpewebkit/fedora/wpewebkit.spec
