// CENCDecryptor.swift
// CENC-AES-CTR mp4 解密（番茄短剧 progressive mp4，非 fragmented）。
// 忠实移植 gorgon_py/cenc_decrypt.py：解析 moov→trak→mdia→minf→stbl 下的
// stsz/stsc/stco(co64)/senc，逐样本用其 IV 做 AES-128-CTR 整样本解密。
// CTR 不能用 CryptoKit 的 AES.GCM，这里用 CommonCrypto 的 CCCryptorCreateWithMode(kCCModeCTR)。

import Foundation
import CommonCrypto

public enum CENCError: Error, LocalizedError {
    case noMoov
    case noStbl
    case missingTable(String)
    case truncated
    case cryptoFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .noMoov: return "mp4 缺少 moov box"
        case .noStbl: return "trak 缺少 stbl box"
        case .missingTable(let t): return "stbl 缺少 \(t) box"
        case .truncated: return "mp4 数据被截断"
        case .cryptoFailed(let s): return "AES-CTR 解密失败 (status=\(s))"
        }
    }
}

/// 一个解密样本：mdat 中的偏移 + 大小 + 8 字节 IV。
struct CENCSample {
    var offset: Int
    var size: Int
    var iv: [UInt8]?
}

public enum CENCDecryptor {

    // MARK: - box 迭代

    struct Box {
        let type: String
        let offset: Int
        let headerSize: Int
        let size: Int
    }

    /// 按 _iter_boxes：返回 [off, end) 内的顶层 box 列表。
    static func iterBoxes(_ buf: [UInt8], _ off: Int, _ end: Int) -> [Box] {
        var boxes = [Box]()
        var o = off
        while o + 8 <= end {
            let size = Int(be32(buf, o))
            let typ = latin1(buf, o + 4, 4)
            var hdr = 8
            var sz = size
            if size == 1 {
                sz = Int(be64(buf, o + 8))
                hdr = 16
            } else if size == 0 {
                sz = end - o
            }
            if sz < 8 { break }
            boxes.append(Box(type: typ, offset: o, headerSize: hdr, size: sz))
            o += sz
        }
        return boxes
    }

    /// _find_box：按 path 依次进入容器，返回 (offset, size)。path 为空时在顶层找。
    static func findBox(_ buf: [UInt8], _ typ: String, path: [String] = []) -> (Int, Int)? {
        var cur = [(0, buf.count)]
        for want in path {
            var nxt = [(Int, Int)]()
            for (o, e) in cur {
                for b in iterBoxes(buf, o, e) where b.type == want {
                    nxt.append((b.offset + b.headerSize, b.offset + b.size))
                }
            }
            cur = nxt
        }
        for (o, e) in cur {
            for b in iterBoxes(buf, o, e) where b.type == typ {
                return (b.offset, b.size)
            }
        }
        return nil
    }

    // MARK: - 轨道表解析（rec 递归，忠实移植 parse_track_tables）

    static func findIn(_ buf: [UInt8], _ o: Int, _ e: Int, _ want: String) -> (Int, Int)? {
        for b in iterBoxes(buf, o, e) {
            if b.type == want { return (b.offset + b.headerSize, b.offset + b.size) }
            if b.type == "trak" || b.type == "mdia" || b.type == "minf" ||
                b.type == "stbl" || b.type == "edts" || b.type == "dinf" {
                if let r = findIn(buf, b.offset + b.headerSize, b.offset + b.size, want) {
                    return r
                }
            }
        }
        return nil
    }

    /// 解析单个 trak 的 stsz/stsc/stco(co64)/senc，返回表内容字节。
    static func parseTrackTables(_ data: [UInt8], _ trakOff: Int, _ trakEnd: Int)
        -> [String: [UInt8]]? {
        guard let stbl = findIn(data, trakOff, trakEnd, "stbl") else { return nil }
        let (so, se) = stbl
        var tbls = [String: [UInt8]]()
        for b in iterBoxes(data, so, se) {
            if b.type == "stsz" || b.type == "stsc" || b.type == "stco" ||
                b.type == "co64" || b.type == "senc" || b.type == "stsd" {
                tbls[b.type] = Array(data[(b.offset + b.headerSize)..<(b.offset + b.size)])
            }
        }
        return tbls
    }

    // MARK: - 样本 (offset,size,iv) 列表（忠实移植 samples_from_tables，含 chunk 内累加）

    static func samplesFromTables(_ tbls: [String: [UInt8]]) throws -> [CENCSample] {
        guard let stsz = tbls["stsz"] else { throw CENCError.missingTable("stsz") }
        guard let stsc = tbls["stsc"] else { throw CENCError.missingTable("stsc") }
        guard let senc = tbls["senc"] else { throw CENCError.missingTable("senc") }

        // stsz
        let sampleSize = Int(be32(stsz, 4))
        let count = Int(be32(stsz, 8))
        var sizes = [Int](repeating: 0, count: count)
        if sampleSize != 0 {
            for i in 0..<count { sizes[i] = sampleSize }
        } else {
            for i in 0..<count {
                let p = 12 + 4 * i
                guard p + 4 <= stsz.count else { throw CENCError.truncated }
                sizes[i] = Int(be32(stsz, p))
            }
        }

        // stsc: (first_chunk, samples_per_chunk, sample_desc)
        let n = Int(be32(stsc, 4))
        var stscEntries = [(Int, Int, Int)]()
        stscEntries.reserveCapacity(n)
        for i in 0..<n {
            let p = 8 + 12 * i
            guard p + 12 <= stsc.count else { throw CENCError.truncated }
            stscEntries.append((Int(be32(stsc, p)), Int(be32(stsc, p + 4)), Int(be32(stsc, p + 8))))
        }

        // stco(32) / co64(64)
        var chunks = [Int]()
        if let co = tbls["co64"] {
            let nco = Int(be32(co, 4))
            chunks.reserveCapacity(nco)
            for i in 0..<nco {
                let p = 8 + 8 * i
                guard p + 8 <= co.count else { throw CENCError.truncated }
                chunks.append(Int(be64(co, p)))
            }
        } else if let co = tbls["stco"] {
            let nco = Int(be32(co, 4))
            chunks.reserveCapacity(nco)
            for i in 0..<nco {
                let p = 8 + 4 * i
                guard p + 4 <= co.count else { throw CENCError.truncated }
                chunks.append(Int(be32(co, p)))
            }
        } else {
            throw CENCError.missingTable("stco")
        }

        // sample → chunk offset：同一 chunk 内样本连续排布，需累加前序样本大小
        var offsets = [Int]()
        var chunkIdx = 0
        var si = 0
        for ci in 0..<stscEntries.count {
            let firstChunk = stscEntries[ci].0
            let spc = stscEntries[ci].1
            let nextFirst: Int? = (ci + 1 < stscEntries.count) ? stscEntries[ci + 1].0 : nil
            while chunkIdx + 1 < firstChunk { chunkIdx += 1 }
            while si < sizes.count {
                if let nf = nextFirst, chunkIdx + 1 >= nf { break }
                guard chunkIdx < chunks.count else { throw CENCError.truncated }
                var curOff = chunks[chunkIdx]
                for _ in 0..<spc {
                    if si >= sizes.count { break }
                    offsets.append(curOff)
                    curOff += sizes[si]   // chunk 内下一个样本紧随其后
                    si += 1
                }
                chunkIdx += 1
                if let nf = nextFirst, chunkIdx + 1 >= nf { break }
            }
        }

        // senc IVs
        guard senc.count >= 8 else { throw CENCError.truncated }
        let flags = Int(be24(senc, 1))
        var idx = 4
        let cnt = Int(be32(senc, idx))
        idx += 4
        var ivs = [[UInt8]]()
        ivs.reserveCapacity(cnt)
        for _ in 0..<cnt {
            let ivlen: Int
            if flags & 0x2 != 0 {
                guard idx < senc.count else { throw CENCError.truncated }
                ivlen = Int(senc[idx])
                idx += 1
            } else {
                ivlen = 8
            }
            guard idx + ivlen <= senc.count else { throw CENCError.truncated }
            ivs.append(Array(senc[idx..<(idx + ivlen)]))
            idx += ivlen
            var nsub = 0
            if flags & 0x1 != 0 {
                guard idx + 2 <= senc.count else { throw CENCError.truncated }
                nsub = Int(be16(senc, idx))
                idx += 2
            }
            idx += nsub * 6
        }

        var out = [CENCSample]()
        out.reserveCapacity(sizes.count)
        for i in 0..<sizes.count {
            guard i < offsets.count else { break }  // stsc 未覆盖全部样本时安全截断
            let iv = i < ivs.count ? ivs[i] : nil
            out.append(CENCSample(offset: offsets[i], size: sizes[i], iv: iv))
        }
        return out
    }

    // MARK: - 解密入口

    /// 返回解密后的 mp4 data。对每个 trak 的每个样本用其 IV 做 AES-CTR 整样本解密。
    public static func decrypt(data: Data, key: Data) throws -> Data {
        var buf = [UInt8](data)
        guard let moov = findBox(buf, "moov") else { throw CENCError.noMoov }
        let (moovOff, moovSize) = moov
        let moovHdr = (Int(be32(buf, moovOff)) == 1) ? 16 : 8
        for b in iterBoxes(buf, moovOff + moovHdr, moovOff + moovSize) {
            if b.type == "trak" {
                guard let tbls = parseTrackTables(buf, b.offset, b.offset + b.size),
                      tbls["stsz"] != nil, tbls["senc"] != nil else { continue }
                let samples = try samplesFromTables(tbls)
                for s in samples {
                    guard let iv = s.iv else { continue }
                    let soff = s.offset
                    let ssize = s.size
                    guard soff >= 0, ssize >= 0, soff + ssize <= buf.count else { continue }
                    let plain = try ctrCrypt(key: key, iv: iv, data: Array(buf[soff..<(soff + ssize)]))
                    buf.replaceSubrange(soff..<(soff + ssize), with: plain)
                }
            }
        }
        return Data(buf)
    }

    // MARK: - AES-128-CTR（CommonCrypto；CTR 加密=解密）

    /// 用 iv（8 字节）构造 16B 计数器 = iv + 8 字节 big-endian 从 0 起，对整段 data 做 CTR XOR。
    static func ctrCrypt(key: Data, iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard !data.isEmpty else { return data }
        // 计数器块：IV(8) 左对齐 + 8 字节计数器从 0 起
        var counter = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(iv.count, 16) { counter[i] = iv[i] }

        var cryptor: CCCryptorRef?
        // CTR 无 padding；加密=解密，此处用 kCCDecryptMode（与参考一致）
        var status = counter.withUnsafeBytes { cBuf -> CCCryptorStatus in
            key.withUnsafeBytes { kBuf -> CCCryptorStatus in
                CCCryptorCreateWithMode(
                    kCCDecryptMode, kCCModeCTR, kCCAlgorithmAES, ccNoPadding,
                    cBuf.baseAddress!, kBuf.baseAddress!, key.count,
                    nil, 0, 0, &cryptor)
            }
        }
        guard status == kCCSuccess, let ref = cryptor else {
            throw CENCError.cryptoFailed(status)
        }
        defer { CCCryptorRelease(ref) }

        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        status = data.withUnsafeBytes { inBuf -> CCCryptorStatus in
            out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
                CCCryptorUpdate(ref,
                                inBuf.baseAddress!, data.count,
                                outBuf.baseAddress!, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw CENCError.cryptoFailed(status) }
        if moved < out.count {
            out.removeLast(out.count - moved)
        }
        return out
    }

    // MARK: - 字节读取助手（big-endian / latin1）

    @inline(__always) static func be16(_ b: [UInt8], _ o: Int) -> Int {
        return (Int(b[o]) << 8) | Int(b[o + 1])
    }

    @inline(__always) static func be24(_ b: [UInt8], _ o: Int) -> Int {
        return (Int(b[o]) << 16) | (Int(b[o + 1]) << 8) | Int(b[o + 2])
    }

    @inline(__always) static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) |
               (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    @inline(__always) static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }

    @inline(__always) static func latin1(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
        let slice = b[o..<(o + n)]
        return String(decoding: slice, as: Unicode.Latin1.self)
    }
}
