;--------------------------------------------------------------
; Part of enemy.asm (icl in place): A_Explode / P_RadiusAttack -- en_boom, en_dist, en_dray, en_los, en_lfind, en_bthings, en_bhit, en_bkill, en_ovkill, en_gibq, en_plr_hurt.
;--------------------------------------------------------------
;--------------------------------------------------------------
; en_boom -- A_Explode: P_RadiusAttack(spot, ..., 128) reduced to the player.
;   PIT_RadiusAttack verbatim: dx/dy are absolute, dist is the LARGER of the two
;   (Chebyshev, not Euclidean), thing->radius comes off it, negatives clamp to 0,
;   dist >= bombdamage is out of range, and the damage is bombdamage - dist.
;   en_k2 = the exploding thing. Clobbers A/Y, m_a, m_b, m_prod, sp_ptr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_boom
        lda en_k2                    ; en_tick/en_adv own these -- the sweep below
        pha                          ;   calls en_kill, which reuses them
        lda en_k2+1
        pha
        lda en_kind
        pha
        jsr en_thing                 ; sp_ptr = the exploding thing's record
                                      ; 2026-09-22 A_Explode(thingy, thingy->target):
        ldx en_k2                    ;   the barrel's TH_TARG (aif_retal wrote it on
        lda.l EXT_BASE+TH_TARG,x     ;   a hit it survived; 0 = the player) is the
        sta en_bsrc                  ;   bombsource
                                      ; 2026-09-23: en_lfind first (it touches neither
        jsr en_lfind                 ;   sp_ptr nor en_bx), then ONE window: each
        rep #$20                     ;   coordinate stays in A for its delta
        .LONGA ON
        lda (sp_ptr)
        sta en_bx
        sec                          ; --- the player
        sbc zp_px
        sta m_a
        ldy #2
        lda (sp_ptr),y
        sta en_by
        sec
        sbc zp_py
        sta m_b
        .LONGA OFF
        sep #$20
        jsr en_dist
        bcc ?things
                                      ; 2026-09-22: the bombsource hurts the player
        ldx en_bsrc                  ;   (0: the player's own blast = no attacker)
        stx pl_src
        jsr en_plr_hurt
?things jsr en_bthings               ; --- and everything else in range
        stz en_bsrc                  ; 2026-09-22: back to 0 = the player
        pla
        sta en_kind
        pla
        sta en_k2+1
        pla
        sta en_k2
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_dist -- PIT_RadiusAttack's test, verbatim. IN m_a/m_b = signed dx/dy.
;   OUT C=1 and A = bombdamage - dist, or C=0 = out of range.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_dist
        jsr en_los
        bcs ?see
        rts                          ; blocked: C=0 reads as "out of range"
                                      ; 2026-09-23: |dx|, |dy| and the max in ONE window,
?see    rep #$20                     ;   in A (m_neg/m_negb were two calls and 8-bit
        .LONGA ON                    ;   halves; |dy| and the max never needed memory:
        lda m_a                      ;   m_a/m_b are scratch past here -- en_thrust_bl
        bpl ?dx                      ;   and en_plr_hurt write them before reading)
        eor #$FFFF
        inc @
        sta m_a
?dx     lda m_b
        bpl ?dy
        eor #$FFFF
        inc @
?dy     cmp m_a                      ; dist = the LARGER of the two (Chebyshev)
        bcs ?big
        lda m_a
?big    sep #$20
        .LONGA OFF
        xba
        bne ?out                     ; >= 256 units: nowhere near
        xba
        sec
        sbc #BOOM_R                  ; dist -= radius, clamped at 0
        bcs ?pos
        lda #0
?pos    cmp #BOOM_DMG
        bcs ?out                     ; dist >= bombdamage -> out of range
        eor #$FF                     ; C = 0: ~d + DMG+1 = DMG - d, and it carries
        adc #BOOM_DMG+1              ;   out (DMG - d >= 1): C=1 as before
        rts
?out    clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_dray -- PIT_RadiusAttack, both halves, for one candidate:
;     if (dist >= bombdamage) return;              <- en_dist
;     if ( P_CheckSight (thing, bombspot) ) ...    <- the ray below
;   en_bdist tail-jumps HERE instead of at en_dist, so the sweep's call site is
;     IN  sp_ptr = the candidate's record (x +0, y +2, as spr_proj packs it),
;         en_bx/en_by = where the blast went off, m_a/m_b = the signed deltas.
;     OUT C=1 and A = the damage, or C=0. sp_ptr, m_a and m_b survive, which is
;         what en_bthings' loop needs.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_dray
        jsr en_dist                  ; range (and a barrel's grid) first
        bcc ?out
        pha                          ; the damage, across the ray
        lda en_lp
        ora en_lp+1
        bne ?ok                      ; a barrel: en_los has already answered
	rep #$20
	.LONGA ON
	lda zp_px
	sta sg_pl
	lda zp_px+2
	sta sg_pl+2

	lda (sp_ptr)
	sta USE_PT_B
	ldy #2
	lda (sp_ptr),y
	sta USE_PT_B+2

	lda en_bx
	sta USE_PT_A
	lda en_bx+2
	sta USE_PT_A+2

	lda #$ffff
	sta USE_SS
	sep #$20
	.LONGA OFF
        stz sg_zon                   ; a FLAT walk, no sill test: sg_set resolves
                                     ;   a z only for a PLAYER target and a blast ...
        jsr sg_bsp                   ; C=1 = nothing crossed the ray
        bcc ?no
?ok     pla
        rts
?no     pla
?out    clc
        rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
en_bx   dta 0,0                      ; where the blast went off
en_by   dta 0,0
en_bi   dta 0                        ; the sweep's thing index
en_bself dta 0                       ; ...and the exploding thing, so it is skipped
en_lp   dta 0,0                      ; this blast's LOS record in bank $01 (0 = none)
en_lt   dta 0,0                      ; en_los: the 16-bit cell arithmetic
en_lt2  dta 0                        ; en_los: the byte offset inside the row
        .endseg

;--------------------------------------------------------------
; en_los -- P_CheckSight for the blast, read straight out of the grid en_lfind
;   found. IN m_a/m_b = the SIGNED (blast - target) deltas, which is what
;   en_dist has in hand before it takes their absolute values.
;   OUT C=1 = the target is visible (or this thing has no grid, so nothing is
;   Clobbers A/X/Y, en_lt/en_lt2 and zp_ptr (zp_ptr+2 is already MAP_EXT_BANK --
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_los
        lda en_lp
        ora en_lp+1
        bne ?go
        sec                          ; no grid for this thing -> everything visible
        rts
                                      ; 2026-09-23: both cells straight off the m_a/m_b
?go     rep #$20                     ;   words in one window (no A/X -> en_lt copy,
        .LONGA ON                    ;   no ?cell call), and the record pointer too
        lda en_lp
        sta zp_ptr
        sec
        lda #LOS_BIAS
        sbc m_b
        lsr @                        ; row = (BIAS - dy) >> 4, * LOS_ROW (4):
        lsr @                        ;   >> 2 with the low two bits cleared
        and #$FFFC
        sta en_lt
        sec
        lda #LOS_BIAS
        sbc m_a
        lsr @
        lsr @
        lsr @
        lsr @                        ; column
        .LONGA OFF
        sep #$20
        tax
        lsr
        lsr
        lsr                          ; col >> 3 = which byte of the row
        clc
        adc en_lt
        adc #2                       ; past the record's index byte + pad
        tay
        txa
        and #7                       ; the bit, counted from the MSB: shift it
        tax                          ;   out through carry rather than build a
        inx                          ;   mask -- (col&7)+1 ASLs land it in C
        lda [zp_ptr],y
?rot    asl
        dex
        bne ?rot
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_lfind -- en_k2 = the exploding thing -> en_lp = its LOS record in bank $01,
;   or 0 if it has none: not a barrel at all, or the level had more barrels than
;   LOS_NMAX, in which case en_los lets everything through and that one barrel
;   blasts through walls like the whole game used to. Once per explosion.
;   Clobbers A/X/Y and zp_ptr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_lfind
        lda #<LOS_EXT
        sta zp_ptr
        lda #>LOS_EXT
        sta zp_ptr+1
                                      ; 2026-09-23: +0 of every record = the thing
        ldx #LOS_NMAX                ;   index -- [dp] without an index, no ldy #0
?rec    lda [zp_ptr]
        cmp en_k2
        beq ?found
        clc
        lda zp_ptr
        adc #LOS_REC
        sta zp_ptr
        bcc ?nc
        inc zp_ptr+1
?nc     dex
        bne ?rec
        stz en_lp
        stz en_lp+1
        rts
?found  lda zp_ptr
        sta en_lp
        lda zp_ptr+1
        sta en_lp+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_bthings -- the rest of P_RadiusAttack: every OTHER shootable thing in range
;   takes bombdamage - dist, and dies into its own chain if that finishes it.
;   That is what makes barrels set each other off, exactly as DOOM does -- and
;   en_dist's sight test (en_los) is what keeps the chain from jumping a wall
;   into the next room.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bthings
        lda en_k2
        sta en_bself                 ; en_kind_of below reuses en_k2 as scratch
        stz en_bi
?lp
	ldy en_bi
	cpy THINGS_BASE
	bcs ?done
	cpy en_bself
	beq ?next
        lda #<TH_HPL
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
        bne ?next                    ; already dying -- do not restart its chain

                                      ; 2026-09-23: Y still holds en_bi (ldy above)
        tya
        jsr en_thing.en_th2w          ; 2026-09-22: returns 16-bit
	.LONGA ON
	sec
	lda en_bx
	sbc (sp_ptr)
	sta m_a

	ldy #2
	sec
	lda en_by
	sbc (sp_ptr),y
	sta m_b
	sep #$20
	.LONGA OFF
        jsr en_bdist                 ; PIT_RadiusAttack's boss exemption, its
        bcc ?next                    ;   range test AND its P_CheckSight, all
        jsr en_bhit                  ;   three behind the same three bytes the
        jsr en_thrust_bl             ;   `jsr en_dist` here used to be -- which
                                     ;   is all this block has ever had.
                                      ; 2026-09-22 p_inter.c:894-915 for a survivor:
        jsr en_bpain                 ;   the flinch roll, reactiontime 0 and the
?next   inc en_bi                    ;   ...and P_DamageMobj's kick, if it lived
        bne ?lp
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; en_bpain -- P_DamageMobj's tail for thing en_bi after en_bhit: nothing if the
;   blast killed it, else its voice + painchance roll and ai_hurt (reactiontime
;   0, MF_JUSTHIT, aif_retal against en_bsrc). en_bhit already set en_last.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bpain
        ldy en_bi
        jsr aif_live                 ; dying or dead: en_bkill has it
        bcc ?out
        lda en_bsrc                  ; P_RadiusAttack's bombsource, +1 (0 = the
        sta ai_src                   ;   player), for aif_retal
        tya
        jsr en_thing.en_th2
        ldy #6
        lda (sp_ptr),y               ; its sprite id -> en_kind
        jsr en_kind_of
        jsr en_hurt_snd              ; the painchance roll -> en_painr
        ldy en_bi
        jsr ai_hurt
        stz ai_src                   ; 0 = the player again, for every other caller
?out    rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
en_bsrc dta 0                        ; the blast's bombsource +1, 0 = the player
        .endseg

;--------------------------------------------------------------
; en_bhit -- A = damage, en_bi = the thing. P_DamageMobj's arithmetic only.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bhit
        sta m_prod
        ldy en_bi
        sty en_last                  ; STEREO: en_die_snd/en_gibq pan the voice
                                     ;   from en_last, and a blast kill comes
                                     ;   through here, not en_shoot

                                      ; 2026-09-22 idiom: Y IS en_bi (loaded 4 lines up,
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        sec
        lda [zp_ptr],y
        sbc m_prod
        sta en_t
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        sbc #0
        sta en_t+1
        jsr en_ovkill                ; the overkill, then the clamp -- and the
                                     ;   `health <= 0` test itself (see en_shoot)
        lda en_t+1
        sta [zp_ptr],y
        lda #>TH_HPL
        sta zp_ptr+1
        lda en_t
        sta [zp_ptr],y
        ora en_t+1
        beq en_bkill 
        ;bra en_bkill                 ; it died: hand it its own chain
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; en_bkill -- the blast finished off thing en_bi: give it its voice and its
;   death chain, the same two steps a bullet kill takes.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bkill
        lda en_bi
        jsr en_thing.en_th2
        ldy #6
        lda (sp_ptr),y               ; its sprite id -> en_kind
        jsr en_kind_of
        jsr en_gibq                  ; BEFORE the voice: A_XScream, not A_Scream,
        jsr en_die_snd               ;   is what a gib yells (p_enemy.c:1572)
        ldy en_bi
        jmp en_kill
.endp
        .endseg

;--------------------------------------------------------------
; en_ovkill -- P_DamageMobj's tail, for both damage sites: en_t is the health
;   the subtraction just produced. Health still ABOVE zero -> return, touching
;   nothing. Health <= 0 -> en_ovk = -en_t (the overkill p_inter.c:719 gibs on)
;   and then the clamp to 0 both sites used to do inline.
;   Clobbers A.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_ovkill
                                      ; 2026-09-23: the test, the negate and the clear
        rep #$20                     ;   as one word window (N/Z of the word = the
        .LONGA ON                    ;   old hi-byte bmi + lo|hi zero test)
        lda en_t
        bmi ?kill
        bne ?out                     ; > 0 -> nothing died: leave en_ovk alone
?kill   eor #$FFFF                   ; en_ovk = -en_t (0 stays 0)
        inc @
        sta en_ovk
        stz en_t                     ; the clamp
?out    sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
                                     ; en_bhit/en_bkill is full
;--------------------------------------------------------------
; en_gibq -- en_gib = 1 iff this kill is p_inter.c:719's:
;     health - damage < -spawnhealth   <=>   overkill > spawnhealth
;   AND info.c gives the kind an xdeathstate at all (XTAB_EXT != $FF). Runs
;   with en_kind already resolved; idempotent, so both kill paths may call it.
;   Clobbers A/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_gibq
        stz en_gib
        ldy en_kind                  ; Y survives to the chain lookup below
        lda #>XTAB_EXT               ; == >DTAB_EXT: only the LOW byte tells the
        sta zp_ptr+1                 ;   two chain headers apart
        lda en_ovk+1                 ; more than 255 past zero: a rocket on a
        bne ?maybe                   ;   zombie does exactly this
        lda en_ovk
        cmp mk_hp,y
        bcc ?no                      ; overkill <= spawnhealth -> ordinary death
        beq ?no                      ;   (DOOM's test is strictly less-than)
?maybe  lda #<XTAB_EXT               ; ...and only if the kind HAS a gib chain
        sta zp_ptr
        lda [zp_ptr],y
        cmp #$FF
        beq ?no                      ; no S_x_XDIE in info.c -> ordinary death
        inc en_gib
        lda #SFX_SLOP                ; A_XScream, not A_Scream (p_enemy.c:1572)
                                      ; 2026-09-22 idiom: snd_qm_last inlined (the tail
        sta en_snd_q                 ;   jmp went: -3)   (STEREO: from en_last)
        lda en_last
        sta en_snd_th
        rts
?no     lda #<DTAB_EXT               ; the ordinary chain, and en_kill reads
        sta zp_ptr                   ;   zp_ptr straight out of here
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_plr_hurt -- A = damage to the player. P_DamageMobj for the player, and the
;   ONLY one: update_damage (the nukage floors) comes through here too now, so
;   there is one death path, one grunt and one armour split for every source.
;   The armour itself is pl_armsub's (movers.asm, next to update_damage -- this
;   block has no room for it). Death restarts the level.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_plr_hurt
        tay                          ; the damage, across the two tests below
        lda pl_dead                  ; P_DamageMobj's second line: "if
        bne ?out                     ;   (target->health <= 0) return" -- a barrel
                                     ;   can still go off next to the corpse, and
                                     ;   without this it would grunt for it
        lda PW_INVUL                 ; ...and its invulnerability test: "damage
        ora PW_INVUL+1               ;   < 1000 && powers[pw_invulnerability]"
        bne ?out                     ;   -> the hit does nothing at all
                                      ; 2026-09-22 p_inter.c:874 player->attacker =
        lda pl_src                   ;   source (thing+1, 0 = none); a caller that
        sta pl_atk                   ;   names none (nukage, crushers) leaves 0
        stz pl_src
        tya
        jsr pl_armsub                ; the armour's share comes off FIRST
        sta m_b                      ;   (p_inter.c:854) -> A = what got through
        sec                          ; (the grunt + the dirty bar moved into
        lda PSTATE+PS_HEALTH         ;   fl_damage's pl_hurtfx, with the face:
        sbc m_b                      ;   one event, one place -- and a KILLING
                                     ;   blow now only screams, like P_KillMobj)
        bcc ?dead
        beq ?dead
        sta PSTATE+PS_HEALTH
        lda m_b
        jmp pl_hurtfx                ; flash + grunt + face, all one path
?dead   jmp pl_dieq                  ; the scream, then the view falls to the floor
                                      ;   and a keypress restarts (pl_death.asm).
?out    stz pl_src                   ; a dead or invulnerable player: no attacker
        rts
.endp
        .endseg
