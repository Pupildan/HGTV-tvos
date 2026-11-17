// RootTabView.swift
// tvOS 26 顶层导航。遵循 tvOS 规范：顶部 TabView（焦点驱动），
// 每页内容用系统液态玻璃材质（.glass / .glassEffect），不自绘背景。

import SwiftUI
import HGTVCore

struct RootTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            RecommendView()
                .tabItem { Label("推荐", systemImage: "play.rectangle.fill") }

            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }

            // 电影频道（v23 占位）：电影条目走单独的内容通道，功能后期接上
            MovieView()
                .tabItem { Label("电影", systemImage: "film.fill") }

            CategoryView()
                .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            LibraryView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .overlay {
            // 启动引导：设备注册状态（对应原「初始化失败可直接重试」）
            if case .failed(let msg) = appModel.bootstrapState {
                BootstrapFailedView(message: msg)
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