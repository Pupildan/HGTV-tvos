// LibraryView.swift
// 「我的」页：本机收藏 / 最近观看 / 稍后看。
// 原 APK 这些数据存本机（hgtv-library-*.json），登录后才同步云端；
// tvOS 端先落地本机存储，登录同步留接口。

import SwiftUI
import HGTVCore

@MainActor
@Observable
final class LibraryViewModel {
    var favorites: [DramaItem] = []
    var history: [DramaItem] = []
    var watchLater: [DramaItem] = []
    var loggedIn = false

    func load() async {
        favorites = LocalLibrary.shared.favorites
        history = LocalLibrary.shared.history
        watchLater = LocalLibrary.shared.watchLater
        loggedIn = await APIService.shared.isLoggedIn()
    }

    func clearHistory() {
        LocalLibrary.shared.clearHistory()
        history = []
    }
}

struct LibraryView: View {
    @State private var model = LibraryViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    section("收藏", model.favorites)
                    section("最近观看", model.history)
                    section("稍后看", model.watchLater)
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
            .navigationTitle("我的")
            .navigationDestination(for: DramaItem.self) { item in
                DramaDetailView(item: item)
            }
            .toolbar {
                ToolbarItem {
                    Button("清空观看记录") { model.clearHistory() }
                }
                ToolbarItem {
                    // 扫码 / 验证码登录入口，登录后同步云端
                    Button(model.loggedIn ? "已登录" : "登录") {}
                        .disabled(model.loggedIn)
                }
            }
            .overlay {
                if model.favorites.isEmpty && model.history.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "heart",
                                           description: Text("收藏与进度保存在本机"))
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [DramaItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
            }
        }
    }
}