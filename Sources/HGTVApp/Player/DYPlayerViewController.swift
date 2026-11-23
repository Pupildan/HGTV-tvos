// DYPlayerViewController.swift
// 抖音式垂直分页播放控制器（参考 DYTV 架构）。核心三原则之三：
// tvOS 不用 isPagingEnabled，用 scrollViewWillEndDragging 手动 snap；
// 程序化切换用 setContentOffset（不用 scrollToItem —— flow layout 未就绪抛 NSException→SIGABRT）。
// willDisplay 只 peekPlayer bind（不 acquire，防快速滑动撑大池）；
// 滚动停稳 updatePlaybackStates（居中 play / 非居中 pause，只查池不触驱逐）；
// 遥控 pressesBegan up/down 切换；接近末尾触发 engine.onNeedMore 无限 feed。

import UIKit
import AVFoundation
import HGTVCore

final class DYPlayerViewController: UIViewController {
    private let engine: PlaybackEngine
    private lazy var manager: PlayerManager = PlayerManager(
        resolve: { [weak self] vid in
            guard let self else { throw PlaybackResolveError.missingVid }
            return try await self.engine.resolveLocalURL(for: vid)
        },
        itemCount: { [weak self] in self?.engine.itemCount ?? 0 },
        vidAt: { [weak self] i in self?.engine.vid(at: i) }
    )

    private var collectionView: UICollectionView!
    private var isLoadingMore = false
    private var playToEndObserver: NSObjectProtocol?

    /// 遥控确认键（中键 .select）→ 通知 SwiftUI 呼出底部功能弹窗（v25）。
    /// 不再用返回键呼出（返回键交还系统做正常返回/关闭浮层），也取消中键直接进详情。
    var onSelectKey: (() -> Void)?
    /// 返回推荐流后整表 reload + 回到第 0 条（v24）。
    private func handleFeedRestored() {
        manager.pauseAll()
        collectionView.reloadData()
        scrollTo(index: 0, animated: false)
    }

    // MARK: - 弹窗焦点让渡（v26）
    /// 底部弹窗显示期间调用：让 collectionView 退出焦点与交互，
    /// 使焦点能落到 SwiftUI 弹窗按钮上，并禁用上下滑动/方向键切剧。
    /// 关闭后务必恢复，否则刷剧交互全断（坑 16 教训）。
    private var panelActive = false
    func setPanelActive(_ active: Bool) {
        guard panelActive != active else { return }
        panelActive = active
        // v27：只关焦点（allowsFocus），不再动 isUserInteractionEnabled——
        // 后者会连手势识别器一起禁掉，导致弹窗关闭后确认键再也收不到（呼不出的回归根因）。
        if #available(tvOS 15.0, *) {
            collectionView.allowsFocus = !active
        }
        // 让焦点系统重新计算：退出时从 collectionView 移走，恢复时回到当前 cell
        view.setNeedsFocusUpdate()
        view.updateFocusIfNeeded()
        DiagnosticsLogger.log("弹窗\(active ? "打开" : "关闭")：collectionView 焦点 \(active ? "禁用" : "恢复")",
                              category: "playback", level: .debug)
    }

    // v28：确认键不再用 pressesBegan / 手势识别器——tvOS 上 .select 被焦点系统
    // 优先分配给当前聚焦的 cell，这两种都收不到。改由 UICollectionViewDelegate 的
    // collectionView(_:didSelectItemAtIndexPath:) 处理（聚焦 cell 按中键的标准回调）。

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // 注意：不加 deinit——Swift 6 下 deinit 非隔离，访问 MainActor 属性会编译失败
    //（endCheckTimer/playToEndObserver 与控制器同生命周期，随进程结束释放）。

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCollectionView()
        wireCallbacks()
        installLoopObserver()
        // v28：确认键由 collectionView(_:didSelectItemAtIndexPath:) 处理（见 extension），
        // 不再用 pressesBegan / 手势识别器（tvOS .select 被焦点系统消费，二者都收不到）。

        Task { [weak self] in
            guard let self else { return }
            if self.engine.itemCount == 0 {
                await self.engine.load()
            }
            self.syncItemCount()
            self.collectionView.reloadData()
            self.scrollTo(index: 0, animated: false)
            self.updatePlaybackStates(center: 0)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // cell = 全屏：layout itemSize = view 尺寸，保证 layer 铺满
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let size = view.bounds.size
        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
            let idx = engine.index
            if idx > 0 {
                scrollTo(index: idx, animated: false)
            }
        }
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize = view.bounds.size

        let cv = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        cv.contentInsetAdjustmentBehavior = .never
        cv.decelerationRate = .fast
        cv.register(PlayerCell.self, forCellWithReuseIdentifier: PlayerCell.reuseID)
        cv.dataSource = self
        cv.delegate = self
        view.addSubview(cv)
        cv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cv.topAnchor.constraint(equalTo: view.topAnchor),
            cv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        collectionView = cv
    }

    private func wireCallbacks() {
        // 池建好 player → 重新 bind 可见 cell（首屏 acquire 完成时 cell 已 willDisplay 过）
        manager.onPlayerAcquired = { [weak self] index in
            self?.handlePlayerAcquired(index: index)
        }
        // 驱逐 → 释放对应本地代理（省内存）
        manager.onEvicted = { [weak self] index in
            guard let self, let vid = self.engine.vid(at: index) else { return }
            self.engine.releaseProxy(vid: vid)
        }
        // 接近末尾 → 加载更多并刷新 collection
        engine.onNeedMore = { [weak self] in
            self?.loadMoreAndSync()
        }
        // 选集 → 整表替换为剧集连播（v22）
        engine.onDataReplaced = { [weak self] startIndex in
            guard let self else { return }
            self.collectionView.reloadData()
            self.scrollTo(index: startIndex, animated: false)
        }
        // 取流失败（电影等无流条目）→ 居中时自动跳到最近可播条目（v23 兜底）
        manager.onAcquireFailed = { [weak self] index in
            self?.handleAcquireFailed(index: index)
        }
        // 返回推荐流（v24）：整表 reload + 回到第 0 条
        engine.onFeedRestored = { [weak self] in
            self?.handleFeedRestored()
        }
        // 推荐流整剧展开（v新）：本集后面插入了本剧后续集，精确增量插入 cell，不打断播放
        engine.onItemsInserted = { [weak self] at, count in
            self?.handleItemsInserted(at: at, count: count)
        }
    }

    /// 推荐流整剧展开回调：在 at 位置精确插入 count 个 cell（当前集后面）。
    /// 用 performBatchUpdates 精确插入，避免 syncItemCount 的尾部追加把中间插入算错位。
    private func handleItemsInserted(at: Int, count: Int) {
        guard let cv = collectionView, count > 0 else { return }
        let paths = (at..<(at + count)).map { IndexPath(item: $0, section: 0) }
        cv.performBatchUpdates { cv.insertItems(at: paths) }
        DiagnosticsLogger.log("整剧展开插入 \(count) 个 cell@\(at) → 共 \(engine.itemCount)",
                              category: "playback", level: .info)
    }

    /// 居中条目取流失败：就近跳到可播条目（双向），避免停留在只有封面的死页。
    private func handleAcquireFailed(index: Int) {
        guard index == engine.index else { return }
        if let next = engine.nearestPlayableIndex(after: index, forwardOnly: false) {
            DiagnosticsLogger.log("条目无播放地址，自动跳过 → index=\(next)", category: "playback", level: .info)
            scrollTo(index: next, animated: true)
        } else {
            DiagnosticsLogger.warn("无可播条目可跳过，原地停留", category: "playback")
        }
    }

    /// 播完自动切下一集（v22 A1；v23 增加跳过无流条目；v31 增加轮询兜底）。
    /// 通知路径：AVPlayerItemDidPlayToEndTime。
    /// 轮询路径（v31）：本地代理流若未正确标记流结尾（Content-Length/连接关闭），
    /// AVPlayer 会停在最后一帧却认为仍在缓冲 → 通知永不触发。轮询每 0.5s 检查
    /// 居中播放器「已播进度 ≥ 时长 - 0.5s」兜底切集。两条路径共用 autoAdvance，幂等。
    private func installLoopObserver() {
        guard playToEndObserver == nil else { return }
        // 用字面量构造（部分 SDK 解析不到该符号）。
        // 注意系统通知 rawValue 是 "AVPlayerItemDidPlayToEndTime"（旧代码少了 "Time"）。
        let name = Notification.Name("AVPlayerItemDidPlayToEndTime")
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] note in
            guard let ended = note.object as? AVPlayerItem else { return }
            // 通知块是 @Sendable 上下文，所有 MainActor 操作统一 hop 回主 actor
            Task { @MainActor [weak self] in
                guard let self else { return }
                let centered = self.manager.peekPlayer(at: self.engine.index)
                let matched = centered?.currentItem === ended
                DiagnosticsLogger.log("收到播完通知 匹配居中条=\(matched)", category: "playback", level: .debug)
                guard matched else { return }
                self.autoAdvance()
            }
        }
        installEndCheckTimer()
    }

    // MARK: - 播完兜底轮询 + 自动切集（v31）

    /// 兜底播完检测计时器。
    private var endCheckTimer: Timer?
    /// 最近一次自动切集时间（幂等去重：通知与轮询不会重复触发；3s 内只切一次）。
    private var lastAutoAdvanceAt = Date.distantPast

    private func installEndCheckTimer() {
        guard endCheckTimer == nil else { return }
        endCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPlaybackEnded() }
        }
    }

    /// 居中条目播完检测：已播进度到达片尾即切下一集（不依赖 EOS 通知）。
    private func checkPlaybackEnded() {
        guard let player = manager.peekPlayer(at: engine.index),
              let item = player.currentItem,
              item.status == .readyToPlay,
              item.duration.seconds.isFinite, item.duration.seconds > 1 else { return }
        let cur = player.currentTime().seconds
        if cur >= item.duration.seconds - 0.5 {
            DiagnosticsLogger.log("轮询检测到播完 cur=\(String(format: "%.1f", cur))s dur=\(String(format: "%.1f", item.duration.seconds))s",
                                  category: "playback", level: .debug)
            autoAdvance()
        }
    }

    /// 自动切下一集（通知/轮询共用入口）。3s 去重防止双路径重复触发。
    private func autoAdvance() {
        guard Date().timeIntervalSince(lastAutoAdvanceAt) > 3 else { return }
        lastAutoAdvanceAt = Date()
        if let next = engine.nearestPlayableIndex(after: engine.index, forwardOnly: true) {
            DiagnosticsLogger.log("播完自动切下一集 index=\(next)", category: "playback", level: .info)
            scrollTo(index: next, animated: true)
        } else {
            // 向前无可播：补一批 feed 后再试（剧集连播看完自动续接推荐流）
            Task { [weak self] in
                guard let self else { return }
                await self.loadMoreAndSync()
                guard Date().timeIntervalSince(self.lastAutoAdvanceAt) > 3 else { return }
                if let next = self.engine.nearestPlayableIndex(after: self.engine.index, forwardOnly: true) {
                    self.lastAutoAdvanceAt = Date()
                    self.scrollTo(index: next, animated: true)
                }
            }
        }
    }

    // MARK: - 数据同步（无限 feed）

    /// 按当前 engine.items 数量增量插入 cell（不整表 reload，避免打断滚动）。
    func syncItemCount() {
        guard let cv = collectionView else { return }
        let count = engine.itemCount
        let old = cv.numberOfItems(inSection: 0)
        guard count != old else { return }
        if count > old {
            let new = (old..<count).map { IndexPath(item: $0, section: 0) }
            cv.insertItems(at: new)
            DiagnosticsLogger.log("syncItemCount 插入 \(new.count) 条 → 共 \(count)", category: "playback", level: .debug)
        } else {
            cv.reloadData()
        }
    }

    private func loadMoreAndSync() {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            let before = self.engine.itemCount
            await self.engine.loadMore()
            self.isLoadingMore = false
            if self.engine.itemCount != before {
                self.syncItemCount()
            }
        }
    }

    // MARK: - 池建好后重新 bind

    private func handlePlayerAcquired(index: Int) {
        let ip = IndexPath(item: index, section: 0)
        if let cell = collectionView.cellForItem(at: ip) as? PlayerCell,
           let player = manager.peekPlayer(at: index) {
            bind(cell: cell, at: index, player: player)
        }
        if index == engine.index {
            manager.play(index: index)
            // v32：池建好即开播 → 弹幕发射器同步进入播放态
            if let cell = collectionView.cellForItem(at: ip) as? PlayerCell {
                cell.syncDanmaku(playing: true)
            }
        }
    }

    // MARK: - bind cell

    private func bind(cell: PlayerCell, at index: Int, player: AVPlayer) {
        let coverURL = dramaAt(index)?.thumbURL
        cell.bind(index: index, player: player, coverURL: coverURL) { [weak self] idx, ready in
            guard let self else { return }
            if ready {
                DiagnosticsLogger.log("首帧 isReadyForDisplay=true index=\(idx) vid=\(self.engine.vid(at: idx) ?? "?")", category: "playback", level: .info)
            }
            self.engine.noteFirstFrame(index: idx)
        }
        // v32 弹幕：换集取数（duration 未就绪时传 0 → DanmakuService 用兜底时长分窗）
        let item = engine.items[index]
        let durationMs = Int(player.currentItem?.duration.seconds.isFinite == true
                             ? player.currentItem!.duration.seconds * 1000 : 0)
        let danmakuVid = engine.vid(at: index) ?? ""
        DiagnosticsLogger.log("🔍 [弹幕诊断] bind() 调用 configureDanmaku vid=\(danmakuVid) bookId=\(item.seriesId ?? "nil") durationMs=\(durationMs)",
                              category: "danmaku", level: .info)
        cell.configureDanmaku(vid: danmakuVid,
                              bookId: item.seriesId,
                              durationMs: max(0, durationMs))
    }

    private func dramaAt(_ index: Int) -> DramaItem? {
        engine.vid(at: index) != nil ? engine.items[index] : nil
    }

    // MARK: - 播放状态（居中 play / 非居中 pause）

    private func updatePlaybackStates(center: Int) {
        let count = engine.itemCount
        guard count > 0 else { return }
        let clamped = min(max(0, center), count - 1)
        engine.updateCenter(clamped)
        manager.prepare(center: clamped)

        // 只查池（peekPlayer），不 acquire、不触驱逐 —— 杜绝双 center 打架
        for i in 0..<count {
            guard let player = manager.peekPlayer(at: i) else { continue }
            let playing = i == clamped && player.currentItem?.status == .readyToPlay
            if i == clamped {
                if player.currentItem?.status == .readyToPlay {
                    player.play()
                }
            } else {
                player.pause()
            }
            // v32 弹幕播放态跟随（居中在播才发射）
            if let cell = collectionView.cellForItem(at: IndexPath(item: i, section: 0)) as? PlayerCell {
                cell.syncDanmaku(playing: playing)
            }
        }
        DiagnosticsLogger.log("updatePlaybackStates center=\(clamped) vid=\(engine.vid(at: clamped) ?? "?")", category: "playback", level: .info)
    }

    // MARK: - 程序化切换（setContentOffset，不用 scrollToItem）

    private func scrollTo(index: Int, animated: Bool) {
        let count = engine.itemCount
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        let pageHeight = view.bounds.height
        guard pageHeight > 0 else { return }
        let offset = CGPoint(x: 0, y: CGFloat(clamped) * pageHeight)
        collectionView.setContentOffset(offset, animated: animated)
        if !animated {
            updatePlaybackStates(center: clamped)
        }
    }

    private func advance() { scrollTo(index: engine.index + 1, animated: true) }
    private func rewind() { scrollTo(index: engine.index - 1, animated: true) }

    // MARK: - 遥控（v25：中键呼出弹窗，返回键交还系统）

    /// 遥控交互模型（基于 tvOS 焦点引擎的真实行为，v23 的焦点代理方案在 SwiftUI
    /// 环境下拿不到焦点、还误杀了 cell 焦点机制，真机三处交互全失效——教训见坑 16）：
    ///   - **上下滑动**：cell 保持默认可聚焦 → 焦点引擎在 cell 间移动焦点 →
    ///     collection 自动滚动 = 切换不同短剧（v22 之前就在工作的原生机制，勿动）。
    ///   - **左右滑动**：横向没有可聚焦目标 → 焦点引擎放弃该方向 → 方向按键
    ///     **回落到 pressesBegan** → 这里翻译成上一集/下一集。
    ///   - **中键确认**：v28 由 collectionView(_:didSelectItemAtIndexPath:) 呼出弹窗
    ///     （.select 被焦点系统消费，pressesBegan/手势都收不到）。原「中键直接进详情」已取消。
    ///   - **返回键**：v25 起不再拦截，交还 tvOS 系统做正常返回/关闭浮层。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:
                rewind()
                handled = true
            case .rightArrow:
                advance()
                handled = true
            default:
                // v28：.select 已改由 didSelectItemAtIndexPath 处理（pressesBegan 收不到）
                break
            }
        }
        if handled { return }
        super.pressesBegan(presses, with: event)
    }

    /// 离开时停播并移除循环观察（避免 deinit 访问 actor 隔离属性）。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        manager.pauseAll()
        if let obs = playToEndObserver {
            NotificationCenter.default.removeObserver(obs)
            playToEndObserver = nil
        }
        DiagnosticsLogger.log("DYPlayerViewController viewDidDisappear，已停播并移除循环观察", category: "playback", level: .info)
    }
}

// MARK: - UICollectionViewDataSource

extension DYPlayerViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        engine.itemCount
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PlayerCell.reuseID,
                                                      for: indexPath) as! PlayerCell
        // 只有封面兜底；真正 bind 在 willDisplay（池分配 player）
        cell.showCoverOnly(index: indexPath.item, coverURL: dramaAt(indexPath.item)?.thumbURL)
        return cell
    }
}

// MARK: - UICollectionViewDelegate（willDisplay bind + 停稳 updatePlaybackStates）

extension DYPlayerViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let playerCell = cell as? PlayerCell else { return }
        let index = indexPath.item
        // 只 peek 不 acquire：快速滑动不会撑大池（防抖动黑屏）
        if let player = manager.peekPlayer(at: index) {
            bind(cell: playerCell, at: index, player: player)
        } else {
            playerCell.showCoverOnly(index: index, coverURL: dramaAt(index)?.thumbURL)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // 离屏条目 pause（不驱逐，仍在 ±2 窗口内的留给池管理）
        if let player = manager.peekPlayer(at: indexPath.item) {
            player.pause()
        }
        // v32：离屏条目弹幕停发射（防换集旧幕串场）
        (cell as? PlayerCell)?.syncDanmaku(playing: false)
    }

    /// v28：遥控确认键（中键）在 tvOS 上会选中当前聚焦的 cell → 走这里。
    /// 这是 .select 被焦点系统消费后唯一可靠的接收点。弹窗显示时 cell 已退出焦点，
    /// 不会触发本回调，故不会与弹窗按钮的点击冲突。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard !panelActive else { return }
        DiagnosticsLogger.log("cell 确认键(index=\(indexPath.item))，呼出弹窗", category: "playback", level: .debug)
        onSelectKey?()
    }

    // MARK: 手动 snap（tvOS 不用 isPagingEnabled）

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pageHeight = view.bounds.height
        guard pageHeight > 0 else { return }
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)

        // v28：降低翻页灵敏度。用「拖拽起点页 → 目标页」的实际跨页距离判断：
        // 只有位移超过阈值（页高 35%）或速度足够大（快速轻扫）才翻一页；
        // 轻微滑动一律回弹到当前页，避免碰一下就切剧。
        let currentPage = max(0, min(engine.index, engine.itemCount - 1))
        let currentOffset = CGFloat(currentPage) * pageHeight
        let raw = targetContentOffset.pointee.y
        let delta = raw - currentOffset
        let threshold = pageHeight * 0.35
        let fastSwipe = abs(velocity.y) >= 0.6   // 快速轻扫仍按方向翻页

        var targetPage = currentPage
        if fastSwipe {
            targetPage += velocity.y > 0 ? 1 : -1
        } else if delta >= threshold {
            targetPage += 1
        } else if delta <= -threshold {
            targetPage -= 1
        }
        targetPage = max(0, min(targetPage, engine.itemCount - 1))
        let clamped = min(CGFloat(targetPage) * pageHeight, maxOffset)
        targetContentOffset.pointee.y = clamped
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.y / max(1, view.bounds.height)))
        updatePlaybackStates(center: page)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.y / max(1, view.bounds.height)))
        updatePlaybackStates(center: page)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            let page = Int(round(scrollView.contentOffset.y / max(1, view.bounds.height)))
            updatePlaybackStates(center: page)
        }
    }
}
