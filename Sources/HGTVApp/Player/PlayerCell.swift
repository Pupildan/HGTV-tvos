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
    /// v32 弹幕层（Nbeetok 成熟方案移植）：层级 player < danmaku < cover（封面期一并盖住弹幕）
    let danmakuOverlay = DanmakuOverlay(frame: .zero)
    /// v27 背景：封面高斯模糊铺满，避免小图放大后满屏马赛克
    let coverBlurView = UIImageView(frame: .zero)
    /// v27 前景：清晰封面，保持比例居中（scaleAspectFit），不拉伸失真
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

        // v32 弹幕层：纯展示、不参与焦点/按键
        danmakuOverlay.isUserInteractionEnabled = false
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(danmakuOverlay)

        // v27 背景层：封面高斯模糊铺满（小图放大做背景，模糊反而自然）
        coverBlurView.contentMode = .scaleAspectFill
        coverBlurView.clipsToBounds = true
        coverBlurView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        coverBlurView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverBlurView)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        coverBlurView.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: coverBlurView.topAnchor),
            blur.bottomAnchor.constraint(equalTo: coverBlurView.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: coverBlurView.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: coverBlurView.trailingAnchor),
        ])

        // 前景层：清晰封面保持比例居中，不拉伸失真（v27）
        coverImageView.contentMode = .scaleAspectFit
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = .clear
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(coverImageView)

        NSLayoutConstraint.activate([
            playerLayerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerLayerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playerLayerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerLayerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            danmakuOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            danmakuOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            danmakuOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            danmakuOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverBlurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBlurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            coverBlurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBlurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - 弹幕（v32，渲染层见 HGTVDanmakuOverlay.swift）

    /// bind 后由控制器调用：挂 player + 换集取弹幕。
    func configureDanmaku(vid: String, bookId: String?, durationMs: Int) {
        danmakuOverlay.bind(player: playerLayerView.player)
        danmakuOverlay.load(vid: vid, bookId: bookId, durationMs: durationMs)
    }

    /// 播放态同步（居中在播 = true；离屏/暂停 = false）。
    func syncDanmaku(playing: Bool) {
        danmakuOverlay.syncPlaying(playing)
    }

    /// MARK: - bind（player 由池分配，cell 只挂 layer）

    /// 绑定池里的 player 到本 cell 的 playerLayerView，并挂首帧观察。
    func bind(index: Int, player: AVPlayer, coverURL: URL?,
              onReadyForDisplay: @escaping (Int, Bool) -> Void) {
        boundIndex = index
        self.onReadyForDisplay = onReadyForDisplay
        playerLayerView.isHidden = false
        playerLayerView.player = player
        playerLayerView.setNeedsLayout()
        playerLayerView.layoutIfNeeded()
        coverImageView.isHidden = false
        coverBlurView.isHidden = false
        loadCover(coverURL)
        observeFirstFrame()
        logGeometry(force: true)
    }

    /// 无 player（未进池）时只显示封面兜底。
    func showCoverOnly(index: Int, coverURL: URL?) {
        boundIndex = index
        playerLayerView.player = nil
        playerLayerView.isHidden = true
        danmakuOverlay.bind(player: nil)
        danmakuOverlay.stopAndClean()   // v32：无播放就停弹幕发射器与定时器
        coverImageView.isHidden = false
        coverBlurView.isHidden = false
        loadCover(coverURL)
    }

    /// 字节系图床（byteimg / fqnovelpic）支持 URL 末尾的 `~WxH.jpeg` 规格后缀。
    /// 短剧封面常下发 ~300x400 的小图，全屏铺满会糊；这里升级到 ~1080x1440 取高清。
    /// 无法识别的格式原样返回，加载失败时下方会回退原图。
    private static func hiResCoverURL(_ url: URL) -> URL {
        let s = url.absoluteString
        // 已有形如 ~300x400.jpeg / ~300x400.webp 的规格：替换为更大尺寸
        if let range = s.range(of: #"~(\d+)x(\d+)(\.\w+)$"#, options: .regularExpression) {
            let upgraded = s.replacingOccurrences(of: #"~\d+x\d+(\.\w+)$"#,
                                                  with: "~1080x1440$1",
                                                  options: .regularExpression)
            if let u = URL(string: upgraded) { return u }
            _ = range
        }
        // 无规格后缀：追加高清规格（仅字节系图床，避免在第三方中转上乱加）
        if (s.contains("byteimg.com") || s.contains("fqnovelpic.com")),
           let u = URL(string: s + "~1080x1440.jpeg") {
            return u
        }
        return url
    }

    private func loadCover(_ url: URL?) {
        guard let url else {
            coverImageView.image = nil
            coverBlurView.image = nil
            return
        }
        // v27：先试高清规格，失败回退原图
        let hiRes = Self.hiResCoverURL(url)
        loadCoverData(from: hiRes, fallback: hiRes == url ? nil : url)
    }

    @MainActor
    private func loadCoverData(from url: URL, fallback: URL?) {
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok, let data, let image = UIImage(data: data) {
                Task { @MainActor [weak self] in self?.applyCover(image) }
            } else if let fallback {
                Task { @MainActor [weak self] in self?.loadCoverData(from: fallback, fallback: nil) }
            }
        }.resume()
    }

    @MainActor
    private func applyCover(_ image: UIImage) {
        coverImageView.image = image          // 前景：清晰、保持比例
        coverBlurView.image = image           // 背景：同一张图，下面加模糊
    }

    // MARK: - 首帧信号 playerLayer.isReadyForDisplay

    private func observeFirstFrame() {
        readyObs?.invalidate()
        readyObs = nil
        let layer = playerLayerView.playerLayer
        if layer.isReadyForDisplay {
            coverImageView.isHidden = true
            coverBlurView.isHidden = true
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
            coverBlurView.isHidden = true
            logGeometry(force: true)
        }
        onReadyForDisplay?(boundIndex, ready)
    }

    // MARK: - 尺寸日志（定位「画面残缺」）

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayerView.frame = contentView.bounds
        coverBlurView.frame = contentView.bounds
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
        danmakuOverlay.bind(player: nil)
        danmakuOverlay.stopAndClean()   // v32：复用前清弹幕（防旧集弹幕串场）
        coverImageView.image = nil
        coverImageView.isHidden = false
        coverBlurView.image = nil
        coverBlurView.isHidden = false
        onReadyForDisplay = nil
        boundIndex = -1
    }
}
