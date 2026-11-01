#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-proton-sync.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SOURCES=()
for source in "$ROOT/Pigi/"*.swift; do
    case "$source" in
        */PigiApp.swift|*/MailCache.swift|*/Keychain.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" "$ROOT/Pigi/Engine/"*.swift -lsqlite3 -lz "$ROOT/Tests/ProtonSyncRegression.swift" -o "$TEST_BUILD/proton-sync-regression"
"$TEST_BUILD/proton-sync-regression" "$@"
