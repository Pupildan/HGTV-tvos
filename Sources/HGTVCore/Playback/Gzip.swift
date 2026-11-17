// Gzip.swift
// gzip 压缩（multi_video_model 的 POST body 需要 Content-Encoding: gzip）。
// Apple 的 Compression 框架 COMPRESSION_ZLIB 是裸 DEFLATE（RFC1951），
// 这里手工包 gzip 头尾（RFC1952）：10B 头 + DEFLATE + CRC32(LE) + ISIZE(LE)。

import Foundation
import Compression

public enum Gzip {
    /// 压缩为完整 gzip 字节流。
    public static func compress(_ data: Data) -> Data {
        var out = Data()
        // gzip header: magic 1f 8b, method 08(deflate), flags 00, mtime 00000000, xfl 00, os 03(unix)
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflate(data))
        appendLE32(&out, crc32(data))
        appendLE32(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// 裸 DEFLATE 压缩（COMPRESSION_ZLIB）。
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        // 预留足够输出缓冲（DEFLATE 对不可压数据最多略高于输入）
        var capacity = data.count + 128
        while true {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written: Int = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dst, capacity,
                    base.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB)
            }
            if written > 0 {
                return Data(bytes: dst, count: written)
            }
            // 缓冲不足则扩容重试（compression_encode_buffer 返回 0 表示空间不够/失败）
            capacity *= 2
            if capacity > data.count * 8 + 65536 {
                // 极端情况兜底：返回未压缩数据（调用方 body 仍可被服务端解析为普通 JSON）
                return data
            }
        }
    }

    static func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 24) & 0xff))
    }

    /// CRC-32 (IEEE 802.3)，逐位实现（body 很小，无需查表）。
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xedb88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xffffffff
    }
}
