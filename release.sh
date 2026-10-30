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
FILE="Pigi-$VERSION-macos-arm64.zip"
SIGNING=()
if [ -n "${PIGI_SIGNING_IDENTITY:-}" ]; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$PIGI_SIGNING_IDENTITY")
  [ -z "${PIGI_DEVELOPMENT_TEAM:-}" ] || SIGNING+=("DEVELOPMENT_TEAM=$PIGI_DEVELOPMENT_TEAM")
fi

xcodegen generate >/dev/null
xcodebuild -project Pigi.xcodeproj -scheme Pigi -configuration Release -derivedDataPath build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "${SIGNING[@]}" build 2>&1 | grep -E "error:|BUILD"
APP="build/Build/Products/Release/pigi.app"
codesign --verify --deep --strict "$APP"

OUT="build/release"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/$FILE"
SIZE="$(stat -f%z "$OUT/$FILE")"
SHA="$(shasum -a 256 "$OUT/$FILE" | cut -d' ' -f1)"
printf '{"version":"%s","build":%s,"notes":"%s","size":%s,"sha256":"%s","date":"%s","file":"%s"}\n' \
  "$VERSION" "$BUILD" "$NOTES" "$SIZE" "$SHA" "$(date +%Y-%m-%d)" "$FILE" > "$OUT/latest.json"
echo "已打包 $OUT/$FILE ($SIZE 字节)"
