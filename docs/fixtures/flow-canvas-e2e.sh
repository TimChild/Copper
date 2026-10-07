#!/bin/bash
# Chrome Flow → a local, foreground, once-only guide. Uses a generated one-tab
# Chromium session, never a real Chrome folder or the user's Copper world.
# Run after ./build.sh: docs/fixtures/flow-canvas-e2e.sh [build/Copper.app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=${1:-"$ROOT/build/Copper.app"}
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "Build Copper.app first: $APP" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/sfc-flow.XXXXXX")
WORLD="sfcflow$(date +%s)$$"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
      "$APP/Contents/MacOS/Copper"*) kill "$PID" 2>/dev/null || : ;;
    esac
  fi
  rm -rf "$TEMP" # only this script's private mktemp folder
  # and the world this script made up: a unique name, never the user's own
  defaults delete "com.officecommun.search.test.$WORLD" >/dev/null 2>&1 || :
  rm -rf "$HOME/Library/Application Support/Copper ($WORLD)"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$TEMP/copper.log" ] || tail -n 12 "$TEMP/copper.log" >&2; exit 1; }
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
# JSON::PP is shipped with macOS Perl. Each invocation consumes stdin and
# produces a small scalar; canvas read contains large inline image data URLs.
J() { perl -MJSON::PP -0777 -ne 'BEGIN { $expr = shift @ARGV } my $d = decode_json($_); my $v = eval $expr; die $@ if $@; print defined($v) ? $v : ""' "$1" -; }
PROFILE="$TEMP/Chrome/Default"
mkdir -p "$PROFILE/Sessions"
printf '{"profile":{"name":"Default"}}\n' > "$PROFILE/Preferences"
# Chromium v1 SNSS commands: one window/tab + selected navigation. The
# pickle navigation has the tab id, URL, UTF-16 title, empty page state and
# a transition number. No network URL is loaded by Flow's sleeping tab.
perl -e '
  use strict; use warnings;
  sub cmd { my ($id,$p) = @_; return pack("vC", length($p)+1, $id).$p }
  sub field { my ($s) = @_; my $p = pack("V",length($s)).$s; return $p.("\0" x ((4-length($s)%4)%4)) }
  sub field16 { my ($s) = @_; my $p = pack("v*", unpack("C*", $s)); return pack("V",length($s)).$p.("\0" x ((4-length($p)%4)%4)) }
  my $url = "https://example.invalid/from-chrome";
  my $title = "Fixture";
  my $nav = pack("V2", 7, 0).field($url).field16($title).pack("V2",0,0);
  $nav = pack("V",length($nav)).$nav;
  print "SNSS",pack("V",1),cmd(0,pack("V2",1,7)),cmd(2,pack("V2",7,0)),
        cmd(8,pack("V2",1,0)),cmd(6,$nav);
' > "$PROFILE/Sessions/Current Session"

# A unique world and defaults suite (not even the shared 'test' probe world).
# Headless suppresses activation and all macOS dialogs.
defaults write "com.officecommun.search.test.$WORLD" bench -bool true
defaults write "com.officecommun.search.test.$WORLD" welcomed -bool true
SEARCH_PROBE="$WORLD" SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$((42000 + $$ % 10000)) \
  "$APP/Contents/MacOS/Copper" > "$TEMP/copper.log" 2>&1 &
PID=$!
ready=0
for _ in $(seq 1 60); do
  if B tabs >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = 1 ] || fail "headless app did not start (log: $TEMP/copper.log)"
B flow root --source Chrome --path "$TEMP/Chrome" > "$TEMP/root.json"
[ "$(J '$d->{locked} ? 1 : 0' < "$TEMP/root.json")" = 0 ] || fail "fake Chrome root locked"
[ "$(J 'scalar @{$d->{profiles}}' < "$TEMP/root.json")" = 1 ] || fail "fake Chrome profile not detected"
B flow scan --source Chrome > "$TEMP/scan.json"
[ "$(J '$d->{tabs}' < "$TEMP/scan.json")" = 1 ] || fail "fixture tab not read: $(<"$TEMP/scan.json")"

B flow move --source Chrome --only tabs,bookmarks,history > "$TEMP/first.json"
CID=$(J '$d->{canvasId}' < "$TEMP/first.json")
export SFC_CID="$CID"
[ -n "$CID" ] || fail "Flow did not return a canvas id: $(<"$TEMP/first.json")"
[ "$(J '$d->{tabs}' < "$TEMP/first.json")" = 1 ] || fail "move did not import the tab"
B canvas list > "$TEMP/list.json"
[ "$(J 'scalar grep { $_->{name} eq "Switching from Chrome" && $_->{id} eq $ENV{SFC_CID} && $_->{kind} eq "local" } @{$d->{canvases}}' < "$TEMP/list.json")" = 1 ] || fail "guide missing or not local"
B canvas tabs "$CID" > "$TEMP/tabs.json"
[ "$(J '$d->{canvases}[0]{tabs}[0]{active} ? 1 : 0' < "$TEMP/tabs.json")" = 1 ] || fail "guide is not the foreground tab"
B canvas read "$CID" > "$TEMP/read.json"
N=$(J 'scalar @{$d->{shapes}}' < "$TEMP/read.json")
[ "$N" = 73 ] || fail "expected 73 shapes (60 adds + 13 arrows), got $N"
echo "ok: Chrome move imported 1 tab; guide $CID local, foreground, 73 shapes"

# An owner's edit must survive a second Flow move; reopening is not applying.
B canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"id\":\"sfc_e2e_own_edit\",\"type\":\"sticky\",\"text\":\"My note\"}}]}" > "$TEMP/edit.json"
[ "$(J '$d->{applied}' < "$TEMP/edit.json")" = 1 ] || fail "could not edit guide"
B canvas rename "$CID" "My Chrome guide" > /dev/null
B flow move --source Chrome --only tabs,bookmarks,history > "$TEMP/second.json"
[ "$(J '$d->{canvasId}' < "$TEMP/second.json")" = "$CID" ] || fail "second move created another canvas"
B canvas list > "$TEMP/list.json"
[ "$(J 'scalar grep { $_->{id} eq $ENV{SFC_CID} && $_->{name} eq "My Chrome guide" && $_->{kind} eq "local" } @{$d->{canvases}}' < "$TEMP/list.json")" = 1 ] || fail "renamed guide was not reused"
[ "$(J 'scalar grep { $_->{name} eq "Switching from Chrome" } @{$d->{canvases}}' < "$TEMP/list.json")" = 0 ] || fail "duplicate guide"
B canvas read "$CID" > "$TEMP/read.json"
N=$(J 'scalar @{$d->{shapes}}' < "$TEMP/read.json")
[ "$N" = 74 ] || fail "second move reapplied ops or erased edit: $N shapes"
[ "$(J 'scalar grep { $_->{id} eq "sfc_e2e_own_edit" && $_->{text} eq "My note" } @{$d->{shapes}}' < "$TEMP/read.json")" = 1 ] || fail "owner edit lost"
B canvas tabs "$CID" > "$TEMP/tabs.json"
[ "$(J '$d->{canvases}[0]{tabs}[0]{active} ? 1 : 0' < "$TEMP/tabs.json")" = 1 ] || fail "second move did not reopen guide in front"
echo "ok: second move reused renamed $CID; edited board has 74 shapes and stays in front"
