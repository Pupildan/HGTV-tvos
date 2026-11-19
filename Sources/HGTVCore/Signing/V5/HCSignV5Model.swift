// HCSignV5Model.swift
// 对应 Kotlin:crypto/MedusaModel.kt。身份/设备/SDK/线程模型 + 三段消息构造。
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct HCMedusaIdentity {
    let aid: String
    let deviceID: String
    let licenseID: String
    let appVersion: String
    let sdkVersion: String
    let channel: String
    let token: String
    let sdkPlatform: String
}

struct HCMedusaDevice {
    var collectionState: Int32 = 0
    var cache256: String = ""
    var timezone: String = ""
    var locale: String = ""
    var cpuCoreCount: Int32 = 0
    var storageRAMGiB: [Float] = [Float](repeating: 0, count: 6)
    var androidRelease: String = ""
    var brightness: Int32 = 0
    var systemVolume: Int32 = 0
    var usbConnected: Int32 = 0
    var model: String = ""
    var brand: String = ""
    var board: String = ""
    var product: String = ""
    var device: String = ""
    var manufacturer: String = ""
    var hardware: String = ""
    var featureBits: Int64 = 0
}

struct HCMedusaConfigMaps {
    var integers: [String: Int32] = [:]
    var longs: [String: Int64] = [:]
    var strings: [String: String] = [:]
    func integer(_ key: String) -> Int32 { integers[key] ?? 694367 }
    func long(_ key: String) -> Int64 { longs[key] ?? 0 }
    func text(_ key: String) -> String { strings[key] ?? "" }
}

struct HCMedusaSdk {
    var configMask: Int64 = 0
    var root22: Int32 = 0
    var devicePresent: Bool = true
    var processID: Int32 = 0
    var parentProcessID: Int32 = 0
    var detectionTypes: [Int32] = []
    var cmr: Int64 = 0
    var cmr2: Int64 = 0
    var unH: Int64 = 0
    var vpn: Int32 = 0
    var sts: Int32 = 0
    var fkd: Int64 = 0
    var pd: Int32 = 0
    var maps: HCMedusaConfigMaps = HCMedusaConfigMaps()
    var requestChecks: HCDigestChecks = HCDigestChecks()
}

struct HCMedusaProcessState {
    var fl: [Int32] = [Int32](repeating: 0, count: 9)
    var record0: Int64 = 0
    var record8: Int64 = 0
    // 线程/指针上下文（generate() 从 process 读取；默认态由 defaultAutonomousState 填充）
    var firstTPIDR: Int64 = 0
    var callbackAddress: Int64 = 0
    var pointerGap: Int64 = 0
    var tokenPointerTLS: Int64 = 0
    var tokenPointerLP: Int64 = 0
}

struct HCMedusaThread {
    var tls: Int64 = 0
    let firstTPIDR: Int64
    let callbackAddress: Int64
    let pointerGap: Int64
    let tokenPointerTLS: Int64
    let tokenPointerLP: Int64
    var process: HCMedusaProcessState
}

struct HCMedusaOptions {
    var timestamp: Int64 = 0
    var timeMS: Int64 = 0
    var body: [UInt8]? = nil
    var bodyMD5: [UInt8]? = nil
    var random: [Int64]? = nil
}

/** Go medusaTokenValid:宽松 base64 校验。 */
func hcMedusaTokenValid(_ token: String) -> Bool {
    if token.isEmpty { return true }
    let s = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var table = [Int](repeating: -1, count: 256)
    for ch in alphabet.utf8 { table[Int(ch)] = 1 }
    table[Int(UInt8(ascii: "="))] = 64
    var pads = 0
    var count = 0
    var out = 0
    var quad = 0
    var nbytes = 3
    for ch in s {
        if ch == " " || ch == "\n" || ch == "\r" { continue }
        if ch == "=" {
            pads += 1
            if pads > 2 { return false }
        } else if ch.asciiValue == nil || table[Int(ch.asciiValue!)] < 0 || pads > 0 {
            return false
        }
        count += 1
        quad += 1
        if ch == "=" { nbytes -= 1 }
        if quad == 4 {
            if nbytes > 0 { out += nbytes }
            quad = 0
        }
    }
    return count > 0 && out > 0
}

/** Go (DeviceState) message:设备档案 protobuf 字段。 */
func hcMedusaDeviceMessage(_ d: HCMedusaDevice, _ i: HCMedusaIdentity, nowMS: Int64, record0: Int64) -> [Int32: Any] {
    var v = [Int32: Any]()
    v[1] = Int64(1)
    v[2] = Int64(d.collectionState)
    v[3] = i.aid
    v[4] = i.deviceID
    v[5] = i.token
    v[6] = d.cache256
    v[12] = d.timezone
    v[13] = d.locale
    v[14] = Int64(d.cpuCoreCount)
    v[22] = d.androidRelease
    v[23] = Int64(d.brightness)
    v[24] = Int64(d.systemVolume)
    v[25] = record0 - 400
    v[26] = record0 - 41
    v[27] = record0 - 1000
    v[28] = nowMS
    v[29] = Int64(d.usbConnected)
    v[30] = d.model
    v[31] = d.brand
    v[32] = d.board
    v[33] = d.product
    v[34] = d.device
    v[35] = d.manufacturer
    v[36] = d.hardware
    v[38] = d.featureBits
    v[40] = record0 - 321
    for n in 0..<6 { v[Int32(16 + n)] = d.storageRAMGiB[n] }
    return v
}

/** Go medusaContext:medusa field 23。 */
func hcMedusaContext(_ i: HCMedusaIdentity, _ d: HCMedusaDevice, _ s: HCMedusaSdk, _ t: HCMedusaThread, _ o: HCMedusaOptions) -> [Int32: Any] {
    let m = s.maps
    let saved = m.long("fd8d1a41d3c56026d47f1f8ba146eb99")
    // p17 = ((saved and 15L.inv()) or ((saved and 240L) ushr 4)) xor ((configMask ushr 28) and 15)
    let p17 = ((saved & ~Int64(15)) | (kshr64(saved & 240, 4))) ^ (kshr64(s.configMask, 28) & 15)
    var v = [Int32: Any]()
    v[2] = Int64(m.integer("45ca7e170e474edadd7d40972a193ace"))
    v[3] = Int64(m.integer("f866b105da86ad7edbaf9846a68fdbab"))
    v[5] = Int64(m.integer("593fa435c8460ab2ac0b86b32e28de66"))
    v[6] = i.sdkVersion
    v[7] = Int64(s.processID)
    v[8] = i.channel
    v[14] = i.appVersion
    v[15] = Int64(s.parentProcessID)
    v[17] = p17
    v[18] = t.firstTPIDR ^ t.callbackAddress ^ (o.timestamp & 0xFFFFFFFF)
    v[19] = Int32(truncatingIfNeeded: (t.pointerGap ^ (o.timestamp & 0xFFFFFFFF)) & 0xFFFFFFFF)
    v[20] = t.callbackAddress ^ (o.timestamp & 0xFFFFFFFF)
    v[22] = Int64(m.integer("cede084aa3812c79e4614ee74ba582dd"))
    v[23] = Int64(m.integer("30c8cb0fcd3ea4c95cfd5170df341924"))
    if s.devicePresent {
        v[12] = hcMedusaDeviceMessage(d, i, nowMS: o.timeMS, record0: t.process.record0)
    }
    v[13] = [
        Int32(1): Int64(t.process.record0 / 1000),
        Int32(2): Int64(3),
        Int32(4): Int64(200),
    ] as [Int32: Any]
    return v
}

/** Go medusaEnvironment:medusa field 24 的 JSON。 */
func hcMedusaEnvironment(_ i: HCMedusaIdentity, _ s: HCMedusaSdk, _ t: HCMedusaThread) -> String {
    let kd = mVal(s, "167774bf518c11948aa0784351ccf5a9")
    let mask: Int64 = 0x7943f10b58
    let lp = "2|\(t.process.record8 ^ mask)|\(t.tls ^ mask)|" +
        "\(t.process.record0 ^ mask)|\(t.tokenPointerLP)"
    var parts = [String](repeating: "", count: 10)
    for n in 0..<t.process.fl.count {
        // Kotlin (fl[n].toLong() and 0xFFFFFFFFL).toString() —— 无符号 32 位十进制
        parts[n] = UInt32(bitPattern: t.process.fl[n]).description
    }
    parts[9] = UInt32(bitPattern: t.tls).description
    let fl = parts.joined(separator: "|")
    let dyn = mStr(s, "fa4c0a5bbd8dcedf5ee28719c5bb1df1")
    let tk = hcMedusaTokenValid(i.token)
    return "{\"cmr\":\(s.cmr)" +
        ",\"cmr2\":\(s.cmr2)" +
        ",\"un_h\":\(s.unH)" +
        ",\"vpn\":\(s.vpn)" +
        ",\"sts\":\(s.sts)" +
        ",\"kd\":\(kd)" +
        ",\"fkd\":\(s.fkd)" +
        ",\"pd\":\(s.pd)" +
        ",\"lp\":\"\(lp)\"" +
        ",\"fl\":\"\(fl)\"" +
        ",\"dyn\":\"\(dyn)\"" +
        ",\"do\":0" +
        ",\"tk\":\(tk)" +
        "}"
}

// helpers 避免直接依赖 maps 键入错
private func mVal(_ s: HCMedusaSdk, _ key: String) -> Int32 { s.maps.integer(key) }
private func mStr(_ s: HCMedusaSdk, _ key: String) -> String { s.maps.text(key) }
