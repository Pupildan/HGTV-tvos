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

    /// 确保已注册。未注册则发起 device_register（走签名拦截器）。
    /// 签名占位阶段此请求会被服务端拒，但流程与接口已对齐原 APK。
    public func ensureRegistered() async throws {
        if isRegistered { return }
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

        let signed = try registrar.buildRequest(context: context)
        let req = signed.toURLRequest()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let reg = try registrar.parseResponse(
            status: http?.statusCode ?? 0,
            headers: http.map { $0.allHeaderFields as? [String: String] ?? [:] } ?? [:],
            body: [UInt8](data)
        )
        _ = registrar.apply(reg, to: context)
        Self.persistRegistration(registrar.registration)
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