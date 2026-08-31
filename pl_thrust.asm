;==============================================================
; pl_thrust.asm -- P_DamageMobj's KICK for the PLAYER (p_inter.c:804-831).
;--------------------------------------------------------------
; WHAT DOOM DOES. P_DamageMobj thrusts EVERY target that has an inflictor --
; the player included, and nothing in the block exempts him:
;
;       ang    = R_PointToAngle2(inflictor->x, inflictor->y, target->x, target->y)
;       thrust = damage*(FRACUNIT>>3)*100/target->info->mass
;       target->momx += FixedMul(thrust, finecosine[ang])
;
; MT_PLAYER's mass is 100, so the player gets thrust = damage*8192 = damage/8
; units a tic, which P_XYMovement spends at FRICTION 0.90625 until it drops
; under STOPSPEED -- a visible slide of damage*133/100 = 1.33*damage units.
; An imp's fireball (3..24) shoves him 4 to 32 units; a baron's (8..64) up to
; 85. Until now the port did none of it: en_plr_hurt took the health and the
; player stood exactly where he was.
;
; THE SAME REDUCTION THE THINGS GOT. enemy_ai_thrust.asm spends a thing's whole
; slide AT ONCE on the tic of the hit, because nothing in this port carries
; momentum across tics. The player carries none either -- pl_adx/pl_ady exist
; only while airborne and pl_zmove's ?land zeroes them every frame he stands --
; so the kick is spent the same way: one move_player-style step, this frame,
; through the collision path he already walks with. At this frame rate DOOM's
; slide is three or four drawn frames long, so one step reads much the same.
;
; DIRECTION is the OCTANT of (player - inflictor), oct_of's eight, exactly as
; en_thrust does it: 22 degrees of error on a 20-unit slide is under two units,
; and it costs a table read where DOOM's angle costs a divide.
;
; MAGNITUDE is 2*damage. DOOM's own figure is 1.33*damage, but DOOM SPREADS it
; over the three or four drawn frames its friction takes, so what the player
; feels is a shove. This port has no per-tic momentum and spends the slide in
; ONE step, and a single step of 1.0*damage is 3..24 units for an imp -- less
; than one walk step (SPD 24), which is why the first cut of this felt like
; nothing happened at all. x2 costs one asl and lands the imp at 6..48.
;
; WHERE IT LIVES -- and why it is in six pieces. The engine's bank-0 address
; space is full: 223 bytes over eleven gaps, the biggest 26 B (tools/ram_map.py
; says "FREE RAM FOR NEW CODE: NONE" and it is telling the truth). This proc is
; ~110 B. Rather than evict a warm block, the code is CUT INTO SIX and parked in
; six of those gaps, each piece ending in a jmp to the next. The port already
; relocates procs this way (collision @ $0900, check_bbox @ $1B00, tw_setup @
; $8D00); this is the same trick, just finer.
;
;   ALL SIX ARE UNDER $C000 ON PURPOSE. The under-ROM gaps ($EA4E, $E6C3) are
;   bigger and would have taken this in three, but underrom.asm banks the OS ROM
;   out only AROUND the calls that live there, and ball.asm's ?hit runs with the
;   ROM in. A piece parked there would have to carry a rom_out/rom_in pair --
;   and would fetch garbage the one time it did not.
;
;   THE CARRY CROSSES THE SEAMS. Pieces 1->2->3 are one 32-bit subtract cut in
;   three; jmp touches no flag, so the borrow rides across intact. If a piece
;   ever moves, it moves WHOLE -- do not reorder the halves of a sbc pair.
;
; CALLED FROM ball.asm ?hit (the flying missile: imp/caco/baron fireball and
; the rocket). It REPLACES the `lda bl_dmg / jsr en_plr_hurt` that stood there
; and makes that call itself at the end, in DOOM's order: p_inter.c:806 kicks
; BEFORE the health test, so a killing shot still shoves him.
;==============================================================

        org PLTHR1_BASE
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
                                     ;   in ONE step, and at 1.0 an imp moved the
                                     ;   player 3..24 units -- under a single walk
                                     ;   step (SPD 24), which reads as "nothing
                                     ;   happened". x2 is 6..48 for an imp and up
                                     ;   to 128 for a baron; 64*2 still fits the
                                     ;   byte, x4 would not.
        stz thr_d+1                  ; 2*damage still fits a byte, so the high half
                                     ;   is always 0. stz, not lda #0/sta: the
                                     ;   piece is full to the byte and the asl
                                     ;   above had to come from somewhere (the
                                     ;   port is 65816 -- coll_plr uses stz too).
        sec                          ; --- swr_vx = zp_px - bl_x, low half
        lda zp_px
        sbc bl_x
        sta swr_vx
        jmp pl_thr2                  ; ...carry rides the jmp into the high half
.endp
    .if * > PLTHR1_END+1
        ert 'pl_thrust piece 1 outgrew PLTHR1_BASE..PLTHR1_END (memory_map.inc)'
    .endif

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
        jsr oct_of                   ; A = the octant of (player - ball), 0..7
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

        org PLTHR5_BASE
.proc pl_thr5                        ; ...and spend it through move_player's own
        lda ai_sx                    ;   collision path: the halfway probe, the
        sta mv_dx                    ;   step-up rule, coll_plr and en_solid, so
        lda ai_sx+1                  ;   a shove into a wall slides along it and
        sta mv_dx+1                  ;   a shove into a monster stops dead.
        jmp pl_thr6
.endp
    .if * > PLTHR5_END+1
        ert 'pl_thrust piece 5 outgrew PLTHR5_BASE..PLTHR5_END (memory_map.inc)'
    .endif

        org PLTHR6_BASE
.proc pl_thr6
        lda ai_sy                    ; ...the other axis, then P_TryMove itself
        sta mv_dy
        lda ai_sy+1
        sta mv_dy+1
        jsr skipx_ref                ; cur_floor FIRST -- coll_step_ok measures the
                                     ;   step against it, and move_player only
                                     ;   refreshes it on a frame the stick moved
                                     ;   him (locate_floor sits past ?go, and a
                                     ;   standing player leaves through ?nomove
                                     ;   before it). A kick taken while standing
                                     ;   still would otherwise be measured against
                                     ;   whatever sector he last WALKED in, and be
                                     ;   silently refused -- or step up something
                                     ;   MAXSTEP should have stopped. skipx_ref is
                                     ;   move_player's own between-axes refresh and
                                     ;   no-ops while airborne (doors.asm).
        jsr move_player.mp_slide     ; the KICK, spent (p_inter.c:830)
        lda bl_dmg                   ; ...and ONLY THEN the damage. Swallowing
        jmp en_plr_hurt              ;   ball.asm's own two instructions is what
                                     ;   pays for the call: ?hit is three bytes
                                     ;   SHORTER than before, not three longer,
                                     ;   and ball_frame was full to the byte.
.endp
    .if * > PLTHR6_END+1
        ert 'pl_thrust piece 6 outgrew PLTHR6_BASE..PLTHR6_END (memory_map.inc)'
    .endif
