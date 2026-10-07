#!/bin/bash
# A fresh, private SEARCH_PROBE world. No live Chrome or Copper files are read.
# Build first: ./build.sh, then docs/fixtures/flow-bookmarks-e2e.sh [app-path].
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=${1:-"$ROOT/build/Copper.app"}
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required for tree assertions"; exit 1; }
TMP=$(mktemp -d)
WORLD="flowbm-$(date +%s)-$$"
HOME_WORLD="$HOME/Library/Application Support/Copper ($WORLD)"
DOMAIN="com.officecommun.search.test.$WORLD"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    case "$(ps -p "$PID" -o command= 2>/dev/null)" in
      "$APP/Contents/MacOS/Copper"*) kill "$PID"; wait "$PID" 2>/dev/null || true ;;
    esac
  fi
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  rm -rf "$HOME_WORLD" "$TMP"
}
if [ -e "$HOME_WORLD" ]; then
  echo "FAIL: probe world already exists"
  rm -rf "$TMP"
  exit 1
fi
trap cleanup EXIT
mkdir -p "$TMP/chrome" "$HOME_WORLD"
cp -R "$ROOT/docs/fixtures/flow-chrome/." "$TMP/chrome/"
# Flow discovers profiles through Preferences, not bookmark files. The copied
# fixture gets only these two markers; the checked-in fixture adds bookmark
# files only (and may also hold Default metadata from a sibling fixture).
printf '{}\n' > "$TMP/chrome/Profile 1/Preferences"
printf '{}\n' > "$TMP/chrome/Profile 2/Preferences"
# A personally saved Copper bookmark is not import-owned. It must survive both
# the first import and a later import that replaces its own previous roots.
printf '[{"id":"11111111-1111-4111-8111-111111111111","title":"Owned","url":"https://owned.example/","children":null}]\n' > "$HOME_WORLD/bookmarks.json"
defaults write "$DOMAIN" bench -bool true
defaults write "$DOMAIN" welcomed -bool true
SEARCH_PROBE="$WORLD" SEARCH_HEADLESS=1 "$APP/Contents/MacOS/Copper" >"$TMP/copper.log" 2>&1 &
PID=$!
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
ready=0
for _ in $(seq 1 60); do if B tabs >/dev/null 2>&1; then ready=1; break; fi; sleep 0.5; done
[ "$ready" = 1 ] || { echo "FAIL: headless probe did not start"; tail -15 "$TMP/copper.log"; exit 1; }
check() {
  local label=$1 expression=$2 input=$3
  if printf '%s\n' "$input" | jq -e "$expression" >/dev/null; then echo "ok: $label";
  else echo "FAIL: $label"; printf '%s\n' "$input"; exit 1; fi
}
ROOT_RESULT=$(B flow root --source Chrome --path "$TMP/chrome")
check 'bookmark-only profiles discovered without Login Data' '.profiles | index("Profile 1") != null and index("Profile 2") != null' "$ROOT_RESULT"
SCAN=$(B flow scan --source Chrome)
check 'scan counts all 12 sites, not root nodes' '.bookmarks == 12' "$SCAN"
MOVE=$(B flow move --source Chrome --only bookmarks)
check 'move and scan use the same reader' '.bookmarks == 12' "$MOVE"
TREE=$(B flow bookmarks)
check 'Copper bar has account then local then next profile, no Chrome wrapper' \
  '.count == 13 and [.roots[].title] == ["Owned", "Alpha", "Projects", "Shared", "Local", "Beta", "Other", "Mobile"]' "$TREE"
check 'nested folders retain their children and order' \
  '.roots[2].children | [.[] | .title] == ["Work", "Extra"] and .[0].children[0].title == "Launch" and .[0].children[0].children[0].url == "https://deep.example/"' "$TREE"
check 'Other and Mobile keep merged profile roots' \
  '.roots[6].children | [.[] | .title] == ["Reading", "Offline", "Second other"]' "$TREE"
check 'Mobile items are kept in order' \
  '.roots[7].children | [.[] | .title] == ["Phone", "Pocket", "Second mobile"]' "$TREE"
check 'non-http entries and duplicate URL+title skipped' \
  '[.. | objects | .url? // empty] | all(. | startswith("http")) and (map(select(. == "https://shared.example/")) | length == 1)' "$TREE"
# Change the source copy, not Copper or Chrome, then re-import. Only the
# previous import's own untouched roots may be removed and replaced.
jq '(.roots.bookmark_bar.children[0].name) = "Alpha updated"' \
  "$TMP/chrome/Profile 1/AccountBookmarks" > "$TMP/new-bookmarks"
mv "$TMP/new-bookmarks" "$TMP/chrome/Profile 1/AccountBookmarks"
REPEAT=$(B flow move --source Chrome --only bookmarks)
check 're-import reports the same 12 source sites' '.bookmarks == 12' "$REPEAT"
AFTER=$(B flow bookmarks)
check 're-import replaces its previous roots, not the owned bookmark' \
  '.count == 13 and [.roots[].title] == ["Owned", "Alpha updated", "Projects", "Shared", "Local", "Beta", "Other", "Mobile"]' "$AFTER"
echo 'ok: flow Chrome bookmark import end to end'
