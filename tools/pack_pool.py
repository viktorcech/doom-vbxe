#!/usr/bin/env python3
"""Shared texture POOL for the whole episode, so textures can be streamed one at
a time instead of a whole level's set having to be resident.

Why: pack_textures.py emits one .tex blob per level and load_textures streams the
whole thing into VBXE at level load. That works for E1M1 (313 KB) and E1M8
(169 KB) but not for the rest -- E1M2 alone needs 619 KB and VBXE has 512 KB, so
no amount of RAM or map juggling makes it fit. The visible working set, however,
is tiny: measured over E1M2, a sector shows at most 9 textures / 91 KB (average
2.3 / 21 KB), and the eight richest sectors together need 19 textures / 260 KB.
So a VRAM cache filled on demand is enough, and the piece that was missing is a
disk layout where each texture is individually addressable.

Emitted into build/assets/textures/:
  pool.tex      every distinct texture of the built levels, each PADDED to a
                whole 128-byte sector so a texture can be read by sector index.
                Column-major, exactly as before: texel(x,y) at base + x*h + y.
  pool.dir      u16 count, then per texture:
                  u16 sector   (offset into pool.tex, in sectors)
                  u16 sectors  (length)
                  u16 w, u16 h, u8 wlog2, u8 dom, 8s name       = 18 B
  {map}.poolidx u16 count, then u16 pool index per LEVEL texid -- the level's
                own texid space is unchanged, so nothing else has to move.

  python tools/pack_pool.py [E1M1 E1M2 ...]      (default: the whole episode)
"""
import os
import struct
import sys
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                       # noqa: E402
from wadtex import WadTextures                            # noqa: E402
from pack_textures import _seg_slots, half_cols           # noqa: E402

OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures')
SECTOR = 128


def level_texture_names(md):
    """The texture names this level references, in the same deterministic order
    pack_textures uses, so level texids keep their meaning."""
    slots = _seg_slots(md)
    return sorted({n for pair in slots for n in pair if n})


def build(names, wad_path=DEFAULT_WAD):
    wad = Wad(wad_path)
    wt = WadTextures(wad)
    maps = {n: wad.load_map(n) for n in names}

    pool = {}                                   # name -> (w, h, cols, dom)
    for md in maps.values():
        for nm in level_texture_names(md):
            if nm in pool:
                continue
            t = wt.get_texture(nm)
            if t is None:
                continue
            w, h, tx = t
            cols, w = half_cols(tx, w, h)       # column-major, 2:1 H (pack_textures)
            pool[nm] = (w, h, cols, Counter(cols).most_common(1)[0][0])

    order = sorted(pool)
    blob = bytearray()
    directory = bytearray(struct.pack('<H', len(order)))
    index = {}
    for i, nm in enumerate(order):
        w, h, cols, dom = pool[nm]
        sec = len(blob) // SECTOR
        pad = (-len(cols)) % SECTOR             # sector-align so it is addressable
        blob += cols + bytes(pad)
        nsec = (len(cols) + pad) // SECTOR
        index[nm] = i
        directory += struct.pack('<HHHHBB8s', sec, nsec, w, h,
                                 w.bit_length() - 1, dom,
                                 nm.encode('ascii', 'replace')[:8].ljust(8, b'\x00'))

    per_level = {}
    for nm, md in maps.items():
        ids = [index[t] for t in level_texture_names(md) if t in index]
        per_level[nm] = bytearray(struct.pack('<H', len(ids)))
        for pid in ids:
            per_level[nm] += struct.pack('<H', pid)
    return blob, directory, per_level, order, pool


def main():
    names = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not names:
        names = [f'E1M{i}' for i in range(1, 10)]
    os.makedirs(OUT_DIR, exist_ok=True)
    blob, directory, per_level, order, pool = build(names)

    with open(os.path.join(OUT_DIR, 'pool.tex'), 'wb') as f:
        f.write(blob)
    with open(os.path.join(OUT_DIR, 'pool.dir'), 'wb') as f:
        f.write(directory)
    for nm, idx in per_level.items():
        with open(os.path.join(OUT_DIR, f'{nm}.poolidx'), 'wb') as f:
            f.write(idx)

    per_sum = 0
    print(f'  levels : {" ".join(names)}')
    for nm in names:
        n = struct.unpack_from('<H', per_level[nm], 0)[0]
        kb = sum((len(pool[t][2]) + SECTOR - 1) // SECTOR * SECTOR
                 for t in level_texture_names(Wad().load_map(nm)) if t in pool) / 1024
        per_sum += kb
        print(f'    {nm}: {n:3} textures, {kb:7.1f} kB resident if all loaded')
    print(f'  pool   : {len(order)} distinct textures, {len(blob)/1024:.1f} kB '
          f'({len(blob)//SECTOR} sectors)')
    print(f'  sum of per-level sets would be {per_sum:.1f} kB -> pool saves '
          f'{per_sum - len(blob)/1024:.1f} kB of disk')
    print(f'  -> {OUT_DIR}')


if __name__ == '__main__':
    main()
