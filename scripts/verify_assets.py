#!/usr/bin/env python3
"""Verify all 106 restored animations; optionally decode every frame with AVFoundation."""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    source_manifest=json.loads((ROOT/'scripts/assets_manifest.json').read_text())
    build_manifest=json.loads((ROOT/'Assets/hd_manifest.json').read_text())
    expected={name for name in source_manifest['clips'] if name.endswith('.webm')}
    actual={str(path.relative_to(ROOT/'Assets/clips').with_suffix('.webm'))
            for path in (ROOT/'Assets/clips').rglob('*.mov')}
    if expected!=set(build_manifest) or expected!=actual:
        raise SystemExit(f'Asset set mismatch: missing={expected-actual}; extra={actual-expected}; records={len(build_manifest)}')
    clip_paths=[]
    clips=[]
    for rel in sorted(expected):
        item=build_manifest[rel]
        source=ROOT/'assets_raw'/rel
        video=ROOT/'Assets/clips'/Path(rel).with_suffix('.mov')
        if Path(item['output'])!=video.relative_to(ROOT):
            raise SystemExit(f'Unexpected output path: {rel}')
        if digest(source)!=item['source_sha256'] or digest(video)!=item['output_sha256']:
            raise SystemExit(f'Checksum mismatch: {rel}')
        if item['source_size']!=[640,360] or item['output_size']!=[2560,1440]:
            raise SystemExit(f'Unexpected resolution: {rel}')
        clip_paths.append(str(video))
        clips.append({'file':str(video.relative_to(ROOT/'Assets/clips')),
                      'size':video.stat().st_size,'sha256':item['output_sha256'],
                      'frames':item['frames'],'fps':item['fps'],'resolution':item['output_size']})
    native_report=ROOT/'inspection/all-clips.json'
    if args.native:
        subprocess.run([str(ROOT/'tools/video-probe'),str(native_report),*clip_paths],check=True)
    native_checked=native_report.exists()
    if native_checked:
        decoded={str(Path(v['file']).resolve()):v for v in json.loads(native_report.read_text())}
        if set(decoded)!=set(clip_paths):
            raise SystemExit('Native decode report does not cover the full asset set')
        for rel,path in zip(sorted(expected),clip_paths):
            item=decoded[path]
            original=build_manifest[rel]
            if (item['width'],item['height'])!=(2560,1440):
                raise SystemExit(f'Native resolution mismatch: {rel}')
            if item['frames']!=original['frames'] or abs(item['fps']-float(Fraction(original['fps'])))>0.001:
                raise SystemExit(f'Frame count or FPS mismatch: {rel}')
            if not item['containsAlpha'] or item['alphaMin']!=0 or item['alphaMax']<248:
                raise SystemExit(f'Alpha channel check failed: {rel}')
    report={'passed':True,'clips':len(clips),'frames':sum(v['frames'] for v in clips),
            'resolution':[2560,1440],'native_decode_checked':native_checked,
            'groups':dict(Counter(Path(v['file']).parts[0] for v in clips)),
            'bytes':sum(v['size'] for v in clips),
            'upstream_revision':source_manifest['source_revision']}
    (ROOT/'Assets/clip_manifest.json').write_text(json.dumps(clips,ensure_ascii=False,indent=2)+'\n')
    (ROOT/'inspection/assets-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
