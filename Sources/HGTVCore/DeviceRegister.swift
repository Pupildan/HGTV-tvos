// DeviceRegister.swift
// 设备注册流程（对应 F0.e1.S / F0.e1.q 的调用链）。
//
// ⚠️ 来源说明：
// signing_full.txt 里并未包含 device_register 端点的请求体构造类
// （搜索 "device_register" / "device_token" 只有 e1.S 行 2920-2931 命中，
//   那是「解析响应 → 写回 g0 字段」的部分，不是请求构造）。
// 请求构造类（TTNet device_register helper）未导出，下面是基于
// 已确认常量 + 端点路径 + 响应解析逻辑的推断实现，待补 dex 后校对。

import Foundation

public struct DeviceRegistration: Codable {
    public var deviceID: String
    public var iid: String
    public var installID: String
    public var deviceToken: String
    public var klinkEgdi: String?
    public var extraCookies: [String: String]
}

/// F0.D0：device_register 响应解析结果
public struct DeviceRegisterResponse {
    public var deviceID: String
    public var iid: String
    public var installID: String
    public var deviceToken: String
    public var klinkEgdi: String?
    public var cookies: [String: String]
}

public enum DeviceRegisterError: Error {
    case httpError(Int)
    case emptyBody
    case invalidJSON
    case missingField(String)
}

/// 设备注册 + 持久化存取（跨 actor 共享）
public final class DeviceRegistrar: @unchecked Sendable {
    private let signer: RequestSigner
    // 设备注册 host：严格用原 APK dex 里的 log5-applog-lf.fqnovel.com（此前误用
    // appapi2.phoenixfm.com，TLS 连不上导致设备注册失败、后续接口返回空）。
    private let host = "https://" + HGTVConfig.Host.deviceRegister
    private let path = HGTVConfig.Path.deviceRegister

    public private(set) var registration: DeviceRegistration?
    public static let persistenceKey = "HGTV.device.registration"

    public init(signer: RequestSigner, initial: DeviceRegistration? = nil) {
        self.signer = signer
        self.registration = initial
    }

    /// 预注册（首次没有 device_id 时用空值）
    public func seed(context: SignContext) {
        registration = DeviceRegistration(
            deviceID: context.deviceID, iid: context.installID,
            installID: context.installID, deviceToken: context.deviceToken,
            klinkEgdi: nil, extraCookies: [:]
        )
    }

    /// 构造注册请求（含签名头）
    public func buildRequest(context: SignContext) throws -> SignedRequest {
        let extra = [
            "tt_data": "a",
            "cronet_version": "8d40f833_2026-03-03",
            "ttnet_version": "4.2.243.31-douyin",
            "use_store_region_cookie": "1",
        ]
        let query = CommonParams.query(deviceID: nil, iid: nil, installID: nil)
            .merging(extra) { $1 }
        let body = buildBody(context: context)
        return signer.sign(baseURL: host + path, params: query, body: body, method: "POST")
    }

    /// 注册请求 body
    /// ⚠️ 待确认：真实字段来自未导出的 TTNet device_register 类。
    /// 下面字段基于 R3.a 默认参数 + 公共注册参数惯例推断。
    func buildBody(context: SignContext) -> [UInt8] {
        let payload: [String: Any] = [
            "app_name": "novelread",
            "version_code": context.versionCode,
            "version_name": context.versionName,
            "aid": context.aid,
            "device_id": context.deviceID.isEmpty ? "" : context.deviceID,
            "iid": context.installID.isEmpty ? "" : context.installID,
            "device_platform": "android",
            "os": "android",
            "os_version": context.osVersion,
            "device_type": context.deviceType,
            "rom_version": context.romVersion,
            "channel": "update_64",
            "language": "zh",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            return [UInt8](data)
        }
        return []
    }

    /// 解析 device_register 响应（对应 F0.e1.S 行 2920-2947）
    public func parseResponse(status: Int, headers: [String: String], body: [UInt8]) throws -> DeviceRegisterResponse {
        guard (200..<300).contains(status) else { throw DeviceRegisterError.httpError(status) }
        guard !body.isEmpty else { throw DeviceRegisterError.emptyBody }

        // TTNet 通常返回 JSON：{"device_id": "...", "install_id": "...", "device_token": "...", ...}
        // 或 key=value&... 形式；这里两种都尝试
        let text = String(decoding: body, as: UTF8.self)
        var fields: [String: String] = [:]
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in json {
                if let s = v as? String { fields[k] = s }
                else if let n = v as? NSNumber { fields[k] = n.stringValue }
            }
        } else {
            for pair in text.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
            }
        }

        guard let deviceID = fields["device_id"], !deviceID.isEmpty else {
            throw DeviceRegisterError.missingField("device_id")
        }
        let iid = fields["iid"] ?? fields["install_id"] ?? deviceID
        let installID = fields["install_id"] ?? iid
        let token = fields["device_token"] ?? ""
        let egdi = fields["klink_egdi"]

        var cookies: [String: String] = [:]
        for (k, v) in headers {
            if k.lowercased() == "set-cookie" {
                for piece in v.split(separator: ";") {
                    let kv = piece.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { cookies[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]) }
                }
            }
        }
        return DeviceRegisterResponse(
            deviceID: deviceID, iid: iid, installID: installID,
            deviceToken: token, klinkEgdi: egdi, cookies: cookies
        )
    }

    /// 把解析结果写回 SignContext（对应 F0.g0.n(Map) / p(Map)）
    public func apply(_ response: DeviceRegisterResponse, to base: SignContext) -> SignContext {
        var updated = base
        updated.deviceID = response.deviceID
        updated.installID = response.installID
        updated.deviceToken = response.deviceToken
        if !response.iid.isEmpty {
            updated.installID = response.iid
        }
        registration = DeviceRegistration(
            deviceID: response.deviceID, iid: updated.installID,
            installID: updated.installID, deviceToken: response.deviceToken,
            klinkEgdi: response.klinkEgdi, extraCookies: response.cookies
        )
        return updated
    }
}
