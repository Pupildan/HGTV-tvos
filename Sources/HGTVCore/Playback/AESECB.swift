// AESECB.swift
// 纯 Swift 实现 AES-128 单块加密（ECB 单块 = 加密一个 16 字节块）。
//
// 为什么手写：CENC-AES-CTR 需要 keystream 块 = AES-ECB(key, counter_block)，
// 而 CommonCrypto 在 HGTVCore target 里不可用（CI 反复报 kCCDecryptMode /
// CCCryptorStatus / CCCryptorUpdate "cannot find in scope"），CryptoKit 的
// AES.GCM 又做不了 CTR（12 字节 nonce 只在末 4 字节递增、首块从 J0+1 起，
// 对不齐 CENC 计数器）。故用纯 Swift 手写单块加密，仅依赖 Foundation。
//
// 算法步骤已用纯 Python 等价实现对照 FIPS-197 附录 C.1 验证通过：
//   key=000102030405060708090a0b0c0d0e0f
//   pt =00112233445566778899aabbccddeeff
//   ct =69c4e0d86a7b0430d8cdb78070b4c55a  ✓
// 同时通过 NIST SP 800-38A ECB-AES128 第一块：
//   key=2b7e151628aed2a6abf7158809cf4f3c
//   pt =6bc1bee22e409f96e93d7e117393172a
//   ct =3ad77bb40d7a3660a89ecaf32466ef97  ✓

import Foundation

/// AES-128 S-box，运行时用 GF(2^8) 生成（避免手抄 256 项常量表出错）。
private let AES_SBOX: [UInt8] = {
    // GF(2^8) 乘法，模多项式 x^8+x^4+x^3+x+1 = 0x11B
    func gmul(_ a0: UInt8, _ b0: UInt8) -> UInt8 {
        var a = a0
        var b = b0
        var p: UInt8 = 0
        for _ in 0..<8 {
            if b & 1 != 0 { p ^= a }
            let hi = a & 0x80
            a = a << 1
            if hi != 0 { a ^= 0x1B }
            b = b >> 1
        }
        return p
    }
    // 暴力求乘法逆元
    var inv = [UInt8](repeating: 0, count: 256)
    for a in 1..<256 {
        for b in 1..<256 {
            if gmul(UInt8(a), UInt8(b)) == 1 {
                inv[a] = UInt8(b)
                break
            }
        }
    }
    var sbox = [UInt8](repeating: 0, count: 256)
    for x in 0..<256 {
        let s: UInt8 = (x != 0) ? inv[x] : 0
        var r = s
        var v = s
        for _ in 0..<4 {
            v = (v << 1) | (v >> 7)
            r ^= v
        }
        sbox[x] = r ^ 0x63
    }
    return sbox
}()

/// 轮常数 Rcon[i] = x^i 在 GF(2^8) 中。
private let AES_RCON: [UInt8] = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
]

extension CENCDecryptor {

    /// AES-128 单块加密（ECB 单块）。key 必须 16 字节，block 必须 16 字节，返回 16 字节密文。
    /// key 非 16 字节或 block 非 16 字节时返回空数组（调用方需检查）。
    static func ecbEncryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8] {
        guard key.count == 16, block.count == 16 else { return [] }

        // ---- Rijndael key schedule：128 位密钥 → 11 个 16 字节轮密钥 ----
        // w[i] 为一个 32-bit 字（4 字节）。i % 4 == 0 时做 RotWord/SubWord/Rcon。
        var w = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 44)
        for i in 0..<4 {
            for j in 0..<4 { w[i][j] = key[4 * i + j] }
        }
        for i in 4..<44 {
            var temp = w[i - 1]
            if i % 4 == 0 {
                // RotWord
                temp = [temp[1], temp[2], temp[3], temp[0]]
                // SubWord
                for j in 0..<4 { temp[j] = AES_SBOX[Int(temp[j])] }
                // XOR Rcon
                temp[0] ^= AES_RCON[i / 4 - 1]
            }
            for j in 0..<4 { w[i][j] = w[i - 4][j] ^ temp[j] }
        }
        var roundKeys = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 11)
        for r in 0..<11 {
            for c in 0..<4 {
                for j in 0..<4 { roundKeys[r][4 * c + j] = w[4 * r + c][j] }
            }
        }

        // ---- state 列主序：state[r][c] = block[4*c + r] ----
        var state = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 4)
        for c in 0..<4 {
            for r in 0..<4 { state[r][c] = block[4 * c + r] }
        }

        // AddRoundKey
        for c in 0..<4 {
            for r in 0..<4 { state[r][c] ^= roundKeys[0][4 * c + r] }
        }

        for round in 1..<10 {
            // SubBytes
            for r in 0..<4 {
                for c in 0..<4 { state[r][c] = AES_SBOX[Int(state[r][c])] }
            }
            // ShiftRows：行 r 左旋 r 字节
            for r in 1..<4 {
                let row = [state[r][0], state[r][1], state[r][2], state[r][3]]
                for c in 0..<4 { state[r][c] = row[(c + r) % 4] }
            }
            // MixColumns
            for c in 0..<4 {
                let a0 = state[0][c], a1 = state[1][c]
                let a2 = state[2][c], a3 = state[3][c]
                let x1 = xtime(a1), x2 = xtime(a2), x3 = xtime(a3), x0 = xtime(a0)
                state[0][c] = x0 ^ x1 ^ a1 ^ a2 ^ a3
                state[1][c] = a0 ^ x1 ^ x2 ^ a2 ^ a3
                state[2][c] = a0 ^ a1 ^ x2 ^ x3 ^ a3
                state[3][c] = x0 ^ a0 ^ a1 ^ a2 ^ x3
            }
            // AddRoundKey
            for c in 0..<4 {
                for r in 0..<4 { state[r][c] ^= roundKeys[round][4 * c + r] }
            }
        }

        // 末轮（无 MixColumns）
        for r in 0..<4 {
            for c in 0..<4 { state[r][c] = AES_SBOX[Int(state[r][c])] }
        }
        for r in 1..<4 {
            let row = [state[r][0], state[r][1], state[r][2], state[r][3]]
            for c in 0..<4 { state[r][c] = row[(c + r) % 4] }
        }
        for c in 0..<4 {
            for r in 0..<4 { state[r][c] ^= roundKeys[10][4 * c + r] }
        }

        var out = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 { out[4 * c + r] = state[r][c] }
        }
        return out
    }

    /// GF(2^8) 乘 2（模 x^8+x^4+x^3+x+1）。用于 MixColumns。
    @inline(__always)
    private static func xtime(_ a: UInt8) -> UInt8 {
        let doubled = a << 1
        return (a & 0x80) != 0 ? (doubled ^ 0x1B) : doubled
    }

    /// CENC 计数器块最后 8 字节（big-endian 64-bit 计数器）+1，进位跨越全部 8 字节。
    /// counter 为 16 字节 in-place 修改：counter[8] 是最高字节，counter[15] 是最低字节。
    @inline(__always)
    static func incrementCounter(_ counter: inout [UInt8]) {
        var carry: UInt8 = 1
        var i = 15
        while i >= 8 && carry != 0 {
            let s = UInt16(counter[i]) + UInt16(carry)
            counter[i] = UInt8(s & 0xFF)
            carry = UInt8(s >> 8)
            i -= 1
        }
        // carry 残留时表示 64-bit 计数器溢出回绕（CENC 实际不会发生），忽略高位进位
    }
}
