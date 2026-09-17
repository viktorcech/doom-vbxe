#!/usr/bin/env python3
"""split_b1 -- DRAC_PLAN phase 2: the bank-$01 code out of the XEX, back in as
boot-time chunks.

drac.txt: the code goes to $010000-$01FFFF. In the source that is a MADS
segment (`.segdef B1 ... 1`, `.segment B1` ... `.endseg` around each moved
proc): MADS lays the procs out one after another, checks the segment length,
and tags every label with bank 1. But MADS writes each segment block into the
XEX at its 16-bit address, and the boot loader would store that in BANK 0.

So this runs right after mads, BEFORE split_menu_ovl.py, and:
  * finds the segment blocks -- the listing marks them "01,AAAA-EEEE>" -- and
    takes them out of the XEX;
  * writes build/b1code.bin (the 64 KB bank image) + build/b1code.map (the
    used ranges) for the simulators and tools;
  * puts the bytes back as STAGED chunks: a segment at B1STAGE holding
    [dst lo, dst hi, len lo, len hi] + payload, then an INIT segment to
    b1_stage_copy, which copies the payload to $01:dst while the XEX is still
    loading. The chunks go right behind the XEX block that carries
    b1_stage_copy, so the bank is complete long before main runs.

  python tools/split_b1.py [build/doom_bsp.xex]
"""
import json
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import code_map                                                 # noqa: E402

BUILD = os.path.join(ROOT, 'build')


def equ(name):
    src = open(os.path.join(ROOT, 'memory_map.inc'), encoding='latin-1').read()
    m = re.search(r'^\s*%s\s+equ\s+(\$?[0-9A-Fa-f]+)' % name, src, re.M)
    if not m:
        sys.exit('split_b1: %s is not a plain equ in memory_map.inc' % name)
    v = m.group(1)
    return int(v[1:], 16) if v.startswith('$') else int(v)


def lab(name):
    for line in open(os.path.join(BUILD, 'doom_bsp.lab'), encoding='latin-1'):
        p = line.split()
        if len(p) == 3 and p[2].upper() == name.upper():
            return int(p[0], 16), int(p[1], 16)
    return None


def xex_blocks(data):
    i = 2 if data[:2] == b'\xff\xff' else 0
    out = []
    while i + 4 <= len(data):
        lo, hi = struct.unpack_from('<HH', data, i)
        if lo == 0xFFFF:
            i += 2
            continue
        n = hi - lo + 1
        out.append([lo, hi, bytes(data[i + 4:i + 4 + n])])
        i += 4 + n
    return out


def main():
    xex = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BUILD, 'doom_bsp.xex')
    blocks = xex_blocks(open(xex, 'rb').read())
    marks = code_map._listing_blocks(os.path.join(BUILD, 'doom_bsp.lst'))
    b1 = [(lo, hi, bk) for lo, hi, bk in marks if bk]
    img = bytearray(0x10000)
    used = []
    if not b1:
        # nothing assembled into the bank: leave the XEX alone, but keep the
        # image files honest (empty) for the tools that read them
        open(os.path.join(BUILD, 'b1code.bin'), 'wb').write(img)
        json.dump([], open(os.path.join(BUILD, 'b1code.map'), 'w'))
        print('split_b1: no bank segment in the listing')
        return
    # Walk the listing's blocks against the XEX in order. A bank-0 listing
    # block the XEX does not have is an overlay split_menu_ovl.py already
    # lifted (this runs after it: the overlays stage at addresses -- $9000 is
    # FINOVL_STAGE -- that the split frees for our chunks).
    keep = []
    j = 0
    for lo, hi, bk in marks:
        blk = blocks[j] if j < len(blocks) else None
        if blk is None or (blk[0], blk[1]) != (lo, hi):
            if bk == 0:
                continue                         # lifted overlay
            sys.exit(f'split_b1: bank-${bk:02X} listing block ${lo:04X}-${hi:04X} '
                     f'is not in the XEX -- run order or listing is stale')
        j += 1
        if bk == 0:
            keep.append(blk)
            continue
        if bk != 1:
            sys.exit(f'split_b1: a segment in bank ${bk:02X} -- only $01 is wired')
        for a, b, _ in used:
            if lo <= b and hi >= a:
                sys.exit(f'split_b1: bank-$01 blocks overlap at ${lo:04X}')
        img[lo:hi + 1] = blk[2]
        used.append((lo, hi, None))

    stage = equ('B1STAGE')
    smax = equ('B1STAGE_MAX')
    copier = lab('b1_stage_copy')
    if copier is None or copier[0] != 0:
        sys.exit('split_b1: b1_stage_copy is not a bank-0 label in doom_bsp.lab')
    copier = copier[1]

    # contiguous runs, then chunks that fit the stage
    runs = []
    for lo, hi, _ in sorted(used):
        if runs and lo == runs[-1][1] + 1:
            runs[-1][1] = hi
        else:
            runs.append([lo, hi])
    chunks = []
    room = smax - 4
    for lo, hi in runs:
        a = lo
        while a <= hi:
            n = min(room, hi - a + 1)
            payload = bytes(img[a:a + n])
            hdr = bytes((a & 0xFF, a >> 8, n & 0xFF, n >> 8))
            chunks.append([stage, stage + 4 + n - 1, hdr + payload])
            chunks.append([0x02E2, 0x02E3, bytes((copier & 0xFF, copier >> 8))])
            a += n

    at = None
    for k, (lo, hi, _) in enumerate(keep):
        if lo <= copier <= hi:
            at = k
            break
    if at is None:
        sys.exit(f'split_b1: no XEX block carries b1_stage_copy (${copier:04X})')
    out_blocks = keep[:at + 1] + chunks + keep[at + 1:]

    buf = bytearray(b'\xff\xff')
    for lo, hi, data in out_blocks:
        buf += struct.pack('<HH', lo, hi) + data
    open(xex, 'wb').write(buf)
    open(os.path.join(BUILD, 'b1code.bin'), 'wb').write(img)
    json.dump([[lo, hi] for lo, hi in runs],
              open(os.path.join(BUILD, 'b1code.map'), 'w'))
    total = sum(hi - lo + 1 for lo, hi in runs)
    print(f'split_b1: {len(used)} segment blocks, {total} B into bank $01 '
          f'({len(runs)} runs) -> {len(chunks) // 2} staged chunks at ${stage:04X}')


if __name__ == '__main__':
    main()
