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

; fps_tab is GONE (2026-08-31): the readout's mean was floor(sum/4), which
; overstated the rate by up to 12 % (sum 34 showed 6,25 for a true 5,88).
; The exact tables live in fps.asm now, indexed by the window SUM itself
; (200/sum needs no mean at all) -- and this stage got its 192 B back.

;--------------------------------------------------------------
; HUD_TAB -- the status bar's 29 lump records, SIX bytes each: u16 vram,
;   u8 w(bytes), u8 h, i8 left, i8 top. The u24's high byte is HUD_TAB_HI
;   (hud_syms.inc): every lump is in the same VBXE bank, so storing it 29 times
;   was 29 wasted bytes -- and 29 x 7 = 203 B does not fit what is left of this
;   staged block, 29 x 6 = 174 B does. hud_entry puts the byte back.
;   It was $BE60 in base RAM until 2026-08-30 and was the biggest cold block
;   left down there: nothing reads it per frame, only a HUD repaint does.
;--------------------------------------------------------------
HUD_TAB
        ins 'build/assets/hud/hud.tab'

b1_code_end = *
B1CODE_BYTES = b1_code_end - b1_code_start
    .if B1CODE_BYTES > B1CODE_MAX
        ert 'bank01.asm outgrew B1CODE_MAX -- b1_to_ext copies that many bytes'
    .endif

;==============================================================
; B1CODE2 -- the second block (2026-08-31). B1CODE has 14 B left, so this one
; stages in the raw-XEX hole behind SGOVL's parking (B1CODE2_STAGE, memory_map)
; and b1_to_ext copies it up in the same breath. Same rules as above.
;==============================================================
        org B1CODE2_OFF, B1CODE2_STAGE
b1_code2_start = *

;--------------------------------------------------------------
; b1_build_frac -- build_frac_tables' body: TSIN/TCOS = 4*|sin|*b, 4*|cos|*b
;   (b=0..255) by running sum. The SIX table pages live in THIS bank
;   (FRAC_EXT+TSIN_LO.., memory_map.inc), so the 1,536 stores of a rotation
;   frame are full-speed `sta.l` instead of win2 x11.2 -- which is the whole
;   reason the builder moved here. zp reads/writes (zp_sin, m_a, m_ma, m_prod)
;   are direct page = bank 0 from any bank; sin_sgn/cos_sgn are plain bank-0
;   stores (DBR stays 0, the block's rule). m_neg is INLINED twice: a `jsr`
;   from here would target this bank, not math.asm.
;--------------------------------------------------------------
.proc b1_build_frac
        ; --- |sin| + sign -> TSIN ---
        lda #0
        sta sin_sgn
        lda zp_sin
        sta m_a
        lda zp_sin+1
        sta m_a+1
        bpl ?sp
        inc sin_sgn
        sec                        ; m_a = -m_a (m_neg, inlined)
        lda #0
        sbc m_a
        sta m_a
        lda #0
        sbc m_a+1
        sta m_a+1
?sp     jsr ?step4                 ; m_ma = |sin| << 2 -- the >>14 FMUL used to
        lda #0                     ;   pay eight shifts for, folded into the
        sta m_prod                 ;   table once per rotation frame instead
        sta m_prod+1
        sta m_prod+2
        sta.l FRAC_EXT+TSIN_LO
        sta.l FRAC_EXT+TSIN_MI
        sta.l FRAC_EXT+TSIN_HI
        ldx #1                     ; NO clc in the loop: the running sum tops
                                   ;   out at 4*16384*255 < 2^24, so the third
                                   ;   adc never carries out; and ?step4's last
                                   ;   rol shifts a guaranteed-0 bit (m_ma+2
                                   ;   <= 1 before it), so C is 0 on entry too
?sl     lda m_prod                 ; acc += 4*|sin|; store T[x]
        adc m_ma
        sta m_prod
        sta.l FRAC_EXT+TSIN_LO,x
        lda m_prod+1
        adc m_ma+1
        sta m_prod+1
        sta.l FRAC_EXT+TSIN_MI,x
        lda m_prod+2
        adc m_ma+2
        sta m_prod+2
        sta.l FRAC_EXT+TSIN_HI,x
        inx
        bne ?sl
        ; --- |cos| + sign -> TCOS ---
        lda #0
        sta cos_sgn
        lda zp_cos
        sta m_a
        lda zp_cos+1
        sta m_a+1
        bpl ?cp
        inc cos_sgn
        sec                        ; m_a = -m_a (m_neg, inlined)
        lda #0
        sbc m_a
        sta m_a
        lda #0
        sbc m_a+1
        sta m_a+1
?cp     jsr ?step4
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
        sta.l FRAC_EXT+TCOS_LO
        sta.l FRAC_EXT+TCOS_MI
        sta.l FRAC_EXT+TCOS_HI
        ldx #1                     ; (same no-clc argument as ?sl above)
?cl     lda m_prod
        adc m_ma
        sta m_prod
        sta.l FRAC_EXT+TCOS_LO,x
        lda m_prod+1
        adc m_ma+1
        sta m_prod+1
        sta.l FRAC_EXT+TCOS_MI,x
        lda m_prod+2
        adc m_ma+2
        sta m_prod+2
        sta.l FRAC_EXT+TCOS_HI,x
        inx
        bne ?cl
        rtl
?step4  lda m_a                    ; m_ma(24b) = m_a << 2. |sin| reaches 16384
        asl                        ;   (Q14 1.0), so 4*|sin| needs 17 bits and
        sta m_ma                   ;   the running sum needs a 3-byte step.
        lda m_a+1
        rol
        sta m_ma+1
        lda #0
        rol
        sta m_ma+2
        asl m_ma
        rol m_ma+1
        rol m_ma+2
        rts                        ; in-bank helper: jsr/rts, not rtl
.endp

;--------------------------------------------------------------
; b1_sq2_restore -- repaint SQ2L_HOME/SQ2H_HOME (under-ROM RAM) from the
;   masters this bank holds at SQ2L_EXT/SQ2H_EXT. Called by init_level after
;   EVERY level load: load_things streams the THINGS blob straight over the
;   homes. The ROM is already banked out there, so the plain abs,x stores land
;   in RAM (and DBR is 0, so they land in bank 0). Clobbers A/X.
;--------------------------------------------------------------
;--------------------------------------------------------------
; b1_amgate -- am_gate's whole body (its bank-0 block is 11 bytes and holds
;   exactly one jml here). Map up: copy page 1 of the overlay (AMOVL_EXT,
;   this bank) down to MENU_RUN and jml into it -- the page's own head
;   (am_head) long-reads pages 2-5, exactly as it read them from the MEMW
;   window when the overlay lived in VRAM. Map down: jml render_world.
;   jml in, jml out: no stack, so the overlay's / render_world's rts still
;   returns to main, the way am_gate's plain jmp always did. Clobbers A/X
;   on the map path only.
;--------------------------------------------------------------
.proc b1_amgate
        lda am_on                    ; abs = bank 0 (DBR stays 0, block rules)
        beq ?world
        ldx #0
?p      lda.l B1CODE_BASE+AMOVL_EXT,x
        sta MENU_RUN,x
        inx
        bne ?p
        jml MENU_RUN
?world  jml render_world
.endp

.proc b1_sq2_restore
        ldx #0
?p      lda.l B1CODE_BASE+SQ2L_EXT,x
        sta SQ2L_HOME,x
        lda.l B1CODE_BASE+SQ2L_EXT+$100,x
        sta SQ2L_HOME+$100,x
        lda.l B1CODE_BASE+SQ2H_EXT,x
        sta SQ2H_HOME,x
        lda.l B1CODE_BASE+SQ2H_EXT+$100,x
        sta SQ2H_HOME+$100,x
        inx
        bne ?p
        rtl
.endp

b1_code2_end = *
B1CODE2_BYTES = b1_code2_end - b1_code2_start
    .if B1CODE2_BYTES > B1CODE2_MAX
        ert 'bank01.asm B1CODE2 outgrew B1CODE2_MAX (memory_map.inc)'
    .endif
        org b1_resume
