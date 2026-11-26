// CanonicalJSON.swift
// 固定键序 JSON body 构造器（v98）。
//
// 2026-11-26 根因实锤：Swift JSONSerialization 对 Dictionary 的输出键序随机（哈希
// 种子每次进程启动不同），ATV body 与 Python 标准答案（test_landpage_v2.py /
// test_danmu_v3.py / play_sign.py）长度相同而 MD5 不同（x-ss-stub 对比）。ATV 三层
// 传输（curl-imp/NIO/URLSession）× HTTP1.1/H2 全灭 200+0B，而 PC 用同身份同参数
// 重放恒 49KB 真数据（五种 TLS 栈全通）——唯一未解释变量即 body 键序漂移，服务端
// 疑似对 body 规范化后与签名绑定校验，键序不对即静默 0B。
// 三接口（landpage/playback/danmaku）body 一律按 Python 标准答案键序手工拼接，
// 字符串值经 JSON 转义，禁止再用 JSONSerialization 序列化带键字典。

import Foundation

public enum CanonicalJSON {
    /// JSON 字符串字面量转义（引号/反斜杠/控制字符），输出不含外层引号。
    public static func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}