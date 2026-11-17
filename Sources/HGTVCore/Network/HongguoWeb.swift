// HongguoWeb.swift
// 红果短剧 web 端数据源（hongguoduanju.com，无签名直连）。
// 背景：番茄原 API /novel/player/video_detail/v1（series_id→剧集列表）被风控门控
// （恒返 200+0 字节），但红果 web 的剧集详情页 /detail?series_id=x 是 SSR 渲染，
// HTML 里内嵌完整的 `_ROUTER_DATA` JSON——包含剧名/简介/封面/标签/集数信息/全量
// vid_list（实测 1000 集全量）。拿到 vid 后走现有 multi_video_model 播放管线
// 即可播任意集（实测第 1/2/10/100/501/1000 集全部可播）。
// 这是选集功能的正式数据通路（v22）。

import Foundation

public struct SeriesDetail: Sendable {
    public let seriesId: String
    public let name: String?
    public let coverURL: URL?
    public let intro: String?
    public let tags: [String]
    /// 服务端组装好的集数文案，如「全1000集」。
    public let episodeText: String?
    public let episodeCount: Int?
    /// 全量剧集 vid（顺序即集序）。
    public let vidList: [String]
    /// 榜单名（如「漫剧热播榜第25名」）。
    public let rankLabel: String?
    /// 热度文案（如「5469万热度」）。
    public let hotText: String?
    /// 点赞/收藏数文案（原始字符串）。
    public let likeText: String?
    public let favoriteText: String?
    /// 季/部信息：红果源数据只给 series_group_id（同一系列组），无季编号。
    public let seriesGroupId: String?
}

public enum HongguoWebError: Error, LocalizedError {
    case badResponse
    case noRouterData
    case noDetail

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "红果 web 响应异常"
        case .noRouterData: return "详情页数据缺失"
        case .noDetail: return "未找到该剧的详情数据"
        }
    }
}

public enum HongguoWeb {
    static let host = "hongguoduanju.com"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// 抓取剧集详情页并解析 SSR 内嵌的 _ROUTER_DATA JSON。
    public static func fetchSeriesDetail(seriesId: String) async throws -> SeriesDetail {
        guard let url = URL(string: "https://\(host)/detail?series_id=\(seriesId)") else {
            throw HongguoWebError.badResponse
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw HongguoWebError.badResponse
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw HongguoWebError.badResponse
        }
        guard let html = String(data: data, encoding: .utf8),
              let json = Self.extractRouterJSON(from: html),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw HongguoWebError.noRouterData
        }
        guard
            let loader = root["loaderData"] as? [String: Any],
            let page = loader["detail_page"] as? [String: Any],
            let detail = page["seriesDetail"] as? [String: Any]
        else {
            throw HongguoWebError.noDetail
        }
        let social = page["seriesSocialInfo"] as? [String: Any] ?? [:]

        let vids = (detail["vid_list"] as? [Any])?.compactMap { $0 as? String } ?? []
        let tags = (detail["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        let episodeInfo = detail["series_episode_info"] as? [String: Any] ?? [:]
        let seasonInfo = detail["season_info"] as? [String: Any] ?? [:]
        let hot = social["hot_score_data"] as? [String: Any] ?? [:]

        func str(_ dict: [String: Any], _ key: String) -> String? {
            dict[key] as? String
        }
        func int(_ dict: [String: Any], _ key: String) -> Int? {
            (dict[key] as? NSNumber)?.intValue
        }

        guard !vids.isEmpty, let sid = str(detail, "series_id") else {
            throw HongguoWebError.noDetail
        }
        return SeriesDetail(
            seriesId: sid,
            name: str(detail, "series_name"),
            coverURL: (detail["series_cover"] as? String).flatMap(URL.init(string:)),
            intro: str(detail, "series_intro"),
            tags: tags,
            episodeText: str(detail, "episode_right_text"),
            episodeCount: int(episodeInfo, "episode_cnt") ?? int(detail, "episode_cnt"),
            vidList: vids,
            rankLabel: str(social, "rank_label"),
            hotText: str(hot, "text"),
            likeText: str(social, "series_like_count"),
            favoriteText: str(social, "series_favorite_count"),
            seriesGroupId: str(seasonInfo, "series_group_id")
        )
    }

    /// 从 SSR HTML 中提取 `_ROUTER_DATA = {...}` 的首个配平 JSON 对象。
    /// 不能简单找 `</script>`（JSON 后还有别的语句），需做括号配平并跳过字符串字面量。
    static func extractRouterJSON(from html: String) -> Data? {
        let bytes = Array(html.utf8)
        let markerBytes = Array("_ROUTER_DATA".utf8)

        // 定位标记起始字节
        var markerPos: Int?
        var pos = 0
        while pos + markerBytes.count <= bytes.count {
            if bytes[pos] == markerBytes[0] {
                var match = true
                for k in 1..<markerBytes.count where bytes[pos + k] != markerBytes[k] {
                    match = false
                    break
                }
                if match {
                    markerPos = pos
                    break
                }
            }
            pos += 1
        }
        guard var scan = markerPos else { return nil }
        scan += markerBytes.count

        // 标记之后第一个 '{'
        while scan < bytes.count, bytes[scan] != UInt8(ascii: "{") {
            scan += 1
        }
        guard scan < bytes.count else { return nil }
        let brace = scan

        // 括号配平（跳过字符串与转义）
        var depth = 0
        var inString = false
        var escape = false
        var idx = brace
        while idx < bytes.count {
            let b = bytes[idx]
            if escape {
                escape = false
            } else if inString {
                if b == UInt8(ascii: "\\") {
                    escape = true
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                if b == UInt8(ascii: "\"") {
                    inString = true
                } else if b == UInt8(ascii: "{") {
                    depth += 1
                } else if b == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        return Data(bytes[brace...idx])
                    }
                }
            }
            idx += 1
        }
        return nil
    }
}
