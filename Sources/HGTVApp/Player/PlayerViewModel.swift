// PlayerViewModel.swift
// 播放层：使用 Apple 官方 AVPlayer（AVKit / AVFoundation）。
// 原 APK 用 ExoPlayer，tvOS 规范要求用系统播放器，故替换为 AVPlayer，
// 但取流逻辑（video_model → CDN 直链 + 候选域名容灾）严格复用原链路。

import Foundation
import AVFoundation
import HGTVCore

@MainActor
@Observable
public final class PlayerViewModel {
    public private(set) var player: AVPlayer?
    public private(set) var currentQuality: String?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// 候选播放域名（对应原 tncHosts + apiHosts 容灾）
    private var candidateHosts: [String] = HGTVConfig.Host.tncHosts

    public init() {}

    /// 播放单集：先取播放模型，再建 AVPlayer
    public func play(itemId: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let model = try await APIService.shared.fetchVideoModel(itemId: itemId)
            guard let url = model.videoURL else {
                errorMessage = "未取到播放地址"
                return
            }
            // CDN 直链带时效（对应 StreamExpiredException）
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            player?.play()
        } catch let e as HTTPError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 取流失败换候选域名重试（对应原「取流失败切换候选域名与备用地址并自动重试」）
    public func retryWithNextHost(itemId: String) async {
        guard !candidateHosts.isEmpty else { return }
        candidateHosts.removeFirst()
        await play(itemId: itemId)
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func stop() {
        player?.pause()
        player = nil
    }
}