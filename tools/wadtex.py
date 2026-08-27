#!/usr/bin/env python3
"""DOOM WAD texture extraction over wadlib -- the real graphics the flat-shaded
port dropped.

Pulls:
  * PLAYPAL    -> 256-colour DOOM palette (RGB)
  * PNAMES     -> patch name table
  * TEXTURE1/2 -> composite wall-texture definitions
  * patches    -> DOOM picture (post/column) format, assembled into textures

get_texture(name) -> (w, h, tex) where tex[x][y] is a palette index (0..255),
column-major (natural for per-column wall sampling); None for '-'/missing.
Map palette indices -> RGB via self.playpal[idx].

This is the data side of putting textures back on the walls (Rapidus makes the
per-pixel loop feasible again). It does NOT change the .bin -- it's read straight
from the WAD, indexed the same way pack_map.py resolves a seg's texture name.

CLI (verify):  python wadtex.py [TEXNAME]   -> _pomocne/preview/<name>.png
               python wadtex.py --list       -> list texture names
"""
import os
import struct
import sys

from wadlib import Wad, DEFAULT_WAD, _name

_HERE = os.path.dirname(os.path.abspath(__file__))
_IDENTITY = bytes(range(256))          # "this file's palette is the shipped one"


class WadTextures:
    """Graphics out of a WAD PAIR, all of it in ONE palette.

    THE PALETTE IS THE IWAD'S, ALWAYS (2026-08-16). A layered WAD may ship its
    own PLAYPAL -- heretic.wad and hexen.wad do, and so does any total
    conversion -- and then the same byte means a different colour in its
    textures than in the IWAD's sprites. The Atari has ONE 256-entry VBXE
    palette for the whole screen, so one of the two has to give, and it cannot
    be the IWAD's: the status bar, the weapons, the monsters, the menu, the
    HU strips and the four flash palettes are all DOOM art indexed into DOOM's
    PLAYPAL, and the light table (pack_cmap.py COLORMAP) is indexed by it too.

    So a foreign file's pixels are REMAPPED here, index -> nearest colour in
    the IWAD's palette, once per file, and everything downstream (pack_map's
    dominant flat colour, texruns' runs, the sprite packer) sees indices that
    already mean what the shipped palette says.

    Plain DOOM is untouched by construction: with no second file, or one that
    ships no PLAYPAL, or one whose PLAYPAL is byte-identical, every table is
    the identity and not one packed byte moves (verified by hashing
    build/assets across the change)."""

    def __init__(self, wad, base_src=0):
        self.w = wad
        self.base_src = base_src               # the file whose palette SHIPS
        self._luts = {}                        # source -> 256-byte translate
        self.remapped = {}                     # source -> (colours, mean err)
        self.playpal_lump = (wad.source_lump(base_src, 'PLAYPAL')
                             if hasattr(wad, 'source_lump') else None)
        if self.playpal_lump is None:          # a Wad built before sources, or
            self.playpal_lump = self._lump('PLAYPAL')      # a WAD without one
        self.playpal = self._read_playpal()
        self.pnames = self._read_pnames()
        self.texdefs = {}                      # NAME -> (w, h, [(pnames_idx, ox, oy)])
        for ln in ('TEXTURE1', 'TEXTURE2'):
            self._read_texturex(ln)
        self._tex_cache = {}
        self._patch_cache = {}
        self._near_black = None
        self._patch_off = {}                   # patch -> (leftoffset, topoffset)

    # ---- raw lump access -----------------------------------------------------
    def _lump(self, name):
        idx = self.w._index.get(name.upper())
        if idx is None:
            return None
        _nm, off, size = self.w.lumps[idx]
        return self.w.data[off:off + size]

    # ---- the palette remap (see the class docstring) -------------------------
    def lut(self, name):
        """The 256-byte translate table for the file that ships lump `name`."""
        if not hasattr(self.w, 'lump_source'):
            return _IDENTITY
        src = self.w.lump_source(name)
        return _IDENTITY if src is None else self._lut(src)

    def _lut(self, src):
        if src in self._luts:
            return self._luts[src]
        raw = None if src == self.base_src else self.w.source_palette(src)
        if raw is None or bytes(raw) == bytes(self.playpal_lump[:768]):
            lut = _IDENTITY                    # same palette, or none of its own
        else:
            import numpy as np
            a = np.frombuffer(bytes(raw), dtype=np.uint8).reshape(256, 3)
            b = np.array(self.playpal, dtype=np.int32)
            d2 = ((a.astype(np.int32)[:, None, :] - b[None, :, :]) ** 2).sum(2)
            j = d2.argmin(1)
            lut = bytes(j.astype(np.uint8))
            err = np.sqrt(d2[np.arange(256), j])
            self.remapped[src] = (int((err == 0).sum()), float(err.mean()),
                                  float(err.max()), len(set(j.tolist())))
        self._luts[src] = lut
        return lut

    def remap_note(self):
        """One line per remapped file, or [] when nothing was remapped."""
        out = []
        for src, (exact, mean, worst, used) in sorted(self.remapped.items()):
            out.append(f'{os.path.basename(self.w.sources[src])} has its own '
                       f'PLAYPAL: its graphics are remapped into '
                       f'{os.path.basename(self.w.sources[self.base_src])}\'s '
                       f'palette ({exact} of 256 colours identical, {used} '
                       f'distinct targets, mean error {mean:.1f} of 441, '
                       f'worst {worst:.0f})')
        return out

    # ---- global tables -------------------------------------------------------
    def _read_playpal(self):
        d = self.playpal_lump
        if d is None:
            raise ValueError('WAD has no PLAYPAL')
        return [struct.unpack_from('<BBB', d, i * 3) for i in range(256)]

    def _read_pnames(self):
        d = self._lump('PNAMES')
        if d is None:
            return []
        n, = struct.unpack_from('<I', d, 0)
        return [_name(d[4 + i * 8:4 + i * 8 + 8]) for i in range(n)]

    def _read_texturex(self, lumpname):
        d = self._lump(lumpname)
        if d is None:
            return
        numtex, = struct.unpack_from('<i', d, 0)
        for i in range(numtex):
            offs, = struct.unpack_from('<i', d, 4 + i * 4)
            name = _name(d[offs:offs + 8])
            width, height = struct.unpack_from('<hh', d, offs + 12)
            patchcount, = struct.unpack_from('<h', d, offs + 20)
            patches = []
            for j in range(patchcount):
                po = offs + 22 + j * 10
                ox, oy, pidx = struct.unpack_from('<hhH', d, po)
                patches.append((pidx, ox, oy))
            self.texdefs[name.upper()] = (width, height, patches)

    # ---- patch (DOOM picture / post format) ----------------------------------
    def get_patch(self, name):
        up = name.upper()
        if up in self._patch_cache:
            return self._patch_cache[up]
        data = self._lump(up)
        tbl = self.lut(up)                      # this FILE's palette -> the
        out = None                              #   shipped one (usually identity)
        if data is not None and len(data) >= 8:
            w, h, _left, _top = struct.unpack_from('<hhhh', data, 0)
            self._patch_off[up] = (_left, _top)     # sprites need the offsets
            if 0 < w <= 4096 and 0 < h <= 4096:
                cols = []
                ok = True
                for cx in range(w):
                    colof, = struct.unpack_from('<I', data, 8 + cx * 4)
                    posts = []
                    p = colof
                    while p < len(data):
                        topdelta = data[p]; p += 1
                        if topdelta == 255:
                            break
                        length = data[p]; p += 1
                        p += 1                          # unused pad byte
                        pix = list(bytes(data[p:p + length]).translate(tbl))
                        p += length
                        p += 1                          # unused pad byte
                        posts.append((topdelta, pix))
                    else:
                        ok = False
                    cols.append(posts)
                if ok:
                    out = (w, h, cols)
        self._patch_cache[up] = out
        return out

    def patch_offset(self, name):
        """(leftoffset, topoffset) of a patch -- sprite anchor (feet/centre)."""
        up = name.upper()
        if up not in self._patch_off:
            self.get_patch(up)
        return self._patch_off.get(up, (0, 0))

    # ---- flats (floor/ceiling; 64x64 raw palette indices) --------------------
    def get_flat(self, name):
        """A flat lump: 4096 raw palette indices (64x64). None for sky/missing."""
        if not name or name in ('-', 'F_SKY1'):
            return None
        d = self._lump(name)
        if d is None or len(d) < 4096:
            return None
        return bytes(d).translate(self.lut(name))   # its file's palette -> ours

    def flat_dominant(self, name):
        """ONE representative PLAYPAL index for the flat-shaded floor/ceiling
        fill -- the flat's area-weighted MEAN colour, snapped to the nearest
        palette entry. None for sky/missing.

        It was the modal index until 2026-08-15, and the mode is the wrong
        statistic for a surface painted in a single colour: it answers "what is
        this flat's background", not "what does this flat look like". On a
        noisy rock or metal flat the two agree, but on a STRUCTURED one they do
        not, and every structured flat in DOOM is structured the same way --
        something bright inside a dark frame. TLITE6_1, the ceiling light panel
        E1M1 hangs over its two glowing alcoves, is 3616 dark border pixels and
        180 white ones: the mode is $05, RGB (27,27,27), so the port painted a
        LIGHT dark grey and the sector's glow ran between two shades of black.
        The mean puts it at (47,47,47) and the glow is visible again. 29 of
        episode 1's 50 flats move, all of them toward what the texture actually
        looks like; the other 21 were already the same index."""
        d = self.get_flat(name)
        if d is None:
            return None
        import numpy as np
        px = np.frombuffer(bytes(d[:4096]), dtype=np.uint8)
        pal = np.array(self.playpal, dtype=np.int32)
        mean = pal[px].mean(axis=0)
        return int(np.argmin(((pal - mean) ** 2).sum(axis=1)))

    # ---- composite wall texture ---------------------------------------------
    def get_texture(self, name, masked=False):
        """Composite wall texture -> (w, h, [[index]*h]*w).

        masked=True is the TWO-SIDED MIDDLE texture form (r_segs.c
        R_RenderMaskedSegRange): a texel no patch covered is TRANSPARENT, and
        the port marks that with palette index 0 -- so a covered texel that
        really is index 0 has to move to the next-darkest entry, or the
        painter would punch a hole in the bars themselves (paint.asm skips a
        run whose colour is 0). Opaque textures keep the plain 0-init: nothing
        downstream can tell the difference, because texruns.py never GIVES a
        run colour 0 unless the texture is masked."""
        if not name or name == '-':
            return None
        up = name.upper()
        key = (up, masked)
        if key in self._tex_cache:
            return self._tex_cache[key]
        td = self.texdefs.get(up)
        out = None
        if td is not None:
            w, h, patches = td
            tex = [[0] * h for _ in range(w)]           # opaque-init 0; walls fully cover
            cov = [bytearray(h) for _ in range(w)] if masked else None
            for (pidx, ox, oy) in patches:
                if not (0 <= pidx < len(self.pnames)):
                    continue
                pat = self.get_patch(self.pnames[pidx])
                if pat is None:
                    continue
                pw, ph, cols = pat
                for cx in range(pw):
                    dx = ox + cx
                    if not (0 <= dx < w):
                        continue
                    col = tex[dx]
                    for (topdelta, pix) in cols[cx]:
                        base = oy + topdelta
                        for k, px in enumerate(pix):
                            dy = base + k
                            if 0 <= dy < h:
                                col[dy] = px
                                if cov is not None:
                                    cov[dx][dy] = 1
            if cov is not None:
                alt = self.near_black()
                for x in range(w):
                    col, cc = tex[x], cov[x]
                    for y in range(h):
                        if cc[y]:
                            if col[y] == 0:
                                col[y] = alt
                        else:
                            col[y] = 0                  # transparent
            out = (w, h, tex)
        self._tex_cache[key] = out
        return out

    def near_black(self):
        """The darkest PLAYPAL entry that is NOT index 0 -- what a genuinely
        black texel becomes in a masked texture, so index 0 can mean
        'transparent' with no ambiguity."""
        if self._near_black is None:
            self._near_black = min(
                range(1, 256),
                key=lambda i: sum(c * c for c in self.playpal[i]))
        return self._near_black


# ---- CLI verify -------------------------------------------------------------
def _dump(wt, name):
    from PIL import Image
    t = wt.get_texture(name)
    if t is None:
        print(f'no such texture: {name}')
        return
    w, h, tex = t
    img = Image.new('RGB', (w, h))
    px = img.load()
    for x in range(w):
        for y in range(h):
            px[x, y] = wt.playpal[tex[x][y]]
    out_dir = os.path.join(os.path.dirname(_HERE), '_pomocne', 'preview')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f'{name.upper()}.png')
    img.resize((w * 3, h * 3), Image.NEAREST).save(out)
    print(f'{name.upper()}: {w}x{h} -> {out}')


def main():
    wt = WadTextures(Wad(DEFAULT_WAD))
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if '--list' in sys.argv:
        for nm in sorted(wt.texdefs):
            w, h, _ = wt.texdefs[nm]
            print(f'{nm:9} {w:3}x{h:3}')
        print(f'\n{len(wt.texdefs)} textures, {len(wt.pnames)} patches, PLAYPAL ok')
        return
    for nm in (args or ['STARTAN3']):
        _dump(wt, nm)


if __name__ == '__main__':
    main()
