#!/usr/bin/env python3
"""vbxe_reloc -- the bytes that move with VBXE's base ($D6xx -> $D7xx).

build_atr.ps1 assembles the engine twice, the second time with VBXE_D7 set
(build/doom_bsp_d7.xex). The two XEX files are the same block for block; the
bytes that differ are the high bytes of the register addresses, $D6 in one and
$D7 in the other. This sorts them by where the byte IS when it has to move:

  * the code overlays tools/split_menu_ovl.py lifts into menu.bin: their
    addresses in the menu's depack bounce go into mn_vtab (menu.asm), which
    menu_boot steps before the streams reach VRAM. Written into the XEX here.
  * everything else -- bank 0 at its load address, bank $01 at its own:
    build/assets/code/vbxe_reloc.bin, 3 B an entry (lo, hi, bank), $FF $FF $FF at the end.
    make_atr_doom.py puts it in front of the XEX's RUN vector and the boot
    loader walks it when it has found the VBXE at $D7xx (boot.asm b_reloc).

Any other difference between the two assemblies fails the build: a register
address nobody steps is a game that hangs on such a machine, silently.

Run right after the two assemblies, BEFORE split_b1.py and split_menu_ovl.py.

    python tools/vbxe_reloc.py
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import code_map                                                   # noqa: E402
import split_menu_ovl                                             # noqa: E402


XEX = code_map.XEX
XEX_D7 = code_map.img('build', 'doom_bsp_d7.xex')
OUT = code_map.img('build', 'assets', 'code', 'vbxe_reloc.bin')
CHUNK = 4096


def blocks(data):
    """[(lo, hi, offset of the payload)] over a segmented XEX."""
    out, i = [], 2 if data[:2] == b'\xff\xff' else 0
    while i + 4 <= len(data):
        lo, hi = struct.unpack_from('<HH', data, i)
        if lo == 0xFFFF:
            i += 2
            continue
        out.append((lo, hi, i + 4))
        i += 4 + hi - lo + 1
    return out


def equ(path, name):
    src = open(os.path.join(ROOT, path), encoding='latin-1').read()
    m = re.search(r'^\s*%s\s+equ\s+(\$?[0-9A-Fa-f]+)' % name, src, re.M)
    if not m:
        sys.exit('vbxe_reloc: %s is not in %s' % (name, path))
    v = m.group(1)
    return int(v[1:], 16) if v.startswith('$') else int(v)


def lab(name):
    for line in open(code_map.LAB, encoding='latin-1'):
        p = line.split()
        if len(p) == 3 and p[2].upper() == name.upper():
            return int(p[0], 16), int(p[1], 16)
    sys.exit('vbxe_reloc: %s is not in the .lab' % name)


def main():
    for p in (XEX, XEX_D7):
        if not os.path.exists(p):
            sys.exit('vbxe_reloc: %s is missing -- assemble both passes first' % p)
    a = bytearray(open(XEX, 'rb').read())
    b = open(XEX_D7, 'rb').read()
    ba, bb = blocks(a), blocks(b)
    if len(a) != len(b) or ba != bb:
        sys.exit('vbxe_reloc: the two assemblies are not the same block for block '
                 '-- something but an address depends on VBXE_D7')
    marks = code_map._listing_blocks(code_map.LST)
    b1 = {(lo, hi) for lo, hi, bk in marks if bk}
    ovls, _off, _nch = split_menu_ovl.overlays()
    stage = {s: (who, o) for s, who, o in ovls}

    # the menu's two streams (make_atr_doom.py): chunks [0, A) and [LVCH, end)
    src = open(os.path.join(HERE, 'make_atr_doom.py'), encoding='utf-8').read()
    m = re.search(r'MENU_A_CH, MENU_PLAIN_CH = (\d+), (\d+)', src)
    if not m:
        sys.exit('vbxe_reloc: MENU_A_CH is not in make_atr_doom.py any more')
    a_ch, b_ch = int(m.group(1)), int(m.group(1)) + int(m.group(2))
    bounce = equ('atr_layout.inc', 'MENU_BOUNCE')
    vmax = equ('menu.asm', 'MN_VMAX')

    boot, grp = [], ([], [])
    for lo, hi, off in ba:
        if lo in (0x2E0, 0x2E2):
            continue
        n = hi - lo + 1
        if a[off:off + n] == b[off:off + n]:
            continue
        for k in range(n):
            x, y = a[off + k], b[off + k]
            if x == y:
                continue
            if (x, y) != (0xD6, 0xD7):
                sys.exit('vbxe_reloc: block $%04X-$%04X +$%04X differs $%02X/$%02X '
                         '-- not a register address' % (lo, hi, k, x, y))
            if (lo, hi) in b1:
                boot.append((lo + k, 1))
            elif lo in stage:
                who, o = stage[lo]
                ch = o // CHUNK
                if ch < a_ch:
                    grp[0].append(bounce + o + k)
                elif ch >= b_ch:
                    grp[1].append(bounce + o - b_ch * CHUNK + k)
                else:
                    sys.exit('vbxe_reloc: %s is in neither menu stream' % who)
            else:
                boot.append((lo + k, 0))

    # --- the overlays' table, into the XEX
    bank, addr = lab('mn_vtab')
    hit = [(lo, hi, off) for lo, hi, off in ba
           if lo <= addr <= hi and ((lo, hi) in b1) == (bank == 1)
           and (bank or lo not in stage)]
    if bank > 1 or len(hit) != 1:
        sys.exit('vbxe_reloc: mn_vtab ($%02X:%04X) is in %d blocks' % (bank, addr, len(hit)))
    lo, hi, off = hit[0]
    base = off + addr - lo
    for g, ents in enumerate(grp):
        if len(ents) > vmax:
            sys.exit('vbxe_reloc: %d overlay addresses in stream %s, mn_vtab holds '
                     '%d -- raise MN_VMAX (menu.asm)' % (len(ents), 'AB'[g], vmax))
        blob = b''.join(struct.pack('<I', e)[:3] for e in ents) + bytes(3)
        p = base + g * (vmax + 1) * 3
        if any(a[p:p + (vmax + 1) * 3]):
            sys.exit('vbxe_reloc: mn_vtab is not empty -- run on a fresh assembly')
        a[p:p + len(blob)] = blob
    open(XEX, 'wb').write(a)

    # --- ... and the boot loader's
    boot.sort(key=lambda e: (e[1], e[0]))
    tab = b''.join(struct.pack('<HB', ad, bk) for ad, bk in boot) + b'\xff\xff\xff'
    open(OUT, 'wb').write(tab)
    os.remove(XEX_D7)
    print('vbxe_reloc: %d addresses for the boot loader (%d in bank 0, %d in bank $01), '
          '%d + %d in the overlays' % (len(boot), sum(1 for e in boot if not e[1]),
                                       sum(1 for e in boot if e[1]),
                                       len(grp[0]), len(grp[1])))


if __name__ == '__main__':
    main()
