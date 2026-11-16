// HGTVApp.swift
// tvOS 26 入口。遵循 tvOS 规范：全屏焦点驱动、TabView 顶层导航、
// 界面材质用系统 .glass（液态玻璃）效果，不自行造背景。

import SwiftUI
import HGTVCore

@main
struct HGTVApp: App {
    @State private var appModel = AppModel()

    init() {
        // tvOS 上不做任何隐私弹窗前置（原 APK 的 targetSdk 29 逻辑不适用）；
        // 设备注册在首次联网时异步完成。
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
                .task {
                    // 启动即注册设备，取流与签名的前提（对应原 SessionBootstrap.init/onAppStart）
                    await appModel.bootstrap()
                }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var bootstrapState: BootstrapState = .idle
    var deviceReady = false

    enum BootstrapState: Equatable {
        case idle, registering, ready, failed(String)
    }

    func bootstrap() async {
        bootstrapState = .registering
        do {
            // 设备注册：产出 device_id / device_token，是所有签名请求的前提
            try await DeviceRegisterService.shared.ensureRegistered()
            deviceReady = true
            bootstrapState = .ready
        } catch {
            // 失败可重试，与原 APK「初始化失败可直接重试」一致
            bootstrapState = .failed(error.localizedDescription)
        }
    }
}