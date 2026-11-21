// DeviceRegisterService.swift
// 设备注册引导 + 全局签名上下文。包装 Signing/DeviceRegister.swift 的完整
// DeviceRegistrar，作为单一入口供 AppModel / APIService / HTTPClient 使用。
//
// ⚠️ 签名层的 x-gorgon / x-argus 当前是占位实现（见 SIGNING_NOTES.md §5），
//    所以设备注册请求与后续签名请求尚不能通过服务端校验——这是已知限制，
//    不影响工程编译与界面/播放跑通。真实签名接入点见 Signing/XGorgon.swift。

import Foundation

public final class DeviceRegisterService: @unchecked Sendable {
    public static let shared = DeviceRegisterService()

    /// 全局签名器与设备注册器（与 SignInterceptor 共享同一实例）
    public let signer: RequestSigner
    public let registrar: DeviceRegistrar
    public let interceptor: SignInterceptor

    private let store = UserDefaults.standard
    private let keySession = "hgtv.session"

    private init() {
        let s = RequestSigner()
        self.signer = s
        // 启动时恢复已持久化的注册信息
        let restored = Self.loadRegistration()
        let r = DeviceRegistrar(signer: s, initial: restored)
        self.registrar = r
        self.interceptor = SignInterceptor(signer: s, registrar: r)
    }

    public var isRegistered: Bool {
        registrar.registration?.deviceToken.isEmpty == false
    }

    public func hasSession() async -> Bool {
        store.string(forKey: keySession) != nil
    }

    /// 确保已注册。优先走真实 device_register（金标准配方，本网络实测成功）；
    /// 成功后用全新身份（device_id/token/store-region cookie）更新签名凭证并持久化。
    /// 真实注册失败时回退旧占位流程，保证 App 可用。
    public func ensureRegistered() async throws {
        if isRegistered {
            DiagnosticsLogger.info("设备已注册，跳过", category: "device",
                                   meta: ["device_id": registrar.registration?.deviceID ?? "",
                                          "install_id": registrar.registration?.installID ?? ""])
            return
        }
        // —— 真实注册（金标准 v2 配方）——
        do {
            let id = try await RealDeviceRegister.register()
            let context = SignContext(
                deviceID: id.deviceID,
                deviceToken: id.deviceToken,
                installID: id.installID,
                versionCode: "74332",
                versionName: "7.4.3.32",
                osVersion: "16",
                deviceType: "25053RT47C",
                romVersion: "BP2A.250605.031.A3"
            )
            registrar.seed(context: context)
            let response = DeviceRegisterResponse(
                deviceID: id.deviceID, iid: id.installID, installID: id.installID,
                deviceToken: id.deviceToken, klinkEgdi: id.klinkEgdi,
                cookies: ["store-region": id.storeRegion]
            )
            _ = registrar.apply(response, to: context)
            Self.persistRegistration(registrar.registration)

            // 凭证同步进拦截器（V5 device dict + query device_token + Cookie store-region）
            interceptor.updateCredentials(AccountCredentials(
                cookie: "store-region=\(id.storeRegion)",
                token: id.deviceToken,
                tsSign: "",
                deviceId: id.deviceID,
                installId: id.installID,
                cdid: id.cdid,
                openudid: id.openudid,
                expiresAt: 0,
                device: ["klink_egdi": id.klinkEgdi,
                         "rom_version": "BP2A.250605.031.A3",
                         "rom": "BP2A.250605.031.A3",
                         "device_type": "25053RT47C",
                         "device_brand": "Redmi",
                         "carrier": "CHINA MOBILE",
                         "channel": "69310258a",
                         "store_region": id.storeRegion]
            ))
            DiagnosticsLogger.info("真实注册成功", category: "device", meta: [
                "device_id": id.deviceID,
                "install_id": id.installID,
                "token_len": "\(id.deviceToken.count)",
                "store_region": id.storeRegion,
            ])
            return
        } catch {
            DiagnosticsLogger.warn("真实注册失败，回退占位流程: \(error.localizedDescription)", category: "device")
        }

        // —— 旧占位流程（回退）——
        let context = SignContext(
            deviceID: registrar.registration?.deviceID ?? "",
            deviceToken: registrar.registration?.deviceToken ?? "",
            installID: registrar.registration?.installID ?? "",
            versionCode: String(HGTVConfig.versionCode),
            versionName: HGTVConfig.versionName,
            osVersion: "16",
            deviceType: "AppleTV",
            romVersion: "tvOS 26"
        )
        // 预注册占位（首次无 device_id）
        registrar.seed(context: context)

        do {
            let signed = try registrar.buildRequest(context: context)
            let req = signed.toURLRequest()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            DiagnosticsLogger.info("device_register 响应 status=\(http?.statusCode ?? 0) bytes=\(data.count)",
                                   category: "device")
            let reg = try registrar.parseResponse(
                status: http?.statusCode ?? 0,
                headers: http.map { $0.allHeaderFields as? [String: String] ?? [:] } ?? [:],
                body: [UInt8](data)
            )
            _ = registrar.apply(reg, to: context)
            Self.persistRegistration(registrar.registration)

            // —— 日志：注册结果（device_id / install_id / device_token 是否拿到）——
            let final = registrar.registration
            DiagnosticsLogger.info("设备注册成功", category: "device", meta: [
                "device_id": final?.deviceID ?? "",
                "install_id": final?.installID ?? "",
                "device_token_empty": "\(final?.deviceToken.isEmpty ?? true)",
                "device_token_len": "\(final?.deviceToken.count ?? 0)",
            ])
        } catch {
            // —— 日志：注册失败 ——
            let final = registrar.registration
            DiagnosticsLogger.error("设备注册失败：\(error.localizedDescription)", category: "device", meta: [
                "device_id": final?.deviceID ?? "",
                "install_id": final?.installID ?? "",
                "device_token_empty": "\(final?.deviceToken.isEmpty ?? true)",
            ])
            throw error
        }
    }

    /// 清空身份（对应原「恢复出厂 / 重新注册设备」）
    public func reset() {
        store.removeObject(forKey: keySession)
        store.removeObject(forKey: DeviceRegistrar.persistenceKey)
        // registration 由 DeviceRegistrar 内部管理，此处仅清持久化；
        // 下次 ensureRegistered 会重新 seed。
    }

    // MARK: - 持久化（跨启动恢复设备身份，对应原「重装恢复」）
    private static func loadRegistration() -> DeviceRegistration? {
        guard let data = UserDefaults.standard.data(forKey: DeviceRegistrar.persistenceKey) else { return nil }
        return try? JSONDecoder().decode(DeviceRegistration.self, from: data)
    }

    private static func persistRegistration(_ reg: DeviceRegistration?) {
        guard let reg, let data = try? JSONEncoder().encode(reg) else { return }
        UserDefaults.standard.set(data, forKey: DeviceRegistrar.persistenceKey)
    }
}