// CENCDecryptor.swift
// CENC-AES-CTR mp4 解密（番茄短剧 progressive mp4，非 fragmented）。
// 忠实移植 gorgon_py/cenc_decrypt.py：解析 moov→trak→mdia→minf→stbl 下的
// stsz/stsc/stco(co64)/senc，逐样本用其 IV 做 AES-128-CTR 整样本解密。
// CTR 计数器块 = IV(8) + 8 字节 big-endian 从 0 起。CryptoKit 的 AES.GCM 无法对齐
// （12 字节 nonce 时首数据块计数器固定从 J0+1=2 起，给不出 counter_0/counter_1），
// 因此逐 16 字节计数器块用纯 Swift 手写 AES-128-ECB（AESECB.swift）生成 keystream。

import Foundation

public enum CENCError: Error, LocalizedError {
    case noMoov
    case noStbl
    case missingTable(String)
    case truncated
    case cryptoFailed(Int32)
    case keySizeInvalid

    public var errorDescription: String? {
        switch self {
        case .noMoov: return "mp4 缺少 moov box"
        case .noStbl: return "trak 缺少 stbl box"
        case .missingTable(let t): return "stbl 缺少 \(t) box"
        case .truncated: return "mp4 数据被截断"
        case .cryptoFailed(let s): return "AES-CTR 解密失败 (status=\(s))"
        case .keySizeInvalid: return "AES-128 密钥长度必须为 16 字节"
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
    /// 解密后额外做 AVPlayer 兼容清理（见 sanitizeForAVPlayer）。
    /// v21：整个视频共用一个内容密钥 → key schedule 在此展开一次传入 ctrCrypt。
    ///
    /// 对齐 nas-bridge/cenc_decrypt.py v90 实战版（逐行核过）：senc 每样本 8 字节 IV
    ///（flags&0x2 可变长 / flags&0x1 subsample 跳过）直接读表、无需自行递增；
    /// CTR 16B 计数器块 = IV(8) + 64bit big-endian 从 0 起（Python
    /// `Counter.new(64, prefix=iv, initial_value=0)` 等价）；逐块 +1 仅在低 8 字节内进位；
    /// 整样本 XOR keystream。stsz/stsc/stco(co64) 样本定位含 chunk 内累加，逐行一致。
    public static func decrypt(data: Data, key: Data) throws -> Data {
        var buf = [UInt8](data)
        guard let moov = findBox(buf, "moov") else { throw CENCError.noMoov }
        let (moovOff, moovSize) = moov
        let moovHdr = (Int(be32(buf, moovOff)) == 1) ? 16 : 8
        let keyBytes = [UInt8](key)
        guard keyBytes.count == 16 else { throw CENCError.keySizeInvalid }
        let schedule = expandKey(keyBytes)
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
                    let plain = try ctrCrypt(schedule: schedule, iv: iv, data: Array(buf[soff..<(soff + ssize)]))
                    buf.replaceSubrange(soff..<(soff + ssize), with: plain)
                }
            }
        }
        sanitizeForAVPlayer(&buf)
        return Data(buf)
    }

    // MARK: - AVPlayer 兼容清理（坑 13：解密后 mp4 仍带加密壳 → AVPlayer 拒渲染）

    /// 番茄的 progressive mp4 在 stsd 里用加密样本入口：视频 `encv`、音频 `enca`，
    /// 配套 `sinf`(frma/schm/schi/tenc)，stbl 里还有 `senc`/`saiz`/`saio`。
    /// 只解密 mdat 样本、不动这些壳时：
    ///   - moov 结构可解析 → AVPlayerItem 照样 readyToPlay、timeControl 能到 playing；
    ///   - 但 AVFoundation 见到 encv/enca 就认定内容受保护、需要解密器 → 视频解码器
    ///     永不输出一帧，playerLayer.isReadyForDisplay 恒 false → 全黑。
    ///   - 桌面播放器（VLC/ffplay）对"样本已是明文"宽容，所以 Python 金标准产物能播，
    ///     这个坑只在 AVPlayer 上暴露。
    ///
    /// 清理方式（**in-place 4CC 替换**，不移动任何字节，stco/co64 绝对偏移无需修正）：
    ///   - `encv`/`enca` → `frma` 里的原始编码 4CC（hvc1/avc1/mp4a…）
    ///   - `sinf`（含 schm/schi/tenc）→ `free`
    ///   - `senc`/`saiz`/`saio` → `free`（对照 nas-bridge/cenc_sanitize.py v90 实战版：
    ///     其保留这三个 box 原样也实测播通——AVPlayer 的加密判定只看 stsd sample entry；
    ///     换成 free 属无害的额外保险，维持 v83 真机已验证的路径）
    static func sanitizeForAVPlayer(_ buf: inout [UInt8]) {
        guard let moov = findBox(buf, "moov") else { return }
        let (moovOff, moovSize) = moov
        let moovHdr = (Int(be32(buf, moovOff)) == 1) ? 16 : 8
        for b in iterBoxes(buf, moovOff + moovHdr, moovOff + moovSize) where b.type == "trak" {
            guard let stbl = findIn(buf, b.offset, b.offset + b.size, "stbl") else { continue }
            let (so, se) = stbl
            for t in iterBoxes(buf, so, se) {
                switch t.type {
                case "stsd":
                    sanitizeStsd(&buf, t)
                case "senc", "saiz", "saio":
                    swapBoxType(&buf, at: t.offset, to: "free")
                default:
                    break
                }
            }
        }
    }

    /// 原地把 box type 改成 newType（4 字节，不改变 box 大小/位置）。
    private static func swapBoxType(_ buf: inout [UInt8], at off: Int, to newType: String) {
        let bytes = Array(newType.utf8)
        guard bytes.count == 4, off + 8 <= buf.count else { return }
        for (i, c) in bytes.enumerated() { buf[off + 4 + i] = c }
    }

    /// 清理 stsd：加密样本入口 encv/enca → frma 原格式；其内部 sinf → free。
    ///
    /// 对齐 nas-bridge/cenc_sanitize.py v90 实战版：sinf 定位**不用固定偏移 walk**
    ///（encv/enca 的 child boxes 前有非 box 固定字段，enca version≠0 时长度还会变），
    /// 改为在 entry payload 里逐字节扫描 "sinf" fourcc + 结构自洽校验
    ///（size>=8、off+size<=end、sinf 内第一个子 box 必须是 frma(size=12)），
    /// 扫描未命中时退回旧固定偏移路径（Visual 86 / Audio 36，v83 真机验证过）兜底。
    ///
    /// box 处理保留 in-place 4CC 替换（sinf→free 而非整段切除）：AVPlayer 按规范跳过
    /// free box，与切除语义等价，且免去 Python 版所需的 stco/co64 chunk 偏移重定位；
    /// v83 真机已验证可播。
    private static func sanitizeStsd(_ buf: inout [UInt8], _ stsd: Box) {
        let bodyStart = stsd.offset + stsd.headerSize
        let bodyEnd = stsd.offset + stsd.size
        // stsd body：[ver/flags 4][entry_count 4][entries...]
        guard bodyStart + 8 <= bodyEnd else { return }
        var pos = bodyStart + 8
        while pos + 8 <= bodyEnd {
            let entrySize = Int(be32(buf, pos))
            guard entrySize >= 8, pos + entrySize <= bodyEnd else { return }
            let type4 = String(decoding: buf[(pos + 4)..<(pos + 8)], as: Unicode.ASCII.self)
            if type4 == "encv" || type4 == "enca" {
                let entryBody = pos + 8
                let entryEnd = pos + entrySize
                var originalFormat: [UInt8]?
                // 主路径（对齐 cenc_sanitize.py _find_sinf）：payload 全范围扫描 sinf
                if let sinf = findSinf(buf, entryBody, entryEnd) {
                    // frma 是 sinf 第一个子 box（实战观察），data_format 在其 payload 前 4 字节
                    let sinfBody = sinf.offset + sinf.headerSize
                    let sinfEnd = sinf.offset + sinf.size
                    for sub in iterBoxes(buf, sinfBody, sinfEnd) where sub.type == "frma" {
                        let fr = sub.offset + sub.headerSize
                        guard fr + 4 <= buf.count else { continue }
                        originalFormat = Array(buf[fr..<(fr + 4)])
                    }
                    // sinf（含 schm/schi/tenc）→ free（in-place，大小/位置不变）
                    swapBoxType(&buf, at: sinf.offset, to: "free")
                }
                if originalFormat == nil {
                    // 兜底路径（旧实现，v83 真机验证过）：固定偏移 walk child boxes
                    let childStart = (type4 == "encv") ? pos + 86 : pos + 36
                    if childStart <= entryEnd {
                        for child in iterBoxes(buf, childStart, entryEnd) {
                            if child.type == "frma" {
                                let fr = child.offset + child.headerSize
                                guard fr + 4 <= buf.count else { continue }
                                originalFormat = Array(buf[fr..<(fr + 4)])
                            } else if child.type == "sinf" {
                                // 自洽校验未命中但 4CC 存在的 sinf 也一并换成 free
                                swapBoxType(&buf, at: child.offset, to: "free")
                                let sinfBody = child.offset + child.headerSize
                                let sinfEnd = child.offset + child.size
                                for sub in iterBoxes(buf, sinfBody, sinfEnd) where sub.type == "frma" {
                                    let fr = sub.offset + sub.headerSize
                                    guard fr + 4 <= buf.count else { continue }
                                    originalFormat = Array(buf[fr..<(fr + 4)])
                                }
                            }
                        }
                    }
                }
                // encv/enca → 原始编码（hvc1/avc1/mp4a…）；找不到 frma 就保持原样
                if let fmt = originalFormat {
                    for (i, c) in fmt.enumerated() { buf[pos + 4 + i] = c }
                }
            }
            pos += entrySize
        }
    }

    /// 对齐 nas-bridge/cenc_sanitize.py v90 实战版 `_find_sinf`：
    /// 在 [start,end) 里逐字节定位一个结构自洽的 sinf box，返回 (offset, size) 或 nil。
    /// 校验：size>=8、off+size<=end，且 sinf 内第一个子 box 必须是 frma（size==12）。
    /// 这样能避免误匹配到 hvcC 等负载里偶然出现的 'sinf' 字符串。
    static func findSinf(_ buf: [UInt8], _ start: Int, _ end: Int) -> (offset: Int, size: Int)? {
        var o = start
        while o + 8 <= end {
            if buf[o + 4] == 0x73, buf[o + 5] == 0x69,
               buf[o + 6] == 0x6E, buf[o + 7] == 0x66 {   // "sinf"
                let size = Int(be32(buf, o))
                if size >= 8, o + size <= end, o + 16 <= end {
                    // sinf payload 第一个子 box 应为 frma：4CC 在 +12..+16，size 在 +8..+12
                    if buf[o + 12] == 0x66, buf[o + 13] == 0x72,
                       buf[o + 14] == 0x6D, buf[o + 15] == 0x61 {   // "frma"
                        let fsize = Int(be32(buf, o + 8))
                        if fsize == 12 {
                            return (o, size)
                        }
                    }
                }
            }
            o += 1
        }
        return nil
    }

    // MARK: - AES-128-CTR（纯 Swift 手写 AES-128-ECB 生成 keystream）

    /// CENC 8 字节 IV → CTR 解密。CENC 计数器块 = IV(8) + 8 字节 big-endian 从 0 起，
    /// keystream 块 k = AES-ECB(IV || k)。首块计数器是 IV||0x0000000000000000（counter_0）。
    ///
    /// v21：接受预展开轮密钥（每视频展开一次，避免逐块重算 key schedule）。
    /// 兼容入口见下方 ctrCrypt(key:iv:data:)。
    ///
    /// ⚠️ 不要用 CryptoKit 的 AES.GCM 生成 keystream：12 字节 nonce 时 GCM 计数器只在
    /// 末 4 字节递增，且首数据块固定从 J0+1（=nonce||0x00000002）开始，只能产出
    /// counter_2、counter_3…，永远给不出 counter_0/counter_1，且字节布局也不对。
    /// CommonCrypto 在本 target 不可用，故用纯 Swift 手写 AES-128-ECB 单块加密，
    /// 逐 16 字节计数器块生成 keystream，再 XOR 到 data。
    static func ctrCrypt(schedule: [[UInt8]], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard !data.isEmpty else { return data }

        // 16 字节计数器块 = IV(8) + 8 字节 big-endian 计数器（从 0 起）
        var counter = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(iv.count, 8) { counter[i] = iv[i] }
        // counter[8..<16] 保持 0 → 首块即 CENC counter_0

        var out = [UInt8](repeating: 0, count: data.count)
        var blockStart = 0
        while blockStart < data.count {
            // keystream 块 = AES-128-ECB(key, 当前计数器块)
            let keystream = encryptBlock(roundKeys: schedule, block: counter)
            guard keystream.count == 16 else {
                throw CENCError.keySizeInvalid
            }
            // XOR 本块数据（末块可能不足 16 字节）
            let blockEnd = min(blockStart + 16, data.count)
            for j in blockStart..<blockEnd {
                out[j] = data[j] ^ keystream[j - blockStart]
            }
            // 计数器 +1（8 字节 big-endian，进位跨越全部 8 字节）
            incrementCounter(&counter)
            blockStart = blockEnd
        }
        return out
    }

    /// 兼容入口：临时密钥场景（非热路径）用。
    static func ctrCrypt(key: Data, iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let keyBytes = [UInt8](key)
        guard keyBytes.count == 16 else { throw CENCError.keySizeInvalid }
        return try ctrCrypt(schedule: expandKey(keyBytes), iv: iv, data: data)
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
        return String(decoding: slice, as: Unicode.ASCII.self)
    }
}
