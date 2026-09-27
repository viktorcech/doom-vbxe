;--------------------------------------------------------------
; use_ray.asm -- part of renderer.asm (icl in place): the geometry half of try_use
;   (P_UseLines / PTR_UseTraverse).
;--------------------------------------------------------------
; use_side -- sign helper for the crossing test: A = 1 if
;   cross(PT[Y] - PT[X], PT[USE_K] - PT[X]) > 0, i.e. point k is LEFT of the
;   directed line PT[X] -> PT[Y]. X/Y/USE_K are byte offsets into USE_PT
;--------------------------------------------------------------
us_resume = *
        org USESIDE_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_side
        rep #$20                     ; ---- 16-bit A: four word subtractions
        .LONGA ON                    ;   (X/Y are byte offsets into USE_PT)
usd_w16                              ; (2026-09-23: 16-bit callers enter here)
        sec                          ; cx_a = PTx[j] - PTx[i]
        lda USE_PT,y
        sbc USE_PT,x
        sta cx_a
        sec                          ; cx_c = PTy[j] - PTy[i]
        lda USE_PT+2,y
        sbc USE_PT+2,x
        sta cx_c
        ldy USE_K
        sec                          ; cx_b = PTy[k] - PTy[i]
        lda USE_PT+2,y
        sbc USE_PT+2,x
        sta cx_b
        sec                          ; cx_d = PTx[k] - PTx[i]
        lda USE_PT,y
        sbc USE_PT,x
        sta cx_d
                                      ; 2026-09-22: into cross_pos past its rep -- the
        jmp cross_pos.cp_w16         ;   sep here and that rep were an empty pair
        .LONGA OFF
.endp
        .endseg
    .if * > PJGO_BASE
        ert 'use_side overran its $5432 slot (pj_go at $5480; memory_map.inc)'
    .endif
        org us_resume                ; back to the $2000 engine-code segment


;--------------------------------------------------------------
; use_seg_hit -- zp_sptr -> seg. A = 1 if the USE ray (USE_PT_A..USE_PT_B) crosses
;   this seg. Both segments straddle each other's line -- the textbook 4-sign test,
;   which needs no intersection point (so no divide).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_seg_hit
        stz USE_K                    ; (8-bit, before the window: use_side's first K)
        rep #$20                     ; ---- 16-bit A: v1 -> USE_PT_P, v2 -> USE_PT_Q,
        .LONGA ON                    ;   each a word index and two word reads
                                      ; 2026-09-22: coll_vptr inlined (as coll_seg): the
        lda [zp_sptr]                ;   index is in A, *4 + MAP_VERTS (idx < 16384:
        asl @                        ;   the asl's shift out 0s, the adc rides on C=0)
        asl @
        adc #MAP_VERTS
        sta zp_ptr
        lda [zp_ptr]
        sta USE_PT_P
        ldy #2
        lda [zp_ptr],y
        sta USE_PT_P+2
        lda [zp_sptr],y              ; (Y = 2: v2)
        asl @
        asl @
        adc #MAP_VERTS
        sta zp_ptr
        lda [zp_ptr]
        sta USE_PT_Q
                                      ; 2026-09-22 (drac030 RELOAD): Y is still 2 (the .if 1 v2 read above)
        lda [zp_ptr],y
        sta USE_PT_Q+2
                                      ; 2026-09-23: into use_side past its rep (USE_K
        .LONGA OFF                   ;   is a byte: the 8-bit stz went to the top).
        ldx #8                       ;   Sides are 0/1, so side1 EOR side2 IS the
        ldy #12                      ;   answer: 0 (and Z) = same side = miss
        jsr use_side.usd_w16
        sta m_ma                     ; side(P->Q, A)
        lda #4
        sta USE_K
        ldx #8
        ldy #12
        jsr use_side
        eor m_ma
        beq ?out                     ; same side -> no crossing (A = 0)
        lda #8                       ; ... and do the seg's ENDS straddle the ray?
        sta USE_K
        ldx #0
        ldy #4
        jsr use_side
        sta m_ma
        lda #12
        sta USE_K
        ldx #0
        ldy #4
        jsr use_side
        eor m_ma
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; use_shut -- zp_sptr -> two-sided seg. A = 1 if its opening is <= 0, i.e.
;   p_maputl.c P_LineOpening: opentop = min(fceil, bceil),
;   openbottom = max(ffloor, bfloor), shut when opentop <= openbottom.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_shut
        ldy #SEG_FRONT               ; front sector -> coll_ax = floor, coll_ay = ceil
        lda [zp_sptr],y
        sta m_a
        stz m_a+1
        jsr coll_secheights
                                     ; 2026-09-22: coll_secheights returns 16-bit now
        .LONGA ON                    ;   (coll_secheights reuses coll_ax/ay)
        lda coll_ax
        sta coll_bx
        lda coll_ay
        sta coll_by
        ldy #SEG_BACK                ; back sector -> coll_ax/coll_ay
        lda [zp_sptr],y
        and #$FF
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_secheights.csh_w16 ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$21                     ; fceil - ffloor - 1 < 0 <=> fceil <= ffloor:
        .LONGA ON                    ;   the FRONT sector is collapsed (the .else
        ;clc                          ;   side says why this one lives here)
        lda coll_by
        sbc coll_bx
        bvc ?f3
        eor #$8000
?f3     bpl us_open 
        ;bra us_open                  ; the other three (16-bit on entry: us_open
                                     ;   starts with its own rep)
?shut   sep #$20
        .LONGA OFF
        lda #1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; us_open -- use_shut's tail. coll_ax/coll_ay = the BACK sector's floor/ceil,
;   coll_bx/coll_by = the FRONT sector's. A = 1 if the opening is <= 0.


;--------------------------------------------------------------
usop_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc us_open
        rep #$21                     ; ---- 16-bit A (idempotent: use_shut arrives
        .LONGA ON                    ;   in it). Three signed "<=" compares, each
        ;clc                          ;   one word subtract with the -1 riding on
        lda coll_ay                  ;   the clc; V fixes the sign
        sbc coll_ax                  ; bceil - bfloor - 1 < 0: the BACK sector is
        bvc ?f0                      ;   collapsed, i.e. a shut door (E1M4's
        eor #$8000                   ;   tag-1 doors, 26 lines in episode 1)
?f0     bmi ?shut
        clc                          ; fceil - bfloor - 1 < 0  <=>  fceil <= bfloor
        lda coll_by
        sbc coll_ax
        bvc ?f1
        eor #$8000
?f1     bmi ?shut
        clc                          ; bceil - ffloor - 1 < 0  <=>  bceil <= ffloor
        lda coll_ay
        sbc coll_bx
        bvc ?f2
        eor #$8000
?f2     bmi ?shut
        sep #$20
        .LONGA OFF
        lda #0
        rts
?shut   sep #$20
        .LONGA OFF
        lda #1
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org usop_resume
