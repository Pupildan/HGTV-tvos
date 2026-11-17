// NativePlayerView.swift
// SwiftUI 桥接：把 DYPlayerViewController（UICollectionView 垂直分页 + AVPlayer 池）
// 包成 UIViewControllerRepresentable，塞进 ZStack。overlay（剧名/简介/加载态）由
// SwiftUI 侧用 zIndex 分层叠加，不放进 collection cell（cell 只管全屏视频+封面）。

import SwiftUI

struct NativePlayerView: UIViewControllerRepresentable {
    let engine: PlaybackEngine

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> DYPlayerViewController {
        let vc = DYPlayerViewController(engine: engine)
        context.coordinator.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: DYPlayerViewController, context: Context) {
        // engine.items 增长时兜底同步（主路径由控制器 onNeedMore 自驱）
        vc.syncItemCount()
    }

    final class Coordinator {
        weak var controller: DYPlayerViewController?
    }
}
