#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从上游开源项目下载角色动画素材（MIT 许可）。

用法：
    python3 scripts/fetch_assets.py            # 下载全部
    python3 scripts/fetch_assets.py --workers 4

素材来源：https://github.com/MerZlin/dsh-pet-indesktop
许可：MIT (Copyright (c) 2026 Merzlin)，详见 NOTICE.md
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, 'scripts', 'assets_manifest.json')
OUT_DIR = os.path.join(ROOT, 'assets_raw')


def download(session_base, rel, overwrite=False):
    dst = os.path.join(OUT_DIR, rel)
    if os.path.exists(dst) and os.path.getsize(dst) > 0 and not overwrite:
        return 'skip'
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    url = session_base + urllib.parse.quote(rel)
    for attempt in range(3):
        try:
            data = urllib.request.urlopen(url, timeout=45).read()
            with open(dst, 'wb') as f:
                f.write(data)
            return 'ok'
        except Exception as e:
            if attempt == 2:
                print(f'  FAIL {rel}: {e}', flush=True)
                return 'fail'
            time.sleep(1.0)
    return 'fail'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--workers', type=int, default=6)
    ap.add_argument('--overwrite', action='store_true')
    args = ap.parse_args()

    m = json.load(open(MANIFEST, encoding='utf-8'))
    base = m['raw_base'] + m['upstream_path']
    clips = m['clips']
    print(f"素材来源: {m['source_repo']}")
    print(f"许可: {m['license']}")
    print(f"共 {len(clips)} 个文件 → {OUT_DIR}\n", flush=True)

    os.makedirs(OUT_DIR, exist_ok=True)
    stat = {'ok': 0, 'skip': 0, 'fail': 0}
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for i, r in enumerate(ex.map(lambda c: download(base, c, args.overwrite), clips), 1):
            stat[r] += 1
            if i % 20 == 0:
                print(f"  进度 {i}/{len(clips)}  {stat}", flush=True)

    print(f"\n完成: {stat}")
    if stat['fail']:
        print("存在失败项，可重复运行本脚本续传。")
        return 1
    print("下一步: python3 scripts/transcode.py")
    return 0


if __name__ == '__main__':
    sys.exit(main())
