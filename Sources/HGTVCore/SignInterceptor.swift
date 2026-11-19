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
    /// 内容签名器（V5 = 1.3.7.7 官方 gorgonAligned/0081 + medusa v5 有状态）。
    /// device_register 仍走旧 RequestSigner（其 body 是 ttEncrypt，签名头由 DeviceRegistrar 单独拼）。
    public let signer: RequestSigner
    public let registrar: DeviceRegistrar
    public var credentials: AccountCredentials
    /// V5 签名器：内部 medusa 有状态机按 device_id+token 分桶，须跨请求复用同一实例。
    private let v5: HCSignerV5
    private let v5Lock = NSLock()

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
        self.v5 = HCSignerV5(device: Self.v5Device(from: credentials))
    }

    /// 把凭证 + 官方渠道档案组装成 V5 签名器要的 device dict。
    /// 关键：channel=69310258a（官方渠道，抓包实锤），version_code 默认 74332（视频/landpage 族）。
    private static func v5Device(from c: AccountCredentials) -> [String: String] {
        var d = CommonParams.defaults
        if !c.deviceId.isEmpty { d["device_id"] = c.deviceId }
        if !c.installId.isEmpty { d["iid"] = c.installId }
        // 凭证 device 字典可覆盖 rom_version / device_type / device_brand / carrier 等
        for (k, v) in c.device where !v.isEmpty { d[k] = v }
        if !c.token.isEmpty { d["device_token"] = c.token }
        d["channel"] = c.device["channel"] ?? "69310258a"
        return d
    }

    /// 凭证更新后同步 V5 签名器的 device dict（medusa 有状态按 did+token 分桶）。
    public func updateCredentials(_ c: AccountCredentials) {
        self.credentials = c
        v5Lock.lock()
        v5.updateDevice(Self.v5Device(from: c))
        v5Lock.unlock()
    }

    /// 给业务请求加公共头 + 签名。
    /// - Parameters:
    ///   - baseURL: 不含 query
    ///   - params: 业务 query 参数
    ///   - body: POST body；GET 传 nil
    ///   - extraHeaders: 调用方补充头
    ///   - appFamily: true = 搜索/弹幕/账号族（version 72232 / 7.2.2.32）；
    ///                false（默认）= 视频/landpage 族（74332 / 7.4.3.32）。抓包分族实锤。
    public func intercept(baseURL: String,
                          params: [String: String],
                          body: [UInt8]?,
                          extraHeaders: [String: String] = [:],
                          appFamily: Bool = false) -> SignedRequest {
        // 1) 合并公共 query（device_id / iid 来自凭证）
        var merged = CommonParams.query(
            deviceID: credentials.deviceId.isEmpty ? nil : credentials.deviceId,
            iid: credentials.installId.isEmpty ? nil : credentials.installId,
            installID: credentials.installId.isEmpty ? nil : credentials.installId
        )
        for (k, v) in params { merged[k] = v }

        // 2) 补全身份 query（原 app 弹幕/搜索 query 携带全身份，见抓包）
        if !credentials.token.isEmpty { merged["device_token"] = credentials.token }
        for key in ["openudid", "cdid", "klink_egdi", "rom", "rom_version",
                    "carrier", "mcc_mnc", "apk_first_install_time"] {
            if let v = credentials.device[key], !v.isEmpty { merged[key] = v }
        }

        // 3) V5 签名（gorgonAligned/0081 + medusa v5 + helios + ladon/argus）。
        //    appFamily 决定版本族：72232 走 appDevice，74332 走默认 device。
        let deviceOverride = appFamily ? HCVendor5.appDevice : nil
        v5Lock.lock()
        let req = v5.sign(baseURL, merged, body: body, method: nil, deviceOverride: deviceOverride)
        v5Lock.unlock()

        // 4) 注入公共头（等价 H0/d；V5 已产出的签名头以拦截器补充为准不覆盖）
        var headers = req.headers
        for (k, v) in extraHeaders { headers[k] = v }

        // Cookie：凭证 cookie
        if credentials.hasCookie {
            headers["Cookie"] = credentials.cookie
        }
        // X-SS-DP（V5 passport 路径已加，这里统一补齐）
        headers["x-ss-dp"] = Self.xSSDP
        // X-Tt-Token（登录后才有）
        if !credentials.token.isEmpty {
            headers["x-tt-token"] = credentials.token
        }

        // X-HGTV-Identity / X-HGTV-Anonymous
        if let identity = credentials.device["hgtv_identity"], !identity.isEmpty {
            headers[Self.hgtvIdentityHeader] = identity
        } else {
            let anon = credentials.device["hgtv_anonymous"]
                ?? CommonParams.sanitize(credentials.cdid, fallback: CommonParams.generateCdid())
            headers[Self.hgtvAnonymousHeader] = anon
        }

        // x-tt-trace-id（可空）
        if headers["x-tt-trace-id"] == nil {
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            headers["x-tt-trace-id"] = "00-\(uuid)-\(uuid.prefix(16))-01"
        }

        return SignedRequest(url: req.url, headers: headers, body: req.body, method: req.method)
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
