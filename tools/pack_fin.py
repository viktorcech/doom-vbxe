#!/usr/bin/env python3
"""The END-OF-EPISODE FINALE (f_finale.c) -> fin.bin / fin_syms.inc.

f_finale.c, episodes 1-3. When an ExM8 is finished DOOM does NOT show the
intermission at all -- G_DoCompleted sees `gamemap == 8` and hands straight to
ga_victory / F_StartFinale, which types the episode's story text over a tiled
floor and then shows a full-screen picture:

    ep  text     flat      stage 1 (F_Drawer)
    1   E1TEXT   FLOOR4_8  HELP2      (CREDIT only in retail; this IWAD has no
                                       E4M1, so it is registered v1.9 -> HELP2)
    2   E2TEXT   SFLR6_1   VICTORY2
    3   E3TEXT   MFLR8_4   F_BunnyScroll -- PFUB1 scrolling into PFUB2, then
                                       END0..END6 spelling "THE END"

Everything here is halved horizontally, like every other graphic in this port
(160 across where DOOM draws 320). Vertically nothing changes: SCREEN_HEIGHT is
DOOM's own 200, so a full-screen picture is exactly 160 x 200 = 32,000 B -- the
same shape pack_menu.py already gives TITLEPIC and the READ THIS! pages.

Four things ship:

  THE FLATS are ONE 64x64 flat each, not a rendered page. F_TextWrite tiles them
  (`memcpy(dest, src+((y&63)<<6), 64)` per row) and the VBXE blitter tiles just
  as happily -- 5 across by 4 down, at 2 KB of VRAM instead of 32.

  THE FONT is the real thing. Everything else this port draws is a
  pre-rasterised patch (pack_menu.py's HU strips, pack_wi.py's labels), which
  works because those line sets are CLOSED. A typewriter is not closed: it needs
  glyph N of a string at tic N. So hu_font is packed as a FIXED-STRIDE cell
  block -- STCFN033..STCFN095, '!' through '_' -- and the engine gets a glyph's
  address with a shift instead of a table lookup. Widths still vary, so a
  63-byte advance table rides along in fin_syms.inc.

  THE TEXTS are E1TEXT/E2TEXT/E3TEXT from d_englsh.h, upper-cased the way
  F_TextWrite upper-cases them, newlines kept as $0A, NUL-terminated. They stay
  in VRAM and are read a character at a time through the MEMAC window: 1.6 KB of
  6502 RAM is 1.6 KB this port does not have.

  THE PICTURES are halved 160x200 pages, one section each, plus the seven END
  patches. Every section is CHUNK-ALIGNED so the engine can stream any one of
  them on its own into a VBXE bank without reading the others -- the bunny
  scroll is the only moment that needs two pages at once.

  python tools/pack_fin.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                              # noqa: E402
from wadtex import WadTextures                                   # noqa: E402

ROOT = os.path.dirname(_HERE)
CHUNK = 4096

SCREEN_W = 160                       # memory_map.inc SCREEN_WIDTH (halved)
SCREEN_H = 200                       # ...and SCREEN_HEIGHT, DOOM's own
FONT_FIRST, FONT_LAST = 33, 95       # hu_stuff.h HU_FONTSTART..HU_FONTEND
FONT_H = 8                           # every STCFN glyph is 8 rows
TEXTSPEED = 3                        # f_finale.c:56, tics per character
TEXTWAIT = 250                       # f_finale.c:57, tics to hold the full page
CX0, CY0, LINEH, SPACEW = 10, 10, 11, 4       # F_TextWrite's own numbers (x
                                              #   halved on the way out)

# --- F_BunnyScroll's clock (f_finale.c:644-693), all in DOOM tics ------------
BUNNY_START = 230                    # scrolled = 320 - (finalecount-230)/2
BUNNY_END0 = 1130                    # ...before this, no letters at all
BUNNY_STAGE0 = 1180                  # END0 holds from 1130 to here
BUNNY_STEP = 5                       # then one more letter every 5 tics
BUNNY_LAST = 6                       # END0..END6

E1TEXT = (
    "Once you beat the big badasses and\n"
    "clean out the moon base you're supposed\n"
    "to win, aren't you? Aren't you? Where's\n"
    "your fat reward and ticket home? What\n"
    "the hell is this? It's not supposed to\n"
    "end this way!\n"
    "\n"
    "It stinks like rotten meat, but looks\n"
    "like the lost Deimos base.  Looks like\n"
    "you're stuck on The Shores of Hell.\n"
    "The only way out is through.\n"
    "\n"
    "To continue the DOOM experience, play\n"
    "The Shores of Hell and its amazing\n"
    "sequel, Inferno!\n")

E2TEXT = (
    "You've done it! The hideous cyber-\n"
    "demon lord that ruled the lost Deimos\n"
    "moon base has been slain and you\n"
    "are triumphant! But ... where are\n"
    "you? You clamber to the edge of the\n"
    "moon and look down to see the awful\n"
    "truth.\n"
    "\n"
    "Deimos floats above Hell itself!\n"
    "You've never heard of anyone escaping\n"
    "from Hell, but you'll make the bastards\n"
    "sorry they ever heard of you! Quickly,\n"
    "you rappel down to  the surface of\n"
    "Hell.\n"
    "\n"
    "Now, it's on to the final chapter of\n"
    "DOOM! -- Inferno.")

E3TEXT = (
    "The loathsome spiderdemon that\n"
    "masterminded the invasion of the moon\n"
    "bases and caused so much death has had\n"
    "its ass kicked for all time.\n"
    "\n"
    "A hidden doorway opens and you enter.\n"
    "You've proven too tough for Hell to\n"
    "contain, and now Hell at last plays\n"
    "fair -- for you emerge from the door\n"
    "to see the green fields of Earth!\n"
    "Home at last.\n"
    "\n"
    "You wonder what's been happening on\n"
    "Earth while you were battling evil\n"
    "unleashed. It's good that no Hell-\n"
    "spawn could have come through that\n"
    "door with you ...")

# episode -> (flat lump, text). f_finale.c:116-137.
EPISODES = ((1, 'FLOOR4_8', E1TEXT),
            (2, 'SFLR6_1', E2TEXT),
            (3, 'MFLR8_4', E3TEXT))

# The stage-1 art. Episode 1 takes HELP2 and not CREDIT because CREDIT is the
# `gamemode == retail` branch (f_finale.c:715) and this IWAD has no E4M1.
END_LUMPS = tuple('END%d' % i for i in range(BUNNY_LAST + 1))


def halve_patch(wt, nm, pad_h=0):
    """A patch -> (bytes, w in bytes, h), halved horizontally like every other
       graphic in this port, with the patch's own top offset folded in so the
       image sits where V_DrawPatch puts it. Column-major source, row-major out.
       Byte 0 is transparent (the port has no mask): every patch here is either
       full-screen or drawn over one, and DOOM's own art has no holes in it."""
    pat = wt.get_patch(nm)
    if pat is None:
        return None
    w, h, cols = pat
    _left, top = wt.patch_offset(nm)
    hw = (w + 1) // 2
    rows = max(pad_h, h)
    img = bytearray(hw * rows)
    for cx in range(0, w, 2):
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                y = td + k - top
                if 0 <= y < rows:
                    img[y * hw + cx // 2] = c
    return bytes(img), hw, rows


def full_page(wt, nm):
    """A 320x200 lump -> the port's 160x200 page, exactly TITLEPIC's shape."""
    g = halve_patch(wt, nm)
    if g is None:
        sys.exit('  ERROR: %s is not in the WAD' % nm)
    img, hw, rows = g
    if hw != SCREEN_W or rows != SCREEN_H:
        sys.exit('  ERROR: %s is %dx%d halved, expected %dx%d'
                 % (nm, hw, rows, SCREEN_W, SCREEN_H))
    return img


def _pad(blob):
    """Round the blob up to a chunk boundary and return the new length."""
    short = (-len(blob)) % CHUNK
    blob += bytes(short)
    return len(blob)


def emit():
    wt = WadTextures(Wad(DEFAULT_WAD))

    # ---- the font: measure first, so the cell is as tight as it can be -----
    glyphs = []
    for code in range(FONT_FIRST, FONT_LAST + 1):
        g = halve_patch(wt, 'STCFN%.3d' % code, pad_h=FONT_H)
        if g is None:                              # not every code is in the WAD
            glyphs.append((b'', 0))                #   ('!'..'_' all are, but a
            continue                               #    converted WAD may differ)
        img, hw, rows = g
        if rows > FONT_H:
            sys.exit('  ERROR: STCFN%.3d is %d rows, the cell is %d'
                     % (code, rows, FONT_H))
        glyphs.append((img, hw))
    # A POWER-OF-TWO cell, not the measured maximum. The widest halved glyph is
    # 5 bytes, so 8 wastes 3 per row -- and buys the engine a glyph address of
    # `(c - '!') * 64`, which is three shifts instead of a multiply by 40.
    cell = 1
    while cell < max(w for _i, w in glyphs):
        cell *= 2
    font = bytearray()
    for img, hw in glyphs:                         # one fixed-stride cell each,
        for y in range(FONT_H):                    #   so the address is a shift
            row = img[y * hw:(y + 1) * hw] if hw else b''
            font += row + bytes(cell - len(row))

    # ---- SECTION 1: the small stuff -- font, the three flats, the three -----
    #      texts. All of it together is under one chunk pair, and the engine
    #      keeps it resident for the whole finale.
    blob = bytearray(font)
    font_off = 0
    flat_off, text_off, textlen = [], [], []
    for _ep, flatname, _txt in EPISODES:
        flat = wt.get_flat(flatname)
        if flat is None:
            sys.exit('  ERROR: %s is not in the WAD' % flatname)
        flat_off.append(len(blob))
        for y in range(64):                        # halved: 32 bytes x 64 rows
            for x in range(0, 64, 2):
                blob.append(flat[y * 64 + x])
    for _ep, _flatname, txt in EPISODES:
        t = txt.upper().encode('latin-1') + b'\0'
        text_off.append(len(blob))
        textlen.append(len(t))
        blob += t
    data_len = len(blob)
    _pad(blob)
    data_chunks = len(blob) // CHUNK

    # ---- fin.bin ends here. THE PAGES GO IN A FILE OF THEIR OWN -------------
    # fin.bin rides menu.bin's boot stream (pack_menu.py appends it inside the
    # intermission's consecutive bank run), and that stream is written to VRAM
    # the moment the game boots. The four 32 KB pages must NOT be in it: 41
    # chunks of boot stream would walk straight through FRAME_C. They go to
    # finpic.bin, a stream of their own on the ATR, which the finale pulls into
    # the SPRITE ARENA on demand -- the same trick mn_readthis plays with the
    # HELP pages, and legal for the same reason: the arena holds the level's
    # sprites, and by the time a finale runs the level is over.
    pics = bytearray()
    pic_ch = {}
    for nm in ('HELP2', 'VICTORY2', 'PFUB1', 'PFUB2'):
        pic_ch[nm] = len(pics) // CHUNK
        pics += full_page(wt, nm)
        _pad(pics)

    # ---- the END letters: seven small patches, one chunk-aligned section ----
    end_ch = len(pics) // CHUNK
    ends = []
    base = len(pics)
    for nm in END_LUMPS:
        g = halve_patch(wt, nm)
        if g is None:
            sys.exit('  ERROR: %s is not in the WAD' % nm)
        img, hw, rows = g
        ends.append((len(pics) - base, hw, rows))
        pics += img
    _pad(pics)

    out = os.path.join(ROOT, 'build', 'assets', 'fin')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'fin.bin'), 'wb').write(blob)
    open(os.path.join(out, 'finpic.bin'), 'wb').write(pics)
    emit_syms(cell, [w for _i, w in glyphs], font_off, flat_off, text_off,
              textlen, pic_ch, end_ch, ends, data_chunks,
              len(pics) // CHUNK, data_len)
    print('fin.bin %d B (%d chunks, boot stream): font %d + 3 flats + 3 texts'
          % (len(blob), data_chunks, len(font)))
    print('finpic.bin %d B (%d chunks, on demand): 4 pages x %d B + %d END '
          'patches -> %s'
          % (len(pics), len(pics) // CHUNK, SCREEN_W * SCREEN_H, len(ends), out))


def emit_syms(cell, widths, font_off, flat_off, text_off, textlen, pic_ch,
              end_ch, ends, chunks, pic_chunks, data_len):
    p = os.path.join(ROOT, 'fin_syms.inc')
    with open(p, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_fin.py -- DO NOT EDIT.\n')
        w('; f_finale.c geometry. x values are HALVED (the port draws 160\n')
        w('; wide where DOOM draws 320); y values are DOOM\'s own.\n')
        w('; Every FIN_*_OFF is a byte offset INSIDE fin.bin; the page and END\n')
        w('; sections start on a 4 KB chunk so each streams on its own.\n')
        w('FIN_CHUNKS   equ %d      ; fin.bin: rides menu.bin\'s boot stream\n'
          % chunks)
        w('FIN_PICCHUNKS equ %d    ; finpic.bin: its own ATR stream (FIN_SEC1),\n'
          % pic_chunks)
        w('                        ;   pulled into the sprite arena on demand\n')
        w('FIN_DATA_LEN equ %d   ; font + flats + texts, the resident section\n'
          % data_len)
        w('FIN_FONT_OFF equ %d\n' % font_off)
        w('FIN_CELL     equ %d      ; bytes per glyph ROW\n' % cell)
        w('FIN_GLYPH    equ %d     ; ...and per glyph (FIN_CELL * %d rows)\n'
          % (cell * FONT_H, FONT_H))
        w('FIN_FONT_H   equ %d\n' % FONT_H)
        w('FIN_FIRST    equ %d      ; HU_FONTSTART, \'!\'\n' % FONT_FIRST)
        w('FIN_LAST     equ %d      ; HU_FONTEND, \'_\'\n' % FONT_LAST)
        w('FIN_TILE_W   equ 32     ; the flats, halved from 64x64\n')
        w('FIN_TILE_H   equ 64\n')
        w('FIN_TILE_X   equ %d      ; tiles across a %d-byte row\n'
          % (SCREEN_W // 32, SCREEN_W))
        w(';   --- per EPISODE (1-3): flat, text, text length ---\n')
        for i, (ep, flatname, _t) in enumerate(EPISODES):
            w('FIN_FLAT%d    equ %-6d ; %s\n' % (ep, flat_off[i], flatname))
        for i, (ep, _f, _t) in enumerate(EPISODES):
            w('FIN_TEXT%d    equ %-6d ; %d B incl. the NUL\n'
              % (ep, text_off[i], textlen[i]))
        for i, (ep, _f, _t) in enumerate(EPISODES):
            w('FIN_TLEN%d    equ %d\n' % (ep, textlen[i] - 1))
        w(';   --- the stage-1 pages: %d x %d = %d B = %d chunks each. The\n'
          % (SCREEN_W, SCREEN_H, SCREEN_W * SCREEN_H,
             (SCREEN_W * SCREEN_H + CHUNK - 1) // CHUNK))
        w(';       numbers are CHUNK indices inside finpic.bin, so a page\'s\n')
        w(';       first sector is FIN_SEC1 + index*32 (atr_layout.inc).\n')
        w('FIN_PAGE_LEN equ %d\n' % (SCREEN_W * SCREEN_H))
        w('FIN_PAGE_CH  equ %d      ; chunks one page takes\n'
          % ((SCREEN_W * SCREEN_H + CHUNK - 1) // CHUNK))
        w('FIN_HELP2    equ %-6d ; episode 1 (registered; retail uses CREDIT)\n'
          % pic_ch['HELP2'])
        w('FIN_VICTORY2 equ %-6d ; episode 2\n' % pic_ch['VICTORY2'])
        w('FIN_PFUB1    equ %-6d ; episode 3, the page the scroll STARTS on\n'
          % pic_ch['PFUB1'])
        w('FIN_PFUB2    equ %-6d ; ...and the one it scrolls onto\n'
          % pic_ch['PFUB2'])
        w(';   --- F_BunnyScroll (f_finale.c:644), tics and PORT pixels ---\n')
        w('FIN_BUN_T0   equ %d    ; scroll starts; x = %d - (t-%d)/4 halved\n'
          % (BUNNY_START, SCREEN_W, BUNNY_START))
        w('FIN_BUN_END0 equ %d   ; END0 appears\n' % BUNNY_END0)
        w('FIN_BUN_ST0  equ %d   ; ...and the letters start marching\n'
          % BUNNY_STAGE0)
        w('FIN_BUN_STEP equ %d      ; one more letter every this many tics\n'
          % BUNNY_STEP)
        w('FIN_BUN_LAST equ %d      ; END0..END6\n' % BUNNY_LAST)
        w('FIN_END_CH   equ %-6d ; the END section, chunk index in finpic.bin\n'
          % end_ch)
        w('FIN_END_N    equ %d\n' % len(ends))
        w('; END patch table: offset INSIDE the END section, width B, height\n')
        w('fin_end_lo\n        dta %s\n'
          % ','.join('<%d' % o for o, _w, _h in ends))
        w('fin_end_hi\n        dta %s\n'
          % ','.join('>%d' % o for o, _w, _h in ends))
        w('fin_end_w\n        dta %s\n'
          % ','.join(str(x) for _o, x, _h in ends))
        w('fin_end_h\n        dta %s\n'
          % ','.join(str(x) for _o, _w, x in ends))
        # V_DrawPatch((SCREENWIDTH-13*8)/2, (SCREENHEIGHT-8*8)/2) -- DOOM's own
        # centring for the END letters, x halved with the rest of the port.
        w('FIN_END_X    equ %d     ; (320-13*8)/2 halved\n'
          % (((320 - 13 * 8) // 2) // 2))
        w('FIN_END_Y    equ %d     ; (200-8*8)/2\n' % ((200 - 8 * 8) // 2))
        w(';   --- F_TextWrite (f_finale.c:261) ---\n')
        w('FIN_CX0      equ %d      ; F_TextWrite cx = %d, halved\n'
          % (CX0 // 2, CX0))
        w('FIN_CY0      equ %d\n' % CY0)
        w('FIN_LINEH    equ %d\n' % LINEH)
        w('FIN_SPACEW   equ %d      ; the "not a glyph" advance, halved\n'
          % (SPACEW // 2))
        w('FIN_SPEED    equ %d      ; TEXTSPEED, tics per character\n' % TEXTSPEED)
        w('FIN_WAIT     equ %d    ; TEXTWAIT, tics to hold the finished page\n'
          % TEXTWAIT)
        w(';   --- hu_font advance widths, \'!\'..\'_\' (halved) ---\n')
        w('fin_fw\n')
        for i in range(0, len(widths), 16):
            w('        dta %s\n' % ','.join(str(v) for v in widths[i:i + 16]))
    print('fin_syms.inc -> %s' % p)


if __name__ == '__main__':
    emit()
