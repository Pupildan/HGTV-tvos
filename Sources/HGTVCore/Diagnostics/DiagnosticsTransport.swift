// DiagnosticsTransport.swift
// 日志回传通道抽象。真机日志层与具体传输解耦：默认实现为 TCPTransport（Bonjour 发现 + TCP 长连接），
// 也可替换为写文件 / 写 os_log / 单元测试里的内存通道。

import Foundation

/// 一条日志的出站通道。
/// - `start()`：启动发现 / 连接（幂等，可重复调用）。
/// - `send(_:)`：发送一行（不含换行）；未连接时应自行缓冲，连上后 flush。
/// - `stop()`：停止发现与连接，释放资源（幂等）。
public protocol DiagnosticsTransport: Sendable {
    func start() async
    func send(_ line: String) async
    func stop() async
}
