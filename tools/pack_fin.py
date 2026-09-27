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

NOTHING here is halved (2026-09-24): the text stage and stage 1 are both VBXE
SR screens at DOOM's own 320x200, like the title.

Four things ship:

  THE FLATS are ONE 64x64 flat each, not a rendered page. F_TextWrite tiles them
  (`memcpy(dest, src+((y&63)<<6), 64)` per row) and the VBXE blitter tiles just
  as happily -- 5 across by 4 down.

  THE FONT is the real thing. Everything else this port draws is a
  pre-rasterised patch (pack_menu.py's HU strips, pack_wi.py's labels), which
  works because those line sets are CLOSED. A typewriter is not closed: it needs
  glyph N of a string at tic N. So hu_font is packed as a FIXED-STRIDE cell
  block -- STCFN033..STCFN095, '!' through '_' -- and the engine gets a glyph's
  address with a shift instead of a table lookup. Widths still vary, so a
  63-byte advance table rides along in fin_syms.inc. Font and flat ride each
  episode's finpic.bin section, behind its art.

  THE TEXTS are E1TEXT/E2TEXT/E3TEXT from d_englsh.h, upper-cased the way
  F_TextWrite upper-cases them, newlines kept as $0A, NUL-terminated. They stay
  in VRAM and are read a character at a time through the MEMAC window: 1.6 KB of
  6502 RAM is 1.6 KB this port does not have.

  THE PICTURES are NOT halved (2026-09-24): stage 1 is shown at DOOM's own
  320x200 in VBXE SR mode, like the title and the READ THIS! pages. HELP2 and
  VICTORY2 are one 16-chunk page each with its SR list in the padding. The
  bunny pair is ONE 640x200 surface (PFUB2 | PFUB1, 32 chunks, its list at
  +128000 showing scrolled = 320) -- the engine scrolls it by adding to the
  list's addresses, no blit at all -- then the seven END patches, full width.
  Every episode's section is CHUNK-ALIGNED so it streams on its own into
  FIN_ARENA.

  python tools/pack_fin.py
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                              # noqa: E402
from wadtex import WadTextures                                   # noqa: E402
import pack_menu                                                 # noqa: E402

ROOT = os.path.dirname(_HERE)
CHUNK = 4096

SR_W, SR_H = pack_menu.SR_W, pack_menu.SR_H   # stage 1: 320x200 SR
BUN_W = 2 * SR_W                     # the bunny pair, PFUB2 | PFUB1
FIN_ARENA_VRAM = 0x018000            # memory_map.inc FIN_ARENA (f_finale checks)
ARENA_TOP = 0x03D000                 # ...ARENA_SPR_TOP: the episode picker above
PAGE_XDL = pack_menu.SR_XDL_OFF      # a page's list, inside it
BUN_XDL = BUN_W * SR_H               # = $1F400, page-aligned
TXT_SR = 0x060000                    # the TEXT stage's SR surface: VRAM the
                                     #   boot stream leaves free below WIPE_START
                                     #   (f_finale.asm checks), untouched by the
                                     #   ESC menu -- so ESC needs no save
TXT_OFF0 = 0x300                     # fin.bin: the texts, behind the list

FONT_FIRST, FONT_LAST = 33, 95       # hu_stuff.h HU_FONTSTART..HU_FONTEND
FONT_H = 8                           # every STCFN glyph is 8 rows
TEXTSPEED = 3                        # f_finale.c:56, tics per character
TEXTWAIT = 250                       # f_finale.c:57, tics to hold the full page
CX0, CY0, LINEH, SPACEW = 10, 10, 11, 4       # F_TextWrite's own numbers

# --- F_BunnyScroll's clock (f_finale.c:644-693), all in DOOM tics ------------
BUNNY_START = 230                    # scrolled = 320 - (finalecount-230)/2
BUNNY_END0 = 1130                    # ...before this, no letters at all
BUNNY_STAGE0 = 1180                  # END0 holds from 1130 to here
BUNNY_STEP = 5                       # then one more letter every 5 tics
BUNNY_LAST = 6                       # END0..END6
END_X = (320 - 13 * 8) // 2          # V_DrawPatch((SCREENWIDTH-13*8)/2,
END_Y = (200 - 8 * 8) // 2           #   (SCREENHEIGHT-8*8)/2) -- DOOM's own

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


def halve_patch(wt, nm, pad_h=0, step=2):
    """A patch -> (bytes, w in bytes, h), halved horizontally (step 2, the
       160-wide text stage) or not (step 1, the SR stage 1), with the patch's
       own top offset folded in so the image sits where V_DrawPatch puts it.
       Column-major source, row-major out. Byte 0 is transparent (the port has
       no mask): every patch here is either full-screen or drawn over one, and
       DOOM's own art has no holes in it."""
    pat = wt.get_patch(nm)
    if pat is None:
        return None
    w, h, cols = pat
    _left, top = wt.patch_offset(nm)
    hw = (w + step - 1) // step
    rows = max(pad_h, h)
    img = bytearray(hw * rows)
    for cx in range(0, w, step):
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                y = td + k - top
                if 0 <= y < rows:
                    img[y * hw + cx // step] = c
    return bytes(img), hw, rows


def full_page(wt, nm):
    """A 320x200 lump at full width, row-major."""
    g = halve_patch(wt, nm, step=1)
    if g is None:
        sys.exit('  ERROR: %s is not in the WAD' % nm)
    img, w, rows = g
    if w != SR_W or rows != SR_H:
        sys.exit('  ERROR: %s is %dx%d, expected %dx%d'
                 % (nm, w, rows, SR_W, SR_H))
    return img


def _pad(blob):
    """Round the blob up to a chunk boundary and return the new length."""
    short = (-len(blob)) % CHUNK
    blob += bytes(short)
    return len(blob)


def emit():
    wt = WadTextures(Wad(DEFAULT_WAD))

    # ---- the font, FULL width: one fixed-stride cell per glyph -------------
    glyphs = []
    for code in range(FONT_FIRST, FONT_LAST + 1):
        g = halve_patch(wt, 'STCFN%.3d' % code, pad_h=FONT_H, step=1)
        if g is None:                              # not every code is in the WAD
            glyphs.append((b'', 0))                #   ('!'..'_' all are, but a
            continue                               #    converted WAD may differ)
        img, gw, rows = g
        if rows > FONT_H:
            sys.exit('  ERROR: STCFN%.3d is %d rows, the cell is %d'
                     % (code, rows, FONT_H))
        glyphs.append((img, gw))
    # A POWER-OF-TWO cell, not the measured maximum: the widest glyph ('@') is
    # 9 bytes, so 16 -- and a glyph's address is `(c - '!') * 128`, a shift.
    cell = 1
    while cell < max(w for _i, w in glyphs):
        cell *= 2
    font = bytearray()
    for img, gw in glyphs:
        for y in range(FONT_H):
            row = img[y * gw:(y + 1) * gw] if gw else b''
            font += row + bytes(cell - len(row))

    # ---- fin.bin, the boot stream's part: the TEXT stage's SR list (page 0,
    #      so xdl_to_r can blit it) and the three texts, read a byte at a time
    #      through the MEMAC window. Everything with pixels is in finpic.bin.
    blob = bytearray(pack_menu._sr_xdl(TXT_SR))
    blob += bytes(TXT_OFF0 - len(blob))
    text_off, textlen = [], []
    for _ep, _flatname, txt in EPISODES:
        t = txt.upper().encode('latin-1') + b'\0'
        text_off.append(len(blob))
        textlen.append(len(t))
        blob += t
    data_len = len(blob)
    _pad(blob)
    data_chunks = len(blob) // CHUNK

    # ---- finpic.bin: one section per EPISODE, each streamed whole into
    # FIN_ARENA by fin_load: its stage-1 art, then its text kit -- the font
    # and the episode's flat at full width, page-aligned behind the art (the
    # font is repeated per section: disk bytes, not VRAM). Sections start on a
    # chunk; inside one, nothing has to.
    pics = bytearray()
    secs = []                                     # (chunk, n, font_off, flat_off)
    end_info = None

    def kit(sec, flatname):
        flat = wt.get_flat(flatname)
        if flat is None:
            sys.exit('  ERROR: %s is not in the WAD' % flatname)
        sec += bytes(-len(sec) % 256)
        fo = len(sec)
        sec += font
        sec += bytes(-len(sec) % 256)
        lo = len(sec)
        sec += bytes(flat[:64 * 64])
        return fo, lo

    for ep, flatname, _txt in EPISODES:
        if ep < 3:                                # HELP2 / VICTORY2: a page
            sec = bytearray(full_page(wt, ('HELP2', 'VICTORY2')[ep - 1]))
            sec += pack_menu._sr_xdl(FIN_ARENA_VRAM)
        else:
            # THE BUNNY PAIR as one 640-wide surface: screen column x of
            # F_BunnyScroll is surface column x + scrolled, so the whole scroll
            # is the list's address plus `scrolled` (f_finale.asm fin_pan).
            p2, p1 = full_page(wt, 'PFUB2'), full_page(wt, 'PFUB1')
            sec = bytearray()
            for y in range(SR_H):
                sec += p2[y * SR_W:(y + 1) * SR_W] + p1[y * SR_W:(y + 1) * SR_W]
            sec += pack_menu._sr_xdl(FIN_ARENA_VRAM + SR_W, stride=BUN_W)
            sec += bytes(-len(sec) % 256)
            end_info = _ends(wt, sec)             # THE END, behind the list
        fo, lo = kit(sec, flatname)
        n = (len(sec) + CHUNK - 1) // CHUNK
        if FIN_ARENA_VRAM + n * CHUNK > ARENA_TOP:
            sys.exit('  ERROR: episode %d\'s finale is %d chunks and ends at '
                     '$%06X, past ARENA_SPR_TOP $%06X'
                     % (ep, n, FIN_ARENA_VRAM + n * CHUNK, ARENA_TOP))
        secs.append((len(pics) // CHUNK, n, fo, lo))
        pics += sec
        _pad(pics)

    out = os.path.join(ROOT, 'build', 'assets', 'fin')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'fin.bin'), 'wb').write(blob)
    open(os.path.join(out, 'finpic.bin'), 'wb').write(pics)
    emit_syms(cell, [w for _i, w in glyphs], text_off, textlen, secs, end_info,
              data_chunks, len(pics) // CHUNK, data_len)
    print('fin.bin %d B (%d chunks, boot stream): the text list + 3 texts'
          % (len(blob), data_chunks))
    print('finpic.bin %d B (%d chunks, on demand): per episode its stage-1 art'
          ' + a full-width font and flat -> %s' % (len(pics), len(pics) // CHUNK, out))


def _ends(wt, sec):
    """THE END letters into the bunny section, from its current end. END0..END6
    are the same "THE END" with one more bullet hole each, so END0 ships whole
    and every later one only as the RECTANGLE where it differs from the one
    before (~8.5 KB instead of 43): fin_endblit puts that rectangle's pristine
    PFUB2 back and stencils the crop over it. -> (arena offset, ends, box)"""
    grids = []
    for nm in END_LUMPS:
        g = halve_patch(wt, nm, step=1)
        if g is None:
            sys.exit('  ERROR: %s is not in the WAD' % nm)
        grids.append(g)
    rw = max(w for _i, w, _h in grids)
    rh = max(h for _i, _w, h in grids)
    if END_X + rw > SR_W or END_Y + rh > SR_H:
        sys.exit('  ERROR: an END patch runs off the 320x200 screen')
    full = []
    for img, w, h in grids:                       # all on one rw x rh grid
        f = bytearray(rw * rh)
        for y in range(h):
            f[y * rw:y * rw + w] = img[y * w:(y + 1) * w]
        full.append(f)
    base = len(sec)
    ends = []                                     # (data off, w, h, dx, dy)
    for n, f in enumerate(full):
        if n == 0:
            x0, y0, x1, y1 = 0, 0, grids[0][1], grids[0][2]
        else:
            diff = [(i % rw, i // rw) for i in range(rw * rh)
                    if f[i] != full[n - 1][i]]
            if not diff:
                sys.exit('  ERROR: %s is the same picture as the one before'
                         % END_LUMPS[n])
            x0, y0 = min(x for x, _y in diff), min(y for _x, y in diff)
            x1, y1 = max(x for x, _y in diff) + 1, max(y for _x, y in diff) + 1
        ends.append((len(sec) - base, x1 - x0, y1 - y0, x0, y0))
        for y in range(y0, y1):
            sec += f[y * rw + x0:y * rw + x1]
    return base, ends, (rw, rh)


def emit_syms(cell, widths, text_off, textlen, secs, end_info, chunks,
              pic_chunks, data_len):
    end_off, ends, ebox = end_info
    p = os.path.join(ROOT, 'fin_syms.inc')
    with open(p, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_fin.py -- DO NOT EDIT.\n')
        w('; f_finale.c geometry at DOOM\'s own 320x200: the text stage and\n')
        w('; stage 1 are both VBXE SR screens (f_finale.asm).\n')
        w('FIN_CHUNKS   equ %d      ; fin.bin: rides menu.bin\'s boot stream\n'
          % chunks)
        w('FIN_PICCHUNKS equ %d    ; finpic.bin: its own ATR stream (FIN_SEC1),\n'
          % pic_chunks)
        w('                        ;   one section per episode, into FIN_ARENA\n')
        w('FIN_DATA_LEN equ %d   ; the text list + the texts, resident\n' % data_len)
        w('FIN_TXSR     equ $%06X  ; the TEXT stage\'s SR surface (64000 B)\n' % TXT_SR)
        w('FIN_TXL_OFF  equ 0       ; ...its list, at fin.bin +0 (page-aligned)\n')
        w('FIN_CELL     equ %d     ; bytes per glyph ROW\n' % cell)
        w('FIN_GLYPH    equ %d    ; ...and per glyph (FIN_CELL * %d rows)\n'
          % (cell * FONT_H, FONT_H))
        w('FIN_FONT_H   equ %d\n' % FONT_H)
        w('FIN_FIRST    equ %d      ; HU_FONTSTART, \'!\'\n' % FONT_FIRST)
        w('FIN_LAST     equ %d      ; HU_FONTEND, \'_\'\n' % FONT_LAST)
        w('FIN_TILE_W   equ 64     ; the flats, 64x64 at full width\n')
        w('FIN_TILE_H   equ 64\n')
        w(';   --- per EPISODE (1-3): its finpic.bin section (first chunk,\n')
        w(';       chunks), and where the section puts the font and the flat\n')
        w(';       (offsets from FIN_ARENA); its text in fin.bin ---\n')
        for i, (ep, flatname, _t) in enumerate(EPISODES):
            ch, n, fo, lo = secs[i]
            w('FIN_SCH%d     equ %-5d  ; chunk in finpic.bin\n' % (ep, ch))
            w('FIN_NCH%d     equ %-5d  ; chunks\n' % (ep, n))
            w('FIN_FONTA%d   equ $%05X ; the font\n' % (ep, fo))
            w('FIN_FLATA%d   equ $%05X ; %s\n' % (ep, lo, flatname))
        for i, (ep, _f, _t) in enumerate(EPISODES):
            w('FIN_TEXT%d    equ %-6d ; %d B incl. the NUL\n'
              % (ep, text_off[i], textlen[i]))
        for i, (ep, _f, _t) in enumerate(EPISODES):
            w('FIN_TLEN%d    equ %d\n' % (ep, textlen[i] - 1))
        w(';   --- stage 1, 320x200 SR (f_finale.asm fin_show) ---\n')
        w('FIN_ARENA_P  equ $%06X  ; = FIN_ARENA, where every section lands\n'
          % FIN_ARENA_VRAM)
        w('FIN_SR_W     equ %d     ; a screen row, in bytes\n' % SR_W)
        w('FIN_PAGE_XDL equ $%04X  ; a page\'s list, from FIN_ARENA\n' % PAGE_XDL)
        w('FIN_BUN_W    equ %d    ; the PFUB2|PFUB1 surface\'s row pitch\n' % BUN_W)
        w('FIN_BUN_XDL  equ $%05X ; ...its list (scrolled = %d)\n' % (BUN_XDL, SR_W))
        w('FIN_XDL_N    equ %d     ; entries in an SR list\n'
          % len(pack_menu._sr_entries()))
        w(';   --- F_BunnyScroll (f_finale.c:644), tics and 320 pixels ---\n')
        w('FIN_BUN_T0   equ %d    ; scroll starts; scrolled = 320 - (t-%d)/2\n'
          % (BUNNY_START, BUNNY_START))
        w('FIN_BUN_END0 equ %d   ; END0 appears\n' % BUNNY_END0)
        w('FIN_BUN_ST0  equ %d   ; ...and the letters start marching\n'
          % BUNNY_STAGE0)
        w('FIN_BUN_STEP equ %d      ; one more letter every this many tics\n'
          % BUNNY_STEP)
        w('FIN_BUN_LAST equ %d      ; END0..END6\n' % BUNNY_LAST)
        w('FIN_END_OFF  equ $%05X ; the END letters, from FIN_ARENA (episode 3)\n'
          % end_off)
        w('FIN_END_N    equ %d\n' % len(ends))
        w('; END table: END0 whole, END1..6 only the rectangle that changed.\n')
        w('; s = data offset from FIN_END_OFF, d = the rectangle\'s offset on\n')
        w('; the 640 surface from the END origin (dy*640+dx), then w/h bytes.\n')
        w('fin_end_s\n        dta %s\n'
          % ','.join('a(%d)' % e[0] for e in ends))
        w('fin_end_d\n        dta %s\n'
          % ','.join('a(%d)' % (e[4] * BUN_W + e[3]) for e in ends))
        w('fin_end_w\n        dta %s\n' % ','.join(str(e[1]) for e in ends))
        w('fin_end_h\n        dta %s\n' % ','.join(str(e[2]) for e in ends))
        w('FIN_END_X    equ %d    ; (320-13*8)/2\n' % END_X)
        w('FIN_END_Y    equ %d     ; (200-8*8)/2\n' % END_Y)
        w('FIN_END_RW   equ %d    ; the box every END patch fits in: what\n'
          % ebox[0])
        w('FIN_END_RH   equ %d     ;   END0 saves before the first letter\n'
          % ebox[1])
        w(';   --- F_TextWrite (f_finale.c:261), DOOM\'s own numbers ---\n')
        w('FIN_CX0      equ %d\n' % CX0)
        w('FIN_CY0      equ %d\n' % CY0)
        w('FIN_LINEH    equ %d\n' % LINEH)
        w('FIN_SPACEW   equ %d      ; the "not a glyph" advance\n' % SPACEW)
        w('FIN_SPEED    equ %d      ; TEXTSPEED, tics per character\n' % TEXTSPEED)
        w('FIN_WAIT     equ %d    ; TEXTWAIT, tics to hold the finished page\n'
          % TEXTWAIT)
        w(';   --- hu_font advance widths, \'!\'..\'_\' ---\n')
        w('fin_fw\n')
        for i in range(0, len(widths), 16):
            w('        dta %s\n' % ','.join(str(v) for v in widths[i:i + 16]))
    print('fin_syms.inc -> %s' % p)


if __name__ == '__main__':
    emit()
