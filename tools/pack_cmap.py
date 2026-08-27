#!/usr/bin/env python3
"""DOOM's COLORMAP lump -> build/assets/cmap.bin, the port's light table.

The engine has no per-pixel light: a textured wall is blitted straight out of
VRAM and the VBXE blitter can only AND/XOR the source byte, which does nothing
useful to a PLAYPAL index (measured: at colormap row 8 only 30 of 256 entries
share a delta -- the palette is not a set of clean 16-step ramps, so no constant
add/mask darkens it). What the port CAN shade for free is every surface it
paints in ONE palette index: floors, ceilings, and any wall drawn flat (the 'T'
mode, or a texture whose pixels this build does not ship).

So the shading is exactly DOOM's, just applied per SURFACE instead of per pixel:
  colour = COLORMAP[row][colour],  row = (255 - sector->lightlevel) >> 3
which is r_main.c's `scalelight[lightnum]` with the distance term dropped
(lightnum = lightlevel >> LIGHTSEGSHIFT is the same 16-step ladder, doubled to
the colormap's 32).

The first 32 rows only: row 32 is the invulnerability inverse map and row 33 is
all-black, neither of which the port uses. 32 x 256 = 8192 B = exactly two 4 KB
chunks, so it rides into Rapidus SRAM behind the weapon master with no loader of
its own (make_atr_doom.py CMAP_EXT).

  python tools/pack_cmap.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                            # noqa: E402

OUT = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'cmap.bin')
ROWS = 32                                # light rows; 32/33 (invuln, black) dropped


def lump(w, name):
    i = w._index[name]
    _nm, off, size = w.lumps[i]
    return w.data[off:off + size]


def build(wad_path=DEFAULT_WAD):
    # pwads=[] AND NOT THE MERGED VIEW (2026-08-16). A COLORMAP is a table of
    # PALETTE INDICES -- row r maps every index to its shaded twin -- so it is
    # only meaningful together with the palette it was built for. The port
    # ships the IWAD's palette (wadtex.WadTextures: a layered WAD's graphics
    # are remapped INTO it), so the light table has to be the IWAD's too.
    # `Wad(path)` alone does NOT do that: pwads=None means "take DOOMPWAD from
    # the environment", so a heretic.wad conversion shipped HERETIC's colormap
    # over DOOM's palette and every shaded floor, ceiling and flat wall came
    # out a different colour than the one it was painted in.
    cm = lump(Wad(wad_path, pwads=[]), 'COLORMAP')
    if len(cm) < ROWS * 256:
        sys.exit(f'COLORMAP is {len(cm)} B, need at least {ROWS * 256}')
    return cm[:ROWS * 256]


def main():
    wad = next((a for a in sys.argv[1:] if a.lower().endswith('.wad')), DEFAULT_WAD)
    data = build(wad)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(data)
    print(f'  wrote {os.path.relpath(OUT, os.path.dirname(_HERE))}  '
          f'({len(data)} B, {ROWS} light rows x 256)')


if __name__ == '__main__':
    main()
