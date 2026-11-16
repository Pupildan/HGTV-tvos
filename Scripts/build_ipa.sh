#!/bin/bash
# build_ipa.sh — 编译 SwiftPM tvOS 包并组装成 unsigned .ipa
# 运行环境：macOS + Xcode 26（GitHub Actions macos-26 runner 或本地 Mac）
# 产物：dist/HGTV-tvOS-unsigned.ipa
#
# 说明：SwiftPM 包用 xcodebuild 编译（xcodebuild 能直接吃 Package.swift），
# 产物可执行文件再手工组装成 .app + Payload 打成 unsigned ipa。
# 无签名（unsigned），需 AltStore/SideStore 自签后安装。
set -euo pipefail

APP_NAME="HGTV"
BUNDLE_ID="com.hgtv.star.tvos"
SCHEME="HGTV"          # SwiftPM executable product 名
CONFIG="Release"
DIST="${PWD}/dist"
DERIVED="${PWD}/build/DerivedData"

echo "==> xcodebuild -version"
xcodebuild -version
echo "==> swift --version"
swift --version
echo "==> tvOS SDK"
xcrun --sdk appletvos --show-sdk-path

echo "==> resolving package dependencies"
swift package resolve

echo "==> detecting available schemes"
# xcodebuild 对裸 SwiftPM 包自动生成的 scheme 名可能是 HGTV / HGTV-Package / HGTVCore，
# 假设错会直接失败，故探测可用 scheme，优先取与产品名一致的。
SCHEME_LIST="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/{flag=1;next}/^$/{flag=0}flag' || true)"
echo "available schemes: ${SCHEME_LIST//$'\n'/, }"
if echo "${SCHEME_LIST}" | grep -qx "${SCHEME}"; then
  :
elif echo "${SCHEME_LIST}" | grep -qx "${SCHEME}-Package"; then
  SCHEME="${SCHEME}-Package"
elif echo "${SCHEME_LIST}" | grep -q "HGTVCore"; then
  SCHEME="HGTVCore"
fi
echo "==> using scheme: ${SCHEME}"

echo "==> xcodebuild (${CONFIG}, tvOS device arm64)"
xcodebuild \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tail -60

echo "==> locating built binary"
BIN="$(find "${DERIVED}/Build/Products" -type f -name "${SCHEME}" -perm +111 | head -1 || true)"
if [ -z "${BIN}" ]; then
  echo "WARN: no executable named ${SCHEME}, trying .app bundle..."
  APP_BUNDLE="$(find "${DERIVED}/Build/Products" -type d -name "${SCHEME}.app" | head -1 || true)"
  if [ -n "${APP_BUNDLE}" ]; then
    echo "==> found .app bundle: ${APP_BUNDLE}"
    rm -rf "${DIST}"
    mkdir -p "${DIST}"
    cp -R "${APP_BUNDLE}" "${DIST}/Payload.app"
    BIN_IN_APP="${DIST}/Payload.app/${SCHEME}"
    [ -f "${BIN_IN_APP}" ] || { echo "ERROR: no binary in .app"; exit 1; }
    # 直接用现成 .app
    rm -rf "${DIST}/Payload"
    mkdir -p "${DIST}"
    cp -R "${APP_BUNDLE}" "${DIST}/Payload_tmp"
    mv "${DIST}/Payload_tmp" "${DIST}/Payload"
    cd "${DIST}"
    IPA="${APP_NAME}-tvOS-unsigned.ipa"
    rm -f "${IPA}"
    zip -qry "${IPA}" Payload
    cd ..
    echo "==> done: ${DIST}/${IPA}"
    ls -la "${DIST}/${IPA}"
    echo "IPA_PATH=${DIST}/${IPA}" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
  echo "ERROR: could not find built product"; exit 1
fi

echo "==> binary: ${BIN}"
echo "==> assembling ${APP_NAME}.app"
rm -rf "${DIST}"
mkdir -p "${DIST}/Payload/${APP_NAME}.app"
cp "${BIN}" "${DIST}/Payload/${APP_NAME}.app/${APP_NAME}"

cat > "${DIST}/Payload/${APP_NAME}.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HGTV</string>
    <key>CFBundleIdentifier</key><string>com.hgtv.star.tvos</string>
    <key>CFBundleName</key><string>HGTV</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3.7.3</string>
    <key>CFBundleVersion</key><string>78</string>
    <key>MinimumOSVersion</key><string>26.0</string>
    <key>UIDeviceFamily</key><array><integer>3</integer></array>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
    <key>LSRequiresIPhoneOS</key><true/>
</dict>
</plist>
PLIST

echo "==> packaging unsigned ipa"
cd "${DIST}"
IPA="${APP_NAME}-tvOS-unsigned.ipa"
rm -f "${IPA}"
zip -qry "${IPA}" Payload
cd ..

echo "==> done: ${DIST}/${IPA}"
ls -la "${DIST}/${IPA}"
echo "IPA_PATH=${DIST}/${IPA}" >> "${GITHUB_OUTPUT:-/dev/null}"