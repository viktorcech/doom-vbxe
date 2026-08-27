;==============================================================
; underrom.asm -- using the 16 KB of RAM UNDER the OS ROM ($C000-$FFFF)
;--------------------------------------------------------------
; WHY. The Rapidus accelerates the 6502 only in the 16 KB windows it maps into
; its own SRAM, and the block $8000-$BFFF can NEVER be one of them: the VBXE
; MEMAC-A window ($9000) lives there, and an enabled Rapidus window would shadow
; it (Altirra alt-src/Altirra/source/rapidus.cpp, UpdateSRAMWindows). Everything
; in $8000-$BFFF therefore runs at 1.79 MHz -- and that is exactly where the
; per-column texture code sat, which is why textured mode was 5-10x slower than
; flat mode on a Rapidus.
;
; The fix is to move the texture path down into $0000-$3FFF (a Rapidus window),
; and there was no room -- until here. This file makes the RAM under the OS ROM
; usable, so COLD code (collision, doors) can move up there and free the fast
; low RAM for the hot renderer code.
;
; HOW. Three pieces:
;   1. boot.asm stores $C000+ XEX segments with the ROM briefly banked out, so
;      the code physically arrives in that RAM.
;   2. urom_init writes OUR interrupt vectors into $FFFA/$FFFE (RAM). They are
;      only ever fetched while the ROM is banked out, which is precisely when the
;      OS handlers are unreachable -- so an NMI (VBI) or the sound Timer-1 IRQ
;      taken inside a bank-out window lands somewhere valid instead of on
;      whatever byte happened to be in RAM. With those in place the engine can
;      bank freely WITHOUT masking interrupts.
;   3. urom_call trampolines: bank out, call, bank in, preserving A/X/Y + flags.
;      Only cold code goes under the ROM, so ~40 cycles per call costs nothing.
;
; RULES for code that lives under the ROM:
;   * it may call anything in $0000-$BFFF (unaffected by the banking),
;   * it must NOT call the OS (SIOV/CIOV) -- that is why diskio.asm stays below,
;   * it must not be entered except through a trampoline here.
;==============================================================

NMIRES  equ $D40F                    ; write: reset the NMI status latch

        org UROM_STUB_BASE

;--------------------------------------------------------------
; rom_nmi -- stand-in for the OS VBI while the ROM is banked out. The engine
;   only wants one thing from that VBI: RTCLOK3 ticking (swap_buffers waits on
;   it, frame_dt derives door/lift speed from it). NMIEN is $40 (VBI only), so
;   there is nothing to dispatch.
;--------------------------------------------------------------
.proc rom_nmi
        sep #$20                     ; 65816 NATIVE-MODE DISCIPLINE (2026-08-11
                                     ;   pm): an interrupt does NOT resize the
                                     ;   registers -- M/X stay whatever the
                                     ;   interrupted code had (alt-src
                                     ;   co65802.cpp UpdateDecodeTable). Caught
                                     ;   inside a 16-bit block, `pha` would push
                                     ;   TWO bytes against a one-byte `pla` and
                                     ;   `inc RTCLOK3` would carry into $15. So
                                     ;   pin 8-bit FIRST; the RTI's pulled P puts
                                     ;   the widths back. Harmless in emulation
                                     ;   (m/x are read-only there, and this runs
                                     ;   before anything is pushed).
                                     ; #$20, NOT #$30 (2026-08-14): `sep #$10`
                                     ;   ZEROES the high bytes of X and Y, and no
                                     ;   RTI brings them back -- it restores the
                                     ;   width BITS only. This handler touches
                                     ;   neither register, so leaving X/Y alone
                                     ;   costs nothing and keeps a 16-bit index
                                     ;   alive across the VBI. M is different: the
                                     ;   accumulator's high half lives in B and
                                     ;   sep #$20 does not disturb it, so the
                                     ;   pha/pla pair below is still one byte.
                                     ;   snd_irq DOES use X and pays for it there.
        pha
        sta NMIRES                   ; $D40F: any write clears the NMI latch
        inc RTCLOK3
        lda XDLA_PEND                ; deferred triple-buffer flip (2026-08-11):
        beq ?done                    ;   publish the XDL INSIDE the blank -- the
        sta VBXE_XDLA1               ;   real FX core switches mid-frame if the
        lda #0                       ;   store lands mid-picture (the flicker),
        sta XDLA_PEND                ;   Altirra latches at frame start; this is
?done   pla                          ;   correct on both. $00 = nothing pending.
        rti
.endp

;--------------------------------------------------------------
; urom_init -- install rom_nmi / snd_irq into the RAM vectors. Call ONCE at boot,
;   after snd_init and before the first bank-out. Clobbers A.
;--------------------------------------------------------------
.proc urom_init
        sei
        lda #0
        sta NMIEN                    ; VBI off for the same reason boot.asm turns
                                     ;   it off around its stores: THIS bank-out
                                     ;   is the one window where the RAM vectors
                                     ;   are not installed yet, so an NMI here
                                     ;   would jump through garbage. SEI does not
                                     ;   cover NMI.
        lda PORTB
        and #$FE
        sta PORTB                    ; ROM out: $FFFA-$FFFF is RAM now
        lda #<rom_nmi
        sta $FFFA
        sta $FFEA                    ; ... and the NATIVE-mode NMI vector
        lda #>rom_nmi                ;   (2026-08-11 pm): a 65816 in native mode
        sta $FFFB                    ;   fetches NMI from $FFEA and IRQ from
        sta $FFEB                    ;   $FFEE, NOT $FFFA/$FFFE (alt-src
                                     ;   co65802.inl kState816_NatNMIVecToPC).
                                     ;   Without these two, the first VBI taken
                                     ;   inside ANY 16-bit block would fetch its
                                     ;   handler out of virgin RAM -- the same
                                     ;   black screen the $FFFA pair was added
                                     ;   for. They cost 8 bytes and buy the
                                     ;   whole native-mode path.
                                     ; NO RESET vector here (2026-08-09, -10 B).
                                     ;   It used to write main to $FFFC/$FFFD as
                                     ;   "a sane placeholder" -- but that RAM can
                                     ;   never be fetched. On the XL the reset
                                     ;   button resets the PIA along with the CPU
                                     ;   (Altirra simulator.cpp InternalWarmReset:
                                     ;   mPIA.WarmReset() + SetBankRegister($FF)
                                     ;   BEFORE mCPU.WarmReset()), so PORTB is $FF
                                     ;   and $FFFC comes out of the OS ROM. On a
                                     ;   400/800 the button is /RNMI, an NMI, and
                                     ;   $FFFC is not fetched at all.
        lda #<snd_irq                ; the Timer-1 digi IRQ (sound.asm)
        sta $FFFE
        sta $FFEE                    ; ... and its native-mode vector
        lda #>snd_irq
        sta $FFFF
        sta $FFEF
        lda PORTB
        ora #$01
        sta PORTB                    ; ROM back in
        lda #$40
        sta NMIEN                    ; VBI back on (RTCLOK3 drives frame_dt;
                                     ;   ZFRONT/FRM_PAR/XDLA_PEND were zeroed in
                                     ;   setup_chains, long before this NMIEN)
        cli
        rts
.endp

;--------------------------------------------------------------
; rom_out / rom_in -- the banking pair. PORTB is read-modify-written so the BASIC
;   (bit 1) and self-test (bit 7) bits keep whatever the machine booted with.
;   Clobbers A + flags; that is why the trampolines save them around rom_in.
;   Parked at ROMBANK_BASE (2026-08-11 pm): once per LEVEL, never per frame, so
;   win2's fetch cost is invisible -- and the 18 bytes they leave behind are
;   what urom_init needed for the native-mode vectors above.
;--------------------------------------------------------------
; THE 65816 MODE INVARIANT (2026-08-11 pm) lives in this pair:
;     ROM OUT  <=>  NATIVE mode        ROM IN  <=>  EMULATION mode
; Native mode fetches NMI from $FFEA and IRQ from $FFEE. Those are RAM -- and
; urom_init fills them -- but ONLY while the ROM is banked out; with the ROM in,
; $FFEA reads OS ROM and a VBI would vector into whatever byte is there. Tying
; the mode to the banking makes that window impossible to open by accident.
; Both switches are IDEMPOTENT (xce with the flag already at the wanted value
; is a no-op, alt-src co65802.inl kStateXce), so nesting costs nothing.
; The frame loop therefore runs entirely in native mode, which is what makes a
; 16-bit block cost just rep/sep (6 cyc) instead of rep/sep + a clc/xce pair
; (10 cyc) -- measured: a lone 16-bit zp add is +8 cycles with the xce pair and
; a wash without it, while a LOOP body wins either way (8x 32-bit shift:
; 201 -> 167 cyc). M and X stay 8-bit, so every existing instruction behaves
; exactly as it did; the stack keeps its $01xx page (nothing in the engine
; reloads S -- there is no txs/tsx outside boot).
rb_resume = *
        org ROMBANK_BASE
.proc rom_out
        lda PORTB
        and #$FE
        sta PORTB                    ; ROM out first: while still in emulation
        clc                          ;   the NMI vector is $FFFA, also RAM and
        xce                          ;   also installed -- no unguarded window
        rts
.endp

.proc rom_in
        sec                          ; leave native BEFORE the ROM covers $FFEA
        xce
        lda PORTB
        ora #$01
        sta PORTB
        rts
.endp
    .if * > ROMBANK_END+1
        ert 'rom_out/rom_in outgrew ROMBANK_BASE..END (memory_map.inc)'
    .endif
        org rb_resume

;==============================================================
; (The per-call trampolines are GONE.) Since format v3 the map's SECTORS,
; SSECTORS and NODES live at $D800 -- under the ROM -- so the renderer needs RAM
; there for the whole frame, not for the duration of one call. main therefore
; banks the ROM out once, right before the game loop, and only exit_level banks
; it back in around the SIO loaders (SIOV is in the ROM). Every former t_* entry
; point is now a plain jsr, which also gives back the ~40 cycles per call the
; trampoline cost -- seg_yoff alone paid it ~140 times a frame.
;
; RULES for code that lives under the ROM are unchanged: it may call anything in
; $0000-$BFFF, and it must NOT call the OS (SIOV/CIOV).
;==============================================================
