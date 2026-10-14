#!/usr/bin/env bash
# Builds Notess.app from the Swift package and signs it without App Sandbox (ADR 0004).
#
# Usage: scripts/build-app.sh [debug|release]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc). For distribution use
#                           "Developer ID Application: …"; hardened runtime is enabled then.
#        OUTPUT_DIR         where to put Notess.app (default: build/)
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIR:-$root/build}"
identity="${CODESIGN_IDENTITY:--}"
app="$output_dir/Notess.app"

cd "$root"
swift build -c "$configuration" --product Notess
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Notess" "$app/Contents/MacOS/Notess"
cp Support/Info.plist "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

sign_args=(--force --sign "$identity" --entitlements Support/Notess.entitlements)
if [[ "$identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"

echo "Built $app"
