;--------------------------------------------------------------
; pl_thrust.asm -- P_DamageMobj's thrust for the PLAYER (p_inter.c:804-831):
;   damage/8 units away from the inflictor.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; pl_thrust -- no arguments: bl_dmg is the damage, (bl_x, bl_y) the ball,
;   i.e. the inflictor. The vector is (player - ball): away from it,
;   as DOOM's angle is.
;   Clobbers A/X/Y, thr_d, swr_vx/swr_vy, the AI step scratch and mv_dx/mv_dy
;   (which move_player rewrites from the stick next frame anyway).
;--------------------------------------------------------------
.proc pl_thrust
        lda bl_dmg                   ; the damage this ball rolled at spawn, x2.
        asl                          ;   DOOM spends 1.33*damage over ~4 drawn
        sta thr_d                    ;   frames; this port spends the whole slide
                                     ;   in ONE step, and at 1.0 an imp moved the ...
        stz thr_d+1                  ; 2*damage still fits a byte, so the high half
                                     ;   is always 0. stz, not lda #0/sta: the ...
        sec                          ; --- swr_vx = zp_px - bl_x, low half
        lda zp_px
        sbc bl_x
        sta swr_vx
        jmp pl_thr2                  ; ...carry rides the jmp into the high half
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

        org PLTHR2_BASE
.proc pl_thr2
        lda zp_px+1                  ; --- ...swr_vx high half
        sbc bl_x+1
        sta swr_vx+1
        sec                          ; --- swr_vy = zp_py - bl_y, low half
        lda zp_py
        sbc bl_y
        sta swr_vy
        jmp pl_thr3
.endp
    .if * > PLTHR2_END+1
        ert 'pl_thrust piece 2 outgrew PLTHR2_BASE..PLTHR2_END (memory_map.inc)'
    .endif

        org PLTHR3_BASE
.proc pl_thr3
        lda zp_py+1                  ; --- ...swr_vy high half
        sbc bl_y+1
        sta swr_vy+1
                                      ; 2026-09-22 (drac030): the thunk inlined
        jsl B1CODE_BASE+b1_oct_of    ; A = the octant of (player - ball), 0..7
        tax                          ;   (thr_comp indexes thr_sx/thr_sy with it,
        jmp pl_thr4                  ;    and does not clobber X)
.endp
    .if * > PLTHR3_END+1
        ert 'pl_thrust piece 3 outgrew PLTHR3_BASE..PLTHR3_END (memory_map.inc)'
    .endif

        org PLTHR4_BASE
.proc pl_thr4                        ; the octant -> a signed 16-bit step per axis,
        ldy #0                       ;   en_thrust's own decomposition (1 = all of
        lda thr_sx,x                 ;   the slide, 2 = three quarters on the
        jsr thr_comp                 ;   diagonals, bit7 = the other way)
        ldy #ai_sy-ai_sx             ; (ai_sdir sits between them -- the same
        lda thr_sy,x                 ;  guard en_thrust carries applies here)
        jsr thr_comp
        jmp pl_thr5
.endp
    .if * > PLTHR4_END+1
        ert 'pl_thrust piece 4 outgrew PLTHR4_BASE..PLTHR4_END (memory_map.inc)'
    .endif

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
.proc pl_thr5                        ; ...and spend it through move_player's own
        lda ai_sx                    ;   collision path: the halfway probe, the
        sta mv_dx                    ;   step-up rule, coll_plr and en_solid, so
        lda ai_sx+1                  ;   a shove into a wall slides along it and
        sta mv_dx+1                  ;   a shove into a monster stops dead.
        jmp pl_thr6
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
.proc pl_thr6
        lda ai_sy                    ; ...the other axis, then P_TryMove itself
        sta mv_dy
        lda ai_sy+1
        sta mv_dy+1
        jsr skipx_ref                ; cur_floor FIRST -- coll_step_ok measures the
                                     ;   step against it, and move_player only ...
        jsr move_player.mp_slide     ; the KICK, spent (p_inter.c:830)
        lda bl_dmg                   ; ...and ONLY THEN the damage. Swallowing
        jmp en_plr_hurt              ;   ball.asm's own two instructions is what
                                     ;   pays for the call: ?hit is three bytes
                                     ;   SHORTER than before, not three longer,
                                     ;   and ball_frame was full to the byte.
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
