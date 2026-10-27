#!/usr/bin/env python3
"""Check the core's JSON against what the Pocket's firmware will accept.

    tools/check_json.py [pkg/pocket]

The APF parses these files itself and says almost nothing when it cannot:
the first flash of this core stopped at `Load error in "interact" - General
Error`, which was a duplicate variable id (two entries had used id 20) and
two names longer than the field allows.  Nothing in the build caught it,
because everything in the build only ever read the files with a JSON parser,
which is not what the firmware does.

So this checks the things the firmware cares about and a parser does not:

  * every file is valid JSON and carries the magic the firmware looks for;
  * interact variable ids are unique -- the fault above;
  * a list's `defaultval` is an INDEX into its options, not the value to
    write -- which is what the second flash died on, with indices of 256,
    16384 and 2097152 into lists of sixteen.  Every core that loads uses
    0 to 3 there, and in each one it selects the option whose value is
    zero;
  * names fit, and a list's options each have a name and a value;
  * data slot ids are unique and required slots name a filename;
  * video.json's scaler modes declare the size the core actually emits,
    given as --active WxH (the boot bench prints it; repeat it for a core
    with more than one raster, such as NTSC and PAL).  This one is
    not a firmware rule, it is the fault it catches: the template shipped
    320x224 from an arcade board while this core emits 640x256, and on
    hardware that came out as a picture squished horizontally, the bottom
    32 lines -- where the on-screen keyboard is drawn -- cut off, and the
    whole image flickering;
  * the files are no larger than the largest this firmware is known to
    accept, because size is the one limit that cannot be read off the file,
    interact.json has no more options than any core that loads (the
    survey below), and the menu no more entries than Analogue documents;
  * a slider's defaultval lies between its min and max;
  * an Analogizer core's menu and package agree (docs/analogizer.md): its
    interact.json entries at 0xF7000000 each write only inside their
    mask, one of them sets the enable (bit 5), the picture-position
    sliders at 0xF7000004/8 and the width slider at 0xF700000C fit the 8
    signed bits read, no data slot also writes
    0xF7000000 (a file loaded there would overwrite the menu's word), and
    the cartridge port is powered.  Any of those wrong and the Pocket loads
    the core happily while the adapter stays dark or ignores the menu.

It exits non-zero and prints every fault, not just the first.
"""
import glob
import json
import os
import re
import sys

# These, but for the menu's size, are not from a document.  They are what a
# firmware that accepts a file is observed to accept, surveyed across the
# seventeen cores installed on the author's own Pocket
# (tools/survey_interact.py):
#
#     variables      up to 14      option values   up to 0x00C00000
#     bytes          up to 7,597   options a list  up to 16
#                    (11,568 loads since: SIZE_MAX below)
#     longest name   26            defaultval      0..3
#     options in the whole file    up to 52 then; 68 loads, 70 does not
#                                  (measured since: HW_OPTS_MAX below)
#
# The 23 characters an earlier version of this file called a limit was a
# guess, and wrong: OpenJazz ships a 26-character name and loads.
#
# The menu's size is Analogue's own (developer docs, interact.json): "Up to
# 16 UI entries from interact.json can be shown", and no more than 20
# interact and data entries together.  The survey's 14 is only the most any
# installed core happened to have.
NAME_MAX = 26
OPTS_MAX = 16
# Bytes: Atari System 2's 0.3.x interact.json is 11,568 bytes and loads on
# the Pocket (its games play with it), so that is what is known to load.
SIZE_MAX = 11568
VARS_MAX = 16          # Analogue's documented limit
ENTRIES_MAX = 20       # interact variables and data slots together

MAGIC = {
    'core.json': 'APF_VER_1', 'data.json': 'APF_VER_1',
    'input.json': 'APF_VER_1', 'interact.json': 'APF_VER_1',
    'variants.json': 'APF_VER_1', 'audio.json': 'APF_VER_1',
    'video.json': 'APF_VER_1',
}


def main(argv):
    active = []
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == '--active' and i + 1 < len(argv):
            i += 1
            try:
                w_, h_ = argv[i].lower().split('x')
                active.append((int(w_), int(h_)))
            except ValueError:
                print(f'--active wants WxH, got {argv[i]!r}')
                return 2
        else:
            args.append(argv[i])
        i += 1
    root = args[0] if args else 'pkg/pocket'
    bad = []
    def fault(where, msg):
        bad.append(f'{where}: {msg}')

    files = []
    for dirpath, _dirs, names in os.walk(root):
        for n in sorted(names):
            if n.endswith('.json'):
                files.append(os.path.join(dirpath, n))
    if not files:
        print(f'no JSON under {root}')
        return 2

    for path in files:
        base = os.path.basename(path)
        size = os.path.getsize(path)
        try:
            d = json.load(open(path))
        except Exception as e:
            fault(path, f'not valid JSON: {e}')
            continue
        if size > SIZE_MAX:
            fault(path, f'{size} bytes, over the {SIZE_MAX} this firmware is '
                        f'known to accept')
        top = next(iter(d)) if len(d) == 1 else None
        if base in MAGIC:
            magic = d.get(top, {}).get('magic') if top else None
            if magic != MAGIC[base]:
                fault(path, f'magic is {magic!r}, expected {MAGIC[base]!r}')

        if base == 'interact.json':
            v = d['interact'].get('variables', [])
            if len(v) > VARS_MAX:
                fault(path, f'{len(v)} variables, more than the {VARS_MAX} the '
                            f'Pocket shows')
            dj = os.path.join(os.path.dirname(path), 'data.json')
            try:
                ns = len(json.load(open(dj))['data'].get('data_slots', []))
            except Exception:
                ns = 0
            if len(v) + ns > ENTRIES_MAX:
                fault(path, f'{len(v)} variables and {ns} data slots, more than '
                            f'the {ENTRIES_MAX} entries the Pocket allows together')
            for x in v:
                for val in ([o.get('value') for o in x.get('options', [])]
                            + [x.get('value')]):
                    try:
                        n = int(str(val), 16)
                    except (TypeError, ValueError):
                        continue
                    if n & 0x80000000:
                        fault(path, f'{x.get("name")!r} has the value {val}, '
                                    f'with bit 31 set; no core that loads here '
                                    f'has one above 0x00C00000')
            seen = {}
            for x in v:
                i, name = x.get('id'), x.get('name', '')
                if i in seen:
                    fault(path, f'id {i} used by both {seen[i]!r} and {name!r}')
                seen[i] = name
                if len(name) > NAME_MAX:
                    fault(path, f'name {name!r} is {len(name)} characters, '
                                f'over {NAME_MAX}')
                if x.get('type') == 'list':
                    o = x.get('options', [])
                    if not o:
                        fault(path, f'{name!r} is a list with no options')
                    dv = x.get('defaultval')
                    if not isinstance(dv, int) or not 0 <= dv < max(len(o), 1):
                        fault(path, f'{name!r} defaultval is {dv!r}; it must be '
                                    f'an index into its {len(o)} options')
                    if len(o) > OPTS_MAX:
                        fault(path, f'{name!r} has {len(o)} options, over {OPTS_MAX}')
                    for k in o:
                        if 'name' not in k or 'value' not in k:
                            fault(path, f'{name!r} has an option missing '
                                        f'name or value: {k}')
                        elif len(k['name']) > NAME_MAX:
                            fault(path, f'{name!r} option {k["name"]!r} is '
                                        f'{len(k["name"])} characters')
                if x.get('type') == 'slider_u32':
                    g = x.get('graphical', {})
                    lo, hi, dv = g.get('min'), g.get('max'), x.get('defaultval')
                    if not all(isinstance(n, int) for n in (lo, hi, dv)) or not lo <= dv <= hi:
                        fault(path, f'{name!r} slider: min {lo!r}, max {hi!r}, '
                                    f'defaultval {dv!r}; want integers, min <= defaultval <= max')
                if x.get('type') != 'action' and 'address' not in x:
                    fault(path, f'{name!r} has no address')

        if base == 'video.json':
            # The active size has to come from outside this file: the
            # constant that sets it is named differently in every core, and a
            # check that guesses at the name is a check that silently stops
            # working.  Pass --active WxH -- the number the boot bench prints
            # as "N active pixels" is the one to use.
            if not active:
                fault(path, 'no --active WxH given, so the declared scaler '
                            'size was NOT checked against what the core emits. '
                            'Pass the size the bench measures.')
            else:
                for i, m in enumerate(d['video'].get('scaler_modes', [])):
                    if (m.get('width'), m.get('height')) not in active:
                        fault(path, f'scaler_modes[{i}] says '
                                    f'{m.get("width")}x{m.get("height")}, but the '
                                    f'core emits ' + ' or '.join(f'{w}x{h}' for w, h in active))

        if base == 'data.json':
            slots = d['data'].get('data_slots', [])
            seen = {}
            for s in slots:
                i = s.get('id')
                if i in seen:
                    fault(path, f'slot id {i} used twice')
                seen[i] = s.get('name')
                # With a game list (Pleiads' layout) the slot that takes the
                # instance JSON has no filename, and the instances name the
                # others' files: every instance must then name this slot's.
                if s.get('required') and not s.get('filename'):
                    if 'json' in s.get('extensions', []):
                        continue
                    core_dir = os.path.basename(os.path.dirname(path))
                    insts = glob.glob(os.path.join(root, 'Assets', '*', core_dir, '*.json'))
                    named = [any(ds.get('id') == i and ds.get('filename')
                                 for ds in json.load(open(f))['instance'].get('data_slots', []))
                             for f in insts]
                    if not insts or not all(named):
                        fault(path, f'slot {i} is required but names no filename'
                                    + (' (and not every instance JSON names one)' if insts else ''))

    # The Analogizer: settings from the core's own menu, one word at
    # 0xF7000000 that the masked entries share (pocket_analogizer.sv).
    for core_dir in sorted(glob.glob(os.path.join(root, 'Cores', '*'))):
        cj, dj = os.path.join(core_dir, 'core.json'), os.path.join(core_dir, 'data.json')
        ij = os.path.join(core_dir, 'interact.json')
        try:
            core = json.load(open(cj))['core']
            slots = json.load(open(dj))['data'].get('data_slots', [])
            menu = json.load(open(ij))['interact'].get('variables', [])
        except Exception:
            continue
        ana = [v for v in menu if str(v.get('address', '')).lower() == '0xf7000000']
        file_slots = [s for s in slots if s.get('filename') == 'analogizer.bin'
                      or str(s.get('address', '')).lower() == '0xf7000000']
        if not ana and not file_slots:
            continue
        # RndMnkIII's module also reads the word from analogizer.bin, a shared
        # file Pupdate writes.  A core may take its settings from the file
        # alone (MSX2 does: its menu has no room for the Analogizer's thirty
        # options) but never from both, since the file loaded at core start
        # overwrites what the menu set.
        for s in file_slots if ana else []:
            fault(dj, f'data slot {s.get("id")} writes the Analogizer word at '
                      f'0xF7000000; this core sets it from its menu, and a file '
                      f'loaded there would overwrite the menu\'s settings')
        enable = False
        for v in ana:
            try:
                mask = int(str(v.get('mask')), 16)
            except ValueError:
                fault(ij, f'{v.get("name")!r} at 0xF7000000 has no mask: it would '
                          f'clear every other Analogizer setting')
                continue
            for o in v.get('options', []) + ([v] if 'value' in v and v.get('type') != 'action' else []):
                try:
                    val = int(str(o.get('value')), 16)
                except ValueError:
                    continue
                if val & mask:
                    fault(ij, f'{v.get("name")!r} option {o.get("name")!r} writes '
                              f'{o.get("value")}, outside its mask {v.get("mask")}')
                if val & 0x20 and not mask & 0x20:
                    enable = True
        for v in menu:
            a = str(v.get('address', '')).lower()
            if not a.startswith('0xf70000') or a == '0xf7000000':
                continue
            if a not in ('0xf7000004', '0xf7000008', '0xf700000c'):
                fault(ij, f'{v.get("name")!r} writes {v.get("address")}; the Analogizer '
                          f'reads only 0xF7000000, 0xF7000004, 0xF7000008 and 0xF700000C')
                continue
            g = v.get('graphical', {})
            if (v.get('type') != 'slider_u32' or not g.get('signed')
                    or not -127 <= g.get('min', 0) <= 0 <= g.get('max', 0) <= 127):
                fault(ij, f'{v.get("name")!r}: a picture position or width is a signed '
                          f'slider from -127..0 to 0..127 (pocket_analogizer reads 8 bits)')
            if a == '0xf700000c' and g.get('min', 0) < -50:
                fault(ij, f'{v.get("name")!r}: a width below -50% would skip more than '
                          f'every other dot')
        if ana and not enable:
            fault(ij, 'no Analogizer entry sets the enable (bit 5 of 0xF7000000): '
                      'the adapter would never turn on')
        if core.get('framework', {}).get('hardware', {}).get('cartridge_adapter') != 0:
            fault(cj, 'Analogizer menu present but cartridge_adapter is not 0: '
                      'the cartridge port is not powered')

    # What the firmware refuses, measured on hardware (2026-10-09): with 16
    # entries, 70 and 77 options in the whole menu stopped Atari System 2 and
    # BBC Micro with "Error in interact" at core setup, while MSX2 loads with
    # 68 options (80 with its entries) and Cadash and Cloak with 54.
    # Analogue's docs say a list's options count toward no limit; on this
    # firmware they do, somewhere above 68.
    HW_OPTS_MAX, HW_OPTS_VARS_MAX = 68, 80
    for path in files:
        if os.path.basename(path) != 'interact.json':
            continue
        try:
            hv = json.load(open(path))['interact'].get('variables', [])
        except Exception:
            continue
        hn = sum(len(x.get('options', [])) for x in hv)
        if hn > HW_OPTS_MAX or hn + len(hv) > HW_OPTS_VARS_MAX:
            fault(path, f'{hn} options and {len(hv)} entries: the firmware refused '
                        f'70 options (86 with entries) and loads 68 (80); keep to '
                        f'{HW_OPTS_MAX} and {HW_OPTS_VARS_MAX}')

    for f in bad:
        print('  ' + f)
    print()
    if bad:
        print(f'{len(bad)} fault(s) the Pocket would refuse')
        return 1
    print(f'{len(files)} JSON files, nothing the Pocket is known to refuse')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
