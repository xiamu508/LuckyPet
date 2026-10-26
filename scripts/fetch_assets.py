#!/usr/bin/env python3
"""Fetch the pinned upstream animations; verify each Git blob before using it."""
import argparse
import base64
import hashlib
import json
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'scripts/assets_manifest.json'
OUT_DIR = ROOT / 'assets_raw'


def blob_id(data):
    return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workers',type=int,default=6)
    parser.add_argument('--only',nargs='*')
    parser.add_argument('--api',action='store_true',help='Use GitHub blob API when raw CDN times out')
    args=parser.parse_args()
    manifest=json.loads(MANIFEST.read_text())
    clips=args.only or manifest['clips']
    base=manifest['raw_base']+manifest['upstream_path']

    def download(rel):
        dest=OUT_DIR/rel
        expected=manifest['blob_sha1'][rel]
        if dest.exists() and blob_id(dest.read_bytes())==expected:
            return rel,'verified'
        dest.parent.mkdir(parents=True,exist_ok=True)
        for attempt in range(3):
            try:
                url=(f'https://api.github.com/repos/MerZlin/dsh-pet-indesktop/git/blobs/{expected}'
                     if args.api or attempt > 0 else base+urllib.parse.quote(rel))
                req=urllib.request.Request(url,headers={'User-Agent':'LuckyPet-local-repair'})
                with urllib.request.urlopen(req,timeout=55) as response:
                    data=response.read()
                if 'api.github.com/' in url:
                    data=base64.b64decode(json.loads(data)['content'])
                if blob_id(data)!=expected:
                    raise ValueError('Upstream blob checksum mismatch')
                part=dest.with_suffix(dest.suffix+'.download')
                part.write_bytes(data)
                part.replace(dest)
                return rel,'downloaded'
            except Exception as exc:
                print(f'RETRY {attempt+1}/3 {rel}: {exc}',flush=True)
        return rel,'FAILED'

    print('Pinned revision:',manifest['source_revision'],flush=True)
    failed=[]
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        for i,(rel,status) in enumerate(executor.map(download,clips),1):
            print(f'{i}/{len(clips)} {status} {rel}',flush=True)
            if status=='FAILED':
                failed.append(rel)
    if failed:
        raise SystemExit(f'Download failed: {failed}')
    print('All source assets verified.',flush=True)


if __name__=='__main__':
    main()
