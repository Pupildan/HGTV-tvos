# `LF0/l0.H` —— x-gorgon 加密主体分步算法

依据：`/root/workspace/decomp/smali/l0.smali.txt` 行 521-1111（**smali 字节码**，非反编译 Java）。
辅助：`l0.F`(456-487)、`l0.G`(488-520)、`l0.I`(1112-1149)、`l0.J`(1150-1308)、`l0.K`(1309-1378)、`l0.L`(1379-1398)、`l0.M`(1399-1407)、`l0.k0`(5389-5399)；`LF0/e1` 的 `E/F/x/n/b0`（`decomp/signing_full.txt` 行 2194/2201/5772/4844/3383）。

## 0. 签名与寄存器映射

```
H([B v26, J v27+v28, J v29+v30, J v31+v32, [B v33, [B v34) -> String
```

| 寄存器 | 含义（按调用上下文推断） | 置信度 |
| --- | --- | --- |
| `v26` | protobuf 序列化结果（`l0.J` 的输出，`Map<Integer,Object>` 里那套字段） | 高 |
| `v27` | 随机 long 种子（H 内部多处 `xor-long` 用它） | 高 |
| `v29` | 时间戳 long（`long-to-int` 后喂给 `e1.E` 造 4 字节） | 中 |
| `v31` | 另一个 long（`e1.F` 造 8 字节） | 中 |
| `v33` | 20 字节 medusa 摘要 | 中 |
| `v34` | URL / 参数字节（`l0.F` 的 data 输入） | 中 |

依赖的 e1 成员：`o`/`p`/`q`/`r`/`s`/`t`（S-box 与排列表，`e1_fields.txt` 只确认了类型，**具体表值未导出**）、`E(int)`=le32、`F(long)`=le64、`x("MD5",bytes)`=MD5、`n(bytes)`=base64。
依赖的外部方法（**已全部解码，均为平凡字节操作，无加密黑盒**）：
- `h1/j.N1([B,[B)[B` = **数组拼接 concat**（`copyOf(a,a.len+b.len)` + `arraycopy(b,0,a,a.len,b.len)`）——非 XOR！
- `h1/j.I1(I,[B,I)[B` = **切片**（`Arrays.copyOfRange(arr, from, to)`，`l1/d.w` 做边界检查）
- `h1/j.H1([B,[B,I,I,I)V` = **arraycopy**（`System.arraycopy(src,srcPos,dst,dstPos,len)`，`sub dstOfs`）
- `l1/d.z(I,I)`+`l1/d.w(d,I)` = Kotlin stdlib 范围/边界检查，非密钥派生。

> ⚠️ 修正：早前笔记把 `N1` 误判为「逐字节 XOR」，字节码证明是 concat。故阶段 A 的
> `N1(v33,v7)` 是把 20B 摘要与 4B ts **拼接**（→24B），`N1(v1,v3)` 再拼回摘要（→44B），
> 不是异或。这改变了阶段 A 产出的长度与后续分组，移植时须按 concat 处理。

## 1. 分步算法

### 阶段 A —— 造初始 key material（行 522-536）
1. `v2 = (int) v29` → `v7 = e1.E(v2)`（4 字节小端）。
2. `v8 = e1.F(v31)`（8 字节小端）。
3. `v1 = N1(v3=v33, v7)` —— 20 字节摘要与 4 字节 ts 异或。
4. `v1 = N1(v1, v3)` —— 再与原摘要异或一次（等价于只异或了 ts 那一遍，第二次是把 ts 撤掉？**待对拍**：两次 N1 参数顺序若为 `(a,b)` 不可交换则语义不同）。
5. `v1 = e1.b0(v1)` —— SM4-like 变长哈希，输出固定 32 字节。这是后续所有轮密钥的来源。

### 阶段 B —— 第一轮 4 字节搅动（行 537-575）
对 `v26`（protobuf 明文）逐字节处理，`v4 = new byte[v26.length]`：
```
for i in 0..<v26.length:
    v15 = v1[(i*4) % 32] & 255                       // key material 取字节
    v14 = (i*4 + 1) % 32
    v11 = v1[v14] & 255
    v13 = v26[i] & 255
    v12 = k0(v13, 4) + v15                            // 8 位循环左移 4 位再加
    v12 = (v12 & 255) ^ 0xFF ^ v11                    // 取反再异或
    v13 = (v26.length - 1 - i)
    v10 = k0((v12 & 255), 3) + v11
    v10 = ((v10 & 255) ^ 0xFF) ^ v15
    v4[v26.length-1-i] = (byte) v10                   // 注意是倒序写入
```
常数：`k0` = `l0.k0`（8 位 rotate-left，量取低 3 位）；`32` = key material 长度；`4`/`3` = rotate 量。

### 阶段 C —— 三段分组混淆（行 576-634）
前置：`v0 = v26.length - 1`，要求 `v0 >= 2`，否则跳到阶段 D。
1. `v9`（=0）、`v0`（=len-1）、`v6`（=len-2）三处：
   ```
   a = v4[0]; b = v4[len-1] ^ v4[len-2]; b = ~b
   v4[0]     = (byte)(a + b)
   a = v4[len-1]; b = v4[len-1] ^ v4[0]; b = ~b ^ 254
   v4[len-1] = (byte)(a + b)
   ```
2. `v5` 从 0 到 `len-3` 步进 2：
   ```
   x = v4[i]; y = v4[i+1] & 255
   y = k0(y, 3) ^ x ^ (i+2) ^ 0xFF
   v4[i] = (byte)(x + y)
   ```
3. 收尾（行 615-634）：
   ```
   v4[len-1] = (byte)(v4[len-1] ^ v4[len-2])
   sum = 0
   for j in 1..<v26.length: sum = (sum + (v4[j]&255)) & 255
   v4[0] = (byte)(v4[0] ^ v4[len-1] + sum)
   ```

### 阶段 D —— 造 4 字节校验头（行 635-680）
1. `v0 = N1(v33, v4)` —— 摘要与阶段 C 输出异或。
2. `v15 = I1(4, v7, 12)` —— 从 ts 字节数组切 `[4,12)` 8 字节。
3. `v1 = medusaHash(v15, seed=0, 7, 3, 11, 5)`（`l0.F`），取低 32 位 `v2 = (int) v1`。
4. `v1 = ByteBuffer.allocate(v2).putInt(v2).array()` —— **长度等于哈希值本身**，内容是该 int 的大端 4 字节（`putInt` 默认 BIG_ENDIAN）。
5. 对 `v0` 做倒序 XOR：`out[i] = (byte)(v0[len-1-i] ^ v1[i % 4])`。

### 阶段 E —— 派生 1 字节 key + 二次哈希（行 669-688）
1. `v1 = medusaHash(v34, seed=0, 11, 5, 7, 3)`，取低 8 位 → `v2[0]`（1 字节数组）。
2. `v1 = N1(v2, v8)`（与 8 字节 ts 异或）→ `N1(v1, v11)`（与阶段 D 输出异或）→ `v2 = I1(4, v7, 12)` → `N1(v1, v2)`。

### 阶段 F —— 选 AES 变体（行 690-761）
1. `len = v1.length`
2. `if len == 11`：`[[I] sbox = new int[8][0]`（每行空数组）+ 计数 7 → `g1/c` 包装。
3. `else if len >= 248`：`sbox = new int[31][i*8]`（行 i 初始化为 `i*8`）+ 计数 31。
4. `else`：抛 `IllegalStateException("unsupported Medusa inner length")`（行 1100-1103）。

然后（行 730-761）对 `v4 = new byte[31]` 每个位置：
```
for idx in 0..<sbox.length:
  for b in 0..<7:
    base = sbox[idx][0] + e1.s[b][0]      // s-box 索引
    byte = v1[base]                        // 取 key material 字节
    shift = (sbox[idx][1] + e1.s[b][1]) & 7
    bit  = (byte >>> shift) & 1
    v4[idx] = (byte)(v4[idx] | (bit << b))
```
即从 key material 里按 `e1.s` 表指定的位抽取 7 位，拼成 31 字节的轮密钥位掩码。

### 阶段 G —— MD5 + 48 字节 key expansion（行 762-874）
1. `v7 = I1(16, v7, 16)` → `e1.x("MD5", v7)`（16 字节摘要）。
2. `v0 = I1(32, v7, 32)` → `e1.x("MD5", v0)`（再 16 字节）。
3. `v15 = new byte[48]`，对 `v7` 每字节：`v15[i] = (byte)(v7[i] ^ (e1.p[i/4] >>> ((i%4)*8) & 255))`。
   `e1.p` 是 `[J`（long 数组），按小端 8 位一组取。
4. 12 轮（`v6` 从 4 到 12，步进 1；行 802-874）：
   - 每轮先把 `v15` 的 4 个字节装进 `v7[4]`：`v7[k] = v15[v6*4 - 4 + k] & 255`（k=0..3）。
   - `v10[0..2] = e1.o[3][0..2]`（S-box 行 3 的前 3 项），`v10[3] = v7[e1.o[3][3]]`。
   - `mask = (v6 == 3) ? 255 : 249`。
   - `t = e1.p[v6] >>> ((v6<<1) & 24)` & mask & 255；`v7[0] = (t ^ v7[0]) & 255`。
   - 12 次扩散（行 856-869）：`v15[v6*4 + i] = (byte)(v7[i] ^ v15[(v6-1)*4*? + i])`（**确切下标待对拍**：`v14 = (v6-4)*4 + i` 在 smali 里被 `mul-int/lit8 v14,v14,4` 改写过，寄存器复用使基址不明）。
5. 轮后 `v6` 最终为 1（行 875）。

### 阶段 H —— AES-CBC 加密主循环（行 875-1019）
1. `iv = new byte[1]{1}`（行 875-879，**只有 1 字节的 IV**，不是标准 16 字节）。
2. `v0 = Arrays.copyOf(v0, v0.length)`（protobuf 明文，行 882-886）。
3. `out = ByteArrayOutputStream(v4.length)`。
4. 每 16 字节块（行 892-1019）：
   ```
   block = new byte[16]
   for i in 0..<16: block[i] = (byte)(v4[off+i] ^ v0[i])     // 明文异或前一密文块
   state = I1(0, v15, 16)                                     // 取 key material 前 16 字节
   G(state, 16, block)                                        // l0.G：S-box 字节替换 + 行移位
   K(16, block)                                               // l0.K：列混淆（e1.o/r 表）
   // 同一块再做一遍 G/K（行 996-1003）：
   state = I1(16, v15, 16); G(state,16,block); K(16,block)
   state = I1(32, v15, 48); G(state,16,block)                 // 第三轮只 G 不 K
   for i in 0..<16: block[i] = (byte)(block[i] ^ v15[i])      // 行 1005-1012
   out.write(block)
   off += 16
   ```

### 阶段 I —— 尾部 S-box 扩散（行 1020-1063）
对 `v1 = Arrays.copyOf(out.toByteArray(), len)` 每字节做 8 位抽取：
```
for idx in 0..<len:
  for b in 0..<8:
    x = e1.t[b][0] + e1.t[b][1]       // 实际 smali: v12 = v9[0]+v9[1]; v13 = v9[2]+v10[1]... 
    shift = x & 7
    bit   = (v0[idx] >>> shift) & 1
    mask  = (1 << b) ^ 0xFF            // 注意这里取反
    v1[idx] = (byte)((v1[idx] & mask) | (bit << b))
```
（行 1050-1057：`shl-int v14, v20, v10` → `xor-int/lit8 v14, -1` → `and-int v13, v14` → `shl-int v9, v10` → `or-int v9, v13`。与阶段 F 的差别是这里 mask 取反，即**清除该位后写入**。）

### 阶段 J —— 组装输出（行 1064-1099）
```
buf = ByteArrayOutputStream()
for i in 0..<5:
    v = longs[i] ^ v27                  // longs = fill-array-data（见 §2）
    buf.write(e1.E((int) v))            // 4 字节小端
buf.write(I1(0, v30, 2))                // v30 = 阶段 G 的 MD5 输出前 2 字节
buf.write((int) v11)                    // 1 字节（v11 = 0）
buf.write(v0.length - v3)               // 1 字节：明文长度减某偏移
buf.write(I1(v3, v0, v0.length - v3))   // protobuf 尾部切片
buf.write(v1)                           // 阶段 I 的扩散结果
return e1.n(buf.toByteArray())          // base64
```

## 2. 已确认常量

### 阶段 J 的 5 个 long（`fill-array-data` 行 1111）
```
0x0000000000000005
0x00000000CA4F4B2D
0x00000000430D7549
0x000000002CAEB53F
0x0000000056CC6D22
```
（小端字节序：`05 00 00 00 00 00 00 00` → 5；`2D 4B 4F CA ...` → 0xCA4F4B2D；依此类推。）

### 阶段 F 的排列表（l0.K 的 `fill-array-data` 行 1378）
```
int[16] = {1, 9, 5, 13, 9, 1, 13, 5, 2, 14, 6, 2, 10, 6, 14, 10}
```

### 各 helper 的确定性语义（已移植）
| 方法 | 语义 |
| --- | --- |
| `l0.L(OutputStream, long)` | 标准 varint：低位 7 位组，非末字节 `| 0x80`，`>>> 7` |
| `l0.M(int)` | GF(2^8) xtime：`v<<1` 后若原 bit7=1 则 `^0x1B`，再 `&255` |
| `l0.k0(int,int)` | 8 位循环左移，rotate 量取低 3 位 |
| `l0.I(Object)` | Long→longValue / Integer·Byte→符号扩展 long，其它抛 |
| `l0.F` | 见 `MedusaSerializer.medusaHash` |
| `l0.J` | 见 `MedusaSerializer.serialize` |
| `e1.E(int)` | 4 字节小端 |
| `e1.F(long)` | 8 字节小端 |
| `e1.x("MD5", bytes)` | 标准 MD5 |
| `e1.n(bytes)` | base64（字母表 `A-Za-z0-9+/`，带 `=` 填充） |

## 3. 待对拍清单（不要假装确定）

1. **`h1/j.N1` 与 `h1/j.I1` 的确切语义**：N1 按上下文是逐字节 XOR（两参数等长？短的那个怎么循环？），I1 是 `Arrays.copyOfRange(from, to)` 还是别的区间语义。这两个类未导出字节码。
2. **`l1/d.z(I,I)` / `l1/d.w(d,I)` / `w1/b{a,b,c}`**：AES 轮密钥派生。阶段 F/H 里反复调用，返回的 `a`（起始索引）、`b`（结束索引）、`c`（步长/剩余）决定 S-box 取值范围，未导出。
3. **`e1.o`/`e1.q`/`e1.r`/`e1.s`/`e1.t` 的表值**：`e1_fields.txt` 只给了类型（`[[I`），没有初始值。阶段 F/G/I 的位抽取与 `l0.G`/`l0.K` 的字节替换全部依赖这些表。
4. **阶段 B/C 里 `v9`/`v13`/`v6` 的初始值**：smali 用 `move/from16` 从高寄存器搬入，部分初值来自方法参数（`v33`/`v34`），映射已在上表标了置信度。
5. **阶段 G 第 4 步 12 轮扩散的下标基址**：`v14 = (v6-4)*4 + i` 经过 `mul-int/lit8` 改写，寄存器复用使基址不明。
6. **阶段 D 第 4 步 `ByteBuffer.allocate(hashValue)`**：分配长度等于哈希值本身（不是 4），若哈希值很大这段会 OOM；是否 smali 寄存器混用导致读错，需抓包验证。
7. **`v27`/`v29`/`v31` 三个 long 参数的实际来源**：调用方 `C3.c` 里对应 `randomLongs[1]` / `ts` / `longState`（见 `SIGNING_NOTES.md` §1.6），但 `C3.c` 调用点的实参顺序未在本次导出范围内。
8. **AES 模式**：阶段 H 是「明文 ^ 前块 → G → K → G → K → G → ^key」的自定义轮函数，不是标准 AES-CBC/ECB；IV 只有 1 字节（值 1），说明**不是块密码的标准用法**，更像流式混淆。轮数固定 3，`l0.K` 里的 16 项排列表与 4 项 `e1.o[3]` 是列混淆的 MixColumns 替代。

## 4. 本次移植范围

`Sources/HGTVCore/Signing/MedusaSerializer.swift`：
- `MedusaField` / `WireType` / `MedusaParams` / `MedusaValue` —— `LF0/w1` schema 描述。
- `serialize(schema:params:)` —— `l0.J` 全部 8 个 wire type 分支。
- `writeVarint64` / `varint(_:)` —— `l0.L`。
- `jlongValue` —— `l0.I`。
- `xtime` —— `l0.M`。
- `rotateLeft8` —— `l0.k0`。
- `medusaHash` / `medusaHash32` —— `l0.F`。

`l0.G` / `l0.H` 主体**未移植**（依赖未导出的 S-box 表值与 `h1/j`、`l1/d` 字节码），只在本文件给出分步说明。抓到一组真实请求头后可按 §3 逐项消歧。
