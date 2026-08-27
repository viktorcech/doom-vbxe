;==============================================================
; movers.asm -- walkover floor movers (DOOM lifts / lowering floors).
;--------------------------------------------------------------
; This is what opens E1M1's secret: linedef 195 is special 88 (WR Lower Lift,
; tag 2), so sector 70's floor drops to the lowest neighbouring floor, waits and
; comes back. pack_things.py precomputes every trigger as
;     u16 roomA,roomB | i16 x1,y1,x2,y2 | u16 sector+flags | i16 target  (16 B)
; (roomA/roomB = the sectors either side of the line, for mv_crossed's "is the
; player even next to it" gate; flags: b15 = the floor stays down, b14-b11 are
; the door/switch bits trig_fire routes on) and puts a pointer to the table at
; THINGS_BASE+11, the count at +13.
;
; TRIGGERING is a proper SEGMENT crossing, like P_CrossSpecialLine: the player's
; movement (mv_ox,mv_oy -> zp_px,zp_py) and the trigger line must straddle each
; other. Testing only the side of the infinite line would fire anywhere along its
; extension, halfway across the map.
;   side(line, oldpos) != side(line, newpos)   AND
;   side(move, x1y1)   != side(move, x2y2)
; Each side test is one cross_pos (the sign of a*b - c*d), so four in total, and
; only while a mover is idle.
;
; The sector being moved is held in zp_mvsec, its OWN zero-page pointer: the
; renderer reuses every other pointer each frame, and a mover has to survive
; across frames.
;==============================================================
; check_triggers now lives at MVUSED_BASE, together with the "already fired"
; bitmap it consults -- this segment has three spare bytes and the once-only
; logic did not fit. See the block at the end of this file.

;--------------------------------------------------------------
; mv_ptr -- zp_ptr = trigger record mv_i (16 bytes each).
;   Parked at MVPTR_BASE: the movers block ($A0AE..$A301, up to spr_blit) is full,
;   and this runs a handful of times per crossing test.
;--------------------------------------------------------------
mvp_resume = *
        org MVPTR_BASE
.proc mv_ptr
        lda mv_i
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod
        rol m_prod+1                 ; i*2
        lda m_prod
        sta m_a
        lda m_prod+1
        sta m_a+1
        asl m_prod
        rol m_prod+1                 ; i*4
        asl m_prod
        rol m_prod+1                 ; i*8
        asl m_prod
        rol m_prod+1                 ; i*16
        clc
        lda m_prod
        adc THINGS_BASE+11
        sta zp_ptr
        lda m_prod+1
        adc THINGS_BASE+12
        sta zp_ptr+1
        rts
.endp
    .if * > HUDBLIT_BASE
        ert 'mv_ptr overran $B7C1-$B80F and would clobber hud_blit'
    .endif
        org mvp_resume

;--------------------------------------------------------------
; mv_step -- m_b = whole floor units the mover moves THIS frame (the Q8
;   remainder accumulates in mv_frac). PLATSPEED*4 = 2.8 units/VBLANK = exactly
;   2x the door speed, so double frame_dt's DOOR_STEP/DOOR_FADD instead of
;   multiplying again. DOOM runs BOTH E1M1 movers at this speed: special 88 is
;   a downWaitUpStay plat (p_plats.c, PLATSPEED*4) and special 36 a turboLower
;   floor (p_floor.c, FLOORSPEED*4) -- the same 4 units/tic.
;   Parked at MVSTEP_BASE (the hole before this segment): ?rise and ?fall both
;   call it, and the segment tail has no room for two copies.
;--------------------------------------------------------------
mvs_resume = *
        org MVSTEP_BASE
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
    .if * > MVSTEP_END+1
        ert 'mv_step outgrew MVSTEP_BASE..END (memory_map.inc)'
    .endif
        org MVSLOW_BASE

;--------------------------------------------------------------
; mv_slow -- m_b:m_b+1 >>= MV_SPD[slot]: the frame's Q8 step at DOOM's speed for
;   THIS record instead of the port's one-per-direction base. The bases are
;   PLATSPEED*4 down and FLOORSPEED up, which is right for plats and turbo
;   floors and 4x too fast for a plain lowerFloorToLowest or a build8 staircase
;   -- and DOOM's slowness there is the effect, not an oversight (E1M8's 666
;   wall takes 9.8 s in DOOM and took 2.5 here). The shift comes out of the
;   trigger record (tools/pack_things.py SPEED) via mv_start.
;   Clobbers A/Y; X is untouched, both callers reload it straight after.
;--------------------------------------------------------------
.proc mv_slow
        ldy mv_slot
        lda MV_SPD,y
        beq ?out
        tay
?sh     lsr m_b+1
        ror m_b
        dey
        bne ?sh
?out    rts
.endp
    .if * > MVSLOW_END+1
        ert 'mv_slow outgrew MVSLOW_BASE..END (memory_map.inc)'
    .endif
        org mvs_resume

;--------------------------------------------------------------
; mv_crossed -- C=1 if the player's movement segment crosses the trigger line.
;--------------------------------------------------------------
.proc mv_crossed
        ; Same idea as the doors: instead of geometry, ask which sector the
        ; player is standing in and compare it with the trigger's activation
        ; sector (record offset 0). door_at_point does exactly this walk and is
        ; proven on hardware, so mv_sector is a copy of it.
        jsr mv_sector                ; m_a = sector under the player
        ldy #0                       ; either room next to the line will do
        jsr ?match
        bcs ?yes
        ldy #2
        jsr ?match
        bcs ?yes
        clc
        rts
?yes    lda mv_ox                    ; in the right room: now DOOM's own test --
        sta mv_px                    ; did the move cross the line? (side changed)
        lda mv_ox+1
        sta mv_px+1
        lda mv_oy
        sta mv_py
        lda mv_oy+1
        sta mv_py+1
        jsr mv_side_line
        sta mv_s1
        lda zp_px
        sta mv_px
        lda zp_px+1
        sta mv_px+1
        lda zp_py
        sta mv_py
        lda zp_py+1
        sta mv_py+1
        jsr mv_side_line
        cmp mv_s1
        beq ?nocross
        jmp mv_cross2                ; the move straddles the LINE -- real only
                                     ;   if the line also straddles the MOVE
?nocross clc
        rts
?match  lda (zp_ptr),y               ; ONE byte: pack_things.py asserts 255
        cmp m_a                      ;   sectors, so a room id is a byte and $FF
        bne ?nomatch                 ;   is its "no room" sentinel -- which is
        sec                          ;   what the record's OTHER byte was, and
        rts                          ;   it carries the floor SPEED now
?nomatch clc
        rts
.endp



;--------------------------------------------------------------
; mv_sector -- m_a = the sector the player is in (BSP descent, as door_at_point).
;--------------------------------------------------------------
.proc mv_sector
        jsr mvg_arm                  ; arms the depth guard and returns with A =
                                     ;   MAP_HROOT, the root node index (map
                                     ;   header, per level) -- three bytes for the
                                     ;   three the lda took, so this block is the
                                     ;   size it always was
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
mvs_top                              ; (mv_guard comes back here). NOT
                                     ;   mv_step -- that name is taken by
                                     ;   the floor-mover's own proc above.
?w      lda zp_nid+1
        and #$80
        bne ?leaf
        jsr calc_nodeptr
        jsr point_on_side
        bne ?lft
        ldy #8
        bne ?ds
?lft    ldy #10
?ds     lda [zp_nodeptr],y
        sta zp_nid
        iny
        lda [zp_nodeptr],y
        sta zp_nid+1
        jmp mv_guard                 ; ...which is `jmp ?w` unless the descent has
                                     ;   run 40 deep, and then it bails to ?leaf
mvs_leaf                             ; (mv_guard's bail-out lands here)
?leaf   lda zp_nid                   ; ssptr = MAP_SSECT + (nid & $7FFF)*4
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4
        clc                          ; SSECT is an EXT-bank offset (2026-08-18).
        lda m_prod                   ;   NOT zp_ptr -- the trigger RECORD lives
        adc #<MAP_SSECT              ;   there for the whole mv_crossed loop
        sta zp_vptr                  ;   (mv_ptr set it), which is why mv_ss
        lda m_prod+1                 ;   existed. zp_vptr is render-only scratch
        adc #>MAP_SSECT              ;   with the SAME bank byte ($01, seeded
        sta zp_vptr+1                ;   once) -- free outside the frame walk.
        ldy #0                       ; first seg of the subsector
        lda [zp_vptr],y
        sta m_a
        iny
        lda [zp_vptr],y
        sta m_a+1
        jsr m_x8                     ; seg record = MAP_SEGS + first*SEG_SIZE
        clc                          ; MAP_SEGS is an OFFSET in MAP_SEG_BANK ($03),
        lda m_prod                   ;   not a base-RAM address -- the seg records
        adc #<MAP_SEGS               ;   left base RAM on 2026-07-31 (map_syms.inc).
        sta zp_sptr                  ;   So this MUST go through zp_sptr and a long
        lda m_prod+1                 ;   read, exactly like door_at_point: mv_ss is
        adc #>MAP_SEGS               ;   2 bytes with no bank byte, and a plain
        sta zp_sptr+1                ;   (mv_ss),y here read the STACK PAGE instead,
        ldy #SEG_FRONT               ;   so m_a came back garbage, mv_crossed never
        lda [zp_sptr],y              ;   matched, and no walkover trigger ever fired.
        sta m_a
        lda #0
        sta m_a+1
        rts
.endp

;--------------------------------------------------------------
; mv_side_line -- A = 0/1: which side of the trigger line (mv_px, mv_py) is on.
;   sign of (px-x1)*(y2-y1) - (py-y1)*(x2-x1).
;--------------------------------------------------------------
.proc mv_side_line
        sec                          ; cx_a = px - x1
        ldy #4
        lda mv_px
        sbc (zp_ptr),y
        sta cx_a
        iny
        lda mv_px+1
        sbc (zp_ptr),y
        sta cx_a+1
        sec                          ; cx_b = y2 - y1
        ldy #10
        lda (zp_ptr),y
        ldy #6
        sbc (zp_ptr),y
        sta cx_b
        ldy #11
        lda (zp_ptr),y
        ldy #7
        sbc (zp_ptr),y
        sta cx_b+1
        sec                          ; cx_c = py - y1
        ldy #6
        lda mv_py
        sbc (zp_ptr),y
        sta cx_c
        iny
        lda mv_py+1
        sbc (zp_ptr),y
        sta cx_c+1
        sec                          ; cx_d = x2 - x1
        ldy #8
        lda (zp_ptr),y
        ldy #4
        sbc (zp_ptr),y
        sta cx_d
        ldy #9
        lda (zp_ptr),y
        ldy #5
        sbc (zp_ptr),y
        sta cx_d+1
        jmp cross_pos
.endp

;--------------------------------------------------------------
; mv_cross2 -- the second half of the EXACT segment-crossing test. mv_crossed
;   proved the move's endpoints straddle the trigger line -- but that is true
;   anywhere along the line's INFINITE extension, and a trigger's neighbour
;   sector can reach hundreds of units past the segment (E1M1's lift room
;   spans 600, so the lift started from half the map away). The crossing is
;   real only if the LINE's endpoints also straddle the MOVE segment -- the
;   textbook 4-sign test, the same shape use_seg_hit uses for the USE ray.
;   DOOM itself gets this from PIT_CheckLine's line-bbox overlap +
;   P_BoxOnLineSide (p_map.c:191-198); two cross products answer it exactly.
;   IN: zp_ptr = trigger record, mv_ox/oy -> zp_px/py = the move. C=1 = crossed.
;--------------------------------------------------------------
mvx2_resume = *
        org MVX2_BASE
.proc mv_cross2
        ldy #4                       ; side of line end 1 vs the move...
        jsr mv_side_pt
        sta mv_s2                    ; mv_s2, NOT mv_s1: mv_crossed left the side
        ldy #8                       ;   the player came FROM in mv_s1 and
        jsr mv_side_pt               ;   trig_walk's teleport gate still has to
        cmp mv_s2                    ;   read it. Borrowing it here overwrote that
        beq ?no                      ;   with a value about the LINE's endpoints,
                                     ;   which is what killed E1M8's finale
                                     ;   teleport (2026-08-08). same side ->
                                     ;   crossed the extension only
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; mv_side_pt -- A = 0/1: which side of the MOVE segment (mv_ox/oy ->
;   zp_px/py) the record point at offset Y (x lo/hi, y lo/hi) is on:
;   sign of (Px-Ox)*(Ny-Oy) - (Py-Oy)*(Nx-Ox). Clobbers A/Y, cx_a..cx_d.
;--------------------------------------------------------------
.proc mv_side_pt
        sec                          ; cx_a = Px - Ox
        lda (zp_ptr),y
        sbc mv_ox
        sta cx_a
        iny
        lda (zp_ptr),y
        sbc mv_ox+1
        sta cx_a+1
        iny
        sec                          ; cx_c = Py - Oy
        lda (zp_ptr),y
        sbc mv_oy
        sta cx_c
        iny
        lda (zp_ptr),y
        sbc mv_oy+1
        sta cx_c+1
        sec                          ; cx_b = Ny - Oy
        lda zp_py
        sbc mv_oy
        sta cx_b
        lda zp_py+1
        sbc mv_oy+1
        sta cx_b+1
        sec                          ; cx_d = Nx - Ox
        lda zp_px
        sbc mv_ox
        sta cx_d
        lda zp_px+1
        sbc mv_ox+1
        sta cx_d+1
        jmp cross_pos                ; A = 1 if cx_a*cx_b - cx_c*cx_d > 0
.endp
    .if * > MVX2_END+1
        ert 'mv_cross2/mv_side_pt outgrew MVX2_BASE..END (memory_map.inc)'
    .endif
        org mvx2_resume

; (mv_free / mv_start / update_movers moved to MOVERS2_BASE -- see the end of
; this file. The $A0AE block has no room for slot indexing.)

;==============================================================
; Walkover triggers: the scan + the "already fired" bitmap
;--------------------------------------------------------------
; DOOM's walkover specials come in two flavours: WR (repeatable -- E1M1's lift,
; linedef 195 / special 88, which you can ride again and again) and W1 (once --
; the secret whose floor stays down). The port only modelled the first: after a
; W1 secret fired, mv_start put mv_state straight back to idle, so every later
; frame the player spent on that line fired it AGAIN. Nothing moved (the floor
; was already there), but the platform SFX restarted every frame -- which is
; what made the sound stutter while walking through the doorway next to it.
;
; So a W1 trigger now sets its bit here and check_triggers skips it forever.
; One bit per trigger, 32 of them (E1M1 has 2). Cleared by the XEX load, i.e.
; once per boot -- fine while the port is single-level; a level reload would
; have to zero mv_used.
;
; The block sits at MVUSED_BASE because the movers segment ($A0AE..$A301, up to
; spr_blit) has three bytes left.
;==============================================================
mvu_resume = *
        org MVUSED_BASE

.proc check_triggers
        lda #0                       ; NO "is a mover running" gate here. It used
        sta mv_i                     ;   to skip the WHOLE scan while a lift was
                                     ;   moving, so for the ~7 s of a ride not one
                                     ;   walkover line in the level worked -- no
                                     ;   doors (E1M4 has 16 lines of specials
                                     ;   90/86), no teleports, no W1 floors. Only
                                     ;   the FLOOR engine is single-slot, and
                                     ;   trig_fire already refuses those on its own.
?loop   lda mv_i
        cmp THINGS_BASE+13           ; trigger count
        bcc ?test
        rts
?test   jsr mv_used_get              ; a W1 special that has already fired?
        bcs ?nx
        jsr mv_ptr                   ; zp_ptr = this trigger record
        jsr mv_crossed
        bcs ?fire
?nx     inc mv_i
        jmp ?loop
?fire   jsr trig_exit                ; the W1 EXIT test, then trig_walk's own
        jmp ?nx                      ;   doors.asm dispatcher); then KEEP
                                     ;   SCANNING -- one W1 line can tag several
                                     ;   sectors (E1M8: the two baron doors are
                                     ;   two records of one line; the jmp-out
                                     ;   opened only one)
.endp

;--------------------------------------------------------------
; mv_used_get / mv_used_set -- bit mv_i of the fired bitmap. get returns C=1
;   when the trigger is spent. Both clobber A/X/Y.
;--------------------------------------------------------------
.proc mv_used_get
        lda mv_i
        cmp #MV_TRIGS
        bcs ?no                      ; past the bitmap -> treat as repeatable
        jsr mv_used_idx
        and mv_bit,y
        beq ?no
        sec
        rts
?no     clc
        rts
.endp

.proc mv_used_set
        lda mv_i
        cmp #MV_TRIGS
        bcs ?out
        jsr mv_used_idx
        ora mv_bit,y
        sta mv_used,x
?out    rts
.endp

;   X = byte index, Y = bit index, A = the byte
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

mv_bit  dta 1,2,4,8,16,32,64,128
mv_used :[MV_TRIGS/8] dta 0          ; MV_TRIGS triggers, one bit each. E1M4 hit
                                     ;   67 once the raise-floor + 86-door
                                     ;   specials joined pack_things SPEC, and
                                     ;   96 was enough for episode 1 -- but a
                                     ;   TAGGED door is one record per SECTOR
                                     ;   wearing the tag, so a map that leans on
                                     ;   remote doors runs the count up fast
                                     ;   (DOOM II MAP02: 163). The block has the
                                     ;   room, so spend it here rather than have
                                     ;   the converter refuse the map.

    .if * > MVUSED_END
        ert 'the trigger block outgrew MVUSED_BASE..MVUSED_END (memory_map.inc)'
    .endif
        org mvu_resume

;==============================================================
; THE FLOOR ENGINE -- MV_NMAX slots (memory_map.inc), laid out like the doors.
; Parked here because the $A0AE movers block is packed solid and slot indexing
; needs the room.
;   mv_free      -- C=1 and X = the slot to arm, C=0 if they are all busy OR
;                   the record's sector is already moving (EV_DoPlat's
;                   "if (sec->specialdata) continue").
;   mv_start     -- X = slot: arm it from the trigger record at zp_ptr.
;   update_movers-- one step per frame for every live slot.
; The single-mover version this replaces is why E1M4 felt broken: its three WR
; lifts, three switch lifts and four lowering floors shared ONE slot, so for
; the ~7 s of any ride every other lift and switch in the level did nothing.
;==============================================================
;--------------------------------------------------------------
; mv_secptr -- zp_mvsec = &MAP_SECTORS[the sector of the record at zp_ptr].
;   mv_free and mv_start both need it and they MUST agree, or mv_free's "is this
;   sector already moving" test would compare a different sector than the one
;   mv_start then arms. Preserves X (mv_start calls it with the slot in X);
;   clobbers A/Y and zp_mvsec, which update_movers reloads per slot anyway.
;   The mask is #$01, not #$7F: pack_things.py gives a sector id b0-b8 and puts
;   flags in b9-b15. b14 (USE) survived the old mask and only came out right
;   because the three asl push it past bit 15 -- but b12 (once) does NOT, so an
;   F_USE|F_ONCE floor (special 21, absent from episode 1) aimed the mover at
;   MAP_SECTORS+$8000.
;   Parked at MVSEC_BASE ($7000, the run the seg table vacated): the floor
;   engine's own block had one byte left once mv_free grew. It first went into
;   what ram_map.py called the "$E6F8-$E71F hole" -- which is vs_th, the
;   vissprite THING array spr_add rewrites every frame, so the routine was
;   sprite data by the time a lift called it and the game hung. Both arrays are
;   in ram_map.py RESERVED now, so check_xex fails the build if it happens again.
;--------------------------------------------------------------
mvs2_resume = *
        org MVSEC_BASE
.proc mv_secptr
        ldy #12
        lda (zp_ptr),y
        sta m_prod
        iny
        lda (zp_ptr),y
        and #$01                     ; sector ids are 9 bits; b9-b15 are flags
        sta m_prod+1
        asl m_prod                   ; *8 = sizeof(sector record)
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_mvsec
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_mvsec+1
        rts
.endp

;--------------------------------------------------------------
; mv_reset -- per level: park every slot and clear the W1 fired bitmap. Moved
;   out of the $E760 block, which is full to the byte.
;--------------------------------------------------------------
.proc mv_reset
        lda #0
        ldx #MV_TABEND-MV_TAB        ; 200 B: dex/bne, NOT dex/bpl -- the index
?mv     dex                          ;   starts above 127 and bpl would fall out
        sta MV_TAB,x                 ;   of the loop on the very first pass
        bne ?mv
        ldx #11                      ; 96 bits, one per trigger (E1M4 hit 80 once
?mu     sta mv_used,x                ;   the stairs/teleport/donut specials joined
        dex                          ;   pack_things SPEC)
        bpl ?mu
        sta ts_acc                   ; the scrolling wall starts unscrolled -- a
        sta ts_col                   ;   stale ts_col would wrap the base address
        jmp lt_init                  ;   BELOW the texture on the first wrap
                                     ; ... and TAIL-CALL the light init: it is
                                     ;   per level like everything above, and
                                     ;   init_level's $1B00 block has one byte
                                     ;   left, not three (lights.asm)
.endp

;--------------------------------------------------------------
; mv_raise -- state 4: the floor CREEPS UP to MV_DST and stops there. X = the
;   slot, zp_mvsec = its sector (update_movers set both).
;
; This is what a raise used to skip. mv_start armed every mover as a descent, so
; a floor whose target was ABOVE it went below the target on its first step and
; got clamped straight to it -- E1M3's and E1M8's staircases appeared fully built
; in one frame instead of growing. EV_BuildStairs gives every step its own
; floordestheight and one thinker each, so the flight rises together and the
; steps arrive at different times; with a slot per step (MV_NMAX) that now
; happens here too.
;
; SPEED: half the door step, i.e. FLOORSPEED = 1 unit/tic, where mv_step's
; descent is PLATSPEED*4 = 4 units/tic. DOOM runs build8 at FLOORSPEED/4 and
; raiseToNearestAndChange at PLATSPEED/2 -- one speed for every raise is a
; simplification: the trigger record is 16 bytes with all 16 bits of its sector
; word spoken for, so there is nowhere to carry a per-record speed.
;--------------------------------------------------------------
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
        lda #0
        sta MV_STATE,x
        jsr snd_q_pstop              ; DOOM sfx_pstop: T_MoveFloor pastdest
?store  ldy #0
        lda m_a
        sta (zp_mvsec),y
        iny
        lda m_a+1
        sta (zp_mvsec),y
        rts
.endp
;--------------------------------------------------------------
; mv_frame -- what the frame loop calls: step the movers, then let the floors
;   that moved take what stands on them along. bsp_main's $2000 segment has no
;   room for a second jsr (update_pz already tail-calls update_damage and
;   update_door30 for exactly that reason), so the pair is wrapped here.
;--------------------------------------------------------------
.proc mv_frame
        jsr mv_carry                 ; BEFORE the step, not after: a slot armed
        jmp update_movers            ;   this frame has to record where its floor
                                     ;   IS before update_movers moves it, or the
                                     ;   things standing on it are already one
                                     ;   step stale by the time mv_carry first
                                     ;   looks and never match at all. Carrying
                                     ;   the riders one frame behind the floor is
                                     ;   invisible; missing them entirely is what
                                     ;   left the imp hanging in imp.png.
.endp

;--------------------------------------------------------------
; mv_carry -- p_map.c P_ChangeSector's half that matters here: a floor that
;   moves takes what is standing on it along. Without this an imp called down on
;   a lift stayed hanging in the air where the platform used to be (imp.png),
;   because a thing's height lives in its record and only the P_TryWalk commit
;   in enemy_ai.asm ever rewrites it -- i.e. only when the monster takes a step.
;
;   DOOM finds the things over a moving sector through the blockmap. This port
;   has no blockmap, so the sweep is the other way round and in two stages, to
;   keep the cost off the frame:
;     1. a per-slot memory of the height its sector was at LAST frame. Nothing
;        else has to change: mv_start does not have to be told, because a slot
;        that was idle last frame simply records where it starts and carries
;        nothing yet.
;     2. only things standing exactly on that old height are candidates (a
;        2-byte compare per thing), and only those pay for a locate_floor to
;        confirm they are really in THAT sector -- two lifts at the same height
;        must not drag each other's occupants.
;   Nothing hangs from a ceiling in episode 1 (pack_things checks
;   MF_SPAWNCEILING), so "stand it on the floor" is the whole rule.
;--------------------------------------------------------------
.proc mv_carry
        ldx #MV_NMAX-1
?slot   lda MV_STATE,x
        sta mvc_now                  ; 0 = the slot is idle as of this frame --
        bne ?live                    ;   but it may have gone idle ON this frame,
        lda mvc_act,x                ;   and that last step, the one that lands
        beq ?next                    ;   the floor on its target, still has to be
                                     ;   carried. Only a slot that was ALREADY
                                     ;   idle is skipped outright; otherwise the
                                     ;   riders end up parked one step above the
                                     ;   floor for good.
?live   lda MV_SECL,x                ; where is its floor right now?
        sta zp_ptr
        lda MV_SECH,x
        sta zp_ptr+1
        ldy #0
        lda (zp_ptr),y
        sta mvc_new
        iny
        lda (zp_ptr),y
        sta mvc_new+1
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
        stx mvc_slot
        jsr mvc_things
        ldx mvc_slot                 ; ...and fall through to remember the height
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

;--------------------------------------------------------------
; mvc_things -- the sweep. mvc_old = the height the floor just left, zp_ptr =
;   the sector that moved, loc_floor after each locate_floor = where it is now.
;--------------------------------------------------------------
.proc mvc_things
        lda zp_ptr                   ; locate_floor clobbers zp_ptr, so keep the
        sta mvc_sec                  ;   sector we are looking for
        lda zp_ptr+1
        sta mvc_sec+1
        lda zp_px                    ; ...and borrow the point it tests
        sta mvc_sv                   ;   (point_on_side reads zp_px/zp_py)
        lda zp_px+1
        sta mvc_sv+1
        lda zp_py
        sta mvc_sv+2
        lda zp_py+1
        sta mvc_sv+3
        lda #0
        sta mvc_i
?loop   lda mvc_i
        cmp THINGS_BASE              ; the level's thing count
        bcs ?done
        tax
        jsr thing_alive_bit          ; taken / gone: not standing anywhere
        beq ?next
        lda mvc_i
        jsr en_thing.en_th2          ; sp_ptr = its record
        ldy #4                       ; is it standing on the height the floor
        lda (sp_ptr),y               ;   just left?
        cmp mvc_old
        bne ?next
        iny
        lda (sp_ptr),y
        cmp mvc_old+1
        bne ?next
        ldy #0                       ; a candidate -- but is it in THAT sector?
        lda (sp_ptr),y
        sta zp_px
        iny
        lda (sp_ptr),y
        sta zp_px+1
        iny
        lda (sp_ptr),y
        sta zp_py
        iny
        lda (sp_ptr),y
        sta zp_py+1
        jsr locate_floor             ; leaves zp_ptr on the sector it landed in
        lda zp_ptr
        cmp mvc_sec
        bne ?next
        lda zp_ptr+1
        cmp mvc_sec+1
        bne ?next
        lda mvc_i                    ; yes: ride the floor down (or up)
        jsr en_thing.en_th2          ;   (locate_floor went through sp_ptr too)
        ldy #4
        lda loc_floor
        sta (sp_ptr),y
        iny
        lda loc_floor+1
        sta (sp_ptr),y
?next   inc mvc_i
        jmp ?loop
?done   lda mvc_sv                   ; the player goes back where he was
        sta zp_px
        lda mvc_sv+1
        sta zp_px+1
        lda mvc_sv+2
        sta zp_py
        lda mvc_sv+3
        sta zp_py+1
        rts
.endp
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
;   LIFT and nothing else (p_plats.c:217). A FLOOR starts SILENT -- p_floor.c's
;   T_MoveFloor has no start sound, only the stnmov grind while it moves
;   (mv_raiseg/mv_stepg) and pstop when it lands. The old unconditional
;   `jsr snd_q_pstart` played the lift sound on top of the grind -- "the E1M1
;   panel has two sounds" (2026-08-04).
;--------------------------------------------------------------
.proc mv_sndst
        cmp #1
        bne ?floor                   ; a raise is T_MoveFloor: silent start
        lda MV_STAY,x
        bmi ?stay                    ; stays-down floor: silent + spend the bit
        jmp snd_q_pstart             ; state-1, no STAY = the lift
?floor  lda MV_STAY,x
        bpl ?out
?stay   jmp mv_used_set              ; W1 (once): mark it spent NOW -- when the
                                     ;   floor lands the slot returns to idle, and
                                     ;   a later crossing would re-fire it (the
                                     ;   height write is silent, the SFX is not:
                                     ;   that was the doorway stutter).
?out    rts
.endp
    .if * > MVSND_END+1
        ert 'mv_sndst outgrew MVSND_BASE..END (memory_map.inc)'
    .endif
        org mvs2_resume

mv2_resume = *
        org MOVERS2_BASE

;--------------------------------------------------------------
; mv_free -- C=1 and X = the slot to arm for the record at zp_ptr, C=0 if this
;   trigger must be dropped. Two reasons to drop it:
;
;   * every slot is busy, or
;   * THIS RECORD'S SECTOR IS ALREADY MOVING. p_plats.c EV_DoPlat and
;     p_floor.c EV_DoFloor both walk the tagged sectors with
;         if (sec->specialdata)
;             continue;
;     and they have to: two thinkers on one floorheight fight. The port had no
;     such test, so a second trigger armed a SECOND slot on the same sector with
;     MV_SRC latched at wherever the floor happened to be, and then:
;       - both slots landed -> the thunk played twice (or three times),
;       - re-armed while it waited at the bottom -> the lift rose a hair and the
;         second slot yanked it back down, so it never came up again,
;       - re-armed while it rose -> one slot added the step the other subtracted
;         and the floor FROZE mid-travel with both slots busy for good.
;     That is not exotic: E1M2's sector 49 carries four trigger records (three
;     edge lines and a switch), and calling a lift and then STEPPING ON IT
;     crosses the same line twice. 32 sectors in episode 1 have more than one
;     record; only E1M1 has none.
;
;   Either way trig_fire drops the fire and does NOT spend the once-bit, so a
;   W1/S1 trigger can still do its job on a later try.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; mv_start -- X = the slot mv_free found. Arms it from the record at zp_ptr.
;--------------------------------------------------------------
.proc mv_start
        stx mv_slot
        ldy #13                      ; bit 15 = the floor stays down (secret #2)
        lda (zp_ptr),y
        sta MV_STAY,x
        ldy #1                       ; ...and byte 1 is this record's SPEED, as
        lda (zp_ptr),y               ;   a shift count (pack_things.py SPEED)
        sta MV_SPD,x
        jsr mv_secptr                ; zp_mvsec = &MAP_SECTORS[sector], the same
        lda zp_mvsec                 ;   pointer mv_free just compared against
        sta MV_SECL,x
        lda zp_mvsec+1
        sta MV_SECH,x
        ldy #14                      ; target floor
        lda (zp_ptr),y
        sta MV_DSTL,x
        iny
        lda (zp_ptr),y
        sta MV_DSTH,x
        lda #0
        sta MV_FRAC,x
        ldy #0                       ; where the floor started (to return to) --
        sec                          ;   and, on the way past, src - dst, which
        lda (zp_mvsec),y             ;   says which WAY this floor goes
        sta MV_SRCL,x
        sbc MV_DSTL,x
        iny
        lda (zp_mvsec),y
        sta MV_SRCH,x
        sbc MV_DSTH,x
        bmi ?up                      ; target ABOVE us -> state 4 (mv_raise,
        lda #1                       ;   creeping up at FLOORSPEED). Below -> the
        bne ?st                      ;   old state 1 descent at PLATSPEED*4.
?up     lda #4                       ; EVERY mover used to be armed as a descent,
?st     sta MV_STATE,x               ;   which is why a staircase snapped into
                                     ;   place: the first step went straight past
                                     ;   the target and got clamped to it.
        jmp mv_change                ; the raise-AND-CHANGE half, then mv_sndst:
                                     ;   the W1 spend + the start SFX, in the $7000
                                     ;   overflow block: THIS block is full, and
                                     ;   the old inline `jsr snd_q_pstart` played
                                     ;   the LIFT sound on every FLOOR too.
                                     ; The frame's own update_movers takes step 1.
                                     ;   This used to `jmp update_movers` so that
                                     ;   a raise -- which finished on its first
                                     ;   step back then -- freed its slot before
                                     ;   trig_fire returned, and a whole stair
                                     ;   chain fitted in the single slot there
                                     ;   was. With MV_NMAX slots and a raise that
                                     ;   climbs, that call only handed the steps
                                     ;   fired FIRST one extra move per record
                                     ;   still to fire, so the bottom of a
                                     ;   14-record flight (E1M8) set off 13 moves
                                     ;   ahead of the top. All of them start
                                     ;   together now, like EV_BuildStairs'
                                     ;   thinkers do.
.endp


;--------------------------------------------------------------
; mv_change -- p_plats.c:184, raiseToNearestAndChange. The platform that comes
;   up out of the nukage takes the FLOOR of the sector on the line's front side
;   and stops burning ("NO MORE DAMAGE, IF APPLICABLE", sec->special = 0). The
;   port kept the slime flat and the damage class, so E1M3's lift at
;   (-1115,-792) rose wearing acid (2026-08-07).
;
;   The port's flat IS one byte -- MAP_SECTORS[sec].floor_pal at +5 -- so the
;   whole change is that byte plus clearing the damage bits at +7. The new
;   colour comes out of the table pack_things parks right behind the trigger
;   array (p_trig + n_trig*16): (u8 trigger index, u8 colour) pairs, $FF ends
;   it. Nothing on the level pays for it but that one byte per pair.
;
;   Entered from mv_start with A = the new state, X = the slot, zp_mvsec = the
;   sector; both go on to mv_sndst untouched.
;--------------------------------------------------------------
mvchg_resume = *
        org MVCHG_BASE
.proc mv_change
        pha                          ; mv_sndst reads the state out of A
        lda THINGS_BASE+13           ; n_trig * 16
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc                          ; + p_trig = where the pairs start
        lda m_prod
        adc THINGS_BASE+11
        sta zp_ptr
        lda m_prod+1
        adc THINGS_BASE+12
        sta zp_ptr+1
?scan   ldy #0
        lda (zp_ptr),y
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
        bcs ?scan                    ; (always)
?hit    iny
        lda (zp_ptr),y               ; the front side's floor colour
        ldy #5
        sta (zp_mvsec),y
        ldy #7
        lda (zp_mvsec),y
        and #255-$0E                 ; damage class 0: it is not slime any more
        sta (zp_mvsec),y
?out    pla
        jmp mv_sndst
.endp
    .if * > MVCHG_END+1
        ert 'mv_change outgrew MVCHG_BASE..END (memory_map.inc)'
    .endif
        org mvchg_resume

;--------------------------------------------------------------
; update_movers -- one step per frame per live slot, on DOOM's clock: slide
;   down, dwell, raise back. Both counters scale with fps_n (VBLANKs the frame
;   took, from frame_dt), like the doors: p_plats.c gives downWaitUpStay speed =
;   PLATSPEED*4 (140 units/s) and wait = 3 s FROM THE LANDING, and neither may
;   depend on the port's frame rate.
;   The full DOOM sound sequence (T_PlatRaise) lives here + mv_start:
;     pstart (sets off, mv_start) -> pstop (lands, ?fall) -> 3 s -> pstart
;     (rises, ?up) -> pstop (back at the top, ?rise).
;   A W1 floor is done after its landing pstop (T_MoveFloor plays pstop too).
;--------------------------------------------------------------
.proc update_movers
        ldx #MV_NMAX-1
?slot   stx mv_slot
        lda MV_STATE,x
        beq ?next
        lda MV_SECL,x                ; zp_mvsec = &sector for THIS slot
        sta zp_mvsec
        lda MV_SECH,x
        sta zp_mvsec+1
        lda MV_STATE,x
        cmp #3
        beq ?rise                    ; 3 = a lift going back up, 1 = sliding
        cmp #1                       ;   down, 4 = creeping up to a target
        beq ?fall                    ;   (stairs), else 2 = dwelling at the bottom
        cmp #4
        beq ?climb
?dwell  lda MV_TIMER,x               ; the dwell counts VBLANKs, not frames
        sec
        sbc fps_n
        sta MV_TIMER,x
        bcc ?up                      ; underflowed -> time is up
        bne ?next
?up     lda #3
        sta MV_STATE,x
        lda #0
        sta MV_FRAC,x                ; start the rise on a whole unit
        jsr snd_q_pstart             ; DOOM sfx_pstart: the lift sets off again
?next   ldx mv_slot                  ;   (T_PlatRaise, waiting -> up)
        dex
        bpl ?slot
        rts
?climb  jsr mv_raiseg                ; = mv_raise + the T_MoveFloor grind
        jmp ?next                    ;   (sound.asm: BOTH movers blocks are full,
                                     ;   so the grind hangs off retargeted jsrs)
?rise   jsr mv_step                  ; m_b = whole units this frame (MV_FRAC
                                     ;   keeps the Q8 remainder)
        ldx mv_slot
        clc                          ; raising: floor += delta
        ldy #0
        lda (zp_mvsec),y
        adc m_b
        sta m_a
        iny
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
        lda #0
        sta MV_STATE,x               ; idle, ready for the next crossing
        jsr snd_q_pstop              ; DOOM sfx_pstop: back at the top
?store  ldy #0
        lda m_a
        sta (zp_mvsec),y
        iny
        lda m_a+1
        sta (zp_mvsec),y
        jmp ?next
?fall   jsr mv_stepg                 ; the descent, mirror of ?rise: DOOM slides
        ldx mv_slot                  ;   the floor down at the same speed, and
        sec                          ;   the pstop has to come when it LANDS --
        ldy #0                       ;   for the lift ~1.1 s after the pstart
        lda (zp_mvsec),y             ;   (152 units at 2.8/VBLANK). mv_stepg =
                                     ;   mv_step + the STAY-floor grind
                                     ;   (T_MoveFloor); a lift slides silently
        sbc m_b
        sta m_a
        iny
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
        jsr snd_q_pstop              ; ...and thunk (DOOM sfx_pstop: T_PlatRaise
        ldx mv_slot                  ;   down -> waiting, T_MoveFloor pastdest)
        lda MV_STAY,x
        bmi ?stay                    ; W1 floor: stays down, this slot is done
        lda #MV_WAIT_VB              ; DOOM 3 s of dwell, counted in VBLANKs
        sta MV_TIMER,x               ;   from the landing, like p_plats.c
        lda #2
        sta MV_STATE,x               ; a lift dwells, then rises
        bne ?store                   ; (A=2: always)
?stay   lda #0
        sta MV_STATE,x
        beq ?store                   ; (A=0: always)
.endp
    .if * > MOVERS2_END+1
        ert 'the floor engine outgrew MOVERS2_BASE..END (memory_map.inc)'
    .endif
        org mv2_resume

;==============================================================
; update_scroll -- p_spec.c's "ANIMATE LINE SPECIALS" (special 48, scrolling
; wall left): sides[line->sidenum[0]].textureoffset += FRACUNIT every tic.
; The port has no per-seg u offset to add to, so it walks the TEXTURE'S BASE
; ADDRESS through VRAM instead -- one column (h bytes) at a time. pack_textures
; stores a scrolling wall's pixels TWICE end to end, so a column read up to
; w-1 columns past the base still lands inside the copy; at w columns the base
; jumps back and the loop is seamless. Cost per frame: one 24-bit add. Cost per
; drawn column: nothing at all.
;   DOOM moves 1 texel/tic = 35 texels/s, and half_cols already halved the
;   width, so that is 17.5 STORED columns/s = 0.35 per PAL VBLANK = Q8 90.
;   MAP_HSCRTEX is the level's scrolling texid ($FF = it has none).
;==============================================================
SCROLL_Q8   equ 90
usc_resume = *
        org SCROLL_BASE
.proc update_scroll
        ldx MAP_HSCRTEX
        bmi ?out                     ; $FF: nothing scrolls on this level
        ldy fps_n                    ; the VBLANKs this frame took
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
        bne ?fwd                     ; (always)
?wrap   lda #0                       ; rewind the whole width: from column wmask
        sta ts_col                   ;   back to column 0 is wmask*stride bytes
    .if TEX_RUNS
        lda #2*TEX_RUNK              ; a PAINTED column is a fixed run record,
    .else                            ;   not h pixels (paint.asm)
        lda MAP_TEXH,x
    .endif
        sta m_a
        lda MAP_TEXWMASK,x
        sta m_b
        lda #0
        sta m_a+1
        sta m_b+1
        jsr umul16
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
    .if * > SCROLL_END+1
        ert 'update_scroll outgrew SCROLL_BASE..SCROLL_END (memory_map.inc)'
    .endif
        org usc_resume

;--------------------------------------------------------------
; trig_exit -- p_spec.c P_CrossSpecialLine's two exit cases, in front of
;   trig_walk: `case 52: G_ExitLevel()` and `case 124: G_SecretExitLevel()`.
;   Byte 3 of the record (its pad -- pack_things WALK_EXITS) says which one:
;   0 = an ordinary record, 1 = EXIT, 2 = SECRET EXIT.
;
;   WHY IT EXISTS AT ALL. The EXIT bit the packer puts on a seg is read in ONE
;   place, use_leaf -- the USE ray. That covers the S1 switch exits (E1 and E2),
;   but the whole of episode 3 and E2M9 end on a W1 WALKOVER line (E3M6's is the
;   teleport-looking alcove at ld596, reported 2026-08-27) and walking over one
;   did nothing at all: check_triggers only ever sees lines that HAVE a trigger
;   record, and an exit drives no mover so it never had one. It has one now,
;   for this test alone.
;
;   Parked out here because TRIGW ($E580) is full -- check_triggers' `jsr
;   trig_walk` is RETARGETED to this rather than a call being added, so neither
;   block grows a byte (the trick automap.asm's four gates and walk_init use).
;--------------------------------------------------------------
tgx_resume = *
        org TRIGEXIT_BASE
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
?walk   jmp trig_walk                ; the call this routine displaced
.endp
    .if * > TRIGEXIT_END+1
        ert 'trig_exit outgrew TRIGEXIT_BASE..END (memory_map.inc)'
    .endif
        org tgx_resume

;==============================================================
; trig_walk -- what a CROSSED line does. Everything except a teleport is
; trig_fire's business (doors + floors); special 97 moves the PLAYER instead of
; a sector, so p_telept.c EV_Teleport lives here:
;   * "Don't teleport if hit back of line, so you can get out of the
;     teleporter" -- mv_crossed already saved the side the player came FROM in
;     mv_s1, and cross_pos returns 1 for DOOM's side 0 (front).
;   * the destination is the MT_TELEPORTMAN thing (doomednum 14) standing in
;     the tagged sector. pack_things.py resolves it at build time into an
;     8-byte record (i16 x, i16 y, u8 BAM angle) -- the SAME field order as
;     zp_px/zp_py/zp_ang, so landing is one 5-byte copy. The record's "dst"
;     word is the index into that table, at THINGS_BASE+14.
;   * mv_ox/mv_oy get the destination too. check_triggers is mid-scan and the
;     records after this one would otherwise test a movement segment reaching
;     clear across the map -- and fire every line it happens to cross.
; 97 is WR (repeatable), so no fired-bitmap bit is spent.
;==============================================================
tgw_resume = *
        org TRIGW_BASE
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
        sta m_prod                   ;   again once mv_crossed returned) walks
        lda #0                       ;   the table, so zp_ptr stays valid for
        sta m_prod+1                 ;   check_triggers' next record
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1                 ; index * 8
        clc
        lda m_prod
        adc THINGS_BASE+14
        sta mv_ss
        lda m_prod+1
        adc THINGS_BASE+15
        sta mv_ss+1
        ldy #3
?cp     lda (mv_ss),y                ; x,y -> the player AND the frame's "where
        sta zp_px,y                  ;   I was", so no later record sees a
        sta mv_ox,y                  ;   crossing (a teleport is not a walk)
        dey
        bpl ?cp
        ldy #4
        lda (mv_ss),y
        sta zp_ang                   ; thing->angle, BAM like MAP_HSANG
        jmp pl_tele                  ; the SFX and P_Teleport's thing->z = floorz,
                                     ;   both in the FALL block: this one had no
                                     ;   room and ran into en_bkill
?out    rts                          ; zp_pz follows in update_pz, as after any
.endp                                ;   move
    .if * > TRIGW_END+1
        ert 'trig_walk outgrew TRIGW_BASE..TRIGW_END (memory_map.inc)'
    .endif
        org tgw_resume

;==============================================================
; update_damage -- p_spec.c P_PlayerInSpecialSector, once per frame.
; The nukage/slime floors: DOOM charges the player 5/10/20 health every 32 tics
; (0.914 s) while he STANDS in the sector -- and the port's eye always sits on
; the floor (update_pz), so its "has he hit the ground yet" test is free.
;   * the damage class is b1-b3 of the sector's flag byte (pack_map.py DMG).
;   * it costs no point location: update_pz has just run locate_floor, which
;     leaves zp_ptr on &MAP_SECTORS[sector under the player].
;   * the damage goes through en_plr_hurt, exactly like a monster's: it is
;     P_DamageMobj(player->mo, NULL, NULL, damage) in DOOM too, so the armour
;     (pl_armsub, below), the grunt, the face and the death are all shared.
;   * class 4 is sector special 11, E1M8's finale: 20 per tic AND G_ExitLevel
;     once health drops to 10 or less. E1M8 carries no exit linedef whatsoever,
;     so without this the level simply cannot be finished.
;   * at 0 health DOOM kills the player and G_DoReborn restarts the map;
;     init_level is exactly that restart (spawn point, doors shut, W1 bitmap
;     cleared) minus the SIO reload, so collected items stay collected.
;==============================================================
dmg_resume = *
        org DMGSEC_BASE
.proc update_damage
        lda pl_dead                  ; P_PlayerThink hands a PST_DEAD player to
        bne ?safe                    ;   P_DeathThink and RETURNS, so
                                     ;   P_PlayerInSpecialSector never runs on a
                                     ;   corpse: the nukage stops burning it and,
                                     ;   above all, stops grunting every 32 tics
                                     ;   (the "EH" over and over after the death
                                     ;   scream). ?safe also re-arms dmg_timer.
        ldy #7
        lda (zp_ptr),y               ; sector flags: b0 sky, b1-b3 damage class
        and #$0E
        beq ?safe
        lsr
        tax                          ; 1 nukage, 2 slime, 3 super, 4 = E1M8 end
        lda dmg_timer                ; the tic counts VBLANKs, like the doors
        sec
        sbc fps_n
        sta dmg_timer
        bcs ?out                     ; not due yet
        lda #DMG_VB
        sta dmg_timer
        jsr pw_shield                ; the radiation suit / invulnerability decide
        bcs ?out                     ;   whether this tic lands at all (powerups.asm)
        lda dmg_amt,x                ; P_DamageMobj(player->mo, NULL, NULL, dmg):
        jsr en_plr_hurt              ;   armour, health, the grunt, the face and
                                     ;   the death, all of it the monsters' path
                                     ;   (enemy.asm). X survives it -- neither
                                     ;   en_plr_hurt nor pl_hurtfx touches it.
        cpx #4
        bne ?out
        lda PSTATE+PS_HEALTH         ; "if (player->health <= 10) G_ExitLevel()"
        cmp #11                      ;   -- it used to compare what pl_hurtfx
        bcs ?out                     ;   handed back, which is the DAMAGE (20),
        lda #1                       ;   so the E1M8 finale sector could never
        sta EXIT_REQ                 ;   fire the exit at all
?out    rts
?safe   lda #DMG_VB                  ; stepping off re-arms the whole delay
        sta dmg_timer
        rts
.endp

;--------------------------------------------------------------
; pl_armsub -- P_DamageMobj's armour block (p_inter.c:854-869), the one place
;   the port models it. Sits here because en_plr_hurt's own block has room for
;   the jsr and nothing more.
;     IN  A = damage
;     OUT A = what got through (the caller subtracts it from health), armour
;         points and pl_armt updated. X is untouched, C is NOT meaningful.
;   armortype 1 (green) eats damage/3, 2 (blue) damage/2, and never more points
;   than it has left -- when the last point goes, so does the type, exactly as
;   DOOM's "armor is used up" branch does.
;--------------------------------------------------------------
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
;   b2 counting -> subtract the frame's VBLANKs; at zero, open it again
;                (direction = 1 + sfx_doropn) and clear the bits.
; DOOM re-runs the whole cycle on every WR crossing, and it does here too: the
; trigger just re-arms b1.
;==============================================================
d30_resume = *
        org DOOR30_BASE
.proc update_door30
        ldx MAP_HNDOOR
        beq ?ret
        dex
?l      lda.l DOORSTAY,x
        and #$06
        beq ?nx
        lsr
        lsr                          ; C = b2, the countdown is already running
        bcs ?cnt
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
        sbc fps_n
        sta.l DOOR_WAIT,x
        bcs ?nx
        lda.l DOOR_FRAC,x            ; borrowed into the high half. No read-
        sec                          ;   modify-write in place any more: the
        sbc #1                       ;   65816 gives long,X to the accumulator
        sta.l DOOR_FRAC,x            ;   group only, so DEC long,X does not
        cmp #$FF                     ;   exist. A still holds the new value.
        bne ?nx
        lda #0
        sta.l DOOR_FRAC,x            ; no stale Q8 remainder for the rise
        lda #1                       ; 30 s up: send it back up -- and PARK it
        sta.l DOORSTAY,x             ;   open. p_doors.c removes the thinker when
                                     ;   a close30ThenOpen reaches the top, so it
                                     ;   must NOT dwell and close again.
        lda #1
        sta.l DOOR_STATE,x
        inc DOOR_NACT
        lda #SFX_DOROPN
        jsr snd_q_door_at
?nx     dex
        bpl ?l
?ret    rts
.endp
    .if * > DOOR30_END+1
        ert 'update_door30 outgrew DOOR30_BASE..DOOR30_END (memory_map.inc)'
    .endif
        org d30_resume
