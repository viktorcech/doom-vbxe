;--------------------------------------------------------------
; underrom.asm -- the 16 KB of RAM under the OS ROM ($C000-$FFFF): ROM in/out,
;   the RAM vectors, and SIOV with the ROM banked in.
;--------------------------------------------------------------
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
                                     ;   pm): an interrupt does NOT resize the ...
        pha
        sta NMIRES                   ; $D40F: any write clears the NMI latch
        inc RTCLOK3
        lda XDLA_PEND                ; deferred triple-buffer flip (2026-08-11):
        beq ?done                    ;   publish the XDL INSIDE the blank -- the
        sta VBXE_XDLA1               ;   real FX core switches mid-frame if the
        stz XDLA_PEND                ;   store lands mid-picture (the flicker),
                                     ;   Altirra latches at frame start; this is
        jsr kb_scan                  ; the cheat matcher's press edge, at 50 Hz
?done                                ;   correct on both. $00 = nothing pending.
        pla
        rti
.endp

;--------------------------------------------------------------
; urom_init -- install rom_nmi / snd_irq into the RAM vectors. Call ONCE at boot,
;   after snd_init and before the first bank-out. Clobbers A.
;--------------------------------------------------------------
.proc urom_init
        sei
        stz NMIEN                    ; VBI off for the same reason boot.asm turns
                                     ;   it off around its stores: THIS bank-out ...
                                      ; 2026-09-21: trb, -3 B (A is reloaded below).
        lda #$01                     ;   One read + one write of PORTB as before;
        trb PORTB                    ;   ROM out: $FFFA-$FFFF is RAM now. IF THE
                                     ;   BOOT EVER HANGS ON IRON, FLIP THIS FIRST.
        lda #<rom_nmi
        sta $FFFA
        sta $FFEA                    ; ... and the NATIVE-mode NMI vector
        lda #>rom_nmi                ;   (2026-08-11 pm): a 65816 in native mode
        sta $FFFB                    ;   fetches NMI from $FFEA and IRQ from
        sta $FFEB                    ;   $FFEE, NOT $FFFA/$FFFE (alt-src
                                     ;   co65802.inl kState816_NatNMIVecToPC).
        lda #<snd_irq                ; the Timer-1 digi IRQ (sound.asm)
        sta $FFFE
        sta $FFEE                    ; ... and its native-mode vector
        lda #>snd_irq
        sta $FFFF
        sta $FFEF
                                      ; DRAC_PLAN 4a (drac.txt: all code -> bank $01):
        stz POKMSK_R                 ;   the ROM STAYS OUT from here on, so every
        stz IRQEN_R                  ;   interrupt is ours -- no OS keyboard/BREAK
                                     ;   IRQ (snd_irq acks foreign ones with
                                     ;   IRQEN=POKMSK, which must be 0 for that)
        clc
        xce                          ; native for good: only siov_r (SIOV) and
                                     ;   quit_boot (COLDSV) step back into the ROM
        lda #$40
        sta NMIEN                    ; rom_nmi: RTCLOK3 (ZFRONT/FRM_PAR/XDLA_PEND
        cli                          ;   were zeroed in setup_chains before this)
        rts
.endp

;--------------------------------------------------------------
; siov_r -- DRAC_PLAN 4a: SIOV from the ROM-out, native world. rom_in no longer
;   banks the ROM in; this is the one place it comes in, for exactly one SIOV
;   call: emulation mode (PBR is 0 -- this is bank-0 code, so the interrupts
;   SIOV waits on come back to it), OS VBI + IRQs on as SIOV expects, then ROM
;--------------------------------------------------------------
        .segment D0
.proc siov_r
        php                          ; the caller's I flag
        sei
        stz NMIEN                    ; rom_nmi must not meet the ROM's $FFEA
        sec
        xce                          ; emulation: the OS runs as a 6502
                                      ; 2026-09-21: tsb/trb, -3 B each ($0C/$1C are
        lda #$01                     ;   65C02 opcodes: legal in emulation mode;
        tsb PORTB                    ;   A is reloaded right after both). ROM in
        lda #$40
        sta NMIEN                    ; the OS VBI (SIO's timeout counters)
        cli
        jsr SIOV
        sei
        stz NMIEN
        lda #$01
        trb PORTB                    ; ROM out: $FFEA/$FFEE are RAM again
        clc
        xce                          ; native
        lda #$40
        sta NMIEN                    ; rom_nmi again
        plp
        rts
.endp
        .endseg

;--------------------------------------------------------------
; rom_out / rom_in -- the banking pair. PORTB is read-modify-written so the BASIC
;   (bit 1) and self-test (bit 7) bits keep whatever the machine booted with.
;   Clobbers A + flags; that is why the trampolines save them around rom_in.
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc rom_out
                                      ; DRAC_PLAN 4a: native since urom_init and the
        lda PORTB                    ;   ROM already out -- kept as the idempotent
        and #$FE                     ;   bank-out the callers expect
        sta PORTB
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc rom_in
                                      ; DRAC_PLAN 4a: the ROM stays out -- the only
        rts                          ;   ROM routine the loaders need is SIOV, and
                                     ;   siov_r banks it in around that one call
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org rb_resume

;==============================================================
; (The per-call trampolines are GONE.) Since format v3 the map's SECTORS,
; SSECTORS and NODES live at $D800 -- under the ROM -- so the renderer needs RAM
; there for the whole frame, not for the duration of one call. main therefore
; banks the ROM out once, right before the game loop, and only exit_level banks
;==============================================================
