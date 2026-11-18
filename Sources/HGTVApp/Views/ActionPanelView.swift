// ActionPanelView.swift
// 全局底部功能弹窗（v26）。
// 遥控确认键（中键）呼出，屏幕底部居中液态玻璃面板，横向四个功能按钮：
// 选集 / 评论 / 弹幕开关 / 返回推荐。
// 本期接入「选集」「返回推荐」；评论、弹幕开关保留占位但同样可选中（点击暂无动作）。
//
// 焦点约定（v26 修正）：
//   - 出现时焦点落到首个可用按钮（defaultFocus + onAppear 双保险）；
//   - .focusSection() 把焦点困在弹窗内，配合宿主让底层 collectionView 退出焦点；
//   - 返回键用 SwiftUI 原生 .onExitCommand 关闭（tvOS 标准，仅当焦点属于本视图时触发）；
//   - 任何焦点移动/点击都重置 5s 无操作计时，到时自动关闭。

import SwiftUI

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

    var body: some View {
        ZStack {
            // 遮罩：点击空白处关闭（tvOS 触控板点击）
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

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
        .onAppear {
            focused = initialFocus
            idleTick += 1
        }
        .defaultFocus($focused, initialFocus)   // 视图出现时焦点兜底
        // tvOS 返回键标准处理：焦点在本视图时触发关闭（比 UITapGestureRecognizer 可靠）
        .onExitCommand(perform: onDismiss)
        // 焦点在按钮间移动 = 有操作，重置 idle 计时
        .onChange(of: focused) { _, _ in idleTick += 1 }
        // 5s 无操作自动隐藏；idleTick 变化会取消并重启计时
        .task(id: idleTick) {
            try? await Task.sleep(nanoseconds: UInt64(autoHideSeconds) * 1_000_000_000)
            onDismiss()   // View.task 闭包运行于 MainActor，可直接调用
        }
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
