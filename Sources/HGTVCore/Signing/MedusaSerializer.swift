// MedusaSerializer.swift
// 抖音/HGTV x-gorgon 签名里的 protobuf 式 TLV 序列化原语。
// 逐行对应 dex `LF0/l0` 的字节码（不是反编译 Java）：
//   J(Map, List) -> byte[]   序列化主体          —— 本文件 serialize(schema:params:)
//   L(ByteArrayOutputStream, long)  varint 写入   —— writeVarint64
//   M(int) -> int            GF(2^8) xtime       —— xtime
//   k0(int, int) -> int      8 位循环左移          —— rotateLeft8
//   I(Object) -> long        Number -> long      —— jlongValue
//   F([B, J, I, I, I, I) -> J  64 位自定义哈希     —— medusaHash
// 常量/S-box 依赖（e1.o/p/q/r/s/t、w1 字段布局）不在本文件，见 XGorgonSerialize.md。

import Foundation

// MARK: - schema 描述（对应 LF0/w1）

/// dex 里是 `LF0/w1`：`int a` = 字段 id，`int b` = wire 类型，`List c` = 嵌套 schema。
/// 嵌套字段只有 wire == .nested 时才被读。
public struct MedusaField {
    public var id: Int32
    public var type: WireType
    /// wire == .nested 时使用（对应 w1.c）；其它类型忽略。
    public var nested: [MedusaField]

    public init(id: Int32, type: WireType, nested: [MedusaField] = []) {
        self.id = id
        self.type = type
        self.nested = nested
    }
}

/// `w1.b`（wire type 常量）。数值 = dex 里 if-eq 比较的那些立即数。
public enum WireType: Int32 {
    /// zigzag(varint64)，tag wire = 5（fixed32 槽位，但内容是 varint）
    case varint = 1
    /// zigzag(int32)，越界抛 "Medusa int32 overflow"
    case int32 = 4
    /// length-delimited bytes / String(UTF-8)
    case bytes = 6
    /// float，Java Float.floatToRawIntBits 后 le32；值为 +0.0/-0.0 时整个字段跳过
    case float = 10
    /// length-delimited bytes，遇到第一个 0x00 截断（C 字符串语义）
    case cstring = 13
    /// 嵌套 message，递归调用 serialize
    case nested = 16
}

/// 参数字典（对应 `HashMap<Integer, Object>`）。key = 字段 id。
public typealias MedusaParams = [Int32: MedusaValue]

public enum MedusaValue {
    case int(Int64)
    case float(Float)
    case bytes([UInt8])
    case string(String)
    case nested(MedusaParams)
}

public enum MedusaError: Error, CustomStringConvertible {
    case invalidInteger(Any.Type)
    case invalidBytes(Any.Type)
    case int32Overflow(Int64)

    public var description: String {
        switch self {
        case .invalidInteger(let t): return "invalid Medusa integer \(t)"
        case .invalidBytes(let t): return "invalid Medusa bytes \(t)"
        case .int32Overflow(let v): return "Medusa int32 overflow \(v)"
        }
    }
}

// MARK: - 整数位操作 helper（Java 语义）

/// l0.k0(int a, int b)：`b & 7 == 0` 时原样返回，否则 8 位 rotate-left。
/// 字节码：and-int/lit16 v1,255; and-int/lit8 v2,7; if-nez v2,+3;
///         shl-int v0,v1,v2; rsub-int/lit8 v2,v2,8; ushr-int v1,v2; or-int v1,v0; and-int v1,255
@inline(__always)
public func rotateLeft8(_ value: UInt32, _ amount: UInt32) -> UInt32 {
    let v = value & 0xFF
    let k = amount & 7
    if k == 0 { return v }
    return ((v << k) | (v >> (8 - k))) & 0xFF
}

/// l0.M(int v)：GF(2^8) xtime。`v<<1` 后若原最高位为 1 则 `^0x1B`，再 &255。
/// 字节码：and-int v0,v1,128; shl-int v1,1; if-eqz v0,+7; xor-int v1,27; and-int v1,255
@inline(__always)
public func xtime(_ v: UInt32) -> UInt32 {
    let hi = v & 0x80
    var r = (v << 1) & 0xFFFFFFFF
    if hi != 0 { r = r ^ 27 }
    return r & 0xFF
}

/// l0.I(Object) -> long。只接受 Long / Integer / Byte（Kotlin Number 子类），
/// 其它类型抛 IllegalStateException("invalid Medusa integer ...")。
/// Integer / Byte 走 `int-to-long`，即符号扩展；Long 直接取值。
@inline(__always)
public func jlongValue(_ v: MedusaValue) throws -> Int64 {
    switch v {
    case .int(let x): return x
    case .float: throw MedusaError.invalidInteger(Float.self)
    case .bytes: throw MedusaError.invalidInteger([UInt8].self)
    case .string: throw MedusaError.invalidInteger(String.self)
    case .nested: throw MedusaError.invalidInteger(MedusaParams.self)
    }
}

// MARK: - l0.L：ByteArrayOutputStream 写 varint（zigzag 之前的那种）
//
// 字节码：
//   v0 = Long.MIN_VALUE ^ value          // 把符号位翻到 bit63
//   if (Long.compare(v0, -9223372036854775680L) < 0) {
//       loop { write( (value & 127) | 128 ); value >>>= 7 }
//   }
//   write( value & 127 )
//
// `-9223372036854775680` = 0xFFFF_FFFF_FFFF_FF80，即 `~127L`。
// `Long.MIN ^ x < ~127L` 等价于 `x >= 0`：负数直接进多字节分支。
public func writeVarint64(_ value: UInt64, into out: inout [UInt8]) {
    var v = value
    if (v ^ UInt64(bitPattern: Int64.min)) < UInt64(bitPattern: ~Int64(127)) {
        repeat {
            out.append(UInt8(truncatingIfNeeded: (v & 127) | 128))
            v = v >> 7
        } while (v ^ UInt64(bitPattern: Int64.min)) < UInt64(bitPattern: ~Int64(127))
    }
    out.append(UInt8(truncatingIfNeeded: v & 127))
}

// MARK: - l0.J：TLV 序列化主体
//
// 伪代码（字节码行 1150-1308）：
//   ByteArrayOutputStream out
//   for (w1 f : schema) {
//       Object v = params.get(f.id)
//       if (v == null) continue
//       switch (f.type) {
//         case 16: v = J((Map) v, f.nested);  -> fallthrough 到 6/13 那条写法
//         case 6:  v = v instanceof byte[] ? v : ((String) v).getBytes(UTF8)
//                  if (type == 13) 截断到第一个 0x00
//                  if (v.length != 0 || type == 16) { tag=id<<3|2; L(out,tag); L(out,len); out.write(v) }
//                  break
//         case 10: float f = ((Float) v).floatValue()
//                  if (f == 0f) continue          // +0.0 / -0.0 都跳过
//                  v1 = Float.floatToRawIntBits(f)
//                  tag = id<<3 | 5; L(out, tag)
//                  out.write(e1.E(v1))            // 4 字节小端，无长度前缀
//                  break
//         default: long x = I(v); if (x == 0) continue
//                  if (type == 1)              enc = zigzag64(x)          // shl 1 ^ shr 63
//                  else if (type == 4)         { 检查 int32 范围; enc = zigzag32((int)x) & 0xFFFFFFFF }
//                  else                        enc = x                    // 5/9/11 等未列举的整型
//                  tag = id<<3 | 5; L(out, tag); L(out, enc)
//       }
//   }
//   return out.toByteArray()
public func serialize(schema: [MedusaField], params: MedusaParams) throws -> [UInt8] {
    var out: [UInt8] = []

    for field in schema {
        guard let value = params[field.id] else { continue }   // if-nez v4 → goto 迭代头

        var payload: [UInt8]
        var wireType: UInt32

        switch field.type {
        case .nested:
            guard case .nested(let child) = value else {
                throw MedusaError.invalidBytes(type(of: value))
            }
            payload = try serialize(schema: field.nested, params: child)
            wireType = 2

        case .bytes, .cstring:
            switch value {
            case .bytes(let b): payload = b
            case .string(let s): payload = Array(s.utf8)      // z1.a = UTF-8
            default: throw MedusaError.invalidBytes(type(of: value))
            }
            if field.type == .cstring {
                // 行 1203-1216：找第一个 0 字节，copyOf 截断；找不到就原样
                if let zero = payload.firstIndex(of: 0) {
                    payload = Array(payload[..<zero])
                }
            }
            wireType = 2

        case .float:
            guard case .float(let f) = value else {
                throw MedusaError.invalidBytes(type(of: value))
            }
            // 行 1250-1253：cmpg-float 与 0 比较，相等（含 -0.0）直接 continue
            if f == 0 { continue }
            let bits = f.bitPattern                             // floatToRawIntBits
            payload = [UInt8(truncatingIfNeeded: bits),
                       UInt8(truncatingIfNeeded: bits >> 8),
                       UInt8(truncatingIfNeeded: bits >> 16),
                       UInt8(truncatingIfNeeded: bits >> 24)]   // e1.E
            wireType = 5
            out.append(contentsOf: varint(UInt64(field.id) << 3 | UInt64(wireType)))
            out.append(contentsOf: payload)
            continue

        case .varint, .int32:
            let x = try jlongValue(value)
            if x == 0 { continue }                              // 行 1272-1273
            let enc: UInt64
            if field.type == .varint {
                // 行 1277-1280：shl 1 ^ shr 63（有符号 zigzag，64 位）
                enc = UInt64(bitPattern: (x << 1) ^ (x >> 63))
            } else {
                // 行 1282-1303：int32 范围检查后 zigzag32
                guard x >= Int64(Int32.min), x <= Int64(Int32.max) else {
                    throw MedusaError.int32Overflow(x)
                }
                let i = Int32(truncatingIfNeeded: x)
                enc = UInt64(UInt32(bitPattern: (i << 1) ^ (i >> 31)))
            }
            out.append(contentsOf: varint(UInt64(UInt32(bitPattern: field.id)) << 3 | 5))
            out.append(contentsOf: varint(enc))
            continue
        }

        // length-delimited 分支（nested / bytes / cstring）公共尾部，行 1219-1227
        if payload.isEmpty && field.type != .nested { continue } // if-nez v4 + if-ne v3,v5
        out.append(contentsOf: varint(UInt64(field.id) << 3 | UInt64(wireType)))
        out.append(contentsOf: varint(UInt64(payload.count)))
        out.append(contentsOf: payload)
    }
    return out
}

/// varint 编码（l0.L 的纯函数版）。
public func varint(_ value: UInt64) -> [UInt8] {
    var out: [UInt8] = []
    writeVarint64(value, into: &out)
    return out
}

// MARK: - l0.F：64 位自定义哈希
//
// 签名 F([B data, J seed, I s1, I s2, I s3, I s4) -> J
// 字节码（行 456-487）：
//   v9 = seed & 0xFFFFFFFF          // and-long/2addr v9, 0xFFFFFFFF
//   for i in 0..<data.length:
//       b = data[i] & 255
//       if (i & 1) != 0:                                    // 奇数下标
//           t  = ((v9 << s1) & 0xFFFFFFFF) ^ v9
//           t  = b ^ t
//           v9 = (v9 >>> s2) ^ t
//           v9 = v9 & 0xFFFFFFFF
//       else:                                               // 偶数下标
//           t  = b | ((v9 << s3) & 0xFFFFFFFF)
//           t  = t ^ (v9 >>> s4)
//           v9 = v9 ^ t
//           v9 = v9 ^ (-1L)                                 // 按位取反
//   return v9
//
// 已知调用点（都在 l0.H 内）：
//   F(data, seed, 7, 3, 11, 5)      // 行 645，data = I1(11, digest, 32)
//   F(urlBytes, 0, 11, 5, 7, 3)     // 行 675，data = v34 参数
//   C3.b 里 selector 用的 F(input, 539167016, 6, 4, 12, 7)
public func medusaHash(_ data: [UInt8], seed: UInt64,
                       _ s1: Int, _ s2: Int, _ s3: Int, _ s4: Int) -> UInt64 {
    let mask32: UInt64 = 0xFFFF_FFFF
    var v9 = seed & mask32
    let sh1 = UInt64(s1), sh2 = UInt64(s2), sh3 = UInt64(s3), sh4 = UInt64(s4)

    for i in 0..<data.count {
        let b = UInt64(data[i])                 // aget-byte + int-to-long + &255
        if i & 1 != 0 {
            let t = ((v9 &<< sh1) & mask32) ^ v9
            let t2 = b ^ t
            v9 = (v9 >> sh2) ^ t2               // ushr-long：无符号右移
            v9 = v9 & mask32
        } else {
            var t = b | ((v9 &<< sh3) & mask32)
            t = t ^ (v9 >> sh4)
            v9 = v9 ^ t
            v9 = v9 ^ UInt64(bitPattern: Int64(-1))   // xor-long/2addr v9, -1
        }
    }
    return v9
}

/// F 的截断版本：H 里 `long-to-int` 之后就只用低 32 位。
@inline(__always)
public func medusaHash32(_ data: [UInt8], seed: UInt64,
                         _ s1: Int, _ s2: Int, _ s3: Int, _ s4: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: medusaHash(data, seed: seed, s1, s2, s3, s4))
}
