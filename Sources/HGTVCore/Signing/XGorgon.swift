// XGorgon.swift
// X-Gorgon / X-Argus / X-Ladon / X-Khronos / X-Helios 请求头生成。
// 对应 dex：LF0/C3.c(String base, LinkedHashMap params, byte[] body, String method, Map device)
//           以及它调用的 LF0/C3.b(...)（x-medusa）。

import Foundation

/// 一个已签名请求（等价 LF0/B3）。
public struct SignedRequest {
    public var url: String
    public var headers: [String: String]
    public var body: [UInt8]?
    public var method: String
}

/// 签名所需的设备上下文（等价 LF0/g0 里那些字段的最小子集）。
public struct SignContext {
    public var deviceID: String        // device_id
    public var deviceToken: String     // device_token（可空）
    public var installID: String       // iid / install_id
    public var versionCode: String     // 如 "74332"
    public var versionName: String     // 如 "7.4.3.32"
    public var osVersion: String       // 如 "16"
    public var deviceType: String      // 如 "25053RT47C" / 机型
    public var romVersion: String      // 如 "BP2A.250605.031.A3"
    public var passportSDKVersion: String = "5051452"
    public var aid: String = "8662"

    public init(deviceID: String, deviceToken: String, installID: String,
                versionCode: String, versionName: String, osVersion: String,
                deviceType: String, romVersion: String) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.installID = installID
        self.versionCode = versionCode
        self.versionName = versionName
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.romVersion = romVersion
    }
}

/// 全局签名入口（对应 C3 实例）。
/// 跨 actor 共享；clock/rng 闭包由调用方保证线程安全。
public final class RequestSigner: @unchecked Sendable {
    /// C3.c 里的 this.c：调用方可注入的额外 query 参数。
    public var extraQuery: [String: String] = [:]
    /// 时间源（默认系统毫秒）。
    private let clock: () -> UInt64
    /// 随机器。
    private let rng: (Int) -> UInt64

    public init(clock: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) },
                rng: @escaping (Int) -> UInt64 = { count in
                    var bytes = [UInt8](repeating: 0, count: count)
                    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
                    return UInt64(bytes.reduce(0) { ($0 << 8) | UInt64($1) })
                }) {
        self.clock = clock
        self.rng = rng
    }

    /// 给定 base URL、query 参数、body，产出带签名头的 SignedRequest。
    /// - Parameters:
    ///   - baseURL: 不含 query 的 URL（dex 里叫 base）
    ///   - params: 业务 query 参数（会与 extraQuery 合并）
    ///   - body: 请求体（GET 传 nil）
    ///   - method: 显式方法；nil 时按 body 是否为空推断 GET/POST
    public func sign(baseURL: String, params: [String: String], body: [UInt8]?, method: String?) -> SignedRequest {
        var merged = extraQuery
        for (k, v) in params where !v.isEmpty { merged[k] = v }

        let nowMs = clock()
        let ts = nowMs / 1000

        // C3.c：最多尝试 128 次，直到 (hash & 15) % 3 == 0
        for attempt in 0..<128 {
            let rticket = nowMs + UInt64(attempt)
            var q = merged
            q["ts"] = String(ts)
            q["_rticket"] = String(rticket)

            let query = queryString(q)
            let queryBytes = Array(query.utf8)

            let bodyMD5: [UInt8]
            if let body = body {
                bodyMD5 = md5(body)
            } else {
                bodyMD5 = [UInt8](repeating: 0, count: 16)
            }

            let h1 = customHash(seed: customHash(seed: 539167016, data: queryBytes), data: bodyMD5)
            let h2 = customHash(seed: h1, data: le32(ts))
            if (h2 & 15) % 3 != 0 { continue }

            let fullURL = baseURL + "?" + query
            let hasBody = body != nil

            var headers: [String: String] = [:]
            headers["User-Agent"] = CommonParams.userAgent(for: nil, cronet: hasBody)
            headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
            headers["x-ss-req-ticket"] = String(rticket)
            headers["sdk-version"] = "2"
            headers["passport-sdk-version"] = hasBody ? "5051452" : "6031190"
            headers["x-khronos"] = String(ts)
            headers["x-xs-from-web"] = "0"
            headers["x-tt-request-tag"] = "t=0;n=0"

            // x-ladon：4 字节随机（dex 里就是 SecureRandom 4 字节直接 base64）
            let ladonBytes = randomBytes(4)
            headers["x-ladon"] = base64Encode(ladonBytes)

            // x-argus：C1.c 路径（简化版；完整 medusa 版见 XArgus.swift）
            headers["x-argus"] = XArgus.simple(ts: ts)

            // x-medusa
            let medusa = medusaHeader(url: fullURL, body: body, ts: ts)
            headers["x-medusa"] = medusa

            // x-helios
            headers["x-helios"] = heliosHeader(ts: ts, rticket: rticket)

            // x-gorgon
            headers["x-gorgon"] = gorgonHeader(ts: ts, rticket: rticket)

            headers["x-tt-dt"] = ""

            if hasBody {
                headers["Content-Type"] = "application/json; charset=UTF-8"
                headers["x-vc-bdturing-sdk-version"] = "4.0.3.cn"
                let nonce = UInt64(UInt32(truncatingIfNeeded: rng(4)))
                headers["x-reading-request"] = "\(rticket)-\(nonce)"
                if let body = body {
                    headers["x-ss-stub"] = base64Encode(md5(body)).uppercased()
                }
            }

            let finalMethod = method ?? (body != nil ? "POST" : "GET")
            return SignedRequest(url: fullURL, headers: headers, body: body, method: finalMethod)
        }
        // dex: throw new IllegalStateException("无法生成请求签名")
        return SignedRequest(url: baseURL, headers: [:], body: body, method: method ?? "GET")
    }

    // MARK: - query 串（h3.d + h3.e）

    private func queryString(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&")
    }

    /// h3.d：URLEncoder.encode + "+"→"%20" + "%7E"→"~"
    func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    // MARK: - x-argus（C3.c 简化路径）

    // 见 XArgus.swift

    // MARK: - x-gorgon（F0.l0.H 主体，见 XGorgonH.swift）

    private func gorgonHeader(ts: UInt64, rticket: UInt64) -> String {
        // C3_b 行 1784-1813 的实参映射（invoke-static/range v14...v22）：
        //   v14 = l0.J(A1.a, deviceMap)  → protobuf 明文
        //   v15-16 = seed long
        //   v17-18 = longState long（来自 randomLongs）
        //   v19    = 由 v45/v67/v60 拼装的 long（shl 46 / or 1729382256910270464 / or 4294967296）
        //   v20    = null → medusaDigest 传空数组
        //   v21-22 = ts long
        // TODO(待对拍)：protobuf 明文需接入 l0.J（MedusaSerializer.serialize）的真实输出；
        // v19 的拼装此处用 rticket 近似。protobuf 为空时 H 会因 len<2 短路，
        // 故先走结构化占位保证 header 不缺，待 protobuf 接入后自动切到 H 主体。
        let protobuf: [UInt8] = []                                // TODO(待对拍)：接 l0.J 输出
        if protobuf.count < 2 {
            var payload: [UInt8] = XArgus.prefix8404()
            payload.append(contentsOf: [0, 0, 64, 1])
            payload.append(contentsOf: le32(UInt32(truncatingIfNeeded: ts)))
            payload.append(contentsOf: le64(rticket))
            return base64Encode(payload)
        }
        return xGorgonH(protobuf: protobuf, seed: rticket, tsLong: ts,
                        stateLong: ts, medusaDigest: [], urlBytes: Array("8662".utf8))
    }

    // MARK: - x-helios（C3.c 尾部那段 Long 循环）

    private func heliosHeader(ts: UInt64, rticket: UInt64) -> String {
        // "ts-646637794-8662" + PKCS5 填充到 16 倍数
        let plain = Array("\(ts)-646637794-8662".utf8)
        let padLen = 16 - (plain.count % 16)
        var buf = plain
        buf.append(contentsOf: [UInt8](repeating: UInt8(padLen), count: padLen))

        // 34 轮 Long 混淆，种子来自 body 相关 MD5 派生（此处用 rticket 派生占位）
        var longs: [UInt64] = []
        for i in stride(from: 0, to: buf.count - 1, by: 16) {
            let l1 = readLong(buf, at: i, littleEndian: true)
            let l2 = readLong(buf, at: min(i + 8, buf.count - 8), littleEndian: true)
            longs.append(l1)
            longs.append(l2)
        }
        var v1 = le64(ts)[0] != 0 ? ts : rticket
        var v2 = v1 ^ 0x646637794
        for i in 0..<34 {
            let x = (rotateRight64(v2, 8) &+ v1) ^ UInt64(i)
            longs.append(x)
            v1 = rotateRight64(v1, 61) ^ x
            v2 = x
        }
        var out = le64(v1)
        out.append(contentsOf: le64(v2))
        return base64Encode(out)
    }

    // MARK: - x-medusa（C3.b，极长分支选择器）

    private func medusaHeader(url: String, body: [UInt8]?, ts: UInt64) -> String {
        // 完整算法见 SIGNING_NOTES.md；此处给出已确认的结构骨架。
        let path = URL(string: url)?.path ?? url
        let pathBytes = Array(path.utf8)
        let urlHash = varlenHash(pathBytes) // F0.e1.b0（自由函数，非 DeviceFingerprint 成员），32 字节
        let bodyMD5 = body.map { md5($0) } ?? [UInt8](repeating: 0, count: 16)

        var input = [UInt8](repeating: 0, count: 52)
        input.replaceSubrange(0..<32, with: urlHash.prefix(32))
        input.replaceSubrange(32..<48, with: bodyMD5)
        input.replaceSubrange(48..<52, with: le32(ts))

        // medusa selector
        let sel = Int(crc64(Array("646637794".utf8)) ^ UInt64(truncatingIfNeeded: ts)) & 15
        let digest = MedusaBranch.run(selector: sel, input: input, ts: ts)
        var out = [UInt8](repeating: 0, count: 20)
        out.replaceSubrange(0..<16, with: digest)
        let trailer = le32(UInt32(truncatingIfNeeded: crc64(digest)))
        out.replaceSubrange(16..<20, with: trailer)
        out[16] |= 4
        out[16] |= 32
        return base64Encode(out)
    }
}
