#!/bin/bash
# 编译 Debug 版 pigi.app。本机有自签证书 "Pigi Local Signing" 时用它签名，
# 让多次重编译保持同一签名身份（钥匙串“始终允许”只需授权一次）；否则退回 ad-hoc。
# 只编译与校验，不启动、不退出、不杀任何 pigi 进程。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
IDENTITY_NAME="Pigi Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY_NAME")
  echo "签名身份: $IDENTITY_NAME"
else
  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)
  echo "未找到 \"$IDENTITY_NAME\"，退回 ad-hoc 签名（每次重编译钥匙串都会重新要求授权）。"
fi

xcodegen generate >/dev/null
xcodebuild -quiet -project Pigi.xcodeproj -scheme Pigi -configuration Debug -derivedDataPath build \
  "${SIGNING[@]}" build

APP="build/Build/Products/Debug/pigi.app"
HELPER="$APP/Contents/Helpers/pigi-proton-helper"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$HELPER"
echo "签名校验通过。designated requirement:"
codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => /  app:    /p'
codesign -dr - "$HELPER" 2>/dev/null | sed -n 's/^designated => /  helper: /p'
echo "已编译 $APP"
