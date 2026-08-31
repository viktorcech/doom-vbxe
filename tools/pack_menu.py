#!/usr/bin/env python3
"""DOOM's own menu graphics -> menu.bin / menu.tab, for the title + main menu.

1:1 with m_menu.c, which is easier than it sounds: DOOM's main menu is not TEXT.
Every line is a PATCH (M_NGAME, M_OPTION, ...) and the cursor is the two-frame
skull (M_SKULL1/2), so the port needs no font at all for it -- only the patch
blitter it already has for the HUD.

Geometry, straight out of m_menu.c so the engine can hardcode it:
    MainDef      = { main_end, NULL, MainMenu, M_DrawMainMenu, 97, 64, 0 }
    LINEHEIGHT   = 16          (m_menu.c:129)
    SKULLXOFF    = -32         (m_menu.c:128)
    skull y      = MainDef.y - 5 + itemOn*LINEHEIGHT   (m_menu.c:1802)
    M_DOOM at    (94, 2)       (m_menu.c:858)
    skull blinks every 8 tics  (m_menu.c:1836-1839)
All of those are DOOM's 320-wide pixels; the port draws 160 wide, so the engine
halves x exactly the way this file halves the pixels.

Same encoding as pack_hud.py -- row-major, halved horizontally (one byte = two
DOOM pixels, every second column kept), palette index 0 = transparent.

THE BLOB IS THREE STREAMS, not one, because the menu is on ESC now as well as at
boot (menu.asm) and only the TITLE may live in RAM the game reuses:

  chunk 0..7   TITLEPIC -> $018000, the SPRITE ARENA. Empty until the first
               load_level and re-initialised by arena_init on every load after
               that -- fine for a picture that is only ever shown at boot.
  chunk 8..10  M_DOOM + MainMenu[] + the two skulls -> $00B000, one of the fixed
               4 KB holes the weapon regions freed (memory_map.inc). Nothing a
               level load touches, which is what lets ESC draw the menu at any
               point in the game without re-reading the drive.
  chunk 11     the menu CODE overlay -> $00E000. Written here as zeros;
               tools/split_menu_ovl.py lifts the block out of the XEX after mads
               and patches it in. Reserving the chunk at pack time is what keeps
               MENU_SEC1/MENU_CHUNKS stable across the two make_atr_doom passes.

Each stream starts on a 4 KB chunk boundary so load_menu can point load_vram at
it with nothing but a sector offset and a bank number.

  python tools/pack_menu.py
"""
import os
import re
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                              # noqa: E402
from wadtex import WadTextures                                   # noqa: E402

# The sprite arena. pack_things.POOL_BASE is the same address; nothing lives
# there until load_sprites runs, and the title is gone by then.
MENU_VRAM_BASE = 0x018000
# ...and the PERMANENT half: the M_* patches and the menu code overlay, in the
# fixed 4 KB holes at $00B000 / $00E000 (memory_map.inc's VRAM map). A level load
# never writes there, so the ESC menu needs no SIO at all.
PATCH_VRAM_BASE = 0x00B000
OVL_VRAM_BASE = 0x00E000
CHUNK = 4096                                     # load_vram's unit (32 sectors)
# Two overlay chunks, one VBXE bank each: $00E000 = menu.asm's, $00F000 =
# savegame.asm's. Both are assembled for MENU_RUN ($1000) and only one is ever
# in RAM at a time -- see menu.asm's header.
OVL_PAIR = 2
# ...and a THIRD, automap.asm's, which cannot join them: load_vram streams a run
# of chunks into CONSECUTIVE banks and the bank after $0F is $10 = FRAME_B. So
# it is reserved here, and load_menu points a stream of its own at AMOVL_BANK
# ($17, FRAME_B's dead status-bar rows -- memory_map.inc says why that is free).
OVL_CHUNKS = OVL_PAIR + 1

# ---- the HU STRIPS: every line of text the ENGINE shows (hu_stuff.c) --------
# Two widgets, one array. DOOM's HU_Drawer draws exactly two things:
#   w_title    the level name in the bottom-left of the automap, `if
#              (automapactive)` (hu_stuff.c:491) -- text from mapnames[];
#   w_message  the one-line message across the TOP of the view, whatever
#              P_TouchSpecialThing last parked in player->message, for
#              HU_MSGTIMEOUT (4*TICRATE = 4 s).
# Both use hu_font, i.e. the STCFN* lumps -- the same font _text_line already
# burns the credits page with.
#
# The port has no font at RUNTIME (menu.asm's header: "every line is a patch, so
# no font is needed"), and giving it one would cost a glyph table, a string
# table and a per-character draw loop. So every line is rasterised HERE, one
# strip each, and the engine blits ONE rectangle -- which is the same trade the
# whole menu already makes. The set of lines is closed: nine level names and one
# message per bonus id, so nothing has to be composed at runtime.
#
# The stride is a power of two so strip_blit's address arithmetic is one shift
# pair: strip N lives at TITLE_VRAM + N*1024, i.e. only the MIDDLE address byte
# moves and it moves by 4 per strip (40 strips = $A0, so it cannot carry into
# the bank byte). Widest line is GOTBACKPACK at 121 bytes x 8 rows = 968, so
# 1024 still holds any line that fits the 160-byte screen at all.
TITLE_VRAM_BASE = 0x040000       # memory_map.inc: $040000-$06FFFF is free VRAM
TITLE_STRIDE = 1024
TITLE_H = 8                      # STCFN glyph height, and DOOM's own row count
# hu_stuff.c mapnames, all three episodes; the BUILD's level list picks which
# get a strip (strip index = level index -- automap w_title + the WI screens).
NAMES = {
    'E1M1': 'E1M1: Hangar', 'E1M2': 'E1M2: Nuclear Plant',
    'E1M3': 'E1M3: Toxin Refinery', 'E1M4': 'E1M4: Command Control',
    'E1M5': 'E1M5: Phobos Lab', 'E1M6': 'E1M6: Central Processing',
    'E1M7': 'E1M7: Computer Station', 'E1M8': 'E1M8: Phobos Anomaly',
    'E1M9': 'E1M9: Military Base',
    'E2M1': 'E2M1: Deimos Anomaly', 'E2M2': 'E2M2: Containment Area',
    'E2M3': 'E2M3: Refinery', 'E2M4': 'E2M4: Deimos Lab',
    'E2M5': 'E2M5: Command Center', 'E2M6': 'E2M6: Halls of the Damned',
    'E2M7': 'E2M7: Spawning Vats', 'E2M8': 'E2M8: Tower of Babel',
    'E2M9': 'E2M9: Fortress of Mystery',
    'E3M1': 'E3M1: Hell Keep', 'E3M2': 'E3M2: Slough of Despair',
    'E3M3': 'E3M3: Pandemonium', 'E3M4': 'E3M4: House of Pain',
    'E3M5': 'E3M5: Unholy Cathedral', 'E3M6': 'E3M6: Mt. Erebus',
    'E3M7': 'E3M7: Limbo', 'E3M8': 'E3M8: Dis',
    'E3M9': 'E3M9: Warrens',
    # hu_stuff.c mapnames_commercial (d_englsh.h HUSTR_1..32) -- DOOM II, and
    # what vanilla shows for a PWAD's MAPxx too: the name comes from the IWAD's
    # table, not from the map. Without these, converting any MAPxx WAD died
    # right here on a KeyError with every level already packed. (2026-08-30)
    'MAP01': 'MAP01: Entryway', 'MAP02': 'MAP02: Underhalls',
    'MAP03': 'MAP03: The Gantlet', 'MAP04': 'MAP04: The Focus',
    'MAP05': 'MAP05: The Waste Tunnels', 'MAP06': 'MAP06: The Crusher',
    'MAP07': 'MAP07: Dead Simple', 'MAP08': 'MAP08: Tricks and Traps',
    'MAP09': 'MAP09: The Pit', 'MAP10': 'MAP10: Refueling Base',
    'MAP11': 'MAP11: Circle of Death', 'MAP12': 'MAP12: The Factory',
    'MAP13': 'MAP13: Downtown', 'MAP14': 'MAP14: The Inmost Dens',
    'MAP15': 'MAP15: Industrial Zone', 'MAP16': 'MAP16: Suburbs',
    'MAP17': 'MAP17: Tenements', 'MAP18': 'MAP18: The Courtyard',
    'MAP19': 'MAP19: The Citadel', 'MAP20': 'MAP20: Gotcha!',
    'MAP21': 'MAP21: Nirvana', 'MAP22': 'MAP22: The Catacombs',
    'MAP23': 'MAP23: Barrels o Fun', 'MAP24': 'MAP24: The Chasm',
    'MAP25': 'MAP25: Bloodfalls', 'MAP26': 'MAP26: The Abandoned Mines',
    'MAP27': 'MAP27: Monster Condo', 'MAP28': 'MAP28: The Spirit World',
    'MAP29': 'MAP29: The Living End', 'MAP30': 'MAP30: Icon of Sin',
    'MAP31': 'MAP31: Wolfenstein', 'MAP32': 'MAP32: Grosse',
}
TITLES = tuple(NAMES['E1M%d' % i] for i in range(1, 10))

# ---- one message per BONUS ID, in id order (pack_things.py BONUS) -----------
# The strings are d_englsh.h's, the id -> string pairing is p_inter.c's
# P_TouchSpecialThing switch read through pack_things.py's doomednum -> id map.
# Index 0 is the "no such bonus" slot and is never drawn (give_bonus is never
# called with 0): the engine's strip index is bonus id + MSG_IDX0, so keeping it
# here costs one entry and saves the subtract at every pickup.
#
# WHAT IS NOT HERE, and why:
#   GOTMEDINEED ("...that you REALLY need!") -- vanilla can never print it.
#     p_inter.c:138 tests `player->health < 25` AFTER P_GiveBody(player,25) has
#     already added the 25, so the test cannot be true and SPR_MEDI always ends
#     on GOTMEDIKIT. Faithful means leaving it out.
#   GOTBLUESKUL/GOTYELWSKUL/GOTREDSKULL -- the port gives the card and the skull
#     of a colour ONE bonus id (pack_things BONUS: 5|40 -> 22), because they are
#     the same key bit and the id travels in the sprite table. Episode 1 has no
#     skull keys at all, so the card wording is right for every key in the game;
#     an episode that has them would need the ids split first.
#   GOTMSPHERE (DOOM II) -- no megasphere in episode 1, and no bonus id for it.
MESSAGES = (
    '',                                   # 0: not a bonus
    'Picked up a stimpack.',              # 1  GOTSTIM
    'Picked up a medikit.',               # 2  GOTMEDIKIT
    'Picked up a health bonus.',          # 3  GOTHTHBONUS
    'Supercharge!',                       # 4  GOTSUPER      (soulsphere)
    'Picked up an armor bonus.',          # 5  GOTARMBONUS
    'Picked up the armor.',               # 6  GOTARMOR      (green)
    'Picked up the MegaArmor!',           # 7  GOTMEGA       (blue)
    'Picked up a clip.',                  # 8  GOTCLIP
    'Picked up a box of bullets.',        # 9  GOTCLIPBOX
    'Picked up 4 shotgun shells.',        # 10 GOTSHELLS
    'Picked up a box of shotgun shells.', # 11 GOTSHELLBOX
    'Picked up a rocket.',                # 12 GOTROCKET
    'Picked up a box of rockets.',        # 13 GOTROCKBOX
    'Picked up an energy cell.',          # 14 GOTCELL
    'Picked up an energy cell pack.',     # 15 GOTCELLBOX
    'You got the shotgun!',               # 16 GOTSHOTGUN
    'You got the chaingun!',              # 17 GOTCHAINGUN
    'You got the rocket launcher!',       # 18 GOTLAUNCHER
    'You got the plasma gun!',            # 19 GOTPLASMA
    'You got the BFG9000!  Oh, yes.',     # 20 GOTBFG9000    (doomednum 2006)
    'A chainsaw!  Find some meat!',       # 21 GOTCHAINSAW   (doomednum 2005)
    'Picked up a blue keycard.',          # 22 GOTBLUECARD
    'Picked up a yellow keycard.',        # 23 GOTYELWCARD
    'Picked up a red keycard.',           # 24 GOTREDCARD
    'Picked up a backpack full of ammo!', # 25 GOTBACKPACK
    'Partial Invisibility',               # 26 GOTINVIS
    'Radiation Shielding Suit',           # 27 GOTSUIT
    'Computer Area Map',                  # 28 GOTMAP
    'Light Amplification Visor',          # 29 GOTVISOR
    'Invulnerability!',                   # 30 GOTINVUL
    'Berserk!',                           # 31 GOTBERSERK
    'Picked up a blue skull key.',        # 32 GOTBLUESKUL   (2026-08-31: skulls
    'Picked up a yellow skull key.',      # 33 GOTYELWSKUL    stopped borrowing
    'Picked up a red skull key.',         # 34 GOTREDSKULL    the card ids)
    'A medikit that you REALLY need!',    # 35 GOTMEDINEED -- vanilla tests
                                          # health<25 AFTER the +25
                                          # (p_inter.c:477-480), so ITS line
                                          # never shows; msg_set implements the
                                          # intent (post-add <50 == pre-add
                                          # <25). SHORTENED from d_englsh.h's
                                          # 41 chars: a strip is TITLE_W=128 B
                                          # wide and the full sentence needs
                                          # 143 -- widening the stride doubles
                                          # every strip's VRAM for one line.
)
LEVEL_NAMES = ()                 # set_levels fills it; EPI_FIRST needs it
MSG_IDX0 = len(TITLES) - 1       # strip index of bonus id 1 is MSG_IDX0+1, so
                                 #   the engine's index is (id + MSG_IDX0) and
                                 #   MESSAGES[0] never gets a strip of its own


def set_levels(names):
    """Size the strip array for the BUILD's level list (build_atr.ps1 passes
    --levels). MSG_IDX0 moves with the name count and reaches the engine as a
    menu_syms.inc equ, so hud.asm's `adc #MSG_IDX0` re-numbers itself."""
    global TITLES, MSG_IDX0, LEVEL_NAMES
    # .get, not [] -- a converted WAD may call its maps anything at all, and a
    # map with no entry in hu_stuff.c's tables gets its own name on the strip
    # instead of taking the whole build down (2026-08-30).
    TITLES = tuple(NAMES.get(nm, nm) for nm in names)
    MSG_IDX0 = len(TITLES) - 1
    LEVEL_NAMES = tuple(names)


def _hu_line(wt, text):
    """One line of hu_font text -> (halved bytes, width in bytes). Halved
       horizontally like every other graphic in the port (our byte = 2 DOOM px);
       index 0 is transparent under BLT_BSTENCIL."""
    glyphs = []
    for c in text.upper():                        # HUlib_drawTextLine uppercases
        if c == ' ':
            glyphs.append((None, None, 4))
            continue
        nm = 'STCFN%.3d' % ord(c)
        pat = wt.get_patch(nm)
        if pat is None:
            sys.exit(f'  ERROR: no STCFN glyph for {c!r}')
        glyphs.append((nm, pat, pat[0]))
    lw = sum(adv for _, _, adv in glyphs)
    line = bytearray(lw * TITLE_H)
    x = 0
    for nm, pat, adv in glyphs:
        if pat is not None:
            gw, _gh, cols = pat
            left, top = wt.patch_offset(nm)
            for cx in range(gw):
                for (td, pix) in cols[cx]:
                    for k, c in enumerate(pix):
                        if not c:
                            continue
                        ry, rx = td + k - top, x + cx - left
                        if 0 <= ry < TITLE_H and 0 <= rx < lw:
                            line[ry * lw + rx] = c
        x += adv
    # Halved like every other graphic in the port, but the PHASE is chosen,
    # not assumed. This font has one-pixel stems and one-pixel gaps at 320,
    # so which of the two columns in a pair survives decides whether a
    # letter keeps its stem or its counter -- and the answer is not the same
    # for every line. Keeping the phase with more ink left is a two-line
    # test and visibly better on the short names.
    # (Merging the pair instead -- keep whichever is lit -- was tried and is
    # worse: it fills the one-pixel gaps and the letters run together.)
    hw = (lw + 1) // 2
    best, bestn = bytearray(), -1
    for phase in (0, 1):
        cand = bytearray(hw * TITLE_H)
        for ry in range(TITLE_H):
            for cx in range(hw):
                sx = 2 * cx + phase
                if sx < lw:
                    cand[ry * hw + cx] = line[ry * lw + sx]
        n = sum(1 for b in cand if b)
        if n > bestn:
            best, bestn = cand, n
    return best, hw


def _hu_strips(wt):
    """The whole strip array: the nine level names first (strip index = level),
       then one per bonus id (strip index = id + MSG_IDX0). Every strip is
       left-aligned, padded to the widest of ALL of them -- so the engine needs
       no width table -- and to TITLE_STRIDE, so its address is a shift.
       -> (blob, width in bytes, strip count)"""
    strips, widest = [], 0
    for text in TITLES + MESSAGES[1:]:
        half, hw = _hu_line(wt, text)
        widest = max(widest, hw)
        strips.append((half, hw))
    if widest > 160:                              # SCREEN_WIDTH: a wider line
        sys.exit(f'  ERROR: an HU strip is {widest} B, the screen is 160 -- '
                 f'shorten the line in tools/pack_menu.py')
    blob = bytearray()
    for half, hw in strips:                       # every strip the SAME width, so
        row = bytearray()                         #   the engine needs no table
        for ry in range(TITLE_H):
            r = half[ry * hw:(ry + 1) * hw]
            row += r + bytes(widest - len(r))
        if len(row) > TITLE_STRIDE:
            sys.exit(f'  ERROR: an HU strip is {len(row)} B, stride is '
                     f'{TITLE_STRIDE} -- raise TITLE_STRIDE (and strip_blit\'s '
                     f'shift) in tools/pack_menu.py')
        blob += row + bytes(TITLE_STRIDE - len(row))
    return blob, widest, len(strips)


def _chunks(n):
    return (n + CHUNK - 1) // CHUNK


# READ THIS! -- m_menu.c M_ReadThis. They are streamed ON DEMAND into
# TITLEPIC's own arena slot (same 320x200 -> same 32000 B), so they cost no
# VRAM of their own; menu.asm re-streams TITLEPIC when the reader leaves. No
# menu.tab rows: the engine blits them through the title's fixed geometry
# (rd_tab in menu.asm).
#
# WHICH lumps depends on the IWAD, exactly as it does in m_menu.c -- the
# registered flow is HELP1 then HELP2, the commercial one a single HELP. So ask
# the WAD instead of naming one game's lumps: take the first candidate set that
# is actually in there. `HELP_LUMPS` was ('HELP1', 'HELP2') flat, and a WAD
# without them stopped the build dead ("HELP1 is not in the WAD").
HELP_SETS = (('HELP1', 'HELP2'), ('HELP',), ('CREDIT',))


def help_lumps(wt):
    """The READ THIS! pages this IWAD has, in order. Empty if it has none --
    the reader then has nothing to show, which beats refusing to convert."""
    for names in HELP_SETS:
        if all(wt.get_patch(n) is not None for n in names):
            return names
    return ()


def _read_version():
    """VERSION (repo root) holds the minor number; build_atr.ps1 bumps it
    before this runs. The screen shows V0.<n>."""
    path = os.path.join(os.path.dirname(_HERE), 'VERSION')
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return 1


def _raster_full(pat):
    """patch -> full-resolution byte grid (w x h), 0 = transparent"""
    w, h, cols = pat
    img = bytearray(w * h)
    for cx in range(w):
        for (td, pix) in cols[cx]:
            for k, c in enumerate(pix):
                if 0 <= td + k < h:
                    img[(td + k) * w + cx] = c
    return img, w, h


def _epx2(img, w, h):
    """Scale2x/EPX: pixel-art doubling that rounds the staircases off without
    blurring -- exactly what a magnified 8-pixel font needs."""
    out = bytearray(4 * w * h)
    ow = 2 * w
    for y in range(h):
        up, dn = max(y - 1, 0), min(y + 1, h - 1)
        for x in range(w):
            p = img[y * w + x]
            a = img[up * w + x]                       # above
            d = img[dn * w + x]                       # below
            c = img[y * w + max(x - 1, 0)]            # left
            b = img[y * w + min(x + 1, w - 1)]        # right
            o1 = a if (c == a and c != d and a != b) else p
            o2 = b if (a == b and a != c and b != d) else p
            o3 = c if (d == c and d != b and c != a) else p
            o4 = d if (b == d and b != a and d != c) else p
            i = 2 * y * ow + 2 * x
            out[i], out[i + 1] = o1, o2
            out[i + ow], out[i + ow + 1] = o3, o4
    return out


def _text_line(wt, img, w, h, text, y, scale):
    """burn `text` onto the 160x200 grid with DOOM's own menu font (STCFN*,
    hu_font semantics: V_DrawPatch honours each glyph's left/top offsets --
    that is what keeps '.' and ':' on the BASELINE). The line is rasterised
    1:1 first and blown up with EPX (scale 1, 2 or 4), so the big sizes get
    rounded corners instead of the staircase blocks. Centered on row y."""
    glyphs = []
    for c in text.upper():
        if c == ' ':
            glyphs.append((None, None, 4))
            continue
        nm = 'STCFN%.3d' % ord(c)
        pat = wt.get_patch(nm)
        if pat is None:
            sys.exit(f'  ERROR: no STCFN glyph for {c!r}')
        glyphs.append((nm, pat, pat[0]))
    lw = sum(adv for _, _, adv in glyphs)
    lh = 12                                       # tallest glyph + offset room
    line = bytearray(lw * lh)
    x = 0
    for nm, pat, adv in glyphs:
        if pat is not None:
            gw, gh, cols = pat
            left, top = wt.patch_offset(nm)
            for cx in range(gw):
                for (td, pix) in cols[cx]:
                    for k, c in enumerate(pix):
                        if not c:
                            continue
                        ry = td + k - top
                        rx = x + cx - left
                        if 0 <= ry < lh and 0 <= rx < lw:
                            line[ry * lw + rx] = c
        x += adv
    while scale > 1:
        line = _epx2(line, lw, lh)
        lw, lh = 2 * lw, 2 * lh
        scale //= 2
    x0 = (w - lw) // 2
    for ry in range(lh):
        for rx in range(lw):
            c = line[ry * lw + rx]
            if c and 0 <= y + ry < h and 0 <= x0 + rx < w:
                img[(y + ry) * w + x0 + rx] = c


# The credit block: (text, top row, EPX scale). One table so the layout can be
# nudged in one place -- `python tools/pack_menu.py --preview` renders it.
#
# SIZE (2026-08-13, "je to moc velke, nemoze to byt na celu screen"): this ran
# W1K at scale 4 and everything else at 2, from row 40 down to row 197. Three
# glyphs at scale 4 are ~120 of the 160 columns and the block reached both
# edges of the page, so the screen WAS the text. One step down each (W1K 2, the
# rest 1) leaves it a centred group in the middle half with black all round --
# which is also what it looks like next to DOOM's own two HELP pages, since
# those are full-bleed artwork and this one is not meant to compete with them.
#
# TITLE (2026-08-21, "dalo by sa to zmenit na DOOM VBXE, author: w1k"): the
# headline was the bare handle W1K, so the page named the author and never the
# port. It now names the PORT at scale 2 and the author on a line of its own
# underneath, which is the order a title screen credits in. "DOOM VBXE" is 138
# of the 160 columns at scale 2 -- WIDER than W1K was, but still narrower than
# "CODE: OPUS 4.7, 4.8, 5," (140), so it changes nothing about how far the
# block reaches: the ink still runs cols 10..149. The seventh line costs 24
# rows, so everything below moved down 12 and the title up 10; the block sits
# at rows 30..168, i.e. margins 30/31, as centred as the six-line one was.
#
# The model line is WRAPPED, not shrunk: "CODE: OPUS 4.7, 4.8, 5, FABLE 5" is
# 195 px of the 160 the page has, so it breaks at the comma between the two
# families -- 141 px and 51 px, both with room to spare. The trailing comma is
# kept so the second line reads as the rest of one list rather than a new
# credit. The two halves sit 2 rows apart where every other gap is 4 or more,
# which is what makes them read as one entry.
CREDITS = (('DOOM VBXE',               30, 2),
           ('AUTHOR: W1K',             58, 1),
           ('CODE: OPUS 4.7, 4.8, 5,', 86, 1),
           ('FABLE 5',                102, 1),
           ('2026',                   122, 1),
           ('V0.%s',                  138, 1),      # %s = VERSION
           ('%s',                     162, 1))      # %s = the build stamp


def _credits_page(wt, ver):
    """the third READ THIS! page: black, DOOM's red menu font, the port's
    credit, the build version (VERSION, bumped by build_atr.ps1) and the
    moment this build was packed."""
    import datetime
    w, h = 160, 200
    img = bytearray(w * h)                        # palette 0 = black
    stamp = datetime.datetime.now().strftime('%d.%m.%Y %H:%M')
    fill = {'V0.%s': f'V0.{ver}', '%s': stamp}
    for text, y, scale in CREDITS:
        _text_line(wt, img, w, h, fill.get(text, text), y, scale)
    return img, stamp


def _preview(img, path, w=160, h=200):
    """the credits page as a PNG at the display's 2:1 pixel aspect, so the
    layout can be judged without booting three pages deep into the menu."""
    from PIL import Image
    pp = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures',
                      'playpal.bin')
    pal = open(pp, 'rb').read()
    im = Image.new('RGB', (w, h))
    im.putdata([tuple(pal[c * 3:c * 3 + 3]) for c in img])
    im.resize((w * 4, h * 2), Image.NEAREST).save(path)
    print(f'  credits preview -> {path}')


def _halve(img, w, h):
    """keep every second column, like the emit loop does"""
    hw = (w + 1) // 2
    out = bytearray(hw * h)
    for ry in range(h):
        row = img[ry * w:(ry + 1) * w:2]
        out[ry * hw:ry * hw + len(row)] = row
    return out

# Order IS the engine's index. 0 = the title picture, 1 = the M_DOOM banner,
# 2..7 = MainMenu[] in m_menu.c's own order (m_menu.c:252-258), 8/9 = the skull.
MENU_LUMPS = ('TITLEPIC', 'M_DOOM',
              'M_NGAME', 'M_OPTION', 'M_LOADG', 'M_SAVEG', 'M_RDTHIS', 'M_QUITG',
              'M_SKULL1', 'M_SKULL2')
MI_TITLEPIC, MI_DOOM, MI_FIRST_ITEM, MI_SKULL = 0, 1, 2, 8
N_ITEMS = MI_SKULL - MI_FIRST_ITEM

# ---- the EPISODE menu (m_menu.c EpiDef / M_DrawEpisode) --------------------
# NEW GAME opens it: `M_NewGame` -> `M_SetupNextMenu(&EpiDef)` for every
# non-commercial gamemode, and `M_Init` drops the fourth entry on `registered`,
# which is what this IWAD is. Its own overlay and its own 7-byte rows, because
# menu.tab and the whole menu picker live INSIDE the menu overlay's 1280 B
# window -- the episode screen cannot borrow either.
EPI_LUMPS = ('M_EPISOD', 'M_EPI1', 'M_EPI2', 'M_EPI3')
# ...and its VRAM. Both chunks come off the TOP of the sprite arena
# (memory_map.inc ARENA_SPR_TOP): that arena is a bump cache with a
# flush-when-full (spr_fget), so 12 KB less of it costs a few more flushes on
# the fullest bestiaries and nothing else -- where every other region in the
# VRAM map is a hard reservation. They ride the HU-strip stream's own
# mn_ld_tab row by sitting directly in front of it (mn_ld_tab is 3 bytes from
# full, so a row of their own was never on offer).
EPIOVL_VRAM_BASE = 0x03D000      # the picker's CODE overlay, 1 chunk
EPI_VRAM_BASE = 0x03E000         # ...and the four patches, 2 chunks
EPI_CHUNKS = 3
# EpiDef = { ep_end, &MainDef, EpisodeMenu, M_DrawEpisode, 48, 63, ep1 }
EPI_X, EPI_Y = 48, 63
EPISOD_X, EPISOD_Y = 54, 38      # M_DrawEpisode's own V_DrawPatchDirect

# m_menu.c's numbers, kept here so the .inc and the engine cannot drift apart.
MAIN_X, MAIN_Y = 97, 64
LINEHEIGHT = 16
SKULLXOFF = -32
DOOM_X, DOOM_Y = 94, 2
SKULL_TICS = 8


def emit(wt):
    """menu.bin = the pixels; menu.tab = per lump u24 vram, u8 w, u8 h, i8 left,
    i8 top -- byte for byte the layout hud.tab uses, so the same reader works."""
    blob, tab = bytearray(), bytearray()
    addr = MENU_VRAM_BASE
    sizes, tchunks, rows = [], 0, {}
    for i, nm in enumerate(MENU_LUMPS):
        if i == MI_DOOM:                          # TITLEPIC done -> pad it out to
            blob += bytes(-len(blob) % CHUNK)     # a chunk and start the PERMANENT
            tchunks = len(blob) // CHUNK          # stream at $00B000
            addr = PATCH_VRAM_BASE
        pat = wt.get_patch(nm)
        if pat is None:
            sys.exit(f'  ERROR: {nm} is not in the WAD')
        w, h, cols = pat
        left, top = wt.patch_offset(nm)
        hw = (w + 1) // 2
        img = bytearray(hw * h)                       # 0 = transparent
        for cx in range(0, w, 2):
            for (td, pix) in cols[cx]:
                for k, c in enumerate(pix):
                    if 0 <= td + k < h:
                        img[(td + k) * hw + cx // 2] = c
        blob += img
        row = struct.pack('<HBBBbb', addr & 0xFFFF, (addr >> 16) & 0xFF,
                          hw, h, left // 2, top)
        tab += row
        rows[nm] = row                            # ...and keep it: the episode
        sizes.append((nm, hw, h, len(img)))       #   picker has no menu.tab
        addr += len(img)
    blob += bytes(-len(blob) % CHUNK)             # patches -> whole chunks too
    pchunks = len(blob) // CHUNK - tchunks
    blob += bytes(CHUNK * OVL_CHUNKS)             # ...and the overlay's placeholder

    # --- the READ THIS! pages, one 8-chunk page each, after the overlay ------
    helps = help_lumps(wt)
    if not helps:
        print('  note: no READ THIS! pages in this WAD (looked for '
              + ', '.join('/'.join(s) for s in HELP_SETS) + ')')
    for nm in helps:
        pat = wt.get_patch(nm)
        img, w, h = _raster_full(pat)
        half = _halve(img, w, h)
        blob += half
        blob += bytes(-len(blob) % CHUNK)
        sizes.append((nm, (w + 1) // 2, h, len(half)))
    ver = _read_version()
    page3, stamp = _credits_page(wt, ver)         # ...and the credits page
    blob += page3
    blob += bytes(-len(blob) % CHUNK)
    shown = ' / '.join(t.replace('V0.%s', f'V0.{ver}').replace('%s', stamp)
                       for t, _y, _s in CREDITS)   # from the table, so the log
    sizes.append((f'CREDITS "{shown}"',            #   cannot drift off the page
                  160, 200, len(page3)))
    # --- the EPISODE menu, then the HU strips: ONE consecutive bank run and
    #     therefore one mn_ld_tab row (menu.asm's table is 3 bytes from full).
    #     The run starts at EPIOVL_VRAM_BASE and the strips still land on
    #     TITLE_VRAM_BASE, because the episode chunks are exactly the gap.
    lvch = len(blob) // CHUNK
    blob += bytes(CHUNK)                          # the picker's overlay chunk,
                                                  #   filled by split_menu_ovl.py
    etab = bytearray()
    eaddr = EPI_VRAM_BASE
    for nm in EPI_LUMPS + ('M_SKULL1', 'M_SKULL2'):
        pat = wt.get_patch(nm)
        if pat is None:
            sys.exit(f'  ERROR: {nm} is not in the WAD')
        w, h, cols = pat
        left, top = wt.patch_offset(nm)
        hw = (w + 1) // 2
        if nm in EPI_LUMPS:                       # the skulls are already in the
            img = bytearray(hw * h)               #   patch stream -- only their
            for cx in range(0, w, 2):             #   ROWS are copied here, so the
                for (td, pix) in cols[cx]:        #   picker can point hud_blit at
                    for k, c in enumerate(pix):   #   them without menu.tab
                        if 0 <= td + k < h:
                            img[(td + k) * hw + cx // 2] = c
            blob += img
            sizes.append((nm, hw, h, len(img)))
            a = eaddr
            eaddr += len(img)
            etab += struct.pack('<HBBBbb', a & 0xFFFF, (a >> 16) & 0xFF,
                                hw, h, left // 2, top)
        else:
            etab += rows[nm]                      # the skull is already packed
    if eaddr > EPI_VRAM_BASE + (EPI_CHUNKS - 1) * CHUNK:
        sys.exit('  ERROR: the episode patches are %d B, the reserve is %d'
                 % (eaddr - EPI_VRAM_BASE, (EPI_CHUNKS - 1) * CHUNK))
    blob += bytes(-len(blob) % CHUNK)
    if len(blob) // CHUNK - lvch != EPI_CHUNKS:
        sys.exit('  ERROR: the episode run is %d chunks, EPI_CHUNKS says %d'
                 % (len(blob) // CHUNK - lvch, EPI_CHUNKS))
    hu, tw, nstrips = _hu_strips(wt)
    blob += hu
    blob += bytes(-len(blob) % CHUNK)
    lvchunks = len(blob) // CHUNK - lvch
    sizes.append((f'HU x{nstrips}', tw, TITLE_H, len(hu)))
    # --- the INTERMISSION screen (tools/pack_wi.py), same deal as the strips:
    #     map-independent, so it rides the boot stream into free VRAM. Its CODE
    #     overlay is the chunk right behind the pixels -- one consecutive bank
    #     run, hence one mn_ld_tab row, which is all menu.asm has room for.
    wich = len(blob) // CHUNK
    wi = open(os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'wi',
                           'wi.bin'), 'rb').read()
    blob += wi
    blob += bytes(-len(blob) % CHUNK)
    wi_ovl_ch = len(blob) // CHUNK                # FOUR overlay placeholders:
    blob += bytes(4 * CHUNK)                      #   wi stage 1 (MENU_RUN), wi
                                                  #   stage 2 (the map slot), and
                                                  #   the FINALE's own two -- it
                                                  #   is split the same way, and
                                                  #   for the same reason: 1280 B
                                                  #   at MENU_RUN does not hold a
                                                  #   typewriter AND a scroller.
    # ...and the finale's resident assets (tools/pack_fin.py): the three flats,
    # the hu_font cells and the three story texts. In the same bank run so it is
    # still one mn_ld_tab row. The four PAGES are not here -- 38 chunks would
    # walk the boot stream through FRAME_C -- they are finpic.bin, its own ATR
    # region, streamed into the sprite arena on demand (make_atr_doom.py).
    fin = open(os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'fin',
                            'fin.bin'), 'rb').read()
    fin_ch = len(blob) // CHUNK
    blob += fin
    blob += bytes(-len(blob) % CHUNK)
    wichunks = len(blob) // CHUNK - wich
    sizes.append(('WI intermission (+4 ovl chunks)', 160, 200, len(wi)))
    sizes.append(('finale assets (flats+font+texts)', 0, 0, len(fin)))
    return (blob, tab, addr, sizes, tchunks, pchunks, lvch, lvchunks, tw,
            nstrips, wich, wichunks, wi_ovl_ch, fin_ch, etab)


def _wi_bank():
    """WI_BANK out of the wi_syms.inc pack_wi.py just wrote. The finale's banks
    are the next ones along the same run, so they have to follow it."""
    p = os.path.join(os.path.dirname(_HERE), 'wi_syms.inc')
    m = re.search(r'^WI_BANK\s+equ\s+\$([0-9A-Fa-f]+)', open(p).read(),
                  re.MULTILINE)
    if not m:
        sys.exit('  ERROR: WI_BANK is not in wi_syms.inc -- run pack_wi.py first')
    return int(m.group(1), 16)


def emit_inc(path, tchunks, pchunks, lvch, lvchunks, tw, nstrips,
             wich, wichunks, wi_ovl_ch, fin_ch):
    """menu_syms.inc -- m_menu.c's geometry, halved where the port is halved."""
    with open(path, 'w') as f:
        f.write('; AUTO-GENERATED by tools/pack_menu.py -- DO NOT EDIT.\n'
                '; m_menu.c geometry. x values are HALVED (the port draws 160\n'
                '; wide where DOOM draws 320); y values are DOOM\'s own.\n')
        f.write(f'MENU_VRAM    equ ${MENU_VRAM_BASE:06X}\n')
        f.write(f'MI_TITLEPIC  equ {MI_TITLEPIC}\n')
        f.write(f'MI_DOOM      equ {MI_DOOM}\n')
        f.write(f'MI_ITEM0     equ {MI_FIRST_ITEM}    ; MainMenu[] (m_menu.c:252)\n')
        f.write(f'MI_SKULL     equ {MI_SKULL}    ; +1 = the second blink frame\n')
        f.write(f'MENU_NITEMS  equ {N_ITEMS}\n')
        f.write(f'MENU_X       equ {MAIN_X // 2}   ; MainDef.x {MAIN_X} halved\n')
        f.write(f'MENU_Y       equ {MAIN_Y}\n')
        f.write(f'MENU_LINEH   equ {LINEHEIGHT}\n')
        f.write(f'MENU_SKULLX  equ {(MAIN_X + SKULLXOFF) // 2}   ; x+SKULLXOFF, halved\n')
        f.write(f'MENU_SKULLY  equ {MAIN_Y - 5}   ; MainDef.y - 5 (m_menu.c:1802)\n')
        f.write(f'MENU_DOOMX   equ {DOOM_X // 2}\n')
        f.write(f'MENU_DOOMY   equ {DOOM_Y}\n')
        f.write(f'MENU_SKTICS  equ {SKULL_TICS}   ; skullAnimCounter (m_menu.c:1839)\n')
        f.write('; --- the three streams inside menu.bin (load_menu drives them) ---\n')
        f.write(f'MENU_TCHUNKS equ {tchunks}    ; TITLEPIC, 4 KB chunks\n')
        f.write(f'MENU_TBANK   equ ${MENU_VRAM_BASE >> 12:02X}   ; ...into VBXE bank\n')
        f.write(f'MENU_PCHUNKS equ {pchunks}    ; the M_* patches\n')
        f.write(f'MENU_PBANK   equ ${PATCH_VRAM_BASE >> 12:02X}\n')
        f.write(f'MENU_OCHUNKS equ {OVL_PAIR}    ; the menu + savegame CODE overlays\n')
        f.write(f'MENU_OBANK   equ ${OVL_VRAM_BASE >> 12:02X}\n')
        f.write(f'MENU_OVL_OFF equ {(tchunks + pchunks) * CHUNK}  ; its byte offset in menu.bin\n')
        f.write(f'MENU_ACHUNK  equ {tchunks + pchunks + OVL_PAIR}   ; the AUTOMAP overlay: a\n'
                '                        ; stream of its own, into AMOVL_BANK\n')
        f.write(f'MENU_OVL_N   equ {OVL_CHUNKS}    ; overlay chunks RESERVED here in total\n'
                '                        ; (split_menu_ovl.py checks its list against this)\n')
        f.write('; --- READ THIS! (mn_readthis): HELP1/HELP2, streamed into the title slot\n')
        f.write(f'MENU_HCHUNKS equ {tchunks}    ; one page = the title page\'s size\n')
        f.write(f'MENU_HELP_CH equ {tchunks + pchunks + OVL_CHUNKS}   ; HELP1\'s chunk offset in menu.bin\n')
        f.write('; --- the HU STRIPS (hu_stuff.c HU_Drawer): the nine automap\n'
                ';     level names first, then one message per BONUS ID. One\n'
                ';     strip each, TITLE_STRIDE apart, into the free VRAM at\n'
                ';     $040000 (memory_map.inc); strip_blit draws one rectangle.\n')
        f.write(f'MENU_LVCH    equ {lvch}   ; their chunk offset in menu.bin\n')
        f.write(f'MENU_LVCHUNKS equ {lvchunks}\n')
        w = f.write
        w('; --- the EPISODE menu (m_menu.c EpiDef / M_DrawEpisode): THREE\n')
        w(';     chunks in FRONT of the strips, same run and so the same\n')
        w(';     mn_ld_tab row (that table is 3 bytes from full). The picker\n')
        w(';     CODE overlay, then the four M_EPI* patches. Both come off\n')
        w(';     the TOP of the sprite arena (ARENA_SPR_TOP): that arena is a\n')
        w(';     bump cache with a flush-when-full, so 12 KB less of it costs\n')
        w(';     a few more flushes and nothing else -- every other region in\n')
        w(';     the VRAM map is a hard reservation.\n')
        w(f'MENU_LVBANK  equ ${EPIOVL_VRAM_BASE >> 12:02X}   ; the RUN first bank\n')
        w(f'EPIOVL_BANK  equ ${EPIOVL_VRAM_BASE >> 12:02X}   ; ...which IS the picker overlay\n')
        w(f'EPI_VRAM     equ ${EPI_VRAM_BASE:06X}\n')
        w(f'EPI_CHUNKS   equ {EPI_CHUNKS}\n')
        w(f'EPI_N        equ {len(EPI_LUMPS) - 1}    ; items M_EPI1..3 -- M_Init drops the\n')
        w('                        ;   fourth one on `registered`\n')
        w('EPI_I_TITLE  equ 0    ; epi.tab rows: M_EPISOD, M_EPI1..3, then\n')
        w('EPI_I_ITEM0  equ 1    ;   the two skull frames\n')
        w(f'EPI_I_SKULL  equ {len(EPI_LUMPS)}\n')
        w(f'EPI_X        equ {EPI_X // 2}   ; EpiDef.x {EPI_X} halved\n')
        w(f'EPI_Y        equ {EPI_Y}\n')
        w(f'EPI_SKULLX   equ {(EPI_X + SKULLXOFF) // 2}    ; x + SKULLXOFF, halved\n')
        w(f'EPI_SKULLY   equ {EPI_Y - 5}   ; m_menu.c:1802\n')
        w(f'EPI_TITLEX   equ {EPISOD_X // 2}   ; M_EPISOD at ({EPISOD_X},{EPISOD_Y})\n')
        w(f'EPI_TITLEY   equ {EPISOD_Y}\n')
        w('; the LEVEL INDEX each episode starts on, out of the build own disk\n')
        w('; order -- G_InitNew(skill, epi+1, 1).\n')
        for _e in range(1, len(EPI_LUMPS)):
            _nm = 'E%dM1' % _e
            w('EPI_FIRST%d   equ %d    ; %s\n'
              % (_e, LEVEL_NAMES.index(_nm) if _nm in LEVEL_NAMES else 0, _nm))
        f.write(f'TITLE_VRAM   equ ${TITLE_VRAM_BASE:06X}\n')
        f.write(f'TITLE_BANK   equ ${TITLE_VRAM_BASE >> 12:02X}\n')
        f.write(f'TITLE_STRIDE equ {TITLE_STRIDE}\n')
        f.write(f'TITLE_W      equ {tw}   ; bytes, the widest line (all padded to it)\n')
        f.write(f'TITLE_H      equ {TITLE_H}\n')
        f.write('TITLE_Y      equ 159   ; hu_stuff.c HU_TITLEY = 167 - font height\n')
        f.write(f'HU_NSTRIPS   equ {nstrips}   ; level names + messages\n')
        f.write(f'MSG_IDX0     equ {MSG_IDX0}    ; strip index of a message = bonus id + this\n')
        f.write(f'MSG_N        equ {len(MESSAGES) - 1}   ; bonus ids 1..N have one\n')
        f.write('MSG_Y        equ 0    ; hu_stuff.c HU_MSGY: the top of the view\n')
        f.write('; --- the INTERMISSION (wi_stuff.c, tools/pack_wi.py): the WI\n'
                ';     patches into free VRAM at WI_VRAM, with the wi.asm CODE\n'
                ';     overlay in the chunk right behind them, so ONE mn_ld_tab\n'
                ';     row streams both (WI_CHUNKS+1 consecutive banks).\n')
        f.write(f'MENU_WICH    equ {wich}   ; its chunk offset in menu.bin\n')
        f.write(f'MENU_WICHUNKS equ {wichunks}   ; pixels + table + 2 overlay chunks\n')
        f.write(f'WI_OVL_OFF   equ {wi_ovl_ch * CHUNK}  ; stage 1\'s byte offset in menu.bin\n')
        f.write(f'WI_OVL2_OFF  equ {(wi_ovl_ch + 1) * CHUNK}  ; ...and stage 2\'s\n')
        f.write('; --- the end-of-episode FINALE (f_finale.c, f_finale.asm +\n'
                ';     tools/pack_fin.py). Two CODE chunks behind the WI pair,\n'
                ';     then its resident assets -- all inside the same MENU_WICH\n'
                ';     bank run, so it still costs no mn_ld_tab row (that table\n'
                ';     has none left). The four PAGES are NOT here: they are\n'
                ';     finpic.bin at FIN_SEC1, streamed on demand.\n')
        f.write(f'FIN_OVL_OFF  equ {(wi_ovl_ch + 2) * CHUNK}  ; finale stage 1\'s byte offset\n')
        f.write(f'FIN_OVL2_OFF equ {(wi_ovl_ch + 3) * CHUNK}  ; ...and stage 2\'s\n')
        # WI_BANK is where this whole consecutive run lands, and pack_wi.py
        # COMPUTES it (it drifts up as the HU strips grow), so read it back
        # rather than recomputing -- importing pack_wi here would be circular,
        # it already imports this module for TITLE_STRIDE.
        fin_bank = _wi_bank() + fin_ch - wich
        f.write(f'FINOVL_BANK  equ ${fin_bank - 2:02X}   ; VBXE bank of stage 1\n')
        f.write(f'FIN2_BANK    equ ${fin_bank - 1:02X}   ; ...stage 2\n')
        f.write(f'FIN_BANK     equ ${fin_bank:02X}   ; ...and of the resident assets\n')
        f.write(f'FIN_VRAM     equ ${fin_bank << 12:06X}\n')


def main():
    if '--levels' in sys.argv:
        arg = sys.argv[sys.argv.index('--levels') + 1]
        set_levels([nm.strip().upper() for nm in arg.split(',') if nm.strip()])
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if '--levels' in sys.argv:                    # drop --levels' VALUE too
        args = [a for a in args
                if a != sys.argv[sys.argv.index('--levels') + 1]]
    wad = args[0] if args else DEFAULT_WAD
    wt = WadTextures(Wad(wad))
    if '--preview' in sys.argv:
        out = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'menu')
        os.makedirs(out, exist_ok=True)
        page, _ = _credits_page(wt, _read_version())
        _preview(page, os.path.join(out, 'credits.png'))
        return
    (blob, tab, end, sizes, tchunks, pchunks, lvch, lvchunks, tw, nstrips,
     wich, wichunks, wi_ovl_ch, fin_ch, etab) = emit(wt)
    out = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'menu')
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'menu.bin'), 'wb').write(blob)
    open(os.path.join(out, 'menu.tab'), 'wb').write(tab)
    open(os.path.join(out, 'epi.tab'), 'wb').write(etab)
    emit_inc(os.path.join(os.path.dirname(_HERE), 'menu_syms.inc'), tchunks,
             pchunks, lvch, lvchunks, tw, nstrips, wich, wichunks, wi_ovl_ch,
             fin_ch)
    for nm, w, h, n in sizes:
        print(f'  {nm:9} {w:3}x{h:3} = {n:6} B')
    print(f'menu.bin {len(blob)} B = {len(blob)//CHUNK} chunks '
          f'(title {tchunks} -> ${MENU_VRAM_BASE:06X}, patches {pchunks} -> '
          f'${PATCH_VRAM_BASE:06X} ..${end:06X}, overlay {OVL_CHUNKS} -> '
          f'${OVL_VRAM_BASE:06X}), menu.tab {len(tab)} B ({len(tab)//7} lumps) -> {out}')
    print('  wrote menu_syms.inc')


if __name__ == '__main__':
    main()
