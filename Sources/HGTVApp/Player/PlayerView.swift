// PlayerView.swift
// 播放页：Apple 官方 AVPlayer + AVKit。tvOS 规范下用系统传输控件
// （VideoPlayer 提供 play/pause/进度/倍速），焦点自动落到播放器。

import SwiftUI
import AVKit
import HGTVCore

struct PlayerView: View {
    let item: DramaItem
    @State private var playerModel = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playerModel.player {
                // 系统播放器：自带 tvOS 传输控件（进度、暂停、倍速、字幕）
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if playerModel.isLoading {
                ProgressView("正在取流…")
            } else if let err = playerModel.errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "play.slash.fill").font(.system(size: 48))
                    Text("无法播放").font(.title2)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        Button("换备用地址重试") {
                            Task { await playerModel.retryWithNextHost(itemId: item.id) }
                        }
                        Button("返回") { dismiss() }
                    }
                }
                .padding(40)
                .glassEffect()
                .cornerRadius(20)
            }
        }
        .navigationTitle(item.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await playerModel.play(itemId: item.id) }
        }
        .onDisappear {
            playerModel.stop()
        }
    }
}