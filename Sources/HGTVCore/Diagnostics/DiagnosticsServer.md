# DiagnosticsServer — 开发机日志接收端

真机（tvOS App）通过 Bonjour/mDNS 自动发现本机，建立 **TCP 长连接**，把运行日志一行行
JSON（见 `Diagnostics.swift`）推到这里，用于定位签名层（`x-gorgon`/`x-argus` 等占位实现）导致的数据获取失败——能看到真实发出的签名头与服务端响应。

## 1. 依赖

```bash
pip install zeroconf
```

## 2. 运行

```bash
python3 Scripts/log_server.py              # 默认监听 0.0.0.0:51820，服务名 HGTV-Log-Dev
python3 Scripts/log_server.py --port 51820 --name "HGTV-Log-MacBook"
```

启动后会打印两行：

- `[bonjour] 已注册 _hgtvlog._tcp.local. -> <本机IP>:51820`
- `[tcp] 监听 0.0.0.0:51820，等待 App 连接…`

App 端（`TCPTransport`）用 `NWBrowser` 浏览 `_hgtvlog._tcp` 即可发现本机并连上。收到一行日志按
`[时:分:秒.毫秒] <来源IP>  <JSON>` 打印到终端。

跨平台：macOS / Linux / Windows 均可，需与 Apple TV 在**同一局域网**，且路由器未隔离 mDNS 组播。

## 3. 防火墙放行

- **入站 TCP 51820**（日志数据）
- **入站 UDP 5353**（mDNS/Bonjour 组播）

| 系统 | 命令 / 操作 |
| --- | --- |
| macOS | 系统设置 › 网络 › 防火墙 › 选项，允许 `python3`；或 `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add python3 --unblockapp python3` |
| Linux | `sudo ufw allow 51820/tcp && sudo ufw allow 5353/udp` |
| Windows | `netsh advfirewall firewall add rule name="HGTVLog" dir=in action=allow protocol=TCP localport=51820`，mDNS 一般系统已放行 |

## 4. 日志行格式

App 端每条日志封装成一行 JSON（`+ "\n"` 分帧）：

```json
{"ts":"2026-01-01T08:00:00.123Z","level":"info","category":"http","message":"GET …","meta":{"x-gorgon":"…","x-argus":"…"}}
```

字段：`ts`(ISO8601)、`level`(debug/info/warn/error)、`category`、`message`、可选 `meta`（键值对，含全部请求头，便于看签名头）。

## 5. App 端 Info.plist 需要的键（由维护者添加）

tvOS 上局域网发现受本地网络隐私限制，需在 App target 的 `Info.plist` 声明，否则 `NWBrowser` 会失败（代码已优雅重试，不会崩溃，但发现不到开发机）：

- **`NSLocalNetworkUsageDescription`**（String）：说明为何访问本地网络，如 `"回传运行日志到开发机用于诊断"`。
- **`NSBonjourServices`**（Array of String）：声明要浏览的服务类型，需包含
  - `_hgtvlog._tcp`

> 只需这两项。服务类型字符串必须与 `Scripts/log_server.py` 注册的 `_hgtvlog._tcp` 一致。

## 6. 排错

- App 日志出现 `Bonjour 浏览失败（检查本地网络权限）` → 多为 Info.plist 缺上面两个键，或首次弹的本地网络权限被拒。
- 注册成功但连不上 → 检查防火墙 51820，确认两端同网段，路由器未开 AP 隔离。
- 想临时禁用回传 → 不调用 `DiagnosticsLogger.shared.registerTransport(...)` 即可；`os.Logger` 本地输出始终可用（Console.app 过滤 subsystem `com.hgtv.star.tvos`）。
