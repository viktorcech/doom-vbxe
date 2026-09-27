;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): the player's death (P_DeathThink) and the
;   hitscan leaf walk.
;--------------------------------------------------------------

;--------------------------------------------------------------
; pl_die -- health reached 0. X = the cry, chosen by pl_dieq (its one caller;
;   the nukage reaches here through en_plr_hurt like everything else).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_die
        lda pl_dead                  ; already dead: monsters keep shooting the
        bne ?out                     ;   corpse and the nukage keeps burning it.
        lda #1                       ;   Without this the view jumps back up and
        sta pl_dead                  ;   the scream restarts on every hit.
        lda #EYE_H                   ; the fall starts from the normal eye height
        sta pl_vh
        lda #1
        sta pl_keyw                  ; ignore whatever is held right now
        stz PSTATE+PS_HEALTH
                                      ; 2026-09-22 idiom: A is still 1 (the pl_keyw
        sta hud_dirty                ; the HUD has to show the 0
        jsr snd_play                 ; X = A_PlayerScream / A_XScream, and it
                                     ;   gets a VOICE, not the one queue slot
        ldx wp_cur                   ; P_DropWeapon: the ready weapon goes into
        lda wi_down,x                ;   its downstate and A_Lower slides it off
        jmp wp_enter                 ;   the bottom, WEAPONSPEED px per tic
?out    rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; pl_dieq -- the killing blow from en_plr_hurt, the only path that can GIB.
;--------------------------------------------------------------
pldq_resume = *
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_dieq
        beq ?plain                   ; A = 0: the blow landed on EXACTLY zero,
        cmp #$9C                     ;   so there is no overkill at all.
        bcc ?slop                    ; -100 as a byte: the value runs $FF (-1)
                                     ;   DOWN to $01 (-255), so "below -100" is
                                     ;   an unsigned "less than $9C"
?plain  ldx #SFX_PLDETH              ; A_PlayerScream (info.c S_PLAY_DIE2)
        bne ?go                      ; always -- the id is 13
?slop   ldx #SFX_SLOP                ; A_XScream (S_PLAY_XDIE2, p_enemy.c:1572)
?go     bra pl_die
.endp
        .endseg

;--------------------------------------------------------------
; pl_dthink -- one DOOM tic of P_DeathThink, from wp_think's tic loop so it
;   runs at DOOM's rate however many frames the Atari manages.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_dthink
        lda pl_dead
        beq ?out
        lda pl_vh                    ; "if (viewheight > 6) viewheight -= 1".
        cmp #DEAD_EYE_H+1            ;   The bcc alone IS that test: 7 must still
                                      ; 2026-09-22: then P_DeathThink's turn to the
        bcc ?turn                    ;   attacker (pl_dturn), every tic
        dec pl_vh
?turn   jmp pl_dturn
?out    rts                          ;   and SPACE fell through to try_use.
.endp
        .endseg

;--------------------------------------------------------------
; pl_dturn -- p_user.c:200-222: the dead view turns ANG5 a tic towards
;   player->attacker (pl_atk = thing+1, 0 = none) and locks on inside ANG5.
;   ANG5 is 3.6 BAM bytes: 4 a tic, then k = round(delta) bytes and done.
;   fwd/side = the attacker in view space (Q14 sin/cos, the high word = v/4).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_dturn
        lda pl_atk
        bne ?go
        rts                          ; no attacker: nothing to turn to
?go     dec @
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = the attacker's record
        .LONGA ON
        lda (sp_ptr)                 ; v = attacker - player
        sec
        sbc zp_px
        sta swr_vx
        ldy #2
        lda (sp_ptr),y
        sec
        sbc zp_py
        sta swr_vy
        sta m_a
        .LONGA OFF
        sep #$20
        ldx zp_ang
        lda.l TRGX_SIN_LO,x
        sta m_b
        lda.l TRGX_SIN_HI,x
        sta m_b+1
        jsr smul32                   ; vy*sin
        rep #$20
        .LONGA ON
        lda m_prod
        sta pd_p
        lda m_prod+2
        sta pd_p+2
        lda swr_vx
        sta m_a
        .LONGA OFF
        sep #$20
        ldx zp_ang
        lda.l TRGX_COS_LO,x
        sta m_b
        lda.l TRGX_COS_HI,x
        sta m_b+1
        jsr smul32                   ; vx*cos
        rep #$21
        .LONGA ON
        lda m_prod                   ; fwd = vx*cos + vy*sin (the low words only
        adc pd_p                     ;   carry into the high one)
        lda m_prod+2
        adc pd_p+2
        sta pd_fwd
        lda swr_vx
        sta m_a
        .LONGA OFF
        sep #$20
        ldx zp_ang
        lda.l TRGX_SIN_LO,x
        sta m_b
        lda.l TRGX_SIN_HI,x
        sta m_b+1
        jsr smul32                   ; vx*sin
        rep #$20
        .LONGA ON
        lda m_prod
        sta pd_p
        lda m_prod+2
        sta pd_p+2
        lda swr_vy
        sta m_a
        .LONGA OFF
        sep #$20
        ldx zp_ang
        lda.l TRGX_COS_LO,x
        sta m_b
        lda.l TRGX_COS_HI,x
        sta m_b+1
        jsr smul32                   ; vy*cos
        rep #$20
        .LONGA ON
        sec                          ; side = vx*sin - vy*cos: > 0 = on the right
        lda pd_p
        sbc m_prod
        lda pd_p+2
        sbc m_prod+2
        sta pd_side
        bpl ?sp
        eor #$FFFF
        inc @
?sp     sta pd_as                    ; |side| < 4096: |v| < 16384, a quarter of it
        ldx #4                       ; k = 4: a whole ANG5
        lda pd_fwd
        bmi ?turn                    ; behind the view
        beq ?turn
        lda pd_as                    ; |side|*10 >= fwd: more than 5.7 deg off. No
        asl @                        ;   asl can carry (|side| < 4096), so the adc
        sta pd_t                     ;   needs no clc
        asl @
        asl @
        adc pd_t
        cmp pd_fwd
        bcs ?turn
        lda pd_as                    ; inside: k = round(delta in BAM) = how many j
        asl @                        ;   in 1..4 have |side|*81 >= fwd*(2j-1)
        asl @                        ;   (|side| < fwd/10 < 410: no carries)
        asl @
        asl @
        sta pd_t
        asl @
        asl @
        adc pd_t
        adc pd_as
        sta pd_t                     ; |side|*81
        lda pd_fwd
        asl @
        sta pd_f2                    ; 2*fwd
        lda pd_fwd                   ; fwd*(2j-1), j = 1
        ldx #0
?fk     cmp pd_t
        beq ?fk1
        bcs ?turn                    ; beyond |side|*81: k = j-1
?fk1    inx
        cpx #4
        bcs ?turn
        adc pd_f2                    ; (C = 0: the bcs fell through)
        bra ?fk
?turn   sep #$20
        .LONGA OFF
        stx pd_k
        lda zp_ang
        bit pd_side+1                ; side >= 0: right (or dead behind, as DOOM's
        bmi ?left                    ;   delta >= ANG180): clockwise, BAM down
        sec
        sbc pd_k
        sta zp_ang
        rts
?left   clc
        adc pd_k
        sta zp_ang
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
pl_src  dta 0                        ; the NEXT en_plr_hurt's source, thing+1 (0 = none)
pl_atk  dta 0                        ; player->attacker, thing+1 (0 = none)
pd_p    dta a(0),a(0)                ; pl_dturn: a 32-bit product...
pd_fwd  dta a(0)                     ; ...the attacker along the view (v/4)
pd_side dta a(0)                     ; ...and across it, > 0 = right
pd_as   dta a(0)                     ; |side|
pd_t    dta a(0)
pd_f2   dta a(0)
pd_k    dta 0                        ; the BAM step, 0..4
        .endseg

;--------------------------------------------------------------
; pl_deadkey -- from the frame loop, BEFORE read_keys so the key that restarts
;   cannot also be read as USE. Waits for the fall to finish first.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_deadkey
        lda pl_dead
        beq ?out
        lda SKSTAT                   ; bit2 clear = some key is down
        and #4
        bne ?rel                     ; nothing down -> arm the edge
        lda pl_keyw                  ; a key held from BEFORE the death must not
        bne ?out                     ;   count: wait for a release first, then the
        jmp pl_restart               ;   next press restarts. (DOOM takes BT_USE
                                     ;   2026-09-22 idiom: jsr X / rts -> jmp X; both
                                     ;   procs are bank $01 code (.lab), rts type
?rel    stz pl_keyw                  ;   the instant P_DeathThink runs; any key is
                                     ;   easier to hit by accident, hence the edge)
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pl_restart -- PST_REBORN. The port has no save of the level's start state, so
;   it reloads the level outright, and clears ps_started so load_things runs its
;   BOOT-time PSTATE init again: 100 health, 50 bullets, fist + pistol, no keys.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_restart
        stz pl_dead
        stz ps_started
        lda #EYE_H
        sta pl_vh
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a)
        jmp exit_level.pl_reload     ; reload current_level, then init_level
.endp
        .endseg

;--------------------------------------------------------------
; sh_leaf -- PTR_ShootTraverse's line half over one subsector: C=1 if any seg of
;   the leaf in zp_nid is CROSSED by the ray USE_PT_A..USE_PT_B and stops a
;   bullet. Parked in the death block's slack -- ROCKW holds sh_trace itself and
;   has no room, and this runs once per sample, i.e. cold.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_leaf
        jsr leaf_segs                ; zp_sptr / zp_segcnt = this leaf's segs
        lda zp_segcnt
        ora zp_segcnt+1
        beq ?none
?loop   ldy #SEG_BACK                ; the CHEAP half first: can this seg stop a
        lda [zp_sptr],y              ;   bullet at all? (the .else side has the
        cmp #NO_SECTOR               ;   cycle counts)
        beq ?geo
        jsr sg_shut
        beq ?next
?geo    jsr use_seg_hit
        bne ?block
?next   rep #$21                     ; ---- 16-bit A, C=0: next seg, count down
        .LONGA ON
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        dec zp_segcnt                ; (one 16-bit RMW, 2026-09-15)
        sep #$20                     ; (sep keeps Z: the count's)
        .LONGA OFF
        bne ?loop
?none   clc
        rts
?block  sec
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sh_setb -- USE_PT_B = the ray end at length sh_d. The crossing test reads the
;   ray out of USE_PT_A/USE_PT_B, so shortening THAT is the binary search.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_setb
        jsr sh_dist
                                    ; 2026-09-22 (65816-windows): sh_dist returns 16-bit
        .LONGA ON
                                      ; A = zp_px: sh_dist's LAST pass is X = 0 (2026-09-23)
        sta USE_PT_B
        lda zp_py
        sta USE_PT_B+2
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sh_end -- sh_trace's exit, tail-jumped with C = "a wall was found": hand the
;   point in zp_px/zp_py to en_bx/en_by and put the player back. Out of the
;   ROCKW block, which sh_trace fills to within a dozen bytes.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_end
                                      ; 2026-09-23: rep/lda/sta/sep leave C alone, and
        rep #$20                     ; ---- 16-bit A: four word moves
        .LONGA ON
        lda zp_px                    ; the impact point...
        sta en_bx
        lda zp_py
        sta en_by
        lda USE_PT_A                 ; ...and the player goes back where he was
        sta zp_px
        lda USE_PT_A+2
        sta zp_py
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

sh_sa   dta 0                        ; sh_refine: which side of the blocking seg
                                     ;   the ray START is on (it never moves)
sh_n    dta 0                        ; sh_trace: samples left in the leaf walk
sh_d    dta a(0)                     ; the ray length sh_dist is evaluating
sh_lo   dta a(0)                     ; binary search: the longest CLEAR ray...
sh_hi   dta a(0)                     ;   ...and the shortest BLOCKED one

        .endseg

