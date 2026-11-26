// NIOHTTPTransport.swift
// 字节系域名专用传输层：AsyncHTTPClient（内置 BoringSSL TLS 栈）。
//
// 背景（2026-11-24 归一实验实锤）：字节 CDN 按 TLS 指纹（JA3）黑名单 Apple 原生
// Network.framework——tvOS URLSession 发 landpage 恒 200+0B；而 urllib(OpenSSL)/
// curl_cffi（含 BoringSSL 默认模板）在中国出口 NAS 上全部 200+49KB 真数据。
// 结论：任何 BoringSSL/OpenSSL 指纹可过 → 字节系域名一律走 NIO-BoringSSL 通道。
//
// 本文件整体包在 canImport(AsyncHTTPClient) 内：CI 的 sign_cli 用 swiftc 直接编译
// 全部 HGTVCore 源文件（无 SPM 依赖图，canImport=false），此时本文件为空、
// HTTPClient 走 URLSession 原路径；Xcode（project.yml package 依赖）与 SwiftPM
// （Package.swift）构建下模块可见，NIO 通道启用。

import Foundation

#if canImport(AsyncHTTPClient)
import AsyncHTTPClient
import NIOCore

enum NIOHTTPTransport {

    // MARK: - 域名路由

    /// 字节系域名后缀清单（对照 HGTVConfig.Host 实际清单 + 2026-11-24 点名清单）。
    /// 自建搜索中转（hongguoduanju.com）/镜像（luckysf.net）不在清单 → 仍走 URLSession。
    private static let byteDanceSuffixes: [String] = [
        "fqnovel.com",       // 番茄内容接口 api5-normal-*.fqnovel.com、log5-applog-*
        "snssdk.com",        // reading/novel/passport.snssdk.com、log.snssdk.com
        "zijieapi.com",      // TNC 播放调度 tnc3-*.zijieapi.com
        "byteimg.com",       // 图片 CDN p3-novel.byteimg.com
        "ibyteimg.com",
        "bytecdn.cn",
        "zjcdn.com",
        "douyinpic.com",
        "douyinvod.com",
        "toutiao.com",
        "toutiaostatic.com",
    ]

    /// 字节系域名 → NIO-BoringSSL 通道；其余域名维持 URLSession 原路径。
    static func shouldUseNIO(host: String) -> Bool {
        let h = host.lowercased()
        return byteDanceSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: - 客户端单例

    /// 全局共享 AsyncHTTPClient。TLS 栈 = BoringSSL（swift-nio-ssl 内置），与
    /// urllib/curl_cffi 的成功指纹同族；EventLoopGroup 单例全程复用。
    private static let client: AsyncHTTPClient.HTTPClient = {
        var config = AsyncHTTPClient.HTTPClient.Configuration()
        config.timeout = .init(connect: .seconds(10), read: .seconds(30))
        config.redirectConfiguration = .follow(max: 5, allowCycles: false)
        // 强制 HTTP/1.1（2026-11-26 排查：ATV 三层传输全 0B，PC H1.1 组合全通——
        // 规避 ATV 端 H2 帧指纹嫌疑，与 curl 通道 ③b 对齐）
        config.httpVersion = .http1Only
        // 响应 gzip/deflate 自动解压（landpage/multi_video_model 响应恒 gzip；
        // 上层解析假设明文，与 URLSession 自动解压行为对齐）
        config.decompression = .enabled(limit: .ratio(50))
        return AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .singleton,
                                          configuration: config)
    }()

    // MARK: - 发送

    /// 发送签名后的完整请求（url/headers/body 均为 SignInterceptor 产出）。
    /// - headers: 大小写原样拷贝（HTTPHeaders 保留原始 name，签名头不失真）
    /// - body: gzip 后字节（与 x-ss-stub/gorgon 绑定），原样发出
    /// - Returns: (状态码, 已自动解压的响应体)
    static func execute(url: String, method: String, headers: [String: String],
                        body: Data?) async throws -> (status: Int, data: Data) {
        var req = HTTPClientRequest(url: url)
        req.method = method.uppercased() == "GET" ? .GET : .POST
        for (k, v) in headers { req.headers.add(name: k, value: v) }
        if let body, !body.isEmpty {
            req.body = .bytes(ByteBuffer(bytes: [UInt8](body)))
        }
        let resp = try await client.execute(req, timeout: .seconds(30))
        var buf = try await resp.body.collect(upTo: 64 * 1024 * 1024)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        return (status: Int(resp.status.code), data: Data(bytes))
    }
}

#endif