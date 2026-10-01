#!/bin/bash
# Stamp the release version into a built Copper.app, re-sign it ad hoc, and zip it.
#
#   release/package-app.sh <path/to/Copper.app> <version> <out-dir>
#
# Writes to <out-dir>:
#   copper-<version>-macos-arm64.zip          ditto --keepParent archive
#   copper-<version>-macos-arm64.zip.sha256   "<hex>  <zip name>" (shasum format)
# and prints `has_cli=true|false` on stdout (whether the bundle ships the
# `copper` CLI shim at Contents/Resources/bin/copper — the cask renders its
# `binary` stanza only when it does).
#
# Why stamp: Copper's build.sh writes CFBundleShortVersionString from the
# VERSION file (1.0) and CFBundleVersion from the build clock. Homebrew needs a
# monotonic, unique version per release, so the release workflow derives
# <VERSION>.<YYYYMMDD>.<run_number> and this script stamps that same string
# into the bundle so the About box / MCP serverInfo.version match the cask.
# Editing Info.plist invalidates the ad-hoc signature, hence the re-sign.
set -euo pipefail

app="${1:?usage: package-app.sh <Copper.app> <version> <out-dir>}"
version="${2:?version}"
out="${3:?out-dir}"

[ -d "$app/Contents" ] || { echo "not an app bundle: $app" >&2; exit 1; }
case "$version" in
  [0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
  *) echo "version must look like 1.0.20260924.3, got: $version" >&2; exit 1 ;;
esac

plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
# Why --deep: the bundle has no nested frameworks today, but a future build
# might; --deep keeps the whole tree consistently ad-hoc signed either way.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

if [ -x "$app/Contents/Resources/bin/copper" ]; then has_cli=true; else has_cli=false; fi

mkdir -p "$out"
zip="$out/copper-${version}-macos-arm64.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
( cd "$out" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256" )

echo "stamped $(plutil -extract CFBundleShortVersionString raw -o - "$plist") (build $(plutil -extract CFBundleVersion raw -o - "$plist"))" >&2
echo "packed  $zip ($(du -h "$zip" | cut -f1))" >&2
echo "has_cli=$has_cli"
