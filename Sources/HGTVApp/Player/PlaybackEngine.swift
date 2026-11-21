// PlaybackEngine.swift
// 抖音式竖向 feed 的数据/状态层（参考 DYTV 架构）。
// 职责：有序 DramaItem 列表 + 当前 index + 无限 feed（merge 去重追加）+ onNeedMore 回调。
// 同时封装「resolve 本地播放 URL」：复用已打通的解密链路
//（fetchPlayback → 下载 → SpadeKey 派生密钥 → CENC 解密 → PlaybackProxy 本地代理），
// 供 PlayerManager.acquire 使用。不重写任何数据获取/签名/解密逻辑。

import Foundation
import AVFoundation
import HGTVCore

/// resolve 本地播放地址失败。
enum PlaybackResolveError: Error, LocalizedError {
    case missingKey
    case missingVid
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "未取到内容密钥 (spade_a)"
        case .missingVid: return "该条目缺少 vid"
        }
    }
}

@MainActor
@Observable
final class PlaybackEngine {
    // MARK: - 状态

    private(set) var items: [DramaItem] = []
    private(set) var index = 0
    /// 当前居中条目首帧是否已渲染（playerLayer.isReadyForDisplay）。
    private(set) var firstFrameReady = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    /// 首批 feed 是否已成功拉到（拉到才停止顶层加载态）。
    private(set) var hasLoaded = false

    /// 接近末尾时触发（由控制器注册，负责加载更多 + 刷新 collection）。
    var onNeedMore: (() -> Void)?
    /// 整表替换（选集进入剧集连播）后触发，控制器据此 reload + 跳转到起始集。
    var onDataReplaced: ((Int) -> Void)?
    /// 从剧集连播返回推荐流后触发，控制器据此整表 reload 并回到第 0 条。
    var onFeedRestored: (() -> Void)?

    private var seenVids: Set<String> = []
    /// landpage 翻页游标（成功接入后 loadMore 续页）。
    private var feedOffset = 0
    private var feedSessionId = ""
    private var feedExhausted = false
    private var landpageActive = false
    /// 已确认拿不到播放地址的 vid（如电影）。resolve 失败时记录，用于自动跳过。
    private var failedVids: Set<String> = []

    // MARK: - 本地代理缓存（vid → 解密后明文的本地 URL）

    private var proxyCache: [String: PlaybackProxy] = [:]
    private var urlCache: [String: URL] = [:]
    private var proxyOrder: [String] = []
    /// 同时驻留的解密明文代理上限（防内存无限增长）。
    private let proxyLimit = 6
    /// 进行中的 resolve 任务（vid → task）。冷启动/快速滑动时 prepare 可能对同一 vid
    /// 并发触发两次 acquire → 曾导致重复下载解密 15MB、泄漏孤儿播放器和代理（真机
    /// 日志：同一 vid 建出 55806/55807 两个端口）。这里收敛为同 vid 共享一个任务。
    private var inflightResolves: [String: Task<URL, Error>] = [:]

    init() {
        DiagnosticsLogger.log("PlaybackEngine 初始化", category: "playback", level: .info)
    }

    // MARK: - 派生状态

    var currentDrama: DramaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var currentVid: String? { currentDrama?.videoId }

    func vid(at i: Int) -> String? {
        items.indices.contains(i) ? items[i].videoId : nil
    }

    var itemCount: Int { items.count }

    // MARK: - 数据加载（复用现有数据层，未改动）

    /// 首次加载：landpage 正确池子 + 身份自愈（原 app 机制：被拒 → rebuilding → 换新身份重试）。
    /// 最多 3 个身份轮换；全部被拒才 bookmall 兜底。
    func load() async {
        guard items.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await DeviceRegisterService.shared.ensureRegistered()
        } catch {
            DiagnosticsLogger.warn("注册未就绪仍继续: \(error.localizedDescription)", category: "playback")
        }

        // 身份自愈轮换：landpage 返空 = 当前身份被拒 → 换新身份重试（原 app 机制）
        for attempt in 1...3 {
            do {
                let page = try await APIService.shared.fetchLandpage(offset: 0, sessionId: "")
                feedOffset = page.nextOffset
                feedSessionId = page.sessionId
                feedExhausted = !page.hasMore
                let added = merge(page.items)
                if !added.isEmpty {
                    landpageActive = page.hasMore || !page.items.isEmpty
                    hasLoaded = true; errorMessage = nil
                    DiagnosticsLogger.log("首批 feed：landpage 正确池子 \(added.count) 条（身份#\(attempt)）session=\(feedSessionId)",
                                          category: "playback", level: .info)
                    return
                }
                DiagnosticsLogger.warn("landpage 身份#\(attempt) 返 0 条 → 视为身份被拒", category: "playback")
            } catch {
                DiagnosticsLogger.warn("landpage 身份#\(attempt) 失败: \(error.localizedDescription)", category: "playback")
            }
            if attempt < 3 {
                do {
                    try await DeviceRegisterService.shared.reregister()
                    DiagnosticsLogger.log("身份自愈：已重建新身份（第 \(attempt) 次切换），重试 landpage", category: "playback", level: .info)
                } catch {
                    DiagnosticsLogger.error("身份自愈失败: \(error.localizedDescription)", category: "playback")
                    break
                }
            }
        }
        landpageActive = false

        // 无兜底：landpage 失败直接显示错误（干净测试，不进旧池子）
        errorMessage = "landpage 未接通（3 个身份均被拒或返空）"
        DiagnosticsLogger.error("首批 feed：landpage 3 个身份全部失败，无兜底", category: "playback")
    }

    /// 无限 feed：landpage 翻页（回传 nextOffset + sessionId，req_type=only_content），按 vid 去重追加。
    /// 无限 feed：landpage 接通时走真翻页（offset/session_id 续页）；否则 bookmall tab 轮换。
    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if landpageActive {
            do {
                let page = try await APIService.shared.fetchLandpage(offset: feedOffset, sessionId: feedSessionId)
                feedOffset = page.nextOffset
                feedSessionId = page.sessionId
                feedExhausted = !page.hasMore
                var batch = page.items
                batch.shuffle()
                let added = merge(batch)
                DiagnosticsLogger.log("追加 feed(landpage offset=\(feedOffset)) +\(added.count) 条，总计 \(items.count)",
                                      category: "playback", level: .info)
                if added.isEmpty {
                    // 翻页返空：身份可能中途被拒，自愈一次后重试首页
                    try? await DeviceRegisterService.shared.reregister()
                    let fresh = try await APIService.shared.fetchLandpage(offset: 0, sessionId: "")
                    feedOffset = fresh.nextOffset
                    feedSessionId = fresh.sessionId
                    feedExhausted = !fresh.hasMore
                    let added2 = merge(fresh.items)
                    DiagnosticsLogger.log("landpage 中途被拒 → 自愈换身份重试 +\(added2.count) 条", category: "playback", level: .info)
                }
            } catch {
                DiagnosticsLogger.warn("landpage 翻页失败: \(error.localizedDescription)", category: "playback")
            }
            return
        }
        // landpage 未接通：无兜底，不加载任何旧池子内容
        DiagnosticsLogger.warn("landpage 未接通，loadMore 跳过（无兜底）", category: "playback")
    }

    /// 合并去重：返回真正新增的条目。
    @discardableResult
    func merge(_ candidates: [DramaItem]) -> [DramaItem] {
        var added: [DramaItem] = []
        for d in candidates {
            guard let vid = d.videoId, !vid.isEmpty else { continue }
            guard !seenVids.contains(vid) else { continue }
            seenVids.insert(vid)
            added.append(d)
        }
        if !added.isEmpty { items.append(contentsOf: added) }
        return added
    }

    // MARK: - 剧集连播（选集入口，v22）

    /// 用一部剧的全量集数整表替换当前 feed，从 startIndex 集开始播。
    /// 选集网格点任意一集 → 回到全屏刷集模式，播完自动衔接下一集（A1）。
    /// 替换完成后触发 onDataReplaced(startIndex)（控制器 reload + 跳转）。
    func playSeries(seriesId: String, title: String?, coverURL: URL?,
                    vids: [String], startIndex: Int) {
        guard !vids.isEmpty else { return }
        let dramaItems = vids.enumerated().map { (i, vid) in
            DramaItem(bookId: nil, videoId: vid, seriesId: seriesId,
                      title: title.map { "第 \(i + 1) 集 · \($0)" } ?? "第 \(i + 1) 集",
                      thumbURL: coverURL, description: nil,
                      category: nil, playCount: nil, score: nil)
        }
        seenVids = Set(vids)
        items = dramaItems
        let target = min(max(0, startIndex), vids.count - 1)
        index = target
        firstFrameReady = false
        hasLoaded = true
        errorMessage = nil
        DiagnosticsLogger.log("选集进入剧集 series=\(seriesId) 共 \(vids.count) 集，从第 \(target + 1) 集开始",
                              category: "playback", level: .info)
        onDataReplaced?(target)
    }

    /// 从剧集连播模式返回推荐流（v24 弹窗「返回推荐」入口）。
    /// 清空剧集列表与去重集合、释放本地代理，重新拉第一批推荐并回到第 0 条。
    /// 说明：方案默认「重新拉取」；位置恢复（退出前浏览位置）暂不做，后续需要再加。
    func returnToRecommendFeed() async {
        // 1) 释放已缓存的明文代理，避免连播剧集的代理残留占用内存
        for (_, proxy) in proxyCache { proxy.stop() }
        proxyCache.removeAll()
        urlCache.removeAll()
        proxyOrder.removeAll()
        inflightResolves.removeAll()

        // 2) 清空剧集连播状态，让 load() 的 guard items.isEmpty 放行
        items = []
        seenVids = []
        failedVids = []
        index = 0
        firstFrameReady = false
        hasLoaded = false
        errorMessage = nil

        // 3) 重新拉推荐流（tab=找剧），复用现有 load()
        await load()

        // 4) 通知控制器整表 reload + 回到第 0 条
        onFeedRestored?()
        DiagnosticsLogger.log("返回推荐流：已重置剧集连播并重新拉取 feed，共 \(items.count) 条",
                              category: "playback", level: .info)
    }

    // MARK: - 居中对齐（唯一真相源）

    /// 控制器滚动停稳后调用：更新 index，接近末尾触发 onNeedMore。
    func updateCenter(_ i: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(0, i), items.count - 1)
        let changed = clamped != index
        index = clamped
        if changed {
            firstFrameReady = false
            let vid = currentDrama?.videoId ?? "?"
            DiagnosticsLogger.log("居中切到 index=\(index) vid=\(vid)", category: "playback", level: .info)
        }
        if index >= items.count - 5 {
            onNeedMore?()
        }
    }

    /// 首帧渲染回调（控制器上报）。
    func noteFirstFrame(index i: Int) {
        guard i == index else { return }
        firstFrameReady = true
    }

    // MARK: - resolve 本地播放 URL（供 PlayerManager.acquire）

    /// vid → 本地代理 URL。命中缓存秒回；否则走完整解密链路。
    /// 同 vid 并发调用共享同一个进行中任务（防重复下载/解密/建代理）。
    func resolveLocalURL(for vid: String) async throws -> URL {
        if let url = urlCache[vid], proxyCache[vid] != nil {
            DiagnosticsLogger.log("命中本地代理缓存 vid=\(vid)", category: "playback", level: .debug)
            return url
        }
        if let existing = inflightResolves[vid] {
            DiagnosticsLogger.log("复用进行中的 resolve vid=\(vid)", category: "playback", level: .debug)
            return try await existing.value
        }
        let task = Task { [weak self] () -> URL in
            defer { self?.inflightResolves.removeValue(forKey: vid) }
            guard let self else { throw PlaybackResolveError.missingVid }
            do {
                return try await self.doResolve(vid)
            } catch {
                // 记入失败名单：自动切集时跳过拿不到流的条目（如电影，v23 兜底）
                self.failedVids.insert(vid)
                throw error
            }
        }
        inflightResolves[vid] = task
        return try await task.value
    }

    /// 该 vid 是否已确认取流失败。
    func isFailedVid(_ vid: String?) -> Bool {
        guard let vid else { return false }
        return failedVids.contains(vid)
    }

    /// 从 i 出发向后（forwardOnly）或双向寻找最近的可播 index。
    /// 用于：播完自动切下一集（只向前）、失败自动跳过（双向就近）。
    /// 找不到返回 nil（调用方原地停留）。
    func nearestPlayableIndex(after i: Int, forwardOnly: Bool) -> Int? {
        let n = items.count
        guard n > 0 else { return nil }
        for step in 1..<n {
            let j = i + step
            if j >= n { break }
            if let vid = items[j].videoId, !failedVids.contains(vid) { return j }
        }
        if forwardOnly { return nil }
        for step in 1..<n {
            let j = i - step
            if j < 0 { break }
            if let vid = items[j].videoId, !failedVids.contains(vid) { return j }
        }
        return nil
    }

    /// 完整解密链路（取流 → 下载 → 派生密钥 → 解密 → 本地代理）。
    private func doResolve(_ vid: String) async throws -> URL {
        DiagnosticsLogger.log("resolve 开始 vid=\(vid)", category: "playback", level: .info)
        // 1) 取加密直链 + spade_a
        let stream = try await APIService.shared.fetchPlayback(vid: vid)
        guard !stream.spadeA.isEmpty else { throw PlaybackResolveError.missingKey }
        // 2) 下载加密 mp4
        let encrypted = try await APIService.shared.downloadData(from: stream.url)
        // 3) 派生密钥
        let key = try SpadeKey.deriveKey(stream.spadeA)
        // 4) 解密（后台线程）
        let plain = try await Task.detached(priority: .userInitiated) {
            try CENCDecryptor.decrypt(data: encrypted, key: key)
        }.value
        // 5) 本地代理托管明文
        let proxy = PlaybackProxy(payload: plain)
        let url = try await proxy.start()
        proxyCache[vid] = proxy
        urlCache[vid] = url
        touchProxyOrder(vid)
        trimProxyCache()
        DiagnosticsLogger.log("resolve 完成 vid=\(vid) url=\(url.absoluteString) 明文=\(plain.count) 字节", category: "playback", level: .info)
        return url
    }

    /// 驱逐时释放对应代理（仅对窗口外条目调用，居中/邻居不会）。
    func releaseProxy(vid: String) {
        guard let proxy = proxyCache.removeValue(forKey: vid) else { return }
        proxy.stop()
        urlCache.removeValue(forKey: vid)
        proxyOrder.removeAll { $0 == vid }
        DiagnosticsLogger.log("释放本地代理 vid=\(vid)", category: "playback", level: .debug)
    }

    private func touchProxyOrder(_ vid: String) {
        proxyOrder.removeAll { $0 == vid }
        proxyOrder.append(vid)
    }

    private func trimProxyCache() {
        while proxyOrder.count > proxyLimit {
            let victim = proxyOrder.removeFirst()
            if let proxy = proxyCache.removeValue(forKey: victim) {
                proxy.stop()
                urlCache.removeValue(forKey: victim)
                DiagnosticsLogger.log("代理缓存超限，释放 vid=\(victim)", category: "playback", level: .debug)
            }
        }
    }

    /// 整体停掉所有代理（视图消失）。
    func shutdown() {
        for (_, proxy) in proxyCache { proxy.stop() }
        proxyCache.removeAll()
        urlCache.removeAll()
        proxyOrder.removeAll()
        onNeedMore = nil
        DiagnosticsLogger.log("PlaybackEngine shutdown，已停全部本地代理", category: "playback", level: .info)
    }
}
