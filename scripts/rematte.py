#!/usr/bin/env python3
"""Compatibility entry point for the repaired original-alpha HD pipeline."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--src', type=Path, default=ROOT/'assets_raw')
    parser.add_argument('--dst', type=Path, default=ROOT/'Assets/clips')
    parser.add_argument('--one', nargs=2, type=Path, metavar=('SRC', 'DST'))
    parser.add_argument('--device', default='auto', choices=['auto', 'mps', 'cpu'])
    parser.add_argument('--workers', type=int, default=2)
    args = parser.parse_args()
    if args.src.resolve() != ROOT/'assets_raw' or args.dst.resolve() != ROOT/'Assets/clips':
        parser.error('Place source files in project assets_raw/; outputs are project Assets/clips/.')
    python = ROOT/'.venv/bin/python'
    command = [str(python if python.exists() else sys.executable), str(ROOT/'scripts/animation_hd.py'),
               '--device', args.device, '--workers', str(args.workers)]
    if args.one:
        command += ['--one', str(args.one[0]), '--output', str(args.one[1])]
    return subprocess.run(command).returncode


if __name__ == '__main__':
    raise SystemExit(main())
