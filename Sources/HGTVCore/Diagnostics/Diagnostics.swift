// Diagnostics.swift
// 日志诊断层核心：把真机运行日志封装成一行 JSON，通过 transport 回传到同局域网开发机，
// 同时用 os.Logger 本地输出一份便于 Console 调试。内部维护有界环形缓冲供 UI / 崩溃前读取。
//
// 用法：
//   DiagnosticsLogger.shared.info("启动完成", category: "app")
//   DiagnosticsLogger.shared.error("请求失败", category: "http", meta: ["url": url])
//
// 并发：单例被多 Task 并发调用，内部可变状态（缓冲 / transport）用 os_unfair_lock 保护，
// 类标记 @unchecked Sendable 是安全的。

import Foundation
import os

public final class DiagnosticsLogger: @unchecked Sendable {
    public static let shared = DiagnosticsLogger()

    // MARK: - 日志级别

    public enum Level: String, Sendable, Comparable {
        case debug, info, warn, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    // MARK: - 常量

    /// 环形缓冲容量（最近 N 条）。
    public static let bufferCapacity = 500
    private static let subsystem = "com.hgtv.star.tvos"
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 可变状态（lock 保护）

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var ring: [String] = []
        var transports: [DiagnosticsTransport] = []
        var started = false
        var minLevel: Level = .debug
    }

    private init() {}

    // MARK: - 通道注册

    /// 注册回传通道并启动。重复调用以最后一次为准（先停旧通道）。
    /// 注意：不持锁跨 await，避免阻塞其它日志调用。
    public func registerTransport(_ transport: DiagnosticsTransport) async {
        let (previous, shouldStart): ([DiagnosticsTransport], Bool) = lock.withLock { st in
            let old = st.transports
            st.transports = [transport]
            let start = !st.started
            st.started = true
            return (old, start)
        }
        for t in previous { await t.stop() }
        if shouldStart { await transport.start() }
    }

    /// 移除并停止当前通道。
    public func removeTransport() async {
        let old: [DiagnosticsTransport] = lock.withLock { st in
            let previous = st.transports
            st.transports = []
            st.started = false
            return previous
        }
        for t in old { await t.stop() }
    }

    /// 启动所有已注册通道（App 启动挂钩用）。
    public func start() async {
        let transports: [DiagnosticsTransport] = lock.withLock { st in
            st.started = true
            return st.transports
        }
        for t in transports { await t.start() }
    }

    /// 设置最低输出级别（低于该级别的日志丢弃）。
    public func setMinLevel(_ level: Level) {
        lock.withLock { $0.minLevel = level }
    }

    // MARK: - 核心 API

    /// 记录一条日志：封装成 JSON 行 → transport 发送（fire-and-forget）+ os.Logger 本地输出 + 环形缓冲。
    public static func log(_ message: String, category: String = "general", level: Level = .info,
                           meta: [String: String]? = nil) {
        shared.emit(message, category: category, level: level, meta: meta)
    }

    public static func debug(_ message: String, category: String = "general",
                             meta: [String: String]? = nil) {
        log(message, category: category, level: .debug, meta: meta)
    }
    public static func info(_ message: String, category: String = "general",
                            meta: [String: String]? = nil) {
        log(message, category: category, level: .info, meta: meta)
    }
    public static func warn(_ message: String, category: String = "general",
                            meta: [String: String]? = nil) {
        log(message, category: category, level: .warn, meta: meta)
    }
    public static func error(_ message: String, category: String = "general",
                             meta: [String: String]? = nil) {
        log(message, category: category, level: .error, meta: meta)
    }

    // 实例便捷方法（内部 / 链式调用）
    public func debug(_ message: String, category: String = "general", meta: [String: String]? = nil) {
        emit(message, category: category, level: .debug, meta: meta)
    }
    public func info(_ message: String, category: String = "general", meta: [String: String]? = nil) {
        emit(message, category: category, level: .info, meta: meta)
    }
    public func warn(_ message: String, category: String = "general", meta: [String: String]? = nil) {
        emit(message, category: category, level: .warn, meta: meta)
    }
    public func error(_ message: String, category: String = "general", meta: [String: String]? = nil) {
        emit(message, category: category, level: .error, meta: meta)
    }

    // MARK: - 发送实现

    private func emit(_ message: String, category: String, level: Level, meta: [String: String]?) {
        let minLevel = lock.withLock { $0.minLevel }
        guard level >= minLevel else { return }

        let line = Self.encodeLine(message: message, category: category, level: level, meta: meta)

        // 1) os.Logger 本地输出（subsystem/category 对应）
        let logger = Logger(subsystem: Self.subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        // 2) 环形缓冲
        lock.withLock { st in
            st.ring.append(line)
            if st.ring.count > Self.bufferCapacity {
                st.ring.removeFirst(st.ring.count - Self.bufferCapacity)
            }
        }

        // 3) transport 发送（fire-and-forget，不阻塞调用方）
        let transports: [DiagnosticsTransport] = lock.withLock { $0.transports }
        guard !transports.isEmpty else { return }
        for t in transports {
            Task { await t.send(line) }
        }
    }

    // MARK: - JSON 编码

    private static func encodeLine(message: String, category: String, level: Level,
                                   meta: [String: String]?) -> String {
        let ts = isoFormatter.string(from: Date())
        // 手工拼单行 JSON：字符串统一 JSON 转义，键排序稳定，meta 为嵌套对象。
        var fields: [(String, String)] = [
            ("ts", quote(ts)),
            ("level", quote(level.rawValue)),
            ("category", quote(category)),
            ("message", quote(message)),
        ]
        if let meta, !meta.isEmpty {
            let metaJSON = meta.sorted { $0.key < $1.key }
                .map { "\(quote($0.key)):\(quote($0.value))" }
                .joined(separator: ",")
            fields.append(("meta", "{\(metaJSON)}"))
        }
        fields.sort { $0.0 < $1.0 }
        let body = fields.map { "\(quote($0.0)):\($0.1)" }.joined(separator: ",")
        return "{" + body + "}"
    }

    private static func quote(_ s: String) -> String {
        "\"\(escape(s))\""
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - 环形缓冲读取（供 UI / 崩溃前读取）

    /// 返回最近 N 条 JSON 行（旧 → 新）。
    public func recentLines(limit: Int = bufferCapacity) -> [String] {
        lock.withLock { st in
            guard limit < st.ring.count else { return st.ring }
            return Array(st.ring.suffix(limit))
        }
    }

    /// 清空缓冲。
    public func clearBuffer() {
        lock.withLock { $0.ring.removeAll() }
    }
}
