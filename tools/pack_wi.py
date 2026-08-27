#!/usr/bin/env python3
"""DOOM's own intermission graphics -> wi.bin / wi.tab / wi_syms.inc.

wi_stuff.c, single player, episode 1. Like the main menu (pack_menu.py) the
intermission is NOT text: every label is a patch (WIF, WIENTER, WIOSTK, ...)
and every digit is one too (WINUM0..9), so the port needs no font for it --
only the patch blitter hud.asm already has. The 7-byte rows this emits are
byte-for-byte hud.tab's layout, so hud_entry + hud_blit draw a WI patch with
no new blitter at all.

Same encoding as pack_hud.py / pack_menu.py -- row-major, halved horizontally
(one byte = two DOOM pixels, every second column kept), palette index 0 =
transparent under BLT_BSTENCIL. The background is the one opaque lump.

WHERE IT LIVES. $04A000 -- the free 152 KB above the HU strips (memory_map.inc
VRAM map), streamed ONCE at boot as another stream inside menu.bin, exactly
the way the HU strips already ride there. It is map-independent, so this is
the same deal the status bar and the menu patches get.

The obvious cheaper-looking alternative -- borrow the sprite arena at $018000
like TITLEPIC and the READ THIS! pages, since the outgoing level's pool is
finished with -- does NOT work, and the reason is worth writing down:
load_vram stages every chunk through TEX_STAGE ($1000-$13FF, diskio.asm),
which is the same RAM the overlay RUNS in (MENU_RUN). So the stream would
have to be driven from resident code before the overlay opens, and that stub
is ~33 B against a largest free hole of 21 B (tools/ram_map.py). Loading at
boot instead makes the entry stub 7 bytes, costs 48 KB of VRAM we have three
times over, and means the intermission comes up with no drive access at all.

The overlay's TWO 4 KB chunks (stage 1 and stage 2 -- see wi.asm for why it
is two) are appended right BEHIND the pixels so the whole thing is ONE
consecutive bank run and therefore ONE row in menu.asm's mn_ld_tab, which is
what it has room for (7 spare bytes = one 4-byte row). The 7-byte patch rows
are not a chunk at all: wi.asm ins-es wi.tab straight into stage 2.

GEOMETRY is wi_stuff.c's own, with x HALVED (the port draws 160 where DOOM
draws 320) and y kept -- exactly the split pack_menu.py documents:
    WI_TITLEY   2                       SP_STATSX  50    SP_STATSY 50
    SP_TIMEX   16                       SP_TIMEY   SCREENHEIGHT-32 = 168
    lh = (3 * WINUM0.height) / 2                    (the stats line pitch)
    "Finished" sits (5 * lnames.height) / 4 under the level name (WI_drawLF)
Percentages are right-aligned at SCREENWIDTH - SP_STATSX, which WI_drawPercent
reaches by drawing the '%' AT that x and then walking the digits leftwards.

  python tools/pack_wi.py
"""
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                              # noqa: E402
from wadtex import WadTextures                                   # noqa: E402

ROOT = os.path.dirname(_HERE)
CHUNK = 4096                                     # load_vram's unit (32 sectors)

# The free VRAM above the HU strips ($040000 + nstrips x 1 KB, 4 KB-aligned;
# nine levels' 40 strips end at $049FFF, so the E1 base is $04A000). FRAME_C
# is at $070000, so there are ~150 KB here and this takes ~14 chunks. The
# strip count moves with the BUILD's level list (pack_menu.TITLES grows one
# strip per level), so _set_maps() recomputes the base -- everything downstream
# reads it from wi_syms.inc (WI_VRAM/WI_BANK/WIOVL_BANK/WI2_BANK).
WI_VRAM_BASE = 0x04A000

SCREEN_W = 160                                   # port bytes (= 320 DOOM px)
SCREEN_H = 200

# ---- wi_stuff.c geometry, x halved -----------------------------------------
WI_TITLEY = 2
SP_STATSX = 50 // 2
SP_STATSY = 50
SP_TIMEX = 16 // 2
SP_TIMEY = SCREEN_H - 32

# lnodes[NUMEPISODES][NUMMAPS] -- where each level sits on its episode's WIMAP
# (wi_stuff.c:177), x halved on the way out. All THREE episodes since
# 2026-08-18: E2/E3 used to borrow episode 1's spots (index mod 9), which put
# every splat and the YAH pointer somewhere meaningless on an E2/E3 map.
LNODES = (
    ((185, 164), (148, 143), (69, 122), (209, 102), (116, 89),
     (166, 55), (71, 56), (135, 29), (71, 24)),
    ((254, 25), (97, 50), (188, 64), (128, 78), (214, 92),
     (133, 130), (208, 136), (148, 140), (235, 158)),
    ((156, 168), (48, 154), (174, 95), (265, 75), (130, 48),
     (279, 23), (198, 48), (140, 25), (281, 136)),
)

# epsd0animinfo (wi_stuff.c:222) -- episode 1 is wbs->epsd 0, so these are the
# ones that play. All ten are ANIM_ALWAYS, 3 frames, period TICRATE/3.
ANIM_LOC = ((224, 104), (184, 160), (112, 136), (72, 112), (88, 96),
            (64, 48), (192, 40), (136, 16), (80, 16), (64, 24))
ANIM_FRAMES = 3
ANIM_PERIOD = 35 // 3                            # TICRATE/3 = 11 tics

# pars -- g_game.c:981 pars[episode][map], seconds, all three episodes.
PARS = {'E1M1': 30, 'E1M2': 75, 'E1M3': 120, 'E1M4': 90, 'E1M5': 165,
        'E1M6': 180, 'E1M7': 180, 'E1M8': 30, 'E1M9': 165,
        'E2M1': 90, 'E2M2': 90, 'E2M3': 90, 'E2M4': 120, 'E2M5': 90,
        'E2M6': 360, 'E2M7': 240, 'E2M8': 30, 'E2M9': 170,
        'E3M1': 90, 'E3M2': 45, 'E3M3': 90, 'E3M4': 150, 'E3M5': 90,
        'E3M6': 90, 'E3M7': 165, 'E3M8': 30, 'E3M9': 135}

E1_MAPS = tuple('E1M%d' % i for i in range(1, 10))


def wilv(nm):
    """The level-name lump: hu_stuff's WILV<episode-1><map-1> (E2M1->WILV10)."""
    return 'WILV%d%d' % (int(nm[1]) - 1, int(nm[3]) - 1)


# ---- the lump list, in INDEX order (the engine's wi_syms.inc constants) -----
# Single player only: WIOSTS/WIFRGS/WIMSTT/WIKILRS/WIVCTMS/WIP*/WIBP* are the
# netgame and deathmatch tallies and this port has neither.
# 2026-08-18 (multi-episode builds): everything per-level -- the name lumps,
# wi_lvx, wi_par, the lnodes -- keys off the BUILD's level list, and every
# index after the name block shifts with len(MAPS). wi.asm reads them all from
# wi_syms.inc equs, so a 10-level build simply re-numbers itself. _set_maps()
# sizes the module for a list; the default is episode 1.
#
# WIMINUS is deliberately absent, and it is not an omission: it does not exist
# in registered DOOM (this WAD has 2045 lumps, E1-E3, no E4 and no WIMINUS --
# it is a DOOM II lump). WI_loadData caches it unconditionally, but WI_drawNum
# only draws it when `n < 0`, and no single-player stat is ever negative: the
# three percentages are 0..100 and both times are unsigned. So the one code
# path that could want it is unreachable here.


def _set_maps(maps):
    global MAPS, LEVELS, PAR, LUMPS, WI_VRAM_BASE
    global I_BG, I_LV0, I_FINISH, I_ENTER, I_KILLS, I_ITEMS, I_SECRET
    global I_TIME, I_PAR, I_SUCKS, I_NUM0, I_PCNT, I_COLON
    global I_SPLAT, I_YAH0, I_YAH1, I_ANIM0
    MAPS = list(maps)
    n = LEVELS = len(MAPS)
    import pack_menu                              # strip count = levels + the
    nstrips = n + len(pack_menu.MESSAGES) - 1     # messages (MESSAGES[0] gets
    WI_VRAM_BASE = (0x040000 + nstrips * pack_menu.TITLE_STRIDE
                    + 0xFFF) & ~0xFFF             # no strip) -- keep clear of
                                                  # the HU strip run above
    PAR = tuple(PARS[nm] for nm in MAPS)
    LUMPS = (['WIMAP0']                                      # 0    background
             + [wilv(nm) for nm in MAPS]                     # 1    level names
             + ['WIF', 'WIENTER']                            # n+1  finished/entering
             + ['WIOSTK', 'WIOSTI', 'WISCRT2']               # n+3  kills/items/secret
             + ['WITIME', 'WIPAR', 'WISUCKS']                # n+6  time/par/sucks
             + ['WINUM%d' % i for i in range(10)]            # n+9  digits
             + ['WIPCNT', 'WICOLON']                         # n+19 % and :
             + ['WISPLAT', 'WIURH0', 'WIURH1']               # n+21 splat + "you are here"
             + ['WIA0%.2d%.2d' % (j, i)                      # n+24 the ten animations
                for j in range(len(ANIM_LOC)) for i in range(ANIM_FRAMES)])
    I_BG, I_LV0 = 0, 1
    I_FINISH, I_ENTER = n + 1, n + 2
    I_KILLS, I_ITEMS, I_SECRET = n + 3, n + 4, n + 5
    I_TIME, I_PAR, I_SUCKS = n + 6, n + 7, n + 8
    I_NUM0 = n + 9
    I_PCNT, I_COLON = n + 19, n + 20
    I_SPLAT, I_YAH0, I_YAH1 = n + 21, n + 22, n + 23
    I_ANIM0 = n + 24


_set_maps(E1_MAPS)


def halve(wt, nm):
    """One WAD patch -> (bytes, w in bytes, h, left in bytes, top), halved
       horizontally exactly the way pack_hud.py halves the status bar."""
    pat = wt.get_patch(nm)
    if pat is None:
        sys.exit('  ERROR: %s is not in the WAD' % nm)
    w, h, cols = pat
    left, top = wt.patch_offset(nm)
    hw = (w + 1) // 2
    img = bytearray(hw * h)                       # 0 = transparent
    for cx in range(0, w, 2):                     # keep every second column
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                if 0 <= td + k < h:
                    img[(td + k) * hw + cx // 2] = c
    return bytes(img), hw, h, left // 2, top


def emit():
    wad = Wad(DEFAULT_WAD)
    wt = WadTextures(wad)
    blob = bytearray()
    tab = bytearray()
    addr = WI_VRAM_BASE
    dims = {}
    for nm in LUMPS:
        img, hw, h, left, top = halve(wt, nm)
        dims[nm] = (hw, h, left, top)
        blob += img
        tab += struct.pack('<HBBBbb', addr & 0xFFFF, (addr >> 16) & 0xFF,
                           hw, h, left, top)
        addr += len(img)

    bgw, bgh = dims['WIMAP0'][:2]
    if (bgw, bgh) != (SCREEN_W, SCREEN_H):
        sys.exit('  ERROR: WIMAP0 is %dx%d halved, the screen is %dx%d'
                 % (bgw, bgh, SCREEN_W, SCREEN_H))

    chunks = (len(blob) + CHUNK - 1) // CHUNK
    blob += bytes(chunks * CHUNK - len(blob))
    # wi.tab is written as a FILE, not a chunk: wi.asm ins-es it into stage 2.
    # It has to be in 6502 RAM for hud_blit to read a row with (zp_ptr),y, and
    # stage 2 had 700 spare bytes -- which is better spent than the 512 B of
    # clip pool it used to borrow, because the melt needs those for its y[].
    out = os.path.join(ROOT, 'build', 'assets', 'wi')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'wi.bin'), 'wb').write(blob)
    open(os.path.join(out, 'wi.tab'), 'wb').write(tab)
    emit_syms(dims, chunks, len(tab) // 7)
    print('wi.bin %d B (%d chunks, VRAM $%06X..$%06X), wi.tab %d B (%d lumps,'
          ' ins-ed into the overlay) -> %s'
          % (len(blob), chunks, WI_VRAM_BASE, addr, len(tab), len(tab) // 7, out))


def emit_syms(dims, chunks, nlumps):
    numw, numh = dims['WINUM0'][:2]
    lh = (3 * numh) // 2                          # WI_drawStats' line height
    lvh = dims[wilv(MAPS[0])][1]
    p = os.path.join(ROOT, 'wi_syms.inc')
    with open(p, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_wi.py -- DO NOT EDIT.\n')
        w('; wi_stuff.c geometry. x values are HALVED (the port draws 160\n')
        w('; wide where DOOM draws 320); y values are DOOM\'s own.\n')
        w('WI_VRAM      equ $%06X\n' % WI_VRAM_BASE)
        w('WI_BANK      equ $%02X   ; = WI_VRAM >> 12\n' % (WI_VRAM_BASE >> 12))
        w('WI_CHUNKS    equ %d   ; the PIXELS\n' % chunks)
        w('WIOVL_BANK   equ $%02X   ; the code overlay\'s STAGE 1, right behind\n'
          % ((WI_VRAM_BASE >> 12) + chunks))
        w('WI2_BANK     equ $%02X   ; ...and stage 2 behind that\n'
          % ((WI_VRAM_BASE >> 12) + chunks + 1))
        w('                        ; (split_menu_ovl.py puts both there), so ONE\n')
        w('                        ; mn_ld_tab row streams all three. The 7-byte\n')
        w('                        ; ROWS are not a chunk at all: wi.asm ins-es\n')
        w('                        ; wi.tab straight into stage 2, which leaves\n')
        w('                        ; the clip pool free for the melt\'s y[].\n')
        w('WI_NLUMPS    equ %d\n' % nlumps)
        w('WI_LEVELS    equ %d\n' % LEVELS)
        w(';   --- wi.tab indices ---\n')
        for nm, ix in (('WI_I_BG', I_BG), ('WI_I_LV0', I_LV0),
                       ('WI_I_FINISH', I_FINISH), ('WI_I_ENTER', I_ENTER),
                       ('WI_I_KILLS', I_KILLS), ('WI_I_ITEMS', I_ITEMS),
                       ('WI_I_SECRET', I_SECRET), ('WI_I_TIME', I_TIME),
                       ('WI_I_PAR', I_PAR), ('WI_I_SUCKS', I_SUCKS),
                       ('WI_I_NUM0', I_NUM0), ('WI_I_PCNT', I_PCNT),
                       ('WI_I_COLON', I_COLON),
                       ('WI_I_SPLAT', I_SPLAT), ('WI_I_YAH0', I_YAH0),
                       ('WI_I_YAH1', I_YAH1), ('WI_I_ANIM0', I_ANIM0)):
            w('%-12s equ %d\n' % (nm, ix))
        w(';   --- geometry (wi_stuff.c WI_drawStats / WI_drawLF / WI_drawEL) ---\n')
        w('WI_TITLEY    equ %d\n' % WI_TITLEY)
        w('WI_LFY2      equ %d   ; "Finished" y: TITLEY + 5*lvh/4\n'
          % (WI_TITLEY + (5 * lvh) // 4))
        w('WI_STATSX    equ %d\n' % SP_STATSX)
        w('WI_STATSY    equ %d\n' % SP_STATSY)
        w('WI_LH        equ %d   ; 3*WINUM0.h/2, the stats line pitch\n' % lh)
        w('WI_PCTX      equ %d   ; SCREENWIDTH - SP_STATSX, halved\n'
          % (SCREEN_W - SP_STATSX))
        w('WI_TIMEX     equ %d\n' % SP_TIMEX)
        w('WI_TIMEY     equ %d\n' % SP_TIMEY)
        w('WI_TIMEVX    equ %d   ; SCREENWIDTH/2 - SP_TIMEX, halved\n'
          % (SCREEN_W // 2 - SP_TIMEX))
        w('WI_PARX      equ %d   ; SCREENWIDTH/2 + SP_TIMEX, halved\n'
          % (SCREEN_W // 2 + SP_TIMEX))
        w('WI_PARVX     equ %d   ; SCREENWIDTH - SP_TIMEX, halved\n'
          % (SCREEN_W - SP_TIMEX))
        w('WI_NUMW      equ %d   ; WINUM0 width in bytes (WI_drawNum step)\n' % numw)
        w('WI_COLONW    equ %d\n' % dims['WICOLON'][0])
        # The "YOU ARE HERE" pointer's OWN erase box, and it is not the
        # percentage field's: WIURH0 is 30x15 halved and carries left=-2,
        # top=15, so hud_blit puts it at (x+1, y-15). A box at (x, y) sized for
        # a percentage erases the wrong place and too little of it -- the blink
        # left the arrow on screen for good.
        yw, yh, yl, yt = dims['WIURH0']
        w('WI_YAHW      equ %d      ; WIURH0, halved\n' % yw)
        w('WI_YAHH      equ %d\n' % yh)
        w('WI_YAHDX     equ %d      ; hud_blit draws it at (x-left, y-top)\n' % -yl)
        w('WI_YAHDY     equ %d\n' % yt)
        w('WI_ANIMS     equ %d\n' % len(ANIM_LOC))
        w('WI_ANIMF     equ %d\n' % ANIM_FRAMES)
        w('WI_ANIMPER   equ %d   ; TICRATE/3, in DOOM tics\n' % ANIM_PERIOD)
        w(';   --- centred x for the two title lines, per level (pre-computed:\n')
        w(';       V_DrawPatch((SCREENWIDTH - width)/2, ...) with no runtime\n')
        w(';       divide, and the widths are pack-time constants anyway) ---\n')
        w('wi_lvx\n')
        for nm in MAPS:
            lw = dims[wilv(nm)][0]
            w('        dta %d    ; %s (%s), %d B wide\n'
              % ((SCREEN_W - lw) // 2, wilv(nm), nm, lw))
        w('wi_finx dta %d    ; WIF\n' % ((SCREEN_W - dims['WIF'][0]) // 2))
        w('wi_entx dta %d    ; WIENTER\n' % ((SCREEN_W - dims['WIENTER'][0]) // 2))
        w(';   --- lnodes[episode][map]: where each level sits on its OWN\n')
        w(';       episode WIMAP, x halved (wi_stuff.c:177). Indexed by the\n')
        w(';       BUILD level index, so wi_yahput needs no arithmetic. ---\n')
        nodes, ebase, nanim = [], [], []
        for nm in MAPS:
            e, mp = int(nm[1]) - 1, int(nm[3]) - 1
            nodes.append(LNODES[e][mp] if e < len(LNODES) else LNODES[0][mp])
            b = 'E%dM1' % (e + 1)
            ebase.append(MAPS.index(b) if b in MAPS else 0)
            # (nanim is NOT a table: "this episode has animations" is exactly
            #  "ebase == 0", because only episode 1's set is packed.)
            # epsd0animinfo is the only set packed: episode 1's ten ANIM_ALWAYS
            # blobs. Episodes 2 and 3 have their own lumps (WIA1*/WIA2*, 31 KB
            # more) and episode 2's are ANIM_LEVEL, which appear as the player
            # advances -- not modelled. Drawing episode 1's ten on an E2/E3 map
            # would put them somewhere meaningless, so those episodes get NONE.
            nanim.append(len(ANIM_LOC) if e == 0 else 0)
        w('wi_nodex\n')
        w('        dta %s\n' % ','.join(str(x // 2) for x, _ in nodes))
        w('wi_nodey\n')
        w('        dta %s\n' % ','.join(str(y) for _, y in nodes))
        w(';   --- per level: the index of its episode M1 (wi_splats walks\n')
        w(';       lnodes from there, WI_drawShowNextLoc is episode-relative)\n')
        w(';       Episode 1 is the only one with animations packed, and\n')
        w(';       that is exactly "wi_ebase == 0" -- no second table. ---\n')
        w('wi_ebase\n        dta %s\n' % ','.join(str(v) for v in ebase))
        w(';   --- epsd0animinfo locations (x halved) ---\n')
        w('wi_animx\n')
        w('        dta %s\n' % ','.join(str(x // 2) for x, _ in ANIM_LOC))
        w('wi_animy\n')
        w('        dta %s\n' % ','.join(str(y) for _, y in ANIM_LOC))
        w(';   --- pars[episode][map] (g_game.c:981), seconds. A BYTE each:\n')
        w(';       E2M6 alone says 360 and clamps to 255 (the stat line shows\n')
        w(';       4:15 for it; a u16 table is not worth the reader rework).\n')
        w('wi_par\n')
        w('        dta %s\n' % ','.join(str(min(v, 255)) for v in PAR))
    print('wi_syms.inc -> %s' % p)


#==============================================================
# PREVIEW -- renders the two intermission screens FROM THE EMITTED BLOB, not
# from the WAD. That is the point: it exercises wi.bin's pixels, wi.tab's
# widths and patch offsets and wi_syms.inc's geometry, i.e. exactly the three
# things the 6502 will read, so a wrong halving phase or a bad centred x shows
# up here instead of on an Atari. The blit it models is hud_blit's: place at
# (x - left, y - top), index 0 transparent.
#==============================================================
OUT = os.path.join(ROOT, '_pomocne', 'preview')


def _syms():
    """wi_syms.inc back in as {name: int} + {label: [ints]} -- read, not
       repeated, so the preview cannot drift from what the engine assembles."""
    import re
    txt = open(os.path.join(ROOT, 'wi_syms.inc')).read()
    eq = {m.group(1): int(m.group(2)) for m in
          re.finditer(r'^(\w+)\s+equ\s+(\d+)', txt, re.M)}
    tb, cur = {}, None
    for line in txt.splitlines():
        line = line.split(';')[0].rstrip()
        m = re.match(r'^(\w+)(?:\s+dta\s+(.*))?$', line)
        if m and not line.startswith(' '):
            cur = m.group(1)
            tb[cur] = []
            if m.group(2):
                tb[cur] += [int(v) for v in m.group(2).split(',')]
            continue
        m = re.match(r'^\s+dta\s+(.*)$', line)
        if m and cur:
            tb[cur] += [int(v) for v in m.group(1).split(',')]
    return eq, tb


def _blit(px, blob, tab, pal, ix, x, y, opaque=False):
    lo, bank, w, h, left, top = struct.unpack('<HBBBbb', tab[ix * 7:ix * 7 + 7])
    off = ((bank << 16) | lo) - WI_VRAM_BASE
    x -= left
    y -= top
    for ry in range(h):
        for rx in range(w):
            c = blob[off + ry * w + rx]
            if c or opaque:
                if 0 <= x + rx < SCREEN_W and 0 <= y + ry < SCREEN_H:
                    px[x + rx, y + ry] = pal[c]


def _num(px, blob, tab, pal, eq, x, y, n, digits):
    """WI_drawNum: digits emitted right to left from x. Returns the new x."""
    if digits < 0:
        digits = 1 if not n else len(str(n))
    while digits:
        x -= eq['WI_NUMW']
        _blit(px, blob, tab, pal, eq['WI_I_NUM0'] + n % 10, x, y)
        n //= 10
        digits -= 1
    return x


def _pct(px, blob, tab, pal, eq, x, y, p):
    _blit(px, blob, tab, pal, eq['WI_I_PCNT'], x, y)
    _num(px, blob, tab, pal, eq, x, y, p, -1)


def _time(px, blob, tab, pal, eq, x, y, t):
    """WI_drawTime, the t <= 61*59 branch."""
    div = 1
    while True:
        n = (t // div) % 60
        x = _num(px, blob, tab, pal, eq, x, y, n, 2) - eq['WI_COLONW']
        div *= 60
        if div == 60 or t // div:
            _blit(px, blob, tab, pal, eq['WI_I_COLON'], x, y)
        if not t // div:
            return


def preview():
    from PIL import Image
    eq, tb = _syms()
    blob = open(os.path.join(ROOT, 'build', 'assets', 'wi', 'wi.bin'), 'rb').read()
    tab = open(os.path.join(ROOT, 'build', 'assets', 'wi', 'wi.tab'), 'rb').read()
    pal = WadTextures(Wad(DEFAULT_WAD)).playpal
    last, nxt = 0, 1                              # E1M1 finished -> entering E1M2

    def fresh():
        im = Image.new('RGB', (SCREEN_W, SCREEN_H), (0, 0, 0))
        p = im.load()
        _blit(p, blob, tab, pal, eq['WI_I_BG'], 0, 0, opaque=True)
        for j in range(eq['WI_ANIMS']):           # WI_drawAnimatedBack, frame 0
            _blit(p, blob, tab, pal, eq['WI_I_ANIM0'] + j * eq['WI_ANIMF'],
                  tb['wi_animx'][j], tb['wi_animy'][j])
        return im, p

    # ---- StatCount: WI_drawStats with the counters at their finals ----------
    im, p = fresh()
    _blit(p, blob, tab, pal, eq['WI_I_LV0'] + last, tb['wi_lvx'][last],
          eq['WI_TITLEY'])                                        # WI_drawLF
    _blit(p, blob, tab, pal, eq['WI_I_FINISH'], tb['wi_finx'][0], eq['WI_LFY2'])
    lh, sy = eq['WI_LH'], eq['WI_STATSY']
    for i, (lump, val) in enumerate((('WI_I_KILLS', 100), ('WI_I_ITEMS', 87),
                                     ('WI_I_SECRET', 50))):
        _blit(p, blob, tab, pal, eq[lump], eq['WI_STATSX'], sy + i * lh)
        _pct(p, blob, tab, pal, eq, eq['WI_PCTX'], sy + i * lh, val)
    _blit(p, blob, tab, pal, eq['WI_I_TIME'], eq['WI_TIMEX'], eq['WI_TIMEY'])
    _time(p, blob, tab, pal, eq, eq['WI_TIMEVX'], eq['WI_TIMEY'], 92)
    _blit(p, blob, tab, pal, eq['WI_I_PAR'], eq['WI_PARX'], eq['WI_TIMEY'])
    _time(p, blob, tab, pal, eq, eq['WI_PARVX'], eq['WI_TIMEY'], tb['wi_par'][last])
    os.makedirs(OUT, exist_ok=True)
    im.resize((SCREEN_W * 4, SCREEN_H * 2), Image.NEAREST).save(
        os.path.join(OUT, 'wi_stats.png'))

    # ---- ShowNextLoc: splats on taken levels + the YAH pointer --------------
    im, p = fresh()
    for i in range(last + 1):                     # "draw a splat on taken cities"
        _blit(p, blob, tab, pal, eq['WI_I_SPLAT'], tb['wi_nodex'][i],
              tb['wi_nodey'][i])
    _blit(p, blob, tab, pal, eq['WI_I_YAH0'], tb['wi_nodex'][nxt],
          tb['wi_nodey'][nxt])
    _blit(p, blob, tab, pal, eq['WI_I_ENTER'], tb['wi_entx'][0], eq['WI_TITLEY'])
    _blit(p, blob, tab, pal, eq['WI_I_LV0'] + nxt, tb['wi_lvx'][nxt], eq['WI_LFY2'])
    im.resize((SCREEN_W * 4, SCREEN_H * 2), Image.NEAREST).save(
        os.path.join(OUT, 'wi_next.png'))
    print('wrote %s/wi_stats.png and wi_next.png' % OUT)


if __name__ == '__main__':
    if '--levels' in sys.argv:                    # the BUILD's level list --
        arg = sys.argv[sys.argv.index('--levels') + 1]      # build_atr.ps1
        _set_maps([nm.strip().upper() for nm in arg.split(',') if nm.strip()])
    emit()
    if '--preview' in sys.argv:
        preview()
