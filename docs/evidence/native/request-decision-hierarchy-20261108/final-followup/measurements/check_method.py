"""Synthetic format/contamination checks; these are not UI acceptance evidence."""
import json
from pathlib import Path
import struct
import tempfile
import zlib
from measure_field import measure


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def fixture(path, color, background=255, text=197, transparent=False):
    width, height = 220, 60
    palette = [background, text, 0]
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            value = text if 20 <= y < 32 and any(10+12*i <= x < 16+12*i for i in range(12)) else background
            if y == 0 or 190 <= x < 192 and 8 <= y < 45:
                value = 0  # Stronger border and caret must not turn faint glyphs into a pass.
            alpha = 0 if transparent and (x, y) == (0, 0) else 255
            row.extend({0: [value], 2: [value]*3, 3: [palette.index(value)],
                        4: [value, alpha], 6: [value]*3+[alpha]}[color])
        rows.append(b'\0'+row)
    raw = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color, 0, 0, 0))
    raw += chunk(b'sRGB', b'\0')
    if color == 3:
        raw += chunk(b'PLTE', bytes(v for v in palette for _ in range(3)))
    raw += chunk(b'IDAT', zlib.compress(b''.join(rows)))+chunk(b'IEND', b'')
    path.write_bytes(raw)


checks = []
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)/'synthetic.png'
    for color in [0, 2, 3, 4, 6]:
        fixture(path, color)
        result = measure(path)
        assert result['dominantCoreCandidate']['RGB'] == (197, 197, 197)
        assert result['dominantCoreCandidate']['contrast'] < 2
        assert result['distributedColorSupport']
        assert len([c for c in result['components'] if c['excludedReason']]) == 2
        checks.append({'colorType': color, 'faintPromptWithBlackCaretAndBorder': 'correctly below threshold'})
    fixture(path, 6, background=20, text=220)
    result = measure(path)
    assert result['dominantCoreCandidate']['contrast'] > 10
    checks.append({'darkBackgroundLightGlyphs': 'ratio above 10:1, still requires visual review'})
    fixture(path, 6, transparent=True)
    try:
        measure(path)
    except ValueError as error:
        assert 'Nonopaque' in str(error)
        checks.append({'nonopaqueRGBA': 'refused without assumed compositing background'})
    else:
        raise AssertionError('Transparency must not be silently discarded')
print(json.dumps({'syntheticOnly': True, 'checks': checks}, indent=2))
