#!/usr/bin/env python3
"""Render the on-screen keyboard panel bitmap for the OSK overlay.

Produces four 240x72 1bpp pages of key legends on a 15-column grid:
Japanese base, Japanese shifted (+4096), International base (+8192),
International shifted (+12288). The two layouts share the same key
geometry and scancodes -- both address the same key-matrix positions,
and the loaded BIOS decides what each position types -- so the pages
differ only in printed legends. Output is a Quartus MIF (for the spram
init) and a plain hex file (for iverilog testbenches), 30 bytes per
row, MSB = leftmost pixel, 16384 bytes for the BRAM's 14-bit address
space.

Usage: tools/make_osk_panel.py [--preview]
Writes rtl/rom/osk_panel.mif and rtl/rom/osk_panel.hex.
"""
import os
import sys

W, H = 240, 72
CELL_W, CELL_H = 16, 12

FONT = {  # 3x5, rows top-down, 3 bits each (MSB left)
    'A': "010 101 111 101 101", 'B': "110 101 110 101 110",
    'C': "011 100 100 100 011", 'D': "110 101 101 101 110",
    'E': "111 100 110 100 111", 'F': "111 100 110 100 100",
    'G': "011 100 101 101 011", 'H': "101 101 111 101 101",
    'I': "111 010 010 010 111", 'J': "001 001 001 101 010",
    'K': "101 110 100 110 101", 'L': "100 100 100 100 111",
    'M': "101 111 101 101 101", 'N': "110 101 101 101 101",
    'O': "010 101 101 101 010", 'P': "110 101 110 100 100",
    'Q': "010 101 101 110 011", 'R': "110 101 110 101 101",
    'S': "011 100 010 001 110", 'T': "111 010 010 010 010",
    'U': "101 101 101 101 111", 'V': "101 101 101 101 010",
    'W': "101 101 101 111 101", 'X': "101 101 010 101 101",
    'Y': "101 101 010 010 010", 'Z': "111 001 010 100 111",
    '0': "010 101 101 101 010", '1': "010 110 010 010 111",
    '2': "110 001 010 100 111", '3': "111 001 010 001 110",
    '4': "101 101 111 001 001", '5': "111 100 110 001 110",
    '6': "011 100 110 101 010", '7': "111 001 010 010 010",
    '8': "010 101 010 101 010", '9': "010 101 011 001 110",
    '-': "000 000 111 000 000", '=': "000 111 000 111 000",
    '[': "011 010 010 010 011", ']': "110 010 010 010 110",
    ';': "000 010 000 010 100", "'": "010 010 000 000 000",
    ',': "000 000 000 010 100", '.': "000 000 000 000 010",
    '/': "001 001 010 100 100", '\\': "100 100 010 001 001",
    '`': "100 010 000 000 000", '@': "010 101 111 100 011",
    ' ': "000 000 000 000 000",
    '!': "010 010 010 000 010", '"': "101 101 000 000 000",
    '#': "101 111 101 111 101", '$': "011 110 010 011 110",
    '%': "101 001 010 100 101", '^': "010 101 000 000 000",
    '&': "010 101 010 101 011", '*': "101 010 111 010 101",
    '(': "001 010 010 010 001", ')': "100 010 010 010 100",
    '_': "000 000 000 000 111", '+': "000 010 111 010 000",
    '{': "001 010 110 010 001", '}': "100 010 011 010 100",
    ':': "000 010 000 010 000", '<': "001 010 100 010 001",
    '>': "100 010 001 010 100", '?': "110 001 010 000 010",
    '|': "010 010 010 010 010", '~': "000 001 111 100 000",
    'Y#': "101 010 111 010 111",
}

# shifted legends per layout: what the matrix positions actually type
# under the matching BIOS. Letters and named keys keep their labels --
# caps state implies their case. ('Y#' is the yen-sign glyph; JIS 0 has
# no shifted character.)
ALT_JP = {
    '1': '!', '2': '"', '3': '#', '4': '$', '5': '%', '6': '&',
    '7': "'", '8': '(', '9': ')', '-': '=', '^': '~', 'Y#': '|',
    '@': '`', '[': '{', ';': '+', ':': '*', ']': '}',
    ',': '<', '.': '>', '/': '?',
}
ALT_INTL = {
    '1': '!', '2': '@', '3': '#', '4': '$', '5': '%', '6': '^',
    '7': '&', '8': '*', '9': '(', '0': ')', '-': '_', '=': '+',
    '\\': '|', '[': '{', ']': '}', ';': ':', "'": '"', '`': '~',
    ',': '<', '.': '>', '/': '?',
}

# (label, row, col, cell-span) on a 15-column grid. The two layouts
# share every key position; only legends differ.
LAYOUT_JP = [
    ("ESC",0,0,1),("F1",0,1,1),("F2",0,2,1),("F3",0,3,1),("F4",0,4,1),
    ("F5",0,5,1),("STOP",0,6,2),("HOME",0,8,2),("INS",0,10,2),("DEL",0,12,2),
    ("TAB",0,14,1),
    ("1",1,0,1),("2",1,1,1),("3",1,2,1),("4",1,3,1),("5",1,4,1),("6",1,5,1),
    ("7",1,6,1),("8",1,7,1),("9",1,8,1),("0",1,9,1),("-",1,10,1),("^",1,11,1),
    ("Y#",1,12,1),("BS",1,13,2),
    ("Q",2,0,1),("W",2,1,1),("E",2,2,1),("R",2,3,1),("T",2,4,1),("Y",2,5,1),
    ("U",2,6,1),("I",2,7,1),("O",2,8,1),("P",2,9,1),("@",2,10,2),("[",2,12,3),
    ("A",3,0,1),("S",3,1,1),("D",3,2,1),("F",3,3,1),("G",3,4,1),("H",3,5,1),
    ("J",3,6,1),("K",3,7,1),("L",3,8,1),(";",3,9,1),(":",3,10,1),("]",3,11,1),
    ("RET",3,12,3),
    ("SHF",4,0,2),("Z",4,2,1),("X",4,3,1),("C",4,4,1),("V",4,5,1),("B",4,6,1),
    ("N",4,7,1),("M",4,8,1),(",",4,9,1),(".",4,10,1),("/",4,11,1),
    ("_",4,12,1),("SHF",4,13,2),
    ("CAP",5,0,2),("CTL",5,2,2),("GRP",5,4,2),("SPACE",5,6,6),("COD",5,12,3),
]

LAYOUT_INTL = [
    ("ESC",0,0,1),("F1",0,1,1),("F2",0,2,1),("F3",0,3,1),("F4",0,4,1),
    ("F5",0,5,1),("STOP",0,6,2),("HOME",0,8,2),("INS",0,10,2),("DEL",0,12,2),
    ("TAB",0,14,1),
    ("1",1,0,1),("2",1,1,1),("3",1,2,1),("4",1,3,1),("5",1,4,1),("6",1,5,1),
    ("7",1,6,1),("8",1,7,1),("9",1,8,1),("0",1,9,1),("-",1,10,1),("=",1,11,1),
    ("\\",1,12,1),("BS",1,13,2),
    ("Q",2,0,1),("W",2,1,1),("E",2,2,1),("R",2,3,1),("T",2,4,1),("Y",2,5,1),
    ("U",2,6,1),("I",2,7,1),("O",2,8,1),("P",2,9,1),("[",2,10,2),("]",2,12,3),
    ("A",3,0,1),("S",3,1,1),("D",3,2,1),("F",3,3,1),("G",3,4,1),("H",3,5,1),
    ("J",3,6,1),("K",3,7,1),("L",3,8,1),(";",3,9,1),("'",3,10,1),("`",3,11,1),
    ("RET",3,12,3),
    ("SHF",4,0,2),("Z",4,2,1),("X",4,3,1),("C",4,4,1),("V",4,5,1),("B",4,6,1),
    ("N",4,7,1),("M",4,8,1),(",",4,9,1),(".",4,10,1),("/",4,11,1),("SHF",4,12,3),
    ("CAP",5,0,2),("CTL",5,2,2),("GRP",5,4,2),("SPACE",5,6,6),("COD",5,12,3),
]


def render_page(layout, alts, alt):
    img = [[0] * W for _ in range(H)]

    def putc(ch, x, y):
        rows = FONT[ch].split()
        for r in range(5):
            bits = rows[r]
            for c in range(3):
                if bits[c] == '1' and 0 <= x + c < W and 0 <= y + r < H:
                    img[y + r][x + c] = 1

    for label, row, col, span in layout:
        if alt:
            label = alts.get(label, label)
        x0, y0 = col * CELL_W, row * CELL_H
        w, h = span * CELL_W, CELL_H
        for x in range(x0, x0 + w):
            img[y0][x] = img[y0 + h - 1][x] = 1
        for y in range(y0, y0 + h):
            img[y][x0] = img[y][x0 + w - 1] = 1
        glyphs = [label] if label in FONT else list(label)
        tw = 4 * len(glyphs) - 1
        tx, ty = x0 + (w - tw) // 2, y0 + (h - 5) // 2
        for i, ch in enumerate(glyphs):
            putc(ch, tx + i * 4, ty)
    return img


def page_bytes(img):
    data = bytearray()
    for y in range(H):
        for xb in range(W // 8):
            b = 0
            for i in range(8):
                b = (b << 1) | img[y][xb * 8 + i]
            data.append(b)
    return data + b'\0' * (4096 - len(data))


def main():
    pages = [render_page(LAYOUT_JP, ALT_JP, False),
             render_page(LAYOUT_JP, ALT_JP, True),
             render_page(LAYOUT_INTL, ALT_INTL, False),
             render_page(LAYOUT_INTL, ALT_INTL, True)]
    img, img_alt = pages[0], pages[1]
    data = b''.join(bytes(page_bytes(p)) for p in pages)

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    with open(os.path.join(root, 'rtl/rom/osk_panel.hex'), 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in data) + '\n')
    with open(os.path.join(root, 'rtl/rom/osk_panel.mif'), 'w') as f:
        f.write("DEPTH = 16384;\nWIDTH = 8;\nADDRESS_RADIX = HEX;\n"
                "DATA_RADIX = HEX;\nCONTENT\nBEGIN\n")
        for a, b in enumerate(data):
            f.write(f"{a:03X} : {b:02X};\n")
        f.write("END;\n")
    print(f"osk_panel: 4 pages of {W}x{H}, {len(data)} bytes")

    if '--preview' in sys.argv:
        for page in pages:
            for y in range(H):
                print(''.join('#' if v else '.' for v in page[y]))
            print()

    if '--png' in sys.argv:
        import struct
        import zlib
        scale = 4
        fg, bg = (255, 255, 255), (24, 28, 48)  # overlay look: white on dim
        stack = []
        for pg in pages:
            stack = stack + pg + [[0] * W for _ in range(4)]
        stack = stack[:-4]
        SH = len(stack)
        rows = bytearray()
        for y in range(SH):
            row = bytearray()
            for x in range(W):
                row += bytes(fg if stack[y][x] else bg)
            for _ in range(scale):
                rows += b'\x00' + bytes(v for px in [row] for v in px)
        # widen horizontally
        out_rows = bytearray()
        for y in range(SH * scale):
            src = rows[y * (W * 3 + 1):(y + 1) * (W * 3 + 1)][1:]
            line = bytearray()
            for x in range(W):
                line += src[x * 3:x * 3 + 3] * scale
            out_rows += b'\x00' + line

        def chunk(tag, payload):
            return (struct.pack('>I', len(payload)) + tag + payload +
                    struct.pack('>I', zlib.crc32(tag + payload)))

        png = (b'\x89PNG\r\n\x1a\n'
               + chunk(b'IHDR', struct.pack('>IIBBBBB', W * scale, SH * scale,
                                            8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress(bytes(out_rows), 9))
               + chunk(b'IEND', b''))
        path = os.path.join(root, 'docs/osk_panel.png')
        with open(path, 'wb') as f:
            f.write(png)
        print(f"wrote {path} ({W*scale}x{SH*scale})")


if __name__ == "__main__":
    main()
