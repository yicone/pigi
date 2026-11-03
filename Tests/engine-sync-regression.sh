#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-engine-sync.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SOURCES=()
while IFS= read -r source; do
    case "$source" in */Keychain.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)
xcrun swiftc -swift-version 5 -D DEBUG -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/EngineSyncRegression.swift" -o "$TEST_BUILD/engine-sync-regression"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$TEST_BUILD/key.pem" -out "$TEST_BUILD/cert.pem" 2>/dev/null
python3 "$ROOT/Tests/engine_sync_regression.py" "$TEST_BUILD"
