#!/usr/bin/env python3
"""Make an Atari ATR out of somebody else's DOOM maps.

Point it at a map WAD, tick the maps you want, press KONVERTOVAT and it runs the
project's own build pipeline (build_atr.ps1) to produce a bootable
build/doom.atr with those levels on it.

HOW THE WAD GETS IN. Every packer opens the WAD through tools/wadlib.py, and
wadlib reads two environment variables: DOOMWAD (the IWAD -- textures, sprites,
sounds) and DOOMPWAD (PWADs layered on top, DOOM's own -file rule). So this tool
sets those two and then runs the NORMAL build. There is no second pipeline to
keep in step, and no packer needed changing.

A map WAD ships maps and nothing else, so the IWAD stays in the picture: the
wall textures (painted as TEX_RUNK-run columns since 2026-08-06, all of them,
not just doors and switches), the monster sprites, the weapons, the HUD and
every sound still come out of DOOM.WAD unless the PWAD overrides them.

WHAT IT CHECKS FIRST. The Atari engine is much smaller than DOOM, so before
converting anything it reads the maps and reports what will not survive:
levels that were never node-built, more things or doors or sectors than the
engine can hold, linedef specials it does not implement, and monsters it has no
sprites for. Nothing there is a guess -- the supported sets come from
tools/doomspecs.py and tools/wadthings.py, the same tables the packers use, and
the size limits from tools/pack_map.py and tools/pack_things.py.

WHICH LEVEL IS THE SECRET ONE. The report says so, and the map list marks it.
Half of that answer is not in the WAD at all: DOOM picks the secret map by
NUMBER in g_game.c (ExM9, or MAP31/MAP32), and what the WAD supplies is the
secret EXIT LINE (special 51 or 124) in whichever map leads there. So the tool
states both halves and names its source -- see the secret-level block below.

  python tools/wad/wadconv.py                       # GUI
  python tools/wad/wadconv.py --check GALAXIA.WAD   # just the report, no GUI
  python tools/wad/wadconv.py --build GALAXIA.WAD E1M1 E1M9
"""
import os
import re
import struct
import subprocess
import sys
import threading

_HERE = os.path.dirname(os.path.abspath(__file__))
_TOOLS = (_HERE if os.path.exists(os.path.join(_HERE, 'wadlib.py'))
          else os.path.dirname(_HERE))   # the packers and wadlib (this file is
                                         #   build/py/wad/, or tools/ itself in
                                         #   web/bundle.zip)
_PROJ = _TOOLS                           # repo root: the dir holding bsp_main.asm
while not os.path.exists(os.path.join(_PROJ, 'bsp_main.asm')) and os.path.dirname(_PROJ) != _PROJ:
    _PROJ = os.path.dirname(_PROJ)
sys.path.insert(0, _HERE)
sys.path.insert(0, _TOOLS)

# Everything build_atr.ps1 rewrites IN PLACE and that belongs to the project's
# own episode 1, not to the WAD being converted:
#   * the ATR itself -- the pipeline has one output name and always uses it
#   * the four generated includes, which are ASSEMBLER INPUTS. atr_layout.inc
#     and atr_levels.inc carry the level list and the sector map of the ATR;
#     map_syms.inc the packed map's symbols. Leave those on a foreign WAD and
#     the next plain build_atr.ps1 quietly assembles an XEX for the wrong maps.
#   * the built XEX + listing, which every tools/_verify_*.py reads
# build/assets/** is NOT in the list on purpose: build_atr.ps1 repacks all of
# it from scratch on every run, so a stale copy there costs nothing.
# 2026-08-30: the list was SIX SHORT. Anything a packer writes to the project
# root is an assembler input and has to be here, and the way to find them is to
# ask the packers, not to remember: every `os.path.join(<project root>, '*.inc')`
# that gets WRITTEN. Missed were pack_wi's wi_syms.inc, pack_fin's fin_syms.inc,
# pack_hud's hud_syms.inc, wadsound's snd_pitch.inc and the two pack_things
# emits BESIDE mk_tables.inc -- at_tables.inc and wi_tables.inc. A TNT
# conversion left every one of them describing TNT, and the next plain
# build_atr.ps1 assembled the project's own episode 1 against them.
_GUARDED = ('build/doom.atr', 'build/doom_bsp.xex', 'build/doom_bsp.lst',
            'map_syms.inc', 'atr_layout.inc', 'atr_levels.inc',
            'weap_tables.inc', 'sound_tables.inc',
            'mk_tables.inc', 'menu_syms.inc',   # pack_things / pack_menu
                                                #   rewrite these two as well
            'at_tables.inc', 'wi_tables.inc',   # ...and pack_things these two
            'wi_syms.inc',                      # pack_wi  -- the level list
            'fin_syms.inc',                     # pack_fin -- the finale
            'hud_syms.inc',                     # pack_hud -- STBAR geometry
            'snd_pitch.inc',                    # wadsound, beside sound_tables
            'memory_map.inc',                   # ram_map.py --update rewrites
                                                #   the RAM budget block from
                                                #   the .lst of THIS build
            # 2026-10-07: build_atr.ps1 grew the ANTONIA II image, the boot
            # loaders and more generated includes; a conversion left all of
            # them foreign (the project's ant2 ATR held the test level)
            'build/doom_bsp.lab', 'build/doom_bsp_ant2.atr',
            'build/doom_bsp_ant2.xex', 'build/doom_bsp_ant2.lst',
            'build/doom_bsp_ant2.lab', 'build/boot.xex', 'build/boot_ant2.xex',
            'lvlpak.inc', 'boot_cfg.inc', 'boot_rows.inc', 'console_ver.inc',
            'VERSION',
            'music_syms.inc', 'music_tabs.inc',  # the silent songs (build())
            'build/.packed.stamp')              # ...and this one DESCRIBES
                                                #   build/assets (which WAD
                                                #   pair and level set packed
                                                #   it), so it has to travel
                                                #   with the tree it describes
# Whole TREES the packers refill from the conversion's WAD. These were left
# foreign on purpose once ("build_atr repacks them from scratch anyway") --
# but anything that packages an ATR WITHOUT a full repack (make_atr_doom.py
# standalone) then bakes the foreign TITLEPIC, sounds and sprites into
# doom.atr. 2026-08-10: it did -- the project ATR booted with DOOM II's
# title picture after a Doom2.wad conversion.
_GUARDED_DIRS = ('build/assets',)


def _quickstart(atr_path, lst, lab, log=print):
    """Straight into the game: in a CONVERSION's ATR copy (never the project's),
    menu_boot's two `lda #BANK_EN|MENU_OBANK / ldx #MN_E_x / jsr mn_open` --
    the title and the menu -- become what they leave behind for the game:
        stz mn_ing                     mn_boot's; the byte sits in the boot
                                       loader's sector buffer (garbage)
        lda #BANK_EN|BANK_OVERHEAD     mn_head's: mn_togame writes its BCB
        sta VBXE_BANK_SEL              through that MEMAC window
        nop x 6
    mn_togame then puts the renderer's display list up itself, and
    current_level is the boot's 0 = the first converted map. The sta's high
    byte joins the VBXE-at-$D7xx table (boot.asm b_reloc). Same unpack / repack
    of the ZX02 XEX window as test-levels.py. -> True when patched."""
    import boot_cfg
    import make_atr_doom as MA
    sym = {}
    for line in open(lab, encoding='latin-1'):
        f = line.split()
        if len(f) == 3:
            sym[f[2]] = int(f[1], 16)
    code = re.compile(r'^\s*\d+\s+(?:[0-9A-F]{2},)?([0-9A-F]{4})\s+'
                      r'([0-9A-F]{2}(?: [0-9A-F]{2})*)\t+\s*(\S[^;]*)')
    rows = [(int(m.group(1), 16), bytes.fromhex(m.group(2)), m.group(3).strip())
            for m in map(code.match, open(lst, encoding='latin-1')) if m]
    want = ['lda #BANK_EN | MENU_OBANK', 'ldx #MN_E_TITLE', 'jsr mn_open',
            'lda #BANK_EN | MENU_OBANK', 'ldx #MN_E_BOOT', 'jsr mn_open']
    at = next((i for i in range(len(rows) - 5)
               if [r[2] for r in rows[i:i + 6]] == want), None)
    if at is None:
        log('   quickstart: menu_boot\'s title/menu calls not found in the '
            'listing -- ATR left with its menu')
        return False
    start, old = rows[at][0], b''.join(r[1] for r in rows[at:at + 6])
    atr = bytearray(open(atr_path, 'rb').read())
    base = 16 + atr[17] * 128                       # behind the boot sectors
    size = 16 + (MA.XEX_WIN_END - 1) * 128 - base
    xex = bytearray(MA._unzx02(bytes(atr[base:base + size])))

    def seg_at(addr):                               # (header offset, start, end)
        i = 0
        while i + 4 <= len(xex):
            if xex[i:i + 2] == b'\xff\xff':
                i += 2
                continue
            s, e = struct.unpack_from('<HH', xex, i)
            if s <= addr <= e:
                return i, s, e
            i += 4 + e - s + 1
        return None

    hit = seg_at(start)
    if hit is None or xex[hit[0] + 4 + start - hit[1]:][:len(old)] != old:
        log('   quickstart: the XEX does not hold menu_boot as listed -- ATR left '
            'with its menu')
        return False
    sel = sym['VBXE_BANK_SEL']
    new = bytes([0x9C, sym['MN_ING'] & 0xFF, sym['MN_ING'] >> 8,
                 0xA9, sym['BANK_EN'] | sym['BANK_OVERHEAD'],
                 0x8D, sel & 0xFF, sel >> 8]) + b'\xea' * (len(old) - 8)
    o = hit[0] + 4 + start - hit[1]
    xex[o:o + len(new)] = new
    rl = seg_at(boot_cfg.BOOT_RELOC)                # the $D7xx table: + the sta
    if rl is None or rl[1] != boot_cfg.BOOT_RELOC:
        log('   quickstart: no VBXE table in the XEX -- ATR left with its menu')
        return False
    h, s, e = rl
    end = h + 4 + e - s + 1 - 3                     # its $FF $FF $FF terminator
    if xex[end:end + 3] != b'\xff\xff\xff':
        log('   quickstart: the VBXE table does not end in $FF $FF $FF -- ATR '
            'left with its menu')
        return False
    for a in range(e + 1, e + 4):                   # 3 more bytes of RAM: free?
        if seg_at(a) is not None:
            log('   quickstart: no room behind the VBXE table -- ATR left with its menu')
            return False
    hi = start + 7                                  # the sta operand's high byte
    xex[end:end] = bytes([hi & 0xFF, hi >> 8, 0])
    struct.pack_into('<H', xex, h + 2, e + 3)
    pak = MA._zx02(bytes(xex))
    if len(pak) > size:
        log(f'   quickstart: the patched XEX packs to {len(pak)} B, the window '
            f'has {size} -- ATR left with its menu')
        return False
    atr[base:base + size] = pak.ljust(size, b'\0')
    open(atr_path, 'wb').write(atr)
    return True


def _snapshot():
    """Read the guarded files (and trees) into memory. None = it did not
    exist, and the restore then deletes whatever the conversion put there."""
    keep = {}
    for rel in _GUARDED:
        p = os.path.join(_PROJ, *rel.split('/'))
        keep[rel] = open(p, 'rb').read() if os.path.exists(p) else None
    for d in _GUARDED_DIRS:
        base = os.path.join(_PROJ, *d.split('/'))
        for root, _dirs, files in os.walk(base):
            for fn in files:
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, _PROJ).replace(os.sep, '/')
                keep[rel] = open(p, 'rb').read()
    return keep


def _restore(keep, log=print):
    back = []
    for d in _GUARDED_DIRS:              # files the conversion ADDED: delete,
        base = os.path.join(_PROJ, *d.split('/'))   # they are not ours
        for root, _dirs, files in os.walk(base):
            for fn in files:
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, _PROJ).replace(os.sep, '/')
                if rel not in keep:
                    os.remove(p)
                    back.append(rel + ' (removed)')
    for rel, data in keep.items():
        p = os.path.join(_PROJ, *rel.split('/'))
        if data is None:
            if os.path.exists(p):
                os.remove(p)
            continue
        if os.path.exists(p) and open(p, 'rb').read() == data:
            continue                         # untouched, say nothing
        with open(p, 'wb') as f:
            f.write(data)
        back.append(rel)
    if back:
        log(f'   project restored to its own files: {len(back)} entries '
            f'({", ".join(back[:6])}{", ..." if len(back) > 6 else ""})')

import doomspecs                                               # noqa: E402
import wadlib                                                  # noqa: E402
sys.path.insert(0, os.path.join(_HERE, 'custom'))
import hooks as _custom                                        # noqa: E402
_custom.install_global()          # what foreign WADs need of wadtex/texruns,
                                  #   for CHECK too (tools/wad/custom/hooks.py)
import wadthings                                               # noqa: E402

IWAD_DEFAULT = os.path.join(_TOOLS, 'DOOM.WAD')

# ------------------------------------------------------------------ settings --
# WHAT THE TOOL REMEMBERS between runs: the IWAD, the map WAD and where Altirra
# is. The emulator matters most -- testlevel.launch falls back to the .atr file
# association, which on a fresh machine opens a zip tool or nothing at all, and
# then a conversion that worked looks like it did nothing. Nobody should have to
# set an environment variable to get their own ATR to boot, so it is a field in
# the window and it is kept.
# Beside the script normally; beside the EXE when frozen (PyInstaller unpacks
# the code to a temp dir that is gone next run, so _MEIPASS is never the place
# for it).
_CFG_DIR = (os.path.dirname(sys.executable) if getattr(sys, 'frozen', False)
            else _HERE)
CONFIG = os.path.join(_CFG_DIR, 'wadconv.json')


def load_cfg():
    try:
        import json
        with open(CONFIG, encoding='utf-8') as f:
            c = json.load(f)
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def save_cfg(**kw):
    """Merge and write. A settings file that cannot be written is not worth an
    error -- the conversion still works, it just forgets."""
    try:
        import json
        c = load_cfg()
        c.update({k: v for k, v in kw.items() if v is not None})
        with open(CONFIG, 'w', encoding='utf-8') as f:
            json.dump(c, f, indent=1)
    except Exception:
        pass


def default_iwad():
    """The IWAD to fall back on: the remembered one, then DOOMWAD, then the copy
    beside the packers. The packaged EXE ships NO DOOM.WAD -- it is id's, not
    ours -- so there the first two are the only ones that ever exist, and the
    command line has to reach them the same way the window does."""
    # 2026-10-20: a remembered file the port cannot use as the IWAD (batman.wad
    # picked into step 1) is passed over -- it stood in the IWAD slot of every
    # later run, the CLI's too, and each one stopped on "not a DOOM IWAD".
    for p in (load_cfg().get('iwad'), os.environ.get('DOOMWAD'), IWAD_DEFAULT):
        if p and os.path.isfile(p) and not missing_engine_art(p):
            return p
    return IWAD_DEFAULT


def game_order(names):
    """Map names in GAME order (E1M1..E4M9, MAP01..MAP32), not the WAD's own
    lump order -- batman.wad stores MAP14, MAP20, MAP10 ... (2026-10-20)."""
    return sorted(dict.fromkeys(names),
                  key=lambda n: (int(n[1]), int(n[3])) if n[0] == 'E' else (0, int(n[3:])))


def fix_slots(iwad, pwad, log=None):
    """A map WAD in the IWAD slot (batman.wad, tnt.wad, heretic.wad: no WIMAP0/
    STBAR/...) moves to the MAP WAD slot and DOOM.WAD takes the IWAD slot --
    what the stop message told the user to do by hand. -> (iwad, pwad)."""
    if not iwad or not os.path.isfile(iwad) or not missing_engine_art(iwad):
        return iwad, pwad
    new = default_iwad()
    if log:
        log(f'   {os.path.basename(iwad)} is a MAP WAD, not DOOM.WAD -- it goes in '
            f'step 2, and {os.path.basename(new)} is the IWAD')
    return new, iwad


def find_altirra():
    """The remembered path, else ALTIRRA, else PATH, else the usual install
    spots. '' when there is none -- the caller then says so instead of handing
    the ATR to whatever owns the .atr extension."""
    import shutil
    seen = load_cfg().get('altirra')
    if seen and os.path.isfile(seen):
        return seen
    env = os.environ.get('ALTIRRA')
    if env and os.path.isfile(env):
        return env
    for nm in ('Altirra64', 'Altirra'):
        p = shutil.which(nm)
        if p:
            return p
    for base in (os.environ.get('ProgramFiles', r'C:\Program Files'),
                 os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)'),
                 os.path.join(_PROJ, '..')):
        for nm in ('Altirra64.exe', 'Altirra.exe'):
            for sub_ in ('', 'Altirra'):
                p = os.path.join(base, sub_, nm)
                if os.path.isfile(p):
                    return p
    return ''


# --------------------------------------------- the resource WAD in the middle
# A MAP WAD SHIPS MAPS. Which wall textures and flats those maps NAME is a
# property of the game they were built for, and this port cannot switch IWADs to
# match: it bakes episode 1's intermission screen, so a file without WIMAP0 can
# never hold the IWAD slot (see ENGINE_ART) and DOOM.WAD stays. Point a DOOM II
# map WAD at it and every DOOM II texture name is simply not there. SIMPLE.WAD's
# MAP01 lost 14 of its 25 wall textures and 4 of its 19 flats that way, and the
# packers then do the only thing they can with a name that has no picture --
# substitute the map's commonest wall (pack_textures) and paint the floor black
# (pack_map: flat_dominant -> None -> colour 0). The report said "all clear".
#
# So the pair is a STACK: DOOM.WAD, then the game file the maps were built for,
# then the map WAD itself. That is DOOM's own -file rule and the same
# os.pathsep-separated DOOMPWAD list wadlib has always taken, so nothing
# downstream needed changing. The middle file is found by ASKING THE MAPS which
# names they use that the stack cannot resolve, and then asking each WAD on the
# shelf which of those it has -- not guessed from the map names: a MAPxx WAD
# built out of DOOM 1 textures needs no second file, and an ExMy WAD can name
# DOOM II's perfectly well.
_RES_ENV = 'DOOMRESWAD'        # explicit override, os.pathsep-separated
# Only breaks a TIE between two files that supply the same names -- doom2.wad,
# tnt.wad and plutonia.wad share almost every texture, so without this the pick
# would come down to directory order.
_FAMILY = {'DOOM2.WAD': 2, 'PLUTONIA.WAD': 2, 'TNT.WAD': 2,
           'FREEDOOM2.WAD': 2, 'FREEDM.WAD': 2,
           'DOOM.WAD': 1, 'DOOMU.WAD': 1, 'DOOM1.WAD': 1, 'FREEDOOM1.WAD': 1}
_MAPDATA = {'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS', 'SSECTORS',
            'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP', 'BEHAVIOR', 'SCRIPTS'}
_dir_cache = {}


def _wad_dir(path):
    """(magic, [(NAME, offset, size)]) out of the DIRECTORY ALONE -- two seeks
    and 16 bytes a lump, so looking over a shelf of 15 MB IWADs is free. The
    whole resource decision is made on directories: not one candidate is ever
    read into memory."""
    key = os.path.normcase(os.path.abspath(path))
    if key in _dir_cache:
        return _dir_cache[key]
    out = (None, [])
    try:
        with open(path, 'rb') as f:
            head = f.read(12)
            if len(head) == 12 and head[:4] in (b'IWAD', b'PWAD'):
                n, off = struct.unpack_from('<ii', head, 4)
                if 0 <= n < (1 << 22) and off >= 0:
                    f.seek(off)
                    raw = f.read(n * 16)
                    lumps = []
                    for i in range(min(n, len(raw) // 16)):
                        lo, ls = struct.unpack_from('<ii', raw, i * 16)
                        lumps.append((wadlib._name(raw[i * 16 + 8:i * 16 + 16]),
                                      lo, ls))
                    out = (head[:4].decode(), lumps)
    except OSError:
        pass
    _dir_cache[key] = out
    return out


def is_wad(path):
    """A readable file with an IWAD/PWAD header and a directory in it."""
    return bool(path) and os.path.isfile(path) and _wad_dir(path)[0] is not None


def _wad_names(path):
    """Every lump name in a file -- that is the flat test, and the patch test."""
    return {nm for nm, _o, _s in _wad_dir(path)[1]}


def _wad_textures(path):
    """The texture names a file DEFINES, out of its own TEXTURE1/TEXTURE2.

    Deliberately the same union wadtex._read_textures builds (every source's own
    set, later files winning by name), so "does this candidate have the name" is
    answered here exactly as the packers will answer it."""
    magic, lumps = _wad_dir(path)
    names = set()
    if magic is None:
        return names
    want = [(lo, ls) for nm, lo, ls in lumps if nm in ('TEXTURE1', 'TEXTURE2')]
    if not want:
        return names
    with open(path, 'rb') as f:
        for lo, ls in want:
            f.seek(lo)
            raw = f.read(ls)
            if len(raw) < 4:
                continue
            n, = struct.unpack_from('<i', raw, 0)
            for i in range(max(0, n)):
                if 8 + i * 4 > len(raw):
                    break
                o, = struct.unpack_from('<i', raw, 4 + i * 4)
                if 0 <= o <= len(raw) - 8:
                    names.add(wadlib._name(raw[o:o + 8]))
    return names


def map_art(path, maps):
    """(wall textures, flats) the named maps ASK FOR, read straight out of their
    SIDEDEFS and SECTORS lumps.

    Not load_map: this has to run before the WAD pair is even decided, it must
    not narrate (load_map prints its sector merge), and the two structs it reads
    are the same 30 and 26 bytes in Hexen format as in DOOM's."""
    magic, lumps = _wad_dir(path)
    tex, flat = set(), set()
    if magic is None:
        return tex, flat
    want = {m.upper() for m in maps}
    with open(path, 'rb') as f:
        for i, (nm, _lo, _ls) in enumerate(lumps):
            if nm not in want:
                continue
            for j in range(i + 1, len(lumps)):
                sub_, lo, ls = lumps[j]
                if sub_ not in _MAPDATA:
                    break
                if sub_ == 'SIDEDEFS':
                    f.seek(lo)
                    raw = f.read(ls)
                    for k in range(len(raw) // 30):
                        b = raw[k * 30:k * 30 + 30]
                        for at in (4, 12, 20):           # upper, lower, middle
                            t = wadlib._name(b[at:at + 8])
                            if t and t != '-':
                                tex.add(t)
                elif sub_ == 'SECTORS':
                    f.seek(lo)
                    raw = f.read(ls)
                    for k in range(len(raw) // 26):
                        b = raw[k * 26:k * 26 + 26]
                        for at in (4, 12):               # floor, ceiling
                            t = wadlib._name(b[at:at + 8])
                            if t and t not in ('-', 'F_SKY1'):
                                flat.add(t)
    return tex, flat


def _shelf(iwad, mapwad):
    """Where to look for the game file a map WAD was built for: beside the map
    WAD, beside the IWAD, and the project's own wads-mapy. DOOMRESWAD names
    files outright and is looked at first."""
    out = []
    for p in os.environ.get(_RES_ENV, '').split(os.pathsep):
        if p and os.path.isfile(p):
            out.append(os.path.abspath(p))
    dirs = []
    for d in (os.path.dirname(os.path.abspath(mapwad or iwad)),
              os.path.dirname(os.path.abspath(iwad)),
              os.path.join(_PROJ, 'wads-mapy'), _PROJ):
        if d and os.path.isdir(d) and d not in dirs:
            dirs.append(d)
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:                                         # pragma: no cover
            continue
        for fn in names:
            if fn.lower().endswith('.wad'):
                p = os.path.abspath(os.path.join(d, fn))
                if p not in out:
                    out.append(p)
    return out


def is_doom1(path):
    """DOOM 1 (DOOM.WAD, DOOM1.WAD): an IWAD with E1M1 -- the only game an
    add-on (new graphics and sounds over its levels) is made for here."""
    try:
        return bool(path) and 'E1M1' in wadlib.Wad(path, pwads=[]).map_names()
    except Exception:
        return False


def wad_kind(path):
    """What a WAD brings, from its lump directory alone -> {'maps': [...],
    'text': one line}. A WAD without maps is an ADD-ON: its graphics, sprites,
    sounds and music replace the IWAD's under the same names."""
    import struct
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            hdr = f.read(12)
            if len(hdr) < 12 or hdr[:4] not in (b'IWAD', b'PWAD'):
                raise ValueError('not a WAD')
            n, off = struct.unpack_from('<ii', hdr, 4)
            if n < 0 or off < 12 or off + 16 * n > size:
                raise ValueError('damaged')
            f.seek(off)
            d = f.read(16 * n)
        names = [d[16 * i + 8:16 * i + 16].split(b'\0')[0].decode('latin-1').upper()
                 for i in range(n)]
    except (OSError, struct.error, ValueError) as e:
        why = 'damaged (its lump directory runs past the end)' if str(e) == 'damaged' \
            else 'not a WAD file'
        return {'maps': [], 'body': why, 'text': why, 'bad': True}
    maps = [x for x in names if re.match(r'^(E\dM\d|MAP\d\d)$', x)]
    inside, sprites, flats = None, 0, 0
    for x in names:                       # the S_/F_ markers, as DOOM reads them
        if x in ('S_START', 'SS_START'):
            inside = 'S'
        elif x in ('F_START', 'FF_START'):
            inside = 'F'
        elif x.endswith('_END'):
            inside = None
        elif inside == 'S':
            sprites += 1
        elif inside == 'F':
            flats += 1
    sounds = sum(1 for x in names if x.startswith(('DS', 'DP')))
    music = sum(1 for x in names if x.startswith('D_'))
    walls = 'TEXTURE1' in names or 'TEXTURE2' in names
    menu = sum(1 for x in names if x.startswith(('M_', 'ST', 'WI', 'TITLEPIC', 'HELP', 'CREDIT')))
    maplump = re.compile(r'^(E\dM\d|MAP\d\d|THINGS|LINEDEFS|SIDEDEFS|VERTEXES|SEGS|'
                         r'SSECTORS|NODES|SECTORS|REJECT|BLOCKMAP|BEHAVIOR|SCRIPTS|'
                         r'.*_START|.*_END|TEXTURE1|TEXTURE2|PNAMES)$')
    other = (len(names) - sprites - flats - sounds - music - menu
             - sum(1 for x in names if maplump.match(x)))
    what = [f'{c} {w}' for c, w in ((len(maps), 'maps'), (sprites, 'sprites'),
                                    (flats, 'flats'), (sounds, 'sounds'),
                                    (music, 'songs'), (menu, 'menu/HUD/screen pictures'),
                                    (other, 'other graphics (wall patches, flats ...)'))
            if c > 0]
    if walls:
        what.append('its own wall textures')
    body = ', '.join(what) or 'nothing the converter uses'
    return {'maps': maps, 'body': body,
            'text': (f'MAP WAD -- {body}' if maps else
                     f'ADD-ON for DOOM 1, no maps -- {body}; it converts DOOM 1\'s '
                     f'own levels and goes with DOOM.WAD alone')}


def as_list(pwads):
    """The map-WAD argument, however it was passed, as a list of paths."""
    if not pwads:
        return []
    if isinstance(pwads, str):
        return [pwads]
    return [p for p in pwads if p]


def resolve_wads(iwad, pwads, maps, log=None):
    """The DOOMPWAD stack to convert with: the map WAD, with the game file its
    maps were built for inserted UNDER it when the names say one is needed.

    Idempotent -- given a stack that already resolves every name it returns that
    stack unchanged, so check() and build() can each ask without piling up."""
    pwads = as_list(pwads)
    log = log or (lambda *_a: None)
    src = pwads[-1] if pwads else iwad
    tex, flat = map_art(src, maps)
    stack = [iwad] + pwads
    seen = {os.path.normcase(os.path.abspath(p)) for p in stack}
    miss_t = {t for t in tex if not any(t in _wad_textures(p) for p in stack)}
    miss_f = {f for f in flat if not any(f in _wad_names(p) for p in stack)}
    if not miss_t and not miss_f:
        return pwads
    # WHICH GAME the selection looks like. The TIE-BREAK only, never the
    # decision: what a candidate actually supplies outranks it.
    fam = 2 if any(map_number(m)[0] is None and map_number(m)[1] is not None
                   for m in maps) else 1
    picked = []
    for _round in range(2):              # needing two files is already exotic
        best, best_key = None, None
        for cand in _shelf(iwad, src):
            if os.path.normcase(cand) in seen:
                continue
            magic, _l = _wad_dir(cand)
            if magic is None:
                continue
            ct, cf = _wad_textures(cand), _wad_names(cand)
            gain_t, gain_f = miss_t & ct, miss_f & cf
            gain = len(gain_t) + len(gain_f)
            if not gain:
                continue
            key = (gain, magic == 'IWAD',
                   _FAMILY.get(os.path.basename(cand).upper()) == fam,
                   -len(ct))             # ...and the tightest set that does
            if best_key is None or key > best_key:
                best, best_key = (cand, gain_t, gain_f), key
        if best is None:
            break
        cand, gain_t, gain_f = best
        picked.append(cand)
        seen.add(os.path.normcase(cand))
        miss_t -= gain_t
        miss_f -= gain_f
        log("   {} names {} wall texture(s) and {} flat(s) {} does not have; {} "
            "has them -- layering it UNDER the map WAD (the map WAD still "
            "wins)".format(os.path.basename(src), len(gain_t), len(gain_f),
                           os.path.basename(iwad), os.path.basename(cand)))
        if not miss_t and not miss_f:
            break
    if miss_t or miss_f:
        if miss_t:
            log("WARNING: {} wall texture(s) are in no WAD on the shelf -- each "
                "is painted as the map's commonest wall: {}{}".format(
                    len(miss_t), ', '.join(sorted(miss_t)[:12]),
                    ', ...' if len(miss_t) > 12 else ''))
        if miss_f:
            log("WARNING: {} flat(s) are in no WAD on the shelf -- those floors "
                "and ceilings come out black: {}{}".format(
                    len(miss_f), ', '.join(sorted(miss_f)[:12]),
                    ', ...' if len(miss_f) > 12 else ''))
        log('   (put the game WAD they came from beside the map WAD, or name it '
            'in {}, and it is picked up automatically)'.format(_RES_ENV))
    return picked + pwads


# ---- how far along a conversion is -------------------------------------------
# The pipeline is a chain of packers that each narrate in their own way, so the
# bar is driven off what they PRINT rather than off a timer: every phase below
# is recognised by a line the step actually emits, and the two that run once per
# map (geometry, textures, things) also fill in between maps. A phase that never
# reports simply does not move the bar -- it never jumps backwards, and it never
# claims to be finished when it is not.
PHASES = [
    ('check',    'reading the maps',           16),
    ('assets',   'sound, weapons, colormap',    6),
    ('geometry', 'packing geometry',           20),
    ('textures', 'packing wall textures',      24),
    ('things',   'packing things and sprites', 16),
    ('layout',   'laying out the disk',         4),
    ('assemble', 'assembling the engine',       8),
    ('image',    'writing the ATR',             6),
]
_PH_AT = {}
_acc = 0
for _k, _t, _w in PHASES:
    _PH_AT[_k] = (_acc, _w, _t)
    _acc += _w


class Progress:
    """percent + one line of "what is happening", for the CLI and the GUI.

    sink(pct, text) does the showing. Everything else here is bookkeeping so
    that callers only ever say WHICH phase they are in and, when it repeats per
    map, how far through the maps they are.
    """

    def __init__(self, sink=None):
        self.sink = sink
        self.pct = 0

    def __call__(self, phase, detail='', done=0, total=0):
        at, weight, text = _PH_AT.get(phase, (self.pct, 0, phase))
        frac = (done / total) if total else 0
        pct = int(at + weight * min(1.0, frac))
        self.pct = max(self.pct, pct)             # never walk backwards
        if self.sink:
            self.sink(self.pct, f'{text}{" " + detail if detail else ""}')

    def finish(self, text='done'):
        self.pct = 100
        if self.sink:
            self.sink(100, text)


def _cli_progress(pct, text):
    print(f'[{pct:3d}%] {text}')


SKILL = 2                        # what the engine ships with (pack_things.SKILL)


# ------------------------------------------------------------ secret levels --
# WHICH MAP IS THE SECRET ONE IS NOT IN THE WAD. Nothing in a map lump says
# "I am the secret level" -- DOOM decides it by map NUMBER, in g_game.c
# G_DoCompleted, and the WAD only supplies the LINE you leave through:
#
#   secret exit lines   51 = S1 switch (p_switch.c:431), 124 = W1 walk-over
#                       (p_spec.c:760). Both call G_SecretExitLevel.
#   normal exit lines   11 = S1 switch, 52 = W1 walk-over, plus sector special
#                       11 (the "die and the level ends" floor, p_spec.c:1054).
#
#   DOOM 1 (gamemode != commercial):  a secret exit sets wminfo.next = 8, i.e.
#     ExM9 -- ANY map of the episode can hold one, and they all lead to the same
#     ninth map. Leaving ExM9 puts you back at a fixed map per episode (the
#     table below), and ExM8 never chains at all: it is ga_victory.
#   DOOM II (commercial): the secret exit only means anything on MAP15 (-> 31)
#     and MAP31 (-> 32); both secret maps return to MAP16.
#
# So this tool can answer the question exactly, and it says which half of the
# answer is the ENGINE's rule and which half it read out of the WAD.
SECRET_EXIT = {51, 124}
NORMAL_EXIT = doomspecs.EXIT - SECRET_EXIT
DOOM1_RETURN = {1: 4, 2: 6, 3: 7, 4: 3}          # G_DoCompleted, +1 (0-biased)
DOOM2_SECRET = {15: 31, 31: 32}                  # from -> to
DOOM2_RETURN = 16                                # ...and both come back here
_EXMY = re.compile(r'^E(\d)M(\d)$')
_MAPXX = re.compile(r'^MAP(\d\d)$')


def map_number(name):
    """'E1M9' -> (1, 9); 'MAP31' -> (None, 31); anything else -> (None, None)"""
    m = _EXMY.match(name.upper())
    if m:
        return int(m.group(1)), int(m.group(2))
    m = _MAPXX.match(name.upper())
    if m:
        return None, int(m.group(1))
    return None, None


def is_secret_map(name):
    """Does the ENGINE treat a map with this name as a secret level?"""
    ep, num = map_number(name)
    if num is None:
        return False
    return num == 9 if ep else num in (31, 32)


def secret_dest(name):
    """The map a SECRET exit in `name` leads to, by g_game.c's rules -- or None
    when the engine ignores a secret exit there (any DOOM II map but 15/31)."""
    ep, num = map_number(name)
    if num is None:
        return None
    if ep:
        return f'E{ep}M9'
    return f'MAP{DOOM2_SECRET[num]:02d}' if num in DOOM2_SECRET else None


def secret_role(name):
    """One line about this map's place in the secret structure, or None."""
    ep, num = map_number(name)
    if not is_secret_map(name):
        return None
    if ep:
        return (f'SECRET LEVEL: the engine sends every secret exit in episode '
                f'{ep} here (g_game.c wminfo.next = 8), and leaving it returns '
                f'to E{ep}M{DOOM1_RETURN.get(ep, 4)}')
    return (f'SECRET LEVEL: MAP{num} is reached from '
            f'MAP{[k for k, v in DOOM2_SECRET.items() if v == num][0]:02d}\'s '
            f'secret exit and returns to MAP{DOOM2_RETURN}')


def secret_survey(wad, maps):
    """[(level, text), ...] -- the secret structure of the WHOLE selection,
    which is the part no single map can answer."""
    out = []
    fmt = {}
    for nm in maps:
        try:
            fmt[nm] = wad.map_format(nm)
        except Exception:                                       # pragma: no cover
            fmt[nm] = 'doom'
    # A HEXEN-format map has NO secret level, and DOOM's rule cannot be pointed
    # at it: DOOM picks the secret map by NUMBER (g_game.c -- ExM9, MAP31/32)
    # and reaches it through a secret EXIT line (51/124), while Hexen is
    # hub-based -- every exit is a Teleport_NewMap and the destination is in
    # that line's own arg0, not in a rule about the map's name. Asking DOOM's
    # question anyway is how hexen.wad's MAP31 came to be announced as "the
    # SECRET level": it is an ordinary map that happens to wear the number.
    # load_map keeps arg0 in the linedef's tag, so the real answer is here.
    hexen = [nm for nm in maps if fmt[nm] == 'hexen']
    doom_maps = [nm for nm in maps if fmt[nm] != 'hexen']
    for nm in hexen:
        try:
            md = wad.load_map(nm)
        except Exception:                                       # pragma: no cover
            continue
        dest = sorted({ld.tag for ld in md.linedefs if ld.special in (11, 52)})
        where = (', '.join(f'MAP{d:02d}' for d in dest) if dest
                 else 'nothing -- no exit line at all')
        out.append(('ok', f'{nm} is a HEXEN map: no secret level in DOOM\'s '
                          f'sense (Hexen has no secret exit special, and '
                          f'MAP31/MAP32 here are ordinary maps that happen to '
                          f'carry those numbers). Its exits lead to {where}'))
    secrets = [nm for nm in doom_maps if is_secret_map(nm)]
    holders = {}
    for nm in doom_maps:
        try:
            md = wad.load_map(nm)
        except Exception:                                       # pragma: no cover
            continue
        n = sum(1 for ld in md.linedefs if ld.special in SECRET_EXIT)
        if n:
            holders[nm] = n
    if not secrets and not holders:
        if not hexen:
            out.append(('ok', 'no secret level in this selection (no ExM9/MAP31/32 '
                              'and no secret exit line)'))
            return out
    for nm in secrets:
        who = [h for h in holders if secret_dest(h) == nm]
        if who:
            out.append(('ok', f'{nm} is the SECRET level, entered from '
                              f'{", ".join(sorted(who))}'))
        else:
            out.append(('WARNING', f'{nm} is the SECRET level, but nothing in '
                                   f'this selection has a secret exit to it -- '
                                   f'vanilla could not reach it either'))
    for nm, n in sorted(holders.items()):
        dest = secret_dest(nm)
        if dest is None:
            out.append(('WARNING', f'{nm} has {n} secret exit line(s), but the '
                                   f'engine ignores a secret exit on this map '
                                   f'number (g_game.c: only MAP15 and MAP31)'))
        elif dest not in maps:
            out.append(('WARNING', f'{nm} has {n} secret exit line(s) leading '
                                   f'to {dest}, which is not in this selection'))
    # ...and what the ATR will actually do with all of it.
    out.append(('ok', 'NOTE: this port has ONE exit. pack_map marks every exit '
                      'line the same (special 11/51/52/124 -> bit7 of low_tex) '
                      'and MAP_HNEXT is simply the next map in the list, '
                      'wrapping at the end -- so a secret map is played in the '
                      'order you tick it here, not through its secret exit.'))
    return out


# ----------------------------------------------------------------- palette --
# The port has ONE 256-entry VBXE palette for the whole screen, and the art on
# it comes from TWO files: the maps' walls and flats from the WAD being
# converted, everything else -- status bar, weapons, monsters, menu, the HU
# strips -- from the IWAD. A WAD that ships its own PLAYPAL (heretic.wad,
# hexen.wad, any total conversion) therefore cannot simply bring it along: it
# would repaint DOOM's own art in Heretic's colours.
#
# So the IWAD's palette ships and wadtex.py remaps the other file's graphics
# into it, nearest colour in RGB, once per file. This reports what that costs.
# (Plain DOOM is untouched: no second palette, no remap, byte-identical output.)
# WIMAP0/WISPLAT/WIURH0/WIA00000 are here for a family the first four miss.
# A DOOM II-family IWAD (doom2.wad, tnt.wad, plutonia.wad) HAS all four of
# those, so the magic plus that list made tnt.wad the IWAD -- and then
# pack_wi died on "WIMAP0 is not in the WAD", because DOOM II's intermission
# is a flat INTERPIC with no map, no splats and no animations, and this port
# bakes episode 1's map screen (wi_stuff.c epsd0animinfo, pack_wi.py). The
# port bakes it, so a file without it cannot be the IWAD -- it goes in the
# PWAD slot and DOOM.WAD supplies the screen, exactly as it does for the
# monsters and the HUD. TNT's own maps, textures, sounds and sprites still
# win: they are the layer on top.
ENGINE_ART = ('STBAR', 'STCFN033', 'M_DOOM', 'TITLEPIC',
              'WIMAP0', 'WISPLAT', 'WIURH0', 'WIA00000')


def missing_engine_art(wad_path):
    """Which of the lumps the PORT ITSELF bakes this file does not have.
    heretic.wad and hexen.wad are IWADs by magic but have none of them, so the
    magic alone would put them in the IWAD slot -- where pack_hud dies on a
    missing STBAR and every colour would come out of the wrong palette."""
    try:
        w = wadlib.Wad(wad_path, pwads=[])
    except Exception:                                           # pragma: no cover
        return ()
    return tuple(nm for nm in ENGINE_ART if nm not in w._index)


def palette_survey(wad):
    """[(level, text), ...] -- whose palette ships and what the others cost."""
    from wadtex import WadTextures
    out = []
    base = os.path.basename(wad.sources[0])
    try:
        wt = WadTextures(wad)
    except Exception as e:                                      # pragma: no cover
        return [('WARNING', f'palette could not be checked: {e}')]
    for src in range(1, len(wad.sources)):                      # measure each
        wt._lut(src)
    notes = wt.remap_note()
    if not notes:
        out.append(('ok', f'palette: {base} PLAYPAL, and nothing layered over '
                          f'it brings its own -- no remapping'))
        return out
    out.append(('ok', f'palette: {base} PLAYPAL ships (the port has ONE screen '
                      f'palette, and the status bar, weapons, monsters and '
                      f'menu are its art)'))
    for n in notes:
        out.append(('ok', n))
    out.append(('ok', 'the light table (COLORMAP) comes from the same file, so '
                      'shading matches the palette that ships'))
    return out


def _limits():
    """The engine's hard caps, read from the modules that enforce them."""
    import pack_map
    import pack_things
    mm = open(os.path.join(_PROJ, 'memory_map.inc')).read()
    doors = int(re.search(r'DOORS_NMAX\s+equ\s+(\d+)', mm).group(1))
    return {
        'things': 255,                        # pack_things keeps the first 255
        'sectors': pack_map.NO_SECTOR,        # $FF is "no sector" on a seg
        'textures': pack_map.NO_TEX,          # $3F is "no texture" on a seg
        'doors': doors,
        'things_blob': pack_things.THINGS_MAX,
    }


# ------------------------------------------------------------------ analysis --
def open_wads(iwad, pwad):
    return wadlib.Wad(iwad, pwads=as_list(pwad))


def analyse(wad, mapname, lim):
    """[(level, text), ...] -- 'ERROR' stops the build, 'WARNING' survives it,
    'ok' is information."""
    out = []
    md = wad.load_map(mapname)
    # A HEXEN-format map (hexen.wad, any ZDoom-in-Hexen PWAD) is read with the
    # Hexen structs and its line specials translated to DOOM's -- see
    # wadlib.load_map and doomspecs.HEXEN_LINE. The geometry, the textures and
    # the flats are exact; what cannot survive is named here.
    if md.hexen:
        acted = sum(1 for ld in md.linedefs if ld.special)
        out.append(('ok', f'HEXEN-format map (BEHAVIOR lump, 16-byte linedefs, '
                          f'20-byte things): read with the Hexen structs, '
                          f'{acted} line special(s) translated to DOOM\'s'))
        if md.dropped:
            n = sum(md.dropped.values())
            worst = ', '.join(f'{doomspecs.hexen_line_name(s)} x{c}' for s, c in
                              sorted(md.dropped.items(), key=lambda kv: -kv[1])[:5])
            # ...and say WHY, but only about the families this map actually
            # has. The sentence used to name ACS_Execute unconditionally, which
            # read as a lie on a map whose only dropped line was a
            # Line_SetIdentification.
            why = []
            if md.dropped.keys() & doomspecs.HEXEN_ACS:
                why.append('ACS_* runs the level\'s compiled SCRIPTS (the '
                           'BEHAVIOR lump) -- most of Hexen\'s puzzles, its '
                           'switches-at-a-distance and its scripted doors')
            if md.dropped.keys() & doomspecs.HEXEN_POLYOBJ:
                why.append('Polyobj_* is Hexen\'s rotating and sliding '
                           'geometry, which this renderer cannot move')
            out.append(('WARNING', f'{n} line(s) carry a Hexen special with no '
                                   f'DOOM equivalent ({worst})'
                                   + (' -- ' + '; '.join(why) if why else '')))
        out.append(('WARNING', 'Hexen sector specials are cleared (its '
                               'lighting/damage/wind numbers are not DOOM\'s), '
                               'and its monsters and items have no sprites in '
                               'this port -- expect an empty, walkable level'))
    n_seg, n_ss, n_nd = len(md.segs), len(md.ssectors), len(md.nodes)
    out.append(('ok', f'{len(md.vertices)} vertices, {len(md.sectors)} sectors, '
                      f'{len(md.linedefs)} lines, {n_seg} segs, {n_ss} subsectors, '
                      f'{n_nd} nodes'))
    if not (n_seg and n_ss and n_nd):
        out.append(('ERROR', 'map has no BSP built (SEGS/SSECTORS/NODES '
                             'missing) -- run it through a nodebuilder (ZDBSP)'))
        return md, out
    # The SEG bank: segs, nodes and their side tables share ONE 64 KB Rapidus
    # bank (pack_map._seg_layout). mtx/lights at the floor's counts -- the
    # packer's own numbers come later; segs, lines and nodes are the bulk.
    import pack_map
    f = pack_map.CAPS_FLOOR
    seg_end = pack_map._seg_layout(f._replace(
        segs=max(f.segs, n_seg), nodes=max(f.nodes, n_nd),
        lines=max(f.lines, len(md.linedefs))))[-1]
    if seg_end > pack_map.SEG_LIMIT:
        out.append(('ERROR', f'{n_seg} segs + {n_nd} nodes need {seg_end} B, the '
                             f'engine\'s seg bank holds {pack_map.SEG_LIMIT} B '
                             f'({seg_end - pack_map.SEG_LIMIT} B over) -- the map '
                             f'is too big for this port'))
    if len(md.sectors) >= lim['sectors']:
        out.append(('ERROR', f'{len(md.sectors)} sectors, the engine holds '
                             f'{lim["sectors"] - 1} (id {lim["sectors"]} means "none")'))

    # --- things ---------------------------------------------------------
    spawn = wadthings.map_things(md, skill=SKILL)
    unknown = [t for (t, base, *_r) in spawn if base is None]
    if len(spawn) > lim['things']:
        out.append(('WARNING', f'{len(spawn)} things at skill {SKILL}, the engine '
                               f'keeps the first {lim["things"]} -- the rest '
                               f'will not appear'))
    else:
        out.append(('ok', f'{len(spawn)} things at skill {SKILL}'))
    if unknown:
        kinds = sorted({t.type for t in unknown})
        out.append(('WARNING', f'{len(unknown)} things of unknown type {kinds} -- '
                               f'not in this port (usually DOOM II monsters)'))

    # --- line types this port does not have, substituted (doomspecs, and
    #     tools/wad/custom/specials.py for the rest of vanilla and Boom) -------
    if md.remapped:
        subs = ', '.join(f'{a}->{b}' + (f' x{n}' if n > 1 else '')
                         for (a, b), n in sorted(md.remapped.items()))
        out.append(('ok', f'{sum(md.remapped.values())} line(s) use a type the '
                          f'port lacks, run as the nearest it has: {subs}'))

    # --- linedef specials ------------------------------------------------
    used = {}
    for ld in md.linedefs:
        if ld.special:
            used[ld.special] = used.get(ld.special, 0) + 1
    miss = {s: n for s, n in used.items()
            if s not in doomspecs.SUPPORTED and s not in doomspecs.LIGHT_LINE}
    if miss:
        out.append(('WARNING', 'unsupported linedef specials (they will do '
                    'nothing): ' +
                    ', '.join(f'{s}x{n}' for s, n in sorted(miss.items()))))
    if used and not miss:
        out.append(('ok', f'all {len(used)} linedef specials used are supported'))

    # --- doors ----------------------------------------------------------
    door_secs = set()
    for ld in md.linedefs:
        if ld.special in doomspecs.MANUAL_DOOR and ld.left != wadlib.NO_SIDEDEF:
            door_secs.add(md.sidedefs[ld.left].sector)
        elif ld.special in doomspecs.TAG_DOOR and ld.tag:
            door_secs |= {s for s, sec in enumerate(md.sectors) if sec.tag == ld.tag}
    if len(door_secs) > lim['doors']:
        out.append(('ERROR', f'{len(door_secs)} doors, the engine has room for '
                             f'{lim["doors"]} (DOORS_NMAX in memory_map.inc)'))
    elif door_secs:
        out.append(('ok', f'{len(door_secs)} doors of {lim["doors"]}'))

    # --- textures -------------------------------------------------------
    # The real packer, not a guess: a seg carries its texid in 6 bits, so a map
    # that names more distinct wall textures than that cannot be drawn at all.
    # (Every wall is textured -- TEX_RUNK-run columns painted out of SDRAM --
    # so a texture costs disk and SDRAM, which scale, and one id, which is
    # the byte that does not.)
    try:
        import contextlib
        import io
        import pack_textures
        from wadtex import WadTextures
        with contextlib.redirect_stdout(io.StringIO()):   # it narrates; we only
            _ptx = pack_textures.pack_map_textures(        # want the verdict
                md, WadTextures(wad))
        table = _ptx[3]
        import pack_map
        # Ids 0..NO_TEX-1 are real and NO_TEX itself means "none", so NO_TEX
        # rows fit -- two-sided MIDDLE textures included: they take ordinary
        # texids and only WHICH seg uses them lives outside the seg record
        # (MAP_SEGMID). E1M3 is exactly 63 once its struts are in, so this is a
        # real ceiling and not a comfortable one.
        if len(table) > pack_map.NO_TEX:
            out.append(('ERROR', f'{len(table)} texture ids, the engine has room '
                                 f'for {pack_map.NO_TEX} (the seg texid is 6 bits, '
                                 f'${pack_map.NO_TEX:02X} = none)'))
        else:
            out.append(('ok', f'{len(table)} texture ids of {pack_map.NO_TEX}'))
        # y-offsets: r_segs' sidedef->rowoffset, one entry per seg where it is
        # visible. seg_draw walks the table with a dey/bpl scan, so past 128
        # entries the XEX does not even assemble (the MAP_NYOFF assert) --
        # freedm.wad MAP01 was the first map to hit it (159, 2026-08-10).
        with contextlib.redirect_stdout(io.StringIO()):
            _yb, _yl, _yh, _yv = pack_map._yoffs(md, _ptx[2], table)
        _ydrop = getattr(pack_map._yoffs, 'dropped', 0)   # custom/hooks.py cap
        if _ydrop:
            out.append(('WARNING', f'{len(_yv) + _ydrop} segs carry a texture '
                                   f'y-offset, the engine holds {len(_yv)}: the '
                                   f'{len(_yv)} longest keep theirs, {_ydrop} '
                                   f'walls draw a few pixels unshifted'))
        elif len(_yv) > 128:
            out.append(('ERROR', f'{len(_yv)} segs carry a texture y-offset, '
                                 f'the engine table holds 128 '
                                 f'(seg_draw.asm MAP_NYOFF)'))
        else:
            out.append(('ok', f'{len(_yv)} segs with a y-offset of 128'))
        # texture heights: the engine keeps texH in one byte and tiles mod
        # texH; vanilla DOOM itself could not tile anything past 128 rows
        # (tutti-frutti), so a custom PWAD texture that tall never looked
        # right on a wall anyway.
        tall = [(t[0], t[3]) for t in table if t[3] > 128]
        over = [(n, h) for n, h in tall if h > 255]
        if over:
            out.append(('ERROR', 'textures taller than 255 rows: ' +
                        ', '.join(f'{n} ({h})' for n, h in over) +
                        ' -- texH is one byte in this engine'))
        elif tall:
            out.append(('WARNING', 'textures taller than 128 rows: ' +
                        ', '.join(f'{n} ({h})' for n, h in tall) +
                        ' -- vanilla DOOM could not tile these either'))
    except AssertionError as e:
        out.append(('ERROR', f'textures: {e}'))
    except Exception as e:                                      # pragma: no cover
        out.append(('WARNING', f'textures could not be checked: {e}'))

    # --- sprites + the things blob --------------------------------------
    # Run the REAL packer. This is the "does it fit in VRAM" question and there
    # is no honest shortcut: how many bytes a map's monsters cost depends on
    # which kinds it spawns, how many rotations each of their frames has and how
    # well they dedup. Every limit below is pack_things' own.
    try:
        import contextlib
        import io
        import pack_things
        from wadtex import WadTextures
        from wadthings import Sprites
        # B2: sprite pixels live in SDRAM and the FIXED VRAM arena caches them
        # (arena_init: textures stopped renting VRAM when the walls went to
        # painted runs). The hard limits left are the frame-id byte, the
        # coltab region and the DTAB rows, all asserted inside pack(); the
        # arena size only decides how much of the bestiary stays warm.
        # pack_things.main() does NOT take the first pack() and call it a
        # day: when piece 1 is over budget it re-packs with the BFG BALL's
        # frames dropped and then with progressively more decorations cut,
        # and only the LAST rung of that ladder decides the build. Walk the
        # same ladder here, or the report errors on maps the build converts.
        with contextlib.redirect_stdout(io.StringIO()):
            wt = WadTextures(wad)
            sprites = Sprites(wad, wt)
            for _bfg, _dc, _oc in [(b, d, o) for b in (True, False)
                                   for d, o in ((0, 0), (24, 0), (48, 0),
                                                (96, 0), (96, 12), (96, 32),
                                                (160, 64))]:
                blob, blk, tab, _th, _dt, _lo, _sc = pack_things.pack(
                    md, sprites, SKILL, _dc, _oc, _bfg)
                if pack_things.things_p1_len(blk) <= pack_things.THINGS_MAX:
                    break
            cut = ([] if _bfg else ['the BFG BALL frames']) +                   ([f'{_dc} decor + {_oc} obstacle decorations']
                   if _dc or _oc else [])
        try:
            mm = open(os.path.join(_PROJ, 'memory_map.inc')).read()
            arena = (int(re.search(r'ARENA_SPR_TOP\s+equ\s+\$([0-9A-Fa-f]+)',
                                   mm).group(1), 16)
                     - int(re.search(r'ARENA_SPR_BASE\s+equ\s+\$([0-9A-Fa-f]+)',
                                     mm).group(1), 16))
        except Exception:                     # pragma: no cover
            arena = 0
        if arena and len(blob) > arena:
            out.append(('ok', f'sprites {len(blob) // 1024} KB > arena '
                              f'{arena // 1024} KB -- the game runs, a full '
                              f'bestiary tour flushes the arena'))
        else:
            out.append(('ok', f'sprites {len(blob) // 1024} KB, arena '
                              f'{arena // 1024} KB ({len(tab)} sprites)'))
        # blk is NOT the thing to measure. pack() returns piece 1 PADDED OUT
        # to the whole THINGS_MAX (load_things reads 31 sectors flat to $C000)
        # with piece 2 behind it, so len(blk) is always THINGS_MAX + piece 2 --
        # comparing it to THINGS_MAX errored on every map that has any piece 2
        # at all (tnt.wad MAP01: 4387 B "over" 3968, actually 982 + 419 B, a
        # quarter of each budget) and could never see the overflow that does
        # matter. The two pieces live in different holes and have their own
        # caps; measure them separately, exactly as pack_things.main() does.
        p1 = pack_things.things_p1_len(blk)
        p2 = len(blk) - pack_things.THINGS_MAX
        if p1 > pack_things.THINGS_MAX:
            out.append(('ERROR', f'things piece 1 is {p1} B > '
                                 f'{pack_things.THINGS_MAX} B at '
                                 f'${pack_things.THINGS_BASE:04X} -- even with '
                                 f'every decoration cut it runs into BTNUPD '
                                 f'(see memory_map.inc)'))
        elif p2 > pack_things.THINGS2_MAX:
            out.append(('ERROR', f'things piece 2 is {p2} B > '
                                 f'{pack_things.THINGS2_MAX} B at '
                                 f'${pack_things.THINGS2_BASE:04X} -- triggers '
                                 f'and teleport destinations, and there are no '
                                 f'cosmetics in there to drop'))
        else:
            out.append(('ok', f'things table: piece 1 {p1} B of '
                              f'{pack_things.THINGS_MAX} B, piece 2 {p2} B of '
                              f'{pack_things.THINGS2_MAX} B'))
        if cut:
            out.append(('WARNING', 'to fit the things table the build drops ' +
                        ' and '.join(cut)))
    except SystemExit as e:
        # the packers' own sys.exit() strings already start with "ERROR:", and
        # the report puts that prefix on too -- "ERROR: ERROR: ..."
        out.append(('ERROR', re.sub(r'^ERROR:\s*', '', str(e).strip())))
    except AssertionError as e:
        # A packer's assert IS an engine limit -- that is how pack_things
        # states them. Filed as a warning, the report said "all clear" and the
        # build then died on the very same assertion with a traceback
        # (level2.txt: 163 triggers). A limit stops the conversion.
        out.append(('ERROR', str(e).strip() or 'a pack_things limit was hit'))
    except Exception as e:                                      # pragma: no cover
        out.append(('WARNING', f'sprites could not be checked: {e}'))

    # --- exit, and which KIND of exit (see the secret-level block above) --
    norm = [ld.special for ld in md.linedefs if ld.special in NORMAL_EXIT]
    secr = [ld.special for ld in md.linedefs if ld.special in SECRET_EXIT]
    death = any(s.special == 11 for s in md.sectors)     # p_spec.c:1054
    if not norm and not secr and not death:
        out.append(('WARNING', 'map has no exit -- it cannot be finished'))
    role = secret_role(mapname)
    if role:
        out.append(('ok', role))
    if secr:
        dest = secret_dest(mapname)
        kinds = ', '.join(f'{s}x{secr.count(s)}' for s in sorted(set(secr)))
        out.append(('ok', f'{len(secr)} SECRET exit line(s) ({kinds}) -> '
                          + (dest if dest else 'nowhere: the engine only '
                             'honours a secret exit on MAP15 and MAP31')))
        if not norm and not death:
            out.append(('WARNING', 'the ONLY way out of this map is the secret '
                                   'exit -- in vanilla it always leads to the '
                                   'secret level'))
    if not any(t.type == 1 for t in md.things):
        out.append(('ERROR', 'map has no player 1 start (thing 1)'))
    return md, out


def check(iwad, pwad, maps, log, prog=None, resolved=False):
    prog = prog or Progress()
    # THE STACK, before anything is read: a map WAD may need the game file its
    # maps were built for underneath it (resolve_wads). build() has already
    # resolved and passes resolved=True, so the report and the conversion are
    # always looking at the same files.
    if not resolved:
        pwad = resolve_wads(iwad, pwad, maps, log)
    pwad = as_list(pwad)
    # POINT THE WHOLE TOOLCHAIN AT THIS STACK, not just the Wad we open here.
    # wadlib captures DEFAULT_WAD/DEFAULT_PWADS from the environment at import,
    # and several packers build their own Wad from those rather than taking one
    # -- fine in a checkout, where the default is tools/DOOM.WAD and it exists,
    # and fatal in the packaged EXE, which ships no DOOM.WAD at all: the
    # texture check died on "No such file or directory: .../engine/tools/
    # DOOM.WAD" while the conversion itself had a perfectly good IWAD in hand.
    os.environ['DOOMWAD'] = wadlib.DEFAULT_WAD = os.path.abspath(iwad)
    wadlib.DEFAULT_PWADS = tuple(os.path.abspath(x) for x in pwad)
    os.environ['DOOMPWAD'] = os.pathsep.join(wadlib.DEFAULT_PWADS)
    log('   WAD stack: '
        + ' + '.join(os.path.basename(p) for p in [iwad] + pwad)
        + '   (later files win)')
    log('')
    # WHAT THE FILES ARE, before anything parses them (custom/formats.py): a
    # damaged WAD, a UDMF map, ZDoom extended nodes or an unbuilt map is SAID,
    # with what to do about it, instead of taking the converter down.
    import formats
    errors = 0
    # WHAT EACH FILE IS: a map WAD, or an ADD-ON (no maps of its own) -- which
    # converts DOOM 1's levels and goes with DOOM.WAD alone
    for p in pwad:
        kind = wad_kind(p)
        log(f'   {os.path.basename(p)}: {kind["text"]}')
        if kind.get('bad'):
            log(f'ERROR: {os.path.basename(p)} is {kind["body"]}')
            return 1
        if not kind['maps']:
            if len(pwad) > 1:
                log(f'ERROR: {os.path.basename(p)} is an ADD-ON -- it goes with '
                    f'DOOM.WAD alone, never with a map WAD')
                return 1
            if not is_doom1(iwad):
                log(f'ERROR: {os.path.basename(p)} is an ADD-ON for DOOM 1 -- '
                    f'the IWAD must be DOOM.WAD or DOOM1.WAD, not '
                    f'{os.path.basename(iwad)}')
                return 1
    rows = formats.survey(pwad, maps)
    if rows:
        log('--- what the WAD is made of ---')
        for level, text in rows:
            log(f'  {"" if level == "ok" else level + ": "}{text}')
            errors += level == 'ERROR'
        log('')
    try:
        wad = open_wads(iwad, pwad)
    except Exception as e:
        log(f'ERROR: the WADs cannot be opened: {e}')
        return errors + 1
    lim = _limits()
    # The IWAD is not just "textures and sprites": the port bakes DOOM's status
    # bar, HU font, menu and title picture into the ATR from it. A game WAD
    # that is not DOOM (heretic.wad, hexen.wad) has none of them, and put in
    # this slot it takes the build down inside pack_hud with a KeyError.
    gone = missing_engine_art(iwad)
    if gone:
        log(f'ERROR: {os.path.basename(iwad)} has no {", ".join(gone)} -- it is '
            f'not a DOOM IWAD. Put it in the MAP WAD field with DOOM.WAD as the '
            f'IWAD: its maps, textures and flats are then used and remapped '
            f'into DOOM\'s palette, and the status bar, weapons and monsters '
            f'stay DOOM\'s (which is the only art this port has).')
        return 1
    for i, nm in enumerate(maps):
        prog('check', nm, i, len(maps))
        log(f'--- {nm} ---')
        try:
            _md, rows = analyse(wad, nm, lim)
        except Exception as e:                                  # pragma: no cover
            log(f'  ERROR: {e}')
            errors += 1
            continue
        for level, text in rows:
            log(f'  {"" if level == "ok" else level + ": "}{text}')
            errors += level == 'ERROR'
    # The secret structure is a property of the SELECTION, not of one map: the
    # map that holds the secret exit and the map it leads to are two different
    # lumps, and either can be missing from the tick list.
    log('')
    log('--- palette ---')
    for survey in (lambda: palette_survey(wad), None, lambda: secret_survey(wad, maps)):
        if survey is None:
            log('')
            log('--- secret levels ---')
            continue
        try:
            for level, text in survey():
                log(f'  {"" if level == "ok" else level + ": "}{text}')
        except Exception as e:                  # a strange WAD: said, not raised
            log(f'  WARNING: could not survey this: {e}')
    log('')
    log(f'== {"CANNOT CONVERT: " + str(errors) + " errors" if errors else "all clear, ready to convert"} ==')
    log('   (the one thing only the conversion itself can see is the map')
    log('    geometry in Atari RAM: the selected maps share one space, so it')
    log('    depends on how many you tick -- pack_map is exact and the build')
    log('    stops there)')
    return errors


# ------------------------------------------------------------------- build ----
def build(iwad, pwad, maps, log, prog=None, name=None):
    """Run the project's own pipeline with the WAD pair pointed at this set.
    name = the ATR's file stem (test-level.py passes 'test-level'); None =
    the WAD's own name, plus the map when there is one.

    The check runs first, always. Without it the first thing a converted map
    that does not fit produces is a Python traceback out of whichever packer
    hit its limit -- true, but not an answer to "why".
    """
    prog = prog or Progress()
    pwad = resolve_wads(iwad, pwad, maps, log)
    if check(iwad, pwad, maps, log, prog, resolved=True):
        log('')
        log('== not converting: fix the maps above, or untick them ==')
        return 1
    log('')
    # A conversion is a SIDE TRIP. build_atr.ps1 has exactly one output name --
    # build/doom.atr -- and it also regenerates the .inc files the assembler
    # reads, so running it on somebody else's maps used to leave the project
    # holding THEIR level list: the shipping ATR gone, and the next plain
    # build_atr.ps1 assembling an XEX for maps that are not ours. Snapshot the lot
    # first and put it back in the finally below; the conversion's own output is
    # copied out before that happens.
    keep = _snapshot()
    # build_atr.ps1 skips pack_weap while weap.bin is newer than pack_weap.py
    # and DOOM.WAD -- the map WAD / add-on is not in that test, so every
    # conversion shipped the PROJECT's guns (ATW1.0.wad's never showed). The
    # tree is in the snapshot: gone here, the project's comes back after.
    for f in ('weap.bin', 'weap.tab'):
        p = os.path.join(_PROJ, 'build', 'assets', 'weap', f)
        if os.path.exists(p):
            os.remove(p)
    # NO MUSIC FROM A CUSTOM WAD (2026-10-07, "wadconv nemusi balit hudbu v
    # custom wadoch"): a map WAD or an add-on gets the web converter's silent
    # set -- every song an empty MUS (webverzia/fd/music_silent.zip, made by
    # tools/web_music.py). Not DOOM 1's songs over somebody else's levels, and
    # their sectors off the disk. The project's own songs come back with the
    # snapshot. DOOM.WAD alone keeps its music.
    silent = os.path.join(_HERE, 'webverzia', 'fd', 'music_silent.zip')
    if pwad and os.path.exists(silent):
        import zipfile
        zipfile.ZipFile(silent).extractall(_PROJ)
        log('   music: none (a custom WAD -- the silent song set)')
    env = dict(os.environ)
    # BUILD THE LAYOUT THE ENGINE IS KNOWN TO RUN (2026-08-30). pack_map sizes
    # every section of the map blob -- and so every address in map_syms.inc --
    # over the levels BEING BUILT. The shipping game always builds all 27, so
    # that is the only blob layout that has ever been played; a conversion is
    # always a handful of maps, gets a smaller layout, and its ATR comes up with
    # broken wall textures. Not this tool's doing: build_atr.ps1 -Full E1M5 on
    # our own DOOM.WAD, no wadconv anywhere, is broken the same way, while the
    # SAME single level built at the 27-level capacities is correct. So ask
    # pack_map for its capacity floor (CAPS_FLOOR) and convert into the layout
    # the engine has actually been run on. Only conversions set this, so the
    # project's own build is untouched.
    env['DOOM_CAPS_FLOOR'] = '1'
    # ...and every Python tool of the build through tools/wad/custom (run.py): what
    # a foreign map WAD or an add-on needs from the packers lives there, in
    # memory, never in the game's own tools/pack_*.py
    env['DOOM_PY'] = os.path.join(_HERE, 'custom', 'py.cmd')
    env['DOOMWAD'] = os.path.abspath(iwad)
    if pwad:
        # The WHOLE stack, in load order -- wadlib splits DOOMPWAD on os.pathsep
        # and layers left to right, so the map WAD stays last and still wins
        # over the game file underneath it.
        env['DOOMPWAD'] = os.pathsep.join(
            os.path.abspath(p) for p in as_list(pwad))
    else:
        env.pop('DOOMPWAD', None)
    script = os.path.join(_PROJ, 'build_atr.ps1')
    # -Time makes build_atr.ps1 print its own `Lap` line per step. Those are
    # the ONLY unambiguous phase markers it has: the pipeline assembles more
    # than once (boot loader, menu overlays, then the engine), so keying the
    # bar off "object file" put it at 94% before the assets were even packed.
    # -Fx127 (2026-10-20): the game is the VBXE FX 1.27 build since 2026-10-19
    # (128-row texture tiles, the raycasting blitter) -- the 1.26 configuration
    # no longer fits bank $01 ("Segment B1 error"), so a conversion builds what
    # the game builds.
    cmd = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', script, '-Time', '-Fx127'] + list(maps)
    log(f'$ DOOMWAD={env["DOOMWAD"]}')
    if pwad:
        log(f'$ DOOMPWAD={env["DOOMPWAD"]}')
    log('$ ' + ' '.join(cmd[-len(maps) - 1:]))
    log('')
    p = subprocess.Popen(cmd, cwd=_PROJ, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                         errors='replace', bufsize=1)
    # Every line the pipeline prints goes into the log: a filter here hid the
    # one line that says WHY a step failed (pack_map's SEG region exit).
    # What each step PRINTS when it gets to work. pack_map, pack_textures and
    # pack_things each emit one line per map, so those three fill in smoothly;
    # the rest are single milestones.
    seen = {}

    def advance(line):
        m = re.match(r'^\s*\[\s*[\d.,]+s\]\s*(.+)$', line)     # build_atr.ps1 Lap
        if m:
            done = m.group(1)
            for key, tag in (('wad assets', 'assets'),
                             ('level assets', 'things'),
                             ('mads', 'assemble'),
                             ('overlay split', 'assemble'),
                             ('ATR image', 'image')):
                if done.startswith(key):
                    return prog(tag, '', 1, 1)
            return
        m = re.match(r'^\s*(\w+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+', line)
        if m and m.group(1) in maps:                  # pack_map's per-map row
            seen['geometry'] = seen.get('geometry', 0) + 1
            return prog('geometry', m.group(1), seen['geometry'], len(maps))
        m = re.match(r'^(\w+): \d+ textures,', line)
        if m:
            seen['textures'] = seen.get('textures', 0) + 1
            return prog('textures', m.group(1), seen['textures'], len(maps))
        m = re.match(r'^(\w+): \d+ things,', line)
        if m:
            seen['things'] = seen.get('things', 0) + 1
            return prog('things', m.group(1), seen['things'], len(maps))
        if 'packing levels' in line:
            return prog('geometry', '', 0, 1)
        if 'wrote atr_layout' in line or 'wrote atr_levels' in line:
            return prog('layout', '', 1, 1)

    for line in p.stdout:
        line = line.rstrip()
        if not line:
            continue
        advance(line)
        log(line)                               # every line: the log shows all of it
    rc = p.wait()
    log('')
    if rc != 0:
        log(f'== BUILD FAILED (code {rc}) -- see the message above ==')
        _restore(keep, log)
        return rc
    # Keep it under the WAD's own name: the pipeline always writes doom.atr,
    # and the next conversion would overwrite it. One ATR per WAD, ready to hand
    # to somebody with an Atari.
    import shutil
    src = os.path.join(_PROJ, 'build', 'doom.atr')
    stem = os.path.splitext(os.path.basename(
        as_list(pwad)[-1] if pwad else iwad))[0]
    if len(maps) == 1:
        stem += f'_{maps[0]}'        # Doom2_MAP01.atr: one ATR per experiment
    if name:
        stem = name                  # the caller's own name (test-level.atr)
    if stem.lower() == 'doom':
        stem = 'doom_conv'        # never the name we are about to restore
    # WHERE IT GOES. From a checkout: build/, beside doom.atr, under the WAD's
    # own name (2026-09-15, "aby aj wadconv.py ukladal testovacie atr do build/,
    # ale s vlastnym nazvom") -- the stem guard above keeps it off doom.atr. In
    # the packaged EXE the project tree is a temp directory that does not
    # survive the run, so there build/ is exactly the wrong place and the ATR
    # still goes beside the WAD they converted.
    if getattr(sys, 'frozen', False):
        _home = os.path.dirname(os.path.abspath(as_list(pwad)[-1])) if pwad \
            else os.path.join(_PROJ, 'build')
        if not os.access(_home, os.W_OK):
            _home = os.path.join(_PROJ, 'build')
    else:
        _home = os.path.join(_PROJ, 'build')
    out = os.path.join(_home, f'{stem}.atr')
    shutil.copyfile(src, out)
    bdir = os.path.join(_PROJ, 'build')
    if _quickstart(out, os.path.join(bdir, 'doom_bsp.lst'),        # no title,
                   os.path.join(bdir, 'doom_bsp.lab'), log):       #   no menu
        log('   straight into the game: title and menu skipped')
    ant = os.path.join(bdir, 'doom_bsp_ant2.atr')             # the ANTONIA II
    if os.path.exists(ant):                                   #   image of it too
        ant_out = os.path.join(_home, f'{stem}_ant2.atr')
        shutil.copyfile(ant, ant_out)
        _quickstart(ant_out, os.path.join(bdir, 'doom_bsp_ant2.lst'),
                    os.path.join(bdir, 'doom_bsp_ant2.lab'), log)
    _restore(keep, log)              # ...and only NOW give the project its own
                                     #    ATR and .inc files back
    log(f'== DONE -> {out} ==')
    log(f'   {len(maps)} maps: {", ".join(maps)}')
    # HAND IT TO THE EMULATOR, or say plainly that there is none. The old path
    # fell through to os.startfile(), i.e. whatever owns the .atr extension --
    # on a machine without Altirra that is a zip tool or nothing, and a
    # conversion that worked looked like it had done nothing at all.
    exe = find_altirra()
    if exe:
        log(f'   Mount it as D1: and boot. Launching {os.path.basename(exe)}...')
        try:
            subprocess.Popen([exe, out])
        except Exception as e:                                  # pragma: no cover
            log(f'   (could not launch {exe}: {e})')
    else:
        log('   Mount it as D1: and boot.')
        log('   (no Altirra found -- put its path in the "Altirra (.exe)" box '
            'and it is remembered, or set the ALTIRRA environment variable)')
    return 0


# --------------------------------------------------------------------- GUI ----
def run_gui():
    """Four steps, top to bottom, each saying what it holds:

      1  DOOM 1        the IWAD: DOOM.WAD / DOOM1.WAD (textures, monsters,
                       sounds, the status bar and menus the port bakes)
      2  YOUR WAD      ONE file: a MAP WAD (its levels), or an ADD-ON (no maps:
                       new monsters, graphics, sounds for DOOM 1's own levels --
                       ATW1.0.wad). An add-on goes with DOOM.WAD alone.
      3  LEVELS        what will be converted, with the map drawn
      4  CONVERT       CHECK (what survives, what does not) and MAKE ATR

    and the log and the progress under them. Altirra (the emulator) on top."""
    import tkinter as tk
    from tkinter import filedialog, ttk

    root = tk.Tk()
    root.title('wadconv  --  DOOM maps and add-ons to an Atari ATR')
    root.minsize(860, 400)
    # A SCROLLED BODY (2026-10-07): the steps, the levels and the log are
    # ~720 px, and on a short screen (864 px, the taskbar takes its share) the
    # bottom of the window was simply out of reach. Everything goes in `body`,
    # inside a canvas with a scrollbar; the window opens no taller than the
    # screen leaves, and the wheel scrolls it (the level list and the log keep
    # their own wheel).
    outer = tk.Canvas(root, highlightthickness=0)
    vbar = ttk.Scrollbar(root, orient='vertical', command=outer.yview)
    outer.configure(yscrollcommand=vbar.set)
    vbar.pack(side='right', fill='y')
    outer.pack(side='left', fill='both', expand=True)
    body = ttk.Frame(outer)
    body_id = outer.create_window(0, 0, window=body, anchor='nw')
    # TWO COLUMNS (2026-10-07): the files, CONVERT and the log on the left,
    # the levels and their map on the right -- one column of everything was
    # taller than a 864 px screen and the Altirra path fell off the bottom.
    leftc = ttk.Frame(body, width=560)
    leftc.pack(side='left', fill='both', expand=False)
    rightc = ttk.Frame(body)
    rightc.pack(side='left', fill='both', expand=True)

    def fit_body(_e=None):
        need = body.winfo_reqheight()
        outer.itemconfigure(body_id, width=outer.winfo_width(),
                            height=max(need, outer.winfo_height()))
        outer.configure(scrollregion=(0, 0, outer.winfo_width(),
                                      max(need, outer.winfo_height())))
    body.bind('<Configure>', fit_body)
    outer.bind('<Configure>', fit_body)

    def wheel(e):
        if isinstance(e.widget, (tk.Listbox, tk.Text)):
            return                                # their own scrolling
        if body.winfo_reqheight() > outer.winfo_height():
            outer.yview_scroll(-e.delta // 120, 'units')
    root.bind_all('<MouseWheel>', wheel)
    cfg = load_cfg()
    i0, w0 = fix_slots(cfg.get('iwad') or (default_iwad() if os.path.exists(default_iwad())
                                            else ''), cfg.get('pwad', ''))
    iwad = tk.StringVar(value=i0)          # (a remembered map WAD in step 1 moves to
    pwad = tk.StringVar(value=w0)          #   step 2 at start-up too: fix_slots)
    altirra = tk.StringVar(value=find_altirra())
    busy = {'on': False}
    style = ttk.Style(root)
    style.configure('Step.TLabelframe.Label', font=('Segoe UI', 10, 'bold'))
    BLUE, RED, GREEN, GREY = '#1d5fbf', '#c0302a', '#23843c', '#666666'

    def step(parent, title):
        f = ttk.LabelFrame(parent, text=title, style='Step.TLabelframe',
                           padding=(8, 4))
        f.pack(fill='x', padx=(8, 4), pady=(6, 0))
        return f

    def file_row(parent, var, what, on_pick, types=None, clear=None):
        f = ttk.Frame(parent)
        f.pack(fill='x')
        ttk.Entry(f, textvariable=var).pack(side='left', fill='x', expand=True)

        def pick():
            p = filedialog.askopenfilename(
                title=what, filetypes=types or [('WAD', '*.wad *.WAD'),
                                                ('everything', '*.*')])
            if p:
                on_pick(p)
        ttk.Button(f, text='Browse...', command=pick).pack(side='left', padx=(6, 0))
        if clear:
            ttk.Button(f, text='Clear', command=clear).pack(side='left', padx=(4, 0))
        return f

    # ---- the emulator: at the TOP (2026-10-07). At the bottom it was never
    # seen -- the window is 844 px tall and a 864 px screen puts its bottom
    # edge under the taskbar, so the field existed and nobody could reach it.
    setf = ttk.LabelFrame(leftc, text='Altirra  (the emulator MAKE ATR boots '
                                     'the ATR in -- remembered)',
                          style='Step.TLabelframe', padding=(8, 4))
    setf.pack(fill='x', padx=(8, 4), pady=(6, 0))

    def pick_altirra(p):
        altirra.set(p)
        save_cfg(altirra=p)
        os.environ['ALTIRRA'] = p
    file_row(setf, altirra, 'Pick Altirra64.exe / Altirra.exe', pick_altirra,
             types=[('Altirra', 'Altirra*.exe'), ('programs', '*.exe'),
                    ('everything', '*.*')])

    # ---- 1  DOOM 1 ----------------------------------------------------------
    s1 = step(leftc, '1   DOOM 1  (the IWAD: DOOM.WAD or DOOM1.WAD)')

    def pick_iwad(p):
        i_, w_ = fix_slots(p, pwad.get(), log)
        iwad.set(i_)
        if w_ != pwad.get():
            pwad.set(w_)
        show_iwad()
        show_kind()
        reload_maps()
    file_row(s1, iwad, 'Pick DOOM.WAD', pick_iwad)
    iwadl = tk.Label(s1, text='', anchor='w', justify='left')
    iwadl.pack(fill='x')

    def show_iwad():
        p = iwad.get()
        if not p or not os.path.exists(p):
            iwadl.config(text='pick DOOM.WAD -- the textures, monsters, sounds, '
                              'status bar and menus come from it', fg=RED)
        elif missing_engine_art(p):
            iwadl.config(text=f'{os.path.basename(p)} is not a DOOM IWAD (no '
                              f'{", ".join(missing_engine_art(p))}) -- put '
                              f'DOOM.WAD here and this file in step 2', fg=RED)
        elif is_doom1(p):
            n = len(wadlib.Wad(p, pwads=[]).map_names())
            iwadl.config(text=f'DOOM 1, {n} levels -- ready', fg=GREEN)
        else:
            iwadl.config(text=f'{os.path.basename(p)}: a DOOM IWAD, but not DOOM 1 '
                              f'-- map WADs work, add-ons do not', fg=BLUE)

    # ---- 2  YOUR WAD --------------------------------------------------------
    s2 = step(leftc, '2   YOUR WAD  (a map WAD, or an add-on for DOOM 1)')

    def clear_pwad():
        pwad.set('')
        show_kind()
        reload_maps()
    file_row(s2, pwad, 'Pick your WAD: maps, or an add-on for DOOM 1',
             lambda p: place(p), clear=clear_pwad)
    kindl = tk.Label(s2, text='', anchor='w', justify='left',
                     font=('Segoe UI', 9, 'bold'))
    kindl.pack(fill='x')
    kindd = tk.Label(s2, text='', anchor='w', justify='left', fg=GREY,
                     wraplength=520)
    kindd.pack(fill='x')

    def place(p):
        """ONE WAD, placed by what is IN it. An add-on converts DOOM 1's own
        levels, so it needs DOOM 1 in step 1 and stands alone."""
        kind = wad_kind(p)
        if kind.get('bad'):
            log(f'ERROR: {os.path.basename(p)} is {kind["body"]}')
            return
        if not kind['maps'] and not is_doom1(iwad.get()):
            log(f'ERROR: {os.path.basename(p)} is an ADD-ON ({kind["body"]}) -- '
                f'an add-on goes with DOOM 1 only (DOOM.WAD or DOOM1.WAD), not '
                f'{os.path.basename(iwad.get()) or "no IWAD"}')
            return
        pwad.set(p)
        show_kind(log_it=True)
        reload_maps()

    def show_kind(log_it=False):
        p = pwad.get()
        if not p:
            kindl.config(text='none -- DOOM 1\'s own levels are listed', fg=GREY)
            kindd.config(text='Pick a map WAD to convert its levels, or an add-on '
                              '(new monsters, graphics, sounds) to convert DOOM 1\'s '
                              'levels in its look.')
            return
        kind = wad_kind(p)
        if kind['maps']:
            kindl.config(text=f'MAP WAD  --  {len(kind["maps"])} level(s)', fg=BLUE)
            kindd.config(text=f'{kind["body"]}. What it does not bring comes from '
                              f'{os.path.basename(iwad.get()) or "the IWAD"}.')
        else:
            kindl.config(text='ADD-ON for DOOM 1  --  no levels of its own', fg=BLUE)
            kindd.config(text=f'{kind["body"]}. It converts DOOM 1\'s own levels in '
                              f'its graphics and sounds, and goes with DOOM.WAD '
                              f'alone -- never with a map WAD.')
        if log_it:
            log(f'{os.path.basename(p)}: {kind["text"]}')

    def stack():
        """DOOMPWAD: the one WAD of step 2."""
        return [pwad.get()] if pwad.get() else []

    # ---- 3  LEVELS ----------------------------------------------------------
    s3 = ttk.LabelFrame(rightc, text='3   LEVELS  (Ctrl / Shift for several)',
                        style='Step.TLabelframe', padding=(8, 4))
    s3.pack(fill='both', expand=True, padx=(4, 8), pady=(6, 8))
    left = ttk.Frame(s3)
    left.pack(side='left', fill='y')
    lst = tk.Listbox(left, selectmode='extended', width=22, height=24,
                     exportselection=False)
    lst.pack(fill='y', expand=True)
    lb = ttk.Frame(left)
    lb.pack(fill='x', pady=(4, 0))
    ttk.Button(lb, text='All', width=6,
               command=lambda: lst.selection_set(0, 'end')).pack(side='left')
    ttk.Button(lb, text='None', width=6,
               command=lambda: lst.selection_clear(0, 'end')).pack(side='left', padx=4)
    from mapview import MapView                          # the same automap the
    dummy = tk.StringVar()                               # level tester draws
    view = MapView(s3, tk, dummy, lambda _sp: None)
    view.canvas.config(height=440, width=520)
    view.canvas.pack(side='left', fill='both', expand=True, padx=(8, 0))

    # ---- 4  CONVERT ---------------------------------------------------------
    s4 = step(leftc, '4   CONVERT')
    brow = ttk.Frame(s4)
    brow.pack(fill='x')
    ttk.Button(brow, text='CHECK', width=14,
               command=lambda: spawn(check)).pack(side='left')
    tk.Button(brow, text='MAKE ATR', width=16, font=('Segoe UI', 10, 'bold'),
              command=lambda: spawn(build)).pack(side='left', padx=8)
    prow = ttk.Frame(s4)                         # the bar under the buttons:
    prow.pack(fill='x', pady=(4, 0))             #   the left column is narrow
    pbar = ttk.Progressbar(brow, maximum=100, length=200)
    pbar.pack(side='left', fill='x', expand=True, padx=(8, 0))
    pnum = tk.Label(brow, text='', width=5, anchor='e')
    pnum.pack(side='left', padx=(6, 4))
    pwhat = tk.Label(prow, text='idle', anchor='w', fg=GREY)
    pwhat.pack(side='left', fill='x', expand=True)

    def show_progress(pct, text):
        pbar['value'] = pct
        pnum.config(text=f'{pct}%')
        pwhat.config(text=text)
        brow.update_idletasks()

    # ---- the log -------------------------------------------------------
    logf = ttk.Frame(leftc)
    logf.pack(fill='both', expand=True, padx=(8, 4), pady=(6, 8))
    log_box = tk.Text(logf, wrap='word', height=14, width=70, bg='#101014', fg='#d8d8d8',
                      insertbackground='#d8d8d8', font=('Consolas', 9))
    log_box.pack(side='left', fill='both', expand=True)
    scroll = ttk.Scrollbar(logf, command=log_box.yview)
    scroll.pack(side='left', fill='y')
    log_box.config(yscrollcommand=scroll.set)
    log_box.tag_config('ERROR', foreground='#ff6b6b')
    log_box.tag_config('WARNING', foreground='#ffd24d')
    log_box.tag_config('OK', foreground='#6bff9b')
    def log(text=''):
        tag = ('ERROR' if 'ERROR' in text or 'FAILED' in text
               or 'CANNOT' in text
               else 'WARNING' if 'WARNING' in text
               else 'OK' if 'DONE' in text or 'all clear' in text else '')
        log_box.insert('end', text + '\n', tag)
        log_box.see('end')
        log_box.update_idletasks()

    def reload_maps():
        """The levels of the WAD being converted: the map WAD's, or -- with an
        add-on or nothing in step 2 -- DOOM 1's own."""
        lst.delete(0, 'end')
        src = pwad.get() if pwad.get() and wad_kind(pwad.get())['maps'] else iwad.get()
        if not src or not os.path.exists(src):
            return
        try:
            srcwad = wadlib.Wad(src, pwads=[])
            names = game_order(srcwad.map_names())
        except Exception as e:
            log(f'ERROR: {os.path.basename(src)} cannot be read: {e}')
            return
        if not names:
            log(f'WARNING: no levels in {os.path.basename(src)} '
                f'(looking for ExMy or MAPxx)')
            return
        # The secret level is marked in the list (DOOM picks it by NUMBER,
        # g_game.c); a HEXEN-format map never is -- Hexen is a hub game and its
        # MAP31/32 are ordinary maps. selected() splits the mark back off.
        def marked_secret(nm):
            try:
                if srcwad.map_format(nm) == 'hexen':
                    return False
            except Exception:                                   # pragma: no cover
                pass
            return is_secret_map(nm)
        def mark(nm):
            if marked_secret(nm):
                return f'{nm}  (secret)'
            ep, n = map_number(nm)
            try:
                hexen = srcwad.map_format(nm) == 'hexen'
            except Exception:                                   # pragma: no cover
                hexen = False
            if hexen:
                return nm
            if ep is None and n == 30:
                return f'{nm}  (final)'           # Icon of Sin: the game ends
            if ep is not None and n == 8:
                return f'{nm}  (episode end)'     # g_game.c: gamemap == 8
            return nm
        for nm in names:
            lst.insert('end', mark(nm))
        lst.selection_set(0, 'end')
        log(f'{os.path.basename(src)}: {len(names)} level(s) -- {", ".join(names)}')
        sec = [nm for nm in names if marked_secret(nm)]
        if sec:
            log(f'secret level(s): {", ".join(sec)} -- CHECK says which map '
                f'holds the secret exit that leads there')
        lst.activate(0)
        lst.selection_anchor(0)
        root.after(150, preview)          # once the canvas has its real size

    def selected():
        return [lst.get(i).split()[0] for i in lst.curselection()]

    def preview(*_a):
        """Draw the level under the cursor -- as it will go on the disk."""
        if not lst.size():
            return
        # 'anchor' is the row just clicked (or moved to with the keys) -- set
        # BEFORE <<ListboxSelect>> fires; 'active' follows only afterwards, so
        # it drew the previously clicked level
        nm = lst.get('anchor').split()[0]
        try:
            wad = open_wads(iwad.get(), stack() or None)
            view.load(wad.load_map(nm))
            dummy.set('')
        except Exception as e:                                  # pragma: no cover
            log(f'WARNING: {nm} cannot be drawn: {e}')

    lst.bind('<<ListboxSelect>>', preview)

    def spawn(fn, *a):
        if busy['on']:
            return
        if not iwad.get() or not os.path.exists(iwad.get()):
            log('ERROR: step 1 -- pick DOOM.WAD first')
            return
        maps = selected()
        if not maps:
            log('WARNING: step 3 -- pick at least one level')
            return
        i_, w_ = fix_slots(iwad.get(), pwad.get(), log)   # a map WAD in step 1
        if (i_, w_) != (iwad.get(), pwad.get()):
            iwad.set(i_)
            pwad.set(w_)
            show_iwad()
            show_kind()
        busy['on'] = True
        save_cfg(iwad=iwad.get(), pwad=pwad.get(), altirra=altirra.get())
        if altirra.get():
            os.environ['ALTIRRA'] = altirra.get()
        log_box.delete('1.0', 'end')
        prog = Progress(show_progress)
        show_progress(0, 'starting')

        def work():
            try:
                fn(iwad.get(), stack() or None, maps, log, prog, *a)
            except Exception as e:                              # pragma: no cover
                log(f'ERROR: {type(e).__name__}: {e}')
            finally:
                busy['on'] = False
                prog.finish('done' if prog.pct >= 100 else 'stopped')
        threading.Thread(target=work, daemon=True).start()

    show_iwad()
    show_kind()
    reload_maps()
    root.update_idletasks()               # open as tall as the screen allows
    w = min(max(860, body.winfo_reqwidth() + vbar.winfo_reqwidth()),
            root.winfo_screenwidth() - 40)
    h = min(body.winfo_reqheight(), root.winfo_screenheight() - 120)
    root.geometry(f'{w}x{h}+{max(0, (root.winfo_screenwidth() - w) // 2)}+20')
    log('1 DOOM.WAD   2 your WAD (maps or an add-on)   3 the levels   4 CHECK, MAKE ATR')
    root.mainloop()


def main():
    a = sys.argv[1:]
    if not a:
        return run_gui()
    mode = a[0]
    if mode not in ('--check', '--build'):
        sys.exit(__doc__)
    p = a[1]
    maps = a[2:]
    try:
        return _cli(mode, p, maps)
    except SystemExit:
        raise
    except Exception as e:                # a WAD nobody foresaw: SAY it (the
        if os.environ.get('WADCONV_DEBUG'):   # trace with WADCONV_DEBUG=1)
            import traceback
            traceback.print_exc()
        print(f'ERROR: {os.path.basename(p)} cannot be converted: '
              f'{type(e).__name__}: {e}')
        return 1


def _cli(mode, p, maps):
    kind = wad_kind(p)
    if kind.get('bad'):
        print(f'ERROR: {os.path.basename(p)} is {kind["body"]}')
        print('== CANNOT CONVERT: 1 errors ==')
        return 1
    # WHICH SLOT the file goes in is decided by what is IN it, not by the magic
    # word. heretic.wad and hexen.wad are IWADs and still belong in the map
    # slot: they have maps, textures and flats but none of the art the port
    # bakes (STBAR, the HU font, M_DOOM, TITLEPIC), so DOOM.WAD has to supply
    # that -- and then wadtex remaps their graphics into DOOM's palette.
    layered = open(p, 'rb').read(4) == b'PWAD' or bool(missing_engine_art(p))
    iwad = default_iwad() if layered else p
    pw = p if layered else None
    if layered and iwad != p:
        print(f'{os.path.basename(p)} -> layered over '
              f'{os.path.basename(iwad)}')
    if not maps:
        maps = game_order(wadlib.Wad(p, pwads=[]).map_names())
    print(f'{os.path.basename(p)}: {wad_kind(p)["text"]}')
    if pw and not wad_kind(p)['maps']:   # an ADD-ON: the IWAD's own levels
        if not is_doom1(iwad):           #   in its graphics and sounds --
            sys.exit(f'ERROR: an add-on goes with DOOM 1 only (DOOM.WAD or '
                     f'DOOM1.WAD), not {os.path.basename(iwad)}')
        if not maps:
            maps = wadlib.Wad(iwad, pwads=[]).map_names()
        print(f'   -> the levels of {os.path.basename(iwad)} in its graphics')
    fn = check if mode == '--check' else build
    prog = Progress(_cli_progress)
    rc = fn(iwad, pw, maps, print, prog)
    if not rc:
        prog.finish('done')
    return rc


if __name__ == '__main__':
    sys.exit(main() or 0)
