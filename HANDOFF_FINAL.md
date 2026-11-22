# HGTV tvOS 项目交接文档 — 播放实现失败分析与剩余方案

> 2026-11-23 · 基于 v75（最新构建）+ 1.3.8.13 dex 全量反编译
> 接手人：本文档包含完整失败分析、已验证/未验证清单、剩余方案

---

## 一、核心问题一句话

**ATV 端所有需要签名的接口（landpage 推荐流、bookmall 内容流）均返回 HTTP 200 + 0 字节**。签名五件套（gorgon/helios/ladon/argus/medusa）中，前四个已逐字节验证正确，**medusa 是唯一未完全验证的**——它是服务端拒绝的直接原因。

## 二、为什么 75 轮还没搞定

### 2.1 问题的本质难度

这不是普通的 API 对接。番茄小说（fqnovel）的签名体系是字节级加密协议：

```
每个请求需要 5 个签名头，全部由客户端实时计算：
  x-gorgon  — 基于 query+body 的 RC4 加密（30 字节）     ✅ 已破
  x-helios  — 34 轮 Feistel 加密（36 字节）               ✅ 已破
  x-ladon   — 4 字节随机数 base64                         ✅ 已破
  x-argus   — le32(timestamp) base64                      ✅ 已破
  x-medusa  — protobuf → SM3 → 自研区块密码 → 位采样 →     ⚠️ 结构已破，PB 内容未逐字节验证
              位补丁 → base64（~1160 字节）
```

**medusa 是唯一的拦路虎**。它是字节级加密协议，不是简单的 hash 或 HMAC——任何一个字节错误都会导致服务端拒绝。

### 2.2 为什么这么难

| 困难 | 具体表现 |
|---|---|
| **无官方 SDK 文档** | 全靠反编译 dex + 抓包逆向 |
| **算法版本漂移** | 我们参考 1.3.7.7，手机实际跑 7.4.3.32/1.3.8.13，算法有演进 |
| **jadx 反编译缺陷** | 核心方法（1322 指令）反编译失败，需从 smali 手工还原 |
| **验证依赖真机** | 无法在 PC 上完整运行 medusa 生成链，只能靠抓包对拍 |
| **每次验证成本高** | 改一行代码 → CI 构建 20 分钟 → ATV 手动安装 → 看日志 |
| **PC 与 ATV 环境差异** | PC 重放（Python 签名）能拿到数据，但 ATV 的 Swift 实现行为不同 |

### 2.3 已完成的验证（不是全白费）

| 组件 | 验证方式 | 结果 |
|---|---|---|
| **x-gorgon** | 手机抓包 112 组逐字节对拍 | ✅ 完全正确 |
| **x-helios** | 手机抓包 112 组逐字节对拍（v72 修复 ror61 bug） | ✅ 完全正确 |
| **x-ladon** | 4 字节随机 base64 | ✅ 正确 |
| **x-argus** | le32(ts) base64 | ✅ 正确 |
| **SM3 哈希** | dex V1/b 类抠出在 PC 编译运行，"abc" → 标准向量 ✓ | ✅ 标准 SM3 |
| **medusa envelope 外层** | 112 组抓包对拍（20 字节前缀 + 结构） | ✅ 结构正确 |
| **medusa obscure 链** | smali + Kotlin 参考 + dex Java 三方对照 | ✅ 逻辑正确 |
| **medusa 六张表** | sboxes/rcon/perms/row3/select/patch 逐值比对 | ✅ 一致 |
| **medusa PB 字段映射** | 1.3.8.13 Java 原文逐字段核对 | ⚠️ 大部分一致，细节待确认 |

## 三、medusa 未通过的具体原因分析

### 3.1 已确认并修复的 bug

| 轮次 | Bug | 修复 |
|---|---|---|
| v72 | helios 中 `krotl64(b0, 61)` 应为 `kror64` | ✅ 已修 |
| v74 | sm3Hash: FF 误用 (A,B,C)（应为 B,C,D），漏 W' | ✅ 已修 |
| v74 | medusa 设备字段：HONOR VER-AN00 → SM-F7310/samsung | ✅ 已修（v71） |
| v75 | context 缺 v[1]（uptime）、多 v[13]（dex 无此字段） | ✅ 已修 |

### 3.2 仍未确认的差异

**1. PB 明文长度差异**
- 手机 PB 明文 ≈ 1118 字节
- 我们 PB 明文 ≈ 1064 字节
- 差额 ≈ 54 字节，来源未确定

可能原因：
- v[23] context 子消息中设备字段（7-11）在真机有值（-888888/2/!notset!），我们为 0/空
- v[23] context 字段 v[1]（uptime）刚加，之前缺失
- v[24] environment JSON 字符串长度差异

**2. medusa 解密残差**
- 用正确 digest（phone=标准SM3, ATV=buggy-SM3）解密，均只能恢复部分字节
- 完整解密链有循环依赖（select 位被 cipher 位覆盖），无法直接逆
- 需要 frida hook 真机拿中间值，或完整移植 dex Java 链在 PC 运行

**3. 设备字段 7-11**
- dex device 子消息有字段 7-11（c3.f1627c 到 f1631g）
- 默认状态：全 0/空（PB 序列化器跳过）
- 真实路径：-888888/2/!notset!（非零，会被编码）
- 我们的 ATV 用默认状态 → 这些字段缺失 → PB 与真机不同

### 3.3 为什么 PC 重放成功但 ATV 失败

| 环境 | 签名来源 | 结果 |
|---|---|---|
| PC + 手机抓包头重放 | 手机 app 生成的真实签名 | ✅ 1.15MB |
| ATV + Swift 移植签名 | 我们自己算的签名 | ✗ 0 字节 |

**关键差异**：手机 app 的 medusa 是 dex 原生代码生成的，我们的 Swift 移植有细微差异。PC 重放成功是因为用了手机的真实签名（不是我们自己算的）。

## 四、剩余可行方案（按可行性排序）

### 方案 A：Frida hook 真机拿 medusa 中间值（最可靠）

**原理**：在手机上用 Frida hook medusa 生成链的关键节点，拿到每一步的中间值，然后逐字节对拍我们的 Swift 实现。

**步骤**：
1. 手机连 adb，安装 Frida server
2. Hook 以下函数，打印输入/输出：
   - `LF0/e1;->x(Ljava/lang/String;[B)[B` — SM3 digest 调用（确认算法名）
   - medusa obscure 函数（per-index 映射 + 链式变异）
   - medusaSmall 区块加密（key expansion + 2 轮）
   - PB 序列化（拿到完整明文 PB）
3. 用拿到的中间值逐字节对拍 Swift 实现
4. 修完差异 → v76

**预估工作量**：1-2 天（Frida 脚本 + 对拍）
**成功率**：高（直接拿真实中间值，不猜）

### 方案 B：完整移植 dex Java 链到 PC 运行（次可靠）

**原理**：把 1.3.8.13 dex 的 medusa 全链（I1.e → envelope → base64）在 PC 上编译运行，用受控输入生成 ground-truth medusa，然后逐字节对拍 Swift。

**步骤**：
1. 解决 jadx 反编译的坏方法（已部分完成，SM3 类已成功编译运行）
2. 补齐依赖闭包（约 20-30 个类，大部分无 Android 依赖）
3. 写 Java driver 调用 medusa 生成链
4. 生成 ground-truth medusa → 与 Swift 对拍

**预估工作量**：2-3 天（依赖闭包 + stub 编写）
**成功率**：中高（jadx 反编译可能有残留错误）

### 方案 C：抓包重放代理（快速但非终极方案）

**原理**：PC 作为代理，拦截 ATV 的内容请求，用手机的真实签名替换 ATV 的签名，转发给服务端。

**步骤**：
1. ATV → PC 代理 → 服务端
2. PC 拦截请求，用预存的手机签名替换 ATV 签名
3. 服务端返回数据 → PC 转发给 ATV

**问题**：
- 签名绑定了 query/body/ts，不能直接替换
- 需要手机持续在线提供签名
- 本质上是"借手机签名"，不是独立实现

**预估工作量**：半天
**成功率**：高（但不是终极方案）

### 方案 D：放弃 medusa，只用不验签接口

**原理**：bookmall 播放接口（multi_video_model/v1 旧变体）和部分 bookmall 接口不严格验签。只用这些接口获取内容和播放。

**现状**：bookmall/tab/v 从 ATV 也返回 0 字节（v75 日志确认）。说明 bookmall 也需要有效签名。

**结论**：此路不通——所有内容接口都需要有效签名。

### 方案 E：接受现状，用搜索接口

**原理**：搜索接口（/reading/bookapi/search/tab/v）可能验签较松。用户手动输入剧名搜索，绕过推荐流。

**风险**：搜索接口可能同样被门控。

## 五、踩过的坑（完整清单）

### 5.1 代码移植坑

| 坑 | 表现 | 教训 |
|---|---|---|
| Kotlin→Swift rotateLeft/Right | `krotl64(b0, 61)` 应为 `kror64` | Java Long.rotateLeft ≠ Swift rotateLeft，必须逐个确认方向 |
| UInt32 checked 转换 | `UInt32(负数)` 秒崩 | Kotlin/Java 的 int 是有符号 32 位，Swift UInt32 是无符号 |
| UInt8 >> ≥8 | Swift 的 UInt8 移位 ≥8 会 trap | 必须 `& 7` 后再移位 |
| Int64 无 rotate | Swift Int64 没有 rotateLeft/Right | 自己实现，用 UInt64 bitPattern |
| sm3Hash 写错 | FF(A,B,C) 应为 FF(B,C,D)，漏 W' | 注释声称"abc 校准"是假的，必须实际跑标准向量 |
| helios kror61 | krotl64 应为 kror64 | rotateLeft(61) = rotateRight(3)，方向搞反 |
| flatMap Optional | `groups.flatMap(\.items)` 返回嵌套数组 | items 是 Optional 时必须 `?? []` 解包 |
| memberwise init 访问级别 | public struct 的 memberwise init 是 internal | 必须显式写 public init |

### 5.2 环境/工具坑

| 坑 | 表现 | 解决 |
|---|---|---|
| bash 双路径 | `/c/`=真C盘，`"C:\..."`=假 `Git\c\` | 用前先 `pwd` 确认，产物会分叉两处 |
| CI push 竞争 | CI 版本 bump 与手动 push 冲突 | 用 workflow_dispatch 重跑 |
| git credential.helper | WorkBuddy GCM 已卸载会卡死 | 用 PowerShell CredRead 读凭据管理器 |
| GitHub API 劫持 | api.github.com 被劫持 | curl 加 `--resolve api.github.com:443:140.82.112.6` |
| token 不支持 git push | 桌面 token 只支持 API | push 用 CredMan 里的 github_pat |
| artifact 下载 302 | S3 签名 URL 不接受 Authorization | 先拿 Location 再无 auth GET |
| jadx 反编译坏点 | `?? r2;` 类型推断失败 | 自动迭代 patcher 剔除坏方法 |
| MSYS 路径翻译 | adb -s 参数后的路径被翻译 | 用 workspace 相对路径 |

### 5.3 协议理解坑

| 坑 | 表现 | 教训 |
|---|---|---|
| medusa PB 长度差异 | 手机 1118B vs 我们 1064B | 不是固定 54B 结构差，是设备字段值差异 |
| bookmall 也验签 | 以为不验签，实际宽松验签 | 所有内容接口都需要有效签名 |
| 签名时效窗口 | 90 分钟旧签名仍有效 | 不能靠"等签名过期"判断是否被拒 |
| 身份烧毁 | 长龄身份被反复测试后烧毁 | 每次测试用新注册身份 |
| dex 版本漂移 | 1.3.7.3 参考 vs 1.3.8.13 实际 | 必须用与手机一致的 dex 版本 |
| jadx 类名不稳定 | S1/b → V1/b（仅类名变化） | 按 smali 内容搜索，不按类名 |
| medusa select/patch 位重叠 | 读 8 位再被密文位覆盖 | 解密时有循环依赖，无法直接逆 |

## 六、项目资产清单

| 资产 | 位置 | 用途 |
|---|---|---|
| 1.3.8.13 jadx Java 源 | C:\Users\Admin\jadxrun\out13\sources\ | medusa 全链可读源码 |
| 1.3.8.13 smali | C:\Program Files\Git\c\HGTV-tvOS-项目资产备份\apk_13813\decoded\smali\ | 底层验证 |
| 1.3.7.3 smali | /c/apktool_work/decoded/smali/ | 旧版对比 |
| jadx 1.5.7 | C:\Users\Admin\jadxrun\jadx.jar | 反编译工具 |
| 手机抓包 | hgtv-analysis/hdr_capture.txt | 112 组签名向量 |
| bookmall 重放响应 | hgtv-analysis/bookmall_replay.json | 1.15MB 真实响应 |
| SM3 PC 编译 | C:\Users\Admin\jadxrun\sm3run\ | dex SM3 可运行验证 |
| medusa 解密器 | medusa_decrypt.py | envelope 逆（部分） |
| helios 验证器 | Scripts/signing_verify/helios_verify.py | 双向量 True |
| gorgon 验证器 | Scripts/signing_verify/gorgon_verified.py | 手机向量 match:True |
| GitHub token | 桌面 "token api.txt" | API 访问 |
| git push 凭据 | Windows 凭据管理器 git:https://github.com | PowerShell CredRead |

## 七、给接手人的建议

1. **不要从零开始**——75 轮的积累是有价值的。gorgon/helios/ladon/argus 四个签名头已逐字节验证正确，SM3 已修正，envelope 结构已验证。只差 medusa PB 内容的精确匹配。

2. **优先方案 A（Frida hook）**——这是唯一能拿到 medusa 中间值的方法，不需要猜。一旦拿到 PB 明文和 obscure 前后的值，差异会立刻暴露。

3. **不要盲试**——每一轮构建 20-30 分钟 + 手动安装。必须先在 PC 上验证（方案 A 或 B），确认修对了再构建。

4. **注意版本一致性**——所有逆向分析必须基于 1.3.8.13 dex（不是 1.3.7.3/1.3.7.7）。手机实际运行的就是这个版本。

5. **medusa 的 55 字节差额是关键线索**——手机 PB 1118B vs 我们 1064B。找到这 55 字节是什么字段，就找到了问题。最可能的位置：v[23] context 子消息中的设备字段（7-11）和 v[24] environment JSON 的值差异。
