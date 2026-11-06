#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tests/isolate-support.sh"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/pigi-proton-regression.XXXXXX")"
trap isolate_support_finish EXIT
isolate_support_snapshot
bash "$ROOT/tools/build-proton-helper.sh" "$TEST_BUILD"
xcrun swiftc -swift-version 5 -parse-as-library \
    "$ROOT/Sources/PigiCore/ProtonHelper.swift" "$ROOT/Sources/PigiCore/ProtonNetworkSettings.swift" "$ROOT/Sources/PigiCore/ProtonVerificationPolicy.swift" "$ROOT/Pigi/ProtonLoginPrompt.swift" "$ROOT/Tests/ProtonLoginRegression.swift" "$ROOT/Tests/ProtonHelperRegression.swift" \
    -o "$TEST_BUILD/proton-helper-regression"
"$TEST_BUILD/proton-helper-regression" "$TEST_BUILD"
