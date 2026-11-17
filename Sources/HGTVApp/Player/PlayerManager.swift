// PlayerManager.swift
// AVPlayer 池（参考 DYTV 架构）。核心三原则之一：
// 维持 [center-2, center+2] 共 5 个 AVPlayer；超范围立刻 pause + replaceCurrentItem(nil)
// 驱逐（置空 item 让系统瞬间回收解码器，缺这步 → 解码器耗尽 → 黑屏）。
// acquire 建 player + KVO；peekPlayer 纯查询不 acquire（willDisplay 用它，防快速滑动撑大池）。

import Foundation
import AVFoundation
import HGTVCore

@MainActor
final class PlayerManager {
    /// vid → 本地播放 URL（由 PlaybackEngine.resolveLocalURL 提供）。
    typealias Resolver = (String) async throws -> URL

    private let resolve: Resolver
    private let itemCount: () -> Int
    private let vidAt: (Int) -> String?

    private var players: [Int: AVPlayer] = [:]
    private var itemStatusObs: [Int: NSKeyValueObservation] = [:]
    private var timeControlObs: [Int: NSKeyValueObservation] = [:]
    private var currentCenter = 0
    /// 冷启动收敛：池全空时只装载居中条，邻居推迟到居中 ready 后补齐。
    private var pendingNeighbors: [Int] = []
    /// 建池中的 index。acquire 在 resolve 期间会让 players[index] 仍为空，
    /// 期间再来的 prepare/acquire 会并发建第二个 player 覆盖第一个（孤儿泄漏 +
    /// 出现 failed/ready 双日志）。同 index 并发请求直接复用现有结果。
    private var acquiring: Set<Int> = []

    /// 成功建起 player 后回调（控制器据此重新 bind 可见 cell 并播放）。
    var onPlayerAcquired: ((Int) -> Void)?
    /// 驱逐某索引后回调（控制器据此释放对应本地代理）。
    var onEvicted: ((Int) -> Void)?

    init(resolve: @escaping Resolver, itemCount: @escaping () -> Int, vidAt: @escaping (Int) -> String?) {
        self.resolve = resolve
        self.itemCount = itemCount
        self.vidAt = vidAt
        DiagnosticsLogger.log("PlayerManager 初始化", category: "playback", level: .info)
    }

    // MARK: - 池窗口

    /// 维持 ±2 窗口。驱逐越界、补齐窗口内缺失。
    func prepare(center index: Int) {
        let count = itemCount()
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        currentCenter = clamped
        let lower = max(0, clamped - 2)
        let upper = min(count - 1, clamped + 2)

        // 1) 驱逐窗口外（pause + 置空 item 回收解码器）
        for key in players.keys where key < lower || key > upper {
            evict(index: key)
        }

        // 2) 冷启动：池全空只装载居中条，邻居推迟
        if players.isEmpty {
            pendingNeighbors = Array((lower...upper).filter { $0 != clamped })
            Task { await self.acquire(index: clamped) }
            return
        }

        // 3) 补齐窗口内缺失（居中优先）。acquiring 防重入：建池中的 index 不重复建。
        if players[clamped] == nil, !acquiring.contains(clamped) {
            Task { await self.acquire(index: clamped) }
        }
        for i in lower...upper where i != clamped && players[i] == nil && !acquiring.contains(i) {
            Task { await self.acquire(index: i) }
        }
    }

    /// 冷启动邻居补齐（居中 ready 后调用）。
    private func drainPendingNeighbors() {
        guard !pendingNeighbors.isEmpty else { return }
        let batch = pendingNeighbors
        pendingNeighbors.removeAll()
        DiagnosticsLogger.log("冷启动收敛：补齐邻居 \(batch)", category: "playback", level: .debug)
        for i in batch {
            Task { await self.acquire(index: i) }
        }
    }

    /// 纯查询，不 acquire、不驱逐。willDisplay / updatePlaybackStates 都用它。
    func peekPlayer(at index: Int) -> AVPlayer? {
        players[index]
    }

    func isWindowCenter(_ index: Int) -> Bool { index == currentCenter }

    // MARK: - 新建 player

    /// 建 player + KVO。已存在直接复用；同 index 建池中则不重复建。
    func acquire(index: Int) async -> AVPlayer? {
        if let existing = players[index] { return existing }
        guard !acquiring.contains(index) else { return players[index] }
        let count = itemCount()
        guard index >= 0, index < count else { return nil }
        guard let vid = vidAt(index) else {
            DiagnosticsLogger.warn("acquire 失败：index=\(index) 无 vid", category: "playback")
            return nil
        }
        acquiring.insert(index)
        defer { acquiring.remove(index) }
        do {
            let url = try await resolve(vid)
            // resolve 期间可能已被并发驱逐/重建，回读仍为空才落池
            guard players[index] == nil else { return players[index] }
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 8
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .none
            players[index] = player
            installObservers(index: index, player: player, item: item)
            DiagnosticsLogger.log("acquire 建池 index=\(index) vid=\(vid) 池大小=\(players.count)", category: "playback", level: .info)
            onPlayerAcquired?(index)
            return player
        } catch {
            DiagnosticsLogger.error("acquire 失败 index=\(index) vid=\(vid): \(error.localizedDescription)", category: "playback")
            return nil
        }
    }

    // MARK: - 驱逐

    /// 必须置空 item —— 让系统回收解码器（防黑屏关键）。
    private func evict(index: Int) {
        guard let player = players.removeValue(forKey: index) else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers(index: index)
        DiagnosticsLogger.log("驱逐 index=\(index)（pause + item=nil）池大小=\(players.count)", category: "playback", level: .info)
        onEvicted?(index)
    }

    // MARK: - 播放控制

    func pauseAll() {
        for (_, player) in players { player.pause() }
    }

    func pause(index: Int) { players[index]?.pause() }

    func play(index: Int) {
        guard let player = players[index],
              player.currentItem?.status == .readyToPlay else { return }
        player.play()
    }

    /// 全部销毁（视图消失）。
    func shutdown() {
        for key in Array(players.keys) {
            if let player = players[key] {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            removeObservers(index: key)
        }
        players.removeAll()
        pendingNeighbors.removeAll()
        acquiring.removeAll()
        DiagnosticsLogger.log("PlayerManager shutdown，池已清空", category: "playback", level: .info)
    }

    // MARK: - KVO（注意隔离：KVO 回调非 actor 隔离，读值后跳回 MainActor）

    private func installObservers(index: Int, player: AVPlayer, item: AVPlayerItem) {
        // item.status：ready → 补邻居；failed → 只记日志（不自动跳）
        itemStatusObs[index] = item.observe(\.status, options: [.new]) { [weak self] obj, _ in
            let status = obj.status
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status, index: index)
            }
        }
        // timeControlStatus：playing / paused / waitingToPlayAtSpecifiedRate
        timeControlObs[index] = player.observe(\.timeControlStatus, options: [.new]) { [weak self] obj, _ in
            let status = obj.timeControlStatus
            Task { @MainActor [weak self] in
                self?.handleTimeControl(status, index: index)
            }
        }
    }

    private func removeObservers(index: Int) {
        itemStatusObs.removeValue(forKey: index)?.invalidate()
        timeControlObs.removeValue(forKey: index)?.invalidate()
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, index: Int) {
        switch status {
        case .readyToPlay:
            let vid = vidAt(index) ?? "?"
            DiagnosticsLogger.log("item ready index=\(index) vid=\(vid)", category: "playback", level: .info)
            if index == currentCenter {
                drainPendingNeighbors()
                // 关键：fast scroll 时 center 切过来时 item 往往还没 ready（走了 pause 分支），
                // 等 item 真正 readyToPlay 时已没人再触发 play → 停在 paused 黑屏。
                // 这里补一次 play：当前居中条 ready 即播，确保出画面。
                if let p = players[index] {
                    p.play()
                    DiagnosticsLogger.log("居中条 ready 补 play index=\(index) vid=\(vid)", category: "playback", level: .info)
                }
            }
        case .failed:
            let err = players[index]?.currentItem?.error?.localizedDescription ?? "unknown"
            DiagnosticsLogger.error("item failed index=\(index) err=\(err)", category: "playback")
        default:
            DiagnosticsLogger.debug("item status=\(status.rawValue) index=\(index)", category: "playback")
        }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus, index: Int) {
        let vid = vidAt(index) ?? "?"
        switch status {
        case .playing:
            DiagnosticsLogger.log("timeControl=playing index=\(index) vid=\(vid)", category: "playback", level: .info)
        case .paused:
            DiagnosticsLogger.debug("timeControl=paused index=\(index) vid=\(vid)", category: "playback")
        case .waitingToPlayAtSpecifiedRate:
            DiagnosticsLogger.debug("timeControl=waiting index=\(index) vid=\(vid)", category: "playback")
        @unknown default:
            break
        }
    }
}
