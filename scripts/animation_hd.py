#!/usr/bin/env python3
"""Restore original VP9 alpha, remove white matte, and upscale animation with Real-ESRGAN."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault('TORCH_HOME', str(ROOT / '.cache/torch'))
os.environ.setdefault('XDG_CACHE_HOME', str(ROOT / '.cache'))

import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt

MODEL_SHA256 = 'b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d'
PIPELINE_VERSION = 'original-alpha-white-unmatte-anime-v3-4x-1'


def metadata(path):
    result = subprocess.run([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=codec_name,width,height,avg_frame_rate:stream_tags',
        '-of', 'json', str(path)
    ], capture_output=True, check=True, text=True)
    return json.loads(result.stdout)['streams'][0]


def decode(path, info):
    if info['codec_name'] != 'vp9' or info.get('tags', {}).get('ALPHA_MODE') != '1':
        raise ValueError(f'{path}: original VP9 alpha channel is required')
    result = subprocess.run([
        'ffmpeg', '-v', 'error', '-nostdin', '-c:v', 'libvpx-vp9', '-threads', '1',
        '-i', str(path), '-map', '0:v:0', '-fps_mode', 'passthrough',
        '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'
    ], capture_output=True, check=True)
    w, h = info['width'], info['height']
    if len(result.stdout) % (w * h * 4):
        raise ValueError('Decoded frame data is incomplete')
    return np.frombuffer(result.stdout, np.uint8).reshape(-1, h, w, 4)


def unmatte_rgba(rgba):
    """Reverse the white matte using SOURCE alpha, preserving opaque artwork."""
    c = rgba[..., :3].astype(np.float32)
    a8 = rgba[..., 3]
    a = a8.astype(np.float32) / 255.0
    band = (a8 >= 21) & (a8 < 250)
    restored = np.clip((c - 255.0 * (1.0 - a[..., None])) /
                       np.maximum(a[..., None], 1.0 / 255.0), 0, 255)
    c[band] = restored[band]
    seeds = a8 >= 250
    if seeds.any():
        distance, nearest = distance_transform_edt(~seeds, return_indices=True)
        neighbor = c[nearest[0], nearest[1]]
        weights = np.array([0.299, 0.587, 0.114], np.float32)
        bright = (c @ weights) > (neighbor @ weights) + 30
        fringe = (a8 >= 3) & (a8 < 128) & bright & (distance <= 8)
        c[fringe] = neighbor[fringe]
        # RGB padding is invisible. Extending real edge colors prevents a second
        # fringe when the neural network samples across the transparent boundary.
        c[a8 < 3] = neighbor[a8 < 3]
    a[a8 <= 2] = 0
    return c, a


def clean_alpha(a, previous=None, gray=None, previous_gray=None, erosion=0.6):
    """Subpixel edge contraction and motion-compensated alpha stabilization."""
    inner = cv2.erode(a, np.ones((3, 3), np.uint8))
    cleaned = a * (1.0 - erosion) + inner * erosion
    cleaned = cv2.GaussianBlur(cleaned, (0, 0), 0.30)
    if previous is not None and gray is not None:
        # Backward flow: coordinates in the current frame -> previous frame.
        flow = cv2.calcOpticalFlowFarneback(gray, previous_gray, None,
                                          0.5, 3, 15, 3, 5, 1.1, 0)
        yy, xx = np.mgrid[:a.shape[0], :a.shape[1]].astype(np.float32)
        maps = xx + flow[..., 0], yy + flow[..., 1]
        warped = cv2.remap(previous, *maps, cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        old_gray = cv2.remap(previous_gray, *maps, cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        stable = ((np.abs(cleaned - warped) < 0.16) &
                  (np.abs(gray.astype(np.float32) - old_gray) < 12) &
                  (cleaned > 0) & (cleaned < 0.99))
        cleaned[stable] = 0.85 * cleaned[stable] + 0.15 * warped[stable]
    cleaned[cleaned < 2 / 255.0] = 0
    return np.clip(cleaned, 0, 1)


class AnimeUpscaler:
    def __init__(self, device='auto'):
        import torch
        from torch import nn
        from torch.nn import functional as F

        class SRVGGNetCompact(nn.Module):
            # Architecture adapted from Real-ESRGAN (BSD-3-Clause).
            # See THIRD_PARTY/Real-ESRGAN-LICENSE.
            def __init__(self):
                super().__init__()
                self.body = nn.ModuleList([nn.Conv2d(3, 64, 3, 1, 1), nn.PReLU(64)])
                for _ in range(16):
                    self.body.extend([nn.Conv2d(64, 64, 3, 1, 1), nn.PReLU(64)])
                self.body.append(nn.Conv2d(64, 3 * 4 * 4, 3, 1, 1))
                self.upsampler = nn.PixelShuffle(4)

            def forward(self, x):
                out = x
                for layer in self.body:
                    out = layer(out)
                return self.upsampler(out) + F.interpolate(x, scale_factor=4, mode='nearest')

        model_path = ROOT / 'tools/models/realesr-animevideov3.pth'
        if hashlib.sha256(model_path.read_bytes()).hexdigest() != MODEL_SHA256:
            raise ValueError('Animation model checksum mismatch')
        if device == 'auto':
            device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        self.device = torch.device(device)
        self.dtype = torch.float16 if device == 'mps' else torch.float32
        self.torch = torch
        torch.set_num_threads(4)
        self.model = SRVGGNetCompact()
        weights = torch.load(model_path, map_location='cpu', weights_only=True)
        self.model.load_state_dict(weights.get('params_ema', weights.get('params', weights)))
        self.model.eval().to(device=self.device, dtype=self.dtype)
        print(f'Real-ESRGAN animevideov3: {device}, {self.dtype}', flush=True)

    def __call__(self, rgb):
        torch = self.torch
        tensor = torch.from_numpy(np.ascontiguousarray(rgb.transpose(2, 0, 1)))
        tensor = tensor.unsqueeze(0).to(device=self.device, dtype=self.dtype) / 255.0
        with torch.inference_mode():
            result = self.model(tensor).clamp_(0, 1)
        return (result[0].permute(1, 2, 0).float().cpu().numpy() * 255.0).round().astype(np.uint8)


def crop_bounds(frames):
    alpha = frames[..., 3].max(axis=0)
    yy, xx = np.where(alpha > 2)
    h, w = alpha.shape
    if not len(xx):
        return 0, 0, w, h
    pad = 24  # exceeds the model's convolutional receptive radius
    x0, y0 = max(0, int(xx.min()) - pad), max(0, int(yy.min()) - pad)
    x1, y1 = min(w, int(xx.max()) + pad + 1), min(h, int(yy.max()) + pad + 1)
    x0, y0 = x0 // 16 * 16, y0 // 16 * 16
    x1, y1 = min(w, (x1 + 15) // 16 * 16), min(h, (y1 + 15) // 16 * 16)
    return x0, y0, x1, y1


def encode_frames(source, dest, upscaler, *, preview=False, erosion=0.6):
    info = metadata(source)
    frames = decode(source, info)
    if not len(frames):
        raise ValueError(f'{source}: no frames')
    x0, y0, x1, y1 = crop_bounds(frames)
    w, h = info['width'], info['height']
    fps = info['avg_frame_rate']
    dest.parent.mkdir(parents=True, exist_ok=True)
    if preview:
        selected = [0]
        encoder = None
    else:
        selected = range(len(frames))
        partial = dest.with_suffix('.partial.mov')
        encoder = subprocess.Popen([
            'ffmpeg', '-v', 'error', '-nostdin', '-y',
            '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{w*4}x{h*4}',
            '-r', fps, '-i', '-', '-c:v', 'hevc_videotoolbox',
            '-alpha_quality', '1.0', '-q:v', '80', '-tag:v', 'hvc1',
            '-pix_fmt', 'bgra', '-allow_sw', '1', '-an',
            '-movflags', '+faststart', str(partial)
        ], stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    previous = previous_gray = None
    started = time.monotonic()
    try:
        for index in selected:
            tile = frames[index, y0:y1, x0:x1]
            rgb, alpha = unmatte_rgba(tile)
            gray = cv2.cvtColor(tile[..., :3], cv2.COLOR_RGB2GRAY)
            alpha = clean_alpha(alpha, previous, gray, previous_gray, erosion)
            previous, previous_gray = alpha, gray
            high = upscaler(rgb)
            high_alpha = cv2.resize(alpha, (high.shape[1], high.shape[0]), interpolation=cv2.INTER_LINEAR)
            high_alpha = np.rint(np.clip(high_alpha, 0, 1) * 255).astype(np.uint8)
            rgba = np.zeros((h * 4, w * 4, 4), np.uint8)
            rgba[y0*4:y1*4, x0*4:x1*4, :3] = high
            rgba[y0*4:y1*4, x0*4:x1*4, 3] = high_alpha
            if preview:
                from PIL import Image
                Image.fromarray(rgba).save(dest)
            else:
                encoder.stdin.write(rgba.tobytes())
            if index == 0 or (index + 1) % 60 == 0:
                print(f'  {source.name}: {index+1}/{len(frames)} frames, {time.monotonic()-started:.1f}s', flush=True)
        if encoder:
            encoder.stdin.close()
            error = encoder.stderr.read().decode()
            code = encoder.wait()
            if code:
                raise RuntimeError(f'HEVC alpha encoding failed: {error}')
            partial.replace(dest)
    except BaseException:
        if encoder:
            encoder.kill()
            encoder.wait()
        raise
    return {
        'source': str(source.relative_to(ROOT)), 'output': str(dest.relative_to(ROOT)),
        'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'output_sha256': hashlib.sha256(dest.read_bytes()).hexdigest(),
        'source_size': [w, h], 'output_size': [w*4, h*4],
        'fps': fps, 'frames': len(frames), 'crop': [x0, y0, x1, y1],
        'pipeline': PIPELINE_VERSION, 'model_sha256': MODEL_SHA256,
        'erosion_source_pixels': erosion,
        'seconds': round(time.monotonic()-started, 2),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--device', choices=['auto', 'cpu', 'mps'], default='auto')
    parser.add_argument('--one', type=Path)
    parser.add_argument('--preview', action='store_true')
    parser.add_argument('--erosion', type=float, default=0.6)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    cv2.setNumThreads(1)
    upscaler = AnimeUpscaler(args.device)
    sources = [args.one] if args.one else sorted((ROOT/'assets_raw').rglob('*.webm'))
    report_path = ROOT/'Assets/hd_manifest.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    tasks = []
    for number, source in enumerate(sources, 1):
        source = source.resolve()
        rel = source.relative_to(ROOT/'assets_raw')
        dest = args.output or (ROOT/'Assets/clips'/rel.with_suffix('.mov'))
        if args.preview and not args.output:
            dest = ROOT/'inspection'/(source.stem+'-hd.png')
        key = str(rel)
        old = report.get(key, {})
        if (not args.preview and old.get('pipeline') == PIPELINE_VERSION and dest.exists()
                and old.get('erosion_source_pixels') == args.erosion
                and old.get('source_sha256') == hashlib.sha256(source.read_bytes()).hexdigest()
                and old.get('output_sha256') == hashlib.sha256(dest.read_bytes()).hexdigest()):
            print(f'{number}/{len(sources)} VERIFIED {rel}', flush=True)
            continue
        tasks.append((key, source, dest))

    def run(task):
        key, source, dest = task
        print(f'RESTORING {key}', flush=True)
        result = encode_frames(source, dest, upscaler, preview=args.preview, erosion=args.erosion)
        return key, result

    with ThreadPoolExecutor(max_workers=min(max(1, args.workers), 2)) as executor:
        futures = [executor.submit(run, task) for task in tasks]
        for number, future in enumerate(as_completed(futures), 1):
            key, result = future.result()
            if not args.preview:
                report[key] = result
                report_path.parent.mkdir(parents=True, exist_ok=True)
                report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
            print(f'{number}/{len(tasks)} DONE {key} {result["seconds"]}s', flush=True)



if __name__ == '__main__':
    main()
