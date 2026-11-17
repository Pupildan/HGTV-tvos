// DramaDetailView.swift
// 剧集详情 + 选集网格（v22 重写）。
// 数据源：红果短剧 web /detail?series_id=（HongguoWeb，一次拿全量 vid_list——番茄原
// video_detail/v1 被风控门控不可用）。
// 布局参考 PC 端详情页 + tvOS 焦点优化：
//   - 上方：左侧海报、右侧剧名/标签/热度/简介（PC 端横排结构）
//   - 下方：全量集数网格（LazyVGrid + focusSection，当前集高亮，遥控焦点驱动）
//   - 背景：海报大图模糊铺满（自带环境色）+ CIAreaAverage 取主色做氛围渐变
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
    @State private var focusedEpisode: Int?
    @State private var playingVid: VidRef?

    struct VidRef: Identifiable, Equatable {
        let id: String
    }

    var body: some View {
        ZStack {
            background
            if let detail {
                content(detail)
            } else if let err = loadError {
                errorView(err)
            } else {
                ProgressView("正在加载剧集信息…")
            }
        }
        .background(Color.black)
        .task { await load() }
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

    private func content(_ d: SeriesDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 36) {
                    poster
                    infoColumn(d)
                    Spacer(minLength: 0)
                }
                Divider().overlay(Color.white.opacity(0.18))
                episodeSection(d)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 40)
        }
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
        .frame(width: 300, height: 400)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("选集").font(.title2.bold()).foregroundStyle(.white)
                Text(d.episodeText ?? "共 \(d.vidList.count) 集")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 18)], spacing: 18) {
                ForEach(Array(d.vidList.enumerated()), id: \.offset) { idx, vid in
                    episodeButton(index: idx, vid: vid, current: d)
                }
            }
            .focusSection()
        }
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
        .focused($focusedEpisode, value: idx)
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
            let initialFocus: Int? = currentVid.flatMap { cv in d.vidList.firstIndex(of: cv) }
            detail = d
            focusedEpisode = initialFocus
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
        .background(MenuDismiss { dismiss() })
        .task { await viewModel.play(vid: vid) }
        .onDisappear { viewModel.stop() }
    }
}

/// Menu 键关闭播放浮层（拦截 menu 按压后手动 dismiss）。
struct MenuDismiss: UIViewRepresentable {
    let onMenu: () -> Void

    func makeUIView() -> MenuCatchView { MenuCatchView() }
    func updateUIView(_ v: MenuCatchView) { v.onMenu = onMenu }

    final class MenuCatchView: UIView {
        var onMenu: () -> Void = {}
        override init(frame: CGRect) {
            super.init(frame: frame)
            let t = UITapGestureRecognizer(target: self, action: #selector(menuTapped))
            t.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            addGestureRecognizer(t)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
        @objc private func menuTapped() { onMenu() }
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
