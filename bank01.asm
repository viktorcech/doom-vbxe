;==============================================================
; bank01.asm -- COLD ENGINE CODE THAT RUNS IN RAPIDUS SRAM BANK $01.
;--------------------------------------------------------------
; WHY. Base RAM is full to the byte (tools/ram_map.py: "FREE RAM FOR NEW CODE:
; NONE"), and the Rapidus SRAM banks are 448 KB of which bank $01 still has
; ~26 KB free above SNDX_EXT (tools/bank_map.py --check). The 65816 EXECUTES
; from there at full speed -- the opcode fetch is ExtReadByteAccel(mPC, mK)
; through the program bank register, and the SRAM layer is FastBus, so no
; slow-cycle is ever signalled (alt-src: h/cpumachine.inl:44/72, cpumemory.h:87,
; rapidus.cpp:122-125, memorymanager.cpp:663). ANTIC never reads a Rapidus bank,
; so there is no DMA contention either.
;
; HOW IT GETS THERE. Two-address `org`: the code is ASSEMBLED at its bank
; offset (B1CODE_OFF, so every internal branch and jsr resolves inside the bank)
; and PARKED in the XEX at B1CODE_STAGE -- $C000, the THINGS slot, which is
; empty in the shipped XEX (the menu/savegame overlays that park there are
; lifted out by tools/split_menu_ovl.py) and which nothing writes until the
; first load_things. b1_to_ext (bsp_main.asm) copies it up at boot, in the same
; breath as recip_to_ext/snd_to_ext, and the slot goes back to being the things
; slot. Exactly the RECIP_STAGE trick with 4 KB of room instead of 256 B.
;
; RULES for anything moved in here:
;   * it is entered with jsl and must end in RTL, never RTS. The old address
;     keeps a 5-byte `jsl ... / rts` thunk, so no CALL SITE has to change --
;     which matters, because the $2000 frame-loop segment has no spare byte.
;   * absolute data accesses are fine: jsl does not touch the DATA bank, so
;     DBR stays 0 and `lda lt_n` still reads base RAM.
;   * it must NOT be reached by a bank-0 `jmp` (a tail call would return with
;     RTL against a JSR's two-byte frame) and it must not be an interrupt
;     handler -- the vectors are 16-bit and live in bank 0.
;==============================================================
b1_resume = *
        org B1CODE_OFF, B1CODE_STAGE
b1_code_start = *

.proc b1_oct_of
        lda swr_vx                   ; swr_ax = |vx|
        sta swr_ax
        lda swr_vx+1
        sta swr_ax+1
        bpl ?axp
        sec
        lda #0
        sbc swr_ax
        sta swr_ax
        lda #0
        sbc swr_ax+1
        sta swr_ax+1
?axp    lda swr_vy                   ; swr_ay = |vy|
        sta swr_ay
        lda swr_vy+1
        sta swr_ay+1
        bpl ?ayp
        sec
        lda #0
        sbc swr_ay
        sta swr_ay
        lda #0
        sbc swr_ay+1
        sta swr_ay+1
?ayp    lda swr_ax+1                 ; shift both right until both fit a byte:
        ora swr_ay+1                 ;   the octant only needs the RATIO
        beq ?small
?nrm    lsr swr_ax+1
        ror swr_ax
        lsr swr_ay+1
        ror swr_ay
        lda swr_ax+1
        ora swr_ay+1
        bne ?nrm
?small  lda swr_ay                   ; swr_t = ay*2 + ay/4 (16-bit: max 573)
        lsr
        lsr
        sta swr_t
        lda #0
        sta swr_t+1
        lda swr_ay
        asl
        rol swr_t+1
        clc
        adc swr_t
        sta swr_t
        bcc ?t1
        inc swr_t+1
?t1     lda swr_t+1                  ; ax > ay*2.25 -> the x axis dominates
        bne ?notx                    ;   (hi byte set: ax (a byte) cannot beat it)
        lda swr_ax
        cmp swr_t
        beq ?notx
        bcs ?xaxis
?notx   lda swr_ax                   ; swr_t = ax*2 + ax/4
        lsr
        lsr
        sta swr_t
        lda #0
        sta swr_t+1
        lda swr_ax
        asl
        rol swr_t+1
        clc
        adc swr_t
        sta swr_t
        bcc ?t2
        inc swr_t+1
?t2     lda swr_t+1
        bne ?diag
        lda swr_ay
        cmp swr_t
        beq ?diag
        bcs ?yaxis
?diag   ldx #1                       ; a diagonal: pick the quadrant by signs
        lda swr_vx+1
        bpl ?dxp
        ldx #3
        lda swr_vy+1
        bpl ?oct
        ldx #5
        bne ?oct                     ; always
?dxp    lda swr_vy+1
        bpl ?oct
        ldx #7
        bne ?oct                     ; always
?xaxis  ldx #0                       ; within ~24 deg of the x axis
        lda swr_vx+1
        bpl ?oct
        ldx #4
        bne ?oct                     ; always
?yaxis  ldx #2                       ; within ~24 deg of the y axis
        lda swr_vy+1
        bpl ?oct
        ldx #6
?oct    txa
        rtl
.endp

.proc b1_aif_alen
        lda ai_alx
        sta ai_aax
        lda ai_alx+1
        sta ai_aax+1
        bpl ?xok
        sec
        lda #0
        sbc ai_aax
        sta ai_aax
        lda #0
        sbc ai_aax+1
        sta ai_aax+1
?xok    lda ai_aly
        sta ai_aay
        lda ai_aly+1
        sta ai_aay+1
        bpl ?yok
        sec
        lda #0
        sbc ai_aay
        sta ai_aay
        lda #0
        sbc ai_aay+1
        sta ai_aay+1
?yok    lda #1
        sta ai_axmaj
        sec
        lda ai_aax
        sbc ai_aay
        lda ai_aax+1
        sbc ai_aay+1
        bcs ?xbig
        lda #0
        sta ai_axmaj
        lda ai_aax+1                 ; y is bigger: len = |dy| + |dx|/2
        lsr                          ; the half is 16-BIT here, unlike ai_pdist's
        sta ai_ahalf+1               ;   copy of this -- that one drops the high
        lda ai_aax                   ;   byte of it, which it can afford because
        ror                          ;   everything it feeds is clamped to 200.
        sta ai_ahalf                 ;   |d| is not: it scales the whole line test
        clc
        lda ai_aay
        adc ai_ahalf
        sta ai_alen
        lda ai_aay+1
        adc ai_ahalf+1
        sta ai_alen+1
        rtl
?xbig   lda ai_aay+1                 ; x is bigger: len = |dx| + |dy|/2
        lsr
        sta ai_ahalf+1
        lda ai_aay
        ror
        sta ai_ahalf
        clc
        lda ai_aax
        adc ai_ahalf
        sta ai_alen
        lda ai_aax+1
        adc ai_ahalf+1
        sta ai_alen+1
        rtl
.endp

;--------------------------------------------------------------
; fps_tab -- 5000/n as three DECIMAL DIGITS, for n = 1..64 VBLANKs per frame.
;   Row n-1 is {integer, tenths, hundredths}: n=8 -> 6,2,5 because a frame that
;   takes 8 VBLANKs is 50/8 = 6.25 fps EXACTLY. That exactness is the whole
;   point of the readout -- doors.asm's frame_dt already measures dt_vbl, and
;   the old counter threw it away by counting whole frames in a one-second
;   window, which can only ever yield an integer.
;   64 is DOOR_DTMAX, frame_dt's own clamp, so no frame can index past the end.
;   MADS builds it: nothing computes a reciprocal at runtime, and nothing of
;   base RAM is spent -- this bank has ~26 KB free and base RAM has 273 B.
;--------------------------------------------------------------
fps_tab
        .rept 64,#
        dta [5000/(#+1)]/100, [[5000/(#+1)]/10]%10, [5000/(#+1)]%10
        .endr
FPS_TAB_EXT = $010000 + fps_tab      ; what the readout's `lda.l` wants

b1_code_end = *
B1CODE_BYTES = b1_code_end - b1_code_start
    .if B1CODE_BYTES > B1CODE_MAX
        ert 'bank01.asm outgrew B1CODE_MAX -- b1_to_ext copies that many bytes'
    .endif
        org b1_resume
