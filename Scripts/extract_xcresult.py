#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_xcresult.py — 从 xcresult.json 提取全部 Swift 编译错误（明文输出）。
CI 失败诊断专用：xcodebuild 管道模式会把 Swift 错误吞进 xcresult（stdout 无明文），
必须用 xcresulttool --legacy 转 JSON 后提取 errorDiagnostics。"""
import json
import os
import sys


def walk(o):
    """兜底：递归找所有含 error: 的诊断文本。"""
    if isinstance(o, dict):
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)
    elif isinstance(o, str) and 'error:' in o.lower():
        print('  [walk]', o[:300])


def main():
    p = 'xcresult.json'
    if not os.path.exists(p):
        print('xcresult.json 不存在')
        return
    d = json.load(open(p, encoding='utf-8'))
    issues = d.get('issues', {})
    errs = issues.get('errorDiagnostics', [])
    print('xcresult errorDiagnostics 条数:', len(errs))
    for e in errs:
        fp = e.get('filePath', '') or ''
        ln = e.get('line', '')
        msg = (e.get('diagnostic', '') or '')[:400]
        print(f'  {fp}:{ln} {msg}')
    if not errs:
        print('errorDiagnostics 为空——递归兜底搜索:')
        walk(d)


if __name__ == '__main__':
    main()