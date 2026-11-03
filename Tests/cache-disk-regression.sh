#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-proton-sync.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SOURCES=()
for source in "$ROOT/Pigi/"*.swift; do
    case "$source" in
        */PigiApp.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done
while IFS= read -r source; do
    case "$source" in
        */Keychain.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)
xcrun swiftc -D CACHE_DISK_REGRESSION -swift-version 5 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/ProtonSyncRegression.swift" "$ROOT/Tests/CacheDiskRegression.swift" -o "$TEST_BUILD/proton-sync-regression"
mkdir -p "$TEST_BUILD/home"
CFFIXED_USER_HOME="$TEST_BUILD/home" "$TEST_BUILD/proton-sync-regression" "$TEST_BUILD/home"
