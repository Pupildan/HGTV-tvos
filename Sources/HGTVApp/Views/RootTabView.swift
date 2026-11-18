// RootTabView.swift
// tvOS 26 顶层导航。遵循 tvOS 规范：顶部 TabView（焦点驱动），
// 每页内容用系统液态玻璃材质（.glass / .glassEffect），不自绘背景。

import SwiftUI
import UIKit
import HGTVCore

struct RootTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // @Environment 注入的 Observable 需先 Bindable 才能用 $ 做双向绑定（SwiftUI 约束）
        @Bindable var appModel = appModel
        TabView(selection: $appModel.selectedTab) {
            RecommendView()
                .tabItem { Label("推荐", systemImage: "play.rectangle.fill") }
                .tag(0)

            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(1)

            // 电影频道（v23 占位）：电影条目走单独的内容通道，功能后期接上
            MovieView()
                .tabItem { Label("电影", systemImage: "film.fill") }
                .tag(2)

            CategoryView()
                .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                .tag(3)

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(4)

            LibraryView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .tag(5)
        }
        .overlay {
            // 启动引导：设备注册状态（对应原「初始化失败可直接重试」）
            if case .failed(let msg) = appModel.bootstrapState {
                BootstrapFailedView(message: msg)
            }
        }
        // v24：刷推荐流/播放时彻底隐藏顶部 tab 条（UIKit 层无官方 SwiftUI API）
        .background(TabBarHider(hidden: appModel.tabBarHidden))
        // v24：接收「返回推荐」——切回推荐 tab 并恢复导航条
        .onReceive(NotificationCenter.default.publisher(for: .hgtvReturnToRecommend)) { _ in
            Task { @MainActor in
                appModel.selectedTab = 0
                appModel.tabBarHidden = true
            }
        }
    }
}

/// 电影频道占位页（v23）：电影内容通道与短剧不同（multi_video_model 不下发播放地址），
/// 功能后期接入；先占住顶部栏位。
struct MovieView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.85))
            Text("电影频道")
                .font(.title2.bold())
            Text("内容接入中，敬请期待")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .glassEffect()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct BootstrapFailedView: View {
    @Environment(AppModel.self) private var appModel
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                Text("初始化失败")
                    .font(.title2)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await appModel.bootstrap() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .glassEffect()   // 液态玻璃卡片
            .cornerRadius(20)
        }
    }
}

// MARK: - 顶部 Tab 条隐藏（v24）
//
// SwiftUI TabView 在 tvOS 上由 UITabBar 承载顶部导航条，官方没有隐藏 API。
// 通过递归遍历当前 window 找到 UITabBar 实例，直接改 isHidden / alpha 实现
// 「播放时彻底不可见」。用 UIViewRepresentable 挂载，hidden 变化时重新应用。
struct TabBarHider: UIViewRepresentable {
    let hidden: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 延迟到布局完成后再找（TabView 的 UITabBar 此时才挂载到 window）
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            Self.apply(to: window, hidden: hidden)
        }
    }

    private static func apply(to root: UIView, hidden: Bool) {
        if let tabBar = root as? UITabBar {
            tabBar.isHidden = hidden
            tabBar.isUserInteractionEnabled = !hidden
            tabBar.alpha = hidden ? 0 : 1
            return
        }
        for sub in root.subviews {
            apply(to: sub, hidden: hidden)
        }
    }
}