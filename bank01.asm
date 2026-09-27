;--------------------------------------------------------------
; bank01.asm -- cold engine code that runs in Rapidus SRAM bank $01 (jsl/rtl; the
;   SRAM layer is fast bus, so it executes at full speed).
;--------------------------------------------------------------
b1_resume = *
        .segment B1
b1_code_start = *

.proc b1_oct_of
	rep #$20
	.LONGA ON
oo_w16                               ; (2026-09-23: 16-bit callers enter here)
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
	cmp #$0100                   ; (ax|ay) >= $100 <=> a hi bit set; A KEEPS the OR
	bcc ?small
?nrm	lsr swr_ax
	lsr swr_ay
	lsr @                        ; (ax|ay)>>1 = (ax>>1)|(ay>>1): no reload, no ora
	cmp #$0100                   ;   (2026-09-15, -6 a step)
	bcs ?nrm

?small  lda swr_ay                   ; swr_t = ay*2 + ay/4 (16-bit: max 573),
        lsr @                        ;   still in the 16-bit window (the .else
        lsr @                        ;   side did it as bytes + rol/inc): the
        sta swr_t                    ;   quarter, then the double on top of it
        lda swr_ay
        asl @                        ; (ay <= 255 after ?nrm: the asl's carry out
        adc swr_t                    ;   is 0, so no clc)
        cmp swr_ax                   ; t < ax (C=0, never equal) = "ax > t": the x
        bcc ?xaxis16                 ;   axis. The compare runs from t's side, so t
?notx   lda swr_ax                   ; swr_t = ax*2 + ax/4
        lsr @
        lsr @
        sta swr_t
        lda swr_ax
        asl @
        adc swr_t
        cmp swr_ay                   ; t < ay = "ay > t": the y axis
        bcc ?yaxis16
        sep #$20                     ; 2026-09-27: each 16-bit exit's sep sits right
        .LONGA OFF                   ;   above its own body (no sep / bra hop)
?diag   ldx #1                       ; a diagonal: pick the quadrant by signs
        lda swr_vx+1
        bpl ?dxp
        ldx #3
        lda swr_vy+1
        bpl ?oct
        ldx #5
	bra ?oct
?dxp    lda swr_vy+1
        bpl ?oct
        ldx #7
	bra ?oct
        .LONGA ON
?xaxis16 sep #$20
        .LONGA OFF
?xaxis  ldx #0                       ; within ~24 deg of the x axis
        lda swr_vx+1
        bpl ?oct
        ldx #4
	bra ?oct
        .LONGA ON
?yaxis16 sep #$20
        .LONGA OFF
?yaxis  ldx #2                       ; within ~24 deg of the y axis
        lda swr_vy+1
        bpl ?oct
        ldx #6
?oct    txa
        rtl
.endp

.proc b1_aif_alen
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

                                      ; 2026-09-22 idiom: A IS ai_aax (cmp/bcs/ldy/sty
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
.endp

; fps_tab is GONE (2026-08-31): the readout's mean was floor(sum/4), which
; overstated the rate by up to 12 % (sum 34 showed 6,25 for a true 5,88).
; The exact tables live in fps.asm now, indexed by the window SUM itself
; (200/sum needs no mean at all) -- and this stage got its 192 B back.

;--------------------------------------------------------------
; HUD_TAB -- the status bar's 29 lump records, SIX bytes each: u16 vram,
;   u8 w(bytes), u8 h, i8 left, i8 top.
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
        ert 'HUD_TAB outgrew its page -- b1_to_ext copies ONE (bsp_main.asm ?tab)'
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
;   (b=0..255) by running sum.
;--------------------------------------------------------------
.proc b1_build_frac
        ; --- |sin| + sign -> TSIN ---
                                      ; 2026-09-23: m_ma = 4*|sin| in the same window,
	ldy #$00                     ;   ?step4 inlined. |sin| <= 16384 (Q14), so the
	rep #$20                     ;   first asl carries 0 and the second one's carry
	.LONGA ON                    ;   IS bit 16 (sty/sep leave C alone)
	lda zp_sin
	bpl ?sp2
	iny
	eor #$ffff
	inc
?sp2	asl
	asl
	sta m_ma
	sty sin_sgn
	sep #$20
	.LONGA OFF
	lda #0
	rol
	sta m_ma+2

        lda #0                     ;   pay eight shifts for, folded into the
        sta.l FRAC_EXT+TSIN_LO
        sta.l FRAC_EXT+TSIN_MI
        sta.l FRAC_EXT+TSIN_HI
        ldx #1                     ; NO clc in the loop: the running sum tops
                                   ;   out at 4*16384*255 < 2^24, so the third ...
        tay                        ; A = 0: the sum's LOW byte rides in Y from here
?sl     tya                        ;   (tya/tay leave C alone; m_prod's low byte is
        adc m_ma                   ;   scratch nobody reads after the build) -- -2
        tay                        ;   a step, 510 steps a rotation frame
        sta.l FRAC_EXT+TSIN_LO,x
        lda.l FRAC_EXT+TSIN_MI-1,x
        adc m_ma+1                 ;   (the sum's upper bytes are the TABLE's
        sta.l FRAC_EXT+TSIN_MI,x    ;   previous entry: long,x has no page-cross
        lda.l FRAC_EXT+TSIN_HI-1,x  ;   cycle, alt-src AbsLongX -- no m_prod
        adc m_ma+2                 ;   copy to keep)
        sta.l FRAC_EXT+TSIN_HI,x
        inx
        bne ?sl
        ; --- |cos| + sign -> TCOS ---
                                      ; (as TSIN: ?step4 inlined in the window)
	ldy #$00
	rep #$20
	.LONGA ON
	lda zp_cos
	bpl ?cp2
	iny
	eor #$ffff
	inc
?cp2	asl
	asl
	sta m_ma
	sty cos_sgn
	sep #$20
	.LONGA OFF
	lda #0
	rol
	sta m_ma+2
        lda #0
        sta.l FRAC_EXT+TCOS_LO
        sta.l FRAC_EXT+TCOS_MI
        sta.l FRAC_EXT+TCOS_HI
        ldx #1                     ; (same no-clc argument as ?sl above)
        tay                        ; (Y carries the low byte, as ?sl above)
?cl     tya
        adc m_ma
        tay
        sta.l FRAC_EXT+TCOS_LO,x
        lda.l FRAC_EXT+TCOS_MI-1,x
        adc m_ma+1                 ;   (the sum's upper bytes are the TABLE's
        sta.l FRAC_EXT+TCOS_MI,x    ;   previous entry: long,x has no page-cross
        lda.l FRAC_EXT+TCOS_HI-1,x  ;   cycle, alt-src AbsLongX -- no m_prod
        adc m_ma+2                 ;   copy to keep)
        sta.l FRAC_EXT+TCOS_HI,x
        inx
        bne ?cl
        rtl
.endp

;--------------------------------------------------------------
; b1_amgate -- am_gate's whole body (its bank-0 block is 11 bytes and holds
;   exactly one jml here).
;   returns to main, the way am_gate's plain jmp always did. Clobbers A/X
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
