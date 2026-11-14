"""Draws the chain-link icon: two interlocked links, gold with a dark outline, 64x64 32-bit TGA.

  python -I tools/make-chain-icon.py            writes Chain.tga next to the addon's TOC
  python -I tools/make-chain-icon.py preview.png   also writes a PNG preview

Pure Python (no imaging library). 4x4 supersampling for smooth edges.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE, SS = 64, 4
R, L, T, OUT = 9.0, 11.0, 4.5, 1.4          # outer radius, half straight length, ring thickness, outline
FILL = (255, 214, 92)
EDGE = (58, 38, 8)
K = 12.0                                    # half the distance between the two link centres
ux, uy = 1 / math.sqrt(2), -1 / math.sqrt(2)  # chain direction (towards bottom-right)
vx, vy = 1 / math.sqrt(2), 1 / math.sqrt(2)   # perpendicular
C1 = (32 - K * ux, 32 - K * uy)
C2 = (32 + K * ux, 32 + K * uy)


def band(px, py, c):
    """Return 'fill', 'edge' or None for a point relative to one stadium-shaped ring."""
    dx, dy = px - c[0], py - c[1]
    t = dx * ux + dy * uy
    s = dx * vx + dy * vy
    d = math.hypot(max(abs(t) - L, 0.0), s)
    if R - T <= d <= R:
        return "fill"
    if R - T - OUT <= d <= R + OUT:
        return "edge"
    return None


def sample(px, py):
    a, b = band(px, py, C1), band(px, py, C2)
    # Over/under: on one side of the chain axis link 1 passes over link 2, on the other side under it.
    p = (px - 32) * vx + (py - 32) * vy
    order = (a, b) if p > 0 else (b, a)
    for layer in order:
        if layer == "fill":
            return FILL
        # an edge only wins when nothing above it is a fill
    for layer in order:
        if layer == "edge":
            return EDGE
    return None


def render():
    px = []
    for y in range(SIZE):
        for x in range(SIZE):
            r = g = b = a = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                    if c:
                        r += c[0]; g += c[1]; b += c[2]; a += 1
            n = SS * SS
            if a:
                px.append((round(r / a), round(g / a), round(b / a), round(255 * a / n)))
            else:
                px.append((0, 0, 0, 0))
    return px


def write_tga(path, px):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)  # top-left origin, 8 alpha bits
    body = b"".join(struct.pack("BBBB", b, g, r, a) for r, g, b, a in px)
    Path(path).write_bytes(header + body)


def write_png(path, px):
    raw = b"".join(b"\x00" + b"".join(struct.pack("BBBB", *px[y * SIZE + x]) for x in range(SIZE)) for y in range(SIZE))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    pixels = render()
    write_tga(Path(__file__).resolve().parent.parent / "Chain.tga", pixels)
    if len(sys.argv) > 1:
        write_png(sys.argv[1], pixels)
    print("wrote Chain.tga")
