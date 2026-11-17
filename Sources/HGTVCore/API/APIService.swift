// APIService.swift
// 业务接口层。严格按原 APK 数据获取方式：自建搜索中转 + 番茄内容接口 + Passport。
// 每个方法的 host/path/query 都来自 HGTVConfig（dex 原文）。

import Foundation

public final class APIService: Sendable {
    public static let shared = APIService()
    private let http = HTTPClient.shared

    // MARK: - 搜索（自建中转 hongguoduanju.com，无需签名）
    public func search(keyword: String, page: Int = 1) async throws -> [DramaItem] {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.hongguo,
            path: HGTVConfig.Path.searchResult,
            query: ["query": keyword, "page": String(page)],
            signed: false
        )
        // 中转站响应结构以实际为准（见 SIGNING_NOTES），先按 envelope 解
        let env = try await http.request(target, as: APIEnvelope<SearchResult>.self)
        return env.data?.items ?? []
    }

    public func searchSuggestion(keyword: String) async throws -> [SearchSuggestion] {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.hongguo,
            path: HGTVConfig.Path.searchSuggestion,
            query: ["query": keyword],
            signed: false
        )
        let env = try await http.request(target, as: APIEnvelope<[SearchSuggestion]>.self)
        return env.data ?? []
    }

    // MARK: - 内容（番茄接口，需签名）
    // 公共参数（aid/version/device_id/token/ts/_rticket）由 SignInterceptor 统一注入，
    // 这里只传业务参数，避免与 CommonParams.query 重复。

    // 内容源：/reading/bookapi/bookmall/tab/v —— 开发机已验证返回 62KB 真实数据
    //（分类导航 + 真实短剧名）。landpage 端点对原 APK 也返回空，故弃用。
    public func fetchHome() async throws -> [CategoryGroup] {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.bookmallTab,
            query: [:],
            signed: true
        )
        let env = try await http.request(target, as: APIEnvelope<BookmallData>.self)
        // 把每个 tab 映射为一个分类组，tab 里的剧目 cell 展开成 DramaItem
        let tabs = env.data?.tabItem ?? []
        return [CategoryGroup(id: "bookmall", name: "精选", items: tabs.map(\.dramaItem))]
    }

    public func fetchCategories() async throws -> CategoryLandpage {
        let groups = try await fetchHome()
        return CategoryLandpage(categoryList: groups)
    }

    public func fetchCategory(genre: String) async throws -> [DramaItem] {
        let groups = try await fetchHome()
        return groups.flatMap { $0.items ?? [] }
    }

    public func fetchDetail(bookId: String) async throws -> DramaDetail {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.multiDetail,
            query: ["book_id": bookId],
            signed: true
        )
        let env = try await http.request(target, as: APIEnvelope<DramaDetail>.self)
        return env.data ?? DramaDetail(bookId: bookId, title: nil, thumbURL: nil,
                                       description: nil, episodeList: [])
    }

    // MARK: - 播放模型（取流）
    public func fetchVideoModel(itemId: String) async throws -> VideoModel {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.videoModel,
            query: ["item_id": itemId],
            signed: true
        )
        let env = try await http.request(target, as: APIEnvelope<VideoModel>.self)
        guard let model = env.data else { throw HTTPError.streamExpired }
        return model
    }

    // MARK: - 登录态
    public func isLoggedIn() async -> Bool {
        await DeviceRegisterService.shared.hasSession()
    }
}