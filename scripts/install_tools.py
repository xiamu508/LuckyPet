"""Install repair dependencies inside this project, using a faster PyPI mirror."""
from pathlib import Path
import os
import signal
import subprocess

root=Path(__file__).resolve().parents[1]
python=root/'.venv/bin/python'
# Stop only the slow download started by this repair task for this exact venv.
needle=f'uv pip install --python {python} numpy pillow scipy opencv-python-headless onnxruntime'
result=subprocess.run(['ps','-axo','pid=,args='],capture_output=True,text=True,check=True)
for line in result.stdout.splitlines():
    fields=line.strip().split(None,1)
    if len(fields)==2 and fields[1]==needle:
        os.kill(int(fields[0]),signal.SIGINT)
        print('Stopped slow project-only dependency download',fields[0],flush=True)
env=os.environ.copy()
env['UV_CACHE_DIR']=str(root/'.cache/uv')
wheel=next((root/'tools/wheels').glob('torch-2.6.0-*.whl'))
cmd=['uv','pip','install','--python',str(python),'--index-url',
     'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple',
     'numpy','pillow','scipy','opencv-python-headless',str(wheel)]
raise SystemExit(subprocess.run(cmd,env=env).returncode)
