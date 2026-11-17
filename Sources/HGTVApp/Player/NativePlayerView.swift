// NativePlayerView.swift
// SwiftUI 桥接：把 DYPlayerViewController（UICollectionView 垂直分页 + AVPlayer 池）
// 包成 UIViewControllerRepresentable，塞进 ZStack。overlay（剧名/简介/加载态）由
// SwiftUI 侧用 zIndex 分层叠加，不放进 collection cell（cell 只管全屏视频+封面）。
// v22：转发遥控确认键（中键）→ 进入当前剧详情页。

import SwiftUI

struct NativePlayerView: UIViewControllerRepresentable {
    let engine: PlaybackEngine
    /// 遥控确认键（中键）→ 进入当前剧详情页。
    var onSelectSeries: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> DYPlayerViewController {
        let vc = DYPlayerViewController(engine: engine)
        context.coordinator.controller = vc
        vc.onSelectSeries = { sid, _ in onSelectSeries?(sid) }
        return vc
    }

    func updateUIViewController(_ vc: DYPlayerViewController, context: Context) {
        // engine.items 增长时兜底同步（主路径由控制器 onNeedMore 自驱）
        vc.syncItemCount()
        // SwiftUI 重建 representable 时刷新回调闭包（捕获的是新副本）
        vc.onSelectSeries = { sid, _ in onSelectSeries?(sid) }
    }

    final class Coordinator {
        weak var controller: DYPlayerViewController?
    }
}
