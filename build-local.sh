#!/bin/sh
# Compile the Pocket core with Quartus 18.1 in Docker (x86 emulation on ARM Macs).
set -e
cd "$(dirname "$0")"
docker run --rm --platform linux/amd64 \
    -v "$PWD":/build -w /build \
    raetro/quartus:pocket \
    quartus_sh --flow compile projects/msx_pocket.qpf
python3 package-pocket.py
