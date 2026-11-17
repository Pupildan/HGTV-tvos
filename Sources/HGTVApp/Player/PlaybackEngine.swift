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

    private var seenVids: Set<String> = []
    /// feed 内容池轮换：4 个 tab 实测内容**完全不相交**（tab8 找剧 9 条 / tab38 真人剧
    /// 11 条 / tab32 漫剧 10 条 / tab14 电影 16 条，两两交集全为 0）。bookmall 端点
    /// 不提供翻页（has_more 恒 false），只靠反复请求同一 tab 会得到高度重复的固定
    /// 内容池；轮换 tab 才有真正多样的无限流。
    private let feedTabTypes: [Int] = [8, 38, 32, 14]
    private var feedTabCursor = 0

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

    /// 首次加载：拉第一批 feed（找剧 tab）。失败可重试（items 仍为空时放行）。
    func load() async {
        guard items.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let groups = try await APIService.shared.fetchHome(tabType: feedTabTypes[0])
            feedTabCursor = 1
            let added = merge(groups.flatMap { $0.items ?? [] })
            if added.isEmpty {
                errorMessage = "暂无推荐内容"
                DiagnosticsLogger.warn("首批 feed 去重后为空", category: "playback")
            } else {
                hasLoaded = true
                errorMessage = nil
                DiagnosticsLogger.log("首批 feed 已加载 \(added.count) 条，总计 \(items.count)", category: "playback", level: .info)
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticsLogger.error("首批 feed 加载失败: \(error.localizedDescription)", category: "playback")
        }
    }

    /// 无限 feed：按 tab 轮换请求（8→38→32→14 循环），按 vid 去重后追加。
    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let tab = feedTabTypes[feedTabCursor % feedTabTypes.count]
            feedTabCursor += 1
            let groups = try await APIService.shared.fetchHome(tabType: tab)
            let added = merge(groups.flatMap { $0.items ?? [] })
            DiagnosticsLogger.log("追加 feed(tab=\(tab)) +\(added.count) 条，总计 \(items.count)", category: "playback", level: .info)
        } catch {
            // 追加失败静默（保留现有流），仅记日志。
            DiagnosticsLogger.warn("追加 feed 失败: \(error.localizedDescription)", category: "playback")
        }
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
        if index >= items.count - 3 {
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
            return try await self.doResolve(vid)
        }
        inflightResolves[vid] = task
        return try await task.value
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
