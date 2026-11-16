// swift-tools-version: 6.2
// HGTV for tvOS 26 — 第三方番茄短剧客户端移植
// 严格复用原 APK 数据获取链路；界面遵循 tvOS 规范 + 液态玻璃；播放用 AVPlayer。
// 注意：tvOS 26 / 液态玻璃需 Xcode 26（Swift 6.2 工具链），故 tools-version 取 6.2。
import PackageDescription

let package = Package(
    name: "HGTV",
    platforms: [
        .tvOS(.v26)
    ],
    products: [
        .executable(name: "HGTV", targets: ["HGTVApp"]),
        .library(name: "HGTVCore", targets: ["HGTVCore"])
    ],
    targets: [
        // 数据获取层：签名 + 设备注册 + 网络 + 接口 + 模型（纯 Swift，无 UI 依赖）
        .target(
            name: "HGTVCore",
            dependencies: [],
            path: "Sources/HGTVCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // 界面层：tvOS 26 SwiftUI + 液态玻璃 + AVPlayer
        .executableTarget(
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