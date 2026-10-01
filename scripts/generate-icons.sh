#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift scripts/generate-icons.swift
mkdir -p build/mac-icon.iconset windows/assets
cp build/SongNote.iconset/icon_*.png build/mac-icon.iconset/
iconutil -c icns build/mac-icon.iconset -o assets/AppIcon.icns
python3 - <<'PY'
from pathlib import Path
import struct
sizes = [16, 24, 32, 48, 64, 128, 256]
images = [(s, (Path('build/SongNote.iconset') / f'windows-{s}.png').read_bytes()) for s in sizes]
offset = 6 + 16 * len(images)
directory = []
for size, image in images:
    directory.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(image), offset))
    offset += len(image)
Path('windows/assets/SongNote.ico').write_bytes(struct.pack('<HHH', 0, 1, len(images)) + b''.join(directory) + b''.join(image for _, image in images))
print('ICNS_AND_ICO_OK')
PY
