// ActionPanelView.swift
// 全局底部功能弹窗（v24）。
// 遥控返回键（Menu / 新款顶部返回键，代码均为 .menu）在屏幕底部居中呼出，
// 横向排列四个功能按钮：选集 / 评论 / 弹幕开关 / 返回推荐。
// 本期接入「选集」「返回推荐」两个实功能；评论、弹幕开关占位（禁用焦点、灰显）。
//
// 焦点约定：弹窗出现时由宿主把焦点交给 firstFocused（默认首个可用按钮），
// 左右移动在可用按钮间切换；关闭由宿主统一处理（menu 键 / 点击遮罩），
// 组件不自行拦截 menu，以免与播放器 DYPlayerViewController 的按键处理冲突。

import SwiftUI

struct ActionPanelView: View {
    /// 弹窗里的功能项。占位项 notImplemented=true，禁用交互。
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

        /// 尚未接入：禁用按钮与焦点，避免用户点了没反应。
        var implemented: Bool {
            switch self {
            case .episodes, .backToRecommend: return true
            case .comment, .danmaku: return false
            }
        }
    }

    let onAction: (Action) -> Void
    /// 点击遮罩关闭（menu 键关闭由宿主统一拦截）。
    let onDismiss: () -> Void
    /// 首个聚焦项（宿主可指定进入弹窗时的落点，默认「选集」）。
    var initialFocus: Action = .episodes

    @FocusState private var focused: Action?

    var body: some View {
        ZStack {
            // 遮罩：点击空白处关闭（tvOS 上点击手势来自触控板；遥控走宿主的 menu 拦截）
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
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .glassEffect()               // tvOS 26 液态玻璃
                .padding(.bottom, 80)
            }
        }
        .onAppear { focused = initialFocus }
        // defaultFocus：视图刚出现时 focus 引擎可能还没就绪，onAppear 里赋值偶发失效，
        // 由 defaultFocus 兜底保证焦点落到首个可用按钮（tvOS 17+）。
        .defaultFocus($focused, initialFocus)
        // 弹窗显示期间焦点在本视图，menu 键不会传到底层 DYPlayerViewController，
        // 故由这里的 MenuDismiss 负责关闭（与播放器 onMenuKey 互斥，不会重复触发）。
        .background(MenuDismiss { onDismiss() })
    }

    @ViewBuilder
    private func button(for action: Action) -> some View {
        Button {
            guard action.implemented else { return }
            onAction(action)
        } label: {
            VStack(spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.system(size: 40, weight: .medium))
                Text(action.rawValue)
                    .font(.body.weight(.semibold))
                if !action.implemented {
                    Text("待接入")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 120)
            .foregroundStyle(action.implemented ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: action)
        .disabled(!action.implemented)
    }
}
