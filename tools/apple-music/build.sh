#!/bin/bash
# 构建手机端 HAP，两种模式：
#
#   bash tools/apple-music/build.sh                        # 本地自用（带本机 key / WVD / 本地签名）
#   bash tools/apple-music/build.sh musichomesample public # 分发包（不含任何凭据、不签名）
#
# 分发包 = 把「本机凭据文件」临时换成空模板再构建，产物拷到 dist/ 并自动扫一遍有没有凭据。
cd "$(dirname "$0")/../.." || exit 1
export HVIGOR_USER_HOME=/tmp/hvigor_home
export npm_config_cache=/tmp/npm_cache
export NPM_CONFIG_USERCONFIG=/tmp/npmrc
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default

MODULE="${1:-musichomesample}"
MODE="${2:-local}"

APPLE="common/musicbasic/src/main/ets/apple"
AI_LOCAL="$APPLE/AiKeyLocal.ets"
AI_EXAMPLE="$APPLE/AiKeyLocal.example.ets"
WVD_LOCAL="$APPLE/widevine/WvdLocal.ets"
WVD_EXAMPLE="$APPLE/widevine/WvdLocal.example.ets"
OUT="products/default/build/default/outputs/default"

# 本机凭据文件不存在时用空模板兜底（保证任何机器都能编译）
[ -f "$AI_LOCAL" ] || cp "$AI_EXAMPLE" "$AI_LOCAL"
[ -f "$WVD_LOCAL" ] || cp "$WVD_EXAMPLE" "$WVD_LOCAL"

restore_secrets() {
  if [ -f "$AI_LOCAL.hidden" ]; then mv -f "$AI_LOCAL.hidden" "$AI_LOCAL"; fi
  if [ -f "$WVD_LOCAL.hidden" ]; then mv -f "$WVD_LOCAL.hidden" "$WVD_LOCAL"; fi
}
restore_profile() {
  if [ -f /tmp/build-profile.public.json5 ]; then
    cp /tmp/build-profile.public.json5 build-profile.json5
    rm -f /tmp/build-profile.public.json5
  fi
}

if [ "$MODE" = "public" ]; then
  echo "[build] 分发包模式：临时隐藏本机凭据（AI key / WVD）"
  mv -f "$AI_LOCAL" "$AI_LOCAL.hidden"
  mv -f "$WVD_LOCAL" "$WVD_LOCAL.hidden"
  cp "$AI_EXAMPLE" "$AI_LOCAL"
  cp "$WVD_EXAMPLE" "$WVD_LOCAL"
  trap 'restore_secrets' EXIT INT TERM
else
  # 本地构建：临时套用本机签名（签名配置不入库）
  SIGN_LOCAL="$PWD/build-profile.signing.local.json5"
  if [ -f "$SIGN_LOCAL" ]; then
    cp build-profile.json5 /tmp/build-profile.public.json5
    cp "$SIGN_LOCAL" build-profile.json5
    trap 'restore_profile' EXIT INT TERM
  else
    echo "[build] 没找到 build-profile.signing.local.json5 —— 将构建未签名包（DevEco 里可用自动签名）"
  fi
fi

devecocli build --modules "$MODULE"
CODE=$?

restore_secrets
if [ "$MODE" != "public" ]; then restore_profile; fi
if [ $CODE -ne 0 ]; then
  echo "[build] 构建失败"
  exit $CODE
fi

if [ "$MODE" = "public" ]; then
  mkdir -p dist
  SRC=$(ls -t "$OUT"/*-unsigned.hap 2>/dev/null | head -1)
  if [ -z "$SRC" ]; then
    echo "[build] 没找到未签名产物（$OUT/*-unsigned.hap）"
    exit 1
  fi
  DST="dist/musichome-$(date +%Y%m%d)-public-unsigned.hap"
  cp "$SRC" "$DST"
  echo "[build] 分发包：$DST"
  python3 tools/apple-music/scan-hap-secrets.py "$DST" --expect-clean
  exit $?
fi

echo "[build] 本机包：$OUT/${MODULE}-default-signed.hap"
python3 tools/apple-music/scan-hap-secrets.py "$OUT/${MODULE}-default-signed.hap" || true
exit 0
