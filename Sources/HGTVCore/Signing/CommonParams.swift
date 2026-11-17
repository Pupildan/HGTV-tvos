// CommonParams.swift
// 公共 query 参数 + User-Agent（对应 LF0/R3）。

import Foundation

public enum CommonParams {
    /// R3.a：静态默认 query map
    /// 设备身份已替换为开发机端到端验证过的真实值（原 APK 注册产物，
    /// bookmall/tab 实测返回 62KB 真实数据）。旧的红米假设备身份会导致内容接口返空。
    public static let defaults: [String: String] = [
        "iid": "4280878733470867",
        "device_id": "4280878733466771",
        "install_id": "4280878733470867",
        "openudid": "25bc291e06c950fa3431",
        "cdid": "7868af32-90ad-441e-b1f8-3ef7d1c515ff",
        "clientudid": "4b59a9f3-d9a9-42ee-b58a-0e0fa13c9ee5",
        "ac": "wifi",
        "channel": "update_64",
        "aid": "8662",
        "app_name": "novelread",
        "version_code": "74332",
        "version_name": "7.4.3.32",
        "device_platform": "android",
        "os": "android",
        "ssmix": "a",
        "device_type": "SM-F7310",
        "resolution": "2546*1080",
        "need_personal_recommend": "1",
        "player_so_load": "1",
        "is_android_pad_screen": "0",
        "device_brand": "samsung",
        "language": "zh",
        "os_api": "36",
        "os_version": "16",
        "manifest_version_code": "74332",
        "dpi": "480",
        "update_version_code": "74332",
        "host_abi": "arm64-v8a",
        "dragon_device_type": "phone",
        "pv_player": "74332",
        "compliance_status": "0",
    ]

    /// R3.b：机型候选（行 1626-1628）
    static let deviceTypeCandidates = ["23046PNC9C", "24069RA21C", "23127PN0CC", "2211133C"]

    /// R3.c：构造请求 query（未登录时移除 device_id/iid/install_id）
    public static func query(channel: String = "hgtv-tv",
                             deviceID: String? = nil,
                             iid: String? = nil,
                             installID: String? = nil) -> [String: String] {
        var q = defaults
        // device_type 保持 defaults 里的已验证值（SM-F7310），不再随机覆盖为红米型号，
        // 否则会破坏与开发机验证一致的设备指纹导致内容接口返空。
        q["ac"] = "wifi"
        q["channel"] = "update_64"
        q["aid"] = "8662"
        q["app_name"] = "novelread"
        q["version_code"] = "74332"
        q["version_name"] = "7.4.3.32"
        q["manifest_version_code"] = "74332"
        q["update_version_code"] = "74332"
        q["pv_player"] = "74332"
        q["device_platform"] = "android"
        q["os"] = "android"
        q["os_api"] = "36"
        q["os_version"] = "16"
        // credentials 为空时保留 defaults 里的已验证设备身份（不再删除导致请求无设备参数）。
        if let v = deviceID { q["device_id"] = v }
        if let v = iid { q["iid"] = v }
        if let v = installID { q["install_id"] = v }
        return q
    }

    /// R3.d：User-Agent
    /// - cronet=true 时带 Cronet/TTNet 后缀（POST 或带 body 请求）
    public static func userAgent(for device: [String: String]?, cronet: Bool) -> String {
        let vc = device?["version_code"] ?? "74332"
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
