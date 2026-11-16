// LocalLibrary.swift
// 本机收藏 / 观看记录 / 稍后看。对应原 APK「收藏与进度保存在本机」
// （hgtv-library-*.json）。tvOS 端用 App Group / Documents 下 JSON 落地。

import Foundation

public final class LocalLibrary: @unchecked Sendable {
    public static let shared = LocalLibrary()

    private let queue = DispatchQueue(label: "hgtv.library")
    private let fileURL: URL

    private(set) public var favorites: [DramaItem] = []
    private(set) public var history: [DramaItem] = []
    private(set) public var watchLater: [DramaItem] = []

    private struct Store: Codable {
        var favorites: [DramaItem] = []
        var history: [DramaItem] = []
        var watchLater: [DramaItem] = []
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("hgtv-library.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let store = (try? JSONDecoder().decode(Store.self, from: data)) ?? Store()
        favorites = store.favorites
        history = store.history
        watchLater = store.watchLater
    }

    private func save() {
        let store = Store(favorites: favorites, history: history, watchLater: watchLater)
        queue.async {
            if let data = try? JSONEncoder().encode(store) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    public func toggleFavorite(_ item: DramaItem) {
        if let i = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(item, at: 0)
        }
        save()
    }

    public func recordWatch(_ item: DramaItem) {
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        if history.count > 100 { history.removeLast() }
        save()
    }

    public func toggleWatchLater(_ item: DramaItem) {
        if let i = watchLater.firstIndex(where: { $0.id == item.id }) {
            watchLater.remove(at: i)
        } else {
            watchLater.insert(item, at: 0)
        }
        save()
    }

    public func clearHistory() {
        history = []
        save()
    }
}