#!/usr/bin/env python3
"""Summarize a tb_framedump frame.txt: geometry, content extent, anomalies."""
import sys

lines = []  # list of list[(r,g,b)]
cur = None
for ln in open(sys.argv[1] if len(sys.argv) > 1 else "frame.txt"):
    ln = ln.strip()
    if ln.startswith("LINE"):
        cur = []
        lines.append(cur)
    elif ln == "END":
        break
    elif cur is not None and ln:
        r, g, b = map(int, ln.split())
        cur.append((r, g, b))

print(f"lines: {len(lines)}")
widths = sorted(set(len(l) for l in lines))
print(f"samples per line: {widths}")

def classify(px):
    # palette: black(0,0,0)ish, blue(B high, R/G low), white(all high)
    r, g, b = px
    if r > 32 and g > 32 and b > 32:
        return "W"
    if b > 32 and r < 16 and g < 16:
        return "b"
    if r < 16 and g < 16 and b < 16:
        return "k"
    return "?"

summary = []
for y, l in enumerate(lines):
    kinds = [classify(p) for p in l]
    uniq = set(kinds)
    if uniq == {"b"}:
        desc = "border"
    else:
        first_w = kinds.index("W") if "W" in kinds else -1
        last_w = len(kinds) - 1 - kinds[::-1].index("W") if "W" in kinds else -1
        nk = kinds.count("k")
        nq = kinds.count("?")
        desc = f"content W[{first_w}..{last_w}] k={nk} odd={nq}"
        if nq:
            # show the odd pixels
            odds = [(x, lines[y][x]) for x, k in enumerate(kinds) if k == "?"][:8]
            desc += f" oddpx={odds}"
    summary.append(desc)

# compress consecutive identical descriptions
start = 0
for y in range(1, len(summary) + 1):
    if y == len(summary) or summary[y] != summary[start]:
        rng = f"{start}" if y - 1 == start else f"{start}-{y-1}"
        print(f"line {rng}: {summary[start]}")
        start = y

# distinct colors across whole frame
colors = {}
for l in lines:
    for p in l:
        colors[p] = colors.get(p, 0) + 1
print("colors:", sorted(colors.items(), key=lambda kv: -kv[1])[:8])
