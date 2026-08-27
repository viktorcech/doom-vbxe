#!/usr/bin/env python3
"""The shaded palette: 31 base colours x 8 light levels, in ONE VBXE palette.

WHY. DOOM darkens a room by running every pixel through a COLORMAP -- a
256->256 index LUT picked from the sector's lightlevel (r_segs.c:122,
`lightnum = (lightlevel >> LIGHTSEGSHIFT) + extralight`) and the distance. This
port has no per-pixel step to hang a LUT on: a wall column is one VBXE blit and
the blitter's only per-byte arithmetic is `c = (src & AND) ^ XOR`
(_pomocne/alt-src/Altirra/source/vbxe.cpp:3644). A mask cannot subtract, so the
light level has to live in the pixel VALUE, in bits the mask can reach.

THE LAYOUT. index = (shade << 5) | base, base 1..31, shade 0..7 (0 = brightest).
Palette entry (S,b) is DOOM's own colour for base b run through COLORMAP at the
level SHADE_CM[S] -- id's ramp, not a home-made fade.

Art is stored at the DARKEST shade, $E0 | base, and the blit BRIGHTENS with the
AND mask alone:

    BCB_AND = (S << 5) | $1F      BCB_XOR = 0        -> shade S

because $E0 AND (S<<5) is exactly S<<5. Three things fall out of doing it this
way round instead of the obvious `AND $1F / XOR S<<5`:

  * TRANSPARENCY SURVIVES. The sprite blits run BLT_BSTENCIL, and Altirra shows
    the "skip source byte" test happening AFTER the masking (vbxe.cpp:3680,
    `c &= andMask; c ^= xorMask; if (c) {...}`). With an XOR every transparent
    byte would come out as S<<5, i.e. opaque -- the whole sprite box painted.
    An AND leaves 0 as 0 at every shade.
  * ...which is why base 0 does not exist. An opaque pixel of base 0 would read
    as 0 at shade 0 and vanish. 31 colours, and index 0 means transparent.
  * A FLAT FILL still works: those blits run AND = 0, which Altirra turns into a
    straight `write(xorMask)` (vbxe.cpp:3631), so a flat writes (S<<5)|base as
    its XOR and needs nothing else.

WHAT IT COSTS. The art is requantised from PLAYPAL's 256 to 31 base colours.
Measured over the 100 wall textures E1 actually uses (207 distinct PLAYPAL
indices, 1.02M texels): mean RGB error 9 of a possible 441. Nothing is spent at
run time and nothing in VRAM -- the alternative, a pre-shaded copy of every
texture, would have multiplied a 192 KB texture arena that E1M2 already
overflows by 84 KB.

  python tools/palette32.py            # stats + build/assets/pal32.png preview
"""
import os
import struct
import sys
from collections import Counter

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from wadlib import Wad, DEFAULT_WAD                        # noqa: E402
from wadtex import WadTextures                            # noqa: E402

OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets')

NBASE = 32                      # 1..31 usable; 0 is the transparent slot
NSHADE = 8

# Which of DOOM's 32 colormaps each of our 8 shades is. Level 0 is id's own
# "full bright". The ramp stops at 28, not 31: row 31 sends almost every index
# to pure black, and spending one of only eight shades on "invisible" is a waste
# -- DOOM only ever reaches it by piling distance on top of a dark sector, which
# this port has no term for.
SHADE_CM = tuple(round(s * 28 / (NSHADE - 1)) for s in range(NSHADE))

# sector lightlevel -> shade. DOOM's r_main.c:745 gives a sector its brightest
# colormap as `startmap = (15 - (light>>4)) * 4` and then subtracts a distance
# term (up to 23 at the near end of the scale). This port has no per-pixel
# distance, so it picks the MIDDLE of that walk -- startmap - 12 -- which lands
# 255/208/192 on full bright and 64 and below on black, the same places the
# original does at arm's length.
def light_shade(light):
    cm = (15 - (min(255, max(0, light)) >> 4)) * 4 - 12
    cm = min(31, max(0, cm))
    return min(NSHADE - 1, max(0, round(cm * (NSHADE - 1) / 31)))


class Pal32:
    def __init__(self, wad=None):
        self.wad = wad or Wad(DEFAULT_WAD)
        self._raw = open(self.wad.path if hasattr(self.wad, 'path')
                         else DEFAULT_WAD, 'rb').read()
        self.playpal = self._lump('PLAYPAL')
        self.colormap = self._lump('COLORMAP')
        self.base = self._pick_base()          # [32] PLAYPAL index, base[0] unused
        self.remap = self._build_remap()       # [256] PLAYPAL index -> base 1..31

    # ---- wad access --------------------------------------------------------
    def _lump(self, name):
        i = self.wad._index[name]
        _, off, size = self.wad.lumps[i]
        return self._raw[off:off + size]

    def rgb(self, idx, slot=0):
        p = slot * 768 + 3 * idx
        return (self.playpal[p], self.playpal[p + 1], self.playpal[p + 2])

    # ---- the 31 base colours ----------------------------------------------
    def art_histogram(self):
        """Every PLAYPAL index the shipped art uses, weighted by how often.

        Walls are counted per texel over the textures E1 actually references;
        sprites/HUD/weapon patches are counted per pixel over every lump in
        S_START..S_END plus the status bar. Transparent patch gaps are not in
        the runs at all, so they never vote."""
        wt = WadTextures(self.wad)
        hist = Counter()
        names = set()
        for m in range(1, 10):
            md = self.wad.load_map(f'E1M{m}')
            for sd in md.sidedefs:
                for t in (sd.upper, sd.middle, sd.lower):
                    if t and t != '-':
                        names.add(t.upper())
        for n in sorted(names):
            t = wt.get_texture(n)
            if t:
                for col in t[2]:
                    hist.update(col)
        for nm, off, size in self.wad.lumps:      # sprites + HUD + weapons
            if size < 12 or not self._looks_like_patch(off, size):
                continue
            pat = wt.get_patch(nm)
            if not pat:
                continue
            for col in pat[2]:
                for _td, pix in col:
                    hist.update(pix)
        return hist

    def _looks_like_patch(self, off, size):
        w, h, _lo, _to = struct.unpack_from('<HHhh', self._raw, off)
        if not (0 < w <= 320 and 0 < h <= 200) or size < 8 + 4 * w:
            return False
        first = struct.unpack_from('<I', self._raw, off + 8)[0]
        return 8 + 4 * w <= first < size

    def _pick_base(self):
        """31 PLAYPAL indices, weighted k-means in RGB seeded by the most-used
        colours, each centre snapped back to a REAL PLAYPAL index -- the shaded
        variants come out of COLORMAP, which is indexed by PLAYPAL index, so a
        made-up RGB triple would have nothing to darken.

        Cached: the sweep reads every wall texture and every patch in the WAD
        (6M pixels, ~40 s) and each packer is its own process, so a full ATR
        build would pay it eight times over for an answer that only changes when
        the WAD does. Delete build/assets/pal32_base.txt to force a rebuild."""
        cache = os.path.join(OUT_DIR, 'pal32_base.txt')
        key = f'{os.path.getsize(DEFAULT_WAD)} {NBASE}'
        if os.path.exists(cache):
            head, _, body = open(cache).read().partition('\n')
            vals = [int(v) for v in body.split()]
            if head.strip() == key and len(vals) == NBASE:
                return vals
        hist = self.art_histogram()
        hist.pop(0, None)                         # pure black is the empty slot
        if not hist:
            raise RuntimeError('no art pixels found -- wrong WAD?')
        pts = [(i, c, self.rgb(i)) for i, c in hist.items()]
        centres = [self.rgb(i) for i, _ in hist.most_common(NBASE - 1)]
        while len(centres) < NBASE - 1:           # tiny WADs: pad deterministically
            centres.append(centres[-1])
        for _ in range(24):                       # Lloyd, fixed round count
            sums = [[0, 0, 0, 0] for _ in centres]
            for _i, c, (r, g, b) in pts:
                k = min(range(len(centres)),
                        key=lambda j: (r - centres[j][0]) ** 2
                        + (g - centres[j][1]) ** 2 + (b - centres[j][2]) ** 2)
                s = sums[k]
                s[0] += r * c
                s[1] += g * c
                s[2] += b * c
                s[3] += c
            moved = [(s[0] // s[3], s[1] // s[3], s[2] // s[3]) if s[3] else c
                     for s, c in zip(sums, centres)]
            if moved == centres:
                break
            centres = moved
        # snap each centre to the nearest PLAYPAL index, keeping them distinct
        taken, base = set(), []
        for (r, g, b) in centres:
            order = sorted(range(1, 256),
                           key=lambda i: (r - self.rgb(i)[0]) ** 2
                           + (g - self.rgb(i)[1]) ** 2 + (b - self.rgb(i)[2]) ** 2)
            pick = next((i for i in order if i not in taken), order[0])
            taken.add(pick)
            base.append(pick)
        out = [0] + sorted(base, key=lambda i: sum(self.rgb(i)))
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(cache, 'w') as f:
            f.write(key + '\n' + ' '.join(str(v) for v in out) + '\n')
        return out

    def _build_remap(self):
        """PLAYPAL index -> base 1..31. Index 0 is DOOM's pure black AND what
        wadtex leaves where no patch covered a wall, so it maps to the darkest
        base rather than to the transparent slot: a wall with a hole in it must
        read black, not see-through."""
        out = [0] * 256
        for i in range(256):
            r, g, b = self.rgb(i)
            out[i] = min(range(1, NBASE),
                         key=lambda k: (r - self.rgb(self.base[k])[0]) ** 2
                         + (g - self.rgb(self.base[k])[1]) ** 2
                         + (b - self.rgb(self.base[k])[2]) ** 2)
        return out

    # ---- the VBXE palette --------------------------------------------------
    def vbxe_palette(self, slot=0):
        """768 B: entry (S<<5)|b = base b seen through COLORMAP row SHADE_CM[S],
        looked up in PLAYPAL slot `slot` (0 normal, 5 damage red, 10 pickup)."""
        out = bytearray(768)
        for s in range(NSHADE):
            cm = SHADE_CM[s] * 256
            for b in range(1, NBASE):
                idx = self.colormap[cm + self.base[b]]
                r, g, bl = self.rgb(idx, slot)
                p = 3 * ((s << 5) | b)
                out[p], out[p + 1], out[p + 2] = r, g, bl
        return bytes(out)                          # (S<<5)|0 stays black

    def texel(self, playpal_index):
        """An art pixel, stored at the DARKEST shade so the AND mask can pick
        any level: $E0 | base."""
        return 0xE0 | self.remap[playpal_index]

    @staticmethod
    def and_mask(shade):
        return ((shade & 7) << 5) | 0x1F


_SINGLETON = None


def pal32():
    global _SINGLETON
    if _SINGLETON is None:
        _SINGLETON = Pal32()
    return _SINGLETON


def preview(names=('STARTAN3', 'BROWN1', 'COMPTALL', 'TEKWALL4')):
    """build/assets/pal32.png -- each texture as DOOM ships it, then the same
    texture requantised and shown at all eight shades. The point is to judge the
    31-colour loss and the darkness ramp by EYE before five packers are rewired
    around them."""
    from PIL import Image
    p = pal32()
    wt = WadTextures(p.wad)
    rows = []
    for n in names:
        t = wt.get_texture(n)
        if t:
            rows.append((n, t))
    if not rows:
        return None
    cw = max(t[0] for _n, t in rows)
    ch = max(t[1] for _n, t in rows)
    img = Image.new('RGB', (cw * (NSHADE + 1), ch * len(rows)), (0, 0, 0))
    px = img.load()
    for r, (_n, (w, h, tex)) in enumerate(rows):
        for x in range(w):
            for y in range(h):
                src = tex[x][y]
                px[x, r * ch + y] = p.rgb(src)             # column 0: original
                stored = p.texel(src)                      # $E0 | base
                for s in range(NSHADE):
                    idx = stored & Pal32.and_mask(s)
                    q = 3 * idx
                    pal = p.vbxe_palette(0)
                    px[cw * (s + 1) + x, r * ch + y] = (pal[q], pal[q + 1],
                                                        pal[q + 2])
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, 'pal32.png')
    img.save(out)
    return out


def main():
    p = pal32()
    hist = p.art_histogram()
    tot = sum(hist.values())
    err = 0
    for i, c in hist.items():
        r, g, b = p.rgb(i)
        br, bg, bb = p.rgb(p.base[p.remap[i]])
        err += c * ((r - br) ** 2 + (g - bg) ** 2 + (b - bb) ** 2) ** 0.5
    print(f'art: {len(hist)} distinct PLAYPAL indices, {tot} pixels')
    print(f'31 base colours: {[p.base[b] for b in range(1, NBASE)]}')
    print(f'mean requantisation error {err / tot:.1f} RGB units (max 441)')
    print(f'shade -> COLORMAP row: {list(SHADE_CM)}')
    print('lightlevel -> shade: ' +
          ', '.join(f'{L}->{light_shade(L)}' for L in
                    (255, 208, 192, 176, 160, 144, 128, 112, 96, 80, 64, 0)))
    for s in range(NSHADE):
        print(f'  AND ${Pal32.and_mask(s):02X} -> shade {s} '
              f'(COLORMAP {SHADE_CM[s]})')
    try:
        out = preview()
        print(f'preview -> {out}' if out else 'preview: no textures found')
    except ImportError:
        print('preview skipped (no PIL)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
