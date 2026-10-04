#!/usr/bin/env python3
"""Run native feature checks without changing the runtime or user notebooks."""
import argparse
import base64
import gzip
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', type=Path, default=ROOT.parent / 'koreader-src/koreader-emulator-x86_64-pc-linux-gnu-debug/koreader')
parser.add_argument('--output', type=Path, help='Keep screenshots and exports in this directory')
args = parser.parse_args()
runtime = args.runtime.resolve()
if not (runtime / 'luajit').exists():
    parser.error(f'KOReader runtime not found: {runtime}')
with tempfile.TemporaryDirectory(prefix='notebook-native-') as directory:
    stage = Path(directory)
    for source in runtime.iterdir():
        if source.name in {'common', 'frontend', 'resources', 'fonts', 'libs', 'ffi', 'luajit'} or (
            source.suffix == '.lua' and not source.name.startswith(('settings.', 'defaults.custom'))
        ):
            (stage / source.name).symlink_to(source.resolve(), target_is_directory=source.is_dir())
    for width, height, dpi, language in [(600, 800, 96, 'en'), (800, 600, 96, 'it'), (1860, 2480, 300, 'it')]:
        output = (args.output.resolve() if args.output else stage / 'artifacts') / f'{width}x{height}-{language}'
        output.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(stage / 'luajit'), str(ROOT / 'tools/smoke-features.lua'), str(ROOT / 'lua'), str(output)],
                       cwd=stage, check=True, timeout=90,
                       env={**os.environ, 'SDL_VIDEODRIVER': 'dummy', 'KO_HOME': str(output),
                            'EMULATE_READER_W': str(width), 'EMULATE_READER_H': str(height),
                            'EMULATE_READER_DPI': str(dpi), 'LANGUAGE': language})

        svg = ET.parse(output / 'image.svg')
        images = svg.findall('.//{http://www.w3.org/2000/svg}image')
        assert len(images) == 2, 'SVG lost image objects'
        for image in images:
            header, encoded = image.attrib['href'].split(',', 1)
            data = base64.b64decode(encoded, validate=True)
            assert data.startswith(b'\x89PNG' if 'image/png' in header else b'\xff\xd8')
        with gzip.open(output / 'image.xopp', 'rb') as stream:
            xopp = ET.fromstring(stream.read())
        embedded = xopp.findall('.//image')
        assert len(embedded) == 2 and all(base64.b64decode(image.text, validate=True) for image in embedded)
