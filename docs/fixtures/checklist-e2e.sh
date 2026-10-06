#!/bin/bash
# Checklist cards on a shared canvas, end to end: two headless probe-world
# Coppers of this build (Ada in world a, Grace in world b) and, when one is
# given, an older Copper (world o) against one copper-cloud 0.6.0+. One-click
# picks through real mouse input; two people clicking different rows at once,
# then at the same millisecond together with a REST op — every pick sticks on
# both clients and on the server; cloud /read parity; an older client neither
# draws nor harms the card.
#
#   docs/fixtures/checklist-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world, headless, on its own MCP port, and only the pids this
# script started are ever stopped. CKL_WORLD=NAME names the worlds NAMEa,
# NAMEb, NAMEo (default ckl), CKL_PORT=N puts them on N…N+2 (default 4302).
# OLD_APP=PATH is the older Copper (default /Applications/Copper.app; empty or
# missing skips those checks). CKL_SHOTS=DIR keeps pictures there
# (checklist-*.png).
set -uo pipefail
LINK=${1:?link code}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NEW=${2:-"$ROOT/build/Copper.app"}
OLD=${OLD_APP-/Applications/Copper.app}
[ -n "$OLD" ] && [ ! -x "$OLD/Contents/MacOS/Copper" ] && OLD=""
NAME=${CKL_WORLD:-ckl}; PORT=${CKL_PORT:-4302}
WA="${NAME}a"; WB="${NAME}b"; WO="${NAME}o"
PA=$PORT; PB=$((PORT + 1)); PO=$((PORT + 2))
SHOTS=${CKL_SHOTS:-}
KEY=$(python3 -c 'import sys,urllib.parse as u; f=u.urlparse(sys.argv[1]).fragment; print(dict(p.split("=",1) for p in f.split("&"))["k"])' "$LINK")
HOST=https://$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).netloc)' "$LINK")
STAMP=$(date +%s); PW=correct-horse-battery
A_EMAIL=ada-$STAMP@example.com; B_EMAIL=grace-$STAMP@example.com; O_EMAIL=cy-$STAMP@example.com
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 600 || true)"; fi; }
B(){ "$ROOT/bench" --world "$1" "${@:2}"; }
J(){ python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
start(){ # world port app
  rm -rf "$HOME/Library/Application Support/Copper ($1)"
  defaults delete "com.officecommun.search.test.$1" >/dev/null 2>&1
  defaults write "com.officecommun.search.test.$1" bench -bool true
  defaults write "com.officecommun.search.test.$1" welcomed -bool true
  SEARCH_PROBE=$1 SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$2 SEARCH_HEADLESS_SIZE=1440x1000 "$3/Contents/MacOS/Copper" >"/tmp/copper-$1.log" 2>&1 &
  echo "$! $3" >"/tmp/copper-$1.pid"
  for _ in $(seq 1 60); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "no bench in $1"; return 1; }
stop(){ # only the pid this run started, and only while it is still that Copper
  local pid app; read -r pid app < "/tmp/copper-$1.pid" 2>/dev/null || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$app/Contents/MacOS/Copper"*) kill "$pid";; esac
  for _ in $(seq 1 40); do ps -p "$pid" >/dev/null 2>&1 || break; sleep 0.25; done
  rm -f "/tmp/copper-$1.pid"; }
trap 'stop $WA; stop $WB; stop $WO' EXIT
tab(){ B "$1" canvas tabs | J "[t['tab'] for c in d['canvases'] for t in c['tabs'] if c['id']=='$CID'][0]"; }
summary(){ B "$1" canvas checklist "$2" | J "[(r['label'], r['pick'], r.get('by')) for r in d['checklists'][0]['rows']]"; }
shot(){ [ -n "$SHOTS" ] && mkdir -p "$SHOTS" && { B "$1" drive pane off >/dev/null 2>&1; B "$1" window "$SHOTS/$2" >/dev/null 2>&1; } || true; }

echo "== worlds, link, accounts"
start "$WA" "$PA" "$NEW"; start "$WB" "$PB" "$NEW"; [ -n "$OLD" ] && start "$WO" "$PO" "$OLD"; sleep 2
for w in $WA $WB ${OLD:+$WO}; do B "$w" cloud link "$LINK" >/dev/null; done
B "$WA" cloud signup "$A_EMAIL" $PW "Ada Lovelace" >/dev/null
B "$WB" cloud signup "$B_EMAIL" $PW "Grace Hopper" >/dev/null
[ -n "$OLD" ] && B "$WO" cloud signup "$O_EMAIL" $PW "Cy Older" >/dev/null
CID=$(B "$WA" canvas create "Team dinners $STAMP" | J 'd["id"]')
check "A made a shared canvas" '[ -n "$CID" ]' 'echo none'
B "$WA" canvas open "$CID" >/dev/null; sleep 2
for e in "$B_EMAIL" ${OLD:+"$O_EMAIL"}; do
  SEARCH_PROBE=$WA SEARCH_MCP_PORT=$PA "$NEW/Contents/Resources/bin/copper" call canvas_invite "{\"reason\":\"e2e\",\"id\":\"$CID\",\"email\":\"$e\"}" >/dev/null
done; sleep 2
for w in $WB ${OLD:+$WO}; do I=$(B "$w" canvas invites | J 'd["invites"][0]["id"]'); B "$w" canvas accept "$I" >/dev/null; done

echo "== agent ops on the page (canvas_apply)"
ROWS='[{"label":"Ann","id":"ann"},{"label":"Bob","id":"bob"},{"label":"Cy","id":"cy"},{"label":"Dee","id":"dee"},{"label":"Eve","id":"eve"},{"label":"Fay","id":"fay"}]'
R=$(B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"tue\",\"x\":0,\"y\":0,\"title\":\"Tue\",\"rows\":$ROWS}},{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"wed\",\"x\":360,\"y\":0,\"title\":\"Wed\",\"rows\":$ROWS,\"picks\":{\"Ann\":\"yes\"}}},{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"todo\",\"x\":720,\"y\":0,\"title\":\"Bring\",\"columns\":[\"Done\"],\"rows\":[\"Plates\",\"Napkins\",\"Ice\"],\"picks\":{\"Plates\":true}}}],\"as\":{\"id\":\"agent:planner\",\"name\":\"Planner\"}}")
check "canvas_apply adds three checklists" '[ "$(echo "$R" | J "d[\"applied\"]")" = 3 ]' 'echo "$R"'
for w in $WA $WB; do B "$w" canvas open "$CID" >/dev/null; done; sleep 3
TA=$(tab "$WA"); TB=$(tab "$WB")
for p in "$WA $TA" "$WB $TB"; do set -- $p; B "$1" eval "$2" "(() => { window.copperCanvas.zoomTo(['tue','wed','todo']); return 'ok' })()" >/dev/null; done; sleep 1.2
check "B reads the agent's pick" 'summary "$WB" wed | grep -q "(.Ann., .Yes."' 'summary "$WB" wed'

echo "== real clicks in both worlds at once (different rows)"
( for r in Ann Cy Eve; do B "$WA" canvas check tue Yes $r >/dev/null; done ) & P1=$!
( for r in Bob Dee Fay; do B "$WB" canvas check tue No $r >/dev/null; done ) & P2=$!
wait $P1 $P2; sleep 1.5
WANT="[('Ann', 'Yes', 'Ada Lovelace'), ('Bob', 'No', 'Grace Hopper'), ('Cy', 'Yes', 'Ada Lovelace'), ('Dee', 'No', 'Grace Hopper'), ('Eve', 'Yes', 'Ada Lovelace'), ('Fay', 'No', 'Grace Hopper')]"
check "A has every click" '[ "$(summary "$WA" tue)" = "$WANT" ]' 'summary "$WA" tue'
check "B has every click" '[ "$(summary "$WB" tue)" = "$WANT" ]' 'summary "$WB" tue'
check "one click left the card unselected" '[ "$(B "$WA" canvas read "$CID" | J "d[\"selection\"]")" = "[]" ]' 'B "$WA" canvas read "$CID" | head -c 200'
UNDO=$(B "$WA" canvas check tue Yes Ann | J 'd["checked"]')
check "a second click clears the pick" '[ "$UNDO" = False ]' 'echo $UNDO'
B "$WA" canvas check tue Yes Ann >/dev/null
TICK=$(B "$WA" eval "$TA" "(() => { const t = document.querySelector('[data-id=\"todo\"] .cl-label-text'); return t ? getComputedStyle(t).textDecorationLine : 'none' })()")
check "a ticked to-do row is not struck through" '! echo "$TICK" | grep -q line-through' 'echo "$TICK"'

echo "== the same millisecond: two worlds + a REST op"
TOK=$(curl -sk -X POST "$HOST/v1/auth/login" -H "x-copper-instance: $KEY" -H 'content-type: application/json' -d "{\"email\":\"$B_EMAIL\",\"password\":\"$PW\"}" | J 'd["token"]')
AT=$(python3 -c "import time; print(int(time.time()*1000)+2500)")
JS='(() => { const at = AT; setTimeout(() => { for (const r of ROWS) document.querySelector(`[data-id="wed"] [data-row="${r}"][data-col="COL"]`).click() }, at - Date.now()); return "armed" })()'
B "$WA" eval "$TA" "$(echo "$JS" | sed "s/AT/$AT/; s/ROWS/['bob','dee']/; s/COL/Yes/")" >/dev/null
B "$WB" eval "$TB" "$(echo "$JS" | sed "s/AT/$AT/; s/ROWS/['cy','eve']/; s/COL/No/")" >/dev/null
python3 -c "import time; time.sleep(max(0, $AT/1000 - time.time()))"
curl -sk -X POST "$HOST/v1/canvases/$CID/ops" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"as":{"id":"agent:helper","name":"Helper"},"ops":[{"op":"update","id":"wed","patch":{"picks":{"Fay":"No"}}}]}' >/dev/null
sleep 2
WANT2="[('Ann', 'Yes', 'Planner'), ('Bob', 'Yes', 'Ada Lovelace'), ('Cy', 'No', 'Grace Hopper'), ('Dee', 'Yes', 'Ada Lovelace'), ('Eve', 'No', 'Grace Hopper'), ('Fay', 'No', 'Helper')]"
check "A: all six picks" '[ "$(summary "$WA" wed)" = "$WANT2" ]' 'summary "$WA" wed'
check "B: all six picks" '[ "$(summary "$WB" wed)" = "$WANT2" ]' 'summary "$WB" wed'
SRV=$(curl -sk "$HOST/v1/canvases/$CID/read?ids=wed" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK" | J '[(r["label"], r["pick"], r.get("by")) for r in d["shapes"][0]["rows"]]')
check "cloud /read: all six picks" '[ "$SRV" = "$WANT2" ]' 'echo "$SRV"'
TALLY=$(curl -sk "$HOST/v1/canvases/$CID/read?ids=tue,wed" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK" | J '[s["tally"] for s in d["shapes"]]')
check "cloud tallies" '[ "$TALLY" = "[{'"'"'Yes'"'"': 3, '"'"'No'"'"': 3}, {'"'"'Yes'"'"': 3, '"'"'No'"'"': 3}]" ]' 'echo "$TALLY"'
shot "$WB" checklist-light.png
B "$WB" ui look dark >/dev/null; sleep 1; shot "$WB" checklist-dark.png; B "$WB" ui look light >/dev/null

if [ -n "$OLD" ]; then
  echo "== an older Copper on the same canvas"
  B "$WO" canvas open "$CID" >/dev/null; sleep 4
  check "old client reads no checklist (and does not fail)" '[ "$(B "$WO" canvas read "$CID" | J "[s[\"type\"] for s in d[\"shapes\"]]")" = "[]" ]' 'B "$WO" canvas read "$CID" | head -c 300'
  OLDR=$(B "$WO" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"id\":\"oldnote\",\"text\":\"from an older Copper\"}},{\"op\":\"update\",\"id\":\"tue\",\"patch\":{\"title\":\"x\"}}]}")
  check "old client writes beside it" '[ "$(echo "$OLDR" | J "d[\"applied\"]")" = 1 ]' 'echo "$OLDR"'
  sleep 2
  check "checklists and picks intact after the old client wrote" '[ "$(summary "$WA" wed)" = "$WANT2" ] && [ "$(summary "$WB" tue)" = "$(summary "$WA" tue)" ]' 'summary "$WA" wed'
  check "new clients see the old client's note" 'B "$WB" canvas read "$CID" | grep -q "from an older Copper"' 'B "$WB" canvas read "$CID" | head -c 300'
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
