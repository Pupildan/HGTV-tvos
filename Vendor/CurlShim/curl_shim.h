// curl_shim.h — Swift ↔ libcurl-impersonate 绑定 shim。
//
// 关键约束（2026-11-25 实锤）：
// 1. curl_easy_setopt 是 varargs → Swift importer 标记 unavailable，Swift 无法直调
//    → 全部 setopt 封装为专用 C inline 函数（宏在 C 函数体内由预处理器展开，
//      Swift 只看到类型安全的具体函数，零宏暴露）。
// 2. curl_easy_getinfo 的 void* 参数被 Swift importer 映射成 Any，&value 无法桥接
//    → 同样封装为专用函数。
// 3. CURLOPT_*/CURLINFO_* 是 C 宏 → Swift 根本看不到这些符号
//    → Swift 侧禁止出现任何 CURLOPT_/CURLINFO_ 字样（CI typecheck 会拦截）。
//
// Swift 通过同目录 module.modulemap import CurlShim：
//   Xcode（project.yml）HGTVCore 的 SWIFT_INCLUDE_PATHS 指向本目录。
#ifndef CURL_SHIM_H
#define CURL_SHIM_H
#include "curl.h"   /* same-dir copy pushed by CI; quoted include ignores search paths */

/* —— setopt 系列（每个 option 一个专用函数）—— */

static inline CURLcode curl_shim_set_url(CURL *h, const char *url) {
    return curl_easy_setopt(h, CURLOPT_URL, url);
}
static inline CURLcode curl_shim_set_followlocation(CURL *h, long v) {
    return curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, v);
}
static inline CURLcode curl_shim_set_connecttimeout(CURL *h, long v) {
    return curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, v);
}
static inline CURLcode curl_shim_set_timeout(CURL *h, long v) {
    return curl_easy_setopt(h, CURLOPT_TIMEOUT, v);
}
static inline CURLcode curl_shim_set_accept_encoding(CURL *h, const char *v) {
    return curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, v);
}
static inline CURLcode curl_shim_set_http_version_1_1(CURL *h) {
    /* 强制 HTTP/1.1：ATV 上 H2 帧指纹疑被字节风控，PC 成功案例（urllib）均为
       HTTP/1.1——impersonate 预设的 ALPN 可能含 h2，此选项让 curl 忽略 h2 协商。 */
    return curl_easy_setopt(h, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
}
static inline CURLcode curl_shim_set_httpheader(CURL *h, struct curl_slist *sl) {
    return curl_easy_setopt(h, CURLOPT_HTTPHEADER, sl);
}
static inline CURLcode curl_shim_set_postfieldsize(CURL *h, long v) {
    return curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, v);
}
static inline CURLcode curl_shim_set_copypostfields(CURL *h, const char *v) {
    return curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, v);
}
static inline CURLcode curl_shim_set_writefunction(CURL *h, curl_write_callback fn) {
    return curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, fn);
}
static inline CURLcode curl_shim_set_writedata(CURL *h, void *v) {
    return curl_easy_setopt(h, CURLOPT_WRITEDATA, v);
}

/* —— getinfo 系列 —— */

static inline long curl_shim_get_response_code(CURL *h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

#endif /* CURL_SHIM_H */