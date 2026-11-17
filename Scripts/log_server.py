#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HGTV tvOS 日志诊断接收端（开发机）。

作用：
  在开发机上起一个 TCP 服务监听某端口（默认 51820），并用 zeroconf 把自己注册成
  Bonjour/mDNS 服务 `_hgtvlog._tcp.local.`，这样真机 App 端（HGTVCore/Diagnostics）
  能通过 Bonjour 自动发现本机地址，建立 TCP 长连接把运行日志一行行 JSON 推过来。
  收到一行就带时间戳 + 来源 IP 打印到终端，便于定位签名层（x-gorgon/x-argus）导致的数据获取失败。

依赖：
  pip install zeroconf

运行：
  python3 Scripts/log_server.py            # 默认监听 0.0.0.0:51820
  python3 Scripts/log_server.py --port 51820 --name "HGTV-Log-MacBook"

防火墙（放行入站 TCP 51820 + UDP 5353 mDNS）：
  macOS:   系统设置 > 网络 > 防火墙 > 选项，允许 python3，或
           sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add python3 --unblockapp python3
  Linux:   sudo ufw allow 51820/tcp && sudo ufw allow 5353/udp
  Windows: 首次运行时允许 python 的专用/公用网络入站；或
           netsh advfirewall firewall add rule name="HGTVLog" dir=in action=allow protocol=TCP localport=51820

跨平台：macOS / Linux / Windows 均可（需同一局域网，且 mDNS/组播未被路由器隔离）。
"""

import argparse
import datetime
import socket
import sys
import threading

from zeroconf import IPVersion, NonUniqueNameException, ServiceInfo, Zeroconf

SERVICE_TYPE = "_hgtvlog._tcp.local."
PROP = {"app": "HGTV", "platform": "dev"}


def _pick_service_ip(zc: Zeroconf, server: str) -> str:
    """挑一个本机可用于对外的 IPv4，作为 Bonjour 通告地址。"""
    # server 形如 "MacBook-Pro.local."
    candidates = []
    try:
        infos = socket.getaddrinfo(server.rstrip("."), None, socket.AF_INET, socket.SOCK_STREAM)
        candidates = [i[4][0] for i in infos]
    except OSError:
        pass
    if not candidates:
        # 退而取一个非回环 IPv4
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            candidates = [s.getsockname()[0]]
            s.close()
        except OSError:
            candidates = ["127.0.0.1"]
    return candidates[0]


def handle_client(conn: socket.socket, addr, logfile=None):
    ip = addr[0]
    conn.settimeout(None)
    buf = b""
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", "replace").strip()
                if not text:
                    continue
                ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
                print(f"[{ts}] {ip}  {text}", flush=True)
                # 落盘到固定文件（开发机=这台机器时，便于随时读历史日志）
                if logfile:
                    try:
                        with open(logfile, "a", encoding="utf-8") as f:
                            f.write(f"{datetime.datetime.now().isoformat()}\t{ip}\t{text}\n")
                    except OSError as e:
                        print(f"[warn] 写日志文件失败：{e}", file=sys.stderr, flush=True)
    except OSError as e:
        print(f"[conn] {ip} 连接异常：{e}", file=sys.stderr, flush=True)
    finally:
        print(f"[conn] {ip} 断开", file=sys.stderr, flush=True)
        conn.close()


def serve(host: str, port: int, name: str, logfile=None):
    zc = Zeroconf(ip_version=IPVersion.V4Only)
    server = socket.gethostname()
    if "." not in server:
        server += ".local."
    else:
        server = server.rstrip(".") + "."
    addr = _pick_service_ip(zc, server)

    info = ServiceInfo(
        SERVICE_TYPE,
        f"{name}.{SERVICE_TYPE}",
        addresses=[socket.inet_aton(addr)],
        port=port,
        properties=PROP,
        server=server,
    )
    try:
        zc.register_service(info)
    except NonUniqueNameException:
        print(f"[warn] 服务名 {name} 已被占用，追加后缀重试", file=sys.stderr, flush=True)
        name = f"{name}-{port}"
        info.name = f"{name}.{SERVICE_TYPE}"
        zc.register_service(info)
    print(f"[bonjour] 已注册 {info.name} -> {addr}:{port}", flush=True)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(16)
    print(f"[tcp] 监听 {host}:{port}，等待 App 连接…（Ctrl-C 退出）", flush=True)
    try:
        while True:
            conn, addr = srv.accept()
            print(f"[conn] {addr[0]} 连入", file=sys.stderr, flush=True)
            threading.Thread(target=handle_client, args=(conn, addr, logfile), daemon=True).start()
    except KeyboardInterrupt:
        print("\n[exit] 退出中…", flush=True)
    finally:
        zc.unregister_service(info)
        zc.close()
        srv.close()


def main():
    ap = argparse.ArgumentParser(description="HGTV tvOS 日志诊断接收端")
    ap.add_argument("--host", default="0.0.0.0", help="监听地址，默认 0.0.0.0")
    ap.add_argument("--port", type=int, default=51820, help="监听端口，默认 51820")
    ap.add_argument("--name", default="HGTV-Log-Dev", help="Bonjour 服务实例名")
    ap.add_argument("--logfile", default=None,
                    help="把收到的日志追加写入该文件（开发机=本机时建议设，便于随时读取）。"
                         "例：--logfile /root/workspace/hgtv-logs/received.jsonl")
    args = ap.parse_args()
    if args.logfile:
        import os
        os.makedirs(os.path.dirname(args.logfile) or ".", exist_ok=True)
        print(f"[log] 日志将落盘到 {args.logfile}", flush=True)
    serve(args.host, args.port, args.name, logfile=args.logfile)


if __name__ == "__main__":
    main()
