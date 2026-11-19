// HCSignV5Core.swift
// HGTV 1.3.7 源码 crypto/ 包的 Swift 移植(第 1 部分:基础层)。
// 对应 Kotlin:crypto/Bytes.kt + MedusaPb.kt + MedusaTables.kt + MedusaSchema.kt。
// 语义对齐:Kotlin Int = Int32(溢出回绕)、Long = Int64;ushr = 无符号右移(用 UInt 位型移位)。
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import CryptoKit

// MARK: - Kotlin 语义辅助

@inline(__always) func kU(_ v: Int32) -> Int32 { v & 0xFF }           // Byte.u()
@inline(__always) func kshr32(_ v: Int32, _ n: Int32) -> Int32 {       // Int ushr
    Int32(bitPattern: UInt32(bitPattern: v) >> UInt32(truncatingIfNeeded: n))
}
@inline(__always) func kshr64(_ v: Int64, _ n: Int64) -> Int64 {       // Long ushr
    Int64(bitPattern: UInt64(bitPattern: v) >> UInt64(truncatingIfNeeded: n))
}
@inline(__always) func kshrU64(_ v: UInt64, _ n: UInt64) -> UInt64 { v >> n }
@inline(__always) func kToU32(_ v: Int64) -> Int64 { Int64(UInt32(bitPattern: UInt32(truncatingIfNeeded: v))) }
@inline(__always) func kInv32(_ v: Int32) -> Int32 { ~v }
@inline(__always) func kInv64(_ v: Int64) -> Int64 { ~v }
// Swift stdlib 无 rotate（在 swift-numerics 包里），这里用移位实现（n 取位宽模，支持负数=反向）。
@inline(__always) func krotl32(_ v: Int32, _ n: Int32) -> Int32 {
    let u = UInt32(bitPattern: v); let k = UInt32(n) & 31
    return Int32(bitPattern: (u << k) | (u >> ((32 - k) & 31)))
}
@inline(__always) func kror32(_ v: Int32, _ n: Int32) -> Int32 {
    let u = UInt32(bitPattern: v); let k = UInt32(n) & 31
    return Int32(bitPattern: (u >> k) | (u << ((32 - k) & 31)))
}
@inline(__always) func krotl64(_ v: Int64, _ n: Int64) -> Int64 {
    let u = UInt64(bitPattern: v); let k = UInt64(n) & 63
    return Int64(bitPattern: (u << k) | (u >> ((64 - k) & 63)))
}
@inline(__always) func kror64(_ v: Int64, _ n: Int64) -> Int64 {
    let u = UInt64(bitPattern: v); let k = UInt64(n) & 63
    return Int64(bitPattern: (u >> k) | (u << ((64 - k) & 63)))
}

// MARK: - Bytes.kt

func hcHexToBytes(_ value: String) -> [UInt8] {
    precondition(value.count % 2 == 0)
    var out = [UInt8]()
    out.reserveCapacity(value.count / 2)
    var i = value.startIndex
    while i < value.endIndex {
        let next = value.index(i, offsetBy: 2)
        out.append(UInt8(value[i..<next], radix: 16) ?? 0)
        i = next
    }
    return out
}

func hcBytesToHex(_ data: [UInt8]) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private let kBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

func hcBase64Decode(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var buffer = 0
    var bits = 0
    for raw in s {
        if raw == "=" { break }
        let c: Character = raw == "-" ? "+" : (raw == "_" ? "/" : raw)
        guard let idx = kBase64Alphabet.firstIndex(of: c) else { continue }
        buffer = (buffer << 6) | kBase64Alphabet.distance(from: kBase64Alphabet.startIndex, to: idx)
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((buffer >> bits) & 255))
        }
    }
    return out
}

func hcBase64Encode(_ data: [UInt8]) -> String {
    var out = ""
    let chars = Array(kBase64Alphabet)
    var index = 0
    while index < data.count {
        let b0 = Int(data[index])
        let b1 = index + 1 < data.count ? Int(data[index + 1]) : 0
        let b2 = index + 2 < data.count ? Int(data[index + 2]) : 0
        out.append(chars[b0 >> 2])
        out.append(chars[((b0 & 3) << 4) | (b1 >> 4)])
        out.append(index + 1 < data.count ? chars[((b1 & 15) << 2) | (b2 >> 6)] : "=")
        out.append(index + 2 < data.count ? chars[b2 & 63] : "=")
        index += 3
    }
    return out
}

func hcLe32(_ n: Int32) -> [UInt8] {
    withUnsafeBytes(of: n.littleEndian) { Array($0) }
}
func hcBe32(_ n: Int32) -> [UInt8] {
    withUnsafeBytes(of: n.bigEndian) { Array($0) }
}
func hcLe64(_ n: Int64) -> [UInt8] {
    withUnsafeBytes(of: n.littleEndian) { Array($0) }
}
func hcI32(_ data: [UInt8], _ at: Int, little: Bool = false) -> Int32 {
    let u: UInt32 = little
        ? UInt32(data[at]) | UInt32(data[at+1]) << 8 | UInt32(data[at+2]) << 16 | UInt32(data[at+3]) << 24
        : UInt32(data[at]) << 24 | UInt32(data[at+1]) << 16 | UInt32(data[at+2]) << 8 | UInt32(data[at+3])
    return Int32(bitPattern: u)
}
func hcI64(_ data: [UInt8], _ at: Int, little: Bool = false) -> Int64 {
    var v: UInt64 = 0
    if little {
        for i in 0..<8 { v |= UInt64(data[at+i]) << (8 * i) }
    } else {
        for i in 0..<8 { v = (v << 8) | UInt64(data[at+i]) }
    }
    return Int64(bitPattern: v)
}
func hcDigest(_ algorithm: String, _ value: [UInt8]) -> [UInt8] {
    switch algorithm {
    case "MD5":
        return Array(Insecure.MD5.hash(data: Data(value)))
    case "SHA-512":
        return Array(SHA512.hash(data: Data(value)))
    default:
        fatalError("unsupported digest \(algorithm)")
    }
}
func hcSm3(_ value: [UInt8]) -> [UInt8] { sm3Hash(value) }   // 复用工程内 SM3
func hcXor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    (0..<a.count).map { a[$0] ^ b[$0 % b.count] }
}
func hcRol(_ v: Int32, _ n: Int32) -> Int32 {
    let u = UInt32(bitPattern: v); let k = UInt32(n) & 31
    return Int32(bitPattern: (u << k) | (u >> ((32 - k) & 31)))
}
func hcRor(_ v: Int32, _ n: Int32) -> Int32 {
    let u = UInt32(bitPattern: v); let k = UInt32(n) & 31
    return Int32(bitPattern: (u >> k) | (u << ((32 - k) & 31)))
}

// MARK: - MedusaPb.kt

func hcMedusaInteger(_ value: Any?) -> Int64 {
    if let v = value as? Int64 { return v }
    if let v = value as? Int32 { return Int64(v) }
    if let v = value as? Int { return Int64(v) }
    fatalError("invalid Medusa integer \(String(describing: value))")
}

func hcMedusaVarint(_ out: inout [UInt8], value: Int64) {
    var v = value
    // Kotlin: while (compareUnsigned(v, 128) >= 0) —— 无符号比较
    while UInt64(bitPattern: v) >= 128 {
        out.append(UInt8((v & 0x7F) | 0x80))
        v = kshr64(v, 7)
    }
    out.append(UInt8(v & 0x7F))
}

struct HCMedusaDescriptor {
    let id: Int32
    let typ: Int32
    let fields: [HCMedusaDescriptor]
}

func hcMedusaPB(_ values: [Int32: Any], schema: [HCMedusaDescriptor]) -> [UInt8] {
    var out = [UInt8]()
    for d in schema {
        guard let v = values[d.id] else { continue }
        switch d.typ {
        case 1, 4, 13:
            let n = hcMedusaInteger(v)
            if n == 0 { continue }
            var x: Int64
            if d.typ == 1 {
                precondition(n >= Int64(Int32.min) && n <= Int64(Int32.max), "Medusa int32 overflow")
                let i = Int32(truncatingIfNeeded: n)
                // (((i shl 1) xor (i shr 31)).toLong()) and 0xFFFFFFFFL —— Kotlin shr 为算术右移
                let zigzag = UInt32(bitPattern: (i << 1) ^ (i >> 31))
                x = Int64(zigzag)
            } else if d.typ == 4 {
                // (n shl 1) xor (n shr 63) —— Long 算术右移 63
                x = (n << 1) ^ (n >> 63)
            } else {
                x = n
            }
            hcMedusaVarint(&out, value: Int64(d.id) << 3)
            hcMedusaVarint(&out, value: x)
        case 6, 10:
            var x: Int32
            if d.typ == 10 {
                let f = v as! Float
                if f == 0 { continue }
                x = Int32(bitPattern: f.bitPattern)
            } else {
                let n = Int32(truncatingIfNeeded: hcMedusaInteger(v))
                if n == 0 { continue }
                x = n
            }
            hcMedusaVarint(&out, value: Int64(d.id << 3) | 5)
            out += hcLe32(x)
        default:
            var raw: [UInt8]
            if d.typ == 16 {
                raw = hcMedusaPB(v as! [Int32: Any], schema: d.fields)
            } else if let b = v as? [UInt8] {
                raw = b
            } else if let s = v as? String {
                raw = Array(s.utf8)
            } else {
                fatalError("invalid Medusa bytes \(type(of: v))")
            }
            var data = raw
            if d.typ == 14 {
                if let at = data.firstIndex(of: 0) { data = Array(data[..<at]) }
            }
            if data.isEmpty && d.typ != 16 { continue }
            hcMedusaVarint(&out, value: Int64(d.id << 3) | 2)
            hcMedusaVarint(&out, value: Int64(data.count))
            out += data
        }
    }
    return out
}

// MARK: - MedusaTables.kt

let hcMedusaSboxes: [[Int32]] = [
    [83, 41, 15, 233, 229, 31, 49, 111, 144, 247, 74, 126, 3, 77, 54, 119,
     132, 171, 73, 35, 124, 208, 19, 92, 220, 99, 44, 50, 47, 211, 190, 14,
     38, 36, 164, 23, 236, 217, 21, 26, 127, 246, 79, 96, 115, 10, 135, 249,
     68, 94, 198, 173, 162, 248, 101, 210, 43, 105, 108, 65, 136, 242, 76, 13,
     243, 123, 117, 81, 11, 147, 159, 107, 194, 254, 104, 131, 230, 139, 200, 199,
     34, 24, 27, 160, 189, 176, 140, 152, 113, 181, 12, 154, 22, 180, 110, 234,
     142, 237, 32, 186, 75, 138, 20, 224, 252, 241, 70, 141, 187, 239, 5, 169,
     62, 90, 157, 125, 207, 6, 137, 134, 53, 193, 253, 153, 245, 222, 40, 122,
     128, 197, 148, 218, 170, 177, 155, 98, 121, 251, 215, 80, 112, 203, 82, 235,
     37, 85, 196, 86, 227, 158, 120, 57, 133, 56, 116, 226, 240, 1, 58, 192,
     182, 71, 66, 216, 202, 16, 228, 183, 156, 149, 93, 232, 184, 67, 206, 78,
     212, 100, 166, 167, 46, 213, 8, 9, 28, 146, 231, 179, 238, 221, 30, 29,
     209, 42, 250, 195, 33, 97, 143, 163, 214, 95, 145, 103, 201, 130, 244, 61,
     102, 165, 60, 106, 25, 151, 88, 91, 52, 109, 191, 150, 114, 255, 55, 205,
     188, 7, 59, 45, 174, 17, 69, 51, 4, 223, 0, 129, 84, 118, 178, 161,
     63, 204, 219, 48, 185, 87, 168, 172, 175, 225, 39, 64, 2, 72, 89, 18],
    [56, 146, 37, 99, 227, 100, 6, 211, 122, 36, 16, 11, 121, 2, 160, 40,
     4, 78, 33, 132, 83, 194, 163, 153, 25, 156, 157, 19, 220, 64, 197, 91,
     166, 126, 80, 34, 115, 133, 14, 189, 193, 162, 226, 24, 139, 143, 45, 158,
     60, 185, 9, 184, 196, 106, 42, 159, 74, 109, 217, 48, 7, 234, 250, 101,
     183, 179, 168, 129, 170, 144, 140, 199, 79, 10, 215, 107, 187, 181, 134, 23,
     195, 112, 18, 202, 5, 164, 105, 253, 68, 230, 46, 236, 241, 228, 39, 44,
     232, 96, 192, 174, 94, 173, 249, 155, 32, 216, 240, 35, 65, 116, 0, 111,
     63, 17, 13, 118, 87, 208, 22, 69, 212, 239, 248, 247, 20, 113, 203, 254,
     28, 178, 245, 38, 72, 114, 123, 243, 201, 222, 85, 21, 62, 3, 27, 77,
     97, 117, 125, 182, 61, 191, 119, 130, 238, 175, 233, 1, 138, 136, 145, 54,
     47, 177, 71, 89, 172, 50, 186, 176, 59, 52, 154, 235, 90, 55, 124, 81,
     86, 190, 76, 141, 251, 225, 58, 104, 75, 218, 57, 207, 131, 102, 151, 200,
     148, 84, 95, 224, 242, 73, 26, 206, 169, 252, 98, 82, 244, 255, 30, 15,
     231, 43, 210, 223, 110, 103, 167, 246, 53, 229, 188, 198, 209, 165, 221, 149,
     29, 137, 150, 8, 135, 161, 142, 180, 12, 120, 92, 219, 31, 128, 237, 66,
     41, 147, 51, 171, 152, 205, 214, 127, 49, 108, 213, 67, 70, 88, 93, 204],
    [215, 89, 251, 114, 39, 137, 176, 136, 7, 204, 15, 218, 41, 63, 126, 94,
     24, 25, 187, 3, 83, 81, 112, 32, 179, 29, 61, 0, 55, 73, 82, 190,
     162, 196, 33, 232, 98, 4, 10, 158, 200, 146, 160, 91, 38, 107, 122, 13,
     12, 195, 22, 244, 131, 184, 26, 243, 151, 21, 101, 127, 254, 50, 173, 141,
     224, 193, 48, 119, 100, 96, 53, 35, 110, 229, 54, 62, 95, 144, 14, 154,
     124, 248, 80, 168, 28, 217, 150, 11, 109, 247, 51, 23, 34, 111, 153, 234,
     166, 255, 241, 92, 236, 52, 172, 185, 130, 70, 99, 155, 145, 138, 178, 133,
     20, 102, 167, 205, 252, 74, 209, 181, 44, 42, 233, 90, 88, 211, 115, 78,
     71, 221, 213, 183, 86, 1, 147, 246, 68, 239, 156, 64, 139, 125, 238, 57,
     180, 214, 170, 191, 77, 231, 97, 227, 37, 45, 76, 123, 163, 132, 49, 135,
     116, 93, 85, 230, 165, 219, 5, 212, 43, 69, 202, 237, 67, 192, 197, 208,
     182, 75, 250, 157, 148, 164, 169, 216, 242, 240, 225, 161, 8, 220, 253, 40,
     143, 210, 188, 31, 199, 189, 103, 84, 18, 19, 129, 105, 203, 9, 36, 152,
     117, 186, 59, 104, 207, 177, 17, 128, 175, 174, 16, 79, 201, 120, 149, 113,
     198, 223, 206, 2, 65, 56, 134, 121, 106, 226, 30, 60, 72, 140, 194, 27,
     159, 66, 58, 6, 108, 46, 171, 249, 142, 47, 222, 235, 87, 118, 228, 245],
    [208, 154, 81, 91, 165, 140, 187, 171, 62, 55, 176, 159, 212, 246, 217, 36,
     77, 248, 5, 18, 232, 76, 215, 149, 107, 227, 1, 207, 100, 241, 66, 157,
     88, 87, 124, 194, 65, 243, 162, 198, 85, 20, 79, 129, 170, 249, 90, 78,
     16, 141, 168, 148, 179, 137, 112, 86, 26, 233, 0, 38, 25, 251, 186, 201,
     31, 169, 34, 237, 32, 43, 252, 98, 203, 8, 224, 222, 42, 127, 54, 49,
     67, 95, 139, 71, 200, 163, 197, 99, 180, 219, 64, 113, 206, 116, 196, 109,
     166, 250, 105, 106, 158, 40, 45, 30, 130, 93, 102, 59, 147, 191, 213, 108,
     72, 220, 225, 136, 75, 177, 15, 204, 234, 6, 57, 41, 247, 70, 68, 63,
     216, 48, 164, 35, 46, 83, 218, 33, 161, 242, 209, 189, 254, 188, 58, 2,
     193, 10, 27, 138, 211, 29, 4, 253, 97, 101, 144, 210, 114, 172, 115, 126,
     152, 235, 51, 175, 96, 82, 135, 22, 190, 231, 142, 192, 238, 134, 153, 3,
     17, 119, 39, 125, 156, 255, 50, 84, 44, 103, 202, 245, 244, 69, 145, 104,
     19, 53, 174, 14, 23, 143, 52, 9, 167, 128, 61, 184, 56, 146, 221, 229,
     185, 183, 240, 199, 80, 226, 74, 239, 7, 123, 173, 214, 120, 160, 155, 133,
     11, 132, 236, 21, 151, 228, 150, 60, 181, 230, 117, 223, 28, 13, 111, 182,
     24, 73, 110, 205, 118, 195, 92, 121, 131, 37, 89, 12, 47, 178, 122, 94],
]

let hcMedusaRcon: [Int64] = [3149258354, 3563294043, 2460350267, 2314772937]

let hcMedusaPerms: [[Int32]] = [
    [2, 0, 3, 1],
    [1, 3, 2, 0],
    [3, 2, 1, 0],
    [2, 3, 1, 0],
]

let hcMedusaRow3: [[Int32]] = [
    [15, 7, 3, 11],
    [11, 3, 15, 7],
    [3, 15, 11, 7],
    [15, 3, 11, 7],
]

let hcMedusaSelect: [[Int32]] = [
    [5, 7], [0, 6], [4, 2], [2, 3], [6, 1], [7, 0], [3, 4], [1, 5],
]

let hcMedusaPatch: [[Int32]] = [
    [7, 1, 5], [6, 3, 4], [3, 2, 3], [5, 7, 0],
    [4, 6, 1], [1, 0, 6], [0, 5, 7], [2, 4, 2],
]

// MARK: - MedusaSchema.kt

let hcMedusaSchema: [HCMedusaDescriptor] = [
    HCMedusaDescriptor(id: 1, typ: 15, fields: []),
    HCMedusaDescriptor(id: 2, typ: 1, fields: []),
    HCMedusaDescriptor(id: 3, typ: 1, fields: []),
    HCMedusaDescriptor(id: 4, typ: 14, fields: []),
    HCMedusaDescriptor(id: 5, typ: 14, fields: []),
    HCMedusaDescriptor(id: 6, typ: 14, fields: []),
    HCMedusaDescriptor(id: 7, typ: 14, fields: []),
    HCMedusaDescriptor(id: 8, typ: 14, fields: []),
    HCMedusaDescriptor(id: 9, typ: 1, fields: []),
    HCMedusaDescriptor(id: 10, typ: 15, fields: []),
    HCMedusaDescriptor(id: 11, typ: 13, fields: []),
    HCMedusaDescriptor(id: 12, typ: 4, fields: []),
    HCMedusaDescriptor(id: 13, typ: 15, fields: []),
    HCMedusaDescriptor(id: 14, typ: 15, fields: []),
    HCMedusaDescriptor(id: 15, typ: 16, fields: [
        HCMedusaDescriptor(id: 1, typ: 1, fields: []),
        HCMedusaDescriptor(id: 2, typ: 1, fields: []),
        HCMedusaDescriptor(id: 3, typ: 1, fields: []),
        HCMedusaDescriptor(id: 4, typ: 1, fields: []),
        HCMedusaDescriptor(id: 5, typ: 1, fields: []),
    ]),
    HCMedusaDescriptor(id: 16, typ: 14, fields: []),
    HCMedusaDescriptor(id: 17, typ: 1, fields: []),
    HCMedusaDescriptor(id: 18, typ: 15, fields: []),
    HCMedusaDescriptor(id: 19, typ: 15, fields: []),
    HCMedusaDescriptor(id: 20, typ: 14, fields: []),
    HCMedusaDescriptor(id: 21, typ: 1, fields: []),
    HCMedusaDescriptor(id: 22, typ: 1, fields: []),
    HCMedusaDescriptor(id: 23, typ: 16, fields: [
        HCMedusaDescriptor(id: 1, typ: 1, fields: []),
        HCMedusaDescriptor(id: 2, typ: 4, fields: []),
        HCMedusaDescriptor(id: 3, typ: 4, fields: []),
        HCMedusaDescriptor(id: 4, typ: 1, fields: []),
        HCMedusaDescriptor(id: 5, typ: 1, fields: []),
        HCMedusaDescriptor(id: 6, typ: 14, fields: []),
        HCMedusaDescriptor(id: 7, typ: 1, fields: []),
        HCMedusaDescriptor(id: 8, typ: 14, fields: []),
        HCMedusaDescriptor(id: 9, typ: 14, fields: []),
        HCMedusaDescriptor(id: 10, typ: 14, fields: []),
        HCMedusaDescriptor(id: 11, typ: 14, fields: []),
        HCMedusaDescriptor(id: 12, typ: 16, fields: [
            HCMedusaDescriptor(id: 1, typ: 1, fields: []),
            HCMedusaDescriptor(id: 2, typ: 1, fields: []),
            HCMedusaDescriptor(id: 3, typ: 14, fields: []),
            HCMedusaDescriptor(id: 4, typ: 14, fields: []),
            HCMedusaDescriptor(id: 5, typ: 14, fields: []),
            HCMedusaDescriptor(id: 6, typ: 14, fields: []),
            HCMedusaDescriptor(id: 7, typ: 1, fields: []),
            HCMedusaDescriptor(id: 8, typ: 1, fields: []),
            HCMedusaDescriptor(id: 9, typ: 1, fields: []),
            HCMedusaDescriptor(id: 10, typ: 1, fields: []),
            HCMedusaDescriptor(id: 11, typ: 14, fields: []),
            HCMedusaDescriptor(id: 12, typ: 14, fields: []),
            HCMedusaDescriptor(id: 13, typ: 14, fields: []),
            HCMedusaDescriptor(id: 14, typ: 1, fields: []),
            HCMedusaDescriptor(id: 15, typ: 14, fields: []),
            HCMedusaDescriptor(id: 16, typ: 10, fields: []),
            HCMedusaDescriptor(id: 17, typ: 10, fields: []),
            HCMedusaDescriptor(id: 18, typ: 10, fields: []),
            HCMedusaDescriptor(id: 19, typ: 10, fields: []),
            HCMedusaDescriptor(id: 20, typ: 10, fields: []),
            HCMedusaDescriptor(id: 21, typ: 10, fields: []),
            HCMedusaDescriptor(id: 22, typ: 14, fields: []),
            HCMedusaDescriptor(id: 23, typ: 1, fields: []),
            HCMedusaDescriptor(id: 24, typ: 1, fields: []),
            HCMedusaDescriptor(id: 25, typ: 4, fields: []),
            HCMedusaDescriptor(id: 26, typ: 4, fields: []),
            HCMedusaDescriptor(id: 27, typ: 4, fields: []),
            HCMedusaDescriptor(id: 28, typ: 4, fields: []),
            HCMedusaDescriptor(id: 29, typ: 1, fields: []),
            HCMedusaDescriptor(id: 30, typ: 14, fields: []),
            HCMedusaDescriptor(id: 31, typ: 14, fields: []),
            HCMedusaDescriptor(id: 32, typ: 14, fields: []),
            HCMedusaDescriptor(id: 33, typ: 14, fields: []),
            HCMedusaDescriptor(id: 34, typ: 14, fields: []),
            HCMedusaDescriptor(id: 35, typ: 14, fields: []),
            HCMedusaDescriptor(id: 36, typ: 14, fields: []),
            HCMedusaDescriptor(id: 37, typ: 14, fields: []),
            HCMedusaDescriptor(id: 38, typ: 4, fields: []),
            HCMedusaDescriptor(id: 39, typ: 15, fields: []),
            HCMedusaDescriptor(id: 40, typ: 4, fields: []),
        ]),
        HCMedusaDescriptor(id: 13, typ: 16, fields: [
            HCMedusaDescriptor(id: 1, typ: 4, fields: []),
            HCMedusaDescriptor(id: 2, typ: 13, fields: []),
            HCMedusaDescriptor(id: 3, typ: 14, fields: []),
            HCMedusaDescriptor(id: 4, typ: 1, fields: []),
            HCMedusaDescriptor(id: 5, typ: 1, fields: []),
            HCMedusaDescriptor(id: 6, typ: 1, fields: []),
        ]),
        HCMedusaDescriptor(id: 14, typ: 14, fields: []),
        HCMedusaDescriptor(id: 15, typ: 1, fields: []),
        HCMedusaDescriptor(id: 16, typ: 4, fields: []),
        HCMedusaDescriptor(id: 17, typ: 4, fields: []),
        HCMedusaDescriptor(id: 18, typ: 4, fields: []),
        HCMedusaDescriptor(id: 19, typ: 1, fields: []),
        HCMedusaDescriptor(id: 20, typ: 4, fields: []),
        HCMedusaDescriptor(id: 21, typ: 1, fields: []),
        HCMedusaDescriptor(id: 22, typ: 1, fields: []),
        HCMedusaDescriptor(id: 23, typ: 1, fields: []),
        HCMedusaDescriptor(id: 24, typ: 1, fields: []),
    ]),
    HCMedusaDescriptor(id: 24, typ: 14, fields: []),
    HCMedusaDescriptor(id: 25, typ: 16, fields: [
        HCMedusaDescriptor(id: 1, typ: 14, fields: []),
        HCMedusaDescriptor(id: 2, typ: 14, fields: []),
        HCMedusaDescriptor(id: 3, typ: 14, fields: []),
        HCMedusaDescriptor(id: 4, typ: 1, fields: []),
    ]),
    HCMedusaDescriptor(id: 26, typ: 1, fields: []),
    HCMedusaDescriptor(id: 27, typ: 15, fields: []),
    HCMedusaDescriptor(id: 28, typ: 1, fields: []),
    HCMedusaDescriptor(id: 29, typ: 6, fields: []),
]
