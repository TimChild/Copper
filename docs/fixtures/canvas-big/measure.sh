#!/usr/bin/env bash
# Run measure.js in the probe's front tab (the canvas): counts, a scripted 5 s
# pan+zoom with rAF p50/p95, counts after settle, WebContent RSS (macOS).
#   SEARCH_PROBE=cfix SEARCH_MCP_PORT=4203 [FIXTURE_PROBE_STARTED=<epoch>] ./measure.sh [--shot /tmp/x.png]
set -euo pipefail
source "$(dirname "$0")/_guard.sh"
exec python3 "$HERE/drive.py" measure "$@"
