#!/usr/bin/env python3
"""Build a BOOTABLE ATR: custom boot loader + doom_bsp.xex + episode-1 maps.

Booting FROM this ATR cold-starts the Atari OS properly (valid VIMIRQ + serial
IRQ vectors), so the engine's own SIO level streaming (load_level) works.
Running the bare XEX without a clean OS boot left VIMIRQ pointing into RAM
(-> BRK on every IRQ -> SIO hang).

Level handling (diskio.asm + atr_layout.inc): all
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
"""
import os
import re
import struct
import sys
import zlib

import code_map
import doomgamma

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJ = os.path.dirname(_HERE)
WADMAPS = os.path.join(_PROJ, 'build', 'assets', 'wadmaps')
BOOT_BIN = code_map.img('build', 'assets', 'code', 'boot.bin')  # this image's
                                     #   loader (ANTONIA II: + the mul/div check)
XEX = code_map.XEX                   # this pass's image (code_map.IMG)
OUT_ATR = (code_map.img('build', 'doom_bsp.atr') if code_map.IMG
           else os.path.join(_PROJ, 'build', 'doom.atr'))
OUT_INC = os.path.join(_PROJ, 'atr_layout.inc')

SECTOR_SIZE = 128
ATR_SIGNATURE = 0x0296
# the boot loader's size in sectors: boot.asm counts its own, and its header
# (byte 1) says how many the OS loads -- the XEX follows them
try:
    BOOT_SECTORS = open(BOOT_BIN, 'rb').read(2)[1]
except (OSError, IndexError):
    BOOT_SECTORS = 12
XEX_SEC = BOOT_SECTORS + 1
# (MAP_SLOT_END lived here: load_level's $8600 ceiling. Dead since 2026-07-31 --
#  nothing read it, and the slot ends at $4C00 now. pack_map.py LOW_LIMIT is the
#  live constant, and it is the one that fails the pack.)
XEX_WIN_END = 640                    # FIXED: the XEX window ends here (560 until
                                     #   inflate816.asm's decode tables, 2026-09-28).
LVL_SEC1 = 32000                     # 2026-09-28: was 33000 -- MAP_SEGLEN grew the
                                     # slot by 38 sectors a level and the virtual
                                     # chain ran 54 past 65535; the physical image
                                     # ends near 24,200.
                                     # VIRTUAL (2026-09-26): the per-level slots
                                     # left the disk (lvl_pak depacks them), so
                                     # their sector numbers only address the
                                     # SDRAM cache (pre_map). Above every real
                                     # sector; the virtual span must stay u16.
                                     # 2026-09-24: was 448; the 320 melt and the
                                     # 320 menu (melt.asm, bank $01) made the
                                     # XEX 446 of 444. 8 KB of headroom again.
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
    """Common stride = max sectors over all included levels (pads all the
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
MENU_BIN = code_map.img('build', 'assets', 'menu', 'menu.bin')
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
# The episode 2/3 intermission world maps, WIMAP1/WIMAP2 halved (tools/pack_wi.py,
# 2026-09-16). Only WIMAP0 fits the boot stream's VRAM run, so these go to
# Rapidus SDRAM instead: laid down RIGHT BEHIND the songs, so load_music's chunk
# walk reaches them with ll_sec already pointing there (music.asm), 0 B for an
# episode-1-only build.
WIM_BIN = os.path.join(_PROJ, 'build', 'assets', 'wi', 'wimaps.bin')
PAL_BIN = os.path.join(TEX_DIR, 'playpal.bin')
SND_BIN = os.path.join(_PROJ, 'build', 'assets', 'sounds', 'sounds.bin')
WEAP_BIN = os.path.join(_PROJ, 'build', 'assets', 'weap', 'weap.bin')
# The light table (tools/pack_cmap.py). It is map-independent and 8 KB = exactly
# two 4 KB chunks, so it is laid down right BEHIND the weapon master and read by
# the same load_weapons chunk walk (WEAP_CHUNKS covers both). A loader of its own
# would have cost ~30 B of base RAM, and there are 179 B left in the whole
# machine -- see the RAM-BUDGET block in memory_map.inc.
CMAP_BIN = os.path.join(_PROJ, 'build', 'assets', 'cmap.bin')
# DOOM's sky columns (tools/pack_sky.py), the same deal once more: laid down
# BEHIND the COLORMAP and inside WEAP_CHUNKS, so load_weapons streams it into
# the free SRAM at $05:8000 (SKY_EXT) and seg_draw.asm sky_clip reads it there.
SKY_BIN = os.path.join(_PROJ, 'build', 'assets', 'sky.bin')
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
                    sprpool_sec=0, sprpool_len=0, pre0_cnt=0):
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
    # The pool homes sit right after the level cache: PRE0_CNT x 128 in
    # (2026-09-26: no longer tied to the DISK position -- the level slots are
    # virtual numbers above the physical image, the pool is packed at 512).
    texsd = 0x080000 + pre0_cnt * SECTOR_SIZE
    sprsd = texsd + (sprpool_sec - pool_sec) * SECTOR_SIZE
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
    # The sky per level (seg_draw.asm sky_clip: `lda.l sky_lvl,x` with X =
    # current_level), in THIS list's order. A table and not a header byte: the
    # map header has none free (+24 is the format version bsp_main checks).
    with open(LVL_SKY_BIN, 'wb') as f:
        f.write(bytes(sky_of(nm) for nm in names))
    return None


LVL_SKY_BIN = os.path.join(_PROJ, 'build', 'assets', 'lvl_sky.bin')


def _equ_int(inc, name):
    """One `NAME equ N` out of a generated include in the project root."""
    with open(os.path.join(_PROJ, inc), encoding='latin-1') as f:
        m = re.search(r'^%s\s+equ\s+\$?([0-9A-Fa-f]+)' % name, f.read(), re.M)
    if not m:
        sys.exit(f'{name} not found in {inc}')
    return int(m.group(1), 16 if '$' in m.group(0) else 10)


_PAKC = {}                           # md5(data) -> its best DEFLATE stream;
_PAKC_STATE = {}                     # backed by tools/cache/paks.cache so the
                                     # zopfli cost is paid once per changed blob
# 2026-09-28: the streams packed WITHOUT zopfli are remembered under this key
# (a set of md5s) and packed again once zopfli is there. A machine without it
# grew the ATR by 100+ KB in a day, one re-packed blob at a time, and said
# nothing.
_PAKC_WEAK = b'zlib-only'


def _zopfli():
    """zopfli.zlib, or None -- with ONE warning a run."""
    if 'zopfli' not in _PAKC_STATE:
        try:
            import zopfli.zlib as zz
        except ImportError:
            zz = None
            print('  WARNING: zopfli is not installed -- every re-packed stream is '
                  'zlib -9 only, 3-7 % bigger (python -m pip install zopfli)')
        _PAKC_STATE['zopfli'] = zz
    return _PAKC_STATE['zopfli']


def _pak_cache():
    import atexit
    import pickle
    bdir = os.path.join(_HERE, 'cache')
    os.makedirs(bdir, exist_ok=True)
    _PAKC_STATE.update(path=os.path.join(bdir, 'paks.cache'), dirty=False)
    try:
        with open(_PAKC_STATE['path'], 'rb') as f:
            _PAKC.update(pickle.load(f))
    except (OSError, EOFError, pickle.UnpicklingError):
        pass

    def save():
        if not _PAKC_STATE['dirty']:
            return
        tmp = _PAKC_STATE['path'] + '.tmp'
        with open(tmp, 'wb') as f:
            pickle.dump(_PAKC, f, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, _PAKC_STATE['path'])
    atexit.register(save)


_PAKC_FAR = b'far1:'                 # + md5(data) -> (stream, md5(stream))


def _i816(z):
    """True when inflate816.asm can depack the stream (inflate816_ok.py). The
    walk is 0.2 s a stream, so it is made once: the cache keeps the md5 of
    every stream that passed, under the checker's own md5."""
    import hashlib
    from inflate816_ok import problem
    if 'i816' not in _PAKC_STATE:
        src = open(os.path.join(_HERE, 'inflate816_ok.py'), 'rb').read()
        _PAKC_STATE['i816'] = b'i816:' + hashlib.md5(src).digest()
    seen = _PAKC.setdefault(_PAKC_STATE['i816'], set())
    h = hashlib.md5(z).digest()
    if h not in seen:
        if problem(z) is not None:
            return False
        seen.add(h)
        _PAKC_STATE['dirty'] = True
    return True


def _deflate(data):
    """What inflate816.asm depacks: the best DEFLATE stream (_deflate_near),
    with FAR matches in when that saves a sector (tools/deflate_far.py). The
    far stream is unpacked against the data when it is made; the cache keeps
    its md5 beside it."""
    if not data:
        return b''
    import hashlib
    import deflate_far
    base = _deflate_near(data)
    key = _PAKC_FAR + hashlib.md5(data).digest()
    hit = _PAKC.get(key)
    if hit is not None and hit[1] == hashlib.md5(hit[0]).digest() and hit[2] == len(base):
        return hit[0]
    far = deflate_far.pack(base, data)
    if _sectors(len(far)) >= _sectors(len(base)):
        far = base
    assert _i816(far), 'inflate816 cannot depack the far stream'
    _PAKC[key] = (far, hashlib.md5(far).digest(), len(base))
    _PAKC_STATE['dirty'] = True
    return far


def _deflate_near(data):
    """Raw DEFLATE (RFC 1951, no zlib header). zlib -9 (both strategies) and
    zopfli compete, the smallest stream wins -- measured 2026-09-26: zopfli
    -3..-7 % across the boot blobs, and Z_FILTERED wins only the SFX samples.
    Round-tripped HERE, so a packer bug can never reach the ATR."""
    import hashlib
    if not _PAKC_STATE:
        _pak_cache()
    # 2026-09-27 (the E3M1 freeze): a stream must also pass inflate816_ok --
    # inflate816.asm counts the codes of each length in ONE byte, and a block
    # with 256+ codes of one length (E3M1's map: 258 of length 9) hangs it.
    # zlib never notices, so the check picks among the candidates here.
    key = hashlib.md5(data).digest()
    zz = _zopfli()
    weak = _PAKC.setdefault(_PAKC_WEAK, set())
    hit = _PAKC.get(key)
    if hit is not None and zlib.decompress(hit, wbits=-15) == data and _i816(hit) \
            and not (zz is not None and key in weak):
        return hit
    cands = []
    for strat in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED):
        c = zlib.compressobj(9, zlib.DEFLATED, -15, 9, strat)
        cands.append(c.compress(data) + c.flush())
    if zz is not None:
        cands.append(zz.compress(data, numiterations=15)[2:-4])  # strip header + adler
        weak.discard(key)
    else:                            # no zopfli on this machine: zlib alone
        weak.add(key)
    c = zlib.compressobj(9, zlib.DEFLATED, -15, 9, zlib.Z_FIXED)
    cands.append(c.compress(data) + c.flush())   # fixed codes: always inflate816-safe
    ok = [z for z in cands if _i816(z)]
    assert ok, 'no DEFLATE candidate inflate816 can depack'
    best = min(ok, key=len)
    assert zlib.decompress(best, wbits=-15) == data, 'deflate round-trip failed'
    _PAKC[key] = best
    _PAKC_STATE['dirty'] = True
    return best


def _with_reloc(xex):
    """The XEX with the VBXE-at-$D7xx table (tools/vbxe_reloc.py) as one more
    data segment, in front of the RUN vector: it loads into BOOT_RELOC, RAM no
    other segment touches, and the boot loader walks it before it starts main
    (boot.asm b_reloc). ONLY the ATR's copy carries it -- build/doom_bsp.xex
    stays what check_xex.py and the simulators read."""
    import boot_cfg
    path = code_map.img('build', 'assets', 'code', 'vbxe_reloc.bin')
    if not os.path.exists(path):
        sys.exit(f'missing {path} -- run tools/vbxe_reloc.py')
    tab = open(path, 'rb').read()
    lo, hi = boot_cfg.BOOT_RELOC, boot_cfg.BOOT_RELOC + len(tab) - 1
    i, run = 2 if xex[:2] == b'\xff\xff' else 0, None
    while i + 4 <= len(xex):
        s, e = struct.unpack_from('<HH', xex, i)
        if s == 0xFFFF:
            i += 2
            continue
        if s == 0x02E0:
            run = i
        elif s != 0x02E2 and s <= hi and e >= lo:
            sys.exit(f'the XEX loads ${s:04X}-${e:04X} over the VBXE table at '
                     f'${lo:04X}-${hi:04X} -- move BOOT_RELOC (tools/boot_cfg.py)')
        i += 4 + e - s + 1
    if run is None:
        sys.exit('the XEX has no RUN vector')
    return xex[:run] + struct.pack('<HH', lo, hi) + tab + xex[run:]


def sky_of(name):
    """G_InitNew (g_game.c 1455-1478): SKY1/2/3 = 0/1/2 by episode; commercial
    maps take SKY1 below MAP12, SKY2 below MAP21, SKY3 after. Anything else
    (E4, a foreign name) gets SKY1."""
    m = re.fullmatch(r'E(\d)M\d+', name.upper())
    if m and 1 <= int(m.group(1)) <= 3:
        return int(m.group(1)) - 1
    m = re.fullmatch(r'MAP(\d+)', name.upper())
    if m:
        n = int(m.group(1))
        return 0 if n < 12 else 1 if n < 21 else 2
    return 0


def emit_inc(names, stride, tex_sec1, tex_stride, pool_sec=0, pool_secs=0,
             dir_sec=0, idx_sec=0, idx_stride=0, pool_n=0,
             spr_sec1=0, spr_stride=0, thg_sec1=0, thg_stride=0,
             dtb_sec1=0, dtb_stride=0, los_sec1=0, los_stride=0,
             sprc_sec1=0, sprc_stride=0,
             hud_sec1=0, hud_chunks=0, snd_chunks=0, weap_sec1=0, weap_chunks=0,
             pal_count=1, cmap_chunks=0, cmap_ext=0,
             menu_sec1=0, menu_chunks=0, mus_sec1=0, mus_chunks=0,
             save_sec1=0, fin_sec1=0, fin_chunks=0,
             sky_chunks=0, sky_ext=0, sky_len=0, wim_sec1=0, wim_chunks=0,
             pool_pak_secs=0, wim_pak_secs=0, snd_pak0_secs=0, snd_pak1_secs=0,
             weap_pak_secs=0, mus_pak_secs=0, menu_plain_sec=0, menu_pakb_sec=0,
             menu_disk_secs=0, hud_pak_secs=0, fin_pak_secs=(),
             fin_disk_secs=0, gam_chunks=0, gam_ext=0):
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
        f.write('; Level layout on the bootable ATR (fixed stride):\n')
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
        f.write(';   POOL_SECTORS is the UNPACKED span (the SDRAM home size);'+chr(10))
        f.write(';   on the disk the pool is a raw-DEFLATE stream of'+chr(10))
        f.write(';   POOL_PAK_SECT sectors, depacked by inflate816.asm.'+chr(10))
        f.write('POOL_PAK_SECT equ %d' % (pool_pak_secs or pool_secs) + chr(10))
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
        f.write('HUD_PAK_SECT equ %d' % (hud_pak_secs
                                         or hud_chunks * CHUNK_SECTORS) + chr(10))
        f.write('PAL_COUNT    equ %d' % pal_count + chr(10))
        f.write(';   DOOM ships 14 palettes in PLAYPAL (st_stuff.c: normal, 8 red,'+chr(10))
        f.write(';   4 gold, 1 green); VBXE holds 4 at once, so pack_textures.py'+chr(10))
        f.write(';   PAL_SLOTS picks them. They ride the GAMMA block into SDRAM'+chr(10))
        f.write(';   (GAMMA_EXT below), not sectors of their own (2026-09-28).'+chr(10))
        f.write('; Digitized SFX (tools/wadsound.py), map-independent:'+chr(10))
        f.write(';   SND_CHUNKS x 4KB streamed into Rapidus SRAM bank $02 (SND_EXT;'+chr(10))
        f.write(';   the Timer-1 IRQ reads samples with lda.l, no VBXE involved).'+chr(10))
        snd_sec1 = hud_sec1 + (hud_pak_secs or hud_chunks * CHUNK_SECTORS)
        f.write('SND_SEC1     equ %d' % snd_sec1 + chr(10))
        f.write('SND_CHUNKS   equ %d' % snd_chunks + chr(10))
        f.write(';   On the disk each wadsound REGION is its own DEFLATE'+chr(10))
        f.write(';   stream (inflate816.asm; sound.asm load_sounds):'+chr(10))
        f.write('SND_PAK0_SEC equ %d' % snd_sec1 + chr(10))
        f.write('SND_PAK1_SEC equ %d' % (snd_sec1 + snd_pak0_secs) + chr(10))
        f.write('SND_PAK_SECT equ %d' % ((snd_pak0_secs + snd_pak1_secs)
                                         or snd_chunks * CHUNK_SECTORS) + chr(10))
        f.write('; Weapon psprites (tools/pack_weap.py), map-independent: WEAP_CHUNKS'+chr(10))
        f.write(';   x 4KB streamed ONCE at boot into Rapidus SRAM at WEAP_EXT'+chr(10))
        f.write(';   ($04:0000); wp_wload copies the active weapon into the VRAM'+chr(10))
        f.write(';   slot (weap_tables.inc WEAP_SLOT) on a switch.'+chr(10))
        f.write(';   MENU_CHUNKS x 4KB (title + main menu, tools/pack_menu.py)'+chr(10))
        f.write(';   streamed into the VRAM pool base by load_menu at boot.'+chr(10))
        f.write('MENU_SEC1    equ %d' % menu_sec1 + chr(10))
        f.write('MENU_CHUNKS  equ %d' % menu_chunks + chr(10))
        f.write(';   chunks 0-33 and 83-93 are TWO DEFLATE streams, depacked'+chr(10))
        f.write(';   into the MENU_BOUNCE SDRAM and spr_fcopy-ed to VRAM'+chr(10))
        f.write(';   (menu.asm mn_dist); chunk 34 is plain at MENU_PLAIN_SEC,'+chr(10))
        f.write(';   a READ THIS! page is a DEFLATE stream at the start of'+chr(10))
        f.write(';   its own 512 sectors behind it (menu.asm rd_pages).'+chr(10))
        f.write('MENU_PLAIN_SEC equ %d' % (menu_plain_sec or menu_sec1) + chr(10))
        f.write('MENU_PAKB_SEC equ %d' % (menu_pakb_sec or menu_sec1) + chr(10))
        f.write('MENU_DISK_SECT equ %d' % (menu_disk_secs
                                           or menu_chunks * CHUNK_SECTORS) + chr(10))
        f.write('MENU_BOUNCE  equ $740000            ; depack bounce (boot menu' + chr(10))
        f.write(';   rows, the HUD, the finale episodes -- never mid-frame)' + chr(10))
        f.write('MENU_BNC_CH  equ 37                 ; its size, 4 KB chunks' + chr(10))
        f.write(';   The end-of-episode FINALE (tools/pack_fin.py). Its INTERNAL'+chr(10))
        f.write(';   layout -- which chunk holds which page -- is fin_syms.inc;'+chr(10))
        f.write(';   this is only where the blob starts on the disk.'+chr(10))
        f.write('FIN_SEC1     equ %d' % fin_sec1 + chr(10))
        f.write('FIN_ATRCHUNKS equ %d' % fin_chunks + chr(10))
        for n, fsec in enumerate(fin_pak_secs or (fin_sec1,) * 3, 1):
            f.write('FIN_PAK%d_SEC equ %d' % (n, fsec) + chr(10))
        f.write('FIN_DISK_SECT equ %d' % fin_disk_secs + chr(10))
        f.write('; The songs as POKEY register streams (tools/pack_musstream.py):'+chr(10))
        f.write(';   MUS_CHUNKS x 4KB into Rapidus SDRAM from $550000, once at'+chr(10))
        f.write(';   boot (music.asm load_music, tail-called by load_weapons).'+chr(10))
        f.write('MUS_SEC1     equ %d' % mus_sec1 + chr(10))
        f.write('MUS_PAK_SECT equ %d' % mus_pak_secs + chr(10))
        f.write('MUS_CHUNKS   equ %d' % mus_chunks + chr(10))
        f.write('; The episode 2/3 intermission world maps (tools/pack_wi.py'+chr(10))
        f.write(';   wimaps.bin): WIM_CHUNKS x 4KB of SDRAM right behind the'+chr(10))
        f.write(';   songs; on the disk a raw-DEFLATE stream of WIM_PAK_SECT'+chr(10))
        f.write(';   sectors (inflate816.asm), NOT the chunk walk, into'+chr(10))
        f.write(';   Rapidus SDRAM at WIMAP_BANK by the same load_music walk.'+chr(10))
        f.write('WIM_SEC1     equ %d' % wim_sec1 + chr(10))
        f.write('WIM_CHUNKS   equ %d' % wim_chunks + chr(10))
        f.write('WIM_PAK_SECT equ %d' % (wim_pak_secs or wim_chunks * CHUNK_SECTORS) + chr(10))
        f.write('; SAVE GAME slots (savegame.asm) -- the only region the engine'+chr(10))
        f.write(';   WRITES. Slot n starts at SAVE_SEC1 + n*SAVE_SECTORS; sector 0'+chr(10))
        f.write(';   of a slot is the header (magic + level + the scattered vars),'+chr(10))
        f.write(';   the rest are the raw region snapshots sg_tab lists.'+chr(10))
        f.write('SAVE_SEC1    equ %d' % save_sec1 + chr(10))
        f.write('SAVE_SLOTS   equ %d' % SAVE_SLOTS + chr(10))
        f.write('SAVE_SECTORS equ %d' % SAVE_SECTORS + chr(10))
        f.write('WEAP_SEC1    equ %d' % weap_sec1 + chr(10))
        f.write('WEAP_CHUNKS  equ %d' % (weap_chunks + cmap_chunks + sky_chunks
                                         + gam_chunks) + chr(10))
        f.write('WEAP_PAK_SECT equ %d' % weap_pak_secs + chr(10))
        f.write(';   ...the last %d of them the GAMMA block (tools/doomgamma.py):' % gam_chunks
                + chr(10))
        f.write(';   v_video.c gammatable[5][256], then the PAL_COUNT palettes as'+chr(10))
        f.write(';   R/G/B planes -- lights.asm gm_apply installs them from here.'+chr(10))
        f.write('GAMMA_EXT    equ $%06X' % gam_ext + chr(10))
        f.write('PALRAW_EXT   equ $%06X' % (gam_ext + doomgamma.PAL_OFF) + chr(10))
        f.write(';   ...and the last %d behind THOSE are the sky (tools/pack_sky.py):'
                % sky_chunks + chr(10))
        f.write(';   SKY1-3 as painter run columns + the view column offsets,'+chr(10))
        f.write(';   read by seg_draw.asm sky_clip at SKY_EXT.'+chr(10))
        f.write('SKY_EXT      equ $%06X' % sky_ext + chr(10))
        f.write('SKY_BYTES    equ %d' % sky_len + chr(10))
        f.write(';   The last %d of those chunks are NOT psprites: DOOM COLORMAP'
                % cmap_chunks + chr(10))
        f.write(';   (tools/pack_cmap.py), 32 light rows x 256, rides in behind'+chr(10))
        f.write(';   them so it needs no loader of its own. lights.asm reads it'+chr(10))
        f.write(';   at CMAP_EXT: colour = [CMAP_EXT + row*256 + colour], the row'+chr(10))
        f.write(';   off lights.asm LT_ROW.'+chr(10))
        f.write('CMAP_EXT     equ $%06X' % cmap_ext + chr(10))
        f.write('CMAP_ROWS    equ 32' + chr(10))
        # ---- SDRAM preload (2026-08-03): the whole episode -> Rapidus SDRAM
        # at boot, level loads become memory copies. Two sector ranges:
        # [level slots] and [spr..weapons]. read_sectors' SDRAM branch maps
        # sec -> PREn_BASE + (sec-PREn_SEC)*128.
        # The pool LEFT range 0 on 2026-09-26: it ships as a DEFLATE stream
        # (inflate816.asm depacks it onto its homes directly), and its PACKED
        # sectors must never be teed -- range 0 now ends where the pool
        # starts. The pool's UNPACKED span still owns the SDRAM between the
        # ranges (LVL_TEXSD_C .. PRE1_BASE), so PRE1_BASE keeps its value.
        pre0_cnt = len(names) * stride
        # ... and range 1 spans the VIRTUAL things..sprcol slots only
        # (2026-09-26): HUD + PAL sit on the physical disk OUTSIDE both
        # ranges now -- read_sectors' pre_map miss falls back to SIO, so a
        # level reload re-reads the 18 palette sectors instead of the cache.
        pre1_cnt = sprc_sec1 + len(names) * sprc_stride - spr_sec1
        pre1_base = 0x080000 + (pre0_cnt + pool_secs) * 128
        f.write('; SDRAM cache ranges (read_sectors tees every drive read into'+chr(10))
        f.write(';   its home; a revisit reads SDRAM instead of SIO -- ld_src).'+chr(10))
        f.write(';   Range 0 = the level slots, range 1 = sprites through the'+chr(10))
        f.write(';   weapon master; between them sits the DEPACKED pool'+chr(10))
        f.write(';   (LVL_TEXSD_C, POOL_SECTORS x 128 B -- atr_levels.inc).'+chr(10))
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
    pool_sec = XEX_WIN_END               # the DISK starts here (2026-09-26):
                                         #   packed pool right after the XEX;
                                         #   the level slots are virtual now
    sprpool_sec = pool_sec + _sectors(len(pool))
    poolsecs_all = _sectors(len(pool)) + _sectors(len(sprpool))
    # PACKED POOL (2026-09-26): both pools ship as ONE raw-DEFLATE stream that
    # inflate816.asm depacks straight onto the SDRAM homes at boot. The plain
    # blob must be byte-identical to the old on-disk layout (pool.tex padded to
    # its sector edge, sprpool right behind) because LVL_TEXSD_C/LVL_SPRSD_C
    # and every SDRAM read are priced off THAT layout -- only the disk shrinks.
    pool_plain = (pool.ljust(_sectors(len(pool)) * SECTOR_SIZE, b'\0')
                  + sprpool) if pool else b''
    pool_pak = _deflate(pool_plain)
    pool_pak_secs = _sectors(len(pool_pak)) if pool_pak else poolsecs_all
    dir_sec = pool_sec + pool_pak_secs
    idx_sec = dir_sec + _sectors(len(pdir))
    idx_stride = max([_sectors(len(v)) for v in idxs.values()] + [1])
    spr_stride, thg_stride, dtb_stride, los_stride, sprc_stride = \
        _thing_files(names)
    # the VIRTUAL slot chain (2026-09-26): sector NUMBERS for pre_map's
    # ld_src = 1 cache addressing only -- none of it exists on the disk
    spr_sec1 = LVL_SEC1 + len(names) * stride
    thg_sec1 = spr_sec1 + len(names) * spr_stride
    dtb_sec1 = thg_sec1 + len(names) * thg_stride
    los_sec1 = dtb_sec1 + len(names) * dtb_stride
    sprc_sec1 = los_sec1 + len(names) * los_stride
    if sprc_sec1 + len(names) * sprc_stride > 0xFFFF:
        sys.exit('the virtual slot space runs past sector 65535 (u16 ll_sec)')
    # ... and the PHYSICAL chain continues where the pool-side regions end
    hud_sec1 = idx_sec + len(names) * idx_stride
    hud_dat = open(HUD_BIN, 'rb').read() if os.path.exists(HUD_BIN) else b''
    hud_len = len(hud_dat)
    hud_chunks = (_sectors(hud_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    # PACKED HUD (2026-09-26): one DEFLATE stream -> MENU_BOUNCE -> spr_fcopy
    hud_pak = _deflate(hud_dat.ljust(hud_chunks * 4096, b'\0'))
    hud_pak_secs = (_sectors(len(hud_pak)) if hud_pak
                    else hud_chunks * CHUNK_SECTORS)
    snd_dat = open(SND_BIN, 'rb').read() if os.path.exists(SND_BIN) else b''
    snd_len = len(snd_dat)
    snd_chunks = (_sectors(snd_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    # PACKED SFX (2026-09-26): one DEFLATE stream per wadsound REGION -- the
    # regions land in banks $02 and $06, not adjacent in the 24-bit space, so
    # one stream cannot span them. The split point is wadsound's own SND_RCH0.
    snd_rch0 = _equ_int('sound_tables.inc', 'SND_RCH0') if snd_dat else 0
    snd_a = snd_dat[:snd_rch0 * 4096].ljust(snd_rch0 * 4096, b'\0')
    snd_b = snd_dat[snd_rch0 * 4096:]
    snd_b = snd_b.ljust(-(-len(snd_b) // 4096) * 4096 if snd_b else 0, b'\0')
    snd_pak0, snd_pak1 = _deflate(snd_a), _deflate(snd_b)
    snd_pak0_secs = _sectors(len(snd_pak0))
    snd_pak1_secs = _sectors(len(snd_pak1))
    pal_dat = open(PAL_BIN, 'rb').read() if os.path.exists(PAL_BIN) else bytes(768)
    pal_count = max(1, len(pal_dat) // 768)                   # pack_textures.py
    snd_sec1 = hud_sec1 + hud_pak_secs   # (PLAYPAL left the disk, 2026-09-28)
    weap_dat = open(WEAP_BIN, 'rb').read() if os.path.exists(WEAP_BIN) else b''
    weap_len = len(weap_dat)
    weap_chunks = (_sectors(weap_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    weap_sec1 = snd_sec1 + snd_pak0_secs + snd_pak1_secs
    # ... and the light table straight after it, in the same chunk run
    cmap_dat = open(CMAP_BIN, 'rb').read() if os.path.exists(CMAP_BIN) else b''
    cmap_len = len(cmap_dat)
    cmap_chunks = (_sectors(cmap_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    cmap_ext = WEAP_EXT + weap_chunks * CHUNK_SECTORS * SECTOR_SIZE
    # ... and the sky columns straight after THAT, still in the same chunk run
    sky_dat = open(SKY_BIN, 'rb').read() if os.path.exists(SKY_BIN) else b''
    sky_len = len(sky_dat)
    sky_chunks = (_sectors(sky_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    sky_ext = cmap_ext + cmap_chunks * CHUNK_SECTORS * SECTOR_SIZE
    # PACKED WEAPONS run (2026-09-26): weapons + colormap + sky are ONE linear
    # $04:0000.. SRAM run, so they pack as ONE stream. Chunk padding between
    # the three blobs is kept (the SRAM layout is priced off the chunk map).
    # ... and the gamma block behind the sky (2026-09-28, tools/doomgamma.py):
    # gammatable + the palettes themselves, which left their own sectors
    gam_dat = doomgamma.block(pal_dat)
    gam_chunks = (_sectors(len(gam_dat)) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    gam_ext = sky_ext + sky_chunks * CHUNK_SECTORS * SECTOR_SIZE
    weap_plain = (weap_dat.ljust(weap_chunks * 4096, b'\0')
                  + cmap_dat.ljust(cmap_chunks * 4096, b'\0')
                  + sky_dat.ljust(sky_chunks * 4096, b'\0')
                  + gam_dat.ljust(gam_chunks * 4096, b'\0'))
    weap_pak = _deflate(weap_plain)
    weap_pak_secs = (_sectors(len(weap_pak)) if weap_pak else
                     (weap_chunks + cmap_chunks + sky_chunks + gam_chunks)
                     * CHUNK_SECTORS)

    menu_dat = open(MENU_BIN, 'rb').read() if os.path.exists(MENU_BIN) else b''
    menu_len = len(menu_dat)
    menu_chunks = (_sectors(menu_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    menu_sec1 = weap_sec1 + weap_pak_secs
    # PACKED MENU (2026-09-26): the BOOT rows pack, the on-demand middle does
    # not. menu.bin = [chunks 0-33: title+pristine+patches+code overlays]
    # [34-82: the automap-reserved chunk + the three READ THIS! pages, read
    # by rd_pages straight off the disk -> they stay PLAIN] [83-93: episode
    # picker + intermission]. Streams A and B depack into the SDRAM bounce
    # (MENU_BOUNCE) and mn_dist hands them to VRAM through spr_fcopy.
    MENU_A_CH, MENU_PLAIN_CH = 34, 49            # pack_menu.py's chunk map
    menu_a = menu_dat[:MENU_A_CH * 4096].ljust(MENU_A_CH * 4096, b'\0') \
        if menu_dat else b''
    menu_mid = menu_dat[MENU_A_CH * 4096:(MENU_A_CH + MENU_PLAIN_CH) * 4096]
    menu_b = menu_dat[(MENU_A_CH + MENU_PLAIN_CH) * 4096:]
    menu_b = menu_b.ljust(-(-len(menu_b) // 4096) * 4096 if menu_b else 0, b'\0')
    menu_paka, menu_pakb = _deflate(menu_a), _deflate(menu_b)
    # PACKED READ THIS!: a DEFLATE stream a page, at the start of the page's
    # own slot -- the sectors rd_pages asks for stay where they were, SIO
    # reads the packed ones only. What is left of the middle stays plain.
    rd_paks = []
    if menu_dat:
        help_ch = _equ_int('menu_syms.inc', 'MENU_HELP_CH')
        hch = _equ_int('menu_syms.inc', 'MENU_HCHUNKS')
        hpages = _equ_int('menu_syms.inc', 'MENU_HPAGES')
        if help_ch < MENU_A_CH or help_ch + hpages * hch > MENU_A_CH + MENU_PLAIN_CH:
            sys.exit('the READ THIS! pages left the middle chunks of menu.bin')
        for n in range(hpages):
            c0 = help_ch + n * hch
            page = menu_dat[c0 * 4096:(c0 + hch) * 4096].ljust(hch * 4096, bytes(1))
            rd_paks.append((c0 * CHUNK_SECTORS, _deflate(page)))
        menu_mid = menu_mid[:(help_ch - MENU_A_CH) * 4096]
    # FIXED OFFSETS inside the menu region. split_menu_ovl.py rewrites
    # menu.bin's overlay chunks BETWEEN this script's --dir pass and its disk
    # pass, so the packed sizes differ between the passes -- any downstream
    # sector derived from them would disagree with the XEX's equs (2026-09-26:
    # a 15-sector skew froze the menu). The region keeps its plain footprint;
    # SIO only ever reads the packed streams, the padding is never touched.
    menu_plain_sec = menu_sec1 + MENU_A_CH * CHUNK_SECTORS
    menu_pakb_sec = menu_sec1 + (MENU_A_CH + MENU_PLAIN_CH) * CHUNK_SECTORS
    menu_disk_secs = menu_chunks * CHUNK_SECTORS
    if len(menu_paka) > MENU_A_CH * 4096 or \
       len(menu_pakb) > (menu_chunks - MENU_A_CH - MENU_PLAIN_CH) * 4096:
        sys.exit('a packed menu stream outgrew its fixed slot -- menu.bin '
                 'stopped compressing?')

    fin_dat = open(FIN_BIN, 'rb').read() if os.path.exists(FIN_BIN) else b''
    fin_len = len(fin_dat)
    fin_chunks = (_sectors(fin_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    fin_sec1 = menu_sec1 + menu_disk_secs
    # PACKED FINALE (2026-09-26): one DEFLATE stream per EPISODE run
    # (fin_syms.inc FIN_SCHn/FIN_NCHn), depacked to MENU_BOUNCE and handed
    # to the arena by f_finale.asm fin_pak -- the ~45 s end-of-episode read
    # halves. Streams may duplicate shared chunks; disk is cheap, SIO is not.
    fin_paks, fin_pak_secs = [], []
    fp_sec = fin_sec1
    if fin_dat:
        for n in (1, 2, 3):
            sch = _equ_int('fin_syms.inc', 'FIN_SCH%d' % n)
            nch = _equ_int('fin_syms.inc', 'FIN_NCH%d' % n)
            blob = fin_dat[sch * 4096:(sch + nch) * 4096].ljust(nch * 4096,
                                                                bytes([0]))
            pak = _deflate(blob)
            fin_paks.append((fp_sec, pak))
            fin_pak_secs.append(fp_sec)
            fp_sec += _sectors(len(pak))
    fin_disk_secs = fp_sec - fin_sec1 if fin_dat else fin_chunks * CHUNK_SECTORS

    mus_dat = open(MUS_BIN, 'rb').read() if os.path.exists(MUS_BIN) else b''
    mus_len = len(mus_dat)
    mus_chunks = (_sectors(mus_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    mus_sec1 = fin_sec1 + fin_disk_secs
    # PACKED SONGS (2026-09-26): POKEY register runs, one DEFLATE stream.
    mus_pak = _deflate(mus_dat.ljust(mus_chunks * 4096, b'\0'))
    mus_pak_secs = (_sectors(len(mus_pak)) if mus_pak
                    else mus_chunks * CHUNK_SECTORS)

    wim_dat = open(WIM_BIN, 'rb').read() if os.path.exists(WIM_BIN) else b''
    wim_len = len(wim_dat)
    wim_chunks = (_sectors(wim_len) + CHUNK_SECTORS - 1) // CHUNK_SECTORS
    wim_sec1 = mus_sec1 + mus_pak_secs
    # PACKED WIMAPS (2026-09-26): one raw-DEFLATE stream, like the pool. The
    # SDRAM span stays WIM_CHUNKS x 4 KB; only the disk footprint shrinks.
    wim_pak = _deflate(wim_dat)
    wim_pak_secs = _sectors(len(wim_pak))

    # SAVE GAME slots -- the one region the ENGINE WRITES (savegame.asm). Last on
    # the disk on purpose: everything above it is content the build lays down, so
    # a bigger save format only moves the end of the image.
    save_sec1 = wim_sec1 + wim_pak_secs

    # MUST match emit_inc's `0x080000 + (pre0_cnt + pool_secs) * 128` -- range
    # 1 starts where the depacked pool ends.
    pre1_base = 0x080000 + (len(names) * stride + poolsecs_all) * SECTOR_SIZE
    emit_levels_inc(names, spr_sec1, spr_stride, pre1_base, tex_sec1, tstride,
                    pool_sec if pool else 0, sprpool_sec, len(sprpool),
                    pre0_cnt=len(names) * stride)
                                      # per-level loader tables + the sidecar
                                      # "does the FTAB match the file" asserts

    # PER-LEVEL PACK (2026-09-26): the five per-level slots (map, things,
    # dtab, los, sprcol) ship as DEFLATE streams in ONE region past the save
    # slots. The VIRTUAL slot layout above (LVL_SEC1.., THG_SEC1..) stays as
    # the ADDRESSING for the SDRAM cache homes (pre_map's ld_src = 1 path);
    # the plain slots are never written to the disk at all. diskio.asm's
    # lvl_pak depacks a level's streams onto its cache homes on FIRST visit
    # and the untouched loader chain then reads them back from SDRAM.
    # The level bins never change between this script's --dir and disk
    # passes (unlike menu.bin), so the directory is pass-stable.
    lvlpak_sec1 = save_sec1 + SAVE_SLOTS * SAVE_SECTORS
    lvp_dir, lvp_streams = [], []
    lvp_sec = lvlpak_sec1
    for nm in names:
        row = []
        for sub, strd in ((os.path.join(WADMAPS, nm + '.bin'), stride),
                          (os.path.join(THINGS_DIR, nm + '.things'), thg_stride),
                          (os.path.join(THINGS_DIR, nm + '.dtab'), dtb_stride),
                          (os.path.join(THINGS_DIR, nm + '.los'), los_stride),
                          (os.path.join(THINGS_DIR, nm + '.sprcol'), sprc_stride)):
            d = open(sub, 'rb').read() if os.path.exists(sub) else b''
            # the whole slot, padding included: the depacked bytes must be
            # what the tee used to park (the chain reads whole strides)
            pak = _deflate(d.ljust(strd * SECTOR_SIZE, b'\0')) if strd else b''
            row.append(lvp_sec)
            lvp_streams.append((lvp_sec, pak))
            lvp_sec += _sectors(len(pak))
        lvp_dir.append(row)
    lvlpak_end = lvp_sec
    if lvlpak_end > LVL_SEC1:
        sys.exit('the physical image ran into the virtual slot space at '
                 f'{LVL_SEC1} -- raise LVL_SEC1 (and mind the u16 ceiling)')
    with open(os.path.join(_PROJ, 'lvlpak.inc'), 'w') as f:
        f.write('; AUTO-GENERATED by tools/make_atr_doom.py -- do not edit.\n')
        f.write('; Per-level DEFLATE stream directory (2026-09-26): five\n')
        f.write('; streams a level -- map, things, dtab, los, sprcol --\n')
        f.write('; walked by diskio.asm lvl_pak on a level\'s FIRST load.\n')
        for tag, col in (('map', 0), ('thg', 1), ('dtb', 2),
                         ('los', 3), ('spc', 4)):
            f.write('lvp_%s_lo dta %s\n'
                    % (tag, ','.join('<%d' % r[col] for r in lvp_dir)))
            f.write('lvp_%s_hi dta %s\n'
                    % (tag, ','.join('>%d' % r[col] for r in lvp_dir)))

    if dir_only:
        emit_inc(names, stride, tex_sec1, tstride, pool_sec,
                 poolsecs_all, dir_sec, idx_sec, idx_stride,
                 len(pdir) // 18 if pdir else 0,
                 spr_sec1, spr_stride, thg_sec1, thg_stride, dtb_sec1, dtb_stride,
                 los_sec1, los_stride, sprc_sec1, sprc_stride,
                 hud_sec1, hud_chunks, snd_chunks, weap_sec1, weap_chunks,
                 pal_count, cmap_chunks, cmap_ext, menu_sec1, menu_chunks,
                 mus_sec1, mus_chunks, save_sec1,
                 fin_sec1=fin_sec1, fin_chunks=fin_chunks,
                 sky_chunks=sky_chunks, sky_ext=sky_ext, sky_len=sky_len,
                 wim_sec1=wim_sec1, wim_chunks=wim_chunks,
                 pool_pak_secs=pool_pak_secs, wim_pak_secs=wim_pak_secs,
                 snd_pak0_secs=snd_pak0_secs, snd_pak1_secs=snd_pak1_secs,
                 weap_pak_secs=weap_pak_secs, mus_pak_secs=mus_pak_secs,
                 menu_plain_sec=menu_plain_sec, menu_pakb_sec=menu_pakb_sec,
                 menu_disk_secs=menu_disk_secs, hud_pak_secs=hud_pak_secs,
                 gam_chunks=gam_chunks, gam_ext=gam_ext,
                 fin_pak_secs=fin_pak_secs, fin_disk_secs=fin_disk_secs)
        return

    for p, what in ((BOOT_BIN, 'boot.bin (assemble boot.asm)'),
                    (XEX, 'doom_bsp.xex (run build_atr.ps1)')):
        if not os.path.exists(p):
            sys.exit(f'missing {p} -- build {what} first')
    boot = open(BOOT_BIN, 'rb').read()
    stock = os.path.join(_PROJ, 'build', 'assets', 'code', 'boot.bin')
    if BOOT_BIN != stock and os.path.exists(stock) and open(stock, 'rb').read(2)[1] != BOOT_SECTORS:
        sys.exit(f"{os.path.basename(BOOT_BIN)} is {BOOT_SECTORS} sectors, boot.bin "
                 f"{open(stock, 'rb').read(2)[1]}: the layout is the stock image's")
    if len(boot) > BOOT_SECTORS * SECTOR_SIZE:
        sys.exit(f'boot loader too large ({len(boot)} B > {BOOT_SECTORS * SECTOR_SIZE})')
    xex = _with_reloc(open(XEX, 'rb').read())
    xex_sec = _sectors(len(xex))
    if XEX_SEC + xex_sec > XEX_WIN_END:
        sys.exit(f'XEX too large: {xex_sec} sectors > {XEX_WIN_END - XEX_SEC}-sector window '
                 f'(raise XEX_WIN_END)')

    last_sector = lvlpak_end - 1
    total = max(last_sector, FLOPPY_SECTORS)
    disk = bytearray(total * SECTOR_SIZE)
    disk[0:len(boot)] = boot
    o = (XEX_SEC - 1) * SECTOR_SIZE
    disk[o:o + len(xex)] = xex
    # (the plain per-level slots -- map, things, dtab, los, sprcol, .tex --
    #  are GONE from the disk: their sectors stay zero and only address the
    #  SDRAM cache; the content ships packed in the LVLPAK region below)
    for sec, pak in lvp_streams:
        o = (sec - 1) * SECTOR_SIZE
        disk[o:o + len(pak)] = pak

    if hud_len:                                      # status bar: one deflate
        o = (hud_sec1 - 1) * SECTOR_SIZE             #   stream (2026-09-26)
        disk[o:o + len(hud_pak)] = hud_pak

    if menu_len:                                     # title + main menu: pakA,
        o = (menu_sec1 - 1) * SECTOR_SIZE            #   the plain READ THIS!
        disk[o:o + len(menu_paka)] = menu_paka       #   middle, then pakB
        o = (menu_plain_sec - 1) * SECTOR_SIZE
        disk[o:o + len(menu_mid)] = menu_mid
        for sec, pak in rd_paks:                     # the READ THIS! pages
            o = (menu_sec1 + sec - 1) * SECTOR_SIZE
            disk[o:o + len(pak)] = pak
        o = (menu_pakb_sec - 1) * SECTOR_SIZE
        disk[o:o + len(menu_pakb)] = menu_pakb

    for sec, pak in fin_paks:                        # the end-of-episode finale:
        o = (sec - 1) * SECTOR_SIZE                  #   a stream per episode
        disk[o:o + len(pak)] = pak

    if mus_len:                                      # the pre-played songs:
        o = (mus_sec1 - 1) * SECTOR_SIZE             #   one deflate stream
        disk[o:o + len(mus_pak)] = mus_pak

    if wim_len:                                      # the world maps + wi kit:
        o = (wim_sec1 - 1) * SECTOR_SIZE             #   ONE deflate stream
        disk[o:o + len(wim_pak)] = wim_pak

    if snd_len:                                      # digitized SFX: a deflate
        o = (snd_sec1 - 1) * SECTOR_SIZE             #   stream per REGION
        disk[o:o + len(snd_pak0)] = snd_pak0
        o = (snd_sec1 + snd_pak0_secs - 1) * SECTOR_SIZE
        disk[o:o + len(snd_pak1)] = snd_pak1

    if weap_len:                                     # weapons + colormap + sky:
        o = (weap_sec1 - 1) * SECTOR_SIZE            #   ONE deflate stream over
        disk[o:o + len(weap_pak)] = weap_pak         #   the whole SRAM run

    if pool_pak:                                     # tex+spr pools: ONE deflate
        o = (pool_sec - 1) * SECTOR_SIZE             #   stream (sprpool rides
        disk[o:o + len(pool_pak)] = pool_pak         #   inside it, see above)
        o = (dir_sec - 1) * SECTOR_SIZE
        disk[o:o + len(pdir)] = pdir
    if sprpool:
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
             save_sec1, fin_sec1=fin_sec1, fin_chunks=fin_chunks,
             sky_chunks=sky_chunks, sky_ext=sky_ext, sky_len=sky_len,
             wim_sec1=wim_sec1, wim_chunks=wim_chunks,
             pool_pak_secs=pool_pak_secs, wim_pak_secs=wim_pak_secs,
             snd_pak0_secs=snd_pak0_secs, snd_pak1_secs=snd_pak1_secs,
             weap_pak_secs=weap_pak_secs, mus_pak_secs=mus_pak_secs,
             menu_plain_sec=menu_plain_sec, menu_pakb_sec=menu_pakb_sec,
             menu_disk_secs=menu_disk_secs, hud_pak_secs=hud_pak_secs,
                 gam_chunks=gam_chunks, gam_ext=gam_ext,
             fin_pak_secs=fin_pak_secs, fin_disk_secs=fin_disk_secs)
    def _pk(tag, sec1, pak, plain, where):
        print(f'  {tag}: sector {sec1}.., {_sectors(len(pak))} packed sectors '
              f'({len(pak)} B <- {len(plain)} B, '
              f'{len(pak)*100//max(1,len(plain))}%) -> {where}')
    print(f'  ATR : {OUT_ATR}  ({16 + image} B, {total} sectors, bootable)')
    print(f'  fin : sector {fin_sec1}.., {fin_chunks} x 4 KB ({fin_len} B) '
          f'-> the sprite arena, on demand')
    print(f'  save: sector {save_sec1}.., {SAVE_SLOTS} slots x {SAVE_SECTORS} '
          f'sectors ({SAVE_SLOTS * SAVE_SECTORS * SECTOR_SIZE} B, engine-written)')
    print(f'  menu: sector {menu_sec1}.., {menu_disk_secs} disk sectors '
          f'(pakA {len(menu_paka)} B + plain {len(menu_mid)} B + '
          f'pakB {len(menu_pakb)} B <- {menu_len} B) -> VRAM via MENU_BOUNCE')
    print('  read: the READ THIS! pages, on demand: '
          + ', '.join(f'{_sectors(len(p))} sectors' for _, p in rd_paks)
          + ' (each was 512)')
    _pk('mus ', mus_sec1, mus_pak, mus_dat, 'SDRAM MUS_BANK0')
    _pk('wim ', wim_sec1, wim_pak, wim_dat, f'SDRAM WIMAP_BANK ({wim_chunks} x 4 KB)')
    _pk('pool', pool_sec, pool_pak, pool_plain,
        f'SDRAM LVL_TEXSD_C ({poolsecs_all} sectors)')
    _pk('weap', weap_sec1, weap_pak, weap_plain,
        f'SRAM $040000 (+cmap ${cmap_ext:06X}, sky ${sky_ext:06X}, '
        f'gamma ${gam_ext:06X})')
    _pk('snd ', snd_sec1, snd_pak0 + snd_pak1, snd_dat, 'SRAM banks $02+$06')
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
