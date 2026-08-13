#!/usr/bin/env python3
"""Map each DE window line of a tb_framedump5 dump back to its display line.

Bitmap line y carries colour 1+(y mod 14); palette entry i is the unique
triple (i&7, (i//2)&7, (15-i)&7) scaled by the VDP's 3-bit -> 6-bit output.
"""
import sys
from collections import Counter

lines = []
cur = None
for ln in open(sys.argv[1] if len(sys.argv) > 1 else "frame5.txt"):
    ln = ln.strip()
    if ln.startswith("LINE"):
        cur = []
        lines.append(cur)
    elif ln == "END":
        break
    elif cur is not None and ln:
        cur.append(tuple(map(int, ln.split())))

print(f"lines: {len(lines)}  widths: {sorted(set(len(l) for l in lines))}")

# palette map: colour index -> expected (r,g,b) in 6-bit terms (3-bit << 3)
pal = {}
for i in range(16):
    pal[((i % 8) << 3, ((i // 2) % 8) << 3, ((15 - i) % 8) << 3)] = i

def classify(l):
    """Return (dominant colour index or None=unknown, count of off-pixels)."""
    cnt = Counter(l)
    dom, n = cnt.most_common(1)[0]
    idx = pal.get(dom, None)
    return idx, len(l) - n, dom

rows = []
for y, l in enumerate(lines):
    idx, off, dom = classify(l)
    rows.append((idx, off, dom))

# compress runs; a run = consecutive lines whose colour index advances by the
# bitmap sequence (1 + (y mod 14)) or stays equal (border colour 0)
start = 0
def desc(y):
    idx, off, dom = rows[y]
    if idx is None:
        return f"UNKNOWN colour {dom} offpx={off}"
    return f"idx={idx} offpx={off}"

y = 0
while y < len(rows):
    idx0, off0, _ = rows[y]
    if idx0 == 0 or idx0 is None:
        # border or unknown: compress equal lines
        z = y
        while z + 1 < len(rows) and rows[z + 1][:2] == rows[y][:2] and rows[z+1][2] == rows[y][2]:
            z += 1
        print(f"win {y}-{z}: {desc(y)}" + ("  <border?>" if idx0 == 0 else ""))
        y = z + 1
    else:
        # content: follow the mod-14 sequence
        z = y
        seq_ok = True
        while z + 1 < len(rows):
            nidx = rows[z + 1][0]
            want = 1 + ((rows[z][0]) % 14) if rows[z][0] != 0 else None
            exp = 1 + (((rows[z][0] - 1) + 1) % 14)
            if nidx == exp and rows[z + 1][1] == 0:
                z += 1
            else:
                break
        first = rows[y][0]
        last = rows[z][0]
        print(f"win {y}-{z}: content colours idx {first}..{last} "
              f"({z - y + 1} lines, sequence mod14)")
        y = z + 1

# horizontal extent on a middle content line
mid = len(lines) // 2
l = lines[mid]
dom = Counter(l).most_common(1)[0][0]
xs = [x for x, p in enumerate(l) if p == dom]
print(f"mid line {mid}: dominant {dom} from sample {xs[0]} to {xs[-1]} "
      f"({xs[-1]-xs[0]+1} samples)")
