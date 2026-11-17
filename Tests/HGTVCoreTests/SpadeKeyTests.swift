// SpadeKeyTests.swift
// 播放解密链路自检：spade_a → AES-128 密钥的固定向量回归。
// 参考向量来自 gorgon_py/spade.py 实测（已解出可播放 HEVC mp4）。

import Testing
import Foundation
@testable import HGTVCore

@Suite("播放解密")
struct SpadeKeyTests {

    @Test("spade_a 派生密钥固定向量")
    func deriveKeyVector() throws {
        let spade = "nLwS816KF8Jsjxf0R486wHS5DfdEjjnGaL0WxFu9JfKlu+1nZw=="
        let key = try SpadeKey.deriveKey(spade)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "195c21c7dd8de75cb71be08dfa4ae6f3")
        #expect(key.count == 16)
    }

    @Test("hex decode 往返")
    func hexDecode() {
        #expect(SpadeKey.hexDecode("00ff10") == [0x00, 0xff, 0x10])
        #expect(SpadeKey.hexDecode("zz") == nil)
        #expect(SpadeKey.hexDecode("abc") == nil)
    }

    @Test("Range 解析")
    func byteRange() {
        let req = "GET /video HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n"
        #expect(PlaybackProxy.parseByteRange(req, total: 1000) == (0, 99))
        let openEnded = "GET /video HTTP/1.1\r\nRange: bytes=500-\r\n\r\n"
        #expect(PlaybackProxy.parseByteRange(openEnded, total: 1000) == (500, 999))
        let suffix = "GET /video HTTP/1.1\r\nRange: bytes=-100\r\n\r\n"
        #expect(PlaybackProxy.parseByteRange(suffix, total: 1000) == (900, 999))
        let none = "GET /video HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(PlaybackProxy.parseByteRange(none, total: 1000) == nil)
    }
}
