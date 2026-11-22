// HCSignV5State.swift
// 对应 Kotlin:crypto/MedusaState.kt + MedusaEnvelope.kt。
// 有状态 medusa 生成器 + 信封加密(protobuf → obscure → 31 行位采样 → medusaSmall 补丁)。
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// MARK: - MedusaEnvelope.kt

@inline(__always) private func hcRotateLeft8(_ value: Int32, _ n: Int32) -> Int32 {
    let x = value & 0xFF
    let s = n & 7
    return s == 0 ? x : ((x << s) | kshr32(x, 8 - s)) & 0xFF
}

/** Go medusaExpand:16 字节 key 扩成 48 字节轮密钥。 */
private func hcMedusaExpand(_ key: [UInt8], _ variant: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 48)
    for i in 0..<key.count {
        out[i] = UInt8(truncatingIfNeeded: Int32(key[i]) ^ Int32((kshr64(hcMedusaRcon[variant], Int64(8 * (i % 4)))) & 0xFF))
    }
    for word in 4..<12 {
        var t = [
            Int32(out[4*word-4]), Int32(out[4*word-3]), Int32(out[4*word-2]), Int32(out[4*word-1]),
        ]
        if word % 4 == 0 {
            t = [
                hcMedusaSboxes[variant][Int(t[1])], hcMedusaSboxes[variant][Int(t[2])],
                hcMedusaSboxes[variant][Int(t[3])], hcMedusaSboxes[variant][Int(t[0])],
            ]
            let mask: Int64 = variant == 3 ? 249 : 255
            let extra = Int32(truncatingIfNeeded: (kshr64(hcMedusaRcon[variant], Int64((word << 1) & 24)) & mask) & 0xFF)
            t[0] = t[0] ^ extra
        }
        for j in 0..<4 {
            out[word*4+j] = UInt8(truncatingIfNeeded: t[j] ^ Int32(out[4*(word-4)+j]))
        }
    }
    return out
}

private func hcMedusaAddKey(_ s: inout [UInt8], _ key: [UInt8], _ variant: Int) {
    for i in stride(from: 0, to: 16, by: 4) {
        for j in 0..<4 {
            s[i+j] = s[i+j] ^ key[i + Int(hcMedusaPerms[variant][j])]
        }
    }
}

private func hcMedusaShift(_ variant: Int) -> [Int] {
    let old = (0..<16).map { 4 * Int(hcMedusaPerms[variant][$0 / 4]) + $0 % 4 }
    var out = old
    let swaps = [1, 9, 5, 13, 9, 1, 13, 5, 2, 14, 6, 2, 10, 6, 14, 10]
    var k = 0
    while k < swaps.count {
        out[swaps[k]] = old[swaps[k+1]]
        k += 2
    }
    let dsts = [3, 7, 11, 15]
    for i in 0..<dsts.count {
        out[dsts[i]] = old[Int(hcMedusaRow3[variant][i])]
    }
    return out
}

private func hcMedusaSubShift(_ s: inout [UInt8], _ variant: Int) {
    let old = s
    let shift = hcMedusaShift(variant)
    for i in 0..<16 {
        s[i] = UInt8(truncatingIfNeeded: hcMedusaSboxes[variant][Int(old[shift[i]])])
    }
}

@inline(__always) private func hcMedusaXtime(_ b: Int) -> Int {
    (b & 128) != 0 ? ((b << 1) ^ 0x1b) & 0xFF : (b << 1) & 0xFF
}

private func hcMedusaMix(_ s: inout [UInt8], _ variant: Int) {
    var t = [Int](repeating: 0, count: 16)
    for i in stride(from: 0, to: 16, by: 4) {
        for j in 0..<4 {
            t[i+j] = Int(s[i + Int(hcMedusaPerms[variant][j])])
        }
    }
    for lane in 0..<4 {
        let a = t[lane], b = t[lane+4], c = t[lane+8], d = t[lane+12]
        s[lane] = UInt8(hcMedusaXtime(a) ^ hcMedusaXtime(b) ^ b ^ c ^ d)
        s[lane+4] = UInt8(a ^ hcMedusaXtime(b) ^ hcMedusaXtime(c) ^ c ^ d)
        s[lane+8] = UInt8(a ^ b ^ hcMedusaXtime(c) ^ hcMedusaXtime(d) ^ d)
        s[lane+12] = UInt8(hcMedusaXtime(a) ^ a ^ b ^ c ^ hcMedusaXtime(d))
    }
}

private func hcMedusaSmall(_ data: [UInt8], _ variant: Int, _ key: [UInt8], _ iv: [UInt8]) -> [UInt8] {
    let keys = hcMedusaExpand(key, variant)
    let pad = 16 - data.count % 16
    var plain = data
    plain += [UInt8](repeating: UInt8(pad), count: pad)
    var state = iv
    var out = [UInt8]()
    out.reserveCapacity(plain.count)
    var off = 0
    while off < plain.count {
        var s = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { s[i] = plain[off+i] ^ state[i] }
        hcMedusaAddKey(&s, Array(keys[0..<16]), variant)
        hcMedusaSubShift(&s, variant)
        hcMedusaMix(&s, variant)
        hcMedusaAddKey(&s, Array(keys[16..<32]), variant)
        hcMedusaSubShift(&s, variant)
        hcMedusaAddKey(&s, Array(keys[32..<48]), variant)
        for i in 0..<16 {
            state[i] = s[i] ^ keys[16+i]
        }
        out += state
        off += 16
    }
    return out
}

private func hcMedusaObscure(_ plain: [UInt8], _ digest: [UInt8]) -> [UInt8]? {
    var a = [UInt8](repeating: 0, count: plain.count)
    for i in 0..<plain.count {
        let k0 = Int(digest[(4 * i) % 32])
        let k1 = Int(digest[(4 * i + 1) % 32])
        let x = (~(Int(hcRotateLeft8(Int32(plain[i]), 4)) &+ k0) & 0xFF) ^ k1
        a[a.count - 1 - i] = UInt8((~(Int(hcRotateLeft8(Int32(x & 0xFF), 3)) &+ k1) & 0xFF) ^ k0)
    }
    let last = a.count - 1
    guard last >= 2 else {
        DiagnosticsLogger.error("V5 medusa: protobuf too short (\(plain.count))", category: "sign")
        return nil
    }
    a[0] = a[0] &+ ~(a[last] ^ a[last-1])
    a[1] = a[1] &+ (a[last] ^ a[0] ^ 254)
    for i in 0..<(a.count - 3) {
        let mixed = ~(Int(a[i]) ^ Int(hcRotateLeft8(Int32(a[i+1]), 3)) ^ (i + 2)) & 0xFF
        a[i+2] = a[i+2] &+ UInt8(mixed)
    }
    a[last] = a[last] ^ a[last-1]
    var sum = 0
    for i in 1..<a.count { sum = (sum + Int(a[i])) & 0xFF }
    a[0] = (a[0] ^ a[1]) &+ UInt8(sum)
    return a
}

/** 返回 (layout, tail)。layout[i] = [offset, bitGroup]。inner 长度不在支持范围时返回 nil（调用方降级，勿 crash）。 */
private func hcMedusaLayout(_ n: Int) -> ([[Int]], Int)? {
    V5CrashBreadcrumbs.mark("V5 🧬 layout n=\(n)")
    if n == 11 {
        let layout = (0..<8).map { [0, $0] }
        return (layout, 7)
    }
    if n >= 248 {
        let layout = (0..<31).map { [$0 * 8, 0] }
        return (layout, 31)
    }
    DiagnosticsLogger.error("V5 medusa: unsupported inner length \(n)", category: "sign")
    return nil
}

func hcMedusaEnvelope(
    _ plain: [UInt8],
    timestamp: Int64,
    nonce: Int64,
    flags: Int64,
    prefix: [UInt8],
    mode: Int,
    key: [UInt8],
) -> String? {
    if mode == 1 {
        DiagnosticsLogger.error("V5 medusa: SDK mode 1 has no supported signature", category: "sign")
        return nil
    }
    V5CrashBreadcrumbs.mark("V5 🧬 envelope 开始 plainLen=\(plain.count) mode=\(mode)")
    let n = hcLe32(Int32(truncatingIfNeeded: nonce))
    let f = hcLe64(flags)
    let digest = hcSm3(key + n + key)
    var mixed = [UInt8]()
    if mode == 0 {
        guard let obscured = hcMedusaObscure(plain, digest) else { return nil }
        let m = prefix + obscured
        // Kotlin be32(medusaAP(n[2..4], 0, 7, 3, 11, 5).toInt() —— .toInt() 截断
        let mask = hcBe32(Int32(truncatingIfNeeded: hcMedusaAP(Array(n[2..<4]), initial: 0, 7, 3, 11, 5)))
        mixed = (0..<m.count).map { m[m.count - 1 - $0] ^ mask[$0 % 4] }
    }
    var inner: [UInt8] = [UInt8(truncatingIfNeeded: hcMedusaAP(key, initial: 0, 7, 3, 11, 5))]
    inner += f + mixed + Array(n[2..<4])
    guard let (layout, tail) = hcMedusaLayout(inner.count) else { return nil }
    var small = [UInt8](repeating: 0, count: 31)
    for i in 0..<layout.count {
        for j in 0..<hcMedusaSelect.count {
            let sel = hcMedusaSelect[j]
            // Kotlin: ushr ((sel[1] + layout[i][1]) and 7) —— 移位量必须 &7，否则 UInt8 移位 ≥8 触发 runtime trap
            let bit = (inner[layout[i][0] + Int(sel[0])] >> UInt8((Int(sel[1]) + layout[i][1]) & 7) & 1) & 1
            small[i] = small[i] | (UInt8(bit) << j)
        }
    }
    let cipher = hcMedusaSmall(
        small,
        Int(timestamp & 3),
        Array(hcDigest("MD5", Array(key[0..<16]))),
        Array(hcDigest("MD5", Array(key[16..<32]))),
    )
    var patched = inner
    for i in 0..<layout.count {
        for p in hcMedusaPatch {
            let at = layout[i][0] + Int(p[1])
            let bit = (Int(p[2]) + layout[i][1]) & 7
            let cipherBit = (Int(cipher[i]) >> Int(p[0])) & 1
            patched[at] = UInt8((Int(patched[at]) & ~(1 << bit)) | (cipherBit << bit))
        }
    }
    var outer = [UInt8]()
    for word: Int64 in [Int64(5), Int64(bitPattern: 0xca4f4b2d), Int64(bitPattern: 0x430d7549), Int64(bitPattern: 0x2caeb53f), Int64(bitPattern: 0x56cc6d22)] {
        outer += hcLe32(Int32(truncatingIfNeeded: timestamp ^ word))
    }
    outer += Array(n[0..<2])
    outer.append(0)
    outer.append(UInt8(cipher.count - tail))
    outer += Array(cipher[tail...])
    outer += patched
    return hcBase64Encode(outer)
}

// MARK: - MedusaState.kt

private let hcMedusaRootMagic: [UInt8] = [
    45, 75, 79, 202, 73, 117, 13, 67, 63, 181, 174, 44, 34, 109, 204, 86,
]

private let hcMedusaDefaultKey: [UInt8] = [
    178, 60, 42, 71, 10, 32, 209, 5, 220, 63, 140, 68, 56, 248, 39, 46,
    212, 109, 108, 137, 255, 220, 222, 221, 81, 8, 105, 141, 38, 233, 72, 157,
]

private let hcMedusaFLTable: [UInt8] = [
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
]

private func hcReadLe32(_ data: [UInt8], _ at: Int) -> Int64 {
    Int64(data[at]) | (Int64(data[at+1]) << 8) | (Int64(data[at+2]) << 16) | (Int64(data[at+3]) << 24)
}

func hcMedusaCRC64(_ data: [UInt8]) -> Int64 {
    var h: Int64 = 0
    let poly = Int64(bitPattern: 0x95ac9329ac4bc9b5)
    for b in data {
        var x = Int64((h ^ Int64(b)) & 0xFF)
        for _ in 0..<8 {
            x = (x & 1) != 0 ? kshr64(x, 1) ^ poly : kshr64(x, 1)
        }
        h = x ^ kshr64(h, 8)
    }
    return h
}

func hcMedusaQuery(_ url: String) -> String {
    let s = url.components(separatedBy: "#")[0]
    guard let at = s.firstIndex(of: "?") else { return "" }
    return String(s[s.index(after: at)...])
}

struct HCMedusaFLProcess {
    var fl: [Int32] = [Int32](repeating: 0, count: 9)
    var record0: Int64
    var record8: Int64
}

func hcApplyFLStages(_ p: inout HCMedusaFLProcess, _ stages: [Int32]) {
    for n in stages {
        switch n {
        case 2:
            p.fl[2] = Int32(truncatingIfNeeded: (UInt64(bitPattern: p.record0) ^ (UInt64(bitPattern: p.record0) >> 32)))
        case 3:
            p.fl[3] = p.fl[2].byteSwapped
        case 4:
            var b = [UInt8](repeating: 0, count: 8)
            b.replaceSubrange(0..<4, with: hcLe32(p.fl[3]))
            p.fl[4] = Int32(truncatingIfNeeded: hcMedusaAP(b, initial: 0x201507, 6, 4, 12, 7))
        case 5:
            var x = p.fl[4]
            for bit in [Int64(0), Int64(1)] {
                if (p.record8 & (1 << bit)) != 0 { x = krotl32(x, 1) }
            }
            var v: Int32 = 0
            for i in 0..<4 {
                v = v | (Int32(hcMedusaFLTable[Int(kshr32(x, Int32(i * 8))) & 63]) << (i * 8))
            }
            p.fl[5] = v
        case 6:
            let ux = UInt32(bitPattern: p.fl[5])
            let x = ux ^ (ux << 13)
            let y = Int32(bitPattern: x ^ (x >> 17))
            p.fl[6] = y ^ (y << 5)
        default:
            break
        }
        p.record8 |= (1 << Int64(n))
    }
}

struct HCMedusaResult {
    let header: String
    let tls: Int64
    let record8: Int64
    let selector: Int32
    let digest: [UInt8]
    let protobuf: [UInt8]
}

/** Go MedusaDetailed。 */
func hcMedusaDetailed(
    url: String,
    i: HCMedusaIdentity,
    d: HCMedusaDevice,
    s: HCMedusaSdk,
    thread: HCMedusaThread,
    o: HCMedusaOptions,
) -> HCMedusaResult? {
    let rnd: [Int64] = o.random ?? {
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { b[i] = UInt8.random(in: 0...255) }
        return (0..<3).map { hcReadLe32(b, $0 * 4) & 0x7fffffff }
    }()
    V5CrashBreadcrumbs.mark("🧬 detailed 开始")
    var process = thread.process
    process.record8 |= 256
    // Kotlin: rotateLeft(tokenPointerTLS xor crc64(license) xor ts, 4) & 0xFFFFFFFF
    let tlsMask = krotl64(thread.tokenPointerTLS ^ hcMedusaCRC64(Array(i.licenseID.utf8)) ^ (o.timestamp & Int64(0xFFFFFFFF)), 4) & Int64(0xFFFFFFFF)
    var tls = (thread.tls ^ tlsMask) & Int64(0xFFFFFFFF)
    V5CrashBreadcrumbs.mark("🧬 tls/crc64 完成")

    let stub = o.bodyMD5 ?? ((o.body != nil && o.body!.count > 0) ? hcDigest("MD5", o.body!) : [UInt8](repeating: 0, count: 16))
    let query = Array(hcMedusaQuery(url).utf8)
    let qh = hcSm3(query)
    V5CrashBreadcrumbs.mark("🧬 sm3 完成 queryLen=\(query.count)")
    var data = [UInt8](repeating: 0, count: 52)
    for k in 0..<32 { data[k] = qh[k] }
    for k in 0..<16 { data[32+k] = stub[k] }
    data.replaceSubrange(48..<52, with: hcLe32(Int32(truncatingIfNeeded: o.timestamp & Int64(0xFFFFFFFF))))
    let selector = Int32(truncatingIfNeeded: hcMedusaAP(data, initial: 0x20230928, 6, 4, 12, 7) & 15)
    V5CrashBreadcrumbs.mark("🧬 selector=\(selector)，进入 core")
    let dgst = hcMedusaTail(hcMedusaCore(data, selector: selector, timestamp: o.timestamp), checks: s.requestChecks)
    V5CrashBreadcrumbs.mark("🧬 core/tail 完成")

    var detection: Int64 = 0
    for n in s.detectionTypes { detection |= (1 << Int64(n & 31)) }
    let prefix = hcLe64(detection)
    let root17 = Int32(truncatingIfNeeded: o.timestamp & Int64(0xFFFFFFFF))

    var v = [Int32: Any]()
    v[1] = hcMedusaRootMagic
    v[2] = Int64(5)
    v[3] = rnd[0] & 0xFFFFFFFF
    v[4] = i.aid
    v[5] = i.deviceID
    v[6] = i.licenseID
    v[7] = i.appVersion
    v[8] = i.sdkPlatform
    v[9] = Int64(0x040A0300)
    v[10] = prefix
    v[11] = Int64(0)
    v[12] = o.timestamp
    v[13] = dgst
    v[14] = Array(qh[0..<6])
    v[15] = [
        Int32(1): Int64(s.maps.integer("04b29480233f4def5c875875b6bdc3b1")),
        Int32(2): Int64(s.maps.integer("e98d2f001da5678b39482efbdf5770dc")),
        Int32(3): Int64(s.maps.integer("7dc22b2c6a992f0232345df41303f5ea")),
        Int32(4): Int64(s.maps.integer("f0036511a681da731501008a14354fa3")),
        Int32(5): Int64(s.maps.integer("73e41d5295b696cc41657fef7bba312e")),
    ] as [Int32: Any]
    v[16] = i.token
    v[17] = Int64(root17)
    v[20] = "none"
    v[21] = Int64(Int32(truncatingIfNeeded: s.configMask & 0xfffffff))
    v[22] = s.root22
    v[23] = hcMedusaContext(i, d, s, HCMedusaThread(tls: tls, firstTPIDR: thread.firstTPIDR, callbackAddress: thread.callbackAddress, pointerGap: thread.pointerGap, tokenPointerTLS: thread.tokenPointerTLS, tokenPointerLP: thread.tokenPointerLP, process: process), o)
    v[24] = hcMedusaEnvironment(i, s, HCMedusaThread(tls: tls, firstTPIDR: thread.firstTPIDR, callbackAddress: thread.callbackAddress, pointerGap: thread.pointerGap, tokenPointerTLS: thread.tokenPointerTLS, tokenPointerLP: thread.tokenPointerLP, process: process))

    let plain = hcMedusaPB(v, schema: hcMedusaSchema)
    V5CrashBreadcrumbs.mark("V5 🧬 PB 完成 plainLen=\(plain.count)")
    DiagnosticsLogger.warn("V5 🧬 PB hex=0x\(plain.map { String(format: "%02x", $0) }.joined())", category: "sign")
    let f0: Int64 = 3 << 59
    let f1: Int64 = Int64(qh[0] & 63) << 46
    let f2: Int64 = Int64(dgst[0] & 63) << 40
    let f3: Int64 = 1 << 32
    let f4: Int64 = rnd[2] & 0xFFFFFFFF
    let flags: Int64 = f0 | f1 | f2 | f3 | f4
    guard let header = hcMedusaEnvelope(plain, timestamp: o.timestamp, nonce: rnd[1], flags: flags, prefix: prefix, mode: 0, key: hcMedusaDefaultKey) else {
        DiagnosticsLogger.error("V5 🧬 envelope 返回 nil", category: "sign")
        return nil
    }
    V5CrashBreadcrumbs.mark("V5 🧬 envelope 完成")
    return HCMedusaResult(header: header, tls: tls, record8: process.record8, selector: selector, digest: dgst, protobuf: plain)
}

/** TLS 输入值:Int32(bitPattern: 0xb462c5a0) 与 ts 的预抵消量。 */
private func hcMedusaTlsInput(_ licenseID: String, _ ts: Int64) -> Int64 {
    let crc = hcMedusaCRC64(Array(licenseID.utf8)) ^ (ts & 0xFFFFFFFF)
    let rotated: Int64 = krotl64(crc, 4) & 0xFFFFFFFF
    return Int64(0xb462c5a0 ^ rotated)
}

/** 每个 (device_id, device_token) 一份 Medusa 状态,跨请求推进。 */
final class HCAutonomousState {
    let identity: HCMedusaIdentity
    let device: HCMedusaDevice
    let sdk: HCMedusaSdk
    var process: HCMedusaProcessState
    var requestCount: Int64
    var random: [Int64]
    var randomFunc: (() -> [Int64])? = nil

    init(identity: HCMedusaIdentity, device: HCMedusaDevice, sdk: HCMedusaSdk,
         process: HCMedusaProcessState, requestCount: Int64, random: [Int64]) {
        self.identity = identity
        self.device = device
        self.sdk = sdk
        self.process = process
        self.requestCount = requestCount
        self.random = random
    }

    func initialize(nowMS: Int64) {
        process.record0 = nowMS
        process.record8 = 0x83
        var p = HCMedusaFLProcess(record0: process.record0, record8: process.record8)
        hcApplyFLStages(&p, [2, 3, 4, 5, 6])
        process.record8 = p.record8
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { b[i] = UInt8.random(in: 0...255) }
        for i in 0..<3 { random[i] = hcReadLe32(b, i * 4) & 0x7fffffff }
    }

    func generate(url: String, body: [UInt8]?, bodyMD5: [UInt8]?, ts: Int64, nowMS: Int64) -> String? {
        generateDetailed(url: url, body: body, bodyMD5: bodyMD5, ts: ts, nowMS: nowMS)?.header
    }

    func generateDetailed(url: String, body: [UInt8]?, bodyMD5: [UInt8]?, ts: Int64, nowMS: Int64) -> HCMedusaResult? {
        var integers = sdk.maps.integers
        integers[HCAutonomousState.keyC1] = Int32(truncatingIfNeeded: requestCount)
        var sdkCopy = sdk
        sdkCopy.maps = HCMedusaConfigMaps(integers: integers, longs: sdk.maps.longs, strings: sdk.maps.strings)
        var processCopy = HCMedusaFLProcess(record0: process.record0, record8: process.record8)
        hcApplyFLStages(&processCopy, [2, 3, 4, 5, 6])
        let thread = HCMedusaThread(
            tls: hcMedusaTlsInput(identity.licenseID, ts),
            firstTPIDR: process.firstTPIDR,
            callbackAddress: process.callbackAddress,
            pointerGap: process.pointerGap,
            tokenPointerTLS: process.tokenPointerTLS,
            tokenPointerLP: process.tokenPointerLP,
            process: process,
        )
        if let injected = randomFunc?() {
            random = injected
        } else {
            var fresh = [UInt8](repeating: 0, count: 12)
            for i in 0..<12 { fresh[i] = UInt8.random(in: 0...255) }
            for i in 0..<3 { random[i] = hcReadLe32(fresh, i * 4) & 0x7fffffff }
        }
        let options = HCMedusaOptions(
            timestamp: ts,
            timeMS: nowMS,
            body: body,
            bodyMD5: bodyMD5,
            random: random,
        )
        guard let result = hcMedusaDetailed(url: url, i: identity, d: device, s: sdkCopy, thread: thread, o: options) else {
            DiagnosticsLogger.error("V5 medusa: detailed generation failed (envelope/layout)", category: "sign")
            return nil
        }
        requestCount += 1
        // Kotlin:process.record8 = processCopy.record8 —— medusaDetailed 里已 |= 256
        process.record8 = result.record8
        return result
    }

    static let keyC1 = "04b29480233f4def5c875875b6bdc3b1"
}

/** Go DefaultAutonomousState:与官方 7.4.3.32 稳定态一致的初始档案。
    v71：设备字段按身份档案注入——此前硬编码 HONOR VER-AN00/Android 12，
    与身份注册档案（SM-F7310/samsung/Android 16）不一致；landpage 严格校验
    medusa 设备字段 × 注册指纹一致性 → 拒绝（0B）。真机 SM-F7310 getprop 实锤。 */
func hcDefaultAutonomousState(_ deviceID: String, _ token: String, nowMS: Int64, processID: Int32 = 1,
                              profile: [String: String]? = nil) -> HCAutonomousState {
    let p = profile ?? [:]
    let model = p["device_type"] ?? "VER-AN00"
    let brand = p["device_brand"] ?? "HONOR"
    // 真机 SM-F7310（Galaxy Z Flip5）getprop 实锤：device=b5q product=b5qzcx
    // board=kalama hardware=qcom。其他机型暂用默认（主用身份即 SM-F7310）。
    let isFlip5 = model == "SM-F7310"
    let shortToken = hcMedusaShortToken(deviceToken: token, deviceID: deviceID)
    let identity = HCMedusaIdentity(
        aid: "8662",
        deviceID: deviceID,
        licenseID: "646637794",
        appVersion: "7.4.3.32",
        sdkVersion: "v04.10.03.04-bugfix",
        channel: "69310258a",
        token: shortToken,
        sdkPlatform: "v04.10.03-ml-android",
    )
    let device = HCMedusaDevice(
        collectionState: 2,
        cache256: "!noperm!",
        timezone: "Asia/Shanghai,8",
        locale: "zh_CN",
        cpuCoreCount: 3,
        // 真机 float 原始位（hook ground truth），勿改成直觉上的存储容量
        storageRAMGiB: [Float(bitPattern: 1123679104), Float(bitPattern: 1123272447),
                        Float(bitPattern: 1081505568), Float(bitPattern: 1036126208),
                        Float(bitPattern: 1132067712), Float(bitPattern: 1131661055)],
        androidRelease: p["os_version"] ?? "16",
        brightness: 102,
        systemVolume: 5,
        usbConnected: -1,
        model: model,
        brand: brand,
        board: "kona",
        product: "arm64_mac_qemu",
        device: "OnePlus8Pro",
        manufacturer: "OnePlus",
        hardware: "unknown",
        featureBits: 21,
        extra7: -888888,
        extra8: -888888,
        extra9: 2,
        extra10: -888888,
        extra11: "!notset!",
        physicalSize: "Physical size: 1080x1226",
    )
    let sdk = HCMedusaSdk(
        configMask: 312,
        processID: 22088,
        parentProcessID: 2113,
        detectionTypes: [2, 8, 10, 15],
        cmr: 16777216,
        cmr2: 16777216,
        unH: 1893996536,
        vpn: 0,
        sts: 32251,
        fkd: 2187746471,
        pd: 1417818606,
        startedAtSeconds: Int32(truncatingIfNeeded: nowMS / 1000),
        clockValue: 27,
        maps: HCMedusaConfigMaps(
            integers: [
                "45ca7e170e474edadd7d40972a193ace": 247235599,
                "f866b105da86ad7edbaf9846a68fdbab": 247235596,
                "593fa435c8460ab2ac0b86b32e28de66": 7,
                "04b29480233f4def5c875875b6bdc3b1": 1,
                "e98d2f001da5678b39482efbdf5770dc": 5,
                "7dc22b2c6a992f0232345df41303f5ea": 694367,
                "f0036511a681da731501008a14354fa3": 0,
                "73e41d5295b696cc41657fef7bba312e": 281826712,
                "cede084aa3812c79e4614ee74ba582dd": -780914011,
                "30c8cb0fcd3ea4c95cfd5170df341924": -780914011,
                "167774bf518c11948aa0784351ccf5a9": 0,
            ],
            longs: ["fd8d1a41d3c56026d47f1f8ba146eb99": 2491],
            strings: ["fa4c0a5bbd8dcedf5ee28719c5bb1df1": ""],
        ),
        requestChecks: HCDigestChecks(configCount: 1),
    )
    let process = HCMedusaProcessState(
        fl: [Int32](repeating: 0, count: 9),
        record0: nowMS,
        record8: 0x83,
    )
    // Kotlin process.firstTPIDR=491512328192 callbackAddress=491857043860 pointerGap=1804 tokenPointerLP=495781201056
    var st = HCAutonomousState(
        identity: identity, device: device, sdk: sdk, process: process,
        requestCount: 1, random: [1234567, 2345678, 3456789],
    )
    st.process.firstTPIDR = 491512328192
    st.process.callbackAddress = 491857043860
    st.process.pointerGap = 1804
    st.process.tokenPointerTLS = 0
    st.process.tokenPointerLP = 495781201056
    return st
}
