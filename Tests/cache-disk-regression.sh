#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-proton-sync.XXXXXX")"
trap isolate_support_finish EXIT
isolate_support_snapshot
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
xcrun swiftc -D CACHE_DISK_REGRESSION -D PIGI_REGRESSION -swift-version 5 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/ProtonSyncRegression.swift" "$ROOT/Tests/CacheDiskRegression.swift" -o "$TEST_BUILD/proton-sync-regression"
status=0
isolate_support_env "$TEST_BUILD/home" -- "$TEST_BUILD/proton-sync-regression" "$TEST_BUILD/home" || status=$?
if [[ "$status" -eq 0 ]]; then
  isolated="$TEST_BUILD/home/Library/Application Support/pigi/translations.db"
  [[ -f "$isolated" ]] || { echo "FAIL: translations.db was not created under the temporary home" >&2; status=1; }
fi
exit "$status"
