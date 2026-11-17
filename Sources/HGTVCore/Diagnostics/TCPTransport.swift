// TCPTransport.swift
// 基于 Network.framework 的日志回传通道：用 NWBrowser 通过 Bonjour/mDNS 自动发现
// 同一局域网内开发机上的接收端（服务类型 _hgtvlog._tcp），发现后用 NWConnection 建立
// TCP 长连接，把一行行 JSON + "\n" 推过去。
//
// 设计要点：
// - 可变状态全部收敛在 actor 里，NWBrowser/NWConnection 的回调通过 Task { await ... }
//   hop 回 actor，满足 Swift 6 严格并发（无数据竞争）。
// - 连接断开自动重连，指数退避（0.5s 起，封顶 10s）。
// - 发现到服务变化时重连最新端点。
// - 未连接时缓冲最近若干条日志，连上后 flush；缓冲有上界避免内存膨胀。
// - tvOS 局域网发现需要 Info.plist 声明（本地网络权限）。权限未授予时 NWBrowser 会
//   报错，这里只记日志并按退避重试，绝不崩溃。
//
// 开发机接收端见 Scripts/log_server.py 与 DiagnosticsServer.md。

import Foundation
import Network

public actor TCPTransport: DiagnosticsTransport {

    // MARK: - 配置

    /// Bonjour 服务类型（与 Scripts/log_server.py 注册的类型一致）。
    public let serviceType: String
    private let domain: String
    /// 未连接时的离线缓冲上限。
    private let pendingCapacity: Int
    private let queue: DispatchQueue

    // MARK: - 可变状态（actor 隔离）

    // NWBrowser / NWConnection 不是 Sendable，但其回调都被绑定到 self.queue（串行），
    // 且所有状态读写都收敛在本 actor。这里用 nonisolated(unsafe) 显式声明"信任 queue 串行 +
    // actor 隔离"，绕过 Swift 6 对非 Sendable 存储的静态检查。
    nonisolated(unsafe) private var browser: NWBrowser?
    nonisolated(unsafe) private var connection: NWConnection?
    /// 最近发现的服务（按名字标识，用于断线重连 / 端点变化判断）。
    private var discoveredServiceNames: [String] = []
    private var currentServiceName: String?
    private var pending: [String] = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var started = false

    // MARK: - 初始化

    public init(serviceType: String = "_hgtvlog._tcp",
                domain: String = "local.",
                pendingCapacity: Int = 300) {
        self.serviceType = serviceType
        self.domain = domain
        self.pendingCapacity = pendingCapacity
        // 串行队列：给 NWBrowser / NWConnection 回调一个明确的执行上下文。
        self.queue = DispatchQueue(label: "com.hgtv.diagnostics.tcp")
    }

    // MARK: - DiagnosticsTransport

    public func start() {
        guard !started else { return }
        started = true
        reconnectAttempt = 0
        startBrowsing()
    }

    public func stop() {
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        discoveredServiceNames.removeAll()
        currentServiceName = nil
    }

    /// 发送一行日志。未连接时缓冲最近若干条，连上后 flush。
    public func send(_ line: String) {
        guard started else { return }
        if let conn = connection, conn.state == .ready {
            sendLine(line, on: conn)
        } else {
            appendPending(line)
        }
    }

    // MARK: - Bonjour 发现

    private func startBrowsing() {
        // 每次浏览都新建 browser；旧的先取消。
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = false
        // 用静态工厂方法构造 service descriptor（Descriptor 无公开构造器）；service 有 3 个关联值
        let browser = NWBrowser(for: .service(type: serviceType, domain: domain, interface: nil), using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] newState in
            // 回调在 queue 上；先转成 Sendable 的 String，再 hop 回 actor，避免跨隔离传非 Sendable。
            guard let self else { return }
            switch newState {
            case .ready:
                Task { await self.browserDidBecomeReady() }
            case .failed(let error):
                Task { await self.browserDidFail(description: "\(error)") }
            case .cancelled:
                Task { await self.browserWasCancelled() }
            case .waiting(let error):
                Task { await self.browserIsWaiting(description: "\(error)") }
            @unknown default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            // 在 queue 线程上抽取服务名（Sendable 的 [String]），再 hop 回 actor。
            var names: [String] = []
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    names.append(name)
                }
            }
            Task { await self.handleDiscovered(names: names) }
        }
        browser.start(queue: queue)
        DiagnosticsLogger.debug("开始 Bonjour 浏览 \(serviceType)", category: "diag")
    }

    private func browserDidBecomeReady() {
        DiagnosticsLogger.debug("Bonjour 浏览就绪", category: "diag")
    }

    private func browserDidFail(description: String) {
        // 本地网络权限未授予 / mDNS 不可用会走到这里：记日志 + 退避重启浏览，不崩溃。
        DiagnosticsLogger.warn("Bonjour 浏览失败：\(description)（检查本地网络权限）", category: "diag")
        browser?.cancel()
        browser = nil
        scheduleReconnect()
    }

    private func browserWasCancelled() {
        browser = nil
    }

    private func browserIsWaiting(description: String) {
        DiagnosticsLogger.debug("Bonjour 浏览等待：\(description)", category: "diag")
    }

    private func handleDiscovered(names: [String]) {
        guard !names.isEmpty else { return }
        let changed = names != discoveredServiceNames
        discoveredServiceNames = names
        if changed {
            DiagnosticsLogger.info("发现日志接收端服务：\(names.joined(separator: ", "))", category: "diag")
        }
        // 尚未连接，或发现到更新端点，则（重）连最新端点。
        if connection == nil || connection?.state != .ready {
            connect(to: names[0])
        }
    }

    // MARK: - 连接

    private func connect(to serviceName: String) {
        guard started else { return }
        // 已连到同一服务就不重连。
        if currentServiceName == serviceName, connection?.state == .ready { return }

        connection?.cancel()
        currentServiceName = serviceName
        // 直接用 Bonjour service 端点，Network 内部完成 mDNS 地址解析。
        let endpoint = NWEndpoint.service(
            name: serviceName, type: serviceType, domain: domain, interface: nil
        )
        let conn = NWConnection(to: endpoint, using: NWParameters.tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            // 同样先转成 Sendable 的描述，再 hop 回 actor。
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.connectionDidBecomeReady() }
            case .waiting(let error):
                Task { await self.connectionIsWaiting(description: "\(error)") }
            case .failed(let error):
                Task { await self.connectionDidFail(description: "\(error)") }
            case .cancelled:
                Task { await self.connectionWasCancelled() }
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func connectionDidBecomeReady() {
        reconnectAttempt = 0
        DiagnosticsLogger.info("日志通道已连接：\(currentServiceName ?? "?")", category: "diag")
        flushPending()
        receiveLoop()
    }

    private func connectionIsWaiting(description: String) {
        DiagnosticsLogger.debug("日志通道等待：\(description)", category: "diag")
        scheduleReconnect()
    }

    private func connectionDidFail(description: String) {
        DiagnosticsLogger.warn("日志通道失败：\(description)", category: "diag")
        connection = nil
        scheduleReconnect()
    }

    private func connectionWasCancelled() {
        connection = nil
    }

    private func receiveLoop() {
        guard let conn = connection, conn.state == .ready else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            // 只关心断开；data 不跨隔离传递。
            guard let self else { return }
            let didError = (error != nil)
            let desc = error.map { "\($0)" }
            Task { await self.handleReceive(isComplete: isComplete, didError: didError, description: desc) }
        }
    }

    private func handleReceive(isComplete: Bool, didError: Bool, description: String?) {
        // 接收端一般不回数据；这里只处理断开。
        if let description {
            DiagnosticsLogger.debug("日志通道接收错误：\(description)", category: "diag")
        }
        if isComplete || didError {
            connection = nil
            scheduleReconnect()
            return
        }
        receiveLoop()
    }

    // MARK: - 发送

    private func sendLine(_ line: String, on conn: NWConnection) {
        let payload = Data((line + "\n").utf8)
        conn.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            let desc = error.map { "\($0)" }
            Task { await self.handleSendError(description: desc) }
        })
    }

    private func handleSendError(description: String?) {
        guard let description else { return }
        DiagnosticsLogger.warn("日志发送失败：\(description)", category: "diag")
        connection = nil
        scheduleReconnect()
    }

    private func appendPending(_ line: String) {
        pending.append(line)
        if pending.count > pendingCapacity {
            pending.removeFirst(pending.count - pendingCapacity)
        }
    }

    private func flushPending() {
        guard let conn = connection, conn.state == .ready else { return }
        let lines = pending
        pending.removeAll()
        guard !lines.isEmpty else { return }
        let payload = Data(lines.map { $0 + "\n" }.joined().utf8)
        conn.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                Task { await self.handleSendError(description: "\(error)") }
            } else {
                DiagnosticsLogger.debug("已 flush \(lines.count) 条缓冲日志", category: "diag")
            }
        })
    }

    // MARK: - 重连（指数退避）

    private func scheduleReconnect() {
        guard started else { return }
        reconnectTask?.cancel()
        let delay = Self.backoff(reconnectAttempt)
        reconnectAttempt = min(reconnectAttempt + 1, 8)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return // 任务被取消
            }
            guard let self, await self.started else { return }
            await self.reconnect()
        }
    }

    private func reconnect() {
        guard started else { return }
        if let name = discoveredServiceNames.first {
            connect(to: name)
        } else {
            // 还没发现到端点：重启浏览。
            startBrowsing()
        }
    }

    private nonisolated static func backoff(_ attempt: Int) -> Double {
        let base = 0.5
        let capped = min(attempt, 6)
        return min(base * pow(2, Double(capped)), 10.0)
    }
}
