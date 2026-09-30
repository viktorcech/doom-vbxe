#!/usr/bin/env python3
"""DOOM's own intermission graphics -> wi.bin / wi.tab / wi_syms.inc.

wi_stuff.c, single player, episode 1. Like the main menu (pack_menu.py) the
intermission is NOT text: every label is a patch (WIF, WIENTER, WIOSTK, ...)
and every digit is one too (WINUM0..9), so the port needs no font for it --
only a patch blitter. The 7-byte rows this emits are hud.tab's layout.

AT DOOM'S OWN 320 (2026-09-24). The intermission is a VBXE SR screen (wi.asm):
the world map, the labels, the digits and the animations are all full width,
palette index 0 transparent under BLT_BSTENCIL.

WHERE IT LIVES. Rapidus SDRAM, not VRAM: wimaps.bin rides the ATR behind the
songs and load_music streams it in at boot -- the world maps (one bank each,
with their SR list), then the KIT (every other patch), then every level name
in a 4 KB slot. When the intermission opens, wi_bgfetch copies the map onto
the SR surface and wi_kitfetch copies the kit and the two names it shows into
the pool behind it (KIT_VRAM): the level is over, so the pool is free, and no
drive access is needed at all.

The overlay's TWO 4 KB chunks (stage 1 and stage 2 -- see wi.asm for why it
is two) still ride the boot stream as ONE row in menu.asm's mn_ld_tab; the
7-byte patch rows are not a chunk at all: wi.asm ins-es wi.tab into stage 2.

GEOMETRY is wi_stuff.c's own, x and y as DOOM has them:
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
import pack_menu                                                 # noqa: E402

ROOT = os.path.dirname(_HERE)
CHUNK = 4096                                     # load_vram's unit (32 sectors)

# The free VRAM above the HU strips ($040000 + nstrips x 1 KB, 4 KB-aligned;
# nine levels' 40 strips end at $049FFF, so the E1 base is $04A000). FRAME_C
# is at $070000, so there are ~150 KB here and this takes ~14 chunks. The
# strip count moves with the BUILD's level list (pack_menu.TITLES grows one
# strip per level), so _set_maps() recomputes the base -- everything downstream
# reads it from wi_syms.inc (WI_VRAM/WI_BANK/WIOVL_BANK/WI2_BANK).
WI_VRAM_BASE = 0x04A000

SCREEN_W = 320                                   # the SR screen: DOOM's own
SCREEN_H = 200

# ---- wi_stuff.c geometry, DOOM's own pixels ---------------------------------
WI_TITLEY = 2
SP_STATSX = 50
SP_STATSY = 50
SP_TIMEX = 16
SP_TIMEY = SCREEN_H - 32

# The patches at full width live in SDRAM (wimaps.bin) and wi_kitfetch copies
# what one intermission needs into the pool behind the SR surface: the kit,
# then two level-name slots. The pool ends where the episode picker begins.
KIT_VRAM = 0x030000
ARENA_TOP = 0x03D000               # memory_map.inc ARENA_SPR_TOP
NAME_SLOT = 0x1000                 # a level name's slot in SDRAM (one 4 KB step)
MSG_STRIDE = 72                    # the message directory's per-array stride
                                   #   (2026-09-28: 64 -> 72, the gamma lines)
MSG_DIR = 0x200                    # ...and where the lines start in their bank

# lnodes[NUMEPISODES][NUMMAPS] -- where each level sits on its episode's WIMAP
# (wi_stuff.c:177), DOOM's own x. All THREE episodes since
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

# THE WORLD MAPS, at DOOM's own 320x200 (2026-09-24): the intermission is a
# VBXE SR screen like the title (wi.asm). Every map the build needs -- WIMAP0
# included, it left the boot VRAM stream -- is one whole SDRAM bank: the
# 64000-byte picture with its SR list in the padding at SR_XDL_OFF, so ONE
# spr_fcopy of WIM_COPY bytes puts both on the intermission's surface. Which
# episodes (0-based) got one -- filled by emit() from the level list.
WIM_BANK = 0x10000
WIM_MTXDL = pack_menu.LD_XDL_OFF   # the list of MELT_SR behind the map's list:
MELT_SR = 0x060000                 #   melt.asm's screen (the melts, the stats
                                   #   through a load, the in-game menu), which
                                   #   mt_show reads straight out of SDRAM
WIM_COPY = WIM_MTXDL               # what wi_bgfetch copies: the picture + its list
WIM_EPS = []
WI_SR_VRAM = 0x020000              # the surface wi.asm draws into (= the title's,
                                   #   pool RAM: the level is over)
WI_SR_BG = 0x010000                # ...and its pristine copy, what wi_erase
                                   #   restores from (FRAME_B + the pool's first
                                   #   32 KB, dead from the first melt on)

# pars -- g_game.c:981 pars[episode][map], seconds, all three episodes.
PARS = {'E1M1': 30, 'E1M2': 75, 'E1M3': 120, 'E1M4': 90, 'E1M5': 165,
        'E1M6': 180, 'E1M7': 180, 'E1M8': 30, 'E1M9': 165,
        'E2M1': 90, 'E2M2': 90, 'E2M3': 90, 'E2M4': 120, 'E2M5': 90,
        'E2M6': 360, 'E2M7': 240, 'E2M8': 30, 'E2M9': 170,
        'E3M1': 90, 'E3M2': 45, 'E3M3': 90, 'E3M4': 150, 'E3M5': 90,
        'E3M6': 90, 'E3M7': 165, 'E3M8': 30, 'E3M9': 135}

# DOOM II keeps its par times in a SEPARATE table, cpars[32] (g_game.c:987),
# indexed gamemap-1 -- not pars[episode][map]. Final Doom (TNT, Plutonia) has
# no table of its own: doom2.exe's cpars is what tnt.exe and plutonia.exe
# shipped with, so a MAPxx conversion gets these whatever the WAD is.
CPARS = (30, 90, 120, 120, 90, 150, 120, 120, 270, 90,          # MAP01-10
         210, 150, 150, 150, 210, 150, 420, 150, 210, 150,      # MAP11-20
         240, 150, 180, 150, 150, 300, 330, 420, 300, 180,      # MAP21-30
         120, 30)                                               # MAP31-32

E1_MAPS = tuple('E1M%d' % i for i in range(1, 10))


def is_mapxx(nm):
    """DOOM II / Final Doom level naming -- MAP01..MAP32 instead of ExMy."""
    return nm[:3] == 'MAP' and nm[3:].isdigit()


def epsd_map(nm):
    """(episode, map) as wi_stuff.c indexes them, both 0-based.

    A MAPxx level has no episode and, in DOOM II, no map screen at all --
    WI_drawShowNextLoc just draws INTERPIC. This port has one background slot
    and the WAD layering fills it from the IWAD (WIMAP0, episode 1's map), so
    a MAPxx level is placed on THAT map: episode 0, and the nine lnode spots
    reused round-robin. It is a spot on a picture, nothing reads it back."""
    if is_mapxx(nm):
        return 0, (int(nm[3:]) - 1) % len(LNODES[0])
    return int(nm[1]) - 1, int(nm[3]) - 1


def par_of(nm):
    """Par time in seconds. 0 = "no par" -- DOOM itself shows the par line
    regardless, and a WAD with levels outside both tables (MAP33+, or a name
    like TITLEMAP) used to take the whole build down with a KeyError."""
    if is_mapxx(nm):
        i = int(nm[3:]) - 1
        return CPARS[i] if 0 <= i < len(CPARS) else 0
    return PARS.get(nm, 0)


def wilv(nm):
    """The level-name lump. Two schemes, and wi_stuff.c:1570 picks between
    them on gamemode: commercial (MAPxx) caches CWILV00..CWILV31, everything
    else WILV<episode-1><map-1> (E2M1 -> WILV10)."""
    if is_mapxx(nm):
        return 'CWILV%.2d' % (int(nm[3:]) - 1)
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


LVNAME = {}                       # level -> the name lump finally used


def _set_maps(maps):
    global MAPS, LEVELS, PAR, LUMPS, WI_VRAM_BASE
    global I_BG, I_LV0, I_FINISH, I_ENTER, I_KILLS, I_ITEMS, I_SECRET
    global I_TIME, I_PAR, I_SUCKS, I_NUM0, I_PCNT, I_COLON
    global I_SPLAT, I_YAH0, I_YAH1, I_ANIM0
    MAPS = list(maps)
    n = LEVELS = len(MAPS)
    # 2026-09-16: PINNED, not
    WI_VRAM_BASE = pack_menu.WI_VRAM_BASE         #   computed. It used to be
                                                  #   "wherever the HU strips
                                                  #   end", and the strips just
                                                  #   shrank by 25 KB to pay for
                                                  #   the SR status bar -- so the
                                                  #   old formula would have
                                                  #   walked the intermission
                                                  #   straight back down onto the
                                                  #   bar graphics. pack_menu
                                                  #   owns the three bases and
                                                  #   guards the gaps.
    PAR = tuple(par_of(nm) for nm in MAPS)
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
    LVNAME.clear()                    # what wilv() ASKS for, until emit() has
    LVNAME.update((nm, wilv(nm)) for nm in MAPS)   # seen the WAD and found it


_set_maps(E1_MAPS)


def patch_full(wt, nm):
    """One WAD patch -> (bytes, w, h, left, top) at full width, row-major,
       0 = transparent (the blitter's stencil)."""
    pat = wt.get_patch(nm)
    if pat is None:
        sys.exit('  ERROR: %s is not in the WAD' % nm)
    w, h, cols = pat
    left, top = wt.patch_offset(nm)
    if w > 255 or h > 255:
        sys.exit('  ERROR: %s is %dx%d -- a 7-byte row holds a byte of each'
                 % (nm, w, h))
    img = bytearray(w * h)
    for cx in range(w):
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                if 0 <= td + k < h:
                    img[(td + k) * w + cx] = c
    return bytes(img), w, h, left, top


def _resolve_lvnames(wad):
    """Swap in a level-name lump that is actually THERE.

    A map-only PWAD full of MAPxx levels layered over the DOOM IWAD asks for
    CWILV00.., and the IWAD underneath has none -- registered DOOM never
    shipped them. patch_full() would sys.exit on the first one and take the
    build down over a caption. Fall back to the WILVxx slot in the same
    position: the wrong words, but the intermission comes up."""
    have = {n for n, _o, _s in wad.lumps}
    for i, nm in enumerate(MAPS):
        want = wilv(nm)
        if want in have:
            continue
        alt = 'WILV%d%d' % (0, i % 9)              # episode 1's nine captions
        if alt not in have:
            sys.exit('  ERROR: neither %s nor %s is in the WAD -- %s has no '
                     'level-name graphic' % (want, alt, nm))
        print('  %s: no %s in the WAD, using %s (a map-only PWAD brings no '
              'level-name graphic)' % (nm, want, alt))
        LUMPS[I_LV0 + i] = alt
        LVNAME[nm] = alt


def _a256(n):
    return (n + 255) & ~255


def emit():
    wad = Wad(DEFAULT_WAD)
    _resolve_lvnames(wad)
    wt = WadTextures(wad)
    pats = {nm: patch_full(wt, nm) for i, nm in enumerate(LUMPS) if i != I_BG}
    dims = {nm: p[1:] for nm, p in pats.items()}

    # ---- THE KIT: every patch but the map and the level names, back to back,
    # and where each name goes: two fixed SLOTS behind it, the finished level's
    # and the next one's (wi_kitfetch fills them and points their rows there).
    kit, koff = bytearray(), {}
    for nm in LUMPS[I_FINISH:]:
        koff[nm] = len(kit)
        kit += pats[nm][0]
    names = [LUMPS[I_LV0 + i] for i in range(LEVELS)]
    namesz = _a256(max(len(pats[nm][0]) for nm in names))
    if namesz > NAME_SLOT:
        sys.exit('  ERROR: a level name is %d B, its SDRAM slot is %d' % (namesz, NAME_SLOT))
    lva = KIT_VRAM + _a256(len(kit))
    lvb = lva + namesz
    if lvb + namesz > ARENA_TOP:
        sys.exit('  ERROR: the kit + two name slots end at $%06X, past $%06X'
                 % (lvb + namesz, ARENA_TOP))
    if len(kit) > WIM_BANK:
        sys.exit('  ERROR: the kit is %d B, more than its SDRAM bank' % len(kit))

    # ---- wi.tab, 7-byte rows as hud.tab has them: u24 vram, w, h, left, top.
    # It has to be in 6502 RAM for sr_put to read a row with (zp_ptr),y, so
    # wi.asm ins-es it into stage 2.
    tab = bytearray()
    for i, nm in enumerate(LUMPS):
        if i == I_BG:                             # the map is not a patch (it is
            tab += bytes(7)                       #   wimaps.bin's): the row stays
            continue                              #   so the indices hold
        _img, w, h, left, top = pats[nm]
        a = lva if I_LV0 <= i < I_FINISH else KIT_VRAM + koff[nm]
        tab += struct.pack('<HBBBbb', a & 0xFFFF, a >> 16, w, h, left, top)
    out = os.path.join(ROOT, 'build', 'assets', 'wi')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'wi.bin'), 'wb').write(b'')   # no pixels boot-streamed
    open(os.path.join(out, 'wi.tab'), 'wb').write(tab)

    # ---- the SDRAM blob: the world maps (320x200, one bank each), then the
    # kit (a bank of its own), then the level names in NAME_SLOT-byte slots.
    # WI_loadData draws WIMAP%d for wbs->epsd (wi_stuff.c:1548); a MAPxx level
    # has no map of its own and goes on WIMAP0 (epsd_map). It rides the ATR
    # right behind the songs (make_atr_doom.py WIM) and load_music streams it
    # into Rapidus SDRAM from WIMAP_BANK (memory_map.inc).
    have = {n for n, _o, _s in wad.lumps}
    WIM_EPS[:] = sorted({epsd_map(nm)[0] for nm in MAPS}
                        & {e for e in range(len(LNODES)) if 'WIMAP%d' % e in have})
    if 0 not in WIM_EPS:
        sys.exit('  ERROR: WIMAP0 is not in the WAD -- every level falls back to it')
    wim = bytearray()
    for e in WIM_EPS:
        img, w, h = pack_menu._raster_full(wt.get_patch('WIMAP%d' % e))
        if (w, h) != (SCREEN_W, SCREEN_H):
            sys.exit('  ERROR: WIMAP%d is %dx%d, the SR screen is %dx%d'
                     % (e, w, h, SCREEN_W, SCREEN_H))
        bank = bytearray(img)
        bank += bytes(pack_menu.SR_XDL_OFF - len(bank))
        bank += pack_menu._sr_xdl(WI_SR_VRAM)
        bank += bytes(WIM_MTXDL - len(bank))
        mtx = pack_menu._sr_xdl(MELT_SR)
        bank += mtx
        if WIM_MTXDL + len(mtx) > WIM_BANK or pack_menu.SR_XDL_OFF + len(mtx) > WIM_COPY:
            sys.exit('  ERROR: the two lists do not fit a map bank behind the map')
        wim += bank + bytes(WIM_BANK - len(bank))
    wim += kit + bytes(WIM_BANK - len(kit))
    for nm in names:
        wim += pats[nm][0] + bytes(NAME_SLOT - len(pats[nm][0]))
    # ---- THE HU LINES at DOOM's own width: one bank, the directory first --
    # lo[64], hi[64], width[64], bank[64] by STRIP index (the level names, then the
    # messages at id + MSG_IDX0: pack_menu's MSG_IDX0 numbering), read
    # with lda.l -- then the lines, TITLE_H rows each. The engine copies the
    # one it shows into VRAM: the message line (strip.asm st_mfetch), a save
    # slot's level name (menu.asm mn_sname).
    wim += bytes(-len(wim) % WIM_BANK)
    msgbk = len(wim) // WIM_BANK
    texts = [pack_menu.NAMES.get(nm, nm) for nm in MAPS] + list(pack_menu.MESSAGES[1:])
    lines, lo, hi, wd, bk = bytearray(), [], [], [], []
    for text in texts:
        img, lw = pack_menu._hu_line(wt, text)
        if lw > 255 or lw > SCREEN_W:
            sys.exit('  ERROR: the line %r is %d px wide' % (text, lw))
        off = MSG_DIR + len(lines)                # 24 bits: the lines run on
        lo.append(off & 0xFF)                     #   into the next bank
        hi.append((off >> 8) & 0xFF)
        bk.append(off >> 16)
        wd.append(lw)
        lines += img
    if len(texts) > MSG_STRIDE or 4 * MSG_STRIDE > MSG_DIR:
        sys.exit('  ERROR: the HU line directory does not fit')
    pad = bytes(MSG_STRIDE - len(lo))
    blk = bytes(lo) + pad + bytes(hi) + pad + bytes(wd) + pad + bytes(bk) + pad
    wim += blk + bytes(MSG_DIR - len(blk)) + lines
    open(os.path.join(out, 'wimaps.bin'), 'wb').write(wim)

    emit_syms(dims, len(tab) // 7, wt, len(kit), namesz, lva, lvb, msgbk,
              max(wd))
    print('wi.tab %d B (%d lumps, ins-ed into the overlay); the patches ride '
          'wimaps.bin -> %s' % (len(tab), len(tab) // 7, out))
    print('wimaps.bin %d B (%s, a %d B kit, %d names) -> Rapidus SDRAM at boot'
          % (len(wim), ', '.join('WIMAP%d' % e for e in WIM_EPS), len(kit), LEVELS))


def yah_pick(wt, x, y):
    """WI_drawOnLnode (wi_stuff.c:469): the first of WIURH0/WIURH1 whose box
    fits the 320x200 screen at lnode (x, y), in DOOM's own pixels. WIURH0 hangs
    to the right of the node, WIURH1 to the left -- E3M4/E3M6/E3M9 sit too
    close to the right edge for WIURH0. Neither fitting is DOOM's "Could not
    place patch" and draws nothing; no lnode of the three episodes does that,
    so it keeps WIURH0 (a MAPxx build reuses episode 1's spots, which all fit)."""
    for i, nm in enumerate(('WIURH0', 'WIURH1')):
        w, h, _cols = wt.get_patch(nm)
        left, top = wt.patch_offset(nm)
        x0, y0 = x - left, y - top
        if x0 >= 0 and x0 + w < 320 and y0 >= 0 and y0 + h < SCREEN_H:
            return i
    return 0


def emit_syms(dims, nlumps, wt, kitlen, namesz, lva, lvb, msgbk, msgw):
    numw, numh = dims['WINUM0'][:2]
    lh = (3 * numh) // 2                          # WI_drawStats' line height
    lvh = dims[LVNAME[MAPS[0]]][1]
    p = os.path.join(ROOT, 'wi_syms.inc')
    with open(p, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_wi.py -- DO NOT EDIT.\n')
        w('; wi_stuff.c geometry at DOOM\'s own 320x200: x values are 0..319\n')
        w('; (a word where they pass 255); the *H ones are HALVED, for the\n')
        w('; erase boxes (menu.asm mn_sbox works in 160 units).\n')
        w('WI_VRAM      equ $%06X\n' % WI_VRAM_BASE)
        w('WI_BANK      equ $%02X   ; = WI_VRAM >> 12\n' % (WI_VRAM_BASE >> 12))
        w('WI_CHUNKS    equ 0    ; no pixels in the boot stream any more\n')
        w('WIOVL_BANK   equ $%02X   ; the code overlay\'s STAGE 1\n'
          % (WI_VRAM_BASE >> 12))
        w('WI2_BANK     equ $%02X   ; ...and stage 2 behind it\n'
          % ((WI_VRAM_BASE >> 12) + 1))
        w(';   --- the 320x200 SR screen (wi.asm): the surface, its pristine\n')
        w(';       copy, and the world maps in SDRAM (one bank each) ---\n')
        w('WI_SRVRAM    equ $%06X\n' % WI_SR_VRAM)
        w('WI_SRBG      equ $%06X\n' % WI_SR_BG)
        w('WI_SRXDL     equ $%06X   ; the map\'s list, copied along with it\n'
          % (WI_SR_VRAM + pack_menu.SR_XDL_OFF))
        w('WI_WIMCOPY   equ $%04X   ; bytes wi_bgfetch copies per map\n' % WIM_COPY)
        w('WI_MTSR      equ $%06X   ; the melt screen (melt.asm)...\n' % MELT_SR)
        w('WI_MTXOFF    equ $%04X   ; ...its list, in every map bank (SDRAM)\n'
          % WIM_MTXDL)
        w('WI_MTXLEN    equ %d\n' % len(pack_menu._sr_xdl(MELT_SR)))
        w(';   --- the patches, 1:1: the kit and two level-name slots in the\n')
        w(';       pool (wi_kitfetch), out of SDRAM banks from WIMAP_BANK ---\n')
        w('WI_KITVRAM   equ $%06X\n' % KIT_VRAM)
        w('WI_KITLEN    equ %d\n' % kitlen)
        w('WI_KITBK     equ %d      ; bank from WIMAP_BANK: the kit, offset 0\n'
          % len(WIM_EPS))
        w('WI_NAMEBK    equ %d      ; ...the names, NAME_SLOT B each from here\n'
          % (len(WIM_EPS) + 1))
        w('WI_NAMESLOT  equ %d\n' % NAME_SLOT)
        w('WI_NAMESZ    equ %d    ; bytes a name slot takes in VRAM (and is copied)\n'
          % namesz)
        w('WI_LVA       equ $%06X  ; the finished level\'s name\n' % lva)
        w('WI_LVB       equ $%06X  ; the next one\'s\n' % lvb)
        w(';   --- the message line at 320 (strip.asm): its SDRAM bank from\n')
        w(';       WIMAP_BANK, the directory lo/hi/width at +0/+%d/+%d ---\n'
          % (MSG_STRIDE, 2 * MSG_STRIDE))
        w('MSG_BK       equ %d\n' % msgbk)
        w('MSG_STRIDE   equ %d\n' % MSG_STRIDE)
        w('MSG_WMAX     equ %d    ; the widest line, px\n' % msgw)
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
        w('WI_PCTX      equ %d  ; SCREENWIDTH - SP_STATSX\n' % (SCREEN_W - SP_STATSX))
        w('WI_PCTXH     equ %d\n' % ((SCREEN_W - SP_STATSX) // 2))
        w('WI_TIMEX     equ %d\n' % SP_TIMEX)
        w('WI_TIMEY     equ %d\n' % SP_TIMEY)
        w('WI_TIMEVX    equ %d  ; SCREENWIDTH/2 - SP_TIMEX\n' % (SCREEN_W // 2 - SP_TIMEX))
        w('WI_TIMEVXH   equ %d\n' % ((SCREEN_W // 2 - SP_TIMEX) // 2))
        w('WI_PARX      equ %d  ; SCREENWIDTH/2 + SP_TIMEX\n' % (SCREEN_W // 2 + SP_TIMEX))
        w('WI_PARVX     equ %d  ; SCREENWIDTH - SP_TIMEX\n' % (SCREEN_W - SP_TIMEX))
        w('WI_PARVXH    equ %d\n' % ((SCREEN_W - SP_TIMEX) // 2))
        w('WI_NUMW      equ %d   ; WINUM0 width (WI_drawNum step)\n' % numw)
        w('WI_COLONW    equ %d\n' % dims['WICOLON'][0])
        # The "YOU ARE HERE" pointer's OWN erase box, and it is not the
        # percentage field's. WIURH1 shares the box's size and top; only its
        # left differs, and that is per level (wi_yahex below). The box is in
        # 160 units and covers the patch wherever its first pixel falls.
        yw, yh, yl, yt = dims['WIURH0']
        if dims['WIURH1'][:2] != (yw, yh) or dims['WIURH1'][3] != yt:
            sys.exit('  ERROR: WIURH0 and WIURH1 differ in size or top offset --'
                     ' wi_yah erases both with one box')
        w('WI_YAHW      equ %d      ; the erase box, 160 units\n' % ((yw + 1) // 2 + 1))
        w('WI_YAHH      equ %d\n' % yh)
        w('WI_YAHDY     equ %d      ; sr_put draws it at (x-left, y-top)\n' % yt)
        w('WI_ANIMS     equ %d\n' % len(ANIM_LOC))
        w('WI_ANIMF     equ %d\n' % ANIM_FRAMES)
        w('WI_ANIMPER   equ %d   ; TICRATE/3, in DOOM tics\n' % ANIM_PERIOD)
        w(';   --- centred x for the two title lines, per level (pre-computed:\n')
        w(';       V_DrawPatch((SCREENWIDTH - width)/2, ...); all < 256) ---\n')
        w('wi_lvx\n')
        for nm in MAPS:
            lw = dims[LVNAME[nm]][0]
            w('        dta %d    ; %s (%s), %d px wide\n'
              % ((SCREEN_W - lw) // 2, LVNAME[nm], nm, lw))
        w('wi_finx dta %d    ; WIF\n' % ((SCREEN_W - dims['WIF'][0]) // 2))
        w('wi_entx dta %d    ; WIENTER\n' % ((SCREEN_W - dims['WIENTER'][0]) // 2))
        nodes, ebase = [], []
        for nm in MAPS:
            e, mp = epsd_map(nm)
            nodes.append(LNODES[e][mp] if e < len(LNODES) else LNODES[0][mp])
            b = 'E%dM1' % (e + 1)
            ebase.append(MAPS.index(b) if b in MAPS else 0)
        # WI_drawOnLnode's WIURH0/WIURH1 pick rides bit 7 of the x HIGH byte
        # (x < 320, so bit 0 is all it ever needs); the pointer's erase box
        # left edge, in 160 units, is its own table.
        xh, yahex = [], []
        for x, y in nodes:
            pick = yah_pick(wt, x, y)
            xh.append((x >> 8) | (pick << 7))
            yahex.append((x - dims[('WIURH0', 'WIURH1')[pick]][2]) // 2)
        w(';   --- lnodes[episode][map] at full x, as lo/hi: where each level\n')
        w(';       sits on its OWN episode WIMAP (wi_stuff.c:177), indexed by\n')
        w(';       the BUILD level index. wi_nodexh bit 7 = WIURH1 (hangs left) ---\n')
        w('wi_nodexl\n        dta %s\n' % ','.join(str(x & 0xFF) for x, _ in nodes))
        w('wi_nodexh\n        dta %s\n' % ','.join(str(v) for v in xh))
        w('wi_nodey\n        dta %s\n' % ','.join(str(y) for _, y in nodes))
        w(';   --- per level: the pointer\'s erase box left edge, 160 units ---\n')
        w('wi_yahex\n        dta %s\n' % ','.join(str(v) for v in yahex))
        w(';   --- per level: the index of its episode M1 (wi_splats walks\n')
        w(';       lnodes from there, WI_drawShowNextLoc is episode-relative)\n')
        w(';       Episode 1 is the only one with animations packed, and\n')
        w(';       that is exactly "wi_ebase == 0" -- no second table. ---\n')
        w('wi_ebase\n        dta %s\n' % ','.join(str(v) for v in ebase))
        bgm = [WIM_EPS.index(epsd_map(nm)[0] if epsd_map(nm)[0] in WIM_EPS else 0)
               for nm in MAPS]
        w(';   --- per level: which world map its intermission draws on, as\n')
        w(';       a bank from WIMAP_BANK -- wi_bgfetch. ---\n')
        w('wi_bgm\n        dta %s\n' % ','.join(str(v) for v in bgm))
        w(';   --- epsd0animinfo locations (all x < 256) ---\n')
        w('wi_animx\n        dta %s\n' % ','.join(str(x) for x, _ in ANIM_LOC))
        w('wi_animy\n        dta %s\n' % ','.join(str(y) for _, y in ANIM_LOC))
        w(';   --- pars[episode][map] (g_game.c:981), seconds. A BYTE each:\n')
        w(';       E2M6 alone says 360 and clamps to 255 (the stat line shows\n')
        w(';       4:15 for it; a u16 table is not worth the reader rework).\n')
        w('wi_par\n        dta %s\n' % ','.join(str(min(v, 255)) for v in PAR))
    print('wi_syms.inc -> %s' % p)


if __name__ == '__main__':
    if '--levels' in sys.argv:                    # the BUILD's level list --
        arg = sys.argv[sys.argv.index('--levels') + 1]      # build_atr.ps1
        _set_maps([nm.strip().upper() for nm in arg.split(',') if nm.strip()])
    emit()
