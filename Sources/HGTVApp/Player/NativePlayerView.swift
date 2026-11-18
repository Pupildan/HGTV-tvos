// NativePlayerView.swift
// SwiftUI 桥接：把 DYPlayerViewController（UICollectionView 垂直分页 + AVPlayer 池）
// 包成 UIViewControllerRepresentable，塞进 ZStack。overlay（剧名/简介/加载态）由
// SwiftUI 侧用 zIndex 分层叠加，不放进 collection cell（cell 只管全屏视频+封面）。
// v25：转发遥控确认键（中键）→ 呼出底部功能弹窗（原「中键进详情」已取消）。

import SwiftUI

struct NativePlayerView: UIViewControllerRepresentable {
    let engine: PlaybackEngine
    /// 遥控确认键（中键 .select）→ 呼出底部功能弹窗。
    var onSelectKey: (() -> Void)? = nil
    /// 底部弹窗是否显示（v26）：显示时让底层 collectionView 退出焦点与交互。
    var panelActive: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> DYPlayerViewController {
        let vc = DYPlayerViewController(engine: engine)
        context.coordinator.controller = vc
        vc.onSelectKey = { onSelectKey?() }
        vc.setPanelActive(panelActive)
        return vc
    }

    func updateUIViewController(_ vc: DYPlayerViewController, context: Context) {
        // engine.items 增长时兜底同步（主路径由控制器 onNeedMore 自驱）
        vc.syncItemCount()
        // SwiftUI 重建 representable 时刷新回调闭包（捕获的是新副本）
        vc.onSelectKey = { onSelectKey?() }
        // v26：弹窗显示/隐藏同步到底层控制器（退出/恢复焦点与交互）
        vc.setPanelActive(panelActive)
    }

    final class Coordinator {
        weak var controller: DYPlayerViewController?
    }
}
