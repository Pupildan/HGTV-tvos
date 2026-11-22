// RealDeviceRegister.swift
// 真实 device_register —— 逐字段对照金标准 test_register_v2.py（本网络实测注册成功
// device_id=2970193670715852 / new_user=1 / store-region cookie）。
// 配方：POST log.snssdk.com/service/2/device_register/，body = ttEncrypt(gzip(JSON))，
// ttEncrypt = MAGIC(6B) + salt(32B 随机) + AES-128-CBC(km[0:16], km[16:32],
//             PKCS7(SHA512(gz) ++ gz))，km = SHA512(SHA512(salt) ++ F0_B)。
// 无签名头（注册端点在身份建立之前）。替换原占位注册（服务端曾恒返 device_id=0）。

import Foundation
import CryptoKit

public enum RealDeviceRegister {

    static let host = "log.snssdk.com"
    static let path = "/service/2/device_register/"
    static let magic: [UInt8] = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00]
    /// F0.smali b:[B（e1.y hex 解码）—— KDF 盐
    static let kdfSalt: [UInt8] = hexBytes("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

    // MARK: - 结果

    public struct Identity {
        public let deviceID: String
        public let installID: String
        public let deviceToken: String
        public let klinkEgdi: String
        public let storeRegion: String   // 如 "cn-zj"
        public let cdid: String
        public let openudid: String
        public let clientudid: String
        public let apkFirstInstallTime: Int64
        /// Cookie 头完整值（预置身份用；新注册为 store-region=...）
        public var cookieHeader: String = ""
        /// 身份专属设备档案（nil = 用共享 presetProfile）
        public var deviceProfile: [String: String]? = nil
    }

    // MARK: - 预置身份池（原版「多设备身份切换」机制）
    //
    // 身份 A：原版 app 会话镜像（hgtv-session-4.json，长龄身份，WiFi 下出过 feed 内容）
    // 身份 B：真机抓包 00:38:20 landpage 成功请求所用的全身份（流量网络）
    // 每个预置身份携带自己的完整三星档案——query/V5 device dict/UA 全套随之切换。

    public static let presetIdentities: [Identity] = [
        // 身份 C（2026-11-22 手机实测暖身份）：fgtv-v2 响应抓包确认其在 WiFi 下
        // landpage 连续成功（195-351KB/页，注册后 1 秒即成功），且 PC(OpenSSL/HTTP1.1)
        // 原样重放也成功（377KB）——目前已知最可信身份。放在池首。
        Identity(
            deviceID: "3093339275809908",
            installID: "3093339275814004",
            deviceToken: "AAAYR3N2COO6LZJBHO2XYPIAF6M3NSS5J6V7OSEOFUFSMFVJFWBQGUSVJZFM5PGGMP3AEEGH563FYN4VKTTLY5WAHOLP7UAEED32EHYEUP66MQOJY3RKP55U4NLL2",
            klinkEgdi: "AAKvKdL8rPboP7iOYP2Jh7Lx1-B_-p1lAqjFISZj_7vYL1nm2Kn8Rxo8",
            storeRegion: "cn-zj",
            cdid: "83bb8199-3cec-48ee-8e35-5c32232928c2",
            openudid: "ac052ea31ff8401cba75",
            clientudid: "bd7c0136-435c-471c-86f8-106b851aa357",
            apkFirstInstallTime: 1795345419167,
            cookieHeader: "install_id=3093339275814004; store-region=cn-zj; ttreq=1$f2e70aba5bc9e857702cb2ce81e55b09f31c04a6; store-region-src=did",
            deviceProfile: [
                "device_type": "SM-F7310",
                "device_brand": "samsung",
                "resolution": "1226*1080",
                "dpi": "360",
                "rom_version": "BP4A.251205.006.F7310ZCS9GZF1",
                "rom": "F7310ZCS9GZF1",
                "carrier": "中国电信",
                "mcc_mnc": "46011",
                "openudid-source": "primary_random",
                "profile-format": "official-v1",
            ]
        ),
        Identity(
            deviceID: "1290207924645523",
            installID: "1290207924649619",
            deviceToken: "AAA7T7NFJGA5NDYL3RSQ23JVCGLY4UWL2MTTGVKDDJ66MW64TTEBP6XR5XEBJ5DFGZ3T7RUISATOZQC4I56IH4EP4NP7KBQWT675NT2WASA3E6RVGO5BXUGIPNAVISNZTDJEB4PSWXSTA6URIWIMPNA",
            klinkEgdi: "AAIMvCd7m9xGnX_w0hwf-8CVdY3CvJd88f-TnF_4d103EYSW1en5mtcN",
            storeRegion: "cn-zj",
            cdid: "f77fc328-9e84-4189-bc97-60a295c58249",
            openudid: "4fea0f9308e38d43",
            clientudid: "416f820f-5179-49a6-8df9-2c17f30418c4",
            apkFirstInstallTime: 1795101759185,
            cookieHeader: "install_id=1290207924649619; store-region=cn-zj; ttreq=1$f2adb9f9171223811b67eb0e3e68ba76e214a43e; store-region-src=did"
        ),
        Identity(
            deviceID: "1642051663562816",
            installID: "1642051663566912",
            deviceToken: "AAAQQXI6MAI6UWSOORMFGG47ZKQYU5HQUX2MNH2UUEMLEVWPM2YR53LOA3RLTVXPFBWX24DTOFILZYUB3RIT7IIAQDCA6ZZFE5BSDN2XLBDN4GHE76NN6HG553VIURIMCYOBOANOZVJM572VKIUE6FA",
            klinkEgdi: "AAKC3PLVsVy7yEHcT5VfBF0AyK_V9_247B80nd9WgSxiYs5RmjkdU-So",
            storeRegion: "cn-zj",
            cdid: "2541aee9-7df2-4be1-8d32-ce1976da00ab",
            openudid: "4fea0f9308e38d43",
            clientudid: "16c5281f-12c7-42d2-9612-37f096a41300",
            apkFirstInstallTime: 1795105798067,
            cookieHeader: "install_id=1642051663566912; store-region=cn-zj; store-region-src=did"
        ),
    ]

    /// 预置身份的完整三星档案（query/V5 dict 共用；与对应 device_id 注册时一致）
    static let presetProfile: [String: String] = [
        "device_type": "SM-F7310",
        "device_brand": "samsung",
        "resolution": "2546*1080",
        "dpi": "480",
        "rom_version": "BP4A.251205.006.F7310ZCS9GZF1",
        "rom": "F7310ZCS9GZF1",
        "carrier": "中国电信",
        "mcc_mnc": "46011",
        "openudid-source": "android_id",
        "profile-format": "official-v1",
        "apk_first_install_time_marker": "1",
    ]

    // MARK: - ttEncrypt 信封

    static func ttEncrypt(_ data: [UInt8]) -> [UInt8]? {
        let salt = secureRandom(32)
        let shaSalt = SHA512.hash(data: salt)
        let km = SHA512.hash(data: Array(shaSalt) + kdfSalt)
        let kmBytes = Array(km)
        var body = Array(SHA512.hash(data: data)) + data
        let pad = 16 - (body.count % 16)
        body += [UInt8](repeating: UInt8(pad), count: pad)
        // CBC：在现有单块 ECB 上做链式异或
        let iv = Array(kmBytes[16..<32])
        let key = Array(kmBytes[0..<16])
        var prev = iv
        var out = [UInt8]()
        out.reserveCapacity(body.count)
        for off in stride(from: 0, to: body.count, by: 16) {
            let blk = (0..<16).map { body[off + $0] ^ prev[$0] }
            let enc = CENCDecryptor.ecbEncryptBlock(key: key, block: blk)
            out += enc
            prev = enc
        }
        return magic + salt + out
    }

    static func secureRandom(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    // MARK: - 注册 payload（JSON 手工拼串，与金标准字节级一致）

    static func buildPayloadJSON(nowMs: Int64) -> (json: String, cdid: String, openudid: String, clientudid: String) {
        let cdid = UUID().uuidString.lowercased()
        let openudid = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        let clientudid = UUID().uuidString.lowercased()
        let reqID = UUID().uuidString.lowercased()
        // 手工拼 JSON（键序与金标准一致；红果显示名直接 UTF-8）
        let json = """
        {"magic_tag":"ss_app_log","header":{"display_name":"红果免费短剧","update_version_code":73532,"manifest_version_code":73532,"app_version_minor":"","aid":8662,"channel":"update_64","package":"com.phoenix.read","app_version":"7.3.5.32","version_code":73532,"sdk_version":"3.7.2","sdk_target_version":29,"os":"Android","os_version":"12","os_api":32,"device_model":"25053RT47C","device_brand":"Redmi","device_manufacturer":"Xiaomi","cpu_abi":"arm64-v8a","density_dpi":520,"display_density":"xxhdpi","resolution":"1280x2772","language":"zh","timezone":8,"access":"wifi","not_request_sender":0,"cdid":"\(cdid)","openudid":"\(openudid)","clientudid":"\(clientudid)","ipv6_list":[],"region":"CN","tz_name":"Asia/Shanghai","tz_offset":28800,"sim_region":"cn","sim_serial_number":[],"oaid_may_support":true,"req_id":"\(reqID)","device_platform":"android","custom":{"account_region_src":"fallback","host_bit":64,"account_region":"cn","dragon_device_type":"pad","is_android_fold":0,"filter_warn":0,"web_ua":"","is_android_pad":0},"pre_installed_channel":"","apk_first_install_time":\(nowMs),"is_system_app":0,"sdk_flavor":"china","guest_mode":0},"_gen_time":\(nowMs)}
        """
        return (json, cdid, openudid, clientudid)
    }

    static func md5HexUpper(_ data: [UInt8]) -> String {
        let d = Insecure.MD5.hash(data: Data(data))
        return d.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - 发起注册

    /// 执行真实注册；成功返回身份（含 store-region）。
    public static func register() async throws -> Identity {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // payload 与 query 必须用同一组 cdid/openudid/clientudid（服务端校验一致性）
        let payload = buildPayloadJSON(nowMs: nowMs)
        let cdid = payload.cdid
        let openudid = payload.openudid
        let clientudid = payload.clientudid

        let gz = try Gzip.compress(Data(payload.json.utf8))
        guard let body = ttEncrypt([UInt8](gz)) else { throw HTTPError.invalidResponse }

        // query 与金标准一致（73532 族 + 随机 cdid/openudid + ts/_rticket）
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = host; comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "ac", value: "wifi"),
            URLQueryItem(name: "aid", value: "8662"),
            URLQueryItem(name: "app_name", value: "novelread"),
            URLQueryItem(name: "channel", value: "update_64"),
            URLQueryItem(name: "device_brand", value: "Redmi"),
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "device_type", value: "25053RT47C"),
            URLQueryItem(name: "dpi", value: "520"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "manifest_version_code", value: "73532"),
            URLQueryItem(name: "os", value: "android"),
            URLQueryItem(name: "os_api", value: "36"),
            URLQueryItem(name: "os_version", value: "16"),
            URLQueryItem(name: "resolution", value: "1280*2772"),
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "update_version_code", value: "73532"),
            URLQueryItem(name: "version_code", value: "73532"),
            URLQueryItem(name: "version_name", value: "7.3.5.32"),
            URLQueryItem(name: "cdid", value: cdid),
            URLQueryItem(name: "openudid", value: openudid),
            URLQueryItem(name: "tt_data", value: "a"),
            URLQueryItem(name: "package", value: "com.phoenix.read"),
            URLQueryItem(name: "ts", value: String(nowMs / 1000)),
            URLQueryItem(name: "_rticket", value: String(nowMs)),
        ]
        guard let url = comps.url else { throw HTTPError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body)
        req.setValue("com.phoenix.read/73532 (Linux; U; Android 12; zh_CN; 25053RT47C; Build/SKQ1.211006.001)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/octet-stream;tt-data=a", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        req.setValue("gzip", forHTTPHeaderField: "log-encode-type")
        req.setValue("t=0;n=1", forHTTPHeaderField: "X-Tt-Request-Tag")
        req.setValue("8662", forHTTPHeaderField: "x-ss-dp")
        req.setValue(String(nowMs), forHTTPHeaderField: "x-ss-req-ticket")
        req.setValue("4.0.3.cn", forHTTPHeaderField: "x-vc-bdturing-sdk-version")
        req.setValue("102", forHTTPHeaderField: "lc")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        req.setValue("60755", forHTTPHeaderField: "passport-sdk-version")
        req.setValue("device_transfer_s_0,device_transfer_ab_1", forHTTPHeaderField: "passport-sdk-settings")
        req.setValue("cn", forHTTPHeaderField: "x-tt-store-region")
        req.setValue("did", forHTTPHeaderField: "x-tt-store-region-src")
        req.setValue("-8|50:51:59:30:40:47:49:39", forHTTPHeaderField: "x-neptune")
        req.setValue(md5HexUpper(body), forHTTPHeaderField: "x-ss-stub")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        let (data, resp) = try await session.data(for: req)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError.catalogHTTP((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let did = (obj["device_id_str"] as? String) ?? String(describing: obj["device_id"] ?? "0")
        let iid = (obj["install_id_str"] as? String) ?? String(describing: obj["install_id"] ?? "0")
        let token = obj["device_token"] as? String ?? ""
        let egdi = obj["klink_egdi"] as? String ?? ""
        guard did != "0", !did.isEmpty, !token.isEmpty else {
            DiagnosticsLogger.error("真实注册被拒: \(String(data: data, encoding: .utf8) ?? "")", category: "device")
            throw HTTPError.deviceNotRegistered
        }
        // 注册响应 Set-Cookie 全集（fgtv-v2 响应抓包实锤：服务端下发
        // store-region / store-region-src / install_id / ttreq 四件套；
        // 原版 landpage 请求 Cookie 带全其中所有项——ttreq 之前被丢弃）。
        // URLSession 会把多段 Set-Cookie 合并进 allHeaderFields，交给 HTTPCookie 拆。
        var region = "cn-zj"
        var cookies: [String: String] = [:]
        if let sc = http.allHeaderFields["Set-Cookie"] as? String,
           let url = resp.url {
            for c in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": sc], for: url) {
                cookies[c.name] = c.value
            }
        }
        if let v = cookies["store-region"] { region = v }
        // 顺序与原版一致：install_id; store-region; ttreq; store-region-src
        let order = ["install_id", "store-region", "ttreq", "store-region-src"]
        let cookieHeader = order
            .compactMap { name -> String? in
                guard let v = cookies[name], !v.isEmpty else { return nil }
                return "\(name)=\(v)"
            }
            .joined(separator: "; ")
        return Identity(deviceID: did, installID: iid, deviceToken: token,
                        klinkEgdi: egdi, storeRegion: region, cdid: cdid,
                        openudid: openudid, clientudid: clientudid,
                        apkFirstInstallTime: nowMs,
                        cookieHeader: cookieHeader.isEmpty ? "store-region=\(region)" : cookieHeader)
    }
}

private func hexNibble(_ c: UInt8) -> UInt8 {
    switch c {
    case 0x30...0x39: return c - 0x30          // 0-9
    case 0x61...0x66: return c - 0x61 + 10     // a-f
    case 0x41...0x46: return c - 0x41 + 10     // A-F
    default: return 0
    }
}

private func hexBytes(_ hex: String) -> [UInt8] {
    let c = Array(hex.utf8)
    var out = [UInt8]()
    out.reserveCapacity(c.count / 2)
    var i = 0
    while i + 1 < c.count {
        out.append(hexNibble(c[i]) << 4 | hexNibble(c[i + 1]))
        i += 2
    }
    return out
}
