// HGTVModels.swift
// 数据模型。字段名对齐原 APK 接口返回（番茄短剧 bookapi / novel/player）。
// 反序列化用宽松解码：接口字段随版本变化，缺失字段不致命。

import Foundation

// MARK: - 解码工具：宽松（缺字段不崩）
public struct LenientDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(type, from: data)
    }
}

// MARK: - 通用接口外层（番茄系多为 { code, data, msg }）
public struct APIEnvelope<T: Decodable>: Decodable {
    public let code: Int?
    public let message: String?
    public let msg: String?
    public let data: T?

    public var okMessage: String? { message ?? msg }
}

// MARK: - 剧集条目（书 / 短剧）
public struct DramaItem: Identifiable, Decodable, Hashable {
    // id 只依赖存储属性，避免在 Hashable 合成 hash 里访问 hashValue 造成递归
    public var id: String { bookId ?? title ?? "" }
    public let bookId: String?
    public let title: String?
    public let thumbURL: URL?
    public let description: String?
    public let category: String?
    public let playCount: Int?
    public let score: Double?

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case title, thumbURL = "thumb_url", description, category
        case playCount = "play_count", score
    }
}

// MARK: - 分类落地页（/reading/distribution/category/landpage）
public struct CategoryLandpage: Decodable {
    public let categoryList: [CategoryGroup]?
    enum CodingKeys: String, CodingKey { case categoryList = "category_list" }
}

public struct CategoryGroup: Identifiable, Decodable, Hashable {
    public let id: String
    public let name: String?
    public let items: [DramaItem]?
}

// MARK: - 搜索
public struct SearchResult: Decodable {
    public let items: [DramaItem]?
    public let hasMore: Bool?
    enum CodingKeys: String, CodingKey { case items, hasMore = "has_more" }
}

public struct SearchSuggestion: Decodable, Identifiable {
    public var id: String { name }
    public let name: String
}

// MARK: - 剧集详情 + 选集
public struct DramaDetail: Decodable {
    public let bookId: String?
    public let title: String?
    public let thumbURL: URL?
    public let description: String?
    public let episodeList: [Episode]?
    enum CodingKeys: String, CodingKey {
        case bookId = "book_id", title, thumbURL = "thumb_url", description
        case episodeList = "episode_list"
    }
}

public struct Episode: Identifiable, Decodable, Hashable {
    public var id: String { itemId ?? "ep\(index)" }
    public let itemId: String?
    public let index: Int
    public let title: String?
    public let duration: Int?
    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", index, title, duration
    }
}

// MARK: - 播放模型（/novel/player/video_model）→ 取流地址
public struct VideoModel: Decodable {
    public let videoURL: URL?
    public let backupURLs: [URL]?
    public let duration: Int?
    public let qualities: [Quality]?
    enum CodingKeys: String, CodingKey {
        case videoURL = "video_url", backupURLs = "backup_urls"
        case duration, qualities
    }
}

public struct Quality: Decodable, Hashable {
    public let level: String?   // 360P / 480P / ... / 1080P
    public let url: URL?
}