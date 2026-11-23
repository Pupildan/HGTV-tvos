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
    /// 总开关：2026-11-23 起启用。SM3 FF 在 v83 修复后服务端仍 200+0B，
    /// 静态复刻路到头；改走 NAS 桥——NAS 用手机真机合法签名重放官方接口
    /// （已实测 377KB 稳定出数据）。ATV 只做 UI + 播放，签名/取数交给 NAS。
    public static let isEnabled = true
    /// NAS 地址（常驻；飞牛 NAS 固定 IP）。
    public static let host = "192.168.10.120"
    public static let port: UInt16 = 51901

    /// ATV 启动时打一枪：让 NAS 桥触发一轮原版 app 冷启动 + 翻页，刷新 landpage 池。
    /// 桥立即回 ok（异步驱动，不阻塞），失败无感忽略——feed 仍走已有池子。
    /// 一天最多几次（开关 ATV 次数），不会风控。
    public static func bump() async {
        guard let sendData = try? JSONSerialization.data(
            withJSONObject: ["action": "bump"], options: [.sortedKeys]) + [0x0A] else { return }
        _ = try? await sendAndRead(sendData)
    }

    /// 走 NAS 桥代理拉 feed：桥用预存的手机真签名重放 landpage，返回官方真实响应。
    /// 协议：{"action":"feed"} → {status, body_b64, error}
    public static func fetchFeed() async throws -> Data {
        let payload: [String: Any] = ["action": "feed"]
        let sendData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + [0x0A]
        let respData = try await sendAndRead(sendData)
        guard let obj = try? JSONSerialization.jsonObject(with: respData, options: []) as? [String: Any] else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -6,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS feed 响应解析失败"]))
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS feed 失败: \(err)"]))
        }
        let status = obj["status"] as? Int ?? 0
        guard status == 200 else {
            throw HTTPError.catalogHTTP(status)
        }
        guard let b64 = obj["body_b64"] as? String, let data = Data(base64Encoded: b64) else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -8,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS feed 响应体解码失败"]))
        }
        return data
    }

    /// 走 NAS 桥获取视频播放地址：桥按 vid 现场取播放地址 + spade_a，
    /// 下载 CENC 密文 → 解密成明文 → 经 HTTP 代理托管，返回可直接播的明文 URL。
    /// 协议：{"action":"play","vid":"..."} → {status, play_url, error}
    /// 返回的 URL 指向 NAS 上的明文 mp4（已解密，AVPlayer 直接播，无需本地解密）。
    public static func fetchPlayUrl(vid: String) async throws -> URL {
        let payload: [String: Any] = ["action": "play", "vid": vid]
        let sendData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + [0x0A]
        let respData = try await sendAndRead(sendData)
        guard let obj = try? JSONSerialization.jsonObject(with: respData, options: []) as? [String: Any] else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -6,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS play 响应解析失败"]))
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS play 失败: \(err)"]))
        }
        let status = obj["status"] as? Int ?? 0
        guard status == 200 else {
            throw HTTPError.catalogHTTP(status)
        }
        guard let playUrlStr = obj["play_url"] as? String,
              let url = URL(string: playUrlStr) else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -8,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS play 返回 URL 无效"]))
        }
        return url
    }

    /// 走 NAS 桥取某 vid 的弹幕。桥被动读 redroid 原版 app 的 commentapi dump（原版用活身份+
    /// native 签名拉到真弹幕），按 vid 缓存；ATV 播同 vid 直接命中。
    /// 协议：{"action":"danmaku","vid":"..."} → {status, body_b64}，body={items:[{id,offset_ms,text}],count}
    /// 桥未命中/该 vid 无弹幕时返回空数组（不报错）。
    public static func fetchDanmaku(vid: String) async throws -> [DanmakuMessage] {
        let payload: [String: Any] = ["action": "danmaku", "vid": vid]
        let sendData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + [0x0A]
        let respData = try await sendAndRead(sendData)
        guard let obj = try? JSONSerialization.jsonObject(with: respData, options: []) as? [String: Any] else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -6,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS danmaku 响应解析失败"]))
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS danmaku 失败: \(err)"]))
        }
        let status = obj["status"] as? Int ?? 0
        guard status == 200 else {
            throw HTTPError.catalogHTTP(status)
        }
        guard let b64 = obj["body_b64"] as? String, let data = Data(base64Encoded: b64) else {
            throw HTTPError.network(NSError(domain: "PCBridge", code: -8,
                                            userInfo: [NSLocalizedDescriptionKey: "NAS danmaku 响应体解码失败"]))
        }
        // body = {"items":[{"id","offset_ms","text"}], "count":N}
        guard let bodyObj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let items = bodyObj["items"] as? [[String: Any]] else {
            return []
        }
        var out: [DanmakuMessage] = []
        for it in items {
            guard let id = it["id"] as? String, let text = it["text"] as? String, !text.isEmpty else { continue }
            let off = (it["offset_ms"] as? NSNumber)?.doubleValue ?? 0
            out.append(DanmakuMessage(id: id, offsetMs: off, text: text))
        }
        return out
    }

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

        let readData = try await sendAndRead(sendData)

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

    /// 底层 TCP 收发：把一行 JSON 发给 PC，读到第一行响应返回。所有 action 复用。
    private static func sendAndRead(_ sendData: Data) async throws -> Data {
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
        return readData
    }
}
