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

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCollectionView()
        wireCallbacks()
        installLoopObserver()

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
    }

    /// 循环播放：居中条目播完自动重头。
    private func installLoopObserver() {
        guard playToEndObserver == nil else { return }
        // 用字面量构造（部分 SDK 解析不到该符号）
        let name = Notification.Name("AVPlayerItemDidPlayToEnd")
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let ended = note.object as? AVPlayerItem else { return }
            let centered = self.manager.peekPlayer(at: self.engine.index)
            guard centered?.currentItem === ended else { return }
            centered?.seek(to: .zero)
            centered?.play()
            DiagnosticsLogger.debug("循环重播 index=\(self.engine.index)", category: "playback")
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
            if i == clamped {
                if player.currentItem?.status == .readyToPlay {
                    player.play()
                }
            } else {
                player.pause()
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

    // MARK: - 遥控（Siri Remote 上下箭头）

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardUpArrow:
                rewind()
                handled = true
            case .keyboardDownArrow:
                advance()
                handled = true
            default:
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
    }

    // MARK: 手动 snap（tvOS 不用 isPagingEnabled）

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pageHeight = view.bounds.height
        guard pageHeight > 0 else { return }
        let raw = targetContentOffset.pointee.y
        let snapped: CGFloat = velocity.y >= 0
            ? ceil(raw / pageHeight)
            : floor(raw / pageHeight)
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clamped = min(max(0, snapped * pageHeight), maxOffset)
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
