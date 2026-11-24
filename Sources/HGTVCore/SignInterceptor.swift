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
    /// V5 签名总开关。v40 曾关掉 V5 绕开闪退；现打开 V5 + 阶段面包屑日志，真机一崩日志即定位崩点。
    public static var useV5: Bool = true
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
    /// landpage query 白名单（2026-11-24 突破版标准答案 = test_landpage_v2.py QUERY_VALUES，
    /// 29 键固定序；ts/_rticket 由签名器追加在末尾）。
    /// 关键：73532 landpage 族 query 【不带】 openudid/cdid/clientudid/install_id/
    /// rom/rom_version/carrier/mcc_mnc/apk_first_install_time/profile-format/
    /// openudid-source（此前 41 键序是 2026-11-22 抓包的旧规格，已被 11-24
    /// landpage 4/4 实测推翻）。
    static let landpageQueryOrder: [String] = [
        "ac", "channel", "aid", "app_name", "version_code", "version_name",
        "device_platform", "os", "ssmix", "device_type", "device_brand",
        "language", "os_api", "os_version", "manifest_version_code", "resolution",
        "dpi", "update_version_code", "host_abi", "dragon_device_type", "pv_player",
        "compliance_status", "need_personal_recommend", "player_so_load",
        "is_android_pad_screen", "device_id", "iid", "device_token", "klink_egdi",
        "ts", "_rticket",
    ]
    /// 弹幕/搜索族（72232）固定身份档案：真机 samsung 72232 活身份
    /// （test_danmu_v3.py 87 条实测标准答案，与身份 C 同一组）。
    /// 版本族 72232 与 klink_egdi/openudid/cdid/clientudid 绑定该身份，
    /// 与 landpage 族（73532/redroid Redmi）不能混用——弹幕请求无论当前
    /// credentials 是哪个身份，身份键一律强制用这一套。
    static let danmakuIdentity: [String: String] = [
        "device_id": "3093339275809908",
        "iid": "3093339275814004",
        "device_token": "AAAYR3N2COO6LZJBHO2XYPIAF6M3NSS5J6V7OSEOFUFSMFVJFWBQGUSVJZFM5PGGMP3AEEGH563FYN4VKTTLY5WAHOLP7UAEED32EHYEUP66MQOJY3RKP55U4NLL2",
        "klink_egdi": "AAKvKdL8rPboP7iOYP2Jh7Lx1-B_-p1lAqjFISZj_7vYL1nm2Kn8Rxo8",
        "openudid": "ac052ea31ff8401cba75",
        "openudid-source": "primary_random",
        "clientudid": "bd7c0136-435c-471c-86f8-106b851aa357",
        "cdid": "83bb8199-3cec-48ee-8e35-5c32232928c2",
        "rom": "F7310ZCS9GZF1",
        "rom_version": "BP4A.251205.006.F7310ZCS9GZF1",
        "device_type": "SM-F7310",
        "device_brand": "samsung",
        "resolution": "1226*1080",
        "dpi": "360",
        "carrier": "中国电信",
        "mcc_mnc": "46011",
        "apk_first_install_time": "1795345419167",
        "profile-format": "official-v1",
    ]
    /// 弹幕族 Cookie（test_danmu_v3.py COOKIE 实锤：install_id/store-region/
    /// store-region-src，无 ttreq）。
    static let danmakuCookie = "install_id=3093339275814004; store-region=cn-zj; store-region-src=did"
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
                          appFamily: Bool = false,
                          landpageFamily: Bool = false,
                          legacySigning: Bool = false) -> SignedRequest {
        // 1) 合并公共 query（device_id / iid 来自凭证）
        var merged = CommonParams.query(
            deviceID: credentials.deviceId.isEmpty ? nil : credentials.deviceId,
            iid: credentials.installId.isEmpty ? nil : credentials.installId,
            installID: credentials.installId.isEmpty ? nil : credentials.installId
        )
        for (k, v) in params { merged[k] = v }

        // 2) 补全身份 query（原 app 弹幕/搜索 query 携带全身份，见抓包）
        //    openudid/cdid/clientudid 用注册时的同一组值（覆盖 CommonParams 里的旧硬编码），
        //    device_id 与身份指纹一致是个性化接口的硬要求。
        if !credentials.token.isEmpty { merged["device_token"] = credentials.token }
        if landpageFamily {
            // landpage：先应用全部身份档案键（预置身份切换时档案随身份整体替换），
            // 再按白名单（landpageQueryOrder = test_landpage_v2.py QUERY_VALUES）裁剪。
            // 2026-11-24 突破版实锤：query 只留 29 键，openudid/cdid/clientudid/
            // install_id/rom/carrier/mcc_mnc 等档案键全部不进 query（服务端
            // 对 73532 族的多余键敏感，多带即静默 0B）。store_region 走头不走 query。
            for (k, v) in credentials.device where !v.isEmpty && k != "store_region" { merged[k] = v }
            let allow = Set(Self.landpageQueryOrder)
            merged = merged.filter { allow.contains($0.key) }
            merged.removeValue(forKey: "install_id")
        } else if appFamily {
            // 弹幕/搜索族（72232）：身份键固定用真机 samsung 72232 活身份
            // （danmakuIdentity，test_danmu_v3.py 87 条实测）。版本族与
            // klink_egdi/openudid/cdid/clientudid 绑定该身份，即使当前
            // credentials 已切到 landpage 族身份（Redmi）也不能混用。
            for (k, v) in Self.danmakuIdentity { merged[k] = v }
            // test_danmu_v3.py QUERY_VALUES 无 install_id（只有 iid）
            merged.removeValue(forKey: "install_id")
        } else {
            for key in ["openudid", "cdid", "clientudid", "klink_egdi", "rom", "rom_version",
                        "carrier", "mcc_mnc", "apk_first_install_time", "profile-format",
                        "openudid-source"] {
                if let v = credentials.device[key], !v.isEmpty { merged[key] = v }
            }
        }
        if landpageFamily {
            // 抓包实锤：原版 landpage query 不带 install_id
            merged.removeValue(forKey: "install_id")
        } else {
            // v85：非 landpage 请求的版本号必须与签名 PB 的族保持一致，
            // 否则出现「query 73532 / 签名 74332」自相矛盾（landpage 用 73532 走 defaults）。
            let vc = appFamily ? "72232" : "74332"
            let vn = appFamily ? "7.2.2.32" : "7.4.3.32"
            merged["version_code"] = vc
            merged["version_name"] = vn
            merged["manifest_version_code"] = vc
            merged["update_version_code"] = vc
            merged["pv_player"] = vc
        }

        // 3) 签名。legacySigning=true 或 V5 总开关关闭时直接走旧 XGorgon。
        let req: SignedRequest
        if !legacySigning && Self.useV5 {
            // V5 签名（gorgonAligned/0081 + medusa v5 + helios + ladon/argus）。
            // appFamily 决定版本族：72232 走 appDevice，74332 走默认 device。
            // V5 任一环节降级返回 nil 时，回退到旧 XGorgon 签名器，保证 App 不 crash、请求照发。
            var deviceOverride = landpageFamily ? HCVendor5.landpageDevice : (appFamily ? HCVendor5.appDevice : nil)
            if landpageFamily, !credentials.device.isEmpty, let base = deviceOverride {
                // 预置身份（三星档案）整体覆盖族默认（Redmi）——UA/medusa 同步随身份切换
                deviceOverride = base.merging(credentials.device) { _, new in new }
            }
            v5Lock.lock()
            // 2026-11-24 突破版：UA 版本号跟随签名 device dict 的 version_code
            // （landpage=73532 / 弹幕=72232 / 视频族=74332），POST 带完整 Cronet/TTNet
            // 后缀（与 Python 标准答案 UA 一致，出口不再裁剪）。
            // queryOrder：突破版 landpage 白名单键序（test_landpage_v2.py QUERY_VALUES）。
            let v5req = v5.sign(baseURL, merged, body: body, method: nil, deviceOverride: deviceOverride,
                                queryOrder: landpageFamily ? Self.landpageQueryOrder : nil)
            v5Lock.unlock()
            if let v5req {
                req = SignedRequest(url: v5req.url, headers: v5req.headers, body: v5req.body, method: v5req.method)
            } else {
                DiagnosticsLogger.warn("V5 签名降级，回退旧 XGorgon 签名器", category: "sign")
                req = signer.sign(baseURL: baseURL, params: merged, body: body, method: nil)
            }
        } else {
            req = signer.sign(baseURL: baseURL, params: merged, body: body, method: nil)
        }

        // 4) 注入公共头（等价 H0/d；V5 已产出的签名头以拦截器补充为准不覆盖）
        var headers = req.headers
        for (k, v) in extraHeaders { headers[k] = v }

        // Cookie：弹幕族固定 samsung 72232 Cookie（无 ttreq，test_danmu_v3.py 实锤）；
        // 其余请求用凭证 cookie（landpage 突破版 = install_id/store-region/ttreq/
        // store-region-src 四件套，无 device_token）
        if appFamily {
            headers["Cookie"] = Self.danmakuCookie
        } else if credentials.hasCookie {
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

        if landpageFamily || appFamily {
            // hdr_capture(01:07) + 2026-11-24 突破版（test_landpage_v2/test_danmu_v3）逐项对齐：
            // ① 原版不带 x-tt-token（device_token 只在 query，x-tt-token 是登录会话头）
            // ② 原版不带 X-HGTV-Anonymous / X-HGTV-Identity
            // ③ 原版不带 x-tt-trace-id
            // ④ 带 X-Tt-Store-Region / X-Tt-Store-Region-Src（TTNet 传输层注入）
            // ⑤ UA 保留完整形态：2026-11-24 实锤 landpage/弹幕 UA 均带 Cronet/TTNet
            //    后缀，且版本号与请求族一致（landpage=73532、弹幕=72232）——v66 的
            //    「裁 Cronet + 版本跟随旧族」已被新抓包推翻，此处不再裁剪。
            // x-tt-dt 保留：1.3.8.6 jadx J3 头组装实锤真版 app 明确发送 "x-tt-dt": ""
            headers.removeValue(forKey: "x-tt-token")
            headers.removeValue(forKey: Self.hgtvIdentityHeader)
            headers.removeValue(forKey: Self.hgtvAnonymousHeader)
            headers.removeValue(forKey: "x-tt-trace-id")
        }
        // X-Tt-Store-Region(-Src)：landpage 与弹幕族都带（Python 标准答案头集实锤）
        if landpageFamily || appFamily {
            let sr = credentials.device["store_region"] ?? ""
            if !sr.isEmpty {
                headers[HGTVConfig.HeaderKey.storeRegion] = sr
                headers[HGTVConfig.HeaderKey.storeRegionSrc] = "did"
            }
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
