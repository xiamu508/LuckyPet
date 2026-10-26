"""Read upstream files and save references inside this project only."""
import base64
import json
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT / 'inspection'
INSPECT.mkdir(exist_ok=True)


def get(url, timeout=25):
    req = urllib.request.Request(url, headers={'User-Agent': 'LuckyPet-local-repair'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def blob(repo, path):
    tree = json.loads((INSPECT / f"{repo.replace('/', '_')}-tree.json").read_text())
    entry = next(e for e in tree['tree'] if e['path'] == path)
    url = f"https://api.github.com/repos/{repo}/git/blobs/{entry['sha']}"
    doc = json.loads(get(url, 60))
    return base64.b64decode(doc['content'])


def job(task):
    repo, path, dest = task
    try:
        data = blob(repo, path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        print('SAVED', dest.relative_to(ROOT), len(data), flush=True)
    except Exception as exc:
        print('ERROR', path, repr(exc), flush=True)


tasks = [
    ('MerZlin/dsh-pet-indesktop', 'assets/characters/shenshen/videos/idle/待机呼吸休闲.webm', ROOT / 'assets_raw/idle/待机呼吸休闲.webm'),
    ('MerZlin/dsh-pet-indesktop', 'pet/frameseq_clip.py', INSPECT / 'upstream_frameseq_clip.py'),
    ('MerZlin/dsh-pet-indesktop', 'pet/frameseq_provision.py', INSPECT / 'upstream_frameseq_provision.py'),
    ('zhiyou-conder/deepseek-pet', 'README.md', INSPECT / 'original_README.md'),
]
with ThreadPoolExecutor(max_workers=4) as executor:
    list(executor.map(job, tasks))
for repo in ('xinntao/Real-ESRGAN', 'nihui/realcugan-ncnn-vulkan', 'nihui/realesrgan-ncnn-vulkan'):
    try:
        doc=json.loads(get(f'https://api.github.com/repos/{repo}/releases/latest'))
        (INSPECT / f"{repo.replace('/', '_')}-release.json").write_text(json.dumps(doc, indent=2))
        print('RELEASE', repo, doc.get('tag_name'), flush=True)
        for asset in doc.get('assets', []):
            if any(k in asset['name'].lower() for k in ('macos', 'anime', 'v3')):
                print('MODEL_TOOL',asset['name'],asset['size'],asset['browser_download_url'],flush=True)
    except Exception as exc:
        print('RELEASE_ERROR',repo,repr(exc),flush=True)
