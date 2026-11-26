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
    /// 拉书城 tab feed。tabType 对应原 APK 各 tab（找剧=8/真人剧=38/漫剧=32/电影=14…）。
    /// 无限 feed 机制：反复请求同一 URL，服务端每次按新 session 随机出 6 条，
    /// 客户端按 vid 去重累积。传 nil 时为默认（找剧 tab）。
    public func fetchHome(tabType: Int? = nil, legacy: Bool = false) async throws -> [CategoryGroup] {
        let target = HTTPTargetImpl(
            host: HGTVConfig.Host.fqnovel,
            path: HGTVConfig.Path.bookmallTab,
            query: tabType.map { ["tab_type": String($0)] } ?? [:],
            signed: true,
            legacySigning: legacy
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

    // MARK: - 推荐流 landpage（官方分页接口，根治 bookmall 内容池重复）
    //
    // 原版推荐流 = POST /reading/distribution/category/landpage/v/（2026-11-20 抓包实锤）。
    // body：{"filter_ids":"","req_scene":"default","offset":0,"need_selector_panel":true,
    //        "limit":100,"select_items":{"genre":[],"sort":["hot_score"]},
    //        "session_id":"","req_type":"default"(首次)/"only_content"(后续),"client_req_type":3}
    // 真·offset/limit 分页 + session_id 会话态 + 服务端个性化去重（recommend_info 带
    // request_id/rank/normal_session_id）。bookmall/tab/v 无翻页池 ~50 条 = 重复根因。

    /// 一页 landpage 结果 + 翻页游标。
    public struct LandpagePage {
        public let items: [DramaItem]
        /// 下一页 offset（= 本次 offset + 实际返回条数；服务端按 limit 切）。
        public let nextOffset: Int
        /// 会话 id（首页响应下发，后续翻页原样回传）。
        public let sessionId: String
        /// 服务端是否还有更多（缺失时按 items 非空推断）。
        public let hasMore: Bool
        public init(items: [DramaItem], nextOffset: Int, sessionId: String, hasMore: Bool) {
            self.items = items; self.nextOffset = nextOffset
            self.sessionId = sessionId; self.hasMore = hasMore
        }
    }

    /// 拉一页推荐流。offset=0/sessionId="" 为首页（req_type=default），后续翻页传上页
    /// 返回的 offset/sessionId 且 req_type=only_content。
    ///
    /// 主机层级（1.3.8.6 反编译实锤）：landpage 走 sinfonlineb（q()=T3.j(2,"sinfonlineb")），
    /// api5-normal-lf 层级不服务该接口（实测恒 200+0 字节）。带 a/c/lf 故障转移。
    public func fetchLandpage(offset: Int, sessionId: String) async throws -> LandpagePage {
        // v91：原生自签版彻底移除桥兜底——自签（突破版参数，commit 3f9d363）失败就抛真实错误，
        // 不再回退任何 PC/NAS 桥路径，让上层看到真实信号。
        let isFirst = offset == 0 && sessionId.isEmpty
        // v98：body 固定键序（CanonicalJSON.swift 顶部说明）——键序逐字节对齐
        // Python test_landpage_v2.py（4/4 实测标准答案），禁用 JSONSerialization。
        let bodyPlain = Data((
            "{\"filter_ids\":\"\",\"req_scene\":\"default\",\"offset\":\(offset),"
            + "\"need_selector_panel\":\(isFirst),\"limit\":100,"
            + "\"select_items\":{\"genre\":[],\"sort\":[\"hot_score\"]},"
            + "\"session_id\":\"\(CanonicalJSON.escape(sessionId))\","
            + "\"req_type\":\"\(isFirst ? "default" : "only_content")\","
            + "\"client_req_type\":3}"
        ).utf8)
        // landpage body 必须 gzip：2026-11-24 Nbeedp 实测明文 body 恒 200+0B（五个 host
        // × 三身份全灭），Python test_landpage_v2 gzip body 4/4 全 200——landpage 服务端
        // 只解析 gzip body（与 multi_video_model 恰好相反：那边明文才行）。x-ss-stub 与
        // gorgon 绑定的是 gzip 后字节，签名链拿 target.body 自动对齐。
        let body = Gzip.compress(bodyPlain)
        // query 版本族覆写（真机抓包 00:38:19 实锤）：landpage 走 73532/7.3.5.32 + channel=69310258a。
        // 这些键在 intercept 里覆盖 CommonParams 的默认值。
        let family: [String: String] = [
            "version_code": "73532",
            "version_name": "7.3.5.32",
            "manifest_version_code": "73532",
            "update_version_code": "73532",
            "pv_player": "73532",
            "channel": "69310258a",
        ]
        let hosts = [HGTVConfig.Host.sinfonlineb, HGTVConfig.Host.sinfonlinea,
                     HGTVConfig.Host.sinfonlinec, HGTVConfig.Host.fqnovel]
        var lastError: Error = HTTPError.invalidResponse
        for host in hosts {
            let target = HTTPTargetImpl(
                host: host,
                path: HGTVConfig.Path.categoryLandpage,
                method: "POST",
                query: family,
                body: body,
                signed: true,
                landpageFamily: true   // UA/device dict 同步 73532 族
            )
            do {
                let raw = try await http.request(target)
                if raw.count > 0 {
                    let page = try Self.parseLandpage(from: raw, requestOffset: offset, requestSessionId: sessionId)
                    DiagnosticsLogger.log("landpage host=\(host) 成功 \(page.items.count) 条 bytes=\(raw.count)",
                                          category: "playback", level: .info)
                    return page
                }
                DiagnosticsLogger.warn("landpage host=\(host) 返回 0 字节，换下一个", category: "playback")
            } catch {
                DiagnosticsLogger.warn("landpage host=\(host) 失败: \(error.localizedDescription)", category: "playback")
                lastError = error
            }
        }
        // 全 host 失败（0 字节/异常）：抛真实错误（无桥兜底）
        throw lastError
    }

    /// 解析 landpage 响应：递归提取 video_data[]（复用 extractVideos）+ 翻页游标。
    /// session_id 可能出现在顶层、data 层或 recommend_info（自适应）。
    public static func parseLandpage(from data: Data, requestOffset: Int, requestSessionId: String) throws -> LandpagePage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        if let code = obj["code"] as? Int, code != 0 {
            throw HTTPError.catalogHTTP(code)
        }
        let items = extractVideos(from: data)
        // has_more：优先读 data.has_more / has_more，缺失按 items 非空推断
        let dataDict = obj["data"] as? [String: Any] ?? [:]
        let hasMore = (dataDict["has_more"] as? Bool)
            ?? (obj["has_more"] as? Bool)
            ?? !items.isEmpty
        // session_id：data.session_id > 顶层 > recommend_info.normal_session_id > 回传值
        var sessionId = (dataDict["session_id"] as? String)
            ?? (obj["session_id"] as? String) ?? ""
        if sessionId.isEmpty,
           let ri = dataDict["recommend_info"] as? [String: Any] {
            sessionId = (ri["normal_session_id"] as? String) ?? (ri["session_id"] as? String) ?? ""
        }
        if sessionId.isEmpty { sessionId = requestSessionId }
        let nextOffset = requestOffset + max(items.count, 0)
        return LandpagePage(items: items, nextOffset: nextOffset, sessionId: sessionId, hasMore: hasMore)
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
        // v98：body 固定键序——键序逐字节对齐 Python playback_client.BIZ_PARAM +
        // play_sign.py（2026-11-24 取流突破实测标准答案），禁用 JSONSerialization。
        let bodyPlain = Data((
            "{\"biz_param\":{"
            + "\"detail_page_version\":0,\"device_level\":5,\"disable_digg_stat\":false,"
            + "\"disable_video_relate_book\":false,\"need_all_video_definition\":true,"
            + "\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":true,"
            + "\"use_server_dns_scene\":\"cold_start_stage\",\"video_platform\":1024},"
            + "\"dr_scene\":\"player\","
            + "\"mixed_video_id_map\":{\"1004\":[\"\(CanonicalJSON.escape(vid))\"]}}"
        ).utf8)
        let gzipped = Gzip.compress(bodyPlain)

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

        // 选最高清晰度。两个关键事实（CDN 实测，2026-11-18）：
        //   1) 字节系 quality_type **数值越小质量越高**：q=1=原画。两条视频实测码率
        //      q=1→1.11/0.71 Mbps、q=10→0.56/0.40、q=40→0.30/0.23（最低）。v19 曾误
        //      选 max 恰好命中最低档。
        //   2) video_list 顺序不保证（5 档 40/30/20/10/1，全部带 spade_a），不能靠序位取。
        // 策略：有加密流（spade_a 非空）在加密流里挑 quality_type **最小**者；
        // 无加密流退回全部候选最小者；缺失按 Int.max 处理（并列保留先出现的）。
        struct Candidate {
            let url: URL
            let spadeA: String
            let kid: String?
            let quality: Int
        }
        var encrypted: [Candidate] = []
        var plain: [Candidate] = []
        for item in videoList {
            guard let urlStr = item["main_url"] as? String, let url = URL(string: urlStr) else {
                continue
            }
            let encrypt = item["encrypt_info"] as? [String: Any] ?? [:]
            let spade = encrypt["spade_a"] as? String ?? ""
            let kid = encrypt["kid"] as? String
            let quality: Int
            if let q = item["quality_type"] as? Int {
                quality = q
            } else if let s = item["quality_type"] as? String, let q = Int(s) {
                quality = q
            } else {
                quality = Int.max
            }
            let c = Candidate(url: url, spadeA: spade, kid: kid, quality: quality)
            if spade.isEmpty { plain.append(c) } else { encrypted.append(c) }
        }
        let pool = encrypted.isEmpty ? plain : encrypted
        guard let best = pool.min(by: { $0.quality < $1.quality }) else { return nil }
        DiagnosticsLogger.log(
            "选定清晰度 q=\(best.quality)（1=原画，越小越清晰）加密=\(!best.spadeA.isEmpty) 候选=\(videoList.count) 档",
            category: "playback", level: .info)
        return PlaybackStream(url: best.url, spadeA: best.spadeA, kid: best.kid)
    }

    /// 下载加密 mp4（CDN 直链，无需签名，跟随重定向）。
    /// v21：大文件走 4 分片并发 Range 下载（真机实测设备端单连接仅 ~1.2MB/s，
    /// 并发分片可摊薄限速/抖动；PC 实测 CDN 单连接可达 23MB/s），每片自带一次重试；
    /// 探测不到大小或分片结果不符时回退单流整下。
    public func downloadData(from url: URL) async throws -> Data {
        // 1) 探测总大小（Range 0-0 读 Content-Range）
        if let total = try? await Self.probeContentLength(url: url, session: Self.downloadSession),
           total > Self.parallelChunkThreshold {
            // 2) 并发分片
            if let joined = try? await Self.parallelRangeDownload(url: url, total: total, session: Self.downloadSession),
               joined.count == total {
                return joined
            }
            // 分片失败 → 落到单流
        }
        // 3) 单流整下（兼容路径）
        return try await downloadDataSingle(from: url)
    }

    /// 单流整下（原实现）。
    private func downloadDataSingle(from url: URL) async throws -> Data {
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

    // MARK: - 并发分片下载

    /// 大于该字节数才走并发分片（避免小请求白探一次）。
    private static let parallelChunkThreshold: Int = 4_000_000
    /// 并发分片数。
    private static let chunkCount: Int = 4

    private static func probeContentLength(url: URL, session: URLSession) async throws -> Int? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue(HGTVConfig.userAgent(), forHTTPHeaderField: HGTVConfig.HeaderKey.userAgent)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        // 206 + Content-Range: bytes 0-0/<total>
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last, let n = Int(total), n > 0 {
            _ = data
            return n
        }
        // 不支持 Range：看 Content-Length（一次性返回全量也可用）
        if http.statusCode == 200, http.expectedContentLength > 0 {
            return Int(http.expectedContentLength)
        }
        return nil
    }

    private static func parallelRangeDownload(url: URL, total: Int, session: URLSession) async throws -> Data {
        let n = chunkCount
        let seg = total / n
        var ranges: [(Int, Int)] = []
        for i in 0..<n {
            let start = i * seg
            let end = (i == n - 1) ? total - 1 : (i + 1) * seg - 1
            ranges.append((start, end))
        }
        // 并发拉各分片，每片失败重试一次（提升稳定性）
        var parts = [Data?](repeating: nil, count: n)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (i, r) in ranges.enumerated() {
                group.addTask {
                    let bytes = try await Self.fetchRange(url: url, start: r.0, end: r.1, session: session)
                    return (i, bytes)
                }
            }
            for try await (i, bytes) in group {
                parts[i] = bytes
            }
        }
        // 缺片重试一次
        for (i, r) in ranges.enumerated() where parts[i] == nil {
            parts[i] = try? await Self.fetchRange(url: url, start: r.0, end: r.1, session: session)
        }
        guard parts.allSatisfy({ $0 != nil }) else { throw HTTPError.network(NSError(domain: "hgtv.download", code: -1)) }
        var joined = Data()
        joined.reserveCapacity(total)
        for p in parts { joined.append(p!) }
        return joined
    }

    private static func fetchRange(url: URL, start: Int, end: Int, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue(HGTVConfig.userAgent(), forHTTPHeaderField: HGTVConfig.HeaderKey.userAgent)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HTTPError.catalogHTTP((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }
            return data
        } catch {
            // 重试一次（抖动容错）
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HTTPError.catalogHTTP((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }
            return data
        }
    }

    /// 下载专用会话（独立于签名 HTTPClient，CDN 直链用）
    private static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    // MARK: - 弹幕（v32，协议照抄反编译原项目 LF0/l0.A 方法）

    /// 弹幕窗口响应。
    public struct DanmakuWindow {
        public let items: [DanmakuMessage]
        public let cursor: String
        public let hasMore: Bool
    }

    /// 拉一个弹幕窗口。
    /// POST /novel/commentapi/comment/list/{vid}/v1/，body 参数与原 APK 逐字段对齐
    /// （comment_source=601 / server_channel=1000 / group_type=30 / comment_type=20）。
    /// 弹幕与评论共用评论接口，参数不同：评论是 4/18/4（dex 原文实测值）。
    ///
    /// 2026-11-20 抓包校正（真机通时 body）：playlet_item_duration 恒为 0（非视频时长）；
    /// cursor 为服务端状态串（首窗传 ""）；count=200；走 app 版本族（72232）。
    public func fetchDanmakuWindow(vid: String, bookId: String?,
                                   startOffsetMs: Int, durationMs: Int,
                                   cursor: String) async throws -> DanmakuWindow {
        // v98：body 固定键序——键序逐字节对齐 Python test_danmu_v3.py（87 条实测
        // 标准答案；business_param 内层同序），禁用 JSONSerialization。
        var bp = "\"playlet_item_duration\":0,"
            + "\"need_danmaku_guide_type\":[1,3,4,2],"
            + "\"start_offset_time\":\(startOffsetMs)"
        if let bookId, !bookId.isEmpty {
            bp += ",\"book_id\":\"\(CanonicalJSON.escape(bookId))\""
        }
        let bodyPlain = Data((
            "{\"server_channel\":1000,"
            + "\"cursor\":\"\(CanonicalJSON.escape(cursor))\","
            + "\"business_param\":{\(bp)},"
            + "\"group_id\":\"\(CanonicalJSON.escape(vid))\","
            + "\"comment_type\":20,\"count\":200,"
            + "\"comment_source\":601,\"group_type\":30,\"sort\":1,"
            + "\"aid\":\(HGTVConfig.aid),\"compliance_status\":0}"
        ).utf8)
        let body = bodyPlain

        let target = HTTPTargetImpl(
            // 2026-11-24 突破版：弹幕实测成功 host = sinfonlineb（test_danmu_v3.py
            // v2.HOST 改写 + 87 条真数据）。反编译的 sinfonlinea 保留作备选层级记录。
            host: HGTVConfig.Host.sinfonlineb,
            path: "/novel/commentapi/comment/list/\(vid)/v1/",
            method: "POST",
            query: [:],
            body: body,
            signed: true,
            // 弹幕/搜索走 app 版本族（72232 / 7.2.2.32）
            appFamily: true,
            // comment-source/server-channel 照原 app 头集；x-ss-stub 不再显式置空——
            // V5 签名器按 body MD5 大写填充（test_danmu_v3.py 87 条实测标准答案），
            // 旧「置空」与实测成功请求不符
            extraHeaders: [
                "comment-source": "601",
                "server-channel": "1000",
            ]
        )
        let raw = try await http.request(target)
        return try Self.parseDanmakuWindow(from: raw)
    }

    /// 解析弹幕窗口响应：data.data_list[]（text/comment_id/offset）+ common_list_info 游标。
    /// offset 字段按反编译字符串做双 fallback（`offset` 优先，`offset_time` 兜底，均为 ms）。
    static func parseDanmakuWindow(from data: Data) throws -> DanmakuWindow {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let code = obj["code"] as? Int ?? (obj["BaseResp"] as? [String: Any]).flatMap { $0["StatusCode"] as? Int } ?? -1
        guard code == 0 else {
            throw HTTPError.catalogHTTP(code)
        }
        guard let dataDict = obj["data"] as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let list = dataDict["data_list"] as? [[String: Any]] ?? []
        var items: [DanmakuMessage] = []
        for e in list {
            guard let text = e["text"] as? String, !text.isEmpty else { continue }
            let id = (e["comment_id"] as? String)
                ?? (e["comment_id"] as? NSNumber).map { $0.stringValue }
                ?? ""
            guard !id.isEmpty else { continue }
            let off = (e["offset"] as? NSNumber)?.doubleValue
                ?? (e["offset_time"] as? NSNumber)?.doubleValue
                ?? 0
            items.append(DanmakuMessage(id: id, offsetMs: off, text: text))
        }
        let common = dataDict["common_list_info"] as? [String: Any] ?? [:]
        let cursor = common["cursor"] as? String ?? ""
        let hasMore = common["has_more"] as? Bool ?? false
        return DanmakuWindow(items: items, cursor: cursor, hasMore: hasMore)
    }

    // MARK: - 登录态
    public func isLoggedIn() async -> Bool {
        await DeviceRegisterService.shared.hasSession()
    }
}