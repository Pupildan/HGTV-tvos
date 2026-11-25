#!/bin/bash
# build_curl_impersonate.sh — 交叉编译 libcurl-impersonate（chrome131_android 指纹）tvOS arm64 静态库
#
# 实现方式：lexiforest/curl-impersonate（curl_cffi 同源实现，2913 星，2026-11 仍活跃维护）
# 的 CMake superbuild。superbuild 自动下载并构建全部依赖：
#   BoringSSL（pin Chrome 150 commit）+ nghttp2 1.63 + ngtcp2/nghttp3（H3）+
#   brotli + zstd + zlib + c-ares + curl 8.23（打 impersonate patch，39 个浏览器
#   预设内建：curl_easy_impersonate("chrome131_android", 0) 一站式应用 TLS/H2 指纹）。
#
# tvOS 交叉编译：CMAKE_SYSTEM_NAME=iOS + appletvos SDK + arm64（cmake 官方 Apple
# 交叉做法）。lexiforest 顶层 CMakeLists 对 CMAKE_SYSTEM_NAME=iOS 有专门处理，
# 且把 CMAKE_SYSTEM_NAME / CMAKE_OSX_SYSROOT / CMAKE_OSX_ARCHITECTURES /
# CMAKE_OSX_DEPLOYMENT_TARGET 自动传播到全部子项目；Apple 平台自动启用
# USE_APPLE_SECTRUST=ON（证书校验走 tvOS 系统信任库 SecTrust，无需打包 cacert.pem）
# 并 IGNORE /usr/local /opt/homebrew 防 host 污染。
#
# 产物：curl-impersonate-tvos.tar.gz（include/ 头文件 + lib/libcurl-imp-tvos.a
# 合并静态库 + share/BUNDLE_INFO.txt）。合并库 = libcurl-impersonate.a + 全部私有
# 依赖（libssl/libcrypto/libnghttp2/libngtcp2/libnghttp3/libcares/libz/libzstd/
# libbrotli*），Xcode 侧一个 OTHER_LDFLAGS 即可链接。
set -euo pipefail

IMPERSONATE_REF="${CURL_IMPERSONATE_REF:-main}"
PREFIX="$PWD/curl-imp-install"
WORKDIR="$PWD/curl-imp-work"

echo "==> tvOS SDK"
SDK_PATH="$(xcrun --sdk appletvos --show-sdk-path)"
echo "SDK: ${SDK_PATH}"

echo "==> tools"
cmake --version | head -1
go version || { echo "ERROR: go missing (BoringSSL build requires it)"; exit 1; }
patch --version | head -1

echo "==> clone lexiforest/curl-impersonate (${IMPERSONATE_REF})"
rm -rf "$WORKDIR" "$PREFIX"
mkdir -p "$WORKDIR"
git clone --depth 1 --branch "$IMPERSONATE_REF" \
  https://github.com/lexiforest/curl-impersonate.git "$WORKDIR/curl-imp"
cd "$WORKDIR/curl-imp"
IMP_SHA="$(git rev-parse HEAD)"
git log -1 --format='curl-impersonate HEAD: %h %s'
echo "IMP_SHA=${IMP_SHA}"

echo "==> cmake configure (tvOS arm64 cross; superbuild pulls BoringSSL+deps+curl)"
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DUSE_LIBIDN2=OFF \
  -DCURL_CA_BUNDLE=none

echo "==> build (BoringSSL + 8 deps + curl, 15-25 min on runner)"
cmake --build build --parallel "$(sysctl -n hw.ncpu)"

echo "==> install"
cmake --install build

echo "==> installed layout:"
find "${PREFIX}" -maxdepth 2 | head -40

echo "==> merge static libs into single archive (simplifies Xcode linking)"
if [ ! -f "${PREFIX}/lib/libcurl-impersonate.a" ]; then
  echo "ERROR: libcurl-impersonate.a not found after install"
  exit 1
fi
LIBS=("${PREFIX}/lib/libcurl-impersonate.a")
shopt -s nullglob
for f in "${PREFIX}"/lib/curl-impersonate/*.a; do
  LIBS+=("$f")
done
shopt -u nullglob
echo "merge inputs:"
printf '  %s\n' "${LIBS[@]}"
xcrun libtool -static -o "${PREFIX}/lib/libcurl-imp-tvos.a" "${LIBS[@]}"

echo "==> verify"
lipo -info "${PREFIX}/lib/libcurl-imp-tvos.a"
SYMCOUNT="$(nm -gU "${PREFIX}/lib/libcurl-imp-tvos.a" 2>/dev/null | grep -c 'T _curl_easy_impersonate' || true)"
echo "curl_easy_impersonate symbol count: ${SYMCOUNT}"
if [ "${SYMCOUNT}" -eq 0 ]; then
  echo "ERROR: curl_easy_impersonate symbol missing in merged archive"
  exit 1
fi

echo "==> package minimal tarball (include/ + merged lib + info)"
mkdir -p "${PREFIX}/share"
{
  echo "libcurl-impersonate tvOS arm64 static bundle"
  echo "source: lexiforest/curl-impersonate ${IMPERSONATE_REF} @ ${IMP_SHA}"
  echo "target: chrome131_android (curl_easy_impersonate, default_headers=0)"
  echo "built:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "sdk:    $(basename "${SDK_PATH}")"
} > "${PREFIX}/share/BUNDLE_INFO.txt"
tar czf "$PWD/curl-impersonate-tvos.tar.gz" \
  -C "${PREFIX}" include lib/libcurl-imp-tvos.a share
echo "==> tarball:"
ls -la "$PWD/curl-impersonate-tvos.tar.gz"
tar tzf "$PWD/curl-impersonate-tvos.tar.gz" | head -25
echo "==> done"