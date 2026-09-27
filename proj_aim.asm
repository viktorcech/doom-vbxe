;--------------------------------------------------------------
; Part of proj.asm (icl in place): the missile's z aim -- pj_zaim, pj_zaim2, pj_zstep, pj_aim3, pj_aim.
;--------------------------------------------------------------
;--------------------------------------------------------------
; pj_zaim / pj_zaim2 / pj_zstep -- THE VERTICAL AIM (2026-08-19, "ked vystrelim
;   raketu alebo plazmu na enemies, ktory je vyssie, naboj leti tam.. ale u nas
;   to tak nie je").
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_zaim
        stz pj_zf
        stz pj_dz                    ; a WALL shot keeps DOOM's slope 0: dz 0
        stz pj_dz+1                  ;   falls through the same maths and comes
        lda pj_vic                   ;   out as a level flight
        cmp #$FF                     ; $FF = a wall (the shared jmp is the only
        beq ?done                    ;   way out of this island anyway). cmp, not
                                     ;   bmi: thing indices reach 253 (pj_hit)
        jsr en_thing.en_th2w          ; 2026-09-22: returns 16-bit
        .LONGA ON                    ;   i.e. (its z - muzzle) + 28 -- the same
        ldy #4                       ;   number mod 2^16, without the m_a stash.
        lda (sp_ptr),y               ; +4/+5 = its z (pack_things: x,y,z,sid,fl)
        sec
        sbc pj_z
        clc
        adc #28                      ; the muzzle less half a monster: the middle
                                     ;   of a 56-unit sprite is the aim point
        ldy pj_sh                    ; ...brought down the same number of
        beq ?st                      ;   halvings pj_go's loop cost dx/dy, so all
?sh     cmp #$8000                   ;   three legs share one scale. Arithmetic:
        ror @                        ;   the sign has to survive -- and the value
        dey                          ;   stays in A the whole way, one store
        bne ?sh
?st     sta pj_dz
        sep #$20
        .LONGA OFF
?done
        ert *<>pj_zaim2             ;   next byte of this segment -- fall through
                                     ;   branch
.endp                                ;   branch
        .endseg

        org PJZ2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_zaim2                       ; dz (shrunk) -> the per-sub-step z leg
        ldx #0                       ; the sign FIRST: pj_leg tail-jumps into
        lda pj_dz+1                  ;   umul16, whose qsmul eats X and Y
        bpl ?p
        dex
?p      stx pj_sze
        ; BUG FIX 2026-09-15: dz is NOT a byte. pj_go's loop shrinks until dx ...
        rep #$20
        .LONGA ON
        lda pj_dz
        bpl ?ap
        eor #$FFFF
        inc @
?ap     sta m_a
        sep #$20
        .LONGA OFF
        stz m_b+1
        lda pj_f
        sta m_b
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
        rep #$20                     ;   sign is already in pj_sze)
        .LONGA ON
        lda m_prod+2
        bne ?big
        lda m_prod
        cmp #$4000
        bcc ?fit
?big    lda #$3FFF
?fit    asl @                        ; x2, as pj_leg
        ldy pj_sze
        bpl ?pos
        eor #$FFFF
        inc @
?pos    sta pj_sz
        sep #$20
        .LONGA OFF
        jmp pj_leaf
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_zstep                       ; ONE sub-step of the z leg (pj_frame)
        clc
        lda pj_zf
        adc pj_sz
        sta pj_zf
        lda pj_z
        adc pj_sz+1
        sta pj_z
        lda pj_z+1
        adc pj_sze
        sta pj_z+1
        rts
.endp
        .endseg
pj_dz   dta a(0)                     ; SHARED, not per-bolt: it is only alive
                                     ;   inside pj_zaim, at the launch
    .if * > PJZ2_END+1
        ert 'pj_zaim2/pj_zstep outgrew PJZ2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_aim3 -- BUG FIX 2026-09-15 ("ked je imp nado mnou na plosine a strelim
;   raketu, raketa neleti za nim hore"; plasma looked fine only because a
;   stream of bolts catches the monster on the crosshair now and then).
;   IN: A = damage, pj_hold set, the aim cell on the crosshair (en_gunshot /
;--------------------------------------------------------------
PJ_AIMOFF equ 8                      ; full size; 6 at the *3/4 sizes
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_aim3
        jsr en_shoot                 ; the facing angle
        ldx en_best
        bpl ?out
        lda #PJ_AIMOFF               ; the 5.625 deg offset at this view size
        ldx vw_q34
        beq ?q
        lda #PJ_AIMOFF*3/4
?q      ldx vw_sh
        beq ?sh0
?sh     lsr @
        dex
        bne ?sh
?sh0    sta pj_aoff
        lda #SCREEN_HALF             ; an += 1<<26: to the LEFT
        sec
        sbc pj_aoff
        jsr ?try
        bpl ?out
        lda #SCREEN_HALF             ; an -= 2<<26: the same to the RIGHT
        clc
        adc pj_aoff
        jsr ?try
?out    php                          ; (N = the verdict, X = en_best)
        lda #SCREEN_HALF             ; the aim cell back on the crosshair
        jsr ?cell
        plp
        rts
?try    jsr ?cell
        lda en_dmg                   ; en_shoot stored it on the first call
        jsr en_shoot
        ldx en_best
        rts
?cell   sta en_col                   ; A = the column -> en_col, en_cl/en_ch = +-1
        dec @
        sta en_cl
        inc @
        inc @
        sta en_ch
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_aim
        inc pj_hold
        jsr pj_aim3                  ; en_shoot + DOOM's two 5.625 deg retries
        dec pj_hold
        lda en_dmg                   ; the roll travels with the rocket
        sta pj_dmg
        ldx en_best
        bmi ?wall
        lda vs_th,x
        sta pj_vic
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record -> the flight target
        .LONGA ON
        lda (sp_ptr)
        sta en_bx
        ldy #2
        lda (sp_ptr),y
        sta en_by
        sep #$20
        .LONGA OFF
        rts
?wall   lda #$FF
        sta pj_vic                   ; nobody to hurt -- just the blast, and
        lda #SH_NROCK                ;   pj_hit centres it where the rocket
        jmp sh_trace                 ;   stopped
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a
pj_aoff dta 0                        ; pj_aim3's column offset for this shot
        .endseg
