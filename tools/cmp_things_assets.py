#!/usr/bin/env python3
"""Compare two build/assets/things trees LEVEL BY LEVEL, by what the engine sees.

Byte-compares .dtab / .things / .los. .sprcol cannot be byte-compared across a
repack: its FTAB holds offsets into sprpool.bin, the ONE sprite pool every level
shares, so a level that packs different frames shifts the pool for every level
packed after it. So for .sprcol the check is per frame id: same coltab bytes,
same stored size, and the SAME PIXEL BYTES at each side's own pool offset.

    python tools/cmp_things_assets.py <old_dir> [<new_dir>]   (new = build/assets/things)

Exit 0 = every level identical as far as the engine can tell; the report lists
the levels that differ and how.
"""
import glob
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(_HERE)
FTAB_OFF = 0xE000          # pack_things.FTAB_OFF
NFRAMES_MAX = 255          # pack_things.NFRAMES_MAX
FTAB_ROW = 8               # pack_things.FTAB_ROW


def frames(sprcol, pool):
    """[(size, coltab bytes, pixel bytes)] per frame id; None past the last."""
    out = []
    for i in range(NFRAMES_MAX):
        row = sprcol[FTAB_OFF + i * FTAB_ROW:FTAB_OFF + (i + 1) * FTAB_ROW]
        lo, hi, sz, ptr, _pad = struct.unpack('<HBHHB', row)
        if row == bytes(FTAB_ROW):
            out.append(None)
            continue
        off = lo | (hi << 16)
        out.append((sz, ptr, pool[off:off + sz]))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    old = sys.argv[1]
    new = sys.argv[2] if len(sys.argv) > 2 else os.path.join(PROJ, 'build', 'assets', 'things')
    pool_o = open(os.path.join(old, 'sprpool.bin'), 'rb').read()
    pool_n = open(os.path.join(new, 'sprpool.bin'), 'rb').read()
    names = sorted(os.path.splitext(os.path.basename(p))[0]
                   for p in glob.glob(os.path.join(new, '*.dtab')))
    changed = 0
    for nm in names:
        notes = []
        for ext in ('dtab', 'things', 'los'):
            a = open(os.path.join(old, f'{nm}.{ext}'), 'rb').read()
            b = open(os.path.join(new, f'{nm}.{ext}'), 'rb').read()
            if a != b:
                nd = sum(x != y for x, y in zip(a, b)) + abs(len(a) - len(b))
                notes.append(f'.{ext}: {nd} B differ')
        so = open(os.path.join(old, f'{nm}.sprcol'), 'rb').read()
        sn = open(os.path.join(new, f'{nm}.sprcol'), 'rb').read()
        if so[:FTAB_OFF] != sn[:FTAB_OFF]:
            notes.append('.sprcol coltabs differ')
        fo, fn = frames(so, pool_o), frames(sn, pool_n)
        bad = [i for i in range(NFRAMES_MAX) if fo[i] != fn[i]]
        if bad:
            notes.append(f'.sprcol: {len(bad)} frame id(s) differ in size/coltab/pixels '
                         f'(first {bad[0]})')
        elif so != sn:
            notes.append('(.sprcol pool offsets moved only -- same frames)')
        real = [n for n in notes if not n.startswith('(')]
        changed += bool(real)
        print(f'{"DIFF" if real else "same"} {nm}' + (f'  {"; ".join(notes)}' if notes else ''))
    print(f'\n{changed} level(s) differ as the engine sees them')
    return 1 if changed else 0


if __name__ == '__main__':
    sys.exit(main())
