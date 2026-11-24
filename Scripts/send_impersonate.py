#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""curl-impersonate TLS 指纹验证发送器。

读取 sign_cli 生成的 request.json（url / headers / gzip body_base64），
用所有可用的 curl-impersonate 通道（brew 二进制包装 + curl_cffi）与
chrome 移动/桌面指纹模板逐个发送 landpage，输出 impersonate_result.json。

判定：任一模板 HTTP 200 且响应 > 200B → IMPERSONATE_OK；
全部 0B（或全部失败）→ IMPERSONATE_FAILED（200+0B = TLS 指纹假说被证伪）。
"""
import base64
import glob
import json
import os
import subprocess
import sys
import time

REQ_PATH = "request.json"
CFFI_TARGETS = ("chrome131_android", "chrome131", "chrome124", "chrome116", "chrome99_android")


def parse_hdr(path):
    h = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    h[k.strip()] = v.strip()
    except Exception:
        pass
    return h


def main():
    with open(REQ_PATH, encoding="utf-8") as f:
        req = json.load(f)
    url = req["url"]
    headers = req["headers"]
    body = base64.b64decode(req["body_base64"])
    with open("body.gz", "wb") as f:
        f.write(body)
    host = url.split("/")[2] if "://" in url else url
    print(f"target: https://{host} body_gz={len(body)}B headers={len(headers)}")

    results = []

    def record(sender, template, status, size, resp_path=None, resp_headers=None, note=""):
        results.append({
            "sender": sender, "template": template,
            "status": status, "size": size, "note": note,
            "resp_file": resp_path, "resp_headers": resp_headers or {},
        })
        print(f"[{sender}/{template}] HTTP {status} bytes={size} {note}".rstrip())
        if resp_headers:
            keep = ("x-tt-logid", "server", "content-type", "content-length", "via", "cf-ray")
            hits = {k: v for k, v in resp_headers.items() if k.lower() in keep}
            if hits:
                print(f"    resp headers: {hits}")

    # ── 通道 1：curl-impersonate 官方二进制（brew），curl_chromeXXX 包装逐个探测 ──
    prefix = ""
    try:
        p = subprocess.run(["brew", "--prefix"], capture_output=True, text=True, timeout=60)
        prefix = p.stdout.strip()
    except Exception:
        pass
    wrappers = sorted(os.path.basename(x) for x in glob.glob(os.path.join(prefix, "bin", "curl_chrome*")))
    print(f"curl_chrome wrappers found: {wrappers or '(none)'}")
    cacert = "/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None
    for w in wrappers:
        out, hdr = f"resp_{w}.bin", f"hdr_{w}.txt"
        cmd = [os.path.join(prefix, "bin", w), "-sS", "--max-time", "30", "-X", "POST", url]
        for k, v in headers.items():
            cmd += ["-H", f"{k}: {v}"]
        cmd += ["--data-binary", "@body.gz", "-o", out, "-D", hdr]
        if cacert:
            cmd += ["--cacert", cacert]
        cmd += ["-w", "%{http_code} %{size_download}"]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            line = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
            parts = line.split()
            status = int(parts[0]) if parts and parts[0].isdigit() else 0
            size = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            record("curl-impersonate", w, status, size, out, parse_hdr(hdr),
                   note=p.stderr.strip()[:200])
        except Exception as e:
            record("curl-impersonate", w, 0, 0, note=f"error: {e}")
        time.sleep(1.5)

    # ── 通道 2：curl_cffi（同一 curl-impersonate 库的 Python 绑定，模板新到 chrome131_android）──
    try:
        from curl_cffi import requests as cf
        have_cffi = True
    except ImportError:
        have_cffi = False
        print("curl_cffi not available (pip install curl_cffi)")
    if have_cffi:
        for t in CFFI_TARGETS:
            out = f"resp_cffi_{t}.bin"
            try:
                r = cf.post(url, headers=headers, data=body, impersonate=t, timeout=30)
                with open(out, "wb") as f:
                    f.write(r.content)
                record("curl_cffi", t, r.status_code, len(r.content), out, dict(r.headers))
            except Exception as e:
                record("curl_cffi", t, 0, 0, note=f"error: {e}")
            time.sleep(1.5)

    # ── 判定 ──
    ok = any(r["status"] == 200 and r["size"] > 200 for r in results)
    verdict = "IMPERSONATE_OK" if ok else "IMPERSONATE_FAILED"
    previews = {}
    for r in results:
        if r.get("resp_file") and os.path.exists(r["resp_file"]):
            with open(r["resp_file"], "rb") as f:
                previews[r["resp_file"]] = f.read(400).decode("utf-8", "replace")
    summary = {"url_host": host, "url": url, "verdict": verdict,
               "results": results, "resp_previews": previews}
    with open("impersonate_result.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print("=" * 60)
    print(f"VERDICT: {verdict}")
    for r in results:
        print(f"  {r['sender']}/{r['template']}: HTTP {r['status']} {r['size']}B {r['note']}")
    for name, pv in previews.items():
        print(f"  preview {name}: {pv[:200]!r}")
    sys.exit(0)


if __name__ == "__main__":
    main()