// DramaDetailView.swift
// 详情页 + 选集网格。对应原 multi-detail 接口与「选集网格每页 10-50 集」。
// tvOS 焦点驱动，点选集进 AVPlayer 播放。

import SwiftUI
import HGTVCore

@MainActor
@Observable
final class DetailViewModel {
    var detail: DramaDetail?
    var isLoading = false
    var errorMessage: String?

    func load(bookId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await APIService.shared.fetchDetail(bookId: bookId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DramaDetailView: View {
    let item: DramaItem
    @State private var model = DetailViewModel()
    @State private var selectedEpisode: Episode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                episodeGrid
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 30)
        }
        .navigationTitle(item.title ?? "")
        .overlay {
            if model.isLoading { ProgressView() }
            if let err = model.errorMessage {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(err))
            }
        }
        .sheet(item: $selectedEpisode) { ep in
            NavigationStack {
                PlayerView(item: item)
            }
        }
        .task { await model.load(bookId: item.bookId ?? item.id) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 30) {
            AsyncImage(url: item.thumbURL) { img in
                img.resizable().aspectRatio(2/3, contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 220, height: 330)
            .cornerRadius(14)
            .glassEffect()

            VStack(alignment: .leading, spacing: 12) {
                Text(item.title ?? "").font(.title2.bold())
                if let desc = item.description {
                    Text(desc).font(.callout).foregroundStyle(.secondary)
                }
                if let cat = item.category {
                    Text(cat).font(.caption).padding(6).background(.ultraThinMaterial).cornerRadius(6)
                }
            }
        }
    }

    @ViewBuilder
    private var episodeGrid: some View {
        if let eps = model.detail?.episodeList, !eps.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("选集").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 14)], spacing: 14) {
                    ForEach(eps) { ep in
                        Button {
                            selectedEpisode = ep
                        } label: {
                            Text(ep.title ?? "第\(ep.index)集")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}