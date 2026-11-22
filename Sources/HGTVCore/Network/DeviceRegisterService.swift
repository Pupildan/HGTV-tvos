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
    /// 完整身份凭证持久化（cdid/openudid/clientudid 等 DeviceRegistration 不含的字段）。
    /// 没有它，重启后拦截器凭证为空 → 所有请求回退旧硬编码身份 → 个性化接口拒绝。
    private let keyIdentity = "HGTV.identity.credentials"

    private struct StoredIdentity: Codable {
        var deviceID: String = ""
        var installID: String = ""
        var deviceToken: String = ""
        var klinkEgdi: String = ""
        var storeRegion: String = ""
        var cdid: String = ""
        var openudid: String = ""
        var clientudid: String = ""
        var apkFirstInstallTime: Int64 = 0
        var cookieHeader: String = ""
    }

    private init() {
        let s = RequestSigner()
        self.signer = s
        // 启动时恢复已持久化的注册信息
        let restored = Self.loadRegistration()
        let r = DeviceRegistrar(signer: s, initial: restored)
        self.registrar = r
        self.interceptor = SignInterceptor(signer: s, registrar: r)
        // —— 恢复完整身份凭证到拦截器（关键：否则重启后 query 用旧硬编码身份）——
        if let data = store.data(forKey: keyIdentity),
           let id = try? JSONDecoder().decode(StoredIdentity.self, from: data) {
            applyIdentity(id)
            DiagnosticsLogger.info("已恢复注册身份凭证", category: "device", meta: ["device_id": id.deviceID])
        }
    }

    /// 把身份凭证写入拦截器（V5 device dict + query 全身份）。
    private func applyIdentity(_ id: StoredIdentity) {
        let isPreset = !id.cookieHeader.isEmpty
        // 原版 Cookie 全集（hdr_capture 01:07 实锤）: install_id + store-region +
        // ttreq(服务端下发,新身份没有) + store-region-src。新注册身份补齐前三项。
        let cookieValue = id.cookieHeader.isEmpty
            ? "install_id=\(id.installID); store-region=\(id.storeRegion); store-region-src=did"
            : id.cookieHeader
        var dev = ["klink_egdi": id.klinkEgdi,
                   "openudid": id.openudid,
                   "cdid": id.cdid,
                   "clientudid": id.clientudid,
                   "rom_version": "BP2A.250605.031.A3",
                   "rom": "A3",
                   "device_type": "25053RT47C",
                   "device_brand": "Redmi",
                   "carrier": "CHINA MOBILE",
                   "mcc_mnc": "46000",
                   "openudid-source": "android_id",
                   "profile-format": "official-v1",
                   "channel": "69310258a",
                   "store_region": id.storeRegion]
        if String(id.apkFirstInstallTime) != "0" {
            dev["apk_first_install_time"] = String(id.apkFirstInstallTime)
        }
        if isPreset {
            // 预置身份=原版三星档案，query/V5 dict 全套随身份切换
            for (k, v) in RealDeviceRegister.presetProfile where k != "apk_first_install_time_marker" {
                dev[k] = v
            }
            if !id.cdid.isEmpty { dev["cdid"] = id.cdid }
            if !id.openudid.isEmpty { dev["openudid"] = id.openudid }
            if !id.clientudid.isEmpty { dev["clientudid"] = id.clientudid }
            if id.apkFirstInstallTime != 0 { dev["apk_first_install_time"] = String(id.apkFirstInstallTime) }
        }
        interceptor.updateCredentials(AccountCredentials(
            cookie: cookieValue,
            token: id.deviceToken,
            tsSign: "",
            deviceId: id.deviceID,
            installId: id.installID,
            cdid: id.cdid,
            openudid: id.openudid,
            expiresAt: 0,
            device: ["klink_egdi": id.klinkEgdi,
                     "openudid": id.openudid,
                     "cdid": id.cdid,
                     "clientudid": id.clientudid,
                     "openudid-source": "android_id",
                     "profile-format": "official-v1",
                     "mcc_mnc": "46000",
                     "rom": "A3",
                     "apk_first_install_time": String(id.apkFirstInstallTime),
                     "rom_version": "BP2A.250605.031.A3",
                     "device_type": "25053RT47C",
                     "device_brand": "Redmi",
                     "carrier": "CHINA MOBILE",
                     "channel": "69310258a",
                     "store_region": id.storeRegion]
        ))
    }

    private func saveIdentity(_ id: StoredIdentity) {
        if let data = try? JSONEncoder().encode(id) {
            store.set(data, forKey: keyIdentity)
        }
        applyIdentity(id)
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
        // 只有「已注册且完整身份凭证存在」才跳过；老版本只持久化了 registration
        //（缺 cdid/openudid/clientudid），凭证不完整必须重新走真实注册，否则 query
        // 里会混用旧指纹 → 个性化接口拒绝。
        if isRegistered, store.data(forKey: keyIdentity) != nil {
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

            // 凭证持久化 + 同步进拦截器（V5 device dict + query 全身份覆盖旧硬编码值）
            // 关键：openudid/cdid/clientudid 必须用注册 payload 里的同一组值，否则
            // device_id 与身份指纹不匹配，landpage 等个性化接口会拒绝。
            saveIdentity(StoredIdentity(
                deviceID: id.deviceID,
                installID: id.installID,
                deviceToken: id.deviceToken,
                klinkEgdi: id.klinkEgdi,
                storeRegion: id.storeRegion,
                cdid: id.cdid,
                openudid: id.openudid,
                clientudid: id.clientudid,
                apkFirstInstallTime: id.apkFirstInstallTime,
                cookieHeader: id.cookieHeader
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
        store.removeObject(forKey: keyIdentity)
        // registration 由 DeviceRegistrar 内部管理，此处仅清持久化；
        // 下次 ensureRegistered 会重新 seed。
    }

    /// 应用预置身份（原版「多设备身份切换」池）。写入凭证+持久化，返回是否成功。
    @discardableResult
    public func applyPresetIdentity(_ index: Int) -> Bool {
        guard index >= 0, index < RealDeviceRegister.presetIdentities.count else { return false }
        let id = RealDeviceRegister.presetIdentities[index]
        saveIdentity(StoredIdentity(
            deviceID: id.deviceID,
            installID: id.installID,
            deviceToken: id.deviceToken,
            klinkEgdi: id.klinkEgdi,
            storeRegion: id.storeRegion,
            cdid: id.cdid,
            openudid: id.openudid,
            clientudid: id.clientudid,
            apkFirstInstallTime: id.apkFirstInstallTime,
            cookieHeader: id.cookieHeader
        ))
        DiagnosticsLogger.info("切换到预置身份#\(index) device_id=\(id.deviceID)", category: "device")
        return true
    }

    /// 身份自愈（原 app 机制真机实锤：被拒 → rebuilding → 换新身份重试）。
    /// 强制清掉当前身份并重新注册一个全新的，返回后调用方立即用新身份重试。
    public func reregister() async throws {
        reset()
        // 用空身份 seed，让 isRegistered 变 false，ensureRegistered 才会真正重注册
        registrar.seed(context: SignContext(
            deviceID: "", deviceToken: "", installID: "",
            versionCode: "74332", versionName: "7.4.3.32",
            osVersion: "16", deviceType: "25053RT47C", romVersion: "BP2A.250605.031.A3"
        ))
        try await ensureRegistered()
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