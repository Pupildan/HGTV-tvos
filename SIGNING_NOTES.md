# HGTV (com.hgtv.star) 签名链路逆向笔记

来源：`/root/workspace/decomp/signing_full.txt`（androguard 反编译导出，7068 行）。
目标：移植到 tvOS/iOS 纯 Swift（`Sources/HGTVCore/Signing/*` + `DeviceRegister.swift` + `SignInterceptor.swift`）。

---

## 0. 总览

请求签名类结构（Kotlin + 混淆后 dex）：

| 类 | 职责 |
| --- | --- |
| `LF0/C3` | 核心签名器。`c(...)` 构造完整请求 + query 重试；`b(...)` 生成 x-medusa；`a(int, byte[])` 自研哈希 |
| `LF0/C1` | 三个静态字节数组 + 操作状态机 `a(z1, int[])` + 设备指纹构造 `b(...)` + CRC64 `c(byte[])` + 小端读 `d(int, byte[])` |
| `LF0/R3` | 公共 query 参数（`a` LinkedHashMap） + UA 构造 `d(...)` + cdid 生成 `b()` |
| `LF0/h3` | query 拼接 / URL 编码 / 网络执行 / 业务参数组装 |
| `LF0/e1` | 庞大的工具类：MD5/SHA-256 常量表（`b/c/d/e/f/g/h/i/j/k`）、le32/le64/be32、base64 `n`/`v`/`y`、变长哈希 `b0` |
| `LF0/v` | 设备指纹持有者（y1 设备、x1 权重、B1 版本常量、u 时间、f[3] 随机 long） |
| `LF0/z1` | 操作状态（int[9] + long 种子 + int 标志位） |
| `LF0/B1` / `LF0/v1` | 版本常量包（B1 含 14 个字段，v1 含 config/longs/strings） |
| `LF0/b` | AccountCredentials（cookie/token/tsSign/deviceId/installId/cdid/openudid/expiresAt/device） |

签名头（每请求）：

- `x-gorgon`：主签名（x-medusa 算法变体）
- `x-medusa`：medusa 分支哈希
- `x-argus`：**Java 层只放 4 字节 le32(ts) 的 base64**（生产环境走 libsgmain 原生）
- `x-ladon`：**4 字节 SecureRandom 的 base64**
- `x-khronos`：`String.valueOf(ts)`（秒）
- `x-helios`：34 轮 Long 混淆 + base64
- `x-ss-req-ticket`：毫秒时间戳
- `sdk-version: 2`、`x-xs-from-web: 0`、`x-tt-request-tag: t=0;n=0`
- `passport-sdk-version`: `6031190`（未登录，无 body）/ `5051452`（登录或带 body）
- 带 body 时附加：`Content-Type: application/json; charset=UTF-8`、`x-vc-bdturing-sdk-version: 4.0.3.cn`、`x-reading-request: <rticket>-<nonce>`、`x-ss-stub: <大写 MD5(body)>`
- 拦截器（`H0/d`）再注入：`Cookie`、`x-ss-dp: 8662`、`x-tt-token`、`X-HGTV-Identity`/`X-HGTV-Anonymous`

UA 模板（R3.d）：

```
com.phoenix.read/%VC% (Linux; U; Android %OS%; zh_CN; %MODEL%; Build/%BUILD%)
com.phoenix.read/%VC% (Linux; U; Android %OS%; zh_CN; %MODEL%; Build/%BUILD%; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)
```

`%VC%`=version_code（`74332`/`72232`）、`%OS%`=os_version（`16`）、`%MODEL%`=device_type（`25053RT47C`）、`%BUILD%`=rom_version（`BP2A.250605.031.A3`）。

---

## 1. X-Gorgon 算法（C3.c + C3.b）

### 1.1 query 重试（C3.c，行 1240-1550）

伪代码：

```
nowMs = System.currentTimeMillis()   // C3.a = z3.i
ts = nowMs / 1000

for attempt in 0..<128:
    rticket = nowMs + attempt
    query = urlencode(params + {ts, _rticket})
    queryBytes = query.getBytes(UTF-8)

    bodyMD5 = body != null ? md5(body) : new byte[16]   // 空 16 字节占位

    h1 = C3.a(C3.a(539167016, queryBytes), bodyMD5)      // 自研哈希双重
    h2 = C3.a(h1, le32(ts))
    if (h2 & 15) % 3 != 0: continue                       // 不满足则重试

    // 命中后构造请求头 ...
```

`C3.a(seed, data)`（行 313-327）：

```java
for i in 0..<data.length:
    if i & 1 != 0:
        p4 = ((((p4 << 12) | (data[i] & 255)) ^ ((p4 >> 7) ^ p4)) ^ -1)
    else:
        p4 = (((p4 << 6) ^ ((p4 >> 4) ^ p4)) ^ (data[i] & 255))
return p4
```

种子 `539167016` 硬编码。Swift 实现 `customHash(seed:data:)`。

### 1.2 x-argus / x-ladon / x-khronos（C3.c 行 1321-1330）

```java
byte[4] ladon = SecureRandom();       x-ladon = base64(ladon)
byte[4] argus = le32(ts);             x-argus = base64(argus)
x-khronos = String.valueOf(ts)
```

⚠️ 这是 Java 兜底路径。生产抓包的 x-argus 长度远大于 8 字符 → 走的是 TTNet 原生 `libsgmain`（native）。**这部分无法从 dex 静态还原**，Swift 里 `XArgus.full(...)` 仅调用 `simple(...)` 占位。

### 1.3 x-ss-stub / x-reading-request（C3.c 行 1532-1534）

```
x-ss-stub = md5(body).base64().uppercase()   // 注意是 base64 后再大写，不是 hex
x-reading-request = "<rticket>-<nonce>"      // nonce = random.double * 2e9 截断为 long
```

⚠️ Swift 实现里 `x-ss-stub` 当前用的是 `md5Hex(body).uppercased()`（hex 大写）——这与 dex 不一致，**待修正**：应改为 `base64Encode(md5(body)).uppercased()`。

### 1.4 x-medusa（C3.b，行 345-1237）

入口：

```java
String url = baseURL + "?" + query
byte[] urlHash = e1.b0(url.getBytes(UTF-8))    // 变长哈希，取前 32 字节
byte[] bodyMD5 = body != null ? md5(body) : new byte[16]

byte[52] input
input[0..32]   = urlHash[0..32]
input[32..48]  = bodyMD5[0..16]
input[48..52]  = le32(ts)

int ts32 = (int) ts     // Java int 截断
int selector = l0.F(input, 539167016, 6, 4, 12, 7) & 15
```

selector 决定走哪条分支：

- **0-7**（`u1.a` 注册的 D1）：MD5 变体。state[4] 来自 `e1.e` rotateLeft(-base)；K 表 `e1.f` rotateLeft(-((i/16)+base+1))；额外 8 字节 `e1.g`；末尾 `e1.h` rotateLeft(-(base+6))。布尔函数：
  - i<16：`((b^c)&d)^c`
  - i<32：`((b^c)&d)^c`
  - i<48：`(b^c)^d`
  - i≥48：`c^(b|(d^0xFFFFFFFF))`
- **8-11**（`u1.b` 注册的 W3）：SHA-256 变体。h 来自 `e1.b` rotateLeft(-base)；K 来自 `e1.c` rotateLeft(-(base+1))；52-56 位置插入 `e1.d[0..4]`。调度/压缩为标准 SHA-256。
- **12-15**（`u1.c` 注册的 M3）：自定义 128 字节块轮函数，用 `e1.k` 10 个 long 常量，128 轮 Feistel + 异或扩散。

输出 32 字节摘要 → 前 16 字节与后 16 字节异或得 16 字节 → 拼 4 字节 `l0.F(digest[0..12], 539100192, 7, 3, 11, 5)` → 20 字节 → 字节 16 |= 4 |= 32 → 若 `B1.o`（长度 > 0 的字符串）非空则字节 19 ^= 1 → base64 → x-medusa。

⚠️ **待确认**：
- `u1.a/b/c` 三个注册表的 selector → 实现类的映射（D1/W3/M3）在 dex 里通过反射/服务发现装载，导出文件未包含。
- base 偏移：`D1.c`/`W3.a`/`M3.a` 这些字段值未导出，rotateLeft 的实际偏移量不明。当前 Swift 用 `ts & 0xFFFFFFFF` 占位。
- `l0.F` 内部实现未导出（签名 `F(byte[], long, int, int, int, int) → int`），selector 计算依赖它。
- 12-15 那条 128 字节块分支的轮函数细节（dex 553-621）寄存器名污染严重（`v3_35`/`v5_47`/`v6_43` 循环复用），当前 Swift 实现直接 fallback 到 SHA-256 变体，**仅结构骨架正确，常量与轮函数待补**。

### 1.5 x-helios（C3.c 行 1444-1498）

```
plain = "<ts>-646637794-8662".getBytes(UTF-8)
padLen = 16 - (plain.length % 16)
buf = plain + fill(padLen, padLen)          // PKCS5-like

seed = le64(body 或 rticket 派生)            // dex 行 1418: random.double * 4751297606875873280 截断
mixer = md5(seed + "8662".getBytes())       // 32 字节
longs[0..2] = 4 个 8 字节从 mixer 读取

v1 = longs[0]; v2 = longs[1]
for i in 0..<34:
    x = (rotateRight64(v2, 8) + v1) ^ i
    longs.append(x)
    v1 = rotateRight64(v1, 61) ^ x
    v2 = x

// 然后对 buf 每 16 字节做 Long 混淆（dex 1474-1495 的 do-while 循环）
output = le64(v1) + le64(v2)
x-helios = base64(output)
```

⚠️ dex 1481-1495 那段 `if (v10_1 >= 34) ... else ...` 的条件判断在反编译输出里顺序错乱，Long 混淆与 longs 数组的实际组合顺序**待确认**。当前 Swift 用简化版（只跑 34 轮然后取 v1/v2），**只结构对，输出不对**。

### 1.6 x-gorgon（C3.c 行 1499 + 拦截器）

Java 层的 x-gorgon 调用 `C3.b(...)`（同 x-medusa 主生成器）+ 参数字典 + `l0.H` 序列化：

```java
v4_94 = new HashMap<Integer, Object>()
v4_94.put(1,  C1.a)                          // 16 字节常量
v4_94.put(2,  5)
v4_94.put(3,  randomLongs[0] & 0xFFFFFFFF)
v4_94.put(4,  "8662")
v4_94.put(5,  deviceID)                       // y1.a
v4_94.put(6,  "646637794")
v4_94.put(7,  "7.4.3.32")
v4_94.put(8,  "v04.10.03-ml-android")
v4_94.put(9,  67764992)
v4_94.put(10, e1.F(detectionFlagBits))        // long
v4_94.put(11, 0)
v4_94.put(12, 0)                              // 占位 ts
v4_94.put(13, medusaDigest20)                 // byte[20]
v4_94.put(14, urlHash[0..6])                  // 6 字节
v4_94.put(15, longs)                          // 5 项 hex config
v4_94.put(16, deviceToken)                    // y1.b
v4_94.put(17, ts32)
v4_94.put(20, "none")
v4_94.put(21, weights[0] & 0xFFFFFFF)         // 268435455 掩码
v4_94.put(22, B1.a)                           // 312
// ... 后续还塞了 detectionTypes JSON、timezone、language 等

byte[] serialized = l0.J(v4_94, A1.a)          // 排序 + 序列化
x-gorgon = l0.H(serialized, ts, randomLongs[1], longState, randomLongs, C1.b)
```

⚠️ **完全待确认**：`l0.J`（排序规则 `A1.a`）和 `l0.H`（序列化 + 加密）的反编译结果被寄存器传播彻底污染（`v3_7`/`v7_14`/`v1_31` 在同一作用域里被反复赋不同类型），无法确定性还原。当前 Swift 的 `gorgonHeader(...)` 仅输出结构正确的占位（`8404` 前缀 + 4 字节头 + ts + rticket），**值不对**。要真正可对拍需要：
1. 补导出 `F0/l0`（含 `F`/`H`/`J`）+ `F0/A1`（Comparator）+ `F0/D1`/`F0/W3`/`F0/M3`（medusa 分支注册表）。
2. 或者直接调起 native `libsgmain.so` 的 `getGorgon`/`getArgus`（这是生产环境实际路径）。

---

## 2. X-Argus / X-Ladon 步骤

### 2.1 Java 层（已确认）

- x-argus = `base64(le32(ts))` —— 4 字节
- x-ladon = `base64(SecureRandom 4 字节)` —— 4 字节
- x-khronos = `String.valueOf(ts)` —— 秒级时间戳字符串

位置：C3.c 行 1321-1330。

### 2.2 生产环境（未确认）

真实客户端 x-argus 是 ~28 字符 base64 → 走 native `libsgmain.so` 的 argus 算法（与抖音同源）。该 .so 在 APK `lib/arm64-v8a/` 下，需要 SoLoader + JNI 调用才能产出正确值。**纯 Swift 无法还原**，除非：
- 把 `libsgmain.so` 打进 tvOS bundle 用 dlopen 调（tvOS 禁止 dlopen 任意 .so，需要越狱或特殊 entitlement）。
- 或逆 .so 的 OLLVM 混淆（工程量极大）。

Swift 里 `XArgus.full(...)` 当前回落到 `simple(...)`，请求能发但 argus 值服务端会校验失败 → **登录/敏感接口会 4xx**，普通浏览接口可能宽容。

---

## 3. 设备注册流程

### 3.1 端点（已确认）

```
POST https://<host>/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1
```

公共 query（R3.a）附加到所有接口：`aid=8662`、`app_name=novelread`、`version_code=74332`、`version_name=7.4.3.32`、`device_platform=android`、`os=android`、`ssmix=a`、`device_type`、`device_brand=Redmi`、`language=zh`、`os_api=36`、`os_version=16`、`resolution=1280*2772`、`dpi=520`、`host_abi=arm64-v8a`、`channel=update_64`、`manifest_version_code=74332`、`update_version_code=74332`、`pv_player=74332`、`dragon_device_type=phone`、`compliance_status=0`、`need_personal_recommend=1`、`player_so_load=1`、`is_android_pad_screen=0`。

未登录时移除 `device_id`/`iid`/`install_id`（R3.c 行 1720-1722）。

### 3.2 请求 body（⚠️ 待确认）

signing_full.txt 里 `device_register` 字符串只在 `e1.S`（响应解析段，行 2920-2947）命中，请求构造类（TTNet `device_register` helper）**未导出**。`DeviceRegister.swift` 的 `buildBody` 是基于公共参数惯例推断的字段集合（app_name/version_code/device_id/iid/os_version/device_type/rom_version/channel/language），**字段名和必填项待补 dex 后校对**。

### 3.3 响应解析（e1.S 行 2919-2947，已确认）

```java
U1.b root = new U1.b(responseBody)            // JSON
String deviceID   = root.p("device_id")
String iid        = root.p("iid")             // = install_id
String deviceToken = root.p("device_token")    // 可空
String klinkEgdi   = root.p("klink_egdi")     // 可空

g0.n({device_id, iid, device_token?, klink_egdi?})   // 写回 device map
g0.p({install_id?, ...})                              // 写回 install map
```

签名链路在 `C3.b` 行 350-382 取 `device_id`/`device_token` 作为 key 缓存设备指纹（`C3.d` HashMap），同一 (device_id, device_token) 只算一次 `C1.b`，之后每次请求只刷新时间种子 `v.a(now)`。

### 3.4 设备指纹缓存（C3.b 行 350-382）

```
key = device_id + "\0" + device_token         // dex 行 370-374：StringBuilder 拼 0 + token
fingerprint = C3.d.get(key)
if fingerprint == null:
    fingerprint = C1.b(device_id, device_token, now)
    fingerprint.a(now)                        // 刷新时间种子
    C3.d.put(key, fingerprint)
else:
    fingerprint.a(now)                        // 每次请求只刷新时间
```

---

## 4. 已确认常量与参数

### 4.1 C1 三个字节数组（dex 行 121-132）

```java
C1.a[16] = {45, 75, 79, -54, 73, 117, 13, 67, 63, -75, -82, 44, 34, 109, -52, 86}
C1.b[32] = {-78, 60, 42, 71, 10, 32, -47, 5, -36, 63, -116, 68, 56, -8, 39, 46,
            -44, 109, 108, -119, -1, -36, -34, -35, 81, 8, 105, -115, 38, -23, 72, -99}
C1.c[64] = {58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
            62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
            57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
            61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7}
```

Swift 里 `C1.a/b/c` 已原样搬运（Java 负数字节转 UInt8：`-54 → 202`、`-75 → 181`、`-82 → 174`、`-52 → 204`、`-78 → 178`、`-47 → 209`、`-36 → 220`、`-116 → 140`、`-8 → 248`、`-44 → 212`、`-119 → 137`、`-1 → 255`、`-34 → 222`、`-35 → 221`、`-115 → 141`、`-23 → 233`、`-99 → 157`）。

### 4.2 CRC64（C1.c 行 260-281）

```
poly = -7661587058870466123L    // Java long 字面量
     = 0x6ADE_74B3_6300_875C    // 二进制补码
init = 0
每字节：idx = (byte ^ crc) & 0xFF
        8 次迭代：idx & 1 ? (idx >> 1) ^ poly : idx >> 1
        crc = (crc >> 8) ^ idx
无最终异或
```

已用于 x-argus 摘要尾、`C1.b` 内部状态。

### 4.3 自研哈希种子（C3.a 行 313-327）

```
seed = 539167016
奇数字节：state = ((state << 12 | b) ^ (state >> 7 ^ state)) ^ -1
偶数字节：state = (state << 6 ^ (state >> 4 ^ state)) ^ b
```

### 4.4 hex 参数字符串（C1.b 行 225-253）

11 个 32 位 hex + 关联值：

| hex | 值 |
| --- | --- |
| `45ca7e170e474edadd7d40972a193ace` | 247235599 |
| `f866b105da86ad7edbaf9846a68fdbab` | 247235596 |
| `593fa435c8460ab2ac0b86b32e28de66` | 7 |
| `04b29480233f4def5c875875b6bdc3b1` | 1 |
| `e98d2f001da5678b39482efbdf5770dc` | 5 |
| `7dc22b2c6a992f0232345df41303f5ea` | 694367 |
| `f0036511a681da731501008a14354fa3` | 0 |
| `73e41d5295b696cc41657fef7bba312e` | 1261494702 |
| `cede084aa3812c79e4614ee74ba582dd` | -780914011 |
| `30c8cb0fcd3ea4c95cfd5170df341924` | -780914011 |
| `167774bf518c11948aa0784351ccf5a9` | 0 |

另有 2 个只在 medusa 参数字典里出现：`fd8d1a41d3c56026d47f1f8ba146eb99 = 983`、`fa4c0a5bbd8dcedf5ee28719c5bb1df1 = ""`。

### 4.5 B1 版本常量（C1.b 行 253）

```
B1(312, 0, 1, pid, 1, [8, 15], 16777216, 16777216, 1904867320, 0, 32251, 3855421825, 1510177550, v1, G0(47))
```

`pid` 来自 `ManagementFactory.getRuntimeMXBean().getName()` 解析（失败则 1）。

### 4.6 medusa 分支常量（e1.b/c/d/e/f/g/h/i/j/k，dex 行 1951-1976）

全部已原样搬运到 `XArgus.swift` 的 `E1` 枚举，注释里标注了 dex 行号。其中：

- `e1.i`（消息字索引）= MD5 标准 π 表变体
- `e1.j`（移位量）= MD5 标准 shifts
- `e1.k`（10 个 long）= 128 字节块轮函数的轮常量（与 SHA-512 K 表前 10 项一致：`0x243F6A8885A308D3...`）

### 4.7 R3 静态资源（行 1626-1629）

```
device_type 候选 = ["23046PNC9C", "24069RA21C"]（R3.b） + "23127PN0CC", "2211133C"（行 1626-1627 局部）
R3.d base64 资源 = "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw=="
```

该 base64 解码后是一段加密的配置 blob（疑为设备指纹权重表 / 风控白名单），`R3.clinit` 行 1629 调用 `e1.v(...)` 解码并缓存，**用途待确认**，Swift 里暂未搬运。

### 4.8 x-helios 字符串常量（C3.c 行 1454）

```
"<ts>-646637794-8662"
```

`646637794` 同时作为 medusa 字段 6、x-gorgon 参数、CRC64 种子（用于 medusa selector 计算前的 `Long.rotateLeft((C1.c("646637794".getBytes()) ^ ts) & 0xFFFFFFFF, 4) ^ 3026372000`）。

---

## 5. 待确认 / 反编译器还原不清

按严重程度排序：

1. **x-gorgon 完全不可用**：`l0.H` / `l0.J` 序列化函数被寄存器传播污染（`v3_7` 在同一方法里既是 `int` 又是 `StringBuilder` 既是 `byte[]`）。Swift 里只输出结构占位，**服务端校验会失败**。要修需要补导出 `F0/l0`、`F0/A1`、`F0/D1`、`F0/W3`、`F0/M3`、`F0/u1`、`F0/l0$WhenMappings` 等类。

2. **x-medusa 基准偏移未导出**：D1.c / W3.a / M3.a 决定 `rotateLeft` 的真实偏移量。当前 Swift 用 `ts & 0xFFFFFFFF` 占位，selector 0-11 的分支结构对但常量偏移错；selector 12-15 的 128 字节块分支直接 fallback 到 SHA-256 变体。

3. **x-argus 走 native libsgmain**：Java 层只是 4 字节兜底。生产环境需要调 .so。

4. **x-helios Long 混淆循环错乱**：dex 1481-1495 的 `if (v10_1 >= 34)` / `while (v10_1 < 34)` 嵌套在反编译输出里条件顺序颠倒，真实混淆流程待确认。当前 Swift 只跑 34 轮，输出不对。

5. **x-ss-stub 编码方式不一致**：dex 是 `base64(md5(body)).uppercase()`，Swift 实现用了 `md5Hex(body).uppercased()`。需改为 `base64Encode(md5(body)).uppercased()`。

6. **设备注册请求 body 字段未确认**：`DeviceRegister.swift` 的 `buildBody` 是推断。需要补导出 TTNet `device_register` helper 类（搜索 `"device_register"` 字符串引用的类）。

7. **R3.b base64 blob 用途未确认**：解码后 1.5KB 加密配置，可能是设备指纹权重或风控白名单。

8. **medusa selector 12-15 的 128 字节块轮函数**：dex 553-621 循环变量 `v3_35`/`v5_47`/`v6_43`/`v10_56` 反复复用，Feistel 结构可辨（4 轮 × 8 字节 + 10 轮密钥异或 + 状态更新），但常量与轮序未确认。

9. **`e1.b0` 变长哈希算法**：结构是 SM3-like（分组 + 0x80 填充 + 64 位长度 + 8×32 位输出），压缩函数用 `e1.o/p/q/r/s/t` 里的 4×256 S-box + 排列表，当前 Swift 用 SHA-256 占位，**输出值不对**。

10. **`v.b` 字段语义**：`F0.v.b = 131`（C1.b 行 217）和 `F0.v.a(long)` 行 7029 的 `v0_0.b = 131` 重复出现，疑为某个固定标志位（设备类型 / SDK 版本号），具体含义待确认。

---

## 6. Swift 文件清单

| 文件 | 内容 | 完整度 |
| --- | --- | --- |
| `Signing/CryptoPrimitives.swift` | MD5 / SHA-256 / CRC64 / le32 / le64 / be32 / 自研哈希 / base64 / 位操作 | ✅ 可对拍 |
| `Signing/XArgus.swift` | x-argus / x-ladon / x-khronos / medusa 分支骨架 / E1 常量表 | ⚠️ 常量全，基准偏移占位 |
| `Signing/DeviceFingerprint.swift` | C1 数组 / 操作状态机 / 设备指纹状态 / 版本常量包 | ⚠️ 结构对，varlenHash 占位 |
| `Signing/CommonParams.swift` | R3 公共 query / UA / cdid 生成 | ✅ 完整 |
| `Signing/XGorgon.swift` | C3.c 签名主流程 + x-gorgon / x-helios / x-medusa 入口 | ⚠️ 流程对，x-gorgon/x-helios 值不对 |
| `DeviceRegister.swift` | 设备注册请求构造 / 响应解析 / 持久化 | ⚠️ body 字段推断 |
| `SignInterceptor.swift` | 等价 H0/d：注入 Cookie / x-ss-dp / x-tt-token / passport-sdk-version / X-HGTV-Identity\|Anonymous | ✅ 完整 |

---

## 7. 后续建议

1. **补导出关键类**：用 androguard 对 `F0/l0.class`、`F0/A1.class`、`F0/D1.class`、`F0/W3.class`、`F0/M3.class`、`F0/u1.class` 跑 `Decompiler`，把 `l0.F`/`l0.H`/`l0.J` 三个函数的 smali（不是 java）也导一份，smali 的寄存器不会撒谎。
2. **对拍测试**：拿到一个真实抓包（URL + query + body + 4 个签名头），用 Swift 单测跑 `intercept(...)`，对比差异定位分支。
3. **native 路径**：如果一定要生产可用，考虑把 `libsgmain.so` 通过 JVMTI/dlopen 在越狱设备上调，或者用 Frida hook 出 `getGorgon`/`getArgus` 的输入输出对作为测试向量，再逆 .so。
4. **x-ss-stub 编码修正**：把 `XGorgon.swift` 行 ~110 的 `md5Hex(body).uppercased()` 改为 `base64Encode(md5(body)).uppercased()`。
