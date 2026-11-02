#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-appearance-regression.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT

SOURCES=()
for source in "$ROOT/Pigi/"*.swift; do
    case "$source" in
        */PigiApp.swift|*/MailCache.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done
while IFS= read -r source; do
    SOURCES+=("$source")
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)

xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/MailAppearanceRegression.swift" \
    -o "$TEST_BUILD/pigi-appearance-regression"
"$TEST_BUILD/pigi-appearance-regression"
