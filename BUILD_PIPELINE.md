# HGTV tvOS 构建 → 推送 → 下载 → 交付 流水线（GitHub CI 版）

> 参考自《构建推送下载交付流水线.md》（Swiftfin-FNOS），改造为 HGTV 工程。
> 核心差异：HGTV 用 SwiftPM（无 xcodeproj），CI 用 xcodebuild 编 Package.swift。

## 与参考流水线的对应关系

| 参考流水线（Swiftfin-FNOS） | 本工程（HGTV） |
| --- | --- |
| 仓库 `Pupildan/swiftfin-fnos` | 你的 GitHub 仓库（待建，见下） |
| Windows + PowerShell + MinGit | macOS CI runner（无本地 Windows） |
| 版本号在 `FNOSAdapterBuild.swift` | 版本号在 `Scripts/build_ipa.sh` 的 Info.plist（CFBundleShortVersionString） |
| CI 工作流 `Build tvOS` | `.github/workflows/build-tvos.yml`（已提供） |
| `_tools/*.ps1` 脚本 | 不需要（GitHub 网页可直接下载 artifact） |
| 交付物 `Swiftfin-FNOS-tvos-unsigned-vXX.ipa` | `HGTV-tvOS-unsigned.ipa` |

## 你要做的（3 步）

### 1. 建仓库 + push
解压 `HGTV-tvOS26-CI.zip`，在里面 `git init` 后推到你的 GitHub 仓库（可私有）：

```bash
cd HGTV
git init
git add -A
git commit -m "HGTV tvOS 26 移植 + CI"
git branch -M main
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

### 2. CI 自动构建
push 到 main 后，`.github/workflows/build-tvos.yml` 自动触发：
- runner：`macos-26`（macOS 26 + Xcode 26，tvOS 26 / 液态玻璃需要）
- 步骤：选 Xcode 26 → `swift package resolve` → `xcodebuild`（tvOS arm64，不签名）→
  组装 `.app` → 打 `HGTV-tvOS-unsigned.ipa` → 上传为 artifact `HGTV-tvOS-unsigned`

监控：仓库 **Actions** 页签 → 点最新 run → 等绿勾（约 5–10 分钟）。

### 3. 下载 ipa
run 成功后，run 页面底部 **Artifacts** → 下载 `HGTV-tvOS-unsigned` →
解压得到 `HGTV-tvOS-unsigned.ipa`。

或用 GitHub CLI：
```bash
gh run download -R <你的用户名>/<仓库名> -n HGTV-tvOS-unsigned -D .
```

安装：unsigned ipa 需 AltStore / SideStore / Sideloadly 自签后装到 Apple TV。

## 构建失败排查

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `error: cannot find 'E1C'` 等 | 缺文件 | 确认 `Signing/E1Constants.swift` 在包内 |
| `no such module HGTVCore` | target 依赖 | 确认 Package.swift 的 HGTVApp deps 含 HGTVCore |
| `SDK 'appletvos' not found` | Xcode 版本 | 确认 runner 用了 Xcode 26 |
| 签名相关报错 | 已 CODE_SIGNING_ALLOWED=NO | 应不出现；出现则检查 xcodebuild 参数 |
| Swift 6 并发报错 | 严格并发 | 按 build 日志行号修（已做静态自查，可能仍有遗漏） |

## ⚠️ 交付前必读

- **这版 ipa 能装、能进界面，但取不到真实数据**：签名层 x-gorgon / x-argus 是占位实现，
  请求会被服务端拒。界面/播放/数据层骨架已就位，签名补全后即可取数。
- **我没有在本机编译验证过**（无 Xcode）。CI 首跑可能报编译错——把 Actions 里的
  错误日志贴给我，我按行号修。
- **首次 CI 大概率需要 1–2 轮调试**（xcodebuild 对 SwiftPM 包的 scheme 名、
  destination、签名参数等可能要微调）。这是正常的，有日志就能快速修。

## 改版本号

每次交付改 `Scripts/build_ipa.sh` 里 Info.plist 的：
```
<key>CFBundleShortVersionString</key><string>1.3.7.3</string>
<key>CFBundleVersion</key><string>78</string>
```
或在 CI 里加 tag 触发（`v*` tag 已配置）。