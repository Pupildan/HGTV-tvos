# HGTV tvOS 26 移植 — 编译与交付说明

## 这是什么

把 HGTV（`com.hgtv.star` 1.3.7.3，番茄短剧第三方客户端）的数据获取链路移植成
可编译的 **tvOS 26 SwiftUI** 工程：严格复用原 APK 的接口与签名链路，界面遵循 tvOS 规范 +
液态玻璃，播放用 Apple 官方 AVPlayer。

## 目录结构

```
tvos/HGTV/
├─ Package.swift                 SwiftPM 清单（tvOS 26，Swift 6.2）
├─ SIGNING_NOTES.md              签名链路逆向笔记（含 10 条待确认）
├─ BUILD_GUIDE.md                本文件
├─ Sources/
│  ├─ HGTVCore/                  数据获取层（纯 Swift，无 UI 依赖）
│  │  ├─ Signing/                签名算法
│  │  │  ├─ CryptoPrimitives.swift    MD5/SHA-256/CRC64/自研哈希/位操作 ✅
│  │  │  ├─ CommonParams.swift        R3 公共 query + UA 模板 + cdid ✅
│  │  │  ├─ DeviceFingerprint.swift   C1 S-box + 状态机（varlenHash 占位）⚠️
│  │  │  ├─ XArgus.swift              x-argus/x-medusa 分支骨架 ⚠️
│  │  │  └─ XGorgon.swift             C3.c 主流程（x-gorgon 值不对）⚠️
│  │  ├─ DeviceRegister.swift         设备注册（响应解析确认，body 推断）⚠️
│  │  ├─ SignInterceptor.swift        公共头注入（等价 H0/d）✅
│  │  ├─ Network/                     HTTPClient / LocalLibrary / DeviceRegisterService
│  │  ├─ API/                         HGTVConfig（域名/endpoint/常量）+ APIService
│  │  └─ Models/                      数据模型
│  └─ HGTVApp/                   界面层
│     ├─ HGTVApp.swift           入口 + AppModel 引导
│     ├─ Views/                  RootTabView / Home / Category / Search / Library / Detail
│     └─ Player/                 PlayerView + PlayerViewModel（AVPlayer + 容灾）
└─ Tests/HGTVCoreTests/          签名固定向量自检（占位）
```

## 编译

需要 **Xcode 26**（Swift 6.2 工具链，tvOS 26 SDK）。本机（手机 proot Ubuntu）无 Xcode，
**未做编译验证**——工程按 Swift 6 严格并发 + 可编译标准编写并做了静态自查，但请以你本地 Xcode 为准。

```bash
cd tvos/HGTV
swift build                      # 命令行编译 HGTVCore + HGTVApp
swift test                       # 跑签名固定向量测试
# 或用 Xcode 打开 Package.swift，选 tvOS 模拟器 / Apple TV 目标直接 Run
```

> 首次打开若提示选 scheme，选 `HGTV`（executable）。

## 界面（tvOS 规范 + 液态玻璃）

- 顶层 `TabView`（首页/分类/搜索/我的），焦点驱动，遥控器上下左右导航。
- 卡片用系统材质（`.glassEffect()` / `.ultraThinMaterial`）表达液态玻璃，不自绘背景。
- 海报卡焦点放大，`ContentUnavailableView` / `ProgressView` 用系统组件。
- 详情页选集网格 → `sheet` 弹出播放页。

## 播放（Apple 官方播放器）

- `AVPlayer` + `AVKit.VideoPlayer`，自带 tvOS 传输控件（进度/暂停/倍速/字幕）。
- 取流严格复用原链路：`/novel/player/video_model` → CDN 直链；失败换候选 TNC 域名重试。

## 数据获取（严格复用原 APK，不造轮子）

| 业务 | 来源 | 签名 |
| --- | --- | --- |
| 搜索/联想 | 自建中转 `hongguoduanju.com` | 不需要 |
| 分类/详情/播放模型 | 番茄 `fqnovel` / `reading.snssdk.com` | 需要 |
| 登录 | 字节 Passport（aid=8662） | 需要 |
| 设备注册 | `/service/2/device_register/` | 需要 |

域名、endpoint、aid、UA、passport-sdk-version 全部来自 dex 原文，见 `HGTVConfig.swift`。

## ⚠️ 已知限制（务必阅读）

**签名层 x-gorgon / x-argus 当前是占位实现，请求会被服务端拒绝**，因此现阶段**取不到真实数据**。
这是字节最核心的混淆序列化（生产环境走 native `libsgmain`），从 dex 静态还原极难。
详见 `SIGNING_NOTES.md` §5 的 10 条待确认，其中关键：

1. x-gorgon 依赖 `F0.l0.H`/`l0.J`（参数字典序列化+加密），反编译被寄存器传播污染。
2. x-argus 生产走 native，Java 层只是 4 字节兜底。
3. 设备注册请求 body 字段是推断，未从 dex 校对。

**要真正跑通取数**，可行的后续路径（按推荐度）：
- **Frida hook 真机 `libsgmain`** 拿「输入→四个签名头」对，先建对拍基准再还原 Swift（最稳）。
- 补导出 `F0/l0`(已有 smali)、`F0/A1`、`F0/D1`、`F0/W3`、`F0/M3`、`F0/u1` 的 smali 逐行还原。
- 签名走后端中转（服务端跑原 dex 的签名模块，App 调接口拿头）。

按你之前的选择「先交可编译工程，签名占位」，这些留作下一步。界面/播放/数据层骨架已就位，
签名头一旦补全即可联调取数。

## 下一步（签名对拍）需要的东西

若要继续还原 x-gorgon，最有价值的是一份真实抓包：
`URL + query + body + x-gorgon/x-argus/x-ladon/x-khronos/x-medusa/x-helios` 的实际值。
有了输入输出对，就能定位 Swift 实现与原算法的差异分支。