#!/usr/bin/env bash
# Builds Notess.app from the Swift package and signs it without App Sandbox (ADR 0004).
#
# Usage: scripts/build-app.sh [debug|release]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc). For distribution use
#                           "Developer ID Application: …"; hardened runtime is enabled then.
#        OUTPUT_DIR         where to put Notess.app (default: build/)
#        BUILD_ARCH         arm64 or x86_64 (default: host architecture)
#        BUILD_NUMBER       override CFBundleVersion in the built app only
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIR:-$root/build}"
identity="${CODESIGN_IDENTITY:--}"
architecture="${BUILD_ARCH:-}"
build_number="${BUILD_NUMBER:-}"
app="$output_dir/Notess.app"

case "$configuration" in
    debug|release) ;;
    *) echo "Usage: scripts/build-app.sh [debug|release]" >&2; exit 1 ;;
esac
case "$architecture" in
    ""|arm64|x86_64) ;;
    *) echo "BUILD_ARCH must be arm64 or x86_64." >&2; exit 1 ;;
esac
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*(\.[0-9]+){0,2}$ ]]; then
    echo "BUILD_NUMBER must contain one to three numeric components, starting with a positive integer." >&2
    exit 1
fi

swift_args=(-c "$configuration")
if [[ -n "$architecture" ]]; then
    swift_args+=(--arch "$architecture")
fi

cd "$root"
swift build "${swift_args[@]}" --product Notess
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Notess" "$app/Contents/MacOS/Notess"
cp Support/Info.plist "$app/Contents/Info.plist"
if [[ -n "$build_number" ]]; then
    plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
fi
plutil -lint -s "$app/Contents/Info.plist"

sign_args=(--force --sign "$identity" --entitlements Support/Notess.entitlements)
if [[ "$identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"

echo "Built $app"
