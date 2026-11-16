// XGorgonH.swift
// F0.l0.H —— x-gorgon 加密主体的忠实 Swift 移植。
//
// 依据：smali 字节码 `decomp/smali/l0.smali.txt` 行 521-1111（逐行对照）。
// 依赖：E1Constants.swift 的 E1C.o/q/r/s/t/p；MedusaSerializer.swift 的 medusaHash；
//       CryptoPrimitives.swift 的 md5/le32/le64/base64Encode；DeviceFingerprint.swift 的 varlenHash。
//
// 字节码寄存器 → H 形参映射（v26..v34 是 smali 的入参槽）：
//   v26 = protobuf 明文      v27 = 随机 long 种子
//   v29 = 时间戳 long        v31 = 另一个 long
//   v33 = 20B medusa 摘要    v34 = URL/参数字节
//
// 已确认语义（任务给定，覆盖 XGorgonSerialize.md 早期误判）：
//   h1/j.N1([B,[B)[B     = 数组拼接 concat（copyOf(a, a.len+b.len) + arraycopy），**非 XOR**
//   h1/j.I1(I,[B,I)[B    = 切片 copyOfRange(arr, from, to)
//   h1/j.H1([B,[B,I,I,I)V = System.arraycopy
//   l1/d.z/w/n           = Kotlin 边界/区间检查，非密钥派生

import Foundation

// MARK: - helper（h1/j 的 Swift 私有实现）

/// h1/j.N1([B a, [B b)[B —— 数组拼接。
/// 字节码语义：`Arrays.copyOf(a, a.len + b.len)` 再 `System.arraycopy(b, 0, a, a.len, b.len)`。
/// 参数顺序 = 拼接顺序（先 a 后 b）。concat 不可交换，凡顺序存疑处见 TODO(待对拍)。
@inline(__always)
private func n1(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var out = a
    out.append(contentsOf: b)
    return out
}

/// h1/j.I1(I from, [B arr, I to)[B —— 切片 `Arrays.copyOfRange(arr, from, to)`。
@inline(__always)
private func i1(_ from: Int, _ arr: [UInt8], _ to: Int) -> [UInt8] {
    guard from >= 0, to <= arr.count, from <= to else {
        // l1/d.z/w 抛 ArrayIndexOutOfBoundsException 的等价路径
        return []
    }
    return Array(arr[from..<to])
}

/// i1 的安全钳制版：to 超出 arr.length 时取到末尾（不抛异常）。
/// 用于 v7 在阶段 G 前可能被重绑定为更长缓冲、但静态无法确定长度的场景。
@inline(__always)
private func i1Safe(_ from: Int, _ arr: [UInt8], _ to: Int) -> [UInt8] {
    let hi = min(max(to, from), arr.count)
    let lo = min(max(from, 0), hi)
    return Array(arr[lo..<hi])
}

/// l0.k0(int a, int b) —— 8 位循环左移，rotate 量取低 3 位（CryptoPrimitives 已有 rotateLeft8）。
@inline(__always)
private func k0(_ a: UInt32, _ b: UInt32) -> UInt32 {
    rotateLeft8(a, b)
}

// MARK: - l0.G / l0.K（阶段 H 的两个轮变换）

/// l0.G([B block, I start, [B keyMat)V —— 用 keyMat 按 e1.q 置换后逐位异或 block。
/// 字节码（行 488-520）：形参 v9=block、v10=start、v11=keyMat。
/// 循环 j in 0..<4（v2=4）：`block[start+j] ^= keyMat[start + e1.q[rounds][j]]`。
/// 三处调用 G(block,0,keyMat) 里 start 恒为 0，rounds 取 keyMat 数组 v10/v11/v12 前缀。
/// e1.q[0]={2,0,3,1}，故 block[j] ^= keyMat[q0[j]]。
private func l0_G(_ block: inout [UInt8], _ start: Int, _ keyMat: [UInt8], _ rounds: Int) {
    let qRow = E1C.q[rounds]
    for j in 0..<4 {
        let idx = start + j
        guard idx < block.count else { continue }
        let src = start + Int(qRow[j])
        guard src < keyMat.count else { continue }
        block[idx] ^= keyMat[src]
    }
}

/// l0.K(I rounds, [B block)V —— 自定义 MixColumns：位置置换 + 列混淆（e1.q/r）+ S-box 替换（e1.o）。
/// 字节码（行 1309-1378）：
///   1) idx[j] = (q[rounds][j/4]*4 + j%4)                    —— 组内位置置换
///   2) {3,7,11,15} 循环左移 2 -> {11,15,3,7}，配 r[rounds]   —— 列内偏移
///   3) block[i] = e1.o[rounds][ block[idx[i] + rOff[i]] & 255 ]
private func l0_K(_ rounds: Int, _ block: inout [UInt8]) {
    let n = block.count
    guard n == 16 else { return }

    // 步骤 1：位置置换表 idx[16]
    var idx = [Int](repeating: 0, count: 16)
    let qRow = E1C.q[rounds]
    for j in 0..<16 {
        let qv = Int(qRow[j / 4])
        idx[j] = qv * 4 + (j % 4)
    }

    // 步骤 2：列偏移。fill-array {3,7,11,15}，用 l1/d.n(0,15,2) 做 (v9,v8) 交换：
    //   n 返回 >=0 时不交换，<0 时交换 → 结果恒为 {3,7,11,15}（n(0,15,2) 返回非负）。
    // TODO(待对拍)：n(0,15,2) 的返回值决定是否交换；按"恒不交换"实现。
    let base = [3, 7, 11, 15]

    // 步骤 3：配 r[rounds] 得最终取字节位置，再过 S-box。
    let rRow = E1C.r[rounds]
    let oRow = E1C.o[rounds]
    var tmp = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 {
        let rv = Int(rRow[i])
        let pos = idx[i] + rv
        let src = pos < n ? block[pos] : 0
        tmp[i] = UInt8(truncatingIfNeeded: oRow[Int(src)])
    }
    block = tmp
}

// MARK: - F0.l0.H 主体

/// H 的移植主体。返回 base64 字符串（= e1.n）。
/// - Parameters:
///   - protobuf: v26，medusa 序列化输出
///   - seed: v27，随机 long
///   - tsLong: v29，时间戳 long
///   - stateLong: v31，另一个 long
///   - medusaDigest: v33，20 字节摘要
///   - urlBytes: v34，URL/参数字节
public func xGorgonH(protobuf: [UInt8], seed: UInt64, tsLong: UInt64,
                     stateLong: UInt64, medusaDigest: [UInt8], urlBytes: [UInt8]) -> String {
    // ================= 阶段 A：造初始 key material（行 522-536）=================
    let v7 = le32(UInt32(truncatingIfNeeded: tsLong))          // e1.E((int)v29)，4B 小端
    let v8 = le64(stateLong)                                    // e1.F(v31)，8B 小端
    var v1 = n1(medusaDigest, v7)                               // N1(v33, v7) = 摘要+ts 拼接
    v1 = n1(v1, medusaDigest)                                   // N1(v1, v33) = 再拼回摘要
    v1 = varlenHash(v1)                                         // e1.b0 -> 32B（见 TODO）

    let len = protobuf.count
    guard len >= 2 else {
        // 行 1104-1107：protobuf 过短，抛 IllegalArgumentException（此处返回空）
        return ""
    }

    // ================= 阶段 B：第一轮 4 字节搅动（行 537-575）=================
    var v4 = [UInt8](repeating: 0, count: len)
    for i in 0..<len {
        let ii = UInt32(truncatingIfNeeded: i)
        let off = ii * 4
        let k1 = UInt32(v1[Int(off % 32)])                      // v1[(i*4)%32] & 255
        let k2 = UInt32(v1[Int((off + 1) % 32)])                // v1[(i*4+1)%32] & 255
        let p = UInt32(protobuf[i])                             // v26[i] & 255
        var t = k0(p, 4) &+ k1                                  // k0(v26[i],4) + k1
        t = (~t) ^ k2                                           // ~t ^ k2
        t = k0(t & 0xFF, 3) &+ k2                               // k0(t&255,3) + k2
        t = (~t) ^ k1                                           // ~t ^ k1
        v4[len - 1 - i] = UInt8(truncatingIfNeeded: t)          // 倒序写入
    }

    // ================= 阶段 C：三段分组混淆（行 576-634）=================
    // 前置：v0 = len-1，若 < 2 跳阶段 D
    let last = len - 1
    if last >= 2 {
        // 1) 头尾（行 579-594）
        var a = UInt32(v4[0])
        var b = UInt32(v4[last]) ^ UInt32(v4[len - 2])
        b = ~b
        v4[0] = UInt8(truncatingIfNeeded: a &+ b)

        a = UInt32(v4[last])
        b = (UInt32(v4[last]) ^ UInt32(v4[0])) ^ 254            // xor-int/lit16 v1,254（XOR 不是 AND）
        v4[last] = UInt8(truncatingIfNeeded: a &+ b)

        // 2) 步进 1 循环（行 595-614）
        //    smali: v5 从 0 起，v16=v5+1，读 v4[v5]/v4[v16]，末尾 `move/from16 v5, v16`
        //    → 步进 1（不是 2）。
        //    x=v4[i]; y=k0(v4[i+1]&255,3)^x^(i+2)^0xFF; v4[i+2]=(byte)(v4[i+2]+y)
        //    循环条件 v5 < (len-3)。
        if last >= 3 {
            var i = 0
            while i < len - 3 {
                let x = UInt32(v4[i])
                let y0 = UInt32(v4[i + 1])
                let y = k0(y0, 3) ^ x ^ UInt32(truncatingIfNeeded: i + 2) ^ 0xFF
                v4[i + 2] = UInt8(truncatingIfNeeded: UInt32(v4[i + 2]) &+ y)
                i += 1
            }
        }

        // 3) 收尾（行 615-634）
        v4[last] = UInt8(truncatingIfNeeded: UInt32(v4[last]) ^ UInt32(v4[last - 1]))
        var sum: UInt32 = 0
        for j in 1..<len {
            sum = (sum &+ UInt32(v4[j])) & 0xFF
        }
        v4[0] = UInt8(truncatingIfNeeded: (UInt32(v4[0]) ^ UInt32(v4[last])) &+ sum)
    }

    // ================= 阶段 D：造 4 字节校验头（行 635-668）=================
    let v0d = n1(medusaDigest, v4)                              // N1(v33, v4)
    // I1(v14=2, v7, v12=4)：从 ts 字节切 [2,4)。v7 只有 4B，故实为 2 字节。
    // TODO(待对拍)：v12 在行 544 是 4，但文档记作 12；若 v12 在阶段 C/D 间被改写则为 12。
    let v15 = i1Safe(2, v7, 4)
    let hash = medusaHash(v15, seed: 0, 7, 3, 11, 5)            // l0.F
    let hv = UInt32(truncatingIfNeeded: hash)                   // long-to-int
    // ByteBuffer.allocate(hv).putInt(hv).array()：长度 = hv，内容 = hv 的大端 4 字节在前
    // TODO(待对拍)：hv 是任意 32 位值，allocate(hv) 可能 OOM/抛异常。这里只取大端 4 字节参与 XOR。
    let hvBE: [UInt8] = [UInt8(truncatingIfNeeded: hv >> 24),
                         UInt8(truncatingIfNeeded: hv >> 16),
                         UInt8(truncatingIfNeeded: hv >> 8),
                         UInt8(truncatingIfNeeded: hv)]
    var v11 = [UInt8](repeating: 0, count: v0d.count)
    for i in 0..<v0d.count {
        v11[i] = v0d[v0d.count - 1 - i] ^ hvBE[i % 4]           // 倒序 XOR
    }

    // ================= 阶段 E：派生 1 字节 key + 二次哈希（行 669-689）=================
    let eh = medusaHash(urlBytes, seed: 0, 11, 5, 7, 3)         // l0.F(v34, ...)
    let eb = UInt8(truncatingIfNeeded: eh)                      // long-to-int -> byte
    var e1 = n1([eb], v8)                                       // N1([eb], v8)
    e1 = n1(e1, v11)                                            // N1(e1, v11)
    let e2 = i1Safe(2, v7, 4)                                   // I1(2, v7, 4)，同阶段 D
    let keyMat = n1(e1, e2)                                     // N1(e1, e2)

    // ================= 阶段 F：选 AES 变体 + 31 字节位掩码（行 690-761）=================
    let kmLen = keyMat.count
    var sbox: [[UInt32]]
    if kmLen == 11 {
        sbox = [[UInt32]](repeating: [], count: 8)
    } else if kmLen >= 248 {
        sbox = (0..<31).map { [UInt32(truncatingIfNeeded: $0 * 8)] }
    } else {
        // 行 1100-1103：抛 IllegalStateException("unsupported Medusa inner length")
        return ""
    }
    // e1.s 是 8×2，b 循环固定 0..<8（行 735：v15 < v6=8，与 sbox 行内容无关）
    var rk = [UInt8](repeating: 0, count: 31)
    for r in 0..<sbox.count {
        // len==11 分支下行是空的，sbox[r][0] 不存在 → 该分支本就要抛异常，这里跳过
        guard !sbox[r].isEmpty else { continue }
        let row0 = sbox[r][0]
        for b in 0..<8 {
            let sRow = E1C.s[b]
            let base = Int(row0 + sRow[0])
            guard base < kmLen else { continue }
            let byte = keyMat[base]
            let shift = Int((sbox[r][1] + sRow[1]) & 7)
            let bit = (UInt32(byte) >> shift) & 1
            rk[r] |= UInt8(bit << UInt32(b))
        }
    }

    // ================= 阶段 G：MD5 + 48 字节 key expansion（行 762-874）=================
    // ⚠️ TODO(待对拍) 关键歧义：阶段 A 里 v7 = le32(ts) 只有 4 字节，但阶段 D/G 用
    // I1(2,v7,12) / I1(0,v7,16) / I1(16,v7,32) 切到 32 字节——说明 v7 在进入 G 前已被
    // 重绑定为一个 ≥32 字节的缓冲（很可能是 medusa 20B 摘要的扩展）。寄存器传播混淆，
    // 静态无法确定 v7 的实际内容。这里对越界切片做安全钳制（取到哪算哪），并显式标注。
    let md51 = md5(i1Safe(0, v7, 16))                           // e1.x("MD5", I1(0,v7,16))
    let md52 = md5(i1Safe(16, v7, 32))                          // e1.x("MD5", I1(16,v7,32))
    var exp = [UInt8](repeating: 0, count: 48)
    for i in 0..<md51.count {
        let pv = E1C.p[i / 4]
        let shift = UInt64((i % 4) * 8)
        let pb = UInt8(truncatingIfNeeded: pv >> shift)
        exp[i] = md51[i] ^ pb
    }
    for rnd in 4..<12 {
        var cur = [UInt8](repeating: 0, count: 4)
        for k in 0..<4 {
            cur[k] = exp[rnd * 4 - 4 + k]
        }
        // ⚠️ TODO(待对拍) 关键歧义：smali 行 788/830/845 用索引寄存器 v5 访问 e1.p / e1.o，
        // 但 v5 在整个 12 轮循环里恒为 3（行 542 `const/4 v10,3` 后未改写），而轮计数器是 v6(4..12)。
        // 这是寄存器传播混淆——轮索引被读成了常量 3。若忠实按 v5=3，每轮取同一行 o[3]/p[3]，
        // 轮常量失去轮依赖；若按 v6 则 p[o[>3]] 越界（p/o 只有 4 项）。这里取 rnd%4 折中，
        // 使每轮用到全部 4 行。正确基址需抓包对拍。
        let pIdx = rnd % 4
        let o3 = E1C.o[pIdx]
        let _ = [o3[0], o3[1], o3[2], o3[3]]                    // s4 构造后未参与后续运算（死变量）
        let mask: UInt32 = (rnd == 3) ? 255 : 249
        let psh = UInt64((rnd << 1) & 24)
        let tv = UInt32(truncatingIfNeeded: (E1C.p[pIdx] >> psh) & UInt64(mask)) & 0xFF
        cur[0] = UInt8(truncatingIfNeeded: (UInt32(cur[0]) ^ tv) & 0xFF)
        for k in 0..<4 {
            let d = (rnd - 4) * 4 + k
            // TODO(待对拍)：smali 行 860-862 `v14=(v6-4)*4` 经 mul-int/lit8 改写，基址不明。
            let eb2 = d < exp.count ? exp[d] : 0
            exp[rnd * 4 + k] = cur[k] ^ eb2
        }
    }

    // ================= 阶段 H：AES-CBC 加密主循环（行 875-1019）=================
    let iv = UInt8(1)                                           // 1 字节 IV，值为 1
    var plain = protobuf                                        // Arrays.copyOf(v0, len)
    var out: [UInt8] = []
    var off = 0
    while off + 16 <= plain.count {
        var block = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            block[i] = rk[off + i] ^ plain[i]                   // v4[off+i] ^ v0[i]
        }
        // TODO(待对拍)：标准 CBC 首块应 XOR IV；此处按字节码 iv ^ plain[i] 后被 block[i] 覆盖，
        // IV 实际未参与。保留明文注释。
        var s1 = i1(0, exp, 16); l0_G(&block, 0, s1, 0); l0_K(0, &block)
        var s2 = i1(16, exp, 16); l0_G(&block, 0, s2, 0); l0_K(0, &block)
        var s3 = i1(32, exp, 48); l0_G(&block, 0, s3, 0)
        for i in 0..<16 {
            block[i] ^= exp[i]
        }
        out.append(contentsOf: block)
        off += 16
    }
    _ = iv

    // ================= 阶段 I：尾部 S-box 扩散（行 1020-1063）=================
    var v1i = out                                               // Arrays.copyOf(out, len)
    for idx in 0..<v1i.count {
        for b in 0..<8 {
            let tRow = E1C.t[b]
            let x = tRow[0] + tRow[2]
            let shift = Int(x & 7)
            let bit = (UInt32(v1i[idx]) >> shift) & 1
            let clr: UInt8 = ~(UInt8(1) << UInt32(b))            // mask 取反：清位后写入
            v1i[idx] = (v1i[idx] & clr) | UInt8(bit << UInt32(b))
        }
    }

    // ================= 阶段 J：组装输出（行 1064-1099）=================
    let longs: [UInt64] = [0x0000000000000005, 0x00000000CA4F4B2D,
                           0x00000000430D7549, 0x000000002CAEB53F,
                           0x0000000056CC6D22]
    var buf: [UInt8] = []
    for i in 0..<5 {
        let v = longs[i] ^ seed
        buf.append(contentsOf: le32(UInt32(truncatingIfNeeded: v)))   // e1.E((int)v)
    }
    buf.append(contentsOf: i1(0, md52, 2))                      // I1(0, v30, 2)
    buf.append(0)                                               // v11 = 0（行 1085）
    let tailLen = plain.count - urlBytes.count                  // v0.length - v3
    buf.append(UInt8(truncatingIfNeeded: tailLen))              // 1 字节
    let from = urlBytes.count
    buf.append(contentsOf: i1(from, plain, plain.count))        // I1(v3, v0, v0.length-v3)
    buf.append(contentsOf: v1i)                                 // 阶段 I 结果
    return base64Encode(buf)
}
