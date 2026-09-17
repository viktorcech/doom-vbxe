;==============================================================
; bank01.asm -- COLD ENGINE CODE THAT RUNS IN RAPIDUS SRAM BANK $01.
;--------------------------------------------------------------
; WHY. Base RAM is full to the byte (base RAM is full).
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
; 2026-09-13 (DRAC_PLAN step 2): this is no longer a two-address block that
; b1_to_ext copies up. It is the start of the B1 SEGMENT (memory_map.inc):
; tools/split_b1.py stages it and b1_stage_copy puts it in bank $01 during the
; XEX load. The rules above still hold.
b1_resume = *
        .segment B1
b1_code_start = *

.proc b1_oct_of
 .if 1
	rep #$20
	.LONGA ON
        lda swr_vx                   ; swr_ax = |vx|
        bpl ?axp

	eor #$ffff
	inc

?axp	sta swr_ax

	lda swr_vy
	bpl ?ayp

	eor #$ffff
	inc

?ayp	sta swr_ay
	ora swr_ax
 .if 1
	cmp #$0100                   ; (ax|ay) >= $100 <=> a hi bit set; A KEEPS the OR
	bcc ?small
?nrm	lsr swr_ax
	lsr swr_ay
	lsr @                        ; (ax|ay)>>1 = (ax>>1)|(ay>>1): no reload, no ora
	cmp #$0100                   ;   (2026-09-15, -6 a step)
	bcs ?nrm
 .else
	and #$ff00
	beq ?small

?nrm	lsr swr_ax
	lsr swr_ay
	lda swr_ax
	ora swr_ay
	and #$ff00
	bne ?nrm
 .endif

?small  lda swr_ay                   ; swr_t = ay*2 + ay/4 (16-bit: max 573),
        lsr @                        ;   still in the 16-bit window (the .else
        lsr @                        ;   side did it as bytes + rol/inc): the
        sta swr_t                    ;   quarter, then the double on top of it
        lda swr_ay
        asl @                        ; (ay <= 255 after ?nrm: the asl's carry out
        adc swr_t                    ;   is 0, so no clc)
 .if 1
        cmp swr_ax                   ; t < ax (C=0, never equal) = "ax > t": the x
        bcc ?xaxis16                 ;   axis. The compare runs from t's side, so t
 .else                                ;   is never stored (2026-09-15, -10)
        sta swr_t
        lda swr_ax                   ; ax > ay*2.25 -> the x axis dominates (one
        cmp swr_t                    ;   word compare: a 9-bit t beats any byte
        beq ?notx                    ;   ax, which is what the hi-byte test said)
        bcs ?xaxis16
 .endif
?notx   lda swr_ax                   ; swr_t = ax*2 + ax/4
        lsr @
        lsr @
        sta swr_t
        lda swr_ax
        asl @
        adc swr_t
 .if 1
        cmp swr_ay                   ; t < ay = "ay > t": the y axis
        bcc ?yaxis16
 .else
        sta swr_t
        lda swr_ay
        cmp swr_t
        beq ?diag16
        bcs ?yaxis16
 .endif
?diag16 sep #$20
        .LONGA OFF
        bra ?diag
?xaxis16 sep #$20
        .LONGA OFF
        bra ?xaxis
?yaxis16 sep #$20
        .LONGA OFF
        bra ?yaxis
 .else
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
?small
	lda swr_ay                   ; swr_t = ay*2 + ay/4 (16-bit: max 573)
        lsr
        lsr
        sta swr_t
 .if 1
        stz swr_t+1
 .else
        lda #0
        sta swr_t+1
 .endif
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
 .if 1
        stz swr_t+1
 .else
        lda #0
        sta swr_t+1
 .endif
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

 .endif
?diag   ldx #1                       ; a diagonal: pick the quadrant by signs
        lda swr_vx+1
        bpl ?dxp
        ldx #3
        lda swr_vy+1
        bpl ?oct
        ldx #5
 .if 1
	bra ?oct
 .else
        bne ?oct                     ; always
 .endif
?dxp    lda swr_vy+1
        bpl ?oct
        ldx #7
 .if 1
	bra ?oct
 .else
        bne ?oct                     ; always
 .endif
?xaxis  ldx #0                       ; within ~24 deg of the x axis
        lda swr_vx+1
        bpl ?oct
        ldx #4
 .if 1
	bra ?oct
 .else
        bne ?oct                     ; always
 .endif
?yaxis  ldx #2                       ; within ~24 deg of the y axis
        lda swr_vy+1
        bpl ?oct
        ldx #6
?oct    txa
        rtl
.endp

.proc b1_aif_alen
 .if 1
	rep #$20
	.LONGA ON
        lda ai_alx
	bpl ?xok
	eor #$ffff
	inc
?xok	sta ai_aax

	lda ai_aly
	bpl ?yok
	eor #$ffff
	inc
?yok	sta ai_aay

	lda ai_aax
	cmp ai_aay
	bcs ?xbig

	ldy #$00
	sty ai_axmaj

	lda ai_aax
	lsr
	sta ai_ahalf

        clc
        lda ai_aay
        adc ai_ahalf
        sta ai_alen

	sep #$20
	.LONGA OFF
	rtl

?xbig	.LONGA ON
	ldy #$01
	sty ai_axmaj

	lda ai_aay
	lsr
	sta ai_ahalf

        clc
        lda ai_aax
        adc ai_ahalf
        sta ai_alen
	sep #$20
	.LONGA OFF
	rtl
 .else
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
 .endif
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
;   2026-09-13: DATA, so it is out of the code segment -- a one-page
;   two-address block that b1_to_ext copies into the data bank at HUDTAB_OFF.
b1_code_end = *
        .endseg
hudtab_resume = *
        org HUDTAB_OFF, B1CODE_STAGE
HUD_TAB
        ins 'build/assets/hud/hud.tab'
HUDTAB_BYTES = * - HUD_TAB
    .if HUDTAB_BYTES > $100
        ert 'HUD_TAB outgrew its page -- b1_to_ext copies TWO and HU_TAB owns'
        ert '  the second one (bsp_main.asm ?tab, memory_map.inc HUTAB_OFF)'
    .endif
;--------------------------------------------------------------
; HU_TAB -- the HU STRIP DIRECTORY, in the page behind HUD_TAB and copied up by
;   the same b1_to_ext row (2026-09-16). Three arrays of HU_MAXSTRIPS bytes --
;   offset lo, offset hi, width -- so strip_blit reads all three with one X and
;   three `lda.l`, and memory_map.inc can name the bases without a strip count.
;   The strips used to be TITLE_STRIDE apart and all padded to the widest line,
;   which is why none of this existed; that padding was 25,699 B and it is the
;   SR status bar now (pack_menu.py _hu_strips, xdl.asm).
;   The offset is 16-bit and TITLE_VRAM is 64 KB-aligned, so the strip's VRAM
;   address is the bank byte and these two -- nothing to add.
;--------------------------------------------------------------
        org HUTAB_OFF, B1CODE_STAGE+$100
HU_TAB
        ins 'build/assets/menu/hu.tab'
HUTAB_BYTES = * - HU_TAB
    .if HUTAB_BYTES > $100
        ert 'HU_TAB outgrew the page behind HUD_TAB (memory_map.inc HUTAB_OFF)'
    .endif
    .if HUTAB_BYTES != 3*HU_MAXSTRIPS
        ert 'HU_TAB is not 3 x HU_MAXSTRIPS -- pack_menu.py and memory_map.inc'
        ert '  disagree about the per-array stride'
    .endif
        org hudtab_resume

;==============================================================
; B1CODE2 -- the second block (2026-08-31). B1CODE has 14 B left, so this one
; stages in the raw-XEX hole behind SGOVL's parking (B1CODE2_STAGE, memory_map)
; and b1_to_ext copies it up in the same breath. Same rules as above.
;==============================================================
        .segment B1                  ; (was org B1CODE2_OFF, B1CODE2_STAGE)
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
 .if 1
	ldy #$00
	rep #$20
	.LONGA ON
	lda zp_sin
	bpl ?sp
	iny
	eor #$ffff
	inc
?sp	sta m_a
	sty sin_sgn
	sep #$20
	.LONGA OFF
 .else
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
?sp
 .endif
	jsr ?step4                 ; m_ma = |sin| << 2 -- the >>14 FMUL used to

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
 .if 1
        tay                        ; A = 0: the sum's LOW byte rides in Y from here
?sl     tya                        ;   (tya/tay leave C alone; m_prod's low byte is
        adc m_ma                   ;   scratch nobody reads after the build) -- -2
        tay                        ;   a step, 510 steps a rotation frame
        sta.l FRAC_EXT+TSIN_LO,x
 .else
?sl     lda m_prod                 ; acc += 4*|sin|; store T[x]
        adc m_ma
        sta m_prod
        sta.l FRAC_EXT+TSIN_LO,x
 .endif
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
 .if 1
	ldy #$00
	rep #$20
	.LONGA ON
	lda zp_cos
	bpl ?cp
	iny
	eor #$ffff
	inc
?cp	sta m_a
	sty cos_sgn
	sep #$20
	.LONGA OFF
 .else
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
?cp
 .endif
	jsr ?step4
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
        sta.l FRAC_EXT+TCOS_LO
        sta.l FRAC_EXT+TCOS_MI
        sta.l FRAC_EXT+TCOS_HI
        ldx #1                     ; (same no-clc argument as ?sl above)
 .if 1
        tay                        ; (Y carries the low byte, as ?sl above)
?cl     tya
        adc m_ma
        tay
        sta.l FRAC_EXT+TCOS_LO,x
 .else
?cl     lda m_prod
        adc m_ma
        sta m_prod
        sta.l FRAC_EXT+TCOS_LO,x
 .endif
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
?p      lda.l EXT_BASE+AMOVL_EXT,x
        sta MENU_RUN,x
        inx
        bne ?p
        jsl menu_run_w0              ; (DRAC_PLAN 2b) the overlay returns with
        rts                          ;   rts: enter it through a bank-0 jsr/rtl
                                     ;   wrapper, or it returns into bank 0
?world  jml B1CODE_BASE+render_world   ; (bank $01 since DRAC_PLAN 2b)
.endp

; (b1_sq2_restore is GONE, 2026-08-31 pm: the SQ2 tables live at
;  SQ2L_UROM/SQ2H_UROM, past every stream the engine has -- nothing to
;  repaint. The $C900 scheme it served lasted one morning; see qs_mirror.inc.)

b1_code2_end = *
        .endseg                      ; (B1SEG_LEN is MADS's own bound -- no ert)
