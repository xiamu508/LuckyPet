#!/usr/bin/env python3
"""Check decoded before/after frames on light and dark backgrounds."""
import json
from pathlib import Path
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from animation_hd import decode, metadata

ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT/'inspection'
source = ROOT/'assets_raw/idle/待机呼吸休闲.webm'
frames = decode(source, metadata(source))
measurements=[]
weights=np.array([0.299,0.587,0.114],np.float32)
for index,time in [(0,0.0),(60,2.5),(120,5.0),(180,7.5)]:
    before=Image.open(INSPECT/f'before-idle-frames/frame-{time:.1f}.png').convert('RGBA')
    after=Image.open(INSPECT/f'after-idle-frames/frame-{time:.1f}.png').convert('RGBA')
    after=after.resize(before.size,Image.Resampling.LANCZOS)
    a=cv2.resize(frames[index,...,3].astype(np.float32)/255,before.size,interpolation=cv2.INTER_LINEAR)
    near=cv2.dilate((a>0.5).astype(np.uint8),np.ones((15,15),np.uint8))>0
    exterior=(a<0.05)&near
    values=[]
    for image in (before,after):
        rgba=np.array(image).astype(np.float32)
        alpha=rgba[...,3]/255
        # Bright energy where the original source says the background is clear.
        composite=rgba[...,:3]*alpha[...,None]+np.array([26,35,52])*(1-alpha[...,None])
        excess=np.maximum(composite@weights-(np.array([26,35,52])@weights),0)
        values.append(float(excess[exterior].sum()))
    measurements.append({'time':time,'before_exterior_bright_energy':round(values[0],2),
                         'after_exterior_bright_energy':round(values[1],2),
                         'reduction':round(1-values[1]/max(values[0],1),5)})

font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',23)
canvas=Image.new('RGB',(1120,1460),'#17212e')
draw=ImageDraw.Draw(canvas)
for row,(background,title) in enumerate([('#1a2334','DARK DESKTOP'),('#f3eee5','LIGHT DESKTOP')]):
    for col,label in enumerate(['BEFORE','AFTER']):
        path=INSPECT/('before-idle-frames' if col==0 else 'after-idle-frames')/'frame-0.0.png'
        image=Image.open(path).convert('RGBA').resize((1280,720),Image.Resampling.LANCZOS)
        image=image.crop((384,90,896,690))
        composite=Image.new('RGBA',image.size,background)
        composite.alpha_composite(image)
        x=24+col*560; y=70+row*730
        canvas.paste(composite.convert('RGB'),(x,y))
        draw.text((x,y-42),f'{title} - {label}',font=font,fill='#edf3ff')
canvas.save(INSPECT/'comparison-backgrounds.png')
report={'method':'Bright energy outside the original source alpha silhouette; 4 decoded sample frames.',
        'note':'This measures exterior halo leakage, not overall image accuracy or every frame of every action.',
        'frames':measurements}
(INSPECT/'edge-quality.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
