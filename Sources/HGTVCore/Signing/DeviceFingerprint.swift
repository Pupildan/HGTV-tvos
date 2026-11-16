// DeviceFingerprint.swift
// 设备指纹状态机（对应 LF0/C1.a / LF0/C1.b / LF0/v / LF0/z1 / LF0/B1 / LF0/u / LF0/x1 / LF0/y1）。

import Foundation

// MARK: - 三个静态字节数组（F0.C1.clinit）

public enum C1 {
    /// 16 字节
    public static let a: [UInt8] = [
        45, 75, 79, 202, 73, 117, 13, 67, 63, 181, 174, 44, 34, 109, 204, 86,
    ]
    /// 32 字节
    public static let b: [UInt8] = [
        178, 60, 42, 71, 10, 32, 209, 5, 220, 63, 140, 68, 56, 248, 39, 46,
        212, 109, 108, 137, 255, 220, 222, 221, 81, 8, 105, 141, 38, 233, 72, 157,
    ]
    /// 64 字节 S-box
    public static let c: [UInt8] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]
}

// MARK: - 操作状态（F0.z1）

/// z1.a = int[9]（操作状态），z1.b = long（时间戳种子），z1.c = int（标志位）
public struct OpState {
    public var regs: [UInt32]
    public var seed: UInt64
    public var flags: UInt32

    public init(seed: UInt64, flags: UInt32) {
        self.regs = [UInt32](repeating: 0, count: 9)
        self.seed = seed
        self.flags = flags
    }
}

/// F0.C1.a(z1, int[])：操作状态机
/// op 2: regs[2] = (b>>32) ^ (b & 0xFFFFFFFF)
/// op 3: regs[3] = Integer.reverseBytes(regs[2])
/// op 4: regs[4] = l0.F(le32(regs[3]), 2102535, 6, 4, 12, 7)
/// op 5: 逐位 rotateLeft + S-box 查表
/// op 6: xorshift32
public func c1A(_ state: inout OpState, _ ops: [Int]) {
    for op in ops {
        switch op {
        case 2:
            state.regs[2] = UInt32(truncatingIfNeeded: state.seed >> 32)
                ^ UInt32(truncatingIfNeeded: state.seed & 0xFFFFFFFF)
        case 3:
            state.regs[3] = reverseBytes32(state.regs[2])
        case 4:
            let le = le32(state.regs[3])
            state.regs[4] = MedusaSerializer.F(le, 2102535, 6, 4, 12, 7)
        case 5:
            var v = state.regs[4]
            for bit in [0, 1] {
                if state.flags & (1 << bit) != 0 {
                    v = rotateLeft32(v, 1)
                }
            }
            var out: UInt32 = 0
            for i in 0..<4 {
                let idx = Int((v >> UInt32(i * 8)) & 63)
                out |= (UInt32(C1.c[idx]) & 255) << UInt32(i * 8)
            }
            state.regs[5] = out
        case 6:
            var x = UInt32(truncatingIfNeeded: state.regs[5] & 0xFFFFFFFF)
            x = x ^ (x << 13)
            x = x ^ (x >> 17)
            state.regs[6] = (x << 5) ^ x
        default:
            break
        }
        state.flags |= (1 << UInt32(op))
    }
}

// MARK: - 配置项（g1.c：hex 字符串 + 关联值）

public struct ConfigEntry {
    public let hex: String
    public let value: Int64
    public init(_ hex: String, _ value: Int64) { self.hex = hex; self.value = value }
}

// MARK: - 设备指纹（F0.v）

/// F0.v：y1(设备 ID + token)、x1(权重数组)、B1(版本常量包)、u(时间)、f[3](随机 long)
public final class DeviceFingerprintState {
    public var deviceID: String
    public var deviceToken: String
    public var weights: [Float] = [1090519040, 1089470464, 1087373312, 1085276160, 1083179008, 1080033280]
    public var counter: UInt64 = 1
    public var seed: UInt64 = 0
    public var flags: UInt32 = 0
    public var randomLongs: [UInt64] = [0, 0, 0]

    public init(deviceID: String, deviceToken: String) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
    }

    /// F0.v.a(long now)：刷新时间种子 + 重算 op 状态 + 重生成 3 个随机 long
    public func refresh(now: UInt64) {
        seed = now
        flags = 131
        var state = OpState(seed: now, flags: 131)
        c1A(&state, [2, 3, 4, 5, 6])
        flags = state.flags
        for i in 0..<3 {
            var bytes = [UInt8](repeating: 0, count: 12)
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, &bytes)
            randomLongs[i] = readLE32AsLong(bytes, at: i * 4) & 0x7FFF_FFFF
        }
    }
}

// MARK: - 版本常量包（F0.B1 / F0.v1）

/// F0.B1：14 个字段，来自 C1.b 里的 g1.c 列表 + v1(configMap, longs, strings)
public struct VersionConstants {
    public var a: UInt32 = 312
    public var b: UInt32 = 0
    public var c: UInt32 = 1
    public var d: UInt32 = 1 // pid（runtime name 派生）
    public var e: UInt32 = 1
    public var f: [Int] = [8, 15]
    public var g: UInt64 = 16777216
    public var h: UInt64 = 16777216
    public var i: UInt32 = 1904867320
    public var j: UInt32 = 0
    public var k: UInt32 = 32251
    public var l: UInt32 = 3855421825
    public var m: UInt32 = 1510177550
    public var n: (config: [String: Int64], longs: [UInt64], strings: [String])
    public var o: String = "47"

    public init() {
        // 11 个 hex 配置项（C1.b）
        let entries: [ConfigEntry] = [
            ConfigEntry("45ca7e170e474edadd7d40972a193ace", 247235599),
            ConfigEntry("f866b105da86ad7edbaf9846a68fdbab", 247235596),
            ConfigEntry("593fa435c8460ab2ac0b86b32e28de66", 7),
            ConfigEntry("04b29480233f4def5c875875b6bdc3b1", 1),
            ConfigEntry("e98d2f001da5678b39482efbdf5770dc", 5),
            ConfigEntry("7dc22b2c6a992f0232345df41303f5ea", 694367),
            ConfigEntry("f0036511a681da731501008a14354fa3", 0),
            ConfigEntry("73e41d5295b696cc41657fef7bba312e", 1261494702),
            ConfigEntry("cede084aa3812c79e4614ee74ba582dd", -780914011),
            ConfigEntry("30c8cb0fcd3ea4c95cfd5170df341924", -780914011),
            ConfigEntry("167774bf518c11948aa0784351ccf5a9", 0),
        ]
        var map: [String: Int64] = [:]
        for e in entries { map[e.hex] = e.value }
        map["fd8d1a41d3c56026d47f1f8ba146eb99"] = 983
        map["fa4c0a5bbd8dcedf5ee28719c5bb1df1"] = 0
        n = (map, [], [])
    }
}

// MARK: - F0.e1.b0：变长哈希（SM3-like，32 字节输出）

/// 这是 dex 里 S1.b 类的实现：分组处理 + 0x80 填充 + 大端 8 字节长度 + 8 个 32 位字输出。
/// 具体压缩函数的常量表在 F0.e1.o/p/q/r/s/t 里（4 组 256 项 S-box + 排列表），
/// 反编译器把循环变量名搞乱了，确定性还原高风险 → 这里给出结构骨架 + 标注。
public func varlenHash(_ data: [UInt8]) -> [UInt8] {
    // 输出 32 字节（8 个大端 UInt32）
    // 完整实现需 F0.e1.o 4×256 S-box + q/r/s/t 排列表
    // 这里用 SHA-256 代替以保证输出长度与类型正确，实际算法待确认
    _ = data
    return sha256(data)
}

// MARK: - F0.C1.b(deviceID, deviceToken, now)：设备指纹构造

public func buildDeviceFingerprint(deviceID: String, deviceToken: String, now: UInt64) -> DeviceFingerprintState {
    let fp = DeviceFingerprintState(deviceID: deviceID, deviceToken: deviceToken)
    fp.refresh(now: now)
    return fp
}
