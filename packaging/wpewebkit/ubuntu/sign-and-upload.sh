#!/bin/bash
# Signs the source packages make-source.py wrote and uploads them to a Launchpad PPA, with
# only gpg and curl (no devscripts or dput needed). The same steps as debsign + dput:
# the .dsc is clear-signed, the .changes gets the signed .dsc's new checksums and is
# clear-signed too, then every file goes to Launchpad's anonymous FTP upload queue.
#
#   ./sign-and-upload.sh OUTDIR KEYID OWNER/PPA            prints what it would do
#   ./sign-and-upload.sh OUTDIR KEYID OWNER/PPA --upload   signs and uploads
#
# KEYID is the OpenPGP key registered on your Launchpad account; OWNER/PPA is e.g.
# lepton-desk/wpewebkit. Series are uploaded oldest first: the first one carries the
# upstream tarball the others reuse.
set -euo pipefail

out=${1:?OUTDIR}; key=${2:?KEYID}; ppa=${3:?OWNER/PPA}; mode=${4:-}
owner=${ppa%%/*}; name=${ppa#*/}
target="ftp://ppa.launchpad.net/~$owner/ubuntu/$name/"
cd "$out"

mapfile -t changes < <(ls wpewebkit_*~lepton*_source.changes | sort -V)
[ ${#changes[@]} -gt 0 ] || { echo "no _source.changes in $out"; exit 1; }

for c in "${changes[@]}"; do
	dsc=${c%_source.changes}.dsc
	files=$(awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f{print $5}' "$c")
	echo "== $c"
	echo "   files: $(echo $files | tr '\n' ' ')"
	if [ "$mode" != "--upload" ]; then
		echo "   (dry run: add --upload to sign and send to $target)"
		continue
	fi
	if ! head -1 "$dsc" | grep -q "BEGIN PGP SIGNED MESSAGE"; then
		gpg --local-user "$key" --clearsign --output "$dsc.signed" "$dsc"
		mv "$dsc.signed" "$dsc"
	fi
	# The signed .dsc is larger: put its real size and checksums in the .changes.
	python3 - "$c" "$dsc" <<'EOF'
import hashlib, os, re, sys
changes, dsc = sys.argv[1], sys.argv[2]
data = open(dsc, 'rb').read()
size = len(data)
sums = {'sha1': hashlib.sha1(data).hexdigest(), 'sha256': hashlib.sha256(data).hexdigest(), 'md5': hashlib.md5(data).hexdigest()}
name = os.path.basename(dsc)
text = open(changes).read()
text = re.sub(rf"(?m)^ [0-9a-f]{{40}} \d+ {re.escape(name)}$", f" {sums['sha1']} {size} {name}", text)
text = re.sub(rf"(?m)^ [0-9a-f]{{64}} \d+ {re.escape(name)}$", f" {sums['sha256']} {size} {name}", text)
text = re.sub(rf"(?m)^ [0-9a-f]{{32}} \d+ (\S+ \S+) {re.escape(name)}$", lambda m: f" {sums['md5']} {size} {m.group(1)} {name}", text)
open(changes, 'w').write(text)
EOF
	if ! head -1 "$c" | grep -q "BEGIN PGP SIGNED MESSAGE"; then
		gpg --local-user "$key" --clearsign --output "$c.signed" "$c"
		mv "$c.signed" "$c"
	fi
	for f in $files; do
		echo "   uploading $f"
		curl --fail --silent --show-error --ftp-pasv -T "$f" "$target"
	done
	echo "   uploading $c"
	curl --fail --silent --show-error --ftp-pasv -T "$c" "$target"
done
echo "Launchpad emails the result of each upload to the address on the signing key."
