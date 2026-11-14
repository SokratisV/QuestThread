"""Draws logo.png (512x512): the CurseForge project avatar, in the family style of the other addon logos
(dark rounded square, thick coloured border, glowing icon, one sparkle).

  python -I tools/make-logo.py

Pure Python (no imaging library). Reuses the chain geometry from make-chain-icon.py.
"""
import importlib.util
import math
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("chainicon", HERE / "make-chain-icon.py")
chain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chain)
# Links further apart than in the small icon, so the two rings read as interlocked at this size.
LINK_GAP = 16.0
chain.C1 = (32 - LINK_GAP * chain.ux, 32 - LINK_GAP * chain.uy)
chain.C2 = (32 + LINK_GAP * chain.ux, 32 + LINK_GAP * chain.uy)

SIZE, SS = 512, 3
CHAIN_SCALE = 4.5                       # logo pixels per chain-icon unit
CX, CY = 256, 264                       # chain centre
BORDER = (47, 182, 214)                 # teal, to sit beside the gold and orange logos
OUTLINE = (27, 29, 35)
HALF, RADIUS = 240, 96                  # outer rounded square (16 px inset)
CREAM = (255, 244, 214)


def rrect_d(x, y):
    """Signed distance to the outer rounded square (negative inside)."""
    dx, dy = abs(x - 256) - (HALF - RADIUS), abs(y - 256) - (HALF - RADIUS)
    return math.hypot(max(dx, 0.0), max(dy, 0.0)) + min(max(dx, dy), 0.0) - RADIUS


def blend(base, top, a):
    return tuple(base[i] * (1 - a) + top[i] * a for i in range(3))


def sparkle(x, y):
    """A four-point star (an astroid) at the bottom right; returns coverage 0 or 1."""
    sx, sy = abs(x - 398), abs(y - 392)
    return 1.0 if (sx / 30) ** 0.6 + (sy / 30) ** 0.6 <= 1.0 else 0.0


def sample(x, y):
    d = rrect_d(x, y)
    if d > 0:
        return None
    if d > -7:
        return OUTLINE + (1.0,)
    if d > -27:
        return BORDER + (1.0,)
    # interior: vertical gradient, a warm glow behind the chain, the chain, the sparkle
    t = (y - 40) / 432
    col = (32 - 15 * t, 35 - 16 * t, 43 - 19 * t)
    r = math.hypot(x - CX, y - CY)
    if r < 200:
        col = blend(col, (240, 180, 60), 0.30 * (1 - r / 200) ** 2)
    if abs(x - CX) < 175 and abs(y - CY) < 175:
        c = chain.sample(32 + (x - CX) / CHAIN_SCALE, 32 + (y - CY) / CHAIN_SCALE)
        if c:
            col = c
    if sparkle(x, y):
        col = CREAM
    return col + (1.0,)


def render():
    out = []
    for y in range(SIZE):
        for x in range(SIZE):
            r = g = b = a = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                    if c:
                        r += c[0]; g += c[1]; b += c[2]; a += 1
            n = SS * SS
            out.append((round(r / a), round(g / a), round(b / a), round(255 * a / n)) if a else (0, 0, 0, 0))
    return out


def write_png(path, px):
    raw = b"".join(b"\x00" + b"".join(struct.pack("BBBB", *px[y * SIZE + x]) for x in range(SIZE)) for y in range(SIZE))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    write_png(HERE.parent / "logo.png", render())
    print("wrote logo.png")
