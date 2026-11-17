#!/bin/bash
# stamp_version.sh — 构建后处理：把自然数版本号 v{N} 写进 .app 的 Info.plist，
# 并把 dist 里的 ipa 重命名为 HGTV-tvOS-v{N}-unsigned.ipa。
# 由 CI 在 build_ipa.sh 之后调用；也可本地手动跑。
# 用法： HGTV_VERSION=3 APP_NAME=HGTV ./Scripts/stamp_version.sh
set -euo pipefail

APP_NAME="${APP_NAME:-HGTV}"
DIST="${PWD}/dist"
# 版本号来源：CI 传 HGTV_VERSION（github.run_number）；本地缺省读 dist 里已有 ipa 推断，否则 1
VERSION="${HGTV_VERSION:-}"

if [ -z "${VERSION}" ]; then
  echo "WARN: HGTV_VERSION 未设置，尝试推断"
  EXISTING="$(ls "${DIST}"/${APP_NAME}-tvOS-v*-unsigned.ipa 2>/dev/null | head -1 || true)"
  if [ -n "${EXISTING}" ]; then
    VERSION="$(echo "${EXISTING}" | sed -E 's/.*-v([0-9]+)-unsigned\.ipa/\1/')"
  else
    VERSION=1
  fi
fi

echo "==> stamping version v${VERSION}"

APP_PATH="${DIST}/Payload/${APP_NAME}.app"
PLIST="${APP_PATH}/Info.plist"

if [ ! -f "${PLIST}" ]; then
  # archive 产物可能还没拷到 dist/Payload，尝试从 .app 直接找
  FOUND="$(find "${DIST}" -type d -name "${APP_NAME}.app" | head -1 || true)"
  if [ -n "${FOUND}" ]; then
    APP_PATH="${FOUND}"
    PLIST="${APP_PATH}/Info.plist"
  fi
fi

if [ -f "${PLIST}" ]; then
  PB=/usr/libexec/PlistBuddy
  # CFBundleVersion = 自然数构建号（每次构建 +1）
  "${PB}" -c "Set :CFBundleVersion ${VERSION}" "${PLIST}" 2>/dev/null \
    || "${PB}" -c "Add :CFBundleVersion string ${VERSION}" "${PLIST}"
  # CFBundleShortVersionString = 1.0.{N}（用户可见版本）
  "${PB}" -c "Set :CFBundleShortVersionString 1.0.${VERSION}" "${PLIST}" 2>/dev/null \
    || "${PB}" -c "Add :CFBundleShortVersionString string 1.0.${VERSION}" "${PLIST}"
  echo "==> Info.plist 版本已更新: CFBundleVersion=${VERSION}, ShortVersion=1.0.${VERSION}"
else
  echo "WARN: 未找到 Info.plist（${PLIST}），跳过 stamp"
fi

# 重新打包成带版本号的 ipa
cd "${DIST}"
rm -rf Payload_tmp
# 确保 Payload 目录存在且含最新 .app
mkdir -p Payload
rm -f ${APP_NAME}-tvOS*-unsigned.ipa
IPA="${APP_NAME}-tvOS-v${VERSION}-unsigned.ipa"
rm -f "${IPA}"
zip -qry "${IPA}" Payload
cd ..
echo "==> packaged: ${DIST}/${IPA}"
ls -la "${DIST}/${IPA}"
echo "IPA_PATH=${DIST}/${IPA}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "HGTV_VERSION=${VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}"