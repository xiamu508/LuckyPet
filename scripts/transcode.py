#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批量转码：黑底 WebM → 带 Alpha 的 HEVC .mov（640×360）

前置：python3 scripts/fetch_assets.py 已把素材下载到 assets_raw/
输出：Assets/clips/
"""
import os, subprocess, sys, json
from concurrent.futures import ThreadPoolExecutor

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 项目根目录
RAW = os.path.join(BASE, 'assets_raw')
OUT = os.path.join(BASE, 'Assets', 'clips')

def convert(task):
    src, dst = task
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return ('skip', src)
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', src,
        '-vf', 'format=rgba,colorkey=0x000000:0.10:0.02',
        '-c:v', 'hevc_videotoolbox',
        '-alpha_quality', '0.50',
        '-tag:v', 'hvc1',
        '-pix_fmt', 'bgra',
        '-q:v', '42',
        '-allow_sw', '1',
        '-an',
        dst
    ]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        return ('fail', src + ' :: ' + r.stderr.decode()[:200])
    return ('ok', src)

def main():
    tasks = []
    for root, _, files in os.walk(RAW):
        for f in files:
            if f.endswith('.webm'):
                src = os.path.join(root, f)
                rel = os.path.relpath(src, RAW).replace('.webm', '.mov')
                tasks.append((src, os.path.join(OUT, rel)))
    tasks.sort()
    print(f'待转码 {len(tasks)} 段', flush=True)
    stat = {'ok': 0, 'skip': 0, 'fail': 0}
    fails = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        for i, (st, msg) in enumerate(ex.map(convert, tasks)):
            stat[st] += 1
            if st == 'fail':
                fails.append(msg)
            if (i + 1) % 20 == 0:
                print(f'  进度 {i+1}/{len(tasks)} {stat}', flush=True)
    print('结果', stat, flush=True)
    for m in fails[:5]:
        print('FAIL', m)
    # 汇总清单
    manifest = []
    for root, _, files in os.walk(OUT):
        for f in sorted(files):
            if f.endswith('.mov'):
                full = os.path.join(root, f)
                manifest.append({
                    'file': os.path.relpath(full, OUT),
                    'size': os.path.getsize(full),
                })
    json.dump(manifest, open(os.path.join(OUT, '..', 'clip_manifest.json'), 'w'),
              ensure_ascii=False, indent=2)
    total = sum(m['size'] for m in manifest)
    print(f'产出 {len(manifest)} 段，合计 {total/1048576:.1f} MB')

if __name__ == '__main__':
    main()
