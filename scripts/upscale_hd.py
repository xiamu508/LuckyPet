#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""可选步骤：把已转码的 640×360 HEVC 动画做 2× 超采样重制（1280×720）。

Retina 屏上桌宠约 216pt 宽 ≈ 432 物理像素，1280 素材属于「缩小显示」，
边缘比 640 素材（放大 1.4×）更锐利。注意这是超采样抗锯齿，不产生新细节。

用法：python3 scripts/upscale_hd.py [每批数量]
可重复运行，进度记录在 .hd_state.json
"""
import os, subprocess, sys, json
from concurrent.futures import ThreadPoolExecutor

STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.hd_state.json')

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 项目根目录
CLIPS = os.path.join(BASE, 'Assets', 'clips')

def convert(src):
    dst = src  # 原地覆盖
    tmp = src + '.hd.tmp.mov'
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', src,
        '-vf', 'scale=1280:720:flags=lanczos,unsharp=5:5:0.30:5:5:0',
        '-c:v', 'hevc_videotoolbox',
        '-alpha_quality', '0.55',
        '-q:v', '45',
        '-tag:v', 'hvc1',
        '-pix_fmt', 'bgra',
        '-allow_sw', '1',
        '-an',
        tmp
    ]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        return ('fail', src, r.stderr.decode()[:150])
    os.replace(tmp, dst)
    return ('ok', src, '')

def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    done = set(json.load(open(STATE))) if os.path.exists(STATE) else set()
    todo = []
    for root, _, files in os.walk(CLIPS):
        for f in sorted(files):
            if f.endswith('.mov'):
                p = os.path.join(root, f)
                if p not in done:
                    todo.append(p)
    print(f'待高清化 {len(todo)} 段', flush=True)
    if not todo:
        print('ALL_DONE'); return
    batch = todo[:limit]
    ok = fail = 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        for st, src, msg in ex.map(convert, batch):
            if st == 'ok':
                ok += 1
                done.add(src)
            else:
                fail += 1
                print('FAIL', os.path.basename(src), msg)
    json.dump(sorted(done), open(STATE, 'w'))
    print(f'本批 ok={ok} fail={fail}，剩余 {len(todo)-len(batch)}', flush=True)
    if len(todo) <= len(batch):
        print('ALL_DONE')

if __name__ == '__main__':
    main()
