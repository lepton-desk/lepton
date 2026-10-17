# WPE WebKit for Ubuntu and Fedora

Lepton renders pages with the web engine the system provides. On Ubuntu and Fedora the
system does not provide WPE WebKit 2.54, so Lepton offers it from its own package
repositories: one engine per machine, shared by every Lepton app, as with WebView2 on
Windows. Apps still do not carry a browser.

Checked against the distributions' own repositories on 2026-10-17:

| Distribution | WPE WebKit |
| --- | --- |
| Arch, openSUSE Tumbleweed, Debian testing/unstable | 2.54.1, packaged by the distribution |
| Ubuntu | only `libwpewebkit-1.0` in 22.04; nothing in 24.04, 26.04, 26.10; no libwpe or WPEBackend-fdo |
| Fedora | `wpewebkit` retired (`dead.package`); last updates for Fedora 29–32 |

Both builds below turn off WebKit's older libwpe API (`-DENABLE_WPE_LEGACY_API=OFF`, as
Arch builds it): neither distribution has libwpe or WPEBackend-fdo, and Lepton uses the
WPEPlatform API.

**Maintenance.** WebKit publishes security releases often. Whoever owns these repositories
takes on rebuilding them for each release; see "A new WebKit release" below.

## Ubuntu: a Launchpad PPA

`ubuntu/make-source.py` turns Debian unstable's `wpewebkit 2.54.1-1` into source packages
for Ubuntu 24.04 (noble), 26.04 (resolute) and 26.10 (stonking). The only changes to
Debian's packaging: the libwpe API off, its two build dependencies and the `-dev`
package's `libwpe-1.0-dev` dependency removed, the WPEBackend-fdo suggestion removed, and
the five symbols that leave the library without that API (measured against Arch's 2.54.1)
dropped from the symbols file. Every other build dependency exists in all three series at
or above the versions WebKit's CMake asks for.

Once:

1. Create the Launchpad team or account the PPA lives under (e.g. `lepton-desk`).
2. Upload your OpenPGP key to your Launchpad account.
3. Create the PPA `wpewebkit` (Launchpad → the team → "Create a new PPA"). Builds are
   amd64 by default; arm64 can be enabled in the PPA's settings.

Each upload:

```sh
cd packaging/wpewebkit
DEBFULLNAME="Your Name" DEBEMAIL="address-on-launchpad@example.org" \
  python3 ubuntu/make-source.py out/ubuntu
./ubuntu/sign-and-upload.sh out/ubuntu YOUR_KEY_ID lepton-desk/wpewebkit            # dry run
./ubuntu/sign-and-upload.sh out/ubuntu YOUR_KEY_ID lepton-desk/wpewebkit --upload   # signs, uploads
```

Only `python3`, `gpg` and `curl` are needed. The first series uploaded (noble) carries the
upstream tarball; the others reuse it. Launchpad mails each upload's result, then builds
(WebKit takes hours).

People then install it with:

```sh
sudo add-apt-repository ppa:lepton-desk/wpewebkit
sudo apt install libwpewebkit-2.0-dev
```

## Fedora: a COPR project

`fedora/wpewebkit.spec` is the spec of the `philn/wpewebkit` COPR (its 2.54.1-1 built for
Fedora 45 on 2026-10-15) with the libwpe API off, its two build dependencies removed, and
a fixed release and changelog. `fedora/copr-custom.sh` lets COPR fetch the tarball
(checksum checked) and this spec itself, so nothing needs to be built locally.

Once:

1. Sign in to COPR with a Fedora account; create the project `wpewebkit` (under your
   account, or a FAS group such as `@lepton-desk`).
2. Chroots: `fedora-43-x86_64`, `fedora-44-x86_64`, `fedora-45-x86_64` (and the
   `aarch64` ones if wanted).

Each build, in the web interface: **New Build → Custom**, paste `fedora/copr-custom.sh`,
build dependencies `curl`, result directory empty. Or with `copr-cli`:

```sh
copr-cli buildcustom lepton-desk/wpewebkit --script packaging/wpewebkit/fedora/copr-custom.sh \
  --script-builddeps curl --script-chroot fedora-latest-x86_64
```

The script reads the spec from this repository's `trunk`, so push the spec first.

People then install it with:

```sh
sudo dnf copr enable lepton-desk/wpewebkit
sudo dnf install wpewebkit-devel
```

## A new WebKit release

- Ubuntu: when Debian uploads the new version, update `DEBIAN`, `UPSTREAM` and the md5
  sums in `make-source.py` from Debian's `.dsc`, and check that the five symbols and the
  replaced lines still match (the script stops if they do not).
- Fedora: update `Version`, the changelog, and the tarball name and md5 in
  `copr-custom.sh`.
