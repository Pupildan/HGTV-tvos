// RealDeviceRegister.swift
// 真实 device_register —— 逐字段对照金标准 test_register_v2.py（本网络实测注册成功
// device_id=2970193670715852 / new_user=1 / store-region cookie）。
// 配方：POST log.snssdk.com/service/2/device_register/，body = ttEncrypt(gzip(JSON))，
// ttEncrypt = MAGIC(6B) + salt(32B 随机) + AES-128-CBC(km[0:16], km[16:32],
//             PKCS7(SHA512(gz) ++ gz))，km = SHA512(SHA512(salt) ++ F0_B)。
// 无签名头（注册端点在身份建立之前）。替换原占位注册（服务端曾恒返 device_id=0）。

import Foundation
import CryptoKit

enum RealDeviceRegister {

    static let host = "log.snssdk.com"
    static let path = "/service/2/device_register/"
    static let magic: [UInt8] = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00]
    /// F0.smali b:[B（e1.y hex 解码）—— KDF 盐
    static let kdfSalt: [UInt8] = Array<UInt8>(hex: "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

    // MARK: - 结果

    struct Identity {
        let deviceID: String
        let installID: String
        let deviceToken: String
        let klinkEgdi: String
        let storeRegion: String   // 如 "cn-zj"
        let cdid: String
        let openudid: String
    }

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

    static func buildPayloadJSON(nowMs: Int64) -> String {
        let cdid = UUID().uuidString.lowercased()
        let openudid = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        let clientudid = UUID().uuidString.lowercased()
        let reqID = UUID().uuidString.lowercased()
        // 手工拼 JSON（键序与金标准一致；红果显示名直接 UTF-8）
        return """
        {"magic_tag":"ss_app_log","header":{"display_name":"红果免费短剧","update_version_code":73532,"manifest_version_code":73532,"app_version_minor":"","aid":8662,"channel":"update_64","package":"com.phoenix.read","app_version":"7.3.5.32","version_code":73532,"sdk_version":"3.7.2","sdk_target_version":29,"os":"Android","os_version":"12","os_api":32,"device_model":"25053RT47C","device_brand":"Redmi","device_manufacturer":"Xiaomi","cpu_abi":"arm64-v8a","density_dpi":520,"display_density":"xxhdpi","resolution":"1280x2772","language":"zh","timezone":8,"access":"wifi","not_request_sender":0,"cdid":"\(cdid)","openudid":"\(openudid)","clientudid":"\(clientudid)","ipv6_list":[],"region":"CN","tz_name":"Asia/Shanghai","tz_offset":28800,"sim_region":"cn","sim_serial_number":[],"oaid_may_support":true,"req_id":"\(reqID)","device_platform":"android","custom":{"account_region_src":"fallback","host_bit":64,"account_region":"cn","dragon_device_type":"pad","is_android_fold":0,"filter_warn":0,"web_ua":"","is_android_pad":0},"pre_installed_channel":"","apk_first_install_time":\(nowMs),"is_system_app":0,"sdk_flavor":"china","guest_mode":0},"_gen_time":\(nowMs)}
        """
    }

    static func md5HexUpper(_ data: [UInt8]) -> String {
        let d = Insecure.MD5.hash(data: Data(data))
        return d.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - 发起注册

    /// 执行真实注册；成功返回身份（含 store-region）。
    public static func register() async throws -> Identity {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cdid = UUID().uuidString.lowercased()
        let openudid = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))

        let jsonStr = buildPayloadJSON(nowMs: nowMs)
        let gz = try Gzip.compress(Data(jsonStr.utf8))
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
        // store-region cookie（响应 Set-Cookie；domain snssdk.com）
        var region = "cn-zj"
        if let sc = http.value(forHTTPHeaderField: "Set-Cookie") ?? http.allHeaderFields["Set-Cookie"] as? String,
           let r = sc.split(separator: ";").first(where: { $0.contains("store-region") }) {
            let parts = r.split(separator: "=")
            if parts.count >= 2 { region = String(parts[1]) }
        }
        return Identity(deviceID: did, installID: iid, deviceToken: token,
                        klinkEgdi: egdi, storeRegion: region, cdid: cdid, openudid: openudid)
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        let chars = Array(hex)
        self = stride(from: 0, to: chars.count - 1, by: 2).map {
            UInt8(String(chars[$0]) + String(chars[$0 + 1]), radix: 16) ?? 0
        }
    }
}
