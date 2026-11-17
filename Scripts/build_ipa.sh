#!/bin/bash
# build_ipa.sh — 用 xcodebuild 归档 SwiftPM tvOS 包，产出**规范的** unsigned .ipa
# 运行环境：macOS + Xcode 26（GitHub Actions macos-26 runner 或本地 Mac）
# 产物：dist/HGTV-tvOS-unsigned.ipa
#
# 关键：**不手工拼 .app / Info.plist**。手工拼会缺 tvOS 必需结构（Assets.car /
# PkgInfo / entitlements），并可能混入 iOS 专属键（如 LSRequiresIPhoneOS），
# 导致侧载工具把它当 iOS app 处理、装不上 Apple TV。
# 正确做法：xcodebuild archive 让 Xcode 按 tvOS 规范生成 .app，再从 .xcarchive 取。
# 无签名（unsigned），需 atvloadly/Sideloadly 自签后安装。
set -euo pipefail

APP_NAME="HGTV"
SCHEME="HGTV"           # SwiftPM executable product 名
CONFIG="Release"
DIST="${PWD}/dist"
ARCHIVE="${PWD}/build/HGTV.xcarchive"

echo "==> xcodebuild -version"
xcodebuild -version
echo "==> swift --version"
swift --version
echo "==> tvOS SDK"
xcrun --sdk appletvos --show-sdk-path

echo "==> resolving package dependencies"
swift package resolve

echo "==> detecting available schemes"
# xcodebuild 对裸 SwiftPM 包自动生成的 scheme 名可能是 HGTV / HGTV-Package / HGTVCore。
# 注意：xcodebuild -list 输出每行有前导空格，须先 trim 再精确匹配。
SCHEME_LIST="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/{flag=1;next}/^$/{flag=0}flag' | xargs -I{} echo {} || true)"
echo "available schemes: ${SCHEME_LIST//$'\n'/, }"
if echo "${SCHEME_LIST}" | grep -qx "${SCHEME}"; then
  :
elif echo "${SCHEME_LIST}" | grep -qx "${SCHEME}-Package"; then
  SCHEME="${SCHEME}-Package"
else
  SCHEME="$(echo "${SCHEME_LIST}" | head -1)"
fi
echo "==> using scheme: ${SCHEME}"

echo "==> xcodebuild archive (${CONFIG}, tvOS device arm64)"
rm -rf "${ARCHIVE}"
xcodebuild archive \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -destination 'generic/platform=tvOS' \
  -archivePath "${ARCHIVE}" \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  SKIP_INSTALL=NO \
  2>&1 | tail -60

echo "==> locating archived .app"
echo "==> archive structure:"
find "${ARCHIVE}" -maxdepth 4 | head -60 || true
# 规范 .app 在 xcarchive 的 Products/Applications 下；裸 SwiftPM 包可能装到别处，递归兜底
APP_BUNDLE="$(find "${ARCHIVE}/Products/Applications" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -1 || true)"
if [ -z "${APP_BUNDLE}" ]; then
  echo "WARN: no .app under Products/Applications, searching whole archive..."
  APP_BUNDLE="$(find "${ARCHIVE}" -type d -name '*.app' | head -1 || true)"
fi
if [ -z "${APP_BUNDLE}" ]; then
  echo "ERROR: no .app anywhere in archive"
  exit 1
fi
echo "==> found .app: ${APP_BUNDLE}"

echo "==> verifying tvOS-ness (no iOS-only LSRequiresIPhoneOS)"
PLIST="${APP_BUNDLE}/Info.plist"
if /usr/libexec/PlistBuddy -c "Print :LSRequiresIPhoneOS" "${PLIST}" >/dev/null 2>&1; then
  echo "WARN: .app still has LSRequiresIPhoneOS (iOS-only key)"
fi
echo "==> Info.plist keys:"
/usr/libexec/PlistBuddy -c "Print" "${PLIST}" 2>/dev/null | head -40 || cat "${PLIST}"

echo "==> packaging unsigned ipa"
rm -rf "${DIST}"
mkdir -p "${DIST}/Payload"
cp -R "${APP_BUNDLE}" "${DIST}/Payload/"
cd "${DIST}"
IPA="${APP_NAME}-tvOS-unsigned.ipa"
rm -f "${IPA}"
zip -qry "${IPA}" Payload
cd ..

echo "==> ipa contents:"
unzip -l "${DIST}/${IPA}" | head -30
echo "==> done: ${DIST}/${IPA}"
ls -la "${DIST}/${IPA}"
echo "IPA_PATH=${DIST}/${IPA}" >> "${GITHUB_OUTPUT:-/dev/null}"