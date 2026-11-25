// CurlTransportTests.swift
// curl-impersonate 传输层冒烟测试（无网络；运行时行为需 tvOS 真机验收）。
// 注意：curl 绑定只在 Xcode 构建（canImport(CurlShim)，CI 静态库就位）可用；
// SwiftPM/macOS 路径无 Vendor 静态库，curl 断言跳过，仅验证域名路由判定。

import Testing
@testable import HGTVCore

@Suite("curl-impersonate 传输层")
struct CurlTransportTests {

    @Test("字节系域名判定（SPM/macOS 与 Xcode 均可跑）")
    func byteDanceRouting() {
        #if canImport(AsyncHTTPClient)
        #expect(NIOHTTPTransport.shouldUseNIO(host: "api5-normal-sinfonlineb.fqnovel.com"))
        #expect(NIOHTTPTransport.shouldUseNIO(host: "api5-normal-lf.fqnovel.com"))
        #expect(NIOHTTPTransport.shouldUseNIO(host: "log.snssdk.com"))
        #expect(NIOHTTPTransport.shouldUseNIO(host: "tnc3-example.zijieapi.com"))
        #expect(NIOHTTPTransport.shouldUseNIO(host: "p3-novel.byteimg.com"))
        #expect(!NIOHTTPTransport.shouldUseNIO(host: "hongguoduanju.com"))
        #expect(!NIOHTTPTransport.shouldUseNIO(host: "luckysf.net"))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test("curl 通道路由与 NIO 清单一致")
    func curlRoutingMatchesNIO() {
        #if canImport(CurlShim) && canImport(AsyncHTTPClient)
        for host in ["api5-normal-sinfonlineb.fqnovel.com", "reading.snssdk.com",
                     "hongguoduanju.com", "example.com"] {
            #expect(CurlImpersonateTransport.shouldUseCurl(host: host)
                    == NIOHTTPTransport.shouldUseNIO(host: host), "host: \(host)")
        }
        #else
        #expect(Bool(true))
        #endif
    }

    #if canImport(CurlShim)
    @Test("curl 绑定冒烟：easy handle + chrome131_android 预设应用（无网络）")
    func curlSmokeInit() {
        #expect(CurlImpersonateTransport.shouldUseCurl(host: "api5-normal-sinfonlineb.fqnovel.com"))
        // 库加载 + curl_easy_init + impersonate 预设（TLS/H2 指纹参数）全部成功才通过；
        // 真实请求留待真机验收（CI runner 无中国出口，且 tvOS slice 不能在 macOS 直接跑）。
        #expect(CurlImpersonateTransport.smokeInit())
    }
    #endif
}