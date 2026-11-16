// HomeView.swift
// 首页分区剧架 + 榜单。tvOS 焦点驱动横向滚动（LazyHGrid + focusable），
// 卡片用液态玻璃。数据走原分类落地页 / 推荐接口。

import SwiftUI
import HGTVCore

@MainActor
@Observable
final class HomeViewModel {
    var sections: [CategoryGroup] = []
    var isLoading = false
    var errorMessage: String?

    func load() async {
        guard sections.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sections = try await APIService.shared.fetchHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HomeView: View {
    @State private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(model.sections) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
            .navigationTitle("首页")
            .navigationDestination(for: DramaItem.self) { item in
                DramaDetailView(item: item)
            }
            .overlay {
                if model.isLoading { ProgressView() }
                if let err = model.errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(err))
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private func section(_ group: CategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.name ?? "")
                .font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(group.items ?? []) { item in
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

// tvOS 标准海报卡：焦点放大 + 液态玻璃容器
struct PosterCard: View {
    let item: DramaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: item.thumbURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                case .failure: Image(systemName: "photo").resizable().aspectRatio(2/3, contentMode: .fit)
                default: Color.gray.opacity(0.3)
                }
            }
            .frame(width: 150, height: 225)
            .cornerRadius(12)
            .glassEffect()

            Text(item.title ?? "")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
    }
}