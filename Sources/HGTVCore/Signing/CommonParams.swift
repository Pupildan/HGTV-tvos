// CommonParams.swift
// 公共 query 参数 + User-Agent（对应 LF0/R3）。

import Foundation

public enum CommonParams {
    /// R3.a：静态默认 query map
    ///
    /// v85 关键修复（2026-11-23）：全套设备身份统一为「真机端到端验证过的那一套」
    /// （来源：手机真机抓包 replay_request.json，PC 重放该请求服务端返回 377KB 真实数据）。
    /// 此前项目内存在三套互相冲突的身份：
    ///   - HCVendor5.device        iid=1905892595382586 / Redmi
    ///   - CommonParams.defaults   iid=4280878733470867 / SM-F7310
    ///   - 真机                     iid=3093339275814004 / SM-F7310
    /// 签名（medusa PB）用一套、query 用另一套 → 服务端看到自相矛盾的身份 → 静默 200+0B。
    /// 现统一为真机这一套，且补齐原先缺失的 11 个字段
    /// （device_token / openudid / clientudid / cdid / klink_egdi / rom / rom_version /
    ///   mcc_mnc / carrier / apk_first_install_time / profile-format）。
    public static let defaults: [String: String] = [
        // —— 身份核心 ——
        "iid": "3093339275814004",
        "device_id": "3093339275809908",
        "install_id": "3093339275814004",
        "device_token": "AAAYR3N2COO6LZJBHO2XYPIAF6M3NSS5J6V7OSEOFUFSMFVJFWBQGUSVJZFM5PGGMP3AEEGH563FYN4VKTTLY5WAHOLP7UAEED32EHYEUP66MQOJY3RKP55U4NLL2",
        "openudid": "ac052ea31ff8401cba75",
        "openudid-source": "primary_random",
        "clientudid": "bd7c0136-435c-471c-86f8-106b851aa357",
        "cdid": "83bb8199-3cec-48ee-8e35-5c32232928c2",
        "klink_egdi": "AAKvKdL8rPboP7iOYP2Jh7Lx1-B_-p1lAqjFISZj_7vYL1nm2Kn8Rxo8",
        "profile-format": "official-v1",
        // —— 设备档案（必须与签名内 PB 完全一致）——
        "device_type": "SM-F7310",
        "device_brand": "samsung",
        "rom": "F7310ZCS9GZF1",
        "rom_version": "BP4A.251205.006.F7310ZCS9GZF1",
        "resolution": "1226*1080",
        "dpi": "360",
        "os_api": "36",
        "os_version": "16",
        "host_abi": "arm64-v8a",
        "mcc_mnc": "46011",
        "carrier": "中国电信",
        "apk_first_install_time": "1795345419167",
        // —— 应用/渠道 ——
        "ac": "wifi",
        "channel": "69310258a",
        "aid": "8662",
        "app_name": "novelread",
        "version_code": "73532",
        "version_name": "7.3.5.32",
        "manifest_version_code": "73532",
        "update_version_code": "73532",
        "pv_player": "73532",
        "device_platform": "android",
        "os": "android",
        "ssmix": "a",
        "language": "zh",
        "dragon_device_type": "phone",
        "compliance_status": "0",
        "need_personal_recommend": "1",
        "player_so_load": "1",
        "is_android_pad_screen": "0",
    ]

    /// R3.b：机型候选（行 1626-1628）
    static let deviceTypeCandidates = ["23046PNC9C", "24069RA21C", "23127PN0CC", "2211133C"]

    /// R3.c：构造请求 query（未登录时移除 device_id/iid/install_id）
    public static func query(channel: String = "hgtv-tv",
                             deviceID: String? = nil,
                             iid: String? = nil,
                             installID: String? = nil) -> [String: String] {
        var q = defaults
        // v85：不再在这里硬编码版本号，统一沿用 defaults 的 landpage 族（73532/7.3.5.32）。
        // 视频族(74332)/App族(72232) 由调用方通过 landpageFamily/appFamily 覆盖，
        // 否则会出现「query 版本号 74332、签名 PB 版本号 73532」的自相矛盾。
        q["ac"] = "wifi"
        q["aid"] = "8662"
        q["app_name"] = "novelread"
        q["device_platform"] = "android"
        q["os"] = "android"
        // credentials 为空时保留 defaults 里的已验证设备身份（不再删除导致请求无设备参数）。
        if let v = deviceID { q["device_id"] = v }
        if let v = iid { q["iid"] = v }
        if let v = installID { q["install_id"] = v }
        return q
    }

    /// R3.d：User-Agent
    /// - cronet=true 时带 Cronet/TTNet 后缀（POST 或带 body 请求）
    public static func userAgent(for device: [String: String]?, cronet: Bool) -> String {
        let vc = device?["version_code"] ?? "73532"
        let os = device?["os_version"] ?? "16"
        let model = device?["device_type"] ?? "SM-F7310"
        let build = device?["rom_version"] ?? "BP4A.251205.006.F7310ZCS9GZF1"
        if cronet {
            return "com.phoenix.read/\(vc) (Linux; U; Android \(os); zh_CN; \(model); Build/\(build); Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"
        } else {
            return "com.phoenix.read/\(vc) (Linux; U; Android \(os); zh_CN; \(model); Build/\(build))"
        }
    }

    /// R3.a(String, String)：清洗字符串（只保留 ASCII 32-126，trim 后 fallback）
    public static func sanitize(_ s: String?, fallback: String) -> String {
        guard let s = s else { return fallback }
        let filtered = String(s.filter { $0.isASCII && $0.asciiValue.map { (32..<127).contains($0) } ?? false })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? fallback : filtered
    }

    /// R3.b()：cdid 生成（"00-" + UUID 去 '-' + "-" + 前 16 位 + "-01"）
    public static func generateCdid() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let mid = String(uuid.prefix(16))
        return "00-\(uuid)-\(mid)-01"
    }
}
