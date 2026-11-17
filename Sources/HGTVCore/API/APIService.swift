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

    // 内容源：/reading/bookapi/bookmall/tab/v —— 开发机已验证返回 ~65KB 真实数据
    //（真实剧在任意嵌套深度的 video_data 里：title/cover/video_desc/series_id）。
    public func fetchHome() async throws -> [CategoryGroup] {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.bookmallTab,
            query: [:],
            signed: true
        )
        let raw = try await http.request(target)
        let dramas = Self.extractVideos(from: raw)
        return [CategoryGroup(id: "bookmall", name: "精选", items: dramas)]
    }

    /// 递归提取响应里所有 video_data[] 节点，映射成 DramaItem。
    static func extractVideos(from data: Data) -> [DramaItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [DramaItem] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let videos = dict["video_data"] as? [[String: Any]] {
                    for v in videos {
                        let title = v["title"] as? String
                        let vid = v["vid"] as? String
                        let key = vid ?? title ?? ""
                        guard !key.isEmpty, !seen.contains(key) else { continue }
                        seen.insert(key)
                        let cover = (v["cover"] as? String).flatMap(URL.init(string:))
                        out.append(DramaItem(
                            bookId: nil,
                            videoId: vid,
                            seriesId: v["series_id"] as? String,
                            title: title,
                            thumbURL: cover,
                            description: v["video_desc"] as? String,
                            category: nil,
                            playCount: v["play_cnt"] as? Int,
                            score: v["score"] as? Double))
                    }
                }
                for (_, val) in dict { walk(val) }
            } else if let arr = node as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(obj)
        return out
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

    // MARK: - 播放链路（multi_video_model，忠实移植 gorgon_py/playback_client.py）

    /// 一档清晰度的播放流（CENC 加密）：main_url + spade_a 派生密钥 + 可选 kid。
    public struct PlaybackStream {
        public let url: URL
        public let spadeA: String
        public let kid: String?
        public init(url: URL, spadeA: String, kid: String?) {
            self.url = url
            self.spadeA = spadeA
            self.kid = kid
        }
    }

    /// vid → 已打通的播放地址 + spade_a。
    /// 端点：POST /novel/player/multi_video_model/v1/?...&vid=<vid>
    /// body（gzip JSON）：{"biz_param":{...},"dr_scene":"player","mixed_video_id_map":{"1004":[vid]}}
    /// 响应：data.<vid>.video_model（内嵌 JSON 字符串）→ video_list[].main_url / encrypt_info.spade_a
    public func fetchPlayback(vid: String) async throws -> PlaybackStream {
        // 内层 biz_param（s0 方法精确字段）
        let bizParam: [String: Any] = [
            "detail_page_version": 0,
            "device_level": 5,
            "disable_digg_stat": false,
            "disable_video_relate_book": false,
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "use_os_player": false,
            "use_server_dns": true,
            "use_server_dns_scene": "cold_start_stage",
            "video_platform": 1024,
        ]
        let payload: [String: Any] = [
            "biz_param": bizParam,
            "dr_scene": "player",
            "mixed_video_id_map": ["1004": [vid]],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let gzipped = Gzip.compress(jsonData)

        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.multiVideoModel,
            method: "POST",
            query: ["vid": vid],
            body: gzipped,
            signed: true,
            // Content-Type 已由 signer 注入，这里补 gzip 编码头
            extraHeaders: ["Content-Encoding": "gzip"]
        )
        let raw = try await http.request(target)
        guard let stream = try Self.parsePlayback(from: raw, vid: vid) else {
            throw HTTPError.streamExpired
        }
        return stream
    }

    /// 解析 multi_video_model 响应，取首个带 main_url + spade_a 的清晰度。
    static func parsePlayback(from data: Data, vid: String) throws -> PlaybackStream? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let code = obj["code"] as? Int
        if let code, code != 0 {
            throw HTTPError.catalogHTTP(code)
        }
        guard let dataDict = obj["data"] as? [String: Any] else { return nil }
        // data.<vid> 可能是字典；兼容 vid 缺失时取第一个
        var model: [String: Any]?
        if let m = dataDict[vid] as? [String: Any] {
            model = m
        } else if let first = dataDict.values.first as? [String: Any] {
            model = first
        }
        guard let model else { return nil }

        let vmRaw = model["video_model"]
        let vm: [String: Any]
        if let s = vmRaw as? String {
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
            else { return nil }
            vm = parsed
        } else if let d = vmRaw as? [String: Any] {
            vm = d
        } else {
            return nil
        }
        guard let videoList = vm["video_list"] as? [[String: Any]] else { return nil }

        // 优先选带 spade_a 的加密流；其次退回任意 main_url
        var fallback: PlaybackStream?
        for item in videoList {
            guard let urlStr = item["main_url"] as? String, let url = URL(string: urlStr) else {
                continue
            }
            let encrypt = item["encrypt_info"] as? [String: Any] ?? [:]
            let spade = encrypt["spade_a"] as? String ?? ""
            let kid = encrypt["kid"] as? String
            if !spade.isEmpty {
                return PlaybackStream(url: url, spadeA: spade, kid: kid)
            }
            if fallback == nil {
                fallback = PlaybackStream(url: url, spadeA: "", kid: kid)
            }
        }
        return fallback
    }

    /// 下载加密 mp4（CDN 直链，无需签名，跟随重定向）。
    public func downloadData(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(HGTVConfig.userAgent(), forHTTPHeaderField: HGTVConfig.HeaderKey.userAgent)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.downloadSession.data(for: req)
        } catch {
            throw HTTPError.network(error)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError.catalogHTTP((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// 下载专用会话（独立于签名 HTTPClient，CDN 直链用）
    private static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    // MARK: - 登录态
    public func isLoggedIn() async -> Bool {
        await DeviceRegisterService.shared.hasSession()
    }
}