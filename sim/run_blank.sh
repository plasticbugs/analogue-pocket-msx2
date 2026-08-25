#!/bin/sh
# Check the V9938's exported H/V blanking (fed to the Analogizer scandoubler)
# against its sync pulses and display enable, in NTSC and PAL.
#
# Requires: ghdl  (brew install ghdl)
set -e
cd "$(dirname "$0")"

rm -rf src work-obj93.cf tb_blank
mkdir -p src
cp ../modules/video-v9938/*.vhd src/

# Same GHDL-strictness patches as run.sh.
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

ghdl -a --std=93c -fsynopsys -fexplicit -frelaxed \
    src/vdp_package.vhd src/vdp_ssg.vhd src/vdp_hvcounter.vhd \
    src/vdp_interrupt.vhd src/vdp_register.vhd src/vdp_command.vhd \
    src/vdp_sprite.vhd src/vdp_spinforam.vhd src/vdp_colordec.vhd \
    src/vdp_graphic123m.vhd src/vdp_graphic4567.vhd src/vdp_text12.vhd \
    src/vdp_linebuf.vhd src/vdp_doublebuf.vhd src/vdp_ntsc_pal.vhd \
    src/vdp_vga.vhd src/vdp_wait_control.vhd src/vdp.vhd tb_blank.vhd 2>&1 | grep -i error || true
ghdl -e --std=93c -fsynopsys -fexplicit -frelaxed tb_blank 2>&1 | grep -i "^error" || true
echo "NTSC:"; ./tb_blank -gPAL=false --stop-time=120ms 2>&1 | grep -E "FIELD" || true
echo "PAL:";  ./tb_blank -gPAL=true  --stop-time=120ms 2>&1 | grep -E "FIELD" || true
