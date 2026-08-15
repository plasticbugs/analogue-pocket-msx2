#!/usr/bin/env python3
"""Distill openMSX's softwaredb.xml into mapperdb.bin for the Pocket core.

The core hashes a loaded ROM with SHA-1 and looks the digest up in this
table to pick the mapper, the same database-first strategy openMSX uses;
the instruction-counting heuristic in rom_detect.v remains the fallback
for dumps the table does not know.

File format (little-endian):
    0x00  "MDB1"          magic
    0x04  u32 count       number of entries
    0x08  entries         count * 9 bytes, sorted ascending by key:
                          u64 key  = first 8 bytes of SHA-1, big-endian
                                     (so byte-wise compare == numeric)
                          u8  mapper id (core numbering, see rom.v)

Only mapped types are included: plain/mirrored ROMs are already handled
correctly by size-based detection, and including them would only bloat
the table.

Usage:
    tools/make_mapperdb.py [path/to/softwaredb.xml] [-o mapperdb.bin]

Default input is the openMSX.app bundled database.
"""

import argparse
import struct
import sys
import xml.etree.ElementTree as ET
from collections import Counter

DEFAULT_DB = ("/Applications/openMSX.app/Contents/Resources/share/"
              "softwaredb.xml")

# openMSX type -> core mapper id (rtl/cart/rom.v numbering).
# SRAM flavours share their base mapper: the RTL maps SRAM in whenever a
# bank register selects past the end of ROM, which is exactly the
# sramEnableBit rule these types use. Koei/Wizardry need SRAM shapes the
# core does not have yet -- excluded until then.
TYPE_MAP = {
    "GameMaster2":   2,
    "Konami":        3,
    "KonamiSCC":     4,
    "ASCII8":        5,
    "ASCII8SRAM8":   5,
    "ASCII8SRAM2":   5,
    "ASCII16":       6,
    "ASCII16SRAM2":  6,
    "ASCII16SRAM8":  6,
    "R-Type":        8,
    "GenericKonami": 10,
    "Generic8kB":    10,
    "8kB":           10,
    "CrossBlaim":    11,
    "HarryFox":      12,
    "SuperLodeRunner": 13,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("softwaredb", nargs="?", default=DEFAULT_DB)
    ap.add_argument("-o", "--output", default="mapperdb.bin")
    args = ap.parse_args()

    tree = ET.parse(args.softwaredb)
    entries = {}
    counts = Counter()
    skipped = Counter()

    def rom_elements(sw):
        # old format: <software><dump><rom|megarom><sha1>..<type>..
        # new format: <software><rom sha1=".." type=".."/>
        found = False
        for dump in sw.iter("dump"):
            for tag in ("rom", "megarom"):
                rom = dump.find(tag)
                if rom is not None:
                    found = True
                    yield rom
        if not found:
            for rom in sw.findall("rom"):
                yield rom

    for sw in tree.getroot().iter("software"):
        for rom in rom_elements(sw):
            rtype = rom.get("type") or rom.findtext("type") or "plain"
            sha1 = rom.get("sha1") or rom.findtext("sha1")
            if sha1 is None:
                h = rom.find("hash")
                sha1 = h.text if h is not None else None
            if not sha1:
                continue
            mapper = TYPE_MAP.get(rtype)
            if mapper is None:
                skipped[rtype] += 1
                continue
            key = int(sha1[:16], 16)
            prev = entries.get(key)
            if prev is not None and prev != mapper:
                print(f"warning: key collision {sha1[:16]} "
                      f"({prev} vs {mapper}), keeping first",
                      file=sys.stderr)
                continue
            entries[key] = mapper
            counts[rtype] += 1

    blob = b"MDB1" + struct.pack("<I", len(entries))
    for key in sorted(entries):
        blob += struct.pack(">Q", key) + struct.pack("B", entries[key])

    with open(args.output, "wb") as f:
        f.write(blob)

    total = sum(counts.values())
    print(f"{args.output}: {len(entries)} entries ({total} dumps), "
          f"{len(blob)} bytes")
    for t, n in counts.most_common():
        print(f"  {n:5d}  {t}")
    if skipped:
        drop = sum(skipped.values())
        print(f"skipped {drop} dumps of unsupported types: "
              + ", ".join(f"{t}({n})" for t, n in skipped.most_common(12)))


if __name__ == "__main__":
    main()
