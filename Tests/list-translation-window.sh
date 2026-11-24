#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
isolate_support_begin "$0" "$@"
EVIDENCE="${1:-$ROOT/../list-translation-evidence}"
mkdir -p "$EVIDENCE"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-list-window.XXXXXX")"
trap isolate_support_finish EXIT
SOURCES=()
for source in "$ROOT/Pigi/"*.swift; do
    case "$source" in
        */PigiApp.swift|*/MailCache.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done
while IFS= read -r source; do
    case "$source" in
        */Keychain.swift) ;;
        *) SOURCES+=("$source") ;;
    esac
done < <(find "$ROOT/Sources/PigiCore" -name '*.swift' | sort)
isolate_support_swiftc -swift-version 5 -O -D PIGI_REGRESSION -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${SOURCES[@]}" -lsqlite3 -lz "$ROOT/Tests/ListTranslationWindowRegression.swift" \
    -o "$TEST_BUILD/list-translation-window"
isolate_support_env "$TEST_BUILD/home" -- "$TEST_BUILD/list-translation-window" "$EVIDENCE"
status=$?
if [[ "$status" -eq 0 ]]; then
    isolated="$TEST_BUILD/home/Library/Application Support/pigi/translations.db"
    if [[ -e "$isolated" ]]; then
        echo "FAIL: shared translations.db was created; the window harness must use the injected cache" >&2
        status=1
    fi
fi
exit "$status"
