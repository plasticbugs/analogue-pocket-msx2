#!/usr/bin/env python3
"""Assemble an Analogue Pocket SD-card package from the compiled bitstream.

The Pocket loads a bit-reversed RBF (each byte's bits swapped) named per
core.json ("bitstream.rbf_r"). Output goes to release/pocket/ ready to copy
onto the SD card root.
"""
import os, shutil, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RBF = os.path.join(ROOT, "projects", "output_files", "msx_pocket.rbf")
PKG = os.path.join(ROOT, "pkg", "pocket")
OUT = os.path.join(ROOT, "release", "pocket")

if not os.path.exists(RBF):
    sys.exit(f"missing {RBF} - run the Quartus compile first "
             "(and make sure the project generates a compressed RBF)")

REV = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(RBF, "rb").read()
reversed_rbf = bytes(REV[b] for b in data)

if os.path.exists(OUT):
    shutil.rmtree(OUT)
shutil.copytree(PKG, OUT)

core_dir = os.path.join(OUT, "Cores", "boogermann.msx")
with open(os.path.join(core_dir, "bitstream.rbf_r"), "wb") as f:
    f.write(reversed_rbf)

print(f"packaged -> {OUT}")
print("copy the contents of that folder onto the Pocket SD card root")
