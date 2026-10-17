#!/bin/sh
# Records `startup.lrec`: the app opening `vault/` as a remembered vault, no clicks.
#
# The vault is copied to a fixed path first, so the recording names that path and not
# the machine it was made on; the app's data directory is a fresh one holding only the
# remembered vault and its grant. `pnpm run test:replay` plays it back against the page.
# Record again when the page's calls change on purpose.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$here/../.." && pwd)
lepton="$project/../../target/release/lepton"
vault=/tmp/lepton-notes-fixture/vault
data=$(mktemp -d)
log="$data/record.log"

rm -rf /tmp/lepton-notes-fixture
mkdir -p "$vault"
cp -R "$here/vault/." "$vault/"
mkdir -p "$data/dev.lepton.notes"
printf '{"root":"%s","recent":["%s"]}\n' "$vault" "$vault" >"$data/dev.lepton.notes/vault.json"
printf 'd %s\n' "$vault" >"$data/dev.lepton.notes/lepton-grants"
chmod 600 "$data/dev.lepton.notes/vault.json" "$data/dev.lepton.notes/lepton-grants"

rm -f "$here/startup.lrec"
cd "$project"
XDG_DATA_HOME="$data" "$lepton" record --unmasked -o test/fixtures/startup.lrec >"$log" 2>&1 &
pid=$!
# The window line comes once the page is loading; its start-up calls end well within 6 s.
tries=0
until grep -q "window" "$log"; do
  tries=$((tries + 1))
  [ "$tries" -gt 300 ] && { cat "$log"; kill "$pid"; exit 1; }
  sleep 1
done
sleep 6
kill -TERM "$pid"
wait "$pid" || true
rm -rf "$data" /tmp/lepton-notes-fixture
echo "recorded $here/startup.lrec"
