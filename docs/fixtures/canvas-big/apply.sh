#!/usr/bin/env bash
# Build the canvas-big board in a PROBE Copper.
#   SEARCH_PROBE=cfix SEARCH_MCP_PORT=4203 [COPPER_BIN=…] ./apply.sh NAME [small|big|huge]
# Creates canvas NAME (canvas_create), opens it in front, applies every
# out/<scale>/ops-NNN.json batch (canvas_apply, timed), focuses the bench view
# (canvas_focus) and reads it back (canvas_read). Report: out/<scale>/apply-NAME-*.json.
# Starts serve.sh in the background if the pages are not being served.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 NAME [small|big|huge]" >&2; exit 2; }
source "$(dirname "$0")/_guard.sh"
python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${FIXTURE_PORT:-8765}/index.html', timeout=1)" 2>/dev/null \
  || "$HERE/serve.sh" start
exec python3 "$HERE/drive.py" apply "$1" "${2:-big}"
