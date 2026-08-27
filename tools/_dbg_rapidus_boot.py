#!/usr/bin/env python3
"""RapidusBoot -- simulate the ATR cold boot on sim6502, end to end.

Rebuilt 2026-08-17: the original vanished with the rest of tools/tests'
harnesses (the "bad magic number" era). check_boot.py imports RapidusBoot and
treats run() == True as "this ATR comes up".

What is simulated, and how faithfully:
  * The OS boot handoff: sector 1's header names the count + load address
    ($0700 x 3), the OS enters at load+6 (EBL: JMP (RAMLO) at BOOTAD+6).
  * SIOV ($E459) is HOOKED, not emulated: the DCB at $0300 is read, the
    sector served straight from the ATR image, Y/DSTATS = 1, then an RTS is
    synthesized. Command $52 reads, $50/$57 write back into the image (for a
    future _verify_save), anything else just succeeds. The engine drives the
    same vector (diskio.asm SIOV equ $E459), so one hook covers the whole
    boot: loader -> XEX -> INIT -> main -> (run_to) the level loaders.
  * VBI: every VBI_PERIOD cycles, IF the recorded NMIEN ($D40E, BootSim.hw)
    has bit6 set AND $FFFA holds a vector, an NMI frame is pushed and the
    vector taken -- plus the OS's RTCLOK tick ($14/$13/$12), which is what
    swap_buffers/menu code actually wait on. During boot.asm's under-ROM
    byte stores NMIEN is 0, so nothing fires there -- exactly the invariant
    the loader depends on.
  * RAM under the ROM starts VIRGIN (zeros): a path that relies on ROM
    content, or takes an interrupt through an uninstalled vector, dies
    loudly instead of booting -- which is the point of the gate.
  * PORTB banking is a no-op (one flat 64 KB + the bank dict): correct for
    a loader whose ROM-out windows only WRITE RAM that nothing else claims.

  from _dbg_rapidus_boot import RapidusBoot
  RapidusBoot().run()                      # -> True if PC reached main
  RapidusBoot().run(until='menu_boot')     # any .lab symbol / address
"""
import os

from sim6502 import Sim, load_syms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATR = os.path.join(ROOT, 'build', 'doom_e1.atr')

SIOV = 0xE459
VBI_PERIOD = 30000                   # ~1 frame at 1.79 MHz; the engine only
                                     # ever tests "did RTCLOK move", not rates


class FlatBank:
    """The 65816 24-bit space as ONE 16 MB bytearray instead of Sim's dict --
    the boot tee parks megabytes in SDRAM and a dict of ints would cost ~100 B
    a byte. Duck-types the two calls Sim makes (get / [addr] = v)."""

    def __init__(self):
        self.m = bytearray(0x1000000)

    def get(self, a, default=0):
        return self.m[a & 0xFFFFFF]

    def __setitem__(self, a, v):
        self.m[a & 0xFFFFFF] = v & 0xFF


VBXE_VCTL = 0xD640                   # r: CORE_VERSION ($10 = FX 1.xx)
VBXE_BL_BUSY = 0xD653                # r: non-zero while the blitter runs
VBXE_BANK_SEL = 0xD65F               # w: MEMAC-A bank (bit7 = enable)
MEMW = 0x9000                        # the 4 KB MEMAC-A window
CORE_FX_1XX = 0x10


class BootSim(Sim):
    """Sim + the hardware the boot path actually touches:
      * $D000-$D7FF stores are RECORDED (BootSim.hw) -- NMI injection gates on
        NMIEN ($D40E) -- and reads come from a tiny register model instead of
        zeros: CORE_VERSION says "VBXE present" (or detect_vbxe halts the
        boot), BL_BUSY says "idle".
      * MEMAC-A: with BANK_SEL bit7 set, $9000-$9FFF reads/writes hit
        vram[bank*4K + off] (512 KB) -- mn_open COPIES the menu overlay CODE
        back out of VBXE through that window, so a zero model would jump into
        garbage instead of the menu.
      * bank: FlatBank, so the SDRAM tee can park the whole episode."""

    def __init__(self):
        super().__init__()
        self.hw = {}
        self.vram = bytearray(0x80000)
        self.bank = FlatBank()
        self.tap_until = 0               # cyc horizon: a key is HELD until then
        self.tap_code = 0x21             # its KBCODE (SPACE -- dismisses the
                                         #   title, USE in-game: harmless)

    def _memac(self):
        b = self.hw.get(VBXE_BANK_SEL, 0)
        return (b & 0x7F) if (b & 0x80) else None

    def rd(self, a):
        a &= 0xFFFF
        if 0xD000 <= a < 0xD800:
            if a == VBXE_VCTL:
                return CORE_FX_1XX
            if a == VBXE_BL_BUSY:
                return 0
            if a == 0xD20F:               # SKSTAT: bit2 = 0 while the injected
                return 0xFB if self.cyc < self.tap_until else 0xFF   # key is held
            if a == 0xD209:               # KBCODE latches the last key
                return self.tap_code
            if 0xD200 <= a < 0xD300:      # POKEY read regs: IRQST $FF = no IRQ
                return 0xFF               #   pending

            if 0xD300 <= a < 0xD400:      # PIA: reads back writes; $FF = stick
                return self.hw.get(a, 0xFF)   # centered, OS ROM in (PORTB bit0)
            if 0xD010 <= a <= 0xD013:     # GTIA TRIGn: 1 = not pressed
                return 1
            if a == 0xD01F:               # CONSOL: 7 = no console key
                return 7
            return self.hw.get(a, 0)
        bank = self._memac()
        if bank is not None and MEMW <= a < MEMW + 0x1000:
            return self.vram[bank * 0x1000 + (a - MEMW)]
        return self.mem[a]

    def wr(self, a, v):
        a &= 0xFFFF
        if 0xD000 <= a < 0xD800:
            self.hw[a] = v & 0xFF
            return
        bank = self._memac()
        if bank is not None and MEMW <= a < MEMW + 0x1000:
            self.vram[bank * 0x1000 + (a - MEMW)] = v & 0xFF
            return
        self.mem[a] = v & 0xFF


class RapidusBoot:
    def __init__(self, atr_path=ATR, verbose=False):
        self.atr = bytearray(open(atr_path, 'rb').read())
        if self.atr[0] | (self.atr[1] << 8) != 0x0296:
            raise ValueError(f'{atr_path}: no ATR signature')
        self.secsize = self.atr[4] | (self.atr[5] << 8)
        if self.secsize != 128:
            raise ValueError(f'{atr_path}: {self.secsize} B sectors, expected 128')
        self.s = BootSim()
        self.s.sym = load_syms()
        self.verbose = verbose
        self.sio_reads = 0

    # ---- ATR sectors ---------------------------------------------------
    def sector(self, n):
        off = 16 + (n - 1) * 128
        return self.atr[off:off + 128]

    # ---- the SIOV hook -------------------------------------------------
    def _siov(self):
        s, m = self.s, self.s.mem
        cmd = m[0x0302]
        buf = m[0x0304] | (m[0x0305] << 8)
        n = (m[0x0308] | (m[0x0309] << 8)) or 128
        sec = m[0x030A] | (m[0x030B] << 8)
        if cmd == 0x52:                                   # read sector
            data = self.sector(sec)[:n]
            m[buf:buf + len(data)] = data
            self.sio_reads += 1
        elif cmd in (0x50, 0x57):                         # write (savegames)
            off = 16 + (sec - 1) * 128
            self.atr[off:off + n] = bytes(m[buf:buf + n])
        s.y = 1                                           # Y = 1: success
        m[0x0303] = 1                                     # ... and DSTATS
        s.sp = (s.sp + 1) & 0xFF; lo = m[0x100 + s.sp]    # synthesize the RTS
        s.sp = (s.sp + 1) & 0xFF; hi = m[0x100 + s.sp]
        return ((hi << 8) | lo) + 1

    # ---- the injected VBI ----------------------------------------------
    def _vbi(self, pc):
        s, m = self.s, self.s.mem
        if not (s.hw.get(0xD40E, 0) & 0x40):
            return pc                                     # NMIs off at ANTIC
        vec = m[0xFFFA] | (m[0xFFFB] << 8)
        if vec == 0:
            return pc                                     # no vector installed
        m[0x14] = (m[0x14] + 1) & 0xFF                    # OS stage-1: RTCLOK
        if m[0x14] == 0:
            m[0x13] = (m[0x13] + 1) & 0xFF
            if m[0x13] == 0:
                m[0x12] = (m[0x12] + 1) & 0xFF
        m[0x100 + s.sp] = (pc >> 8) & 0xFF                # NMI frame (e-mode)
        s.sp = (s.sp - 1) & 0xFF
        m[0x100 + s.sp] = pc & 0xFF
        s.sp = (s.sp - 1) & 0xFF
        m[0x100 + s.sp] = ((s.n << 7) | (s.v << 6) | 0x30 |
                           (s.z << 1) | s.c)
        s.sp = (s.sp - 1) & 0xFF
        return vec

    # ---- diagnostics ---------------------------------------------------
    def _where(self, pc):
        best, bn = None, None
        for k, v in self.s.sym.items():
            if v <= pc and (best is None or v > best):
                best, bn = v, k
        return f'{bn}+${pc - best:X}' if bn else f'${pc:04X}'

    def _explain(self, pc, ring, why):
        s = self.s
        print(f'  BOOT FAILED: {why}')
        print(f'  pc=${pc:04X} ({self._where(pc)})  a=${s.a:04X} x=${s.x:04X} '
              f'y=${s.y:04X} sp=${s.sp:02X} e={s.e} m={s.m} x16={s.xf} '
              f'cyc={s.cyc}  sio_reads={self.sio_reads}')
        seen, out = set(), []
        for p in reversed(ring):
            w = self._where(p)
            r = w.split('+')[0]
            if r not in seen:
                seen.add(r)
                out.append(f'${p:04X} {w}')
            if len(out) >= 8:
                break
        print('  trail: ' + '  <-  '.join(out))

    # ---- the run -------------------------------------------------------
    def run(self, until=None, max_cycles=600_000_000, tap=False):
        """Boot the mounted ATR: OS handoff -> boot loader -> XEX -> INIT ->
        RUN. True when PC first reaches `until` (default: main).
        tap=True: press-and-release SPACE every ~700k cycles -- the title and
        the READ THIS! pages block on MN_ANYKEY, and SPACE is the one key that
        dismisses them without navigating the menu (in-game it is only USE)."""
        s, m = self.s, self.s.mem
        b0 = self.sector(1)
        cnt, lda = b0[1], b0[2] | (b0[3] << 8)
        blob = b''.join(bytes(self.sector(i)) for i in range(1, cnt + 1))
        m[lda:lda + len(blob)] = blob
        pc = lda + 6                                      # OS EBL: BOOTAD+6
        if until is None:
            target = self.s.sym.get('main') or self.s.sym.get('MAIN', 0x2000)
        elif isinstance(until, str):
            target = self.s.sym[until]
        else:
            target = until
        ring = []
        next_vbi = VBI_PERIOD
        next_tap = 2_000_000             # first tap well after the title is up
        while s.cyc < max_cycles:
            if pc == SIOV:
                pc = self._siov()
                continue
            if pc == target:
                if self.verbose:
                    print(f'  reached {self._where(pc)} at cyc={s.cyc}, '
                          f'{self.sio_reads} sector reads')
                return True
            ring.append(pc)
            if len(ring) > 96:
                del ring[:32]
            try:
                pc = s.step(pc)
            except Exception as e:                        # unimplemented op etc.
                self._explain(pc, ring, f'{type(e).__name__}: {e}')
                return False
            if s.cyc >= next_vbi:
                next_vbi += VBI_PERIOD
                if tap and s.cyc >= next_tap:
                    s.tap_until = s.cyc + 90_000       # held across ~3 frames
                    next_tap = s.cyc + 700_000
                pc = self._vbi(pc)
        self._explain(pc, ring, f'cycle budget {max_cycles} exhausted '
                                f'(a wait loop the sim does not feed?)')
        return False


if __name__ == '__main__':
    ok = RapidusBoot(verbose=True).run()
    print('boot sim:', 'OK -- reached main' if ok else 'FAILED')
    raise SystemExit(0 if ok else 1)
