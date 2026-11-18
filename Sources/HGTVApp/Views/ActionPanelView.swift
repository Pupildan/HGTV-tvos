// ActionPanelView.swift
// 全局底部功能弹窗（v26）。
// 遥控确认键（中键）呼出，屏幕底部居中液态玻璃面板，横向四个功能按钮：
// 选集 / 评论 / 弹幕开关 / 返回推荐。
// 本期接入「选集」「返回推荐」；评论、弹幕开关保留占位但同样可选中（点击暂无动作）。
//
// 焦点约定（v26 修正）：
//   - 出现时焦点落到首个可用按钮（defaultFocus + onAppear 双保险）；
//   - .focusSection() 把焦点困在弹窗内，配合宿主让底层 collectionView 退出焦点；
//   - 返回键用 MenuDismiss 手势识别器关闭（v29：弃用 .onExitCommand——
//     真机日志证实它在焦点转移时会误触发，导致弹窗打开后 25ms 内被瞬间关闭）；
//   - 出现后 500ms 内忽略一切 dismiss 请求（冷却窗口，挡住同一次按键的
//     touch-up 被新遮罩手势误判、以及焦点转移期间的杂散 exit 事件）；
//   - 任何焦点移动/点击都重置 5s 无操作计时，到时自动关闭。

import SwiftUI
import HGTVCore

struct ActionPanelView: View {
    /// 弹窗功能项。占位项 implemented=false：可选中、可聚焦，但点击暂无实际功能。
    enum Action: String, CaseIterable, Identifiable {
        case episodes = "选集"
        case comment = "评论"
        case danmaku = "弹幕开关"
        case backToRecommend = "返回推荐"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .episodes: return "square.grid.2x2.fill"
            case .comment: return "bubble.left.and.bubble.right.fill"
            case .danmaku: return "captions.bubble.fill"
            case .backToRecommend: return "arrow.uturn.left.circle.fill"
            }
        }

        /// 已接入实功能；占位项仍可选中，只是点击不触发 onAction。
        var implemented: Bool {
            switch self {
            case .episodes, .backToRecommend: return true
            case .comment, .danmaku: return false
            }
        }
    }

    let onAction: (Action) -> Void
    /// 关闭弹窗（返回键 / 点击遮罩 / 5s 无操作都会调用）。
    let onDismiss: () -> Void
    /// 首个聚焦项，默认「选集」。
    var initialFocus: Action = .episodes
    /// 无操作自动隐藏秒数（默认 5s）。
    var autoHideSeconds: Int = 5

    @FocusState private var focused: Action?
    /// 每次交互自增，用于重启 idle 计时。
    @State private var idleTick = 0
    /// 出现冷却：true 之后才接受 dismiss（v29 防瞬间误关）。
    @State private var acceptDismiss = false

    var body: some View {
        ZStack {
            // 遮罩：点击空白处关闭（tvOS 触控板点击）
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { requestDismiss(reason: "遮罩点击") }

            VStack {
                Spacer()
                HStack(spacing: 28) {
                    ForEach(Action.allCases) { action in
                        button(for: action)
                    }
                }
                .focusSection()                 // 焦点困在弹窗按钮组内
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .glassEffect()                  // tvOS 26 液态玻璃
                .padding(.bottom, 80)
            }
        }
        .background(MenuDismiss { requestDismiss(reason: "返回键") })
        .onAppear {
            focused = initialFocus
            idleTick += 1
            DiagnosticsLogger.log("弹窗出现，冷却开始", category: "playback", level: .debug)
        }
        .defaultFocus($focused, initialFocus)   // 视图出现时焦点兜底
        // 焦点在按钮间移动 = 有操作，重置 idle 计时
        .onChange(of: focused) { _, newValue in
            idleTick += 1
            DiagnosticsLogger.log("弹窗焦点=\(newValue?.rawValue ?? "nil")", category: "playback", level: .debug)
        }
        // 出现 500ms 后开始接受 dismiss（冷却窗口结束）
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            acceptDismiss = true
            DiagnosticsLogger.log("弹窗冷却结束，开始接受关闭", category: "playback", level: .debug)
        }
        // 5s 无操作自动隐藏；idleTick 变化会取消并重启计时
        .task(id: idleTick) {
            try? await Task.sleep(nanoseconds: UInt64(autoHideSeconds) * 1_000_000_000)
            requestDismiss(reason: "5s无操作")
        }
    }

    /// 统一的 dismiss 入口：冷却期内一律忽略（防止出现瞬间的杂散事件误关弹窗）。
    private func requestDismiss(reason: String) {
        guard acceptDismiss else {
            DiagnosticsLogger.log("弹窗忽略冷却期内 dismiss(\(reason))", category: "playback", level: .debug)
            return
        }
        DiagnosticsLogger.log("弹窗关闭(\(reason))", category: "playback", level: .debug)
        onDismiss()
    }

    @ViewBuilder
    private func button(for action: Action) -> some View {
        Button {
            idleTick += 1
            // 占位项可选中、可聚焦，但点击不触发业务动作；实功能项抛给宿主
            if action.implemented { onAction(action) }
        } label: {
            VStack(spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.system(size: 40, weight: .medium))   // 图标统一大小
                Text(action.rawValue)
                    .font(.body.weight(.semibold))
            }
            .frame(width: 180, height: 120)
            .foregroundStyle(.primary)                          // 占位项也用主色，不再灰显
        }
        .buttonStyle(.plain)
        .focused($focused, equals: action)                      // 所有按钮可聚焦可选中
    }
}
