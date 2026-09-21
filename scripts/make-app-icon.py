#!/usr/bin/env python3
"""Generate the Races app icon set.

A placeholder, and labelled as one: a horseshoe is legible at 60px and
unmistakably racing, which is all this has to be until there is real artwork.
Replace the PNGs (or this script) rather than working around them.

Written in pure Python with no imaging dependency, because the build
environment has none and an icon that cannot be regenerated is worse than a
plain one. PNG is simple enough to emit directly.

    python3 scripts/make-app-icon.py

Output is RGB with no alpha channel. App Store Connect rejects a 1024 marketing
icon that carries alpha, and the asset catalogue's 1024 slot is what Xcode
derives it from.
"""

import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
SUPERSAMPLE = 2  # rendered at 2048 and averaged down: 4 samples per pixel

OUT = Path(__file__).resolve().parent.parent / (
    "ios/Races/Races/Assets.xcassets/AppIcon.appiconset")


class Palette:
    def __init__(self, name, top, bottom, shoe, hole):
        self.name = name
        self.top = top          # background gradient, top
        self.bottom = bottom    # background gradient, bottom
        self.shoe = shoe
        self.hole = hole        # nail holes, punched in the shoe


# Racing green, which is the one colour every reader of a racecard expects.
LIGHT = Palette("AppIcon", (11, 92, 51), (7, 61, 34), (247, 244, 236), (11, 92, 51))
DARK = Palette("AppIcon-dark", (10, 30, 20), (4, 14, 9), (232, 228, 218), (10, 30, 20))
# The tinted variant is greyscale by design: the system supplies the colour, so
# anything but luminance here is thrown away.
TINTED = Palette("AppIcon-tinted", (24, 24, 24), (8, 8, 8), (236, 236, 236), (24, 24, 24))


def shoe_coverage(x, y, n):
    """1.0 inside the horseshoe, 0.0 outside, sampled at n×n per output pixel."""
    cx = n * SIZE / 2
    cy = n * SIZE * 0.53          # a shade low: the gap at the bottom reads better
    outer = n * SIZE * 0.325
    inner = n * SIZE * 0.205
    mid = (outer + inner) / 2
    arm = (outer - inner) / 2

    # The opening at the bottom, as a half-angle either side of straight down.
    gap = math.radians(52)

    dx = x - cx
    dy = y - cy
    dist = math.hypot(dx, dy)

    inside_ring = inner <= dist <= outer
    if inside_ring:
        # Angle from straight down, so the gap is symmetric about it.
        angle = math.atan2(dx, dy)
        if abs(angle) > gap:
            return 1.0

    # Rounded ends, so the shoe finishes as a shoe rather than a cut pipe.
    for sign in (-1, 1):
        ex = cx + sign * mid * math.sin(gap)
        ey = cy + mid * math.cos(gap)
        if math.hypot(x - ex, y - ey) <= arm:
            return 1.0

    return 0.0


def hole_coverage(x, y, n):
    """The nail holes. Six, three per arm, as a real shoe has."""
    cx = n * SIZE / 2
    cy = n * SIZE * 0.53
    mid = n * SIZE * 0.265
    radius = n * SIZE * 0.0235

    for sign in (-1, 1):
        for degrees in (34, 64, 94):
            angle = math.radians(degrees)
            hx = cx + sign * mid * math.sin(angle)
            hy = cy - mid * math.cos(angle)
            if math.hypot(x - hx, y - hy) <= radius:
                return 1.0
    return 0.0


def render(palette):
    n = SUPERSAMPLE
    big = n * SIZE
    half = big // 2

    # The design is symmetric about the vertical axis, so only the left half is
    # evaluated and the right is mirrored. Halves an otherwise slow loop.
    rows = []
    for y in range(big):
        t = y / (big - 1)
        bg = tuple(
            round(palette.top[i] + (palette.bottom[i] - palette.top[i]) * t)
            for i in range(3))

        left = bytearray()
        for x in range(half):
            if hole_coverage(x, y, n):
                colour = palette.hole
            elif shoe_coverage(x, y, n):
                colour = palette.shoe
            else:
                colour = bg
            left += bytes(colour)
        rows.append(left)

    # Average each n×n block down to one output pixel.
    out = bytearray()
    for oy in range(SIZE):
        line = bytearray()
        for ox in range(half // n):
            r = g = b = 0
            for dy in range(n):
                row = rows[oy * n + dy]
                for dx in range(n):
                    i = (ox * n + dx) * 3
                    r += row[i]
                    g += row[i + 1]
                    b += row[i + 2]
            count = n * n
            line += bytes((r // count, g // count, b // count))
        # Mirror to make the full width.
        mirrored = bytearray()
        for px in range(len(line) // 3 - 1, -1, -1):
            mirrored += line[px * 3:px * 3 + 3]
        out += b"\x00" + bytes(line) + bytes(mirrored)  # filter byte 0 per scanline
    return bytes(out)


def write_png(path, raw):
    def chunk(kind, payload):
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF)

    # Colour type 2 is RGB: no alpha channel, deliberately.
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    path.write_bytes(png)
    return len(png)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for palette in (LIGHT, DARK, TINTED):
        path = OUT / f"{palette.name}.png"
        size = write_png(path, render(palette))
        print(f"{path.name}: {SIZE}x{SIZE} RGB, {size:,} bytes")


if __name__ == "__main__":
    main()
