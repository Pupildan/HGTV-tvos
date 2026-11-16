// SearchView.swift
// 搜索页：走自建中转 hongguoduanju.com（原 APK 的搜索结果/联想接口），
// 历史搜索在前、推荐词在后，每页 50 条。tvOS 用 .searchable 焦点输入。

import SwiftUI
import HGTVCore

@MainActor
@Observable
final class SearchViewModel {
    var keyword = ""
    var results: [DramaItem] = []
    var suggestions: [SearchSuggestion] = []
    var history: [String] = []
    var isLoading = false
    var errorMessage: String?

    func search() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        remember(kw)
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            results = try await APIService.shared.search(keyword: kw)
        } catch {
            // 原 APK：接口偶发空响应会自动重发；这里给可重试提示
            errorMessage = error.localizedDescription
        }
    }

    func loadSuggestions() async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard kw.count >= 1 else { suggestions = []; return }
        suggestions = (try? await APIService.shared.searchSuggestion(keyword: kw)) ?? []
    }

    private func remember(_ kw: String) {
        history.removeAll { $0 == kw }
        history.insert(kw, at: 0)
        if history.count > 20 { history.removeLast() }
    }
}

struct SearchView: View {
    @State private var model = SearchViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 20) {
                    ForEach(model.results) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
            }
            .navigationTitle("搜索")
            .navigationDestination(for: DramaItem.self) { item in
                DramaDetailView(item: item)
            }
            .searchable(text: $model.keyword, placement: .automatic, prompt: "搜索短剧")
            .onSubmit(of: .search) {
                Task { await model.search() }
            }
            .onChange(of: model.keyword) { _, _ in
                Task { await model.loadSuggestions() }
            }
            .overlay {
                if model.isLoading { ProgressView() }
                if let err = model.errorMessage {
                    ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle",
                                           description: Text(err + "\n接口偶发空响应，可重试"))
                } else if model.results.isEmpty && !model.keyword.isEmpty && !model.isLoading {
                    ContentUnavailableView.search(text: model.keyword)
                }
            }
        }
    }
}