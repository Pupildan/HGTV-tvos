// HTTPClient.swift
// 网络层。严格对齐原 APK：字节 TTNet 语义在 tvOS 上用 URLSession + 自定义头复刻，
// 签名头由 SignInterceptor 统一注入（等价原 H0/d 拦截器）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTarget {
    var host: String { get }
    var path: String { get }
    var method: String { get }
    var query: [String: String] { get }
    var body: Data? { get }
    /// 是否走签名链路（passport / novel / reading 需要；自建搜索中转不需要）
    var signed: Bool { get }
}

public struct HTTPTargetImpl: HTTPTarget {
    public let host: String
    public let path: String
    public let method: String
    public let query: [String: String]
    public let body: Data?
    public let signed: Bool

    public init(host: String,
                path: String,
                method: String = "GET",
                query: [String: String] = [:],
                body: Data? = nil,
                signed: Bool = true) {
        self.host = host
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.signed = signed
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
                body: target.body.map { [UInt8]($0) }
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

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw HTTPError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.catalogHTTP(http.statusCode)
        }
        return data
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