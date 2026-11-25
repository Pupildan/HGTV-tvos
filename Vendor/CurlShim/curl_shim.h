// curl_shim.h — Swift ↔ libcurl-impersonate 绑定 shim（最小注入面）。
//
// 仅 #include patched curl 头（Vendor/curl-imp/include/curl/curl.h，CI job
// build-curl-impersonate 产出的 artifact，解压后 HEADER_SEARCH_PATHS 可达）。
// 全部 CURLOPT_*/CURLcode/类型常量由 curl.h 保证（不手抄数值）。
// curl_easy_impersonate 是 lexiforest curl-impersonate patch 新增的 lib API
// （39 个浏览器指纹预设），声明同样来自 patched curl.h。
//
// Swift 通过同目录 module.modulemap import CurlShim：
//   Xcode（project.yml）HGTVCore 的 SWIFT_INCLUDE_PATHS 指向本目录。
//   SwiftPM/sign_cli swiftc 直编路径不含本目录 → canImport(CurlShim)=false，
//   CurlImpersonateTransport.swift 整体为空，HTTPClient 回退 NIO/URLSession。
#ifndef CURL_SHIM_H
#define CURL_SHIM_H
#include <curl/curl.h>
#endif /* CURL_SHIM_H */