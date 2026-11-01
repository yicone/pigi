#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-proton-regression.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
bash "$ROOT/tools/build-proton-helper.sh" "$TEST_BUILD"
xcrun swiftc -swift-version 5 -parse-as-library \
    "$ROOT/Pigi/ProtonHelper.swift" "$ROOT/Tests/ProtonHelperRegression.swift" \
    -o "$TEST_BUILD/proton-helper-regression"
"$TEST_BUILD/proton-helper-regression" "$TEST_BUILD"
