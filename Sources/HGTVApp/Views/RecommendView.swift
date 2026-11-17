// RecommendView.swift
// 推荐：抖音式竖向滑动即播。按 DYTV 参考架构重构播放/切换层：
//   SwiftUI RecommendView (ZStack + overlay 分层)
//     └─ NativePlayerView (UIViewControllerRepresentable)
//          └─ DYPlayerViewController (UICollectionView 垂直分页 + 手动 snap + 遥控)
//               ├─ PlayerManager (AVPlayer 池 ±2 窗口)
//               └─ PlayerCell (playerLayerView + 封面兜底，不持 player)
// 数据源/解密链路复用现有实现（fetchHome / fetchPlayback / 下载 / SpadeKey / CENC / PlaybackProxy），
// 由 PlaybackEngine.resolveLocalURL 封装成给 PlayerManager 的 resolve 闭包。
// 旧 GeometryReader/ScrollView/LazyVStack 分页 + 手挂 AVPlayerLayer（画面残缺）已删除。

import SwiftUI
import HGTVCore

struct RecommendView: View {
    @State private var engine = PlaybackEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 全屏分页播放器（底层）
            NativePlayerView(engine: engine)
                .ignoresSafeArea()
                .zIndex(0)

            // 顶层 overlay：加载态 / 错误 / 底部剧名简介（非可聚焦，避免焦点锁死）
            overlay
                .ignoresSafeArea()
                .zIndex(1)
        }
        .background(Color.black)
        .navigationTitle("推荐")
        .onDisappear {
            DiagnosticsLogger.log("RecommendView 消失", category: "playback", level: .info)
        }
    }

    // MARK: - overlay 分层

    @ViewBuilder
    private var overlay: some View {
        if !engine.hasLoaded, engine.isLoading {
            // 首批 feed 加载中
            ProgressView("正在加载推荐…")
        } else if !engine.hasLoaded, let err = engine.errorMessage {
            // 启动失败：可重试（此时无播放，允许出现可聚焦按钮）
            VStack(spacing: 16) {
                Image(systemName: "play.slash.fill").font(.system(size: 44))
                Text("无法加载推荐").font(.title2)
                Text(err).font(.caption).foregroundStyle(.secondary)
                Button("重试") {
                    Task { await engine.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .glassEffect()
        } else if engine.hasLoaded, !engine.firstFrameReady {
            // 首帧未到：居中加载圈（封面由 PlayerCell 兜底显示）
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // 底部剧名/简介（抖音式左下角信息），仅非空时叠加
        if let drama = engine.currentDrama {
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(drama.title ?? "未知短剧")
                            .font(.title3).bold()
                            .lineLimit(2)
                        if let desc = drama.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(28)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
