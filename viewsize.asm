;--------------------------------------------------------------
; viewsize.asm -- '-' / '=' shrink and grow the 3D view (DOOM's screenblocks): the
;   projection scales with the window, so the FOV stays 90 degrees.
;--------------------------------------------------------------
vs_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; vw_apply -- vw_size -> the eight window bytes + a border repaint.
;   Called from init_level (boot AND every level, so the size survives an exit)
;   and from read_keys on '-' / '='.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vw_apply
        lda vw_size
        asl                          ; *8 = vw_tab record
        asl
        asl
                                      ; 2026-09-22 idiom: count DOWN (a plain 8-byte copy,
        adc #7                       ;   order-free): no cpx, and Y starts at the record's
        tay                          ;   last byte -- C = 0 from the asl (vw_size*8 < 128)
        ldx #7
?cp     lda vw_tab,y
        sta vw_x0,x
        dey
        dex
        bpl ?cp
        lda vw_sh                    ; K + vw_sh into the reciprocal shifts' adc #
        clc                          ;   (scale_z, screenx_signed): vw_sh changes
        adc #RECIP_SCALE_K           ;   only here
        sta.l B1CODE_BASE+scale_z.sz_k+1
        lda vw_sh
        clc
        adc #RECIP_SX_K
        sta.l B1CODE_BASE+screenx_signed.sx_k+1
                                      ; 2026-09-27: screenx_signed's view-size slot --
        lda vw_q34                   ;   the 3/4 view keeps `sta m_prod` (its own first
        beq ?sq0                     ;   instruction), the others get `bra sx_q0`
        lda #$85                     ; sta dp
        ldx #<m_prod
        bra ?sqp
?sq0    lda #$80                     ; bra
        ldx #screenx_signed.sx_q0-screenx_signed.sx_q34-2
?sqp    sta.l B1CODE_BASE+screenx_signed.sx_q34
        txa
        sta.l B1CODE_BASE+screenx_signed.sx_q34+1
    .if [screenx_signed.sx_q0-screenx_signed.sx_q34-2] > 127
        ert 'screenx_signed: sx_q0 out of the slot bra range'
    .endif
        ; Every column starts CLOSED and only the window is re-opened per frame
        ; (render_world), so the border columns are marked ONCE, here: nothing in
        ; the frame path ever writes solid_arr outside [vw_x0,vw_x1].
                                      ; 2026-09-23 BUG FIX: `ldx #159 / dex / bpl` ran ONCE
        ldx #SCREEN_WIDTH            ;   (159 = $9F has bit 7 set: after the dex N = 1),
        lda #1                       ;   so only column 159 was closed. X = 160..1 ->
?bd     sta solid_arr-1,x            ;   columns 159..0, dex/bne (6502-idioms: dex/bpl
        dex                          ;   only for n <= 128)
        bne ?bd
        lda #3                       ; repaint the border into ALL THREE buffers
        sta vw_dirty                 ;   (triple buffer, 2026-08-11)
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;  vw_frame lives in OVLCLR_BASE now -- see the block at the end of this file.

vwf_resume = *
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; ovl_frame -- erase the overlay band, but only when someone has to.
;--------------------------------------------------------------
;--------------------------------------------------------------
; vw_frame -- once per frame, off read_keys: paint the border after a resize.
;   Three frames = all three buffers. The 3D view is redrawn every frame anyway,
;   so only the ring around it needs this (clear_screen covers rows 0..167; the
;   status bar owns the rest).
;   OUT OF VIEWSZ (2026-09-10): that block was full to the byte and this now
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vw_frame
        lda vw_dirty
        beq ovl_frame                ; no resize pending -> the band may still
        dec vw_dirty                 ;   need it (fall through, next proc)
        lda #VIEW_BORDER
        jmp clear_screen             ; tail call (both in bank $01)
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ovl_frame
        lda vw_size
        beq ?ret                     ; FULL view: the render still erases them
        lda msg_t                    ;   free, so this costs two loads a frame
        ora fps_on
        beq ?stale                   ; nothing showing -> just drain the counter
        lda #3
        sta ovl_dirty                ; showing -> keep all three buffers due
?stale  lda ovl_dirty
        beq ?ret
        dec ovl_dirty
        stz bg_x0                    ; bg_blit's rectangle: rows 0..OVL_H-1
        stz bg_top
        lda #OVL_W
        sta bg_w
        lda #OVL_H-1
        sta bg_bot
                                      ; 2026-09-23 BUG FIX: the entry that stamps THIS frame's
        jmp bg_blit.bgb_ovl          ;   bank (ptc_frame has not run yet -- colmerge.asm)
?ret    rts                          ;   both rgb(0,0,0), and this saves the byte
.endp                                ;   a colour argument would cost
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
ovl_dirty dta 0                      ; buffers still owing the clear
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; vw_smaller / vw_bigger -- one step down / up the ladder ('-' / '=').
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vw_smaller
        lda vw_size
        cmp #VW_NSIZE-1
        bcs ?ret                     ; already the smallest
        inc vw_size
        jmp vw_apply                 ; (same bank, rts: a tail jump)
?ret    rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vw_bigger
        lda vw_size
        beq ?ret                     ; already full size
        dec vw_size
        jmp vw_apply                 ; (same bank, rts: a tail jump)
?ret    rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

vw_size dta 0                        ; the ONLY view-size state that has to survive
                                     ;   a level load; it lives here (in the XEX, so ...

; ---- the ladder: x0, x1, x1+1, y0, y1, ncol, sh, q34 (8 B per size) ---------
; x0 and ncol stay EVEN: render_world clears the window two columns a word.
; k = 1, 3/4, 1/2, 3/8, 1/4 of 160x168, always centred on (80, 84) -- DOOM puts
; the window in the middle of the non-status area too, which is what keeps the
; horizon (HHFP) and the projection centre (SCREEN_HALF) constant.
vw_tab
        dta   0,159,160,   0,167, 160, 0,0    ; 160x168  full
        dta  20,139,140,  21,146, 120, 0,1    ; 120x126  3/4
        dta  40,119,120,  42,125,  80, 1,0    ;  80x84   1/2
        dta  50,109,110,  53,115,  60, 1,1    ;  60x63   3/8
        dta  60, 99,100,  63,104,  40, 2,0    ;  40x42   1/4

        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; vw_q34x -- m_prod[0..1] *= 3/4, for the sizes that are not a power of two.
;--------------------------------------------------------------
        org VWQ34_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vw_q34x
        lda vw_q34
        beq ?ret
        rep #$20                     ; ---- 16-bit A: v - (v >> 2) = v * 3/4, all
        .LONGA ON                    ;   in the accumulator: the quarter is two
        lda m_prod                   ;   shifts, the subtract is ~q + 1 + v (no
        lsr @                        ;   vw_t round trip, no memory shifts)
        lsr @
        eor #$FFFF
        sec
        adc m_prod
        sta m_prod
        sep #$20
        .LONGA OFF
?ret    rts
.endp
        .endseg
    .if * > VWQ34_END+1
        ert 'vw_q34x outgrew VWQ34_BASE..END (memory_map.inc)'
    .endif

        org vs_resume
