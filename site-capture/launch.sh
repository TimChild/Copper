#!/bin/sh
# Start (or restart) the headless capture instance of Copper — never the one you are using.
#   COPPER_SHOOT=/tmp/copper-shoot SIZE=1440x900 site-capture/launch.sh
# Probe world "sitepics" (own data folder: ~/Library/Application Support/Copper (sitepics)),
# MCP on 4196, the hidpi shim for real 2x pixels and active-looking window controls.
set -eu
SHOOT="${COPPER_SHOOT:-/tmp/copper-shoot}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SHOOT/hidpi"
[ -d "$SHOOT/Copper.app" ] || {
  curl -fsSL -o "$SHOOT/c.zip" https://github.com/copper-browser/Copper/releases/latest/download/copper-macos-arm64.zip
  ditto -x -k "$SHOOT/c.zip" "$SHOOT" && xattr -cr "$SHOOT/Copper.app"
}
[ -f "$SHOOT/hidpi/hidpi.dylib" ] || clang -dynamiclib -fobjc-arc -framework AppKit -o "$SHOOT/hidpi/hidpi.dylib" "$HERE/hidpi.m"
P="$(cat "$SHOOT/PID" 2>/dev/null || true)"
if [ -n "$P" ] && ps -p "$P" -o command= | grep -q "$SHOOT/Copper.app"; then kill "$P"; sleep 2; fi
open -n -g --stderr "$SHOOT/log.txt" \
  --env SEARCH_PROBE=sitepics --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT=4196 \
  --env SEARCH_HEADLESS_SIZE="${SIZE:-1440x900}" \
  --env DYLD_INSERT_LIBRARIES="$SHOOT/hidpi/hidpi.dylib" --env COPPER_SHOOT_ACTIVE=1 \
  "$SHOOT/Copper.app"
sleep 7; pgrep -f "$SHOOT/Copper.app" > "$SHOOT/PID"; echo "capture instance pid $(cat "$SHOOT/PID")"
