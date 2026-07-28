"""Generates the ODYS Service Tool app icon.

The mark is a tapered gauge sweep with a needle: an open ring that reads as
both an "O" and a speedometer dial, thin at the zero end and thickening toward
maximum. Colours come from the app palette in lib/src/ui/odys_theme.dart.

Renders at 4x and downsamples, which is cheaper than writing an anti-aliased
rasteriser and produces cleaner edges than PIL's own arc drawing.

    python tool/make_icon.py
"""

from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFilter

# ── Palette (must track AppColors) ──
BG_OUTER = (0x05, 0x08, 0x0E)
BG_INNER = (0x14, 0x20, 0x33)
ARC_STOPS = [
    (0.0, (0x1C, 0x84, 0x7C)),   # zero end, deep teal
    (0.55, (0x38, 0xD3, 0x9F)),  # primary
    (1.0, (0x7A, 0xEC, 0xC0)),   # highlight at maximum
]
NEEDLE = (0xEA, 0xF1, 0xF8)
HUB_RING = (0xEA, 0xF1, 0xF8)

# ── Geometry, in units of the mark's radius ──
ARC_START_DEG = 230.0   # bottom-left; sweep runs clockwise from here
ARC_SWEEP_DEG = 280.0   # leaves an 80 degree gap centred on the bottom
ARC_THIN = 0.090
ARC_THICK = 0.208
NEEDLE_ANGLE_DEG = 55.0
NEEDLE_LENGTH = 0.64
NEEDLE_BASE_HALF = 0.075
NEEDLE_TAIL = 0.16
HUB_RADIUS = 0.108
HUB_RING_WIDTH = 0.042

SS = 4  # supersampling factor
OUT_SIZE = 1024


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def arc_colour(t: float) -> tuple[int, int, int]:
    """Colour along the sweep, piecewise-linear between ARC_STOPS."""
    for (t0, c0), (t1, c1) in zip(ARC_STOPS, ARC_STOPS[1:]):
        if t <= t1:
            local = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(int(round(lerp(c0[i], c1[i], local))) for i in range(3))
    return ARC_STOPS[-1][1]


def thickness(t: float) -> float:
    """Sweep width at position t. Eased so the taper is not a flat ramp."""
    return lerp(ARC_THIN, ARC_THICK, t * t * (3 - 2 * t))


def point(cx: float, cy: float, radius: float, angle_deg: float):
    a = math.radians(angle_deg)
    # Screen y grows downward, so the sine is negated to keep standard
    # orientation (0 degrees at the right, angles counterclockwise).
    return cx + radius * math.cos(a), cy - radius * math.sin(a)


def draw_gauge(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float) -> None:
    steps = 720
    ring_r = r * 0.80

    for i in range(steps):
        t0 = i / steps
        t1 = (i + 1) / steps
        a0 = ARC_START_DEG - ARC_SWEEP_DEG * t0
        a1 = ARC_START_DEG - ARC_SWEEP_DEG * t1
        h0 = thickness(t0) * r / 2
        h1 = thickness(t1) * r / 2

        quad = [
            point(cx, cy, ring_r + h0, a0),
            point(cx, cy, ring_r + h1, a1),
            point(cx, cy, ring_r - h1, a1),
            point(cx, cy, ring_r - h0, a0),
        ]
        # Each segment gets its own colour, which is what produces the gradient.
        # Segments overlap by a fraction of a pixel at this step count, so no
        # seams show after downsampling.
        draw.polygon(quad, fill=arc_colour((t0 + t1) / 2))

    # Round both terminals of the sweep.
    for t in (0.0, 1.0):
        angle = ARC_START_DEG - ARC_SWEEP_DEG * t
        h = thickness(t) * r / 2
        px, py = point(cx, cy, ring_r, angle)
        draw.ellipse([px - h, py - h, px + h, py + h], fill=arc_colour(t))


def draw_needle(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float) -> None:
    tip = point(cx, cy, r * NEEDLE_LENGTH, NEEDLE_ANGLE_DEG)
    left = point(cx, cy, r * NEEDLE_BASE_HALF, NEEDLE_ANGLE_DEG + 90)
    right = point(cx, cy, r * NEEDLE_BASE_HALF, NEEDLE_ANGLE_DEG - 90)
    # A short counterweight past the hub stops the needle reading as an arrow.
    # Blunt rather than pointed, so it does not compete with the tip.
    tail_l = point(cx, cy, r * NEEDLE_TAIL, NEEDLE_ANGLE_DEG + 155)
    tail_r = point(cx, cy, r * NEEDLE_TAIL, NEEDLE_ANGLE_DEG - 155)
    draw.polygon([tip, left, tail_l, tail_r, right], fill=NEEDLE)

    outer = r * HUB_RADIUS
    inner = outer - r * HUB_RING_WIDTH
    draw.ellipse([cx - outer, cy - outer, cx + outer, cy + outer], fill=HUB_RING)
    draw.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=BG_INNER)


def radial_background(size: int) -> Image.Image:
    """Dark field with a soft off-centre glow, so the tile is not flat."""
    bg = Image.new("RGB", (size, size), BG_OUTER)
    pixels = bg.load()
    cx = cy = size / 2
    focus_x, focus_y = size * 0.42, size * 0.36
    max_d = math.hypot(size, size) * 0.62
    # Coarse grid then blur: per-pixel Python over 4096^2 would take minutes.
    step = max(1, size // 256)
    for y in range(0, size, step):
        for x in range(0, size, step):
            d = math.hypot(x - focus_x, y - focus_y) / max_d
            d = min(1.0, d)
            colour = tuple(
                int(round(lerp(BG_INNER[i], BG_OUTER[i], d ** 0.85)))
                for i in range(3)
            )
            for yy in range(y, min(y + step, size)):
                for xx in range(x, min(x + step, size)):
                    pixels[xx, yy] = colour
    del cx, cy
    return bg.filter(ImageFilter.GaussianBlur(radius=size / 90))


def render(full_bleed: bool, mark_fraction: float) -> Image.Image:
    size = OUT_SIZE * SS
    if full_bleed:
        base = radial_background(size).convert("RGBA")
    else:
        base = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    r = size * mark_fraction / 2
    draw_gauge(draw, size / 2, size / 2, r)
    draw_needle(draw, size / 2, size / 2, r)

    base.alpha_composite(layer)
    return base.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(os.path.dirname(here), "assets", "brand")
    os.makedirs(out_dir, exist_ok=True)

    # Full-bleed tile for iOS and the legacy Android icon.
    icon = render(full_bleed=True, mark_fraction=0.74)
    icon.convert("RGB").save(os.path.join(out_dir, "odys_icon.png"))

    # Adaptive-icon foreground: transparent, mark held inside the 66/108 safe
    # circle so launcher masks and animations cannot clip it.
    foreground = render(full_bleed=False, mark_fraction=0.50)
    foreground.save(os.path.join(out_dir, "odys_icon_fg.png"))

    print("wrote", os.path.join(out_dir, "odys_icon.png"))
    print("wrote", os.path.join(out_dir, "odys_icon_fg.png"))


if __name__ == "__main__":
    main()
