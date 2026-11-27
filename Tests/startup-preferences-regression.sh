#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-startup.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SOURCES=()
while IFS= read -r source; do
    case "$source" in */Keychain.swift|*/CorePreferences.swift) ;; *) SOURCES+=("$source") ;; esac
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)
# Optional source argument lets acceptance reproduce the original crash with
# the old CorePreferences file while keeping the same bundle/fixture harness.
PREFERENCES_SOURCE="${1:-$ROOT/Sources/PigiCore/CorePreferences.swift}"
bash "$ROOT/Tests/isolate-support.sh" xcrun swiftc -disable-sandbox \
    -swift-version 5 -D PIGI_REGRESSION -parse-as-library \
    "${SOURCES[@]}" "$PREFERENCES_SOURCE" "$ROOT/Pigi/AppPreferences.swift" \
    "$ROOT/Tests/StartupPreferencesRegression.swift" -lsqlite3 -lz -o "$TEST_BUILD/probe"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/Tests/startup_preferences_regression.py" "$TEST_BUILD"
