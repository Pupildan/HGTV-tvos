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

/* Swift importer 会把 curl_easy_setopt（varargs）标记为 unavailable——Swift 无法
 * 调 C varargs 函数。用 C inline 类型安全包装绕开（C 内部调 varargs 合法）。 */
static inline CURLcode curl_shim_setopt_cstr(CURL *h, CURLoption opt, const char *v) {
    return curl_easy_setopt(h, opt, v);
}
static inline CURLcode curl_shim_setopt_long(CURL *h, CURLoption opt, long v) {
    return curl_easy_setopt(h, opt, v);
}
static inline CURLcode curl_shim_setopt_ptr(CURL *h, CURLoption opt, void *v) {
    return curl_easy_setopt(h, opt, v);
}

/* Swift importer 会把 curl_easy_getinfo 的 void* 参数映射成 Any 导致 &status
 * 无法桥接——用 C inline 包装绕开（static inline 在 Swift 可直接调用）。 */
static inline long curl_shim_get_response_code(CURL *h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

#endif /* CURL_SHIM_H */