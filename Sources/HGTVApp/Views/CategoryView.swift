// CategoryView.swift
// 分类页：大类 / 小类筛选 + 剧架。面板与已选列表缓存（对应原 hgtv-category-panel-cache）。

import SwiftUI
import HGTVCore

@MainActor
@Observable
final class CategoryViewModel {
    var genres: [String] = []
    var selectedGenre: String?
    var items: [DramaItem] = []
    var isLoading = false
    var errorMessage: String?

    func load() async {
        guard genres.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let landpage = try await APIService.shared.fetchCategories()
            // 从分类落地页抽大类名（真实字段以接口为准，见 SIGNING_NOTES / 接口核对）
            genres = (landpage.categoryList ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }
            selectedGenre = genres.first
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let genre = selectedGenre else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await APIService.shared.fetchCategory(genre: genre)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CategoryView: View {
    @State private var model = CategoryViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 20) {
                    ForEach(model.items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
            .navigationTitle(model.selectedGenre ?? "分类")
            .navigationDestination(for: DramaItem.self) { item in
                DramaDetailView(item: item)
            }
            .safeAreaInset(edge: .top) {
                genreBar
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

    private var genreBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.genres, id: \.self) { genre in
                    Button(genre) {
                        model.selectedGenre = genre
                        Task { await model.reload() }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.selectedGenre == genre ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)   // 液态玻璃分隔条
    }
}