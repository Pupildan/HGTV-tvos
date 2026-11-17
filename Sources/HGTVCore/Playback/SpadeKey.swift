// SpadeKey.swift
// spade_a → AES-128 内容密钥派生。
// 忠实移植 gorgon_py/spade.py（逆向自原 APK signing_full.txt 行 6498-6540）。
// 自测基准：spade_a = "nLwS816KF8Jsjxf0R486wHS5DfdEjjnGaL0WxFu9JfKlu+1nZw=="
//           → key hex = 195c21c7dd8de75cb71be08dfa4ae6f3

import Foundation

public enum SpadeKeyError: Error, LocalizedError {
    case badBase64
    case tooShort
    case keyLengthTooSmall(Int)
    case badKeyString
    case badKeyLength(Int)

    public var errorDescription: String? {
        switch self {
        case .badBase64: return "spade_a 不是合法 Base64"
        case .tooShort: return "内容密钥格式异常 (len<3)"
        case .keyLengthTooSmall(let n): return "Failed requirement. (keyLen=\(n))"
        case .badKeyString: return "密钥字符串不是合法 UTF-8"
        case .badKeyLength(let n): return "Failed requirement. (key len=\(n))"
        }
    }
}

public enum SpadeKey {
    /// spade_a（base64 字符串）→ 16 字节 AES-128 内容密钥。
    public static func deriveKey(_ spadeA: String) throws -> Data {
        guard let raw = Data(base64Encoded: spadeA) else {
            throw SpadeKeyError.badBase64
        }
        let bytes = [UInt8](raw)
        guard bytes.count >= 3 else { throw SpadeKeyError.tooShort }

        // keyLen = min((len - (b0^b1^b2)) + 47, len-1)
        let xor3 = bytes[0] ^ bytes[1] ^ bytes[2]
        let keyLen = min((bytes.count - Int(xor3)) + 47, bytes.count - 1)
        guard keyLen >= 33 else { throw SpadeKeyError.keyLengthTooSmall(keyLen) }

        // slice = raw[1:keyLen+1]（copyOfRange(bytes,1,keyLen+1)）
        var slice = Array(bytes[1...keyLen])

        var oddSeed: UInt8 = 85    // 奇数位种子 v12_4
        var evenSeed: UInt8 = 246  // 偶数位种子 v13_6
        for i in 0..<slice.count {
            let b = slice[i]
            let s: UInt8
            if (i & 1) == 0 {
                s = evenSeed
                evenSeed = b
            } else {
                s = oddSeed
                oddSeed = b
            }
            // (-21 - bitCount(i)) + (s ^ b)，按 byte 截断（& 0xFF）
            let v = (-21 - i.nonzeroBitCount) + Int(s ^ b)
            slice[i] = UInt8(truncatingIfNeeded: v)
        }

        // keyStr = slice[1:33] → 32 字符 hex
        guard slice.count >= 33,
              let keyStr = String(bytes: slice[1..<33], encoding: .utf8) else {
            throw SpadeKeyError.badKeyString
        }
        guard let key = Self.hexDecode(keyStr) else {
            throw SpadeKeyError.badKeyString
        }
        guard key.count == 16 else { throw SpadeKeyError.badKeyLength(key.count) }
        return Data(key)
    }

    /// 手写 hex decode（偶数长度，非 hex 字符返回 nil）。
    public static func hexDecode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }
}
