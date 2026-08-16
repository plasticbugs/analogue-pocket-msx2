#!/usr/bin/env python3
"""Render the on-screen keyboard panel bitmap for the OSK overlay.

Produces a 240x72 1bpp image: 12 columns x 6 rows of 20x12 key cells,
each key an outlined box with a centred label in a 3x5 font. Output is
a Quartus MIF (for the spram init) and a plain hex file (for iverilog
testbenches), 30 bytes per row, MSB = leftmost pixel, padded to 4096
bytes to match the BRAM's 12-bit address space.

Usage: tools/make_osk_panel.py [--preview]
Writes rtl/rom/osk_panel.mif and rtl/rom/osk_panel.hex.
"""
import os
import sys

W, H = 240, 72
CELL_W, CELL_H = 20, 12

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
}

# (label, row, col, cell-span). Chord keys later index this same table.
LAYOUT = [
    ("ESC",0,0,1),("F1",0,1,1),("F2",0,2,1),("F3",0,3,1),("F4",0,4,1),
    ("F5",0,5,1),("STOP",0,6,1),("HOME",0,7,1),("INS",0,8,1),("DEL",0,9,1),
    ("TAB",0,10,1),("BS",0,11,1),
    ("1",1,0,1),("2",1,1,1),("3",1,2,1),("4",1,3,1),("5",1,4,1),("6",1,5,1),
    ("7",1,6,1),("8",1,7,1),("9",1,8,1),("0",1,9,1),("-",1,10,1),("=",1,11,1),
    ("Q",2,0,1),("W",2,1,1),("E",2,2,1),("R",2,3,1),("T",2,4,1),("Y",2,5,1),
    ("U",2,6,1),("I",2,7,1),("O",2,8,1),("P",2,9,1),("[",2,10,1),("]",2,11,1),
    ("A",3,0,1),("S",3,1,1),("D",3,2,1),("F",3,3,1),("G",3,4,1),("H",3,5,1),
    ("J",3,6,1),("K",3,7,1),("L",3,8,1),(";",3,9,1),("'",3,10,1),("RET",3,11,1),
    ("SHF",4,0,1),("Z",4,1,1),("X",4,2,1),("C",4,3,1),("V",4,4,1),("B",4,5,1),
    ("N",4,6,1),("M",4,7,1),(",",4,8,1),(".",4,9,1),("/",4,10,1),("SHF",4,11,1),
    ("CAP",5,0,1),("CTL",5,1,1),("GRP",5,2,1),("SPACE",5,3,5),("COD",5,8,1),
    ("@",5,9,1),("\\",5,10,1),("`",5,11,1),
]


def main():
    img = [[0] * W for _ in range(H)]

    def putc(ch, x, y):
        rows = FONT[ch].split()
        for r in range(5):
            bits = rows[r]
            for c in range(3):
                if bits[c] == '1' and 0 <= x + c < W and 0 <= y + r < H:
                    img[y + r][x + c] = 1

    for label, row, col, span in LAYOUT:
        x0, y0 = col * CELL_W, row * CELL_H
        w, h = span * CELL_W, CELL_H
        for x in range(x0, x0 + w):
            img[y0][x] = img[y0 + h - 1][x] = 1
        for y in range(y0, y0 + h):
            img[y][x0] = img[y][x0 + w - 1] = 1
        tw = 4 * len(label) - 1
        tx, ty = x0 + (w - tw) // 2, y0 + (h - 5) // 2
        for i, ch in enumerate(label):
            putc(ch, tx + i * 4, ty)

    data = bytearray()
    for y in range(H):
        for xb in range(W // 8):
            b = 0
            for i in range(8):
                b = (b << 1) | img[y][xb * 8 + i]
            data.append(b)
    data += b'\0' * (4096 - len(data))

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    with open(os.path.join(root, 'rtl/rom/osk_panel.hex'), 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in data) + '\n')
    with open(os.path.join(root, 'rtl/rom/osk_panel.mif'), 'w') as f:
        f.write("DEPTH = 4096;\nWIDTH = 8;\nADDRESS_RADIX = HEX;\n"
                "DATA_RADIX = HEX;\nCONTENT\nBEGIN\n")
        for a, b in enumerate(data):
            f.write(f"{a:03X} : {b:02X};\n")
        f.write("END;\n")
    print(f"osk_panel: {W}x{H}, {W*H//8} bytes used of 4096")

    if '--preview' in sys.argv:
        for y in range(H):
            print(''.join('#' if v else '.' for v in img[y]))


if __name__ == "__main__":
    main()
