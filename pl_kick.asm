;--------------------------------------------------------------
; pl_kick.asm -- P_DamageMobj's kick for the PLAYER: momentum added on a hit and
;   spent under FRICTION a frame at a time.
;--------------------------------------------------------------
        org PLKDAT_BASE
pl_kd   dta 0                        ; units of shove still to spend
pl_ko   dta 0                        ; ...along this octant (oct_of's eight)
    .if * > PLKDAT_END+1
        ert 'pl_kd/pl_ko outgrew PLKDAT_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_kick -- move_player's ?slide: what is left of a shove joins mv_dx/mv_dy.
;==============================================================
        org PLKICK1_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_kick
        lda pl_kd
        beq ?out
        lsr                          ; an eighth of what is left, the taper
        lsr                          ;   en_slide spends a corpse's slide with
        lsr
        beq ?stop                    ; under a unit a frame -> STOPSPEED
        sta thr_d
        stz thr_d+1
        bra pl_kick2
?stop   stz pl_kd
?out    rts
.endp
        .endseg
    .if * > PLKICK1_END+1
        ert 'pl_kick piece 1 outgrew PLKICK1_BASE..END (memory_map.inc)'
    .endif

        org PLKICK2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_kick2
        sec                          ; ...and take it off the remainder
        lda pl_kd
        sbc thr_d
        sta pl_kd
        ldx pl_ko
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_kick3             ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLKICK2_END+1
        ert 'pl_kick piece 2 outgrew PLKICK2_BASE..END (memory_map.inc)'
    .endif

        org PLKICK3_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_kick3                       ; the octant -> a signed 16-bit component
        ldy #0                       ;   per axis: en_thrust's own decomposition
        lda thr_sx,x                 ;   (1 = all of it, 2 = three quarters on
        jsr thr_comp                 ;   the diagonals, bit7 = the other way)
        ldy #ai_sy-ai_sx             ; (ai_sdir sits between them -- the same
        lda thr_sy,x                 ;  guard en_thrust carries applies here)
        jsr thr_comp
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_kick4             ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLKICK3_END+1
        ert 'pl_kick piece 3 outgrew PLKICK3_BASE..END (memory_map.inc)'
    .endif

        org PLKICK4_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_kick4                       ; mv_dx += the X component. The shove joins
        rep #$21                     ; mv_dx += the X component, one word add
        .LONGA ON                    ;   (drac030 idiom)
        lda mv_dx
        adc ai_sx
        sta mv_dx
                                      ; 2026-09-23: STAYS 16-bit into pl_kick5 (its only way
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_kick5             ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLKICK4_END+1
        ert 'pl_kick piece 4 outgrew PLKICK4_BASE..END (memory_map.inc)'
    .endif

        org PLKICK5_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_kick5
                                      ; 2026-09-23: entered 16-bit from pl_kick4
        .LONGA ON
        clc                          ; mv_dy += the Y component, one word add
        lda mv_dy
        adc ai_sy
        sta mv_dy
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg
    .if * > PLKICK5_END+1
        ert 'pl_kick piece 5 outgrew PLKICK5_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_idle -- move_player's ?dead jumps HERE instead of straight to ?nomove.
;==============================================================
        org PLIDLE1_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_idle
        lda pl_dead                  ; a corpse is still a corpse: P_DeathThink
        bne ?no                      ;   runs instead of P_MovePlayer
        lda pl_kd
        bne pl_idle2 
        ;bra pl_idle2
?no     jmp mp_pkhere                ; mp_nomove is only `jmp mp_pkhere`: go there
.endp
        .endseg
    .if * > PLIDLE1_END+1
        ert 'pl_idle piece 1 outgrew PLIDLE1_BASE..END (memory_map.inc)'
    .endif

        org PLIDLE2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_idle2
        stz mv_dx                    ; no walk this frame -- pl_kick puts the
        stz mv_dx+1                  ;   shove on top of a zero step
        stz mv_dy
        stz mv_dy+1
        jsr skipx_ref                ; cur_floor, the step-up reference ?go
                                     ;   would have set (doors.asm)
        jmp move_player.mp_slide
.endp
        .endseg
    .if * > PLIDLE2_END+1
        ert 'pl_idle piece 2 outgrew PLIDLE2_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_thrust -- ball.asm ?hit calls this instead of `lda bl_dmg / jsr
;   en_plr_hurt` and it makes that call itself at the end: p_inter.c:806 kicks
;   BEFORE the health test, so a killing shot still shoves the corpse.
;==============================================================
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thrust
        lda bl_dmg
        asl
        sta pl_kd
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_thr2              ;   next byte of this segment -- fall through
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

        org PLTHR2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thr2                        ; swr_vx = zp_px - bl_x: AWAY from the ball,
                                      ; 2026-09-23 (65816-windows): both deltas as words
        rep #$20                     ;   in ONE window -- the four byte halves pl_thr2..5
        .LONGA ON                    ;   did are empty pieces now (they are reached by
        sec                          ;   falling through only)
        lda zp_px
        sbc bl_x
        sta swr_vx
        sec                          ; swr_vy = zp_py - bl_y
        lda zp_py
        sbc bl_y
        sta swr_vy
        .LONGA OFF                   ; (2026-09-23: NO sep -- still 16-bit through the
                                     ;   empty pieces 3-5 into pl_thr6's jsl oo_w16)
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_thr3              ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLTHR2_END+1
        ert 'pl_thrust piece 2 outgrew PLTHR2_BASE..END (memory_map.inc)'
    .endif

        org PLTHR3_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thr3
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_thr4              ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLTHR3_END+1
        ert 'pl_thrust piece 3 outgrew PLTHR3_BASE..END (memory_map.inc)'
    .endif

        org PLTHR4_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thr4
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_thr5              ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > PLTHR4_END+1
        ert 'pl_thrust piece 4 outgrew PLTHR4_BASE..END (memory_map.inc)'
    .endif

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thr5
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pl_thr6              ;   next byte of this segment -- fall through
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_thr6
                                      ; 2026-09-23: 16-bit from pl_thr2 (no sep there):
        jsl B1CODE_BASE+b1_oct_of.oo_w16 ;   past oct_of's rep; returns 8-bit
        sta pl_ko
        lda bl_dmg                   ; ...and ONLY THEN the damage half
        jmp en_plr_hurt
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
