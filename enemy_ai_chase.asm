;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): A_Chase -- ai_tick, ai_state, ai_chase, P_Move (ai_move), P_NewChaseDir (ai_newdir), P_TryWalk.
;--------------------------------------------------------------
;--------------------------------------------------------------
; ai_tick -- ONE DOOM tic, from wp_think next to en_tick. Sweeps the same 256
;   things en_tick does; only the ones with a TH_WROW cost more than a branch.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_tick
        ; 2026-09-09 (drac030 style): the sweep reads TH_WROW as WORDS -- two
        ; things per [zp_ptr],y -- so the idle path is 16 cycles a PAIR where
        ; it was 15 a thing.
    .if [TH_WROW & $FF] != 0
        ert 'ai_tick: TH_WROW must be page-aligned for the word sweep'
    .endif
        lda ai_flyn                  ; P_MobjThinker: P_XYMovement before the state
        bne ?fly                     ;   clock (ai_flyall, enemy_ai_attack.asm). The
?grnd   stz zp_ptr                   ;   rare flight is out of line below. Every AI
                                     ;   page shares low byte 0, so the
        lda #>TH_WROW                ;   sweep only ever moves zp_ptr+1
        sta zp_ptr+1
        ldx #0                       ; 2026-09-26: the idle sweep in X, long,x (6
        rep #$20                     ;   cycles a pair where [zp_ptr],y was 7) and
        .LONGA ON                    ;   the watermark an IMMEDIATE ai_reset patches
?lp     lda.l MAP_EXT_BANK*$10000+TH_WROW,x  ; (cpx # 2, cpy ai_lim was 4). Same
        bne ?hit                     ;   order, same pairs; a hit hands X to Y
?next   inx
        inx
ait_lim cpx #0                       ; WATERMARK (2026-09-14): the level's n_things
        bne ?lp                      ;   (ai_reset patches it with ai_lim)
        sep #$20
        .LONGA OFF
        rts
?fly    jsr ai_flyall                ; a lost soul in the air (8-bit, like ?grnd)
        bra ?grnd
?hit    txy
        sep #$20                     ; one of the pair chases: which?
        .LONGA OFF
        lda [zp_ptr],y               ; the even one
        beq ?odd
        jsr ?one
?odd    iny
        lda [zp_ptr],y               ; the odd one (?one puts TH_WROW back)
        beq ?cont
        jsr ?one
?cont   iny                          ; Z = Y at the watermark: the sweep is
        tyx                          ;   over (rep leaves Z alone)
ait_lim2 cpx #0
        rep #$20
        .LONGA ON
        bne ?lp
        sep #$20
        .LONGA OFF
        rts
?one    sty ai_i                     ; ---- thing Y chases: its state tic
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
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_state -- ai_t = thing: P_SetMobjState onto the next RUN state. The chain
;   loops, so "next" is (state+1) mod the kind's state count, the new state's
;   tics are info.c's, and its action -- A_Chase, on every single RUN state --
;   runs here.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_state
        jsr ai_ismon                 ; it may have died since the last tic
        bne ?live
                                      ; 2026-09-22 idiom: ai_bank inlined (see ai_look)
        stz zp_ptr
        lda #>TH_WROW
        sta zp_ptr+1                 ; dead: stop chasing. It KEEPS its chaser
        ldy ai_t                     ;   slot -- en_kill wants the corpse drawn
        lda #0                       ;   from where it FELL, and ai_evict is what
        sta [zp_ptr],y               ;   hands that slot back when a LIVE one needs
        rts                          ;   it. (This used to `jmp ai_untrack`, which
                                     ;   was both unreachable -- en_kill clears ...
                                      ; 2026-09-22 idiom: ai_bank inlined (see ai_look);
?live   stz zp_ptr                   ;   the TH_WROW high byte was a dead store here
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
                                     ; ---- A_Hoof / A_Metal (p_enemy.c) ------ ...
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
?wsnd   jsr snd_qp_ai                ; ONE slot: the footstep beats the 3/256
                                     ;   (STEREO: from ai_t; X and Y survive) ...
?nows   lda #>TH_WTIC
        sta zp_ptr+1
        lda mk_ctic,x
        sta [zp_ptr],y
        jsr ai_setrow
                                     ; 2026-09-21 drac_bra: the target is the very
        ert *<>ai_chase             ;   next byte of this segment -- fall through
.endp
        .endseg

;--------------------------------------------------------------
; ai_chase -- A_Chase. The attack branches run first (they can return without
;   moving at all), then the movement half:
;       if (--movecount < 0 || !P_Move(actor)) P_NewChaseDir(actor);
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_chase
        jsr aif_ttick                ; P_KillMobj clears MF_SHOOTABLE on the dead
        beq ?stand                   ;   player, so A_Chase's target test fails and
                                     ;   DOOM drops the monster to its spawnstate:
                                     ;   it stops moving AND stops attacking.
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
        jsr snd_qp_ai                ; (STEREO: the grunt from ai_t)
                                      ; 2026-09-22 idiom: ai_bank inlined (see ai_look);
?nosnd  stz zp_ptr                   ;   the TH_WROW high byte was a dead store here
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
        .endseg

;--------------------------------------------------------------
; ai_get / ai_put -- one per-thing AI byte, page A. Everything in here is a
;   [zp_ptr],y read or write into bank $01 with the SAME index, so folding it
;   into a pair of helpers is what keeps this module inside its hole.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_get
        sta zp_ptr+1
        stz zp_ptr                   ; all the pages share the low byte (0)
        ldy ai_t
        lda [zp_ptr],y
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_put
                                      ; 2026-09-23: the N/Z the callers read (sg_seen's
        stx zp_ptr+1                 ;   `jsr ai_put / beq ?blind`) come from an ora #0
        stz zp_ptr                   ;   AFTER the store instead of a reload: A is
        ldy ai_t                     ;   still the value (sta changes nothing), C/V
        sta [zp_ptr],y               ;   are left alone as the lda left them. ai_t2
        sta ai_t2                    ;   keeps the value, as before
        ora #0
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_move -- P_Move. A/Z: nonzero = it moved, zero = blocked, which is what
;   A_Chase reads as "pick a new direction".
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_move
        lda #>TH_DIR
        jsr ai_get
am_a    cmp #AI_NODIR                ; (2026-09-23: ai_trywalk's entry, A = the dir it
                                     ;   just ai_put -- zp_ptr/Y as ai_get leaves them)
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
                                      ;   already picked (en_thrust's shove):
        jsr en_thing.en_th2w          ;   ai_t + ai_sx/ai_sy in; P_TryMove proper.
        .LONGA ON                    ;   words (2026-09-15; was 24 byte ops)
        lda (sp_ptr)
        adc ai_sx
        sta coll_cx
        ldy #2
        clc
        lda (sp_ptr),y
        adc ai_sy
        sta coll_cy
        ldy #4                       ; and its z, while sp_ptr is still good
        lda (sp_ptr),y
        sta ai_z
        .LONGA OFF
        sep #$20
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
        ; --- P_TryMove's height rules (p_map.c 478/482).
?zstep  rep #$20                     ; locate_floor point-locates zp_px/zp_py:
        .LONGA ON                    ;   lend it the candidate and take its
                                      ;   position straight back. 2026-09-22 (65816-
        pei (zp_px)                  ;   idioms: pei): the player's position rides
        pei (zp_py)                  ;   the stack straight from zero page
        lda coll_cx
        sta zp_px
        lda coll_cy
        sta zp_py
        .LONGA OFF
        sep #$20
        jsr locate_floor             ; -> loc_floor = the destination's floor
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        .LONGA ON
        pla                          ; zp_py was pushed last
        sta zp_py
        pla
        sta zp_px                    ; (still 16-bit)
        sec                          ; dz = destination floor - the thing's z, and
        lda loc_floor                ;   |dz| <= 24 as ONE unsigned test: dz + 24
        sbc ai_z                     ;   in [0, 48] (2026-09-15 -- the same set
        sta ai_dz                    ;   the two byte branches accepted)
        clc
        adc #24
        cmp #49
        .LONGA OFF
        sep #$20
        bcc ?ok
?no     lda #0
        rts
?ok     lda ai_t                     ; commit. collide_blocked and locate_floor
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ;   both walk the map with zp_ptr/sp_ptr, so
        .LONGA ON                    ;   and the new floor as three words
        lda coll_cx
        sta (sp_ptr)
        ldy #2
        lda coll_cy
        sta (sp_ptr),y
        ldy #4                       ; ...and stand it on the new floor, which is
        lda loc_floor                ;   what makes it visibly walk the stairs
        sta (sp_ptr),y
        .LONGA OFF
        sep #$20
        lda tp_any                   ; P_TryMove's spechit: a level without a
        beq ?trk                     ;   teleport line pays this and no more
        jsr ai_tele
?trk    jsr ai_track                 ; it is in a new subsector now, and zp_nid
                                     ;   still holds the leaf locate_floor found
                                      ; 2026-09-22 p_enemy.c: P_Move only says "it moved";
        lda #1                       ;   the movecount roll is P_TryWalk's (ai_trywalk),
        rts                          ;   A_Chase's own step must not reload it
.endp                                ;   the thrust code, this block is full
        .endseg

;--------------------------------------------------------------
; ai_tele -- EV_Teleport for a MONSTER (P_CrossSpecialLine lets it use 39/97):
;   the step just committed crossed a teleport line from its front side ->
;   move it to the destination, unless something shootable stands there
;   (PIT_StompThing: monsters never stomp). Only a step landing in a room next
;   to a teleport line (tp_bits) runs the record scan.
;   IN: coll_cx/cy = the new position, ai_sx/sy = the step, zp_sptr = the new
;   leaf's seg (locate_floor), sp_ptr = the thing. zp_nid stays the leaf the
;   thing ends in, for ai_track.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_tele
        ldy #SEG_FRONT
        lda [zp_sptr],y              ; the room it stepped into: mv_crossed
        sta mv_psec                  ;   matches it against the record's rooms
        tax
        and #7
        tay
        txa
        lsr @
        lsr @
        lsr @
        tax
        lda tp_bits,x
        and mv_bit,y
        bne ?room
        rts
?room   rep #$20
        .LONGA ON
        pei (zp_px)                  ; mv_crossed reads the move as mv_ox/oy ->
        pei (zp_py)                  ;   zp_px/py: lend it this step
        lda coll_cx
        sta zp_px
        sec
        sbc ai_sx                    ; where the step started = new - step
        sta mv_ox
        lda coll_cy
        sta zp_py
        sec
        sbc ai_sy
        sta mv_oy
        .LONGA OFF
        sep #$20
        stz mv_i
?lp     lda mv_i
        cmp THINGS_BASE+13           ; the trigger count
        bcs ?back
        jsr mv_ptr
        ldy #13
        lda (zp_ptr),y
        and #$04                     ; b10: a teleport record
        beq ?nx
        jsr mv_crossed               ; C=1 crossed; mv_s1 = the side it left
        bcc ?nx
        lda mv_s1
        bne ?hit                     ; from the back: "so you can get out"
?nx     inc mv_i
        bra ?lp
?back   rep #$20
        .LONGA ON
        pla
        sta zp_py
        pla
        sta zp_px
        .LONGA OFF
        sep #$20
        rts
?hit    ldy #14
        lda (zp_ptr),y               ; the destination's index
        rep #$20
        .LONGA ON
        and #$00FF
        asl @
        asl @
        asl @                        ; *8: C = 0, the index is < 256
        adc THINGS_BASE+14
        sta mv_ss
        pla
        sta zp_py
        pla
        sta zp_px                    ; the player back: en_solid tests him too
        lda (mv_ss)
        sta coll_cx
        ldy #2
        lda (mv_ss),y
        sta coll_cy
        .LONGA OFF
        sep #$20
        lda ai_t
        sta sol_self
        jsr en_solid                 ; occupied: the step stands, no teleport
        bne ?out
        rep #$20
        .LONGA ON
        pei (zp_px)                  ; locate_floor point-locates zp_px/py
        pei (zp_py)
        lda coll_cx
        sta zp_px
        lda coll_cy
        sta zp_py
        .LONGA OFF
        sep #$20
        jsr locate_floor             ; the spot's floor; zp_nid = its leaf
        .LONGA ON                    ;   (returns 16-bit)
        pla
        sta zp_py
        pla
        sta zp_px
        .LONGA OFF
        sep #$20
        lda ai_t
        jsr en_thing.en_th2w         ; (returns 16-bit)
        .LONGA ON
        lda coll_cx
        sta (sp_ptr)
        ldy #2
        lda coll_cy
        sta (sp_ptr),y
        ldy #4
        lda loc_floor                ; thing->z = thing->floorz
        sta (sp_ptr),y
        .LONGA OFF
        sep #$20
        lda #SFX_TELEPT              ; one voice, at the arrival
        sta en_snd_q
        lda ai_t
        sta en_snd_th
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_newdir -- P_NewChaseDir, structurally DOOM's: build the two axis wishes
;   from the deltas to the player, try the diagonal that combines them, then
;   each axis alone (the dominant one first, or at random 55 times in 256),
;   then the old direction, the sweep and the turnaround. The turnaround ban
;   is what stops a monster oscillating in a doorway.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_newdir
        jsr aif_tpos                 ; actor->target, which is not always the
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
        sep #$20
                                      ;   player any more (infight.asm)
        lda #>TH_DIR                 ; turnaround = opposite[olddir] = dir ^ 4
        jsr ai_get                   ;   (NODIR stays NODIR)
        cmp #AI_NODIR
        bcc ?t
        lda #AI_NODIR^4
?t      eor #4
        sta ai_turn
        lda ai_t                     ; 2026-09-22: deltas, wishes and |dy| > |dx|
        jsr en_thing.en_th2w          ;   in ONE 16-bit window
        .LONGA ON
        ldx #AI_NODIR                ; d1 = EAST if deltax > 10, WEST if < -10
        sec
        lda ai_tx
        sbc (sp_ptr)
        sta ai_dx
        bmi ?w
        cmp #11
        bcc ?ax
        ldx #AI_EAST
        bra ?ax
?w      cmp #$FFF6
        bcs ?nx
        ldx #AI_WEST
?nx     eor #$FFFF
        inc @
?ax     inc @                        ; |dx| + 1, parked for the compare
        pha
        stx ai_d1
        ldx #AI_NODIR                ; d2 = NORTH if deltay > 10, SOUTH if < -10
        ldy #2
        sec
        lda ai_ty
        sbc (sp_ptr),y
        sta ai_dy
        bmi ?s
        cmp #11
        bcc ?ay
        ldx #AI_NORTH
        bra ?ay
?s      cmp #$FFF6
        bcs ?ny
        ldx #AI_SOUTH
?ny     eor #$FFFF
        inc @
?ay     stx ai_d2
        cmp 1,s                      ; C = |dy| >= |dx| + 1 = |dy| > |dx|
        pla                          ;   (the pull leaves C)
        sep #$20
        .LONGA OFF
        bcs ?swap                    ; p_enemy.c: P_Random() > 200 || abs(dy) >
        lda RANDOM                   ;   abs(dx) swaps the axes. Swapped before the
        cmp #201                     ;   diagonal, which reads only the signs --
        bcc ?diag                    ;   RANDOM has no sequence to keep in step
?swap   ldx ai_d1
        ldy ai_d2
        sty ai_d1
        stx ai_d2
?diag   lda ai_d1                    ; both wishes set -> diags[((dy<0)<<1)+(dx>0)]
        cmp #AI_NODIR
        beq ?tryd1
        lda ai_d2
        cmp #AI_NODIR
        beq ?tryd1
        bit ai_dy+1
        bmi ?dso
        lda #AI_NORTHEAST
        bit ai_dx+1
        bpl ?trydg
        lda #AI_NORTHWEST
        bra ?trydg
?dso    lda #AI_SOUTHEAST
        bit ai_dx+1
        bpl ?trydg
        lda #AI_SOUTHWEST
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
?tryold                              ; nothing worked: keep going the old way,
                                      ;   which is what DOOM tries next. 2026-09-22:
        lda ai_turn                  ;   olddir = turnaround ^ 4 (NODIR stays NODIR)
        cmp #AI_NODIR                ;   -- TH_DIR holds the last ATTEMPT by now,
        beq ?scan                    ;   ai_trywalk writes it
        eor #4
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
        .endseg

;--------------------------------------------------------------
; ai_trywalk -- P_TryWalk: A = the direction to try. Commits it and asks
;   P_Move. Z=0 (bne) = it moved.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_trywalk
        ldx #>TH_DIR
        jsr ai_put
                                      ; 2026-09-22 p_enemy.c:349 P_TryWalk: P_Move, and
        jsr ai_move.am_a             ;   movecount = P_Random()&15 only when it moved
                                     ;   (2026-09-23: no read-back of the dir just put)
        beq ?out
        lda RANDOM
        and #15
        ldx #>TH_MCNT
        jsr ai_put
        lda #1                       ; Z=0: it moved (ai_put left the roll in A)
?out    rts
.endp
        .endseg
