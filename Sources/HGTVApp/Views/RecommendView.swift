// RecommendView.swift
// 推荐：抖音式竖向滑动即播。复用已打通的播放解密链路
//（fetchPlayback → 下载 → spade_a 派生密钥 → CENC 解密 → 本地代理 → AVPlayer）。
// tvOS 无触摸，用焦点驱动上下滚动 + .paging 吸附逐集切换，自动循环播放。
// 数据源：bookmall/tab 的金刚位剧目（唯一已打通的内容源），每集自带 vid。

import SwiftUI
import AVFoundation
import AVKit
import HGTVCore

@MainActor
@Observable
final class RecommendViewModel {
    var dramas: [DramaItem] = []
    var currentIndex = 0
    /// 滚动位置绑定（scrollPosition(id:) 需要 Hashable，用 drama.id）
    var currentIndexID: String?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    /// 无限 feed：已见 vid，去重累积（原 APK 机制：反复请求同一 URL，按 vid 去重追加）
    private var seenVids: Set<String> = []
    private let feedTabType = 8   // 找剧 tab（抖音式混合流）

    /// 共享播放器（竖向滑动切换集时复用同一个 AVPlayer）
    private(set) var player: AVPlayer?
    /// 每集缓存：vid → (本地代理, AVPlayerItem)，切换回来秒开
    private var cache: [String: (proxy: PlaybackProxy, item: AVPlayerItem)] = [:]
    private var playToEndObserver: NSObjectProtocol?
    private var playbackTask: Task<Void, Never>?

    public init() {}

    var currentDrama: DramaItem? {
        dramas.indices.contains(currentIndex) ? dramas[currentIndex] : nil
    }

    /// 首次加载：拉第一批 feed 并播放第一集
    func load() async {
        guard dramas.isEmpty else { return }
        await loadMore()
        if !dramas.isEmpty {
            currentIndexID = dramas[0].id
            await play(at: 0)
        }
    }

    /// 无限 feed：请求一批（服务端按 session 随机出 ~6 条），按 vid 去重后追加。
    /// 原 APK 无分页参数，靠反复请求累积。
    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let groups = try await APIService.shared.fetchHome(tabType: feedTabType)
            let batch = (groups.flatMap { $0.items ?? [] })
                .filter { drama in
                    guard let vid = drama.videoId, !vid.isEmpty else { return false }
                    guard !seenVids.contains(vid) else { return false }
                    seenVids.insert(vid)
                    return true
                }
            guard !batch.isEmpty else { return }
            let wasEmpty = dramas.isEmpty
            dramas.append(contentsOf: batch)
            if wasEmpty {
                currentIndexID = dramas[0].id
                await play(at: 0)
            }
        } catch {
            if dramas.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// 滚动预取：接近底部时加载更多
    func loadMoreIfNeeded(currentID: String?) async {
        guard let id = currentID,
              let idx = dramas.firstIndex(where: { $0.id == id }) else { return }
        if idx >= dramas.count - 3 {
            await loadMore()
        }
    }

    /// 滑动到某集：切播放器到对应缓存项
    func play(at index: Int) async {
        guard dramas.indices.contains(index) else { return }
        currentIndex = index
        currentIndexID = dramas[index].id
        guard let vid = dramas[index].videoId else { return }

        // 命中缓存直接换 item
        if let cached = cache[vid] {
            player = AVPlayer(playerItem: cached.item)
            player?.play()
            return
        }

        // 不取消进行中的下载：让 fetch/下载/解密跑完并写入缓存（秒开），
        // 末尾用 currentIndex 判断是否仍是当前集再切换播放器，避免快速滑动反复取消下载。
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 1) 取加密直链 + spade_a
                let stream = try await APIService.shared.fetchPlayback(vid: vid)
                DiagnosticsLogger.log("取流成功 vid=\(vid) spadeA.len=\(stream.spadeA.count) url=\(stream.url.absoluteString.prefix(90))", category: "playback", level: .info)
                guard !stream.spadeA.isEmpty else {
                    self.errorMessage = "未取到内容密钥 (spade_a)"
                    return
                }
                // 2) 下载加密 mp4
                let encrypted = try await APIService.shared.downloadData(from: stream.url)
                DiagnosticsLogger.log("下载加密 mp4 \(encrypted.count) 字节", category: "playback", level: .info)
                // 3) 派生密钥
                let key = try SpadeKey.deriveKey(stream.spadeA)
                DiagnosticsLogger.log("派生密钥 \(key.map { String(format: "%02x", $0) }.joined())", category: "playback", level: .info)
                // 4) 解密（后台线程）
                let plain = try await Task.detached(priority: .userInitiated) {
                    try CENCDecryptor.decrypt(data: encrypted, key: key)
                }.value
                DiagnosticsLogger.log("解密输出 \(plain.count) 字节 head=\(plain.prefix(12).map { String(format: "%02x", $0) }.joined())", category: "playback", level: .info)
                // 5) 本地代理托管明文
                let proxy = PlaybackProxy(payload: plain)
                let localURL = try await proxy.start()
                DiagnosticsLogger.log("本地代理 \(localURL.absoluteString)", category: "playback", level: .info)
                let item = AVPlayerItem(url: localURL)
                cache[vid] = (proxy, item)
                // 仍在当前集才切换（避免快速滑动竞态）
                guard self.currentIndex == index else { return }
                self.player = AVPlayer(playerItem: item)
                self.player?.play()
                DiagnosticsLogger.log("AVPlayer.play() 已调用 vid=\(vid)", category: "playback", level: .info)
                self.prefetchNext()
            } catch let e as HTTPError {
                DiagnosticsLogger.log("播放失败 HTTPError: \(e.errorDescription)", category: "playback", level: .error)
                self.errorMessage = e.errorDescription
            } catch let e as SpadeKeyError {
                DiagnosticsLogger.log("播放失败 SpadeKey: \(e.errorDescription)", category: "playback", level: .error)
                self.errorMessage = e.errorDescription
            } catch let e as CENCError {
                DiagnosticsLogger.log("播放失败 CENC: \(e.errorDescription)", category: "playback", level: .error)
                self.errorMessage = e.errorDescription
            } catch is CancellationError {
                DiagnosticsLogger.log("播放任务被取消", category: "playback", level: .warn)
            } catch {
                DiagnosticsLogger.log("播放失败: \(error.localizedDescription)", category: "playback", level: .error)
                self.errorMessage = error.localizedDescription
            }
        }
        await playbackTask?.value
    }

    /// 预加载下一集（后台解密，滑到时秒开）
    private func prefetchNext() {
        let next = currentIndex + 1
        guard dramas.indices.contains(next), let vid = dramas[next].videoId, cache[vid] == nil else { return }
        Task { [weak self] in
            // 解密放后台线程，缓存写入回主 actor（cache 是 main-actor 隔离的）
            guard let self else { return }
            do {
                let stream = try await APIService.shared.fetchPlayback(vid: vid)
                guard !stream.spadeA.isEmpty else { return }
                let encrypted = try await APIService.shared.downloadData(from: stream.url)
                let key = try SpadeKey.deriveKey(stream.spadeA)
                let plain = try await Task.detached(priority: .utility) {
                    try CENCDecryptor.decrypt(data: encrypted, key: key)
                }.value
                let proxy = PlaybackProxy(payload: plain)
                let localURL = try await proxy.start()
                let item = AVPlayerItem(url: localURL)
                self.cache[vid] = (proxy, item)
            } catch {
                // 预加载失败静默，滑到时再正式加载
            }
        }
    }

    /// 循环播放：播完自动重头
    func installLoopObserver() {
        guard playToEndObserver == nil else { return }
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let ended = note.object as? AVPlayerItem,
                  ended == self.player?.currentItem else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }
    }

    func stop() {
        playbackTask?.cancel()
        player?.pause()
        player = nil
        for (_, entry) in cache { entry.proxy.stop() }
        cache.removeAll()
        if let obs = playToEndObserver {
            NotificationCenter.default.removeObserver(obs)
            playToEndObserver = nil
        }
    }
}

struct RecommendView: View {
    @State private var model = RecommendViewModel()

    var body: some View {
        GeometryReader { geo in
            Group {
                if model.dramas.isEmpty && model.isLoading {
                    ProgressView("正在加载推荐…")
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let err = model.errorMessage, model.player == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "play.slash.fill").font(.system(size: 44))
                        Text("无法播放").font(.title2)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                        Button("重试") {
                            Task {
                                model.stop()
                                await model.load()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .glassEffect()
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.dramas, id: \.id) { drama in
                                feedPage(drama: drama, size: geo.size)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $model.currentIndexID)
                    .scrollTargetBehavior(.paging)
                    .ignoresSafeArea()
                    .onChange(of: model.currentIndexID) { _, newID in
                        guard let newID else { return }
                        if let idx = model.dramas.firstIndex(where: { $0.id == newID }) {
                            Task { await model.play(at: idx) }
                        }
                        // 无限 feed：接近底部自动加载更多
                        Task { await model.loadMoreIfNeeded(currentID: newID) }
                    }
                }
            }
        }
        .background(Color.black)
        .navigationTitle("推荐")
        .task {
            model.installLoopObserver()
            await model.load()
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private func feedPage(drama: DramaItem, size: CGSize) -> some View {
        let isCurrent = (drama.id == model.currentIndexID)
        return ZStack {
            Color.black
            // 仅当前页挂播放器（LazyVStack 按需渲染，非当前页复用同一个 AVPlayer）
            if isCurrent, let player = model.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .clipped()
            } else {
                // 非当前页显示封面占位
                AsyncImage(url: drama.thumbURL) { image in
                    image.resizable().aspectRatio(contentMode: ContentMode.fill)
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }

            // 底部剧名/简介（抖音式左下角信息）
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
                    if isCurrent && model.isLoading {
                        ProgressView()
                    }
                }
                .padding(28)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
