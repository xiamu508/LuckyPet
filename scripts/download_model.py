"""Download the official Real-ESRGAN animation model into this project."""
from pathlib import Path
import hashlib
import urllib.request

root=Path(__file__).resolve().parents[1]
out=root/'tools/models'
out.mkdir(parents=True,exist_ok=True)
files={
    'realesr-animevideov3.pth':'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth',
    'Real-ESRGAN-LICENSE':'https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/LICENSE',
    'srvgg_arch_reference.py':'https://raw.githubusercontent.com/xinntao/Real-ESRGAN/master/realesrgan/archs/srvgg_arch.py',
}
for name,url in files.items():
    dest=out/name
    if dest.exists() and dest.stat().st_size>0:
        print('EXISTS',name,flush=True)
        continue
    for attempt in range(3):
        try:
            req=urllib.request.Request(url,headers={'User-Agent':'LuckyPet-local-repair'})
            with urllib.request.urlopen(req,timeout=60) as response:
                data=response.read()
            dest.write_bytes(data)
            print('SAVED',name,len(data),'sha256',hashlib.sha256(data).hexdigest(),flush=True)
            break
        except Exception as exc:
            print('RETRY',name,attempt+1,repr(exc),flush=True)
    else:
        raise SystemExit(f'Unable to download {name}')
