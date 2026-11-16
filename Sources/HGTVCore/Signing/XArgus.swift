// XArgus.swift
// X-Argus / X-Ladon / X-Khronos 头生成。
//
// dex 里 x-argus 有两条路径（都在 LF0/C3.c，约 1319-1330 行）：
//   1) 简化路径（Java 层实际走的）：x-argus = base64(le32(ts))，4 字节。
//   2) x-ladon = base64(4 字节 SecureRandom)。
//   3) x-khronos = String.valueOf(ts)。
//
// 注意：真实番茄客户端抓包里 x-argus 长度通常 ~28+ 字符，与简化路径的
// 8 字符 base64 不符 → 生产环境很可能走 TTNet 原生 libsgmain 的 argus，
// Java 层这段只是兜底/降级。这里忠实复刻 Java 层。

import Foundation

public enum XArgus {
    /// C3.c 简化路径：x-argus = base64(le32(ts))
    public static func simple(ts: UInt64) -> String {
        base64Encode(le32(UInt32(truncatingIfNeeded: ts)))
    }

    /// 完整 argus（libsgmain 原生）—— dex 静态分析无法还原，见 SIGNING_NOTES.md。
    public static func full(ts: UInt64, query: String, body: [UInt8]?) -> String {
        _ = (ts, query, body)
        return simple(ts: ts)
    }

    /// F0.e1.y("8404")：x-gorgon 前缀。
    /// ⚠️ dex 里 y() 是 base64 变体解码，"8404" 只是字面量 → 解码后为空。
    /// 真实前缀来自常量池里另一段 base64 字符串（未导出），此处返回空占位。
    public static func prefix8404() -> [UInt8] { [] }

    /// medusa 20 字节摘要尾（C3.b 833-846）
    public static func medusaDigest(selector: Int, input52: [UInt8], ts: UInt64) -> [UInt8] {
        let digest = MedusaBranch.run(selector: selector, input: input52, ts: ts)
        var out = [UInt8](repeating: 0, count: 20)
        out.replaceSubrange(0..<16, with: digest.prefix(16))
        let trailer = MedusaSerializer.F(Array(digest.prefix(12)), 539100192, 7, 3, 11, 5)
        out[16] = jbyte(trailer)
        out[17] = jbyte(trailer >> 8)
        out[18] = jbyte(trailer >> 16)
        out[19] = jbyte(trailer >> 24)
        out[16] |= 4
        out[16] |= 32
        return out
    }
}

/// F0.e1.y：base64 解码（标准字母表，'-'→'+', '_'→'/'，遇 '=' 停）
public func base64Decode(_ s: String) -> [UInt8] {
    let cleaned = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    var out = [UInt8]()
    var val = 0
    var bits = 0
    for ch in cleaned {
        if ch == "=" { break }
        guard let idx = base64Alphabet.firstIndex(of: ch) else { continue }
        val = (val << 6) | base64Alphabet.distance(from: base64Alphabet.startIndex, to: idx)
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((val >> bits) & 0xFF))
        }
    }
    return out
}

// MARK: - X-Gorgon medusa 分支（C3.b 512-832）

/// medusa selector = (l0.F(input52, 539167016, 6, 4, 12, 7) & 15)
/// u1.a / u1.b / u1.c 三个注册表决定走 MD5 变体、SHA-256 变体还是 128 字节块轮函数。
/// dex 里这些分支的常量表（e1.b/c/d/e/f/g/h/i/j/k）已导出，但 W3/M3/D1 里的
/// 基准偏移字段（v2_81.a / v2_84.a / v5_36.c / v5_36.d）未在 signing_full.txt 里，
/// 无法确定 rotateLeft 的实际偏移量 → 分支骨架在此，常量数值待补。
public enum MedusaBranch {
    public static func run(selector: Int, input: [UInt8], ts: UInt64) -> [UInt8] {
        switch selector {
        case 0...7:
            return md5Variant(input: input, ts: ts, selector: selector)
        case 8...15:
            // 含 SHA-256 变体（8..11）与自定义 128 字节块轮函数（12..15）
            return sha256Variant(input: input, ts: ts, selector: selector)
        default:
            return [UInt8](repeating: 0, count: 32)
        }
    }

    /// MD5 变体（C3.b 641-721）
    /// 结构：
    ///   base = W3.a + ts
    ///   state[4] = rotateLeft(e1.e[i], -base)
    ///   K[64]    = rotateLeft(e1.f[i], -((i/16) + base + 1))
    ///   额外 8 字节 = u1.c(e1.g[i], -(base+5))
    ///   消息块 64 字节 = input52 + e1.g 派生 8 字节 + 大端 bitlen(416)
    ///   末尾 state[i] ^= rotateLeft(e1.h[i], -(base+6))
    /// 布尔函数（dex 694-706）：
    ///   i<16: ((b^c)&d)^c     i<32: ((b^c)&d)^c
    ///   i<48: (b^c)^d         i>=48: c^(b|(d^0xFFFFFFFF))
    private static func md5Variant(input: [UInt8], ts: UInt64, selector: Int) -> [UInt8] {
        // base = W3.a（u1.b 表按 selector 选条目；C3.b: rotateLeft(e1.f, W3.a)）
        // 已从 LF0/u1.<clinit> 解码（见 U1Constants.swift）
        let w3 = U1W3.entries[abs(selector) % U1W3.entries.count]
        let base = w3.a
        var state: [UInt32] = (0..<4).map { rotateLeft32(E1C.e[$0], -base) }
        let k: [UInt32] = (0..<64).map { rotateLeft32(E1C.f[$0], -((Int($0) / 16) + base + 1)) }

        var block = [UInt8](repeating: 0, count: 64)
        block.replaceSubrange(0..<52, with: input.prefix(52))
        for i in 0..<8 {
            // u1.c(e1.g[i], -(base+5))：e1.g 是 byte 表，rotate 后截断
            block[52 + i] = E1C.g[i]   // 已是 UInt8，无需 jbyte
        }
        for i in 0..<8 {
            block[56 + i] = jbyte(UInt32(416) >> UInt32((7 - i) * 8))
        }

        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let o = i * 4
            // dex 680：小端拼 word
            m[i] = UInt32(block[o]) | UInt32(block[o + 1]) << 8
                | UInt32(block[o + 2]) << 16 | UInt32(block[o + 3]) << 24
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        for i in 0..<64 {
            let f: UInt32
            switch i / 16 {
            case 0: f = (b ^ c) & d ^ c
            case 1: f = (b ^ c) & d ^ c
            case 2: f = (b ^ c) ^ d
            default: f = c ^ (b | (d ^ ~UInt32(0)))
            }
            let sum = a &+ f &+ m[Int(E1C.i[i])] &+ k[i]
            let tmp = d
            d = c
            c = b
            b = b &+ rotateLeft32(sum, Int(E1C.j[i]))
            a = tmp
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            out[i * 4] = jbyte(state[i])
            out[i * 4 + 1] = jbyte(state[i] >> 8)
            out[i * 4 + 2] = jbyte(state[i] >> 16)
            out[i * 4 + 3] = jbyte(state[i] >> 24)
        }
        for i in 0..<4 {
            let v = rotateLeft32(E1C.h[i], -(base + 6)) ^ state[i]
            out[16 + i * 4] = jbyte(v)
            out[16 + i * 4 + 1] = jbyte(v >> 8)
            out[16 + i * 4 + 2] = jbyte(v >> 16)
            out[16 + i * 4 + 3] = jbyte(v >> 24)
        }
        return out
    }

    /// SHA-256 变体（C3.b 723-832）
    /// 结构：
    ///   base = D1.c + ts
    ///   h[8] = rotateLeft(e1.b[i], -base)
    ///   K[64] = rotateLeft(e1.c[i], -(base+1))
    ///   消息块 64 字节 = input52 + e1.d 前 4 字节 + 0x80 填充 + 大端 bitlen(416)
    ///   调度：w[i] = w[i-16] + σ0(w[i-15]) + w[i-7] + σ1(w[i-2])
    ///   压缩：标准 SHA-256 布尔函数
    private static func sha256Variant(input: [UInt8], ts: UInt64, selector: Int) -> [UInt8] {
        // base = D1.c（u1.a 表按 selector 选条目；已从 LF0/u1.<clinit> 解码，见 U1Constants.swift）
        let d1 = U1D1.entries[abs(selector) % U1D1.entries.count]
        let base = d1.c
        var h: [UInt32] = (0..<8).map { rotateLeft32(E1C.b[$0], -base) }
        let k: [UInt32] = (0..<64).map { rotateLeft32(E1C.c[$0], -(base + 1)) }

        var block = [UInt8](repeating: 0, count: 64)
        block.replaceSubrange(0..<52, with: input.prefix(52))
        for i in 0..<4 {
            block[52 + i] = E1C.d[i]   // 已是 UInt8，无需 jbyte
        }
        block[56] = 0x80
        for i in 0..<8 {
            block[56 + i] = jbyte(Int(416) >> ((7 - i) * 8))
        }

        @inline(__always)
        func rotr(_ v: UInt32, _ n: Int) -> UInt32 { (v >> UInt32(n)) | (v << UInt32(32 - n)) }

        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let o = i * 4
            // dex 748：大端拼 word
            w[i] = UInt32(block[o]) << 24 | UInt32(block[o + 1]) << 16
                | UInt32(block[o + 2]) << 8 | UInt32(block[o + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let mj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ mj
            hh = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[i * 4] = jbyte(h[i])
            out[i * 4 + 1] = jbyte(h[i] >> 8)
            out[i * 4 + 2] = jbyte(h[i] >> 16)
            out[i * 4 + 3] = jbyte(h[i] >> 24)
        }
        return out
    }
}
