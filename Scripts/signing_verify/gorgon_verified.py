#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
真版 x-gorgon（1.3.8.6 jadx H0/J3.e 忠实移植）——已用真机捕获向量逐字节验证 ✓。

验证向量（2026-11-22 手机 landpage 请求，身份 C=3093339275809908）：
  ts=1795348799, rnd16=0x3e3f（从输出 hex[4:8] 小端提取）
  query/body 见 hgtv-analysis/replay_request.json
  期望输出 = 84043f3e0081df5203269567e9a233a6d3361a4f85f3d75e7b47（尾 4B 随机取自捕获）
  ✓ 完全一致（含 4B 随机尾用捕获值时全 30 字节一致）

与旧版（1.3.7.7 移植，25 字节）的差异：
  1. KSA：s[i] = s[j]（覆盖，不交换）
  2. 二次改写：reverse8(swap4(x) ^ nxt) ^ 0xEB（旧版 ^0x14 且套了 reverse）
  3. 框架：[4]=0x00 [5]=0x81（旧版 0x40,1）；总长 30 字节（旧版 25）
"""

import hashlib
import struct


def real_gorgon(ts: int, rnd16: int, query: str, body: bytes | None, tail4: bytes | None = None) -> bytes:
    """ts = x-khronos 秒级时间戳; rnd16 = 16 位随机; tail4 = 末尾 4 随机字节（服务端不校验内容）。"""
    md5q = hashlib.md5(query.encode()).digest()[:4]
    md5b = hashlib.md5(body).digest()[:4] if body else b'\x00' * 4
    j4 = md5q + md5b + b'\x00' * 4 + struct.pack('<I', 67503104) + struct.pack('>I', ts & 0xFFFFFFFF)
    key = [74, 64, 22, (rnd16 >> 8) & 255, 71, 108, 1, rnd16 & 255]
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % 8]) & 255
        s[i] = s[j]                      # 覆盖，不交换（J3.e KSA）
    out = bytearray(len(j4))
    i10 = 0
    for n in range(len(j4)):
        i11 = n + 1
        i10 = (i10 + s[i11]) & 255
        y = s[i10 & 255]
        s[i11] = y
        out[n] = s[(y + y) & 255] ^ (j4[n] & 255)
    length = len(out)
    for i13 in range(length):
        i14 = out[i13] & 255
        i15 = ((i14 << 4) | (i14 >> 4)) & 255
        nxt = out[i13 + 1] & 255 if i13 + 1 < length else out[0] & 255
        rev = int(format((i15 ^ nxt) & 255, '08b')[::-1], 2)
        out[i13] = (rev ^ 0xEB) & 255
    f2 = bytearray(bytes.fromhex('8404') + bytes([rnd16 & 255, (rnd16 >> 8) & 255, 64, 1]) + bytes(out))
    f2[4] = 0x00
    f2[5] = 0x81
    return bytes(f2) + (tail4 if tail4 is not None else b'\x00' * 4)


def self_test():
    import json
    d = json.load(open(r'C:\HGTV-tvOS-项目资产备份\hgtv-analysis\replay_request.json', encoding='utf-8'))
    q = d['url'].split('?', 1)[1]
    hdr = dict(h.split(': ', 1) for h in d['headers'])
    g_hex = hdr['x-gorgon']
    ts = int(hdr['x-khronos'])
    rnd16 = int.from_bytes(bytes.fromhex(g_hex[4:8]), 'little')
    body201 = (b'{"filter_ids":"","req_scene":"default","offset":0,"need_selector_panel":false,'
               b'"limit":100,"select_items":{"genre":[],"sort":["hot_score"]},"session_id":"",'
               b'"req_type":"only_content","client_req_type":3}')
    tail4 = bytes.fromhex(g_hex[52:60])
    mine = real_gorgon(ts, rnd16, q, body201, tail4).hex()
    print('PHONE:', g_hex)
    print('MINE :', mine)
    print('match:', mine == g_hex)


if __name__ == '__main__':
    self_test()
