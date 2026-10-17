#!/usr/bin/env bash
# Serve the canvas-big fixture's pages and images (the live frames' content)
# on 127.0.0.1 only. Python 3 standard library; no network needed.
#
#   ./serve.sh            # foreground (Ctrl-C stops it)
#   ./serve.sh start      # background; pid in out/serve.pid, log in out/serve.log
#   ./serve.sh stop       # stop the background server (only the pid it started)
#   ./serve.sh status
#
# FIXTURE_PORT (default 8765) — gen.py's --base must match (default
# http://127.0.0.1:8765). Builds out/www with `gen.py --www-only` if missing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${FIXTURE_OUT:-$HERE/out}"
WWW="$OUT/www"
PORT="${FIXTURE_PORT:-8765}"
PIDFILE="$OUT/serve.pid"
cmd="${1:-fg}"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$cmd" in
  stop)
    if running; then kill "$(cat "$PIDFILE")" && echo "serve: stopped pid $(cat "$PIDFILE")"; else echo "serve: not running"; fi
    rm -f "$PIDFILE"; exit 0 ;;
  status)
    if running; then echo "serve: pid $(cat "$PIDFILE") on http://127.0.0.1:$PORT/"; else echo "serve: not running"; exit 1; fi
    exit 0 ;;
  fg|start) ;;
  *) echo "usage: $0 [fg|start|stop|status]" >&2; exit 2 ;;
esac

[[ -f "$WWW/index.html" ]] || python3 "$HERE/gen.py" --www-only --out "$OUT"

# Web fonts, off-network: copy a local system font in once (never committed).
# Pages fall back to Georgia/Menlo/serif when none is found.
mkdir -p "$WWW/fonts"
pick() { for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return; }; done; }
serif="$(pick /System/Library/Fonts/Supplemental/Georgia.ttf /System/Library/Fonts/Supplemental/Times\ New\ Roman.ttf \
  /usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf /usr/share/fonts/dejavu/DejaVuSerif.ttf /usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf)"
mono="$(pick /System/Library/Fonts/Supplemental/Courier\ New.ttf /System/Library/Fonts/Supplemental/Andale\ Mono.ttf \
  /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf /usr/share/fonts/dejavu/DejaVuSansMono.ttf /usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf)"
[[ -n "$serif" && ! -f "$WWW/fonts/fixture-serif.ttf" ]] && cp "$serif" "$WWW/fonts/fixture-serif.ttf"
[[ -n "$mono" && ! -f "$WWW/fonts/fixture-mono.ttf" ]] && cp "$mono" "$WWW/fonts/fixture-mono.ttf"

if [[ "$cmd" == start ]]; then
  if running; then echo "serve: already running, pid $(cat "$PIDFILE")"; exit 0; fi
  nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW" >"$OUT/serve.log" 2>&1 &
  echo $! >"$PIDFILE"
  for _ in $(seq 1 50); do
    if python3 -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:$PORT/index.html', timeout=1)" 2>/dev/null; then
      echo "serve: pid $(cat "$PIDFILE") on http://127.0.0.1:$PORT/ ($WWW)"; exit 0
    fi
    sleep 0.1
  done
  echo "serve: did not come up; see $OUT/serve.log" >&2; exit 1
fi
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WWW"
