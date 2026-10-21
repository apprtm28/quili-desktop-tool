#!/usr/bin/env python3
"""Draws the app icon (the green button with the robot face) and writes every size the apps need.

Pure Python, no dependencies:  python3 tools/make_icons.py
  windows/assets/app.ico                       exe, tray and window icon
  mac/Icon/AppIcon.iconset/icon_*.png          input for `iconutil` (mac/build.sh turns it into AppIcon.icns)
"""
import math
import os
import struct
import zlib

GREEN = (0x3D, 0xBE, 0x4A)
DARK = (0x1F, 0x2A, 0x24)
ROBOT_SCALE = 0.64  # robot size relative to the circle

# The robot on a 24x24 canvas, same drawing as the overlay button, back to front.
# ("line", x1, y1, x2, y2, thickness, colour) | ("circle", cx, cy, r, colour) | ("rrect", x, y, w, h, r, colour)
ROBOT = [
    ("line", 12, 3.5, 12, 7, 1.6, DARK),
    ("circle", 12, 3.2, 1.6, DARK),
    ("rrect", 2, 11, 3, 5, 1.2, DARK),
    ("rrect", 19, 11, 3, 5, 1.2, DARK),
    ("rrect", 4.5, 7, 15, 13, 3.5, DARK),
    ("circle", 9.6, 12.4, 1.6, GREEN),
    ("circle", 14.4, 12.4, 1.6, GREEN),
    ("line", 9.5, 16.8, 14.5, 16.8, 1.4, GREEN),
]


def inside(shape, x, y):
    kind = shape[0]
    if kind == "circle":
        _, cx, cy, r, _ = shape
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
    if kind == "rrect":
        _, x0, y0, w, h, r, _ = shape
        if not (x0 <= x <= x0 + w and y0 <= y <= y0 + h):
            return False
        dx = max(x0 + r - x, 0, x - (x0 + w - r))
        dy = max(y0 + r - y, 0, y - (y0 + h - r))
        return dx * dx + dy * dy <= r * r
    _, x1, y1, x2, y2, t, _ = shape  # line with round caps
    vx, vy = x2 - x1, y2 - y1
    length2 = vx * vx + vy * vy
    s = 0 if length2 == 0 else max(0, min(1, ((x - x1) * vx + (y - y1) * vy) / length2))
    return (x - (x1 + s * vx)) ** 2 + (y - (y1 + s * vy)) ** 2 <= (t / 2) ** 2


def render(size, samples=4):
    """RGBA bytes of the icon at size x size, anti-aliased by supersampling."""
    u = size * ROBOT_SCALE / 24
    offset = (size - size * ROBOT_SCALE) / 2
    half = size / 2
    out = bytearray()
    for py in range(size):
        for px in range(size):
            r = g = b = a = 0
            for sy in range(samples):
                for sx in range(samples):
                    x = px + (sx + 0.5) / samples
                    y = py + (sy + 0.5) / samples
                    if (x - half) ** 2 + (y - half) ** 2 > half * half:
                        continue
                    colour = GREEN
                    rx, ry = (x - offset) / u, (y - offset) / u
                    for shape in ROBOT:
                        if inside(shape, rx, ry):
                            colour = shape[-1]
                    r += colour[0]; g += colour[1]; b += colour[2]; a += 1
            n = samples * samples
            if a:
                out += bytes((r // a, g // a, b // a, round(255 * a / n)))
            else:
                out += b"\0\0\0\0"
    return bytes(out)


def png(size, rgba):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    rows = b"".join(b"\0" + rgba[y * size * 4:(y + 1) * size * 4] for y in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def ico(frames):
    """frames: {size: png bytes} -> .ico with PNG-compressed entries."""
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    entries, data = b"", b""
    for size, image in sorted(frames.items()):
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset + len(data))
        data += image
    return header + entries + data


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sizes = sorted({16, 24, 32, 48, 64, 128, 256, 512})
    frames = {s: png(s, render(s, samples=4 if s <= 256 else 3)) for s in sizes}

    win = os.path.join(root, "windows", "assets")
    os.makedirs(win, exist_ok=True)
    with open(os.path.join(win, "app.ico"), "wb") as f:
        f.write(ico({s: frames[s] for s in (16, 24, 32, 48, 64, 128, 256)}))

    iconset = os.path.join(root, "mac", "Icon", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            if px in frames:
                name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
                with open(os.path.join(iconset, name), "wb") as f:
                    f.write(frames[px])
    print("wrote", os.path.join(win, "app.ico"), "and", iconset)


if __name__ == "__main__":
    main()
