#!/bin/sh
# Measure the V9938 video timing (line rate, DE window, lines per field) with
# GHDL, so the Pocket scaler geometry in pkg/pocket/.../video.json can be
# verified against what the VDP actually emits.
#
# Requires: ghdl  (brew install ghdl)
set -e
cd "$(dirname "$0")"

rm -rf src work-obj93.cf tb_vdp
mkdir -p src
cp ../modules/video-v9938/*.vhd src/
cp ../../MSX_MiSTer/rtl/peripheral/ram.vhd ram.vhd 2>/dev/null || true

# GHDL is stricter than Quartus: complete every CASE, and the (unused in 15kHz
# mode) VGA line buffer is indexed past its declared range during simulation.
python3 - <<'PYEOF'
import re, glob
for path in glob.glob('src/*.vhd'):
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    out, stack = [], []
    for ln in lines:
        low = ln.lower()
        if re.search(r'\bcase\b.*\bis\b', low) and not re.search(r'\bend\s+case\b', low):
            stack.append([False, len(ln) - len(ln.lstrip())])
        if re.search(r'\bwhen\b\s+others\b', low) and stack:
            stack[-1][0] = True
        if re.search(r'\bend\s+case\b', low) and stack:
            has_others, indent = stack.pop()
            if not has_others:
                out.append(' ' * (indent + 4) + 'WHEN OTHERS => NULL;')
        out.append(ln)
    open(path, 'w').write('\n'.join(out))
p = 'src/vdp_linebuf.vhd'
s = open(p).read().replace('ARRAY ( 639 DOWNTO 0 )', 'ARRAY ( 1023 DOWNTO 0 )')
open(p, 'w').write(s)
PYEOF

FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed"
ghdl -a $FLAGS ram.vhd \
    src/vdp_package.vhd src/vdp_ssg.vhd src/vdp_hvcounter.vhd \
    src/vdp_interrupt.vhd src/vdp_register.vhd src/vdp_command.vhd \
    src/vdp_sprite.vhd src/vdp_spinforam.vhd src/vdp_colordec.vhd \
    src/vdp_graphic123m.vhd src/vdp_graphic4567.vhd src/vdp_text12.vhd \
    src/vdp_linebuf.vhd src/vdp_doublebuf.vhd src/vdp_ntsc_pal.vhd \
    src/vdp_vga.vhd src/vdp_wait_control.vhd src/vdp.vhd tb_vdp.vhd 2>&1 | grep -i error || true
ghdl -e $FLAGS tb_vdp 2>&1 | grep -i "^error" || true
./tb_vdp --stop-time=150ms 2>&1 | grep -E "LINE:|FIELD" || true
