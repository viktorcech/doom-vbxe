#!/usr/bin/env python3
"""check_overlap -- fail the build when two XEX blocks load over each other.

2026-09-14: setup_chains grew 9 bytes and its tail landed under the block
org'd at $4B9E; nothing said a word (check_xex.py is off while ram_map.py is
missing) and the chain slots stopped being templated. Every bank-0 hole in
this port is fixed by org, so an overlap is always a bug -- EXCEPT the
INIT-staged chunks at B1STAGE ($9000-$9FFF), which are loaded in turn and
copied away by b1_stage_copy before the next one arrives.

    python build/py/check_overlap.py [build/doom_bsp.xex]   exit 1 on overlap
"""
import os
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.exists(os.path.join(ROOT, 'bsp_main.asm')) and os.path.dirname(ROOT) != ROOT:
    ROOT = os.path.dirname(ROOT)         # build/py/ here, tools/ in web/bundle.zip
XEX = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'doom_bsp.xex')
STAGE_LO, STAGE_HI = 0x9000, 0x9FFF


def blocks(path):
    d = open(path, 'rb').read()
    i = 2 if d[:2] == b'\xff\xff' else 0
    out = []
    while i + 4 <= len(d):
        lo, hi = struct.unpack_from('<HH', d, i)
        i += 4
        if lo == 0xFFFF:
            continue
        out.append((lo, hi))
        i += hi - lo + 1
    return out


def main():
    bl = blocks(XEX)
    bad = []
    for n, (lo, hi) in enumerate(bl):
        if STAGE_LO <= lo and hi <= STAGE_HI:
            continue
        for m, (lo2, hi2) in enumerate(bl[n + 1:], n + 1):
            if STAGE_LO <= lo2 and hi2 <= STAGE_HI:
                continue
            if lo <= hi2 and lo2 <= hi:
                # INIT/RUN vectors are written many times on purpose
                if lo == lo2 == 0x02E2 or lo == lo2 == 0x02E0:
                    continue
                bad.append((n, lo, hi, m, lo2, hi2))
    for n, lo, hi, m, lo2, hi2 in bad:
        print(f'OVERLAP: block {n} ${lo:04X}-${hi:04X} and block {m} ${lo2:04X}-${hi2:04X}')
    if bad:
        print(f'check_overlap: {len(bad)} overlapping XEX block pair(s) -- the later load wins')
        sys.exit(1)
    print(f'check_overlap OK ({len(bl)} blocks)')


if __name__ == '__main__':
    main()
