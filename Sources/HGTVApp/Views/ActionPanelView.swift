// ActionPanelView.swift
// 全局底部功能弹窗（v26；v32 修选中效果/返回键/弹幕开关）。
// 遥控确认键（中键）呼出，屏幕底部居中液态玻璃面板，横向四个功能按钮：
// 选集 / 评论 / 弹幕开关 / 返回推荐。
//
// 焦点约定：
//   - 出现时焦点落到首个可用按钮（defaultFocus + onAppear 双保险）；
//   - .focusSection() 把焦点困在弹窗内，配合宿主让底层 collectionView 退出焦点；
//   - 返回键关闭用 .onExitCommand（v32 修复：v29 换成的 MenuDismiss 手势识别器
//     在 SwiftUI overlay 层级里收不到 menu press——识别器视图与焦点按钮不在同一条
//     responder 链上，按键穿透给系统直接退到桌面）。v29 发现的「打开后 25ms 杂散
//     exit 误关」由 500ms 冷却窗口（acceptDismiss）挡住，onExitCommand 本身是安全的；
//     MenuDismiss 保留兜底（两者幂等）。
//   - 选中效果（v32）：只保留系统圆角矩形焦点框。v31 的自绘白色胶囊与系统效果
//     双重叠加，按用户要求去掉自绘层（scaleEffect/focusEffectDisabled 一并去掉）。
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
            case .episodes, .backToRecommend, .danmaku: return true
            case .comment: return false
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
    /// 弹幕当前开关态（v32：按钮文案联动显示「弹幕开/弹幕关」）。
    var danmakuOn: Bool = true

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
        // v32：返回键关闭主通道。焦点在弹窗按钮上时 menu press 走这里（SwiftUI 官方语义），
        // v29 观察到的杂散触发已被冷却窗口挡住，不会再瞬间误关。
        .onExitCommand { requestDismiss(reason: "返回键") }
        .background(MenuDismiss { requestDismiss(reason: "返回键(手势兜底)") })
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
        // 5s 无操作自动隐藏；idleTick 变化会取消并重启计时。
        // 关键：sleep 被取消时 try? 会吞掉 CancellationError，必须显式检查
        // Task.isCancelled，否则每次焦点切换（idleTick+1 取消旧任务）都会
        // 误触发一次关闭——这正是「按钮间切换马上消失」的根因（v29）。
        .task(id: idleTick) {
            try? await Task.sleep(nanoseconds: UInt64(autoHideSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
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
        let isFocused = focused == action
        Button {
            idleTick += 1
            // 占位项可选中、可聚焦，但点击不触发业务动作；实功能项抛给宿主
            if action.implemented { onAction(action) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .font(.system(size: 28, weight: .medium))
                Text(displayTitle(for: action))
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.0))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)   // 关掉系统焦点效果，用自绘圆角矩形
        .focused($focused, equals: action)   // 所有按钮可聚焦可选中
    }

    /// 弹幕按钮文案联动开关态；其余按钮显示原名。
    private func displayTitle(for action: Action) -> String {
        if action == .danmaku { return danmakuOn ? "弹幕开" : "弹幕关" }
        return action.rawValue
    }
}
