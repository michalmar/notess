#!/usr/bin/env bash
# Builds an Apple Silicon preview with a drag-to-Applications disk image.
# Env: OUTPUT_DIR, BUILD_NUMBER and CODESIGN_IDENTITY (see build-app.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIR:-$root/build}"
app="$output_dir/Notess.app"

cd "$root"
BUILD_ARCH=arm64 "$root/scripts/build-app.sh" release
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")"
binary="$app/Contents/MacOS/Notess"
architectures="$(lipo -archs "$binary")"
deployment_target="$(xcrun vtool -show-build "$binary" | awk '/minos/ { print $2 }')"
if [[ "$architectures" != arm64 || "$deployment_target" != "$minimum_os" ]]; then
    echo "Expected arm64 with deployment target $minimum_os; got $architectures targeting $deployment_target." >&2
    exit 1
fi
dmg="$output_dir/Notess-${version}-${build_number}-arm64.dmg"

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/notess-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$app" "$staging_dir/Notess.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create -volname Notess -srcfolder "$staging_dir" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"

echo "Built $dmg"
