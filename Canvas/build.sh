#!/usr/bin/env bash
# Rebuild the Canvas page into one self-contained file: Canvas/dist/canvas.html.
# The built file is committed, so the app builds without bun; run this after
# changing anything under Canvas/src.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v bun >/dev/null 2>&1; then
  echo "Canvas: bun is not installed; keeping the committed dist/canvas.html" >&2
  exit 0
fi
bun install --frozen-lockfile
bun run build
ls -l dist/canvas.html
