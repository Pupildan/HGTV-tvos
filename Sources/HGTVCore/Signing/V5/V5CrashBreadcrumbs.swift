// V5CrashBreadcrumbs.swift
// V5 签名链路的崩溃安全面包屑。真机 V5 崩溃发生在日志通道建立之前，
// 普通 DiagnosticsLogger 面包屑随崩溃丢失。这里把每条面包屑同步写进
// UserDefaults（setAndSynchronize 落盘，崩溃也能存活），下次启动读到后
// 通过日志通道 flush 出来，从而定位崩在哪个阶段。

import Foundation

public enum V5CrashBreadcrumbs {
    private static let key = "v5.crash.breadcrumbs"
    private static let lock = NSLock()

    /// 记录一条面包屑（同步落盘，崩溃安全）。保留最近 60 条。
    public static func mark(_ message: String) {
        lock.withLock {
            var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
            let ts = String(format: "%.3f", Date().timeIntervalSince1970)
            arr.append("[\(ts)] \(message)")
            if arr.count > 60 { arr.removeFirst(arr.count - 60) }
            UserDefaults.standard.set(arr, forKey: key)
            UserDefaults.standard.synchronize()   // 崩溃前强制落盘
        }
    }

    /// 取出并清空缓冲（下次启动调用，把上次崩溃的面包屑交日志通道发出）。
    static func drain() -> [String] {
        lock.withLock {
            let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.synchronize()
            return arr
        }
    }

    /// 下次启动调用：把上次崩溃存活的面包屑通过日志通道发出（public，供 App 层触发）。
    public static func flushLastCrash() {
        let crumbs = drain()
        guard !crumbs.isEmpty else { return }
        DiagnosticsLogger.warn("V5 上次崩溃面包屑（共 \(crumbs.count) 条）↓", category: "sign")
        for c in crumbs { DiagnosticsLogger.warn("  🧭 \(c)", category: "sign") }
    }
}
