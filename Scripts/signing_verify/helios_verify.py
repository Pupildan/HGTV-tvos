#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
x-helios 还原进度 + 验证器（2026-11-22）。

已确认（smali + kotlin_ref + ATV 向量三重验证）：
  - 结构 = kotlin_ref Signer.kt helios：34 轮队列 Feistel
    （t = (ror64(b,8) + a) ^ i3；a = ror64(a,61) ^ t；b = 队列弹出）
  - 块加密 = table[i] ^ (a + ror64(b,8))；a = b ^ ror64(a,61)；逐 16 字节块
  - 输出 = le32(rand) + 每块 le64(a)+le64(b)；base64
  - 数据 = "ts-646637794-8662" PKCS 风格填充
  - 轮密钥来源（SMALI 实锤 F0/c2.1.smali）：
      bytes2 = M1( e1.x(algstr, concat(le32(rand), "8662".getBytes())), E0/f(mode=1) )
      - e1.x(alg, v) = MessageDigest.getInstance(alg).digest(v) —— 纯 digest 包装
      - E0/f mode=1 渲染 = String.format("%02x", byte & 0xff)（小写 hex）——smali pswitch_1b 实锤
  - ⚠️ Swift 移植 bug：krotl64(b0, 61) 应为 kror64(b0, 61)（rotateRight(…,61)）
    —— kotlin_ref Signer.kt L234-242 实锤；Python 本文件用 ror64 已正确。

未解：e1.x 的 algstr 参数值（v29 寄存器，调用方上下文）——MD5 大小写/SHA-256/SM3 均已试
  皆不匹配手机向量；需 frida hook 或 --show-bad-code 重反编译确认 algstr 与可能的额外变换。

运行本文件：先跑 atv_vector_test（应 True，证明与 Swift 一致），再跑 phone_vector_test
  （当前 False = helios 尚未还原完成）。
"""

import base64
import hashlib
import struct

M = (1 << 64) - 1


def ror64(v: int, n: int) -> int:
    v &= M
    return ((v >> n) | (v << (64 - n))) & M


def rotl64(v: int, n: int) -> int:
    v &= M
    return ((v << n) | (v >> (64 - n))) & M


def helios_v71bug(ts: int, rand: int) -> bytes:
    """Swift v72 现状（rotl61 bug 版）——已验证与 ATV 实发 helios 逐字节一致。"""
    rot = rotl64
    ascii_bytes = hashlib.md5(struct.pack('<I', rand) + b'8662').hexdigest().encode()
    words = [struct.unpack('<Q', ascii_bytes[i * 8:i * 8 + 8])[0] for i in range(4)]
    table = [words[0]]
    b0 = words.pop(0)
    b8 = words.pop(0)
    for i in range(34):
        x8 = ((ror64(b8, 8) + b0) ^ i) & M
        words.append(x8)
        x8 = x8 ^ rot(b0, 61)
        table.append(x8)
        b0 = x8
        b8 = words.pop(0)
    text = ('%d-646637794-8662' % ts).encode()
    pad = 16 - len(text) % 16
    data = text + bytes([pad]) * pad
    out = struct.pack('<I', rand)
    for at in range(0, len(data), 16):
        a = struct.unpack('<Q', data[at:at + 8])[0]
        b = struct.unpack('<Q', data[at + 8:at + 16])[0]
        for i in range(34):
            b = table[i] ^ ((a + ror64(b, 8)) & M)
            a = b ^ rot(a, 61)
        out += struct.pack('<Q', a) + struct.pack('<Q', b)
    return out


def helios_ror_ref(ts: int, rand: int, algstr: str = 'MD5', aid: str = '8662',
                   lic: str = '646637794') -> bytes:
    """ror61 修正版（结构 = kotlin_ref + smali 实锤）。algstr 待定（当前不匹配手机向量）。"""
    ascii_bytes = hashlib.md5(struct.pack('<I', rand) + aid.encode()).hexdigest().encode()
    words = [struct.unpack('<Q', ascii_bytes[i * 8:i * 8 + 8])[0] for i in range(4)]
    table = [words[0]]
    b0 = words.pop(0)
    b8 = words.pop(0)
    for i in range(34):
        x8 = ((ror64(b8, 8) + b0) ^ i) & M
        words.append(x8)
        x8 = x8 ^ ror64(b0, 61)
        table.append(x8)
        b0 = x8
        b8 = words.pop(0)
    text = ('%d-%s-%s' % (ts, lic, aid)).encode()
    pad = 16 - len(text) % 16
    data = text + bytes([pad]) * pad
    out = struct.pack('<I', rand)
    for at in range(0, len(data), 16):
        a = struct.unpack('<Q', data[at:at + 8])[0]
        b = struct.unpack('<Q', data[at + 8:at + 16])[0]
        for i in range(34):
            b = table[i] ^ ((a + ror64(b, 8)) & M)
            a = b ^ ror64(a, 61)
        out += struct.pack('<Q', a) + struct.pack('<Q', b)
    return out


def atv_vector_test() -> bool:
    """ATV( Swift) 实发 helios 复现——True = 本结构与 Swift 一致。"""
    import json
    path = r'C:\HGTV-tvOS-项目资产备份\hgtv-logs\received.jsonl'
    got = None
    for ln in open(path, encoding='utf-8', errors='replace'):
        if 'landpage' in ln and 'h.x-helios' in ln and '→ POST' in ln:
            try:
                d = json.loads(ln.split(chr(9), 2)[-1])
            except Exception:
                continue
            if d.get('ts', '').startswith('2026-11-22T14:25'):
                mm = d.get('meta') or {}
                got = (mm.get('h.x-helios', ''), int(mm.get('h.x-khronos', '0')))
    hv = base64.b64decode(got[0])
    rand = struct.unpack('<I', hv[0:4])[0]
    return helios_v71bug(got[1], rand) == hv


def phone_vector_test() -> bool:
    """手机向量——True = helios 还原完成。"""
    hv = base64.b64decode('dbNniieDhqt6cFWjowFCSt0W35f4zomnAD4k/THPt/FKvSMU')
    rand = struct.unpack('<I', hv[0:4])[0]
    return helios_ror_ref(1795345499, rand) == hv


if __name__ == '__main__':
    print('ATV vector (v71bug impl):', atv_vector_test())
    print('PHONE vector (ror ref)  :', phone_vector_test())
