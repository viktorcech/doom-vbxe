;--------------------------------------------------------------
; RAM BUDGET: 1257 B free, biggest contiguous block 253 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------
; AUTO-SPLIT from renderer.asm -- assembled in place via icl (org wrap stays in renderer.asm).

;==============================================================
; DOORS (M6) -- DR open/wait/close. Static config in MAP_DOORS (.bin); runtime
; state in DOOR_* RAM. The engine animates MAP_SECTORS[door_sec].ceil between
; closed (=sector floor) and open (=MAP_DOORS open_ceil); the renderer + collision
; pick up the changing ceiling automatically. (In the $1B00 relocation block.)
;   MAP_DOORS layout: n in the header (MAP_HNDOOR); records are 4 B each:
;   u8 sector_id, u8 deny_sector ($FF = none), i16 open_ceil.
;   MAP_DSND: a parallel 4 B record -- i16 soundorg_x, i16 soundorg_y (the sector
;   bbox centre, P_GroupLines-style; snd_q_door_at attenuates by distance to it).
;   It is a SEPARATE table and not bytes +4..+7 of the door record because both
;   readers index with `txa / asl.. / tay`: at 8 B a stride, door 32 and up sends
;   Y past 255 and the record read wraps to the wrong door. Four bytes reaches 63.
;   MAP_DOORLOCK: a parallel byte per record -- bits0-2 = the PS_KEYS bit the
;   door needs (0 = unlocked), bit7 = D1 opens-once-stays-open (use_door_go).
;
; SPEED: every derived quantity (the &MAP_SECTORS[sec] pointer, open_ceil, the
; sector id) used to be recomputed from the .bin on every frame -- a x8 multiply
; by shifts, twice per moving door, plus a x4 record index. They are constants
; for the whole level, so init_doors hoists them into DOOR_SECL/OPNL/SIDL once
; and the per-frame path is pure table reads. DOOR_NACT then lets update_doors
; return on a single load in the (overwhelmingly common) all-doors-closed case.
;--------------------------------------------------------------
; m_x4 / m_x8 -- m_prod = m_a * 4 (or * 8), the index-to-byte-offset scale in
;   front of every MAP_* table lookup. It was written out seven times (three
;   times *4, four times *8) in collision.asm and doors.asm: 114 B of the same
;   six shifts. Exact substitution -- `rts` leaves A and the flags alone, so a
;   caller still gets m_prod's high byte in A and the last `rol`'s flags.
;   Homed HERE and not in collision.asm because collision's two blocks are the
;   ones that needed the bytes back.
;--------------------------------------------------------------
.proc m_x4
        lda m_a
        asl
        sta m_prod
        lda m_a+1
        rol
        sta m_prod+1
        asl m_prod
        rol m_prod+1
        rts
.endp

.proc m_x8
        jsr m_x4
        asl m_prod
        rol m_prod+1
        rts
.endp

;--------------------------------------------------------------

; The tables are sized by MAP_NDOORS (the CAP over the levels in this build); the
; runtime arrays are DOORS_NMAX entries wide in Rapidus bank $01 at DOOR_EXT --
; see memory_map.inc. Nothing reports an overrun at runtime, so assert both here:
; the cap has to fit the arrays, and the arrays have to fit the kilobyte DOOR_EXT
; reserves below TH_HPL.
; NOTE the loops below all run to the LEVEL's own door count (MAP_HNDOOR, from the
; map header), not to the cap: the padding records are zeroes, and walking them
; would register phantom doors on sector 0 and flatten it.
        .if MAP_NDOORS > DOORS_NMAX
                ert 'MAP_NDOORS > DOORS_NMAX -- widen the DOOR_EXT block (memory_map.inc)'
        .endif
        .if DOORSTAY+DOORS_NMAX > DOOR_BASE+$400
                ert 'the DOOR_* arrays outgrew DOOR_EXT and would reach TH_HPL'
        .endif


; door_index_of + door_toggle sit at DOORIDX_BASE ($06B7, the hole behind
; give_bonus): the $1B00 block is full, and these two are small and cold (one
; runs per crossed seg on a USE press, the other once per press).
di_resume = *
        org DOORIDX_BASE
.proc door_index_of                  ; m_a = sector id -> A = door index, or $FF
        ldx MAP_HNDOOR               ; this LEVEL's door count (0 -> straight out)
        beq ?no
        dex                          ; a compare per door -- no record maths at all
?l      lda.l DOOR_SIDL,x            ; ONE byte: a sector id is one (250 is the
        cmp m_a                      ;   biggest map in episode 1), so the high
        beq ?yes                     ;   half never said anything -- and the byte
?nx     dex                          ;   it used to live in is DOOR_DENY now
        bpl ?l
?no     lda #$FF
        rts
?yes    txa
        rts
.endp

.proc door_toggle                    ; A = door index -> DR toggle its state
        tax
        lda.l DOOR_STATE,x
        beq ?wake                    ; closed (idle) -> opening: one more live door
        cmp #3
        beq ?open                    ; closing -> opening (reverse); already counted
        lda #3                       ; opening / open -> closing
        sta.l DOOR_STATE,x
        rts
?wake   inc DOOR_NACT
?open   lda #1
        sta.l DOOR_STATE,x
        rts
.endp
    .if * > CLIP_BASE
        ert 'door_index_of/door_toggle overran $06B7-$06FF and would clobber CLIP_BASE'
    .endif
        org di_resume                ; back to the $1B00 block

;--------------------------------------------------------------
; init_doors -- all doors closed (cur = ceil = floor) AND build the per-level
;   tables the frame loop reads: sector pointer, open_ceil, sector id.
;--------------------------------------------------------------
.proc init_doors
        lda #0                       ; USE not pressed (so first press is a rising edge)
        sta DOOR_TRIGPREV
        sta DOOR_NACT                ; nothing animating yet
        sta btn_timer                ; no SR button mid-flip from the old level
        sta face_t                   ; face picks on the first frame
        lda #1                       ; paint the shared bar once
        sta hud_dirty                ;   (w3d hud_dirty model -- see hud.asm)
        lda #HUD_FACE
        sta face_cur                 ; doomguy starts looking straight ahead
        lda RTCLOK3                  ; prime the VBLANK clock: the first frame must
        sta fps_last                 ;   see a small delta, not "since power-on"
        ldx MAP_HNDOOR               ; this LEVEL's door count (see the note above)
        beq ?nodoors
        dex
?l      txa                          ; door record @ MAP_DOORS + X*4
        asl                          ;   (u8 sector, u8 deny, i16 open_ceil).
        asl                          ;   The soundorg pair is MAP_DSND's own
        tay                          ;   4 B record -- see snd_q_door_at.
        lda MAP_DOORS,y              ; sector id -> DOOR_SIDL (+ m_a for the maths)
        sta.l DOOR_SIDL,x
        sta m_a
        lda #0
        sta m_a+1
        lda MAP_DOORS+1,y            ; the byte the sector id's high half left:
        sta.l DOOR_DENY,x            ;   the face USE is refused from (use_leaf)
        lda MAP_DOORS+2,y            ; open_ceil -> DOOR_OPNL/H
        sta.l DOOR_OPNL,x
        lda MAP_DOORS+3,y
        sta.l DOOR_OPNH,x
        jsr m_x8                     ; zp_ptr = MAP_SECTORS + sec*8  (once per level)
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        sta.l DOOR_SECL,x
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        sta.l DOOR_SECH,x
        lda #0
        sta.l DOOR_STATE,x
        sta.l DOOR_WAIT,x
        sta.l DOOR_FRAC,x            ; no Q8 leftover yet
        sta.l DOORSTAY,x             ; no switch parked it open yet (trig_fire)
        ldy #2                       ; cur = the ceiling the MAP ships. A normal
        lda (zp_ptr),y               ;   DOOM door has ceilingheight ==
        sta.l DOOR_CURLO,x           ;   floorheight, i.e. shut, so this is the
        iny                          ;   old "cur = ceil = floor" for every one
        lda (zp_ptr),y               ;   of them -- but a close-30 door (16/76,
        sta.l DOOR_CURHI,x           ;   E1M6) starts OPEN, and forcing it shut
                                     ;   would wall the level off.
        dex
        bpl ?l
?nodoors
        rts
.endp

;--------------------------------------------------------------
; update_doors -- advance every door by the TIME the last frame took.
;   DOOM's T_VerticalDoor runs on 35 Hz tics: VDOORSPEED = 2 units/tic and
;   VDOORWAIT = 150 tics. The port's frame rate is neither fixed nor 35 Hz, so
;   the move is scaled by the VBLANKs elapsed since the previous frame
;   (DOOR_SPEED_Q8 = 1.4 units per PAL VBLANK, Q8) and the dwell counts VBLANKs.
;   Q8 leftovers are kept per door in DOOR_FRAC, so slow frames do not round the
;   fractional 0.4 away.
;   A closing door also honours T_MovePlane's `crushed` result (p_floor.c): if the
;   player is standing in this door's sector and the step would leave less than
;   PLAYER_H of opening, the ceiling stays put and the door goes back UP, exactly
;   like p_doors.c:151-165 for a `normal` door.
;--------------------------------------------------------------
;--------------------------------------------------------------
; frame_dt -- dt_vbl = VBLANKs the previous frame took (1..DOOR_DTMAX). Called once
;   per frame from the main loop, BEFORE anything that animates: doors and lifts
;   both scale their motion by it, so DOOM's 35 Hz tic rate survives any frame
;   rate (5 fps on a stock 800XL, far more on a Rapidus).
;--------------------------------------------------------------
.proc frame_dt
        lda RTCLOK3                  ; RTCLOK3 wraps at 256 -- so does the subtract,
        sec                          ;   so only a frame longer than 5 s confuses it
        sbc fps_last
        bne ?dt
        lda #1                       ; same jiffy (very fast frame) -> count 1
?dt     cmp #DOOR_DTMAX+1            ; a load hitch must not fling a door open
        bcc ?ok
        lda #DOOR_DTMAX
?ok     sta dt_vbl
        lda RTCLOK3
        sta fps_last
        lda dt_vbl                    ; DOOR_STEP/DOOR_FADD = SPEED_Q8 * dvb, once per
        sta m_a                      ;   frame: update_movers doubles it (PLATSPEED*4)
        lda #0                       ;   and update_doors uses it as it is
        sta m_a+1
        lda #<DOOR_SPEED_Q8
        sta m_b
        lda #>DOOR_SPEED_Q8
        sta m_b+1
        jsr umul16
        lda m_prod+1
        sta DOOR_STEP
        lda m_prod
        sta DOOR_FADD
        jmp plr_steps                ; + the player's speed/turn for this frame
.endp

;--------------------------------------------------------------
; plr_steps -- PLR_STEP/TRN_STEP for this frame: the ORIGINAL fixed per-frame
;   amounts (SPD=24 units, TURN=3 BAM). The PSPD_Q8*dt_vbl time scaling of
;   2026-07-28 was reverted the same day: at the real frame rates it moved and
;   turned several times faster than the fixed step ever did (unplayable), and
;   move_player's halfway collision probe assumes a step <= 24 anyway.
;   Still frame_dt's tail, so doors/lifts keep their own dt_vbl scaling.
;   Parked in the $FBC0 hole: the doors block is full.
;--------------------------------------------------------------
plrs_resume = *
        org PSTEP_BASE
.proc plr_steps
        lda #SPD
        sta PLR_STEP
        ; --- THE SLOW TURN (g_game.c G_BuildTiccmd). DOOM keeps `turnheld`, the
        ;     number of tics a turn key has been down, and turns at angleturn[2]
        ;     -- HALF speed -- while it is under SLOWTURNTICS. Those 6 tics are
        ;     0.17 s, which is about ONE frame at this port's rate, so the port's
        ;     version is "the first frame of a press turns slowly". That frame
        ;     steps ONE BAM: the whole point of it is aiming, and 1 BAM is the
        ;     finest angle an 8-bit BAM can express (memory_map.inc TURN_SLOW).
        ;     Tap the stick to walk the crosshair one BAM at a time; hold it and
        ;     the normal 3.75 BAM/frame takes over from the second frame.
        ;     NOTE the phasing: read_input consumes TRN_STEP at the TOP of the
        ;     next frame, so what is decided here is the step the NEXT frame will
        ;     turn by. "No turn key down now" therefore ARMS the slow step for a
        ;     press that has not started yet. ---
        ldx #0                       ; the turnheld to store back
        lda stick_save               ; bit 2 = left, bit 3 = right, 0 = pressed;
        and #$0C                     ;   $0C = neither -> turnheld = 0, exactly
        cmp #$0C                     ;   like G_BuildTiccmd's else branch
        beq ?arm
        ldx trn_held                 ; 0 = the press started THIS frame, i.e. it
        beq ?first                   ;   has already turned its one slow BAM
        bne ?full                    ; (always: turnheld is 0 or 1)
?first  inx                          ; turnheld = 1 -> full speed from here on
        ; --- TURN = TURN + TURN_FADD/256 BAM per frame, carried as a Q8 fraction
        ;     so the sub-BAM part is not lost (the DOOR_STEP/DOOR_FADD pattern
        ;     right above). Still PER FRAME, i.e. still frame-rate dependent --
        ;     deliberately; the rate and the one knob are in memory_map.inc. ---
?full   stx trn_held
        lda trn_acc
        clc
        adc #TURN_FADD
        sta trn_acc                  ; (sta keeps the carry)
        lda #TURN
        adc #0                       ; the fraction's carry -> a 4-BAM frame
        sta TRN_STEP
        jmp ?run
?arm    stx trn_held                 ; nothing held -> turnheld = 0 (X is 0) and
        lda #TURN_SLOW               ;   the next press starts with ONE BAM
        sta TRN_STEP                 ; (trn_acc is left alone: a whole-BAM step
?run                                 ;  has no fraction to carry)
        lda SKSTAT                   ; DOOM's run key: SHIFT doubles forwardmove
        and #SK_SHIFT                ;   (0x19 -> 0x32). The port takes a SECOND
        bne ?out                     ;   24-unit step rather than one 48-unit
        jmp move_player              ;   step, because move_player's halfway
?out    rts                          ;   collision probe only holds for step<=24
.endp                                ;   (gap 12 < PLAYER_R). frame_dt tail-calls
                                     ;   us AFTER the frame's first move_player
                                     ;   and BEFORE check_triggers, so a crossing
                                     ;   still sees the whole frame's travel.
;--------------------------------------------------------------
; skipx_ref -- move_player's between-axes cur_floor refresh. Grounded: a
;   committed X step may have raised the player (stairs), so the Y step-up is
;   measured from where he ACTUALLY stands now (matches gui pos_ok, which
;   probes floor_at(px,py) live). Airborne: the reference is his FEET and a
;   horizontal step never moves them -- keep what pl_airmove set. Parked in
;   plr_steps' block: it outgrew the FALL block (bsp_main_player.asm).
;--------------------------------------------------------------
.proc skipx_ref
        lda pl_air
        bne ?out
        jsr locate_floor
        lda loc_floor
        sta cur_floor
        lda loc_floor+1
        sta cur_floor+1
?out    rts
.endp
    .if * > PSTEP_END+1
        ert 'plr_steps/skipx_ref outgrew PSTEP_BASE..END (memory_map.inc)'
    .endif
        org plrs_resume

.proc update_doors
        lda DOOR_NACT                ; nothing is moving -> the whole scan is skippable
        bne ?go
        rts
?go     jsr door_at_point            ; which door sector is the player in? (crush test;
        sta DOOR_PLR                 ;   one BSP descent per frame, doors moving only)
        ldx MAP_HNDOOR               ; loop control sits AHEAD of the body so the
        beq ?ret                     ;   idle path is all short branches
        dex
?l      lda.l DOOR_STATE,x
        bne ?act
?next   dex
        bpl ?l
?ret    rts
?act    lda.l DOOR_SECL,x            ; zp_ptr = &sector (built by init_doors)
        sta zp_ptr
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        clc                          ; this door's move = STEP + the Q8 carry
        lda.l DOOR_FRAC,x
        adc DOOR_FADD
        sta.l DOOR_FRAC,x
        lda DOOR_STEP
        adc #0
        jsr crush_pre                ; stores DOOR_DELTA, halves it for a SLOW
                                     ;   crusher (CEILSPEED is half VDOORSPEED)
                                     ;   and comes back with DOOR_STATE in A
        cmp #1
        beq ?opening
        cmp #2
        bne ?closing
        jmp ?dwell                   ; (out of branch range past the crush test)
?closing
        ; --- closing: new = cur - delta; floor clamp, then the crush test ---
        sec
        lda.l DOOR_CURLO,x
        sbc DOOR_DELTA
        sta m_ma                     ; m_ma = the ceiling this frame WOULD reach
        lda.l DOOR_CURHI,x
        sbc #0
        sta m_ma+1
        ldy #0                       ; floor @ sector+0
        sec
        lda m_ma
        sbc (zp_ptr),y
        sta m_a
        iny
        lda m_ma+1
        sbc (zp_ptr),y               ; new - floor <= 0 ? -> reached closed
        sta m_a+1
        bmi ?shut
        ora m_a
        beq ?shut
        lda m_a+1                    ; opening >= 256 -> everything under this
        bne ?move                    ;   ceiling still fits (P_ThingHeightClip)
        lda m_a
        cmp #PLAYER_H
        bcs ?move
        cpx DOOR_PLR                 ; ...it does not. The player under it?
        bne ?crmon
        jsr door_crush               ; a normal door goes back up and stops here;
        bcs ?crmon                   ;   a CRUSHER hurts him instead, and the
        jsr crush_things             ;   fast one keeps coming down
        jmp ?next                    ; (cur untouched -> nothing to write)
?crmon  jsr crush_things             ; P_ChangeSector: the MONSTERS under it too
?move   lda m_ma
        sta.l DOOR_CURLO,x
        lda m_ma+1
        sta.l DOOR_CURHI,x
        jmp ?writ
?shut   ldy #0
        lda (zp_ptr),y
        sta.l DOOR_CURLO,x
        iny
        lda (zp_ptr),y
        sta.l DOOR_CURHI,x
        ldy #1                       ; a CRUSHER turns straight round and rises
        lda #0                       ; a door PARKS shut: one less to scan next
        jsr door_end                 ;   frame (door_end gives DOOR_NACT back)
        jmp ?writ                    ; (other doors may still be live -- no branch trick)
?opening ; cur += delta, clamp to open, then state=open + dwell timer
        clc
        lda.l DOOR_CURLO,x
        adc DOOR_DELTA
        sta.l DOOR_CURLO,x
        lda.l DOOR_CURHI,x
        adc #0
        sta.l DOOR_CURHI,x
        sec
        lda.l DOOR_CURLO,x
        sbc.l DOOR_OPNL,x
        lda.l DOOR_CURHI,x
        sbc.l DOOR_OPNH,x
        bmi ?writ                    ; cur < open -> keep rising
        lda.l DOOR_OPNL,x            ; cur >= open -> clamp open, dwell
        sta.l DOOR_CURLO,x
        lda.l DOOR_OPNH,x
        sta.l DOOR_CURHI,x
        ldy #3                       ; a CRUSHER reverses at the top instead --
        lda #2                       ;   no dwell, and DOOR_WAIT keeps its speed
        jsr door_end                 ;   class (p_ceilng.c T_MoveCeiling case 1)
        jmp ?writ
?dwell  lda.l DOORSTAY,x             ; a switch parked this door OPEN (103/2 --
        bne ?writ                    ;   p_doors.c case open: thinker removed)
        lda.l DOOR_WAIT,x            ; the dwell counts VBLANKs, not frames
        sec
        sbc dt_vbl
        sta.l DOOR_WAIT,x
        bcc ?dwend                   ; underflowed -> time is up
        bne ?writ
?dwend  lda #3                       ; dwell over -> closing
        sta.l DOOR_STATE,x
        lda #SFX_DORCLS              ; positional: a far door closes quietly or
        jsr snd_q_door_at            ;   not at all (X survives)
?writ   ldy #2                       ; write cur -> sector ceil (@ +2)
        lda.l DOOR_CURLO,x
        sta (zp_ptr),y
        iny
        lda.l DOOR_CURHI,x
        sta (zp_ptr),y
        jmp ?next
.endp

;--------------------------------------------------------------
; door_at_point -- descend to the subsector at (zp_px,zp_py); return A = index of
;   the door whose sector CONTAINS the point (the subsector's own front sector is in
;   MAP_DOORS), or $FF if none. Only "inside the door sector" counts -- NOT merely
;   bordering one -- so the ray-walk in try_use triggers the door it actually enters,
;   not a far door that just happens to wall the player's current (large) subsector.
;
;   A subsector is convex and belongs to ONE sector, so every one of its segs
;   carries the same front_sec: the old loop over all n_segs asked the same
;   question up to a dozen times per probe (and try_use fires 16 probes on one
;   frame). Read seg 0 and answer.
;--------------------------------------------------------------
;--------------------------------------------------------------
; use_locate -- descend the BSP from the root to the leaf containing
;   (zp_px, zp_py); OUT: zp_nid = that subsector id (bit15 set).
;   Shared by door_at_point and try_use's subsector walk. Parked at USELOC_BASE:
;   the doors block is full to the byte at $FBC0 (plr_steps), and this is cold.
;--------------------------------------------------------------
ul_resume = *
        org USELOC_BASE
.proc use_locate
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
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
        jmp ?w
?leaf   rts
.endp
    .if * > USELOC_END+1
        ert 'use_locate outgrew USELOC_BASE..END (memory_map.inc)'
    .endif
        org ul_resume

; --- the USE-press quartet (door_at_point / use_leaf / use_sample / try_use)
;     ran here in the ambient stream, which happened to be $FA00-$FBB7 --
;     exactly where SQ2H_UROM wanted to live. All four fire once per USE
;     press, so win2 prices them at nothing (DAPUSE_BASE, 2026-08-31).
dap_resume = *
        org DAPUSE_BASE
.proc door_at_point
        jsr use_locate
        lda zp_nid                   ; ssptr = MAP_SSECT + (nid&7FFF)*4
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4
        clc
        lda m_prod
        adc #<MAP_SSECT
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SSECT
        sta zp_ptr+1
        ldy #2                       ; n_segs == 0 -> nothing to read, no door
        lda [zp_ptr],y
        iny
        ora [zp_ptr],y
        beq ?none
        ldy #0                       ; first seg index
        lda [zp_ptr],y
        sta m_a
        iny
        lda [zp_ptr],y
        sta m_a+1
        jsr m_x8                     ; zp_sptr = MAP_SEGS + first*SEG_SIZE
        clc
        lda m_prod
        adc #<MAP_SEGS
        sta zp_sptr
        lda m_prod+1
        adc #>MAP_SEGS
        sta zp_sptr+1
        ldy #SEG_FRONT               ; front_sec: the sector this subsector IS
        lda [zp_sptr],y
        sta m_a
        lda #0
        sta m_a+1
        jmp door_index_of            ; tail call -> A = door index, or $FF
?none   lda #$FF
        rts
.endp



;--------------------------------------------------------------
; use_leaf -- test every seg of the subsector in zp_nid against the USE ray.
;   OUT: A = door index if a crossed seg is a door line ($FF = none),
;        USE_BLK = 1 if a crossed seg blocks the ray.
;   This is DOOM's PTR_UseTraverse over the linedefs the ray crosses:
;     * a SPECIAL line never blocks and activates its door -- the .bin has no
;       linedef specials, so the stand-in is "two-sided seg with a door sector on
;       either side" (exact on E1M1: no two-sided non-special line touches one);
;     * any other crossed line stops the ray if it is one-sided, or if its
;       opening is <= 0 (P_LineOpening) -- "can't use through a wall".
;   A door is reported immediately (specials win); blocking is only reported
;   after the whole leaf, so a door line in the same leaf still wins.
;--------------------------------------------------------------
.proc use_leaf
        jsr leaf_segs                ; zp_sptr / zp_segcnt = this leaf's segs
                                     ;   (the body is parked in the POWER block:
                                     ;    this one was full to four bytes, which
                                     ;    is what lifting it out bought back)
?loop   lda zp_segcnt
        ora zp_segcnt+1
        beq ?none
        jsr use_seg_hit
        beq ?next                    ; ray does not cross this seg
        ldy #SEG_LOW                 ; bit7 = EXIT line (pack_map.py EXIT_SPECIALS:
        lda [zp_sptr],y              ;   DOOM specials 11/51/52/124, the S1 switch at
        bpl ?noexit                  ;   the end of a level). The switch sits on a
        ldy #SEG_FRONT               ;   one-sided wall, so the ray stops here anyway
        lda [zp_sptr],y              ;   -- the flag is all we need. main acts on it
        sec                          ;   after the frame is flipped; the swtchx
        sbc MAP_HSECS                ;   click comes from snd_q_nowayx.
        cmp #2                       ; ...and WHICH exit is the sector key
        bcs ?nsecr                   ;   (pack_map._secret_sector): the secret one
        lda MAP_HNEXTS               ;   owns MAP_HSECS and, for a two-sided line,
        sta MAP_HNEXT                ;   the sector behind it. $FF when the map has
?nsecr  lda #1                       ;   no secret exit -- and there MAP_HNEXTS
                                     ;   equals MAP_HNEXT, so the $FF key
                                     ;   wrapping onto sector 0 cannot matter.
        sta EXIT_REQ                 ; G_SecretExitLevel is then just this copy:
?noexit                              ;   exit_level AND wi.asm both read MAP_HNEXT,
                                     ;   and the map slot is untouched until
                                     ;   exit_level streams the next level.
                                     ;   Before this, pack_map gave a map with a
                                     ;   secret exit ONE next_level (its M9) for
                                     ;   BOTH doors, so finishing E1M3 the normal
                                     ;   way landed in E1M9 instead of E1M4.
        jsr switch_match             ; THE LINE'S OWN SPECIAL COMES FIRST. p_map.c
        bcs ?fired                   ;   :1099 PTR_UseTraverse tests
                                     ;   line->special and goes straight to
                                     ;   P_UseSpecialLine; what stands BEHIND the
                                     ;   line never enters into it. This test used
                                     ;   to sit AFTER the door one below, which
                                     ;   holds until the switch sits on the very
                                     ;   door it opens -- E2M1's ld288 (special 29,
                                     ;   tag 19) is the WEST FACE of door sector
                                     ;   35, so door_index_of answered "door" and
                                     ;   returned before switch_match ever saw the
                                     ;   seg. That door is remote-only, so
                                     ;   use_door_go's bit5 only said "oof": the
                                     ;   skull switch next to the platform one did
                                     ;   nothing at all (2026-08-19, (776,-1031)).
                                     ;   46 switch faces in E1-E3 are shaped like
                                     ;   this; the ones on an unlocked door that
                                     ;   also has a PUSH line came open anyway,
                                     ;   through the DR toggle, which is why only
                                     ;   the remote-only ones ever looked broken.
        ldy #SEG_BACK                ; back_sec: none -> one-sided wall -> blocks
        lda [zp_sptr],y
        sta m_a
        cmp #NO_SECTOR
        beq ?block                   ; one-sided, and no switch on it -> a wall
        jsr door_index_of            ; back sector a door? (m_a still = back_sec)
        cmp #$FF
        beq ?plain
        tax                          ; THE SIDE THE DOOR OPENS FROM. p_switch.c
        ldy #SEG_FRONT               ;   P_UseSpecialLine: `if (side) return
        lda [zp_sptr],y              ;   false` -- a manual door answers the
        cmp.l DOOR_DENY,x            ;   FRONT sector of the line that carries the
        beq ?plain                   ;   special, and its other face has special 0
        txa                          ;   and only says "oof". pack_map names that
        rts                          ;   face's sector in DOOR_DENY, because a seg
                                     ;   cannot tell the two faces apart: BOTH
                                     ;   have the door as their back sector. This
                                     ;   used to open either way (and from INSIDE
                                     ;   the doorway, which DOOM refuses too) --
                                     ;   E1M2's secret door came open from the
                                     ;   wrong room, 2026-08-11
?plain  jsr use_shut                 ; not a switch face: does its opening block?
        beq ?next
?block  lda #1
        sta USE_BLK
?next   clc
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        lda zp_sptr+1
        adc #0
        sta zp_sptr+1
        lda zp_segcnt
        bne ?dec
        dec zp_segcnt+1
?dec    dec zp_segcnt
        jmp ?loop
?none   lda #$FF
        rts
?fired  lda #$FE                     ; a switch fired (its sound is queued):
        rts                          ;   stop the ray; try_use skips the toggle
.endp


;--------------------------------------------------------------
; use_sample -- A = distance n along the player's facing (0..USERANGE);
;   OUT: zp_px/zp_py = USE_PT_A + n*(cos,sin) -- where DOOM's trace would be.
;   Every sample is derived from the ORIGIN, never from the previous sample: the
;   truncated 4-unit step is only 3.16 units long at 22.5 deg, and repeating it 16
;   times left the ray 14 units short of USERANGE -- 1.8 % of the sweep in
;   tools/_verify_useray.py missed a door DOOM opens (97.9 % vs 99.6 %).
;--------------------------------------------------------------
.proc use_sample
        sta m_ma                     ; keep n (smul_14 eats m_a)
        sta m_a
        lda #0
        sta m_a+1
        lda zp_cos
        sta m_b
        lda zp_cos+1
        sta m_b+1
        jsr smul_14                  ; m_res = n*cos
        clc
        lda USE_PT_A
        adc m_res
        sta zp_px
        lda USE_PT_A+1
        adc m_res+1
        sta zp_px+1
        lda m_ma
        sta m_a
        lda #0
        sta m_a+1
        lda zp_sin
        sta m_b
        lda zp_sin+1
        sta m_b+1
        jsr smul_14                  ; m_res = n*sin
        clc
        lda USE_PT_A+2
        adc m_res
        sta zp_py
        lda USE_PT_A+3
        adc m_res+1
        sta zp_py+1
        rts
.endp

;--------------------------------------------------------------
; try_use -- DOOM P_UseLines (p_map.c). Walk a ray USERANGE units forward, visit
;   the subsectors it passes through in order, and in each one test the segs the
;   ray CROSSES: activate the first door line, stop at the first wall.
;
;   The old probe only asked "did a sample land inside a door sector", so it
;   happily opened doors through walls -- 4.84 % of the sweep in
;   tools/_verify_useray.py. Testing crossings instead: 99.61 % identical to
;   P_UseLines (0.21 % opens DOOM would not, 0.18 % missed, 0 wrong doors).
;
;   The 16 steps only ENUMERATE subsectors now (the crossing test always uses the
;   whole ray), so consecutive duplicates are skipped and both ray endpoints stay
;   loop constants.
;--------------------------------------------------------------
.proc try_use
        lda zp_px                    ; USE_PT_A = the real player position (the walk
        sta USE_PT_A                 ;   moves zp_px/zp_py, the BSP descent reads it)
        lda zp_px+1
        sta USE_PT_A+1
        lda zp_py
        sta USE_PT_A+2
        lda zp_py+1
        sta USE_PT_A+3
        lda #USE_STEP*USE_NSTEPS     ; USE_PT_B = the ray END, USERANGE ahead
        jsr use_sample
        lda zp_px
        sta USE_PT_B
        lda zp_px+1
        sta USE_PT_B+1
        lda zp_py
        sta USE_PT_B+2
        lda zp_py+1
        sta USE_PT_B+3
        lda #$FF                     ; default: no door found
        sta USE_DOOR
        sta USE_SS                   ; no subsector tested yet ($FFFF is not a leaf id)
        sta USE_SS+1
        lda #0
        sta USE_BLK
        sta USE_N                    ; sample the player's own subsector first (n = 0)
?loop   lda USE_N                    ; zp_px/zp_py = A + n * facing
        jsr use_sample
        jsr use_locate               ; zp_nid = leaf at (zp_px, zp_py)
        lda zp_nid                   ; same leaf as last step -> nothing new to test
        cmp USE_SS
        bne ?test
        lda zp_nid+1
        cmp USE_SS+1
        beq ?step
?test   lda zp_nid
        sta USE_SS
        lda zp_nid+1
        sta USE_SS+1
        jsr use_leaf                 ; A = door index, USE_BLK = hit a wall
        cmp #$FF
        bne ?hit
        lda USE_BLK
        bne ?restore                 ; "can't use through a wall"
?step   clc                          ; next sample, USE_STEP further along the ray
        lda USE_N
        adc #USE_STEP
        sta USE_N
        cmp #USE_STEP*USE_NSTEPS+1   ; still within USERANGE -> keep walking
        bcc ?loop
        bcs ?restore                 ; ray exhausted, no door
?hit    jsr gun_seg_p                ; use_leaf stopped ON the crossed seg: the 46
        bcc ?nogun                   ;   line opens NOTHING by hand, from either
        lda #$FE                     ;   side, and says nothing either -- p_map.c
?nogun  sta USE_DOOR                 ;   :1099 sounds noway ONLY for a line with no
?restore                             ;   special, and 572 has one. $FE is try_use's
                                     ;   silent stop (the switch-fired path)
        lda USE_PT_A                 ; restore the real player position
        sta zp_px
        lda USE_PT_A+1
        sta zp_px+1
        lda USE_PT_A+2
        sta zp_py
        lda USE_PT_A+3
        sta zp_py+1
        lda USE_DOOR
        cmp #$FF
        beq ?none
        cmp #$FE                     ; a switch line fired -- its action queued
        beq ?swit                    ;   its own sound, and there is no DR door
        jmp use_door_go              ; A = door index -> key check, then DR/D1 open
?none   jmp snd_q_nowayx             ; wall: DOOM's "uh-uh" -- unless the wall
?swit   rts                          ;   was the EXIT switch (then swtchx)
.endp
    .if * > DAPUSE_END+1
        ert 'door_at_point..try_use outgrew DAPUSE_BASE..END (memory_map.inc)'
    .endif
        org dap_resume

;--------------------------------------------------------------
; use_door_go -- A = door index the USE ray hit. EV_VerticalDoor's key gate
;   (p_doors.c:186-244), the same shape as w3d Cmd_Use: MAP_DOORLOCK[door]
;   bits0-2 = the PS_KEYS bit this door needs (blue=1 yellow=2 red=4, card and
;   skull share a bit like P_CheckKeys), 0 = unlocked. Missing key -> DOOM's
;   "oof" (w3d: NOWAYSND), door untouched. Bit7 = D1 type (specials 31-34):
;   the door opens once and PARKS open (p_doors.c case open removes the
;   thinker), so it force-opens with DOORSTAY instead of the DR toggle.
;   A special-46 door needs no bit here: try_use refuses the LINE (gun_seg_p),
;   which is where DOOM refuses it too, and never gets as far as the door.
;--------------------------------------------------------------
udg_resume = *
        org USEDOORGO_BASE
.proc use_door_go
        tax
        lda MAP_DOORLOCK,x           ; (under-ROM read: USE runs after rom_out)
        and #$27                     ; key bits 0-2 -- plus bit5, "this door has
                                     ;   no PUSH line at all" (pack_map _doors).
                                     ;   DOOM only ever runs P_UseSpecialLine on
                                     ;   the LINE you bumped, and a remote door's
                                     ;   own lines carry special 0, so
                                     ;   PTR_UseTraverse just plays sfx_noway
                                     ;   (p_map.c) -- E1M5's sector 82, the one
                                     ;   the SW1STONE switch at ld189 opens, came
                                     ;   open under the spacebar here. Bit5 can
                                     ;   never coincide with a key bit (keys only
                                     ;   exist on manual lines), so ANDing the
                                     ;   keys below turns it into exactly that
                                     ;   refusal, for no extra byte.
        beq ?open
        and PSTATE+PS_KEYS           ; the one required key bit present?
        beq ?locked
?open   lda MAP_DOORLOCK,x
        bpl ?dr
        lda #1                       ; D1: park OPEN forever once used
        sta.l DOORSTAY,x
        jmp door_force_open.dfo_go   ; X = door index; open + positional SFX.
                                     ;   PAST the b9 test: there is no trigger
                                     ;   record here, and reading one out of a
                                     ;   stale zp_ptr shut the door instead
                                     ;   (see door_force_open's header)
?dr     txa
        jmp snd_door_toggle          ; DR: the normal toggle + open/close SFX
?locked jmp snd_q_noway              ; no key -> "uh-uh", nothing moves
.endp
    .if * > USEDOORGO_END+1
        ert 'use_door_go outgrew USEDOORGO_BASE..END (memory_map.inc)'
    .endif
        org udg_resume

;==============================================================
; SWITCHES (S1/SR) + walkover doors -- 1:1 with _pomocne/_doomsrc:
;   p_switch.c P_UseSpecialLine:  103 S1 EV_DoDoor(open)   62 SR EV_DoPlat(DWU)
;                                  29 S1 EV_DoDoor(normal)  63 SR EV_DoDoor(normal)
;   p_spec.c  P_CrossSpecialLine:   2 W1 EV_DoDoor(open)    90 WR EV_DoDoor(normal)
;   p_doors.c T_VerticalDoor case open: the thinker is REMOVED when fully open
;   -> the door stays open forever = DOORSTAY here.
; The trigger records come from pack_things.py; a USE record carries the seg
; RECORD ADDRESSES of its switch line, so matching is a compare, not geometry.
;==============================================================

;--------------------------------------------------------------
; switch_match -- is the crossed seg (zp_sptr) a USE-activated trigger line?
;   (b14. A GUN record, b8, carries no b14 and is invisible here on purpose --
;   gun_match owns those, off the seg a BULLET stopped on.)
;   Fires every matching record (a tag can move several sectors). C=1 if any
;   fired. Preserves zp_sptr/zp_segcnt (use_leaf's loop); clobbers A/X/Y+zp_ptr.
;--------------------------------------------------------------
swf_resume = *
        org SWFIRE_BASE
.proc switch_match
        lda #0
        sta sw_hit
        sta mv_i
?loop   lda mv_i
        cmp THINGS_BASE+13           ; trigger count
        bcs ?done
        jsr mv_used_get              ; a spent S1 button? (C=1 -> skip)
        bcs ?nx
        jsr mv_ptr                   ; zp_ptr = the record
        ldy #13
        lda (zp_ptr),y
        and #$40                     ; b14 = USE-activated
        beq ?nx
        ldy #4                       ; 4 seg-record address slots @ bytes 4..11
?slot   lda (zp_ptr),y
        cmp zp_sptr
        bne ?ns
        iny
        lda (zp_ptr),y
        cmp zp_sptr+1
        beq ?hit
        dey
?ns     iny
        iny
        cpy #12
        bcc ?slot
        bcs ?nx                      ; always
?hit    ldy #13
        lda (zp_ptr),y
        sta sw_fl                    ; flags: b12 once = S1, clear = SR button
        jsr trig_fire                ; keeps mv_i/zp_ptr
        inc sw_hit                   ; only ever tested for "not zero"
?nx     inc mv_i
        jmp ?loop
?done   lda sw_hit
        beq ?no
        jsr sw_swap                  ; P_ChangeSwitchTexture (SW1 -> SW2)
        lda #SFX_SWTCHN              ; the click is AT the player -- and it wins
        sta snd_pending              ;   the single sound slot
        sec
        rts
?no     clc
        rts
.endp
sw_hit  dta 0

;--------------------------------------------------------------
; sw_swap -- P_ChangeSwitchTexture: flip the pressed seg's SW1 texid to its
;   SW2 mate (textab row MAP_TEXSWMATE, packed by pack_textures.py). Tries the
;   wall byte, then the lower (62 sits on lift fronts' lower texture). An SR
;   button (sw_fl b12 clear) arms the one button slot to flip back after
;   BUTTONTIME (update_button); S1 stays pressed forever.
.proc sw_swap
        ldy #SEG_WALL
        jsr ?try
        bcs ?arm
        ldy #SEG_LOW
        jsr ?try
        bcc ?out                     ; neither byte is a switch face
?arm    lda sw_fl
        and #$10                     ; b12 = once (S1)
        bne ?out
        lda zp_sptr                  ; SR: arm the (single) button slot
        sta btn_ptr
        lda zp_sptr+1
        sta btn_ptr+1
        lda sw_y
        sta btn_y
        lda btn_old
        sta btn_tex
        lda #BTN_VB
        sta btn_timer
?out    rts
;  Y = seg byte (SEG_WALL/SEG_LOW): texid in bits 0-5. C=1 if it swapped.
?try    sty sw_y
        lda [zp_sptr],y
        sta btn_old                  ; the whole byte, for the flip back
        and #$3F
        cmp #$3F                     ; $3F is "THIS SLOT HAS NO TEXTURE", not a
        beq ?nosw                    ;   texid -- and MAP_TEXSWMATE is TEX_COUNT
                                     ;   = 63 entries wide (0..62), so index $3F
                                     ;   reads the first byte of the NEXT row,
                                     ;   MAP_TEXIXLO[0]. That is never $FF, so
                                     ;   the wall probe "succeeded" on every
                                     ;   two-sided seg with no upper texture,
                                     ;   took the C=1 exit, and the switch face
                                     ;   on the LOWER byte was never looked at:
                                     ;   E2M8's four SW1EXIT stair switches
                                     ;   (also E1M8, E2M1/5/7, E3M1/2/4/9) fired
                                     ;   their action and never lit up.
                                     ;   p_switch.c matches TEXTURE NUMBERS
                                     ;   against switchlist and "no texture" (0)
                                     ;   is not one of them.
        tax
        lda MAP_TEXSWMATE,x          ; $FF = not a switch texture
        cmp #$FF
        beq ?nosw
        sta sw_t
        lda btn_old
        and #$C0                     ; keep the peg/blocking bits
        ora sw_t
        ldy sw_y
        sta [zp_sptr],y
        sec
        rts
?nosw   clc
        rts
.endp

;--------------------------------------------------------------
; trig_fire -- run the trigger record at zp_ptr: DOOR actions go to the door
;   state machine, the rest is a floor/plat for mv_start. Shared by
;   check_triggers (walkover) and switch_match (USE). Preserves mv_i/zp_ptr.
;--------------------------------------------------------------
.proc trig_fire
        ldy #13
        lda (zp_ptr),y
        and #$20                     ; b13 = DOOR action
        bne ?door
        jsr mv_free                  ; a slot for this record? mv_free also runs
        bcs ?go                      ;   EV_DoPlat's "if (sec->specialdata)
        rts                          ;   continue" -- all busy, or that sector is
                                     ;   already moving: drop this fire and do
                                     ;   NOT spend the once-bit (try again later)
?go     jsr mv_start                 ; stays-down floors mark the bitmap there
        jmp ?once
?door   lda (zp_ptr),y               ; (Y is still 13) b15 WITH b13 is not a door
        and #$80                     ;   at all -- a floor's "stays down" bit can
        beq ?nolt                    ;   never ride a door record, so the pair is
        jmp trig_light               ;   free to mean EV_LightTurnOn (p_spec.c
                                     ;   case 35). It spends the once-bit itself.
?nolt
        ldy #12                      ; door index from the tagged sector id
        lda (zp_ptr),y
        sta m_a
        lda #0                       ; byte 13 is ALL flags now (pack_things asserts
        sta m_a+1                    ;   <= 256 sectors). It used to be `and #$07`,
                                     ;   which handed a b9 record (16/76, door close
                                     ;   30 s) a high byte of 2 -> sector id + 512 ->
                                     ;   door_index_of missed and E1M6's three never
                                     ;   fired at all
        jsr door_index_of
        cmp #$FF
        bne ?have
        jmp trig_light               ; no door carries this tag: either the LIGHTS
                                     ;   action (b15 with b13, p_spec.c case 35)
                                     ;   or nothing at all -- trig_light tells
                                     ;   them apart and comes back to tl_once
?have
        tax
        ldy #14                      ; DST. A door record has never used it ("the
        lda (zp_ptr),y               ;   height is in MAP_DOORS"), so it is where
        beq ?nc                      ;   p_ceilng.c's action rides: 1 = 73
        jmp trig_crush               ;   crushAndRaise, 2 = 77 fast, 3 = 74 stop
?nc     dey                          ; ...and back to 13, the flags
        lda (zp_ptr),y
        and #$08                     ; b11 = the door parks OPEN (103 / type 2)
        beq ?fo
        lda #1
        sta.l DOORSTAY,x
?fo     jsr door_force_open
?once
tl_once ldy #13                      ; (trig_light comes back in here)
        lda (zp_ptr),y
        and #$10                     ; b12 = once -> spend the fired-bitmap bit
        beq ?out
        jmp mv_used_set
?out    rts
.endp
    .if * > SWFIRE_END+1
        ert 'switch_match/trig_fire outgrew SWFIRE_BASE..END (memory_map.inc)'
    .endif
        org swf_resume


;--------------------------------------------------------------
; trig_light -- p_spec.c case 35 / p_lights.c EV_LightTurnOn: every sector with
;   the line's tag takes a fixed light level (35, "Lights Very Dark"). The
;   packer emits one record per tagged sector, so this is one write; the level
;   itself rides in the record's dst field, where a floor keeps its height.
;   E1M3's blue key is the only place episode 1 uses it -- the room goes dark
;   the moment you pick the card up (2026-08-07).
;   zp_ptr = the record. Falls into the once-bit spend, like every other action.
;--------------------------------------------------------------
tl_resume = *
        org TRIGLT_BASE
.proc trig_light
        ldy #13                      ; b15 WITH b13 is no door at all -- a floor's
        lda (zp_ptr),y               ;   "stays down" bit can never ride a door
        and #$80                     ;   record, so the pair is free to mean
        beq tl_back                  ;   EV_LightTurnOn. Anything else here is a
                                     ;   tag with no door: nothing to do.
        lda #0                       ; zp_mvsec = &MAP_SECTORS[sector], the *8 in
        sta zp_mvsec+1               ;   the accumulator (250 sectors = 11 bits)
        ldy #12
        lda (zp_ptr),y
        asl
        rol zp_mvsec+1
        asl
        rol zp_mvsec+1
        asl
        rol zp_mvsec+1
        clc
        adc #<MAP_SECTORS
        sta zp_mvsec
        lda zp_mvsec+1
        adc #>MAP_SECTORS
        sta zp_mvsec+1
        ldy #14                      ; the LEVEL rides where a floor keeps its
        lda (zp_ptr),y               ;   height
        ldy #4                       ; sector->lightlevel
        sta (zp_mvsec),y
tl_back jmp trig_fire.tl_once        ; and spend the W1 bit
.endp
    .if * > TRIGLT_END+1
        ert 'trig_light outgrew TRIGLT_BASE..END (memory_map.inc)'
    .endif
        org tl_resume

;--------------------------------------------------------------

;--------------------------------------------------------------
; gun_seg_p / gun_match -- p_spec.c P_ShootSpecialLine, the half a DOOM episode
;   needs: special 46, GR "open door on impact". E1M2's secret computer wall
;   (linedef 572, tag 6 -> sector 188) is the only one in episode 1, so the
;   packer hands the engine ONE seg address instead of a table to scan.
;
;   BOTH halves of DOOM's rule live here, and the second one is why this is not
;   just gun_match:
;     * a BULLET opens it -- gun_match, off pf_shot's hitscan/melee trace. A
;       flying missile does not (P_ExplodeMissile activates no line), so the
;       rocket and plasma traces in proj.asm never call this.
;     * SPACE does not -- P_UseSpecialLine has no case 46, and PTR_UseTraverse
;       returns false on any special line without even the "oof". try_use asks
;       gun_seg_p and stops the ray silently.
;   That second half is a real difference in this port: sector 188 IS a door
;   (linedef 582 is a plain DR from the far side, which DOOM does let you push
;   by hand), and use_leaf's stand-in for "special line" is "the seg has a door
;   sector on one side" -- which cannot tell 572 from 582 on geometry alone.
;
;   Deviation, stated: DOOM fires the special for every special line the shot
;   CROSSES; this fires it for the one the shot STOPS on. The only 46 in
;   episode 1 is a shut door -- openrange 0, so the bullet stops there anyway.
;--------------------------------------------------------------
gm_resume = *
        org GUNMATCH_BASE
.proc gun_seg_p                      ; C=1 if zp_sptr is EITHER face of the 46
        pha                          ;   line. A survives (try_use still needs it)
        ldy #26                      ; the header's two seg record addresses. Both
?l      lda zp_sptr                  ;   sides: the shot comes from the room, but
        cmp THINGS_BASE,y            ;   USE from INSIDE the opened secret crosses
        bne ?nx                      ;   the other face of the same line -- and
        lda zp_sptr+1                ;   that is what let SPACE shut it again
        cmp THINGS_BASE+1,y
        beq ?yes
?nx     iny                          ; 0 on a level with no gun line, and no seg
        iny                          ;   record ever lives at $0000
        cpy #30
        bcc ?l
        pla
        clc
        rts
?yes    pla
        sec
        rts
.endp
    .if * > GUNMATCH_END+1
        ert 'gun_seg_p outgrew GUNMATCH_BASE..END (memory_map.inc)'
    .endif
        org gm_resume

gf_resume = *
        org GUNFIRE_BASE
.proc gun_match                      ; fire it: the record index is in the header too
        jsr gun_seg_p
        bcc ?out
        lda THINGS_BASE+30
        sta mv_i
        jsr mv_ptr                   ; zp_ptr = the trigger record
        jsr trig_fire                ; EV_DoDoor(open) + DOORSTAY (b11)
        ldx en_snd_q                 ; the DOROPN snd_q_door_at just queued is
        bpl ?out                     ;   about to be overwritten: wp_fire_a stores
        lda snd_pending              ;   the GUNSHOT into snd_pending after
        bmi ?out                     ;   en_gunshot returns. Move the door onto the
        ldx #$FF                     ;   other queue byte while it is free and
        stx snd_pending              ;   snd_dispatch starts both, each on its own
        sta en_snd_q                 ;   voice (SND_NV = 4)
?out    rts
.endp
    .if * > GUNFIRE_END+1
        ert 'gun_match outgrew GUNFIRE_BASE..END (memory_map.inc)'
    .endif
        org gf_resume

;--------------------------------------------------------------
; door_force_open -- X = door index: make it open (NOT the DR toggle: an
;   already-open door stays put). Queues the door-open sound.
;   Specials 16/76 (close 30 s, then open) come through here too -- b9 of the
;   trigger record, which trig_fire still has zp_ptr on, sends them DOWN
;   instead and arms update_door30 with DOORSTAY b1.
;
;   TWO ENTRIES, and the b9 read belongs to the FIRST one only. trig_fire has
;   zp_ptr on the record; use_door_go (a D1 door under the spacebar) has no
;   record at all -- zp_ptr is still on the vertex use_seg_hit/coll_vptr read
;   last, so (zp_ptr)+13 was a coin flip decided by which segs the USE ray
;   happened to cross. Bit1 set -> the press CLOSED the door: dorcls on an
;   already-shut door, nothing moves, and DOORSTAY b1 armed update_door30 on
;   top of it. E1M3's first door (ld995/996, sector 64, special 31) does it
;   whenever you stand off to one side or come at it at an angle; the middle
;   works because a different vertex answers. E1M1 never showed it -- it is
;   the one episode-1 map with no D1 line at all. D1 callers enter at dfo_go,
;   past the test (2026-08-11).
;--------------------------------------------------------------
dfo_resume = *
        org DFORCE_BASE
.proc door_force_open
        ldy #13                      ; TRIGGER-RECORD entry: zp_ptr = the record
        lda (zp_ptr),y
        and #$02                     ; b9 = the action CLOSES
        bne ?shut
dfo_go                               ; no-record entry: open, never close
        lda.l DOOR_STATE,x
        cmp #1
        beq ?out                     ; already opening
        cmp #2
        beq ?out                     ; already open (dwelling / parked)
        cmp #3
        beq ?rev                     ; closing -> reopen (still counted live)
        inc DOOR_NACT                ; closed -> wake it
?rev    lda #1
        sta.l DOOR_STATE,x
        lda #SFX_DOROPN              ; positional: a REMOTE door opens quietly
        jsr snd_q_door_at            ;   or silently (s_sound.c attenuation)
?out    rts
?shut   lda.l DOOR_STATE,x           ; already on its way down? leave it alone
        cmp #3
        beq ?out
        tay                          ; parked (0) -> it joins the live scan
        bne ?go
        inc DOOR_NACT
?go     lda #3
        sta.l DOOR_STATE,x
        lda.l DOORSTAY,x
        ora #2                       ; b1: update_door30 waits for the landing,
        and #$FE                     ;   then counts 30 s. b0 (parked open) has
        sta.l DOORSTAY,x             ;   to go or the dwell test never fires.
        lda #SFX_DORCLS
        jmp snd_q_door_at
.endp
    .if * > DFORCE_END+1
        ert 'door_force_open outgrew the DFORCE hole (memory_map.inc)'
    .endif
        org dfo_resume

;--------------------------------------------------------------
; update_button -- the SR button face flips back BUTTONTIME after the press
;   (p_spec.h: 35 tics = 1 s = 50 PAL VBLANKs). One slot; runs once per frame.
;--------------------------------------------------------------
btu_resume = *
        org BTNUPD_BASE
.proc update_button
        lda btn_timer
        bne ?run
        rts
?run    sec
        sbc dt_vbl
        bcs ?ok
        lda #0
?ok     sta btn_timer
        bne ?out
        lda btn_ptr                  ; time: put the SW1 byte back on the seg.
        sta zp_sptr                  ;   THROUGH zp_sptr, exactly like sw_swap
        lda btn_ptr+1                ;   wrote it in the first place: btn_ptr is
        sta zp_sptr+1                ;   only the seg's OFFSET, so the store has
        ldy btn_y                    ;   to be a LONG one into the seg bank
        lda btn_tex                  ;   (map_syms.inc:14, [[map-offsets-not-
        sta [zp_sptr],y              ;   addresses]] -- plain (zp),y here wrote
                                     ;   btn_tex into BASE RAM: seg 683, E1M4's
                                     ;   switch, is offset $1558, which is
                                     ;   tw_setup's CODE, and the write landed
                                     ;   there BTN_VB after the press).
                                     ;
                                     ; WHY zp_sptr AND NOT zp_ptr (2026-08-16).
                                     ;   This used to point zp_ptr at the seg by
                                     ;   storing MAP_SEG_BANK into zp_ptr+2 --
                                     ;   and never put it back. But zp_ptr+2 is
                                     ;   an engine-wide CONSTANT $01 that
                                     ;   init_level seeds ONCE: seg_draw, the
                                     ;   AI's bank-$01 pages (TH_KIND, TH_STATE,
                                     ;   TH_WROW, TH_HP...), infight, collision
                                     ;   and the door code all read [zp_ptr],y
                                     ;   assuming it -- the same trap wp_wload
                                     ;   documents for $04/$05. So BTN_VB after
                                     ;   ANY switch press, the whole engine
                                     ;   started reading thing kinds, monster
                                     ;   state and door state out of the SEG
                                     ;   bank. E1M8's start switch shows it
                                     ;   worst: wrot_idle reads TH_KIND = 0 for
                                     ;   every thing, spr_dyn takes the static
                                     ;   path, spr_one submits NO blit at all,
                                     ;   and the barrel room's 20 barrels + 4
                                     ;   pinkies vanish one second after the
                                     ;   wall drops -- with the doors dying in
                                     ;   the same breath.
                                     ;   zp_sptr ALREADY carries MAP_SEG_BANK,
                                     ;   set once per level by load_level
                                     ;   (diskio.asm) and touched by nobody
                                     ;   since (powerups.asm:284, midtex.asm),
                                     ;   and its low pair is rebuilt per
                                     ;   subsector by render_subsector -- so
                                     ;   borrowing it costs nothing and leaves
                                     ;   nothing to hand back. 4 bytes SMALLER
                                     ;   than the version that set a bank byte,
                                     ;   which matters: this block is full to
                                     ;   $CFFF and $D000 is hardware.
                                     ;   Measured: tools/tests/_dbg_e1m8_switch.py
        lda #SFX_SWTCHN              ; the button pops back out (p_switch.c)
        sta snd_pending
?out    rts
.endp
btn_timer dta 0                      ; VBLANKs left (0 = idle)
btn_ptr   dta 0,0                    ; seg record holding the flipped byte
btn_y     dta 0                      ; which byte (SEG_WALL / SEG_LOW)
btn_tex   dta 0                      ; the original byte to restore
btn_old   dta 0                      ; sw_swap scratch (original byte)
sw_y      dta 0
sw_t      dta 0
sw_fl     dta 0
    .if * > BTNUPD_END+1
        ert 'update_button outgrew BTNUPD (memory_map.inc)'
    .endif
        org btu_resume

;--------------------------------------------------------------
; snd_q_door_at -- queue a door SFX only if the door is AUDIBLE: p_doors.c
;   plays at the door sector's soundorg (bbox centre, MAP_DOORS record +4) and
;   s_sound.c cuts it dead past S_CLIPPING_DIST (1200). Distance here is
;   Chebyshev (max of the axes) -- up to 41 % short on diagonals, i.e. the cut
;   is a little generous there, which errs on the audible side.
;   A = SFX id, X = door index (preserved).
;--------------------------------------------------------------
sda_resume = *
        org SNDDIST_BASE
.proc snd_q_door_at
        sta sda_id
        stx sda_x
        txa
        asl
        asl                          ; MAP_DSND records are 4 B: {i16 x, i16 y}.
        tay                          ;   FOUR and not eight, so this index still
                                     ;   fits a byte at DOORS_NMAX 48 (47*4=188);
                                     ;   at the old 8 B stride it wrapped past 31
        sec                          ; m_a = |px - soundorg.x|
        lda zp_px
        sbc MAP_DSND+0,y
        sta m_a
        lda zp_px+1
        sbc MAP_DSND+1,y
        sta m_a+1
        bpl ?ax
        jsr m_neg
?ax     sec                          ; m_b = |py - soundorg.y|
        lda zp_py
        sbc MAP_DSND+2,y
        sta m_b
        lda zp_py+1
        sbc MAP_DSND+3,y
        sta m_b+1
        bpl ?ay
        jsr m_negb
?ay     lda m_a+1                    ; max(|dx|,|dy|) -> m_a (16-bit)
        cmp m_b+1
        bcc ?useb
        bne ?far
        lda m_a
        cmp m_b
        bcs ?far
?useb   lda m_b
        sta m_a
        lda m_b+1
        sta m_a+1
?far    sec                          ; dist >= 1200 -> inaudible: queue nothing
        lda m_a
        sbc #<1200
        lda m_a+1
        sbc #>1200
        bcs ?silent
        ldx sda_id                   ; PLAY it, do not queue it: snd_pending is
        jsr snd_play                 ;   one byte and spr_pickup runs later in
                                     ;   the same frame -- the key's ITEMUP
                                     ;   overwrote the secret opening behind it
                                     ;   and the door was silent (2026-08-07,
                                     ;   proved in the simulator). s_sound.c
                                     ;   starts every sound at once anyway, and
                                     ;   the mixer has SND_NV voices; only the
                                     ;   QUEUE was single-file. Same byte count,
                                     ;   and no new RAM -- the byte I added to
                                     ;   sound.asm's data for this broke the
                                     ;   build outright.
?silent ldx sda_x
        rts
.endp
sda_id  dta 0
sda_x   dta 0
    .if * > SNDDIST_END+1
        ert 'snd_q_door_at outgrew SNDDIST (memory_map.inc)'
    .endif
        org sda_resume

;==============================================================
; CRUSHERS -- p_ceilng.c EV_DoCeiling / T_MoveCeiling, on the door mover.
;
; The ceiling that comes down on your head, rises, and does it again for ever.
; Episodes 1-3 use three of DOOM's six crusher actions, all WR walkovers:
;   73  crushAndRaise      CEILSPEED     E2M2/E2M4/E2M6/E3M4/E3M5
;   77  fastCrushAndRaise  CEILSPEED*2   E2M2/E2M4
;   74  EV_CeilingCrushStop              every map that has one
; and until 2026-08-29 the port had none of them: the tagged sectors sat
; motionless, so E2M2's mincer corridor (the reported bug -- "drvice nefunguju",
; 91,-306, which is right on top of ld1564, a 77) was a walk-through.
;
; WHY IT IS A DOOR. The door mover already animates a sector CEILING between two
; heights at a VBLANK-scaled speed, already writes it back into MAP_SECTORS for
; the renderer and collision, and already has the "is the player under it" test
; (DOOR_PLR). A crusher is that machine with three answers changed, and each one
; is a jsr on a path that had the bytes to spare:
;   crush_pre    the SPEED (CEILSPEED is half the VDOORSPEED a door moves at)
;   door_crush   what happens when it catches the player: HURT, do not bounce
;   door_end     what happens at each end of the travel: REVERSE, never park
; plus the one thing a door never had to do at all:
;   crush_things P_ChangeSector's sweep -- the MONSTERS under it die too
; pack_map._doors gives the tagged sectors ordinary door records (open_ceil =
; the sector's own map ceiling, LOCK bit3 = CRUSH_BIT, bit5 = no PUSH line, so
; the spacebar and the monsters are refused exactly as on any remote-only door),
; and pack_things puts p_ceilng.c's action in the trigger record's dst.
;
; The whole block is parked at CRUSH_BASE: 384 B under the ROM that the map's
; HIGH region stopped needing when SSECTORS left for the Rapidus EXT bank.
;==============================================================
crush_resume = *
        org CRUSH_BASE

;--------------------------------------------------------------
; crush_pre -- A = the whole-unit ceiling step door X takes this frame.
;   Stores it as DOOR_DELTA, halves it for a SLOW crusher, and hands back the
;   door's STATE so update_doors can dispatch. It replaces the
;   `sta DOOR_DELTA / lda.l DOOR_STATE,x` that was there, so an ordinary door
;   pays one jsr and nothing else.
;   The halving is of the WHOLE part, after DOOR_FRAC has taken the Q8 carry, so
;   a slow crusher runs a few per cent under CEILSPEED rather than exactly on
;   it -- the alternative is a second 16-bit accumulate per door per frame, and
;   nobody can see 3.2 units a frame against 3.5 on a ceiling.
;--------------------------------------------------------------
.proc crush_pre
        sta DOOR_DELTA
        lda MAP_DOORLOCK,x           ; (under-ROM read: the frame loop banks the
        and #CRUSH_BIT              ;   OS ROM out -- bsp_main.asm's rom_out)
        beq ?out
        jsr snd_q_grind              ; T_MoveCeiling plays sfx_stnmov on
                                     ;   !(leveltime&7), which is snd_q_grind's
                                     ;   own gate (sound.asm) -- and it is
                                     ;   WEAK-queued, so the grind never eats a
                                     ;   real event. A crusher you cannot hear
                                     ;   coming is not the same trap DOOM sets.
                                     ;   Preserves X.
        lda.l DOOR_WAIT,x            ; the crusher's speed class: 0 = CEILSPEED,
        bne ?out                     ;   1 = CEILSPEED*2 (special 77)
        lsr DOOR_DELTA
?out    lda.l DOOR_STATE,x
        rts
.endp

;--------------------------------------------------------------
; door_crush -- the descending ceiling has caught the player (update_doors'
;   opening < PLAYER_H test). p_doors.c sends a `normal` door back UP, and that
;   is what T_MovePlane's `crushed` means for a door. A CRUSHER does not bounce:
;   T_MoveCeiling keeps it coming and PIT_ChangeSector takes health off whatever
;   is under it -- crushAndRaise drops to CEILSPEED/8 while it is crushing,
;   fastCrushAndRaise does not slow at all.
;   The port's CEILSPEED/8 is "hold still this frame", which at these frame
;   rates is the same picture and costs no state.
;   OUT: C=1 = go on moving (a fast crusher), C=0 = leave the ceiling alone.
;--------------------------------------------------------------
.proc door_crush
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        bne ?hurt
        lda #1                       ; an ordinary door: back up (p_doors.c:151)
        sta.l DOOR_STATE,x
        clc
        rts
?hurt   lda dt_vbl                   ; P_DamageMobj(player, NULL, NULL, 10) every
        asl                          ;   4 tics = CRUSH_DMG_VB a VBLANK, scaled
        jsr en_plr_hurt              ;   by the frame like every other timer
                                     ;   here. X survives it (enemy.asm) --
                                     ;   update_damage leans on the same fact
        lda.l DOOR_WAIT,x            ; slow -> CEILSPEED/8 -> stand still
        beq ?stop
        sec
        rts
?stop   clc
        rts
.endp

;--------------------------------------------------------------
; door_end -- door X has arrived at one end of its travel.
;   IN: A = the state an ORDINARY door takes there (2 = dwell at the top,
;           0 = parked shut)
;       Y = the state a CRUSHER takes instead (3 = straight back down at the
;           top, 1 = straight back up at the bottom)
;   A crusher never parks and never dwells, so it never gives DOOR_NACT back:
;   update_doors keeps scanning it for the rest of the level, which is exactly
;   what DOOM does by leaving the thinker in the list. That is the standing cost
;   of a running crusher -- the door scan plus door_at_point's one BSP descent,
;   and any moving door already pays both.
;--------------------------------------------------------------
.proc door_end
        pha
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        beq ?door
        pla
        tya                          ; the crusher's other direction
        sta.l DOOR_STATE,x
        rts
?door   pla
        sta.l DOOR_STATE,x           ; (A survives the store, for the cmp)
        cmp #2
        beq ?dwell
        dec DOOR_NACT                ; parked: one less to scan next frame
        rts
?dwell  lda #DOOR_DWELL_VB           ; the dwell counts VBLANKs
        sta.l DOOR_WAIT,x
        rts
.endp

;--------------------------------------------------------------
; trig_crush -- a crusher line was crossed (trig_fire, off the record's dst).
;   IN: A = 1 (73 crushAndRaise) | 2 (77 fastCrushAndRaise) | 3 (74 stop)
;       X = the door index the record's tagged sector maps to
;   EV_DoCeiling walks every sector with the line's tag and skips the ones
;   already running ("if (sec->specialdata) continue"); here the packer emits
;   one record per tagged sector, so the walk IS the trigger scan and the skip
;   is the DOOR_STATE test. A crusher that 74 put in stasis restarts DOWNWARD
;   rather than in the direction it was going -- P_ActivateInStasisCeiling
;   remembers that and this does not; the cost is one wrong half-cycle, once,
;   on a machine that then repeats for ever.
;--------------------------------------------------------------
.proc trig_crush
        cmp #3
        beq ?halt
        pha
        lda.l DOOR_STATE,x
        bne ?pull                    ; already running -> leave it alone
        inc DOOR_NACT                ; one more live ceiling for update_doors
        lda #3                       ; EV_DoCeiling: direction = -1, i.e. DOWN
        sta.l DOOR_STATE,x
        pla
        lsr                          ; dst 1 -> speed 0 (CEILSPEED),
        sta.l DOOR_WAIT,x            ;     dst 2 -> speed 1 (CEILSPEED*2)
        bpl ?out                     ; (always: the lsr cleared bit 7)
?pull   pla
?out    jmp trig_fire.tl_once        ; the tail every fired trigger ends on
?halt   lda.l DOOR_STATE,x           ; EV_CeilingCrushStop: park it where it
        beq ?out                     ;   stands, and stop scanning it
        dec DOOR_NACT
        lda #0
        sta.l DOOR_STATE,x
        beq ?out                     ; (always)
.endp

;--------------------------------------------------------------
; crush_things -- P_ChangeSector(sector, true) for the crusher whose door index
;   is X: the MONSTERS under the descending ceiling, not only the player.
;   p_map.c PIT_ChangeSector runs over the sector and, for every thing
;   P_ThingHeightClip cannot fit, takes 10 health off it every 4 tics; a thing
;   that is ALREADY dead becomes S_GIBS instead, and a dropped item is removed.
;   The port keeps the first of those three and states the other two: it has no
;   gib state to put a corpse into, and nothing it drops is in anyone's way.
;
;   The sweep is en_bthings' (A_Explode's), for the same reason -- the cheap
;   rejects come first and almost everything leaves on health 0 or "already
;   dying", so the linear walk costs about what a blockmap walk would once the
;   port's cells (512 units, WRAPPED into 8x8) have handed back their strangers.
;   What decides membership is door_at_point, which answers "which door's sector
;   is this point in" exactly, and is the same descent update_doors makes for
;   the player every frame anyway.
;
;   The caller has already established that the opening is under PLAYER_H, so
;   none of this runs until the ceiling is low enough to hurt something.
;   Preserves X and m_ma (the ceiling ?move is about to store) and rebuilds
;   zp_ptr, which door_at_point clobbers.
;--------------------------------------------------------------
.proc crush_things
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        bne ?go
?rts    rts                          ; an ordinary door crunches nobody here:
                                     ;   P_ChangeSector(crunch=false) only says
                                     ;   "no fit", and what this port does with
                                     ;   that is send the door back up
?go     stx ct_d
        lda m_ma                     ; ?move still wants the new ceiling, and
        sta ct_m                     ;   door_at_point/en_bhit own the maths
        lda m_ma+1                   ;   registers between here and there
        sta ct_m+1
        lda zp_px                    ; ...and the player's probe point, which
        sta ct_p                     ;   door_at_point reads
        lda zp_px+1
        sta ct_p+1
        lda zp_py
        sta ct_p+2
        lda zp_py+1
        sta ct_p+3
        lda #0
        sta en_bi
?lp     lda en_bi
        cmp THINGS_BASE              ; the thing count (blob header +0)
        bcs ?done
        ldy en_bi
        lda #<TH_HPL                 ; (every bank $01 page has low byte 0)
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        sta m_a
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora m_a
        beq ?next                    ; 0 health: a decoration, or already dead
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?next                    ; already dying -- PIT_ChangeSector gibs a
                                     ;   corpse; there is no gib state here
        lda en_bi                    ; its x/y -> the point to place
        jsr en_thing.en_th2
        ldy #0
        lda (sp_ptr),y
        sta zp_px
        iny
        lda (sp_ptr),y
        sta zp_px+1
        ldy #2
        lda (sp_ptr),y
        sta zp_py
        iny
        lda (sp_ptr),y
        sta zp_py+1
        jsr door_at_point            ; standing in THIS crusher's sector?
        cmp ct_d
        bne ?next
        lda dt_vbl                   ; the same 10-every-4-tics the player takes
        asl                          ;   (CRUSH_DMG_VB), scaled by the frame
        jsr en_bhit                  ; P_DamageMobj: health, death, the scream
?next   inc en_bi
        bne ?lp                      ; (always: the count is a byte)
?done   lda ct_p
        sta zp_px
        lda ct_p+1
        sta zp_px+1
        lda ct_p+2
        sta zp_py
        lda ct_p+3
        sta zp_py+1
        lda ct_m
        sta m_ma
        lda ct_m+1
        sta m_ma+1
        ldx ct_d                     ; update_doors' door index and its sector
        lda.l DOOR_SECL,x            ;   pointer, both of which the descent and
        sta zp_ptr                   ;   the damage above went through
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        rts
.endp
ct_d    dta 0                        ; the door being crushed under
ct_m    dta 0,0                      ; m_ma across the sweep
ct_p    dta 0,0,0,0                  ; the player's probe point across it
    .if * > CRUSH_END+1
        ert 'the crusher block outgrew CRUSH_BASE..END (memory_map.inc)'
    .endif
        org crush_resume
