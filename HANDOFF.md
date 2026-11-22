# HGTV tvOS 移植 —— 交接文档

> 把开源安卓短剧客户端 `com.hgtv.star`（番茄短剧/FQNovel，`HGTV_1.3.7.3.apk`）移植到 **tvOS 26（Apple TV）**。
> 复用原 APK 的**数据获取逻辑**（签名/取流/解密照抄，严禁造轮子）+ **Liquid Glass UI** + **AVPlayer**。
> CI 构建未签名 ipa，用户自行签名/旁加载。
>
> **配套详细实现**：[HANDOFF_IMPL_DETAILS.md](./HANDOFF_IMPL_DETAILS.md)（211 行，代码级精确，逐条标注 `文件:行号`）。
> 本文是总览 + 原理 + 踩坑 + 方向；字节级构造、逐行解析见详细版。

---

## 一、当前进度（截至 v18）

| 模块 | 状态 | 说明 |
|---|---|---|
| 签名算法（X-Gorgon 等） | ✅ 完成 | 纯 Java/Swift 实现，无 native 库，真机身份验证通过 |
| 设备身份 | ✅ 完成 | device_id/iid 等硬编码真机值（见坑 4） |
| 无限推荐 feed | ✅ 完成 | 反复请求 `bookmall/tab/v`，按 vid 去重累积，封面可无限下滑 |
| 播放取流 | ✅ 完成 | `multi_video_model/v1` 取加密直链 + spade_a |
| 视频解密 | ✅ 完成 | spade 派生密钥 + CENC-AES-CTR 整段解密 + stsd 加密壳清理（v18，见坑 13） |
| 播放器池 + 分页切换 | ✅ 完成 | DYTV 架构：AVPlayer 池 ±2 窗口 + UICollectionView 垂直分页 |
| 视频真正播出 | ✅ **真机确认出画面**（v18） | 坑 13 修复生效；v19 继续：清晰度选最高 + overlay 自动隐藏 |
| 清晰度选择 | ✅ v20 修正 | **quality_type 数值越小越清晰：q=1=原画（实测 1.11Mbps），q=40 最低（0.23Mbps）**。v19 误选 max 恰中最低档；v20 改选 min。CDN 实测数据见 APIService.swift 注释 |
| 起播速度 | ✅ v21 | 真机 v20 实测 resolve 8-30s（设备端 ~1.2MB/s）。三管齐下：①居中条优先下载，邻居延后到居中 ready 再补（原来并行抢带宽）②>4MB 走 4 分片并发 Range 下载+分片重试，失败回退单流 ③AES key schedule 每视频展开一次（原来逐 16 字节块重算，省 ~40% 解密耗时） |
| feed 多样性 | ✅ v21 | bookmall 无翻页（has_more 恒 false），单 tab 内容池固定（~6 条/次，两次请求交集 ~4/6）。实测 tab 8/38/32/14 内容池**完全不相交**（9/11/10/16 条）→ loadMore 轮换 tab_type 8→38→32→14 循环 |
| 选集（剧集列表） | ✅ **v22 打通** | 番茄 video_detail/v1 风控门控弃用；改走红果短剧 web（hongguoduanju.com，无签名）：`/detail?series_id=` 的 SSR 内嵌 `_ROUTER_DATA` JSON（剧名/封面/简介/标签/集数/全量 vid_list，实测 1000 集全可播）。`HongguoWeb.swift` 括号配平提取 JSON |
| 播完行为 | ✅ v22（A1） | 播完自动切下一集；feed 末尾先 loadMore 再切（原为循环重播） |
| 遥控交互 | ✅ v22 | **左右**滑动/点击环=上一集/下一集；中键确认=进当前剧详情页。修了潜在 bug：pressesBegan 原检查 press.key（遥控按键该字段为 nil）导致遥控输入全部被丢弃；触控板滑动经全屏 UIFocusGuide+不可见 SwipeFocusProxyView 拦截（上下吞掉） |
| 详情页 | ✅ v22 | DramaDetailView 重写：PC 端布局（海报+信息横排/集数网格）、海报模糊铺满+CIAreaAverage 取主色氛围渐变、当前集高亮、焦点优化；播放器内选集=整表替换 feed 连播，其他 tab 选集=内置 AVPlayerViewController 全屏浮层 |
| 遥控 bug | ✅ v22 | pressesBegan 原检查 `press.key`（Siri Remote 按键该字段为 nil）→ 遥控输入全部被静默丢弃；改用 `press.type` |
| 电影处理 | ✅ v23（用户拍板 A） | 轮换去掉 tab14（电影条目 multi_video_model 不下发播放地址，日志实锤「播放地址已过期」）；顶部栏位加「电影」占位 tab（内容后期接）；无流条目兜底：failedVids 记录 + 居中自动跳过（双向就近）+ 播完自动切集只向前找可播条目 |
| 端点扫描 | ✅ v23 结论 | 手机端**全部详情/列表族接口被风控**：video_detail 全变体（GET/POST/参数变体）、multi-detail、search/tab、plan 均 200+0 字节，bookshelf/info 恒 data=None；仅 bookmall 与 multi_video_model 存活 → 设备/行为级门控，非参数问题。扫描脚本 `exp_scripts/scan_endpoints.py`。剧集列表维持红果 web 数据源，直到真实 device_register（抓手②）或原生 argus（抓手③）落地 |
| 剧集列表（series_id→集数） | ❌ 未打通 | `video_detail/v1` 服务端恒返 200+0 字节，疑风控门控 |
| 分类/搜索/我的 tab | 🚧 骨架 | tab 结构在，功能未填充 |

**构建**：GitHub Actions（`.github/workflows/build-tvos.yml`），macOS + Xcode 26.6，xcodegen + xcodebuild archive。
版本号来自仓库 `VERSION` 文件（自然数），构建成功后自动 +1 并 push。产物 `HGTV-tvOS-v{N}-unsigned.ipa`（GitHub Artifact）。
**最新已交付**：v17；v18（stsd 加密壳修复 + 竞态修复）待构建交付。

**开发机已迁移**（2026-11-18）：现为一台 Windows PC（LAN IP `192.168.10.122`）。
日志接收端 `Scripts/log_server.py` 在该机运行——Windows 必须用 `python -X utf8` 启动
（否则 cp1252 控制台编码崩溃），并放行入站 TCP 51820 + UDP 5353（mDNS）。
tvOS 端走 Bonjour `_hgtvlog._tcp` 自动发现，无需改代码。

---

## 二、签名算法实现（重点）

原 APK 是纯 Java 签名（无 native `.so`），全部逆向复刻为 Swift。主入口 `RequestSigner.sign`：`Signing/XGorgon.swift:69`。

### 2.1 时间源
- `clock()` 返回**毫秒**：`XGorgon.swift:53`
- `ts = nowMs / 1000`（**秒级**）：`:73-74`
- `rticket = nowMs + attempt`（**毫秒**）：`:78`

### 2.2 字节级构造表（核心）

| 头 | 字节构造 | 长度 |
|---|---|---|
| **x-gorgon** | `base64( [00 00 40 01][le32(ts)][le32(rticket低32)][a1 01 00 00] )` | 16B |
| **x-argus** | `base64(le32(ts))` | 4B |
| **x-khronos** | `String(ts)`（秒级十进制文本） | 变长 |
| **x-ladon** | `base64(4 字节 SecRandom)` | 4B |
| **x-medusa** | `base64( [32B SM3][00 00 00 00] )` | 36B |
| **x-helios** | **不发送**（发了内容 API 返空，见坑 1） | — |

- `le32(v)` = 小端 4 字节 `[v, v>>8, v>>16, v>>24]`：`CryptoPrimitives.swift:26-28`
- x-gorgon 首尾 4 字节 `[00 00 40 01]` / `[a1 01 00 00]` **恒定**，中间 ts（秒）+ rticket（毫秒）。

### 2.3 SM3 与校验链
- **SM3 自写标准实现**（非库），`CryptoPrimitives.swift:325-391`，用 `abc`→`66c7f0f4...` 校准。
- `_rticket` 重试：最多 128 次滚动，直到 `(h2 & 15) % 3 == 0`。校验链：
  `h1 = customHash(customHash(539167016, query), bodyMD5)` → `h2 = customHash(h1, le32(ts))`：`XGorgon.swift:93-94`。
  `customHash`（种子 539167016，奇偶字节不同移位）：`CryptoPrimitives.swift:254-265`。
- **x-medusa 输入**：`SM3(UTF8(path) || body || le32(ts))`，不含 query/selector：`XGorgon.swift:223-230`。
  与已打通播放的 Python `playback_client.py` 语义一致（path+ts，无 selector），但比 `signer.py`（含 body-md5+selector）简化。**播放链路已验证可用**。

### 2.4 注入
`SignInterceptor.intercept`：`SignInterceptor.swift:65-126` —— 合并公共 query → sign → 注入 Cookie / x-ss-dp=8662 / x-tt-token / passport-sdk / X-HGTV-* / x-tt-trace-id。

---

## 三、数据获取流程（重点）

域名 `api5-normal-lf.fqnovel.com`，aid=8662：`API/HGTVConfig.swift:37,11`。

### 3.1 关键端点
| 用途 | 端点 | 要点 |
|---|---|---|
| 无限 feed | `GET /reading/bookapi/bookmall/tab/v?tab_type=T` | **无分页参数**；tab_type：找剧=8/真人剧=38/漫剧=32/电影=14 |
| 播放取流 | `POST /novel/player/multi_video_model/v1/?vid=X` | body 为 **gzip JSON** |
| CDN 下载 | 直链 GET（无需签名，跟随重定向） | 加密 mp4 |
| 设备注册 | `POST /service/2/device_register/` | 占位实现（见坑 4） |

### 3.2 无限 feed 机制（逆向得出）
**没有分页参数**。反复请求同一 URL，服务端每次按新 session 随机出 ~6 条，客户端按 **vid 去重累积**：`APIService.swift:41-43,56-90`。
`extractVideos` 深度优先遍历 JSON 树，命中 `dict["video_data"]` 节点逐条映射 `DramaItem`，去重键 `vid ?? title`：`APIService.swift:57-90`。

### 3.3 multi_video_model 请求/响应
- body（`APIService.swift:147-163`）：`{biz_param:{10 字段}, dr_scene:"player", mixed_video_id_map:{"1004":[vid]}}`，gzip 手包头尾（`Playback/Gzip.swift:11-19`）。
- 必带头：`Content-Encoding: gzip`、`Content-Type`、`x-ss-stub`=base64(md5(body)) 大写、`x-reading-request`、`x-vc-bdturing-sdk-version`。
- 响应解析（`APIService.swift:185-233`）：`code==0` → `data.<vid>` → `video_model`（**内嵌 JSON 字符串**需二次解析）→ `video_list[]` 优先取 `encrypt_info.spade_a` 非空项。

---

## 四、视频加密解密（重点 + 原理）

### 4.1 端到端链路
```
fetchPlayback(vid)            → 加密直链 main_url + spade_a
  → downloadData(url)         → 下载加密 mp4（CDN）
  → SpadeKey.deriveKey(spade_a) → 16 字节 AES-128 内容密钥
  → CENCDecryptor.decrypt(data, key) → 明文 mp4 + stsd 加密壳清理（后台线程）
  → PlaybackProxy.start()     → http://127.0.0.1:PORT/video
  → AVPlayer 播放
```
调用点：`HGTVApp/Player/PlayerViewModel.swift:29-75`、`PlaybackEngine.swift`（resolveLocalURL，带 in-flight 去重）。

**坑 13 必读**：解密只还原 mdat 样本；stsd 里的 `encv`/`enca` 加密壳必须一并清掉
（`sanitizeForAVPlayer`，4CC 原地替换、零字节移动），否则 AVPlayer readyToPlay 但永不渲染。

### 4.2 spade 密钥派生（`Playback/SpadeKey.swift:29-71`）
忠实移植原 APK `signing_full.txt`（Python 金标准 `gorgon_py/spade.py`）。输入 `spade_a`（base64）→ 16 字节密钥：
1. base64 解码 → `raw`
2. `xor3 = b0^b1^b2`；`keyLen = min((len-xor3)+47, len-1)`
3. 切片 `raw[1...keyLen]`
4. 逐字节混淆（奇偶位滚动种子 85/246）：`slice[i] = byte((-21 - bitCount(i)) + (s ^ b))`
5. 取 `slice[1..<33]` 解成 32 字符 hex
6. hex 解码 → 16 字节密钥

**无 SHA/SM3**，纯"base64 + 位混淆 + hex"。验证样例：`spade_a="nLwS816...Zw=="` → `195c21c7dd8de75cb71be08dfa4ae6f3`。

### 4.3 CENC-AES-CTR 解密原理（`Playback/CENCDecryptor.swift`）
progressive mp4（ftyp/moov/mdat，非 fragmented）。**每个 track 每个样本独立加密**：
1. 找 moov → 遍历每个 trak
2. 解析轨道表 stsz（样本大小）/ stsc（样本-块映射）/ stco·co64（块偏移）/ senc（IV）→ 算出每样本 `(偏移, 大小, IV)`
3. senc IV：`flags&0x2` 读 ivlen 否则 **ivlen=8**；`flags&0x1` 跳过 subsample 表
4. 逐样本 `ctrCrypt(key, iv, data[偏移..<偏移+大小])` 原地写回

**CTR 计数器构造**（核心，`:273-304`）：
- 16 字节计数器块 = `IV(8 字节) || 8 字节 0` → 首块即 CENC **counter_0**
- keystream 块 = `AES-128-ECB(key, 计数器块)`
- 明文 = 密文 XOR keystream
- 计数器 +1：`counter[15]→counter[8]` big-endian 64 位进位（`AESECB.swift:164-174`）
- Python 对照：`Counter.new(64, prefix=iv, initial_value=0)` ✅

### 4.4 为什么手写 AES-128-ECB（关键踩坑）
- ❌ **CryptoKit AES.GCM**：12 字节 nonce 只在末 4 字节递增，且首数据块固定从 `J0+1`（=nonce||0x00000002）起，只能产出 counter_2/3…，**给不出 counter_0/counter_1**，字节布局也不对 → 解密 99.6% 字节错（黑屏根因）。
- ❌ **CommonCrypto**：在 HGTVCore framework target 里 `kCC*/CCCryptor*` 符号找不到（"cannot find in scope"）。
- ✅ **纯 Swift 手写单块 AES-128-ECB**（`AESECB.swift`，仅依赖 Foundation）：
  - S-box **运行时 GF(2^8) 生成**（模 0x11B + 暴力求逆 + 仿射 `^0x63`），避免手抄 256 项表出错
  - Rijndael 密钥扩展 + 列主序 state + 9 轮 + 末轮无 MixColumns
  - 自测向量：FIPS-197 C.1（→`69c4e0d8...`）、NIST SP800-38A（→`3ad77bb4...`）均通过

### 4.5 PlaybackProxy（为什么需要）
AVPlayer **不能直接播内存 Data**，只能给 URL。故起本地 HTTP 服务（Network.framework `NWListener`，绑 127.0.0.1 随机端口）托管已解密明文，AVPlayer 播 `http://127.0.0.1:PORT/video`。
- Range 请求 → `206 + Content-Range`；无 Range → `200`；都带 `Accept-Ranges: bytes`
- `Connection: close`（每请求一连接，AVPlayer 自行重连）
- 详见 `Playback/PlaybackProxy.swift:109-140,179-216`

---

## 五、踩过的坑与解决方案（按代价排序）

| # | 坑 | 后果 | 解决 |
|---|---|---|---|
| 1 | **x-helios 发送** | 内容 API 返 0 字节（空数据） | 注释掉不发送（`XGorgon.swift:121-123`）。函数体保留但未调用 |
| 2 | fetchHome 映射错字段 | 首页空（数据到了但没解析出） | 递归 `extractVideos` 提取嵌套 `video_data` 节点 |
| 3 | **CryptoKit GCM 做解密** | 黑屏（99.6% 字节解错） | GCM 给不出 counter_0/1 → 改纯 Swift AES-ECB 生成 keystream |
| 4 | **CommonCrypto 在 framework target 找不到** | 编译失败（`kCC*` not found） | 放弃 CommonCrypto，纯 Swift 手写 AES-ECB |
| 5 | x-helios 排查成本 | 盲猜半天 | 用开发机 header replay 隔离：带→0B，不带→正常 |
| 6 | 每次播放 `AVPlayer(playerItem:)` 新建 | 同一 AVPlayerItem 挂到第二个 player → `_attachToPlayer` 抛 NSException → SIGABRT 闪退 | 复用单个 AVPlayer + `replaceCurrentItem` |
| 7 | 播放 Task 被取消 | 快速滑动取消 CDN 下载 → 永远播不出 | 不取消下载任务，跑完写缓存，末尾用 currentIndex 判断是否切换 |
| 8 | SwiftUI VideoPlayer / 手挂 AVPlayerLayer | tvOS 不渲染输出 / 画面残缺压成一小条 | 改用 AVPlayerViewController；再重构为 UICollectionView + PlayerLayerView（layerClass=AVPlayerLayer，layoutSubviews 强制 frame=bounds） |
| 9 | GeometryReader 在 ScrollView 内塌陷 | 布局尺寸错 | DYTV 架构：UICollectionView itemSize = view.bounds |
| 10 | **item readyToPlay 不触发 play** | 视频卡 paused 黑屏（画面能出但不动） | `handleItemStatus` 的 readyToPlay 分支补 `play()`（v17） |
| 11 | tvOS `isPagingEnabled` / `scrollToItem` | 前者 tvOS 不可用编译失败；后者 flow layout 未就绪抛 NSException | 手动 snap（`scrollViewWillEndDragging` + `setContentOffset`） |
| 12 | AVPlayer 池不解绑 | 解码器耗尽 → 黑屏 | 驱逐必须 `replaceCurrentItem(nil)`；±2 窗口 |
| 13 | **解密产物残留 CENC 加密壳**（v18 定位的黑屏真根因） | stsd 仍是 `encv`/`enca` + `sinf`/`senc`/`saiz`/`saio`：AVPlayer 认定内容加密 → item readyToPlay、timeControl=playing 都正常，但**解码器永不输出一帧**（isReadyForDisplay 恒 false 全黑）。桌面播放器（VLC）宽容所以金标准验证没暴露 | `CENCDecryptor.sanitizeForAVPlayer`：解密后原地 4CC 替换 `encv/enca→frma 原格式(hvc1/mp4a)`、`sinf/senc/saiz/saio→free`；**不动任何字节位置**，stco 无需修正。验证：38 字节改动、长度不变（`exp_scripts/verify_sanitize.py`） |
| 14 | resolve 并发竞态（冷启动 prepare 双触发） | 同 vid 并发 resolve 两次：重复下载解密 15MB、孤儿 AVPlayer/PlaybackProxy 泄漏、failed/ready 双日志 | `PlaybackEngine.inflightResolves` 同 vid 共享任务 + `PlayerManager.acquire` 的 `acquiring` 防重入 |
| 15 | 循环播放通知名 typo | `"AVPlayerItemDidPlayToEnd"` 少了 `Time` → 播完循环永不触发 | 改为 `"AVPlayerItemDidPlayToEndTime"` |
| 16 | **v22 遥控交互全灭事故**（真机反馈：上下切剧/左右切集/中键详情全部失效） | v22 误设 `PlayerCell.canBecomeFocused=false` + 自造 UIFocusGuide/代理方案：①杀掉了**本来就在工作**的"cell 焦点移动 → collection 自动滚动"上下切剧机制；②代理在 SwiftUI 环境里没真正拿到焦点，两头条路全断 | **教训：改交互前先确认现有机制怎么工作的**。正确模型：上下=cell 保持可聚焦（焦点引擎翻页）；左右=横向无可聚焦目标 → 焦点引擎放弃 → 方向键**回落到 pressesBegan**（用 `press.type`）；中键=直达 responder 链 |

**调试基建**：`Scripts/log_server.py`（Bonjour `_hgtvlog._tcp`，TCP 51820/51821），ATV 端日志经 LAN 回传开发机 `hgtv-logs/received.jsonl`。v16 起播放链路全步骤打点（取流/下载/密钥/解密/代理 Range/AVPlayer 状态/首帧/cell 尺寸），是定位黑屏的关键。

---

## 六、未来方向

1. **真机验证出画面**（当前 v17 待验证）：确认 readyToPlay 补 play 后视频真播出、铺满全屏、上下切换流畅。这是当前唯一阻塞项。
2. **剧集列表打通**：`series_id → 剧集`，但 `video_detail/v1` 服务端恒返 200+0 字节（疑风控）。需逆向原 APK 正确的取集数请求（可能要不同签名/参数/header，或换端点），才能做"选集"。
3. **填充其余 tab**：分类、搜索、我的。搜索已有自建中转 unsigned 分支（`HTTPClient.swift:108-125`）。
4. **x-medusa 严格性确认**：Swift 的 medusa 比 `signer.py` 少 body-md5 + selector 分支（播放可用）。若某些接口校验严格，需补全。
5. **device_register 真实化**：当前 device_id/iid 硬编码真机值。长期应让运行时注册产出新身份（当前注册是占位实现）。
6. **播放体验**：预加载窗口（±2 已有）、看门狗（防黑屏/卡住自动恢复，参考 DYTV 文档 §二.7）、循环播放已装、手势/焦点优化。
7. **风险**：项目完成后会转闭源，**CI 严禁加 GitHub Release**（只出 unsigned artifact）。

---

## 七、关键文件索引

| 领域 | 文件 |
|---|---|
| 签名 | `Sources/HGTVCore/Signing/XGorgon.swift`、`XArgus.swift`、`CryptoPrimitives.swift`（SM3/customHash/le32）、`SignInterceptor.swift`、`CommonParams.swift` |
| 配置 | `Sources/HGTVCore/API/HGTVConfig.swift`（域名/aid/UA/路径） |
| 数据 | `Sources/HGTVCore/API/APIService.swift`（feed/取流/解析）、`Network/HTTPClient.swift` |
| 解密 | `Sources/HGTVCore/Playback/SpadeKey.swift`、`CENCDecryptor.swift`、`AESECB.swift`（纯 Swift AES）、`PlaybackProxy.swift`、`Gzip.swift` |
| 播放 UI | `Sources/HGTVApp/Player/`：`PlaybackEngine.swift`、`PlayerManager.swift`（池 ±2）、`DYPlayerViewController.swift`（分页/snap/遥控）、`PlayerCell.swift`（AVPlayerLayer 铺满）、`NativePlayerView.swift` |
| 推荐页 | `Sources/HGTVApp/Views/RecommendView.swift`（ZStack + overlay）、`RootTabView.swift`（tab 结构） |
| CI | `.github/workflows/build-tvos.yml`、`Scripts/build_ipa.sh`、`Scripts/stamp_version.sh`、`VERSION` |
| Python 金标准 | `/root/workspace/gorgon_py/`（signer.py / spade.py / cenc_decrypt.py / playback_client.py / sm3.py） |

**铁律**：数据层（签名/取流/解密）照抄原 APK，严禁造轮子。项目完成后转闭源，CI 不加 Release。

---

## 八、最新进展（v32-v36，2026-11-19）

### 8.1 弹幕功能 —— ❌ 已搁置（数据源门控）
详细排查全记录见 **[DANMAKU_INVESTIGATION.md](./DANMAKU_INVESTIGATION.md)**。

- **状态**：UI 层完整（渲染/开关/诊断代码保留），数据层返回空。等可用数据源再接。
- **根因**：commentapi 接口对当前设备身份返回 **110001 门控**，与 video_detail/v1、landpage 同类风控。
- **已穷尽**：body 逐字段对反编译、group_id/book_id 各组合、编码、所有 header 变体、6 个 host、5+ vid、R3.a Redmi 设备身份、完整签名（medusa+gorgon）——**全部 110001**。
- **决定性对照**：playback 同 vid 同身份成功取流，commentapi 失败 → 设备身份/token/网络/签名器全有效，纯接口门控。
- **搁置原因**：穷尽客户端可复刻变量无法绕过，继续攻性价比极低。
- **未来方向**：真实 device_register / 真实登录态 / Frida hook 原版运行时 / 其他数据源。

### 8.2 推荐流重复 —— ⚠️ 接口内容池限制（非 bug）
- **现象**：每次进去刷到重复内容多。
- **根因（定量实测）**：`bookmall/tab/v` 内容池小 + 随机采样 + 无翻页：
  - 单 tab 连续 30 次请求去重仅 **23 条**（第 15 次 plateau 不再增长）
  - 3 短剧 tab（8/38/32）总池 **~50 条**
  - `has_more` 恒 false，回传 session_id/offset/cursor 全部无效（原 app 也无效）
- **不是没接入官方池**：bookmall/tab/v 就是官方唯一 feed 接口（原 app 同款，反编译+抓包确认无独立 /recommend 端点）。原 app 用同接口，单次会话内也重复。
- **池随时间变化**：跨会话累积了 155 个唯一 vid（服务端定期更新内容）。
- **优化空间**：load() 首批可从 6 次增加到 12-18 次（3 tab × 4-6），把单次会话可累积池从 ~30 条提到 ~50 条上限。**未实施**。

### 8.3 图标 —— ✅ 已修复（v36）
- **根因**：project.yml 把 Assets.xcassets 放进 `buildPhase: none` 的 folder 引用，**从未参与编译**（v35 仅 482KB、无 Assets.car）。
- **修复**：HGTV target 单独注册 `- path: tvOS/Assets.xcassets`。
- **v36 = 7.18MB**，诊断三查全过（Assets.car 进包 + Info.plist 图标键 + actool 零 document.errors）。诊断脚本 `exp_scripts/diag_icons.py`。

### 8.4 软件名
- CFBundleDisplayName 已改为 **NbeeSt**（v35 起）。

---

## 九、v37（2026-11-20）—— V5 签名 + landpage 分页 + 弹幕接通

> 原软件=开源客户端 com.hgtv.star，作者在 GitHub 推了 1.3.7.7/1.3.8 完整源码（含 `android/core/.../crypto/` 签名模块），逆向路线作废、直接按源码移植。详见记忆 `hgtv-tvos-original-client-selfheal`。

### 9.1 V5 签名器接入（替换旧 XGorgon 4001）
- `Signing/V5/`（5 文件，从 1.3.7.7 Kotlin crypto/ 移植）：`HCSignerV5.sign()` 产出官方 **gorgonAligned（`8404`+rnd+`0081`+raw）** / **medusa v5（有状态）** / helios(license 646637794) / ladon(4B 随机) / argus(le32(ts))。
- `SignInterceptor` 切到 V5：内容签名走 `HCSignerV5`，`device_register` 仍走旧 `RequestSigner`（body 是 ttEncrypt，签名头由 DeviceRegistrar 单独拼）。
- 官方渠道 `channel=69310258a`（抓包实锤）。
- **版本分族**（抓包实锤）：`appFamily=true` → 72232/7.2.2.32（搜索/弹幕/账号族）；默认 → 74332/7.4.3.32（视频/landpage 族）。经 `HTTPTarget.appFamily` 穿透到 `intercept`。

### 9.2 推荐流换 landpage 分页（根治重复）
- 弃 `bookmall/tab/v`（无翻页、池~50条=重复根因），改官方 `POST /reading/distribution/category/landpage/v/`：`offset/limit=100/session_id/req_type(default|only_content)` 真分页 + 服务端 session 个性化去重 + 客户端 vid merge。
- `PlaybackEngine.load/loadMore` 改用 `fetchLandpage(offset:sessionId:)`，游标 `feedOffset/feedSessionId/feedExhausted`。
- ⏳ 曝光上报（recommend_stat/report）端点在 config 但**未接**（`apktool_work/build` 抓包 body 已丢失，待补）。

### 9.3 弹幕走 app 版本族
- `fetchDanmakuWindow` 按真机抓包校正：`playlet_item_duration` 恒 **0**（非视频时长）、`server_channel=1000`、走 `appFamily=true`（72232）。
- ⚠️ 数据是否真通仍待**真机**验证（IP 信誉门控：家里 WiFi IP 被标记，流量干净）。

### 9.4 V5 移植的编译坑（CI 逐个炸出来，最终全清）
| 坑 | 修法 |
|---|---|
| `structHCMedusaIdentity` 关键字粘连 | 补空格 |
| `map { [...] }, 7` 闭包-元组解析歧义 | 闭包结果提为局部 `let` 再 return |
| Int64 `.rotateLeft/.rotateRight`（Swift stdlib 无 rotate，在 swift-numerics） | 全部改用移位实现的 `krotl32/kror32/krotl64/kror64/hcRol/hcRor` |
| Int32 字面量溢出（>2^31 的 hex/decimal） | 包 `Int32(bitPattern:)` |
| `random` 属性遮蔽 Swift 全局 `random()` + 属性未赋值 | 属性改名 `rnd` + init 里补 `self.clock/self.rnd` 赋值 |
| `process` 指针字段放错 struct | 移到 `HCMedusaProcessState` |
| Danmaku `pool` @MainActor 被非隔离 lazy init 读 | `MainActor.assumeIsolated { }` |
| `data += body`（Optional） | `data += (body ?? [])` |

**交付**：CI run 44610636621 ✅ success → `HGTV-tvOS-v37-unsigned.ipa`（7.2MB，Assets.car 在包）。数据层是否真通（landpage 去重效果 / 弹幕 110001 是否解除）待**真机**旁加载验证。


---

## 十、v37→v60 landpage 攻坚全记录（2026-11-20 ~ 11-22）—— 坑、方法、结论、未来路线

> 目标：推荐流接入**正确池子** = `POST /reading/distribution/category/landpage/v/`（原版推荐流，真分页 + session 去重，无限刷不重复）。
> 现状：**客户端所有可对齐的变量已全部对齐抓包 ground truth，landpage 仍返 200+0 字节**（跨 6+ 身份、4 主机层级、两版签名器）。这份记录写给下一个接手的人。

### 10.1 已解决（这轮的真实成果，不要重做）

| 成果 | 验证方式 |
|---|---|
| ✅ V5 签名器从秒崩到完全可用 | bookmall+V5 = 200/66KB 真实数据（服务端认可签名） |
| ✅ 真实 device_register 移植 | PC(new_user=1, device_id=2970193670715852) + tvOS(v52, device_id=3568328001198260) 双实测成功，store-region=cn-zj cookie 到手 |
| ✅ landpage 请求参数全对齐 | body 逐字节一致(195B)、73532 版本族+channel=69310258a、sinfonlineb 层级、全身份档案参数（openudid-source/profile-format/mcc_mnc/rom/apk_first_install_time）、去 install_id |
| ✅ 身份指纹一致性 | 注册 payload / 持久化凭证 / query 三处同组 cdid/openudid/clientudid |
| ✅ 重启凭证恢复 | 完整身份持久化(HGTV.identity.credentials) + init 恢复注入（旧版 skip 注册导致回退旧硬编码身份的 bug 已修） |
| ✅ 身份自愈机制 | 原版"被拒→rebuilding→换新身份"已移植：预置池→新注册轮换 |
| ✅ 无兜底纯净测试模式 | bookmall 兜底已删（用户要求），失败即报错 |

### 10.2 踩过的坑（按代价排序）

| # | 坑 | 细节 |
|---|---|---|
| 1 | **Kotlin→Swift 语言语义暗坑**（比算法难得多） | `UInt32(负数)` 是 checked 转换直接秒崩（Kotlin rotateLeft 负移位合法）；Swift stdlib 无 rotate（在 swift-numerics）；`UInt8 >> ≥8` 越界；Int64 无 rotateLeft/Right。修法=全部移位实现 + `UInt32(bitPattern:n)&31` |
| 2 | **无 dSYM 读 .ips 定位** | 看 faultingThread 的 queue（后台 Task=签名/网络）、exception.type（SIGTRAP=主动 trap）、寄存器 `type metadata for X`（运行时构造含 X 的错误信息）、strings 对号 fatalError 文案 |
| 3 | **崩溃安全面包屑**（定位利器） | 崩溃发生在日志通道连接前 → 面包屑写 UserDefaults（synchronize 存活）→ 下次启动**同步检测到面包屑则禁用 V5**（防再崩）→ flush 出来。⚠️ 检测必须在 App.init **同步**执行，放异步 Task 会输给崩溃竞态 |
| 4 | **V5 移植抄表抄丢字节** | hcMedusaTable64SubstitutionSeed 255/256（index 136 的 165 丢了+4 个负号抄错）→ 越界崩+签名错。**移植常量表必须程序化 diff 验证** |
| 5 | **凭证重启不恢复** | ensureRegistered 见"已注册"就 skip，从不注入拦截器凭证 → 重启后所有请求回退旧硬编码身份。修=身份全字段持久化 + init 恢复 + skip 条件加"凭证存在" |
| 6 | **身份三元组三处不同源** | 注册 payload 随机一组 cdid/openudid/clientudid，Identity 返回另一组，query 又用第三组（CommonParams 硬编码）→ 指纹不匹配。修=payload 返回三元组，全程同源 |
| 7 | **沙箱路径漂移** | apktool_work/build、kotlin_ref 等目录"时有时无"——**数据一直都在**。先怀疑工具再怀疑数据 |
| 8 | **日志服务器进程死亡+写缓冲** | received.jsonl mtime 停滞 ≠ 没日志，可能是进程死了或 Python 写缓冲未落盘。重启用 `python -u` 无缓冲 |
| 9 | **盲试参数对静默服务器性价比极低** | 服务端拒绝无任何错误信息（200+0B 或 device_id=0），盲改一个字段猜一次 = 每轮 20-30 分钟构建+用户手装。**必须先拿到 headers 级抓包再改** |
| 10 | **保底模式污染测试信号** | bookmall 兜底让"landpage 是否通了"无法从 UI 判断（用户测试看到的永远是旧池子内容）。已按用户要求删除 |

### 10.3 试过的方法清单（landpage 0 字节攻坚，全部失败）

| # | 方法 | 结果 |
|---|---|---|
| 1 | 主机层级 lf → sinfonlineb/a/c 轮换 | 全 0B（lf 本就不服务 landpage；sinfonline 层也 0B） |
| 2 | 73532 版本族 + channel=69310258a（抓包实锤） | 0B |
| 3 | 真实注册新身份（PC+tvOS 双实测 new_user=1） | 0B |
| 4 | 身份指纹一致性（同组 cdid/openudid/clientudid） | 0B |
| 5 | 重启凭证恢复（不再回退旧硬编码身份） | 0B |
| 6 | 抓包 #2 全套差缺参数 + 去 install_id | 0B |
| 7 | 预置长龄身份（会话镜像 1290207924645523，WiFi 下出过内容）| 0B |
| 8 | 预置抓包全身份（1642051663562816，流量下 landpage 成功）| 0B |
| 9 | 身份自愈轮换（最多 4 个身份/次启动） | 0B |
| 10 | 对照：bookmall+V5 同网络同签名 | **正常 66KB** → 排除签名/网络路径整体故障 |

### 10.4 关键对照事实（推理的基石）

1. 原版 landpage 成功抓包（00:38-00:40，3 条）全部在手机**流量**网络
2. 原版 app 在本 WiFi（11-20 00:15）："只有标题封面、视频放不出"——**用户理解为内容能刷**；但未在 WiFi 下抓过原版包，**无法确认它当时用的是哪个接口**
3. bookmall（低敏感目录）在本 WiFi 正常；真实注册在本 WiFi 正常 → IP 没有全烧
4. 我们与抓包成功请求的差异已收敛到：**HTTP headers 全集**（抓包只 dump 了 URL/QRY/BODY，**headers 从未抓到**——x-tt-token/Cookie 全集/Accept-Language 等可能存在差异）和**出口 IP**
5. 会话镜像身份 token 151 位 vs 新注册 125 位——token 类型/版本可能不同（passport 匿名 token vs 设备 token？），未深究

### 10.5 未来解决路线（按性价比排序）

1. **【最高优先·缺口唯一】抓原版 landpage 的完整 headers**
   - 现有注入只 dump URL/QRY/BODY。用 LSPosed/HookBridge（手机上已有框架，logcat 里可见 `p.tzFVBSwRiuBeNxMbglhudvCxQI.dY.XP.HookBridge`）写一个 OkHttp 拦截器模块 dump 全 headers；或用 HttpCanary/Charles 证书装到手机抓 HTTPS
   - 拿到后与我们的 headers 逐项 diff——这是唯一没排除的变量
2. **【2 分钟判据】热点测试**
   - ATV 连手机热点跑 v60：通了 = IP 门控实锤（给 ATV 配代理/常驻热点即解决）；不通 = 彻底排除 IP，聚焦 headers
   - 注意：如果走这条路，v60 已无兜底，结果信号干净
3. **【身份信任假说】养身份**
   - 注册后不立即请求：先发 recommend_stat/report 曝光上报（端点已在 config）+ 等待 10-30 分钟 + 模拟正常启动节奏，再请求 landpage。原版身份有历史积累，新身份零历史可能被风险系统扣内容
4. **【token 深究】**
   - 会话镜像 token 151 位 vs 新注册 125 位：确认是否 x-tt-token 格式（带 expiry 前缀 `AAATT`...）——若是 passport token，我们可能一直发错了 token 类型
5. **【模拟器对照】**
   - PC 安卓模拟器 + 原版 1.3.8.6 + mitmproxy：既能抓全 headers，又能直接看 WiFi 下原版行为（feed 到底空不空、用什么接口）
6. **【数据面备选】**
   - 若 landpage 最终无解：bookmall 池扩展（探 tab 5/2/9/11/12）、红果 web 通路（选集已通）、或接受 bookmall+定期换身份降低重复感

### 10.6 本轮新增的基础设施（复用价值）

- `Signing/V5/` 完整可用（1.3.7.7 Kotlin crypto 移植，签名服务端认可）
- `RealDeviceRegister.swift` 真实注册 + 预置身份池（会话镜像/抓包身份已内嵌）
- `DeviceRegisterService.applyPresetIdentity/reregister` 多身份切换
- `exp_scripts/register_v2_rebuild.py`（Python 注册复刻）、`verify_gorgon_fix.py`（gorgon 对拍）、`diff_all_tables.py`（常量表全量 diff）
- `kotlin_ref/`（1.3.7.7 Kotlin crypto 全量拷贝）、`apk_new/jadx_out/`（1.3.8.6 反编译）、`apktool_work/build/capture_now.txt`（真机抓包 135k 行）
- 崩溃安全面包屑 `V5CrashBreadcrumbs`（UserDefaults 存活 + 启动 flush + 同步禁用开关）

## 十一、v60→v62 勘误与新证据（2026-11-22）—— 重新挖矿已有捕获的产物

> 本节是对 §十 部分结论的**修正**。起因：用户要求继续深挖 + 给 APK 加响应日志。
> 深挖发现 §十 的几个"事实"是从不完整的捕获里错误推断的。

### 11.1 勘误（§十 的三处错误）

| §十 说法 | 实际情况 |
|---|---|
| "headers 从未抓到（唯一缺口）" | ❌ `apktool_work/build/hdr_capture.txt`（11-20 01:07，2.6MB）**有原版 landpage/bookmall 请求的完整请求头**（B/Z.u 注入把每层 Headers.add 都 dump 了）。当时漏挖了 |
| "原版 landpage 成功抓包全部在手机流量网络" | ❌ 所有捕获（capture_now/sign_capture/hdr_capture）的 landpage 全部 `ac=wifi`。"成功"也没有任何响应证据 —— 三个捕获文件**没有一条响应记录**，成功与否当时只能靠 UI 观察推断 |
| "6+ 身份 4 主机层级全试过"（暗示原版 app 在 WiFi 正常） | ❌ 原版 app 在本 WiFi **同样被门控**（见 11.2 重试证据） |

### 11.2 本轮挖出的新事实（对拍基石）

1. **原版 app 在本 WiFi 播放接口全线失败**：01:07 会话（hdr_capture）`/novel/player/multi_video_model/player/v1` **同一请求体（gzip 字节完全相同）在全部 12 个主机（api5/api3 × lf/lq/hl/sinfonlinea/b/c）上各重试 8-9 次（99 次/17 秒）**。00:38 会话（capture_now）693 次 MVM、21 个不同视频、每个都在 12 主机全部失败。landpage 反复 offset=0 重拉。
   - ⚠️ 判读方法：MVM ~6 次/秒 = feed 正常预取节奏（**不是**风暴）；**相同字节跨主机轮换** = 失败重试。
2. **IP 与 TLS 双双排除**（作为普适门控）：同一 WiFi 下，tvOS 的 URLSession + 老硬编码身份 `multi_video_model/v1/`（旧路径变体）866 次全部返回 18-27KB 真实数据；bookmall/tab 200/66KB。URLSession TLS + 本 IP 能过敏感接口 → 门控是**接口变体 × 身份信任 × 客户端指纹**的组合，不是网络层。
3. **接口变体分层**：旧变体 `/novel/player/multi_video_model/v1/`（tvOS 在用）不受门控；新变体 `/player/v1`（原版在用）+ landpage 受门控。
4. **身份信任分层**：新注册身份在原版 app 上也失败（1905892595378490，836 次失败）；长龄身份 1642051663562816 在原版 app 上出过内容（00:38-40），但被 v57-v60 + 原版镜像测试反复打烧（01:07 再用时已全主机失败）。
5. **v60 landpage 与原版的 7 处 headers 差异**（hdr_capture 01:07 逐项对比，已在 v62 全部修复）：
   ① UA 多了 `Cronet/TTNetVersion...` 后缀（原版 app API 请求一律不带，只有 tnc get_domains 带 —— 之前把 tnc 的 UA 错当成了 API UA）
   ② 多发 `x-tt-token`（device_token 只在 query；x-tt-token 是登录会话头）
   ③ 多发 `X-HGTV-Anonymous`（值还是 cdid，语义也不对）
   ④ 多发 `x-tt-trace-id`
   ⑤ Cookie 只有 store-region（原版 = install_id + store-region + ttreq + store-region-src）
   ⑥ 缺 `X-Tt-Store-Region` / `X-Tt-Store-Region-Src` 头（TTNet 传输层注入）
   ⑦ query 多了 `store_region=cn-zj`（该值走 Cookie/头，不进 query）
6. **路径漂移之谜破案**：bash 的 `/c/xxx` 实际是 `C:\Program Files\Git\c\xxx`（MSYS `/` 挂载在 Git 安装目录），真实 C 盘要用 `/cygdrive/c/` 或 `C:\` 反斜杠路径。apktool_work 全套数据在 `C:\Program Files\Git\c\apktool_work\`，一直都在。

### 11.3 本轮交付

| 交付物 | 内容 |
|---|---|
| **v62**（CI 构建，commit d0b488e） | 上述 7 处 headers 差异逐项对齐（SignInterceptor + HCSignerV5.uaCronet 参数 + DeviceRegisterService cookie 补全）。v62 已无兜底，landpage 通/不通信号干净 |
| **fgtv-v2-resplog-signed.apk**（工作区根目录） | 原版 APK + 响应日志注入 v2：F0/h3.f（所有接口响应汇聚点）注入 RSTAT（状态码+URL）/RREQH（最终请求头）/RRESPH（响应头）/RBODY+RPART（响应体分块）/REX（异常）五类标记。响应是历代捕获从未有过的数据。抓取说明见 `fgtv-v2-真机抓取说明.md` |
| `hgtv-analysis/orig_landpage_headers.json` | 原版 landpage 完整请求头 JSON（01:07 会话） |

### 11.4 下一步判读树

1. **v62 真机（ATV，WiFi）**：landpage 若出内容 → 7 处 headers 里至少一处是门控点，收官。
2. v62 仍 0B → **fgtv-v2 装手机抓两轮**（WiFi + 流量）：
   - 手机上 landpage `RBODY len=0`（WiFi）+ 流量下有数据 → 出口 IP 门控实锤 → ATV 走热点/代理。
   - 手机上流量下也 0B → 身份全烧 → 看身份自愈换新身份后是否恢复（养身份假说），或对比 RREQH 找剩余差异。
   - 手机上 MVM `/player/v1` 的结果同样按此树判读（TVOS 不用它，但它是原版 app 能否播的直接证据）。
3. **任何新抓的响应头 RRESPH 都要看**：风控网关常在响应头留标记（x-tt-logid / set-cookie 清空 / server 特征），这是定位拒绝原因的唯一直接线索。
