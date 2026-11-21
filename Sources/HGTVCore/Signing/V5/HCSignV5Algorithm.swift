// HCSignV5Algorithm.swift
// 对应 Kotlin:crypto/MedusaCore.kt + MedusaAlgorithm.kt + MedusaAlgorithmTables.kt。
// 三族 core 哈希(Mix32/Word32/Table64)+ selector 分派 + medusaTail。
// 32 位回绕用 Int32/UInt32 位型转换;uint64 用 Int64 位型。
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// MARK: - MedusaCore.kt

struct HCDigestChecks {
    var unH: Int64 = 0
    var exception: Int32 = 0
    var loader: Int32 = 0
    var pointerGap: Int32 = 0
    var configCount: Int32 = 0
    var gapEqual16: Int32 = 0
}

/** Go medusaAP:带四个移位量的滚动混合。 */
func hcMedusaAP(_ data: [UInt8], initial: Int64, _ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) -> Int64 {
    var h = initial & Int64(0xFFFFFFFF)
    for i in 0..<data.count {
        let v = Int64(data[i])
        if i & 1 == 0 {
            h = (h ^ ((h << Int64(a)) & Int64(0xFFFFFFFF)) ^ v ^ kshr64(h, Int64(b))) & Int64(0xFFFFFFFF)
        } else {
            let t = ((h << Int64(c)) & Int64(0xFFFFFFFF)) | v
            h = kInv64(t ^ kshr64(h, Int64(d)) ^ h) & Int64(0xFFFFFFFF)
        }
    }
    return h
}

/** core 段:纯算法实现。 */
func hcMedusaCore(_ input: [UInt8], selector: Int32, timestamp: Int64) -> [UInt8] {
    hcMedusaCoreAlgorithm(input, selector: selector, timestamp: Int32(truncatingIfNeeded: timestamp))
}

/** Go medusaTail:16 字节摘要后追加 4 字节校验。 */
func hcMedusaTail(_ core: [UInt8], checks: HCDigestChecks) -> [UInt8] {
    V5CrashBreadcrumbs.mark("🔬 tail 开始 coreLen=\(core.count)")
    var out = [UInt8](repeating: 0, count: 20)
    for i in 0..<16 { out[i] = core[i] }
    let eight = checks.exception == 1 || checks.loader == 1 ||
        (UInt64(bitPattern: checks.unH) == 0xf6590850)
    let n = eight ? 8 : 12
    V5CrashBreadcrumbs.mark("🔬 tail AP 前 n=\(n)")
    let ap = hcMedusaAP(Array(core[0..<n]), initial: 0x20220420, 7, 3, 11, 5)
    V5CrashBreadcrumbs.mark("🔬 tail AP 后")
    for i in 0..<4 {
        out[16 + i] = UInt8(truncatingIfNeeded: kshr64(ap, Int64(i * 8)) & 0xFF)
    }
    out[16] = eight ? (out[16] & ~UInt8(4)) : (out[16] | 4)
    out[16] = checks.gapEqual16 == 1 ? (out[16] & ~UInt8(32)) : (out[16] | 32)
    if checks.configCount > 0 { out[19] = out[19] ^ 1 }
    return out
}

// MARK: - MedusaAlgorithmTables.kt

let hcMedusaMix32Initial: [Int32] = [
    2059030472, 1729520903, 1677982208, 873419055, 984304912, -1289919430, -1420842003, -2142554032,
]

let hcMedusaMix32Constants: [Int32] = [
    -340373585, 128638146, -818837569, -535742209, 1829502207, 1513137086, -1273309640, 873991864, -231478417, -1314552628, -859632185, 1204935505,
    -715762722, 1890078625, 1464286226, -143719800, 738688778, -636630320, -71798932, -37433600, 1753874957, -428423514, -1932119157, 440175886,
    -857165717, 1792077067, -1605228777, -596530045, 579197809, -709567066, 1936688720, 1700802668, 1635574438, -467451522, 172024131, 1414414386,
    -1998587094, 1902910176, 1279687304, 95566771, -506415002, -1163666248, -1372359469, -1019733424, 386070363, -26369176, -256585912, 1309670328,
    1923797261, 650459709, -222502666, -1269467775, 1243971549, -1942912350, -1425327226, 1029569300, 1326462516, -746892585, 1146027798, -351652911,
    1822977902, 2640807, 137919738, 1605596550,
]

let hcMedusaMix32Padding: [UInt8] = [
    250, 69, 97, 215, 194, 117, 97, 26, 127, 227, 109, 179, 87, 83, 190, 123, 95, 124, 107, 223, 74, 122, 180, 90,
    178, 20, 173, 45, 196, 77, 82, 136, 43, 86, 215, 26, 20, 127, 95, 12, 87, 8, 198, 81, 161, 163, 97, 7,
    160, 128, 102, 246, 22, 235, 165, 44, 255, 222, 118, 125, 71, 93, 216, 214,
]

let hcMedusaWord32Initial: [Int32] = [
    2044785403, -927652496, -339543859, 2081443219,
]

let hcMedusaWord32Constants: [Int32] = [
    -1481703904, 1900671446, 1206176263, -373977241, -1816582946, -971714315, 951050479, -1296323213, -498842429, -1657082725, -545572892, -659460800,
    -122932808, 1991878923, 836252654, -1790980508, 1785408328, -1944878474, 1831116816, 416944715, -1142193426, 972548694, 345984993, 580470460,
    52949769, -185266586, 1658153386, 2017566610, 1303414951, 1949343768, -216168204, 793695825, -1693188519, 1170575629, 927723756, -710560098,
    -273880298, 1901021201, 1285038907, -907614287, -798868673, -547467409, -860679612, -1378174890, 1873779870, 1652575760, 1873273501, 2118294865,
    -843899391, -1288051687, -459822941, -336812356, 390516055, -67832502, -706073973, -1259327790, 85111186, -273855191, -711201787, 705967842,
    -85298239, 515750632, -1879943235, 760821021,
]

let hcMedusaWord32Padding: [UInt8] = [
    132, 150, 119, 157, 212, 21, 11, 248, 219, 109, 188, 182, 215, 97, 233, 62, 181, 4, 43, 186, 187, 91, 93, 175,
    225, 186, 238, 227, 218, 33, 22, 6, 146, 75, 31, 14, 123, 23, 49, 17, 187, 167, 140, 254, 192, 160, 109, 108,
    133, 248, 38, 225, 41, 14, 106, 212, 243, 2, 32, 170, 197, 127, 242, 253,
]

let hcMedusaWord32Mask: [Int32] = [
    431900774, -396785996, -509922706, 1909577684,
]

let hcMedusaWord32Schedule: [Int32] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    0, 10, 5, 14, 3, 4, 15, 13, 6, 1, 12, 8, 9, 7, 11, 2,
    8, 10, 3, 1, 14, 3, 7, 2, 5, 0, 13, 9, 11, 4, 15, 12,
    8, 9, 15, 10, 2, 6, 5, 13, 13, 1, 7, 3, 11, 14, 4, 12,
]

let hcMedusaWord32Rotations: [Int32] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

let hcMedusaExtensionPermutation: [Int32] = [
    0, 14, 13, 12, 11, 10, 9, 7, 8, 6, 5, 4, 3, 2, 1, 15,
]

let hcMedusaTable64Constants: [Int64] = [
    9220148185898762375, -5732435785149596323, 2298489136484332173, 1883403838777782770, -3819209500580220486, 3690803318557581848,
    -71515097446202885, 782252806811451624, 7081731275062538215, 53211017926475378,
]

// Kotlin medusaTable64SubstitutionSeed 逐字节对齐（256 项；此前 255 项导致 hcMedusaBuildTable64 substitution[255] 越界 trap）
let hcMedusaTable64SubstitutionSeed: [UInt8] = [
    46, 92, 85, 237, 27, 218, 10, 121, 40, 105, 87, 254, 104, 58, 222, 172, 144, 249, 193, 225, 195, 139, 127, 89,
    38, 202, 19, 187, 17, 55, 57, 33, 235, 154, 255, 94, 66, 51, 190, 81, 141, 64, 30, 145, 179, 133, 183, 205,
    220, 39, 146, 131, 135, 63, 230, 74, 100, 86, 140, 161, 118, 210, 253, 192, 99, 24, 68, 26, 159, 97, 203, 110,
    103, 41, 175, 184, 84, 96, 219, 151, 232, 163, 201, 228, 0, 236, 80, 23, 189, 42, 182, 142, 59, 70, 101, 166,
    122, 150, 211, 114, 18, 188, 32, 77, 124, 250, 21, 12, 65, 155, 170, 9, 248, 240, 93, 132, 252, 14, 214, 160,
    242, 239, 78, 16, 191, 137, 109, 156, 152, 6, 194, 199, 90, 241, 177, 165, 244, 185, 162, 245, 120, 174, 61, 36,
    251, 48, 157, 216, 164, 111, 31, 73, 208, 149, 60, 153, 186, 35, 234, 83, 20, 43, 224, 13, 91, 148, 56, 75,
    28, 204, 76, 136, 44, 129, 243, 158, 112, 246, 88, 69, 176, 53, 95, 106, 138, 50, 25, 52, 221, 79, 125, 54,
    238, 171, 117, 113, 15, 37, 181, 233, 71, 247, 207, 67, 108, 198, 143, 49, 178, 47, 217, 29, 196, 168, 212, 147,
    115, 167, 130, 119, 102, 8, 107, 1, 169, 227, 213, 173, 215, 229, 98, 134, 3, 34, 180, 45, 209, 223, 62, 123,
    82, 226, 126, 72, 231, 11, 4, 200, 22, 197, 2, 206, 7, 116, 128, 5,
]

let hcMedusaTable64InitialSeed: [UInt8] = [
    35, 86, 120, 137, 87, 33, 73, 136, 118, 128, 71, 66, 19, 152, 89, 153,
]

let hcMedusaTable64KeySeed: [UInt8] = [
    141, 41, 88, 158, 56, 26, 40, 76, 133, 59, 54, 37, 135, 22, 36, 72,
]

// MARK: - MedusaAlgorithm.kt

private struct HCMix32Profile { let lanes: [Int32]; let sum2Target: Int32; let roundOffset: Int32; let rounds: Int32 }

private struct HCWord32Profile { let rotation: Int32; let permutation: [Int32] }

private struct HCTable64Profile { let rotation: Int32; let tableIndex: Int32; let permutation: [Int32] }

private let hcMedusaMix32Profiles: [Int32: HCMix32Profile] = [
    0: HCMix32Profile(lanes: [0, 1, 3, 7, 4, 5, 2, 6], sum2Target: 7, roundOffset: 15, rounds: 100),
    3: HCMix32Profile(lanes: [5, 3, 6, 4, 0, 2, 7, 1], sum2Target: 2, roundOffset: 13, rounds: 96),
    6: HCMix32Profile(lanes: [7, 6, 5, 4, 3, 1, 0, 2], sum2Target: 3, roundOffset: 62, rounds: 94),
    9: HCMix32Profile(lanes: [6, 7, 4, 0, 2, 5, 1, 3], sum2Target: 4, roundOffset: 79, rounds: 97),
    12: HCMix32Profile(lanes: [3, 5, 2, 7, 1, 0, 4, 6], sum2Target: 7, roundOffset: 66, rounds: 96),
    15: HCMix32Profile(lanes: [6, 2, 7, 4, 1, 3, 0, 5], sum2Target: 6, roundOffset: 127, rounds: 99),
]

private let hcMedusaWord32Profiles: [Int32: HCWord32Profile] = [
    2: HCWord32Profile(rotation: 27, permutation: [8, 1, 12, 11, 9, 6, 0, 4, 13, 7, 3, 2, 10, 5, 14, 15]),
    5: HCWord32Profile(rotation: 2, permutation: [9, 8, 13, 6, 10, 7, 14, 11, 0, 1, 2, 15, 12, 4, 5, 3]),
    8: HCWord32Profile(rotation: 15, permutation: [10, 11, 7, 14, 9, 12, 2, 13, 3, 6, 15, 5, 0, 8, 1, 4]),
    11: HCWord32Profile(rotation: 18, permutation: [7, 5, 11, 12, 6, 1, 15, 14, 13, 8, 4, 3, 9, 0, 10, 2]),
    14: HCWord32Profile(rotation: 17, permutation: [5, 8, 3, 6, 4, 2, 0, 12, 10, 7, 15, 9, 13, 11, 1, 14]),
]

private let hcMedusaTable64Profiles: [Int32: HCTable64Profile] = [
    1: HCTable64Profile(rotation: 17, tableIndex: 0, permutation: [1, 5, 0, 3, 7, 2, 4, 6]),
    4: HCTable64Profile(rotation: 51, tableIndex: 1, permutation: [5, 0, 7, 6, 2, 3, 1, 4]),
    7: HCTable64Profile(rotation: 54, tableIndex: 2, permutation: [1, 5, 0, 6, 2, 7, 3, 4]),
    10: HCTable64Profile(rotation: 39, tableIndex: 3, permutation: [3, 1, 7, 4, 5, 6, 2, 0]),
    13: HCTable64Profile(rotation: 37, tableIndex: 4, permutation: [2, 0, 6, 1, 5, 3, 7, 4]),
]

private func hcRotl8(_ value: Int32, _ n: Int32) -> Int32 {
    let k = ((n % 8) + 8) % 8
    let v = value & 0xFF
    return k == 0 ? v : ((v << k) | kshr32(v, 8 - k)) & 0xFF
}

private func hcu32BE(_ b: [UInt8], _ at: Int) -> Int32 {
    (Int32(b[at]) << 24) | (Int32(b[at+1]) << 16) | (Int32(b[at+2]) << 8) | Int32(b[at+3])
}
private func hcu32LE(_ b: [UInt8], _ at: Int) -> Int32 {
    Int32(b[at]) | (Int32(b[at+1]) << 8) | (Int32(b[at+2]) << 16) | (Int32(b[at+3]) << 24)
}
private func hcu64LE(_ b: [UInt8], _ at: Int) -> Int64 {
    var v: Int64 = 0
    for i in stride(from: 7, through: 0, by: -1) { v = (v << 8) | Int64(b[at+i]) }
    return v
}
private func hcu64BE(_ b: [UInt8], _ at: Int) -> Int64 {
    var v: Int64 = 0
    for i in 0..<8 { v = (v << 8) | Int64(b[at+i]) }
    return v
}
private func hcputU32BE(_ b: inout [UInt8], _ at: Int, _ v: Int32) {
    b[at] = UInt8(truncatingIfNeeded: kshr32(v, 24))
    b[at+1] = UInt8(truncatingIfNeeded: kshr32(v, 16))
    b[at+2] = UInt8(truncatingIfNeeded: kshr32(v, 8))
    b[at+3] = UInt8(truncatingIfNeeded: v)
}
private func hcputU32LE(_ b: inout [UInt8], _ at: Int, _ v: Int32) {
    b[at] = UInt8(truncatingIfNeeded: v)
    b[at+1] = UInt8(truncatingIfNeeded: kshr32(v, 8))
    b[at+2] = UInt8(truncatingIfNeeded: kshr32(v, 16))
    b[at+3] = UInt8(truncatingIfNeeded: kshr32(v, 24))
}
private func hcputU64LE(_ b: inout [UInt8], _ at: Int, _ v: Int64) {
    for i in 0..<8 { b[at+i] = UInt8(truncatingIfNeeded: kshr64(v, Int64(i * 8)) & 0xFF) }
}
private func hcputU64BE(_ b: inout [UInt8], _ at: Int, _ v: Int64) {
    for i in 0..<8 { b[at+i] = UInt8(truncatingIfNeeded: kshr64(v, Int64(i * 8)) & 0xFF) }
}

private func hcMedusaFoldHalves(_ encoded: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 { out[i] = encoded[i] ^ encoded[i+16] }
    return out
}

private func hcMedusaMix32(_ input: [UInt8], timestamp: Int32, profile: HCMix32Profile) -> [UInt8] {
    let rotation = timestamp &+ profile.roundOffset
    var block = [UInt8](repeating: 0, count: 64)
    for i in 0..<52 { block[i] = input[i] }
    for i in 0..<4 {
        block[52+i] = UInt8(truncatingIfNeeded: hcRotl8(Int32(hcMedusaMix32Padding[i]), -(rotation &+ 2)))
    }
    hcputU64BE(&block, 56, 52 * 8)
    V5CrashBreadcrumbs.mark("🔬 mix32 block 完成")
    var message = [Int32](repeating: 0, count: 128)
    for i in 0..<16 { message[i] = hcu32BE(block, i * 4) }
    for i in 16..<128 {
        let left = message[i-15]
        let right = message[i-2]
        // Kotlin Integer.rotateLeft(left, -7) = Swift rotateLeft(-7) —— Swift 要求 |by|<32 ✓
        let sigma0 = krotl32(left, -7) ^ krotl32(left, -18) ^ kshr32(left, 3)
        let sigma1 = krotl32(right, -17) ^ krotl32(right, -19) ^ kshr32(right, 10)
        message[i] = message[i-16] &+ sigma0 &+ message[i-7] &+ sigma1
    }
    V5CrashBreadcrumbs.mark("🔬 mix32 message 完成")
    var initial = [Int32](repeating: 0, count: 8)
    // Kotlin Integer.rotateLeft(v, -rotation) = 右转 rotation&31
    for i in 0..<8 { initial[i] = kror32(hcMedusaMix32Initial[i], rotation & 31) }
    var constants = [Int32](repeating: 0, count: 64)
    for i in 0..<64 { constants[i] = kror32(hcMedusaMix32Constants[i], (rotation &+ 1) & 31) }
    var state = initial
    let lanes = profile.lanes
    for round in profile.roundOffset..<(profile.roundOffset &+ profile.rounds) {
        let a = state[Int(lanes[0])]; let b = state[Int(lanes[1])]
        let c = state[Int(lanes[2])]; let d = state[Int(lanes[3])]
        let e = state[Int(lanes[4])]; let f = state[Int(lanes[5])]
        let g = state[Int(lanes[6])]; let h = state[Int(lanes[7])]
        let choose = g ^ (e & (f ^ g))
        let majority = ((a | b) & c) | (a & b)
        let sigma0 = krotl32(a, -2) ^ krotl32(a, -13) ^ krotl32(a, -22)
        let sigma1 = krotl32(e, -6) ^ krotl32(e, -11) ^ krotl32(e, -25)
        let sum1 = h &+ sigma1 &+ choose &+ constants[Int(round & 63)] &+ message[Int(round & 127)]
        let sum2 = sigma0 &+ majority
        var following = [state[7], state[0], state[1], state[2], state[3], state[4], state[5], state[6]]
        following[Int((lanes[3] &+ 1) & 7)] = d &+ sum1
        following[Int(profile.sum2Target)] = sum1 &+ sum2
        state = following
    }
    V5CrashBreadcrumbs.mark("🔬 mix32 state 完成")
    var encoded = [UInt8](repeating: 0, count: 32)
    for i in 0..<8 { hcputU32BE(&encoded, i * 4, state[i] &+ initial[i]) }
    V5CrashBreadcrumbs.mark("🔬 mix32 fold 前")
    return hcMedusaFoldHalves(encoded)
}

private func hcMedusaCompressWord32(_ state: [Int32], _ block: [UInt8], _ constants: [Int32], _ permutation: [Int32]) -> [Int32] {
    var message = [Int32](repeating: 0, count: 16)
    for i in 0..<16 { message[i] = hcu32LE(block, Int(permutation[i]) * 4) }
    var a = state[0]; var b = state[1]; var c = state[2]; var d = state[3]
    for round in 0..<64 {
        let mix: Int32
        if round < 16 { mix = d ^ (b & (c ^ d)) }
        else if round < 32 { mix = c ^ (d & (b ^ c)) }
        else if round < 48 { mix = b ^ c ^ d }
        else { mix = c ^ (b | ~d) }
        let value = a &+ mix &+ message[Int(hcMedusaWord32Schedule[round])] &+ constants[round]
        let nextB = b &+ krotl32(value, hcMedusaWord32Rotations[round])
        let oldB = b; let oldC = c
        a = d; b = nextB; c = oldB; d = oldC
    }
    return [state[0] &+ a, state[1] &+ b, state[2] &+ c, state[3] &+ d]
}

private func hcMedusaWord32(_ input: [UInt8], timestamp: Int32, profile: HCWord32Profile) -> [UInt8] {
    let rotation = timestamp &+ profile.rotation
    var initial = [Int32](repeating: 0, count: 4)
    for i in 0..<4 { initial[i] = kror32(hcMedusaWord32Initial[i], rotation & 31) }
    var constants = [Int32](repeating: 0, count: 64)
    for i in 0..<64 { constants[i] = kror32(hcMedusaWord32Constants[i], (rotation &+ 1 &+ Int32(i / 16)) & 31) }
    var block = [UInt8](repeating: 0, count: 64)
    for i in 0..<52 { block[i] = input[i] }
    for i in 0..<8 {
        block[52+i] = UInt8(truncatingIfNeeded: hcRotl8(Int32(hcMedusaWord32Padding[i]), -(rotation &+ 5)))
    }
    hcputU32LE(&block, 60, 52 * 8)
    let state = hcMedusaCompressWord32(initial, block, constants, profile.permutation)
    var out = [UInt8](repeating: 0, count: 16)
    for i in 0..<4 {
        let mask = kror32(hcMedusaWord32Mask[i], (rotation &+ 6) & 31)
        hcputU32LE(&out, i * 4, state[i] ^ mask)
    }
    return out
}

private func hcMedusaBuildTable64(_ profile: HCTable64Profile) -> [[Int64]] {
    var inverse = [Int32](repeating: 0, count: 8)
    for i in 0..<8 { inverse[Int(profile.permutation[i])] = Int32(i) }
    var substitution = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 {
        substitution[i] = UInt8(truncatingIfNeeded: hcRotl8(Int32(hcMedusaTable64SubstitutionSeed[i]), -profile.rotation))
    }
    var key = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 {
        key[i] = UInt8(truncatingIfNeeded: hcRotl8(Int32(hcMedusaTable64KeySeed[i]), -profile.rotation))
    }
    var table = [UInt8](repeating: 0, count: 2048)
    for i in 0..<16 {
        let seed = Int(hcMedusaTable64InitialSeed[i]) ^ Int(hcMedusaTable64KeySeed[i])
        table[i] = UInt8(truncatingIfNeeded: hcRotl8(Int32(seed & 0xFF), -profile.rotation))
    }
    for index in 2..<256 {
        let previous = (index - 1) * 8
        var mixed = [UInt8](repeating: 0, count: 8)
        for it in 0..<8 { mixed[it] = table[previous + Int(profile.permutation[it])] }
        if index % 4 == 0 {
            let old = mixed
            for lane in 0..<8 {
                mixed[lane] = substitution[Int(old[Int((lane + 3) & 7)])]
            }
            mixed[0] = mixed[0] ^ substitution[256 - index]
            mixed[4] = mixed[4] ^ substitution[index]
        }
        let offset = (index - 2) * 8 + Int(substitution[index - 1])
        let salted = Int(substitution[(index + Int(key[index & 15])) & 255])
        let position = (offset ^ salted) % 2040
        for lane in 0..<8 {
            table[index * 8 + lane] = table[position + lane] ^ mixed[lane]
        }
    }
    var tables = [[Int64]](repeating: [Int64](repeating: 0, count: 256), count: 8)
    for i in 0..<256 { tables[0][i] = hcu64LE(table, i * 8) }
    for lane in 1..<8 {
        for block in stride(from: 0, to: 256, by: 8) {
            for index in 0..<8 {
                tables[lane][block + index] =
                    kror64(tables[lane-1][block + Int(inverse[index])], Int64(profile.rotation))
            }
        }
    }
    return tables
}

private let hcMedusaTable64Boxes: [[[Int64]]] = {
    var boxes = [[[Int64]]](repeating: [[Int64]](repeating: [Int64](repeating: 0, count: 256), count: 8), count: 5)
    for (_, profile) in hcMedusaTable64Profiles {
        boxes[Int(profile.tableIndex)] = hcMedusaBuildTable64(profile)
    }
    return boxes
}()

private func hcMedusaTable64Round(_ words: [Int64], _ tables: [[Int64]]) -> [Int64] {
    var out = [Int64](repeating: 0, count: 8)
    for column in 0..<8 {
        for lane in 0..<8 {
            let index = Int((words[Int((column - lane) & 7)] >> UInt64(56 - lane * 8)) & 0xFF)
            out[column] ^= tables[lane][index]
        }
    }
    return out
}

private func hcMedusaTable64(_ input: [UInt8], timestamp: Int32, profile: HCTable64Profile) -> [UInt8] {
    let rotation = timestamp &+ profile.rotation
    // Kotlin Long.rotateLeft(v & 0xFFFFFFFF, -rotation) = 右转 rotation&63
    let u = (UInt64(bitPattern: Int64(timestamp)) & 0xFFFFFFFF)
    let k = UInt64(bitPattern: Int64(rotation)) & 63
    let initial: UInt64 = (u >> k) | (u << ((64 - k) & 63))
    var state = [Int64](repeating: Int64(bitPattern: initial), count: 8)
    var constants = [Int64](repeating: 0, count: 10)
    for i in 0..<10 {
        constants[i] = kror64(hcMedusaTable64Constants[i], Int64((rotation &+ 1) & 63))
    }
    var message = [UInt8](repeating: 0, count: 128)
    for i in 0..<52 { message[i] = input[i] }
    message[52] = 0x80
    hcputU64BE(&message, 120, 52 * 8)
    let tables = hcMedusaTable64Boxes[Int(profile.tableIndex)]
    var offset = 0
    while offset < message.count {
        var words = [Int64](repeating: 0, count: 8)
        for it in 0..<8 { words[it] = hcu64BE(message, offset + it * 8) }
        var key = [state[4], state[5], state[6], state[7], state[0], state[1], state[2], state[3]]
        var cipher = [Int64](repeating: 0, count: 8)
        for lane in 0..<8 { cipher[lane] = words[Int(profile.permutation[lane])] ^ key[lane] }
        for constant in constants {
            key = hcMedusaTable64Round(key, tables)
            key[0] ^= constant
            let mixed = hcMedusaTable64Round(cipher, tables)
            for lane in 0..<8 { cipher[lane] = mixed[lane] ^ key[lane] }
        }
        for lane in 0..<8 {
            state[lane] = state[lane] ^ cipher[lane] ^ words[Int((lane + 1) & 7)]
        }
        offset += 64
    }
    var encoded = [UInt8](repeating: 0, count: 32)
    let lanes = [1, 3, 5, 6]
    for index in 0..<8 {
        for lane in 0..<4 {
            encoded[index * 4 + lane] = UInt8(truncatingIfNeeded: kshr64(state[7 - index], Int64(lanes[lane] * 8)) & 0xFF)
        }
    }
    return hcMedusaFoldHalves(encoded)
}

/** selector 分派:三族轮换。 */
func hcMedusaCoreAlgorithm(_ input: [UInt8], selector: Int32, timestamp: Int32) -> [UInt8] {
    if let p = hcMedusaMix32Profiles[selector] { return hcMedusaMix32(input, timestamp: timestamp, profile: p) }
    if let p = hcMedusaWord32Profiles[selector] { return hcMedusaWord32(input, timestamp: timestamp, profile: p) }
    if let p = hcMedusaTable64Profiles[selector] { return hcMedusaTable64(input, timestamp: timestamp, profile: p) }
    DiagnosticsLogger.error("V5 medusa: selector \(selector) out of range 0-15", category: "sign")
    return input
}

/** extension 段:MD5 变体 + 自定义置换(当前生产路径未启用)。 */
func hcMedusaExtensionAlgorithm(_ data: [UInt8]) -> [UInt8] {
    var paddingLength = 60 - data.count % 64
    if paddingLength <= 0 { paddingLength += 64 }
    var message = [UInt8](repeating: 0, count: data.count + paddingLength + 4)
    for i in 0..<data.count { message[i] = data[i] }
    let copy = min(paddingLength, hcMedusaWord32Padding.count)
    for i in 0..<copy { message[data.count + i] = hcMedusaWord32Padding[i] }
    hcputU32LE(&message, message.count - 4, Int32(truncatingIfNeeded: data.count * 8))
    var state = hcMedusaWord32Initial
    var offset = 0
    while offset < message.count {
        let block = Array(message[offset..<offset+64])
        state = hcMedusaCompressWord32(state, block, hcMedusaWord32Constants, hcMedusaExtensionPermutation)
        offset += 64
    }
    var out = [UInt8](repeating: 0, count: 16)
    for i in 0..<4 { hcputU32LE(&out, i * 4, state[i] ^ hcMedusaWord32Mask[i]) }
    return out
}
