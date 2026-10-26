"""Download the macOS ARM64 PyTorch wheel locally, without altering a shared Python."""
from pathlib import Path
import hashlib
import json
import time
import urllib.request

root=Path(__file__).resolve().parents[1]
out=root/'tools/wheels'
out.mkdir(parents=True,exist_ok=True)
req=urllib.request.Request('https://pypi.org/pypi/torch/2.6.0/json',headers={'User-Agent':'LuckyPet-repair'})
with urllib.request.urlopen(req,timeout=45) as r:
    doc=json.load(r)
wheel=next(v for v in doc['urls'] if 'cp312-none-macosx_11_0_arm64.whl' in v['filename'])
dest=out/wheel['filename']
expected=wheel['digests']['sha256']
if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest()==expected:
    print('VERIFIED',dest,flush=True)
    raise SystemExit(0)
url=wheel['url']
# A university PyPI mirror serves the identical hash-addressed wheel.
mirror=url.replace('https://files.pythonhosted.org/','https://mirrors.tuna.tsinghua.edu.cn/pypi/web/')
for candidate in (mirror,url):
    try:
        start=time.monotonic()
        req=urllib.request.Request(candidate,headers={'User-Agent':'LuckyPet-repair'})
        with urllib.request.urlopen(req,timeout=45) as r:
            partial=dest.with_suffix(dest.suffix+'.download')
            size=0
            with partial.open('wb') as stream:
                while chunk:=r.read(1024*1024):
                    stream.write(chunk)
                    size+=len(chunk)
                    print('TORCH_DOWNLOAD',round(size/2**20,1),'MiB',round(time.monotonic()-start,1),'s',flush=True)
        if hashlib.sha256(partial.read_bytes()).hexdigest()!=expected:
            raise ValueError('Wheel checksum mismatch')
        partial.replace(dest)
        print('VERIFIED',dest,'sha256',expected,flush=True)
        break
    except Exception as e:
        print('DOWNLOAD_ERROR',candidate,repr(e),flush=True)
else:
    raise SystemExit('Unable to download torch')
