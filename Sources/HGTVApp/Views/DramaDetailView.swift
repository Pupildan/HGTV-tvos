// DramaDetailView.swift
// 剧集详情 + 选集网格（v24 改版：固定头部 + 100 集动态分页）。
// 数据源：红果短剧 web /detail?series_id=（HongguoWeb，一次拿全量 vid_list——番茄原
// video_detail/v1 被风控门控不可用）。
// 布局（v24）：
//   - 顶部固定区（约 1/3 高，不随焦点滚动）：左侧海报、右侧剧名/标签/热度/简介。
//     tvOS 焦点引擎会把聚焦的选集按钮自动滚进可视区，若头部与网格同处一个 ScrollView，
//     头部会被顶出屏幕——故头部独立、只有选集区滚动。
//   - 选集区分页：每页固定 100 集，页数由真实集数决定（末页取实际剩余），
//     分页条胶囊可聚焦、遥控左右翻页；进详情页按「当前在播集」定位到对应页并高亮。
//   - 背景：海报大图模糊铺满 + CIAreaAverage 取主色做氛围渐变。
// 交互：点任意集 →
//   - 播放器内入口（onPickInPlayer）：整表替换 feed 回刷集模式连播（A1 衔接）
//   - 其他 tab 入口：内置全屏播放浮层（PlayerViewModel 管线 + AVPlayerViewController）

import SwiftUI
import UIKit
import AVKit
import CoreImage
import HGTVCore

struct DramaDetailView: View {
    let item: DramaItem
    /// 当前正在播的 vid（高亮「正在播放」）；tab 入口时为 nil。
    var currentVid: String? = nil
    /// 播放器内入口：选集后整表替换 feed 并由调用方关闭详情。
    var onPickInPlayer: ((_ vids: [String], _ index: Int) -> Void)? = nil

    @State private var detail: SeriesDetail?
    @State private var loadError: String?
    @State private var coverImage: UIImage?
    @State private var ambientColor: Color = Color(red: 0.09, green: 0.09, blue: 0.13)
    @FocusState private var focusedEpisode: Int?
    @State private var playingVid: VidRef?

    // v24 分页：0-based 页码，每页 100 集；页数由 vidList 真实数量决定。
    @State private var page: Int = 0
    private let pageSize = 100
    @Environment(\.dismiss) private var dismiss

    struct VidRef: Identifiable, Equatable {
        let id: String
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                if let detail {
                    VStack(spacing: 0) {
                        // 固定头部（约 1/3 高）——不参与选集滚动
                        header(detail)
                            .frame(height: geo.size.height / 3)
                        // 选集区（剩余 2/3）——只有这里滚动
                        episodeArea(detail)
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.horizontal, 64)
                } else if let err = loadError {
                    errorView(err)
                } else {
                    ProgressView("正在加载剧集信息…")
                }
            }
        }
        .background(Color.black)
        .task { await load() }
        // v24：详情页浮层点「返回推荐」后，本详情页也一并收起（若以 fullScreenCover 呈现）
        .onReceive(NotificationCenter.default.publisher(for: .hgtvReturnToRecommend)) { _ in
            Task { @MainActor in dismiss() }
        }
        .fullScreenCover(item: $playingVid) { ref in
            EpisodePlayerSheet(vid: ref.id)
        }
    }

    // MARK: - 背景（海报取色 + 模糊）

    private var background: some View {
        ZStack {
            if let img = coverImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 42)
                    .overlay(ambientColor.opacity(0.35))
                    .clipped()
            } else {
                ambientColor
            }
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.55), .black.opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - 内容

    /// 固定头部：海报 + 信息，高度由外层约束为约 1/3 屏，不再随焦点滚动。
    private func header(_ d: SeriesDetail) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 36) {
                poster
                infoColumn(d)
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.white.opacity(0.18))
        }
        .padding(.top, 24)
    }

    /// 选集区：分页条 + 当前页网格，独立滚动。
    private func episodeArea(_ d: SeriesDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            pageBar(d)
            ScrollView(.vertical) {
                episodeSection(d)
            }
        }
        .padding(.vertical, 12)
    }

    /// 分页条：按真实集数动态生成页签（每页 100 集，末页为实际剩余）。
    /// 例：350 集 → 1-100 / 101-200 / 201-300 / 301-350；60 集 → 1-60（单页）。
    private func pageBar(_ d: SeriesDetail) -> some View {
        let total = d.vidList.count
        let pages = max(1, (total + pageSize - 1) / pageSize)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<pages, id: \.self) { p in
                    let start = p * pageSize + 1
                    let end = min((p + 1) * pageSize, total)
                    Button {
                        page = p
                    } label: {
                        Text("\(start)-\(end)")
                            .font(.callout.bold())
                            .foregroundStyle(p == page ? .white : .white.opacity(0.75))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(p == page ? Color.white.opacity(0.22) : Color.white.opacity(0.09))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(start) 到 \(end) 集")
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 52)
    }

    private var poster: some View {
        Group {
            if let img = coverImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let url = item.thumbURL ?? detail?.coverURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.08) }
                }
            } else {
                Color.white.opacity(0.08).overlay(ProgressView())
            }
        }
        // v24：按固定头部可用高度自适应（3:4），不再用固定 300x400 以免撑出 1/3 区域。
        .aspectRatio(3/4, contentMode: .fit)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private func infoColumn(_ d: SeriesDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(d.name ?? item.title ?? "未知剧集")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 5, y: 1)
                .lineLimit(2)

            if !d.tags.isEmpty {
                HStack(spacing: 10) {
                    ForEach(d.tags.prefix(6), id: \.self) { tag in
                        Text(tag)
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }

            if let meta = metaLine(d) {
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }

            let intro = d.intro ?? item.description
            if let intro, !intro.isEmpty {
                Text(intro)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(6)
                    .lineLimit(6)
            }
        }
    }

    private func metaLine(_ d: SeriesDetail) -> String? {
        var parts: [String] = []
        if let e = d.episodeText { parts.append(e) }
        if let h = d.hotText { parts.append(h) }
        if let r = d.rankLabel { parts.append(r) }
        if let l = d.likeText, !l.isEmpty { parts.append("点赞 \(l)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func episodeSection(_ d: SeriesDetail) -> some View {
        let total = d.vidList.count
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let safePage = min(max(0, page), pages - 1)
        let start = safePage * pageSize
        let end = min(start + pageSize, total)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("选集").font(.title2.bold()).foregroundStyle(.white)
                Text(d.episodeText ?? "共 \(total) 集")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 18)], spacing: 18) {
                ForEach(start..<end, id: \.self) { idx in
                    episodeButton(index: idx, vid: d.vidList[idx], current: d)
                }
            }
            .focusSection()
        }
        .padding(.bottom, 24)
    }

    private func episodeButton(index idx: Int, vid: String, current: SeriesDetail) -> some View {
        let isCurrent = (vid == currentVid)
        return Button {
            if let onPickInPlayer {
                onPickInPlayer(current.vidList, idx)
            } else {
                playingVid = VidRef(id: vid)
            }
        } label: {
            Text("第 \(idx + 1) 集")
                .font(.callout.bold())
                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isCurrent ? AnyShapeStyle(ambientColor.opacity(0.8))
                                        : AnyShapeStyle(Color.white.opacity(0.09)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isCurrent ? Color.white : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.card)
        .focused($focusedEpisode, equals: idx)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.tv").font(.system(size: 44))
            Text("加载失败").font(.title2)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .glassEffect()
    }

    // MARK: - 数据

    private func load() async {
        do {
            let d = try await HongguoWeb.fetchSeriesDetail(seriesId: item.seriesId ?? "")
            let initialIndex: Int? = currentVid.flatMap { cv in d.vidList.firstIndex(of: cv) }
            // v24 智能定位：当前在播集落在第几页（每页 100 集），就先打开那一页。
            if let idx = initialIndex {
                page = idx / pageSize
            } else {
                page = 0
            }
            detail = d
            focusedEpisode = initialIndex
            if let url = d.coverURL, coverImage == nil {
                let img = try? await Self.fetchImage(url)
                if let img {
                    coverImage = img
                    if let c = Self.dominantColor(img) {
                        ambientColor = c
                    }
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func fetchImage(_ url: URL) async throws -> UIImage {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let img = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return img
    }

    /// CIAreaAverage 取整图平均色（= 海报主色），用于背景氛围渐变。
    static func dominantColor(_ image: UIImage) -> Color? {
        guard let ci = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: kCFNull as Any])
        ctx.render(output, toBitmap: &pixel, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        return Color(red: Double(pixel[0]) / 255.0,
                     green: Double(pixel[1]) / 255.0,
                     blue: Double(pixel[2]) / 255.0)
    }
}

// MARK: - 其他 tab 入口的内置全屏播放（PlayerViewModel 管线）

/// 从详情页点选集（非播放器入口）时的全屏播放浮层。
struct EpisodePlayerSheet: View {
    let vid: String
    @State private var viewModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss
    /// v25：遥控中键（.select）呼出底部功能弹窗；返回键交还系统做正常返回/关闭浮层。
    @State private var panelVisible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeEpisodePlayerView(viewModel: viewModel)
                .ignoresSafeArea()
            if viewModel.isLoading {
                ProgressView("正在加载本集…")
            }
            if let err = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Text(err).font(.callout).foregroundStyle(.white)
                    Button("重试") { Task { await viewModel.play(vid: vid) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        // v25：中键（.select）呼出弹窗；返回键 .menu 不再拦——交还系统正常返回/关闭浮层。
        // 弹窗开着时，关闭由 ActionPanelView 内的 MenuDismiss（.menu）负责，二者分工不冲突。
        .background(MenuDismiss(pressType: .select) {
            if !panelVisible {
                withAnimation { panelVisible = true }
            }
        })
        .overlay {
            if panelVisible {
                ActionPanelView(
                    onAction: { action in handleAction(action) },
                    onDismiss: { withAnimation { panelVisible = false } },
                    initialFocus: .episodes
                )
                .transition(.opacity)
            }
        }
        .task { await viewModel.play(vid: vid) }
        .onDisappear { viewModel.stop() }
    }

    private func handleAction(_ action: ActionPanelView.Action) {
        withAnimation { panelVisible = false }
        switch action {
        case .episodes:
            // 选集：本浮层从详情页弹出，关闭浮层即可回到下面的分页选集网格
            dismiss()
        case .backToRecommend:
            // 返回推荐：关浮层 + 通知各层收起详情、切回推荐 tab
            dismiss()
            NotificationCenter.default.post(name: .hgtvReturnToRecommend, object: nil)
        case .comment, .danmaku:
            break
        }
    }
}

/// 遥控按键捕获器（拦截指定按键并回调）。
/// 默认 .menu：用于关闭弹窗/浮层；可传 .select：用于中键呼出弹窗（v25）。
struct MenuDismiss: UIViewRepresentable {
    let onMenu: () -> Void
    /// 要捕获的按键类型，默认返回键 .menu。
    var pressType: UIPress.PressType = .menu

    func makeUIView(context: Context) -> MenuCatchView {
        MenuCatchView(pressType: pressType)
    }
    func updateUIView(_ v: MenuCatchView, context: Context) { v.onMenu = onMenu }

    final class MenuCatchView: UIView {
        var onMenu: () -> Void = {}
        let pressType: UIPress.PressType

        init(pressType: UIPress.PressType) {
            self.pressType = pressType
            super.init(frame: .zero)
            let t = UITapGestureRecognizer(target: self, action: #selector(keyPressed))
            t.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            addGestureRecognizer(t)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
        @objc private func keyPressed() { onMenu() }
    }
}

/// AVPlayerViewController 包装（tvOS 渲染可靠路径，坑 8 的结论）。
struct NativeEpisodePlayerView: UIViewControllerRepresentable {
    let viewModel: PlayerViewModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = viewModel.player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== viewModel.player {
            vc.player = viewModel.player
        }
    }
}
