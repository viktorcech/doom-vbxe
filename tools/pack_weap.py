#!/usr/bin/env python3
"""DOOM weapon PSPRITES (the gun in your hands) straight out of the WAD.

The player's weapon is not a world sprite: r_things.c R_DrawPSprite draws it at a
FIXED screen position derived from the patch's own offsets plus psp->sx/sy (the
bob + the raise/lower slide). Neither the position nor the size depends on the
view, so the whole projection can be precomputed HERE and the 6502 side is one
BLT_BSTENCIL rectangle blit per frame -- the same blit hud.asm already does.

The projection, with viewwidth 320 / viewheight 168 (DOOM's status-bar view, so
pspritescale = pspriteyscale = FRACUNIT and centerx/centery = 160/84):

    x1  = 1 - leftoffset                        (psp->sx = FRACUNIT = 1 px)
    top = 16 - topoffset                        (psp->sy = WEAPONTOP = 32)

and at runtime weapon.asm adds the bob (psp->sx/sy) and the raise/lower offset
(sy - WEAPONTOP), both in the SAME units -- DOOM pixels vertically, half-pixels
(= our bytes) horizontally.

Two adaptations, both invisible:
  * horizontal 2:1 sampling, exactly like pack_hud.py -- our byte covers two DOOM
    pixels.
  * every frame is cropped to its opaque bounding box AND to the rows the 3D view
    can actually show (0..167; the bar owns 168+). That is not a fidelity loss --
    those pixels are behind the status bar and DOOM never draws them either.
    Cropping the BOTTOM is safe because psp->sy only ever moves the weapon DOWN
    (bob adds |sin|, the raise/lower slide adds sy-32 >= 0).

RESIDENCY (2026-08-03, the VRAM diet -- see _navrh_vram.txt T1). The full set is
76 KB of pixels and used to live in VBXE VRAM permanently, scattered over six
4 KB-aligned holes (REGIONS). But only ONE weapon is ever drawn, and its whole
set (gun + flash) is at most ~21 KB (the shotgun). So:
  * the WHOLE blob goes to Rapidus SRAM at WEAP_EXT ($04:0000) once, at boot
    (load_weapons streams it there like the SFX blob into bank $02), and
  * VRAM keeps ONE slot, WEAP_SLOT ($071000, WEAP_SLOT_CHUNKS x 4 KB): on a
    weapon switch weapon.asm's wp_wload copies the active weapon's frames
    SRAM -> slot through the MEMAC-A window (~15 ms, hidden inside the raise
    animation). The other ~64 KB of VRAM went to the per-level tex+spr pool.
Frames of one weapon are packed CONTIGUOUS (gun frames then flash frames), so
the copy is one linear run and weap.tab's per-frame VRAM address is simply
WEAP_SLOT + the frame's offset inside its weapon -- static, so the record
format and draw_weapon do not change at all.

  python pack_weap.py            -> build/assets/weap/weap.bin  (SRAM master)
                                    build/assets/weap/weap.tab  (per-frame record)
                                    weap_tables.inc             (WPF_*/slot/copy equs)
                                    _pomocne/preview/*.png        (preview, needs PIL)
"""
import os
import struct
import sys

from wadlib import Wad, DEFAULT_WAD
from wadtex import WadTextures
from pack_things import darkest_nonzero

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJ = os.path.dirname(_HERE)
OUT = os.path.join(_PROJ, 'build', 'assets', 'weap')
PNG = os.path.join(_PROJ, '_pomocne', 'preview')
OUT_INC = os.path.join(_PROJ, 'weap_tables.inc')

VIEW_HEIGHT = 168                 # rows the 3D view owns; the bar starts at 168
BASEYCENTER = 100                 # r_things.c
CENTERY = VIEW_HEIGHT // 2        # R_ExecuteSetViewSize: viewheight/2
WEAPONTOP = 32                    # p_pspr.c

# ---- the VRAM slot + the SRAM master (memory_map.inc is the mirror) ----------
WEAP_SLOT = 0x077000              # active weapon's frames, WEAP_SLOT_CHUNKS x 4 KB
                                  # (2026-08-11: was $071000 -- bank 7's head is
                                  # FRAME_C, the triple buffer's third frame)
WEAP_SLOT_CHUNKS = 6              # 24 KB: the shotgun (21,203 B) is the ceiling
WEAP_EXT = 0x040000               # Rapidus SRAM master: every weapon's frames,
                                  # loaded once at boot (diskio.asm load_weapons)
CHUNK = 0x1000

# ---- what to extract -------------------------------------------------------
# (weapon key, sprite prefix, frames used by the STATES in info.c, flash prefix)
# Only frames a state actually names are packed: PISGD0/PISGE0 exist in the WAD
# but no pistol state references them (7 KB saved).
WEAPONS = [
    ('fist',     'PUNG', 'ABCD', ('',     '')),
    ('pistol',   'PISG', 'ABC',  ('PISF', 'A')),
    ('shotgun',  'SHTG', 'ABCD', ('SHTF', 'AB')),
    ('chaingun', 'CHGG', 'AB',   ('CHGF', 'AB')),
    # 2026-07-30. Appended, never inserted: WPF_* is the frame's INDEX, and
    # weapon.asm's state table is written in terms of those names.
    ('chainsaw', 'SAWG', 'ABCD', ('',     '')),   # S_SAW*: no flash (am_noammo)
    ('missile',  'MISG', 'AB',   ('MISF', 'ABCD')),
    ('plasma',   'PLSG', 'AB',   ('PLSF', 'AB')),
]

# WEAPONS-list key -> the WP_* id (memory_map.inc / d_items.c wp_* enum). The
# copy table wp_wload indexes is WP_*-ordered; WP_BFG (6) has no art and its row
# mirrors the pistol so a stray index copies something harmless.
WP_ID = {'fist': 0, 'pistol': 1, 'shotgun': 2, 'chaingun': 3,
         'missile': 4, 'plasma': 5, 'chainsaw': 7}
WP_NWEAP = 8


def frames():
    """The flat frame list, in WPF_* id order: gun frames then flash frames."""
    out = []
    for _w, pre, fr, (fpre, ffr) in WEAPONS:
        for f in fr:
            out.append((f'WPF_{pre}{f}', pre + f + '0'))
        for f in ffr:
            out.append((f'WPF_{fpre}{f}', fpre + f + '0'))
    return out


def project(wt, lump, black):
    """(ax, ay, w, h, pixels) -- the frame cropped, halved and placed on screen.

    ax is a BYTE column (0..159), ay a screen ROW, both for psp->sx/sy at their
    resting values; weapon.asm adds the slide (and the sway, if WP_SWAY is on).

    `black` is what an OPAQUE pixel of palette index 0 becomes: the blit is
    BLT_BSTENCIL, which skips source bytes == 0, and index 0 in PLAYPAL is real
    pure black -- of which the pistol has plenty (the barrel, the shadow under
    the hand). Left as 0 those pixels are transparent and the wall shows THROUGH
    the gun. Same fix and the same helper as the world sprites (pack_things.py).
    """
    pat = wt.get_patch(lump)
    if pat is None:
        sys.exit(f'{lump}: lump not in the WAD')
    w, h, cols = pat
    left, top = wt.patch_offset(lump)
    x1 = 1 - left                                  # R_DrawPSprite, see the header
    y0row = CENTERY - (BASEYCENTER - WEAPONTOP + top)     # = 16 - top
    # opaque bbox over the columns we KEEP (even ones) and the rows the view shows
    bx0 = bx1 = ry0 = ry1 = None
    for cx in range(0, w, 2):
        for (td, pix) in cols[cx]:
            for k in range(len(pix)):
                y = td + k
                if y0row + y >= VIEW_HEIGHT:
                    continue                       # behind the status bar
                b = cx // 2
                bx0 = b if bx0 is None else min(bx0, b)
                bx1 = b if bx1 is None else max(bx1, b)
                ry0 = y if ry0 is None else min(ry0, y)
                ry1 = y if ry1 is None else max(ry1, y)
    if bx0 is None:
        sys.exit(f'{lump}: nothing visible in rows 0..{VIEW_HEIGHT - 1}')
    bw, bh = bx1 - bx0 + 1, ry1 - ry0 + 1
    img = bytearray(bw * bh)                       # 0 = transparent (BLT_BSTENCIL)
    for cx in range(0, w, 2):
        b = cx // 2 - bx0
        if not 0 <= b < bw:
            continue
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                y = td + k - ry0
                if 0 <= y < bh:
                    img[y * bw + b] = c if c else black
    return (x1 >> 1) + bx0, y0row + ry0, bw, bh, img


def place(proj):
    """SRAM layout: per weapon, its frames back to back; weapons back to back.

    -> (frame index -> (sram_addr, slot_addr), per-weapon [(key, src, len)]).
    The slot address is WEAP_SLOT + the frame's offset inside its own weapon,
    which is what weap.tab carries -- wp_wload copies the weapon's whole run to
    WEAP_SLOT, so the addresses hold whenever the weapon is the resident one."""
    addr = {}
    weap_runs = []
    i = 0
    off = 0
    for (key, _pre, fr, (_fpre, ffr)) in WEAPONS:
        n = len(fr) + len(ffr)
        run0 = off
        for k in range(n):
            img = proj[i + k][4]
            addr[i + k] = (WEAP_EXT + off, WEAP_SLOT + (off - run0))
            off += len(img)
        wlen = off - run0
        assert wlen <= WEAP_SLOT_CHUNKS * CHUNK, \
            f'{key}: {wlen} B > the {WEAP_SLOT_CHUNKS * CHUNK} B VRAM slot ' \
            f'(WEAP_SLOT_CHUNKS in this file + memory_map.inc)'
        weap_runs.append((key, WEAP_EXT + run0, wlen))
        i += n
    return addr, weap_runs, off


def emit(wt):
    fr = frames()
    black = darkest_nonzero(wt.playpal)
    proj = [project(wt, lump, black) for _id, lump in fr]
    addr, weap_runs, total = place(proj)

    # ---- weap.bin: the SRAM master, one contiguous run padded to 4 KB chunks
    #      (load_weapons streams it 32 sectors at a time, like the SFX blob) ----
    blob = bytearray(((total + CHUNK - 1) // CHUNK) * CHUNK)
    for i, (_ax, _ay, _w, _h, img) in enumerate(proj):
        o = addr[i][0] - WEAP_EXT
        blob[o:o + len(img)] = img

    # ---- weap.tab: u16/u8 vram (the SLOT address), w, h, ax, ay per frame ----
    tab = bytearray()
    for i, (ax, ay, w, h, _img) in enumerate(proj):
        a = addr[i][1]
        tab += struct.pack('<HBBBBB', a & 0xFFFF, (a >> 16) & 0xFF, w, h, ax, ay)

    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, 'weap.bin'), 'wb').write(blob)
    open(os.path.join(OUT, 'weap.tab'), 'wb').write(tab)

    # ---- the copy table, WP_*-ordered: where each weapon's run starts in SRAM
    #      and how many 256-byte pages wp_wload moves (BFG mirrors the pistol) --
    by_key = {key: (src, wlen) for key, src, wlen in weap_runs}
    wpl = [None] * WP_NWEAP
    for key, (src, wlen) in by_key.items():
        wpl[WP_ID[key]] = (key, src, (wlen + 255) // 256)
    wpl[6] = ('bfg=pistol', by_key['pistol'][0], (by_key['pistol'][1] + 255) // 256)

    with open(OUT_INC, 'w') as f:
        f.write('; AUTO-GENERATED by tools/pack_weap.py -- do not edit.\n')
        f.write('; Weapon psprite frames: WEAP_TAB index per frame (7 B records,\n')
        f.write('; u24 vram / u8 w / u8 h / u8 screen byte-column / u8 screen row).\n')
        f.write('; The vram address points into the ACTIVE-WEAPON SLOT: the whole\n')
        f.write('; blob lives in Rapidus SRAM (WEAP_EXT, loaded once at boot) and\n')
        f.write('; wp_wload copies the current weapon\'s run into WEAP_SLOT on a\n')
        f.write('; switch. WPL_SRCn/WPL_NPGn (WP_* order) drive that copy.\n')
        for i, (name, lump) in enumerate(fr):
            ax, ay, w, h, _ = proj[i]
            f.write(f'{name:12s} equ {i:<3d}          ; {lump} {w}x{h} @ ({ax},{ay})\n')
        f.write(f'WEAP_NFRAME  equ {len(fr)}\n')
        f.write(f'WEAP_SLOT    equ ${WEAP_SLOT:06X}   ; VRAM: the active weapon\n')
        f.write(f'WEAP_SLOT_BK0 equ ${WEAP_SLOT >> 12:02X}\n')
        f.write(f'WEAP_SLOT_CHUNKS equ {WEAP_SLOT_CHUNKS}\n')
        f.write(f'WEAP_EXT     equ ${WEAP_EXT:06X}   ; Rapidus SRAM: the master\n')
        f.write(f'WEAP_EXT_BANK equ ${WEAP_EXT >> 16:02X}\n')
        for wp in range(WP_NWEAP):
            key, src, npg = wpl[wp]
            f.write(f'WPL_SRC{wp}     equ ${src:06X}   ; {key}\n')
            f.write(f'WPL_NPG{wp}     equ {npg}\n')
        f.write(f'WEAP_BYTES   equ {len(blob)}\n')
    print(f'weap.bin {len(blob)} B ({total} B of pixels in {len(fr)} frames, '
          f'SRAM ${WEAP_EXT:06X}..${WEAP_EXT + total:06X}), '
          f'weap.tab {len(tab)} B -> {os.path.relpath(OUT, _PROJ)}')
    for key, src, wlen in weap_runs:
        print(f'  {key:9s} ${src:06X}  {wlen:6d} B '
              f'({(wlen + 255) // 256} pages -> slot ${WEAP_SLOT:06X})')
    return fr, proj


def preview(wt, fr, proj):
    """One PNG per frame: the weapon where it lands on the Atari framebuffer
    (160x200 stretched back to 640x400), with the status-bar rows marked.

    OFF unless WEAP_PNG=1 is in the environment: the build runs this packer
    every time and nobody wants _pomocne/preview/ refilled on every build."""
    if os.environ.get('WEAP_PNG') != '1':
        return
    try:
        from PIL import Image
    except ImportError:
        print('  (PIL missing -- no preview)')
        return
    pal = wt.playpal
    os.makedirs(PNG, exist_ok=True)
    for i, (name, lump) in enumerate(fr):
        ax, ay, w, h, img = proj[i]
        canvas = Image.new('RGB', (160, 200), (24, 24, 24))
        px = canvas.load()
        for y in range(168, 200):                  # the bar's rows
            for x in range(160):
                px[x, y] = (60, 40, 40)
        for y in range(h):
            for x in range(w):
                c = img[y * w + x]
                if c and 0 <= ax + x < 160 and 0 <= ay + y < 200:
                    px[ax + x, ay + y] = pal[c]
        canvas.resize((640, 400), Image.NEAREST).save(
            os.path.join(PNG, f'{name[4:].lower()}.png'))
    print(f'  preview -> {os.path.relpath(PNG, _PROJ)}/*.png ({len(fr)} frames)')


def main():
    wad = Wad(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WAD)
    wt = WadTextures(wad)
    fr, proj = emit(wt)
    preview(wt, fr, proj)


if __name__ == '__main__':
    main()
