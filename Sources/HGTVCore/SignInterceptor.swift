// SignInterceptor.swift
// 等价原 H0/d 拦截器：在请求发出前注入 Cookie / X-SS-DP / X-Tt-Token /
// passport-sdk-version / X-HGTV-Identity|Anonymous 等公共头，再调用 RequestSigner 签名。

import Foundation

/// 账号凭证（对应 F0.b：cookie/token/tsSign/deviceId/installId/cdid/openudid/expiresAt/device）
public struct AccountCredentials {
    public var cookie: String
    public var token: String
    public var tsSign: String
    public var deviceId: String
    public var installId: String
    public var cdid: String
    public var openudid: String
    public var expiresAt: UInt64
    public var device: [String: String]

    public init(cookie: String = "", token: String = "", tsSign: String = "",
                deviceId: String = "", installId: String = "", cdid: String = "",
                openudid: String = "", expiresAt: UInt64 = 0, device: [String: String] = [:]) {
        self.cookie = cookie
        self.token = token
        self.tsSign = tsSign
        self.deviceId = deviceId
        self.installId = installId
        self.cdid = cdid
        self.openudid = openudid
        self.expiresAt = expiresAt
        self.device = device
    }

    /// F0.b.a()：hasCookie = cookie 非空
    public var hasCookie: Bool { !cookie.isEmpty }
}

/// 拦截器：输入业务参数 → 输出带签名头的完整请求
/// 跨 actor 共享（被 Sendable 的 HTTPClient 持有），内部可变凭证由调用方串行化访问。
public final class SignInterceptor: @unchecked Sendable {
    public let signer: RequestSigner
    public let registrar: DeviceRegistrar
    public var credentials: AccountCredentials

    /// X-SS-DP 固定 aid
    public static let xSSDP = "8662"
    /// passport-sdk-version（登录后）/ 6031190（未登录）
    public static let passportSDKVersion = "5051452"
    public static let anonymousPassportSDKVersion = "6031190"
    /// X-HGTV-Identity
    public static let hgtvIdentityHeader = "X-HGTV-Identity"
    public static let hgtvAnonymousHeader = "X-HGTV-Anonymous"

    public init(signer: RequestSigner, registrar: DeviceRegistrar, credentials: AccountCredentials = AccountCredentials()) {
        self.signer = signer
        self.registrar = registrar
        self.credentials = credentials
    }

    /// 给业务请求加公共头 + 签名。
    /// - Parameters:
    ///   - baseURL: 不含 query
    ///   - params: 业务 query 参数
    ///   - body: POST body；GET 传 nil
    ///   - extraHeaders: 调用方补充头
    public func intercept(baseURL: String,
                          params: [String: String],
                          body: [UInt8]?,
                          extraHeaders: [String: String] = [:]) -> SignedRequest {
        // 1) 合并公共 query（device_id / iid 来自凭证）
        var merged = CommonParams.query(
            deviceID: credentials.deviceId.isEmpty ? nil : credentials.deviceId,
            iid: credentials.installId.isEmpty ? nil : credentials.installId,
            installID: credentials.installId.isEmpty ? nil : credentials.installId
        )
        for (k, v) in params { merged[k] = v }

        // 2) 签名
        let context = SignContext(
            deviceID: credentials.deviceId,
            deviceToken: registrar.registration?.deviceToken ?? "",
            installID: credentials.installId,
            versionCode: merged["version_code"] ?? "74332",
            versionName: merged["version_name"] ?? "7.4.3.32",
            osVersion: merged["os_version"] ?? "16",
            deviceType: merged["device_type"] ?? "25053RT47C",
            romVersion: credentials.device["rom_version"] ?? "BP2A.250605.031.A3"
        )
        var signed = signer.sign(baseURL: baseURL, params: merged, body: body, method: nil)

        // 3) 注入公共头（等价 H0/d）
        var headers = signed.headers
        for (k, v) in extraHeaders { headers[k] = v }

        // Cookie：凭证 cookie + device_token 相关
        if credentials.hasCookie {
            headers["Cookie"] = credentials.cookie
        }
        // X-SS-DP
        headers["x-ss-dp"] = Self.xSSDP
        // X-Tt-Token（登录后才有）
        if !credentials.token.isEmpty {
            headers["x-tt-token"] = credentials.token
        }
        // passport-sdk-version（签名里已注入，但拦截器再显式覆盖一次）
        headers["passport-sdk-version"] = credentials.hasCookie
            ? Self.passportSDKVersion
            : Self.anonymousPassportSDKVersion

        // X-HGTV-Identity / X-HGTV-Anonymous
        if let identity = credentials.device["hgtv_identity"], !identity.isEmpty {
            headers[Self.hgtvIdentityHeader] = identity
        } else {
            let anon = credentials.device["hgtv_anonymous"]
                ?? CommonParams.sanitize(credentials.cdid, fallback: CommonParams.generateCdid())
            headers[Self.hgtvAnonymousHeader] = anon
        }

        // x-ss-req-ticket 由 signer 已加；这里再补一个 x-tt-trace-id（可空）
        if headers["x-tt-trace-id"] == nil {
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            headers["x-tt-trace-id"] = "00-\(uuid)-\(uuid.prefix(16))-01"
        }

        signed.headers = headers
        return signed
    }
}

/// URLRequest 便捷扩展
extension SignedRequest {
    public func toURLRequest() -> URLRequest {
        var req = URLRequest(url: URL(string: url) ?? URL(fileURLWithPath: "/"))
        req.httpMethod = method
        req.httpBody = body.map { Data($0) }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }
}
