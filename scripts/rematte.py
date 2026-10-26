#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LuckyPet 素材重制：黑底 → 颜色反混合抠图 → 带 Alpha 的 HEVC。

与旧管线（ffmpeg colorkey）的区别：
  旧：colorkey 直接给 alpha，边缘 RGB 仍是被黑底压暗的观测值 → 黑边毛刺
  新：先由纯黑背景得到确定前景(core)，用邻域 core 色估计真实前景色 F，
      alpha = max_c(C/F)，边缘输出 F 而非 C → 消除黑边污染

用法：
  python3 scripts/rematte.py --src <raw目录> --dst <输出目录> [--limit N]
  python3 scripts/rematte.py --one <单个webm> <输出mov>
"""
import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np

W_SRC, H_SRC = 640, 360
W_OUT, H_OUT = 1280, 720
FG_THRESHOLD = 6.0        # 背景恒为 0，阈值可以极低
MIN_ALPHA_DIV = 4.0       # 防止除零


def _shift_add(dst, src, dy, dx):
    """dst[y,x] += src[y+dy, x+dx]（越界丢弃）"""
    H, W = src.shape[:2]
    ys = slice(max(0, dy), H + min(0, dy))
    yd = slice(max(0, -dy), H - max(0, dy))
    xs = slice(max(0, dx), W + min(0, dx))
    xd = slice(max(0, -dx), W - max(0, dx))
    dst[yd, xd] += src[ys, xs]


def _neighbor_mean(c, mask, k):
    """(2k+1)^2 邻域内 mask 为真的像素均值；返回 (均值, 计数)"""
    H, W = mask.shape
    masked = c * mask[..., None]
    num = np.zeros((H, W, 3), np.float32)
    den = np.zeros((H, W), np.float32)
    m = mask.astype(np.float32)
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            _shift_add(num, masked, dy, dx)
            _shift_add(den, m, dy, dx)
    return num, den


def rematte(rgb):
    """rgb uint8(H,W,3) → rgba uint8(H,W,4)，straight alpha"""
    H, W = rgb.shape[:2]
    c = rgb.astype(np.float32)

    lum = c.max(axis=2)
    fg = lum > FG_THRESHOLD
    if not fg.any():
        return np.zeros((H, W, 4), np.uint8)

    # 4 邻域腐蚀 → 确定前景 core
    core = fg.copy()
    fgf = fg.astype(np.float32)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        nb = np.zeros(fg.shape, np.float32)
        _shift_add(nb, fgf, dy, dx)
        core &= nb > 0.5
    boundary = fg & ~core

    # 邻域核心色：先 3×3，缺口逐级用 5×5 / 7×7 补
    # F 初值取亮值（而非原色），使「找不到核心邻域的孤立暗像素」得到接近 0 的 alpha，
    # 否则这些抗锯齿残留会被当成不透明黑点（上采样后放大成可见碎屑）
    F = np.full_like(c, 255.0)
    assigned = np.zeros((H, W), bool)
    for k in (1, 2, 3):
        num, den = _neighbor_mean(c, core, k)
        need = (den > 0) & ~assigned & boundary
        if need.any():
            F[need] = num[need] / den[need][:, None]
            assigned |= need

    # alpha = max_c(C / F)
    ratio = c / np.maximum(F, MIN_ALPHA_DIV)
    alpha = np.clip(ratio.max(axis=2), 0.0, 1.0)
    alpha[core] = 1.0
    alpha[~fg] = 0.0

    out = np.empty((H, W, 4), np.uint8)
    rgb_out = np.where(boundary[..., None], F, c)
    out[..., :3] = np.clip(rgb_out, 0, 255).astype(np.uint8)
    out[..., 3] = np.rint(alpha * 255).astype(np.uint8)
    return out


def convert(src, dst, q=62, alpha_quality=0.85):
    d = os.path.dirname(dst)
    if d:
        os.makedirs(d, exist_ok=True)
    dec = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-i', src, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
        stdout=subprocess.PIPE)
    enc = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-y',
         '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{W_SRC}x{H_SRC}', '-r', '24', '-i', '-',
         '-vf', f'scale={W_OUT}:{H_OUT}:flags=lanczos,unsharp=5:5:0.30:5:5:0',
         '-c:v', 'hevc_videotoolbox', '-alpha_quality', str(alpha_quality),
         '-q:v', str(q), '-tag:v', 'hvc1', '-pix_fmt', 'bgra',
         '-allow_sw', '1', '-an', dst],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    nbytes = W_SRC * H_SRC * 3
    frames = 0
    try:
        while True:
            buf = dec.stdout.read(nbytes)
            if len(buf) < nbytes:
                break
            rgb = np.frombuffer(buf, np.uint8).reshape(H_SRC, W_SRC, 3)
            enc.stdin.write(rematte(rgb).tobytes())
            frames += 1
    finally:
        dec.stdout.close()
        dec.wait()
        try:
            enc.stdin.close()
        except Exception:
            pass
        err = enc.stderr.read().decode()[:300]
        enc.wait()
    if enc.returncode != 0:
        raise RuntimeError(f'encode failed rc={enc.returncode}: {err}')
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src')
    ap.add_argument('--dst')
    ap.add_argument('--one', nargs=2, metavar=('SRC', 'DST'))
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--q', type=int, default=62)
    ap.add_argument('--alpha-quality', type=float, default=0.85)
    ap.add_argument('--workers', type=int, default=3)
    args = ap.parse_args()

    if args.one:
        n = convert(args.one[0], args.one[1], args.q, args.alpha_quality)
        print(f'OK {n} frames -> {args.one[1]}')
        return

    tasks = []
    for root, _, files in os.walk(args.src):
        for f in sorted(files):
            if f.endswith('.webm'):
                s = os.path.join(root, f)
                rel = os.path.relpath(s, args.src).replace('.webm', '.mov')
                tasks.append((s, os.path.join(args.dst, rel)))
    tasks.sort()
    if args.limit:
        tasks = tasks[:args.limit]
    print(f'待处理 {len(tasks)} 段', flush=True)

    def job(t):
        try:
            n = convert(t[0], t[1], args.q, args.alpha_quality)
            return ('ok', t[0], n)
        except Exception as e:
            return ('fail', t[0], str(e)[:120])

    stat = {'ok': 0, 'fail': 0}
    fails = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for i, (st, src, info) in enumerate(ex.map(job, tasks), 1):
            stat[st] += 1
            if st == 'fail':
                fails.append((src, info))
            if i % 10 == 0 or i == len(tasks):
                print(f'  {i}/{len(tasks)} {stat}', flush=True)
    print('结果', stat)
    for f in fails[:5]:
        print('FAIL', os.path.basename(f[0]), f[1])


if __name__ == '__main__':
    main()
