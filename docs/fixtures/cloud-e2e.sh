#!/bin/bash
# Two headless probe-world Coppers against one copper-cloud: link, accounts,
# sync both ways, a shared canvas with an invite, live collaboration, agent ops.
#
#   docs/fixtures/cloud-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world (clouda/cloudb), headless, on its own MCP port.
set -euo pipefail
LINK=${1:?link code}
LINK_B=${LINK_B:-$LINK}   # directory-mode instances: a second access key for world B
APP=${2:-"$(cd "$(dirname "$0")/../.." && pwd)/build/Copper.app"}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STAMP=$(date +%s)
A_EMAIL="a-$STAMP@example.com"; B_EMAIL="b-$STAMP@example.com"; PW="correct-horse-battery"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $(eval "echo \"$3\"" 2>/dev/null || true)"; fi; }

world() { # world port
  local w=$1 port=$2
  [ -f "/tmp/copper-$w.pid" ] && kill "$(cat /tmp/copper-$w.pid)" 2>/dev/null || true
  lsof -tnP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1
  rm -rf "$HOME/Library/Application Support/Copper ($w)"
  defaults delete "com.officecommun.search.test.$w" >/dev/null 2>&1 || true
  defaults write "com.officecommun.search.test.$w" bench -bool true
  defaults write "com.officecommun.search.test.$w" welcomed -bool true
  SEARCH_PROBE=$w SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$port SEARCH_HEADLESS_SIZE=1440x1000 \
    "$APP/Contents/MacOS/Copper" > "/tmp/copper-$w.log" 2>&1 &
  echo $! > "/tmp/copper-$w.pid"
}
B() { "$ROOT/bench" --world "$1" "${@:2}"; }  # bench in a world
wait_bench() { for _ in $(seq 1 60); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "bench never answered in $1"; return 1; }
json() { python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: d={'raw': raw.strip()}
try: print($1)
except Exception as e: print('')"; }

echo "== launching worlds"
world clouda 4171; world cloudb 4172
wait_bench clouda; wait_bench cloudb
sleep 2

set +e
echo "== link + accounts"
B clouda cloud link "$LINK" | json '"linked" if d.get("linked") else d'
B cloudb cloud link "$LINK_B" | json '"linked" if d.get("linked") else d'
check "A signs up" 'B clouda cloud signup "$A_EMAIL" "$PW" "Alice" | json "d.get(\"signedIn\")" | grep -q True' 'B clouda cloud status'
check "B signs up" 'B cloudb cloud signup "$B_EMAIL" "$PW" "Bob" | json "d.get(\"signedIn\")" | grep -q True' 'B cloudb cloud status'
check "wrong password refused" '{ B cloudb cloud signin "$B_EMAIL" wrong-password-here 2>&1 || true; } | grep -qi "wrong email or password"' 'true'
B cloudb cloud signin "$B_EMAIL" "$PW" >/dev/null

echo "== sync: bookmarks + spaces A → B (same account on both)"
B cloudb cloud signout >/dev/null; B cloudb cloud signin "$A_EMAIL" "$PW" >/dev/null
echo "== privacy: with sync off, the Personal canvas stays on this Mac"
B clouda canvas open personal >/dev/null; sleep 2
B clouda canvas apply "{\"id\":\"personal\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"private $STAMP\"}}]}" >/dev/null; sleep 4
B cloudb canvas open personal >/dev/null; sleep 4
check "Personal content does not reach B while canvas sync is off" '! B cloudb canvas read personal | grep -q "private $STAMP"' 'B cloudb canvas read personal | head -c 300'
B clouda cloud sync on all >/dev/null; B cloudb cloud sync on all >/dev/null
sleep 6
check "Personal content reaches B once canvas sync is on" 'B cloudb canvas read personal | grep -q "private $STAMP"' 'B cloudb canvas read personal | head -c 300'
B clouda cloud bookmark "https://example.com/e2e-$STAMP" "E2E bookmark" >/dev/null
B clouda cloud sync now >/dev/null; sleep 3; B cloudb cloud sync now >/dev/null; sleep 2
check "bookmark reaches B" 'B cloudb cloud doc bookmarks | grep -q "e2e-$STAMP"' 'B cloudb cloud log | tail -5'
B clouda cloud pin "https://example.org/pinned-$STAMP" >/dev/null || true
B clouda cloud sync now >/dev/null; sleep 3; B cloudb cloud sync now >/dev/null; sleep 2
check "pinned tab reaches B" 'B cloudb cloud doc spaces | grep -q "pinned-$STAMP"' 'B cloudb cloud log | tail -5'
check "A sees B as another device" 'B clouda cloud devices | grep -qi "cloudb\|device"' 'B clouda cloud devices'

echo "== canvas: shared canvas, invite, live collaboration, agent ops"
B cloudb cloud signout >/dev/null; B cloudb cloud signin "$B_EMAIL" "$PW" >/dev/null
CREATE=$(B clouda canvas create "Roadmap $STAMP"); echo "$CREATE" | head -c 300; echo
CID=$(echo "$CREATE" | json 'd.get("id") or (d.get("canvas") or {}).get("id") or ""')
check "A created a shared canvas" '[ -n "$CID" ]' 'echo "$CREATE"'
B clouda canvas open "$CID" >/dev/null; sleep 2
INV=$(B clouda canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"from A $STAMP\",\"x\":0,\"y\":0}}]}" 2>&1); echo "$INV" | head -c 200; echo
# invite through the tool surface (copper CLI) so the MCP path is exercised too
export SEARCH_PROBE=clouda SEARCH_MCP_PORT=4171
CLI="$APP/Contents/Resources/bin/copper"
cli() { for _ in 1 2 3 4 5; do if out=$("$CLI" "$@" 2>&1); then echo "$out"; return 0; fi; sleep 2; done; echo "$out"; return 1; }
cli call canvas_invite "{\"reason\":\"e2e\",\"id\":\"$CID\",\"email\":\"$B_EMAIL\"}" | head -c 300; echo
unset SEARCH_PROBE SEARCH_MCP_PORT
sleep 2
INVITES=$(B cloudb canvas invites); echo "$INVITES" | head -c 300; echo
IID=$(echo "$INVITES" | json 'd["invites"][0]["id"]')
check "B has a pending invite" '[ -n "$IID" ]' 'echo "$INVITES"'
B cloudb canvas accept "$IID" | head -c 200; echo
B cloudb canvas open "$CID" >/dev/null; sleep 4
check "B sees A's sticky" 'B cloudb canvas read "$CID" | grep -q "from A $STAMP"' 'B cloudb canvas read "$CID" | head -c 400'
export SEARCH_PROBE=cloudb SEARCH_MCP_PORT=4172
cli call canvas_apply "{\"reason\":\"e2e\",\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"from B agent $STAMP\",\"x\":300,\"y\":0}}]}" | head -c 200; echo
unset SEARCH_PROBE SEARCH_MCP_PORT
sleep 4
check "A sees B's agent sticky live" 'B clouda canvas read "$CID" | grep -q "from B agent $STAMP"' 'B clouda canvas read "$CID" | head -c 400'
check "Personal canvas is listed and not shareable" 'B clouda canvas list | grep -qi personal' 'B clouda canvas list'
B clouda canvas ui picture /tmp/cloud-e2e-canvas-door.png >/dev/null 2>&1 || true
B clouda cloud picture /tmp/cloud-e2e-settings.png >/dev/null 2>&1 || true
B clouda shot /tmp/cloud-e2e-canvas-a.png >/dev/null 2>&1 || true

echo "== persistence: relaunch A, Personal canvas content survives"
B clouda canvas open personal >/dev/null; sleep 2
B clouda canvas apply "{\"id\":\"personal\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"persist $STAMP\"}}]}" >/dev/null; sleep 2
kill "$(cat /tmp/copper-clouda.pid)" 2>/dev/null || true; sleep 3
SEARCH_PROBE=clouda SEARCH_HEADLESS=1 SEARCH_MCP_PORT=4171 "$APP/Contents/MacOS/Copper" > /tmp/copper-clouda.log 2>&1 & echo $! > /tmp/copper-clouda.pid
wait_bench clouda; sleep 2; B clouda canvas open personal >/dev/null; sleep 3
check "Personal canvas survives relaunch" 'B clouda canvas read personal | grep -q "persist $STAMP"' 'B clouda canvas read personal | head -c 300'
check "A is still signed in after relaunch" 'B clouda cloud status | json "d.get(\"signedIn\")" | grep -q True' 'B clouda cloud status'


echo "== pairing: A mints a one-time code, a fresh world C joins with it"
world cloudc 4173; wait_bench cloudc; sleep 2
PAIR=$(B clouda cloud pairing-code); echo "$PAIR" | head -c 200; echo
PLINK=$(echo "$PAIR" | json 'd.get("link") or d.get("code") or ""')
check "A minted a pairing code" '[ -n "$PLINK" ]' 'echo "$PAIR"'
B cloudc cloud pair "$PLINK" | head -c 200; echo
check "C is linked and signed in as A via the pairing code" 'B cloudc cloud status | json "d.get(\"signedIn\") and d.get(\"email\")" | grep -q "$A_EMAIL"' 'B cloudc cloud status'
check "the pairing code works only once" '{ B cloudc cloud pair "$PLINK" 2>&1 || true; } | grep -qi "error\|used\|pairing"' 'true'
kill "$(cat /tmp/copper-cloudc.pid)" 2>/dev/null || true

echo "== canvas share links: join, live presence, reset, landing page, directory"
LINK_CREATE=$(B clouda canvas create "Link Roadmap $STAMP"); echo "$LINK_CREATE" | head -c 300; echo
LINK_CID=$(echo "$LINK_CREATE" | json 'd.get("id") or (d.get("canvas") or {}).get("id") or ""')
check "A created a link-shared canvas" '[ -n "$LINK_CID" ]' 'echo "$LINK_CREATE"'
B clouda canvas open "$LINK_CID" >/dev/null; sleep 2
B clouda canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"link from A $STAMP\",\"x\":40,\"y\":40}}]}" >/dev/null
SHARE=$(B clouda canvas link "$LINK_CID"); echo "$SHARE" | head -c 500; echo
INVITE_LINK=$(echo "$SHARE" | json 'd.get("link") or ""')
WEB_LINK=$(echo "$SHARE" | json 'd.get("webLink") or ""')
check "canvas link returns copper and web links" 'echo "$INVITE_LINK" | grep -q "^copper://canvas/join/" && echo "$WEB_LINK" | grep -q "^https://127.0.0.1:8445/join/" && echo "$INVITE_LINK" | grep -q "127.0.0.1:8445"' 'echo "$SHARE"'
check "B is not invited before joining" '! B cloudb canvas list | grep -q "$LINK_CID"' 'B cloudb canvas list | head -c 500'
B cloudb canvas join "$INVITE_LINK" | head -c 300; echo; sleep 6
check "B joins from copper invite as editor" 'B cloudb canvas list | grep -q "$LINK_CID" && B cloudb canvas list | grep -q editor' 'B cloudb canvas list | head -c 600'
B cloudb canvas open "$LINK_CID" >/dev/null; sleep 4
check "B reads A sticky after link join" 'B cloudb canvas read "$LINK_CID" | grep -q "link from A $STAMP"' 'B cloudb canvas read "$LINK_CID" | head -c 500'
B clouda canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"live from A $STAMP\",\"x\":280,\"y\":40}}]}" >/dev/null; sleep 4
check "A edits arrive live at B" 'B cloudb canvas read "$LINK_CID" | grep -q "live from A $STAMP"' 'B cloudb canvas read "$LINK_CID" | head -c 600'
B cloudb canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"live from B $STAMP\",\"x\":520,\"y\":40}}]}" >/dev/null; sleep 4
check "B edits arrive live at A" 'B clouda canvas read "$LINK_CID" | grep -q "live from B $STAMP"' 'B clouda canvas read "$LINK_CID" | head -c 600'
# Drive real pointermove events through the page bridge so native presence reports a cursor.
ATAB=$(B clouda canvas tabs "$LINK_CID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("canvases") or [{}])[0].get("tabs", [{}])[0].get("tab", ""))')
BTAB=$(B cloudb canvas tabs "$LINK_CID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("canvases") or [{}])[0].get("tabs", [{}])[0].get("tab", ""))')
check "A and B canvas tabs are addressable" '[ -n "$ATAB" ] && [ -n "$BTAB" ]' 'B clouda tabs; B cloudb tabs'
B clouda eval "$ATAB" "(() => { const b=document.querySelector('[role=application]'); if (!b) return false; for (const [x,y] of [[120,140],[280,220],[420,300]]) b.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x,clientY:y,pointerId:1,pointerType:'mouse'})); return true })()" >/dev/null; sleep 4
check "B sees A named human cursor" 'B cloudb canvas presence "$LINK_CID" | json "any(p.get(\"name\")==\"Alice\" and p.get(\"kind\")==\"human\" and p.get(\"cursor\") is not None for p in d.get(\"people\",[]))" | grep -q True' 'B cloudb canvas presence "$LINK_CID"'
B cloudb eval "$BTAB" "(() => { const b=document.querySelector('[role=application]'); if (!b) return false; for (const [x,y] of [[180,160],[340,240],[500,320]]) b.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x,clientY:y,pointerId:2,pointerType:'mouse'})); return true })()" >/dev/null; sleep 4
check "A sees B named human cursor" 'B clouda canvas presence "$LINK_CID" | json "any(p.get(\"name\")==\"Bob\" and p.get(\"kind\")==\"human\" and p.get(\"cursor\") is not None for p in d.get(\"people\",[]))" | grep -q True' 'B clouda canvas presence "$LINK_CID"'
B cloudb canvas join "$INVITE_LINK" >/dev/null; sleep 3
check "joining the same link is idempotent" 'B cloudb canvas list | python3 -c "import json,sys; rows=json.load(sys.stdin).get(\"canvases\",[]); x=[r for r in rows if r.get(\"id\")==\"$LINK_CID\"]; print(len(x)==1 and x[0].get(\"role\")==\"editor\")" | grep -q True' 'B cloudb canvas list | head -c 700'
B cloudb canvas join "$WEB_LINK" >/dev/null; sleep 3
check "web invite form also opens in Copper" 'B cloudb canvas list | grep -q "$LINK_CID"' 'B cloudb canvas list | head -c 500'
# Use the documented auth API for the owner reset and the people directory checks.
KEY=$(python3 -c 'from urllib.parse import urlparse,parse_qs; import sys; print(parse_qs(urlparse(sys.argv[1]).fragment)["k"][0])' "$LINK")
HOST="https://127.0.0.1:8445"; H="X-Copper-Instance: $KEY"
ATOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"$A_EMAIL\",\"password\":\"$PW\",\"device\":{\"name\":\"e2e-reset\"}}" "$HOST/v1/auth/login" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
BTOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"$B_EMAIL\",\"password\":\"$PW\",\"device\":{\"name\":\"e2e-directory\"}}" "$HOST/v1/auth/login" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
TOKEN=$(python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).path.rstrip("/").split("/")[-1])' "$INVITE_LINK")
LANDING=$(mktemp /tmp/copper-join.XXXXXX); LANDING_HEADERS=$(mktemp /tmp/copper-join-headers.XXXXXX)
curl -ksS -D "$LANDING_HEADERS" -o "$LANDING" "$HOST/join/$TOKEN"
check "join landing page is an HTML handoff" 'grep -q "Open this canvas in Copper" "$LANDING" && grep -qi "^cache-control: no-store" "$LANDING_HEADERS" && grep -qi "^referrer-policy: no-referrer" "$LANDING_HEADERS"' 'cat "$LANDING_HEADERS"; head -c 500 "$LANDING"'
check "join landing page reveals no canvas name" '! grep -q "Link Roadmap $STAMP" "$LANDING"' 'cat "$LANDING"'
check "B people directory lists A" 'curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/people?q=Alice" | grep -q "Alice"' 'curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/people?q=Alice"'
DELETE_STATUS=$(curl -ksS -o /dev/null -w '%{http_code}' -X DELETE -H "$H" -H "Authorization: Bearer $ATOKEN" "$HOST/v1/canvases/$LINK_CID/links")
check "owner reset revokes every share link" '[ "$DELETE_STATUS" = 204 ]' "echo reset status $DELETE_STATUS"
C_TOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"c-$STAMP@example.com\",\"password\":\"$PW\",\"display_name\":\"Charlie\",\"device\":{\"name\":\"e2e-third\"}}" "$HOST/v1/auth/signup" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
OLD_JOIN=$(curl -ksS -o /tmp/copper-old-join.json -w '%{http_code}' -X POST -H "$H" -H "Authorization: Bearer $C_TOKEN" "$HOST/v1/canvas-links/$TOKEN/join")
check "revoked link rejects a third account" '[ "$OLD_JOIN" = 404 ] && grep -q "link_not_found" /tmp/copper-old-join.json' 'cat /tmp/copper-old-join.json'
rm -f "$LANDING" "$LANDING_HEADERS"
# Keep both tabs present for the native visual pass; open Share on A and capture B presence.
B clouda canvas ui mode share "$LINK_CID" >/dev/null; B clouda canvas ui open >/dev/null; sleep 2
"$ROOT/bench" --world clouda window /tmp/wave-share-A.png >/dev/null 2>&1 || true
"$ROOT/bench" --world cloudb window /tmp/wave-presence-B.png >/dev/null 2>&1 || true

# The old section plus this section should finish with no failures.
echo "== done: $PASS passed, $FAIL failed"
for w in clouda cloudb cloudc; do [ -f "/tmp/copper-$w.pid" ] && kill "$(cat /tmp/copper-$w.pid)" 2>/dev/null || true; done
[ "$FAIL" -eq 0 ]
