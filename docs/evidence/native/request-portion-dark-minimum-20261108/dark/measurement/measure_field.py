#!/usr/bin/env python3
"""Read-only, original-pixel PNG measurement. No image rendering or rewriting."""
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib


def decode(path):
    raw = path.read_bytes()
    if raw[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Not a PNG')
    pos, parts, meta, palette, transparency = 8, [], {}, None, None
    while pos < len(raw):
        size = struct.unpack('>I', raw[pos:pos + 4])[0]
        kind = raw[pos + 4:pos + 8]
        data = raw[pos + 8:pos + 8 + size]
        crc = struct.unpack('>I', raw[pos + 8 + size:pos + 12 + size])[0]
        if zlib.crc32(kind + data) & 0xffffffff != crc:
            raise ValueError('PNG CRC mismatch')
        if kind == b'IHDR':
            w, h, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', data)
        elif kind == b'IDAT':
            parts.append(data)
        elif kind == b'PLTE':
            palette = [tuple(data[i:i + 3]) for i in range(0, len(data), 3)]
        elif kind == b'tRNS':
            transparency = data
        elif kind == b'sRGB':
            meta['sRGBIntent'] = data[0]
        elif kind == b'iCCP':
            meta['embeddedICCProfile'] = True
        elif kind == b'gAMA':
            meta['gamma'] = struct.unpack('>I', data)[0] / 100000
        pos += size + 12
        if kind == b'IEND':
            break
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    if depth != 8 or color not in channels or comp or filt or interlace:
        raise ValueError('Only 8-bit, noninterlaced PNG types 0/2/3/4/6 supported; no silent conversion')
    bpp, pixels = channels[color], []
    stride = w * bpp
    packed = zlib.decompress(b''.join(parts))
    if len(packed) != h * (stride + 1):
        raise ValueError('Unexpected decompressed size')
    previous = bytearray(stride)
    for y in range(h):
        at = y * (stride + 1)
        filter_type = packed[at]
        if filter_type not in range(5):
            raise ValueError('Invalid PNG filter')
        row = bytearray(packed[at + 1:at + 1 + stride])
        for i in range(stride):
            a, b, c = row[i-bpp] if i >= bpp else 0, previous[i], previous[i-bpp] if i >= bpp else 0
            prediction = a + b - c
            distances = (abs(prediction-a), abs(prediction-b), abs(prediction-c))
            paeth = (a, b, c)[distances.index(min(distances))]
            predictor = (0, a, b, (a+b)//2, paeth)[filter_type]
            row[i] = (row[i] + predictor) & 255
        for x in range(w):
            values = row[x*bpp:(x+1)*bpp]
            if color == 0:
                rgb, alpha = (values[0],)*3, 255
                if transparency and values[0] == struct.unpack('>H', transparency)[0]:
                    alpha = 0
            elif color == 2:
                rgb, alpha = tuple(values), 255
                if transparency and rgb == struct.unpack('>HHH', transparency):
                    alpha = 0
            elif color == 3:
                rgb = palette[values[0]]
                alpha = transparency[values[0]] if transparency and values[0] < len(transparency) else 255
            elif color == 4:
                rgb, alpha = (values[0],)*3, values[1]
            else:
                rgb, alpha = tuple(values[:3]), values[3]
            if alpha != 255:
                raise ValueError('Nonopaque pixels require a known compositing background; refusing to assume one')
            pixels.append(rgb)
        previous = row
    meta.update(width=w, height=h, bitDepth=depth, colorType=color, channels=bpp,
                allPixelsOpaque=True, chunkCRCsVerified=True, sha256=hashlib.sha256(raw).hexdigest())
    return w, h, pixels, meta


def contrast(a, b):
    def luminance(rgb):
        values = [v/255 for v in rgb]
        values = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in values]
        return sum(v*k for v, k in zip(values, (.2126, .7152, .0722)))
    x, y = sorted((luminance(a), luminance(b)))
    return (y+.05)/(x+.05)


def measure(path, roi=None):
    width, height, pixels, meta = decode(path)
    x0, y0, x1, y1 = roi or (0, 0, width, height)
    if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
        raise ValueError('ROI outside PNG')
    selected = {y*width+x: pixels[y*width+x] for y in range(y0, y1) for x in range(x0, x1)}
    counts = collections.Counter(selected.values())
    background, background_count = counts.most_common(1)[0]
    # A distance threshold removes nearly invisible antialias edges. It is not a contrast cutoff.
    mask = {i for i, rgb in selected.items() if max(abs(a-b) for a, b in zip(rgb, background)) >= 8}
    components, kept = [], []
    while mask:
        seed = min(mask)
        mask.remove(seed)
        pending, members = [seed], []
        while pending:
            i = pending.pop()
            members.append(i)
            x, y = i % width, i // width
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x+dx, y+dy
                    ni = ny*width+nx
                    if x0 <= nx < x1 and y0 <= ny < y1 and ni in mask:
                        mask.remove(ni)
                        pending.append(ni)
        xs, ys = [i % width for i in members], [i // width for i in members]
        box = [min(xs), min(ys), max(xs)+1, max(ys)+1]
        w, h = box[2]-box[0], box[3]-box[1]
        reason = None
        if box[0] <= x0+1 or box[1] <= y0+1 or box[2] >= x1-1 or box[3] >= y1-1:
            reason = 'crop-edge component'
        elif w < 2 or h < 3 or len(members) < 8:
            reason = 'small mark'
        elif h/w >= 5:
            reason = 'caret-like or narrow glyph'
        elif w/h >= 6:
            reason = 'border-like horizontal component'
        hist = collections.Counter(pixels[i] for i in members)
        components.append({'boxExclusive': box, 'pixelCount': len(members), 'excludedReason': reason})
        if reason is None:
            kept.append(hist)
    ink = sum(kept, collections.Counter())
    modes = collections.Counter(hist.most_common(1)[0][0] for hist in kept)
    candidates = []
    for rgb, count in ink.most_common(12):
        candidates.append({'RGB': rgb, 'pixels': count, 'contrast': contrast(rgb, background),
                           'componentsWithColor': sum(rgb in hist for hist in kept),
                           'componentsWhereColorIsMode': modes[rgb]})
    dominant = candidates[0] if candidates else None
    sufficient = bool(dominant and len(kept) >= 8 and dominant['componentsWhereColorIsMode'] >= 5
                      and background_count/len(selected) >= .5)
    profile_known = 'sRGBIntent' in meta and not meta.get('embeddedICCProfile')
    return {'source': str(path.resolve()), 'PNG': meta, 'roiExclusive': [x0, y0, x1, y1],
            'backgroundRGB': background, 'backgroundPixels': background_count, 'roiPixels': len(selected),
            'foregroundMaskRule': 'maximum RGB distance from dominant background >= 8',
            'components': components, 'retainedComponents': len(kept), 'dominantCoreCandidate': dominant,
            'coreCandidates': candidates, 'distributedColorSupport': sufficient,
            'sRGBProfileEstablished': profile_known, 'requiredContrast': 4.5,
            'assessment': ('supported dominant core candidate below 4.5:1' if sufficient and profile_known and dominant['contrast'] < 4.5
                           else 'candidate meets 4.5:1; visual text-only and component review required' if sufficient and profile_known
                           else 'inconclusive; inspect crop, color profile and component support'),
            'limits': ['No automatic accessibility pass; verify crop contains the intended empty prompt, not entered text or another label.',
                       'No OCR. Component filters can exclude narrow letters and cannot prove a component is text.',
                       'Maximum/darkest pixel is deliberately not a passing criterion; caret/edges cannot qualify alone.',
                       'Candidate is the exact most frequent retained foreground RGB, requiring repeated component modes.',
                       'Antialiasing can bias the mode toward background; inspect candidate histogram before interpreting a failure.',
                       'No profile conversion; without explicit sRGB and absent ICC, numerical ratio is conditional on sRGB.',
                       'No image scaling, editing, native execution, or claims about other appearance/text-size states.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('png', type=Path)
    parser.add_argument('--roi', type=int, nargs=4, metavar=('LEFT', 'TOP', 'RIGHT', 'BOTTOM'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(measure(args.png, args.roi), indent=2) + '\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')
