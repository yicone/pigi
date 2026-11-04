#!/bin/bash
# 编译 Debug 版 pigi.app。
# 优先选用带 Team ID 的有效 Apple Development 身份，app 与 Proton helper 用同一身份。
# 找不到时明确提示并退回自签 "Pigi Local Signing"；再没有则 ad-hoc。
# 只编译与校验，不启动、不退出、不杀任何 pigi 进程，也不改钥匙串条目。
#
# 演练选证（不编译；夹具只在演练时生效，避免误签）：
#   PIGI_BUILD_DEBUG_DRY_RUN=1 \
#     PIGI_CODESIGN_IDENTITY_FIXTURE='  1) ABC "Pigi Local Signing"' \
#     tools/build-debug.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"

LOCAL_IDENTITY="Pigi Local Signing"

valid_identity_names() {
  local raw
  if [ "${PIGI_BUILD_DEBUG_DRY_RUN:-}" = 1 ] && [ -n "${PIGI_CODESIGN_IDENTITY_FIXTURE:-}" ]; then
    raw="$PIGI_CODESIGN_IDENTITY_FIXTURE"
  else
    raw="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  fi
  printf '%s\n' "$raw" | sed -n 's/.*"\([^"]*\)".*/\1/p'
}

# Team ID 是证书 OU。身份名末尾括号里的 10 位字符不一定等于 OU。
certificate_team_id() {
  local name="$1" subject
  subject="$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"
  printf '%s\n' "$subject" | sed -n 's/.*OU=\([A-Za-z0-9]\{10\}\).*/\1/p' | sed -n '1p'
}

choose_signing() {
  local dev_name team_id dev_count
  CHOSEN_TEAM=""
  dev_name="$(valid_identity_names | grep -E -m 1 '^Apple Development: .+ \([A-Za-z0-9]{10}\)$' || true)"
  team_id=""
  if [ -n "$dev_name" ]; then
    if [ "${PIGI_BUILD_DEBUG_DRY_RUN:-}" = 1 ] && [ -n "${PIGI_CODESIGN_IDENTITY_FIXTURE:-}" ]; then
      team_id="$(printf '%s\n' "$dev_name" | sed -n 's/.*(\([A-Za-z0-9]\{10\}\))$/\1/p')"
    else
      team_id="$(certificate_team_id "$dev_name")"
    fi
  fi
  if [ -n "$dev_name" ] && [ -n "$team_id" ]; then
    dev_count="$(valid_identity_names | grep -E -c '^Apple Development: .+ \([A-Za-z0-9]{10}\)$' || true)"
    # 只把完整身份名交给 xcodebuild。再传 DEVELOPMENT_TEAM 时，Xcode 会按团队
    # 重查这张证书并报 “No certificate for team … matching …”。
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$dev_name")
    CHOSEN_TEAM="$team_id"
    echo "签名身份: ${dev_name}（Team ID ${team_id}）"
    if [ "$dev_count" -gt 1 ]; then
      echo "找到 ${dev_count} 个带 Team ID 的 Apple Development 身份，使用第一条。"
    fi
    return 0
  fi

  if [ -n "$dev_name" ]; then
    echo "找到 Apple Development 身份，但证书没有 Team ID，退回 \"${LOCAL_IDENTITY}\"。"
  else
    echo "未找到带 Team ID 的有效 Apple Development 证书，退回 \"${LOCAL_IDENTITY}\"。"
  fi
  if valid_identity_names | grep -F -x -q -- "$LOCAL_IDENTITY"; then
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$LOCAL_IDENTITY")
    echo "签名身份: $LOCAL_IDENTITY"
    return 0
  fi

  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)
  echo "也未找到 \"${LOCAL_IDENTITY}\"，退回 ad-hoc 签名（每次重编译钥匙串都会重新要求授权）。"
}

signature_field() {
  codesign -dvv "$1" 2>&1 | sed -n "s/^$2=//p" | sed -n '1p'
}

choose_signing

if [ "${PIGI_BUILD_DEBUG_DRY_RUN:-}" = 1 ]; then
  printf '%s\n' "${SIGNING[@]}"
  exit 0
fi

xcodegen generate >/dev/null
xcodebuild -quiet -project Pigi.xcodeproj -scheme Pigi -configuration Debug -derivedDataPath build \
  "${SIGNING[@]}" build

APP="build/Build/Products/Debug/pigi.app"
HELPER="$APP/Contents/Helpers/pigi-proton-helper"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$HELPER"

APP_AUTH="$(signature_field "$APP" Authority)"
APP_TEAM="$(signature_field "$APP" TeamIdentifier)"
HELPER_AUTH="$(signature_field "$HELPER" Authority)"
HELPER_TEAM="$(signature_field "$HELPER" TeamIdentifier)"
CHOSEN_IDENTITY="${SIGNING[1]#CODE_SIGN_IDENTITY=}"

echo "签名校验通过。"
echo "  app:    Authority=${APP_AUTH:-<none>} TeamIdentifier=${APP_TEAM:-<none>}"
echo "  helper: Authority=${HELPER_AUTH:-<none>} TeamIdentifier=${HELPER_TEAM:-<none>}"
echo "designated requirement:"
codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => /  app:    /p'
codesign -dr - "$HELPER" 2>/dev/null | sed -n 's/^designated => /  helper: /p'

if [ "$APP_AUTH" != "$HELPER_AUTH" ] || [ "$APP_TEAM" != "$HELPER_TEAM" ]; then
  echo "app 与 helper 签名身份不一致。" >&2
  exit 1
fi
case "$CHOSEN_IDENTITY" in
  "Apple Development:"*)
    case "$APP_AUTH" in
      "Apple Development:"*) ;;
      *)
        echo "期望 Authority 为 Apple Development，实际为 ${APP_AUTH:-<none>}。" >&2
        exit 1
        ;;
    esac
    if [ -z "$APP_TEAM" ] || [ "$APP_TEAM" = "not set" ]; then
      echo "TeamIdentifier 未设置。" >&2
      exit 1
    fi
    if [ -n "${CHOSEN_TEAM:-}" ] && [ "$APP_TEAM" != "$CHOSEN_TEAM" ]; then
      echo "TeamIdentifier 为 ${APP_TEAM}，与证书 OU ${CHOSEN_TEAM} 不一致。" >&2
      exit 1
    fi
    ;;
esac
echo "已编译 $APP"
