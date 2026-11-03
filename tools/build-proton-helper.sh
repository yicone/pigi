#!/bin/bash
# Build an offline-launchable universal helper. No account credentials needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/proton-helper}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
bash "$ROOT/tools/proton-spike/prepare.sh"
cd "$ROOT/tools/proton-spike"
GO_BIN="${GO_BIN:-go}"
for arch in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" "$GO_BIN" build -mod=readonly -trimpath -buildvcs=false \
        -ldflags='-s -w' -o "$OUT/helper-$arch" ./cmd/pigi-proton-helper
done
python3 "$ROOT/tools/proton-spike/audit-dependencies.py" "$OUT"
lipo -create "$OUT/helper-arm64" "$OUT/helper-amd64" -output "$OUT/pigi-proton-helper"
codesign --force --sign - --options runtime "$OUT/pigi-proton-helper"
codesign --verify --strict "$OUT/pigi-proton-helper"
lipo "$OUT/pigi-proton-helper" -verify_arch arm64 x86_64
