#!/usr/bin/env python3
"""check_boot -- the "will it even boot" guard, wired into build_atr.ps1.

Three checks, each one a regression we have already paid for once
(2026-08-10, the Rapidus black-screen day):

  1. The boot sectors install the safety RTI vectors into the RAM under the
     ROM (with the ROM banked out) before anything loads. Without them, one
     interrupt in any ROM-out moment reads virgin $FFFA/$FFFE -> $00FF ->
     BRK loop -> black screen.
  2. The XEX carries the Rapidus MCR guard (window $8000-$BFFF forced slow:
     a fast window there shadows the VBXE MEMAC-A reads at $9000 and the menu
     overlay loads as garbage), and the boot sectors carry the MCR fast-region
     write (write-through + I/O split + fast1 + fast3). 2026-08-11: window 1
     ($4000-$7FFF) is deliberately FAST now (MEMAC-B is off) -- a guard that
     re-slows it is the bug that made every region experiment measure 0.0%.
  3. The REAL boot path runs in the 6502 sim -- ATR boot sectors, the $0700
     loader, every XEX segment, VBI NMIs injected, RAM under the ROM virgin --
     and must reach main ($2000). Catches unprotected ROM-out windows, broken
     segment order, loader regressions.

Exit 0 = all good; exit 1 + message = the build must fail.
"""
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, os.path.join(TOOLS, "tests"))
sys.path.insert(0, TOOLS)                        # ...and TOOLS AHEAD of it:
# tests/ holds a sourceless _dbg_rapidus_boot.pyc from some older Python and
# with tests/ first it shadowed the real .py -- "bad magic number", which the
# guard below turned into a permanent SKIP. The simulated boot had not run
# since 2026-08-10 because of the search order alone.

ATR = os.path.join(ROOT, "build", "doom_e1.atr")
XEX = os.path.join(ROOT, "build", "doom_bsp.xex")

def fail(msg):
    print(f"BOOT CHECK FAIL: {msg}")
    sys.exit(1)

def main():
    atr = open(ATR, "rb").read()
    xex = open(XEX, "rb").read()
    boot = atr[16:16 + 384]              # boot sectors 1-3

    # 1 -- the safety vectors: sta $FFFA / sta $FFFE with the ROM banked out.
    if boot.find(bytes.fromhex("8dfaff")) < 0 or boot.find(bytes.fromhex("8dfeff")) < 0:
        fail("boot loader no longer installs the RTI safety vectors at $FFFA/$FFFE")

    # 2 -- the Rapidus MCR guard: lda.l $FF0080 / ora #$04 / sta.l $FF0080
    #      (bit2 only: win2 $8000-$BFFF slow for MEMAC-A -- win1 must STAY fast).
    if xex.find(bytes.fromhex("af8000ff09048f8000ff")) < 0:
        fail("XEX lost the Rapidus MCR guard (win2 $8000-$BFFF slow; xdl_build)")
    if xex.find(bytes.fromhex("af8000ff09068f8000ff")) >= 0:
        fail("an MCR guard re-slows window 1 ($4000-$7FFF) -- the 0.0% fetch bug "
             "(2026-08-11); only bit2 (win2) may be forced slow")

    # 2b -- the boot MCR write: lda.l $FF0080 / ora #$60 / and #$F5 / sta.l --
    #       write-through + I/O split on, fast1 ($4000-$7FFF) + fast3 (under-ROM).
    if boot.find(bytes.fromhex("af8000ff096029f58f8000ff")) < 0:
        fail("boot sectors lost the MCR fast-region write (fast1+fast3+split; boot.asm)")

    # 3 -- the real boot, simulated: must reach main ($2000).
    #      _dbg_rapidus_boot exists only as a .pyc for another Python on this
    #      machine (2026-08-10) -- an ENVIRONMENT failure is a SKIP with a
    #      warning, same policy as build_atr.ps1 gives the _verify_* gates;
    #      a real boot-sim FAILURE still fails the build below.
    try:
        from _dbg_rapidus_boot import RapidusBoot
    except ImportError as e:
        print(f"boot check: vectors + MCR guard OK; SKIP simulated boot "
              f"({e})")
        return
    if not RapidusBoot().run():
        fail("simulated ATR boot did not reach main ($2000) -- see the trace above")

    print("boot check OK (vectors + MCR guard + simulated boot to main)")

if __name__ == "__main__":
    main()
