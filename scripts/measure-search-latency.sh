#!/usr/bin/env bash
# Measures global search end to end on a temporary 10,000-file Vault (#83).
# See docs/search-performance.md. Never touches your Vault or a running Notess:
# the app is hosted inside the test process, in a temporary folder.
#
# Usage: scripts/measure-search-latency.sh [debug|release] [report.md]
#   debug    the build `swift test` uses (default)
#   release  optimised like the shipped app (`-c release` with testing enabled)
# The Markdown report is printed and written to report.md
# (default: build/search-latency-<configuration>.md).
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report="${2:-$root/build/search-latency-$configuration.md}"
case "$report" in
    /*) ;;
    *) report="$PWD/$report" ;;
esac

case "$configuration" in
    debug) build_flags=() ;;
    release) build_flags=(-c release -Xswiftc -enable-testing) ;;
    *) echo "Usage: scripts/measure-search-latency.sh [debug|release] [report.md]" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$report")"
cd "$root"
NOTESS_SEARCH_LATENCY=1 NOTESS_SEARCH_LATENCY_REPORT="$report" \
    swift test ${build_flags[@]+"${build_flags[@]}"} --no-parallel --filter "SearchLatencyTests/tenThousandFiles"
echo "Report: $report"
