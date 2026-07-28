"""Static structure map for the ODYS BMS application image.

Read-only analysis. Mirrors the CRC-16/XMODEM scheme already proven on the
BLDC image (see lib/src/protocol/firmware_tools.dart) and tries to locate the
protection/config table that holds the charge-current limit.
"""

import sys
from collections import Counter


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= (b & 0xFF) << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def regions(buf: bytes, fill=0xFF, min_run=32):
    """Collapse the image into (start, end, kind) spans of fill vs content."""
    out, i, n = [], 0, len(buf)
    while i < n:
        if buf[i] == fill:
            j = i
            while j < n and buf[j] == fill:
                j += 1
            if j - i >= min_run:
                out.append((i, j, f"fill 0x{fill:02X}"))
                i = j
                continue
        j = i
        while j < n:
            if buf[j] == fill:
                k = j
                while k < n and buf[k] == fill:
                    k += 1
                if k - j >= min_run:
                    break
                j = k
            else:
                j += 1
        out.append((i, j, "content"))
        i = j
    return out


def entropy(chunk: bytes) -> float:
    if not chunk:
        return 0.0
    c = Counter(chunk)
    n = len(chunk)
    import math
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def main(path):
    buf = open(path, "rb").read()
    print(f"file      : {path}")
    print(f"size      : {len(buf)} bytes (0x{len(buf):X})")
    print()

    print("=== HEADER FIELDS ===")
    print(f"0x00 magic/model : {buf[0:5]!r}")
    print(f"0x05             : {buf[5]:#04x}")
    print(f"0x06             : {buf[6]:#04x}")
    print(f"0x07 version str : {buf[7:15]!r}  -> "
          f"{'.'.join(str(b - 0x30) for b in buf[7:11])} / "
          f"{'.'.join(str(b - 0x30) for b in buf[11:15])}")
    print(f"0x0F             : {buf[15]:#04x}")
    for off in range(0x10, 0x20):
        print(f"0x{off:02X}             : {buf[off]:#04x}")
    print()

    print("=== REGION MAP (runs of 0xFF >= 32 collapsed) ===")
    for s, e, kind in regions(buf):
        tag = ""
        if kind == "content":
            tag = f"  entropy={entropy(buf[s:e]):.2f}"
        print(f"0x{s:05X}-0x{e:05X}  {e-s:6d} bytes  {kind}{tag}")
    print()

    # Locate the real payload: first content span after the header block.
    spans = [(s, e) for s, e, k in regions(buf) if k == "content"]
    print("=== CRC-16/XMODEM PROBE ===")
    stored13 = (buf[0x13] << 8) | buf[0x14]
    print(f"stored BE16 @0x13 : 0x{stored13:04X}")
    stored11 = (buf[0x11] << 8) | buf[0x12]
    print(f"stored BE16 @0x11 : 0x{stored11:04X}   (LE16 = 0x{buf[0x11] | (buf[0x12] << 8):04X})")
    print()

    # Try the BLDC recipe and a grid of plausible windows.
    candidates = []
    starts = [0x00, 0x10, 0x15, 0x20, 0x80, 0x100, 0x800, 0x8C0, 0x8D0]
    if spans:
        starts.append(spans[-1][0])
        starts.append(spans[0][0])
    for st in sorted(set(starts)):
        for en in sorted(set([len(buf), 0x5800, 0x5000 + st, spans[-1][1] if spans else len(buf)])):
            if not (0 <= st < en <= len(buf)):
                continue
            body = bytearray(buf[st:en])
            # zeroed-CRC variant, matching how the BLDC image is built
            z = bytearray(buf)
            z[0x13] = z[0x14] = 0
            for label, data in (("raw", bytes(body)), ("crc-zeroed", bytes(z[st:en]))):
                c = crc16_xmodem(data)
                if c == stored13:
                    candidates.append((st, en, label, c))
    if candidates:
        for st, en, label, c in candidates:
            print(f"MATCH  0x{st:05X}..0x{en:05X}  [{label}]  crc=0x{c:04X} == stored@0x13")
    else:
        print("no window in the probed grid reproduces the value at 0x13")
    print()

    print("=== 16-BIT VALUE SCAN: plausible cell-voltage thresholds (mV) ===")
    print("looking for LE16 in 2400..4300 mV clustered within 64-byte windows")
    hits = []
    for off in range(0, len(buf) - 1):
        v = buf[off] | (buf[off + 1] << 8)
        if 2400 <= v <= 4300:
            hits.append((off, v))
    buckets = {}
    for off, v in hits:
        buckets.setdefault(off // 64, []).append((off, v))
    dense = sorted((k, v) for k, v in buckets.items() if len(v) >= 4)
    if not dense:
        print("  none")
    for k, vals in dense[:25]:
        pretty = " ".join(f"0x{o:04X}={v}" for o, v in vals[:10])
        print(f"  window 0x{k*64:05X}: {len(vals)} hits  {pretty}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "E:/files/bms_app_meger.bin")
