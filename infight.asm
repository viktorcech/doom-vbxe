;==============================================================
; infight.asm -- MONSTERS FIGHTING EACH OTHER (2026-08-01).
;   p_inter.c P_DamageMobj's tail + the actor->target half of p_enemy.c that
;   this port never had. enemy_ai.asm owns being alive, enemy.asm owns damage;
;   this file owns WHO a monster is angry at.
;
; WHY IT HAPPENS IN DOOM, from the source in _pomocne/_doomsrc:
;   * a hitscan attack has NO species check at all. p_map.c PTR_ShootTraverse
;     skips only the shooter itself (`if (th == shootthing) return true`, :976)
;     and then damages whatever it hit (:1011). So a zombieman's bullet that
;     finds an imp standing in the way lands in the imp.
;   * P_DamageMobj (p_inter.c:904) then points the victim at the shooter:
;         if ((!target->threshold || target->type == MT_VILE)
;              && source && source != target && source->type != MT_VILE)
;         { target->target = source; target->threshold = BASETHRESHOLD; ... }
;     and drops it into its seestate if it was still asleep.
;   * from there A_Chase reads actor->target like it always did, so the imp
;     walks at the zombieman and claws it instead of the player.
;   PROJECTILES do NOT start fights between the same kind -- p_map.c:299-314
;   makes a missile pass through its own shooter and explode harmlessly on its
;   own species -- but this port has no missile mobj at all (enemy_ai.asm), so
;   the hitscan pair is the whole story here, which is also the common case in
;   DOOM: two shotgunners in a crossfire.
;
; WHAT IS MODELLED, and what is not:
;   * TH_TARG / TH_THRS are mobj_t.target and mobj_t.threshold, per thing.
;   * aif_block is PTR_ShootTraverse reduced to the thing half: the nearest
;     shootable body whose radius the shot line passes through, in front of the
;     shooter and nearer than what it was aiming at. No wall test -- a bullet
;     that would have hit a wall first still finds the monster behind it.
;   * P_LookForPlayers is still "the player": a monster whose target dies falls
;     back to the player, it does not go hunting for a new monster.
;   * the sight test between two monsters IS RUN since 2026-08-25 (aif_isvis ->
;     aif_mvis). It used to be skipped, and the reason was true when it was
;     written: the port's P_CheckSight stand-in was the PLAYER's vissprite list
;     plus a ray built to zp_px/zp_py, and neither says anything about what a
;     monster can see -- so two monsters traded fire through a wall. What
;     changed is the ray's far end: ai_sight aims at TH_TARG now (enemy_ai.asm
;     sg_tgt), which is what p_enemy.c asks for anyway -- every P_CheckSight in
;     that file reads (actor, actor->target). TH_SEEN carries the answer, so
;     this costs no second ray and no new page.
;     What is still not DOOM: the answer is CACHED, one ray a frame over the
;     whole thing table, so a monster whose quarry just stepped behind a pillar
;     keeps firing until its next lap.
;   * the hit/miss roll for the intended target still runs through the player's
;     blur-sphere spread (ai_fire ?hits). Wrong for a monster target, harmless:
;     it only widens the roll.
;   * the PLAYER is not a candidate blocker: aif_block sweeps the thing table,
;     and the player is not in it. So two monsters shooting at each other cannot
;     hit you by accident, which DOOM's trace would. The other direction -- your
;     attacker's bullet landing in the monster in front of it -- is the one that
;     starts fights, and that one is here.
;   * the sprites are rotation 1 only (tools/_walk_budget.py: "monster always
;     faces you"), so a monster never LOOKS like it turned on another monster.
;     Nothing new: the same billboard already faces you while it walks away.
;   * MT_VILE's two exemptions are not here -- there is no arch-vile in E1.
;==============================================================
        org AIFIGHT_BASE

;--------------------------------------------------------------
; aif_reset -- ai_reset's tail: a fresh level starts with everything after the
;   player, no threshold anywhere, and NOTHING IN SIGHT.
;
;   TH_SEEN joins it since 2026-08-25, and it had never been initialised at all:
;   the only writer was ai_look's own ray. Bank $01 is SRAM that survives a level
;   change, so the first frames of every level after the first read the PREVIOUS
;   level's answers -- and the reader is aif_pvis, i.e. "may this monster fire at
;   the off-screen player". One byte of stale $01 there is a shot through a wall.
;   The third page did NOT fit in this loop (7 B against the 3 this block had
;   left), so it is a tail call into the sight hole: sg_seen, enemy_ai.asm.
;--------------------------------------------------------------
.proc aif_reset
        lda #<TH_TARG                ; 0 -- every per-thing page is 256 B aligned
        sta zp_ptr                   ;   (zp_ptr+2 = MAP_EXT_BANK, init_level)
        ldy #0
        tya
?clr    ldx #>TH_TARG
        stx zp_ptr+1
        sta [zp_ptr],y
        ldx #>TH_THRS
        stx zp_ptr+1
        sta [zp_ptr],y
        iny
        bne ?clr
        jmp sg_seen                  ; ...and nothing is in sight of anything
.endp

;--------------------------------------------------------------
; aif_tpos -- ai_tx/ai_ty = where ai_t's target is standing. p_enemy.c reads
;   actor->target->x/y in P_NewChaseDir, P_CheckMeleeRange and A_FaceTarget
;   alike; this port read the player in all three. Clobbers A/Y, sp_ptr, m_prod.
;--------------------------------------------------------------
.proc aif_tpos
        lda #>TH_TARG
        jsr ai_get
        bne ?mon
        lda zp_px
        sta ai_tx
        lda zp_px+1
        sta ai_tx+1
        lda zp_py
        sta ai_ty
        lda zp_py+1
        sta ai_ty+1
        rts
?mon    sec                          ; TH_TARG is index+1, so 0 can mean "player"
        sbc #1
        jsr en_thing.en_th2          ; sp_ptr = that thing's record (x +0, y +2)
        ldy #0
        lda (sp_ptr),y
        sta ai_tx
        iny
        lda (sp_ptr),y
        sta ai_tx+1
        iny
        lda (sp_ptr),y
        sta ai_ty
        iny
        lda (sp_ptr),y
        sta ai_ty+1
        rts
.endp

;--------------------------------------------------------------
; aif_ttick -- A_Chase's first two blocks, for ai_t:
;       if (actor->threshold) { if (!target || target->health <= 0)
;                                   actor->threshold = 0; else actor->threshold--; }
;       if (!target || !(target->flags & MF_SHOOTABLE)) { look again; stand; }
;   The port's "look again" is P_LookForPlayers' answer: the player.
;   OUT A/Z: nonzero = go on thinking, zero = stand still (the player is dead
;   and the player is what it was after -- what A_Chase's spawnstate does).
;--------------------------------------------------------------
.proc aif_ttick
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
        sec
        sbc #1
        tay
        jsr aif_live                 ; is it still MF_SHOOTABLE? P_KillMobj clears
        bcc ?drop                    ;   that the moment the death chain starts
        jsr aif_thdec                ; alive: just count the lock down
        lda #1                       ; ...and a monster fight does not care
        rts                          ;   whether the player is alive
?drop   lda #0                       ; its enemy died -> back to the player
        ldx #>TH_TARG
        jsr ai_put
        lda #0
        ldx #>TH_THRS
        jsr ai_put
        jmp ?pldead
?plr    jsr aif_thdec
?pldead lda pl_dead
        bne ?stand
        lda #1
        rts
?stand  lda #0
        rts
.endp

;--------------------------------------------------------------
; aif_live -- Y = thing index: C=1 if it is still a thing damage and thresholds
;   can count on -- P_KillMobj has not started its death chain (TH_STATE = 0)
;   and it has health left. This is p_inter.c's "target->health <= 0 -> return"
;   plus MF_SHOOTABLE, and it was written out THREE times (aif_ttick, aif_dmg,
;   aif_alive) at 32 B each; one copy and three jsr/bcc is 45 B less.
;   Leaves zp_ptr on the TH_* page pair -- every one of those pages is 256 B
;   aligned, so the low byte is shared and aif_alive can read TH_RAD straight
;   after -- and ai_t3 = TH_HPL. Clobbers A, ai_t3. Preserves X/Y.
;   Contract proved against the three originals over 312 cases:
;   tools/tests/_verify_aiflive.py.
;--------------------------------------------------------------
.proc aif_live
        lda #<TH_STATE
        sta zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?no
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        sta ai_t3
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora ai_t3
        beq ?no
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; aif_thdec -- threshold--, floored at 0. Clobbers A/X/Y.
;--------------------------------------------------------------
.proc aif_thdec
        lda #>TH_THRS
        jsr ai_get
        beq ?out
        sec
        sbc #1
        ldx #>TH_THRS
        jmp ai_put
?out    rts
.endp

;--------------------------------------------------------------
; aif_isvis -- ai_try_atk's P_CheckSight. Against the player it is the port's
;   vissprite oracle; against another monster it is simply true (see the header).
;--------------------------------------------------------------
.proc aif_isvis
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
        sec                          ; a MONSTER target: alive AND in sight, the
        sbc #1                       ;   ray having been aimed at IT since
        tay                          ;   2026-08-25 (enemy_ai.asm sg_tgt).
        jmp aif_mvis                 ;   2026-08-20: p_enemy.c A_SpidRefire
?plr    jmp aif_pvis                 ;   tests `target->health <= 0` in the SAME
.endp                                ;   if as P_CheckSight, and the day the
                                     ;   spider mastermind's refire loop landed
                                     ;   this became a livelock: the spider shot
                                     ;   a cacodemon, the cacodemon died, and it
                                     ;   went on firing into the corpse for ever
                                     ;   -- because A_Chase is the only thing
                                     ;   that drops a dead target (aif_ttick)
                                     ;   and the refire loop never lets A_Chase
                                     ;   run. Free for the other caller:
                                     ;   ai_chase runs aif_ttick immediately
                                     ;   before ai_try_atk, so a target that
                                     ;   reaches THAT aif_isvis is known live.
                                     ; (?plr: drawn this frame -> free yes; off
                                     ;   screen -> the sight RAY (enemy_ai.asm).
                                     ;   This block has no room for the three
                                     ;   instructions, hence the trampoline.)

;--------------------------------------------------------------
; aif_retal -- p_inter.c:904, the four lines that start every fight in DOOM.
;   ai_t = the thing that was just hurt (ai_hurt has already stored it),
;   ai_src = whoever hurt it, +1 (0 = the player). Clobbers A/X/Y.
;--------------------------------------------------------------
.proc aif_retal
        lda ai_src
        beq ?gate                    ; the player is always a legal target
        sec
        sbc #1
        cmp ai_t
        beq ?out                     ; `source != target`: nothing fights itself,
                                     ;   which is what keeps splash damage from
                                     ;   making a thing chase its own explosion
?gate   lda #>TH_THRS                ; `!target->threshold` -- still locked on
        jsr ai_get                   ;   whoever it is already fighting
        bne ?out
        lda ai_src
        ldx #>TH_TARG
        jsr ai_put
        lda #AI_THRESH
        ldx #>TH_THRS
        jsr ai_put
        lda #>TH_WROW                ; P_SetMobjState(target, seestate): a monster
        jsr ai_get                   ;   that was still asleep joins in
        bne ?out
        lda snd_pending              ; ...silently. ai_start is A_Look's entry and
        pha                          ;   yells; P_DamageMobj only sets the state,
        jsr ai_start                 ;   the sight sound belongs to A_Look alone
        pla
        sta snd_pending
?out    rts
.endp

;--------------------------------------------------------------
; aif_hurt -- ai_fire's damage sink. A = damage, ai_t = the monster firing,
;   ai_vic = a body the shot stopped in ($FF = it reached what it aimed at).
;--------------------------------------------------------------
.proc aif_hurt
        sta ai_t3                    ; the damage, across the target lookup
        lda ai_vic
        cmp #$FF
        bne ?body
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
        sec
        sbc #1
        jmp ?dmg
?plr    lda ai_t3
        jmp en_plr_hurt
?body   lda ai_vic
?dmg    sta ai_vt
        lda ai_t3
        jmp aif_dmg
.endp

;--------------------------------------------------------------
; aif_dmg -- P_DamageMobj with a THING for a target. A = damage, ai_vt = the
;   victim, ai_t = the source. en_bhit already owns the health arithmetic and
;   the death chain; what is added here is the voice, the flinch and the
;   retaliation. ai_t/ai_k are the CALLER's -- ai_hurt stores the victim over
;   ai_t and ai_start rewrites ai_k -- so both are saved across it.
;--------------------------------------------------------------
.proc aif_dmg
        sta ai_t4
        ldy ai_vt                    ; "if (target->health <= 0) return" -- the
        jsr aif_live                 ;   second and third pellets of a shotgun
        bcc ?out                     ;   must not restart a death chain that the
                                     ;   first one already started
        lda ai_t                     ; the source, the way P_DamageMobj takes it
        pha
        lda ai_k
        pha
        clc
        lda ai_t
        adc #1
        sta ai_src
        lda ai_vt
        sta en_bi
        lda ai_t4
        jsr en_bhit                  ; health -= damage; en_bkill at 0
        ldy ai_vt                    ; did it survive?
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        sta ai_t3
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora ai_t3
        beq ?done
        lda ai_vt                    ; its voice needs the kind byte, and a
        jsr en_thing.en_th2          ;   sleeping thing has none cached yet
        ldy #6
        lda (sp_ptr),y
        jsr en_kind_of
        jsr en_hurt_snd              ; the painchance roll -> en_painr
        ldy ai_vt
        jsr ai_hurt                  ; reactiontime = 0, MF_JUSTHIT -- and
                                     ;   aif_retal, which is what turns it round
?done   lda #0
        sta ai_src
        pla
        sta ai_k
        pla
        sta ai_t
?out    rts
.endp

;--------------------------------------------------------------
; aif_block -- p_map.c PTR_ShootTraverse, thing half only. ai_t is about to fire
;   a hitscan at ai_tx/ai_ty; find the nearest shootable body the line passes
;   through and put it in ai_vic ($FF = the line is clear).
;
;   The test is the perpendicular distance from the candidate to the line of
;   fire, without a square root and without a divide:
;       |dx*cy - dy*cx|  <  radius * |d|
;   where d is shooter->target, c is shooter->candidate and |d| is DOOM's own
;   P_AproxDistance. cross_pos (math.asm) already computes exactly that cross
;   product into cx_p1, so this costs three 16x16 multiplies per survivor and
;   nothing at all for the things the distance test throws out first.
;   Candidates must be NEARER than the target (so the target itself never
;   blocks its own shot) and in FRONT of the shooter along the dominant axis.
;   Barrels are shootable and have a radius, so a bullet finds one -- which is
;   what DOOM does too, chain and all.
;--------------------------------------------------------------
.proc aif_block
        lda #$FF
        sta ai_vic
        sta ai_bbest
        lda ai_t                     ; where the shooter stands
        jsr en_thing.en_th2
        ldy #0
        lda (sp_ptr),y
        sta ai_bx0
        iny
        lda (sp_ptr),y
        sta ai_bx0+1
        iny
        lda (sp_ptr),y
        sta ai_by0
        iny
        lda (sp_ptr),y
        sta ai_by0+1
        sec                          ; d = target - shooter
        lda ai_tx
        sbc ai_bx0
        sta ai_bdx
        lda ai_tx+1
        sbc ai_bx0+1
        sta ai_bdx+1
        sec
        lda ai_ty
        sbc ai_by0
        sta ai_bdy
        lda ai_ty+1
        sbc ai_by0+1
        sta ai_bdy+1
        lda ai_bdx
        sta ai_alx
        lda ai_bdx+1
        sta ai_alx+1
        lda ai_bdy
        sta ai_aly
        lda ai_bdy+1
        sta ai_aly+1
        jsr aif_alen                 ; |d|, and which axis the shot runs along
        lda ai_axmaj
        sta ai_bmaj
        lda ai_alen                  ; the cutoff starts at the target's own
        sta ai_bbd                   ;   distance and shrinks to the nearest
        lda ai_alen+1                ;   blocker found so far
        sta ai_bbd+1
        lda ai_alen
        sta ai_blen
        lda ai_alen+1
        sta ai_blen+1
        lda #0
        sta ai_bi
?lp     lda ai_bi                    ; the sweep is split across three procs
        cmp THINGS_BASE              ;   only because a 6502 branch reaches 127
        bcs ?done                    ;   bytes and one straight-line body does not
        cmp ai_t
        beq ?next                    ; p_map.c:976, "can't shoot self"
        jsr aif_alive                ; is it a thing a bullet can stop in?
        bcc ?next
        jsr aif_cand                 ; ...and is it in the way?
        bcc ?next
        jsr aif_bvis                 ; ...and not behind a wall or a shut door
        bcc ?next
        lda ai_bi                    ; a hit, and the nearest one yet
        sta ai_bbest
        lda ai_alen
        sta ai_bbd
        lda ai_alen+1
        sta ai_bbd+1
?next   inc ai_bi
        bne ?lp
?done   lda ai_bbest
        sta ai_vic
        rts
.endp

;--------------------------------------------------------------
; aif_bvis -- thing ai_bi: C=1 if it is in this frame's vissprite list. The
;   header note above says aif_block has "no wall test" -- and that was a real
;   bug, not a shortcut: a stray monster bullet swept the WHOLE thing table,
;   so on any level it could wound a monster parked behind a wall or a CLOSED
;   door, and the pain wake made it scream and chase through a door that never
;   opened (2026-08-04, "imp ma vidi aj cez dvere"). The port's P_CheckSight is the
;   player's vissprite list everywhere else (ai_wake, aif_isvis), and a body
;   that could stop this bullet lies ON the shooter->target line, so if it is
;   not on screen there is a wall or a shut door in front of it. spr_add drops
;   fully-occluded sprites, which is what makes this test mean "reachable".
;--------------------------------------------------------------
.proc aif_bvis
        ldx sp_n
?lp     dex
        bmi ?no
        lda vs_th,x
        cmp ai_bi
        bne ?lp
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; aif_alive -- thing ai_bi: C=1 and ai_brad = its radius if a shot can stop in
;   it. en_bthings' own liveness pair (not already dying, health left) plus the
;   MF_SOLID radius -- p_map.c:979 lets a corpse or a pickup through.
;--------------------------------------------------------------
.proc aif_alive
        ldy ai_bi
        jsr aif_live                 ; not dying, health left (aif_live leaves
        bcc ?no                      ;   zp_ptr on the TH_* page for the radius)
        lda #>TH_RAD
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?no
        sta ai_brad
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; aif_cand -- thing ai_bi against the line of fire. C=1 = the shot stops here,
;   and ai_alen is its distance from the shooter (the loop's new cutoff).
;--------------------------------------------------------------
.proc aif_cand
        lda ai_bi                    ; c = candidate - shooter
        jsr en_thing.en_th2
        ldy #0
        sec
        lda (sp_ptr),y
        sbc ai_bx0
        sta ai_bcx
        iny
        lda (sp_ptr),y
        sbc ai_bx0+1
        sta ai_bcx+1
        iny
        sec
        lda (sp_ptr),y
        sbc ai_by0
        sta ai_bcy
        iny
        lda (sp_ptr),y
        sbc ai_by0+1
        sta ai_bcy+1
        lda ai_bmaj                  ; in FRONT of the shooter? the dominant axis
        beq ?ymaj                    ;   decides -- anything sideways enough for
        lda ai_bcx+1                 ;   this to be wrong is thrown out by the
        eor ai_bdx+1                 ;   perpendicular test anyway
        bmi ?no
        jmp ?dist
?ymaj   lda ai_bcy+1
        eor ai_bdy+1
        bmi ?no
?dist   lda ai_bcx                   ; nearer than the target, and than the best
        sta ai_alx                   ;   blocker so far?
        lda ai_bcx+1
        sta ai_alx+1
        lda ai_bcy
        sta ai_aly
        lda ai_bcy+1
        sta ai_aly+1
        jsr aif_alen
        sec
        lda ai_alen
        sbc ai_bbd
        lda ai_alen+1
        sbc ai_bbd+1
        bcs ?no
        jmp aif_perp
?no     clc
        rts
.endp

;--------------------------------------------------------------
; aif_perp -- the line test itself: C=1 when |dx*cy - dy*cx| < radius * |d|,
;   i.e. the shot passes closer to the candidate's centre than its own radius.
;   cross_pos (math.asm) leaves the full signed 32-bit cross product in cx_p1.
;--------------------------------------------------------------
.proc aif_perp
        lda ai_bdx
        sta cx_a
        lda ai_bdx+1
        sta cx_a+1
        lda ai_bcy
        sta cx_b
        lda ai_bcy+1
        sta cx_b+1
        lda ai_bdy
        sta cx_c
        lda ai_bdy+1
        sta cx_c+1
        lda ai_bcx
        sta cx_d
        lda ai_bcx+1
        sta cx_d+1
        jsr cross_pos
        lda cx_p1+3
        bpl ?abs
        sec                          ; |cross|
        lda #0
        sbc cx_p1
        sta cx_p1
        lda #0
        sbc cx_p1+1
        sta cx_p1+1
        lda #0
        sbc cx_p1+2
        sta cx_p1+2
        lda #0
        sbc cx_p1+3
        sta cx_p1+3
?abs    ldx #3                       ; park it: umul16 below reuses m_prod
?sv     lda cx_p1,x
        sta ai_bcr,x
        dex
        bpl ?sv
        lda ai_brad                  ; radius * |d|
        sta m_a
        lda #0
        sta m_a+1
        lda ai_blen
        sta m_b
        lda ai_blen+1
        sta m_b+1
        jsr umul16
        sec
        lda ai_bcr
        sbc m_prod
        lda ai_bcr+1
        sbc m_prod+1
        lda ai_bcr+2
        sbc m_prod+2
        lda ai_bcr+3
        sbc m_prod+3
        bcc ?yes
        clc
        rts
?yes    sec
        rts
.endp

;--------------------------------------------------------------
; aif_alen -- m_fixed.c P_AproxDistance of ai_alx/ai_aly (signed 16): the larger
;   magnitude whole plus half the smaller. Leaves ai_axmaj = 1 when x is the
;   dominant axis, which is what the "in front" test above reads.
;   OUT ai_alen. Clobbers A, ai_aax/ai_aay/ai_t4.
;--------------------------------------------------------------
.proc aif_alen                          ; THE THUNK -- see bank01.asm.
        jsl B1CODE_BASE+b1_aif_alen
        rts                          ; the tail call comes back through the rts
.endp

; ---- scratch, all of it inside this block ----------------------------------
ai_tx    dta 0,0                     ; where ai_t's TARGET stands (aif_tpos)
ai_ty    dta 0,0
ai_src   dta 0                       ; P_DamageMobj's `source`, +1 (0 = player)
ai_vic   dta $FF                     ; the body a shot stopped in ($FF = none)
ai_vt    dta 0                       ; ...resolved to an actual thing index
ai_t3    dta 0                       ; scratch that survives ai_put (which eats
ai_t4    dta 0                       ;   ai_t2) and ai_pdist
ai_bx0   dta 0,0                     ; aif_block: the shooter
ai_by0   dta 0,0
ai_bdx   dta 0,0                     ; ...to its target
ai_bdy   dta 0,0
ai_bcx   dta 0,0                     ; ...to the candidate
ai_bcy   dta 0,0
ai_blen  dta 0,0                     ; |d|, the full length of the shot
ai_bbd   dta 0,0                     ; the best (nearest) blocker's distance
ai_bbest dta $FF                     ; ...and which thing that was
ai_bi    dta 0                       ; the sweep cursor
ai_brad  dta 0                       ; the candidate's radius
ai_bmaj  dta 0                       ; 1 = the shot runs mostly along x
ai_bcr   dta 0,0,0,0                 ; |cross product|, parked across umul16
ai_alx   dta 0,0                     ; aif_alen in/out
ai_aly   dta 0,0
ai_alen  dta 0,0
ai_aax   dta 0,0
ai_aay   dta 0,0
ai_ahalf dta 0,0                     ; the smaller magnitude, halved (16-bit)
ai_axmaj dta 0

    .if * > AIFIGHT_END+1
        ert 'infight.asm outgrew AIFIGHT_BASE..END (memory_map.inc)'
    .endif
