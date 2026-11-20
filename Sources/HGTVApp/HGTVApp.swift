// HGTVApp.swift
// tvOS 26 入口。遵循 tvOS 规范：全屏焦点驱动、TabView 顶层导航、
// 界面材质用系统 .glass（液态玻璃）效果，不自行造背景。

import SwiftUI
import HGTVCore

/// 「返回推荐」跨层通知：详情页浮层/详情页发出，根层与推荐页据此收起浮层、切回推荐 tab。
/// 「弹幕开关」跨层通知（v32）：功能面板发出，object=NSNumber(bool)，所有弹幕层即时生效。
extension Notification.Name {
    static let hgtvReturnToRecommend = Notification.Name("hgtvReturnToRecommend")
    static let hgtvDanmakuToggled = Notification.Name("hgtvDanmakuToggled")
}

@main
struct HGTVApp: App {
    @State private var appModel = AppModel()

    init() {
        // tvOS 上不做任何隐私弹窗前置（原 APK 的 targetSdk 29 逻辑不适用）；
        // 设备注册在首次联网时异步完成。

        // —— 日志诊断层：注册 TCP 回传通道（Bonjour 自动发现开发机）并启动，整个生命周期保持。
        //    fire-and-forget，不阻塞启动；Info.plist 未声明本地网络权限时通道会优雅重试，不影响 App。
        Task {
            await DiagnosticsLogger.shared.registerTransport(TCPTransport())
            await DiagnosticsLogger.shared.start()

            // —— V5 崩溃诊断：崩溃发生在日志通道建立之前，面包屑靠 UserDefaults 存活。
            //    若检测到上次崩溃的面包屑：本次先关掉 V5（不崩），把面包屑安稳 flush 出来。
            //    useV5=false 贯穿本次会话（拦截器读这个标志），保证 flush 不被再次崩溃打断。
            //    下次启动面包屑已被清空 → useV5 恢复 true → 再次复现崩→存新面包屑，交替一次必能发出。
            let pending = UserDefaults.standard.stringArray(forKey: "v5.crash.breadcrumbs") ?? []
            if !pending.isEmpty {
                SignInterceptor.useV5 = false   // 本次会话禁用 V5，安稳 flush 面包屑
                DiagnosticsLogger.warn("V5 诊断：检测到上次崩溃面包屑 \(pending.count) 条，本次会话禁用 V5 以 flush", category: "sign")
            }
            V5CrashBreadcrumbs.flushLastCrash()

            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            DiagnosticsLogger.info("App 启动 v\(ver) build \(build)", category: "app",
                                   meta: ["version": ver, "build": build,
                                          "os": ProcessInfo.processInfo.operatingSystemVersionString])
        }
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

    /// 当前选中的顶层 tab（0=推荐）。供「返回推荐」等功能跨层切换。
    var selectedTab: Int = 0
    /// 是否隐藏顶部 TabView 导航条：刷推荐流/播放时为 true（v24）。
    var tabBarHidden: Bool = false

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