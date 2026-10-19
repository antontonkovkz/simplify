#!/usr/bin/env python3
"""Export approved raster artwork into native icon slots using macOS sips."""
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'assets/branding/simplefy-icon.png'


def png_info(path):
    header = path.read_bytes()[:26]
    if header[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path.name}')
    return (*struct.unpack('>II', header[16:24]), header[25])


def export(path, pixels):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ['sips', '-s', 'format', 'png', '-z', str(pixels), str(pixels),
         str(SOURCE), '--out', str(path)],
        check=True, capture_output=True,
    )
    if png_info(path) != (pixels, pixels, 2):
        raise ValueError(f'Expected opaque RGB {pixels}px: {path.name}')


def main():
    width, height, color_type = png_info(SOURCE)
    if width != height or width < 1024 or color_type != 2:
        raise ValueError('Approved source must be square opaque RGB PNG, >=1024px')
    icons = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    slots = json.loads((icons / 'Contents.json').read_text())['images']
    outputs = {}
    for slot in slots:
        pixels = round(float(slot['size'].split('x')[0]) * float(slot['scale'][:-1]))
        if slot['filename'] in outputs and outputs[slot['filename']] != pixels:
            raise ValueError('Conflicting native icon slots')
        outputs[slot['filename']] = pixels
    for filename, pixels in outputs.items():
        export(icons / filename, pixels)
    launch = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
    for slot in json.loads((launch / 'Contents.json').read_text())['images']:
        export(launch / slot['filename'], round(144 * float(slot['scale'][:-1])))
    android = ROOT / 'android/app/src/main/res'
    if android.exists():
        for density, pixels in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
            export(android / f'mipmap-{density}/ic_launcher.png', pixels)
        export(android / 'drawable-nodpi/simplefy_foreground.png', 432)
        adaptive = android / 'mipmap-anydpi-v26'
        adaptive.mkdir(parents=True, exist_ok=True)
        (adaptive / 'ic_launcher.xml').write_text('''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/simplefy_background" />
    <foreground><inset android:drawable="@drawable/simplefy_foreground" android:inset="8%" /></foreground>
</adaptive-icon>
''')
    print(f'Exported opaque RGB artwork: Flutter 1024px, {len(outputs)} iOS icons, 3 launch images; Android icons when available.')


if __name__ == '__main__':
    main()
