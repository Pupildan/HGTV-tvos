// HGTVDanmakuOverlay.swift
// 弹幕渲染层（v32）。渲染方案整体移植自 Nbeetok/dy-tvos（本地已实测打磨到 v150 的成熟方案）：
// DanmakuKit（vendored，MIT，见 Player/DanmakuKit/）+ 按播放时钟的发射器。
// 移植改动：DYDanmakuItem → HGTVCore.DanmakuMessage（番茄 commentapi 数据源）；
//           DYLog → DiagnosticsLogger；awemeId → vid。
//
// 已实测沉淀的关键参数与机制（勿随意改动，出处见 Nbeetok v132-v150 迭代记录）：
//   - 字号 34 / 轨道高 50 / 速度 280px/s / 顶部 6 行 / 禁止重叠；
//   - canShoot 门控：轨道满不标记，下个 tick 补射（治「空窗+扎堆」）；
//   - 轨道卡死自愈：due>0 连续 10s 零发射 → clean() 清轨重发；
//   - 迟到 40s 以上过期不射（防堆积爆屏）；id 去重（seek 回退不重放，同抖音观感）。

import UIKit
import SwiftUI
import AVFoundation
import HGTVCore

/// 弹幕文字模型（DanmakuKit DanmakuCellModel 协议实现）。
/// displayTime = 滚屏总时长 = (区域宽+文字宽)/速度；identifier 用弹幕 id（去重/等值判断）。
final class DanmakuTextCellModel: DanmakuCellModel {
    /// 字号统一 34（轨道高 34 的观感匹配；测量与绘制必须同源）
    static let fontSize: CGFloat = 34
    /// 滚动速度 280px/s（Nbeetok v149 用户要求降速；380→280 穿屏约 6.5s）
    static let scrollSpeed: CGFloat = 280

    let text: String
    let sizeValue: CGSize
    let displayTimeValue: Double
    let identifierValue: String

    var cellClass: DanmakuCell.Type { DanmakuTextCell.self }
    var size: CGSize { sizeValue }
    var track: UInt?
    var displayTime: Double { displayTimeValue }
    var type: DanmakuCellType { .floating }
    var identifier: String { identifierValue }

    func isEqual(to cellModel: DanmakuCellModel) -> Bool {
        cellModel.identifier == identifier
    }

    init(danmakuId: String, text: String, screenW: CGFloat) {
        self.text = text
        self.identifierValue = danmakuId
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: Self.fontSize),
        ]
        let measured = (text as NSString).size(withAttributes: attrs)
        let w = min(measured.width + 8, screenW - 40)
        sizeValue = CGSize(width: w, height: measured.height + 6)
        displayTimeValue = max(4.0, (screenW + w) / Self.scrollSpeed)
    }
}

/// 弹幕文字 Cell：DanmakuKit 异步图层上画纯色文字（Nbeetok v134 用户要求：无背景、无描边）。
final class DanmakuTextCell: DanmakuCell {
    required init(frame: CGRect) {
        super.init(frame: frame)
        // 关键：DanmakuAsyncLayer 在 layer isOpaque==true 时会主动填白（白底来源）——显式关掉
        // （官方 example 同款：backgroundColor = .clear；再加 isOpaque=false 双保险）
        backgroundColor = .clear
        isOpaque = false
        layer.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {
        guard let model = model as? DanmakuTextCellModel else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: DanmakuTextCellModel.fontSize),
            .foregroundColor: UIColor.white,
        ]
        model.text.draw(in: CGRect(x: 0, y: 2, width: size.width, height: size.height), withAttributes: attrs)
    }
}

/// 弹幕覆盖层：包 DanmakuView（Core Animation 驱动，滚屏平滑）+ 按播放时钟发射器。
/// 生命周期由控制器驱动：load(vid:) 换集 → syncPlaying 播放态 → seekSync 拖动。
/// tvOS 焦点隔离：isUserInteractionEnabled=false，不参与焦点/按键（渲染纯展示层）。
final class DanmakuOverlay: UIView {
    private let danmakuView: DanmakuView
    private weak var player: AVPlayer?
    private var items: [DanmakuMessage] = []
    /// 已发射过的弹幕 id 集合（Nbeetok v139：分段乱序追加容忍 + seek 回退可重弹）
    private var shotIds = Set<String>()
    private var loadedVid = ""
    private var fetchRequested = false
    private var timer: Timer?
    /// 弹幕总开关（默认开；持久化 + 跨层同步走 NotificationCenter）
    static var globalEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hgtv_danmaku_on") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hgtv_danmaku_on") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hgtv_danmaku_on")
            NotificationCenter.default.post(name: .hgtvDanmakuToggled, object: NSNumber(value: newValue))
        }
    }
    /// 单 overlay 开关
    var enabled = true
    /// 弹幕开关通知 token（block observer 必须持 token 才能注销；let 供 deinit 注销）
    private let toggleObs: NSObjectProtocol?

    var currentVid: String { loadedVid }

    override init(frame: CGRect) {
        danmakuView = DanmakuView(frame: .zero)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        danmakuView.isUserInteractionEnabled = false
        // Nbeetok v149/v150 规格：
        // ①只显示在屏幕顶部 6 行（displayArea 在 layoutSubviews 按 6 行精确计算）；
        // ②禁止重叠（轨道满由 canShoot 门控丢弃，发射连续不扎堆）；
        // ③降速 280px/s；行距加大（轨道高 50，字 34 行间空 ~16px）。
        danmakuView.trackHeight = 50
        danmakuView.isOverlap = false
        danmakuView.enableCellReusable = true
        danmakuView.delegate = self
        addSubview(danmakuView)
        // 弹幕开关跨层同步（面板切换 → 所有 overlay 立即生效）
        toggleObs = NotificationCenter.default.addObserver(
            forName: .hgtvDanmakuToggled, object: nil, queue: .main
        ) { [weak self] note in
            let on = (note.object as? NSNumber)?.boolValue ?? true
            Task { @MainActor [weak self] in
                self?.applyGlobalEnabled(on)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 注意：不加 timer 清理——Swift 6 deinit 非隔离，访问 MainActor 的 var timer 会编译失败
    //（坑：与 DYPlayerViewController 同）。timer 闭包是 [weak self]，视图销毁后 tick 空转成本为零；
    // 正常回收路径（prepareForReuse/showCoverOnly/stopAndClean）都会 invalidate。
    deinit {
        if let toggleObs {
            NotificationCenter.default.removeObserver(toggleObs)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        danmakuView.frame = bounds
        // 顶部 6 行：DanmakuKit viewHeight=bounds.height*displayArea，trackCount=floor(viewHeight/trackHeight)。
        // 按 6.5 行宽度给值（floor 后恰为 6 行，且对任意屏高稳健）；区域从顶部铺。
        if bounds.height > 0 {
            danmakuView.displayArea = min(0.95, 6.5 * danmakuView.trackHeight / bounds.height)
        }
    }

    func bind(player: AVPlayer?) {
        self.player = player
    }

    /// 换集：清空 + 重取该集弹幕（vid 未变则跳过）。
    /// 分段取回：onSegment 可能乱序追加（失败重试段）——追加后按 offset 重排，发射器用 id 去重扫描。
    func load(vid: String, bookId: String?, durationMs: Int) {
        guard loadedVid != vid else { return }
        loadedVid = vid
        items = []
        shotIds = []
        fetchRequested = false
        danmakuView.stop()
        danmakuView.clean()
        guard !vid.isEmpty, !fetchRequested else { return }
        fetchRequested = true
        DiagnosticsLogger.log("DMLOAD vid=\(vid) dur=\(durationMs)", category: "danmaku", level: .debug)
        Task { [weak self] in
            let vidCopy = vid
            _ = await DanmakuService.shared.fetchAll(vid: vidCopy, bookId: bookId, durationMs: durationMs) { [weak self] seg in
                guard let self, self.loadedVid == vidCopy else { return }   // 已换集则丢弃
                self.appendItems(seg)
            }
            guard let self, self.loadedVid == vidCopy else { return }
            DiagnosticsLogger.log("DMLOAD done vid=\(vidCopy) total=\(self.items.count)", category: "danmaku", level: .debug)
        }
    }

    /// 播放态同步（居中且在播 → play 并对齐时钟；否则 pause）。
    func syncPlaying(_ playing: Bool) {
        guard enabled else { return }
        if playing {
            if danmakuView.status == .stop || danmakuView.status == .pause {
                danmakuView.play()
            }
            ensureTimer()
        } else {
            danmakuView.pause()
        }
    }

    /// seek 后：清屏（回退重播时段幕会随时间重新飘出；已发射集合保留防同屏重复）。
    func seekSync() {
        guard enabled else { return }
        danmakuView.clean()
    }

    func stopAndClean() {
        danmakuView.stop()
        danmakuView.clean()
        shotIds = []
        items = []
        loadedVid = ""
        timer?.invalidate()
        timer = nil
    }

    /// 面板弹幕开关联动：关 → 清屏并暂停；开 → 恢复播放态。
    private func applyGlobalEnabled(_ on: Bool) {
        if on {
            syncPlaying(player?.timeControlStatus == .playing)
        } else {
            danmakuView.clean()
            danmakuView.pause()
            timer?.invalidate()
            timer = nil
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 追加弹幕（可能乱序——重试段晚到）：按 offset 重排保持 tick 的顺序扫描假设。
    private func appendItems(_ seg: [DanmakuMessage]) {
        guard !seg.isEmpty else { return }
        items.append(contentsOf: seg)
        items.sort { $0.offsetMs < $1.offsetMs }
    }

    /// 发射器：按播放时钟扫描到点的弹幕 shoot 出去（id 去重，容忍乱序追加）。
    /// Nbeetok v150 关键改造（治「空窗+扎堆」循环）：
    /// ①**canShoot 门控**——先问轨道能否容纳，拒绝则【不标记】，轨道腾出后下个 tick 补射；
    /// ②轨道卡死自愈——due>0 却连续 10s 零发射 → clean() 强制清轨重发；
    /// ③DMSYNC 每 4s 一条诊断日志。迟到 40s 以上的过期不射（防堆积爆屏）。
    private var emptyTicks = 0
    private var syncTick = 0

    private func tick() {
        guard Self.globalEnabled, enabled, !items.isEmpty, danmakuView.status == .play, player?.timeControlStatus == .playing else { return }
        let t = (player?.currentTime().seconds ?? 0) * 1000
        var shot = 0
        var due = 0
        for item in items {
            if item.offsetMs > t { break }   // 有序：后面的都还没到点
            if shotIds.contains(item.id) { continue }
            guard t - item.offsetMs < 40_000 else { continue }   // 过期放弃（不标记）
            guard shot < 6 else { break }   // 单 tick 限量兜底
            let model = DanmakuTextCellModel(danmakuId: item.id.isEmpty ? "\(loadedVid)-\(shotIds.count)" : item.id,
                                             text: item.text,
                                             screenW: max(200, bounds.width))
            guard danmakuView.canShoot(danmaku: model) else { due += 1; continue }   // 轨道满：不标记，留待补射
            shotIds.insert(item.id)
            danmakuView.shoot(danmaku: model)
            shot += 1
        }
        if shot == 0 { emptyTicks += 1 } else { emptyTicks = 0 }
        if due > 0, emptyTicks >= 40 {   // 10s 零发射但仍有待射弹幕 = 轨道卡死 → 强制清轨自愈
            DiagnosticsLogger.log("DMJANITOR due=\(due) stall=\(emptyTicks) ticks -> clean", category: "danmaku", level: .debug)
            danmakuView.clean()
            emptyTicks = 0
        }
        syncTick += 1
        if syncTick % 16 == 0 {   // 每 4s 一条状态线（供真机日志定论空窗真因）
            DiagnosticsLogger.log("DMSYNC t=\(Int(t / 1000))s due=\(due) marked=\(shotIds.count) items=\(items.count) stall=\(emptyTicks)",
                                  category: "danmaku", level: .debug)
        }
    }
}

@MainActor
extension DanmakuOverlay: DanmakuViewDelegate {
    /// 轨道满被丢弃的弹幕（吞吐不足的直接量化）
    func danmakuView(_ danmakuView: DanmakuView, noSpaceShoot danmaku: DanmakuCellModel) {
        DiagnosticsLogger.log("DMDROP", category: "danmaku", level: .debug)
    }
}

// MARK: - SwiftUI 桥接（详情页全屏播放浮层用；推荐流走 PlayerCell 内嵌 overlay）

/// 弹幕层 SwiftUI 包装：跟随 player 播放态（KVO timeControlStatus）+ 换集取数。
struct DanmakuOverlayRepresentable: UIViewRepresentable {
    let player: AVPlayer?
    let vid: String
    let bookId: String?

    @MainActor
    func makeUIView(context: Context) -> DanmakuOverlay {
        let v = DanmakuOverlay(frame: .zero)
        v.bind(player: player)
        context.coordinator.obs = player?.observe(\.timeControlStatus, options: [.new]) { obj, _ in
            let playing = obj.timeControlStatus == .playing
            Task { @MainActor in
                v.syncPlaying(playing)
            }
        }
        return v
    }

    @MainActor
    func updateUIView(_ v: DanmakuOverlay, context: Context) {
        guard context.coordinator.lastVid != vid else { return }
        context.coordinator.lastVid = vid
        // duration 未就绪传 0 → DanmakuService 用兜底时长分窗（弹幕按播放时钟发射，无碍）
        let durMs = player.map { p -> Int in
            let s = p.currentItem?.duration.seconds ?? 0
            return (s.isFinite && s > 1) ? Int(s * 1000) : 0
        } ?? 0
        v.bind(player: player)
        v.load(vid: vid, bookId: bookId, durationMs: max(0, durMs))
    }

    final class Coordinator {
        var obs: NSKeyValueObservation?
        var lastVid = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
