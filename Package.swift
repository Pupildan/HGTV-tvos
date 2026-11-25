// swift-tools-version: 6.2
// HGTV for tvOS 26 — 第三方番茄短剧客户端移植
// 严格复用原 APK 数据获取链路；界面遵循 tvOS 规范 + 液态玻璃；播放用 AVPlayer。
// 注意：tvOS 26 / 液态玻璃需 Xcode 26（Swift 6.2 工具链），故 tools-version 取 6.2。
import PackageDescription

let package = Package(
    name: "HGTV",
    platforms: [
        // macOS 13 声明：impersonate-test 的 swift build 在 macOS runner 上编译
        // HGTVCore（OSAllocatedUnfairLock=13.0 / data(for:)=12.0 / Logger=11.0），
        // 无声明时下限 10.13 → 可用性检查全炸（run#5 教训）。tvOS 26 供主构建。
        .macOS(.v13),
        .tvOS(.v26)
    ],
    products: [
        // 纯 library：界面层 HGTV（含 @main 入口）+ 数据层 HGTVCore。
        // 不声明 executable product，避免与 Xcode app target 的 HGTV.app 产物冲突。
        .library(name: "HGTV", targets: ["HGTVApp"]),
        .library(name: "HGTVCore", targets: ["HGTVCore"])
    ],
    dependencies: [
        // AsyncHTTPClient：字节系域名专用传输层（TLS 栈 = 内置 BoringSSL）。
        // 背景：字节 CDN 按 TLS 指纹（JA3）黑名单 Apple 原生 Network.framework
        // （landpage 恒 200+0B），BoringSSL/OpenSSL 指纹实测可过（2026-11-24 归一实验）。
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.22.0"),
        // NIOCore：ByteBuffer 字节读写（AsyncHTTPClient 请求体/响应体）
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.63.0")
    ],
    targets: [
        // 数据获取层：签名 + 设备注册 + 网络 + 接口 + 模型（纯 Swift，无 UI 依赖）
        .target(
            name: "HGTVCore",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio")
            ],
            path: "Sources/HGTVCore",
            swiftSettings: [
                // v5 语义：与 xcodegen 直编路径（-strict-concurrency=minimal）对齐。
                // v6 严格并发会把 SignInterceptor.useV5 等 static var 判为错误。
                // 主构建走 xcodegen，不读本设置；本设置只影响 SPM 路径（SignCLI）。
                .swiftLanguageMode(.v5)
            ]
        ),
        // sign_cli（CI TLS 指纹验证 CLI）：--transport nio 模式用 AsyncHTTPClient
        // 直发签名后的 landpage（macOS runner 的 TLS 栈同为 BoringSSL，验证指纹过墙）。
        // 现有 impersonate job 的 swiftc 直编路径不受影响（sign_cli 内 canImport 保护）。
        .executableTarget(
            name: "SignCLI",
            dependencies: [
                "HGTVCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio")
            ],
            path: "Scripts",
            exclude: [
                "build_ipa.sh",
                "log_server.py",
                "send_impersonate.py",
                "stamp_version.sh",
                "signing_verify"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 界面层：tvOS 26 SwiftUI + 液态玻璃 + AVPlayer（@main 入口在此，作为 library 被 app target 链接）
        .target(
            name: "HGTVApp",
            dependencies: ["HGTVCore"],
            path: "Sources/HGTVApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // 数据获取层单测（签名向量自检）
        .testTarget(
            name: "HGTVCoreTests",
            dependencies: ["HGTVCore"],
            path: "Tests/HGTVCoreTests"
        )
    ]
)