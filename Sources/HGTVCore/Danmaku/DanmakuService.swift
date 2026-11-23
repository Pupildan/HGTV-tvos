// DanmakuService.swift
// 弹幕数据层（v32）。协议严格照抄反编译原项目 com.hgtv.star 的 LF0/l0.A 方法（dex 原文）：
//
//   POST https://api5-normal-lf.fqnovel.com/novel/commentapi/comment/list/{vid}/v1/
//   Headers: 公共签名头 + comment-source:601 + server-channel:1000 + x-ss-stub:""
//   Body(JSON，不 gzip):
//     {
//       "comment_source": 601,
//       "server_channel": 1000,
//       "group_id": "<vid>",
//       "group_type": 30,
//       "comment_type": 20,
//       "sort": 1,
//       "business_param": {
//         "book_id": "<seriesId>",
//         "start_offset_time": <窗口起点 ms>,
//         "playlet_item_duration": <本集时长 ms>,
//         "need_danmaku_guide_type": [1,3,4,2]
//       },
//       "count": 200,
//       "cursor": "<游标>",
//       "aid": 8662,
//       "compliance_status": 0
//     }
//   响应: data.data_list[]（comment_id/text/offset/...）
//         data.common_list_info.{cursor,has_more,total}
//         data.extra.next_query_danmaku_list_time（下次查询时刻，原项目用它滚动窗口；
//         本实现直接按 30s 步进，等价且对窗口边界抖动更稳）
//
// 取数策略（对齐原项目「按当前时间 30 秒窗口滚动」+ Nbeetok 弹幕分段经验）：
//   - 全集按 30s 窗口顺序请求；窗口内按 cursor 翻页直到 has_more=false；
//   - 窗口间 0.15s 节流；失败窗口收尾重试一轮；
//   - danmaku id 全局去重（窗口重叠/翻页重复兜底）；
//   - 内存缓存 per vid（同集回看不重拉）。

import Foundation

/// 单条弹幕（渲染层只需 id/偏移/文本）。
public struct DanmakuMessage: Sendable, Equatable {
    public let id: String
    /// 视频内偏移（ms）
    public let offsetMs: Double
    public let text: String

    public init(id: String, offsetMs: Double, text: String) {
        self.id = id
        self.offsetMs = offsetMs
        self.text = text
    }
}

/// 窗口分段编排器（串行、去重、缓存）。
public actor DanmakuService {
    public static let shared = DanmakuService()

    private let api = APIService.shared
    private var cache: [String: [DanmakuMessage]] = [:]

    /// 单窗口时长（原项目响应 extra.next_query_danmaku_list_time 兜底值 +30000ms）
    nonisolated static let windowMs = 30_000
    /// 窗口间节流
    nonisolated static let throttleNanos: UInt64 = 150_000_000
    /// durationMs 缺失时的兜底时长（10 分钟，超出部分按时钟自然跳过）
    nonisolated static let fallbackDurationMs = 600_000

    private init() {}

    /// 取整集弹幕。onSegment 每窗口增量回调（主 actor、按 offset 有序、全局去重）。
    /// 返回本集最终全量（也写缓存）。
    @discardableResult
    public func fetchAll(vid: String,
                         bookId: String?,
                         durationMs: Int,
                         onSegment: (@MainActor @Sendable ([DanmakuMessage]) -> Void)?) async -> [DanmakuMessage] {
        DiagnosticsLogger.log("🔍 [弹幕诊断] DanmakuService.fetchAll() 进入 vid=\(vid) bookId=\(bookId ?? "nil") durationMs=\(durationMs)",
                              category: "danmaku", level: .info)
        guard !vid.isEmpty else {
            DiagnosticsLogger.log("🔍 [弹幕诊断] fetchAll() 返回空：vid 为空", category: "danmaku", level: .info)
            return []
        }
        if let cached = cache[vid] {
            DiagnosticsLogger.log("🔍 [弹幕诊断] fetchAll() 返回缓存：\(cached.count) 条", category: "danmaku", level: .info)
            if let onSegment, !cached.isEmpty { await MainActor.run { onSegment(cached) } }
            return cached
        }
        DiagnosticsLogger.log("🔍 [弹幕诊断] fetchAll() 开始获取：duration=\(durationMs > 0 ? durationMs : Self.fallbackDurationMs)ms",
                              category: "danmaku", level: .info)

        // ── NAS 桥数据源（2026-11-23）─────────────────────────────────────────
        // 自签 commentapi 恒 110001（设备身份门控），改走桥：桥被动读 redroid 原版 app
        // 的 commentapi dump（原版活身份+native 签名拿到真弹幕），按 vid 缓存。
        // 桥一次性返回该 vid 全量弹幕，无需 30s 窗口循环。
        if PCBridge.isEnabled {
            do {
                let items = try await PCBridge.fetchDanmaku(vid: vid)
                let sorted = items.sorted { $0.offsetMs < $1.offsetMs }
                if !sorted.isEmpty {
                    if let onSegment {
                        await MainActor.run { onSegment(sorted) }
                    }
                }
                DiagnosticsLogger.log("🔍 [弹幕诊断] fetchAll() 桥返回 vid=\(vid) 条数=\(sorted.count)",
                                      category: "danmaku", level: .info)
                cache[vid] = sorted
                return sorted
            } catch {
                DiagnosticsLogger.warn("弹幕桥取数失败 vid=\(vid)：\(error.localizedDescription)",
                                       category: "danmaku")
                cache[vid] = []
                return []
            }
        }

        let duration = durationMs > 0 ? durationMs : Self.fallbackDurationMs
        var merged: [DanmakuMessage] = []
        var seen = Set<String>()
        var failedWindows: [(Int, Int)] = []

        func accept(_ items: [DanmakuMessage]) {
            var fresh: [DanmakuMessage] = []
            for it in items where !seen.contains(it.id) {
                seen.insert(it.id)
                fresh.append(it)
            }
            guard !fresh.isEmpty else { return }
            fresh.sort { $0.offsetMs < $1.offsetMs }
            merged.append(contentsOf: fresh)
            if let onSegment {
                let seg = fresh
                Task { @MainActor in onSegment(seg) }
            }
        }

        // 取 [start,end) 30s 窗口（窗口内 cursor 翻页）
        func fetchWindow(start: Int, end: Int) async -> Bool {
            var cursor = ""
            var got = false
            var pages = 0
            repeat {
                do {
                    let win = try await api.fetchDanmakuWindow(
                        vid: vid, bookId: bookId,
                        startOffsetMs: start, durationMs: end - start,
                        cursor: cursor)
                    got = true
                    accept(win.items)
                    cursor = win.cursor
                    pages += 1
                } catch {
                    DiagnosticsLogger.warn("弹幕窗口 [\(start/1000)-\(end/1000)s] 失败：\(error.localizedDescription)",
                                           category: "danmaku")
                    break
                }
            } while !cursor.isEmpty && pages < 5
            return got
        }

        var start = 0
        while start < duration {
            let wEnd = min(start + Self.windowMs, duration)
            if !(await fetchWindow(start: start, end: wEnd)) {
                failedWindows.append((start, wEnd))
            }
            start = wEnd
            try? await Task.sleep(nanoseconds: Self.throttleNanos)
        }

        // 失败窗口重试一轮（网络抖动容错，对齐 Nbeetok v139 经验）
        for (s, e) in failedWindows {
            _ = await fetchWindow(start: s, end: e)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        DiagnosticsLogger.log("🔍 [弹幕诊断] fetchAll() 完成 vid=\(vid) 窗口数=\(duration / Self.windowMs + 1) 条数=\(merged.count) 失败窗口=\(failedWindows.count)",
                              category: "danmaku", level: .info)
        cache[vid] = merged
        return merged
    }

    /// 清缓存（内存压力/调试用）。
    public func clearCache() {
        cache.removeAll()
    }
}
