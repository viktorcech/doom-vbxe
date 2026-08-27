;==============================================================
; pl_kick.asm -- P_DamageMobj's KICK for the PLAYER.
;--------------------------------------------------------------
; WHAT DOOM DOES. p_inter.c:830 does not move the target; it adds to its
; momentum, and p_mobj.c P_XYMovement spends that a tic at a time under
; FRICTION (0xe800 = 0.90625) until it drops below STOPSPEED:
;
;       target->momx += FixedMul(thrust, finecosine[ang])
;
; Two more things from the source that shape this:
;   * p_user.c P_Thrust -- the player's OWN walking goes into the same
;     momx/momy. There is no separate "kick" channel; shove and walk add up.
;   * p_mobj.c:137-145 -- momentum is CLAMPED to MAXMOVE (30 units) and the
;     move is then taken in halves, because a single big step would jump a
;     wall. move_player has the same rule the other way round: it tests the
;     HALFWAY point and says so in its own comment -- that is only sound for a
;     step of SPD (24) or less.
;
; HOW IT IS DONE HERE. The port keeps no momentum vector for the player
; (move_player writes the stick's step straight into zp_px/zp_py; pl_adx/pl_ady
; live only while airborne and ?land zeroes them on the ground), so the shove
; is carried the way the port already carries a CORPSE's slide in en_slide:
; an OCTANT and a REMAINING DISTANCE, spending an eighth of what is left per
; frame. Two bytes of state instead of a 16-bit vector, the same taper the
; corpses use, and the first frame of a 128-unit shove is 16 units -- under
; SPD, so move_player's halfway probe stays sound and no clamp is needed.
;
;   pl_thrust  -- the hit: octant of (player - inflictor), distance = 2*damage
;   pl_kick    -- every moving frame: an eighth of it onto mv_dx/mv_dy, so the
;                 shove goes through the SAME P_TryMove the walk does (slides
;                 along walls, stops dead at a monster) and adds to the walk
;   pl_idle    -- the frame where the stick is centred: without it a standing
;                 player would take the hit and not budge, because move_player
;                 leaves through ?nomove before it ever computes a step
;
; WHERE IT LIVES -- and the rule that was broken twice before this worked.
; ram_map.py says "FREE RAM FOR NEW CODE: NONE" and means it; what is left is
; a few hundred bytes in gaps of 10-26 B, so this is cut into thirteen pieces
; chained by jmp (the port already relocates procs that way: collision @ $0900,
; check_bbox @ $1B00, tw_setup @ $8D00).
;
;   A GAP WITH NO XEX SEGMENT IS NOT NECESSARILY FREE. Runtime variables and
;   runtime-built tables carry no segment, so a gap finder built on XEX
;   segments alone offers them as empty space -- and check_xex cannot see it
;   either, because RESERVED does not list every variable (ram_map.py says so
;   itself: "cross-check the .lab"). Two earlier attempts died exactly there:
;   a piece at $A2B2 sat on AM_ON/AM_SH/AM_KARM (the automap's live state) and
;   one at $E6C3 on MV_SPD. The engine rewrote them every frame, the piece
;   turned into data mid-flight, and the first fireball jumped into it -- a
;   screenful of garbage that differed every run.
;   EVERY BASE BELOW WAS CHECKED AGAINST build/doom_bsp.lab: no symbol of any
;   kind falls inside these ranges. Re-check with tools/tests/_verify_holes.py
;   before moving any of them.
;
;   CARRY RIDES THE SEAMS. Several pieces are one 16-bit subtract cut in half;
;   jmp touches no flag. A piece moves WHOLE or not at all.
;==============================================================

        org PLKDAT_BASE
pl_kd   dta 0                        ; units of shove still to spend
pl_ko   dta 0                        ; ...along this octant (oct_of's eight)
    .if * > PLKDAT_END+1
        ert 'pl_kd/pl_ko outgrew PLKDAT_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_kick -- move_player's ?slide calls this INSTEAD of pl_latch and it ends by
;   jumping to pl_latch, so the call site is the size it always was (that block
;   ends flush at MNKEY_BASE with one spare byte).
;==============================================================
        org PLKICK1_BASE
.proc pl_kick
        lda pl_kd
        beq ?out
        lsr                          ; an eighth of what is left, the taper
        lsr                          ;   en_slide spends a corpse's slide with
        lsr
        beq ?stop                    ; under a unit a frame -> STOPSPEED
        sta thr_d
        stz thr_d+1
        jmp pl_kick2
?stop   stz pl_kd
?out    jmp pl_latch
.endp
    .if * > PLKICK1_END+1
        ert 'pl_kick piece 1 outgrew PLKICK1_BASE..END (memory_map.inc)'
    .endif

        org PLKICK2_BASE
.proc pl_kick2
        sec                          ; ...and take it off the remainder
        lda pl_kd
        sbc thr_d
        sta pl_kd
        ldx pl_ko
        jmp pl_kick3
.endp
    .if * > PLKICK2_END+1
        ert 'pl_kick piece 2 outgrew PLKICK2_BASE..END (memory_map.inc)'
    .endif

        org PLKICK3_BASE
.proc pl_kick3                       ; the octant -> a signed 16-bit component
        ldy #0                       ;   per axis: en_thrust's own decomposition
        lda thr_sx,x                 ;   (1 = all of it, 2 = three quarters on
        jsr thr_comp                 ;   the diagonals, bit7 = the other way)
        ldy #ai_sy-ai_sx             ; (ai_sdir sits between them -- the same
        lda thr_sy,x                 ;  guard en_thrust carries applies here)
        jsr thr_comp
        jmp pl_kick4
.endp
    .if * > PLKICK3_END+1
        ert 'pl_kick piece 3 outgrew PLKICK3_BASE..END (memory_map.inc)'
    .endif

        org PLKICK4_BASE
.proc pl_kick4                       ; mv_dx += the X component. The shove joins
        clc                          ;   the walk in the same delta, as P_Thrust
        lda mv_dx                    ;   and P_DamageMobj join in the same momx.
        adc ai_sx
        sta mv_dx
        lda mv_dx+1
        adc ai_sx+1
        sta mv_dx+1
        jmp pl_kick5
.endp
    .if * > PLKICK4_END+1
        ert 'pl_kick piece 4 outgrew PLKICK4_BASE..END (memory_map.inc)'
    .endif

        org PLKICK5_BASE
.proc pl_kick5
        clc
        lda mv_dy
        adc ai_sy
        sta mv_dy
        lda mv_dy+1
        adc ai_sy+1
        sta mv_dy+1
        jmp pl_latch                 ; ...and on into what ?slide used to call
.endp
    .if * > PLKICK5_END+1
        ert 'pl_kick piece 5 outgrew PLKICK5_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_idle -- move_player's ?dead jumps HERE instead of straight to ?nomove.
;==============================================================
        org PLIDLE1_BASE
.proc pl_idle
        lda pl_dead                  ; a corpse is still a corpse: P_DeathThink
        bne ?no                      ;   runs instead of P_MovePlayer
        lda pl_kd
        beq ?no
        jmp pl_idle2
?no     jmp move_player.mp_nomove
.endp
    .if * > PLIDLE1_END+1
        ert 'pl_idle piece 1 outgrew PLIDLE1_BASE..END (memory_map.inc)'
    .endif

        org PLIDLE2_BASE
.proc pl_idle2
        stz mv_dx                    ; no walk this frame -- pl_kick puts the
        stz mv_dx+1                  ;   shove on top of a zero step
        stz mv_dy
        stz mv_dy+1
        jsr skipx_ref                ; cur_floor, the step-up reference ?go
                                     ;   would have set (doors.asm)
        jmp move_player.mp_slide
.endp
    .if * > PLIDLE2_END+1
        ert 'pl_idle piece 2 outgrew PLIDLE2_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; pl_thrust -- ball.asm ?hit calls this instead of `lda bl_dmg / jsr
;   en_plr_hurt` and it makes that call itself at the end: p_inter.c:806 kicks
;   BEFORE the health test, so a killing shot still shoves the corpse.
;   DISTANCE is 2*damage -- DOOM's own figure is 1.33*damage but it is spread
;   over the tics its friction takes, and an eighth-per-frame taper spends
;   about half of what it is handed, so 2x lands the whole slide near DOOM's.
;   An imp (3..24) shoves 6..48 units, a baron (8..64) up to 128.
;==============================================================
        org PLTHR1_BASE
.proc pl_thrust
        lda bl_dmg
        asl
        sta pl_kd
        jmp pl_thr2
.endp
    .if * > PLTHR1_END+1
        ert 'pl_thrust piece 1 outgrew PLTHR1_BASE..END (memory_map.inc)'
    .endif

        org PLTHR2_BASE
.proc pl_thr2                        ; swr_vx = zp_px - bl_x: AWAY from the ball,
        sec                          ;   as DOOM's R_PointToAngle2(inflictor,
        lda zp_px                    ;   target) is
        sbc bl_x
        sta swr_vx
        jmp pl_thr3                  ; ...the borrow rides the jmp
.endp
    .if * > PLTHR2_END+1
        ert 'pl_thrust piece 2 outgrew PLTHR2_BASE..END (memory_map.inc)'
    .endif

        org PLTHR3_BASE
.proc pl_thr3
        lda zp_px+1
        sbc bl_x+1
        sta swr_vx+1
        jmp pl_thr4
.endp
    .if * > PLTHR3_END+1
        ert 'pl_thrust piece 3 outgrew PLTHR3_BASE..END (memory_map.inc)'
    .endif

        org PLTHR4_BASE
.proc pl_thr4
        sec
        lda zp_py
        sbc bl_y
        sta swr_vy
        jmp pl_thr5
.endp
    .if * > PLTHR4_END+1
        ert 'pl_thrust piece 4 outgrew PLTHR4_BASE..END (memory_map.inc)'
    .endif

        org PLTHR5_BASE
.proc pl_thr5
        lda zp_py+1
        sbc bl_y+1
        sta swr_vy+1
        jmp pl_thr6
.endp
    .if * > PLTHR5_END+1
        ert 'pl_thrust piece 5 outgrew PLTHR5_BASE..END (memory_map.inc)'
    .endif

        org PLTHR6_BASE
.proc pl_thr6
        jsr oct_of                   ; A = the octant, 0..7
        sta pl_ko
        lda bl_dmg                   ; ...and ONLY THEN the damage half
        jmp en_plr_hurt
.endp
    .if * > PLTHR6_END+1
        ert 'pl_thrust piece 6 outgrew PLTHR6_BASE..END (memory_map.inc)'
    .endif
