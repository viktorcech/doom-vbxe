#!/usr/bin/env python3
"""Level-skip test GUI: pick a level (and a spot on it) -> patched TEST ATR -> boot.

THREE patches, all into a COPY (build/doom_test.atr -- the shipping ATR is
never touched):

  1. THE LEVEL. The engine boots into `lda #0 / sta current_level` (bsp_main.asm,
     "; E1M1"). Patching current_level's dta byte would be useless -- that init
     overwrites it -- so this patches the OPERAND of the `lda #0` inside the XEX
     portion of the ATR. The operand address comes from build/doom_bsp.lst
     (regenerated every build), the XEX file offset from walking the segment
     headers, and the ATR offset is fixed: the XEX is stored linearly from
     sector 4 (make_atr_doom.py).

  1b. THE EPISODE PICKER'S TABLE. Patch 1 stopped being enough on 2026-08-18,
     when NEW GAME grew m_menu.c's episode submenu (m_episode.asm): menu_boot
     runs the picker before load_level_c and `lda ep_lvl,x / sta current_level`
     overwrites the boot value, so every test landed on E1M1/E2M1/E3M1 instead
     of the chosen level. All three ep_lvl entries take the test level, which
     also means it does not matter which episode gets picked. The table is NOT
     in the XEX -- split_menu_ovl.py lifted the overlay into menu.bin's chunk
     MENU_LVCH -- so its ATR offset comes from MENU_SEC1 + MENU_LVCH*32.

  2. THE SPAWN POINT. make_atr_doom.py drops each level's .bin verbatim at
     sector LVL_SEC1 + n*LVL_SECTORS, and its first 32 bytes are the runtime
     header -- sx at +12, sy at +14, angle at +16, eye Z at +18 (pack_map.py,
     MAP_HSX.. in map_syms.inc). So the player can start ANYWHERE without
     repacking anything: walking across E1M3 to reach the stairs by the exit
     door, or across E1M2 to reach a lift, is most of the cost of testing them.

  python tools/wad/testlevel.py                    # GUI: level buttons + a spot picker
                                                 # (X,Y,uhol box: type a spot, Enter)
  python tools/wad/testlevel.py --cli 3            # E1M3 from its normal start
  python tools/wad/testlevel.py --cli 3 --warp stairs
  python tools/wad/testlevel.py --cli 2 --warp lift:3
  python tools/wad/testlevel.py --cli 3 --at -256,-1600,192
  python tools/wad/testlevel.py --list 3           # what is worth testing on E1M3
  python tools/wad/testlevel.py --cli 3 --warp stairs --nolaunch

The spots come out of the WAD itself, with tools/doomspecs.py saying what each
linedef special means, so they follow the map instead of a hand-typed table.

Emulator: %ALTIRRA% if set, else Altirra64/Altirra on PATH, else the .atr file
association (os.startfile).
"""
import math
import os
import re
import shutil
import struct
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

_TOOLS = os.path.dirname(_HERE)          # tools/ -- the build half
_PROJ = os.path.dirname(_TOOLS)          # repo root -- this file lives in tools/wad/
sys.path.insert(0, _HERE)
sys.path.insert(0, _TOOLS)
LST = os.path.join(_PROJ, 'build', 'doom_bsp.lst')
SRC_ATR = os.path.join(_PROJ, 'build', 'doom.atr')
OUT_ATR = os.path.join(_PROJ, 'build', 'doom_test.atr')
INC = os.path.join(_PROJ, 'atr_layout.inc')

SECTOR_SIZE = 128
XEX_SEC = 4                          # make_atr_doom.py: XEX from sector 4
ATR_HEADER = 16
HDR_SX, HDR_SY, HDR_ANG, HDR_EYE = 12, 14, 16, 18      # pack_map.py's header
EYE = 41                             # pack_map.EYE -- DOOM view height


def _inc(name, default):
    m = re.search(rf'{name}\s+equ\s+(\d+)', open(INC).read())
    return int(m.group(1)) if m else default


def _equ(inc, name):
    """`NAME equ $1234` / `NAME equ 42` out of any generated include."""
    src = open(os.path.join(_PROJ, inc), encoding='latin-1').read()
    m = re.search(rf'^\s*{name}\s+equ\s+(\$?[0-9A-Fa-f]+)', src, re.M)
    if not m:
        sys.exit(f'testlevel: {name} is not in {inc} -- run build_atr.ps1')
    v = m.group(1)
    return int(v[1:], 16) if v.startswith('$') else int(v)


def num_levels():
    return _inc('NUM_LEVELS', 9)


def level_names():
    """The ATR's level list, index order -- make_atr_doom.py stamps it into
    atr_layout.inc (`; LEVELS E1M1 ...`) so multi-episode builds name their
    buttons right. Falls back to E1M1..n for an older .inc."""
    m = re.search(r';\s*LEVELS\s+([A-Z0-9 ]+)', open(INC).read())
    if m:
        return m.group(1).split()
    return [f'E1M{i + 1}' for i in range(num_levels())]


def lvname(i):
    names = level_names()
    return names[i] if 0 <= i < len(names) else f'LV{i + 1}'


# ---------------------------------------------------------------- the level --
def find_patch_addr():
    """Address of the `lda #0` operand feeding `sta current_level ; E1M1`."""
    prev = None
    code = re.compile(r'^\s*\d+\s+([0-9A-F]{4})\s+([0-9A-F]{2}(?: [0-9A-F]{2})*)\t+(.*)$')
    for line in open(LST, encoding='latin-1'):
        m = code.match(line.rstrip('\n'))
        if not m:
            continue
        if 'sta current_level' in m.group(3) and 'E1M1' in m.group(3):
            if prev is None:
                break
            addr, byts, src = prev
            if not (byts.startswith('A9 ') and 'lda #0' in src):
                sys.exit(f'testlevel: expected `lda #0` before the boot '
                         f'`sta current_level`, found: {src.strip()!r} -- '
                         f'bsp_main.asm changed, update find_patch_addr()')
            return addr + 1          # A9 xx -> xx
        prev = (int(m.group(1), 16), m.group(2), m.group(3))
    sys.exit('testlevel: `sta current_level ; E1M1` not found in build/doom_bsp.lst '
             '-- rebuild first (build_atr.ps1)')


def find_ep_lvl():
    """Run address of m_episode.asm's ep_lvl -- the level index NEW GAME's
    episode picker writes into current_level. Since the picker landed
    (2026-08-18) the boot `lda #0 / sta current_level` is NOT enough on its own:
    menu_boot runs the picker before load_level_c and the pick overwrites it."""
    code = re.compile(r'^\s*\d+\s+([0-9A-F]{4})\s+([0-9A-F]{2}(?: [0-9A-F]{2})*)\t+(.*)$')
    for line in open(LST, encoding='latin-1'):
        m = code.match(line.rstrip())
        if m and m.group(3).lstrip().startswith('ep_lvl') and 'dta' in m.group(3):
            return int(m.group(1), 16), m.group(2).split()
    sys.exit('testlevel: ep_lvl not found in build/doom_bsp.lst -- rebuild '
             '(build_atr.ps1), or m_episode.asm renamed the table')


def epi_atr_off(addr):
    """ATR byte offset of an address inside the EPISODE overlay. It is not in
    the XEX at all: split_menu_ovl.py lifts the block out and drops it into
    menu.bin's chunk MENU_LVCH, which make_atr_doom.py writes at MENU_SEC1."""
    menu_run = _equ('memory_map.inc', 'MENU_RUN')
    sec = _equ('atr_layout.inc', 'MENU_SEC1') + _equ('menu_syms.inc', 'MENU_LVCH') * 32
    return ATR_HEADER + (sec - 1) * SECTOR_SIZE + (addr - menu_run)


def xex_offset(data, addr):
    """File offset of `addr` inside a segmented XEX blob."""
    i = 0
    while i + 4 <= len(data):
        if data[i:i + 2] == b'\xff\xff':     # $FFFF marker(s) before a header
            i += 2
            continue
        s, e = struct.unpack('<HH', data[i:i + 4])
        i += 4
        if s <= addr <= e:
            return i + (addr - s)
        i += e - s + 1
    sys.exit(f'testlevel: ${addr:04X} not inside any XEX segment')


# ---------------------------------------------------------------- the spawn --
_wad_cache = {}


def wad_map(level):
    """wadlib MapData for level (0-based). Cached -- the GUI asks repeatedly."""
    if level not in _wad_cache:
        import wadlib
        _wad_cache[level] = wadlib.Wad().load_map(lvname(level))
    return _wad_cache[level]


NF_SUBSECTOR = 0x8000


# The automap moved to mapview.py (2026-08-30) so wadconv.py can have it
# without this whole level tester. Same objects, one definition.
from mapview import (LINE_COLS, C_BG, C_DOOR, C_FLOOR, C_SECRET, C_STEP,
                     C_WALL, MapView, locate, parse_at)   # noqa: E402,F401

def _stand_by_line(md, li):
    """(x, y, ang, sector): a few units off linedef `li`, FACING it.

    Which side: the one with the LOWER floor. A lift, a stair flight and a
    raising floor are all approached from below, and starting on the high side
    means standing on top of the very thing being tested. Both sides and a few
    distances are tried until the point really lands in the sector it is meant
    to be in -- the midpoint of a long line can sit outside a small room."""
    from wadlib import NO_SIDEDEF
    ld = md.linedefs[li]
    v1, v2 = md.vertices[ld.v1], md.vertices[ld.v2]
    dx, dy = v2.x - v1.x, v2.y - v1.y
    ln = math.hypot(dx, dy) or 1.0
    mx, my = (v1.x + v2.x) / 2.0, (v1.y + v2.y) / 2.0
    sides = []
    if ld.right != NO_SIDEDEF:
        s = md.sidedefs[ld.right].sector
        sides.append((md.sectors[s].floor_h, 1, s))       # +1 = DOOM's side 0
    if ld.left != NO_SIDEDEF:
        s = md.sidedefs[ld.left].sector
        sides.append((md.sectors[s].floor_h, -1, s))
    sides.sort()                                          # lowest floor first
    for _fh, sgn, sec in sides:
        nx, ny = sgn * dy / ln, -sgn * dx / ln
        for dist in (56, 40, 72, 96, 28):
            px, py = int(round(mx + nx * dist)), int(round(my + ny * dist))
            if locate(md, px, py) != sec:
                continue
            ang = int(round(math.degrees(math.atan2(-ny, -nx)) * 256 / 360)) & 0xFF
            return px, py, ang, sec
    return None


def landmarks(level):
    """[(kind, label, x, y, ang, sector)] -- spots worth booting straight into.

    Read out of the WAD, with doomspecs.py saying what each special is, so a
    different level set needs no table here."""
    import doomspecs
    from wadlib import NO_SIDEDEF
    md = wad_map(level)
    groups = [('stairs', {7, 8}), ('lift', {88, 62, 21}), ('donut', {9}),
              ('floor', doomspecs.FLOORS - {7, 8, 88, 62, 21, 9}),
              ('tele', doomspecs.TELEPORT), ('exit', doomspecs.EXIT),
              ('door', doomspecs.TAG_DOOR)]
    out, seen = [], set()
    for kind, specials in groups:
        n = 0
        for li, ld in enumerate(md.linedefs):
            if ld.special not in specials:
                continue
            spot = _stand_by_line(md, li)
            if not spot or spot[:2] in seen:
                continue
            seen.add(spot[:2])
            n += 1
            out.append((kind, f'{kind}:{n}  linedef {li}, special {ld.special}',
                        *spot))
    n = 0                                        # sector special 9 = SECRET
    for si, sec in enumerate(md.sectors):
        if sec.special != 9:
            continue
        for li, ld in enumerate(md.linedefs):
            sides = [md.sidedefs[s].sector for s in (ld.right, ld.left)
                     if s != NO_SIDEDEF]
            if si not in sides or len(sides) < 2:
                continue
            spot = _stand_by_line(md, li)
            if spot and spot[:2] not in seen:
                seen.add(spot[:2])
                n += 1
                out.append(('secret', f'secret:{n}  sector {si}', *spot))
            break
    return out


def pick(level, name):
    """'stairs' / 'lift:3' -> one landmark, or exit listing what there is."""
    want, _, idx = name.partition(':')
    idx = int(idx) if idx else 1
    marks = [m for m in landmarks(level) if m[0] == want.lower()]
    if not marks:
        kinds = sorted({m[0] for m in landmarks(level)})
        sys.exit(f'testlevel: {lvname(level)} has no "{want}" -- it has: '
                 f'{", ".join(kinds) or "nothing tagged"}')
    if not 1 <= idx <= len(marks):
        sys.exit(f'testlevel: {lvname(level)} has {len(marks)} x {want}, '
                 f'asked for #{idx}')
    return marks[idx - 1]


# ----------------------------------------------------------------- patching --
def _level_slot(level):
    """Byte offset of level `level`'s .bin -- i.e. of its 32 B header -- in the ATR."""
    sec = _inc('LVL_SEC1', 384) + level * _inc('LVL_SECTORS', 361)
    return ATR_HEADER + (sec - 1) * SECTOR_SIZE


def make_test_atr(level, spawn=None):
    """level is 0-based; spawn is (x, y, ang) or None. -> (path, what it did)."""
    for p in (SRC_ATR, LST):
        if not os.path.exists(p):
            sys.exit(f'testlevel: missing {os.path.relpath(p, _PROJ)} -- run build_atr.ps1 first')
    addr = find_patch_addr()
    atr = bytearray(open(SRC_ATR, 'rb').read())
    xex = open(os.path.join(_PROJ, 'build', 'doom_bsp.xex'), 'rb').read()
    xex_base = ATR_HEADER + (XEX_SEC - 1) * SECTOR_SIZE
    xoff = xex_offset(xex, addr)
    off = xex_base + xoff
    if atr[off] != xex[xoff]:
        sys.exit('testlevel: ATR and doom_bsp.xex disagree -- the ATR is from an '
                 'older build, run build_atr.ps1')
    if atr[off - 1] != 0xA9:
        sys.exit(f'testlevel: byte before the patch is ${atr[off-1]:02X}, not the '
                 f'expected LDA# opcode -- ATR and .lst are out of step, rebuild')
    atr[off] = level
    # PATCH 1b: the EPISODE picker's level table (m_episode.asm ep_lvl). Since
    # NEW GAME opens the picker (2026-08-18) the boot `lda #0` above is not
    # enough on its own: menu_boot runs the picker before load_level_c and
    # `lda ep_lvl,x / sta current_level` overwrites whatever was patched in.
    # All THREE entries take the test level, so it does not matter which episode
    # gets picked -- and the table is not in the XEX at all, it is in the
    # overlay chunk split_menu_ovl.py dropped into menu.bin.
    ep_addr, ep_bytes = find_ep_lvl()
    eoff = epi_atr_off(ep_addr)
    want = bytes(int(b, 16) for b in ep_bytes)
    if bytes(atr[eoff:eoff + len(want)]) != want:
        sys.exit(f'testlevel: ep_lvl on the ATR is '
                 f'{list(atr[eoff:eoff + len(want)])}, the .lst says {list(want)} '
                 f'-- ATR and build are out of step, run build_atr.ps1')
    for i in range(len(want)):
        atr[eoff + i] = level
    # Always report WHERE the player will be standing -- the coordinates are
    # what a bug report needs, and for the normal start they were never shown.
    # Read back from the level slot, so it is the spawn the engine will use and
    # not a second guess at it.
    _b = _level_slot(level)
    _sx, _sy = struct.unpack_from('<hh', atr, _b + HDR_SX)
    note = f'normalny start ({_sx},{_sy}) uhol {atr[_b + HDR_ANG]}'
    if spawn is not None:
        x, y, ang = spawn
        md = wad_map(level)
        sec = locate(md, x, y)
        base = _level_slot(level)
        # Sanity before writing into the level slot: its header must actually be
        # this level's. n_sectors is the cheapest field to recognise, and it
        # catches an atr_layout.inc / ATR mismatch instead of quietly corrupting
        # a map.
        nsec = struct.unpack_from('<H', atr, base + 2)[0]
        if nsec != len(md.sectors):
            sys.exit(f'testlevel: the slot at ${base:X} claims {nsec} sectors, '
                     f'{lvname(level)} has {len(md.sectors)} -- atr_layout.inc and '
                     f'the ATR are out of step, run build_atr.ps1')
        struct.pack_into('<hh', atr, base + HDR_SX, x, y)
        atr[base + HDR_ANG] = ang & 0xFF
        struct.pack_into('<h', atr, base + HDR_EYE, md.sectors[sec].floor_h + EYE)
        note = (f'({x},{y}) uhol {ang}, sektor {sec}, '
                f'podlaha {md.sectors[sec].floor_h}')
    open(OUT_ATR, 'wb').write(atr)
    return OUT_ATR, note


def launch(path):
    exe = os.environ.get('ALTIRRA') or shutil.which('Altirra64') or shutil.which('Altirra')
    if exe:
        subprocess.Popen([exe, path])
    else:
        os.startfile(path)           # .atr file association


# ---------------------------------------------------------------------- GUI --
# An automap you click on. The linedefs are coloured by what they DO, because
# what this tool is for is standing next to a lift / a stair flight / a door and
# watching it work: LMB drops the spawn, dragging out of it aims the player,
# wheel zooms, RMB drags the map.
def run_gui():
    import tkinter as tk
    from tkinter import ttk
    n = num_levels()
    root = tk.Tk()
    root.title('DOOM E1 - test level')
    root.minsize(700, 480)
    status = tk.StringVar(value=f'zdroj: {os.path.relpath(SRC_ATR, _PROJ)}')
    picked = {'spawn': None}

    def boot(i, spawn=None, what='normalny start'):
        try:
            out, note = make_test_atr(i, spawn)
        except SystemExit as e:
            status.set(str(e))
            return
        launch(out)
        status.set(f'{lvname(i)} @ {what} -- {note}')

    bar = tk.Frame(root, padx=8, pady=6)
    bar.pack(fill='x')
    lvl = tk.StringVar(value=level_names()[0])

    def level_no():
        return level_names().index(lvl.get())

    tk.Label(bar, text='level').pack(side='left')
    ttk.Combobox(bar, textvariable=lvl, width=6, state='readonly',
                 values=level_names()[:n]).pack(side='left', padx=(4, 12))
    tk.Button(bar, text='Start odznova',
              command=lambda: boot(level_no())).pack(side='left')

    def go_here():
        # The box is editable, so what is IN it wins over the last mouse click:
        # typing a spot and pressing "Start tu" must not boot the old one.
        if not (edited['v'] or picked['spawn']):
            status.set('klikni na mapu, alebo napis X,Y[,uhol] do policka')
            return
        if not apply_coords():
            return
        boot(level_no(), picked['spawn'], 'z mapy')

    tk.Button(bar, text='Start tu', command=go_here).pack(side='left', padx=6)
    tk.Button(bar, text='Cela mapa', command=lambda: view.fit()).pack(side='left')

    # --- the coordinates, in something you can actually COPY -----------------
    # The status bar is a Label: the numbers show up but cannot be selected, so
    # Ctrl+C gets nothing. A readonly Entry can be dragged over and copied, and
    # the button does it in one click.
    coords = tk.StringVar(value='-')
    edited = {'v': False}         # typed into: the hover tracker backs off

    def apply_coords(*_a):
        """Take the box at its word: move the marker to whatever is typed."""
        p = parse_at(coords.get()) if view.md is not None else None
        if not p:
            status.set('napis X,Y alebo X,Y,uhol -- napriklad -224,176,90')
            return False
        x, y, ang = p
        mnx, mny, mxx, mxy = view.md.bounds()
        if not (mnx <= x <= mxx and mny <= y <= mxy):
            status.set(f'({x}, {y}) je mimo mapy: X {mnx}..{mxx}, Y {mny}..{mxy}')
            return False
        edited['v'] = True
        view.set_spawn(x, y, ang)     # writes the normalised x,y,ang back
        picked['spawn'] = view.spawn
        return True

    def copy_coords():
        root.clipboard_clear()
        root.clipboard_append(coords.get())
        root.update()                            # make it survive this process
        status.set(f'skopirovane: {coords.get()}')

    tk.Label(bar, text='  X,Y,uhol').pack(side='left', padx=(12, 2))
    ent = tk.Entry(bar, textvariable=coords, width=18, justify='center')
    ent.pack(side='left')
    ent.bind('<Return>', lambda _e: apply_coords())
    ent.bind('<KP_Enter>', lambda _e: apply_coords())
    ent.bind('<Key>', lambda _e: edited.__setitem__('v', True))
    tk.Button(bar, text='Ukaz', command=apply_coords).pack(side='left', padx=4)
    tk.Button(bar, text='Kopiruj', command=copy_coords).pack(side='left')
    # Ctrl+C inside the Entry is Tk's own copy-the-selection -- leave it alone;
    # anywhere else it means "copy the whole spot".
    root.bind('<Control-c>',
              lambda _e: None if root.focus_get() is ent else copy_coords())

    legend = tk.Frame(root, padx=8)
    legend.pack(fill='x')
    for _sp, col, name in LINE_COLS:
        tk.Label(legend, text='---', fg=col, bg=C_BG).pack(side='left')
        tk.Label(legend, text=name).pack(side='left', padx=(2, 10))
    for col, name in ((C_FLOOR, 'ina podlaha'), (C_DOOR, 'dvere'),
                      (C_SECRET, 'tajny sektor')):
        tk.Label(legend, text='---', fg=col, bg=C_BG).pack(side='left')
        tk.Label(legend, text=name).pack(side='left', padx=(2, 10))

    view = MapView(root, tk, status, lambda sp: picked.__setitem__('spawn', sp),
                   coords, lambda: not edited['v'])
    view.canvas.pack(fill='both', expand=True, padx=8, pady=6)
    tk.Label(root, textvariable=status, anchor='w').pack(fill='x', padx=8, pady=(0, 6))

    def reload_map(*_a):
        picked['spawn'] = None
        edited['v'] = False           # other level, other coordinates
        coords.set('-')
        try:
            view.load(wad_map(level_no()))
        except Exception as e:                              # pragma: no cover
            import traceback
            traceback.print_exc()
            status.set(f'{type(e).__name__}: {e}  (podrobnosti v konzole)')
            return
        status.set(f'{lvname(level_no())}: klikni kde chces zacat, tahanim nastav '
                   f'smer; alebo napis X,Y[,uhol] do policka a Enter. '
                   f'Koliesko = zoom, prave tlacidlo = posun')

    lvl.trace_add('write', reload_map)
    root.after(50, reload_map)
    root.mainloop()


def main():
    argv = sys.argv[1:]

    def opt(name):
        return argv[argv.index(name) + 1] if name in argv else None

    if '--list' in argv:
        lv = int(opt('--list')) - 1
        for _kind, label, x, y, ang, sec in landmarks(lv):
            print(f'  {label:44} ({x:6},{y:6}) uhol {ang:3}  sektor {sec}')
        return
    if '--cli' in argv:
        a = opt('--cli')
        if a.isdigit():                         # --cli 3 = 3rd level of the ATR
            lv = int(a) - 1
        else:                                   # --cli E2M1 = by NAME
            names = level_names()
            if a.upper() not in names:
                sys.exit(f'testlevel: {a} nie je na tomto ATR ({" ".join(names)})')
            lv = names.index(a.upper())
        if not 0 <= lv < num_levels():
            sys.exit(f'testlevel: level out of range 1..{num_levels()}')
        spawn, what = None, 'normalny start'
        if opt('--warp'):
            m = pick(lv, opt('--warp'))
            spawn, what = (m[2], m[3], m[4]), m[1]
        elif opt('--at'):
            p = parse_at(opt('--at'))
            if not p:
                sys.exit('testlevel: --at chce X,Y alebo X,Y,UHOL')
            spawn = (p[0], p[1], p[2] or 0)
            what = '--at'
        out, note = make_test_atr(lv, spawn)
        print(f'{lvname(lv)} @ {what}: {note}\n-> {out}')
        if '--nolaunch' not in argv:
            launch(out)
    else:
        run_gui()


if __name__ == '__main__':
    main()
