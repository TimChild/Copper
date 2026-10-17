#!/bin/bash
# The 1Password extension in Copper, hop by hop, without anyone's account:
# a COPY of the installed extension loaded under its real id in a fresh
# SEARCH_PROBE world, a stand-in native host, a headless Copper.
#
#   1. The extension loads and runs its native host the way Chrome would
#      (its own origin as the argument) — a stand-in that only listens.
#   2. A canvas tab open beside it: WebKit is never handed a view built
#      without the extension controller ("… is not configured with a
#      WKWebExtensionController" stays out of the log).
#   3. Extensions page › 1Password › Sign In… opens
#      my.1password.com/signin?auth-only=1 and 1Password's content script
#      runs there and gets its answer from the worker.
#   4. A made-up email: the page asks for Secret Key and password.
#   5. What the web app sends the extension after a sign-in
#      (B5SignInSucceeded) reaches the worker with its tab, and the worker
#      takes it as far as 1Password's servers, which turn the made-up
#      Secret Key down (the copy's logging is unredacted for this).
#   6. Use the 1Password App… sends the extension's partner-browser request
#      (NmAuthorizePartnerBrowser) to the native host.
#
# Needs the network (my.1password.com) and the extension installed in the
# main Copper (or COPPER_1P_EXTENSION=folder). COPPER_1P_REAL_HOST=1 talks to
# the real 1Password BrowserSupport instead of the stand-in (step 6 then shows
# up in 1Password's own BrowserSupport log; a dev build is refused there).
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
id=aeblfdkhhhdcdjpifhhbdiojplfjncoa
source_ext="${COPPER_1P_EXTENSION:-$HOME/Library/Application Support/Copper/Extensions/$id}"
world="onepass-$$"
tmp="$(mktemp -d)"
pid=""
started=$(date '+%Y-%m-%d %H:%M:%S')
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.officecommun.search.test.$world.plist"
  rm -rf "$HOME/Library/Application Support/Copper ($world)" "$tmp"
  local hash=2166136261 i byte
  for ((i = 0; i < ${#world}; i++)); do
    printf -v byte '%d' "'${world:i:1}"
    hash=$(( ((hash ^ byte) * 16777619) & 0xFFFFFFFF ))
  done
  local stem; stem=$(printf '5E4C%04X-%04X' $((hash >> 16)) $((hash & 0xFFFF)))
  local kit="$HOME/Library/WebKit/com.collinrijock.copper.dev"
  rm -rf "$kit/WebExtensions/$stem-"* "$kit/WebsiteDataStore/$(tr 'A-F' 'a-f' <<<"$stem")-"*
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

[ -f "$source_ext/manifest.json" ] || { echo "SKIP no 1Password extension at $source_ext"; exit 0; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  if ! (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1; then
    fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
  fi
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build: no Copper executable at $app"

# The stand-in host: notes how it was run and every byte it is sent, and
# never answers — what BrowserSupport does for a browser it doesn't know.
mkdir -p "$tmp/hosts"
cat >"$tmp/hosts/stand-in.sh" <<EOF
#!/bin/bash
echo "\$@" >>"$tmp/host-args.log"
exec cat >>"$tmp/host-frames.log"
EOF
chmod +x "$tmp/hosts/stand-in.sh"
printf '{"name":"com.1password.1password","path":"%s","type":"stdio","allowed_origins":["chrome-extension://%s/"]}\n' \
  "$tmp/hosts/stand-in.sh" "$id" >"$tmp/hosts/com.1password.1password.json"
hosts=(SEARCH_NATIVE_HOSTS="$tmp/hosts")
[ "${COPPER_1P_REAL_HOST:-0}" = 1 ] && hosts=()

# The copy, under its real id (the native host lets only that origin in).
support="$HOME/Library/Application Support/Copper ($world)"
mkdir -p "$support/Extensions"
cp -R "$source_ext" "$support/Extensions/$id"
version=$(jq -r .version "$support/Extensions/$id/manifest.json")
printf '[{"id":"%s","name":"1Password – Password Manager","version":"%s","enabled":true,"fromStore":false,"pinned":true,"permissions":[]}]\n' \
  "$id" "$version" >"$support/Extensions/installed.json"
# The copy only: the worker's "Error handling request" line says what went
# wrong instead of "<redacted>", by way of an uncaught error the shim lists.
uvx --quiet python - "$support/Extensions/$id/background/background.js" <<'PY' || echo "note: couldn't unredact the copy's errors; step 5 checks less"
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'console.error("[Background]",`${a} Error handling request: ${v(m)}`)'
new = '(setTimeout(()=>{throw new Error("UNREDACTED "+String(m&&(m.message||m))+" "+(()=>{try{return JSON.stringify(m)}catch(e){return ""}})())},0),' + old + ')'
if text.count(old) != 1: sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
env ${hosts[@]+"${hosts[@]}"} SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
reported() { bench extensions | jq -r --arg id "$id" '.extensions[] | select(.id == $id) | (.reported + .errors)[]'; }
tab_at() { bench tabs | grep -F -- "$1" | tail -1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{8}$/) { print $i; exit } }'; }

# 1. Loaded, and its native host run as Chrome runs it.
loaded=""
for _ in {1..40}; do
  loaded=$(bench extensions | jq -r --arg id "$id" '.extensions[] | select(.id == $id) | .loaded')
  [ "$loaded" = true ] && break; sleep 0.25
done
[ "$loaded" = true ] || fail "the 1Password copy did not load"
if [ ${#hosts[@]} -gt 0 ]; then
  for _ in {1..60}; do [ -s "$tmp/host-args.log" ] && break; sleep 0.5; done
  grep -qF "chrome-extension://$id/" "$tmp/host-args.log" 2>/dev/null || fail "the extension never ran its native host with its origin"
  echo "ok 1Password $version loaded as $id and ran its native host ($(head -1 "$tmp/host-args.log"))"
else
  echo "ok 1Password $version loaded as $id (real native host)"
fi

# 2. A canvas tab beside it.
bench canvas open >/dev/null
sleep 3

# 3. Sign In… from the Extensions page.
bench ext-manager onepassword signin >/dev/null
signin=""
for _ in {1..40}; do signin=$(tab_at "https://my.1password.com/signin?auth-only=1"); [ -n "$signin" ] && break; sleep 0.25; done
[ -n "$signin" ] || fail "Sign In… opened no sign-in tab"
answered=""
for _ in {1..80}; do
  answered=$(bench eval "$signin" 'document.body && document.body.dataset.onepasswordExtensionVersion || ""' 2>/dev/null || true)
  [ -n "$answered" ] && break; sleep 0.25
done
[ -n "$answered" ] || fail "1Password's content script did not run on the sign-in page, or the worker never answered it"
echo "ok Sign In… opens the auth-only page; its content script ran and the worker answered (build $answered)"

# 4. A made-up email (tried again until the page's form takes it).
type_email='(() => { const i = document.querySelector("input[type=email]"); const go = [...document.querySelectorAll("button")].find((b) => b.innerText.trim() === "Continue"); if (!i || !go) return "not yet"; const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set; i.focus(); set.call(i, "copper-probe@example.invalid"); i.dispatchEvent(new Event("input", { bubbles: true })); go.click(); return "typed"; })()'
fields=""
for attempt in {1..12}; do
  bench eval "$signin" "$type_email" >/dev/null 2>&1 || true
  for _ in {1..8}; do
    fields=$(bench eval "$signin" '[...document.querySelectorAll("input")].map((i) => i.type + ":" + i.id).join(",")' 2>/dev/null || true)
    grep -q "account-key" <<<"$fields" && grep -q "password:" <<<"$fields" && break 2
    sleep 0.25
  done
done
grep -q "account-key" <<<"$fields" && grep -q "password:" <<<"$fields" || fail "the sign-in page did not ask for Secret Key and password (fields: $fields)"
echo "ok a made-up email gets the Secret Key and password form"

# 5. The web app's hand-over, made up.
bench eval "$signin" 'document.dispatchEvent(new CustomEvent("B5SignInSucceeded", { detail: { authOnly: true, accountUuid: "ABCDEFGHJKLMNPQRSTVWXYZ234", userUuid: "BCDEFGHJKLMNPQRSTVWXYZ2345", email: "copper-probe@example.invalid", domain: "my.1password.com", accountKey: "A3-ABCDEF-GHJKLM-NPQRS-TVWXY-Z2345-6789A", masterPassword: "not-a-real-password" } })); 1' >/dev/null
seen=""
for _ in {1..80}; do
  seen=$(reported | grep -E "UNREDACTED|Exception while handling request <sign-in-succeeded>" || true)
  grep -q "UNREDACTED" <<<"$seen" && break; sleep 0.25
done
grep -q "sign-in-succeeded" <<<"$(reported)" || fail "the worker never handled sign-in-succeeded"
if grep -q "lack of TabInfo\|lack of FrameInfo" <<<"$seen"; then fail "the worker had no tab for the sign-in page: $(grep -m1 'TabInfo\|FrameInfo' <<<"$seen" | cut -c1-200)"; fi
why=$(grep -m1 -o 'UNREDACTED [^@]*' <<<"$seen" | cut -c1-160 || true)
grep -q "SecretKeyIdOrFormatIsWrong\|_handleStartAuthResponse" <<<"$seen" \
  && echo "ok the hand-over reached the worker with its tab and went to 1Password's servers, which refused the made-up Secret Key" \
  || echo "ok the hand-over reached the worker (it answered: ${why:-redacted})"

# 6. Use the 1Password App… — the partner-browser request.
bench ext-manager onepassword connect "$id" >/dev/null
if [ ${#hosts[@]} -gt 0 ]; then
  for _ in {1..40}; do grep -qa "NmAuthorizePartnerBrowser" "$tmp/host-frames.log" 2>/dev/null && break; sleep 0.25; done
  grep -qa "NmAuthorizePartnerBrowser" "$tmp/host-frames.log" 2>/dev/null || fail "Use the 1Password App… sent no partner-browser request to the host"
  echo "ok Use the 1Password App… sends NmAuthorizePartnerBrowser to the native host"
else
  sleep 8
  echo "ok asked the real host: $(bench ext-manager onepassword status | jq -c .)"
  logs="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/BrowserSupport"
  ls -t "$logs" 2>/dev/null | head -4 | while read -r f; do cat "$logs/$f"; done | grep -E 'Verifying browser|partner|not valid|UnsupportedBrowser' | sort | tail -4 | cut -c1-220 | sed 's/^/   BrowserSupport: /' || true
fi

# The Extensions page with 1Password's details open, when asked for.
if [ -n "${COPPER_1P_PICTURE:-}" ]; then
  bench ext-manager manage >/dev/null; bench ext-manager expand "$id" >/dev/null; sleep 1.5
  bench ext-manager picture "$COPPER_1P_PICTURE" >/dev/null && echo "ok drew the Extensions page to $COPPER_1P_PICTURE"
fi

# 2, checked last: nothing WebKit refused the whole run.
refused=$(log show --start "$started" --style compact --predicate "processID == $pid AND eventMessage CONTAINS \"is not configured with a WKWebExtensionController\"" 2>/dev/null | grep -c "not configured" || true)
[ "${refused:-0}" -eq 0 ] || fail "WebKit was handed $refused views without the extension controller"
echo "ok no view without the extension controller reached WebKit (canvas tab open)"
echo "ok 1Password e2e"
