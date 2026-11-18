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
//
// overlay 行为（v19）：
//   - 剧名/简介：白色 + 阴影（深色视频画面上可读），标题 1 行、简介 2 行精简显示；
//   - 每次换集重新显示，5 秒后淡出（不遮画面）；
//   - 居中加载圈只在等待首帧时出现，最多 3 秒兜底消失（防止首帧信号丢失导致永远转圈）。

import SwiftUI
import HGTVCore

struct RecommendView: View {
    @Environment(AppModel.self) private var appModel
    @State private var engine = PlaybackEngine()
    /// 底部信息条是否可见（换集重置，5 秒后淡出）。
    @State private var infoVisible = true
    /// 居中加载圈兜底开关（3 秒强制关闭）。
    @State private var spinnerVisible = true
    /// 剧集详情（nil=不显示）。v25：由底部弹窗的「选集」按钮进入（不再用中键直接进）。
    @State private var detailSeriesId: String?
    /// 打开详情时的剧信息（选集后回填到连播标题/封面）。
    @State private var detailDrama: DramaItem?
    /// 底部功能弹窗是否显示（v24：遥控返回键呼出）。
    @State private var actionPanelVisible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 全屏分页播放器（底层）
            NativePlayerView(engine: engine,
                             onSelectKey: {
                                 // 中键呼出弹窗（v25）；返回键交还系统，不再拦。
                                 // 关闭由 ActionPanelView 的 onExitCommand / 遮罩 / 5s 计时处理。
                                 if !actionPanelVisible {
                                     withAnimation { actionPanelVisible = true }
                                 }
                             },
                             panelActive: actionPanelVisible)   // v26：弹窗显示时底层让出焦点
                .ignoresSafeArea()
                .zIndex(0)

            // 顶层 overlay：加载态 / 错误 / 底部剧名简介（非可聚焦，避免焦点锁死）
            overlay
                .ignoresSafeArea()
                .zIndex(1)
        }
        .background(Color.black)
        .navigationTitle("推荐")
        .fullScreenCover(isPresented: Binding(
            get: { detailSeriesId != nil },
            set: { if !$0 { detailSeriesId = nil } }
        )) {
            if let sid = detailSeriesId {
                DramaDetailView(
                    item: detailDrama ?? DramaItem(bookId: nil, videoId: nil, seriesId: sid,
                                                   title: nil, thumbURL: nil, description: nil,
                                                   category: nil, playCount: nil, score: nil),
                    currentVid: engine.currentVid,
                    onPickInPlayer: { vids, index in
                        let drama = detailDrama
                        engine.playSeries(seriesId: sid,
                                          title: drama?.title,
                                          coverURL: drama?.thumbURL,
                                          vids: vids, startIndex: index)
                        detailSeriesId = nil
                    }
                )
            }
        }
        .task(id: engine.currentVid) {
            // 换集（含首次出现）：信息条重现 5 秒 → 淡出；转圈 3 秒兜底关闭。
            // task(id:) 在 currentVid 变化时重跑，正好覆盖"每次换集重新计时"。
            infoVisible = true
            spinnerVisible = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            spinnerVisible = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.4)) {
                infoVisible = false
            }
        }
        .overlay {
            if actionPanelVisible {
                ActionPanelView(
                    onAction: { action in handlePanelAction(action) },
                    onDismiss: { withAnimation { actionPanelVisible = false } }
                )
                .zIndex(3)
                .transition(.opacity)
            }
        }
        // v24：刷推荐流/播放时隐藏顶部 tab 条；呼出功能弹窗或离开时恢复，便于切 tab
        .onAppear { appModel.tabBarHidden = true }
        .onChange(of: actionPanelVisible) { _, visible in
            appModel.tabBarHidden = visible ? false : true
            // 详情页打开时也恢复导航（详情页是 fullScreenCover，tab 条本就不可见）
            if detailSeriesId != nil { appModel.tabBarHidden = false }
        }
        // v24：从推荐流进的详情页，收到「返回推荐」时收起
        .onReceive(NotificationCenter.default.publisher(for: .hgtvReturnToRecommend)) { _ in
            Task { @MainActor in
                detailSeriesId = nil
                actionPanelVisible = false
                appModel.tabBarHidden = true
            }
        }
        .onDisappear {
            appModel.tabBarHidden = false
            DiagnosticsLogger.log("RecommendView 消失", category: "playback", level: .info)
        }
    }

    // MARK: - 底部弹窗动作（v24）

    private func handlePanelAction(_ action: ActionPanelView.Action) {
        withAnimation { actionPanelVisible = false }
        switch action {
        case .episodes:
            // 选集：复用中键的详情页路径（拉详情 → 分页选集网格 → 整表替换连播）
            guard let sid = engine.currentDrama?.seriesId, !sid.isEmpty else {
                DiagnosticsLogger.warn("弹窗选集：当前剧无 seriesId，忽略")
                return
            }
            detailDrama = engine.currentDrama
            detailSeriesId = sid
        case .backToRecommend:
            // 返回推荐：重新拉推荐流并回到第 0 条
            Task { await engine.returnToRecommendFeed() }
        case .comment, .danmaku:
            break // 占位，ActionPanelView 已禁用交互
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
        } else if engine.hasLoaded, spinnerVisible, !engine.firstFrameReady {
            // 首帧未到：居中加载圈（封面由 PlayerCell 兜底显示）。
            // 3 秒兜底：即使 isReadyForDisplay 信号丢失也不会永远转圈。
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // 底部剧名/简介（抖音式左下角信息），仅非空且未到隐藏时间时叠加
        if let drama = engine.currentDrama, infoVisible {
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(drama.title ?? "未知短剧")
                            .font(.title3).bold()
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                        if let desc = drama.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                        }
                    }
                    Spacer()
                }
                .padding(28)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }
}
