// CryptoPrimitives.swift
// 纯 Swift 实现的签名底层工具：MD5 / SHA-256 / CRC64 / 小端编码 / 自研哈希。
// 对应 dex 中的 F0.e1（部分）、F0.C1.c/d、F0.C3.a、F0.l0.F/H/J、S1.b（MD5）。
// 所有整数运算用 UInt32/UInt64 显式定宽，溢出用 &+ / &- / &* / &<< / &>> 保证与 Java 32/64 位环绕一致。

import Foundation

// MARK: - 字节工具

/// Java `new byte[]{...}` 的有符号字节 → Swift UInt8。
@inline(__always)
func jbyte(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }

/// Java `(byte)(x)`。
@inline(__always)
func jbyte(_ v: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: v) }

@inline(__always)
func jbyte(_ v: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: v) }

/// Java `x & 255`（把 byte 当无符号用）。
@inline(__always)
func u8(_ b: UInt8) -> UInt32 { UInt32(b) }

/// F0.e1.E(int) → 4 字节小端。
func le32(_ v: UInt32) -> [UInt8] {
    [jbyte(v), jbyte(v >> 8), jbyte(v >> 16), jbyte(v >> 24)]
}

/// F0.e1.F(long) → 8 字节小端。
func le64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { jbyte(v >> (UInt64($0) * 8)) }
}

/// F0.e1.B(int, byte[]) → 大端读 int（ByteBuffer BIG_ENDIAN getInt）。
func be32(_ buf: [UInt8], at offset: Int) -> UInt32 {
    UInt32(buf[offset]) << 24 | UInt32(buf[offset + 1]) << 16
        | UInt32(buf[offset + 2]) << 8 | UInt32(buf[offset + 3])
}

/// F0.C1.d(int, byte[]) → 小端读（返回 long，高 32 位为 0）。
func readLE32AsLong(_ buf: [UInt8], at offset: Int) -> UInt64 {
    UInt64(buf[offset]) | UInt64(buf[offset + 1]) << 8
        | UInt64(buf[offset + 2]) << 16 | UInt64(buf[offset + 3]) << 24
}

/// F0.e1.C(int, boolean, byte[]) → 8 字节读取；littleEndian=true 用小端。
func readLong(_ buf: [UInt8], at offset: Int, littleEndian: Bool) -> UInt64 {
    var v: UInt64 = 0
    if littleEndian {
        for i in 0..<8 { v |= UInt64(buf[offset + i]) << (UInt64(i) * 8) }
    } else {
        for i in 0..<8 { v = (v << 8) | UInt64(buf[offset + i]) }
    }
    return v
}

// MARK: - 整数位操作（Java 语义）

/// Java `Integer.rotateLeft`。
@inline(__always)
func rotateLeft32(_ v: UInt32, _ n: Int) -> UInt32 {
    let k = UInt32(((n % 32) + 32) % 32)
    return (v << k) | (v >> ((32 - k) & 31))
}

/// Java `Long.rotateLeft`。
@inline(__always)
func rotateLeft64(_ v: UInt64, _ n: Int) -> UInt64 {
    let k = UInt64(((n % 64) + 64) % 64)
    return (v << k) | (v >> ((64 - k) & 63))
}

/// Java `Long.rotateRight`。
@inline(__always)
func rotateRight64(_ v: UInt64, _ n: Int) -> UInt64 {
    let k = UInt64(((n % 64) + 64) % 64)
    return (v >> k) | (v << ((64 - k) & 63))
}

/// Java `Integer.reverseBytes`。
@inline(__always)
func reverseBytes32(_ v: UInt32) -> UInt32 {
    (v & 0x0000_00FF) << 24 | (v & 0x0000_FF00) << 8
        | (v & 0x00FF_0000) >> 8 | (v & 0xFF00_0000) >> 24
}

/// Java `Integer.reverse`（全部 32 位反转）。
@inline(__always)
func reverseBits32(_ v: UInt32) -> UInt32 {
    var x = v
    x = (x & 0x5555_5555) << 1 | (x & 0xAAAA_AAAA) >> 1
    x = (x & 0x3333_3333) << 2 | (x & 0xCCCC_CCCC) >> 2
    x = (x & 0x0F0F_0F0F) << 4 | (x & 0xF0F0_F0F0) >> 4
    return reverseBytes32(x)
}

// MARK: - MD5（对应 F0.e1.x("MD5", bytes)）

func md5(_ message: [UInt8]) -> [UInt8] {
    var a: UInt32 = 0x6745_2301
    var b: UInt32 = 0xEFCD_AB89
    var c: UInt32 = 0x98BA_DCFE
    var d: UInt32 = 0x1032_5476

    let shifts: [Int] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    let kTable: [UInt32] = (0..<64).map { i in
        let v = Foundation.sin(Double(i + 1)) * 4294967296.0
        return UInt32(truncatingIfNeeded: Int64(v.magnitude))
    }

    var msg = message
    let bitLen = UInt64(message.count) &* 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in 0..<8 { msg.append(jbyte(bitLen >> (UInt64(i) * 8))) }

    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let o = chunkStart + i * 4
            m[i] = UInt32(msg[o]) | UInt32(msg[o + 1]) << 8
                | UInt32(msg[o + 2]) << 16 | UInt32(msg[o + 3]) << 24
        }
        var aa = a, bb = b, cc = c, dd = d
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i / 16 {
            case 0: f = (bb & cc) | (~bb & dd); g = i
            case 1: f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16
            case 2: f = bb ^ cc ^ dd; g = (3 * i + 5) % 16
            default: f = cc ^ (bb | ~dd); g = (7 * i) % 16
            }
            f = f &+ aa &+ kTable[i] &+ m[g]
            aa = dd
            dd = cc
            cc = bb
            bb = bb &+ rotateLeft32(f, shifts[i])
        }
        a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
    }

    var out = [UInt8](repeating: 0, count: 16)
    for (i, v) in [a, b, c, d].enumerated() {
        out[i * 4] = jbyte(v)
        out[i * 4 + 1] = jbyte(v >> 8)
        out[i * 4 + 2] = jbyte(v >> 16)
        out[i * 4 + 3] = jbyte(v >> 24)
    }
    return out
}

func md5Hex(_ data: [UInt8]) -> String {
    md5(data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - SHA-256（对应 X-Gorgon medusa selector 8..15 分支里的 b/c 表）

func sha256(_ message: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    var msg = message
    let bitLen = UInt64(message.count) &* 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in 0..<8 { msg.append(jbyte(bitLen >> (UInt64(7 - i) * 8))) }

    @inline(__always)
    func rotr(_ v: UInt32, _ n: Int) -> UInt32 { (v >> UInt32(n)) | (v << UInt32(32 - n)) }

    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let o = chunkStart + i * 4
            w[i] = UInt32(msg[o]) << 24 | UInt32(msg[o + 1]) << 16
                | UInt32(msg[o + 2]) << 8 | UInt32(msg[o + 3])
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
    }

    var out = [UInt8](repeating: 0, count: 32)
    for i in 0..<8 {
        out[i * 4] = jbyte(h[i])
        out[i * 4 + 1] = jbyte(h[i] >> 8)
        out[i * 4 + 2] = jbyte(h[i] >> 16)
        out[i * 4 + 3] = jbyte(h[i] >> 24)
    }
    return out
}

// MARK: - CRC64（F0.C1.c）

/// 多项式（Java long 字面量）-7661587058870466123。
/// Java 二进制补码位模式 = 0x6ADE_74B3_6300_875C，用 UInt64 原样承载。
let crc64Poly: UInt64 = 0x6ADE_74B3_6300_875C

/// F0.C1.c(byte[])：按位 CRC64，初值 0，无最终异或。
func crc64(_ data: [UInt8]) -> UInt64 {
    var crc: UInt64 = 0
    for byte in data {
        var idx = (UInt64(byte) ^ crc) & 0xFF
        for _ in 0..<8 {
            if idx & 1 == 0 {
                idx >>= 1
            } else {
                idx = (idx >> 1) ^ crc64Poly
            }
        }
        crc = (crc >> 8) ^ idx
    }
    return crc
}

// MARK: - F0.C3.a：种子 539167016 的自研哈希（奇偶字节不同移位异或）

/// Java int 语义（32 位有符号环绕），这里用 UInt32 承载位模式。
func customHash(seed: UInt32, data: [UInt8]) -> UInt32 {
    var state = seed
    for i in 0..<data.count {
        if i & 1 != 0 {
            state = ((state << 12) | u8(data[i])) ^ (state >> 7 ^ state)
            state = ~state
        } else {
            state = (state << 6) ^ (state >> 4 ^ state) ^ u8(data[i])
        }
    }
    return state
}

// MARK: - Base64（F0.e1.n：标准字母表，带 '=' 填充）

let base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

func base64Encode(_ data: [UInt8]) -> String {
    var out = ""
    var i = 0
    while i < data.count {
        let b0 = data[i]
        let b1 = i + 1 < data.count ? data[i + 1] : nil
        let b2 = i + 2 < data.count ? data[i + 2] : nil
        out.append(base64Alphabet[base64Alphabet.index(base64Alphabet.startIndex, offsetBy: Int(b0 >> 2))])
        let n = (Int(b0) & 3) << 4 | (b1.map { Int($0) >> 4 } ?? 0)
        out.append(base64Alphabet[base64Alphabet.index(base64Alphabet.startIndex, offsetBy: n)])
        if b1 == nil {
            out.append("=")
        } else {
            let n2 = (Int(b1!) & 15) << 2 | (b2.map { Int($0) >> 6 } ?? 0)
            out.append(base64Alphabet[base64Alphabet.index(base64Alphabet.startIndex, offsetBy: n2)])
        }
        if b2 == nil {
            out.append("=")
        } else {
            out.append(base64Alphabet[base64Alphabet.index(base64Alphabet.startIndex, offsetBy: Int(b2!) & 63)])
        }
        i += 3
    }
    return out
}

// MARK: - F0.l0.F / H / J：medusa 参数序列化入口（stub）

/// 这三个函数在 dex 里属于 F0.l0，反编译结果被寄存器传播严重污染，
/// 无法确定性还原（详见 SIGNING_NOTES.md「待确认」）。
enum MedusaSerializer {
    /// F0.l0.F(byte[], long, int, int, int, int) → int
    static func F(_ data: [UInt8], _ seed: UInt64, _ a: Int, _ b: Int, _ c: Int, _ d: Int) -> UInt32 {
        _ = (data, seed, a, b, c, d)
        return 0 // TODO(待确认)
    }

    /// F0.l0.H(Map, long, long, long, long[], byte[]) → String
    static func H(_ params: [Int: Any], _ t1: UInt64, _ t2: UInt64,
                  _ t3: UInt64, _ longs: [UInt64], _ sbox: [UInt8]) -> String {
        _ = (params, t1, t2, t3, longs, sbox)
        return "" // TODO(待确认)
    }

    /// F0.l0.J(Map, Comparator) → byte[]
    static func J(_ params: [Int: Any]) -> [UInt8] {
        _ = params
        return [] // TODO(待确认)
    }
}
