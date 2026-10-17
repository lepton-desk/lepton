#!/usr/bin/env python3
"""Ubuntu source packages of WPE WebKit for a Launchpad PPA, from Debian's packaging.

Ubuntu has no WPE WebKit after 22.04 and no libwpe or WPEBackend-fdo at all (Launchpad,
2026-10-17). Debian unstable's 2.54.1-1 is taken as it is, with one change of substance:
the libwpe API is turned off (-DENABLE_WPE_LEGACY_API=OFF, as Arch builds it), so neither
missing library is needed. Lepton uses the WPEPlatform API. With the API off, exactly five
symbols leave libWPEWebKit-2.0.so.1 (Debian's symbols file diffed against Arch's 2.54.1
library); they are dropped from the symbols file so the build does not fail on them.

Usage:  DEBFULLNAME="Name" DEBEMAIL="you@example.org" python3 make-source.py OUTDIR
Writes, per Ubuntu series, a .dsc, a debian.tar.xz and an unsigned _source.changes; the
first series' .changes also carries the upstream tarball (a PPA's first upload must).
Signing and uploading: sign-and-upload.sh.
"""
import email.utils
import hashlib
import io
import os
import pathlib
import re
import sys
import tarfile
import urllib.request

DEBIAN = "2.54.1-1"
UPSTREAM = "2.54.1"
POOL = "https://deb.debian.org/debian/pool/main/w/wpewebkit"
# md5 from Debian's signed .dsc; the tarball's md5 also matches wpewebkit.org's published sums.
EXPECTED_MD5 = {
    f"wpewebkit_{UPSTREAM}.orig.tar.xz": "834129000777bef051f2587ab069a6b5",
    f"wpewebkit_{UPSTREAM}.orig.tar.xz.asc": "7c5097da94cc50ac0d4baf2905b7fd71",
    f"wpewebkit_{DEBIAN}.debian.tar.xz": "12223afebc9343a50d64f77147d98755",
}
# Oldest first: a PPA's first upload carries the upstream tarball, the others reuse it.
SERIES = [("noble", "24.04"), ("resolute", "26.04"), ("stonking", "26.10")]
LEGACY_SYMBOLS = [
    "webkit_web_view_backend_get_type",
    "webkit_web_view_backend_get_wpe_backend",
    "webkit_web_view_backend_new",
    "webkit_web_view_get_backend",
    "webkit_web_view_new",
]


def digest(path, name):
    h = hashlib.new(name)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(out):
    for name, md5 in EXPECTED_MD5.items():
        path = out / name
        if not path.exists():
            print(f"downloading {name}")
            urllib.request.urlretrieve(f"{POOL}/{name}", path)
        if digest(path, "md5") != md5:
            sys.exit(f"{name}: md5 does not match Debian's .dsc")


def replace_once(text, old, new, what):
    if text.count(old) != 1:
        sys.exit(f"Debian's {what} changed shape; expected one {old.strip()!r}")
    return text.replace(old, new)


def patch(files, series, version, who, date):
    rules = files["debian/rules"].decode()
    rules = replace_once(rules, "\t   -DUSE_LIBBACKTRACE=OFF\n",
                         "\t   -DUSE_LIBBACKTRACE=OFF \\\n\t   -DENABLE_WPE_LEGACY_API=OFF\n", "rules")
    files["debian/rules"] = rules.encode()

    control = files["debian/control"].decode()
    control = replace_once(control, "               libwpe-1.0-dev,\n", "", "control (Build-Depends)")
    control = replace_once(control, "               libwpebackend-fdo-1.0-dev,\n", "", "control (Build-Depends)")
    control = replace_once(control, "         libwpe-1.0-dev,\n", "", "control (dev Depends)")
    control = replace_once(control, "Suggests: libwpebackend-fdo-1.0-1\n", "", "control (Suggests)")
    files["debian/control"] = control.encode()

    symbols = files["debian/libwpewebkit-2.0-1.symbols"].decode().splitlines(keepends=True)
    kept = [line for line in symbols if not any(line.startswith(f" {name}@") for name in LEGACY_SYMBOLS)]
    if len(symbols) - len(kept) != len(LEGACY_SYMBOLS):
        sys.exit("symbols file: expected to drop exactly the five libwpe API symbols")
    files["debian/libwpewebkit-2.0-1.symbols"] = "".join(kept).encode()

    entry = (
        f"wpewebkit ({version}) {series}; urgency=medium\n\n"
        f"  * Backport Debian's {DEBIAN} to Ubuntu {series} for Lepton.\n"
        "  * Build without the libwpe API (-DENABLE_WPE_LEGACY_API=OFF): Ubuntu has\n"
        "    no libwpe or WPEBackend-fdo, and the WPEPlatform API does not need them.\n"
        "    Drop their build dependencies, the -dev package's libwpe-1.0-dev\n"
        "    dependency, the WPEBackend-fdo suggestion and the five libwpe API symbols.\n\n"
        f" -- {who}  {date}\n\n"
    )
    files["debian/changelog"] = entry.encode() + files["debian/changelog"]
    return entry


def read_debian(out):
    files, members = {}, []
    with tarfile.open(out / f"wpewebkit_{DEBIAN}.debian.tar.xz") as tar:
        for m in tar.getmembers():
            members.append(m)
            if m.isfile():
                files[m.name] = tar.extractfile(m).read()
    return members, files


def write_debian(path, members, files, mtime):
    with tarfile.open(path, "w:xz", format=tarfile.GNU_FORMAT) as tar:
        for m in sorted(members, key=lambda m: m.name):
            info = tarfile.TarInfo(m.name)
            info.mode, info.mtime, info.uid, info.gid, info.uname, info.gname = m.mode, mtime, 0, 0, "root", "root"
            if m.isdir():
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            elif m.issym():
                info.type, info.linkname = tarfile.SYMTYPE, m.linkname
                tar.addfile(info)
            else:
                data = files[m.name]
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))


def fields(text):
    """The paragraph of a control file (signature stripped) as (name, value) pairs."""
    text = re.sub(r"(?s)^-----BEGIN PGP SIGNED MESSAGE-----\n.*?\n\n", "", text)
    text = re.sub(r"(?s)\n-----BEGIN PGP SIGNATURE-----.*", "\n", text)
    pairs = []
    for line in text.splitlines():
        if not line:
            continue
        if line[0] in " \t":
            pairs[-1][1] += "\n" + line
        else:
            name, _, value = line.partition(":")
            pairs.append([name, value.strip()])
    return pairs


def checksum_lines(paths, kind):
    lines = []
    for p in paths:
        size = p.stat().st_size
        if kind == "md5":
            lines.append(f" {digest(p, 'md5')} {size} {p.name}")
        else:
            lines.append(f" {digest(p, kind)} {size} {p.name}")
    return "\n" + "\n".join(lines)


def control_field(control, name):
    m = re.search(rf"(?ms)^{name}:(.*?)(?=^\S|\Z)", control)
    return m.group(1).strip() if m else None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    name, mail = os.environ.get("DEBFULLNAME"), os.environ.get("DEBEMAIL")
    if not name or not mail:
        sys.exit("set DEBFULLNAME and DEBEMAIL to the name and address on your Launchpad account")
    who = f"{name} <{mail}>"
    fetch(out)
    dsc_path = out / f"wpewebkit_{DEBIAN}.dsc"
    if not dsc_path.exists():
        urllib.request.urlretrieve(f"{POOL}/{dsc_path.name}", dsc_path)
    original = fields(dsc_path.read_text())
    orig = [out / f"wpewebkit_{UPSTREAM}.orig.tar.xz", out / f"wpewebkit_{UPSTREAM}.orig.tar.xz.asc"]
    now = email.utils.formatdate(localtime=True)
    mtime = int(email.utils.parsedate_to_datetime(now).timestamp())

    for index, (series, number) in enumerate(SERIES):
        version = f"{DEBIAN}~lepton1~{number}.1"
        members, files = read_debian(out)
        entry = patch(files, series, version, who, now)
        debian_tar = out / f"wpewebkit_{version}.debian.tar.xz"
        write_debian(debian_tar, members, files, mtime)
        control = files["debian/control"].decode()

        sources = orig + [debian_tar]
        dsc_lines = []
        for key, value in original:
            if key == "Version":
                value = version
            elif key == "Build-Depends":
                value = control_field(control, "Build-Depends")
            elif key == "Checksums-Sha1":
                value = checksum_lines(sources, "sha1")
            elif key == "Checksums-Sha256":
                value = checksum_lines(sources, "sha256")
            elif key == "Files":
                value = checksum_lines(sources, "md5")
            sep = "" if value.startswith("\n") else " "
            dsc_lines.append(f"{key}:{sep}{value}")
        dsc = out / f"wpewebkit_{version}.dsc"
        dsc.write_text("\n".join(dsc_lines) + "\n")

        # The first series carries the upstream tarball; the PPA keeps it for the rest.
        uploaded = (orig if index == 0 else []) + [debian_tar, dsc]
        changes_text = "\n".join(" " + (line if line.strip() else ".") for line in entry.rstrip("\n").splitlines())
        binary = dict(original)["Binary"]
        files_lines = "\n" + "\n".join(f" {digest(p, 'md5')} {p.stat().st_size} libs optional {p.name}" for p in uploaded)
        changes = (
            "Format: 1.8\n"
            f"Date: {now}\n"
            "Source: wpewebkit\n"
            f"Binary: {binary}\n"
            "Architecture: source\n"
            f"Version: {version}\n"
            f"Distribution: {series}\n"
            "Urgency: medium\n"
            f"Maintainer: {dict(original)['Maintainer']}\n"
            f"Changed-By: {who}\n"
            f"Changes:\n{changes_text}\n"
            f"Checksums-Sha1:{checksum_lines(uploaded, 'sha1')}\n"
            f"Checksums-Sha256:{checksum_lines(uploaded, 'sha256')}\n"
            f"Files:{files_lines}\n"
        )
        (out / f"wpewebkit_{version}_source.changes").write_text(changes)
        print(f"{series:9} {version}  ({'with' if index == 0 else 'without'} the upstream tarball)")


if __name__ == "__main__":
    main()
