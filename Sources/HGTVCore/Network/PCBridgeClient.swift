// PCBridgeClient.swift
// PC TLS 桥（2026-11-22）。
//
// 决定性实验结论：landpage 等个性化接口按客户端 TLS 指纹门控——
//   - ATV URLSession + 手机实测成功身份 + 逐项对齐的请求 → 恒 0B
//   - PC Python/OpenSSL 原样重放同一请求 → HTTP 200 + 377KB 真实数据
// 唯一剩余差异 = 客户端 TLS 栈。本桥把已签名的请求（url+headers+body）经局域网
// 明文 TCP 交给 PC（bridge_server.py，:51900），由 PC 的 OpenSSL 栈代发并回传响应。
// 签名仍在 ATV 本地完成（V5），PC 只做传输；PC 端还会把请求头排成手机成功抓包
// 的规范顺序。
//
// 协议（每连接一个请求，JSON 行）：
//   发送 {"method","url","headers":[[k,v],...],"body_b64"}
//   收到 {"status","headers":[[k,v],...],"body_b64","error"}

import Foundation

public enum PCBridge {
    /// 总开关：v70 实验结论——桥请求（PC OpenSSL）同样 0B → TLS 不是门控，
    /// 真凶 = medusa 载荷设备字段与身份档案不一致（v71 修复）。桥关闭，回到直连。
    public static let isEnabled = false
    /// PC 地址（开发机常驻；与日志服务器同机）。
    public static let host = "192.168.10.122"
    public static let port: UInt16 = 51900

    public struct Response {
        public let status: Int
        public let data: Data
        public let headers: [(String, String)]
    }

    /// 经 PC 代发一个已签名请求。失败抛错（不做静默回退，保持测试信号干净）。
    public static func execute(method: String, url: String,
                               headers: [String: String], body: [UInt8]?) async throws -> Response {
        var reqHeaders: [[String]] = []
        for (k, v) in headers {
            let lower = k.lowercased()
            // 传输层自动管理的头交给 PC 端栈
            if ["host", "content-length", "accept-encoding", "connection"].contains(lower) { continue }
            if v.isEmpty { continue }
            reqHeaders.append([k, v])
        }
        let payload: [String: Any] = [
            "method": method,
            "url": url,
            "headers": reqHeaders,
            "body_b64": body.map { Data($0).base64EncodedString() } ?? "",
        ]
        let sendData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + [0x0A]

        // 每请求一条连接（LAN 开销可忽略），带超时
        var readData = Data()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                var sock: Int32 = -1
                defer { if sock >= 0 { close(sock) } }
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>? = nil
                guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
                    cont.resume(throwing: HTTPError.network(NSError(domain: "PCBridge", code: -1,
                                                                    userInfo: [NSLocalizedDescriptionKey: "DNS 失败"])))
                    return
                }
                defer { freeaddrinfo(info) }
                sock = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
                guard sock >= 0 else {
                    cont.resume(throwing: HTTPError.network(NSError(domain: "PCBridge", code: -2,
                                                                    userInfo: [NSLocalizedDescriptionKey: "socket 创建失败"])))
                    return
                }
                // 20s 超时
                var tv = timeval(tv_sec: 20, tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                guard connect(sock, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
                    cont.resume(throwing: HTTPError.network(NSError(domain: "PCBridge", code: -3,
                                                                    userInfo: [NSLocalizedDescriptionKey: "PC 桥连不上 \(host):\(port)"])))
                    return
                }
                var sent = 0
                let arr = [UInt8](sendData)
                while sent < arr.count {
                    let n = arr.withUnsafeBufferPointer { bp -> Int in
                        send(sock, bp.baseAddress! + sent, arr.count - sent, 0)
                    }
                    if n <= 0 { break }
                    sent += n
                }
                guard sent == arr.count else {
                    cont.resume(throwing: HTTPError.network(NSError(domain: "PCBridge", code: -4,
                                                                    userInfo: [NSLocalizedDescriptionKey: "请求发送不完整"])))
                    return
                }
                // 读到换行或对端关闭
                var buf = [UInt8](repeating: 0, count: 65536)
                while readData.count < 64 * 1024 * 1024 {
                    let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                        recv(sock, bp.baseAddress, bp.count, 0)
                    }
                    if n <= 0 { break }
                    readData.append(contentsOf: buf[0..<n])
                    if readData.contains(0x0A) { break }
                }
                cont.resume(returning: ())
            }
        }

        guard let line = readData.split(separator: 0x0A, omittingEmptySubsequences: false).first,
              !line.isEmpty else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -5,
                                            userInfo: [NSLocalizedDescriptionKey: "PC 桥无响应"]))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line), options: []) as? [String: Any] else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -6,
                                            userInfo: [NSLocalizedDescriptionKey: "PC 桥响应解析失败"]))
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "PC 代发失败: \(err)"]))
        }
        let status = obj["status"] as? Int ?? 0
        let bodyB64 = obj["body_b64"] as? String ?? ""
        guard let data = Data(base64Encoded: bodyB64) else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -8,
                                            userInfo: [NSLocalizedDescriptionKey: "PC 桥响应体解码失败"]))
        }
        var respHeaders: [(String, String)] = []
        if let hs = obj["headers"] as? [[Any]] {
            for h in hs where h.count == 2 {
                if let k = h[0] as? String, let v = h[1] as? String { respHeaders.append((k, v)) }
            }
        }
        return Response(status: status, data: data, headers: respHeaders)
    }
}
