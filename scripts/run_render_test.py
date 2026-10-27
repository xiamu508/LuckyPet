#!/usr/bin/env python3
"""Run the native UI check with all test configuration and logs inside the project."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary',type=Path,default=ROOT/'dist/LuckyPet.app/Contents/MacOS/LuckyPet')
args=parser.parse_args()
binary=args.binary.resolve()
if not binary.is_relative_to(ROOT):
    parser.error('The test binary must be inside this project')
out=ROOT/'inspection/render-smoke'
out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
env['LUCKY_PET_CONFIG_DIR']=str(out/'config')
env['PET_RENDER_TEST_DIR']=str(out)
if '.app' in str(binary):
    env.pop('LUCKY_PET_RESOURCES',None)
else:
    env['LUCKY_PET_RESOURCES']=str(ROOT/'Assets/clips')
started=time.time()
with (out/'process.log').open('w') as log:
    result=subprocess.run([str(binary)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90)
result.check_returncode()
report=out/'render-smoke.json'
if not report.exists() or report.stat().st_mtime<started:
    raise SystemExit('Native app did not create a new render report; see process.log')
data=json.loads(report.read_text())
for item in data['observations']:
    print(item['phase'],'state=',item['state'],'canvas=',item['canvasInsideWindow'],
          'petOnScreen=',item['petFullyOnScreen'],'stable=',item['positionStable'],
          'boundary=',item['atRequestedBoundary'],'server=',item['serverGeometryValid'],
          'ready=',item['readyForDisplay'],'hitPixels=',item['hasHitPixels'],
          'textFits=',item['bubbleTextFullyVisible'],'bubbleGap=',item['bubbleGap'],flush=True)
print('SINGLE_REMINDER_PER_FIRE',data['singleReminderPerFire'],flush=True)
print('NATIVE_RENDER_PASSED',data['passed'],flush=True)
if not data['passed']:
    raise SystemExit(1)
