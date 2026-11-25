// CurlImpersonateTransport.swift
// 字节系域名专用传输层（第一优先）：libcurl-impersonate（chrome131_android TLS/H2 指纹）。
//
// 背景（2026-11-24 归一实验实锤）：字节 CDN（volc-dcdn）按 TLS 指纹（JA3）黑名单
// Apple 原生 Network.framework——landpage 恒 200+0B；AsyncHTTPClient（NIO 的
// BoringSSL ClientHello 特征）在 ATV 上实测同样 0B。而 python curl_cffi（与
// libcurl-impersonate 同源实现）chrome131_android / chrome131 / chrome124 /
// chrome116 / None（curl+BoringSSL 默认）在中国出口全部 200+49KB 真数据。
//
// 本传输层把 curl+BoringSSL 直接编进 app：CI job build-curl-impersonate 用
// lexiforest/curl-impersonate 的 CMake superbuild 交叉编译 tvOS arm64 静态库
// （curl 8.23 + impersonate patch），artifact 解压到 Vendor/curl-imp/。
// TLS/H2 指纹调 curl_easy_impersonate("chrome131_android", 0)——default_headers=0
// 只应用 TLS（ciphers/curves/ALPN/ALPS/permute-extensions/grease/cert-compression/
// ECH）+ H2 SETTINGS 指纹，HTTP 头保持字节系签名头不变。响应 gzip/deflate/br/zstd
// 由 libcurl 自动解压（brotli/zstd 已编译）。证书校验走 Apple SecTrust（库编译时
// USE_APPLE_SECTRUST=ON，tvOS 系统信任库），无需打包 cacert.pem。
//
// 编译保护（同 NIOHTTPTransport 模式）：
//   - Xcode（project.yml）：SWIFT_INCLUDE_PATHS 指向 Vendor/CurlShim（modulemap）
//     → canImport(CurlShim)=true，通道启用；
//   - SwiftPM（SignCLI/macOS）与 sign_cli swiftc 直编：无 modulemap → 空文件，
//     HTTPClient 自动回退 NIO/URLSession 通道。
// 注意：Vendor/curl-imp/ 缺失时 Xcode 链接期即报错——有意为之（构建期暴露，
// 不留运行时静默降级）。

import Foundation

#if canImport(CurlShim)
import CurlShim

enum CurlImpersonateTransport {

    // MARK: - 指纹目标（与 2026-11-24 中国出口归一实验一致）

    /// libcurl-impersonate 预设目标名。chrome131_android：TLS 同 chrome131
    /// （curves=X25519:P-256:P-384，无 MLKEM），HTTP 头预设不启用（default_headers=0）。
    private static let impersonateTarget = "chrome131_android"

    // MARK: - 域名路由

    /// 字节系域名 → curl-impersonate 通道。清单复用 NIOHTTPTransport（同 target
    /// internal 可见），域名清单调整只改一处（Xcode 构建必含 AsyncHTTPClient）。
    static func shouldUseCurl(host: String) -> Bool {
        #if canImport(AsyncHTTPClient)
        NIOHTTPTransport.shouldUseNIO(host: host)
        #else
        false
        #endif
    }

    // MARK: - 冒烟自检（无网络）

    /// 库加载 + easy handle 创建 + impersonate 预设应用（不发请求）。单测/装机诊断用。
    static func smokeInit() -> Bool {
        guard let h = curl_easy_init() else { return false }
        defer { curl_easy_cleanup(h) }
        return curl_easy_impersonate(h, impersonateTarget, 0) == CURLE_OK
    }

    // MARK: - 发送

    /// 发送签名后的完整请求（url/headers/body 均为 SignInterceptor 产出）。
    /// - headers: 大小写原样保留（curl_slist 按传入顺序发送，签名头不失真）
    /// - body: gzip 后字节（与 x-ss-stub/gorgon 绑定），COPYPOSTFIELDS 由 curl 拷贝
    /// - Returns: (状态码, 已自动解压的响应体)
    /// - Note: curl_easy_* 为阻塞 API，放后台线程池执行，不卡调用方 actor
    static func execute(url: String, method: String, headers: [String: String],
                        body: Data?) async throws -> (status: Int, data: Data) {
        try await Task.detached(priority: .userInitiated) {
            try performBlocking(url: url, method: method, headers: headers, body: body)
        }.value
    }

    private static func performBlocking(url: String, method: String,
                                        headers: [String: String],
                                        body: Data?) throws -> (status: Int, data: Data) {
        guard let handle = curl_easy_init() else {
            throw HTTPError.network(curlFailure(-1, detail: "curl_easy_init 失败", url: url))
        }
        defer { curl_easy_cleanup(handle) }

        // ① TLS/H2 指纹预设（default_headers=0：不动 HTTP 头）
        var code = curl_easy_impersonate(handle, impersonateTarget, 0)
        guard code == CURLE_OK else { throw curlError(code, url: url, what: "impersonate") }

        // ② 基本设置（语义与 NIO 通道对齐）
        code = curl_easy_setopt(handle, CURLOPT_URL, url)
        guard code == CURLE_OK else { throw curlError(code, url: url, what: "setopt URL") }
        curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1)       // 与 NIO redirect follow 一致
        curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 10)
        curl_easy_setopt(handle, CURLOPT_TIMEOUT, 30)
        // 证书校验：库编译时 USE_APPLE_SECTRUST=ON → SecTrust（tvOS 系统信任库）；
        // CURLOPT_SSL_VERIFYPEER 保持默认 1，不关校验。tvOS 无文件系统 CA bundle，
        // 库已不依赖 CURL_CA_BUNDLE 文件。

        // ③ 响应 gzip/deflate/br/zstd 自动解压（上层拿明文，与 URLSession 行为一致；
        //    Accept-Encoding 头由 libcurl 按本串原样发出，与 chrome 顺序一致）
        code = curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, "gzip, deflate, br, zstd")
        guard code == CURLE_OK else { throw curlError(code, url: url, what: "setopt encoding") }

        // ④ 字节系签名头（顺序 = SignInterceptor 产出序）
        var slist: UnsafeMutablePointer<curl_slist>? = nil
        for (k, v) in headers {
            slist = curl_slist_append(slist, "\(k): \(v)")
        }
        defer { curl_slist_free_all(slist) }
        curl_easy_setopt(handle, CURLOPT_HTTPHEADER, slist)

        // ⑤ body（POST：gzip 字节含 0x00——先按长度再 COPYPOSTFIELDS 让 curl 整体拷贝）
        if method.uppercased() == "POST", let body, !body.isEmpty {
            curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, body.count)
            body.withUnsafeBytes { raw in
                _ = curl_easy_setopt(handle, CURLOPT_COPYPOSTFIELDS,
                                     raw.baseAddress?.assumingMemoryBound(to: CChar.self))
            }
        }

        // ⑥ 响应体收集（write callback；首参 char*，与 curl.h 的 curl_write_callback 一致）
        let buffer = ResponseBuffer()
        let writeFn: @convention(c) (UnsafeMutablePointer<CChar>?, UInt, UInt, UnsafeMutableRawPointer?) -> UInt = {
            ptr, size, nmemb, ctx in
            guard let ptr, let ctx else { return 0 }
            let buf = Unmanaged<ResponseBuffer>.fromOpaque(ctx).takeUnretainedValue()
            let total = Int(size) * Int(nmemb)
            if total > 0 {
                let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                buf.data.append(bytes, count: total)
            }
            return UInt(total)
        }
        curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeFn)
        curl_easy_setopt(handle, CURLOPT_WRITEDATA,
                         Unmanaged<ResponseBuffer>.passUnretained(buffer).toOpaque())

        // ⑦ 执行
        code = curl_easy_perform(handle)
        guard code == CURLE_OK else { throw curlError(code, url: url, what: "perform") }

        // 状态码走 curl_shim.h 的 C inline 包装（getinfo 的 void* 在 Swift importer
        // 里被映射成 Any，&status 无法桥接——绕开）
        let status = Int(curl_shim_get_response_code(handle))
        return (status: status, data: buffer.data)
    }

    // MARK: - helpers

    private final class ResponseBuffer {
        var data = Data()
    }

    private static func curlFailure(_ code: Int32, detail: String, url: String) -> NSError {
        NSError(domain: "HGTVCore.curl-impersonate", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(detail) (\(url.prefix(120)))"])
    }

    private static func curlError(_ code: CURLcode, url: String, what: String) -> Error {
        let msg = String(cString: curl_easy_strerror(code))
        return curlFailure(Int32(bitPattern: code.rawValue), detail: "\(what): \(msg)", url: url)
    }
}

#endif