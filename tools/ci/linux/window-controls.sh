#!/usr/bin/env bash
# The three title bar buttons of a page that draws its own (`windowControls`, ci-page.ts),
# clicked with real input on Linux: minimize, maximize, restore, close (exit 0).
#
# For an X11 window: Servo's (`--servo`; under Wayland it runs on XWayland), where
# `"window": { "decorations": false }` takes the system's bar away. WPE WebKit's window
# on Wayland cannot be driven from outside (no protocol lets another program click it),
# and WPE does not yet leave the frame to the page: check its buttons by hand
# (docs/durum.md lists what to click and what must happen).
#
# A project to run it on:
#   lepton new ci-app --template vanilla-ts --target webview --non-interactive && cd ci-app
#   cp <lepton>/tools/ci/ci-page.ts src/ && echo 'import "./ci-page.ts";' >> src/main.ts
#   lepton.config.json: "window": { "decorations": false }, and under "permissions"
#     window.minimize, window.maximize, window.unmaximize, window.state, window.close,
#     window.start_drag, window.menu
#   npm install -D @lepton-desk/servo-linux-x64 && npx lepton build --linux --servo
#   <lepton>/tools/ci/linux/window-controls.sh src-lepton/zig-out/bin/ci-app
#
# Needs xdotool and xprop (Arch: xdotool xorg-xprop; Debian/Ubuntu: xdotool x11-utils).
set -u
app=${1:?usage: window-controls.sh <built app>}
for tool in xdotool xprop; do
  command -v "$tool" > /dev/null || { echo "needs $tool"; exit 2; }
done

failures=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
# until <seconds> <command...>: retries the command every 0.2 s.
until_true() {
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do
    [ $SECONDS -ge $deadline ] && return 1
    sleep 0.2
  done
}
state() { xprop -id "$win" _NET_WM_STATE 2> /dev/null; }
hidden() { state | grep -q _NET_WM_STATE_HIDDEN; }
shown() { ! hidden; }
maximized() { state | grep -q _NET_WM_STATE_MAXIMIZED_VERT && state | grep -q _NET_WM_STATE_MAXIMIZED_HORZ; }
restored() { ! maximized; }
# The page's buttons (ci-page.ts): 46 px each at the right end of its 32 px bar.
click_button() {
  local from
  case $1 in minimize) from=115 ;; maximize) from=69 ;; close) from=23 ;; esac
  eval "$(xdotool getwindowgeometry --shell "$win")"
  xdotool mousemove --sync $((X + WIDTH - from)) $((Y + 16)) click 1
}

"$app" > /tmp/window-controls.log 2>&1 &
pid=$!
win=$(timeout 60 xdotool search --sync --onlyvisible --pid "$pid" | head -1)
[ -n "$win" ] || { echo "FAIL no window for pid $pid after 60 s"; kill "$pid"; exit 1; }
sleep 3
echo "## $(uname -sr), ${XDG_SESSION_TYPE:-?} session, window $win: $(xdotool getwindowname "$win")"
xdotool windowactivate --sync "$win"

click_button minimize
if until_true 5 hidden; then ok "the page's minimize button minimized"; else fail "minimize: $(state)"; fi
xdotool windowactivate --sync "$win"
until_true 5 shown || fail "the window did not come back"
sleep 0.7

click_button maximize
if until_true 5 maximized; then ok "the page's maximize button maximized"; else fail "maximize: $(state)"; fi
sleep 0.7
click_button maximize
if until_true 5 restored; then ok "pressed again, it restored"; else fail "restore: $(state)"; fi
sleep 0.5

click_button close
if until_true 15 bash -c "! kill -0 $pid 2> /dev/null"; then
  wait "$pid"; code=$?
  if [ "$code" = 0 ]; then ok "the page's close button closed the app: exit 0"; else fail "close: exit $code"; fi
else
  fail "still running 15 s after the close button"; kill "$pid"
fi
[ "$failures" = 0 ] && echo "## all checks passed" || { echo "## $failures failed"; exit 1; }
