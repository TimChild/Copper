# Sourced by apply.sh and measure.sh: refuse anything but a PROBE Copper, and
# find the copper CLI. Never point these at the everyday browser.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
if [[ -z "${SEARCH_PROBE:-}" ]]; then
  echo "refusing: SEARCH_PROBE is not set — this fixture only drives a probe world (never the live Copper)." >&2
  exit 2
fi
if [[ -z "${SEARCH_MCP_PORT:-}" || "${SEARCH_MCP_PORT}" == 4123 ]]; then
  echo "refusing: set SEARCH_MCP_PORT to the probe's own port (not 4123, the everyday Copper's)." >&2
  exit 2
fi
if [[ "$(uname -s)" == Linux && -z "${COPPER_WORLD:-}" ]]; then
  echo "refusing: on Linux set COPPER_WORLD=<name> too (the default world is a real profile)." >&2
  exit 2
fi
if [[ -z "${COPPER_BIN:-}" ]]; then
  for c in "$REPO/build/Copper.app/Contents/Resources/bin/copper" "$(command -v copper 2>/dev/null || true)"; do
    [[ -n "$c" && -x "$c" ]] && { COPPER_BIN="$c"; break; }
  done
fi
[[ -n "${COPPER_BIN:-}" && -x "$COPPER_BIN" ]] || { echo "no copper CLI: set COPPER_BIN" >&2; exit 2; }
export COPPER_BIN SEARCH_PROBE SEARCH_MCP_PORT
"$COPPER_BIN" health >/dev/null 2>&1 || { echo "probe Copper not answering on port $SEARCH_MCP_PORT ($COPPER_BIN health failed)" >&2; exit 2; }
