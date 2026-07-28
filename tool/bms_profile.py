"""Pass 2: locate structured (non-code) regions in the BMS body and compare
header layouts across the three ODYS images."""

import math
import sys
from collections import Counter


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= (b & 0xFF) << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def entropy(chunk: bytes) -> float:
    if not chunk:
        return 0.0
    c = Counter(chunk)
    n = len(chunk)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def thumb_ratio(chunk: bytes) -> float:
    """Crude density of common Thumb epilogue/prologue halfwords."""
    if len(chunk) < 2:
        return 0.0
    common = {0x4770, 0xB580, 0xB570, 0xB510, 0xB508, 0xBD80, 0xBD70,
              0xBD10, 0xBD08, 0xB5F0, 0xBDF0, 0x46C0}
    hits = 0
    total = len(chunk) // 2
    for i in range(0, len(chunk) - 1, 2):
        hw = chunk[i] | (chunk[i + 1] << 8)
        if hw in common:
            hits += 1
    return hits / max(total, 1)


def header_probe(path):
    buf = open(path, "rb").read()
    name = path.split("/")[-1]
    magic = bytes(b for b in buf[0:5] if 32 <= b < 127)
    be_len = (buf[0x11] << 8) | buf[0x12]
    be_crc = (buf[0x13] << 8) | buf[0x14]
    print(f"{name:26s} size=0x{len(buf):05X}  magic={magic!r:10s} "
          f"ver={buf[7:15]!r}  len@0x11=0x{be_len:04X}  crc@0x13=0x{be_crc:04X}")
    # try body windows
    for start in (0x80, 0x100, 0x800):
        if start >= len(buf):
            continue
        c = crc16_xmodem(buf[start:])
        if c == be_crc:
            print(f"{'':26s}   -> CRC16/XMODEM over 0x{start:04X}..EOF "
                  f"= 0x{c:04X}  MATCH  (body len 0x{len(buf)-start:04X})")
    return buf


def main():
    print("=== HEADER COMPARISON ACROSS IMAGES ===")
    for p in ("E:/files/bms_app_meger.bin",
              "E:/files/bldc_app_meger.bin",
              "E:/files/meter_app_meger.bin"):
        try:
            header_probe(p)
        except OSError as e:
            print(f"  {p}: {e}")
    print()

    buf = open("E:/files/bms_app_meger.bin", "rb").read()
    BODY_S, BODY_E = 0x800, 0x5394

    print("=== 256-BYTE PROFILE OF BODY (entropy / thumb-density) ===")
    print("low entropy + low thumb density = candidate data table")
    rows = []
    for off in range(BODY_S, BODY_E, 256):
        chunk = buf[off:min(off + 256, BODY_E)]
        rows.append((off, entropy(chunk), thumb_ratio(chunk), chunk))
    for off, ent, thr, chunk in rows:
        flag = ""
        if ent < 5.0 and thr < 0.01:
            flag = "   <== DATA-LIKE"
        elif thr > 0.04:
            flag = "   (code)"
        print(f"0x{off:05X}  entropy={ent:5.2f}  thumb={thr:5.3f}{flag}")


if __name__ == "__main__":
    main()
