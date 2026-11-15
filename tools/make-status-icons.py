"""Draws Status.tga: the four step-status icons side by side, 128x32 (four 32x32 cells), 32-bit TGA.

  cell 0  done        green disc, check mark
  cell 1  in log      blue disc, question mark
  cell 2  available   gold disc, exclamation mark
  cell 3  locked      red disc, padlock

  python -I tools/make-status-icons.py              writes Status.tga next to the addon's TOC
  python -I tools/make-status-icons.py preview.png  also writes a 4x PNG preview

Pure Python (no imaging library), 4x4 supersampling.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

CELL, CELLS, SS = 32, 4, 4
W, H = CELL * CELLS, CELL
CX = CY = 16.0
R = 14.6

# (disc fill, outline, glyph)
STYLES = [
    ((47, 128, 66), (20, 58, 30), (222, 250, 228)),     # done
    ((40, 92, 150), (16, 40, 72), (196, 222, 255)),     # in log
    ((178, 140, 20), (82, 62, 6), (255, 240, 170)),     # available
    ((150, 52, 52), (66, 22, 22), (255, 206, 206)),     # locked
]


def seg_d(px, py, a, b):
    ax, ay, bx, by = a[0], a[1], b[0], b[1]
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def poly(px, py, pts, w):
    return any(seg_d(px, py, pts[i], pts[i + 1]) <= w / 2 for i in range(len(pts) - 1))


def dot(px, py, c, r):
    return math.hypot(px - c[0], py - c[1]) <= r


def round_rect(px, py, x0, y0, x1, y1, r):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    dx, dy = max(abs(px - cx) - hx, 0.0), max(abs(py - cy) - hy, 0.0)
    return math.hypot(dx, dy) <= r


def glyph(kind, px, py):
    if kind == 0:  # check
        return poly(px, py, [(9.5, 16.8), (14, 21.2), (23, 11)], 3.4)
    if kind == 1:  # question mark
        arc = [(11.4, 12.8), (12.4, 9.8), (15, 8.2), (17.9, 8.5), (20.1, 10.5), (20.2, 13.1), (18.6, 15.2), (16, 16.6), (16, 18.4)]
        return poly(px, py, arc, 2.9) or dot(px, py, (16, 23), 1.8)
    if kind == 2:  # exclamation mark
        return poly(px, py, [(16, 8.5), (16, 18)], 3.6) or dot(px, py, (16, 22.6), 2.0)
    # padlock: shackle, body, keyhole cut out
    shackle = poly(px, py, [(12.6, 15.5), (12.6, 12.6), (14, 10.2), (16, 9.4), (18, 10.2), (19.4, 12.6), (19.4, 15.5)], 2.3)
    body = round_rect(px, py, 10, 15, 22, 24, 1.6)
    hole = dot(px, py, (16, 18.8), 1.4) or poly(px, py, [(16, 18.8), (16, 21.4)], 1.7)
    return shackle or (body and not hole)


def sample(x, y):
    cell = int(x // CELL)
    px, py = x - cell * CELL, y
    d = math.hypot(px - CX, py - CY)
    fill, edge, ink = STYLES[cell]
    if d > R + 1.2:
        return None
    if d > R - 0.2:
        return edge
    if glyph(cell, px, py):
        return ink
    return fill


def render():
    out = []
    for y in range(H):
        for x in range(W):
            r = g = b = a = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                    if c:
                        r += c[0]; g += c[1]; b += c[2]; a += 1
            n = SS * SS
            out.append((round(r / a), round(g / a), round(b / a), round(255 * a / n)) if a else (0, 0, 0, 0))
    return out


def write_tga(path, px):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, W, H, 32, 0x28)  # top-left origin, 8 alpha bits
    Path(path).write_bytes(header + b"".join(struct.pack("BBBB", b, g, r, a) for r, g, b, a in px))


def write_png(path, px, scale=4):
    rows = []
    for y in range(H):
        line = b"".join(struct.pack("BBBB", *px[y * W + x]) * scale for x in range(W))
        rows.extend([b"\x00" + line] * scale)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W * scale, H * scale, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    pixels = render()
    write_tga(Path(__file__).resolve().parent.parent / "Status.tga", pixels)
    if len(sys.argv) > 1:
        write_png(sys.argv[1], pixels)
    print("wrote Status.tga")
