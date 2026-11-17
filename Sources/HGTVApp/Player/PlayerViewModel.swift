// PlayerViewModel.swift
// 播放层：使用 Apple 官方 AVPlayer（AVKit / AVFoundation）。
// 播放链路（忠实移植 Python 已验证解密链路）：
//   fetchPlayback(vid) 取加密 mp4 直链 + spade_a
//   → 下载加密 mp4
//   → SpadeKey.deriveKey(spade_a) 派生 AES-128 密钥
//   → CENCDecryptor 解密整段为明文 mp4
//   → PlaybackProxy 本地 HTTP 服务托管明文
//   → AVPlayer 播放本地 URL

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

    /// 持有本地代理（AVPlayer 播放期间不能释放）
    private var proxy: PlaybackProxy?

    public init() {}

    /// 播放单集：取流 → 下载 → 解密 → 本地代理 → AVPlayer
    public func play(vid: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // 1) 取加密直链 + spade_a
            let stream = try await APIService.shared.fetchPlayback(vid: vid)

            // 2) 下载加密 mp4
            let encrypted = try await APIService.shared.downloadData(from: stream.url)

            // 3) 派生 AES-128 内容密钥
            guard !stream.spadeA.isEmpty else {
                errorMessage = "未取到内容密钥 (spade_a)"
                return
            }
            let key = try SpadeKey.deriveKey(stream.spadeA)

            // 4) CENC-AES-CTR 整段解密（放到后台线程，避免阻塞主线程）
            let encForDecrypt = encrypted
            let keyForDecrypt = key
            let plain = try await Task.detached(priority: .userInitiated) {
                try CENCDecryptor.decrypt(data: encForDecrypt, key: keyForDecrypt)
            }.value

            // 5) 本地代理托管明文，返回 127.0.0.1 URL
            let payload = plain
            let newProxy = PlaybackProxy(payloadProvider: { payload })
            let localURL = try await newProxy.start()
            self.proxy?.stop()
            self.proxy = newProxy

            // 6) AVPlayer 播本地 URL
            let item = AVPlayerItem(url: localURL)
            player = AVPlayer(playerItem: item)
            player?.play()
        } catch let e as HTTPError {
            errorMessage = e.errorDescription
        } catch let e as SpadeKeyError {
            errorMessage = e.errorDescription
        } catch let e as CENCError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 取流/解密失败后重试（对应原「取流失败切换备用地址并自动重试」）
    public func retryWithNextHost(vid: String) async {
        stop()
        await play(vid: vid)
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func stop() {
        player?.pause()
        player = nil
        proxy?.stop()
        proxy = nil
    }
}
