#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
isolate_support_begin "$0" "$@"
SOURCE_DIR="${1:-$ROOT/Pigi}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-panel-regression.XXXXXX")"
trap isolate_support_finish EXIT

SOURCES=()
for source in "$SOURCE_DIR/"*.swift; do
    case "$source" in
        */PigiApp.swift|*/MailCache.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done
while IFS= read -r source; do
    SOURCES+=("$source")
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)

isolate_support_swiftc -swift-version 5 -O -D PIGI_REGRESSION -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/PanelLayoutRegression.swift" \
    -o "$TEST_BUILD/pigi-panel-regression"

for scope in all account; do
    for unread in 0 1 12 120; do
        "$TEST_BUILD/pigi-panel-regression" "$unread" "$scope"
    done
done
