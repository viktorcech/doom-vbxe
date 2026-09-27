;--------------------------------------------------------------
; movers.asm -- floor movers: lifts, lowering/raising floors, perpetual plats,
;   teleports. Triggers are 16 B records packed by tools/pack_things.py.
;--------------------------------------------------------------
; mv_ptr -- zp_ptr = trigger record mv_i (16 bytes each).
;   Parked at MVPTR_BASE: the movers block ($A0AE..$A301, up to spr_blit) is full,
;   and this runs a handful of times per crossing test.
;--------------------------------------------------------------
mvp_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_ptr
	lda mv_i
	rep #$20
	.LONGA ON
	and #$00ff
	asl
;	sta m_a			;probably a relic of old code
	asl
	asl
	asl
;	clc
        adc THINGS_BASE+11
        sta zp_ptr
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
    .if * > $B810                  ; hud_blit moved to FAST RAM on 2026-09-09; $B810+ is
        ert 'mv_ptr overran $B7C1-$B80F (memory_map.inc)'   ; free now, the guard keeps the block's size
    .endif
        .endseg
        org mvp_resume

;--------------------------------------------------------------
; mv_step -- m_b = whole floor units the mover moves THIS frame (the Q8
;   remainder accumulates in mv_frac). PLATSPEED*4 = 2.8 units/VBLANK = exactly
;   2x the door speed, so double frame_dt's DOOR_STEP/DOOR_FADD instead of
;   multiplying again.
;--------------------------------------------------------------
mvs_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_step
        lda DOOR_FADD
        asl
        sta m_b
        lda DOOR_STEP
        rol
        sta m_b+1
        jsr mv_slow                  ; ...then DOOM's own speed for this record
        ldx mv_slot                  ; the Q8 remainder is PER SLOT
        clc
        lda MV_FRAC,x
        adc m_b
        sta MV_FRAC,x
        lda m_b+1
        adc #0                       ; + carry out of the Q8 accumulate
        sta m_b
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org MVSLOW_BASE

;--------------------------------------------------------------
; mv_slow -- m_b:m_b+1 >>= MV_SPD[slot]: the frame's Q8 step at DOOM's speed for
;   THIS record instead of the port's one-per-direction base.
;   Clobbers A/Y; X is untouched, both callers reload it straight after.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_slow
        ldy mv_slot
        lda MV_SPD,y
        beq ?out
        tay
        rep #$20                     ; the shifts on the word in A, not on the
        .LONGA ON                    ;   two bytes in memory (drac030 idiom)
        lda m_b
?sh     lsr @
        dey
        bne ?sh
        sta m_b
        .LONGA OFF
        sep #$20
?out    rts
.endp
        .endseg
    .if * > MVSLOW_END+1
        ert 'mv_slow outgrew MVSLOW_BASE..END (memory_map.inc)'
    .endif
        org mvs_resume

;--------------------------------------------------------------
; mv_crossed -- C=1 if the player's movement segment crosses the trigger line.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_crossed
        ; Same idea as the doors: instead of geometry, ask which sector the ...
        ldy #0                       ; either room next to the line will do
        jsr ?match
        bcs ?yes
        ldy #2
        jsr ?match
        bcs ?yes
        rts                          ; (C = 0 here: the bcs fell through)
?yes
	rep #$20
	.LONGA ON
	lda mv_ox                    ; in the right room: now DOOM's own test --
        sta mv_px                    ; did the move cross the line? (side changed)
        lda mv_oy
        sta mv_py
                                     ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr mv_side_line.msl_w16     ;   still 16-bit (this sep and that rep were an
        .LONGA OFF                   ;   empty pair)
        sta mv_s1
	rep #$20
	.LONGA ON
        lda zp_px
        sta mv_px
        lda zp_py
        sta mv_py
                                     ; 2026-09-22 (65816-windows): past the callee's rep
        jsr mv_side_line.msl_w16
        .LONGA OFF
        cmp mv_s1
	jne mv_cross2
	clc
        rts

?match  lda (zp_ptr),y               ; ONE byte: pack_things.py asserts 255
        cmp mv_psec                  ;   sectors, so a room id is a byte and $FF
        bne ?nomatch                 ;   is its "no room" sentinel -- which is
        sec                          ;   what the record's OTHER byte was, and
        rts                          ;   it carries the floor SPEED now
?nomatch clc                         ; (mv_psec, not m_a: the sector is latched
        rts                          ;  once a frame now -- see the head of this
.endp                                ;  .proc. m_a does not survive mv_side_line
        .endseg
                                     ;  anyway, which is why it could never have
                                     ;  been the latch itself.)
;--------------------------------------------------------------
; mv_sector -- m_a = the sector the player is in (BSP descent, as door_at_point).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_sector
                                      ; 2026-09-22 idiom: mvg_arm inlined (-12): arms the
        lda #40                      ;   depth guard (deeper than any tree these maps
        sta mv_dep                   ;   build) and hands back MAP_HROOT in A
        lda MAP_HROOT
                                     ;   MAP_HROOT, the root node index (map ...
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
mvs_top                              ; (mv_guard comes back here). NOT
                                     ;   mv_step -- that name is taken by
                                     ;   the floor-mover's own proc above.
?w      lda zp_nid+1
        bmi ?leaf
        rep #$20                     ; 2026-09-26: node_side (renderer.asm) = calc_
        .LONGA ON                    ;   nodeptr + point_on_side fused, Y = the child's
        lda zp_nid                   ;   offset: one jsr and the 0/1 re-test less
        jsr node_side
	lda [zp_nodeptr],y
        sta zp_nid
	sep #$20
	.LONGA OFF
        jmp mv_guard                 ; ...which is `jmp ?w` unless the descent has
                                     ;   run 40 deep, and then it bails to ?leaf
mvs_leaf                             ; (mv_guard's bail-out lands here)
?leaf
	rep #$20
	.LONGA ON
	lda zp_nid
	asl
	asl
;	clc
	adc #MAP_SSECT
	sta zp_vptr

        lda [zp_vptr]
	asl
	asl
	asl
;	clc
	adc #MAP_SEGS
	sta zp_sptr

	ldy #SEG_FRONT
        lda [zp_sptr],y
	and #$00ff
        sta m_a

	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mv_psec_set -- latch the player's sector for this frame's trigger scan.
;--------------------------------------------------------------
mvps_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_psec_set
        jsr mv_sector                ; m_a = sector under (zp_px, zp_py)
        lda m_a
        sta mv_psec
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
mv_psec dta 0                        ; the latched sector id (a byte: see mv_crossed)
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org mvps_resume

;--------------------------------------------------------------
; mv_side_line -- A = 0/1: which side of the trigger line (mv_px, mv_py) is on.
;   sign of (px-x1)*(y2-y1) - (py-y1)*(x2-x1).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_side_line
	rep #$20
	.LONGA ON
msl_w16                              ; (2026-09-22: 16-bit callers enter here)
        sec                          ; cx_a = px - x1
	ldy #4
        lda mv_px
        sbc (zp_ptr),y
        sta cx_a

        sec                          ; cx_b = y2 - y1
        ldy #10
        lda (zp_ptr),y
        ldy #6
        sbc (zp_ptr),y
        sta cx_b

        sec                          ; cx_c = py - y1
                                      ; 2026-09-22 idiom: Y is still 6 (cx_b's second
        lda mv_py
        sbc (zp_ptr),y
        sta cx_c

        sec                          ; cx_d = x2 - x1
        ldy #8
        lda (zp_ptr),y
        ldy #4
        sbc (zp_ptr),y
        sta cx_d
                                     ; 2026-09-22 (65816-windows): into cross_pos past
        jmp cross_pos.cp_w16         ;   its rep, still 16-bit (this sep and that rep
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; mv_cross2 -- the second half of the EXACT segment-crossing test. mv_crossed
;   proved the move's endpoints straddle the trigger line -- but that is true
;   anywhere along the line's INFINITE extension, and a trigger's neighbour
;   IN: zp_ptr = trigger record, mv_ox/oy -> zp_px/py = the move. C=1 = crossed.
;--------------------------------------------------------------
mvx2_resume = *
        org MVX2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_cross2
        ldy #4                       ; side of line end 1 vs the move...
        jsr mv_side_pt
        sta mv_s2                    ; mv_s2, NOT mv_s1: mv_crossed left the side
        ldy #8                       ;   the player came FROM in mv_s1 and
        jsr mv_side_pt               ;   trig_walk's teleport gate still has to
        cmp mv_s2                    ;   read it. Borrowing it here overwrote that
        beq ?no                      ;   with a value about the LINE's endpoints,
                                     ;   which is what killed E1M8's finale ...
        sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mv_side_pt -- A = 0/1: which side of the MOVE segment (mv_ox/oy ->
;   zp_px/py) the record point at offset Y (x lo/hi, y lo/hi) is on:
;   sign of (Px-Ox)*(Ny-Oy) - (Py-Oy)*(Nx-Ox). Clobbers A/Y, cx_a..cx_d.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_side_pt
	rep #$20
	.LONGA ON
        sec                          ; cx_a = Px - Ox
        lda (zp_ptr),y
        sbc mv_ox
        sta cx_a
	iny
	iny

        sec                          ; cx_c = Py - Oy
        lda (zp_ptr),y
        sbc mv_oy
        sta cx_c

        sec                          ; cx_b = Ny - Oy
        lda zp_py
        sbc mv_oy
        sta cx_b

        sec                          ; cx_d = Nx - Ox
        lda zp_px
        sbc mv_ox
        sta cx_d
                                     ; 2026-09-22 (65816-windows): into cross_pos past
        jmp cross_pos.cp_w16         ;   its rep, still 16-bit
        .LONGA OFF
.endp
        .endseg
    .if * > MVX2_END+1
        ert 'mv_cross2/mv_side_pt outgrew MVX2_BASE..END (memory_map.inc)'
    .endif
        org mvx2_resume

; (mv_free / mv_start / update_movers moved to MOVERS2_BASE -- see the end of
; this file. The $A0AE block has no room for slot indexing.)

;==============================================================
; Walkover triggers: the scan + the "already fired" bitmap
;--------------------------------------------------------------
; linedef 195 / special 88, which you can ride again and again) and W1 (once --
; the secret whose floor stays down). The port only modelled the first: after a
; W1 secret fired, mv_start put mv_state straight back to idle, so every later
; frame the player spent on that line fired it AGAIN. Nothing moved (the floor
; was already there), but the platform SFX restarted every frame -- which is
; what made the sound stutter while walking through the doorway next to it.
;
; So a W1 trigger now sets its bit here and check_triggers skips it forever.
; once per boot -- fine while the port is single-level; a level reload would
; have to zero mv_used.
;
; The block sits at MVUSED_BASE because the movers segment ($A0AE..$A301, up to
; spr_blit) has three bytes left.
;==============================================================
mvu_resume = *
        org MVUSED_BASE

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc check_triggers
                                      ; 2026-09-22 idiom: mv_psec_set inlined (-12)
        jsr mv_sector                ; WHICH ROOM IS THE PLAYER IN -- once for
        lda m_a
        sta mv_psec
                                     ;   the whole scan.
	stz mv_i
                                     ;   moving, so for the ~7 s of a ride not one ...
?loop   lda mv_i
        cmp THINGS_BASE+13           ; trigger count
        bcc ?test
        rts
?test   jsr mv_used_get              ; a W1 special that has already fired?
        bcs ?nx
        jsr mv_ptr                   ; zp_ptr = this trigger record
        jsr mv_crossed
        bcc ?nx                      ; (the fire path FALLS THROUGH to ?nx now:
                                     ;  the `jmp ?nx` it used to end with paid
                                     ;  for the two jsrs above and here)
        jsr trig_exit                ; the W1 EXIT test, then trig_walk's own
                                      ; 2026-09-22 idiom: mv_psec_set inlined (-12)
        jsr mv_sector                ; ...and EV_Teleport moves the player, so
        lda m_a
        sta mv_psec
                                     ;   re-latch: the records after this one
                                     ;   must see the sector the OLD code would
                                     ;   have descended to.
?nx     inc mv_i                     ; KEEP SCANNING after a fire -- one W1 line
	bra ?loop
                                     ;   baron doors are two records of one line;
                                     ;   the old jmp-out opened only one)
.endp
        .endseg

;--------------------------------------------------------------
; mv_used_get / mv_used_set -- bit mv_i of the fired bitmap. get returns C=1
;   when the trigger is spent. Both clobber A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_used_get
        lda mv_i
        cmp #MV_TRIGS
        bcs ?no                      ; past the bitmap -> treat as repeatable
        lsr                          ; mv_used_idx INLINE (2026-09-15): this runs
        lsr                          ;   once per trigger per frame, so the
        lsr                          ;   jsr/rts and the mv_i reload go
        tax
        lda mv_i
        and #7
        tay
        lda mv_used,x
        and mv_bit,y
        beq ?no
        sec
        rts
?no     clc
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_used_set
        lda mv_i
        cmp #MV_TRIGS
        bcs ?out
        jsr mv_used_idx
        ora mv_bit,y
        sta mv_used,x
?out    rts
.endp
        .endseg

;   X = byte index, Y = bit index, A = the byte
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_used_idx
        lda mv_i
        lsr
        lsr
        lsr
        tax
        lda mv_i
        and #7
        tay
        lda mv_used,x
        rts
.endp
        .endseg

mv_bit  dta 1,2,4,8,16,32,64,128
mv_used :[MV_TRIGS/8] dta 0          ; MV_TRIGS triggers, one bit each. E1M4 hit
                                     ;   67 once the raise-floor + 86-door ...

    .if * > MVUSED_END
        ert 'the trigger block outgrew MVUSED_BASE..MVUSED_END (memory_map.inc)'
    .endif
        org mvu_resume

;==============================================================
; THE FLOOR ENGINE -- MV_NMAX slots (memory_map.inc), laid out like the doors.
; Parked here because the $A0AE movers block is packed solid and slot indexing
; needs the room.
;==============================================================
;--------------------------------------------------------------
; mv_secptr -- zp_mvsec = &MAP_SECTORS[the sector of the record at zp_ptr].
;   mv_start then arms. Preserves X (mv_start calls it with the slot in X);
;   clobbers A/Y and zp_mvsec, which update_movers reloads per slot anyway.
;--------------------------------------------------------------
mvs2_resume = *
        org MVSEC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_secptr
	rep #$20
	.LONGA ON
        ldy #12
        lda (zp_ptr),y
                                      ; 2026-09-21: b8 is F_GUN (pack_things.py), a
        and #$00ff                   ;   sector id is b0-b7 -- a G1 floor record
        asl                     ; *8 = sizeof(sector record)
	asl
	asl
;	clc
	adc #MAP_SECTORS
	sta zp_mvsec
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mv_reset -- per level: park every slot and clear the W1 fired bitmap. Moved
;   out of the $E760 block, which is full to the byte.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_reset
        ldx #MV_TABEND-MV_TAB        ; 200 B: dex/bne, NOT dex/bpl -- the index
?mv     dex                          ;   starts above 127 and bpl would fall out
        stz MV_TAB,x                 ;   of the loop on the very first pass
        bne ?mv
        ldx #11                      ; 96 bits, one per trigger (E1M4 hit 80 once
?mu     stz mv_used,x                ;   the stairs/teleport/donut specials joined
        dex                          ;   pack_things SPEC)
        bpl ?mu
        stz ts_acc                   ; the scrolling wall starts unscrolled -- a
        stz ts_col                   ;   stale ts_col would wrap the base address
        jsr tp_build                 ;   BELOW the texture on the first wrap
        jmp sq2_lt_init
                                     ; ... and TAIL-CALL the light init VIA the ...
.endp
        .endseg

;--------------------------------------------------------------
; tp_build -- per level: tp_bits = the rooms on either side of a teleport
;   record (b10), tp_any = the level has one. ai_tele's gates. Also clears
;   pl_rt, so no reactiontime is carried into the next level.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tp_build
        ldx #31
?cl     stz tp_bits,x
        dex
        bpl ?cl
        stz tp_any
        stz pl_rt
        stz mv_i
?lp     lda mv_i
        cmp THINGS_BASE+13           ; the trigger count
        bcs ?out
        jsr mv_ptr
        ldy #13
        lda (zp_ptr),y
        and #$04                     ; b10: a teleport record
        beq ?nx
        sta tp_any                   ; (4: nonzero)
        lda (zp_ptr)                 ; its two rooms, +0 and +2
        jsr ?set
        ldy #2
        lda (zp_ptr),y
        jsr ?set
?nx     inc mv_i
        bra ?lp
?out    rts
?set    cmp #$FF                     ; no room on that side
        beq ?sr
        tax
        and #7
        tay
        txa
        lsr @
        lsr @
        lsr @
        tax
        lda tp_bits,x
        ora mv_bit,y
        sta tp_bits,x
?sr     rts
.endp
        .endseg
        .segment D0
tp_bits :32 dta 0                    ; one bit per room id (a byte, $FF = none)
tp_any  dta 0                        ; nonzero: the level has a teleport line
        .endseg

;--------------------------------------------------------------
; mv_raise -- state 4: the floor CREEPS UP to MV_DST and stops there. X = the
;   slot, zp_mvsec = its sector (update_movers set both).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_raise
        lda DOOR_STEP                ; Q8 step / 2 (mv_step's fast path is x2)
        lsr
        sta m_b+1
        lda DOOR_FADD
        ror
        sta m_b
        jsr mv_slow                  ; ...then DOOM's own speed for this record

        ldx mv_slot                  ; the Q8 remainder is PER SLOT
        clc
        lda MV_FRAC,x
        adc m_b
        sta MV_FRAC,x
        lda m_b+1
        adc #0
        sta m_b                      ; whole units this frame

        clc                          ; floor += m_b
        ldy #0
        lda (zp_mvsec),y
        adc m_b
        sta m_a
        iny
        lda (zp_mvsec),y
        adc #0
        sta m_a+1

        sec                          ; reached the target?
        lda MV_DSTL,x
        sbc m_a
        lda MV_DSTH,x
        sbc m_a+1
        bpl ?store                   ; still below it -> keep climbing

        lda MV_DSTL,x                ; arrived: clamp and park the slot
        sta m_a
        lda MV_DSTH,x
        sta m_a+1
	stz MV_STATE,x
                                      ; 2026-09-22 idiom: snd_q_pstop inlined (-12)
        lda #SFX_PSTOP               ; DOOM sfx_pstop: T_MoveFloor pastdest
        sta snd_pending

?store
        lda m_a
        sta (zp_mvsec)
        ldy #1
        lda m_a+1
        sta (zp_mvsec),y
        rts
.endp
        .endseg
;--------------------------------------------------------------
; mv_frame -- what the frame loop calls: step the movers, then let the floors
;   that moved take what stands on them along. bsp_main's $2000 segment has no
;   room for a second jsr (update_pz already tail-calls update_damage and
;   update_door30 for exactly that reason), so the pair is wrapped here.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_frame
        jsr mv_carry                 ; BEFORE the step, not after: a slot armed
        jmp update_movers            ;   this frame has to record where its floor
                                     ;   IS before update_movers moves it, or the ...
.endp
        .endseg

;--------------------------------------------------------------
; mv_carry -- p_map.c P_ChangeSector's half that matters here: a floor that
;   moves takes what is standing on it along.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_carry
        ldx #MV_NMAX-1
?slot   lda MV_STATE,x
        bne ?live                    ; 0 = the slot is idle as of this frame --
        lda mvc_act,x                ;   but it may have gone idle ON this frame,
        beq ?next                    ;   and that last step, the one that lands
        lda #0                       ;   (mvc_now is only stored on the live
?live   sta mvc_now                  ;   paths, 2026-09-15)
                                     ;   carried.
        lda MV_SECL,x                ; where is its floor right now?
        sta zp_ptr
        lda MV_SECH,x
        sta zp_ptr+1
	rep #$20
	.LONGA ON
        lda (zp_ptr)
        sta mvc_new
	sep #$20
	.LONGA OFF
        lda mvc_act,x
        beq ?arm                     ; it was idle last frame: just remember
        lda mvc_lstl,x               ; did the floor actually move this frame?
        cmp mvc_new
        bne ?carry
        lda mvc_lsth,x
        cmp mvc_new+1
        beq ?next
?carry  lda mvc_lstl,x
        sta mvc_old
        lda mvc_lsth,x
        sta mvc_old+1
                                      ; 2026-09-22 (65816-style: registers ride the
        phx                          ;   stack, not a RAM cell)
        jsr mvc_things
        plx                          ; ...and fall through to remember the height
?arm    lda mvc_now                  ; stopped -> the history goes with it. (The
        beq ?forget                  ;   height is stored either way: with

        lda #1                       ;   mvc_act clear nobody reads it, and a
        bne ?put                     ;   `bne` on the height itself would fall
?forget lda #0                       ;   through whenever its high byte is 0.)
?put    sta mvc_act,x
        lda mvc_new
        sta mvc_lstl,x
        lda mvc_new+1
        sta mvc_lsth,x
?next   dex
        bpl ?slot
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mvc_things -- the sweep. mvc_old = the height the floor just left, zp_ptr =
;   the sector that moved, loc_floor after each locate_floor = where it is now.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mvc_things
	rep #$20
	.LONGA ON
        lda zp_ptr                   ; locate_floor clobbers zp_ptr, so keep the
        sta mvc_sec                  ;   sector we are looking for
        lda zp_px                    ; ...and borrow the point it tests
        sta mvc_sv                   ;   (point_on_side reads zp_px/zp_py)
        lda zp_py
        sta mvc_sv+2
	sep #$20
	.LONGA OFF
        stz mvc_i
?loop   lda mvc_i
        cmp THINGS_BASE              ; the level's thing count
        bcs ?done
        tax
        TALIVE                                ; taken / gone: not standing anywhere (inlined 2026-09-26)
        beq ?next

        lda mvc_i
        jsr en_thing.en_th2          ; sp_ptr = its record

        ldy #4                       ; is it standing on the height the floor
	rep #$20
	.LONGA ON
        lda (sp_ptr),y               ;   just left?
        cmp mvc_old
        bne ?nextw
	                       ; a candidate -- but is it in THAT sector?
        lda (sp_ptr)
        sta zp_px
        ldy #2
        lda (sp_ptr),y
        sta zp_py
	sep #$20
	.LONGA OFF
        jsr locate_floor             ; leaves zp_ptr on the sector it landed in
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        sep #$20

        lda zp_ptr
        cmp mvc_sec
        bne ?next
        lda zp_ptr+1
        cmp mvc_sec+1
        bne ?next

        lda mvc_i                    ; yes: ride the floor down (or up)
        jsr en_thing.en_th2          ;   (locate_floor went through sp_ptr too)

        ldy #4
	rep #$20
	.LONGA ON
        lda loc_floor
        sta (sp_ptr),y
?nextw	sep #$20
	.LONGA OFF
?next	inc mvc_i
        bra ?loop

?done
	rep #$20
	.LONGA ON
	lda mvc_sv                   ; the player goes back where he was
        sta zp_px
        lda mvc_sv+2
        sta zp_py
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg
mvc_act  dta 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; [MV_NMAX] live last frame?
mvc_lstl dta 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; [MV_NMAX] and where
mvc_lsth dta 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
mvc_old  dta 0,0
mvc_new  dta 0,0
mvc_sec  dta 0,0
mvc_sv   dta 0,0,0,0
mvc_i    dta 0
mvc_slot dta 0
mvc_now  dta 0                                         ; is the slot still live?
    .if * > MVSEC_END+1
        ert 'the movers overflow block outgrew MVSEC_BASE..MVSEC_END (memory_map.inc)'
    .endif
        org MVSND_BASE

;--------------------------------------------------------------
; mv_sndst -- mv_start's tail ($E760 and $7000 are both full to the byte):
;   A = the MV_STATE just armed, X = the slot. The W1 spend is unchanged; the
;   start SFX now matches the original exactly: sfx_pstart belongs to a DWUS
;   LIFT and nothing else (p_plats.c:217).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_sndst
                                      ; 2026-09-21: 4 = the T_MoveFloor raise, the
        cmp #4                       ;   ONLY silent start. 1 and 3 are plats (3 =
        beq ?floor                   ;   perpetualRaise setting off upwards)
        lda MV_STAY,x
        bmi ?stay                    ; stays-down floor: silent + spend the bit
                                      ; 2026-09-22 idiom: snd_q_pstart inlined (the tail
        lda #SFX_PSTART              ;   jmp went: -3). state-1, no STAY = the lift
        sta snd_pending
        rts
?floor  lda MV_STAY,x
        bpl ?out
?stay   jmp mv_used_set              ; W1 (once): mark it spent NOW -- when the
                                     ;   floor lands the slot returns to idle, and ...
?out    rts
.endp
        .endseg
    .if * > MVSND_END+1
        ert 'mv_sndst outgrew MVSND_BASE..END (memory_map.inc)'
    .endif
        org mvs2_resume

mv2_resume = *
        org MOVERS2_BASE

;--------------------------------------------------------------
; mv_free -- C=1 and X = the slot to arm for the record at zp_ptr, C=0 if this
;   trigger must be dropped. Two reasons to drop it:
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_free
        jsr mv_secptr                ; zp_mvsec = &MAP_SECTORS[this record]
        ldx #MV_NMAX-1
?l      lda MV_STATE,x
        beq ?nx                      ; idle slot: nothing to clash with
        lda MV_SECL,x
        cmp zp_mvsec
        bne ?nx
        lda MV_SECH,x
        cmp zp_mvsec+1
        beq ?no                      ; already moving -> EV_DoPlat's "continue"
?nx     dex
        bpl ?l
        ldx #MV_NMAX-1               ; free to start: hand back an idle slot
?f      lda MV_STATE,x
        beq ?yes
        dex
        bpl ?f
?no     clc                          ; all slots busy, or the sector is running
        rts
?yes    sec
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mv_start -- X = the slot mv_free found. Arms it from the record at zp_ptr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_stop
        ldx #MV_NMAX-1               ; park EVERY running slot. DOOM stops only
?l      stz MV_STATE,x               ;   the sectors carrying the line's tag, but
        dex                          ;   one record per TAGGED SECTOR is 40 of
        bpl ?l                       ;   them on E2M2 alone and that map's piece
        rts                          ;   2 has 1920 B. On E2M2 and E2M3 -- the
.endp
        .endseg



;--------------------------------------------------------------
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_start
                                      ; 2026-09-21: + p_plats.c perpetualRaise (87).
        stx mv_slot                  ;   Same stores as the .else side, with the
        ldy #1                       ;   FLAG byte taken last so its test needs no
        lda (zp_ptr),y               ;   reload. Byte 1 is this record's SPEED, as
        sta MV_SPD,x                 ;   a shift count (pack_things.py SPEED)
        stz MV_FRAC,x
        jsr mv_secptr                ; zp_mvsec = &MAP_SECTORS[sector], the same
        lda zp_mvsec                 ;   pointer mv_free just compared against
        sta MV_SECL,x                ;   (X survives: mv_secptr uses A and Y)
        lda zp_mvsec+1
        sta MV_SECH,x
        ldy #13                      ; b15 = the floor stays down (secret #2);
        lda (zp_ptr),y               ;   b11 WITHOUT b13 = a plat that never
        sta MV_STAY,x                ;   stops -- trig_fire sends no DOOR record
        and #$08                     ;   here, so b11 alone decides
        bne ?perp
        iny                          ; (Y = 14) target floor
        lda (zp_ptr),y
        sta MV_DSTL,x
        iny
        lda (zp_ptr),y
        sta MV_DSTH,x
        sec                          ; where the floor started (to return to) --
        lda (zp_mvsec)               ;   and, on the way past, src - dst, which
        sta MV_SRCL,x                ;   says which WAY this floor goes
        sbc MV_DSTL,x
        ldy #1
        lda (zp_mvsec),y
        sta MV_SRCH,x
        sbc MV_DSTH,x
        bmi ?up                      ; target ABOVE us -> state 4 (mv_raise,
        lda #1                       ;   creeping up at FLOORSPEED). Below -> the
        bra ?st                      ;   old state 1 descent at PLATSPEED*4.
        ; perpetualRaise (p_plats.c:230): dst = two signed bytes, low | high<<8.
        ;   low -> MV_DST, high -> MV_SRC, so ?fall/?rise run it unchanged.
?perp   iny                          ; (Y = 14: the bne came in with 13)
        lda (zp_ptr),y
        sta MV_DSTL,x
        ora #$7F                     ; sign-extend: b7 set -> $FF, N = 1...
        bmi ?pl
        lda #0                       ;   ...else 0 (two entries: no stz)
?pl     sta MV_DSTH,x
        iny
        lda (zp_ptr),y
        sta MV_SRCL,x
        ora #$7F
        bmi ?ph
        lda #0
?ph     sta MV_SRCH,x
        ldy #12                      ; plat->status = P_Random()&1: the sector's
        lda (zp_ptr),y               ;   bit 0 stands in -- odd rises first (3),
        and #1                       ;   even falls first (1)
        asl @
        inc @
        bra ?st
?up     lda #4                       ; EVERY mover used to be armed as a descent,
?st     sta MV_STATE,x               ;   which is why a staircase snapped into
                                     ;   place: the first step went straight past
                                     ;   the target and got clamped to it.
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>mv_change            ;   next byte of this segment -- fall through
                                     ;   the W1 spend + the start SFX, in the $7000 ...
.endp
        .endseg

;--------------------------------------------------------------
; mv_change -- p_plats.c:184, raiseToNearestAndChange. The platform that comes
;   up out of the nukage takes the FLOOR of the sector on the line's front side
;   and stops burning ("NO MORE DAMAGE, IF APPLICABLE", sec->special = 0).
;--------------------------------------------------------------
mvchg_resume = *
        org MVCHG_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_change
        pha                          ; mv_sndst reads the state out of A
        pei (zp_ptr)                 ; BUG FIX 2026-09-15: keep the RECORD pointer
        lda THINGS_BASE+13           ; n_trig * 16
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
	asl
;	clc
        adc THINGS_BASE+11
        sta zp_ptr
	sep #$20
	.LONGA OFF
?scan
        lda (zp_ptr)
        cmp #$FF
        beq ?out                     ; end of table: this trigger changes nothing
        cmp mv_i
        beq ?hit

        clc
        lda zp_ptr
        adc #2
        sta zp_ptr
        bcc ?scan
        inc zp_ptr+1
	bra ?scan
?hit
	ldy #1
        lda (zp_ptr),y               ; the front side's floor colour
        ldy #5
        sta (zp_mvsec),y
        ldy #7
        lda (zp_mvsec),y
        and #255-$0E                 ; damage class 0: it is not slime any more
        sta (zp_mvsec),y
?out
        rep #$20                     ; trig_fire's tail (tl_once) reads the record's
        .LONGA ON                    ;   ONCE bit through zp_ptr the moment mv_start
        pla                          ;   returns -- and this proc had walked zp_ptr
        sta zp_ptr                   ;   through the change table, so that test read
        sep #$20                     ;   a byte of the TABLE and could spend an SR
        .LONGA OFF                   ;   record's used-bit: E3M1's lift "door" (62,
        pla
        jmp mv_sndst
.endp
        .endseg
    .if * > MVCHG_END+1
        ert 'mv_change outgrew MVCHG_BASE..END (memory_map.inc)'
    .endif
        org mvchg_resume

;--------------------------------------------------------------
; update_movers -- one step per frame per live slot, on DOOM's clock: slide
;   down, dwell, raise back.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_movers
        ldx #MV_NMAX-1
?slot   lda MV_STATE,x
        beq ?idle                    ; an idle slot: no mv_slot round trip
        stx mv_slot                  ;   (2026-09-15)
        lda MV_SECL,x                ; zp_mvsec = &sector for THIS slot
        sta zp_mvsec
        lda MV_SECH,x
        sta zp_mvsec+1
        lda MV_STATE,x
        cmp #3
        beq ?rise                    ; 3 = a lift going back up, 1 = sliding
        cmp #1                       ;   down, 4 = creeping up to a target
                                      ; 2026-09-21: ?fall is 4 B past a branch now
        jeq ?fall                    ;   (perpetualRaise grew ?dwell and ?rise)
        cmp #4
        beq ?climb
?dwell  lda MV_TIMER,x               ; the dwell counts VBLANKs, not frames
        sec
        sbc dt_vbl
        sta MV_TIMER,x
        bcc ?up                      ; underflowed -> time is up
        bne ?next
                                      ; 2026-09-21 perpetualRaise: TWO dwells.
?up     lda MV_STATE,x               ;   2 = at the bottom -> 3, rise (as ever);
        inc @                        ;   8 = at the TOP     -> 1, fall.
        and #3                       ;   (s+1)&3 is both, no compare
        sta MV_STATE,x
        stz MV_FRAC,x                ; start the rise on a whole unit
                                      ; 2026-09-21: a perpetualRaise plat sounds at
        lda MV_STAY,x                ;   its group's soundorg (mv_psnd), not
        and #$08                     ;   level-wide
        beq ?lift
        lda #SFX_PSTART
        jsr mv_psnd
        bra ?next
?lift
                                      ; 2026-09-22 idiom: snd_q_pstart inlined (-12)
        lda #SFX_PSTART              ; DOOM sfx_pstart: the lift sets off again
        sta snd_pending
?next   ldx mv_slot                  ;   (T_PlatRaise, waiting -> up)
?idle   dex
        bpl ?slot
        rts

?climb  jsr mv_raiseg                ; = mv_raise + the T_MoveFloor grind
	bra ?next
?rise   jsr mv_step                  ; m_b = whole units this frame (MV_FRAC
                                     ;   keeps the Q8 remainder)
        ldx mv_slot
        clc                          ; raising: floor += delta
        lda (zp_mvsec)
        adc m_b
        sta m_a
        ldy #1
        lda (zp_mvsec),y
        adc #0
        sta m_a+1

        sec                          ; back at the start height?
        lda MV_SRCL,x
        sbc m_a
        lda MV_SRCH,x
        sbc m_a+1
        bpl ?store
        lda MV_SRCL,x
        sta m_a
        lda MV_SRCH,x
        sta m_a+1
                                      ; 2026-09-21 p_plats.c T_PlatRaise, `up`
        lda MV_STAY,x                ;   reaching plat->high: perpetualRaise
        and #$08                     ;   WAITS there and comes down again
        beq ?park                    ;   (state 8, see ?up); a lift is done --
        lda #MV_WAIT_VB              ;   A = 0 on that branch IS its idle state
        sta MV_TIMER,x
        lda #8
        sta MV_STATE,x
        lda #SFX_PSTOP               ; the thunk, where the plats are (mv_psnd
        jsr mv_psnd                  ;   hands m_a back for ?store)
        bra ?store
?park   sta MV_STATE,x
                                      ; 2026-09-22 idiom: snd_q_pstop inlined (-12)
        lda #SFX_PSTOP               ; DOOM sfx_pstop: back at the top
        sta snd_pending
?store
	rep #$20
	.LONGA ON
        lda m_a
        sta (zp_mvsec)
	sep #$20
	.LONGA OFF
        bra ?next
?fall   jsr mv_stepg                 ; the descent, mirror of ?rise: DOOM slides

        ldx mv_slot                  ;   the floor down at the same speed, and
        sec                          ;   the pstop has to come when it LANDS --
                                     ;   for the lift ~1.1 s after the pstart
        lda (zp_mvsec)               ;   (152 units at 2.8/VBLANK). mv_stepg =
                                     ;   mv_step + the STAY-floor grind
                                     ;   (T_MoveFloor); a lift slides silently
        sbc m_b
        sta m_a
        ldy #1
        lda (zp_mvsec),y
        sbc #0
        sta m_a+1

        sec                          ; reached the target floor?
        lda m_a
        sbc MV_DSTL,x
        lda m_a+1
        sbc MV_DSTH,x
        bpl ?store                   ; still above it -> keep sliding
        lda MV_DSTL,x                ; landed: clamp to the target...
        sta m_a
        lda MV_DSTH,x
        sta m_a+1
        lda MV_STAY,x                ; perpetualRaise: at its group's soundorg
        and #$08                     ;   (see ?up)
        beq ?thunk
        lda #SFX_PSTOP
        jsr mv_psnd
        bra ?quiet
                                      ; 2026-09-22 idiom: snd_q_pstop inlined (-12)
?thunk  lda #SFX_PSTOP               ; ...and thunk (DOOM sfx_pstop: T_PlatRaise
        sta snd_pending
?quiet

        ldx mv_slot                  ;   down -> waiting, T_MoveFloor pastdest)
        lda MV_STAY,x
        bmi ?stay                    ; W1 floor: stays down, this slot is done
        lda #MV_WAIT_VB              ; DOOM 3 s of dwell, counted in VBLANKs
        sta MV_TIMER,x               ;   from the landing, like p_plats.c
        lda #2
        sta MV_STATE,x               ; a lift dwells, then rises
        bra ?store                   ; (A=2: always)

?stay   stz MV_STATE,x
        bra ?store                   ; (A=0: always)

.endp
        .endseg
    .if * > MOVERS2_END+1
        ert 'the floor engine outgrew MOVERS2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mv_psnd -- A = SFX id of a perpetualRaise plat, played at the group's soundorg
;   (MAP_DSND[MAP_HNDOOR], pack_map.py) by the doors' positional routine.
;   Keeps m_a for the caller's ?store. Clobbers A, X, Y, m_b.
;--------------------------------------------------------------
        .segment B1
.proc mv_psnd
        pei (m_a)
        ldx MAP_HNDOOR
        jsr snd_q_door_at
        rep #$20
        .LONGA ON
        pla
        sta m_a
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
        org mv2_resume

;==============================================================
; update_scroll -- p_spec.c's "ANIMATE LINE SPECIALS" (special 48, scrolling
; wall left): sides[line->sidenum[0]].textureoffset += FRACUNIT every tic.
;==============================================================
SCROLL_Q8   equ 90
usc_resume = *
        org SCROLL_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_scroll
        ldx MAP_HSCRTEX
        bmi ?out                     ; $FF: nothing scrolls on this level
        ldy dt_vbl                    ; the VBLANKs this frame took
?acc    clc
        lda ts_acc
        adc #SCROLL_Q8
        sta ts_acc
        bcc ?nx
        jsr ?column                  ; carried: one whole column further on
?nx     dey
        bne ?acc
?out    rts
;   advance MAP_TEXADDR[x] by h bytes, or back to the start after w columns
?column lda ts_col                   ; wmask = w-1 = the last column the base may
        cmp MAP_TEXWMASK,x           ;   stand on; one more and it must come back
        bcs ?wrap
        inc ts_col
        bra ?fwd                     ; (always)
?wrap
	                             ; rewind the whole width: from column wmask
        stz ts_col                   ;   back to column 0 is wmask*stride bytes
    .if TEX_RUNS
        lda #2*TEX_RUNK              ; a PAINTED column is a fixed run record,
    .else                            ;   not h pixels (paint.asm)
        lda MAP_TEXH,x
    .endif
        sta m_a
        lda MAP_TEXWMASK,x
        sta m_b
        stz m_a+1
        stz m_b+1
        phy                          ; Y IS THE CALLER'S VBLANK COUNT (?acc) and
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
        ply                          ;   so Y came back as 2*TEX_RUNK+wmask. For
                                     ;   wmask <= 34 that re-arms the loop before ...
        sec
        lda MAP_TEXADDRLO,x
        sbc m_prod
        sta MAP_TEXADDRLO,x
        lda MAP_TEXADDRMID,x
        sbc m_prod+1
        sta MAP_TEXADDRMID,x
        lda MAP_TEXADDRHI,x
        sbc #0
        sta MAP_TEXADDRHI,x
        rts
?fwd    clc                          ; +stride: the next column of the same texture
        lda MAP_TEXADDRLO,x
    .if TEX_RUNS
        adc #2*TEX_RUNK
    .else
        adc MAP_TEXH,x
    .endif
        sta MAP_TEXADDRLO,x
        lda MAP_TEXADDRMID,x
        adc #0
        sta MAP_TEXADDRMID,x
        lda MAP_TEXADDRHI,x
        adc #0
        sta MAP_TEXADDRHI,x
        rts
.endp
        .endseg
    .if * > SCROLL_END+1
        ert 'update_scroll outgrew SCROLL_BASE..SCROLL_END (memory_map.inc)'
    .endif
        org usc_resume

;--------------------------------------------------------------
; trig_exit -- p_spec.c P_CrossSpecialLine's two exit cases, in front of
;   trig_walk: `case 52: G_ExitLevel()` and `case 124: G_SecretExitLevel()`.
;   Byte 3 of the record (its pad -- pack_things WALK_EXITS) says which one:
;   0 = an ordinary record, 1 = EXIT, 2 = SECRET EXIT.
;--------------------------------------------------------------
tgx_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc trig_exit
        ldy #3
        lda (zp_ptr),y
        beq ?walk
        cmp #2                       ; 2 = the SECRET exit: retarget the header
        bne ?req                     ;   exactly as use_leaf does for the switch
        lda MAP_HNEXTS
        sta MAP_HNEXT
?req    lda #1                       ; main acts on it after the frame flip
        sta EXIT_REQ
        rts
?walk
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>trig_walk            ;   next byte of this segment -- fall through
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org tgx_resume

;==============================================================
; trig_walk -- what a CROSSED line does.
;==============================================================
tgw_resume = *
        org TRIGW_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc trig_walk
        ldy #13
        lda (zp_ptr),y
        and #$04                     ; b10 = teleport record
        bne ?tele
        jmp trig_fire                ; doors + floors, one segment away ($CECA)
?tele   lda mv_s1
        beq ?out                     ; came from the BACK of the line: no-op
        ldy #14                      ; zp_ptr's dst word = destination index;
        lda (zp_ptr),y               ;   mv_ss (the BSP-descent scratch, free
	rep #$20
	.LONGA ON
	and #$00ff
                                     ;   again once mv_crossed returned) walks ...
        asl
        asl
        asl
;       clc
        adc THINGS_BASE+14
        sta mv_ss

	lda (mv_ss)
	sta zp_px
	sta mv_ox
	ldy #2
	lda (mv_ss),y
	sta zp_py
	sta mv_oy
	sep #$20
	.LONGA OFF
        ldy #4
        lda (mv_ss),y
        sta zp_ang                   ; thing->angle, BAM like MAP_HSANG
        jmp pl_tele                  ; the sound, the floor, reactiontime and the
                                     ;   telefrag (bsp_main_player.asm)
?out    rts                          ; zp_pz follows in update_pz, as after any
.endp                                ;   move
        .endseg
    .if * > TRIGW_END+1
        ert 'trig_walk outgrew TRIGW_BASE..TRIGW_END (memory_map.inc)'
    .endif
        org tgw_resume

;==============================================================
; update_damage -- p_spec.c P_PlayerInSpecialSector, once per frame.
;==============================================================
dmg_resume = *
        org DMGSEC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_damage
        lda dmg_timer                ; THE CLOCK FIRST, and it FREE-RUNS: DOOM's
        sec                          ;   test is `!(leveltime & 0x1f)` on the
        sbc dt_vbl                   ;   LEVEL clock, which keeps counting
        sta dmg_timer                ;   wherever the player stands. This used to
        bcs ?out                     ;   be a per-entry countdown re-armed to the
        lda #DMG_VB                  ;   full DMG_VB every frame he was NOT on a
        sta dmg_timer                ;   damaging floor, which made a strip he
                                     ;   WALKS ACROSS incapable of ever charging
                                     ;   him: E2M1's cross is 64 units wide, i.e.
        lda pl_dead                  ; P_PlayerThink hands a PST_DEAD player to
        ora pl_air                   ;   P_DeathThink and RETURNS, so
        bne ?out                     ;   P_PlayerInSpecialSector never runs on a
                                     ;   corpse: the nukage stops burning it and, ...
        ldy #7
        lda (zp_ptr),y               ; sector flags: b0 sky, b1-b3 damage class
        and #$0E
        beq ?out
        lsr
        tax                          ; 1 nukage, 2 slime, 3 super, 4 = E1M8 end
        jsr pw_shield                ; the radiation suit / invulnerability decide
        bcs ?out                     ;   whether this tic lands at all (powerups.asm)
        lda dmg_amt,x                ; P_DamageMobj(player->mo, NULL, NULL, dmg):
        jsr en_plr_hurt              ;   armour, health, the grunt, the face and
                                     ;   the death, all of it the monsters' path
                                     ;   (enemy.asm).
        cpx #4
        bne ?out
        lda PSTATE+PS_HEALTH         ; "if (player->health <= 10) G_ExitLevel()"
        cmp #11                      ;   -- it used to compare what pl_hurtfx
        bcs ?out                     ;   handed back, which is the DAMAGE (20),
        lda #1                       ;   so the E1M8 finale sector could never
        sta EXIT_REQ                 ;   fire the exit at all
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pl_armsub -- P_DamageMobj's armour block (p_inter.c:854-869), the one place
;   the port models it. Sits here because en_plr_hurt's own block has room for
;   the jsr and nothing more.
;     IN  A = damage
;     OUT A = what got through (the caller subtracts it from health), armour
;         points and pl_armt updated. X is untouched, C is NOT meaningful.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_armsub
        ldy pl_armt
        beq ?out                     ; no armour: all of it lands on health
        pha                          ; the raw damage, across the roll
        cpy #2
        bne ?third
        lsr                          ; blue: saved = damage/2
        bpl ?got                     ; (always: bit 7 shifted in as a 0)
?third  ldy #$FF                     ; green: saved = damage/3
        sec
?d3     iny
        sbc #3
        bcs ?d3
        tya
?got    cmp PSTATE+PS_ARMOR          ; "if (player->armorpoints <= saved)"
        bcc ?ok
        lda PSTATE+PS_ARMOR          ;   the armour is used up: saved = points
?ok     sta arm_sav
        lda PSTATE+PS_ARMOR
        sec
        sbc arm_sav
        sta PSTATE+PS_ARMOR          ; armorpoints -= saved
        bne ?keep
        sta pl_armt                  ; ...and with the last point goes the type
?keep   pla                          ; damage -= saved (C=1 out of the sbc above)
        sbc arm_sav
?out    rts
.endp
        .endseg
    .if * > DMGSEC_END+1
        ert 'update_damage/pl_armsub outgrew DMGSEC_BASE..END (memory_map.inc)'
    .endif
        org DMGAMT_BASE
dmg_amt dta 0,5,10,20,20             ; P_PlayerInSpecialSector's damage per tic
    .if * > DMGAMT_END+1
        ert 'dmg_amt outgrew DMGAMT_BASE..DMGAMT_END (memory_map.inc)'
    .endif
        org dmg_resume

;==============================================================
; update_door30 -- the second half of p_doors.c's close30ThenOpen (specials
; 16/76). door_force_open sent the door DOWN and set DOORSTAY b1; here:
;   b1 armed  -> wait for DOOR_STATE to fall back to 0 (it has landed), then
;                load the 16-bit 30 s counter and switch to b2.
;==============================================================
d30_resume = *
        org DOOR30_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_door30
        ldx MAP_HNDOOR
        beq ?ret
        dex
?l      lda.l DOORSTAY,x
        and #$06
        beq ?nx
        and #$04                     ; b2 = the countdown is already running.
        bne ?cnt                     ;   IT WAS `lsr / lsr / bcs` (2026-08-28):
                                     ;   two LSRs after `and #$06` put bit ONE in ...
        lda.l DOOR_STATE,x           ; armed: not shut yet -> nothing to do
        bne ?nx
        lda #4
        sta.l DOORSTAY,x             ; b2 alone: the arm bit is spent
        lda #<DOOR30_VB
        sta.l DOOR_WAIT,x
        lda #>DOOR30_VB
        sta.l DOOR_FRAC,x
        bne ?nx                      ; (>DOOR30_VB = 5, never zero)
?cnt    lda.l DOOR_WAIT,x
        sec
        sbc dt_vbl
        sta.l DOOR_WAIT,x
        bcs ?nx
        lda.l DOOR_FRAC,x            ; borrowed into the high half. No read-
	dec
        sta.l DOOR_FRAC,x            ;   group only, so DEC long,X does not
        cmp #$FF                     ;   exist. A still holds the new value.
        bne ?nx
        lda #0
        sta.l DOOR_FRAC,x            ; no stale Q8 remainder for the rise
        lda #1                       ; 30 s up: send it back up -- and PARK it
        sta.l DOORSTAY,x             ;   open. p_doors.c removes the thinker when
                                     ;   a close30ThenOpen reaches the top, so it
                                     ;   must NOT dwell and close again.
        jsr door_force_open.dfo_go   ; X = door index: open + positional SFX --
                                     ;   and the GUARDED DOOR_NACT bump, which is
                                     ;   the whole reason this is a call now.
?nx     dex
        bpl ?l
?ret    rts
.endp
        .endseg
    .if * > DOOR30_END+1
        ert 'update_door30 outgrew DOOR30_BASE..DOOR30_END (memory_map.inc)'
    .endif
        org d30_resume
