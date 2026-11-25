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

echo "==> resolving package dependencies (local SwiftPM package referenced by project)"
swift package resolve

echo "==> generating Xcode project via xcodegen"
# 用 xcodegen 从 project.yml 生成 HGTV.xcodeproj（保证 pbxproj 格式正确）
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
xcodegen generate
xcodebuild -project HGTV.xcodeproj -list 2>/dev/null || true

echo "==> xcodebuild archive (project HGTV.xcodeproj, ${CONFIG}, tvOS device arm64)"
rm -rf "${ARCHIVE}"
# 用真正的 Xcode app 工程（HGTV.xcodeproj）归档，产出规范 tvOS .app。
# 裸 SwiftPM 可执行包 archive 出来是命令行工具（usr/local/bin），不是 .app。
# 2>&1 全量落盘（错误诊断关键——tail -60 曾把全部 Swift error 截掉）+ pipefail 保留失败码
set -o pipefail
xcodebuild archive \
  -project HGTV.xcodeproj \
  -scheme HGTV \
  -configuration "${CONFIG}" \
  -destination 'generic/platform=tvOS' \
  -archivePath "${ARCHIVE}" \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  SKIP_INSTALL=NO \
  2>&1 | tee "$PWD/build_full.log" | tail -60
BUILD_EXIT=${PIPESTATUS[0]}

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "==> ================= 全部编译 error 行（来自 build_full.log）================="
  grep -E "error:" "$PWD/build_full.log" | grep -viE "warning" | head -60
  echo "==> ================= error 行结束 ================="
fi

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