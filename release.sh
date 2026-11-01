#!/bin/bash
# 构建 Release 包并生成本地更新信息。此 fork 已关闭在线更新，--publish 会失败，不会上传。
# 用法: ./release.sh [--publish] [更新说明]    版本号取根目录 VERSION 第 1 行
set -euo pipefail
cd "$(dirname "$0")"
PUBLISH=0
[ "${1:-}" = "--publish" ] && { PUBLISH=1; shift; }
if [ "$PUBLISH" = 1 ]; then
  echo "此 fork 已关闭在线更新，不会上传到上游更新源。" >&2
  exit 1
fi
NOTES="${1:-}"
VERSION="$(head -1 VERSION | tr -d '[:space:]')"
BUILD="$(date +%y%m%d%H%M)"
FILE="Pigi-$VERSION-macos-universal.zip"
SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)
if [ -n "${PIGI_SIGNING_IDENTITY:-}" ]; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$PIGI_SIGNING_IDENTITY")
  [ -z "${PIGI_DEVELOPMENT_TEAM:-}" ] || SIGNING+=("DEVELOPMENT_TEAM=$PIGI_DEVELOPMENT_TEAM")
fi

xcodegen generate >/dev/null
xcodebuild -quiet -project Pigi.xcodeproj -scheme Pigi -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "${SIGNING[@]}" build
APP="build/Build/Products/Release/pigi.app"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/pigi" -verify_arch arm64 x86_64
lipo "$APP/Contents/Helpers/pigi-proton-helper" -verify_arch arm64 x86_64
"$APP/Contents/MacOS/pigi" --proton-helper-selftest

OUT="build/release"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/$FILE"
if [ -n "${PIGI_NOTARY_PROFILE:-}" ]; then
  if [ -z "${PIGI_SIGNING_IDENTITY:-}" ] || [ "$PIGI_SIGNING_IDENTITY" = "-" ]; then
    echo 'Notarization requires a Developer ID signing identity.' >&2
    exit 1
  fi
  # Profile names are not credentials. Secrets stay in the user's Keychain.
  xcrun notarytool submit "$OUT/$FILE" --keychain-profile "$PIGI_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute "$APP"
  ditto -c -k --keepParent "$APP" "$OUT/$FILE"
fi
SIZE="$(stat -f%z "$OUT/$FILE")"
SHA="$(shasum -a 256 "$OUT/$FILE" | cut -d' ' -f1)"
python3 - "$VERSION" "$BUILD" "$NOTES" "$SIZE" "$SHA" "$(date +%Y-%m-%d)" "$FILE" "$OUT/latest.json" <<'PY'
import json, sys
version, build, notes, size, sha, date, filename, path = sys.argv[1:]
with open(path, 'w') as output:
    json.dump(dict(version=version, build=int(build), notes=notes, size=int(size), sha256=sha, date=date, file=filename), output)
PY
echo "已打包 $OUT/$FILE ($SIZE 字节)"
