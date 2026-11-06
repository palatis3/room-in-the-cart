"""Bounded, fail-closed parsing for diagnostic evidence, never test acceptance."""
from collections import defaultdict
from pathlib import Path
import math
import re
import struct
import zlib

MAX_JOURNAL_BYTES = 262144
MAX_EVENTS = 2048
EVENTS = {
    "observer.installed", "done.enter", "done.exit", "focus.visible", "focus.hidden",
    *["comparison.focus." + x for x in
      ("itemName", "needed", "aQuantity", "aPrice", "bQuantity", "bPrice", "none", "other")],
    *["keyboard." + x for x in ("willShow", "didShow", "willHide", "didHide", "willChangeFrame", "didChangeFrame")],
    "textField.beginEditing", "textField.endEditing", "textView.beginEditing", "textView.endEditing",
}
EVENT = re.compile(r"SDD1\|([1-9][0-9]*)\|([1-9][0-9]*)\|([0-9]+(?:\.[0-9]+)?)\|([A-Za-z.]+)\|(process|comparison|other)")
MARKER = re.compile(r"SDD_RUNNER\|(before|after)\|([1-9][0-9]*)\|([0-9]+(?:\.[0-9]+)?)")


def parse_events(text, *, journal=False):
    if journal and (len(text.encode()) > MAX_JOURNAL_BYTES or not text.endswith("\n")):
        raise ValueError("Oversized or partial journal")
    result = []
    for line in text.splitlines():
        if "SDD_ERROR|" in line:
            raise ValueError("App reported a journal failure")
        if "SDD1|" not in line:
            if journal:
                raise ValueError("Non-event journal line")
            continue
        token = line[line.index("SDD1|"):]
        match = EVENT.fullmatch(token)
        if not match or match[4] not in EVENTS:
            raise ValueError("Malformed or unknown fixed event")
        uptime = float(match[3])
        if not math.isfinite(uptime):
            raise ValueError("Non-finite event uptime")
        result.append((int(match[1]), int(match[2]), uptime, match[4], match[5]))
    grouped = defaultdict(list)
    for event in result:
        grouped[event[0]].append(event)
    for events in grouped.values():
        if len(events) > MAX_EVENTS or [e[1] for e in events] != list(range(1, len(events) + 1)):
            raise ValueError("Journal/event sequence is missing, duplicated or unbounded")
        if events[0][3] != "observer.installed" or any(b[2] < a[2] for a, b in zip(events, events[1:])):
            raise ValueError("Missing activation or reversed uptime")
    if journal and len(grouped) != 1:
        raise ValueError("Journal must contain exactly one process")
    return result


def parse_markers(text):
    result = []
    for line in text.splitlines():
        if "SDD_RUNNER|" not in line:
            continue
        match = MARKER.fullmatch(line.strip())
        if not match:
            raise ValueError("Malformed runner marker")
        uptime = float(match[3])
        if not math.isfinite(uptime):
            raise ValueError("Non-finite marker uptime")
        result.append((match[1], int(match[2]), uptime))
    if [x[0] for x in result] != ["before", "after"] or result[0][1] != result[1][1] or result[1][2] < result[0][2]:
        raise ValueError("Expected one complete, ordered bQuantity Done marker pair")
    return result


def compare_sinks(journals, live, exported, tests):
    """No return value from this function claims absent delivery or a cause."""
    if not 1 <= len(journals) <= 8:
        raise ValueError("Missing or excessive app process journals")
    records, pids = [], set()
    for name, text in journals.items():
        match = re.fullmatch(r"process-([1-9][0-9]*)\.events", name)
        events = parse_events(text, journal=True)
        if not match or int(match[1]) != events[0][0] or events[0][0] in pids:
            raise ValueError("Journal filename/process mismatch")
        pids.add(events[0][0])
        records.extend(events)
    for sink in (live, exported):
        if sorted(parse_events(sink)) != sorted(records):
            raise ValueError("Live, persisted and journal event sequences disagree")
    markers = parse_markers(tests)
    targets = {e[0] for e in records if e[3] == "comparison.focus.bQuantity"
               and e[4] == "comparison" and e[2] <= markers[0][2]}
    if len(targets) != 1:
        raise ValueError("Expected one app process with comparison bQuantity focus before Done")
    target = next(iter(targets))
    if not any(e[0] == target and e[2] > markers[1][2] for e in records):
        raise ValueError("No target app process event coverage after the returned Done call")
    return {"processIDs": sorted(pids), "targetProcessID": target,
            "events": len(records), "markers": markers,
            "absenceInferenceAllowed": False, "causalConclusion": None}


def validate_png(path):
    """Decode the PNG compression stream and validate every chunk and scanline."""
    if Path(path).stat().st_size > 16777216:
        raise ValueError("Oversized PNG")
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Missing, oversized or non-PNG still")
    offset, compressed, header, ended = 8, bytearray(), None, False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        size, kind = struct.unpack(">I4s", data[offset:offset + 8])
        payload = data[offset + 8:offset + 8 + size]
        end = offset + 12 + size
        if end > len(data) or zlib.crc32(kind + payload) != struct.unpack(">I", data[end - 4:end])[0]:
            raise ValueError("Bad PNG chunk/CRC")
        if kind == b"IHDR":
            if header is not None or offset != 8 or size != 13:
                raise ValueError("Invalid PNG header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            ended = size == 0 and end == len(data)
            break
        offset = end
    if not header or not ended:
        raise ValueError("Incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if not channels or depth != 8 or compression or filtering or interlace or not 1 <= width <= 4096 or not 1 <= height <= 4096:
        raise ValueError("Unsupported or excessive PNG layout")
    stride = width * channels + 1
    expected = stride * height
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise ValueError("Invalid PNG compression") from error
    if len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("Incomplete or excessive PNG image data")
    if any(pixels[row * stride] > 4 for row in range(height)):
        raise ValueError("Unknown PNG scanline filter")
    return {"width": width, "height": height, "decodedBytes": len(pixels)}
