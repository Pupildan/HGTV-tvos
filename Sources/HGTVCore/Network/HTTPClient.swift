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
    public let extraHeaders: [String: String]

    public init(host: String,
                path: String,
                method: String = "GET",
                query: [String: String] = [:],
                body: Data? = nil,
                signed: Bool = true,
                appFamily: Bool = false,
                legacySigning: Bool = false,
                extraHeaders: [String: String] = [:]) {
        self.host = host
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.signed = signed
        self.appFamily = appFamily
        self.legacySigning = legacySigning
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