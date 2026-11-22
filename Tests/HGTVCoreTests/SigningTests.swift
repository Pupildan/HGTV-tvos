// SigningTests.swift
// 签名层单测。原 APK 的 core 模块有「单元测试与固定向量」，
// 移植后应把 dex 里提取到的固定输入→输出向量填进来做回归自检。
// ⚠️ 当前为占位；签名实现（XGorgon/XArgus）接入后补充真实向量。

import Testing
@testable import HGTVCore

@Suite("签名层")
struct SigningTests {

    @Test("哈希种子常量正确")
    func seedConstant() {
        // dex: LF0/C3.a 种子 539167016
        #expect(HGTVConfig.Signing.gorgonSeed == 539167016)
    }

    @Test("aid 与 X-SS-DP 一致")
    func aidConstant() {
        #expect(HGTVConfig.aid == 8662)
        #expect(HGTVConfig.ssDP == "8662")
    }

    @Test("passport-sdk-version 头常量")
    func passportSDK() {
        #expect(HGTVConfig.Signing.passportSDKVersion == "5051452")
    }

    // TODO: 补充固定向量测试
    // 给定已知 device_id / device_token / url / ts，
    // 断言 X-Gorgon / X-Argus / X-Ladon / X-Khronos 输出与原 APK 一致。
    // 向量来源：dex 中 core 模块单测（tools/ 目录约定），或对原 APK 抓包采集。

    @Test("x-helios 手机向量逐字节一致（2026-11-22 hdr_capture 112/112 对拍）")
    func heliosPhoneVector() {
        // 真机捕获：ts=1795108068, rand=4156622897（从输出前 4 字节 le32 恢复）
        let signer = HCSignerV5()
        let out = signer.helios(1795108068, random: Int32(bitPattern: UInt32(4156622897)))
        #expect(out == "MQjB95a6lp+CSsFpFEOvC/1JQGAQJt0IEK+ASN8oy7NsYXsT")
    }
}