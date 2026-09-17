#!/usr/bin/env python3
"""DOOM status bar (STBAR & co) straight out of the WAD -- extraction + preview.

FULL WIDTH since 2026-09-16: one byte per DOOM pixel, 320 across, no adaptation
at all. The 3D view is still LR (160 bytes a row, one byte = two hardware
pixels), but VBXE picks the overlay mode per XDL ENTRY, so the bar's 40 scanlines
run in SR -- the same mode the title picture has always used -- while the view
above them stays LR (xdl.asm; alt-src vbxe.cpp kOvModeTable). The bar therefore
has twice the horizontal samples it used to: the halving that used to happen
here is what made STBAR's one-pixel bevels and the tiny AMMO/HEALTH/ARMOR
labels mush.

  python pack_hud.py --preview  -> _pomocne/preview/stbar_320.png
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


import pack_menu                # ...for the VRAM bases: the strips, the bar
                               # graphics and the intermission are three
                               # neighbours in one bank and pack_menu owns them

HUD_VRAM_BASE = pack_menu.HUD_VRAM_BASE
                               # $04A000, six chunks (2026-09-16). It was
                               # $07D000, three chunks to the top of VRAM, and
                               # full -- doubling the width needed six. The
                               # space is what packing the HU strips to their
                               # own width gave back (pack_menu _hu_strips);
                               # $07D000 is the SR bar's FRAMEBUFFER now
                               # (VRAM_BAR320, memory_map.inc).
# What the engine needs to draw: the bar plus every glyph the status widgets use.
# Order matters: the engine indexes this table (0 = STBAR, 1..10 = digits,
# 11 = '%'). The rest of the widgets (arms, keys, face, small yellow digits)
# follow and get drawn once there is code for them.
# STBAR IS NOT IN THE TABLE ANY MORE (2026-09-16). hud.tab's row holds the width
# in ONE byte, and the bar is 320 wide now -- but it was never blitted through
# that row anyway: the full repaint and hud_facefix's cell restore both build
# their own BCB (a sub-rectangle, which the row format cannot express). So it
# rides at the END of the blob, blob-only like the small digits, and reaches the
# engine as HUDV_STBAR. Everything else is <= 40 wide; the packer checks.
HUD_LUMPS = ([f'STTNUM{i}' for i in range(10)] + ['STTPRCNT', 'STARMS']
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
             # 29 GOD, 30 DEAD (2026-09-11). st_stuff.c:900 shows STFGOD0
             # for CF_GODMODE *or* pw_invulnerability -- the port has the
             # second, so the face was missing on every invulnerability
             # sphere. STFDEAD0 did NOT fit: the region is 12 KB to the
             # VRAM top ($07D000) and two more faces ran 348 B past it,
             # into FRAME_A. Nothing guards that, so it is checked here.
             + ['STFGOD0']                                    # 29
             + [f'STYSNUM{i}' for i in range(10)]
             + ['STGNUM' + str(i) for i in range(2, 8)]
             # 2026-08-28: the FPS readout shows 6,25 and needs a separator.
             # STCFN044 is hu_stuff.c's own comma (the HU_FONTSTART + ',' slot),
             # so the readout is drawn in DOOM's font and not in something
             # invented here. APPENDED: every index above is baked into
             # memory_map.inc's HUD_* equs.
             + ['STCFN044']
             + ['STBAR'])                                     # blob-only
HUD_TAB_ENGINE = 29          # digits, %, arms, keys, the 14 face frames
# ...and the lumps that are NOT drawn on the bar. The small yellow digits, the
# grey ARMS digits and the comma only ever go down in the 3D VIEW -- the FPS
# readout (fps.asm) is the one thing that draws them -- and the view is still
# LR, 160 bytes a row, one byte per TWO DOOM pixels. So they keep the halving
# the bar just lost; packed at full width they came out twice as wide on screen
# (2026-09-16, "ked stlacim F, tak horny font je tiez nejaky vacsi").
VIEW_LUMPS = frozenset([f'STYSNUM{i}' for i in range(10)]
                       + ['STGNUM%d' % i for i in range(2, 8)]
                       + ['STCFN044'])


def emit(wt):
    """hud.bin  = row-major pixels at DOOM's own width (one byte per pixel),
                  index 0 = transparent for everything except STBAR.
       hud.tab  = per lump: u16 vram, u8 w, u8 h, i8 left, i8 top (the u24's
                  high byte is HUD_TAB_HI, one constant for the table).
       w and left are in DOOM pixels now, not in halved bytes: the bar is an SR
       surface, so a byte IS a pixel there (bar_blit, hud.asm)."""
    import struct
    blob = bytearray()
    meta = {}
    addr = HUD_VRAM_BASE
    for nm in HUD_LUMPS:
        pat = wt.get_patch(nm)
        if pat is None:
            print(f'  missing {nm}')
            continue
        w, h, cols = pat
        left, top = wt.patch_offset(nm)
        step = 2 if nm in VIEW_LUMPS else 1           # see VIEW_LUMPS: the view
        bw = (w + step - 1) // step                   #   is still 160 wide
        img = bytearray(bw * h)                       # 0 = transparent
        for cx in range(0, w, step):                  # the BAR keeps every column
            for (td, pix) in cols[cx]:
                for k, c in enumerate(pix):
                    if 0 <= td + k < h:
                        img[(td + k) * bw + cx // step] = c
        blob += img
        meta[nm] = (addr, bw, h, left // step, top)
        addr += len(img)
    out = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'hud')
    os.makedirs(out, exist_ok=True)
    # THE REGION ENDS AT THE INTERMISSION and nothing downstream checks it: the
    # blob would simply paint over WI's pixels and the fault would show up
    # between levels, a long way from here. Two extra face frames (STFGOD0 +
    # STFDEAD0, 2026-09-11) once ran 348 B past the old ceiling and the build
    # still said OK, which is why this assert exists.
    assert HUD_VRAM_BASE + len(blob) <= pack_menu.WI_VRAM_BASE, (
        'hud.bin is %d B: $%06X..$%06X runs into the intermission at $%06X '
        '(tools/pack_wi.py)' % (len(blob), HUD_VRAM_BASE,
                                HUD_VRAM_BASE + len(blob),
                                pack_menu.WI_VRAM_BASE))
    open(os.path.join(out, 'hud.bin'), 'wb').write(blob)
    # SIX bytes a row on disk, not seven (2026-08-30). Every lump lives in the
    # same 64 KB VBXE bank, so the u24's high byte is one constant for the whole
    # table -- it goes to hud_syms.inc as HUD_TAB_HI and hud_entry puts it back.
    # That is what let HUD_TAB leave base RAM: 29 x 7 = 203 B did not fit what
    # is left of bank01.asm's staged block, 29 x 6 = 174 B does.
    tab = bytearray()
    banks = set()
    for nm in HUD_LUMPS[:HUD_TAB_ENGINE]:
        a, w, h, left, top = meta[nm]
        assert w < 256, (
            '%s is %d wide and hud.tab holds the width in ONE byte -- a lump '
            'that big has to leave the table and reach the engine as a '
            'hud_syms.inc equ, the way STBAR does' % (nm, w))
        banks.add((a >> 16) & 0xFF)
        tab += struct.pack('<HBBbb', a & 0xFFFF, w, h, left, top)
    assert len(banks) == 1, (
        'HUD_TAB spans VBXE banks %s -- hud_entry assumes one, and the row '
        'would have to carry the bank byte again' % sorted(banks))
    open(os.path.join(out, 'hud.tab'), 'wb').write(bytes(tab))
    # hud_syms.inc -- the VRAM address of the lumps that are in the BLOB but not
    # in the TABLE: the small digits, the comma, and STBAR (too wide for the
    # row's width byte, and blitted from a hand-built BCB anyway). HUD_TAB is
    # capped at HUD_TAB_ENGINE entries because HUDTAB_BASE..END is one page, so
    # anything past it has to be addressed directly. The FPS readout builds its
    # own 7-byte record from these (hud.asm fps_dig).
    syms = os.path.join(os.path.dirname(_HERE), 'hud_syms.inc')
    EQ = {'STYSNUM0': 'HUDV_YS0', 'STCFN044': 'HUDV_COMMA', 'STBAR': 'HUDV_STBAR'}
    with open(syms, 'w') as f:
        f.write('; AUTO-GENERATED by tools/pack_hud.py -- do not edit.\n')
        f.write('; VRAM addresses of HUD lumps that HUD_TAB does not reach\n')
        f.write('; (it stops at HUD_TAB_ENGINE = %d; see there).\n' % HUD_TAB_ENGINE)
        f.write('HUD_TAB_HI   equ $%02X\n' % banks.pop())
        for nm, eq in EQ.items():
            a, w, h, _l, _t = meta[nm]
            f.write('%-12s equ $%06X   ; %s %dx%d\n' % (eq, a, nm, w, h))
        _a, ysw, ysh, _l, _t = meta['STYSNUM0']
        f.write('HUDV_YSSTEP  equ %d          ; bytes per small digit (they are\n'
                % (ysw * ysh))
        f.write('                             ;   all one size, so 0..9 is a stride)\n')
        f.write('HUDV_YSW     equ %d\n' % ysw)
        f.write('HUDV_YSH     equ %d\n' % ysh)
        _a, cw, ch, _l, ct = meta['STCFN044']
        f.write('HUDV_COMMAW  equ %d\n' % cw)
        f.write('HUDV_COMMAH  equ %d\n' % ch)
        f.write('HUDV_COMMAT  equ %d          ; the comma sits BELOW the digit top\n'
                % ct)
        _a, bw, bh, _l, _t = meta['STBAR']
        f.write('HUDV_BARW    equ %d        ; the SR bar: one byte per DOOM pixel\n'
                % bw)
        f.write('HUDV_BARH    equ %d\n' % bh)


    print(f'hud.bin {len(blob)} B (VRAM ${HUD_VRAM_BASE:06X}..${addr:06X}), '
          f'hud.tab {len(tab)} B ({HUD_TAB_ENGINE} of {len(meta)} lumps -- the '
          f'rest are blob-only, see hud_syms.inc) -> {out}')


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
        # ONE picture now: what DOOM draws and what the Atari holds are the same
        # 320 bytes a row. The old stbar_160.png -- the halved copy -- is what
        # the SR bar got rid of, so there is nothing left for it to show.
        img.resize((640, 64), Image.NEAREST).save(os.path.join(OUT, 'stbar_320.png'))
        print(f'wrote {OUT}/stbar_320.png')
    emit(wt)


if __name__ == '__main__':
    main()
