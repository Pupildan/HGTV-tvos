// PlaybackProxy.swift
// 本地 HTTP 服务器（Network.framework NWListener，监听 127.0.0.1 随机端口）。
// 流程：AVPlayer 请求 http://127.0.0.1:<port>/video → 代理从 payloadProvider 取
// 已解密的明文 mp4 data → 按 Range 返回 200/206。
// Range 策略：解析 Range: bytes=start-end，返回 206 + Content-Range 切片；
// 无 Range 返回 200 全量。两种响应都带 Accept-Ranges: bytes（AVPlayer 会发 Range）。

import Foundation
import Network

public enum PlaybackProxyError: Error, LocalizedError {
    case cancelled
    public var errorDescription: String? { "本地播放代理已停止" }
}

public final class PlaybackProxy: @unchecked Sendable {
    /// 提供明文 mp4 数据（已由 CENCDecryptor 解密）。AVPlayer 可多次请求。
    private let payloadProvider: @Sendable () -> Data?
    private let queue = DispatchQueue(label: "hgtv.playback.proxy")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?

    public init(payloadProvider: @escaping @Sendable () -> Data?) {
        self.payloadProvider = payloadProvider
    }

    public convenience init(payload: Data) {
        self.init(payloadProvider: { payload })
    }

    /// 启动监听，返回本地播放 URL（等待 listener ready）。
    public func start() async throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 绑定到 loopback，仅本机 AVPlayer 可访问
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let ls = try NWListener(using: params)
        self.listener = ls

        ls.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // 通过 self.listener 取端口，避免在 @Sendable 闭包里捕获局部 NWListener
                let p = self.listener?.port?.rawValue ?? 0
                let url = URL(string: "http://127.0.0.1:\(p)/video")
                    ?? URL(fileURLWithPath: "/")
                self.finishReady(.success(url))
            case .failed(let err):
                self.finishReady(.failure(err))
            case .cancelled:
                self.finishReady(.failure(PlaybackProxyError.cancelled))
            default:
                break
            }
        }
        ls.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        return try await withCheckedThrowingContinuation { cont in
            // 先登记 continuation 再 start，避免 ready 早于登记的竞态
            self.readyContinuation = cont
            ls.start(queue: self.queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finishReady(_ result: Result<URL, Error>) {
        queue.async { [weak self] in
            guard let self, let cont = self.readyContinuation else { return }
            self.readyContinuation = nil
            switch result {
            case .success(let url): cont.resume(returning: url)
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }

    // MARK: - 连接处理

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let c = content { buf.append(c) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                self.respond(connection: connection, requestHeaders: headerText)
            } else if error == nil, !isComplete {
                self.receiveRequest(connection: connection, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(connection: NWConnection, requestHeaders: String) {
        guard let payload = payloadProvider(), !payload.isEmpty else {
            send(connection: connection, status: "404 Not Found",
                 headers: ["Content-Type": "text/plain", "Connection": "close"],
                 body: Data("no payload".utf8))
            return
        }

        let total = payload.count
        let range = Self.parseByteRange(requestHeaders, total: total)

        var headers = [
            "Content-Type": "video/mp4",
            "Accept-Ranges": "bytes",
            "Connection": "close",
        ]
        var body: Data
        if let r = range {
            let (start, end) = r
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            let slice = payload.subdata(in: payload.startIndex + start ..< payload.startIndex + end + 1)
            body = slice
            send(connection: connection, status: "206 Partial Content", headers: headers, body: body)
        } else {
            body = payload
            send(connection: connection, status: "200 OK", headers: headers, body: body)
        }
    }

    private func send(connection: NWConnection, status: String,
                      headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        for (k, v) in allHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            // Connection: close —— 每个请求一个连接，AVPlayer 会自行重连
            connection.cancel()
        })
    }

    /// 解析 "Range: bytes=start-end"。返回 (start, end) 闭区间（含端点）。
    /// 支持 start-end / start- / -suffix。非法或缺头返回 nil。
    static func parseByteRange(_ headerText: String, total: Int) -> (Int, Int)? {
        guard total > 0 else { return nil }
        for rawLine in headerText.split(separator: "\r\n") {
            let line = rawLine.lowercased()
            guard line.hasPrefix("range:") else { continue }
            let afterColon = rawLine.split(separator: ":", maxSplits: 1).dropFirst().first
                .map(String.init) ?? ""
            let spec = afterColon.trimmingCharacters(in: .whitespaces)
            let parts = spec.split(separator: "=")
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "bytes"
            else { return nil }
            let rangeSpec = parts[1].trimmingCharacters(in: .whitespaces)
            let bounds = rangeSpec.split(separator: "-", maxSplits: 1,
                                         omittingEmptySubsequences: false)
            var start = 0
            var end = total - 1
            if bounds.count >= 1, !bounds[0].isEmpty,
               let s = Int(bounds[0].trimmingCharacters(in: .whitespaces)) {
                start = s
            } else if bounds.count >= 2, bounds[0].isEmpty,
                      let suffix = Int(bounds[1].trimmingCharacters(in: .whitespaces)) {
                // "-suffix"：取末尾 suffix 字节
                start = max(0, total - suffix)
                end = total - 1
                if start > end { return nil }
                return (start, end)
            } else {
                return nil
            }
            if bounds.count >= 2, !bounds[1].isEmpty,
               let e = Int(bounds[1].trimmingCharacters(in: .whitespaces)) {
                end = min(e, total - 1)
            }
            guard start <= end, start < total else { return nil }
            return (start, end)
        }
        return nil
    }
}
