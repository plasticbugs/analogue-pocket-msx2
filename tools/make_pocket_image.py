#!/usr/bin/env python3
"""Convert images into the Pocket's graphical asset .bin format.

The Pocket stores core icons (36x36) and platform images (521x165) as
16-bit monochrome: one brightness byte followed by 0x00 per pixel, with
the whole image rotated 90 degrees counter-clockwise (verified against
the icon.bin/msx.bin shipped by AnalogueOS-compatible cores).

Sources accepted:
  * .bin  -- AnalogueOS *library* image (magic "\x20IPA"/"\x10IPA",
             u16 width, u16 height, BGRA rotated 90 CCW), e.g. an
             author image exported by community library tools
  * .bmp  -- 24/32-bit uncompressed (use `sips -s format bmp` for
             anything else)

Usage:
    make_pocket_image.py icon     input.{bin,bmp} icon.bin [--invert]
    make_pocket_image.py platform input.{bin,bmp} platform.bin
                         [--invert] [--edges] [--bg-knockout N]

--invert       flip black/white (Pocket art is light-on-black)
--edges        Sobel line-art rendering instead of tones
--bg-knockout  force pixels brighter than N to black *after* invert
"""
import argparse
import struct
import sys


def load_bmp(path):
    b = open(path, "rb").read()
    off = struct.unpack("<I", b[10:14])[0]
    w, h = struct.unpack("<ii", b[18:26])
    bpp = struct.unpack("<H", b[28:30])[0]
    if bpp not in (24, 32):
        sys.exit(f"{path}: {bpp}bpp BMP unsupported, re-export as 24-bit")
    n = bpp // 8
    rowsz = (w * n + 3) // 4 * 4
    g = [[0] * w for _ in range(abs(h))]
    for y in range(abs(h)):
        row = b[off + y * rowsz:off + (y + 1) * rowsz]
        ty = abs(h) - 1 - y if h > 0 else y
        for x in range(w):
            p = row[x * n:(x + 1) * n]
            g[ty][x] = round(0.299 * p[2] + 0.587 * p[1] + 0.114 * p[0])
    return g


def load_library_bin(path):
    b = open(path, "rb").read()
    magic = struct.unpack("<I", b[0:4])[0]
    if magic not in (0x41504910, 0x41504920):
        sys.exit(f"{path}: not a library image (magic {magic:#x})")
    w, h = struct.unpack("<HH", b[4:8])
    p = b[8:]
    st = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            i = (y * w + x) * 4
            bl, gr, r = p[i], p[i + 1], p[i + 2]
            st[y][x] = round(0.299 * r + 0.587 * gr + 0.114 * bl)
    # stored rotated 90 CCW; rotate 90 CW back to upright
    return [[st[h - 1 - j][i] for j in range(h)] for i in range(w)]


def box_resize(g, ow, oh):
    ih, iw = len(g), len(g[0])
    out = [[0] * ow for _ in range(oh)]
    for oy in range(oh):
        y0, y1 = oy * ih // oh, max(oy * ih // oh + 1, (oy + 1) * ih // oh)
        for ox in range(ow):
            x0, x1 = ox * iw // ow, max(ox * iw // ow + 1, (ox + 1) * iw // ow)
            s = sum(g[y][x] for y in range(y0, y1) for x in range(x0, x1))
            out[oy][ox] = s // ((y1 - y0) * (x1 - x0))
    return out


def sobel(g):
    h, w = len(g), len(g[0])
    out = [[0] * w for _ in range(h)]
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            gx = (g[y-1][x+1] + 2*g[y][x+1] + g[y+1][x+1]
                  - g[y-1][x-1] - 2*g[y][x-1] - g[y+1][x-1])
            gy = (g[y+1][x-1] + 2*g[y+1][x] + g[y+1][x+1]
                  - g[y-1][x-1] - 2*g[y-1][x] - g[y-1][x+1])
            out[y][x] = min(255, (abs(gx) + abs(gy)) // 3)
    return out


def stretch(g):
    lo = min(min(r) for r in g)
    hi = max(max(r) for r in g)
    if hi <= lo:
        return g
    return [[(v - lo) * 255 // (hi - lo) for v in r] for r in g]


def emit(g, path):
    h, w = len(g), len(g[0])
    st = [[g[j][w - 1 - i] for j in range(h)] for i in range(w)]  # rot 90 CCW
    with open(path, "wb") as f:
        for row in st:
            for v in row:
                f.write(bytes((max(0, min(255, v)), 0)))
    print(f"{path}: {w}x{h}, {w*h*2} bytes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["icon", "platform"])
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--invert", action="store_true")
    ap.add_argument("--edges", action="store_true")
    ap.add_argument("--bg-knockout", type=int, default=None)
    args = ap.parse_args()

    g = (load_library_bin(args.src) if args.src.endswith(".bin")
         else load_bmp(args.src))

    W, H = (36, 36) if args.kind == "icon" else (521, 165)
    # scale to fit, centered on black
    ih, iw = len(g), len(g[0])
    s = min(W / iw, H / ih)
    sw, sh = max(1, round(iw * s)), max(1, round(ih * s))
    small = box_resize(g, sw, sh)
    if args.edges:
        small = sobel(small)
    small = stretch(small)
    if args.invert:
        small = [[255 - v for v in r] for r in small]
    if args.bg_knockout is not None:
        small = [[0 if v > args.bg_knockout else v for v in r] for r in small]
    canvas = [[0] * W for _ in range(H)]
    oy, ox = (H - sh) // 2, (W - sw) // 2
    for y in range(sh):
        for x in range(sw):
            canvas[oy + y][ox + x] = small[y][x]
    emit(canvas, args.out)


if __name__ == "__main__":
    main()
