// HTTPClient.swift
// 网络层。严格对齐原 APK：字节 TTNet 语义在 tvOS 上用 URLSession + 自定义头复刻，
// 签名头由 SignInterceptor 统一注入（等价原 H0/d 拦截器）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// 注：日志诊断层 DiagnosticsLogger 与本文件同属 HGTVCore target，无需 import，直接引用。
//     Diagnostics 不反向依赖网络层，无循环依赖。

public protocol HTTPTarget {
    var host: String { get }
    var path: String { get }
    var method: String { get }
    var query: [String: String] { get }
    var body: Data? { get }
    /// 是否走签名链路（passport / novel / reading 需要；自建搜索中转不需要）
    var signed: Bool { get }
    /// 版本族：true = 搜索/弹幕/账号族（72232）；false（默认）= 视频/landpage 族（74332）。
    /// 仅 signed 请求生效。
    var appFamily: Bool { get }
    /// 强制走旧 XGorgon 签名器（v36 已验证 bookmall 可用）。诊断/回退用。
    var legacySigning: Bool { get }
    /// landpage 专用族（73532/7.3.5.32，真机抓包实锤）。
    var landpageFamily: Bool { get }
    /// 调用方额外补充头（如 Content-Encoding: gzip）；经 SignInterceptor 注入
    var extraHeaders: [String: String] { get }
}

extension HTTPTarget {
    /// 默认无额外头（已有 HTTPTargetImpl 存储属性满足此要求）
    public var extraHeaders: [String: String] { [:] }
    /// 默认走视频/landpage 族
    public var appFamily: Bool { false }
    /// 默认不走旧签名器
    public var legacySigning: Bool { false }
    /// 默认非 landpage 族
    public var landpageFamily: Bool { false }
}

public struct HTTPTargetImpl: HTTPTarget {
    public let host: String
    public let path: String
    public let method: String
    public let query: [String: String]
    public let body: Data?
    public let signed: Bool
    public let appFamily: Bool
    public let legacySigning: Bool
    public let landpageFamily: Bool
    public let extraHeaders: [String: String]

    public init(host: String,
                path: String,
                method: String = "GET",
                query: [String: String] = [:],
                body: Data? = nil,
                signed: Bool = true,
                appFamily: Bool = false,
                legacySigning: Bool = false,
                landpageFamily: Bool = false,
                extraHeaders: [String: String] = [:]) {
        self.host = host
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.signed = signed
        self.appFamily = appFamily
        self.legacySigning = legacySigning
        self.landpageFamily = landpageFamily
        self.extraHeaders = extraHeaders
    }
}

public enum HTTPError: Error, LocalizedError {
    case catalogHTTP(Int)            // 对应 CatalogHttpException
    case searchAPI(String)           // 对应 SearchApiException
    case deviceNotRegistered         // 对应 DeviceNotRegisteredException
    case streamExpired               // 对应 StreamExpiredException
    case searchSessionExpired        // 对应 SearchSessionExpiredException
    case invalidResponse
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .catalogHTTP(let code): return "内容接口错误 (\(code))"
        case .searchAPI(let m): return "搜索接口错误：\(m)"
        case .deviceNotRegistered: return "设备正在初始化，请稍后重试"
        case .streamExpired: return "播放地址已过期"
        case .searchSessionExpired: return "搜索会话过期"
        case .invalidResponse: return "响应解析失败"
        case .network(let e): return e.localizedDescription
        }
    }
}

public final class HTTPClient: Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession
    private let interceptor: SignInterceptor

    /// 签名请求：复用全局引导服务的 signer + registrar（保证设备身份一致）
    public convenience init() {
        self.init(interceptor: DeviceRegisterService.shared.interceptor)
    }

    /// 指定拦截器（自建搜索中转的请求靠 HTTPTarget.signed 区分，不走签名）
    public init(interceptor: SignInterceptor) {
        let cfg = URLSessionConfiguration.default
        // UA 由拦截器（签名请求）或 unsigned 分支按需注入，config 不重复设置
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
        self.interceptor = interceptor
    }

    /// 执行请求，返回原始 Data。
    public func request(_ target: HTTPTarget) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = target.host
        comps.path = target.path
        // query 由签名拦截器统一拼装（公共参数 + 业务参数 + ts/_rticket），此处只留 baseURL
        guard let url = comps.url else { throw HTTPError.invalidResponse }

        let signedReq: SignedRequest
        if target.signed {
            signedReq = interceptor.intercept(
                baseURL: url.absoluteString,
                params: target.query,
                body: target.body.map { [UInt8]($0) },
                extraHeaders: target.extraHeaders,
                appFamily: target.appFamily,
                landpageFamily: target.landpageFamily,
                legacySigning: target.legacySigning
            )
        } else {
            // 自建搜索中转：不签名，只拼 query，补 UA
            var c2 = comps
            if !target.query.isEmpty {
                c2.queryItems = target.query.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            signedReq = SignedRequest(url: (c2.url ?? url).absoluteString,
                                      headers: [HGTVConfig.HeaderKey.userAgent: HGTVConfig.userAgent()],
                                      body: target.body.map { [UInt8]($0) },
                                      method: target.method)
        }

        var req = signedReq.toURLRequest()

        // —— 日志：发起前记录 method/url/signed + 全部请求头（fire-and-forget，不影响请求语义）——
        let isSigned = target.signed
        let method = signedReq.method
        let urlStr = signedReq.url
        let headers = signedReq.headers
        Self.logRequest(method: method, url: urlStr, signed: isSigned, headers: headers,
                        bodyLength: signedReq.body?.count)

#if canImport(CurlShim)
        // —— 传输层路由（第一优先）：字节系域名走 curl-impersonate（chrome131_android
        //    TLS/H2 指纹）——
        // 字节 CDN（volc-dcdn）黑名单 Apple 原生 TLS 指纹（landpage 恒 200+0B，五
        // host × 五身份实测）；NIO 的 BoringSSL ClientHello 特征在 ATV 上实测也未过墙。
        // 2026-11-24 中国出口归一实验：libcurl-impersonate 同源实现（curl_cffi）
        // chrome131_android 等 BoringSSL 指纹全部 200+49KB 真数据。本通道用 tvOS
        // 静态 libcurl-impersonate（CI job build-curl-impersonate 产出 Vendor/curl-imp/），
        // 失败自动降级 NIO → URLSession 三层兜底。其余域名（自建搜索中转
        // hongguoduanju.com、镜像 luckysf.net）不在清单，维持 URLSession。
        if CurlImpersonateTransport.shouldUseCurl(host: target.host) {
            do {
                return try await Self.sendViaCurl(url: urlStr, method: method,
                                                  headers: headers,
                                                  body: signedReq.body.map { Data($0) })
            } catch {
                DiagnosticsLogger.warn("curl-impersonate 通道失败，降级 NIO/URLSession：\(error.localizedDescription)",
                                       category: "http",
                                       meta: ["url": urlStr, "channel": "curl-impersonate"])
            }
        }
#endif

#if canImport(AsyncHTTPClient)
        // —— 传输层路由（第二优先）：字节系域名走 NIO-BoringSSL 通道（v93）——
        // curl-impersonate 通道失败（编译产物缺失/传输错误）时的降级层。
        if NIOHTTPTransport.shouldUseNIO(host: target.host) {
            do {
                return try await Self.sendViaNIO(url: urlStr, method: method,
                                                 headers: headers,
                                                 body: signedReq.body.map { Data($0) })
            } catch {
                DiagnosticsLogger.warn("NIO-BoringSSL 通道失败，降级 URLSession：\(error.localizedDescription)",
                                       category: "http",
                                       meta: ["url": urlStr, "channel": "NIO-BoringSSL"])
            }
        }
#endif

        // 签名请求一律本地直连 URLSession（v91：原生自签版彻底移除 PC/NAS 桥兜底，
        // 签名已升级突破版参数（3f9d363），landpage/弹幕/播放三接口均验证可通；
        // 失败就抛真实错误，不再有任何桥路径）。

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // —— 日志：抛错 ——
            DiagnosticsLogger.error("请求失败：\(error.localizedDescription)", category: "http",
                                    meta: ["method": method, "url": urlStr, "signed": "\(isSigned)"])
            throw HTTPError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            DiagnosticsLogger.warn("响应非 HTTP：\(urlStr)", category: "http")
            throw HTTPError.invalidResponse
        }
        // —— 日志：收到响应（status / 字节数 / 前若干字节）——
        Self.logResponse(url: urlStr, status: http.statusCode, data: data)
        guard (200..<300).contains(http.statusCode) else {
            DiagnosticsLogger.warn("HTTP \(http.statusCode)：\(urlStr)", category: "http")
            throw HTTPError.catalogHTTP(http.statusCode)
        }
        return data
    }

    // MARK: - curl-impersonate 通道（字节系域名第一优先，chrome131_android TLS/H2 指纹）

#if canImport(CurlShim)
    /// libcurl-impersonate（curl+BoringSSL，tvOS 静态库）发送签名请求。
    /// 响应日志带 channel=curl-imp-boringssl，装机后日志服务器可确认通道与指纹状态。
    private static func sendViaCurl(url: String, method: String,
                                    headers: [String: String],
                                    body: Data?) async throws -> Data {
        do {
            let result = try await CurlImpersonateTransport.execute(
                url: url, method: method, headers: headers, body: body)
            let preview = String(data: result.data.prefix(500), encoding: .utf8)
                ?? String(decoding: result.data.prefix(500), as: UTF8.self)
            DiagnosticsLogger.info(
                "← \(result.status) bytes=\(result.data.count) channel=curl-imp-boringssl \(url)",
                category: "http",
                meta: ["status": "\(result.status)",
                       "bytes": "\(result.data.count)",
                       "channel": "curl-imp-boringssl",
                       "body": preview])
            // 200+0B 降级：2026-11-26 PC 对照实验实锤本接口不拦指纹（openssl/curl_cffi
            // chrome131/safari 全 200+49KB），0B 根因在 tvOS 端 curl-imp 实现——0B 必须
            // 抛错触发 NIO → URLSession 降级，否则三层兜底被锁死在 curl 通道。
            if result.data.isEmpty {
                DiagnosticsLogger.warn(
                    "HTTP 200 但响应 0B——curl-imp-boringssl 通道丢弃，降级 NIO/URLSession：\(url)",
                    category: "http", meta: ["status": "\(result.status)", "bytes": "0"])
                throw HTTPError.invalidResponse
            }
            guard (200..<300).contains(result.status) else {
                DiagnosticsLogger.warn("HTTP \(result.status)：\(url)（curl-imp-boringssl）", category: "http")
                throw HTTPError.catalogHTTP(result.status)
            }
            return result.data
        } catch let e as HTTPError {
            throw e
        } catch {
            DiagnosticsLogger.error("curl-impersonate 请求失败：\(error.localizedDescription)", category: "http",
                                    meta: ["url": url, "channel": "curl-imp-boringssl"])
            throw HTTPError.network(error)
        }
    }
#endif

    // MARK: - NIO-BoringSSL 通道（字节系域名专用，v93）

#if canImport(AsyncHTTPClient)
    /// AsyncHTTPClient（BoringSSL TLS）发送签名请求。响应日志带 channel=NIO-BoringSSL，
    /// 装机后日志服务器可确认通道切换生效。
    private static func sendViaNIO(url: String, method: String,
                                   headers: [String: String],
                                   body: Data?) async throws -> Data {
        do {
            let result = try await NIOHTTPTransport.execute(
                url: url, method: method, headers: headers, body: body)
            let preview = String(data: result.data.prefix(500), encoding: .utf8)
                ?? String(decoding: result.data.prefix(500), as: UTF8.self)
            DiagnosticsLogger.info(
                "← \(result.status) bytes=\(result.data.count) channel=NIO-BoringSSL \(url)",
                category: "http",
                meta: ["status": "\(result.status)",
                       "bytes": "\(result.data.count)",
                       "channel": "NIO-BoringSSL",
                       "body": preview])
            // 0B 同样降级 URLSession（2026-11-26 实锤本接口不拦指纹，0B 即通道异常）
            guard !result.data.isEmpty else {
                DiagnosticsLogger.warn(
                    "HTTP 200 但响应 0B——NIO-BoringSSL 通道丢弃，降级 URLSession：\(url)",
                    category: "http", meta: ["status": "\(result.status)", "bytes": "0"])
                throw HTTPError.invalidResponse
            }
            guard (200..<300).contains(result.status) else {
                DiagnosticsLogger.warn("HTTP \(result.status)：\(url)（NIO-BoringSSL）", category: "http")
                throw HTTPError.catalogHTTP(result.status)
            }
            return result.data
        } catch let e as HTTPError {
            throw e
        } catch {
            DiagnosticsLogger.error("NIO 请求失败：\(error.localizedDescription)", category: "http",
                                    meta: ["url": url, "channel": "NIO-BoringSSL"])
            throw HTTPError.network(error)
        }
    }
#endif

    // MARK: - 日志挂钩（不影响请求语义，仅观测）

    /// 发起前：记录全部请求头，特别标出签名相关头是否为空。
    private static func logRequest(method: String, url: String, signed: Bool,
                                   headers: [String: String], bodyLength: Int?) {
        let interesting = ["x-gorgon", "x-argus", "x-ladon", "x-khronos", "x-medusa",
                           "x-helios", "x-ss-stub", "x-ss-dp", "passport-sdk-version", "cookie"]
        var meta: [String: String] = [
            "method": method,
            "url": url,
            "signed": "\(signed)",
            "body_len": "\(bodyLength ?? 0)",
        ]
        if let bl = bodyLength { meta["has_body"] = "\(bl > 0)" }
        // 全部请求头（键统一小写便于对拍）
        for (k, v) in headers {
            meta["h." + k.lowercased()] = v.isEmpty ? "<empty>" : v
        }
        // 签名头是否为空的汇总（一目了然哪个签名头缺失）
        for key in interesting {
            let val = headers.first { $0.key.lowercased() == key }?.value
            meta["sig." + key] = (val?.isEmpty == false) ? "ok" : "EMPTY"
        }
        DiagnosticsLogger.info("→ \(method) \(url) signed=\(signed)", category: "http", meta: meta)
    }

    /// 收到响应：记录 status、字节数、响应前若干字节（便于看报错 JSON）。
    private static func logResponse(url: String, status: Int, data: Data) {
        let preview = String(data: data.prefix(500), encoding: .utf8)
            ?? String(decoding: data.prefix(500), as: UTF8.self) // lossy 兜底
        DiagnosticsLogger.info("← \(status) bytes=\(data.count) \(url)", category: "http",
                               meta: ["status": "\(status)",
                                      "bytes": "\(data.count)",
                                      "body": preview])
    }

    /// 解码 envelope 包裹的数据
    public func request<T: Decodable>(_ target: HTTPTarget, as type: T.Type) async throws -> T {
        let raw = try await request(target)
        do {
            return try LenientDecoder.decode(T.self, from: raw)
        } catch {
            throw HTTPError.invalidResponse
        }
    }
}