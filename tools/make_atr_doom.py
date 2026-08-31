#!/usr/bin/env python3
"""Build a BOOTABLE ATR: custom boot loader + doom_bsp.xex + episode-1 maps.

Booting FROM this ATR cold-starts the Atari OS properly (valid VIMIRQ + serial
IRQ vectors), so the engine's own SIO level streaming (load_level) works.
Running the bare XEX without a clean OS boot left VIMIRQ pointing into RAM
(-> BRK on every IRQ -> SIO hang). Mirrors woll3d's bootable-ATR approach.

Level handling is the SAME as woll3d (src/diskio.asm + atr_layout.inc): all
levels are padded to a common LVL_SECTORS and laid out at a FIXED stride, so the
engine finds level n at  base_sec = LVL_SEC1 + n*LVL_SECTORS  (no per-level
directory needed). LVL_SEC1/LVL_SECTORS/NUM_LEVELS are emitted as MADS equ in
`atr_layout.inc`.

Layout (single density, 128-byte sectors):
  sectors 1..3       boot.bin       (boot loader -> $0700, parses + runs the XEX)
  sectors 4..        doom_bsp.xex   (the engine)
  sector  LVL_SEC1.. level slots, each LVL_SECTORS sectors (padded), level n at
                     LVL_SEC1 + n*LVL_SECTORS
  padded to a standard 720-sector SD floppy.

LVL_SEC1 is FIXED (the XEX gets a reserved window, sectors 4..159), so
atr_layout.inc does NOT depend on the XEX size -> single-pass build.

Usage:
  python tools/make_atr_doom.py --dir [E1M1 ...]   # emit atr_layout.inc only (BEFORE building the XEX)
  python tools/make_atr_doom.py [E1M1 ...]         # build the bootable ATR (needs boot.bin + doom_bsp.xex)
"""
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJ = os.path.dirname(_HERE)
WADMAPS = os.path.join(_PROJ, 'build', 'assets', 'wadmaps')
BOOT_BIN = os.path.join(_PROJ, 'build', 'boot.bin')
XEX = os.path.join(_PROJ, 'build', 'doom_bsp.xex')
OUT_ATR = os.path.join(_PROJ, 'build', 'doom.atr')
OUT_INC = os.path.join(_PROJ, 'atr_layout.inc')

SECTOR_SIZE = 128
ATR_SIGNATURE = 0x0296
BOOT_SECTORS = 3
XEX_SEC = BOOT_SECTORS + 1           # XEX starts at sector 4
# (MAP_SLOT_END lived here: load_level's $8600 ceiling. Dead since 2026-07-31 --
#  nothing read it, and the slot ends at $4C00 now. pack_map.py LOW_LIMIT is the
#  live constant, and it is the one that fails the pack.)
LVL_SEC1 = 448                       # FIXED: XEX window = sectors 4..447 (~55.5 KB).
                                     # 2026-08-20: was 384 (380 sectors) with
                                     # FIFTY BYTES to spare, and the boss work
                                     # -- A_SpidRefire, A_BossDeath off the last
                                     # death frame, PIT_RadiusAttack's boss
                                     # exemption and the rocket's A_Explode --
                                     # made it 381. Went to 444 sectors rather
                                     # than to 381: the cost is 8 KB of a 4.8 MB
                                     # image and the last three raises were each
                                     # ONE sector short.
                                     # MEASURE THE SPLIT XEX, not the assembled
                                     # one: mads writes 388 sectors and step 3a
                                     # (split_menu_ovl.py) takes the menu overlay
                                     # back out, which is the 369 that ships.
                                     # 2026-07-30: was 224 (220 sectors) and the
                                     # death-animation code pushed the XEX to 221.
                                     # 2026-07-31: was 256 (252 sectors); A_Chase's
                                     # attack half made it 253. Given how steadily
                                     # this creeps, the window went to 380 sectors
                                     # rather than to the next 4 -- the cost is
                                     # 16 KB of ATR against a 4.8 MB image.
                                     # Raised from 128 when the engine passed 15.8 KB,
                                     # and from 192 when the view-size code (viewsize.asm)
                                     # pushed it to 189 sectors -- one over the old
                                     # window. The window is reserved, so growing it only
                                     # moves the level slots further down the ATR.
FLOPPY_SECTORS = 720

E1 = [f'E1M{i}' for i in range(1, 10)]


def _sectors(n):
    return (n + SECTOR_SIZE - 1) // SECTOR_SIZE


def lvl_sectors(names):
    """Common stride = max sectors over all included levels (woll3d pads all the
    same; here the slot is sized to the biggest so every level fits its slot)."""
    return max(_sectors(os.path.getsize(os.path.join(WADMAPS, nm + '.bin'))) for nm in names)


TEX_DIR = os.path.join(_PROJ, 'build', 'assets', 'textures')
CHUNK_SECTORS = 32                    # 4 KB per VBXE bank = 32 x 128-byte sectors
# SAVE GAME: DOOM's six slots (m_menu.c load_end = 6). One slot holds the header
# sector plus every region savegame.asm's sg_tab snapshots; 104 sectors = 13 KB
# leaves room for the format to grow without moving the region.
SAVE_SLOTS = 6
SAVE_SECTORS = 104


def tex_sectors(names):
    """Sectors for the largest map's .tex, rounded UP to a whole number of 4KB
    chunks so load_textures reads exactly TEX_CHUNKS*32 sectors (never past the
    slot). All levels padded to this common stride."""
    m = max((_sectors(os.path.getsize(os.path.join(TEX_DIR, nm + '.tex')))
             for nm in names if os.path.exists(os.path.join(TEX_DIR, nm + '.tex'))),
            default=0)
    return ((m + CHUNK_SECTORS - 1) // CHUNK_SECTORS) * CHUNK_SECTORS


THINGS_DIR = os.path.join(_PROJ, 'build', 'assets', 'things')


def _thing_files(names):
    """(spr stride in whole 4KB chunks, things/dtab/los/sprcol strides in
    sectors)."""
    spr = max((_sectors(os.path.getsize(os.path.join(THINGS_DIR, nm + '.spr')))
               for nm in names
               if os.path.exists(os.path.join(THINGS_DIR, nm + '.spr'))), default=0)
    spr = ((spr + CHUNK_SECTORS - 1) // CHUNK_SECTORS) * CHUNK_SECTORS
    thg = max((_sectors(os.path.getsize(os.path.join(THINGS_DIR, nm + '.things')))
               for nm in names
               if os.path.exists(os.path.join(THINGS_DIR, nm + '.things'))), default=0)
    dtb = max((_sectors(os.path.getsize(os.path.join(THINGS_DIR, nm + '.dtab')))
               for nm in names
               if os.path.exists(os.path.join(THINGS_DIR, nm + '.dtab'))), default=0)
    los = max((_sectors(os.path.getsize(os.path.join(THINGS_DIR, nm + '.los')))
               for nm in names
               if os.path.exists(os.path.join(THINGS_DIR, nm + '.los'))), default=0)
    scl = max((_sectors(os.path.getsize(os.path.join(THINGS_DIR, nm + '.sprcol')))
               for nm in names
               if os.path.exists(os.path.join(THINGS_DIR, nm + '.sprcol'))), default=0)
    return spr, thg, dtb, los, scl


HUD_BIN = os.path.join(_PROJ, 'build', 'assets', 'hud', 'hud.bin')
# The title/menu graphics (tools/pack_menu.py). Streamed into the VRAM pool
# base at boot -- that pool is empty until the first load_level, which is
# exactly why the menu costs no main RAM. Parked LAST on the disk so adding
# it shifts no existing region's sector numbers.
MENU_BIN = os.path.join(_PROJ, 'build', 'assets', 'menu', 'menu.bin')
# The end-of-episode FINALE's PAGES (tools/pack_fin.py): HELP2, VICTORY2, PFUB1,
# PFUB2 and the seven END letters. Its small half -- hu_font, the three flats and
# the three story texts -- is fin.bin, and that one rides menu.bin's boot stream
# instead (pack_menu.py appends it); only these 150 KB of pictures need a region,
# because 38 chunks of boot stream would walk straight through FRAME_C. Behind
# the menu, ahead of the music: a new region there shifts nothing before it.
# Every section inside is chunk-aligned, so the engine streams one page at a time
# into the sprite arena, the way mn_readthis already streams the HELP pages.
FIN_BIN = os.path.join(_PROJ, 'build', 'assets', 'fin', 'finpic.bin')
# The songs, pre-played into a stream of POKEY register writes at build time
# (tools/pack_musstream.py). Behind the menu for the same reason the menu is
# last: adding it shifts nothing that came before.
MUS_BIN = os.path.join(_PROJ, 'build', 'assets', 'music', 'music.stream')
PAL_BIN = os.path.join(TEX_DIR, 'playpal.bin')
SND_BIN = os.path.join(_PROJ, 'build', 'assets', 'sounds', 'sounds.bin')
WEAP_BIN = os.path.join(_PROJ, 'build', 'assets', 'weap', 'weap.bin')
# The light table (tools/pack_cmap.py). It is map-independent and 8 KB = exactly
# two 4 KB chunks, so it is laid down right BEHIND the weapon master and read by
# the same load_weapons chunk walk (WEAP_CHUNKS covers both). A loader of its own
# would have cost ~30 B of base RAM, and there are 179 B left in the whole
# machine -- see the RAM-BUDGET block in memory_map.inc.
CMAP_BIN = os.path.join(_PROJ, 'build', 'assets', 'cmap.bin')
WEAP_EXT = 0x040000                   # weap_tables.inc: the master's SRAM base

# ---- the per-level VRAM pool (2026-08-03, _navrh_vram.txt T3) ---------------
# Textures + sprites share $018000..$070000: level n's .tex streams to
# POOL_BASE, its .spr to the first 4 KB chunk above it. The split is emitted
# per level into atr_levels.inc (LVL_TEXCH/LVL_SPRBK/LVL_SPRCH -- what
# load_textures/load_sprites index with current_level), and the sprite base
# is CROSS-CHECKED against the {map}.sprmeta sidecar pack_things.py wrote:
# the addresses inside .spr/.things/.dtab are baked with that base, so a
# re-packed .tex with a stale pack_things run must fail the build here.
POOL_BASE = 0x018000
POOL_TOP = 0x070000                   # TEX8 scratch, then the weapon slot
LEVELS_INC = os.path.join(_PROJ, 'atr_levels.inc')


def emit_levels_inc(names, spr_sec1, spr_stride, pre1_base,
                    tex_sec1=0, tex_stride=0, pool_sec=0,
                    sprpool_sec=0, sprpool_len=0):
    """atr_levels.inc, B2 form (2026-08-18): both pools are SHARED, so the old
    per-level tables (LVL_TEXCH/LVL_SPRCH/LVL_SPRSD/LVL_TEXSD) collapsed to
    two equs -- the pools' SDRAM homes. arena_init loads them immediate and
    load_sprites is a no-op (the sprite pool streams inside load_textures'
    POOL region drain), which is what lets NUM_LEVELS grow past 9 without the
    WEAPLD2 block ($8400, 131 B) ever growing again -- the 10th level's +8
    table bytes are what ran it into PJHK_BASE.
    The per-level .sprmeta sidecars still gate staleness: each carries the
    pool size pack_things saw when it wrote that level's FTAB."""
    if not (pool_sec and sprpool_len):
        sys.exit('emit_levels_inc: non-pooled builds died with B2 '
                 '(2026-08-18) -- pack_textures must write pool.tex and '
                 'pack_things sprpool.bin first')
    for nm in names:
        mp = os.path.join(THINGS_DIR, nm + '.sprmeta')
        if not os.path.exists(mp):
            sys.exit(f'{nm}: no .sprmeta sidecar -- run tools/pack_things.py '
                     f'{nm}')
        spr_len = int(open(mp).read().split()[0])
        if spr_len != sprpool_len:
            sys.exit(f'{nm}: .sprmeta says pool {spr_len} B but sprpool.bin '
                     f'is {sprpool_len} B -- re-run tools/pack_things.py with '
                     f'the FULL level list (a stale FTAB would hand spr_fget '
                     f'offsets into the wrong pool)')
    texsd = 0x080000 + (pool_sec - LVL_SEC1) * SECTOR_SIZE
    sprsd = 0x080000 + (sprpool_sec - LVL_SEC1) * SECTOR_SIZE
    with open(LEVELS_INC, 'w') as f:
        f.write('; AUTO-GENERATED by tools/make_atr_doom.py -- do not edit.\n')
        f.write('; B2 (2026-08-18): both pools are SHARED between levels --\n')
        f.write('; these equs are their Rapidus SDRAM homes. The per-level\n')
        f.write('; loader tables are gone: arena_init loads the constants\n')
        f.write('; immediate, load_sprites is a no-op.\n')
        f.write(f'LVL_TEXSD_C  equ ${texsd:06X}    '
                f'; pool.tex home ({len(names)} level(s))\n')
        f.write(f'LVL_SPRSD_C  equ ${sprsd:06X}    ; sprpool.bin home\n')
    print(f'  wrote {os.path.relpath(LEVELS_INC, _PROJ)}  ({len(names)} '
          f'level(s); shared pools, equ-only)')
    return None


def emit_inc(names, stride, tex_sec1, tex_stride, pool_sec=0, pool_secs=0,
             dir_sec=0, idx_sec=0, idx_stride=0, pool_n=0,
             spr_sec1=0, spr_stride=0, thg_sec1=0, thg_stride=0,
             dtb_sec1=0, dtb_stride=0, los_sec1=0, los_stride=0,
             sprc_sec1=0, sprc_stride=0,
             hud_sec1=0, hud_chunks=0, snd_chunks=0, weap_sec1=0, weap_chunks=0,
             pal_count=1, cmap_chunks=0, cmap_ext=0,
             menu_sec1=0, menu_chunks=0, mus_sec1=0, mus_chunks=0,
             save_sec1=0, fin_sec1=0, fin_chunks=0):
    tex_chunks = tex_stride // CHUNK_SECTORS      # tex_stride is a whole multiple of 32
    # (The old fixed-slot assert died with the pool split: per-level tex+spr
    # bounds are enforced in emit_levels_inc, against the SAME .tex bytes the
    # loaders will actually stream.)
    with open(OUT_INC, 'w') as f:
        f.write('; AUTO-GENERATED by tools/make_atr_doom.py -- do not edit.\n')
        f.write('; RAM BUDGET: see the RAM-BUDGET block at the top of memory_map.inc, or run' + chr(10))
        f.write('; `python tools/ram_map.py`. Some RAM looks free to MADS and is NOT ($B000' + chr(10))
        f.write('; TEX_STAGE, $4000 map slot, $9000 MEMAC window): code assembled there is' + chr(10))
        f.write('; overwritten at runtime with no error and boots to a flat pink screen.' + chr(10))
        f.write('; Level layout on the bootable ATR (woll3d-style fixed stride):\n')
        f.write(';   level n at sector LVL_SEC1 + n*LVL_SECTORS, read by load_level.\n')
        f.write(f'LVL_SEC1     equ {LVL_SEC1}\n')
        f.write(f'LVL_SECTORS  equ {stride}\n')
        f.write(f'NUM_LEVELS   equ {len(names)}\n')
        f.write('; LEVELS ' + ' '.join(names) + '\n')   # index order; read by
                                                        # tools/testlevel.py
        f.write('; Textures (v2): level n .tex at TEX_SEC1 + n*TEX_SECTORS, streamed\n')
        f.write(';   into VBXE VRAM $018000+ by load_textures. TEX_SECTORS is the DISK\n')
        f.write(';   stride (worst level, padded); the chunks actually streamed are per\n')
        f.write(';   level (LVL_TEXCH in atr_levels.inc -- the tex+spr pool split).\n')
        f.write(f'TEX_SEC1     equ {tex_sec1}\n')
        f.write(f'TEX_SECTORS  equ {tex_stride}\n')
        f.write(f'TEX_CHUNKS   equ {tex_chunks}\n')
        f.write('; Shared texture pool (tools/pack_pool.py): every distinct texture'+chr(10))
        f.write(';   of the built levels, sector-aligned so ONE texture can be streamed'+chr(10))
        f.write(';   on its own. Needed because a level set can exceed VBXE: E1M2 alone'+chr(10))
        f.write(';   is 619 kB against 512 kB of VRAM.'+chr(10))
        f.write(';   POOL_DIR entry (18 B): u16 sector, u16 sectors, u16 w, u16 h,'+chr(10))
        f.write(';                          u8 wlog2, u8 dom, 8s name'+chr(10))
        f.write(';   POOL_IDX (per level): u16 count + u16 pool index per level texid'+chr(10))
        f.write('POOL_SEC     equ %d' % pool_sec + chr(10))
        f.write('POOL_SECTORS equ %d' % pool_secs + chr(10))
        f.write('POOL_DIR_SEC equ %d' % dir_sec + chr(10))
        f.write('POOL_COUNT   equ %d' % pool_n + chr(10))
        f.write('POOL_IDX_SEC equ %d' % idx_sec + chr(10))
        f.write('POOL_IDX_STR equ %d' % idx_stride + chr(10))
        f.write('; THINGS (tools/pack_things.py): level n sprite pixels at'+chr(10))
        f.write(';   SPR_SEC1 + n*SPR_SECTORS, streamed into the VRAM pool right'+chr(10))
        f.write(';   above the level\'s own .tex (LVL_SPRBK/LVL_SPRCH in'+chr(10))
        f.write(';   atr_levels.inc); the .things blob (prefix table,'+chr(10))
        f.write(';   things, sprite table, PLAYPAL) at THG_SEC1 + n*THG_SECTORS,'+chr(10))
        f.write(';   read straight into RAM at THINGS_BASE ($C000).'+chr(10))
        f.write('SPR_SEC1     equ %d' % spr_sec1 + chr(10))
        f.write('SPR_SECTORS  equ %d' % spr_stride + chr(10))
        f.write('SPR_CHUNKS   equ %d' % (spr_stride // CHUNK_SECTORS) + chr(10))
        f.write('THG_SEC1     equ %d' % thg_sec1 + chr(10))
        f.write('THG_SECTORS  equ %d' % thg_stride + chr(10))
        f.write(';   death-animation frame table (pack_things.pack_death), streamed'+chr(10))
        f.write(';   into Rapidus SRAM bank $01 at DTAB_EXT by load_things.'+chr(10))
        f.write('DTB_SEC1     equ %d' % dtb_sec1 + chr(10))
        f.write('DTB_SECTORS  equ %d' % dtb_stride + chr(10))
        f.write(';   barrel line-of-sight table (tools/pack_los.py): LOS_NMAX'+chr(10))
        f.write(';   records of "which 16x16 cells around this barrel does the'+chr(10))
        f.write(';   blast reach", streamed into Rapidus SRAM bank $01 at LOS_EXT'+chr(10))
        f.write(';   by load_los -- one slot per level, like the .dtab above.'+chr(10))
        f.write('LOS_SEC1     equ %d' % los_sec1 + chr(10))
        f.write('LOS_SECTORS  equ %d' % los_stride + chr(10))
        f.write(';   T4 sprite column tables (pack_things.emit_sprcol): the'+chr(10))
        f.write(';   per-frame {off, top, len} x w crop tables, streamed into'+chr(10))
        f.write(';   Rapidus SRAM bank $01 at SPRCOL_EXT by load_sprcol --'+chr(10))
        f.write(';   one slot per level, contract tools/_verify_sprcrop.py.'+chr(10))
        f.write('SPRC_SEC1    equ %d' % sprc_sec1 + chr(10))
        f.write('SPRC_SECTORS equ %d' % sprc_stride + chr(10))
        # ll_left is a BYTE, so read_ext takes the blob in passes of 128
        # sectors (diskio.asm sprcol_read). The last one is the remainder.
        _np = (sprc_stride + 127) // 128
        _last = sprc_stride - 128 * (_np - 1)
        f.write('SPRC_PASSES  equ %d' % _np + chr(10))
        f.write('SPRC_LAST    equ %d' % _last + chr(10))
        f.write('; Status bar graphics (tools/pack_hud.py), map-independent:'+chr(10))
        f.write(';   HUD_CHUNKS x 4KB streamed into VBXE banks from $078000.'+chr(10))
        f.write('HUD_SEC1     equ %d' % hud_sec1 + chr(10))
        f.write('HUD_CHUNKS   equ %d' % hud_chunks + chr(10))
        f.write('PAL_SEC1     equ %d' % (hud_sec1 + hud_chunks * CHUNK_SECTORS) + chr(10))
        f.write('PAL_SECTORS  equ 6                  ; 768 B per palette -> staging' + chr(10))
        f.write('PAL_COUNT    equ %d' % pal_count + chr(10))
        f.write(';   DOOM ships 14 palettes in PLAYPAL (st_stuff.c: normal, 8 red,'+chr(10))
        f.write(';   4 gold, 1 green); VBXE holds 4 at once, so pack_textures.py'+chr(10))
        f.write(';   PAL_SLOTS picks the four and load_palette streams them one at'+chr(10))
        f.write(';   a time -- the staging buffer is 1 KB, a palette 768 B.'+chr(10))
        f.write('; Digitized SFX (tools/wadsound.py), map-independent:'+chr(10))
        f.write(';   SND_CHUNKS x 4KB streamed into Rapidus SRAM bank $02 (SND_EXT;'+chr(10))
        f.write(';   the Timer-1 IRQ reads samples with lda.l, no VBXE involved).'+chr(10))
        f.write('SND_SEC1     equ %d' % (hud_sec1 + hud_chunks * CHUNK_SECTORS
                                          + pal_count * 6) + chr(10))
        f.write('SND_CHUNKS   equ %d' % snd_chunks + chr(10))
        f.write('; Weapon psprites (tools/pack_weap.py), map-independent: WEAP_CHUNKS'+chr(10))
        f.write(';   x 4KB streamed ONCE at boot into Rapidus SRAM at WEAP_EXT'+chr(10))
        f.write(';   ($04:0000); wp_wload copies the active weapon into the VRAM'+chr(10))
        f.write(';   slot (weap_tables.inc WEAP_SLOT) on a switch.'+chr(10))
        f.write(';   MENU_CHUNKS x 4KB (title + main menu, tools/pack_menu.py)'+chr(10))
        f.write(';   streamed into the VRAM pool base by load_menu at boot.'+chr(10))
        f.write('MENU_SEC1    equ %d' % menu_sec1 + chr(10))
        f.write('MENU_CHUNKS  equ %d' % menu_chunks + chr(10))
        f.write(';   The end-of-episode FINALE (tools/pack_fin.py). Its INTERNAL'+chr(10))
        f.write(';   layout -- which chunk holds which page -- is fin_syms.inc;'+chr(10))
        f.write(';   this is only where the blob starts on the disk.'+chr(10))
        f.write('FIN_SEC1     equ %d' % fin_sec1 + chr(10))
        f.write('FIN_ATRCHUNKS equ %d' % fin_chunks + chr(10))
        f.write('; The songs as POKEY register streams (tools/pack_musstream.py):'+chr(10))
        f.write(';   MUS_CHUNKS x 4KB into Rapidus SDRAM from $550000, once at'+chr(10))
        f.write(';   boot (music.asm load_music, tail-called by load_weapons).'+chr(10))
        f.write('MUS_SEC1     equ %d' % mus_sec1 + chr(10))
        f.write('MUS_CHUNKS   equ %d' % mus_chunks + chr(10))
        f.write('; SAVE GAME slots (savegame.asm) -- the only region the engine'+chr(10))
        f.write(';   WRITES. Slot n starts at SAVE_SEC1 + n*SAVE_SECTORS; sector 0'+chr(10))
        f.write(';   of a slot is the header (magic + level + the scattered vars),'+chr(10))
        f.write(';   the rest are the raw region snapshots sg_tab lists.'+chr(10))
        f.write('SAVE_SEC1    equ %d' % save_sec1 + chr(10))
        f.write('SAVE_SLOTS   equ %d' % SAVE_SLOTS + chr(10))
        f.write('SAVE_SECTORS equ %d' % SAVE_SECTORS + chr(10))
        f.write('WEAP_SEC1    equ %d' % weap_sec1 + chr(10))
        f.write('WEAP_CHUNKS  equ %d' % (weap_chunks + cmap_chunks) + chr(10))
        f.write(';   The last %d of those chunks are NOT psprites: DOOM COLORMAP'
                % cmap_chunks + chr(10))
        f.write(';   (tools/pack_cmap.py), 32 light rows x 256, rides in behind'+chr(10))
        f.write(';   them so it needs no loader of its own. lights.asm reads it'+chr(10))
        f.write(';   at CMAP_EXT: colour = [CMAP_EXT + row*256 + colour], row ='+chr(10))
        f.write(';   (255 - sector light) >> 3.'+chr(10))
        f.write('CMAP_EXT     equ $%06X' % cmap_ext + chr(10))
        f.write('CMAP_ROWS    equ 32' + chr(10))
        # ---- SDRAM preload (2026-08-03): the whole episode -> Rapidus SDRAM
        # at boot, level loads become memory copies. Two sector ranges skip the
        # unwired texture pool (~1 MB): [levels+tex] and [spr..weapons].
        # read_sectors' SDRAM branch maps sec -> PREn_BASE + (sec-PREn_SEC)*128.
        # The pool is INSIDE range 0 since 2026-08-14: it is the episode's only
        # texture data now, so it has to reach SDRAM like everything else the
        # engine reads at runtime. (It used to sit in the gap between the two
        # ranges, deliberately, because nothing read it.)
        pre0_cnt = pool_sec + pool_secs - LVL_SEC1
        pre1_cnt = (weap_sec1 + (weap_chunks + cmap_chunks) * CHUNK_SECTORS) - spr_sec1
        pre1_base = 0x080000 + pre0_cnt * 128
        f.write('; SDRAM preload ranges (boot: preload_sdram; then every loader'+chr(10))
        f.write(';   reads Rapidus SDRAM instead of SIO -- diskio.asm ld_src).'+chr(10))
        f.write(';   Range 0 = level slots + textures, range 1 = sprites through'+chr(10))
        f.write(';   the weapon master; the unwired texture pool between them'+chr(10))
        f.write(';   stays on disk only.'+chr(10))
        f.write('PRE0_SEC     equ %d' % LVL_SEC1 + chr(10))
        f.write('PRE0_CNT     equ %d' % pre0_cnt + chr(10))
        f.write('PRE0_BASE    equ $080000            ; Rapidus SDRAM starts here' + chr(10))
        f.write('PRE1_SEC     equ %d' % spr_sec1 + chr(10))
        f.write('PRE1_CNT     equ %d' % pre1_cnt + chr(10))
        f.write('PRE1_BASE    equ $%06X' % pre1_base + chr(10))
        f.write('PRE_END      equ $%06X            ; first free SDRAM byte'
                % (pre1_base + pre1_cnt * 128) + chr(10))
    print(f'  wrote {os.path.relpath(OUT_INC, _PROJ)}  '
          f'(LVL_SEC1={LVL_SEC1} LVL_SECTORS={stride} NUM_LEVELS={len(names)} '
          f'TEX_SEC1={tex_sec1} TEX_SECTORS={tex_stride} TEX_CHUNKS={tex_chunks})')


def main():
    args = sys.argv[1:]
    dir_only = '--dir' in args
    names = [a for a in args if not a.startswith('--')] or E1
    for nm in names:
        if not os.path.exists(os.path.join(WADMAPS, nm + '.bin')):
            sys.exit(f'missing {nm}.bin in {WADMAPS} -- run tools/pack_map.py first')
    stride = lvl_sectors(names)
    tstride = tex_sectors(names)
    tex_sec1 = LVL_SEC1 + len(names) * stride

    # --- shared texture pool (tools/pack_pool.py) -----------------------------
    #     Each texture is sector-aligned inside pool.tex, so load_textures can pull
    #     one texture at a time instead of a whole level's set. That is the only
    #     way past VBXE's 512 KB for levels like E1M2, whose own set is 619 KB.
    pool_p = os.path.join(TEX_DIR, 'pool.tex')
    dir_p = os.path.join(TEX_DIR, 'pool.dir')
    pool = open(pool_p, 'rb').read() if os.path.exists(pool_p) else b''
    pdir = open(dir_p, 'rb').read() if os.path.exists(dir_p) else b''
    if pool:
        # POOLED (2026-08-18): the per-level .tex slots are DEAD -- nothing
        # reads them since the episode pool (load_textures streams POOL_SEC,
        # LVL_TEXCH is 0, and no .asm references TEX_SEC1/TEX_SECTORS/
        # TEX_CHUNKS). Dropping the slots shrinks the ATR by ~1.5 MB per 9
        # maps and compacts the tee's SDRAM map by the same amount.
        tstride = 0
    idxs = {}
    for nm in names:
        ip = os.path.join(TEX_DIR, nm + '.poolidx')
        idxs[nm] = open(ip, 'rb').read() if os.path.exists(ip) else b''
    # B2 (2026-08-18): the SPRITE pool rides the disk right behind pool.tex,
    # inside the SAME region load_textures drains once -- POOL_SECTORS below
    # covers both blobs, LVL_SPRSD points every level at its SDRAM home and
    # LVL_SPRCH goes 0, so load_sprites is a no-op. Engine untouched.
    sprp_p = os.path.join(THINGS_DIR, 'sprpool.bin')
    sprpool = open(sprp_p, 'rb').read() if os.path.exists(sprp_p) else b''
    pool_sec = tex_sec1 + len(names) * tstride
    sprpool_sec = pool_sec + _sectors(len(pool))
    poolsecs_all = _sectors(len(pool)) + _sectors(len(sprpool))
    dir_sec = pool_sec + poolsecs_all
    idx_sec = dir_sec + _sectors(len(pdir))
    idx_stride = max([_sectors(len(v)) for v in idxs.values()] + [1])
    spr_stride, thg_stride, dtb_stride, los_stride, sprc_stride = \
        _thing_files(names)
    spr_sec1 = idx_sec + len(names) * idx_stride
    thg_sec1 = spr_sec1 + len(names) * spr_stride
    dtb_sec1 = thg_sec1 + len(names) * thg_stride
    los_sec1 = dtb_sec1 + len(names) * dtb_stride
    sprc_sec1 = los_sec1 + len(names) * los_stride
    hud_sec1 = sprc_sec1 + len(names) * sprc_stride
    hud_len = os.path.getsize(HUD_BIN) if os.path.exists(HUD_BIN) else 0
    hud_chunks = (_sectors(hud_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    snd_len = os.path.getsize(SND_BIN) if os.path.exists(SND_BIN) else 0
    snd_chunks = (_sectors(snd_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    pal_len = os.path.getsize(PAL_BIN) if os.path.exists(PAL_BIN) else 768
    pal_count = max(1, pal_len // 768)                        # pack_textures.py
    snd_sec1 = hud_sec1 + hud_chunks * CHUNK_SECTORS + pal_count * 6   # after PLAYPAL
    weap_len = os.path.getsize(WEAP_BIN) if os.path.exists(WEAP_BIN) else 0
    weap_chunks = (_sectors(weap_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    weap_sec1 = snd_sec1 + snd_chunks * CHUNK_SECTORS
    # ... and the light table straight after it, in the same chunk run
    cmap_len = os.path.getsize(CMAP_BIN) if os.path.exists(CMAP_BIN) else 0
    cmap_chunks = (_sectors(cmap_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    cmap_sec1 = weap_sec1 + weap_chunks * CHUNK_SECTORS
    cmap_ext = WEAP_EXT + weap_chunks * CHUNK_SECTORS * SECTOR_SIZE

    menu_len = os.path.getsize(MENU_BIN) if os.path.exists(MENU_BIN) else 0
    menu_chunks = (_sectors(menu_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    menu_sec1 = cmap_sec1 + cmap_chunks * CHUNK_SECTORS

    fin_len = os.path.getsize(FIN_BIN) if os.path.exists(FIN_BIN) else 0
    fin_chunks = (_sectors(fin_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    fin_sec1 = menu_sec1 + menu_chunks * CHUNK_SECTORS

    mus_len = os.path.getsize(MUS_BIN) if os.path.exists(MUS_BIN) else 0
    mus_chunks = (_sectors(mus_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    mus_sec1 = fin_sec1 + fin_chunks * CHUNK_SECTORS

    # SAVE GAME slots -- the one region the ENGINE WRITES (savegame.asm). Last on
    # the disk on purpose: everything above it is content the build lays down, so
    # a bigger save format only moves the end of the image.
    save_sec1 = mus_sec1 + mus_chunks * CHUNK_SECTORS

    # MUST match emit_inc's `0x080000 + pre0_cnt * 128` -- range 1 starts where
    # range 0 ends, and range 0 swallowed the pool on 2026-08-14 (both pools
    # since B2).
    pre1_base = 0x080000 + (pool_sec + poolsecs_all - LVL_SEC1) * SECTOR_SIZE
    emit_levels_inc(names, spr_sec1, spr_stride, pre1_base, tex_sec1, tstride,
                    pool_sec if pool else 0, sprpool_sec, len(sprpool))
                                      # per-level loader tables + the sidecar
                                      # "does the FTAB match the file" asserts

    if dir_only:
        emit_inc(names, stride, tex_sec1, tstride, pool_sec,
                 poolsecs_all, dir_sec, idx_sec, idx_stride,
                 len(pdir) // 18 if pdir else 0,
                 spr_sec1, spr_stride, thg_sec1, thg_stride, dtb_sec1, dtb_stride,
                 los_sec1, los_stride, sprc_sec1, sprc_stride,
                 hud_sec1, hud_chunks, snd_chunks, weap_sec1, weap_chunks,
                 pal_count, cmap_chunks, cmap_ext, menu_sec1, menu_chunks,
                 mus_sec1, mus_chunks, save_sec1,
                 fin_sec1=fin_sec1, fin_chunks=fin_chunks)
        return

    for p, what in ((BOOT_BIN, 'boot.bin (assemble boot.asm)'),
                    (XEX, 'doom_bsp.xex (run build.ps1)')):
        if not os.path.exists(p):
            sys.exit(f'missing {p} -- build {what} first')
    boot = open(BOOT_BIN, 'rb').read()
    if len(boot) > BOOT_SECTORS * SECTOR_SIZE:
        sys.exit(f'boot loader too large ({len(boot)} B > {BOOT_SECTORS * SECTOR_SIZE})')
    xex = open(XEX, 'rb').read()
    xex_sec = _sectors(len(xex))
    if XEX_SEC + xex_sec > LVL_SEC1:
        sys.exit(f'XEX too large: {xex_sec} sectors > {LVL_SEC1 - XEX_SEC}-sector window '
                 f'(raise LVL_SEC1)')

    last_sector = save_sec1 + SAVE_SLOTS * SAVE_SECTORS - 1
    total = max(last_sector, FLOPPY_SECTORS)
    disk = bytearray(total * SECTOR_SIZE)
    disk[0:len(boot)] = boot
    o = (XEX_SEC - 1) * SECTOR_SIZE
    disk[o:o + len(xex)] = xex
    for i, nm in enumerate(names):
        sec = LVL_SEC1 + i * stride                  # 1-based slot start
        o = (sec - 1) * SECTOR_SIZE
        data = open(os.path.join(WADMAPS, nm + '.bin'), 'rb').read()
        disk[o:o + len(data)] = data                 # rest of the slot stays zero (padding)
        tp = os.path.join(TEX_DIR, nm + '.tex')      # texture pixels (v2), padded slot
        if os.path.exists(tp) and tstride:           # pooled build: no per-level
            o = (tex_sec1 + i * tstride - 1) * SECTOR_SIZE      # .tex slots at all
            tdata = open(tp, 'rb').read()
            disk[o:o + len(tdata)] = tdata

    for i, nm in enumerate(names):                   # THINGS: sprite pixels + blob
        sp = os.path.join(THINGS_DIR, nm + '.spr')
        if os.path.exists(sp) and spr_stride:
            o = (spr_sec1 + i * spr_stride - 1) * SECTOR_SIZE
            d = open(sp, 'rb').read()
            disk[o:o + len(d)] = d
        dp = os.path.join(THINGS_DIR, nm + '.dtab')
        if os.path.exists(dp) and dtb_stride:
            od = (dtb_sec1 + i * dtb_stride - 1) * SECTOR_SIZE
            d = open(dp, 'rb').read()
            disk[od:od + len(d)] = d
        lp = os.path.join(THINGS_DIR, nm + '.los')      # barrel sight table
        if os.path.exists(lp) and los_stride:
            ol = (los_sec1 + i * los_stride - 1) * SECTOR_SIZE
            d = open(lp, 'rb').read()
            disk[ol:ol + len(d)] = d
        cp = os.path.join(THINGS_DIR, nm + '.sprcol')   # T4 column tables
        if os.path.exists(cp) and sprc_stride:
            oc = (sprc_sec1 + i * sprc_stride - 1) * SECTOR_SIZE
            d = open(cp, 'rb').read()
            disk[oc:oc + len(d)] = d
        tp = os.path.join(THINGS_DIR, nm + '.things')
        if os.path.exists(tp) and thg_stride:
            o = (thg_sec1 + i * thg_stride - 1) * SECTOR_SIZE
            d = open(tp, 'rb').read()
            disk[o:o + len(d)] = d

    if os.path.exists(PAL_BIN):                      # PLAYPAL (installed at boot)
        o = (hud_sec1 + hud_chunks * CHUNK_SECTORS - 1) * SECTOR_SIZE
        d = open(PAL_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if hud_len:                                      # status bar graphics
        o = (hud_sec1 - 1) * SECTOR_SIZE
        d = open(HUD_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if menu_len:                                     # title + main menu
        o = (menu_sec1 - 1) * SECTOR_SIZE
        d = open(MENU_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if fin_len:                                      # the end-of-episode finale
        o = (fin_sec1 - 1) * SECTOR_SIZE
        d = open(FIN_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if mus_len:                                      # the pre-played songs
        o = (mus_sec1 - 1) * SECTOR_SIZE
        d = open(MUS_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if snd_len:                                      # digitized SFX blob
        o = (snd_sec1 - 1) * SECTOR_SIZE
        d = open(SND_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if weap_len:                                     # weapon psprite pixels
        o = (weap_sec1 - 1) * SECTOR_SIZE
        d = open(WEAP_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if cmap_len:                                     # ... + the light table, in
        o = (cmap_sec1 - 1) * SECTOR_SIZE            #     the same chunk run
        d = open(CMAP_BIN, 'rb').read()
        disk[o:o + len(d)] = d

    if pool:
        o = (pool_sec - 1) * SECTOR_SIZE
        disk[o:o + len(pool)] = pool
        o = (dir_sec - 1) * SECTOR_SIZE
        disk[o:o + len(pdir)] = pdir
    if sprpool:                                      # B2: the sprite pool, right
        o = (sprpool_sec - 1) * SECTOR_SIZE          #     behind pool.tex
        disk[o:o + len(sprpool)] = sprpool
        for i, nm in enumerate(names):
            o = (idx_sec + i * idx_stride - 1) * SECTOR_SIZE
            disk[o:o + len(idxs[nm])] = idxs[nm]

    image = len(disk)
    para = image // 16
    os.makedirs(os.path.dirname(OUT_ATR), exist_ok=True)
    with open(OUT_ATR, 'wb') as f:
        h = bytearray(16)
        struct.pack_into('<H', h, 0, ATR_SIGNATURE)
        struct.pack_into('<H', h, 2, para & 0xFFFF)
        struct.pack_into('<H', h, 4, SECTOR_SIZE)
        h[6] = (para >> 16) & 0xFF
        f.write(h)
        f.write(disk)

    emit_inc(names, stride, tex_sec1, tstride,
             pool_sec, poolsecs_all, dir_sec, idx_sec, idx_stride,
             len(pdir) // 18 if pdir else 0,
             spr_sec1, spr_stride, thg_sec1, thg_stride, dtb_sec1, dtb_stride,
             los_sec1, los_stride, sprc_sec1, sprc_stride,
             hud_sec1, hud_chunks, snd_chunks, weap_sec1, weap_chunks, pal_count,
             cmap_chunks, cmap_ext, menu_sec1, menu_chunks, mus_sec1, mus_chunks,
             save_sec1, fin_sec1=fin_sec1, fin_chunks=fin_chunks)
    print(f'  ATR : {OUT_ATR}  ({16 + image} B, {total} sectors, bootable)')
    print(f'  fin : sector {fin_sec1}.., {fin_chunks} x 4 KB ({fin_len} B) '
          f'-> the sprite arena, on demand')
    print(f'  save: sector {save_sec1}.., {SAVE_SLOTS} slots x {SAVE_SECTORS} '
          f'sectors ({SAVE_SLOTS * SAVE_SECTORS * SECTOR_SIZE} B, engine-written)')
    print(f'  menu: sector {menu_sec1}.., {menu_chunks} x 4 KB ({menu_len} B) '
          f'-> VRAM $018000 (title + main menu)')
    print(f'  mus : sector {mus_sec1}.., {mus_chunks} x 4 KB ({mus_len} B) '
          f'-> SDRAM $550000 (pre-played POKEY stream)')
    print(f'  weap: sector {weap_sec1}.., {weap_chunks} x 4 KB bank(s) ({weap_len} B)')
    print(f'  cmap: sector {cmap_sec1}.., {cmap_chunks} x 4 KB ({cmap_len} B) '
          f'-> ${cmap_ext:06X}')
    print(f'  snd : sector {snd_sec1}.., {snd_chunks} x 4 KB bank(s) ({snd_len} B)')
    print(f'  spr : sector {spr_sec1}.., {spr_stride} sectors/level | '
          f'things: sector {thg_sec1}.., {thg_stride} sectors/level | '
          f'dtab: sector {dtb_sec1}.., {dtb_stride} sectors/level | '
          f'los: sector {los_sec1}.., {los_stride} sectors/level | '
          f'sprcol: sector {sprc_sec1}.., {sprc_stride} sectors/level')
    print(f'  tex : sector {tex_sec1}.., {tstride} sectors/level ({tstride*128//1024} KB)')
    print(f'  boot: sectors 1..{BOOT_SECTORS}  ({len(boot)} B)')
    print(f'  xex : sectors {XEX_SEC}..{XEX_SEC + xex_sec - 1}  ({len(xex)} B, {xex_sec} sectors)')
    # (The "does it fit in RAM" check moved to tools/pack_map.py: since format v3
    #  a level is TWO regions -- LOW at $4000 and HIGH at $D800, under the OS ROM
    #  -- and only the packer knows where the split falls. It fails the build with
    #  the exact overshoot if either region is too big.)
    fit = ''
    for i, nm in enumerate(names):
        b = os.path.getsize(os.path.join(WADMAPS, nm + '.bin'))
        print(f'  {nm}: sector {LVL_SEC1 + i * stride}, slot {stride} sectors, {b} B{fit}')


if __name__ == '__main__':
    main()
