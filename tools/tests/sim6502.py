#!/usr/bin/env python3
"""Cycle-exact 6502 (+ the 65816 long-indirect reads this port uses) simulator,
written to MEASURE the engine instead of estimating it.

It loads the real build/doom_bsp.xex, so every routine measured is the one that
actually ships. Cycles include page-crossing penalties and taken/page-crossing
branches. Nothing here is guessed: run() returns the exact cycle count between
a JSR and its matching RTS.

Not a full machine: there is no ANTIC/POKEY/GTIA, and writes into the VBXE
register window are accepted and ignored (the blitter runs in parallel with the
CPU anyway, so its time is not CPU time). Unimplemented opcodes raise, so a
routine that needs something missing fails loudly rather than lying.

  from sim6502 import Sim
  s = Sim.from_xex('build/doom_bsp.xex')
  s.poke16(s.sym['m_a'], 1234)
  cycles = s.call(s.sym['umul16'])
"""
import os
import re
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# addressing modes (LAB/LAX: the 65816 long-absolute reads -- frame_setup and
# the reciprocal tables live in Rapidus bank $01 and read with lda.l)
(IMP, ACC, IMM, ZP, ZPX, ZPY, ABS, ABX, ABY, IND, IZX, IZY, REL, LIY,
 LAB, LAX, REL16) = range(17)
SIZE = {IMP: 1, ACC: 1, IMM: 2, ZP: 2, ZPX: 2, ZPY: 2, ABS: 3, ABX: 3, ABY: 3,
        IND: 3, IZX: 2, IZY: 2, REL: 2, LIY: 2, LAB: 4, LAX: 4, REL16: 3}

# opcode -> (mnemonic, mode, base cycles, +1 if page crossed)
OPS = {}


def _op(code, mn, mode, cyc, pc=False):
    OPS[code] = (mn, mode, cyc, pc)


for code, mn, mode, cyc, pc in [
    (0x69, 'adc', IMM, 2, 0), (0x65, 'adc', ZP, 3, 0), (0x75, 'adc', ZPX, 4, 0),
    (0x6D, 'adc', ABS, 4, 0), (0x7D, 'adc', ABX, 4, 1), (0x79, 'adc', ABY, 4, 1),
    (0x61, 'adc', IZX, 6, 0), (0x71, 'adc', IZY, 5, 1),
    (0xE9, 'sbc', IMM, 2, 0), (0xE5, 'sbc', ZP, 3, 0), (0xF5, 'sbc', ZPX, 4, 0),
    (0xED, 'sbc', ABS, 4, 0), (0xFD, 'sbc', ABX, 4, 1), (0xF9, 'sbc', ABY, 4, 1),
    (0xE1, 'sbc', IZX, 6, 0), (0xF1, 'sbc', IZY, 5, 1),
    (0xA9, 'lda', IMM, 2, 0), (0xA5, 'lda', ZP, 3, 0), (0xB5, 'lda', ZPX, 4, 0),
    (0xAD, 'lda', ABS, 4, 0), (0xBD, 'lda', ABX, 4, 1), (0xB9, 'lda', ABY, 4, 1),
    (0xA1, 'lda', IZX, 6, 0), (0xB1, 'lda', IZY, 5, 1), (0xB7, 'lda', LIY, 6, 0),
    (0xAF, 'lda', LAB, 5, 0), (0xBF, 'lda', LAX, 5, 0), (0x8F, 'sta', LAB, 5, 0),
    (0x9F, 'sta', LAX, 5, 0),               # update_lights writes its thinker
                                            # state back into the map's EXT bank
    (0xEF, 'sbc', LAB, 5, 0), (0xFF, 'sbc', LAX, 5, 0),   # paint_col walks its
                                            # run list DOWN from the anchor
                                            # texel, one sbc.l per run
    (0xF7, 'sbc', LIY, 6, 0), (0x77, 'adc', LIY, 6, 0),
    (0x17, 'ora', LIY, 6, 0),
    # The rest of the 65816 long-absolute ALU column. The AUTOMAP OVERLAY reads
    # its seg arrays out of a bank with these (tools/tests/_dbg_amglitch.py died
    # on $1F at $10ED, 2026-08-19); the four families are added together rather
    # than one at a time, because finding them by crashing is a frame-long
    # round trip each. All are the same generic ALU the other modes already use.
    (0x0F, 'ora', LAB, 5, 0), (0x1F, 'ora', LAX, 5, 0),
    (0x2F, 'and', LAB, 5, 0), (0x3F, 'and', LAX, 5, 0),
    (0x4F, 'eor', LAB, 5, 0), (0x5F, 'eor', LAX, 5, 0),
    (0x6F, 'adc', LAB, 5, 0), (0x7F, 'adc', LAX, 5, 0),
    (0xCF, 'cmp', LAB, 5, 0), (0xDF, 'cmp', LAX, 5, 0),
    (0x37, 'and', LIY, 6, 0), (0x57, 'eor', LIY, 6, 0),
    (0xD7, 'cmp', LIY, 6, 0), (0x97, 'sta', LIY, 6, 0),
    (0x85, 'sta', ZP, 3, 0), (0x95, 'sta', ZPX, 4, 0), (0x8D, 'sta', ABS, 4, 0),
    (0x9D, 'sta', ABX, 5, 0), (0x99, 'sta', ABY, 5, 0), (0x81, 'sta', IZX, 6, 0),
    (0x91, 'sta', IZY, 6, 0), (0x97, 'sta', LIY, 6, 0),
    (0xA2, 'ldx', IMM, 2, 0), (0xA6, 'ldx', ZP, 3, 0), (0xB6, 'ldx', ZPY, 4, 0),
    (0xAE, 'ldx', ABS, 4, 0), (0xBE, 'ldx', ABY, 4, 1),
    (0xA0, 'ldy', IMM, 2, 0), (0xA4, 'ldy', ZP, 3, 0), (0xB4, 'ldy', ZPX, 4, 0),
    (0xAC, 'ldy', ABS, 4, 0), (0xBC, 'ldy', ABX, 4, 1),
    (0x86, 'stx', ZP, 3, 0), (0x96, 'stx', ZPY, 4, 0), (0x8E, 'stx', ABS, 4, 0),
    (0x84, 'sty', ZP, 3, 0), (0x94, 'sty', ZPX, 4, 0), (0x8C, 'sty', ABS, 4, 0),
    (0x29, 'and', IMM, 2, 0), (0x25, 'and', ZP, 3, 0), (0x35, 'and', ZPX, 4, 0),
    (0x2D, 'and', ABS, 4, 0), (0x3D, 'and', ABX, 4, 1), (0x39, 'and', ABY, 4, 1),
    (0x09, 'ora', IMM, 2, 0), (0x05, 'ora', ZP, 3, 0), (0x15, 'ora', ZPX, 4, 0),
    (0x0D, 'ora', ABS, 4, 0), (0x1D, 'ora', ABX, 4, 1), (0x19, 'ora', ABY, 4, 1),
    (0x01, 'ora', IZX, 6, 0), (0x11, 'ora', IZY, 5, 1),   # door_at_point's
                                            # "n_segs == 0?" -- the first plain
                                            # (zp),y ora the port ever ran
    (0x21, 'and', IZX, 6, 0), (0x31, 'and', IZY, 5, 1),
    (0x41, 'eor', IZX, 6, 0), (0x51, 'eor', IZY, 5, 1),
    (0x49, 'eor', IMM, 2, 0), (0x45, 'eor', ZP, 3, 0), (0x55, 'eor', ZPX, 4, 0),
    (0x4D, 'eor', ABS, 4, 0), (0x5D, 'eor', ABX, 4, 1), (0x59, 'eor', ABY, 4, 1),
    (0xC9, 'cmp', IMM, 2, 0), (0xC5, 'cmp', ZP, 3, 0), (0xD5, 'cmp', ZPX, 4, 0),
    (0xCD, 'cmp', ABS, 4, 0), (0xDD, 'cmp', ABX, 4, 1), (0xD9, 'cmp', ABY, 4, 1),
    (0xC1, 'cmp', IZX, 6, 0), (0xD1, 'cmp', IZY, 5, 1),
    (0xE0, 'cpx', IMM, 2, 0), (0xE4, 'cpx', ZP, 3, 0), (0xEC, 'cpx', ABS, 4, 0),
    (0xC0, 'cpy', IMM, 2, 0), (0xC4, 'cpy', ZP, 3, 0), (0xCC, 'cpy', ABS, 4, 0),
    (0x0A, 'asl', ACC, 2, 0), (0x06, 'asl', ZP, 5, 0), (0x16, 'asl', ZPX, 6, 0),
    (0x0E, 'asl', ABS, 6, 0), (0x1E, 'asl', ABX, 7, 0),
    (0x4A, 'lsr', ACC, 2, 0), (0x46, 'lsr', ZP, 5, 0), (0x56, 'lsr', ZPX, 6, 0),
    (0x4E, 'lsr', ABS, 6, 0), (0x5E, 'lsr', ABX, 7, 0),
    (0x2A, 'rol', ACC, 2, 0), (0x26, 'rol', ZP, 5, 0), (0x36, 'rol', ZPX, 6, 0),
    (0x2E, 'rol', ABS, 6, 0), (0x3E, 'rol', ABX, 7, 0),
    (0x6A, 'ror', ACC, 2, 0), (0x66, 'ror', ZP, 5, 0), (0x76, 'ror', ZPX, 6, 0),
    (0x6E, 'ror', ABS, 6, 0), (0x7E, 'ror', ABX, 7, 0),
    (0xE6, 'inc', ZP, 5, 0), (0xF6, 'inc', ZPX, 6, 0), (0xEE, 'inc', ABS, 6, 0),
    (0xFE, 'inc', ABX, 7, 0),
    (0xC6, 'dec', ZP, 5, 0), (0xD6, 'dec', ZPX, 6, 0), (0xCE, 'dec', ABS, 6, 0),
    (0xDE, 'dec', ABX, 7, 0),
    (0x4C, 'jmp', ABS, 3, 0), (0x6C, 'jmp', IND, 5, 0), (0x20, 'jsr', ABS, 6, 0),
    (0x60, 'rts', IMP, 6, 0), (0x40, 'rti', IMP, 6, 0),
    # 65816 long call/return: bank01.asm runs its .procs INSIDE Rapidus
    # SRAM bank $01 and every call site is `jsl B1CODE_BASE+proc` / RTL.
    # Without these two the sim died on opcode $22 the first time an imp
    # needed aif_oct.
    (0x22, 'jsl', LAB, 8, 0), (0x6B, 'rtl', IMP, 6, 0),
    (0x90, 'bcc', REL, 2, 0), (0xB0, 'bcs', REL, 2, 0), (0xF0, 'beq', REL, 2, 0),
    (0xD0, 'bne', REL, 2, 0), (0x30, 'bmi', REL, 2, 0), (0x10, 'bpl', REL, 2, 0),
    (0x50, 'bvc', REL, 2, 0), (0x70, 'bvs', REL, 2, 0),
    (0x18, 'clc', IMP, 2, 0), (0x38, 'sec', IMP, 2, 0), (0xD8, 'cld', IMP, 2, 0),
    (0x58, 'cli', IMP, 2, 0), (0x78, 'sei', IMP, 2, 0), (0xB8, 'clv', IMP, 2, 0),
    (0xAA, 'tax', IMP, 2, 0), (0xA8, 'tay', IMP, 2, 0), (0x8A, 'txa', IMP, 2, 0),
    (0x98, 'tya', IMP, 2, 0), (0xBA, 'tsx', IMP, 2, 0), (0x9A, 'txs', IMP, 2, 0),
    (0xE8, 'inx', IMP, 2, 0), (0xC8, 'iny', IMP, 2, 0), (0xCA, 'dex', IMP, 2, 0),
    (0x88, 'dey', IMP, 2, 0), (0xEA, 'nop', IMP, 2, 0),
    (0x48, 'pha', IMP, 3, 0), (0x68, 'pla', IMP, 4, 0), (0x08, 'php', IMP, 3, 0),
    (0x28, 'plp', IMP, 4, 0), (0x24, 'bit', ZP, 3, 0), (0x2C, 'bit', ABS, 4, 0),
    # ---- 65816 NATIVE MODE (2026-08-11 pm) -------------------------------
    # The Rapidus core is a 65816 and the port has only ever used it in
    # EMULATION mode (the long-addressing reads above work there). 16-bit
    # register mode is where the remaining speed is -- one `lda`/`adc`/`sta`
    # pair instead of two, on 24-bit accumulator chains that are most of
    # paint.asm/math.asm -- so the simulator has to model it, or converting a
    # single routine would blind the bench, check_boot and every verifier at
    # once. Widths follow the real chip: M (P bit5) sizes A, X (bit4) sizes
    # X/Y, and e=1 forces both back to 8 bits.
    (0xC2, 'rep', IMM, 3, 0), (0xE2, 'sep', IMM, 3, 0), (0xFB, 'xce', IMP, 2, 0),
    (0xEB, 'xba', IMP, 3, 0),
    (0x1A, 'inc', ACC, 2, 0), (0x3A, 'dec', ACC, 2, 0),
    (0x64, 'stz', ZP, 3, 0), (0x74, 'stz', ZPX, 4, 0),
    (0x9C, 'stz', ABS, 4, 0), (0x9E, 'stz', ABX, 5, 0),
    (0xDA, 'phx', IMP, 3, 0), (0xFA, 'plx', IMP, 4, 0),
    (0x5A, 'phy', IMP, 3, 0), (0x7A, 'ply', IMP, 4, 0),
    (0x8B, 'phb', IMP, 3, 0), (0xAB, 'plb', IMP, 4, 0), (0x4B, 'phk', IMP, 3, 0),
    (0x0B, 'phd', IMP, 4, 0), (0x2B, 'pld', IMP, 5, 0),
    (0x5B, 'tcd', IMP, 2, 0), (0x7B, 'tdc', IMP, 2, 0),
    (0x1B, 'tcs', IMP, 2, 0), (0x3B, 'tsc', IMP, 2, 0),
    (0x9B, 'txy', IMP, 2, 0), (0xBB, 'tyx', IMP, 2, 0),
    (0x89, 'bit', IMM, 2, 0), (0x3C, 'bit', ABX, 4, 1),
    (0x82, 'brl', REL16, 4, 0),
]:
    _op(code, mn, mode, cyc, pc)

# Which register's width flag sizes the operand: M for the accumulator group,
# X for the index group. Everything else is fixed-width.
M_OPS = {'lda', 'sta', 'adc', 'sbc', 'and', 'ora', 'eor', 'cmp', 'bit',
         'asl', 'lsr', 'rol', 'ror', 'inc', 'dec', 'stz', 'pha', 'pla'}
X_OPS = {'ldx', 'ldy', 'stx', 'sty', 'cpx', 'cpy', 'inx', 'dex', 'iny', 'dey',
         'phx', 'plx', 'phy', 'ply'}

RTS_TRAP = 0x3FFE          # call() pushes this; hitting it ends the run


class Sim:
    def __init__(self):
        self.mem = bytearray(0x10000)
        self.bank = {}                 # 65816 long reads: (bank, addr) -> byte
        self.sym = {}
        self.a = self.x = self.y = 0    # 16-bit registers; the high halves are
                                        #   simply unused while M/X say 8-bit
        self.sp = 0xFF
        self.c = self.z = self.n = self.v = 0
        self.cyc = 0
        self.unknown = None
        # 65816 mode, per alt-src ATCPU (co65802.inl / co65802.cpp
        # UpdateDecodeTable): e = emulation flag, m/x = the P width bits, 1 =
        # 8-bit. Emulation forces both to 1 and pins the stack to page 1, so a
        # plain 6502 build behaves exactly as it did before this existed.
        self.e = self.m = self.xf = 1
        self.pbr = 0                  # program bank (jsl/rtl; bank01.asm)

    # ---- loading -------------------------------------------------------
    @classmethod
    def from_xex(cls, path=None):
        s = cls()
        d = open(path or os.path.join(ROOT, 'build', 'doom_bsp.xex'), 'rb').read()
        i = 0
        if d[0:2] == b'\xff\xff':
            i = 2
        while i + 4 <= len(d):
            lo, hi = struct.unpack_from('<HH', d, i)
            i += 4
            if lo == 0xFFFF:                       # another $FFFF header
                continue
            n = hi - lo + 1
            s.mem[lo:lo + n] = d[i:i + n]
            i += n
        s.sym = load_syms()
        return s

    # ---- memory --------------------------------------------------------
    def rd(self, a):
        return self.mem[a & 0xFFFF]

    def wr(self, a, v):
        a &= 0xFFFF
        if 0xD000 <= a < 0xD800:                   # hardware window: accept+drop
            return
        self.mem[a] = v & 0xFF

    def poke16(self, a, v):
        self.wr(a, v & 0xFF); self.wr(a + 1, (v >> 8) & 0xFF)

    def peek16(self, a):
        return self.rd(a) | (self.rd(a + 1) << 8)

    def peek24(self, a):
        return self.rd(a) | (self.rd(a + 1) << 8) | (self.rd(a + 2) << 16)

    # ---- execution -----------------------------------------------------
    def call(self, addr, max_cyc=4_000_000, watch=None):
        """Run a subroutine, return its exact cycle count.

        `watch` is an address to count entries to -- self.watch_hits is how many
        times execution reached it. Cheaper and more honest than inferring a call
        count from a side effect (tools/_verify_wpsim.py counts DOOM tics by
        watching wp_tic itself)."""
        self.cyc = 0
        self.sp = 0xFD
        self.watch_hits = 0
        self.mem[0x01FF] = (RTS_TRAP >> 8) & 0xFF
        self.mem[0x01FE] = RTS_TRAP & 0xFF
        pc = addr
        while True:
            if pc == RTS_TRAP + 1 or pc == RTS_TRAP:
                return self.cyc
            if pc == watch:
                self.watch_hits += 1
            pc = self.step(pc)
            if self.cyc > max_cyc:
                raise RuntimeError(f'runaway at ${pc:04X} after {self.cyc} cycles')

    def step(self, pc):
        op = self.mem[pc]
        e = OPS.get(op)
        if e is None:
            raise NotImplementedError(f'opcode ${op:02X} at ${pc:04X}')
        mn, mode, cyc, pcx = e
        # ---- operand WIDTH (65816): M sizes the accumulator group, X the
        # index group; everything else is fixed. A 16-bit operand costs one
        # extra cycle and, for an immediate, one extra byte.
        w = 2 if ((mn in M_OPS and not self.m) or
                  (mn in X_OPS and not self.xf)) else 1
        mask = 0xFFFF if w == 2 else 0xFF
        # The second byte costs a cycle -- and TWO for a read-modify-write, which
        # reads both bytes, waits, then writes both back (alt-src
        # decode65816.cpp case 0x06: ReadL16/ReadH16/Asl16/Wait/WriteH16/WriteL16
        # against the 8-bit read/read/asl/write). asl/rol/inc on a 16-bit word
        # are the backbone of the converted divide, so getting this wrong would
        # have measured the rewrite in its own favour.
        rmw = mn in ('asl', 'lsr', 'rol', 'ror', 'inc', 'dec') and \
            mode not in (ACC, IMP)
        self.cyc += cyc + (0 if w == 1 else (2 if rmw else 1))
        n = SIZE[mode] + (1 if (w == 2 and mode == IMM) else 0)
        opnd = pc + 1
        addr = None
        if mode == IMM:
            val = self.mem[opnd] if w == 1 else \
                (self.mem[opnd] | (self.mem[opnd + 1] << 8))
        elif mode == ZP:
            addr = self.mem[opnd]
        elif mode == ZPX:
            addr = (self.mem[opnd] + self.x) & 0xFF
        elif mode == ZPY:
            addr = (self.mem[opnd] + self.y) & 0xFF
        elif mode == ABS:
            addr = self.mem[opnd] | (self.mem[opnd + 1] << 8)
        elif mode == ABX:
            base = self.mem[opnd] | (self.mem[opnd + 1] << 8)
            addr = (base + self.x) & 0xFFFF
            if pcx and (base & 0xFF00) != (addr & 0xFF00):
                self.cyc += 1
        elif mode == ABY:
            base = self.mem[opnd] | (self.mem[opnd + 1] << 8)
            addr = (base + self.y) & 0xFFFF
            if pcx and (base & 0xFF00) != (addr & 0xFF00):
                self.cyc += 1
        elif mode == IZX:
            p = (self.mem[opnd] + self.x) & 0xFF
            addr = self.mem[p] | (self.mem[(p + 1) & 0xFF] << 8)
        elif mode == IZY:
            p = self.mem[opnd]
            base = self.mem[p] | (self.mem[(p + 1) & 0xFF] << 8)
            addr = (base + self.y) & 0xFFFF
            if pcx and (base & 0xFF00) != (addr & 0xFF00):
                self.cyc += 1
        elif mode == LIY:                       # 65816 lda [dp],y
            p = self.mem[opnd]
            base = (self.mem[p] | (self.mem[(p + 1) & 0xFF] << 8)
                    | (self.mem[(p + 2) & 0xFF] << 16))
            addr = base + self.y
        elif mode == LAB:                       # 65816 lda.l abs24
            addr = (self.mem[opnd] | (self.mem[opnd + 1] << 8)
                    | (self.mem[opnd + 2] << 16))
        elif mode == LAX:                       # 65816 lda.l abs24,x
            addr = (self.mem[opnd] | (self.mem[opnd + 1] << 8)
                    | (self.mem[opnd + 2] << 16)) + self.x
        elif mode == IND:
            p = self.mem[opnd] | (self.mem[opnd + 1] << 8)
            addr = self.mem[p] | (self.mem[(p & 0xFF00) | ((p + 1) & 0xFF)] << 8)
        elif mode == REL:
            off = self.mem[opnd]
            addr = pc + 2 + (off - 256 if off > 127 else off)
        elif mode == REL16:                     # 65816 brl
            off = self.mem[opnd] | (self.mem[opnd + 1] << 8)
            addr = (pc + 3 + (off - 65536 if off > 32767 else off)) & 0xFFFF

        def rd1(a):
            if mode in (LIY, LAB, LAX) and a >= 0x10000:
                return self.bank.get(a, 0)
            return self.rd(a)

        def rdv():
            if mode == IMM:
                return val
            if w == 1:
                return rd1(addr)
            return rd1(addr) | (rd1(addr + 1) << 8)   # 16-bit: two accesses,
                                                      #   little-endian
        def wrv(v):
            if mode == LIY or (mode in (LAB, LAX) and addr >= 0x10000):
                self.bank[addr] = v & 0xFF
                if w == 2:
                    self.bank[addr + 1] = (v >> 8) & 0xFF
                return
            self.wr(addr, v & 0xFF)
            if w == 2:
                self.wr(addr + 1, (v >> 8) & 0xFF)

        def push(v, nb):
            for i in range(nb - 1, -1, -1):     # high byte first, as the chip
                self.mem[0x100 + self.sp] = (v >> (8 * i)) & 0xFF
                self.sp = (self.sp - 1) & 0xFF

        def pull(nb):
            v = 0
            for i in range(nb):
                self.sp = (self.sp + 1) & 0xFF
                v |= self.mem[0x100 + self.sp] << (8 * i)
            return v

        def widths():
            """P's M/X just changed: emulation pins both to 8-bit, and going
            8-bit on the INDEX side clears the register high halves (alt-src
            co65802.cpp UpdateDecodeTable)."""
            if self.e:
                self.m = self.xf = 1
            if self.xf:
                self.x &= 0xFF
                self.y &= 0xFF

        nxt = pc + n
        sgn = 0x8000 if w == 2 else 0x80          # sign bit at this width
        if mn == 'lda':
            self.a = (self.a & ~mask & 0xFFFF) | rdv()
            self._nz(self.a & mask, mask)
        elif mn == 'ldx':
            self.x = rdv(); self._nz(self.x, mask)
        elif mn == 'ldy':
            self.y = rdv(); self._nz(self.y, mask)
        elif mn == 'sta':
            wrv(self.a & mask)
        elif mn == 'stx':
            wrv(self.x & mask)
        elif mn == 'sty':
            wrv(self.y & mask)
        elif mn == 'stz':
            wrv(0)
        elif mn == 'adc':
            a = self.a & mask
            v = rdv(); t = a + v + self.c
            self.v = 1 if (~(a ^ v) & (a ^ t) & sgn) else 0
            self.c = 1 if t > mask else 0
            self.a = (self.a & ~mask & 0xFFFF) | (t & mask)
            self._nz(self.a & mask, mask)
        elif mn == 'sbc':
            a = self.a & mask
            v = rdv() ^ mask; t = a + v + self.c
            self.v = 1 if (~(a ^ v) & (a ^ t) & sgn) else 0
            self.c = 1 if t > mask else 0
            self.a = (self.a & ~mask & 0xFFFF) | (t & mask)
            self._nz(self.a & mask, mask)
        elif mn in ('and', 'ora', 'eor'):
            a = self.a & mask
            v = rdv()
            r = {'and': a & v, 'ora': a | v, 'eor': a ^ v}[mn]
            self.a = (self.a & ~mask & 0xFFFF) | (r & mask)
            self._nz(r & mask, mask)
        elif mn in ('cmp', 'cpx', 'cpy'):
            r = {'cmp': self.a, 'cpx': self.x, 'cpy': self.y}[mn] & mask
            v = rdv(); t = (r - v) & mask
            self.c = 1 if r >= v else 0
            self._nz(t, mask)
        elif mn == 'bit':
            v = rdv(); self.z = 1 if ((self.a & mask) & v) == 0 else 0
            if mode != IMM:                       # bit #imm touches Z only
                self.n = 1 if (v & sgn) else 0
                self.v = 1 if (v & (sgn >> 1)) else 0
        elif mn in ('asl', 'lsr', 'rol', 'ror'):
            v = (self.a & mask) if mode == ACC else rdv()
            if mn == 'asl':
                c2, v = 1 if v & sgn else 0, (v << 1) & mask
            elif mn == 'lsr':
                c2, v = v & 1, v >> 1
            elif mn == 'rol':
                c2, v = 1 if v & sgn else 0, ((v << 1) | self.c) & mask
            else:
                c2, v = v & 1, (v >> 1) | (self.c * sgn)
            self.c = c2
            if mode == ACC:
                self.a = (self.a & ~mask & 0xFFFF) | v
            else:
                wrv(v)
            self._nz(v, mask)
        elif mn in ('inc', 'dec'):
            d = 1 if mn == 'inc' else -1
            if mode == ACC:                       # 65816 inc a / dec a
                v = ((self.a & mask) + d) & mask
                self.a = (self.a & ~mask & 0xFFFF) | v
            else:
                v = (rdv() + d) & mask
                wrv(v)
            self._nz(v, mask)
        elif mn in ('inx', 'dex', 'iny', 'dey'):
            d = 1 if mn in ('inx', 'iny') else -1
            if mn in ('inx', 'dex'):
                self.x = (self.x + d) & mask; self._nz(self.x, mask)
            else:
                self.y = (self.y + d) & mask; self._nz(self.y, mask)
        elif mn in ('tax', 'tay'):                # width is the INDEX width
            xm = 0xFF if self.xf else 0xFFFF
            v = self.a & xm
            if mn == 'tax':
                self.x = v
            else:
                self.y = v
            self._nz(v, xm)
        elif mn in ('txa', 'tya'):                # ... and here the ACC width
            am = 0xFF if self.m else 0xFFFF
            v = (self.x if mn == 'txa' else self.y) & am
            self.a = (self.a & ~am & 0xFFFF) | v
            self._nz(v, am)
        elif mn in ('txy', 'tyx'):
            xm = 0xFF if self.xf else 0xFFFF
            if mn == 'txy':
                self.y = self.x & xm; self._nz(self.y, xm)
            else:
                self.x = self.y & xm; self._nz(self.x, xm)
        elif mn == 'tsx':
            xm = 0xFF if self.xf else 0xFFFF
            self.x = (self.sp if self.xf else (0x100 | self.sp)) & xm
            self._nz(self.x, xm)
        elif mn == 'txs':
            self.sp = self.x & 0xFF               # the stack stays in page 1
        elif mn in ('tcs', 'tsc', 'tcd', 'tdc'):
            if mn == 'tcs':
                self.sp = self.a & 0xFF
            elif mn == 'tsc':
                self.a = 0x100 | self.sp; self._nz(self.a, 0xFFFF)
            elif mn == 'tcd':
                if self.a & 0xFFFF:
                    raise NotImplementedError(
                        'tcd with a non-zero direct page -- the sim pins DP to 0')
            else:
                self.a = 0; self._nz(0, 0xFFFF)
        elif mn == 'xba':                         # swap the accumulator halves
            self.a = ((self.a << 8) | (self.a >> 8)) & 0xFFFF
            self._nz(self.a & 0xFF, 0xFF)         # flags come from the new LOW
        elif mn in ('rep', 'sep'):
            # alt-src co65802.inl kStateRep/kStateSep: in EMULATION the m and x
            # bits are off-limits (mask $CF), in native every bit is fair game.
            bits = val & (0xCF if self.e else 0xFF)
            if mn == 'rep':
                if bits & 0x20: self.m = 0
                if bits & 0x10: self.xf = 0
                if bits & 0x01: self.c = 0
                if bits & 0x02: self.z = 0
                if bits & 0x40: self.v = 0
                if bits & 0x80: self.n = 0
            else:
                if bits & 0x20: self.m = 1
                if bits & 0x10: self.xf = 1
                if bits & 0x01: self.c = 1
                if bits & 0x02: self.z = 1
                if bits & 0x40: self.v = 1
                if bits & 0x80: self.n = 1
            widths()
        elif mn == 'xce':
            # kStateXce: carry <-> emulation, and a REAL change forces both
            # width bits back to 8-bit.
            new_e = self.c
            if new_e != self.e:
                self.c = self.e
                self.m = self.xf = 1
                self.e = new_e
                if self.e:
                    self.sp = self.sp & 0xFF
                widths()
        elif mn == 'clc':
            self.c = 0
        elif mn == 'sec':
            self.c = 1
        elif mn in ('cld', 'cli', 'sei', 'clv', 'nop'):
            pass
        elif mn == 'pha':
            push(self.a & mask, w)
        elif mn == 'pla':
            v = pull(w)
            self.a = (self.a & ~mask & 0xFFFF) | v
            self._nz(v, mask)
        elif mn in ('phx', 'phy'):
            push((self.x if mn == 'phx' else self.y) & mask, w)
        elif mn in ('plx', 'ply'):
            v = pull(w)
            if mn == 'plx':
                self.x = v
            else:
                self.y = v
            self._nz(v, mask)
        elif mn in ('phb', 'phk'):
            push(0, 1)                            # DBR/PBR: this port is bank 0
        elif mn == 'plb':
            pull(1)
        elif mn == 'phd':
            push(0, 2)                            # DP is pinned to 0 (tcd)
        elif mn == 'pld':
            pull(2)
        elif mn == 'php':
            p = ((self.n << 7) | (self.v << 6) | (self.z << 1) | self.c |
                 (0x30 if self.e else ((self.m << 5) | (self.xf << 4))))
            push(p, 1)
        elif mn == 'plp':
            p = pull(1)
            self.n, self.v = (p >> 7) & 1, (p >> 6) & 1
            self.z, self.c = (p >> 1) & 1, p & 1
            if not self.e:
                self.m, self.xf = (p >> 5) & 1, (p >> 4) & 1
                widths()
        elif mn in ('jmp', 'brl'):
            nxt = addr
        elif mn == 'jsr':
            r = pc + 2
            self.mem[0x100 + self.sp] = (r >> 8) & 0xFF
            self.sp = (self.sp - 1) & 0xFF
            self.mem[0x100 + self.sp] = r & 0xFF
            self.sp = (self.sp - 1) & 0xFF
            nxt = addr
        elif mn == 'jsl':                 # 65816: push PBR:PC-1, then long jump
            r = pc + 3
            self.mem[0x100 + self.sp] = self.pbr
            self.sp = (self.sp - 1) & 0xFF
            self.mem[0x100 + self.sp] = (r >> 8) & 0xFF
            self.sp = (self.sp - 1) & 0xFF
            self.mem[0x100 + self.sp] = r & 0xFF
            self.sp = (self.sp - 1) & 0xFF
            self.pbr = (addr >> 16) & 0xFF
            nxt = addr & 0xFFFF
        elif mn == 'rtl':
            self.sp = (self.sp + 1) & 0xFF; lo = self.mem[0x100 + self.sp]
            self.sp = (self.sp + 1) & 0xFF; hi = self.mem[0x100 + self.sp]
            self.sp = (self.sp + 1) & 0xFF; self.pbr = self.mem[0x100 + self.sp]
            nxt = ((hi << 8) | lo) + 1
        elif mn == 'rts':
            self.sp = (self.sp + 1) & 0xFF; lo = self.mem[0x100 + self.sp]
            self.sp = (self.sp + 1) & 0xFF; hi = self.mem[0x100 + self.sp]
            nxt = ((hi << 8) | lo) + 1
        elif mn == 'rti':
            self.sp = (self.sp + 1) & 0xFF; p = self.mem[0x100 + self.sp]
            self.n, self.v = (p >> 7) & 1, (p >> 6) & 1
            self.z, self.c = (p >> 1) & 1, p & 1
            self.sp = (self.sp + 1) & 0xFF; lo = self.mem[0x100 + self.sp]
            self.sp = (self.sp + 1) & 0xFF; hi = self.mem[0x100 + self.sp]
            nxt = (hi << 8) | lo
            if not self.e:                # native: P carries M/X and the frame
                self.m, self.xf = (p >> 5) & 1, (p >> 4) & 1
                widths()                  #   has a PBR byte under the PC
                self.sp = (self.sp + 1) & 0xFF
        elif mn in ('bcc', 'bcs', 'beq', 'bne', 'bmi', 'bpl', 'bvc', 'bvs'):
            take = {'bcc': not self.c, 'bcs': self.c, 'beq': self.z,
                    'bne': not self.z, 'bmi': self.n, 'bpl': not self.n,
                    'bvc': not self.v, 'bvs': self.v}[mn]
            if take:
                self.cyc += 1
                if (addr & 0xFF00) != ((pc + 2) & 0xFF00):
                    self.cyc += 1
                nxt = addr
        return nxt

    def _nz(self, v, mask=0xFF):
        self.z = 1 if (v & mask) == 0 else 0
        self.n = 1 if (v & ((mask >> 1) + 1)) else 0   # bit7 / bit15


def load_syms():
    """Symbol -> address, from the .lab the assembler writes (or the listing)."""
    out = {}
    lab = os.path.join(ROOT, 'build', 'doom_bsp.lab')
    if os.path.exists(lab):
        for line in open(lab, encoding='utf-8', errors='replace'):
            m = re.match(r'\s*\d+\s+([0-9A-F]{4})\s+(\S+)', line)
            if m:
                out[m.group(2).lstrip('.')] = int(m.group(1), 16)
    lst = os.path.join(ROOT, 'build', 'doom_bsp.lst')
    if os.path.exists(lst):
        pend = None
        for line in open(lst, encoding='utf-8', errors='replace'):
            # equates and .ds reservations: "  129 = 00E8    m_a  .ds 2"
            e = re.match(r'\s*\d+\s+=\s+([0-9A-F]{4})\s+(\w+)', line)
            if e:
                out.setdefault(e.group(2), int(e.group(1), 16))
                continue
            # mads stamps the FIRST line of a block with its extent, e.g.
            # "   38 B7C1-B7F1> AD EA 0F\t lda mv_i" -- and that is exactly the
            # line a .proc's entry point is on. Without the optional range the
            # match failed, the entry fell through to the SECOND instruction,
            # and every harness called each routine one instruction in (mv_ptr
            # then ran without its `lda mv_i`, i.e. on a leftover accumulator).
            m = re.match(r'\s*\d+\s+([0-9A-F]{4})(?:-[0-9A-F]{4}>)?'
                         r'\s([0-9A-F ]{0,14})\t(.*)$', line)
            if not m:
                continue
            p = re.search(r'\.proc\s+(\w+)', m.group(3))
            if p:
                pend = p.group(1)
            elif pend and m.group(2).strip():
                out.setdefault(pend, int(m.group(1), 16))
                pend = None
            eq = re.match(r'\s*(\w+)\s*=\s*\$?([0-9A-Fa-f]+)', m.group(3))
            if eq:
                try:
                    out.setdefault(eq.group(1), int(eq.group(2), 16))
                except ValueError:
                    pass
    return out


if __name__ == '__main__':
    s = Sim.from_xex()
    print(f'loaded {len(s.sym)} symbols')
    for k in ('umul16', 'udiv24', 'track_calc', 'plane_setup', 'screenx_signed'):
        print(f'   {k:16} ${s.sym.get(k, 0):04X}')
