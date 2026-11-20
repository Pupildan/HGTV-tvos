// HCSignerV5.swift
// 对应 Kotlin:crypto/Signer.kt(1.3.7 v5)+ VendorConstants.kt。
// 五件套:gorgonAligned / helios(license 646637794) / ladon(4B 随机) / argus(le32(ts)) / medusa v5(有状态)。
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// MARK: - VendorConstants(与 Kotlin VendorConstants.kt 同源)

enum HCVendor5 {
    static let videoVersionCode = "74332"
    static let appVersionCode = "72232"
    private static let defaultBuild = "BP2A.250605.031.A3"

    static let device: [String: String] = [
        "iid": "1905892595382586",
        "device_id": "1905892595378490",
        "ac": "wifi",
        "channel": "update_64",
        "aid": "8662",
        "app_name": "novelread",
        "version_code": "74332",
        "version_name": "7.4.3.32",
        "device_platform": "android",
        "os": "android",
        "ssmix": "a",
        "device_type": "25053RT47C",
        "device_brand": "Redmi",
        "language": "zh",
        "os_api": "36",
        "os_version": "16",
        "manifest_version_code": "74332",
        "resolution": "1280*2772",
        "dpi": "520",
        "update_version_code": "74332",
        "host_abi": "arm64-v8a",
        "dragon_device_type": "phone",
        "pv_player": "74332",
        "compliance_status": "0",
        "need_personal_recommend": "1",
        "player_so_load": "1",
        "is_android_pad_screen": "0",
    ]

    /// App 路径(搜索/分类/账号)的五项版本号改成 72232。
    static let appDevice: [String: String] = {
        var v = device
        v["version_code"] = "72232"
        v["version_name"] = "7.2.2.32"
        v["manifest_version_code"] = "72232"
        v["update_version_code"] = "72232"
        v["pv_player"] = "72232"
        return v
    }()

    static func headerSafe(_ value: String?, _ fallback: String) -> String {
        let filtered = (value ?? "").filter { $0.isASCII && ($0.asciiValue ?? 0) >= 0x20 && ($0.asciiValue ?? 0) <= 0x7e }
            .trimmingCharacters(in: .whitespaces)
        return filtered.isEmpty ? fallback : filtered
    }

    static func userAgent(_ device: [String: String], video: Bool) -> String {
        let version = video ? videoVersionCode : appVersionCode
        let os = headerSafe(device["os_version"], "16")
        let model = headerSafe(device["device_type"], "25053RT47C")
        let build = headerSafe(device["rom_version"], defaultBuild)
            .split(separator: " ").first.map(String.init) ?? defaultBuild
        if video {
            return "com.phoenix.read/\(version) (Linux; U; Android \(os); zh_CN; \(model); Build/\(build); Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"
        }
        return "com.phoenix.read/\(version) (Linux; U; Android \(os); zh_CN; \(model); Build/\(build))"
    }

    /// AesV3 用的 4×256 sbox(与 VendorConstants.sbox 同源,medusa v5 不直接用,播放解密用)。

    static let hashTable: [Int32] = [
        Int32(bitPattern: 0xebb64faf), 0x07aadcc2, Int32(bitPattern: 0xcf3187bf), Int32(bitPattern: 0xe01138ff), 0x6d0bfcff, 0x5a30a3be, Int32(bitPattern: 0xb41ad638), 0x34180eb8,
        Int32(bitPattern: 0xf233eb6f), Int32(bitPattern: 0xb1a584cc), Int32(bitPattern: 0xccc30dc7), 0x47d1db51, Int32(bitPattern: 0xd55653de), 0x70a84fa1, 0x57473c12, Int32(bitPattern: 0xf76f0288),
        0x2c077f0a, Int32(bitPattern: 0xda0dcad0), Int32(bitPattern: 0xfbb86f6c), Int32(bitPattern: 0xfdc4cf00), 0x688a020d, Int32(bitPattern: 0xe676c6a6), Int32(bitPattern: 0x8cd6338b), 0x1a3c8d0e,
        Int32(bitPattern: 0xcce8b06b), 0x6ad0ed0b, Int32(bitPattern: 0xa0522717), Int32(bitPattern: 0xdc71ac83), 0x2285db71, Int32(bitPattern: 0xd5b4dda6), 0x736f8650, 0x6560306c,
        0x617ce2a6, Int32(bitPattern: 0xe423417e), 0x0a40e143, 0x544e4032, Int32(bitPattern: 0x88dffb2a), 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
        Int32(bitPattern: 0xe1d0b866), Int32(bitPattern: 0xbaa3dcb8), Int32(bitPattern: 0xae3374d3), Int32(bitPattern: 0xc3381a50), 0x1702f75b, Int32(bitPattern: 0xfe6da368), Int32(bitPattern: 0xf0b4cf48), 0x4e0ffbb8,
        0x72aad10d, 0x26c53a3d, Int32(bitPattern: 0xf2bce0f6), Int32(bitPattern: 0xb4557581), 0x4a257fdd, Int32(bitPattern: 0x8c3182a2), Int32(bitPattern: 0xab0b3b86), 0x3d5dfb14,
        0x4f103634, Int32(bitPattern: 0xd37b52d7), 0x444eff16, Int32(bitPattern: 0xeb0a33d1), 0x6ca86f6e, 0x0028ba7, 0x08387cfa, 0x5fb37586,
    ]
}

// MARK: - Signer v5

/// 内部可变态（device / medusaStates）均由 NSLock 保护；跨 actor 共享安全。
final class HCSignerV5: @unchecked Sendable {
    private var device: [String: String]
    private let clock: () -> Int64
    private let rnd: () -> Double
    private let stateLock = NSLock()
    private var medusaStates: [String: HCAutonomousState] = [:]

    init(device: [String: String] = [:],
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         rnd: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.device = device.filter { !$0.value.isEmpty }
        self.clock = clock
        self.rnd = rnd
    }

    func updateDevice(_ values: [String: String]) {
        device = values.filter { !$0.value.isEmpty }
    }

    private func deviceValue(_ d: [String: String], _ key: String, _ fallback: String) -> String {
        if let v = d[key], !v.isEmpty { return v }
        return fallback
    }
    private func deviceId(_ d: [String: String]) -> String {
        deviceValue(d, "device_id", HCVendor5.device["device_id"] ?? "")
    }
    private func deviceType(_ d: [String: String]) -> String { deviceValue(d, "device_type", "25053RT47C") }
    private func deviceBrand(_ d: [String: String]) -> String { deviceValue(d, "device_brand", "Redmi") }
    private func manufacturer(_ d: [String: String]) -> String {
        let b = deviceBrand(d).lowercased()
        if b.contains("samsung") { return "Samsung" }
        if b.contains("redmi") || b.contains("xiaomi") { return "Xiaomi" }
        return deviceBrand(d)
    }

    struct Request {
        var url: String
        var headers: [String: String]
        var body: [UInt8]?
        var method: String
    }

    @inline(__always) private func kRand() -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: Int64(rnd() * 4294967296.0)))
    }

    private func getIv(_ initial: Int32, _ data: [UInt8]) -> Int32 {
        var value = initial
        for i in 0..<data.count {
            value = i & 1 == 0
                ? (kshr32(value, 4) ^ value ^ (value << 6) ^ Int32(data[i]))
                : kInv32(kshr32(value, 7) ^ value ^ (Int32(data[i]) | (value << 12)))
        }
        return value
    }
    private func iv(_ query: [UInt8], _ body: [UInt8], _ ts: Int32) -> Int32 {
        getIv(getIv(getIv(0x20230928, query), body), hcLe32(ts))
    }
    func branch(_ query: String, _ body: [UInt8]?, _ ts: Int32) -> Int32 {
        (iv(hcSm3(Array(query.utf8)), body != nil ? hcDigest("MD5", body!) : [UInt8](repeating: 0, count: 16), ts) & 15) % 3
    }

    private func sumMd5(_ data: [UInt8]) -> Int32 {
        var check: Int32 = 0x20220420
        for i in 0..<12 {
            let temp = kshr32(check, i & 1 == 0 ? 3 : 5) ^ check
            check = i & 1 == 0
                ? Int32(data[i]) ^ (check << 7)
                : kInv32(Int32(data[i]) | (check << 11))
            check ^= temp
        }
        return (check | 4) ^ 0x1000000
    }

    func hashF13(_ query: [UInt8], _ body: [UInt8], _ ts: Int32) -> [UInt8]? {
        let ivV = iv(query, body, ts)
        let index = Int((ivV & 15) / 3)
        guard (ivV & 15) % 3 == 0 else {
            DiagnosticsLogger.error("V5 hashF13: unsupported hash branch ivV=\(ivV)", category: "sign")
            return nil
        }
        let ivV1 = [Int32(bitPattern: 0xc4a78580), Int32(bitPattern: 0xb3c0fd39), Int32(bitPattern: 0xc58c5686),
                    Int32(bitPattern: 0xc9aa3ba7), Int32(bitPattern: 0xf5a7adf2), Int32(bitPattern: 0x963c2ed1)][index]
        let count = ivV1 &+ ts
        let tt = HCVendor5.hashTable.map { hcRor($0, (count &+ 1) & 255) }
        let shift = (count &+ 2) & 7
        let padBase: [Int32] = [0xfa, 0x45, 0x61, 0xd7]
        let pad = padBase.map { Int32(truncatingIfNeeded: kshr32($0 | ($0 << 8), shift)) }
        var data: [UInt8] = query
        data += (body ?? [])
        data += hcLe32(ts)
        data += pad.flatMap { hcLe32($0) }
        data += hcHexToBytes("00000000000001a0")
        var di = stride(from: 0, to: data.count, by: 4).map { hcI32(data, $0) }
        for i in 0..<112 {
            let x = di[i + 1]
            let y = di[i + 14]
            let a1 = hcRol(x, 14) ^ hcRol(x, 25) ^ kshr32(x, 3)
            let a2 = hcRol(y, 13) ^ hcRol(y, 15) ^ kshr32(y, 10)
            let sum = di[i] &+ di[i + 9] &+ a1 &+ a2
            di.append(sum)
        }
        let initialBase: [Int32] = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
                                    984304912, Int32(bitPattern: 3005047866), Int32(bitPattern: 2874125293), Int32(bitPattern: 2152413264)]
        let initial = initialBase.map { hcRor($0, count) }
        let chosen = [
            [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
            [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
            [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
            [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
            [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
            [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
        ][index].map { Int32($0) }
        var d = initial
        for i in 0..<Int(chosen[0]) {
            let base = ivV1 &+ Int32(i)
            let n1 = ((d[Int(chosen[3])] ^ d[Int(chosen[4])]) & d[Int(chosen[1])]) ^ d[Int(chosen[3])]
            let n2 = hcRol(d[Int(chosen[1])], 26) ^ hcRol(d[Int(chosen[1])], 21) ^ hcRol(d[Int(chosen[1])], 7)
            let n4 = di[Int(base & 127)] &+ n1 &+ n2 &+ tt[Int(base & 63)] &+ d[Int(chosen[5])]
            let n5 = hcRol(d[Int(chosen[2])], 30) ^ hcRol(d[Int(chosen[2])], 19) ^ hcRol(d[Int(chosen[2])], 10)
            let n6 = (d[Int(chosen[2])] & d[Int(chosen[6])]) | ((d[Int(chosen[2])] | d[Int(chosen[6])]) & d[Int(chosen[7])])
            let old = d[Int(chosen[9])]
            let removed = d.remove(at: 7)
            d.insert(removed, at: 0)
            d[Int(chosen[10])] = n5 &+ n6 &+ n4
            d[Int(chosen[8])] = old &+ n4
        }
        var ret = [UInt8]()
        for i in 0..<8 { ret += hcBe32(d[i] &+ initial[i]) }
        let folded = hcXor(Array(ret[0..<16]), Array(ret[16..<32]))
        return folded + hcLe32(sumMd5(folded))
    }

    func gorgon(_ query: String, _ body: [UInt8]?, _ ts: Int32, _ random: Int32) -> String {
        var input = Array(hcDigest("MD5", Array(query.utf8))[0..<4])
        input += body != nil ? Array(hcDigest("MD5", body!)[0..<4]) : [UInt8](repeating: 0, count: 4)
        input += [UInt8](repeating: 0, count: 4)
        input += hcLe32(67503104)
        input += hcBe32(ts)
        let key: [Int32] = [0x4a, 0x40, 0x16, kshr32(random, 8) & 255, 0x47, 0x6c, 1, random & 255]
        var s = [Int32](0...255)
        var j: Int32 = 0
        for i in 0...255 {
            j = (j &+ s[i] &+ key[i % 8]) & 255
            // Kotlin: s[i] = s[j]（赋值，非交换）
            s[i] = s[Int(j)]
        }
        j = 0
        var out = [UInt8](repeating: 0, count: input.count)
        for n in 0..<input.count {
            let i = n + 1
            j = (j &+ s[i]) & 255
            let y = s[Int(j & 255)]
            s[i] = y
            out[n] = UInt8(truncatingIfNeeded: Int32(input[n]) ^ Int32(s[Int((y &+ y) & 255)]))
        }
        for i in 0..<out.count {
            let value = ((Int32(out[i]) >> 4) | (Int32(out[i]) << 4)) & 255
            let nxt = Int32(out[i + 1 < out.count ? i + 1 : 0])
            // Kotlin Integer.reverse((next xor value) and 255) ushr 24 —— 8 位反转
            let rv = hcReverse8(UInt32(truncatingIfNeeded: (nxt ^ value) & 255))
            out[i] = UInt8(truncatingIfNeeded: kInv32(Int32(rv) ^ 20))
        }
        return hcBytesToHex(hcHexToBytes("8404") + [UInt8(truncatingIfNeeded: random), UInt8(truncatingIfNeeded: kshr32(random, 8)), 0x40, 1] + out)
    }

    /** 官方 7.4.3.32 前缀:8404 + rnd16 + 00 81。 */
    /** 官方 7.4.3.32 前缀:8404 + rnd16 + 00 81。 */
    func gorgonAligned(_ query: String, _ body: [UInt8]?, _ ts: Int32, _ random: Int32) -> String {
        var bytes = hcHexToBytes(gorgon(query, body, ts, random))
        bytes[4] = 0x00
        bytes[5] = 0x81
        return hcBytesToHex(bytes)
    }

    /** 官方 7.4.3.32 的 x-ladon:4 字节随机值。 */
    private func realLadon() -> String {
        var value = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { value[i] = UInt8.random(in: 0...255) }
        return hcBase64Encode(value)
    }
    /** 官方 7.4.3.32 的 x-argus:base64(le32(ts))。 */
    private func realArgus(_ ts: Int32) -> String { hcBase64Encode(hcLe32(ts)) }

    private func deviceProto(_ d: [String: String]) -> [UInt8] {
        let now = clock()
        func fInt(_ tag: Int32, _ v: Int64) -> [UInt8] { hcProtoField(tag, .sint(v)) }
        func fStr(_ tag: Int32, _ v: String) -> [UInt8] { hcProtoField(tag, .string(v)) }
        func fFloat(_ tag: Int32, _ v: Float) -> [UInt8] { hcProtoField(tag, .float(v)) }
        return fInt(1, 1) + fInt(2, 7) + fStr(3, "8662") + fStr(4, deviceId(d)) +
            fStr(5, "forged-token") + fStr(6, "forged-256") + fInt(7, 264) +
            fInt(8, 268) + fInt(9, 91) + fInt(10, 276) +
            fStr(11, "forged-296") + fStr(12, "Asia/Shanghai") + fStr(13, "zh_CN") +
            fInt(14, 8) + fStr(15, "forged-376") + fFloat(16, 8.0) +
            fFloat(17, 7.5) + fFloat(18, 6.5) + fFloat(19, 5.5) +
            fFloat(20, 4.5) + fFloat(21, 3.5) + fStr(22, "16") +
            fInt(23, 88) + fInt(24, 72) + fInt(25, now - 400) +
            fInt(26, now - 41) + fInt(27, now - 1000) + fInt(28, now) +
            fInt(29, 1) + fStr(30, deviceType(d)) + fStr(31, deviceBrand(d)) +
            fStr(32, "forged-board") + fStr(33, "forged-product") + fStr(34, "forged-device") +
            fStr(35, manufacturer(d)) + fStr(36, "forged-hardware") + fStr(37, "forged-648") +
            fInt(38, 648) + fInt(40, now - 321)
    }

    private enum HCProtoValue {
        case sint(Int64)
        case string(String)
        case float(Float)
    }
    private func hcProtoField(_ tag: Int32, _ value: HCProtoValue) -> [UInt8] {
        var out = [UInt8]()
        func varint(_ v: Int64) { hcMedusaVarint(&out, value: v) }
        switch value {
        case .sint(let n):
            varint(Int64(tag) << 3)
            // Kotlin: if (n < 0) -n*2-1 else n*2 —— sint32 zigzag(Long 语义)
            let x = n < 0 ? -n * 2 - 1 : n * 2
            varint(x)
        case .float(let f):
            varint(Int64(tag << 3) | 5)
            out += hcLe32(Int32(bitPattern: f.bitPattern))
        case .string(let s):
            varint((Int64(tag) << 3) | 2)
            let bytes = Array(s.utf8)
            varint(Int64(bytes.count))
            out += bytes
        }
        return out
    }

    func medusa(_ url: String, _ body: [UInt8]?, _ ts: Int32, _ d: [String: String]) -> String? {
        let did = deviceId(d)
        let token = deviceValue(d, "device_token", "")
        let key = "\(did)\u{0000}\(token)"
        let now = clock()
        stateLock.lock()
        let state: HCAutonomousState
        if let existing = medusaStates[key] {
            state = existing
        } else {
            let fresh = hcDefaultAutonomousState(did, token, nowMS: now)
            fresh.initialize(nowMS: now)
            medusaStates[key] = fresh
            state = fresh
        }
        stateLock.unlock()
        V5CrashBreadcrumbs.mark("V5 🧬 medusa 状态就绪，进入 generate")
        guard let out = state.generate(url: url, body: body, bodyMD5: nil, ts: Int64(UInt32(bitPattern: ts)), nowMS: now) else {
            DiagnosticsLogger.error("V5 medusa: generate 返回 nil（envelope/layout 降级）", category: "sign")
            return nil
        }
        V5CrashBreadcrumbs.mark("V5 🧬 medusa generate 完成 len=\(out.count)")
        return out
    }

    func helios(_ ts: Int32, licenseId: String = "646637794") -> String {
        let random = kRand()
        let ascii = Array(hcBytesToHex(hcDigest("MD5", hcLe32(random) + Array("8662".utf8))).utf8)
        // Kotlin: table = mutableListOf(words[0])（含 w0）；b0=words.removeAt(0)=w0；b8=words.removeAt(0)=w1
        var words = (0..<4).map { hcI64(ascii, $0 * 8, little: true) }
        var table = [words[0]]
        var b0 = words.removeFirst()
        var b8 = words.removeFirst()
        for i in 0..<34 {
            var x8 = (kror64(b8, 8) &+ b0) ^ Int64(i)
            words.append(x8)
            x8 = x8 ^ krotl64(b0, 61)
            table.append(x8)
            b0 = x8
            b8 = words.removeFirst()
        }
        let text = Array("\(ts)-\(licenseId)-8662".utf8)
        let padding = 16 - text.count % 16
        var data = text + [UInt8](repeating: UInt8(padding), count: padding)
        var output = hcLe32(random)
        var at = 0
        while at < data.count {
            var a = hcI64(data, at, little: true)
            var b = hcI64(data, at + 8, little: true)
            for i in 0..<34 {
                b = table[i] ^ (a &+ kror64(b, 8))
                a = b ^ krotl64(a, 61)
            }
            output += hcLe64(a) + hcLe64(b)
            at += 16
        }
        return hcBase64Encode(output)
    }

    static func encode(_ values: [String: String]) -> String {
        values.map { "\(hcEncodeQuery($0.key))=\(hcEncodeQuery($0.value))" }.joined(separator: "&")
    }

    func sign(_ base: String, _ values: [String: String], body: [UInt8]? = nil,
              method: String? = nil, deviceOverride: [String: String]? = nil) -> Request? {
        V5CrashBreadcrumbs.mark("V5 🔢 sign 开始 base=\(base) bodyLen=\(body?.count ?? 0)")
        var d = device
        if let ov = deviceOverride { d.merge(ov) { _, new in new } }
        d = d.filter { !$0.value.isEmpty }
        let now = clock()
        let ts = Int32(truncatingIfNeeded: now / 1000)
        var ticket = now
        for offset in 0...127 {
            ticket = now + Int64(offset)
            var merged = values
            merged["ts"] = String(ts)
            merged["_rticket"] = String(ticket)
            let query = HCSignerV5.encode(merged)
            if branch(query, body, ts) == 0 {
                V5CrashBreadcrumbs.mark("V5 🔢 分支命中 offset=\(offset)")
                let url = "\(base)?\(query)"
                let random = Int32(truncatingIfNeeded: Int64(rnd() * 65536.0))
                let passportPath = base.contains("/passport/")
                var headers = [String: String]()
                headers["User-Agent"] = HCVendor5.userAgent(d, video: body != nil)
                headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
                headers["x-ss-req-ticket"] = String(ticket)
                headers["x-tt-request-tag"] = "t=0;n=0"
                headers["sdk-version"] = "2"
                headers["passport-sdk-version"] = passportPath ? "5051452" : "6031190"
                headers["x-xs-from-web"] = "0"
                headers["x-khronos"] = String(ts)
                headers["x-ladon"] = realLadon()
                V5CrashBreadcrumbs.mark("V5 🔢 ladon/argus 完成")
                headers["x-argus"] = realArgus(ts)
                headers["x-gorgon"] = gorgonAligned(query, body, ts, random)
                V5CrashBreadcrumbs.mark("V5 🔢 gorgon 完成")
                headers["x-helios"] = helios(ts)
                V5CrashBreadcrumbs.mark("V5 🔢 helios 完成，进入 medusa")
                headers["x-medusa"] = medusa(url, body, ts, d) ?? ""
                V5CrashBreadcrumbs.mark("V5 🔢 medusa 完成")
                headers["x-tt-dt"] = ""
                if passportPath {
                    headers["x-vc-bdturing-sdk-version"] = "4.0.3.cn"
                    headers["lc"] = "101"
                    headers["x-ss-dp"] = "8662"
                }
                if body != nil {
                    headers["Content-Type"] = "application/json; charset=UTF-8"
                    headers["x-vc-bdturing-sdk-version"] = "4.0.3.cn"
                    let ridRaw: Int64 = Int64(rnd() * 2_000_000_000.0)
                    let rid = UInt32(bitPattern: Int32(truncatingIfNeeded: ridRaw))
                    headers["x-reading-request"] = "\(ticket)-\(rid)"
                    headers["x-ss-stub"] = hcBytesToHex(hcDigest("MD5", body!)).uppercased()
                }
                return Request(url: url, headers: headers, body: body,
                               method: method ?? (body == nil ? "GET" : "POST"))
            }
        }
        DiagnosticsLogger.error("V5 sign: 128 次尝试未找到可用分支，签名失败", category: "sign")
        return nil
    }
}

func hcEncodeQuery(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)?
        .replacingOccurrences(of: "+", with: "%20") ?? value
}

/// 8 位反转(Kotlin Integer.reverse(x & 255) ushr 24 等价)。
func hcReverse8(_ v: UInt32) -> UInt32 {
    var r: UInt32 = 0
    for i in 0..<8 {
        if (v >> UInt32(i)) & 1 != 0 { r |= 1 << UInt32(7 - i) }
    }
    return r
}
