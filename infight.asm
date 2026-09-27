;--------------------------------------------------------------
; infight.asm -- monsters fighting each other (P_DamageMobj's tail +
;   actor->target): who a monster is angry at.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; aif_reset -- ai_reset's tail: a fresh level starts with everything after the
;   player, no threshold anywhere, and NOTHING IN SIGHT.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

;--------------------------------------------------------------
; aif_tpos -- ai_tx/ai_ty = where ai_t's target is standing. p_enemy.c reads
;   actor->target->x/y in P_NewChaseDir, P_CheckMeleeRange and A_FaceTarget
;   alike; this port read the player in all three. Clobbers A/Y, sp_ptr, m_prod.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_tpos
        lda #>TH_TARG
        jsr ai_get
        bne ?mon
	rep #$20
	.LONGA ON
        lda zp_px
        sta ai_tx
        lda zp_py
        sta ai_ty
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
	.LONGA OFF
        rts
?mon
	dec
        jsr en_thing.en_th2w          ; sp_ptr = that thing's record (x +0, y +2)
	.LONGA ON
        lda (sp_ptr)
        sta ai_tx
	ldy #2
        lda (sp_ptr),y
        sta ai_ty
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_ttick -- A_Chase's first two blocks, for ai_t:
;       if (actor->threshold) { if (!target || target->health <= 0)
;   OUT A/Z: nonzero = go on thinking, zero = stand still (the player is dead
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_ttick
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
	dec
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
	bra ?pldead
?plr    jsr aif_thdec
?pldead lda pl_dead
        bne ?stand
        lda #1
        rts
?stand  lda #0
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_live -- Y = thing index: C=1 if it is still a thing damage and thresholds
;   can count on -- P_KillMobj has not started its death chain (TH_STATE = 0)
;   after -- and ai_t3 = TH_HPL. Clobbers A, ai_t3. Preserves X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_live
        stz zp_ptr                   ; <TH_STATE = 0 (every per-thing page is
    .if [TH_STATE & $FF] != 0        ;   256 B aligned: ert)
        ert 'aif_live: TH_STATE is not page-aligned -- put the lda #< back'
    .endif
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
        .endseg

;--------------------------------------------------------------
; aif_thdec -- threshold--, floored at 0. Clobbers A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_thdec
        lda #>TH_THRS
        jsr ai_get
        beq ?out
	dec
        ldx #>TH_THRS
        jmp ai_put
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_isvis -- ai_try_atk's P_CheckSight. Against the player it is the port's
;   vissprite oracle; against another monster it is simply true (see the header).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_isvis
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
	dec
        tay                          ;   2026-08-25 (enemy_ai.asm sg_tgt).
        jmp aif_mvis                 ;   2026-08-20: p_enemy.c A_SpidRefire
?plr    jmp aif_pvis                 ;   tests `target->health <= 0` in the SAME
.endp                                ;   if as P_CheckSight, and the day the
        .endseg
                                     ;   spider mastermind's refire loop landed ...

;--------------------------------------------------------------
; aif_retal -- p_inter.c:904, the four lines that start every fight in DOOM.
;   ai_t = the thing that was just hurt (ai_hurt has already stored it),
;   ai_src = whoever hurt it, +1 (0 = the player). Clobbers A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_retal
        lda ai_src
        beq ?gate                    ; the player is always a legal target
	dec
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
                                      ; 2026-09-22: TH_SEEN is the ray to the OLD target;
        lda #1                       ;   the hit is the sight line to the new one,
        ldx #>TH_SEEN                ;   until ai_look's next ray (P_CheckSight in the
        jsr ai_put                   ;   next A_Chase, p_enemy.c:201)
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
        .endseg

;--------------------------------------------------------------
; aif_hurt -- ai_fire's damage sink. A = damage, ai_t = the monster firing,
;   ai_vic = a body the shot stopped in ($FF = it reached what it aimed at).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_hurt
        sta ai_t3                    ; the damage, across the target lookup
        lda ai_vic
        cmp #$FF
        bne ?body
        lda #>TH_TARG
        jsr ai_get
        beq ?plr
	dec
	bra ?dmg
                                      ; 2026-09-22 P_DamageMobj(player, actor, actor):
?plr    lda ai_t                     ;   the attacker, +1, for P_DeathThink's turn
        inc @
        sta pl_src
        lda ai_t3
        jmp en_plr_hurt
?body   lda ai_vic
?dmg    sta ai_vt
        lda ai_t3
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>aif_dmg              ;   next byte of this segment -- fall through
.endp
        .endseg

;--------------------------------------------------------------
; aif_dmg -- P_DamageMobj with a THING for a target. A = damage, ai_vt = the
;   victim, ai_t = the source. en_bhit already owns the health arithmetic and
;   the death chain; what is added here is the voice, the flinch and the
;   retaliation. ai_t/ai_k are the CALLER's -- ai_hurt stores the victim over
;   ai_t and ai_start rewrites ai_k -- so both are saved across it.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        lda ai_t
        inc
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
        sta en_last                  ;   (STEREO: en_hurt_snd pans from en_last)
        jsr en_thing.en_th2          ;   sleeping thing has none cached yet

        ldy #6
        lda (sp_ptr),y
        jsr en_kind_of
        jsr en_hurt_snd              ; the painchance roll -> en_painr
        ldy ai_vt
        jsr ai_hurt                  ; reactiontime = 0, MF_JUSTHIT -- and
                                     ;   aif_retal, which is what turns it round
?done
        stz ai_src
        pla
        sta ai_k
        pla
        sta ai_t
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_block -- p_map.c PTR_ShootTraverse, thing half only. ai_t is about to fire
;   a hitscan at ai_tx/ai_ty; find the nearest shootable body the line passes
;   through and put it in ai_vic ($FF = the line is clear).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_block
        lda #$FF
        sta ai_vic
        sta ai_bbest
        lda ai_t                     ; where the shooter stands
        jsr en_thing.en_th2w          ; 2026-09-22: returns 16-bit
	.LONGA ON
        lda (sp_ptr)
        sta ai_bx0
        ldy #2
        lda (sp_ptr),y
        sta ai_by0

        sec                          ; d = target - shooter (A still holds each
        lda ai_tx                    ;   difference for the ai_al* copy)
        sbc ai_bx0
        sta ai_bdx
        sta ai_alx

        sec
        lda ai_ty
        sbc ai_by0
        sta ai_bdy
        sta ai_aly

	sep #$20
	.LONGA OFF
        jsr aif_alen                 ; |d|, and which axis the shot runs along

        lda ai_axmaj
        sta ai_bmaj
	rep #$20
	.LONGA ON
        lda ai_alen                  ; the cutoff starts at the target's own
        sta ai_bbd                   ;   distance and shrinks to the nearest
        sta ai_blen
	sep #$20
	.LONGA OFF
	stz ai_bi
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
        .endseg

;--------------------------------------------------------------
; aif_bvis -- thing ai_bi: C=1 if it is in this frame's vissprite list.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

;--------------------------------------------------------------
; aif_alive -- thing ai_bi: C=1 and ai_brad = its radius if a shot can stop in
;   it. en_bthings' own liveness pair (not already dying, health left) plus the
;   MF_SOLID radius -- p_map.c:979 lets a corpse or a pickup through.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_alive
        ldy ai_bi
        jsr aif_live                 ; not dying, health left (aif_live leaves
        bcc ?no                      ;   zp_ptr on the TH_* page for the radius)
        lda #>TH_RAD
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?no
        sta ai_brad
                                      ; 2026-09-22 idiom: C = 1 already -- the not-taken
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_cand -- thing ai_bi against the line of fire. C=1 = the shot stops here,
;   and ai_alen is its distance from the shooter (the loop's new cutoff).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_cand
        lda ai_bi                    ; c = candidate - shooter
        jsr en_thing.en_th2w          ; 2026-09-22: returns 16-bit
	.LONGA ON
	sec
	lda (sp_ptr)
	sbc ai_bx0
	sta ai_bcx

	ldy #2
	sec
        lda (sp_ptr),y
        sbc ai_by0
        sta ai_bcy
	sep #$20
	.LONGA OFF
        lda ai_bmaj                  ; in FRONT of the shooter? the dominant axis
        beq ?ymaj                    ;   decides -- anything sideways enough for
        lda ai_bcx+1                 ;   this to be wrong is thrown out by the
        eor ai_bdx+1                 ;   perpendicular test anyway
        bmi ?no
	bra ?dist
?ymaj   lda ai_bcy+1
        eor ai_bdy+1
        bmi ?no
?dist
	rep #$20
	.LONGA ON
	lda ai_bcx                   ; nearer than the target, and than the best
        sta ai_alx                   ;   blocker so far?
        lda ai_bcy
        sta ai_aly
	sep #$20
	.LONGA OFF
        jsr aif_alen
        lda ai_alen
        cmp ai_bbd
        lda ai_alen+1
        sbc ai_bbd+1
        bcc aif_perp 
        ;bra aif_perp
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_perp -- the line test itself: C=1 when |dx*cy - dy*cx| < radius * |d|,
;   i.e. the shot passes closer to the candidate's centre than its own radius.
;   cross_pos (math.asm) leaves the full signed 32-bit cross product in cx_p1.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_perp
	rep #$20
	.LONGA ON
        lda ai_bdx
        sta cx_a

        lda ai_bcy
        sta cx_b

        lda ai_bdy
        sta cx_c

        lda ai_bcx
        sta cx_d
                                     ; 2026-09-22 (65816-windows): cross_pos past its
        jsr cross_pos.cp_w16         ;   rep, still 16-bit
        .LONGA OFF

        lda cx_p1+3
	rep #$20
	.LONGA ON
	bpl ?abs

        sec                          ; |cross|
        lda #0
        sbc cx_p1
        sta cx_p1
        lda #0
        sbc cx_p1+2
        sta cx_p1+2

                                      ; 2026-09-22 (65816-idioms: pei): |cross| parked
?abs    pei (cx_p1+2)                ;   on the stack straight from zero page, high
        pei (cx_p1)                  ;   word first so the low word comes back first

        lda ai_brad                  ; radius * |d|
	and #$00ff
        sta m_a
        lda ai_blen
        sta m_b

	sep #$20
	.LONGA OFF
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
	rep #$20
	.LONGA ON
        pla                          ; |cross| low word (pushed last)
        cmp m_prod
        pla                          ; ... high word; pla leaves the cmp's C alone
        sbc m_prod+2
	sep #$20
	.LONGA OFF
        bcc ?yes
        clc
        rts
?yes    sec
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_alen -- m_fixed.c P_AproxDistance of ai_alx/ai_aly (signed 16): the larger
;   magnitude whole plus half the smaller. Leaves ai_axmaj = 1 when x is the
;   dominant axis, which is what the "in front" test above reads.
;   OUT ai_alen. Clobbers A, ai_aax/ai_aay/ai_t4.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_alen                          ; THE THUNK -- see bank01.asm.
        jsl B1CODE_BASE+b1_aif_alen
        rts                          ; the tail call comes back through the rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

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

        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
