; Part of enemy_ai.asm -- AUTO-SPLIT out of it 2026-08-09 -- assembled in place via icl at the
; exact point the text was cut from, so every org and every block guard below is
; unchanged (verified: build/doom_bsp.xex is byte-identical).
;   the PLAYER's death + the hitscan leaf walk (PLDTH_BASE)
;==============================================================
; THE PLAYER'S DEATH -- p_user.c P_DeathThink + P_KillMobj's player half.
;   Before this the level simply restarted the instant health hit 0, with no
;   scream and no pause. DOOM does three things instead:
;     * A_PlayerScream plays sfx_pldeth (p_enemy.c),
;     * P_DeathThink lowers viewheight by one unit per tic until it reaches 6,
;       so the camera sinks to the floor,
;     * and it waits for BT_USE before PST_REBORN -- nothing restarts on its own.
;   The port takes ANY key rather than only USE, and only once the fall has
;   finished, so a key still held from before the death does not skip it.
;==============================================================
        org PLDTH_BASE

;--------------------------------------------------------------
; pl_die -- health reached 0. X = the cry, chosen by pl_dieq (its one caller;
;   the nukage reaches here through en_plr_hurt like everything else).
;
;   IT PLAYS, IT DOES NOT QUEUE (2026-08-19, "hrac po smrti raketou nevyda
;   ziadny zvuk"). snd_pending is ONE slot and the last writer takes it, and
;   the rocket that kills you writes it after you die: pj_frame's arrival is
;       ?burst  jsr pj_hit      -> A_Explode -> en_plr_hurt -> here
;               jmp pj_burst    -> lda pj_bsnd / sta snd_pending
;   so the barexp landed on top of the scream every single time. DOOM mixes
;   eight channels and plays both; snd_play asks snd_alloc for a voice of its
;   own, which is the same answer and costs nothing here -- the two bytes it
;   saves over `lda #imm / sta snd_pending` are why the block still fits.
;--------------------------------------------------------------
.proc pl_die
        lda pl_dead                  ; already dead: monsters keep shooting the
        bne ?out                     ;   corpse and the nukage keeps burning it.
        lda #1                       ;   Without this the view jumps back up and
        sta pl_dead                  ;   the scream restarts on every hit.
        lda #EYE_H                   ; the fall starts from the normal eye height
        sta pl_vh
        lda #1
        sta pl_keyw                  ; ignore whatever is held right now
        lda #0
        sta PSTATE+PS_HEALTH
        lda #1
        sta hud_dirty                ; the HUD has to show the 0
        jsr snd_play                 ; X = A_PlayerScream / A_XScream, and it
                                     ;   gets a VOICE, not the one queue slot
        ldx wp_cur                   ; P_DropWeapon: the ready weapon goes into
        lda wi_down,x                ;   its downstate and A_Lower slides it off
        jmp wp_enter                 ;   the bottom, WEAPONSPEED px per tic
?out    rts
.endp

;--------------------------------------------------------------
; pl_dieq -- the killing blow from en_plr_hurt, the only path that can GIB.
;   A = health - damage, i.e. the negative health DOOM keeps: p_inter.c clamps
;   the player's own copy at 0 but P_KillMobj tests the mobj's, which keeps the
;   sign. Damage is a byte and health is never below 0, so health - damage can
;   never reach -256 -- which makes A = 0 unambiguous: the blow landed on
;   EXACTLY zero and there is no overkill at all.
;
;   p_inter.c:719 sends anything past -spawnhealth to xdeathstate, and info.c
;   gives MT_PLAYER spawnhealth 100 with xdeathstate S_PLAY_XDIE1. That chain's
;   second frame is {A_XScream} where the ordinary S_PLAY_DIE2 carries
;   {A_PlayerScream}, so a player torn apart yells sfx_slop -- the same sound a
;   gibbed zombieman does (p_enemy.c:1572). A_PlayerScream's other sound,
;   sfx_pdiehi, is `gamemode == commercial` only, so episodes 1-3 never see it.
;
;   The cry is chosen HERE and pl_die plays it, rather than pl_die queueing the
;   ordinary one and this overwriting it: snd_pending is a single slot and the
;   rocket that killed you writes it AFTER you die (pj_frame runs pj_hit, whose
;   A_Explode reaches en_plr_hurt, and only then pj_burst), so the scream never
;   survived to the frame's dispatch -- "hrac po smrti raketou nevyda ziadny
;   zvuk". Deciding first also drops the pha/jsr/pla that used to carry the
;   negative health across pl_die.
;--------------------------------------------------------------
pldq_resume = *
        org PLDIEQ_BASE
.proc pl_dieq
        beq ?plain                   ; A = 0: the blow landed on EXACTLY zero,
        cmp #$9C                     ;   so there is no overkill at all.
        bcc ?slop                    ; -100 as a byte: the value runs $FF (-1)
                                     ;   DOWN to $01 (-255), so "below -100" is
                                     ;   an unsigned "less than $9C"
?plain  ldx #SFX_PLDETH              ; A_PlayerScream (info.c S_PLAY_DIE2)
        bne ?go                      ; always -- the id is 13
?slop   ldx #SFX_SLOP                ; A_XScream (S_PLAY_XDIE2, p_enemy.c:1572)
?go     jmp pl_die
.endp
    .if * > PLDIEQ_END+1
        ert 'pl_dieq outgrew PLDIEQ_BASE..END (memory_map.inc)'
    .endif
        org pldq_resume

;--------------------------------------------------------------
; pl_dthink -- one DOOM tic of P_DeathThink, from wp_think's tic loop so it
;   runs at DOOM's rate however many frames the Atari manages.
;--------------------------------------------------------------
.proc pl_dthink
        lda pl_dead
        beq ?out
        lda pl_vh                    ; "if (viewheight > 6) viewheight -= 1".
        cmp #DEAD_EYE_H+1            ;   The bcc alone IS that test: 7 must still
        bcc ?out                     ;   decrement. An extra `beq ?out` here
        dec pl_vh                    ;   parked it at 7, pl_deadkey never matched
?out    rts                          ;   and SPACE fell through to try_use.
.endp

;--------------------------------------------------------------
; pl_deadkey -- from the frame loop, BEFORE read_keys so the key that restarts
;   cannot also be read as USE. Waits for the fall to finish first.
;--------------------------------------------------------------
.proc pl_deadkey
        lda pl_dead
        beq ?out
        lda SKSTAT                   ; bit2 clear = some key is down
        and #4
        bne ?rel                     ; nothing down -> arm the edge
        lda pl_keyw                  ; a key held from BEFORE the death must not
        bne ?out                     ;   count: wait for a release first, then the
        jmp pl_restart               ;   next press restarts. (DOOM takes BT_USE
?rel    lda #0                       ;   the instant P_DeathThink runs; any key is
        sta pl_keyw                  ;   easier to hit by accident, hence the edge)
?out    rts
.endp

;--------------------------------------------------------------
; pl_restart -- PST_REBORN. The port has no save of the level's start state, so
;   it reloads the level outright, and clears ps_started so load_things runs its
;   BOOT-time PSTATE init again: 100 health, 50 bullets, fist + pistol, no keys.
;--------------------------------------------------------------
.proc pl_restart
        lda #0
        sta pl_dead
        sta ps_started
        lda #EYE_H
        sta pl_vh
        jsr rom_in                   ; SIOV is in the OS ROM
        jmp exit_level.pl_reload     ; reload current_level, then init_level
.endp

;--------------------------------------------------------------
; sh_leaf -- PTR_ShootTraverse's line half over one subsector: C=1 if any seg of
;   the leaf in zp_nid is CROSSED by the ray USE_PT_A..USE_PT_B and stops a
;   bullet. Parked in the death block's slack -- ROCKW holds sh_trace itself and
;   has no room, and this runs once per sample, i.e. cold.
;
;   use_leaf's twin, minus every special: a bullet opens no door, fires no
;   switch and sets no EXIT_REQ (p_map.c:955-975 spawns a puff and returns
;   false, nothing else). What is left is DOOM's two rejects:
;     * one-sided line              -> `if (!(li->flags & ML_TWOSIDED)) goto hitline`
;     * two-sided with no opening   -> P_LineOpening, openrange <= 0
;   DOOM also stops a shot whose SLOPE leaves the opening at that distance
;   (p_map.c:940-951). This port's shots are level -- proj.asm's note, "no z
;   slope, it flies level at eye - 9" -- so the slope pair collapses into
;   use_shut's "is the opening shut at all", which is the same test try_use
;   already trusts.
;--------------------------------------------------------------
.proc sh_leaf
        jsr leaf_segs                ; zp_sptr / zp_segcnt = this leaf's segs
?loop   lda zp_segcnt
        ora zp_segcnt+1
        beq ?none
        ldy #SEG_BACK                ; the CHEAP half first: can this seg stop a
        lda [zp_sptr],y              ;   bullet at all? use_seg_hit is 2625
        cmp #NO_SECTOR               ;   cycles (four use_side calls) and
        beq ?geo                     ;   use_shut is a pair of compares, so an
        jsr sg_shut                  ;   open portal must not pay the geometry
                                     ;   (sg_shut IS use_shut for the hitscan; for
                                     ;   the SIGHT ray it is use_shut plus
                                     ;   p_sight.c's sill -- enemy_ai.asm)
        beq ?next                    ;   -- and most of a leaf's segs are one
?geo    jsr use_seg_hit              ;   (this order was the other way round and
        bne ?block                   ;   cost 13471 cycles on E1M1's spawn leaf)
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
?block  sec
        rts
?none   clc
        rts
.endp

;--------------------------------------------------------------
; sh_setb -- USE_PT_B = the ray end at length sh_d. The crossing test reads the
;   ray out of USE_PT_A/USE_PT_B, so shortening THAT is the binary search.
;--------------------------------------------------------------
.proc sh_setb
        jsr sh_dist
        lda zp_px
        sta USE_PT_B
        lda zp_px+1
        sta USE_PT_B+1
        lda zp_py
        sta USE_PT_B+2
        lda zp_py+1
        sta USE_PT_B+3
        rts
.endp

;--------------------------------------------------------------
; sh_end -- sh_trace's exit, tail-jumped with C = "a wall was found": hand the
;   point in zp_px/zp_py to en_bx/en_by and put the player back. Out of the
;   ROCKW block, which sh_trace fills to within a dozen bytes.
;--------------------------------------------------------------
.proc sh_end
        php                          ; C has to survive the restore below
        lda zp_px                    ; the impact point...
        sta en_bx
        lda zp_px+1
        sta en_bx+1
        lda zp_py
        sta en_by
        lda zp_py+1
        sta en_by+1
        lda USE_PT_A                 ; ...and the player goes back where he was
        sta zp_px
        lda USE_PT_A+1
        sta zp_px+1
        lda USE_PT_A+2
        sta zp_py
        lda USE_PT_A+3
        sta zp_py+1
        plp
        rts
.endp

sh_sa   dta 0                        ; sh_refine: which side of the blocking seg
                                     ;   the ray START is on (it never moves)
sh_n    dta 0                        ; sh_trace: samples left in the leaf walk
sh_d    dta a(0)                     ; the ray length sh_dist is evaluating
sh_lo   dta a(0)                     ; binary search: the longest CLEAR ray...
sh_hi   dta a(0)                     ;   ...and the shortest BLOCKED one

    .if * > PLDTH_END+1
        ert 'the death block outgrew PLDTH_BASE..PLDTH_END (memory_map.inc)'
    .endif

