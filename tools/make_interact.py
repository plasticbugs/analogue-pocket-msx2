#!/usr/bin/env python3
"""Write the core's menu, pkg/pocket/Cores/plasticbugs.msx2/interact.json.

The menu is generated because most of it is one key table written six
times. Each "Map <button> to key" list is a 6-bit field of a 32-bit
register, so every option's value is the key's index shifted to that
field, and the list's mask is the register with that field cleared. Done
by hand, the Joy2Key lists drifted apart (Y and X offered sixteen keys, L
and R nine, Select seven, Start eight) and a new key meant six shifted
constants and a mask each; here a key is one line of KEYS and a button one
line of BUTTONS.

Register layout (read by target/pocket/core_top.sv):

    0xF1000000  DIP word; a change resets the machine (interact.sv)
                [3:0] slot A mapper   [7:4] slot B mapper   [8] PAL
    0xF2000000  modifiers; no reset
                [5:0] Y  [11:6] X  [17:12] L  [23:18] R  [29:24] Select
                [30] Joy2Key enable
    0xFA000000  status low; no reset
                [5:0] Start

Joy2Key lives in registers that do not reset the machine, so a mapping can
be changed in the middle of a game. Earlier versions kept Start and the
enable in the DIP word, where changing either rebooted the MSX.

The key indices are joy2ps2.sv's: 1-26 A-Z, 27-36 digits 0-9, then the
specials listed in KEYS.

Size budget: the Pocket's firmware refuses a menu with too many list
options in the whole file. 68 options and 80 options-plus-entries load on
hardware (this core's v0.5.2); 70 and 86 are refused with "Error in
interact" (tools/check_json.py, which this script runs). The mappers take
19 options, which leaves 49 for the six buttons, so each button offers a
subset of the table: F1-F5 everywhere (Metal Gear's weapon, equipment and
transceiver screens and pause), the common action keys on Y and X, SELECT
on Select, SPACE, RETURN and STOP on Start. To offer a key on a button, add it
to that button's list and take one away somewhere, then run this script;
it fails if the budget is exceeded.

Usage:
    tools/make_interact.py          # writes interact.json and checks it
    tools/make_interact.py --check  # exits 1 if the file is out of date
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pkg', 'pocket', 'Cores', 'plasticbugs.msx2',
                   'interact.json')

DIP, MOD, STATUS_L = '0xF1000000', '0xF2000000', '0xFA000000'
RESET, SERVICE = '0xF0000000', '0xF0000010'

# Key name -> index in joy2ps2.sv's table.
KEYS = {'None': 0}
KEYS.update({c: 1 + i for i, c in enumerate('ABCDEFGHIJKLMNOPQRSTUVWXYZ')})
KEYS.update({str(d): 27 + d for d in range(10)})
KEYS.update({
    'SPACE': 37, 'RETURN': 38, 'SHIFT': 39, 'CTRL': 40, 'GRAPH': 41,
    'CODE': 42, 'ESC': 43, 'TAB': 44, 'BACKSPACE': 45,
    'F1': 50, 'F2': 51, 'F3': 52, 'F4': 53, 'F5': 54,
    'SELECT': 55, 'STOP': 56, 'HOME': 57, 'INS': 58, 'DEL': 59,
})

FKEYS = ['F1', 'F2', 'F3', 'F4', 'F5']
Y_KEYS = ['SPACE', 'RETURN', 'SHIFT', 'ESC', 'M']
X_KEYS = ['SPACE', 'RETURN', 'ESC', 'M']        # SHIFT gave its slot to STOP on Start

# (button, register, low bit, keys offered). Every list starts with None.
BUTTONS = [
    ('Y',      MOD,      0,  Y_KEYS + FKEYS),
    ('X',      MOD,      6,  X_KEYS + FKEYS),
    ('L',      MOD,      12, FKEYS),
    ('R',      MOD,      18, FKEYS),
    ('Select', MOD,      24, ['SELECT'] + FKEYS),
    ('Start',  STATUS_L, 0,  ['SPACE', 'RETURN', 'STOP'] + FKEYS),
]
KEY_BITS = 6
JOY2KEY_ENABLE_BIT = 30     # bit 31 is left clear: no core that loads
                            # writes a value with it set (check_json.py)

# Cartridge mapper ids, rom.v's numbering; 0 is automatic detection.
MAPPERS_A = [('Auto', 0), ('None', 1), ('GameMaster2', 2), ('Konami', 3),
             ('KonamiSCC', 4), ('ASCII8', 5), ('ASCII16', 6),
             ('Linear 64k', 7), ('R-TYPE', 8), ('Generic 8K', 10),
             ('Cross Blaim', 11), ('Harry Fox', 12),
             ('Super Lode Runner', 13)]
MAPPERS_B = [('Auto', 0), ('None', 1), ('Konami', 3), ('KonamiSCC', 4),
             ('ASCII8', 5), ('ASCII16', 6)]


def hex32(n):
    return f'0x{n & 0xFFFFFFFF:08X}'


def field_list(name, vid, address, low, width, options, persist):
    """A list that writes one bit field of a shared register."""
    mask = ~(((1 << width) - 1) << low)
    return {
        'name': name, 'id': vid, 'type': 'list', 'enabled': True,
        'persist': persist, 'address': address, 'defaultval': 0,
        'mask': hex32(mask),
        'options': [{'name': n, 'value': hex32(v << low)} for n, v in options],
    }


def check(name, vid, address, bit, persist):
    return {
        'name': name, 'id': vid, 'type': 'check', 'enabled': True,
        'persist': persist, 'address': address, 'defaultval': 0,
        'mask': hex32(~(1 << bit)), 'value': hex32(1 << bit),
    }


def action(name, vid, address):
    return {'name': name, 'id': vid, 'type': 'action', 'enabled': True,
            'address': address, 'value': 1}


def build():
    v = []
    # Cartridges: 0-9. Mappers are not persisted; they are per cartridge.
    v.append(field_list('Slot A Mapper', 0, DIP, 0, 4, MAPPERS_A, False))
    v.append(field_list('Slot B Mapper', 1, DIP, 4, 4, MAPPERS_B, False))
    v.append(action('Remove Cartridges', 5, SERVICE))
    v.append(action('Reset Core', 6, RESET))
    # Video: 10-19
    v.append(check('PAL Video', 10, DIP, 8, True))
    # Joy2Key: 20-29. These ids are new with this layout, so a mapping the
    # Pocket saved under the old ids (1000-1006, encoded for the old
    # registers) is not written into the new fields.
    v.append(check('Enable Joy2Key', 20, MOD, JOY2KEY_ENABLE_BIT, True))
    for i, (button, reg, low, keys) in enumerate(BUTTONS):
        opts = [('None', 0)] + [(k, KEYS[k]) for k in keys]
        v.append(field_list(f'Map {button} to key', 21 + i, reg, low,
                            KEY_BITS, opts, True))
    return {'interact': {'magic': 'APF_VER_1', 'variables': v,
                         'messages': []}}


def render(doc):
    # One line per option, like the template's interact.json, so a diff
    # shows the key that changed.
    text = json.dumps(doc, indent=2)
    out, i, lines = [], 0, text.split('\n')
    while i < len(lines):
        s = lines[i].strip()
        if s == '{' and i + 3 < len(lines) and \
                lines[i + 1].strip().startswith('"name"') and \
                lines[i + 2].strip().startswith('"value"') and \
                lines[i + 3].strip() in ('}', '},'):
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            out.append(f'{indent}{{{lines[i + 1].strip()} '
                       f'{lines[i + 2].strip()}{lines[i + 3].strip()}')
            i += 4
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out) + '\n'


def main(argv):
    doc = build()
    for b in doc['interact']['variables']:
        for o in b.get('options', []):
            assert len(o['name']) <= 26, o
    text = render(doc)
    if '--check' in argv:
        if not os.path.exists(OUT) or open(OUT).read() != text:
            print(f'{OUT} is out of date: run tools/make_interact.py')
            return 1
        return 0
    with open(OUT, 'w') as f:
        f.write(text)
    n_opts = sum(len(x.get('options', [])) for x in doc['interact']['variables'])
    print(f'wrote {os.path.relpath(OUT, ROOT)}: '
          f'{len(doc["interact"]["variables"])} entries, {n_opts} options')
    return subprocess.call([os.path.join(ROOT, 'tools', 'check-package.sh')])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
