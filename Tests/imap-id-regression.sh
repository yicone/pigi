#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
isolate_support_begin "$0" "$@"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-imap-id-regression.XXXXXX")"
trap isolate_support_finish EXIT
isolate_support_swiftc -swift-version 5 -D DEBUG -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$ROOT/Sources/PigiCore/Engine/ImapConnection.swift" "$ROOT/Tests/ImapIDRegression.swift" \
    -o "$TEST_BUILD/imap-id-regression"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$TEST_BUILD/key.pem" -out "$TEST_BUILD/cert.pem" 2>/dev/null
python3 "$ROOT/Tests/imap_id_regression.py" "$TEST_BUILD"
