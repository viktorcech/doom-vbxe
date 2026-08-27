#!/usr/bin/env python3
"""DOOM status bar (STBAR & co) straight out of the WAD -- extraction + preview.

Everything is the original graphic at the original st_stuff.c coordinates; the
only adaptation is horizontal: our framebuffer is 160 bytes wide displayed as 320
hardware pixels, so the bar is sampled 2:1 like the rest of the picture.

  python pack_hud.py            -> _pomocne/preview/stbar_320.png (as DOOM draws it)
                                   _pomocne/preview/stbar_160.png (as the Atari will)
"""
import os
import sys

from wadlib import Wad, DEFAULT_WAD
from wadtex import WadTextures

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(_HERE), '_pomocne', 'preview')

# st_stuff.c: ST_HEIGHT 32, ST_Y = 200-32 = 168. All coordinates below are DOOM's,
# relative to the bar's top-left corner (so screen y minus 168).
ST_Y = 168
ST_AMMOX, ST_AMMOY = 44, 171           # big red, 3 digits, RIGHT edge at x
ST_HEALTHX, ST_HEALTHY = 90, 171       # big red + STTPRCNT
ST_ARMORX, ST_ARMORY = 221, 171
ST_ARMSX, ST_ARMSY = 111, 172          # 3x2 grid of weapon numbers
ST_ARMSXSPACE, ST_ARMSYSPACE = 12, 10
ST_FACESX, ST_FACESY = 143, 168
ST_KEY0X, ST_KEY0Y = 239, 171
ST_KEY1X, ST_KEY1Y = 239, 181
ST_KEY2X, ST_KEY2Y = 239, 191
ST_AMMO0X, ST_AMMO0Y = 288, 173        # small yellow, 3 digits, right-aligned
ST_AMMOSPACE = 6
ST_MAXAMMO0X = 314


def draw_patch(px, wt, name, x, y, pal):
    """Blit a WAD patch with its own offsets, DOOM-style (post gaps stay clear)."""
    p = wt.get_patch(name)
    if p is None:
        print(f'  missing lump: {name}')
        return 0, 0
    w, h, cols = p
    left, top = wt.patch_offset(name)
    for cx in range(w):
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                dx, dy = x - left + cx, y - top + td + k
                if 0 <= dx < 320 and 0 <= dy < 200:
                    px[dx, dy] = pal[c]
    return w, h


def draw_num(px, wt, value, right_x, y, prefix, pal, digits=3):
    """STlib_drawNum: x is the RIGHT edge, digits are emitted right to left."""
    w = wt.get_patch(prefix + '0')[0]
    x = right_x
    num = value
    n = digits
    while n:
        x -= w
        draw_patch(px, wt, prefix + str(num % 10), x, y, pal)
        num //= 10
        n -= 1
        if not num:
            break
    return x


HUD_VRAM_BASE = 0x07D000       # 2026-08-11: bank 7 repacked for FRAME_C (the
                               # triple buffer's third frame): FRAME_C $070000,
                               # WEAP_SLOT $077000, HUD here -- 3 x 4 KB chunks,
                               # exactly to the top of the 512 KB VRAM
# What the engine needs to draw: the bar plus every glyph the status widgets use.
# Order matters: the engine indexes this table (0 = STBAR, 1..10 = digits,
# 11 = '%'). The rest of the widgets (arms, keys, face, small yellow digits)
# follow and get drawn once there is code for them.
HUD_LUMPS = (['STBAR'] + [f'STTNUM{i}' for i in range(10)] + ['STTPRCNT', 'STARMS']
             + [f'STKEYS{i}' for i in range(3)]
             + ['STFST00', 'STFST01', 'STFST02', 'STFEVL0']   # 16..18 look-around,
                                                              # 19 evil grin (weapon)
             # 2026-07-29: the face reacts to HEALTH, like DOOM's
             # ST_calcPainOffset. DOOM keeps 5 pain levels x 3 look-around
             # frames; only 3 levels fit the HUD VRAM budget (3 chunks,
             # $07D000..$07FFFF since 2026-08-11), so we take DOOM's levels 0/2/4
             # -- healthy, hurt, critical -- which gives the biggest visual
             # difference for the bytes. 6 patches, 2178 B.
             + ['STFST20', 'STFST21', 'STFST22']              # 20..22 hurt
             + ['STFST40', 'STFST41', 'STFST42']              # 23..25 critical
             # 2026-08-07 ("tvar v HUDe by sa mala menit pri damage"): the face
             # DOOM really shows while plyr->damagecount is up, one per pain
             # level. NOT the ouch face -- st_stuff.c tests
             #     plyr->health - st_oldhealth > ST_MUCHPAIN
             # and st_oldhealth is LAST tic's health (line 994), so taking
             # damage makes that difference negative and the ouch branch never
             # fires. What is left is ST_RAMPAGEOFFSET (STFKILL) for a hit with
             # no attacker -- the nukage -- and for a monster standing head-on;
             # the turn-left/right pair would be six more patches and the slot
             # holds three (3 chunks, $07D000..$07FFFF since 2026-08-11).
             + ['STFKILL0', 'STFKILL2', 'STFKILL4']           # 26..28 rampage
             + [f'STYSNUM{i}' for i in range(10)]
             + ['STGNUM' + str(i) for i in range(2, 8)])
HUD_TAB_ENGINE = 29          # bar, digits, %, arms, keys, the 13 face frames


def emit(wt):
    """hud.bin  = row-major pixels, halved horizontally (our byte = 2 DOOM px),
                  index 0 = transparent for everything except STBAR.
       hud.tab  = per lump: u24 vram, u8 w(bytes), u8 h, i8 left, i8 top."""
    import struct
    blob = bytearray()
    tab = bytearray()
    addr = HUD_VRAM_BASE
    for nm in HUD_LUMPS:
        pat = wt.get_patch(nm)
        if pat is None:
            print(f'  missing {nm}')
            continue
        w, h, cols = pat
        left, top = wt.patch_offset(nm)
        hw = (w + 1) // 2
        img = bytearray(hw * h)                       # 0 = transparent
        for cx in range(0, w, 2):                     # keep every second column
            for (td, pix) in cols[cx]:
                for k, c in enumerate(pix):
                    if 0 <= td + k < h:
                        img[(td + k) * hw + cx // 2] = c
        blob += img
        tab += struct.pack('<HBBBbb', addr & 0xFFFF, (addr >> 16) & 0xFF,
                           hw, h, left // 2, top)
        addr += len(img)
    out = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'hud')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'hud.bin'), 'wb').write(blob)
    open(os.path.join(out, 'hud.tab'), 'wb').write(tab[:HUD_TAB_ENGINE * 7])
    print(f'hud.bin {len(blob)} B (VRAM ${HUD_VRAM_BASE:06X}..${addr:06X}), '
          f'hud.tab {len(tab)} B ({len(tab)//7} lumps) -> {out}')


def main():
    from PIL import Image
    wad = Wad(DEFAULT_WAD)
    wt = WadTextures(wad)
    pal = wt.playpal
    img = Image.new('RGB', (320, 32), (0, 0, 0))
    full = Image.new('RGB', (320, 200), (0, 0, 0))
    px = full.load()

    draw_patch(px, wt, 'STBAR', 0, ST_Y, pal)            # background
    draw_num(px, wt, 50, ST_AMMOX, ST_AMMOY, 'STTNUM', pal)      # ammo
    draw_num(px, wt, 100, ST_HEALTHX, ST_HEALTHY, 'STTNUM', pal)  # health %
    draw_patch(px, wt, 'STTPRCNT', ST_HEALTHX, ST_HEALTHY, pal)
    draw_num(px, wt, 0, ST_ARMORX, ST_ARMORY, 'STTNUM', pal)      # armour %
    draw_patch(px, wt, 'STTPRCNT', ST_ARMORX, ST_ARMORY, pal)
    draw_patch(px, wt, 'STARMS', 104, ST_Y, pal)                  # arms box
    for i in range(6):                                            # weapons 2..7
        x = ST_ARMSX + (i % 3) * ST_ARMSXSPACE
        y = ST_ARMSY + (i // 3) * ST_ARMSYSPACE
        have = i in (0, 1)                                        # pistol + shotgun
        draw_patch(px, wt, ('STYSNUM' if have else 'STGNUM') + str(i + 2), x, y, pal)
    draw_patch(px, wt, 'STFST01', ST_FACESX, ST_FACESY, pal)      # face, straight on
    for i, (kx, ky) in enumerate(((ST_KEY0X, ST_KEY0Y), (ST_KEY1X, ST_KEY1Y),
                                  (ST_KEY2X, ST_KEY2Y))):
        draw_patch(px, wt, f'STKEYS{i}', kx, ky, pal)
    for i, val in enumerate((50, 0, 0, 0)):                       # ammo counts
        draw_num(px, wt, val, ST_AMMO0X, ST_AMMO0Y + i * ST_AMMOSPACE, 'STYSNUM', pal)
    for i, val in enumerate((200, 50, 50, 300)):                  # max ammo
        draw_num(px, wt, val, ST_MAXAMMO0X, ST_AMMO0Y + i * ST_AMMOSPACE,
                 'STYSNUM', pal)

    # The two PNGs are a HUMAN aid -- nothing on the ATR reads them and the build
    # does not need them, so they are OFF by default now: every build rewrote
    # them, which made tools/ look newer than the packed assets and tripped
    # build_atr.ps1's stamp into a full 27-level re-pack (~2.5 min instead of 5 s).
    # Ask for them with:  python tools/pack_hud.py --preview
    if '--preview' in sys.argv:
        img = full.crop((0, ST_Y, 320, 200))
        os.makedirs(OUT, exist_ok=True)
        img.resize((640, 64), Image.NEAREST).save(os.path.join(OUT, 'stbar_320.png'))
        # what the Atari framebuffer holds: 160 bytes wide (every second DOOM pixel),
        # shown again at 2x horizontally because one byte covers two hardware pixels
        half = img.resize((160, 32), Image.NEAREST)
        half.resize((640, 128), Image.NEAREST).save(os.path.join(OUT, 'stbar_160.png'))
        print(f'wrote {OUT}/stbar_320.png and stbar_160.png')
    emit(wt)


if __name__ == '__main__':
    main()
