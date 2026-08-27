;==============================================================
; enemy_ai.asm -- MONSTERS THAT WAKE UP AND COME AFTER YOU (2026-07-31).
;   p_enemy.c A_Look + A_Chase (P_NewChaseDir / P_TryWalk / P_Move). enemy.asm
;   owns damage and death; this file owns being alive.
;
; THE TIMING IS DOOM'S, EXACTLY. Every RUN state carries A_Chase as its action
; and P_SetMobjState runs a state's action on ENTRY, so a monster thinks once
; per RUN state -- info.c's own tics, straight out of doomstates.run_chain:
;   POSS/SPOS 4/3 tics, TROO 3, SARG 2, BOSS 3, HEAD 3, SKUL 6.
; mk_ctic carries that per kind, there is no cap on how many monsters chase at
; once, and there is no round-robin: a monster that is awake moves exactly as
; often as it does in DOOM.
;
; WHAT THAT COSTS, and why it is affordable: the per-tic sweep is the same
; 256-entry bank $01 walk en_tick already does (a read and a branch per thing),
; and the only real work is one collide_blocked per monster per its own state
; period -- the SAME BSP range query move_player runs three times a frame. A
; monster is only ever awake if the player has seen it, so the count that
; matters is "monsters on screen", not "monsters in the level".
;
; WAKING (A_Look). DOOM traces P_CheckSight from the monster. This port has a
; cheaper oracle that en_gunshot already leans on: the vissprite list. A
; vissprite is BY DEFINITION on screen and wall-clipped, so "the player can see
; it" is free and needs no trace. The divergence, stated plainly: a monster
; behind the player's back does not wake, where DOOM's would if IT could see the
; player. Once awake it stays awake, which is roughly what DOOM's `threshold`
; does anyway.
;
; NOT DOOM, deliberately:
;   * no attacks yet -- this is wake + chase. en_plr_hurt is already there and
;     info.c's melee/missile chains already parse (doomstates.atk_chain); what
;     is missing is VRAM for the attack frames (tools/_walk_budget.py).
;   * P_Move tests the PLAYER radius: collide_blocked is hard-wired to PLAYER_R
;     16, against info.c's 20 for the imp and 30 for the demon. A demon can hug
;     a wall closer than DOOM lets it.
;   * z follows the FLOOR, not a lift: after a step the thing is stood on the
;     destination sector's floor and P_TryMove's 24-unit up/down limits are
;     enforced (p_map.c 478/482), so stairs work. What is not modelled is
;     P_CheckPosition's ceiling test -- a monster will walk under something too
;     low for it rather than being turned back.
;   * (P_Move DOES open doors now -- ai_door, 2026-08-07. Only a plain DR one,
;     which is all P_UseSpecialLine gives a monster.)
;   * the walk cycle draws from however many images the level's VRAM afforded
;     (WTAB_N, 2 or 4 -- tools/_walk_budget.py): with 4 the animation is DOOM's
;     A,A,B,B,C,C,D,D, with 2 it is A,A,B,B,A,A,B,B. The STATE machine is 1:1
;     either way, so the movement never changes -- only how many legs you see.
;==============================================================
        ; PINNED FAST (2026-08-11): this block is per-frame hot and lives in
        ; fast win1 ON PURPOSE -- never move it back to win2 $8000-$BFFF
        ; (x11.2 fetch; that cost 6.2% of the frame). See bench/PROBLEM.md.
        org AI_BASE

;--------------------------------------------------------------
; ai_reset -- from init_level: nothing chases in a fresh level. Clearing
;   TH_WROW is what actually stops it -- everything else keys on that page.
;--------------------------------------------------------------
.proc ai_reset
        lda #$FF
        sta sl_th                    ; no corpse is sliding on a fresh level --
                                     ;   a stale index here would shove whatever
                                     ;   thing wears it now (en_slide)
        stz ai_dn                    ; nothing to re-attach either
        stz zp_ptr                   ; 65816 stz: every TH_ page is 256 B
                                     ;   aligned, so the low byte is 0
        lda #>TH_WROW                ; zp_ptr+2 is MAP_EXT_BANK already: init_level
        sta zp_ptr+1                 ;   sets it and nothing else writes it
        ldy #0
        tya
?clr    sta [zp_ptr],y
        iny
        bne ?clr
        jmp aif_reset                ; ...and nothing is angry at anything either
.endp

;--------------------------------------------------------------
; ai_wake -- A_Look, once per FRAME over the vissprites the BSP walk collected.
;   Runs in the game loop, not the render path, so clobbering zp_ptr is safe.
;--------------------------------------------------------------
.proc ai_wake
        ldx sp_n
        beq ?out
        jsr ai_bank                  ; TH_WROW page for the whole scan; the
?lp     dex                          ;   monster path below restores it
        bmi ?out
        lda vs_th,x
        sta ai_t
        tay
        lda [zp_ptr],y               ; TH_WROW: already chasing -> leave it
        bne ?lp
        lda #>TH_KIND                ; prefilled kind (en_kfill): a pickup or
        sta zp_ptr+1                 ;   decoration costs ONE read here, not
        lda [zp_ptr],y               ;   ai_ismon's four probes
        beq ?back
        jsr ai_ismon                 ; alive, and not already dying?
        beq ?back
        lda ai_noise                 ; the player SHOT: A_Look reads the
        bne ?wake                    ;   sector's soundtarget before it looks
                                     ;   anywhere, and that path has no angle
                                     ;   test at all (p_enemy.c:609)
        lda vs_flip,x                ; ...and is it even LOOKING this way?
        and #$03                     ;   A_Look's 180-degree test, for free:
        cmp #2                       ;   the SLOT spr_wrot picked while drawing
        bcs ?back                    ;   it this frame is the same octant rule
                                     ;   ai_front runs, so slots 0 and 1 (the
                                     ;   front and 3/4-front views) react and
                                     ;   the profile and the back do not.
                                     ;   Opening a door in front of a monster
                                     ;   with its back turned no longer wakes
                                     ;   it. A thing with no stored rotations
                                     ;   (the barrel, a front-only build) reads
                                     ;   0 here and behaves as it always did.
?wake   jsr ai_wseen                 ; ...and is its MIDDLE column open? then wake
?back   lda #<TH_WROW                ; the scan's page back (ai_ismon/ai_start
        sta zp_ptr                   ;   moved both bytes)
        lda #>TH_WROW
        sta zp_ptr+1
        jmp ?lp
?out    lda ai_noise                 ; the shot's alert fades. DOOM's is a
        beq ?done                    ;   soundtarget stored PER SECTOR by
        dec ai_noise                 ;   P_RecursiveSound and it never expires;
?done   rts                          ;   one global countdown is the stand-in
.endp                                ;   (see ai_noise).

;--------------------------------------------------------------
; ai_wseen -- ai_wake's tail, out in free RAM (the AI block has four bytes left).
;   X = the vissprite, ai_t = its thing: wake it only if the sprite's MIDDLE
;   column survived the nearer geometry.
;
;   spr_add keeps a sprite as soon as ONE of its columns is open, which is right
;   for DRAWING -- an imp round a corner really does show an arm. It is wrong for
;   SIGHT: P_CheckSight is a centre-to-centre trace and near a wall the centre is
;   exactly what the wall covers. Measured on E1M1 (tools/tests/_dbg_wakegap.py,
;   player 20 units off every solid linedef within reach of a monster, facing
;   it): 7 of 143 spots with NO line of sight woke the monster, and 6 of them had
;   1-3 of its 10-20 columns open with the middle one shut.
;
;   en_seen is the hitscan's window test and it takes a COLUMN, so this hands it
;   the middle of [xa..xb] -- xa the way spr_one rebuilds it, max(x1, 0).
;--------------------------------------------------------------
aiws_resume = *
        org AIWS_BASE
.proc ai_wseen
        lda #0
        ldy vs_x1h,x                 ; x1 < 0 -> the sprite starts off the left
        bmi ?mid                     ;   edge and xa is column 0
        lda vs_x1l,x
?mid    clc
        adc vs_xb,x                  ; (xa + xb) / 2: the add's carry IS the 9th
        ror                          ;   bit, and the ror rotates it back in
        sta en_col
        jsr en_seen
        beq ?out                     ; only an EDGE of it is past the wall: blind
        stx ai_vx                    ; ai_start clobbers wide, so save the
        jsr ai_start                 ;   vissprite cursor across it
        ldx ai_vx
?out    rts
.endp
    .if * > AIWS_END+1
        ert 'ai_wseen outgrew AIWS_BASE..AIWS_END (memory_map.inc)'
    .endif
        org aiws_resume

;--------------------------------------------------------------
; ai_front -- C=0 if thing ai_t is LOOKING AT the player, C=1 if the player is
;   behind it. p_enemy.c's P_LookForPlayers(actor, FALSE) drops a player more
;   than 90 degrees off the monster's own angle -- "behind back" -- unless he
;   is inside MELEERANGE, and A_Look is the only caller that passes FALSE.
;
;   Angles here are OCTANTS, so the rule is one the player can SEE: spr_wrot
;   draws the monster at rot = (octant(monster->player) - TH_DIR) & 7 and this
;   computes the same number, so a monster reacts exactly while it is drawn
;   showing its FRONT or 3/4-FRONT view (rots 7, 0, 1) and ignores you while
;   it shows a profile or its back (2..6). The cut is 67.5 degrees off its
;   nose where DOOM's is 90 -- an octant cannot split rot 2 down the middle,
;   and erring on the strict side is what "only when it sees me" means.
;
;   Until 2026-08-07 there was no test at all, and the header above says why:
;   the port drew rotation 1 only, so "a facing rule would be a rule the
;   player cannot see". Four stored views later it is one he can.
;
;   WAKING ONLY. A monster already chasing keeps chasing with the player
;   anywhere -- both callers test TH_WROW first (ai_wake's ?lp, ai_look's
;   ai_wk) -- which is DOOM: A_Look runs until the target is set, A_Chase
;   never gives it back for losing sight.
;
;   Clobbers A/X/Y, sp_ptr, zp_ptr and the swr_* render scratch (the AI owns
;   the frame by the time either caller runs).
;--------------------------------------------------------------
;--------------------------------------------------------------
; ai_door -- p_enemy.c P_Move's tail: a step P_TryMove refuses because a LINE
;   is in the way is not the end of it --
;       while (numspechit--) if (P_UseSpecialLine (actor, spechit[..], 0)) ...
;   -- and P_UseSpecialLine lets a monster work special 1 (a plain DR door)
;   and nothing else: not a switch, not an exit line, and EV_VerticalDoor
;   returns early for a non-player on the locked 32/33/34. So this needs no
;   ray and no guessing -- collide_leaf leaves zp_sptr ON the seg that
;   stopped the step, so the line under test IS the line DOOM would hand to
;   P_UseSpecialLine. If either of its sectors is a DR door, toggle it.
;
;   The step still counts as blocked, so A_Chase picks a new direction this
;   tic and walks in on a later one -- which is what DOOM looks like anyway,
;   since the door needs a second to lift out of the way.
;
;   MAP_DOORLOCK[door] != 0 covers BOTH refusals in one test: bits 0-2 are the
;   key a locked door wants (26/27/28) and bit7 is the D1 "open and stay"
;   (31-34). Only the all-zero entry is the special-1 door a monster may open.
;   Clobbers A/X/Y, m_a, m_prod. Called only on a blocked step.
;--------------------------------------------------------------
aidoor_resume = *
        org AIDOOR_BASE
.proc ai_door
        ldy #SEG_BACK
        lda [zp_sptr],y
        cmp #NO_SECTOR               ; one-sided wall: nothing behind it
        beq ?out
        sta m_a                      ; (door_index_of is a byte compare now)
        jsr door_index_of            ; the sector BEHIND the line a door? (only
        cmp #$FF                     ;   BEHIND: a leaf's segs all carry that
        beq ?out                     ;   leaf's own sector in front, so the
        tax                          ;   monster's side is the front one)
        lda MAP_DOORLOCK,x           ; locked or D1 -> EV_VerticalDoor drops a
        bne ?out                     ;   monster; only a plain DR opens
        ldy #SEG_FRONT               ; ...and the door's OTHER face carries no
        lda [zp_sptr],y              ;   special at all, which P_UseSpecialLine
        cmp.l DOOR_DENY,x            ;   answers with `default: return false` for
        beq ?out                     ;   a monster too -- its `if (side)` gate
                                     ;   runs BEFORE the !thing->player one, and
                                     ;   the monster list is 1/32/33/34 only. The
                                     ;   same byte the player's use_leaf tests
                                     ;   (doors.asm), 2026-08-11
        lda.l DOOR_STATE,x           ; "JDC: bad guys never close doors"
        beq ?go                      ;   (p_doors.c:249) -- shut: open it;
        cmp #3                       ;   closing: send it back up; already
        bne ?out                     ;   opening or open: LEAVE IT, or a
?go     txa                          ;   monster stood in the doorway would
        jmp snd_door_toggle          ;   toggle it shut every single tic
?out    rts
.endp
    .if * > AIDOOR_END+1
        ert 'ai_door outgrew AIDOOR_BASE..END (memory_map.inc)'
    .endif
        org aidoor_resume

aifront_resume = *
        org AIFRONT_BASE
.proc ai_front
        lda ai_noise                 ; the player SHOT: A_Look takes the
        beq ?look                    ;   sector's soundtarget FIRST and that
        clc                          ;   path tests no angle at all
        rts                          ;   (p_enemy.c:609) -- C=0, "heard it"
?look   jsr aif_oct                  ; the octant of monster -> its target,
        sta swr_dir                  ;   which for an IDLE one is the player
        lda #>TH_DIR                 ;   (TH_TARG 0, aif_reset); it also leaves
        jsr ai_get                   ;   swr_ax/ay = the |legs|, normalised
        sec
        sbc swr_dir                  ; TH_DIR - octant = -rot, and the front
                                     ;   set {7,0,1} is symmetric about 0, so
                                     ;   the sign costs nothing and saves the
                                     ;   push/pull round ai_get
        clc
        adc #1                       ; rots 7,0,1 -> 0,1,2
        and #7
        cmp #3                       ; C=0: it is facing you
        bcc ?out
        lda swr_ax                   ; "if real close, react anyway": DOOM
        ora swr_ay                   ;   prices that with P_AproxDistance, this
        cmp #MELEERANGE              ;   with max(|dx|,|dy|) -- and against a
                                     ;   POWER OF TWO the or IS the max compare.
                                     ;   oct_of normalised both to one byte and
                                     ;   a normalise always leaves the bigger
                                     ;   leg above 127, so a shifted pair can
                                     ;   never read as melee range.
?out    rts
.endp
    .if * > AIFRONT_END+1
        ert 'ai_front outgrew AIFRONT_BASE..END (memory_map.inc)'
    .endif
        org aifront_resume

;==============================================================
; A_Look's REAL half (2026-08-05, "nepriatelia ma vidia len ked sa na nich
; pozeram"). ai_wake above is the port's original stand-in: it walks the
; PLAYER's vissprite list, so a monster woke exactly when the player's camera
; was pointing at it. p_enemy.c does nothing of the sort --
;     A_Look -> P_LookForPlayers(actor, false) -> P_CheckSight(actor, player)
; -- a BSP trace from the MONSTER, with the camera nowhere in it.
;
; So: ai_look walks the thing table round-robin and spends ONE sight ray a
; frame on an idle monster, and ai_sight is P_CheckSight reduced to the test
; sh_leaf already implements for a bullet -- a one-sided line, or a two-sided
; one whose opening is shut.
;
; THE RAY ENDS AT THE MONSTER'S TARGET, not at the player (2026-08-25, sg_tgt
; below). p_enemy.c only ever writes P_CheckSight (actor, actor->target), and
; A_Look is the one caller where that target IS the player; building the ray to
; zp_px/zp_py unconditionally is what left infight.asm with no sight test to
; run. TH_SEEN carries whichever answer the ray found, so the widening costs no
; second ray -- only the four bytes of sg_pl, because sg_bsp borrows zp_px/zp_py
; for the walk and can no longer put the player back out of the ray's own end.
;
; Reductions, all deliberate:
;   * ONE ray a frame. DOOM runs A_Look for every idle monster every tic; here
;     only the monster the scan stops at gets one. The vissprite path stays as
;     the instant one: what the player can see, the monster there sees back the
;     same frame.
;     A ray is the only thing worth a frame, and that took fixing (2026-08-06,
;     "chrbtom k impovi a nereaguje": E1M2 (-2109,-623), the low west maze, imp
;     thing 165 175 units due north). ai_sight answered SEES from that exact
;     spot, and ai_look still took 25 frames -- five seconds -- to hand it the
;     ray: 17 of those went to monsters past the reach cull below, which says
;     "no" off two hi-byte compares WITHOUT WALKING ANYTHING, and 5 more to
;     scanning the 159 non-monsters twelve at a time. Every one of them was
;     charged a whole frame as if it had cost a ray, so the engine actually
;     spent 0.12 rays a frame where the design says one. Now the frame ends
;     only where a ray really ran (sg_n below) and the scan is one full lap of
;     the thing table: 25 frames -> 3 at that spot.
;     The price is the rays that used to be thrown away. Measured there
;     (tools/_dbg_framecost.py): ai_look 24k -> 230k cycles a frame, which is 9%
;     of the 2.5M that spot costs -- render_world is 2.26M of it. Not the 0.4%
;     the SG_LEAFN note quotes, but that note was pricing a frame that skipped
;     the work.
;   * the 180-degree test is BACK (2026-08-07, "enemies nemaju reagovat ked
;     otvorim dvere, ale iba vtedy, ked ma vidia spredu"). It was left out
;     while the port drew rotation 1 only -- "the monster always faces you",
;     so a facing rule would have been a rule the player cannot see. With the
;     four stored views it is one he can, so ai_front below gates BOTH waking
;     paths: opening a door in front of a monster whose back is turned no
;     longer wakes it. Once it IS chasing nothing takes that back, door or no
;     door -- exactly like DOOM, where only A_Look tests the angle.
;   * 1024 units of reach (ai_sight's cmp #4 -- the header used to claim 2048),
;     past which nothing wakes. DOOM has no such limit. It costs nothing now
;     that a culled monster no longer eats the frame, but it is still a real
;     difference: tools/_dbg_sightrange.py counts 12 clear E1M2 sightlines it
;     drops, so a monster across a long hall never notices you on its own.
;==============================================================
aiwake_resume = *
        org SIGHT_BASE
;--------------------------------------------------------------
; ai_sight -- C=1 if thing ai_t can see the player. Builds the ray
;   (USE_PT_A = the monster, USE_PT_B = the player) and the sample step, then
;   falls into sg_walk. Clobbers A/X/Y, sp_ptr, zp_px/zp_py (put back).
;--------------------------------------------------------------
.proc ai_sight
        lda #$FF                     ; no leaf tested yet ($FFFF is not a leaf
        sta USE_SS                   ;   id). Primed here and not in sg_walk:
        sta USE_SS+1                 ;   that block is full to the byte.
        jsr sg_tgt                   ; USE_PT_B = the monster's TARGET (its own
                                     ;   quarry, not always the player) and
                                     ;   sg_pl = the player, for sg_bsp's restore
        lda ai_t                     ; ...and the monster is its ORIGIN
        jsr en_thing.en_th2          ; sp_ptr = its record: x, y are +0..+3
        ldy #3
?mo     lda (sp_ptr),y
        sta USE_PT_A,y
        dey
        bpl ?mo
        ldx #0                       ; the vector, player - monster. The borrow
        lda #4                       ;   chains inside a leg and starts fresh on
        sta sg_t                     ;   each one, hence the sec on the even
?v      txa                          ;   bytes (sg_dy follows sg_dx). The counter
        and #1                       ;   is a MEMORY byte on purpose: cpx would
        bne ?nc                      ;   clobber the carry the hi byte needs, and
        sec                          ;   that put a phantom -256 in every leg
?nc     lda USE_PT_B,x               ;   whose difference was zero.
        sbc USE_PT_A,x
        sta sg_dx,x
        inx
        dec sg_t
        bne ?v
        lda sg_dx+1                  ; the bigger leg, to the nearest 256 units
        bpl ?px                      ;   (the sign folded away)
        eor #$FF
?px     sta sg_t
        lda sg_dy+1
        bpl ?py
        eor #$FF
?py     cmp sg_t
        bcs ?far
        lda sg_t
?far    cmp #4                       ; 1024 units and out: nothing notices you
        bcs ?no                      ;   that far off (DOOM has no such limit,
        jsr sg_set                   ;   but no E1 sightline is longer)
        jmp sg_bsp                   ; (sg_set: p_sight.c's z, for sh_leaf's sill
                                     ;  test -- and sp_ptr is still the monster's
                                     ;  record here, which is what it reads)
?no     clc
        rts
.endp

;--------------------------------------------------------------
; aif_pvis -- aif_isvis' player case (infight.asm): DOOM's
;   P_CheckMissileRange opens with P_CheckSight(actor, target) and the player's
;   camera is not in it -- a monster used to stop firing the moment you turned
;   your back. On screen still answers yes for free; off screen costs the ray,
;   and only for a monster that is already chasing.
;--------------------------------------------------------------
.proc aif_pvis
        jsr aif_pchk                 ; is there still a player to shoot at, and
        beq ?no                      ;   was it drawn this frame? (2026-08-20:
        bcs ?yes                     ;   the dead half -- see aif_pchk)
        lda #>TH_SEEN                ; off screen: the CACHED ray, the one
        jsr ai_get                   ;   ai_look spends a frame on. Running a
        lsr                          ;   fresh one here cost 250k cycles per
        rts                          ;   attack decision -- most of a frame.
?no     clc
?yes    rts
.endp
    .if * > SIGHT_END+1
        ert 'ai_sight/aif_pvis outgrew SIGHT_BASE..SIGHT_END (memory_map.inc)'
    .endif

        org SGSTK_BASE               ; the stack + counters (the old sg_walk hole)
SG_LEAFN equ 64                      ; leaves one ray may test before it gives up
                                     ;   and answers "blocked". The old sampled
                                     ;   walk needed 12 because it PAID for a leaf
                                     ;   per sample; the descent below visits each
                                     ;   crossed leaf once, so the ceiling can be
                                     ;   high enough never to fire on the shipped
                                     ;   geometry.
                                     ;
                                     ; 40 -> 64 (2026-08-25). The old value came
                                     ; with the note "measured max 17", taken when
                                     ; the port shipped EPISODE 1 ALONE; E2/E3
                                     ; landed 2026-08-18 and nothing re-measured
                                     ; it. tools/_dbg_sightcost.py now walks THIS
                                     ; tree with THIS descent over 219,468 rays on
                                     ; all 27 maps, and the real figures are:
                                     ;   deepest CLEAR ray   39 leaves (E1M6)
                                     ;   deepest ray at all  40 leaves
                                     ; -- so 40 was not wrong, it was ONE LEAF of
                                     ; headroom, and 138 of those rays already hit
                                     ; the ceiling and answered "blocked" without
                                     ; finishing. (Every one of the 138 was blocked
                                     ; anyway, which is the only reason this never
                                     ; showed up as a monster that will not wake.)
                                     ; A ray that starves is INDISTINGUISHABLE
                                     ; from a wall to every caller, so the failure
                                     ; is silent by construction and no test can
                                     ; see it -- hence the headroom instead of the
                                     ; fit. Costs nothing: the counter is one byte
                                     ; either way and no shipped ray reaches 40, so
                                     ; the extra 24 are a net that never pays out.
SG_STKN equ 40                       ; BSP depth the walk can hold. E1's deepest
                                     ;   tree is 605 nodes -- nowhere near this.
                                     ;   Measured max 12 (_dbg_sightcost.py, the
                                     ;   same 219k rays), so this one IS roomy.
sg_stl  :SG_STKN dta 0               ; the far child waiting to be walked, low
sg_sth  :SG_STKN dta 0               ;   ...and high
sg_sp   dta 0                        ; stack pointer (0 = empty)
sg_sa   dta 0                        ; which side of this node USE_PT_A is on
    .if * > SGSTK_END+1
        ert 'the sight stack outgrew SGSTK_BASE..END (memory_map.inc)'
    .endif

        org SGBSP_BASE
;--------------------------------------------------------------
; sg_bsp -- ai_sight's tail: p_sight.c P_CrossBSPNode, iterative.
;   C=1 = nothing crossed the ray USE_PT_A..USE_PT_B, i.e. they see each other.
;
; WHY THE SAMPLED WALK HAD TO GO (2026-08-07, "enemy ma vidi cez steny"). It
; stepped the ray in 64 equal jumps and asked sh_leaf about the leaf each SAMPLE
; landed in. A subsector the ray only clips -- the sliver behind a corner, the
; strip between a pillar and a wall -- is thinner than the step, so no sample
; ever lands in it and the seg that closes it is never tested. The wall is right
; there in the BSP and the ray walks straight through it. Same bug wolf3d's
; los_clear had, and it went the same way: its los_checkline walks the tile
; BOUNDARIES the line crosses instead of sampling points along it.
;
; The BSP's own version of "walk the boundaries" is DOOM's:
;     side1 = P_DivlineSide(A, node);  side2 = P_DivlineSide(B, node)
;     same side -> descend that child only
;     different -> descend BOTH (the ray spans the split)
; point_on_side already IS P_DivlineSide -- it is what use_locate and the
; renderer walk with -- so this needs no new geometry, just the two calls and a
; stack for the far child. Every leaf the segment crosses is visited, however
; thin, and use_seg_hit inside sh_leaf stays the exact crossing test it was.
;
; It is not slower than what it replaces: the sampled walk paid 64 use_locate
; descents (a full root-to-leaf walk EACH), this pays one descent's worth of
; nodes plus the far children.
;--------------------------------------------------------------
.proc sg_bsp
        lda #0
        sta sg_sp
        lda #SG_LEAFN
        sta sg_lf
        lda MAP_HROOT                ; from the root, like use_locate
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
?walk   lda zp_nid+1
        and #$80
        bne ?leaf
        jsr calc_nodeptr
        ldx #3                       ; which side is the MONSTER on?
?pa     lda USE_PT_A,x
        sta zp_px,x
        dex
        bpl ?pa
        jsr point_on_side
        sta sg_sa
        ldx #3                       ; ...and the PLAYER?
?pb     lda USE_PT_B,x
        sta zp_px,x
        dex
        bpl ?pb
        jsr point_on_side            ; A = side of B, 0 or 1
        cmp sg_sa
        beq ?one                     ; both the same side: the other subtree
                                     ;   cannot hold anything the ray crosses
        asl                          ; the ray SPANS the split: park B's child
        clc                          ;   (children are at +8 and +10)
        adc #8
        tay
        ldx sg_sp
        lda [zp_nodeptr],y
        sta sg_stl,x
        iny
        lda [zp_nodeptr],y
        sta sg_sth,x
        inc sg_sp
?one    lda sg_sa                    ; ...and carry on into A's child, so the
        asl                          ;   walk stays roughly monster-to-player
        clc
        adc #8
        tay
        lda [zp_nodeptr],y
        sta zp_nid
        iny
        lda [zp_nodeptr],y
        sta zp_nid+1
        jmp ?walk
?leaf   dec sg_lf                    ; out of budget -> "no sight this time", and
        beq ?blocked                 ;   the next lap of the table looks again
        jsr sh_leaf                  ; C=1: a wall or a shut door is in the way
        bcs ?blocked
        ldx sg_sp                    ; the far children this ray still owes
        beq ?clear
        dec sg_sp
        ldx sg_sp
        lda sg_stl,x
        sta zp_nid
        lda sg_sth,x
        sta zp_nid+1
        jmp ?walk
?clear  sec                          ; nothing crossed it: they see each other
        bcs ?done                    ; (always)
?blocked clc
?done   stz sg_zon                   ; the walk is over: sh_leaf is the HITSCAN's
                                     ;   leaf test again, and those fly level
                                     ;   (stz leaves C alone -- the php is next)
        php                          ; C has to survive the restore
        ldx #3
?rb     lda sg_pl,x                  ; the PLAYER, back into zp_px/zp_py -- and
        sta zp_px,x                  ;   out of sg_tgt's own copy, not out of
        dex                          ;   USE_PT_B: since 2026-08-25 the ray's far
        bpl ?rb                      ;   end is the monster's TARGET, which for an
        plp                          ;   infighting pair is another MONSTER. This
        rts                          ;   read USE_PT_B for as long as the two were
.endp                                ;   the same point, and putting a monster's
                                     ;   position into zp_px would have moved the
                                     ;   PLAYER there for every reader downstream.
    .if * > SGBSP_END+1
        ert 'sg_bsp outgrew SGBSP_BASE..SGBSP_END (memory_map.inc)'
    .endif

sgtgt_resume = *
        org SGTGT_BASE
;==============================================================
; THE RAY GOES WHERE THE MONSTER IS LOOKING (2026-08-25).
;
; p_enemy.c never asks "can this monster see the PLAYER". Every call is
;     P_CheckSight (actor, actor->target)
; -- P_CheckMissileRange, A_SpidRefire, the A_Chase branch -- and A_Look is the
; one exception, which is the case where target IS the player anyway. This port
; built its ray to zp_px/zp_py unconditionally, so the cached answer in TH_SEEN
; meant "can see the player" and the infight path had nothing to ask: infight.asm
; simply skipped the test, and two monsters shot each other through walls.
;
; aif_tpos already resolves TH_TARG to a position (it is what P_NewChaseDir and
; A_FaceTarget walk with), so the ray only had to be pointed at ITS answer. What
; that costs is four bytes: sg_bsp borrows zp_px/zp_py for the walk's sample
; point and used to put the PLAYER back out of USE_PT_B, which is only the same
; point while the target is the player. sg_pl is that copy now.
;
; TH_SEEN therefore means "the last ray this thing spent reached its target" --
; the same byte, one honest step wider, and no new per-thing page.
;==============================================================
;--------------------------------------------------------------
; sg_tgt -- ai_sight's head: sg_pl = the player, USE_PT_B = ai_t's target.
;   Clobbers A/X/Y, sp_ptr, m_prod, zp_ptr (aif_tpos' own list).
;--------------------------------------------------------------
.proc sg_tgt
        ldx #3                       ; the player, parked for sg_bsp's restore.
?pl     lda zp_px,x                  ;   zp_px/zp_py are four adjacent zero-page
        sta sg_pl,x                  ;   bytes, which is what makes this one loop
        dex
        bpl ?pl
        jsr aif_tpos                 ; ai_tx/ai_ty = TH_TARG resolved: the player
        ldx #3                       ;   when it is 0, that thing's record when it
?tg     lda ai_tx,x                  ;   is not. ai_ty follows ai_tx (infight.asm),
        sta USE_PT_B,x               ;   so the same four-byte loop serves again
        dex
        bpl ?tg
        rts
.endp

;--------------------------------------------------------------
; aif_mvis -- aif_isvis' MONSTER-target arm: Y = the target's thing index.
;   C=1 if it is alive AND the last ray reached it. Until now this was a bare
;   `jmp aif_live` -- alive was the whole test, and infight.asm's header said so
;   in as many words ("the sight test between two monsters is skipped ... two
;   monsters already trading fire can [see through a wall]"). With the ray aimed
;   at the target there is finally an answer to read, so the tail call became
;   this and aif_isvis did not grow by a byte.
;
;   The answer is a CACHED one, exactly as it is for the player (aif_pvis): one
;   ray a frame is the budget, so a monster whose quarry just stepped behind a
;   pillar keeps firing until its next lap of the table. That lag is the port's
;   everywhere and DOOM's reactiontime blurs the same edge.
;--------------------------------------------------------------
.proc aif_mvis
        jsr aif_live                 ; `target->health <= 0` first: it is the
        bcc ?no                      ;   cheaper test and the one A_SpidRefire's
        lda #>TH_SEEN                ;   livelock needs (see aif_isvis)
        jsr ai_get                   ; ...and the ray's own answer, for ai_t
        lsr                          ;   (TH_SEEN is 0/1 -- lsr puts it in C)
?no     rts
.endp

;--------------------------------------------------------------
; sg_seen -- aif_reset's tail: TH_SEEN = 0 for all 256 things. See the note
;   there for why a page that only ai_look ever wrote had to start being
;   cleared -- bank $01 keeps the previous level's answers otherwise.
;--------------------------------------------------------------
.proc sg_seen
        lda #<TH_SEEN                ; 0: the page is 256 B aligned like every
        sta zp_ptr                   ;   other per-thing page (zp_ptr+2 is on
        lda #>TH_SEEN                ;   MAP_EXT_BANK already -- init_level)
        sta zp_ptr+1
        ldy #0
        tya
?clr    sta [zp_ptr],y
        iny
        bne ?clr
        rts
.endp

sg_pl   dta 0,0,0,0                  ; the player's x/y across one sight walk
                                     ;   (sg_tgt saves it, sg_bsp puts it back).
                                     ;   USE_PT_B held this job while the ray
                                     ;   always ended at the player; it ends at
                                     ;   the monster's TARGET now, so the two
                                     ;   parted company. It lives HERE and not
                                     ;   with the other sight vars because that
                                     ;   $82E0 run is 16 B and had one left --
                                     ;   see the guard down there.
    .if * > SGTGT_END+1
        ert 'sg_tgt/aif_mvis outgrew SGTGT_BASE..SGTGT_END (memory_map.inc)'
    .endif
        org sgtgt_resume

sgz_resume = *
        org SGZ_BASE
;==============================================================
; THE SIGHT RAY GETS A Z (2026-08-25, "e3m1 -- na zaciatku ma hned vidi IMP,
; ale to by nemal, som dole, nizsie ako on ... podobny problem je aj v e2m1").
;
; sg_bsp walks the BSP exactly as p_sight.c's P_CrossBSPNode does, but sh_leaf's
; per-seg test was use_shut ALONE -- "is the opening shut at all", openrange <=
; 0. p_sight.c's P_CrossSubsector does that AND carries a top/bottom SLOPE pair
; down the ray, narrowing it at every height change:
;
;     sightzstart = t1->z + t1->height - (t1->height>>2)
;     topslope    = t2->z + t2->height - sightzstart
;     ...per crossed two-sided line, if the two FLOORS differ:
;     slope = FixedDiv (openbottom - sightzstart, frac)
;     if (slope > bottomslope) bottomslope = slope
;     if (topslope <= bottomslope) return false
;
; The port had NO vertical component whatever, so this was never two map spots
; -- it was every sill, step, ledge and window in the game. Measured over the
; rays ai_look actually runs on all 27 shipped maps (tools/_dbg_sightz.py):
; 26,242 of them come back CLEAR and 1,776 of those -- 6.8% -- are sightlines
; DOOM blocks on height alone.
;
;   E3M1 spawn: the player stands in a pit at floor -128 whose rim (-8) is 56
;   units in front of his face. The three imps out on the floor are 670-871
;   units away and DOOM's ray dies on that rim; the port's walked straight over
;   it and all three woke on the spot.
;   E2M1 (1468,361): three zombiemen behind line 220 -- front floor 0/ceil 384,
;   back floor 64/ceil 128, i.e. a WINDOW with its sill at 64. A zombie's eye is
;   at 42, so it cannot see over its own sill; openrange is 64 and the port saw
;   straight through.
;
; WHAT IS IMPLEMENTED, and what is not. Three deliberate reductions, each one
; measured against the real P_CheckSight over those same 26,242 rays:
;
;   * THE SILL ONLY -- the bottomslope half. The ceiling half (a low lintel
;     narrowing topslope) is the other 2.7 points: floor-only catches 96.1% of
;     what DOOM blocks, floor+ceiling 98.8%. Half the code for a thirtieth of
;     the answer is not a trade this machine can make.
;   * NOT PROGRESSIVE. DOOM keeps the narrowed slopes and tests the next line
;     against them; this tests every line against the ray's ORIGINAL top slope
;     and keeps nothing. That is 98.8% -> 96.1% of DOOM's blocks and it is what
;     lets the whole test be two cross_pos calls with no division and no state.
;   * frac COMES FROM THE SEG'S ENDPOINTS, not from P_InterceptVector2. The
;     exact frac is |sA| / (|sA|+|sB|), and sA/sB are the 32-bit cross products
;     use_side already forms -- but turning them into cross_pos operands costs a
;     32-bit abs and a normalise, ~110 B this block does not have. The crossing
;     point lies BETWEEN the seg's two endpoints, so their projections on the
;     ray bracket the true frac: test both and block only if BOTH say blocked,
;     and the answer can never be more blocking than DOOM's. Cost: 96.1% ->
;     88.2%, with 9 rays in 26,242 (0.03%) blocked that DOOM would not -- and
;     that error points the safe way, "a monster does not see you", never
;     "a monster sees you through a hill".
;
; So: 88.2% of DOOM's height blocks, for ~150 B and no divide. Both spots in the
; bug report are in it, and so is every window sill and pit rim like them.
;
; WHERE THE BYTES CAME FROM. This block is the 280 B sound_tables.inc used to
; occupy at $3DD8 -- five lookup arrays that snd_play reads five times per sound
; STARTED, sitting in a RAPIDUS-FAST window. They are in bank $01 now (SNDX_EXT,
; memory_map.inc) and the sight ray has the fast window instead.
;==============================================================
SG_EYE  equ 42                       ; sightzstart: mobj z + height - height/4,
                                     ;   for the 56 every monster but the barons
                                     ;   and the cyberdemon is. DOOM prices it per
                                     ;   kind and the port has no height table;
                                     ;   the error is 6 units on a baron.
SG_TOP  equ 56                       ; ...and the target's own height, same deal

;--------------------------------------------------------------
; sg_set -- ai_sight's tail: the four numbers the sill test needs, once per RAY.
;   In: ai_t = the monster, sp_ptr = its thing record, sg_dx/sg_dy = the ray.
;   Clobbers A/X/Y, m_a, sp_ptr, zp_ptr.
;--------------------------------------------------------------
.proc sg_set
        lda #>TH_TARG                ; ONLY A PLAYER TARGET gets a z. A_Look is the
        jsr ai_get                   ;   one path that WAKES anything and its target
        bne ?off                     ;   is always the player (p_enemy.c); an
        ldy #4                       ;   infighting pair keeps the flat answer it
        lda (sp_ptr),y               ;   has always had, which is worth far more
        clc                          ;   than the ~50 B resolving TH_TARG's own z
        adc #SG_EYE                  ;   would have cost this block.
        sta sg_zs                    ; sightzstart: the thing record is x +0, y +2,
        iny                          ;   z +4 (sprites.asm spr_proj)
        lda (sp_ptr),y
        adc #0
        sta sg_zs+1
        clc                          ; m_a = the TOP of the player
        lda pl_z
        adc #SG_TOP
        sta m_a
        lda pl_z+1
        adc #0
        sta m_a+1
        sec                          ; sg_th = topslope at frac 1: how far the
        lda m_a                      ;   eye->target-top line has fallen by the far
        sbc sg_zs                    ;   end of the ray
        sta sg_th
        lda m_a+1
        sbc sg_zs+1
        sta sg_th+1
        bmi ?lo                      ; (sta leaves the sbc's N alone)
        lda sg_zs                    ; sg_lo = min(eye, target top): under THAT no
        ldy sg_zs+1                  ;   sill reaches the line at any frac in [0,1],
        bra ?st                      ;   and that prefilter is what keeps an open
?lo     lda m_a                      ;   portal from paying use_seg_hit's 2625
        ldy m_a+1                    ;   cycles
?st     sta sg_lo
        sty sg_lo+1
        ldx #0                       ; a projection axis. ANY axis is SAFE -- the
        lda sg_dx+1                  ;   seg's two endpoints bracket the crossing
        bpl ?a1                      ;   on every one of them -- it only has to be
        eor #$FF                     ;   NON-ZERO, because the verdict reads its
?a1     bne ?got                     ;   sign. So: x while |dx| >= 256, else y --
        ldx #2                       ;   and a y of zero needs no guard here, the
?got    stx sg_ax                    ;   `ora sg_dt` below already turns the whole
                                     ;   test off for a leg that came out zero.
        lda sg_dx,x                  ; sg_dy FOLLOWS sg_dx, so the axis is an index
        sta sg_dt
        lda sg_dx+1,x
        sta sg_dt+1
        ora sg_dt                    ; a leg of zero would read as "blocked" on
        sta sg_zon                   ;   every seg -- then no z test at all, and
        rts                          ;   any other value means "this is a sight ray"
?off    rts                          ; sg_zon is ALREADY 0 here and this block had
                                     ;   one byte of room, not four: sg_set is only
                                     ;   ever called from ai_sight's `jsr sg_set /
                                     ;   jmp sg_bsp` pair, and sg_bsp's ?done clears
                                     ;   it on the way out of every walk. If a
                                     ;   second caller is ever added, this needs the
                                     ;   stz back -- and three bytes from somewhere.
.endp

;--------------------------------------------------------------
; sg_shut -- use_shut PLUS the sill. A = 1 if this seg stops the ray.
;   Called from sh_leaf in use_shut's place, so it costs sh_leaf nothing -- and
;   for the hitscan (sg_zon = 0) it IS use_shut, to the cycle.
;
;   A "blocked" answer falls through to sh_leaf's ?geo, which runs use_seg_hit
;   again and stops the ray there, exactly as it does for a shut door. That is
;   one repeated crossing test, and only for a seg that really blocks.
;--------------------------------------------------------------
.proc sg_shut
        jsr use_shut
        bne ?out                     ; already shut: A = 1, there is nothing to add
        lda sg_zon
        beq ?out                     ; the bullet path: A = 0, and no z anywhere
        sec                          ; openbottom = max(front floor, back floor),
        lda coll_bx                  ;   and p_sight.c narrows NOTHING where the
        sbc coll_ax                  ;   two floors are equal
        sta cx_d                     ; (cx_d is free until use_seg_hit below, and
        lda coll_bx+1                ;   this needs BOTH bytes: a `tay/tya/beq` on
        sbc coll_ax+1                ;   the low byte alone reads a step of exactly
        bmi ?back                    ;   256 as "equal floors" and skips it)
        ora cx_d
        beq ?open                    ; equal -> not a sill
        bne ?have
?back   lda coll_ax
        sta coll_bx
        lda coll_ax+1
        sta coll_bx+1
?have   sec                          ; can this sill reach the line AT ALL? below
        lda coll_bx                  ;   min(eye, target top) no frac in [0,1] can
        sbc sg_lo                    ;   put it there, and skipping the geometry is
        lda coll_bx+1                ;   what keeps an open portal cheap (use_seg_hit
        sbc sg_lo+1                  ;   is 2625 cycles and most segs are portals)
        bmi ?open
        jsr use_seg_hit              ; ...and does the ray actually cross it?
        beq ?open                    ;   (coll_bx SURVIVES it: use_seg_hit works out
        sec                          ;   of m_a/m_ma/cx_*/USE_PT and coll_vptr out
        lda coll_bx                  ;   of m_prod/zp_ptr -- none of them is zp_X2)
        sbc sg_zs                    ; cx_a = openbottom - sightzstart
        sta cx_a
        lda coll_bx+1
        sbc sg_zs+1
        sta cx_a+1
        lda sg_dt                    ; cx_b = the ray's dominant leg
        sta cx_b
        lda sg_dt+1
        sta cx_b+1
        lda sg_th                    ; cx_c = target top - sightzstart
        sta cx_c
        lda sg_th+1
        sta cx_c+1
        ldx sg_ax                    ; v1 first, then v2 (USE_PT_Q = USE_PT_P+4).
        jsr ?ep                      ;   The crossing lies BETWEEN them, so one
        bcs ?open                    ;   endpoint saying "clear" is the safe answer
        ldx sg_ax
        inx
        inx
        inx
        inx
        jsr ?ep
        bcs ?open
        lda #1
        rts
?open   lda #0
?out    rts
;   ?ep -- C=0 if the sill stands above the eye->target-top line at THIS
;   endpoint's projection. The test is
;       (openbottom - zs) * leg  >=  (top - zs) * (endpoint - start)
;   i.e. cross_pos' own a*b - c*d, and dividing that by the leg to get a real
;   slope is what the sign compare below replaces.
?ep     ldy sg_ax                    ; X carries the ENDPOINT's offset and that is
        sec                          ;   sg_ax+4 for v2 (USE_PT_Q = USE_PT_P+4), so
        lda USE_PT_P,x               ;   the RAY START needs its own index -- with
        sbc USE_PT_A,y               ;   X here, v2 measured itself from USE_PT_B,
        sta cx_d                     ;   the ray's far end, and the second endpoint
        lda USE_PT_P+1,x             ;   answered "clear" almost every time. Which
        sbc USE_PT_A+1,y             ;   is both endpoints' verdict, so NOTHING ever
        bvs ?nb                      ;   blocked (2026-08-25, "neopravil si to").
        sta cx_d+1                   ; (a delta past signed 16 gets the safe answer)
        jsr cross_pos                ; (the full a*b - c*d stays in cx_p1)
        lda cx_p1+3
        eor sg_dt+1                  ; blocked <=> the product has the leg's OWN
        asl                          ;   sign; C=1 here means they differ
        rts
?nb     sec
        rts
.endp

sg_zs   dta a(0)                     ; sightzstart -- the monster's eye
sg_th   dta a(0)                     ; target top - sightzstart (DOOM's topslope)
sg_lo   dta a(0)                     ; min(eye, target top): the prefilter floor
sg_dt   dta a(0)                     ; the ray's projection leg, signed
sg_ax   dta 0                        ; 0 = project on x, 2 = on y (offset in a point)
sg_zon  dta 0                        ; 1 while sg_bsp is walking. sh_leaf is the
                                     ;   HITSCAN's leaf test too and this port's
                                     ;   bullets fly level (proj.asm), so they must
                                     ;   keep getting the old flat answer.
    .if * > SGZ_END+1
        ert 'sg_set/sg_shut outgrew SGZ_BASE..SGZ_END (memory_map.inc)'
    .endif
        org sgz_resume

;--------------------------------------------------------------
; ai_look -- A_Look for ONE SIGHT RAY a frame (the header above says why).
;   The cursor walks the thing table; anything that does not cost a ray -- not a
;   monster, dead, or past ai_sight's reach cull -- is a couple of table reads
;   and the scan moves straight on. The budget is one full lap of the table,
;   taken from the level's own thing count, so the scan cannot end a frame with
;   the monster standing next to the player still unlooked-at.
;--------------------------------------------------------------
        org CAND_BASE
;--------------------------------------------------------------
; ai_cand -- C=1 if thing ai_t is a monster that CHASES and is still alive, and
;   ai_wk = whether it is chasing already (then ai_look's ray only refreshes
;   TH_SEEN). A barrel has a kind too, and E1M1 has fifteen of them -- spending
;   the frame's ray on one is the difference between 1k cycles and 100k.
;--------------------------------------------------------------
.proc ai_cand
        jsr ai_bank
        ldy ai_t
        lda [zp_ptr],y               ; TH_WROW: chasing already?
        sta ai_wk
        lda #>TH_KIND                ; a monster at all? (en_kfill prefilled it)
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?no
        tax
        lda mk_ctic,x                ; ...one with RUN states?
        beq ?no
        jsr ai_ismon                 ; alive, and not already dying?
        beq ?no
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; blk_cell -- sp_ptr = a thing record, sol_i = its index: file it in the
;   blockmap cell pages (memory_map.inc TH_CX/TH_CY). en_radfill calls it once
;   per thing at level load, ai_track once per committed step.
;--------------------------------------------------------------

    .if * > CAND_END+1
        ert 'ai_cand outgrew CAND_BASE..CAND_END (memory_map.inc)'
    .endif

        org BLKSOL_BASE
;--------------------------------------------------------------
; blk_tgt -- en_solid's entry: which blockmap cell is the move target in?
;--------------------------------------------------------------
.proc blk_tgt
        lda coll_cx+1                ; the SAME grid blk_push files things on:
        lsr                          ;   (coord >> 9) & 7
        and #7
        sta sol_cx
        lda coll_cy+1
        lsr
        and #7
        sta sol_cy
        rts
.endp

;--------------------------------------------------------------
; (blk_solid died with the linear sweep) -- Y = thing index -> A = its radius, or 0 (Z set) when it cannot
;   block this move: not MF_SOLID, or more than one 256-unit cell away in
;   either axis. That second half is p_maputl.c P_BlockThingsIterator's whole
;   point -- two compares instead of the record read and the 16-bit box test
;   the sweep used to pay for all 255 things.
;--------------------------------------------------------------

    .if * > BLKSOL_END+1
        ert 'blk_tgt/blk_solid outgrew BLKSOL_BASE..END (memory_map.inc)'
    .endif


;--------------------------------------------------------------
; blk_link -- sp_ptr = a thing record, sol_i = its index: file it in the cell it
;   now stands in (p_maputl.c P_SetThingPosition). Three procs because no hole
;   in this port holds all of it: the cell + the "did it move" test here, the
;   unlink in blk_unlink, the insert in blk_ins.
;--------------------------------------------------------------



;--------------------------------------------------------------
; blk_unlink -- A = the cell it is filed in, Y = sol_i: cut it out of that
;   cell's list, then fall into blk_ins. Singly linked, and a cell holds a
;   handful of things, so the walk is short.
;--------------------------------------------------------------



;--------------------------------------------------------------
; blk_ins -- push thing sol_i onto cell blk_t's list and record the cell.
;--------------------------------------------------------------



        org BLKFILL_BASE
;--------------------------------------------------------------
; blk_fill -- file EVERY thing in the blockmap cell pages. Once per level, from
;   en_init (which has three bytes left, hence the jsr and not the loop).
;--------------------------------------------------------------
.proc blk_fill
        lda #<TH_CELL                ; (every bank $01 page has low byte 0)
        sta zp_ptr
        lda #>BLK_HEAD               ; every cell empty...
        sta zp_ptr+1
        ldy #63
        lda #$FF
?clr    sta [zp_ptr],y
        dey
        bpl ?clr
        lda th_things                ; ...then every thing onto its cell's list
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        lda #0
        sta sol_i
?l      lda sol_i
        cmp THINGS_BASE
        bcs ?done
        jsr blk_push
        clc
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inc sol_i
        bne ?l
?done   lda #>TH_RAD                 ; en_radfill's page back
        sta zp_ptr+1
?out    rts
.endp
    .if * > BLKFILL_END+1
        ert 'blk_fill outgrew BLKFILL_BASE..END (memory_map.inc)'
    .endif

        org BLKPUSH_BASE
;--------------------------------------------------------------
; blk_push -- sp_ptr = a thing record, sol_i = its index: onto the head of its
;   cell's list. p_maputl.c relinks a thing when it moves; this port rebuilds
;   the whole map once a frame instead -- 6k cycles against the 30k a single
;   monster step used to pay, and no unlink to get wrong.
;--------------------------------------------------------------
.proc blk_push
        ldy #1                       ; cell = ((y >> 9) & 7) << 3 | (x >> 9) & 7
        lda (sp_ptr),y
        lsr
        and #7
        sta blk_t
        ldy #3
        lda (sp_ptr),y
        lsr
        and #7
        asl
        asl
        asl
        ora blk_t
        tay                          ; Y = the cell
        lda #>BLK_HEAD
        sta zp_ptr+1
        lda [zp_ptr],y               ; the old head becomes our next
        sta blk_p
        lda sol_i
        sta [zp_ptr],y               ; ...and we become the head
        lda #>TH_BNEXT
        sta zp_ptr+1
        ldy sol_i
        lda blk_p
        sta [zp_ptr],y
        rts
.endp
    .if * > BLKPUSH_END+1
        ert 'blk_push outgrew BLKPUSH_BASE..END (memory_map.inc)'
    .endif



;--------------------------------------------------------------
; blk_cell -- sp_ptr = a thing record, sol_i = its index -> TH_CX/TH_CY.
;   blk_cell_ai is the same for the thing ai_track just moved.
;--------------------------------------------------------------

;--------------------------------------------------------------
; blk_link -- sp_ptr = a thing record, sol_i = its index: put it in the cell it
;   is standing in, taking it out of the one it was in (P_SetThingPosition's
;   half of p_maputl.c). The list is singly linked and a cell holds a handful
;   of things, so the unlink walks it.
;--------------------------------------------------------------




        org AILOOK_BASE
.proc ai_look
        lda pl_dead                  ; a corpse is not worth looking for
        bne ?out
        lda THINGS_BASE              ; one full lap of the table. The counter
        sta ai_lc                    ;   lives in MEMORY: ai_sight and ai_start
                                     ;   clobber X and Y
?next   ldx ai_lk
        inx
        cpx THINGS_BASE              ; the level's thing count -> wrap
        bcc ?ok
        ldx #0
?ok     stx ai_lk
        stx ai_t
        jsr ai_cand                  ; a monster that can chase, and alive?
        bcc ?skip
        lda ai_wk                    ; A_Look's 180-degree test, BEFORE the ray
        bne ?ray                     ;   (a monster already chasing still gets
        jsr ai_front                 ;   one -- aif_pvis reads the cached
        bcs ?skip                    ;   answer): back turned costs nothing
?ray    lda #0                       ; "no ray has run yet": ai_sight's reach
        sta sg_n                     ;   cull returns without touching sg_n,
        jsr ai_sight                 ;   sg_shift sets it to 64 for a walk that
        lda #0                       ;   really happens, and a walk that comes
        rol                          ;   back BLOCKED always stops with at least
        ldx #>TH_SEEN                ;   one sample left (sg_walk tests before
        jsr ai_put                   ;   it decrements). So on C=0, sg_n tells
        beq ?blind                   ;   the two apart. Cache the answer for
        lda ai_wk                    ;   aif_pvis either way (ai_put leaves the
        bne ?out                     ;   value in A); already chasing means the
        jmp ai_start                 ;   refresh was the whole point
?blind  lda sg_n                     ; nothing seen -- but did it COST anything?
        beq ?skip                    ;   culled on distance: two compares, carry
        rts                          ;   on scanning. A real ray: frame is done
?skip   dec ai_lc
        bne ?next
?out    rts
.endp
    .if * > AILOOK_END+1
        ert 'ai_look outgrew AILOOK_BASE..END (memory_map.inc)'
    .endif

        org SIGHT_VARS
sg_dx   dta a(0)                     ; the sample step, monster -> player
sg_dy   dta a(0)                     ;   (sg_dy MUST follow sg_dx: both loops
                                     ;    walk the four bytes as one)
sg_n    dta 0                        ; samples left
sg_lf   dta 0                        ; ...and leaves left in the ray's budget
sg_t    dta 0                        ; the shift count, across the two loops
ai_lk   dta 0                        ; ai_look's round-robin cursor
ai_lc   dta 0                        ; ...its candidate counter this frame
sol_cx  dta 0                        ; the move target's blockmap cell (blk_tgt)
sol_cy  dta 0
blk_t   dta 0                        ; blk_link scratch: the new cell...
blk_dirty dta 1                      ; 1 = a thing moved, blk_fill owes a rebuild
                                     ; (blk_c, "the cell it was filed in", was here
                                     ;  and had no reader or writer at all -- 1 B)
blk_p   dta 0                        ;   ...and the entry ahead of us in the old
ai_wk   dta 0                        ; ...and whether the thing it is looking at
                                     ;   is already chasing (then the ray only
                                     ;   refreshes TH_SEEN)
                                     ; (sg_pl went to the SGTGT hole, not here --
                                     ;  see the guard below)
    .if * > PJSLT_BASE
        ert 'the sight vars outgrew the $82E0 hole (memory_map.inc)'
    .endif
                                     ; THE GUARD USED TO READ `SIGHT_VARS+32`
                                     ; AND THAT IS A PAGE THIS BLOCK DOES NOT
                                     ; OWN (2026-08-25): pj_slot is nailed to
                                     ; $82F0 (PJSLT_BASE), so the run here is 16
                                     ; bytes, not 32. Four bytes of sg_pl went
                                     ; in on the old guard's word, assembled
                                     ; clean, and only check_xex.py's
                                     ; segment-overlap pass caught it --
                                     ; "$82E0-$82F2 and $82F0-$82FF". Pinned to
                                     ; the symbol now so the two can never drift.
        org aiwake_resume

;--------------------------------------------------------------
; ai_bank -- zp_ptr = TH_WROW. Every per-thing AI page is 256 B and page
;   aligned, so switching between them is one store to zp_ptr+1; this sets the
;   common case and the callers step the high byte from there.
;--------------------------------------------------------------
.proc ai_bank
        stz zp_ptr
        lda #>TH_WROW
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; ai_ismon -- ai_t = thing index. Z=0 if it is a monster, alive, and not already
;   dying: TH_HP nonzero (pack_things only gives health to MF_SHOOTABLE) and
;   TH_STATE zero (enemy.asm's death chain owns anything else).
;--------------------------------------------------------------
.proc ai_ismon
        ldy ai_t
        stz zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?no                      ; dying or dead
        stz zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        sta ai_t2
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora ai_t2                    ; hp 0 = not shootable at all
        rts
?no     lda #0
        rts
.endp

;--------------------------------------------------------------
; ai_start -- ai_t = thing index: put it into the chase. Caches the kind byte
;   (TH_KIND) so the per-tic path never has to walk the sprite table again,
;   enters RUN state 0 with that kind's tics, and leaves movecount 0 / DI_NODIR
;   so the first A_Chase picks a direction with no turnaround to avoid.
;--------------------------------------------------------------
.proc ai_start
        jsr ai_bank                  ; the kind byte: en_kfill prefilled it for
        ldy ai_t                     ;   every thing at level init, so the wake
        lda #>TH_KIND                ;   needs no sprite-table walk any more
        sta zp_ptr+1
        lda [zp_ptr],y
        sta en_kind                  ; (en_kind_of used to leave it here)
        sta ai_k                     ; ...and ai_k: the mk_rt read below used a
                                     ;   STALE ai_k from the previous ai_setrow
                                     ;   -- benign only because mk_rt is 8 for
                                     ;   every episode-1 kind
        beq ?no                      ; kind 0 = not a monster after all
        tax
        lda mk_ctic,x                ; a kind with no RUN states (the barrel)
        beq ?no                      ;   never chases
                                     ; (TH_KIND already holds the kind -- the
                                     ;   prefill wrote it, nothing to cache)
        lda #>TH_WTIC
        sta zp_ptr+1
        lda mk_ctic,x
        sta [zp_ptr],y
        lda #0
        ldy ai_t
        ldx #>TH_WST                 ; state 0
        stx zp_ptr+1
        sta [zp_ptr],y
        ldx #>TH_MCNT                ; movecount 0 -> new direction at once
        stx zp_ptr+1
        sta [zp_ptr],y
        lda #AI_NODIR
        ldx #>TH_DIR
        stx zp_ptr+1
        sta [zp_ptr],y
        lda #MK_RT<<AIM_RTSH         ; TH_MODE: RUN chain, nothing attacked yet,
                                     ;   reactiontime = info.c's. This WAS
                                     ;   `lda mk_rt,x` and the table was 8
                                     ;   repeated once per kind -- every mobj in
                                     ;   info.c has the same reactiontime -- so
                                     ;   it is MK_RT (memory_map.inc) now and
                                     ;   mk_tables.inc emits an ert if that ever
                                     ;   stops being true. The three asl's went
                                     ;   with it: the field starts at AIM_RTSH.
                                     ;   P_CheckMissileRange refuses to fire while
                                     ;   it is nonzero, so a monster that just woke
                                     ;   closes in before it shoots -- DOOM sets it
        ldy ai_t                     ;   at SPAWN and only A_Chase counts it down,
        ldx #>TH_MODE
        stx zp_ptr+1
        sta [zp_ptr],y
        jsr ai_setrow                ; and the image state 0 draws
        ldx ai_k                     ; A_Look's seesound. info.c names one per
        lda mk_see,x                 ;   type and p_enemy.c picks at random among
        bmi ?no                      ;   the numbered variants -- posit1..3 for a
        ldy mk_seen,x                ;   zombieman, bgsit1..2 for an imp -- which
        dey                          ;   is why wadsound.py keeps them consecutive
        beq ?one                     ;   and mk_seen says how many there are.
        lda RANDOM                   ; the same POKEY LFSR the rest of this port
        and #3                       ;   rolls with, and the same bias DOOM's own
        cmp mk_seen,x                ;   M_Random%3 has (enemy.asm's header)
        bcc ?pick
        sec
        sbc mk_seen,x
?pick   clc
        adc mk_see,x
        sta snd_pending
        rts
?one    lda mk_see,x
        sta snd_pending
?no     rts
.endp

;--------------------------------------------------------------
; ai_setrow -- ai_t = thing: TH_WROW = the walk row its current RUN state draws.
;   image = (state >> mk_wsh) & (WTAB_N-1): the 8-state monsters hold each image
;   for two states (A,A,B,B,...) so wsh is 1, while the cacodemon's single state
;   and the lost soul's two use it straight. WTAB_N is per LEVEL -- how many
;   images the sprite slot could afford (tools/_walk_budget.py) -- so the mask
;   folds a 4-image cycle onto 2 without the state machine noticing.
;   2026-08-03: rows went image-major x WTAB_N[0] (the rotation slice) and the
;   +14 B pushed this block past AI_END -- parked with spr_wrot, its sibling.
;--------------------------------------------------------------
aisr_resume = *
        org WROT2_BASE
.proc ai_setrow
        jsr ai_bank
        ldy ai_t
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        sta ai_k
        lda #>TH_WST
        sta zp_ptr+1
        lda [zp_ptr],y               ; the RUN state index
        ldx ai_k
        ldy mk_wsh,x
        beq ?noshift
?sh     lsr
        dey
        bne ?sh
?noshift sta ai_t2
        txy                          ; 65816: X is still the kind (ldx ai_k
                                     ;   above; the shift counted in Y), and
                                     ;   this is two bytes where ldy ai_k was
                                     ;   three -- half of what the modulo costs
        lda #<WTAB_N                 ; image MOD WTAB_N, then + the kind's first
        sta zp_ptr                   ;   row. It was `& (WTAB_N-1)`, which folds
        lda #>WTAB_N                 ;   only for a power of two and is what held
        sta zp_ptr+1                 ;   pack_walk's ladder to 4/2/1 images --
        lda ai_t2                    ;   DOOM's spider has SIX (SPID A-F).
?mod    cmp [zp_ptr],y               ; 65816 cmp/sbc [dp],y: no temp needed
        bcc ?inrange
        sbc [zp_ptr],y               ; (cmp left C=1, which sbc wants)
        bcs ?mod                     ; (no borrow -> go round again)
?inrange sta ai_t2
        ldy #0                       ; rows are IMAGE-MAJOR since the rotation
        lda [zp_ptr],y               ;   slice: img * WTAB_N[0] (the per-level
        cmp #4                       ;   stored-view count, 1 or 4 and NOTHING
        bne ?flat                    ;   else -- pack_things plan_views asserts
        lda ai_t2                    ;   it, spr_wrot's swr_rot4 assumes it)
        asl
        asl                          ; *4 (img <= 3, so no carry out)
        sta ai_t2
?flat   ldy ai_k
        lda #<WTAB_EXT
        sta zp_ptr
        lda #>WTAB_EXT
        sta zp_ptr+1
        lda [zp_ptr],y
        clc
        adc ai_t2
        inc @                        ; TH_WROW is row+1: 0 means "not chasing"
        sta ai_t2
        jsr ai_bank
        ldy ai_t
        lda ai_t2
        sta [zp_ptr],y
        rts
.endp
    .if * > WROT2_END+1
        ert 'ai_setrow outgrew WROT2_BASE..END (memory_map.inc)'
    .endif
        org aisr_resume

;--------------------------------------------------------------
; ai_tick -- ONE DOOM tic, from wp_think next to en_tick. Sweeps the same 256
;   things en_tick does; only the ones with a TH_WROW cost more than a branch.
;--------------------------------------------------------------
.proc ai_tick
        stz zp_ptr                   ; every AI page shares low byte 0, so the
                                     ;   sweep only ever moves zp_ptr+1 -- worth
        lda #>TH_WROW                ;   inlining, this runs 256 times a tic.
        sta zp_ptr+1                 ;   The idle path is trimmed to the bone:
        ldy #0                       ;   no ai_i spill and no page reload until
?lp     lda [zp_ptr],y               ;   something actually chases (was 26
        bne ?chase                   ;   cycles an idle thing, is 15)
?next   iny
        bne ?lp
        rts
?chase  sty ai_i
        lda #>TH_WTIC
        sta zp_ptr+1
        lda [zp_ptr],y
        dec @                        ; 65816: dec A. Only Z is read here
        sta [zp_ptr],y
        bne ?back                    ; still inside the state
        sty ai_t
        jsr ai_state                 ; the state ran out -> next one + A_Chase
        stz zp_ptr                   ; ai_state walked pages of its own
?back   lda #>TH_WROW
        sta zp_ptr+1
        ldy ai_i
        jmp ?next
.endp

;--------------------------------------------------------------
; ai_state -- ai_t = thing: P_SetMobjState onto the next RUN state. The chain
;   loops, so "next" is (state+1) mod the kind's state count, the new state's
;   tics are info.c's, and its action -- A_Chase, on every single RUN state --
;   runs here.
;--------------------------------------------------------------
.proc ai_state
        jsr ai_ismon                 ; it may have died since the last tic
        bne ?live
        jsr ai_bank                  ; dead: stop chasing. It KEEPS its chaser
        ldy ai_t                     ;   slot -- en_kill wants the corpse drawn
        lda #0                       ;   from where it FELL, and ai_evict is what
        sta [zp_ptr],y               ;   hands that slot back when a LIVE one needs
        rts                          ;   it. (This used to `jmp ai_untrack`, which
                                     ;   was both unreachable -- en_kill clears
                                     ;   TH_WROW at the moment of death, so ai_tick
                                     ;   never dispatches the thing here again --
                                     ;   and a contradiction of en_kill's own "it
                                     ;   stays in the draw table on purpose".)
?live   jsr ai_bank
        ldy ai_t
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        sta ai_k
        tax
        lda #>TH_MODE                ; mid-ATTACK? then the ATTACK chain owns the
        sta zp_ptr+1                 ;   state machine until its last frame
        lda [zp_ptr],y
        and #AIM_ATK
        beq ?run
        jmp ai_atk_next
?run    lda #>TH_WST
        sta zp_ptr+1
        lda [zp_ptr],y
        inc @                        ; 65816: inc A. cmp sets the C the bcc reads
        cmp mk_wst,x                 ; past the last RUN state -> back to the first
        bcc ?put
        lda #0
?put    sta [zp_ptr],y
                                     ; ---- A_Hoof / A_Metal (p_enemy.c) ------
                                     ; The cyberdemon and the spider are the
                                     ;   ONLY two RUN chains in DOOM that run
                                     ;   anything but A_Chase, and both actions
                                     ;   are "S_StartSound, then A_Chase" -- so
                                     ;   the whole of them is a sound id.
                                     ; It sits HERE, and not in a routine of its
                                     ;   own, because here it is free of
                                     ;   operands: A is the RUN state ai_state
                                     ;   just wrote, X is the kind and Y is the
                                     ;   thing, and none of the three has to be
                                     ;   fetched or put back. 25 B, and the
                                     ;   65816 sweep above (stz/inc/dec, which
                                     ;   this port had never used) freed 28.
                                     ; mk_tables.inc's MK_WSND pins the shape:
                                     ;   pack_things reads the RUN chains out of
                                     ;   info.c and FAILS THE PACK if the two
                                     ;   kinds stop being the tail of MK_ORDER
                                     ;   or the trigger states ever move.
        cpx #MK_WSND                 ; kinds 1..9 walk silently
        bcc ?nows
        bne ?spid                    ; ...MK_WSND+1 = the spider mastermind
        cmp #6                       ; CYBR D (S_CYBER_RUN7) -> A_Metal
        beq ?met
        cmp #0                       ; CYBR A (S_CYBER_RUN1) -> A_Hoof
        bne ?nows
        lda #SFX_HOOF
        bne ?wsnd                    ; SFX_HOOF is never 0 -- always taken
?spid   and #3                       ; SPID A/C/E (S_SPID_RUN1/5/9) -> A_Metal,
        bne ?nows                    ;   i.e. every fourth of its twelve states
?met    lda #SFX_METAL
?wsnd   sta snd_pending              ; ONE slot: the footstep beats the 3/256
                                     ;   A_Chase grunt ai_chase rolls after it,
                                     ;   which is the one DOOM would have put on
                                     ;   a second channel
?nows   lda #>TH_WTIC
        sta zp_ptr+1
        lda mk_ctic,x
        sta [zp_ptr],y
        jsr ai_setrow
        jmp ai_chase
.endp

;--------------------------------------------------------------
; ai_chase -- A_Chase. The attack branches run first (they can return without
;   moving at all), then the movement half:
;       if (--movecount < 0 || !P_Move(actor)) P_NewChaseDir(actor);
;--------------------------------------------------------------
.proc ai_chase
        jsr aif_ttick                ; P_KillMobj clears MF_SHOOTABLE on the dead
        beq ?stand                   ;   player, so A_Chase's target test fails and
                                     ;   DOOM drops the monster to its spawnstate:
                                     ;   it stops moving AND stops attacking. The
                                     ;   RUN chain keeps ticking here, so it walks
                                     ;   on the spot -- which is what DOOM's
                                     ;   two-frame S_x_STND idle looks like.
                                     ;   aif_ttick also runs A_Chase's threshold
                                     ;   countdown and drops a target that died,
                                     ;   and it answers "keep thinking" whenever
                                     ;   the target is another MONSTER: a fight
                                     ;   between two of them outlives the player.
        jsr ai_try_atk               ; melee / missile -- C=1: it attacked, and
        bcc ?move                    ;   A_Chase returns without moving
?stand  rts
?move   lda RANDOM                   ; A_Chase's tail: `if (activesound &&
        cmp #3                       ;   P_Random () < 3) S_StartSound(...)` --
        bcs ?nosnd                   ;   the patrol grunt, about one RUN state in
        lda #>TH_KIND                ;   85. Rolled here rather than after the
        jsr ai_get                   ;   move only because ai_newdir is a tail
        tax                          ;   call; the rate is what you hear, and it
        lda mk_act,x                 ;   is the same either way.
        bmi ?nosnd
        sta snd_pending
?nosnd  jsr ai_bank
        ldy ai_t
        lda #>TH_MCNT
        sta zp_ptr+1
        lda [zp_ptr],y
        dec @                        ; 65816: dec A. 0 -> $FF, N=1, same as sbc
        sta [zp_ptr],y
        bmi ?new                     ; movecount went negative
        jsr ai_move
        bne ?done
?new    jmp ai_newdir                ; ...or the move was blocked
?done   rts
.endp

;--------------------------------------------------------------
; ai_get / ai_put -- one per-thing AI byte, page A. Everything in here is a
;   [zp_ptr],y read or write into bank $01 with the SAME index, so folding it
;   into a pair of helpers is what keeps this module inside its hole.
;--------------------------------------------------------------
.proc ai_get
        sta zp_ptr+1
        stz zp_ptr                   ; all the pages share the low byte (0)
        ldy ai_t
        lda [zp_ptr],y
        rts
.endp

.proc ai_put
        sta ai_t2
        stx zp_ptr+1
        stz zp_ptr
        ldy ai_t
        lda ai_t2
        sta [zp_ptr],y
        rts
.endp

;--------------------------------------------------------------
; ai_move -- P_Move. A/Z: nonzero = it moved, zero = blocked, which is what
;   A_Chase reads as "pick a new direction".
;   The step is info.c's speed run through p_enemy.c's xspeed/yspeed table and
;   folded at pack time into whole map units per direction (mk_stepx): the
;   diagonals are speed*47000/65536, so 8 -> 6, 10 -> 7, 12 -> 9, 16 -> 11.
;
;   ONE TABLE, BOTH AXES (2026-08-20). p_enemy.c's yspeed[] is xspeed[] turned
;   two octants -- yspeed[d] == xspeed[(d+6)&7] for every d, because both are
;   cos/sin of the same eight angles -- so mk_stepy was the same eight numbers
;   stored a second time. It is gone; the y read rotates the index instead,
;   which is nine bytes of code against thirty-two of table. pack_things
;   asserts the identity when it emits the table. What bought the room: the two
;   FINAL BOSSES are two more speeds (16 and 12), i.e. two more rows -- and
;   MKTAB had twelve bytes of slack.
;--------------------------------------------------------------
.proc ai_move
        lda #>TH_DIR
        jsr ai_get
        cmp #AI_NODIR
        bcc ?go
        lda #0                       ; DI_NODIR -> P_Move returns false
        rts
?go     sta ai_d
        lda #>TH_KIND
        jsr ai_get
        tax
        lda mk_spd,x                 ; ai_di = speed ROW * 8 (the row base; the
        asl                          ;   two axes add their own direction to it)
        asl
        asl
        sta ai_di
        clc
        adc ai_d                     ; ...+ movedir = xspeed[movedir]
        tay                          ; the step is a SIGNED byte: sign-extend it
        lda mk_stepx,y               ;   by hand, the adds below are 16-bit
        sta ai_sx
        bpl ?px
        lda #$FF
        bne ?sx                      ; always
?px     lda #0
?sx     sta ai_sx+1
        lda ai_d                     ; yspeed[movedir] IS xspeed[(movedir+6)&7]
        clc                          ;   -- see the header. The row base is
        adc #6                       ;   already in ai_di and the rotated
        and #7                       ;   direction can never carry out of the
        ora ai_di                    ;   low three bits, so ORA is the add
        tay
        lda mk_stepx,y
        sta ai_sy
        bpl ?py
        lda #$FF
        bne ?sy
?py     lda #0
?sy     sta ai_sy+1
ai_step lda ai_t                     ; P_TryMove ENTRY for a step someone else
        jsr en_thing.en_th2          ;   already picked (en_thrust's shove):
                                     ;   ai_t + ai_sx/ai_sy in, everything from
                                     ;   here on is P_TryMove proper.
                                     ;   sp_ptr = the thing record (x at +0, y at +2)
        ldy #0                       ; candidate = thing.xy + step
        clc
        lda (sp_ptr),y
        adc ai_sx
        sta coll_cx
        iny
        lda (sp_ptr),y
        adc ai_sx+1
        sta coll_cx+1
        iny
        clc
        lda (sp_ptr),y
        adc ai_sy
        sta coll_cy
        iny
        lda (sp_ptr),y
        adc ai_sy+1
        sta coll_cy+1
        ldy #4                       ; and its z, while sp_ptr is still good
        lda (sp_ptr),y
        sta ai_z
        iny
        lda (sp_ptr),y
        sta ai_z+1
        jsr coll_mon                 ; the same probe move_player uses, but
                                     ;   at the KIND's radius (p_map.c builds
                                     ;   tmbbox from tmthing->radius)
        beq ?tcheck
        jsr ai_door                  ; a LINE stopped it: P_Move still opens a
        lda #0                       ;   door the monster is allowed to work
        rts
?tcheck lda ai_t                     ; ...and then P_TryMove's OTHER half, the one
        sta sol_self                 ;   this port never had: PIT_CheckThing. It is
        jsr en_solid                 ;   what stops a monster walking through the
        beq ?zstep                   ;   player and through its own kind.
        lda #0
        rts
        ; --- P_TryMove's height rules (p_map.c 478/482). Without these a monster
        ;     is stuck on flat ground: it can neither climb a step nor come back
        ;     down one, because its z never changes. DOOM's limit is 24 units in
        ;     BOTH directions -- up is "too big a step up", down is "don't stand
        ;     over a dropoff", and 24 is what makes stairs walkable and ledges not.
?zstep  lda zp_px                    ; locate_floor point-locates zp_px/zp_py, so
        sta ai_sv                    ;   lend it the candidate and give the player
        lda zp_px+1                  ;   its position straight back
        sta ai_sv+1
        lda zp_py
        sta ai_sv+2
        lda zp_py+1
        sta ai_sv+3
        lda coll_cx
        sta zp_px
        lda coll_cx+1
        sta zp_px+1
        lda coll_cy
        sta zp_py
        lda coll_cy+1
        sta zp_py+1
        jsr locate_floor             ; -> loc_floor = the destination's floor
        lda ai_sv
        sta zp_px
        lda ai_sv+1
        sta zp_px+1
        lda ai_sv+2
        sta zp_py
        lda ai_sv+3
        sta zp_py+1
        sec                          ; dz = destination floor - the thing's z
        lda loc_floor
        sbc ai_z
        sta ai_dz
        lda loc_floor+1
        sbc ai_z+1
        sta ai_dz+1
        bpl ?up
        clc                          ; down: blocked if the drop is more than 24
        lda ai_dz
        adc #24
        lda ai_dz+1
        adc #0
        bmi ?no
        jmp ?ok
?up     lda ai_dz+1                  ; up: blocked if the step is more than 24
        bne ?no
        lda ai_dz
        cmp #25
        bcc ?ok
?no     lda #0
        rts
?ok     lda ai_t                     ; commit. collide_blocked and locate_floor
        jsr en_thing.en_th2          ;   both walk the map with zp_ptr/sp_ptr, so
        ldy #0                       ;   rebuild the record pointer first
        lda coll_cx
        sta (sp_ptr),y
        iny
        lda coll_cx+1
        sta (sp_ptr),y
        iny
        lda coll_cy
        sta (sp_ptr),y
        iny
        lda coll_cy+1
        sta (sp_ptr),y
        iny                          ; ...and stand it on the new floor, which is
        lda loc_floor                ;   what makes it visibly walk the stairs
        sta (sp_ptr),y
        iny
        lda loc_floor+1
        sta (sp_ptr),y
        jsr ai_track                 ; it is in a new subsector now, and zp_nid
                                     ;   still holds the leaf locate_floor found
        jmp ai_mcnt                  ; P_TryWalk's movecount roll -- parked with
.endp                                ;   the thrust code, this block is full

;--------------------------------------------------------------
; ai_newdir -- P_NewChaseDir, structurally DOOM's: build the two axis wishes
;   from the deltas to the player, try the diagonal that combines them, then
;   each axis alone, then the old direction. What is dropped is the random
;   order swap and the final 8-direction scan; what is kept is the turnaround
;   ban, which is what stops a monster oscillating in a doorway.
;--------------------------------------------------------------
.proc ai_newdir
        jsr aif_tpos                 ; actor->target, which is not always the
        lda ai_t                     ;   player any more (infight.asm)
        jsr en_thing.en_th2
        sec                          ; deltax = target - thing
        ldy #0
        lda ai_tx
        sbc (sp_ptr),y
        sta ai_dx
        iny
        lda ai_tx+1
        sbc (sp_ptr),y
        sta ai_dx+1
        sec                          ; deltay
        iny
        lda ai_ty
        sbc (sp_ptr),y
        sta ai_dy
        iny
        lda ai_ty+1
        sbc (sp_ptr),y
        sta ai_dy+1
        lda #>TH_DIR                 ; turnaround = opposite[olddir] = dir ^ 4
        jsr ai_get
        cmp #AI_NODIR
        bcs ?noturn
        eor #4
        sta ai_turn
        jmp ?wish
?noturn lda #AI_NODIR
        sta ai_turn
?wish   lda #AI_NODIR                ; d1 = EAST/WEST if |deltax| > 10
        sta ai_d1
        sta ai_d2
        lda ai_dx+1
        bmi ?west
        ora ai_dx
        beq ?ydir
        lda ai_dx+1
        bne ?east
        lda ai_dx
        cmp #11
        bcc ?ydir
?east   lda #AI_EAST
        sta ai_d1
        jmp ?ydir
?west   lda ai_dx+1                  ; negative: is it < -10?
        cmp #$FF
        bne ?wset
        lda ai_dx
        cmp #<-10
        bcs ?ydir
?wset   lda #AI_WEST
        sta ai_d1
?ydir   lda ai_dy+1                  ; d2 = NORTH/SOUTH if |deltay| > 10
        bmi ?south
        ora ai_dy
        beq ?diag
        lda ai_dy+1
        bne ?north
        lda ai_dy
        cmp #11
        bcc ?diag
?north  lda #AI_NORTH
        sta ai_d2
        jmp ?diag
?south  lda ai_dy+1
        cmp #$FF
        bne ?sset
        lda ai_dy
        cmp #<-10
        bcs ?diag
?sset   lda #AI_SOUTH
        sta ai_d2
?diag   lda ai_d1                    ; both wishes set -> DOOM's diags[] first
        cmp #AI_NODIR
        beq ?tryd1
        lda ai_d2
        cmp #AI_NODIR
        beq ?tryd1
        lda ai_d1
        cmp #AI_EAST
        bne ?dw
        lda ai_d2
        cmp #AI_NORTH
        beq ?dne
        lda #AI_SOUTHEAST
        jmp ?trydg
?dne    lda #AI_NORTHEAST
        jmp ?trydg
?dw     lda ai_d2
        cmp #AI_NORTH
        beq ?dnw
        lda #AI_SOUTHWEST
        jmp ?trydg
?dnw    lda #AI_NORTHWEST
?trydg  cmp ai_turn
        beq ?tryd1
        jsr ai_trywalk
        bne ?dn0
?tryd1  lda ai_d1
        cmp #AI_NODIR
        beq ?tryd2
        cmp ai_turn
        beq ?tryd2
        jsr ai_trywalk
        bne ?dn0
?tryd2  lda ai_d2
        cmp #AI_NODIR
        beq ?tryold
        cmp ai_turn
        beq ?tryold
        jsr ai_trywalk
        bne ?dn0
?tryold lda #>TH_DIR                 ; nothing worked: keep going the old way,
        jsr ai_get                   ;   which is what DOOM tries next
        cmp #AI_NODIR
        beq ?scan
        jsr ai_trywalk
        beq ?scan                    ; blocked -> the sweep
?dn0    rts                          ; near home: ?done went out of branch
                                     ;   range when the sweep moved in
?scan   lda RANDOM                   ; p_enemy.c:449-479, the RANDOM-ORDER SWEEP
        and #1                       ;   of all eight directions. This was
        beq ?dsc                     ;   dropped once -- and a ledge imp whose
        lda #0                       ;   wishes all point off the edge then just
?up     sta ai_sdir                  ;   STOOD there, movecount pinned at 0, and
        cmp ai_turn                  ;   machine-gunned fireballs: the sweep is
        beq ?un                      ;   what walks it along its platform, and
        jsr ai_trywalk               ;   the walk is what reloads movecount
        bne ?done                    ;   (P_TryWalk) -- DOOM's fire rate.
?un     lda ai_sdir
        inc @
        cmp #8
        bcc ?up
        bcs ?turnb
?dsc    lda #7                       ; ...or DI_SOUTHEAST down to DI_EAST
?dn     sta ai_sdir
        cmp ai_turn
        beq ?dn2
        jsr ai_trywalk
        bne ?done
?dn2    lda ai_sdir
        dec @
        bpl ?dn
?turnb  lda ai_turn                  ; p_enemy.c:481: the turnaround, last
        cmp #AI_NODIR
        beq ?stuck
        jsr ai_trywalk
        bne ?done
?stuck  lda ai_d1                    ; cornered for real: face the player and
        cmp #AI_NODIR                ;   let the next state try again. NO
        bne ?keep                    ;   movecount write: DOOM leaves it
        lda ai_d2                    ;   negative (nonzero), which is exactly
?keep   ldx #>TH_DIR                 ;   what keeps a boxed-in monster from
        jsr ai_put                   ;   attempting a missile every state.
?done   rts
.endp

;==============================================================
; WHERE A MOVING THING IS DRAWN FROM.
;   pack_things sorts the things by SUBSECTOR and hands the engine a packed
;   prefix array -- subsector s owns things [prefix[s], prefix[s+1]). That is
;   fixed at pack time and cannot be relinked at runtime, so a monster that
;   walks away is still collected when its SPAWN subsector comes up in the BSP
;   walk. The vissprite order survives that (spr_proj sorts by scale), but the
;   CLIP SNAPSHOT does not: it is taken at the moment the subsector is reached,
;   so a monster that walked toward the player gets the window of a FARTHER
;   subsector -- everything nearer has already been painted and cuts it. That is
;   the "it lost its legs on the stairs" picture: a step riser it had already
;   walked past was still clipping it. And if the spawn subsector is not visible
;   at all, the monster is not drawn even while standing in front of you.
;
;   The fix is a small side table: a chasing thing carries the subsector it is
;   ACTUALLY in (free -- locate_floor already descended to that leaf for the
;   step test), and spr_add projects it there instead. AI_DMAX entries; past
;   that a chaser falls back to the packed prefix, which is what happens today.
;
;   WHO OWNS THE ENTRIES -- and why a CORPSE must give one up (2026-08-13,
;   "casom sa zacnu enemies stracat, vidno ich len na polovicu, zmiznu, alebo
;   ich vidno za stenou.. az po chvili hrania"). A corpse keeps its entry on
;   purpose: it lies where it FELL and only this table draws it from there
;   (en_kill's header). But it keeps it FOREVER -- en_kill clears TH_WROW, so
;   ai_tick never dispatches the thing again, ai_state never runs, and the
;   ai_untrack that used to hang off it was unreachable. The table therefore
;   only ever grew: 14 slots shared between the live chasers and EVERY monster
;   that had ever taken a step before dying. Roughly fourteen kills into a level
;   it was permanently full, and from then on every newly woken monster hit
;   ?full and fell back to its SPAWN subsector -- projected at its real (near,
;   big) scale but clipped to a FAR window. That is exactly the reported
;   picture: a demon in your face, cut off at the knees by the doorway it walked
;   through, its head flat against the top of that same opening, or gone
;   entirely whenever its spawn leaf left the view.
;   So the table is a LIVE-chaser budget, not a level-long log: when it is full
;   ai_evict takes the oldest corpse's slot back. A body drawn from the packed
;   prefix is the old cosmetic bug (it can be clipped by geometry it walked
;   past); a live monster drawn that way is unreadable AND unfair, and en_shoot
;   aims at the vissprite list, so it is unkillable too. Bodies lose.
;==============================================================

;--------------------------------------------------------------
; ai_track -- ai_t = thing, zp_nid = the leaf locate_floor just reached. Insert
;   or refresh its entry. Called on every committed step and once on waking.
;--------------------------------------------------------------
.proc ai_track
        lda ai_t
        jsr ai_ischase
        beq ?add
        dex                          ; ai_ischase leaves X = slot+1
        bpl ?put                     ;   -> X = the slot, never negative, so this
?add    ldx ai_dn                    ;   is an always-taken branch (was a jmp)
        cpx #AI_DMAX
        bcs ?ev                      ; full -> take a corpse's slot instead
        inc ai_dn                    ; (X still holds the OLD count = the new slot)
?st     lda ai_t
        sta ai_dth,x
?put    lda zp_nid
        sta ai_dsl,x
        lda zp_nid+1
        and #$7F                     ; the leaf flag is not part of the id
        sta ai_dsh,x
?full   inc blk_dirty                ; it moved: the blockmap has to be rebuilt
        rts                          ;   before the next frame's move tests
?ev     jsr ai_evict
        bcs ?st                      ; got one: reuse the slot it freed
        bcc ?full                    ; fourteen LIVE chasers: the old fallback
.endp

;--------------------------------------------------------------
; ai_evict -- the table is full and a LIVE chaser wants in. Find a slot held by
;   a CORPSE and hand it over: C=1 and X = that slot, C=0 if all AI_DMAX of them
;   are still chasing (then the caller keeps today's spawn-subsector fallback).
;
;   THE TEST IS TH_WROW == 0. It is the walk row + 1, so a chasing thing always
;   has it nonzero (ai_setrow, ai_atk_row and infight's seestate all add the 1),
;   and the only writers of a zero are ai_reset -- which empties the table in the
;   same breath -- and en_kill. An entry reading zero is therefore a body, and
;   nothing else. No health probe, no TH_STATE probe: one indexed byte.
;
;   It scans UPWARD so the OLDEST corpse goes first: entries are appended in
;   kill order, so the low slots are the bodies furthest back in the level --
;   the ones the player has already walked away from and is least likely to be
;   looking at when they lose their window.
;
;   Cold: only on a committed step by an untracked chaser once the table is
;   full, i.e. a handful of times a tic at worst, fourteen compares each.
;   (This is the byte-for-byte replacement of ai_untrack, which was dead code --
;   see ai_state.)
;--------------------------------------------------------------
.proc ai_evict
        jsr ai_bank                  ; zp_ptr = TH_WROW (bank $01)
        ldx #0
?lp     ldy ai_dth,x
        lda [zp_ptr],y
        beq ?got                     ; not chasing -> en_kill cleared it -> a body
        inx
        cpx #AI_DMAX
        bcc ?lp
        clc                          ; every slot is a live chaser
        rts
?got    sec
        rts
.endp

;--------------------------------------------------------------
; ai_ischase -- A = thing index. Z=0 and X = slot+1 if it is tracked, Z=1 if it
;   is not. Called per thing in spr_add's prefix loop, so it stays a plain scan
;   over at most AI_DMAX bytes and the caller checks ai_dn first.
;--------------------------------------------------------------
.proc ai_ischase
        ldx ai_dn
?lp     beq ?no
        cmp ai_dth-1,x
        beq ?yes
        dex
        jmp ?lp
?no     ldx #0                       ; Z=1 = not tracked
        rts
?yes    txa                          ; X = slot+1, so it is never 0: Z=0 = tracked.
        rts                          ;   WITHOUT this the flag came from the CMP
.endp                                ;   above, which is Z=1 on a match -- the same
                                     ;   answer as "not found". spr_add's dedup then
                                     ;   never fired and every chaser was drawn
                                     ;   TWICE: once from where it stands and once
                                     ;   from its spawn subsector, the second with a
                                     ;   stale clip window that ate pieces of it.

;--------------------------------------------------------------
; spr_chase -- from spr_add, for the subsector in zp_nid: project every tracked
;   chaser standing in it. Same projection the prefix loop uses, so it needs the
;   same thing-record pointer and the same alive test.
;--------------------------------------------------------------
.proc spr_chase
        ldx ai_dn
?lp     dex
        bmi ?out
        lda zp_nid
        cmp ai_dsl,x
        bne ?lp
        lda zp_nid+1
        and #$7F
        cmp ai_dsh,x
        bne ?lp
        stx ai_dx                    ; the scan cursor, across spr_proj
        lda ai_dth,x
        sta ai_t
        sta sp_i                     ; spr_proj reads the THING INDEX for vs_th
                                     ;   out of sp_i, and the hitscan aims by
                                     ;   vs_th. Without this a chasing monster
                                     ;   carried whatever index the last prefix
                                     ;   loop left there, so en_shoot took the
                                     ;   health off some OTHER thing: monsters
                                     ;   would not die, and en_kill parked a
                                     ;   death frame on a bystander -- the imp
                                     ;   that "turned into a zombieman".
        tax
        jsr thing_alive_bit          ; a corpse is the prefix loop's business
        beq ?next
        lda ai_t
        jsr en_thing.en_th2          ; sp_ptr = the thing record
        jsr spr_proj
?next   ldx ai_dx
        lda sp_n
        cmp #VIS_MAX
        bcc ?lp
?out    rts
.endp

;--------------------------------------------------------------
; ai_trywalk -- P_TryWalk: A = the direction to try. Commits it and asks
;   P_Move. Z=0 (bne) = it moved.
;--------------------------------------------------------------
.proc ai_trywalk
        ldx #>TH_DIR
        jsr ai_put
        jmp ai_move
.endp

ai_resume = *                        ; BEFORE the org, never after: `org label`
                                     ;   with the label defined below it resolves
                                     ;   to 0 on pass 1, the scratch lands at
                                     ;   $0000, and the XEX overwrites the zero
                                     ;   page -- black screen, PC in the weeds.
        org MKTAB_BASE               ; per-kind info.c data: the SFX + painchance
        icl 'mk_tables.inc'          ; enemy.asm reads, and the RUN-state timing,
                                     ; P_Move steps and A_Look grunts this file
                                     ; reads. Its own block: twelve tables now,
                                     ; and it outgrew both the ENINIT hole it
                                     ; started in and the AI block after that.
                                     ; (en_die_snd wanted to live here too --
                                     ; 14 B short; it is in the SNDTAB annex.)
    .if * > MKTAB_END+1
        ert 'mk_tables.inc outgrew MKTAB_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; en_bdist -- p_map.c PIT_RadiusAttack's FIRST test, which this port did not
;   have, in front of the one it did:
;
;       // Boss spider and cyborg
;       // take no damage from concussion.
;       if (thing->type == MT_CYBORG || thing->type == MT_SPIDER)
;           return true;
;
;   It is the only immunity in DOOM and the only place the damage path names a
;   TYPE. Without it a rocket splashed E2M8's cyberdemon and E3M8's spider for
;   free -- both bosses were meaningfully cheaper to kill than DOOM's, and the
;   BARREL next to one counted too.
;
;   Asked as `radius >= MK_NOBLAST_R` because en_bthings has TWO spare bytes and
;   no room for a per-kind table, while TH_RAD is a page it already reaches.
;   That is the same question only while the immune types are exactly the widest
;   ones in the roster; pack_things.noblast_radius() reads the pair out of
;   p_map.c and FAILS THE PACK if a WAD ever makes it a different question.
;
;   Slotted in behind mk_tables.inc, in its own block's tail: the call site is
;   `jsr en_bdist` where it used to be `jsr en_dist`, so en_bthings pays nothing
;   at all. The PLAYER's path (en_boom) still calls en_dist directly -- the
;   player is not a thing and has no radius here.
;--------------------------------------------------------------
.proc en_bdist                       ; en_bi = the candidate. C=0 = no damage.
        ldy en_bi                    ; zp_ptr's low byte is 0 already: every
        lda #>TH_RAD                 ;   per-thing page is 256 B aligned and
        sta zp_ptr+1                 ;   en_bthings left it on one
        lda [zp_ptr],y
        cmp #MK_NOBLAST_R
        bcs ?no
        jmp en_dist                  ; ordinary thing -> PIT_RadiusAttack proper
?no     clc                          ; a boss: `return true`, no damage, no kick
        rts                          ;   (a jmp and not a branch: en_dist is at
.endp                                ;    $EA68 and this block is at $3D9C)
    .if * > MKTAB_END+1
        ert 'en_bdist outgrew the mk_tables block (MKTAB_END, memory_map.inc)'
    .endif
        org ai_resume

; ---- scratch. Lives INSIDE the AI block (the way enemy.asm parks en_bx/en_by
;   in its own): it is all cold -- touched once per state change, never in the
;   render path -- and base RAM has nothing to spare outside this hole.
ai_t    dta 0                        ; the thing being worked on
ai_t2   dta 0                        ; ...and a byte of working room
ai_k    dta 0                        ; its kind
ai_i    dta 0                        ; ai_tick's sweep index
ai_d    dta 0                        ; the direction being tried
ai_di   dta 0                        ; that direction's step-table ROW BASE
                                     ;   (mk_spd[kind] * 8; ai_move adds the
                                     ;   direction per axis -- see there)
ai_turn dta 0                        ; opposite[olddir], the banned direction
ai_d1   dta 0                        ; P_NewChaseDir's two axis wishes
ai_d2   dta 0
ai_vx   dta 0                        ; ai_wake's vissprite cursor
ai_noise dta 0                       ; frames left of "the player just fired".
                                     ;   p_pspr.c P_FireWeapon ends with
                                     ;   P_NoiseAlert(player, player), which
                                     ;   floods soundtarget through every
                                     ;   connected sector, and A_Look reads
                                     ;   THAT before it looks anywhere -- so a
                                     ;   shot wakes a monster with its back
                                     ;   turned. The flood wants a sector->line
                                     ;   graph this port has no room for, so
                                     ;   the stand-in is: while this is up,
                                     ;   both A_Look paths skip the facing test
                                     ;   and anything that can SEE the player
                                     ;   wakes. Strictly less than DOOM (it
                                     ;   hears round corners too), never more.
NOISE_FR equ 30                      ; ~1 s: long enough for ai_look's
                                     ;   round-robin ray to reach several
                                     ;   monsters, short enough that walking
                                     ;   away afterwards is quiet again

;--------------------------------------------------------------
; ai_noisealert -- A = the weapon's SFX id. Queues it AND raises ai_noise:
;   p_pspr.c P_FireWeapon does S_StartSound's work and P_NoiseAlert on the same
;   trigger pull, so wp_fire_a calls this where it used to `sta snd_pending` --
;   three bytes for three, which is the only reason it can exist at all (that
;   block, en_gunshot's and the snd_q_* one are each full to the byte). Here
;   and not in sound.asm because the AI block is where the spare RAM is, and
;   ai_noise is the point of it.
;--------------------------------------------------------------
noiseq_resume = *
        org NOISEQ_BASE
.proc ai_noisealert
        sta snd_pending
        lda #NOISE_FR
        sta ai_noise
        rts
.endp
    .if * > NOISEQ_END+1
        ert 'ai_noisealert outgrew NOISEQ_BASE..END (memory_map.inc)'
    .endif
        org noiseq_resume
ai_sx   dta 0,0                      ; the step, sign-extended to 16 bits
ai_sdir dta 0                        ; ai_newdir: the 8-direction sweep cursor
ai_sy   dta 0,0
ai_dx   dta 0,0                      ; player - thing
ai_dy   dta 0,0
ai_z    dta 0,0                      ; the thing's z before the step
ai_dz   dta 0,0                      ; destination floor - that z (the 24 test)
ai_sv   dta 0,0,0,0                  ; zp_px/zp_py, lent to locate_floor
; ---- the draw-side re-attach table (see the block comment above)
ai_dn   dta 0                        ; tracked chasers (0 = spr_add is untouched)
aidt_resume = *                      ; the three arrays are absolute-indexed, so
        org AIDT_BASE                ;   where they sit does not matter -- and the
ai_dth  :AI_DMAX dta 0               ;   AI block has four bytes left
ai_dsl  :AI_DMAX dta 0               ; the subsector it is standing in, low
ai_dsh  :AI_DMAX dta 0               ; ...and high
    .if * > AIDT_END+1
        ert 'the chaser table outgrew AIDT_BASE..END (memory_map.inc)'
    .endif
        org aidt_resume

;--------------------------------------------------------------
; aif_pchk -- the PLAYER half of A_SpidRefire's "is there still a target".
;
;   p_enemy.c tests `!actor->target || actor->target->health <= 0` in the SAME
;   if as P_CheckSight, and for a player target that is pl_dead. aif_isvis
;   carries the MONSTER half already (it tail-calls aif_live); this is the
;   other one, and it lives out here because aif_pvis' block has four spare
;   bytes and the test wants fourteen.
;
;   THE BUG, reported from a real run the day the refire loop landed: you die,
;   and the spider mastermind goes on emptying its chaingun into your corpse.
;   In DOOM a dead player loses MF_SHOOTABLE, A_Chase sees that on its very
;   next state and sends the monster back to its SPAWNSTATE -- it stands still
;   and watches. The port has that too (aif_ttick's ?pldead), and the refire
;   loop is precisely the one path that never lets A_Chase run, so every check
;   A_Chase used to make has to be made here instead.
;
;   OUT: Z=1 -> no player left to shoot at (the carry means nothing).
;        Z=0 -> C is ai_isvis' answer. `lda` does not touch the carry, which is
;               what lets one register bring back both halves.
;--------------------------------------------------------------
.proc aif_pchk
        lda pl_dead
        bne ?dead
        jsr ai_isvis                 ; drawn this frame -> visible, for free
        lda #1
        rts
?dead   lda #0
        rts
.endp

    .if * > AI_END+1
        ert 'enemy_ai.asm outgrew AI_BASE..AI_END (memory_map.inc)'
    .endif


; ---- the rest of enemy_ai.asm, split out 2026-08-09 into the enemy_ai_* files
;      (see each one's header). They are included HERE, in the original order, so
;      the assembler sees the same text in the same place and emits the same bytes.
        icl 'enemy_ai_attack.asm'
        icl 'enemy_ai_pldeath.asm'
        icl 'enemy_ai_drop.asm'
        icl 'enemy_ai_thrust.asm'
