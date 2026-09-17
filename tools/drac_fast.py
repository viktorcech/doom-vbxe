#!/usr/bin/env python3
"""drac_fast -- the frame bench without the boot: ~30 s per test instead of minutes.

  python tools/drac_fast.py snap            boot + load E1M1 once (the slow part),
                                            park the simulator at the first game
                                            loop pass -> bench/drac_snap.pkl
  python tools/drac_fast.py run [--frames N] [--top K]
                                            load the snapshot, overlay the CURRENT
                                            build's code (bank $01 image + bank-0
                                            XEX code bytes), run N frames (1),
                                            print VRAMSHA, cycles/frame, top procs

The overlay is valid while only CODE changed: every bank-0 symbol of the
snapshot's build must still be at the same address in build/doom_bsp.lab
(variables, tables, block layout) -- otherwise the tool refuses and asks for a
new `snap`. Bank-$01 code may move freely (the game loop restarts at the new
LOOP_HEAD). Self-modified operands are pristine at the first loop pass, so the
assembled bytes of the new build are the right initial state.

Same VRAM hash as tools/tests/_gate_vramhash.py for the same frame count when
run on the snapshot's own build -- check that once after `snap`.
"""
import bisect
import hashlib
import json
import os
import pickle
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, 'tests'))
import _bench_frame as B                                         # noqa: E402

SNAP = os.path.join(ROOT, 'bench', 'drac_snap.pkl')
LAB = os.path.join(ROOT, 'build', 'doom_bsp.lab')
XEX = os.path.join(ROOT, 'build', 'doom_bsp.xex')
B1BIN = os.path.join(ROOT, 'build', 'b1code.bin')
B1MAP = os.path.join(ROOT, 'build', 'b1code.map')
LST = os.path.join(ROOT, 'build', 'doom_bsp.lst')


def lab_sig():
    """bank-0 symbols (name -> addr): the data/layout signature of a build"""
    sig = {}
    for ln in open(LAB, encoding='latin-1'):
        p = ln.split()
        if len(p) == 3 and p[0] == '00':
            try:
                sig[p[2]] = int(p[1], 16)
            except ValueError:
                pass
    return sig


def xex_blocks():
    d = open(XEX, 'rb').read()
    i, out = 0, []
    while i + 4 <= len(d):
        lo, hi = struct.unpack_from('<HH', d, i)
        if lo == 0xFFFF:
            i += 2
            continue
        n = hi - lo + 1
        out.append((lo, hi, d[i + 4:i + 4 + n]))
        i += 4 + n
    return out


def code_bytes_bank0():
    """bank-0 addresses the listing marks as INSTRUCTION bytes"""
    import drac_lst as L
    lines, _ = L.read_lst()
    code = set()
    for ln in lines:
        if ln.bank == 0 and ln.kind == 'code':
            for k in range(len(ln.bytes)):
                code.add(ln.addr + k)
    return code


def snap():
    fb = B.FrameBench()
    fb.bench(0)                          # boot + load, break at the first LOOP_HEAD
    if not fb.in_game:
        raise SystemExit('snap: the game loop was never reached')
    fb.per_pc = fb.per_b1 = None
    fb.trace = []
    fb.jlog = []
    state = {'fb': fb, 'sig': lab_sig(), 'loop_head': B.LOOP_HEAD, 'loop_bank': B.LOOP_BANK}
    with open(SNAP, 'wb') as f:
        pickle.dump(state, f, protocol=pickle.HIGHEST_PROTOCOL)
    print(f'snapshot -> {os.path.relpath(SNAP, ROOT)}  ({os.path.getsize(SNAP) // 1024} KB)')


def overlay(fb, snap_sig):
    sig = lab_sig()
    moved = [n for n, a in snap_sig.items() if sig.get(n, a) != a]
    if moved:
        raise SystemExit(f'overlay refused: {len(moved)} bank-0 symbols moved since the snapshot '
                         f'(e.g. {", ".join(moved[:6])}) -- run `snap` again')
    # bank $01: the whole code image
    img = open(B1BIN, 'rb').read()
    bm = fb.s.bank.m if hasattr(fb.s.bank, 'm') else None
    for lo, hi in json.load(open(B1MAP)):
        if bm is not None:
            bm[0x10000 + lo:0x10000 + hi + 1] = img[lo:hi + 1]
        else:
            for a in range(lo, hi + 1):
                fb.s.bank[0x10000 + a] = img[a]
    # bank 0: instruction bytes only (data keeps the running game's values)
    code = code_bytes_bank0()
    m = fb.s.mem
    n = 0
    for lo, hi, data in xex_blocks():
        if lo in (0x02E0, 0x02E2) or lo == 0x9000:      # vectors, B1 staging chunks
            continue
        for k, b in enumerate(data):
            a = lo + k
            if a in code and m[a] != b:
                m[a] = b
                n += 1
    return n


def run(frames, top):
    state = pickle.load(open(SNAP, 'rb'))
    fb = state['fb']
    n = overlay(fb, state['sig'])
    fb.pc = B.LOOP_HEAD                  # the new build's frame boundary
    fw = fb.s.sym.get('fps_win')
    if fw:
        cm = fb.s.bank.m if fw > 0xFFFF else fb.s.mem
        fb.fps_val_addr = cm[fw + 9] | (cm[fw + 10] << 8)
    s, m = fb.s, fb.s.mem
    T_VBI = B.VBI_PERIOD / B.CHIP_HZ
    inv_hz = [(1.0 / B.FAST_HZ) if B.REGION_MUL[B.region(p)] == 1.0 else (1.0 / B.CHIP_HZ)
              for p in range(0x10000)]
    INV_FAST = 1.0 / B.FAST_HZ
    wall, next_vbi_t = 0.0, T_VBI
    marks, per_pc, per_b1 = [], {}, {}
    last_cyc = s.cyc
    steps = 0
    while True:
        pc = fb.pc
        if pc == B.SIOV:
            fb.pc = fb._siov()
            continue
        if pc == B.LOOP_HEAD and s.pbr == B.LOOP_BANK:
            marks.append(s.cyc)
            if B.FIXED_VBI:
                rt = s.sym.get('RTCLOK3') or 0x14
                m[rt & 0xFFFF] = (m[rt & 0xFFFF] + B.FIXED_VBI) & 0xFF
                xp = s.sym.get('XDLA_PEND')
                if xp:
                    m[xp & 0xFFFF] = 0
            fb.blit_log.append((fb.blit_n, fb.blit_bcbs, fb.blit_vcyc))
            fb.blit_n = fb.blit_bcbs = fb.blit_vcyc = 0
            if len(marks) > frames:
                break
        pb = s.pbr
        try:
            npc = s.step(pc)
        except NotImplementedError as e:
            raise SystemExit(f'sim: {e} at ${pc:04X} (pbr {pb})')
        dcyc = s.cyc - last_cyc
        last_cyc = s.cyc
        wall += dcyc * (inv_hz[pc] if not pb else INV_FAST)
        if dcyc:
            per_pc[pc] = per_pc.get(pc, 0) + dcyc
            if pb:
                per_b1[pc] = per_b1.get(pc, 0) + dcyc
        if npc == pc:
            raise SystemExit(f'halted at ${pc:04X}')
        fb.pc = npc
        steps += 1
        if steps > 60_000_000:
            raise SystemExit('runaway')
        if not B.FIXED_VBI and wall >= next_vbi_t:
            next_vbi_t += T_VBI
            fb._run_vbi()
    nf = len(marks) - 1
    total = marks[-1] - marks[0]
    print(f'code overlay: {n} bank-0 bytes changed; {frames} frame(s)')
    print(f'VRAMSHA {hashlib.sha1(fb.vram).hexdigest()}')
    print(f'CYC/frame {total // nf}   ({total / nf / B.FAST_HZ * 1000:.1f} ms at {B.FAST_HZ / 1e6:.2f} MHz)')
    # top procs: bank-1 by bank-1 labels, bank-0 by bank-0 labels
    syms0 = sorted((a, nm) for nm, a in s.sym.items() if isinstance(a, int) and a < 0x10000 and '.' not in nm)
    syms1 = sorted((a & 0xFFFF, nm) for nm, a in s.sym.items() if isinstance(a, int) and (a >> 16) == 1 and '.' not in nm)
    a0 = [a for a, _ in syms0]
    a1 = [a for a, _ in syms1]
    agg = {}
    for pc, c in per_pc.items():
        c1 = per_b1.get(pc, 0)
        if c1:
            i = bisect.bisect_right(a1, pc) - 1
            nm = syms1[i][1] if i >= 0 else '?'
            agg[nm] = agg.get(nm, 0) + c1
        if c - c1:
            i = bisect.bisect_right(a0, pc) - 1
            nm = syms0[i][1] if i >= 0 else '?'
            agg[nm] = agg.get(nm, 0) + (c - c1)
    for nm, c in sorted(agg.items(), key=lambda kv: -kv[1])[:top]:
        print(f'  {c // nf:8d} {100.0 * c / total:5.1f}%  {nm}')


if __name__ == '__main__':
    args = sys.argv[1:]
    frames, top = 1, 15
    if '--frames' in args:
        i = args.index('--frames'); frames = int(args[i + 1]); del args[i:i + 2]
    if '--top' in args:
        i = args.index('--top'); top = int(args[i + 1]); del args[i:i + 2]
    cmd = args[0] if args else 'run'
    if cmd == 'snap':
        snap()
    else:
        run(frames, top)
