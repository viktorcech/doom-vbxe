;--------------------------------------------------------------
; enemy_ai.asm -- monsters that wake up and chase (p_enemy.c A_Look + A_Chase),
;   one think per RUN state at info.c's own tics.
;--------------------------------------------------------------
        org AI_BASE

;--------------------------------------------------------------
; ai_reset -- from init_level: nothing chases in a fresh level. Clearing
;   TH_WROW is what actually stops it -- everything else keys on that page.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_reset
        lda #$FF
        sta sl_th                    ; no corpse is sliding on a fresh level --
                                     ;   a stale index here would shove whatever
                                     ;   thing wears it now (en_slide)
        stz ai_dn                    ; nothing to re-attach either
                                      ; 2026-09-22 (65816-style: a byte sweep read as words)
        ldx #0
        rep #$20
        .LONGA ON
?gc     stz ai_dcnt,x                ; ...and spr_chase's gate with it
        inx
        inx
        bne ?gc
        sep #$20
        .LONGA OFF
        stz zp_ptr                   ; 65816 stz: every TH_ page is 256 B
                                     ;   aligned, so the low byte is 0
        lda #>TH_WROW                ; zp_ptr+2 is MAP_EXT_BANK already: init_level
        sta zp_ptr+1                 ;   sets it and nothing else writes it
        ldy #0
        tya
?clr    sta [zp_ptr],y
        iny
        bne ?clr
        lda THINGS_BASE              ; n_things (pack_things header, <= 255):
        inc @                        ;   ai_tick / en_tick sweep the pairs below
        and #$FE                     ;   it only. Rounded up to even; 255 -> 0
        sta ai_lim                   ;   = the whole page, as before (Y wraps)
        sta.l B1CODE_BASE+ai_tick.ait_lim+1    ; 2026-09-26: the two sweeps compare
        sta.l B1CODE_BASE+ai_tick.ait_lim2+1   ;   against an immediate now
        sta.l B1CODE_BASE+en_tick.ent_lim+1
        sta.l B1CODE_BASE+en_tick.ent_lim2+1
        jmp aif_reset                ; ...and nothing is angry at anything either
.endp
        .endseg

;--------------------------------------------------------------
; ai_wake -- A_Look, once per FRAME over the vissprites the BSP walk collected.
;   Runs in the game loop, not the render path, so clobbering zp_ptr is safe.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_wake
        ldx sp_n
        beq ?out
                                      ; 2026-09-22 idiom: ai_bank INLINED (an 8-cycle
        stz zp_ptr                   ;   body under a 12-cycle jsr/rts; A is dead
        lda #>TH_WROW                ;   across it -- the callee clobbered it too)
        sta zp_ptr+1                 ; TH_WROW page for the whole scan; the
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
                                      ; 2026-09-22 p_enemy.c:535-550: the 90-degree cut
        phx                          ;   and "real close, react anyway", the rule
        jsr ai_front                 ;   ai_look's ray uses (X = the vissprite;
        plx                          ;   plx leaves ai_front's C alone)
        bcs ?back
                                     ;   ai_front runs, so slots 0 and 1 (the
                                     ;   front and 3/4-front views) react and
                                     ;   the profile and the back do not.
?wake   jsr ai_wseen                 ; ...and is its MIDDLE column open? then wake
?back   stz zp_ptr                   ; the scan's page back (ai_ismon/ai_start
    .if [TH_WROW & $FF] != 0         ;   moved both bytes; <TH_WROW = 0)
        ert 'TH_WROW is not page-aligned -- put the lda #< back (enemy_ai.asm)'
    .endif
        lda #>TH_WROW
        sta zp_ptr+1
        bra ?lp
?out    lda ai_noise                 ; the shot's alert fades. DOOM's is a
        beq ?done                    ;   soundtarget stored PER SECTOR by
        dec ai_noise                 ;   P_RecursiveSound and it never expires;
?done   rts                          ;   one global countdown is the stand-in
.endp                                ;   (see ai_noise).
        .endseg

;--------------------------------------------------------------
; ai_wseen -- ai_wake's tail, out in free RAM (the AI block has four bytes left).
;   X = the vissprite, ai_t = its thing: wake it only if the sprite's MIDDLE
;   column survived the nearer geometry.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
                                      ; 2026-09-22: seestate's A_Chase runs at once;
        phx                          ;   the vissprite cursor rides the stack
        jsr ai_see
        plx
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_front -- C=0 if thing ai_t is LOOKING AT the player, C=1 if the player is
;   behind it. p_enemy.c's P_LookForPlayers(actor, FALSE) drops a player more
;   than 90 degrees off the monster's own angle -- "behind back" -- unless he
;   is inside MELEERANGE, and A_Look is the only caller that passes FALSE.
;   Clobbers A/X/Y, sp_ptr, zp_ptr and the swr_* render scratch (the AI owns
;--------------------------------------------------------------
;--------------------------------------------------------------
; ai_door -- p_enemy.c P_Move's tail: a step P_TryMove refuses because a LINE
;   is in the way is not the end of it --
;       while (numspechit--) if (P_UseSpecialLine (actor, spechit[..], 0)) ...
;   -- and P_UseSpecialLine lets a monster work special 1 (a plain DR door)
;   Clobbers A/X/Y, m_a, m_prod. Called only on a blocked step.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
                                     ;   the monster list is 1/32/33/34 only.
        lda.l DOOR_STATE,x           ; "JDC: bad guys never close doors"
        beq ?go                      ;   (p_doors.c:249) -- shut: open it;
        cmp #3                       ;   closing: send it back up; already
        bne ?out                     ;   opening or open: LEAVE IT, or a
?go     txa                          ;   monster stood in the doorway would
        jmp snd_door_toggle          ;   toggle it shut every single tic
?out    rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_front                       ; (A_Look's soundtarget half is ai_heard)
        jsr aif_oct                  ; swr_vx/vy = monster -> its target, which
        lda #>TH_DIR                 ;   for an IDLE one is the player (TH_TARG
        jsr ai_get                   ;   0, aif_reset); swr_ax/ay = the |legs|
        tay                          ; DOOM's 90-degree cut = the SIGN of
        and #3                       ;   facing . vector. The facing is one of
        tax                          ;   eight, so the dot is a sum:
        rep #$20                     ;   E vx, NE vx+vy, N vy, NW vy-vx
        .LONGA ON
        lda #$0000
        cpx #2
        beq ?y                       ; N: no x term
        lda swr_vx
        bcc ?y                       ; E, NE: +vx
        eor #$FFFF                   ; NW: -vx
        inc @
?y      cpx #1
        bcc ?s                       ; E: no y term
        clc
        adc swr_vy
?s      cpy #4                       ; W, SW, S, SE are those four negated
        bcc ?t
        eor #$FFFF
        inc @
?t      asl @                        ; C = the dot's sign; C=0: it is facing you
        sep #$20
        .LONGA OFF
        bcc ?out
        lda swr_ax                   ; "if real close, react anyway": DOOM
        ora swr_ay                   ;   prices that with P_AproxDistance, this
        cmp #MELEERANGE              ;   with max(|dx|,|dy|) -- and against a
                                     ;   POWER OF TWO the or IS the max compare.
?out    rts
.endp
        .endseg

; ---- A_Look's real half. Split out 2026-09-21 like the enemy_ai_* files at the
;      bottom: included HERE, in the original order, so the assembler sees the
;      same text in the same place and emits the same bytes.
aiwake_resume = *
        icl 'enemy_ai_sight.asm'


        icl 'enemy_ai_blk.asm'
        icl 'enemy_ai_look.asm'

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
                                     ;   is already chasing (then the ray only ...
        .endseg
                                     ; THE GUARD USED TO READ `SIGHT_VARS+32` ...
        org aiwake_resume

;--------------------------------------------------------------
; ai_bank -- zp_ptr = TH_WROW. Every per-thing AI page is 256 B and page
;   aligned, so switching between them is one store to zp_ptr+1; this sets the
;   common case and the callers step the high byte from there.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_bank
        stz zp_ptr
        lda #>TH_WROW
        sta zp_ptr+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_ismon -- ai_t = thing index. Z=0 if it is a monster, alive, and not already
;   dying: TH_HP nonzero (pack_things only gives health to MF_SHOOTABLE) and
;   TH_STATE zero (enemy.asm's death chain owns anything else).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

;--------------------------------------------------------------
; ai_start -- ai_t = thing index: put it into the chase. Caches the kind byte
;   (TH_KIND) so the per-tic path never has to walk the sprite table again,
;   enters RUN state 0 with that kind's tics, and leaves movecount 0 / DI_NODIR
;   so the first A_Chase picks a direction with no turnaround to avoid.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_start
        stz zp_ptr                   ; (2026-09-22: ai_bank inlined, see ai_look)
        ldy ai_t                     ;   every thing at level init, so the wake
        lda #>TH_KIND                ;   needs no sprite-table walk any more
        sta zp_ptr+1
        lda [zp_ptr],y
        sta en_kind                  ; (en_kind_of used to leave it here)
        sta ai_k                     ; ...and ai_k: the mk_rt read below used a
                                     ;   STALE ai_k from the previous ai_setrow ...
        beq ?no                      ; kind 0 = not a monster after all
        tax
        lda mk_ctic,x                ; a kind with no RUN states (the barrel)
        beq ?no                      ;   never chases
                                     ; (TH_KIND already holds the kind -- the
                                     ;   prefill wrote it, nothing to cache)
        ldx #>TH_WTIC                ; (A keeps the tics: the page goes via X,
        stx zp_ptr+1                 ;   which ai_k reloads below; Y = ai_t
        sta [zp_ptr],y               ;   from the top, all the way down)
        lda #0
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
                                     ;   reactiontime = info.c's.
                                     ;   at SPAWN and only A_Chase counts it down,
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
        bcc ?pick                    ; (C = 1 past it: no sec)
        sbc mk_seen,x
?pick   clc
        adc mk_see,x
        jmp snd_qp_ai                ; tail call -- (STEREO: ai_t saw -- sound.asm)
?one    lda mk_see,x
        jsr snd_qp_ai
?no     rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_setrow -- ai_t = thing: TH_WROW = the walk row its current RUN state draws.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_setrow
        stz zp_ptr                   ; (2026-09-22: ai_bank inlined, see ai_look)
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
                                     ;   above; the shift counted in Y), and ...
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
                                     ; 2026-09-21 (drac030: [dp] without the index): Y is
        lda [zp_ptr]                 ;   reloaded at ?flat on BOTH ways out, so the
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
        sec                          ; + ai_t2 + 1: TH_WROW is row+1 (0 means "not
        adc ai_t2                    ;   chasing"), the +1 rides in on C
        stz zp_ptr                   ; ai_bank inlined, the page via X so the row
        ldx #>TH_WROW                ;   stays in A (X is clobbered here anyway;
        stx zp_ptr+1                 ;   no caller reads A, ai_t2 or the flags)
        ldy ai_t
        sta [zp_ptr],y
        rts
.endp
        .endseg

        icl 'enemy_ai_chase.asm'
        icl 'enemy_ai_track.asm'

ai_resume = *                        ; BEFORE the org, never after: `org label`
                                     ;   with the label defined below it resolves ...
        org MKTAB_BASE               ; per-kind info.c data: the SFX + painchance
        icl 'mk_tables.inc'          ; enemy.asm reads, and the RUN-state timing,
                                     ; P_Move steps and A_Look grunts this file
                                     ; reads.

;--------------------------------------------------------------
; en_bdist -- p_map.c PIT_RadiusAttack's FIRST test, which this port did not
;   have, in front of the one it did:
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bdist                       ; en_bi = the candidate. C=0 = no damage.
        ldy en_bi                    ; zp_ptr's low byte is 0 already: every
        lda #>TH_RAD                 ;   per-thing page is 256 B aligned and
        sta zp_ptr+1                 ;   en_bthings left it on one
        lda [zp_ptr],y
        cmp #MK_NOBLAST_R
        bcs ?no
        jmp en_dray                  ; ordinary thing -> PIT_RadiusAttack proper,
                                     ;   range test AND P_CheckSight (enemy.asm)
?no     clc                          ; a boss: `return true`, no damage, no kick
        rts                          ;   (a jmp and not a branch: en_dist is at
.endp                                ;    $EA68 and this block is at $3D9C)
        .endseg
    .if * > MKTAB_END+1
        ert 'mk_tables.inc outgrew MKTAB_BASE..END (memory_map.inc)'
    .endif
        org ai_resume

; ---- scratch. Lives INSIDE the AI block (the way enemy.asm parks en_bx/en_by
;   in its own): it is all cold -- touched once per state change, never in the
;   render path -- and base RAM has nothing to spare outside this hole.
                                     ; 2026-09-21: in page 1 now (bsp_main.asm): fast writes
; (ai_t2 moved to memory_map.inc's D0 block, 2026-09-26: out of the $5600 write-through window)
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
NOISE_FR equ 30                      ; ~1 s: long enough for ai_look's
                                     ;   round-robin ray to reach several ...

;--------------------------------------------------------------
; ai_noisealert -- A = the weapon's SFX id.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_noisealert
        sta snd_pending
        lda #NOISE_FR
        sta ai_noise
        rts
.endp
        .endseg
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
        .segment D0
ai_dth  :AI_DMAX dta 0               ; the chaser's thing index
ai_dsl  :AI_DMAX dta 0               ; the subsector it is standing in, low
ai_dsh  :AI_DMAX dta 0               ; ...and high
ai_dcnt :256 dta 0                   ; entries per subsector LOW BYTE: spr_chase's
        .endseg                      ;   gate. Only ai_track and ai_reset write it.

;--------------------------------------------------------------
; aif_pchk -- the PLAYER half of A_SpidRefire's "is there still a target".
;   In DOOM a dead player loses MF_SHOOTABLE, A_Chase sees that on its very
;   OUT: Z=1 -> no player left to shoot at (the carry means nothing).
;        Z=0 -> C is ai_isvis' answer. `lda` does not touch the carry, which is
;               what lets one register bring back both halves.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_pchk
        lda pl_dead
        bne ?dead
        jsr ai_isvis                 ; drawn this frame -> visible, for free
        lda #1
        rts
?dead   lda #0
        rts
.endp
        .endseg

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
