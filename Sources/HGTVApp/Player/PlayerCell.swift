// PlayerCell.swift
// 全屏 PlayerCell（参考 DYTV 架构）。核心三原则之一：
// Cell 不创建也不持有 player，只有一个 playerLayerView（AVPlayerLayer 容器）；
// player 由 PlayerManager 池分配，willDisplay 时 bind 到 cell。
//
// 修「画面残缺/压成一小条」的关键：
//   PlayerLayerView 重写 layerClass 返回 AVPlayerLayer，layer 与 view 同体，
//   layoutSubviews 里强制 playerLayer.frame = bounds，cell = 全屏 → layer 铺满全屏。

import UIKit
import AVFoundation
import HGTVCore

/// AVPlayerLayer 容器。用 layerClass 保证 layer 就是 view 的根 layer，
/// 从而 layoutSubviews 设 frame=bounds 即可让视频铺满整个 cell（全屏）。
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关键：layer 铺满容器，避免画面残缺/压成一小条
        playerLayer.frame = bounds
    }
}

/// 全屏 cell：底层 playerLayerView + 顶层封面兜底（首帧未到时显示封面）。
// ⚠️ cell 保持默认可聚焦（tvOS 焦点引擎靠它在上下滑动时移动焦点 → collection
// 自动滚动 = 切换短剧）。v22 曾误设 canBecomeFocused=false 想改走焦点代理，
// 把这个本来就工作的核心机制杀掉了（真机反馈三处遥控交互全失效）。
final class PlayerCell: UICollectionViewCell {
    static let reuseID = "PlayerCell"

    let playerLayerView = PlayerLayerView(frame: .zero)
    let coverImageView = UIImageView(frame: .zero)

    /// 首帧渲染回调（控制器上报给 engine.noteFirstFrame）。
    var onReadyForDisplay: ((Int, Bool) -> Void)?
    private var boundIndex = -1
    private var readyObs: NSKeyValueObservation?
    private var lastLoggedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        // 底层：视频层
        playerLayerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerLayerView)

        // 顶层：封面兜底（首帧未 ready 时遮住黑屏）
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverImageView)

        NSLayoutConstraint.activate([
            playerLayerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerLayerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playerLayerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerLayerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - bind（player 由池分配，cell 只挂 layer）

    /// 绑定池里的 player 到本 cell 的 playerLayerView，并挂首帧观察。
    func bind(index: Int, player: AVPlayer, coverURL: URL?,
              onReadyForDisplay: @escaping (Int, Bool) -> Void) {
        boundIndex = index
        self.onReadyForDisplay = onReadyForDisplay
        playerLayerView.isHidden = false
        playerLayerView.player = player
        playerLayerView.setNeedsLayout()
        playerLayerView.layoutIfNeeded()
        loadCover(coverURL)
        observeFirstFrame()
        logGeometry(force: true)
    }

    /// 无 player（未进池）时只显示封面兜底。
    func showCoverOnly(index: Int, coverURL: URL?) {
        boundIndex = index
        playerLayerView.player = nil
        playerLayerView.isHidden = true
        loadCover(coverURL)
    }

    private func loadCover(_ url: URL?) {
        guard let url else {
            coverImageView.image = nil
            return
        }
        // 封面异步加载；不引入第三方，用简单的 URLSession 缓存
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Task { @MainActor [weak self] in
                self?.coverImageView.image = image
            }
        }.resume()
    }

    // MARK: - 首帧信号 playerLayer.isReadyForDisplay

    private func observeFirstFrame() {
        readyObs?.invalidate()
        readyObs = nil
        let layer = playerLayerView.playerLayer
        if layer.isReadyForDisplay {
            coverImageView.isHidden = true
            onReadyForDisplay?(boundIndex, true)
            return
        }
        readyObs = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] obj, _ in
            let ready = obj.isReadyForDisplay
            Task { @MainActor [weak self] in
                self?.handleReady(ready)
            }
        }
    }

    private func handleReady(_ ready: Bool) {
        if ready {
            coverImageView.isHidden = true
            logGeometry(force: true)
        }
        onReadyForDisplay?(boundIndex, ready)
    }

    // MARK: - 尺寸日志（定位「画面残缺」）

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayerView.frame = contentView.bounds
        coverImageView.frame = contentView.bounds
        logGeometry(force: false)
    }

    private func logGeometry(force: Bool) {
        let cellSize = contentView.bounds.size
        let layerSize = playerLayerView.playerLayer.frame.size
        guard force || cellSize != lastLoggedSize else { return }
        lastLoggedSize = cellSize
        DiagnosticsLogger.log(
            "cell 几何 index=\(boundIndex) cell=\(cellSize) layer=\(layerSize) gravity=resizeAspect",
            category: "playback", level: .debug
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        readyObs?.invalidate()
        readyObs = nil
        playerLayerView.player = nil
        coverImageView.image = nil
        coverImageView.isHidden = false
        onReadyForDisplay = nil
        boundIndex = -1
    }
}
