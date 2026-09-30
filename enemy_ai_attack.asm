;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): A_Chase's attack half + the damage rolls.
;--------------------------------------------------------------

;--------------------------------------------------------------
; ai_try_atk -- A_Chase's attack branches. C=1: it attacked (or is in the
;   post-attack pause), so A_Chase returns without moving.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_try_atk
        lda #>TH_KIND
        jsr ai_get
        sta ai_k
        tax
        lda mk_atk,x                 ; 0 = this kind has no attack at all (the
        bne ?can                     ;   barrel) -- ?nope is out of branch range
        clc
        rts
?can
        lda #>TH_MODE                ; --- reactiontime-- (A_Chase's first line)
        jsr ai_get                   ; NOTE: ai_amode, not ai_t2 -- ai_put and
        sta ai_amode                 ;   ai_pdist both use ai_t2 as scratch
        cmp #1<<AIM_RTSH
        bcc ?nort                    ; (C = 1 past it: the sbc needs no sec)
        sbc #1<<AIM_RTSH
        sta ai_amode
?nort   and #AIM_JATK                ; --- "do not attack twice in a row" (A IS
                                     ;   ai_amode on both paths: no reload)
        beq ?nojatk
        lda ai_amode
        and #255-AIM_JATK            ; clear it and spend this state turning
        ldx #>TH_MODE
        jsr ai_put
        jsr ai_newdir
        sec
        rts
?nojatk lda ai_amode                 ; write the decremented reactiontime back
        ldx #>TH_MODE
        jsr ai_put
        jsr aif_isvis                ; the port's P_CheckSight -- the vissprite
        bcc ?nope                    ;   oracle ai_wake uses: a thing that got
                                     ;   drawn is by definition visible and
                                     ;   wall-clipped.
        jsr ai_pdist                 ; ai_ad = P_AproxDistance(player, thing)
        ldx ai_k                     ; --- melee: needs a meleestate and 60 units
        lda mk_hmel,x
        beq ?miss
        lda ai_ad+1
        bne ?miss                    ; >= 256 units: nowhere near melee
        lda ai_ad
        cmp #60                      ; MELEERANGE(64) - 20 + player radius(16)
        bcs ?miss
        jmp ai_atk_enter             ; (C=1 from the cmp above -- it attacked)
?miss   ldx ai_k                     ; --- missile
        lda mk_mel,x
        bne ?nope                    ; melee-only kind: no missile branch at all
        lda #>TH_MCNT                ; A_Chase: movecount must be 0. P_TryWalk
        jsr ai_get                   ;   reloads it with P_Random()&15, so this is
        bne ?nope                    ;   the "walk a few steps between shots" gate
        lda ai_amode                 ; MF_JUSTHIT jumps the queue -- p_enemy.c
        and #AIM_JHIT                ;   tests it BEFORE reactiontime and before
        beq ?range                   ;   the distance roll
        lda ai_amode
        and #255-AIM_JHIT            ; ...and clears it
        sta ai_amode
        ldx #>TH_MODE
        jsr ai_put
        bra ?fire
?range  lda ai_amode                 ; reactiontime still running -> not yet
        cmp #1<<AIM_RTSH
        bcs ?nope
        jsr ai_mrange                ; P_CheckMissileRange's roll
        bcc ?nope
?fire
                                      ; 2026-09-23 (reload rule): TH_MODE == ai_amode here
        lda ai_amode                 ;   -- both ways in just ai_put it, and nothing
        ora #AIM_JATK                ;   between writes TH_MODE (aif_isvis, ai_pdist,
        sta ai_amode                 ;   ai_mrange, ai_get: readers only)
        ldx #>TH_MODE
        jsr ai_put
        jmp ai_atk_enter
?nope   clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_hurt -- Y = the thing that just took damage. p_inter.c P_DamageMobj:
;       target->reactiontime = 0;        // we're awake now...
;   and, when the painchance roll passed, MF_JUSTHIT -- which makes the very
;   next P_CheckMissileRange return true regardless of reactiontime OR range.
;   instead of finishing its wind-up. Clobbers A/X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_hurt
        sty ai_t
        jsr aif_retal
        lda #>TH_FLY                 ; MF_SKULLFLY: the momentum goes and the
        jsr ai_get                   ;   flinch never happens (p_inter.c:793/895)
        beq ?grnd
        jsr ai_flyhit
?grnd   lda #>TH_MODE
        jsr ai_get
        and #255-AIM_RTMASK          ; reactiontime = 0
        ldx en_painr
        beq ?put
                                      ; 2026-09-22 p_inter.c:899: the painstate replaces
        and #255-AIM_ATK             ;   the attack state -- a flinch cuts the attack
        ora #AIM_JHIT                ;   short instead of resuming it afterwards
?put    ldx #>TH_MODE
        jmp ai_pain_row              ; ...which stores it and then, on the same
.endp                                ;   roll, drops the FLINCH frame in. It is
        .endseg
                                     ;   a jmp and not a jsr on purpose: this ...

;--------------------------------------------------------------
; ai_isvis -- C=1 if ai_t is in this frame's vissprite list. Clobbers A/X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_isvis
        ldx sp_n
?lp     dex
        bmi ?no
        lda vs_th,x
        cmp ai_t
        bne ?lp
        sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_pdist -- ai_ad = P_AproxDistance(target - thing): dx+dy/2 with the larger
;   term whole, which is DOOM's own cheap distance (m_fixed.c). The target is
;   the player until something else shoots this monster (infight.asm).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_pdist
        jsr aif_tpos                 ; -> ai_tx/ai_ty
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
        sep #$20
        lda ai_t
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w
        .LONGA ON                    ;   the accumulator, then dx+dy/2 with the
        sec                          ;   larger term whole (m_fixed.c)
        lda ai_tx
        sbc (sp_ptr)                 ; thing.x at +0
        bpl ?xp
        eor #$FFFF
        inc @
?xp     sta ai_ax
        ldy #2
        sec
        lda ai_ty
        sbc (sp_ptr),y               ; thing.y at +2
        bpl ?yp
        eor #$FFFF
        inc @
?yp     sta ai_ay
        cmp ai_ax                    ; dy >= dx? (a tie goes either way: the two
        bcs ?ybig                    ;   sums are the same number)
        lsr @                        ; dx is larger: ad = dx + dy/2
        clc
        adc ai_ax
        sta ai_ad
        sep #$20
        .LONGA OFF
        rts
?ybig   lda ai_ax                    ; dy is larger: ad = dy + dx/2
        lsr @
        clc
        adc ai_ay
        sta ai_ad
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_mrange -- P_CheckMissileRange's distance roll. C=1 = fire.
;   dist = ad - 64; kinds with no meleestate get another -128 ("fire more");
;   clamp to 200; fire unless P_Random() < dist.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_mrange
                                      ; 2026-09-22 p_enemy.c:216-253: dist = aprox - 64,
    .if MK_COUNT <> MK_WSND+2         ;   -128 without a meleestate, >>1 for the
        ert 'ai_mrange: kinds >= MK_WSND must be exactly CYBR, SPID'
    .endif                           ;   cyberdemon and spider, <= 200 (cyberdemon 160)
        ldx ai_k
        rep #$20
        .LONGA ON
        lda ai_ad
        sec
        sbc #64                      ; dist = P_AproxDistance - 64
        ldy mk_hmel,x
        bne ?mel
        sec                          ; no meleestate: fire more
        sbc #128
?mel    cpx #MK_SKUL                 ; MT_SKULL, MT_CYBORG, MT_SPIDER: dist >>= 1
        beq ?half
        cpx #MK_WSND
        bcc ?one
?half   cmp #$8000
        ror @
?one    cmp #$8000                   ; dist < 0: P_Random() < dist never holds
        bcs ?point
        cmp #200
        bcc ?c200
        lda #200
?c200   cpx #MK_WSND                 ; MT_CYBORG only: at most 160
        bne ?roll
        cmp #160
        bcc ?roll
        lda #160
?roll   sep #$20
        .LONGA OFF
        sta ai_t2                    ; (dist <= 200: one byte)
        lda RANDOM
        cmp ai_t2                    ; P_Random() < dist -> do NOT fire
        bcc ?no
        rts                          ; (C = 1 already: the bcc fell through)
?no     clc
        rts
        .LONGA ON
?point  sep #$21                     ; C=1: fire
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_atk_enter -- P_SetMobjState(missilestate/meleestate): attack state 0.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_atk_enter
        lda #>TH_MODE
        jsr ai_get
        ora #AIM_ATK
        ldx #>TH_MODE
        jsr ai_put
        lda #0
        ldx #>TH_WST
        jsr ai_put
        jsr ai_atk_row
        sec                          ; A_Chase returns right after the state set
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_atk_next -- the current ATTACK state ran out. AT_LAST hands the thing back
;   to the RUN chain (info.c's last attack state points at S_x_RUN1), otherwise
;   step to the next one.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_atk_next
        jsr ai_atk_tics              ; A = this row's tics byte (and ai_awst =
        and #AT_LAST                 ;   the state it came from)
        beq ?step
        jsr ai_refire                ; AT_REFIRE and still shooting? -> ATK2
        bcs ?step
        lda #>TH_MODE                ; back to the RUN chain, state 0
        jsr ai_get
        and #255-AIM_ATK
        ldx #>TH_MODE
        jsr ai_put
        lda #0
        ldx #>TH_WST
        jsr ai_put
        ldx ai_k
        lda mk_ctic,x
        ldx #>TH_WTIC
        jsr ai_put
        jsr ai_setrow
        jmp ai_chase                 ; the RUN state's action is A_Chase
?step   lda ai_awst
        inc @
        ldx #>TH_WST
        jsr ai_put
                                     ; 2026-09-21 drac_bra: the target is the very
        ert *<>ai_atk_row           ;   next byte of this segment -- fall through
.endp
        .endseg

;--------------------------------------------------------------
; ai_atk_row -- point TH_WROW at the ATTACK row for the current TH_WST, take
;   its tics, and run the action if the row carries AT_FIRE.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_atk_row
        jsr aif_oct                  ; A_FaceTarget: every attack action turns
        ldx #>TH_DIR                 ;   the monster to its target first (the
        jsr ai_put                   ;   store lives here, see aif_oct)
        jsr ai_atk_tics
                                      ; 2026-09-22 (65816-style): the tics byte rides
        pha                          ;   the stack across the two ai_put calls
        and #AT_TICS                 ; bits 0-5 are info.c's own tics
        ldx #>TH_WTIC
        jsr ai_put
        lda ai_arow                  ; TH_WROW is row+1 (0 = not chasing)
        inc @
        ldx #>TH_WROW
        jsr ai_put
        pla
        and #AT_FIRE
        bne ai_fire 
        ;bra ai_fire
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_atk_tics -- ai_arow = ATAB_EXT[kind] + TH_WST, A = that row's tics byte.
;   The attack rows share DTAB_ROWS with the death and walk frames (8 B each,
;   tics at +7 -- see the DTAB note in memory_map.inc).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_atk_tics
        lda #>TH_WST
        jsr ai_get
        sta ai_awst
                                      ; 2026-09-23: the *4 stays in A and ai_asc is stored
        ldy wrot_nst                 ;   once (no reload of ai_awst). The state, scaled
        cpy #4                       ;   by the stored-view count: attack rows are
        bne ?fl2                     ;   state-major x NSTOR
        asl                          ; *4 (a state index: no carry out)
        asl
?fl2    sta ai_asc
?flat   ldy ai_k
        lda #<ATAB_EXT
        sta zp_ptr
        lda #>ATAB_EXT
        sta zp_ptr+1
        lda [zp_ptr],y               ; the kind's first attack row
        clc
        adc ai_asc
        sta ai_arow
        rep #$20                     ; ---- 16-bit A: row*8 + DTAB_ROWS in A (the
        .LONGA ON                    ;   row is a byte, so the asl's carry 0 and
        and #$FF                     ;   the adc needs no clc)
        asl @
        asl @
        asl @
        adc #DTAB_ROWS
        sta zp_ptr
        sep #$20
        .LONGA OFF
        ldy #7
        lda [zp_ptr],y
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_fire -- the damage rolls, p_enemy.c verbatim. mk_atk says which:
;     1 A_PosAttack   pistol, ((P_Random()%5)+1)*3
;     2 A_SPosAttack  shotgun, THREE of the same roll
;     3 A_TroopAttack claw (P_Random()%8+1)*3 in melee range, else the fireball
;     4 A_HeadAttack  bite (P_Random()%6+1)*10, silent, else BAL2
;     5 A_BruisAttack claw (P_Random()%8+1)*10, else BAL7
;     6 A_CyberAttack the rocket    7 A_SargAttack (P_Random()%10+1)*4
;     8 A_SkullAttack the charge (ai_skull, below)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_fire
        ldx ai_k
        lda mk_atk,x
        beq ?out
        pha                          ; the range is re-tested HERE, the way
        jsr ai_pdist                 ;   A_TroopAttack calls P_CheckMeleeRange
        lda #$FF                     ;   itself -- and it also refreshes
        sta ai_vic                   ;   ai_tx/ai_ty for whatever this monster is
        pla                          ;   actually fighting (infight.asm)
        cmp #3
        bcc ?hitscan                 ; 1 or 2: POSS / SPOS
        cmp #7
        beq ?sarg                    ; 7: demon -- melee range only
        jcs ai_skull                 ; 8: lost soul -- A_SkullAttack, the charge
        cmp #4
        beq ?head                    ; 4: cacodemon -- A_HeadAttack
        cmp #6
        bcc ?claw                    ; 3/5: imp / baron -- A_BruisAttack is
                                     ;   A_TroopAttack's shape exactly
?throw  jmp ball_spawn               ; 6: cyberdemon (A_CyberAttack is nothing
                                     ;   BUT P_SpawnMissile), and every claw or
                                     ;   bite out of reach. The ball flies, hits
                                     ;   and bursts in ball.asm.
?out    rts                          ; (here, behind the jmp: in reach of the top)
?head   lda ai_ad+1                 ; 4: A_HeadAttack -- the imp's shape with two
        bne ?throw                   ;   numbers changed: (P_Random()%6+1)*10,
        lda ai_ad                    ;   and NO sound (sfx_claw is the imp's and
        cmp #60                      ;   the baron's alone)
        bcs ?throw
        lda RANDOM
?m6     cmp #6
        bcc ?d6
        sbc #6                       ; (cmp left C=1: no sec)
        bra ?m6
?d6     inc @
        bra ?x3                      ; ...* the kind's damage byte (10, ai_cdmg)
?sarg   lda ai_ad+1                  ; 7: demon -- melee range only
        bne ?out
        lda ai_ad
        cmp #60
        bcs ?out
        jsr ?r10                     ; ((P_Random()%10)+1)*4
        asl
        asl
        jsr aif_hurt                 ; a CALL, like the claw below: the bite
        lda #SFX_SGTATK              ;   (info.c attacksound) is queued AFTER the
        jmp snd_qp_ai                ; tail call --   damage so en_plr_hurt's grunt does not
?claw   lda ai_ad+1                  ; the imp's claw, same range test
        bne ?throw
        lda ai_ad
        cmp #60
        bcs ?throw                   ; out of reach -> A_TroopAttack's else:
        lda RANDOM                   ; (P_Random()%8+1) * the kind's damage byte
        and #7                       ;   (?r8, inlined: its one call site)
        inc @
        jsr ?x3                      ; ...*3 imp / *10 baron. A CALL, not a jump:
        lda #SFX_CLAW                ;   A_TroopAttack plays sfx_claw inside its
        jmp snd_qp_ai                ; tail call --   P_CheckMeleeRange branch, i.e. exactly
                                     ;   en_plr_hurt queues the player's own
                                     ;   grunt (sfx_plpain) on the way through,
                                     ;   and there is ONE sound slot.
?hitscan
        jsr aif_block                ; PTR_ShootTraverse's thing half: does the
                                     ;   bullet reach what it was aimed at, or
                                     ;   stop in whoever is standing in the way?
        ldx ai_k                     ; the gunshot is heard whether it hits or not
        lda mk_atk,x                 ;   -- but it is queued AFTER the pellets and
        cmp #2                       ;   on the MONSTER's voice, not the frame's
        beq ?sg                      ;   SFX slot (2026-08-20). It used to be
        jsr ?shot                    ;   `sta snd_pending` BEFORE the shots, and
        lda #SFX_PISTOL              ;   every pellet that connected ran
        bne ?voice                   ;   en_plr_hurt -> pl_hurtfx, which stores
?sg     jsr ?shot                    ;   sfx_plpain into that same one slot: at
        jsr ?shot                    ;   point blank the shot ALWAYS lands, so the
        jsr ?shot                    ;   gun was never once heard and the spider
        lda #SFX_SHOTGN              ;   mastermind's chaingun was the player's
                                      ; 2026-09-22 idiom: snd_qm_ai inlined (-12)
?voice  sta en_snd_q                 ;   own grunt. en_snd_q is the voice DOOM
        lda ai_t
        sta en_snd_th
                                     ;   (STEREO: ai_t is the one firing)
        rts                          ;   plays attacksound on -- S_StartSound
                                     ;   (actor, ...) -- and snd_dispatch starts
                                     ;   it on a channel of its own, so now BOTH
                                     ;   are heard, exactly as they are in DOOM.
;   one hitscan pellet: DOOM's spread, then the damage if it lands
?shot   lda ai_vic                   ; a body in the way is not something the
        cmp #$FF                     ;   spread can miss: the trace stops in it
        bne ?land
        jsr ?hits
        bcc ?miss
?land   jsr ?r5                      ; ((P_Random()%5)+1)*3
?x3     sta m_a                      ; the roll, then * the KIND's damage byte
        jmp ai_cdmg                  ; (the *3 became per-kind: ai_cdmg, parked
                                     ;   in the OSFREE tail -- this block has 7
                                     ;   bytes, not the 391 AIATK_END claimed)
?miss   rts
;   C=1 if this pellet lands: |spread| * dist < 16 * 620, the lateral miss
;   distance against the player's radius (see the header comment).
?hits   jsr pw_spread                ; m_a = |the aim error|, DOOM's triangular
                                     ;   (P_Random() - P_Random()) -- and TRIPLE ...
        lda ai_ad
        sta m_b
        lda ai_ad+1
        sta m_b+1
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
        lda m_prod+2
        ora m_prod+3
        bne ?nohit                   ; way over 9920
        sec
        lda m_prod
        sbc #<9920
        lda m_prod+1
        sbc #>9920
        bcs ?nohit
        sec
        rts
?nohit  clc
        rts
;   P_Random()%N + 1, for the three N the four actions use
?r5     lda RANDOM
?m5     cmp #5
        bcc ?d5
        sbc #5
        bra ?m5
?d5     inc @                        ; (+1: C is dead in every caller)
        rts
?r8     lda RANDOM
        and #7
        inc @
        rts
?r10    lda RANDOM
?m10    cmp #10
        bcc ?d10
        sbc #10
        bra ?m10
?d10    inc @
        rts
.endp
        .endseg

; EVERY variable this block owns lives OUT of it (the distance trio since
; 2026-08-20 morning, the five attack-state bytes since that afternoon): the
; segment runs FLUSH into mn_ld_tab at $B377, and AIATK_END said $B391 -- stale
; since the day the menu table landed, i.e. the guard would have let this block
; eat 27 bytes of that table and never said a word. First A_CyberAttack's
; dispatch arm wanted the room, then ai_refire's call site. Variables index the
; same from anywhere, and these eleven bytes are the whole reason AIATK still
; fits. They are deliberately NOT ai_t2: ai_put stores through it and ai_pdist
; uses it for the halved delta, so anything that has to survive a call needs its
; own.
aivar_resume = *
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
ai_ad   dta 0,0                      ; P_AproxDistance(player, thing)
ai_ax   dta 0,0                      ; its two |deltas|
ai_ay   dta 0,0
ai_arow dta 0                        ; the ATTACK row the current state draws
ai_awst dta 0                        ; the ATTACK state it came from
ai_asc  dta 0                        ; ... scaled x NSTOR (rows are state-major)
ai_atics dta 0                       ; that row's tics byte, flags and all
ai_amode dta 0                       ; the working copy of TH_MODE
        .endseg
        org aivar_resume

;==============================================================
; A_SpidRefire (p_enemy.c, 2026-08-20) -- the one attack chain in DOOM that does
; not end when its last state does.
;==============================================================

;--------------------------------------------------------------
; ai_refire -- ai_atk_next's AT_LAST arm. C=1: keep firing, and ai_awst is
;   already 0 so the caller's own +1 lands on chain state 1 -- S_x_ATK2 in every
;   info.c refire chain, which pack_things pack_atk asserts at PACK time.
;   C=0: this chain really is over, fall back to the RUN cycle.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_refire
        lda #>TH_FLY                 ; a lost soul still in the air: S_SKULL_ATK4
        jsr ai_get                   ;   -> ATK3, the loop only its flight ends
        bne ?fly                     ;   (pack_atk pins that shape)
        jsr ai_atk_tics              ; the tics byte again -- ai_atk_next spent
        and #AT_REFIRE               ;   its copy on the AT_LAST test, and this
        beq ?no                      ;   runs once per attack PASS, not per tic
        lda RANDOM                   ; `if (P_Random () < 10) return` -- about one
        cmp #10                      ;   pass in 25 keeps firing without even
        bra ai_refire2               ;   asking whether the target is still there
?no     clc
        rts
?fly    lda #1                       ; ai_atk_next's own +1 lands on state 2
        sta ai_awst
        sec
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_refire2 -- entered with C = (P_Random() >= 10), i.e. C=0 already means
;   "keep firing" and only C=1 pays for the sight test.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_refire2
        bcc ?yes
        jsr aif_isvis                ; the port's P_CheckSight -- the same oracle
        bcc ?no                      ;   ai_try_atk decided to open fire on
?yes    stz ai_awst                  ; ai_atk_next's ?step reads ai_awst and adds
                                     ;   one, so 0 here IS P_SetMobjState(ATK2)
        sec
        rts
?no     clc
        rts
.endp
        .endseg

;==============================================================
; THE FLINCH -- info.c's painstate (2026-08-16). p_inter.c P_DamageMobj:
;       if (P_Random () < info->painchance && !(flags & MF_SKULLFLY))
;==============================================================

;--------------------------------------------------------------
; ai_pain_row -- ai_hurt's tail. Reached with A = the thing's new TH_MODE and
;   X = #>TH_MODE, which is precisely what ai_hurt's own `jmp ai_put` wanted,
;   so taking the call over costs that block nothing.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_pain_row
        jsr ai_put                   ; ai_hurt's own store: reactiontime 0,
        lda en_painr                 ;   MF_JUSTHIT if it flinched -- and that
        beq ?out                     ;   same roll decides the frame. 0 = it
        lda #>TH_KIND                ;   took the hit silently, which is DOOM's
        jsr ai_get                   ;   answer too: no flinch, no sound
        tay                          ; Y = kind = the PTAB_EXT index
        lda #>PTAB_EXT
        sta zp_ptr+1
        lda #<PTAB_EXT
        sta zp_ptr
        bra ai_pain2
?out    rts
.endp
        .endseg


;--------------------------------------------------------------
; ai_pain2 -- Y = kind, zp_ptr = PTAB_EXT: the flinch row into TH_WROW and the
;   kind's own painstate duration onto the clock. The $FF test is not a nicety
;   -- TH_WROW is row+1 and 0 means "not chasing", so $FF+1 would stop the
;   monster dead and ai_tick would never look at it again.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_pain2
        lda [zp_ptr],y
        bmi ?out                     ; $FF: no flinch frame for this kind here
        pha                          ; the row, until the pointer is done with
        lda #<PTIC_EXT               ; same page as PTAB_EXT, same bank
        sta zp_ptr
        lda [zp_ptr],y               ; info.c's painstate chain length in tics
        ldx #>TH_WTIC
        jsr ai_put
        pla
        inc @                        ; TH_WROW is row+1: 0 means "not chasing"
        ldx #>TH_WROW
        jmp ai_put
?out    rts
.endp
        .endseg


;--------------------------------------------------------------
; ai_cdmg / ai_mul -- the CLAW half of A_TroopAttack and A_BruisAttack, which
;   p_enemy.c writes twice with one number changed:
;       imp:   damage = (P_Random()%8+1)*3
;       baron: damage = (P_Random()%8+1)*10
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_cdmg
        ldy #3                       ; A_TroopAttack's damage byte
        ldx ai_k
        lda mk_atk,x
        cmp #5
        beq ?ten
        cmp #4                       ; A_HeadAttack's is ten as well -- p_enemy.c
        bne ?go                      ;   (P_Random()%6+1)*TEN (2026-08-20)
?ten    ldy #10                      ; A_BruisAttack's
?go     jsr ai_mul
        jmp aif_hurt
.endp
        .endseg

;   A = m_a * Y, for Y >= 1. Max 8*10 = 80, so no carry ever leaves the loop
;   and the clc can sit outside it.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_mul
        lda #0
        clc
?m      adc m_a
        dey
        bne ?m
        rts
.endp
        .endseg


;==============================================================
; THE LOST SOUL's CHARGE (2026-09-30) -- A_SkullAttack (ai_skull), P_XYMovement
;   with MF_SKULLFLY (ai_flyall/ai_fly), and P_DamageMobj's hit on a flying one
;   (ai_flyhit). TH_FLY is MF_SKULLFLY, TH_FVX/TH_FVY the momentum as a HALF-tic
;   step: the flight moves SKULLSPEED a tic in two P_TryMove halves, as p_mobj.c
;   splits a move above MAXMOVE/2. Like every monster here it keeps to the floor.
;==============================================================
;--------------------------------------------------------------

;--------------------------------------------------------------
; ai_skull -- A_SkullAttack, ai_fire's arm for mk_atk 8: ai_t launches itself.
;   IN: ai_tx/ai_ty = the target, ai_ad/ai_ax/ai_ay = P_AproxDistance and the
;   |legs| (ai_pdist). Each half step = round(|leg| * SKULLSPEED/2 / dist),
;   signed like its leg: the aim of P_AproxDistance, within ~6 % of the speed.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_skull
        lda #MK_SKATK                ; S_StartSound (actor, attacksound)
        jsr snd_qp_ai
        lda #1                       ; actor->flags |= MF_SKULLFLY
        ldx #>TH_FLY
        jsr ai_put
        inc ai_flyn                  ; ai_tick's sweep has something to fly
        lda ai_t
        jsr en_thing.en_th2w         ; sp_ptr = its record; 16-bit
        .LONGA ON
        sec                          ; the legs' SIGNS, target - thing (ai_pdist
        lda ai_tx                    ;   kept only their sizes)
        sbc (sp_ptr)
        sta ai_dx
        ldy #2
        sec
        lda ai_ty
        sbc (sp_ptr),y
        sta ai_dy
        lda ai_ad                    ; the divisor of both legs
        sta m_den
        sep #$20
        .LONGA OFF
        beq ?zero                    ; (Z of the word load) on top of its target:
        ldx #0                       ;   no momentum, the next tic lands it
        jsr ?leg                     ; the x leg...
        ldx #>TH_FVX
        jsr ai_put
        ldx #2                       ; ...and the y leg (ai_ay/ai_dy are +2)
        jsr ?leg
?puty   ldx #>TH_FVY
        jmp ai_put
?zero   ldx #>TH_FVX                 ; A = 0 (the whole word was), and ai_put
        jsr ai_put                   ;   hands it back unchanged
        bra ?puty

;   X = 0 / 2 -> A = that leg's signed half step. m_den = the distance.
?leg    phx                          ; umul16w and udiv24 keep no X
        rep #$20
        .LONGA ON
        lda ai_ax,x
        sta m_a
        lda #MK_SKSPD/2
        sta m_b
        jsr umul16w                  ; m_prod = |leg| * the half step (< 2^20)
        lda m_den                    ; + dist/2, rounding to nearest. lsr's carry
        lsr @                        ;   (dist odd) rides into the add: + ceil,
        adc m_prod                   ;   which rounds the same way
        sta m_prod
        bcc ?nc
        inc m_prod+2                 ; (the word: m_prod+3 is 0 and stays 0)
?nc     jsr udiv24.ud_w16            ; m_quot = that / dist; 8-bit out
        .LONGA OFF
        plx
        lda m_quot                   ; <= SKULLSPEED/2: one byte
        bit ai_dx+1,x                ; the leg's sign
        bpl ?pos
        eor #$FF
        inc @
?pos    rts
.endp
        .endseg
    .if ai_ay != ai_ax+2 || ai_dy != ai_dx+2
        ert 'ai_skull indexes the y leg at +2 -- ai_ax/ai_ay, ai_dx/ai_dy moved'
    .endif

;--------------------------------------------------------------
; ai_flyall -- from ai_tick, while ai_flyn says something launched: ai_fly every
;   thing with MF_SKULLFLY. The sweep RECOUNTS ai_flyn, so a flight that ended
;   any way at all (landed, died, a new level) stops the sweep by itself.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_flyall
        stz ai_flyn
        ldx #0
?lp     lda.l EXT_BASE+TH_FLY,x
        bne ?one
?nx     inx
        cpx ai_lim                   ; the level's n_things, rounded up (0 = 256)
        bne ?lp
        rts
?one    stx ai_fi
        stx ai_t
        inc ai_flyn
        jsr ai_fly
        ldx ai_fi
        bra ?nx
.endp
        .endseg

;--------------------------------------------------------------
; ai_fly -- one tic of P_XYMovement for ai_t, which has MF_SKULLFLY.
;   No momentum: it slammed into something last tic -> spawnstate (p_mobj.c:
;   124). Else two halves, each PIT_CheckThing first (a thing in the way takes
;   ((P_Random()%8)+1)*damage and the flight ends at once, p_map.c:275), then
;   the rest of P_TryMove (ai_step); a wall zeroes the momentum.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_fly
        jsr ai_ismon                 ; P_KillMobj clears MF_SKULLFLY: dead or
        beq ?off                     ;   dying, the flag just goes
        lda #>TH_KIND                ; coll_mon sizes the probe by ai_k
        jsr ai_get
        sta ai_k
        lda #>TH_FVX
        jsr ai_get
        sta ai_t2
        lda #>TH_FVY
        jsr ai_get
        ora ai_t2
        bne ?go                      ; momx == momy == 0 falls into the landing
?land   lda #0                       ; MF_SKULLFLY off, and P_SetMobjState
        ldx #>TH_FLY                 ;   (spawnstate): the RUN cycle's first
        jsr ai_put                   ;   image for S_SKULL_STND's tics, then
        lda #>TH_MODE                ;   A_Chase again
        jsr ai_get
        and #255-AIM_ATK
        ldx #>TH_MODE
        jsr ai_put
        lda #0
        ldx #>TH_WST
        jsr ai_put
        lda #MK_SKSTND
        ldx #>TH_WTIC
        jsr ai_put
        jmp ai_setrow
?off    lda #0
        ldx #>TH_FLY
        jmp ai_put
?go     lda #2
        sta ai_fn
?half   lda #>TH_FVX                ; the half step, sign-extended to the word
        jsr ai_get                   ;   ai_step adds
        sta ai_sx
        ora #$7F                     ; $FF for a minus step...
        bmi ?xn
        lda #0                       ; ...$00 for a plus one
?xn     sta ai_sx+1
        lda #>TH_FVY
        jsr ai_get
        sta ai_sy
        ora #$7F
        bmi ?yn
        lda #0
?yn     sta ai_sy+1
        lda ai_t                     ; PIT_CheckThing at the half's end point
        sta sol_self
        jsr en_thing.en_th2w         ; 16-bit, C = 0 (en_th2w's own proof)
        .LONGA ON
        lda (sp_ptr)
        adc ai_sx
        sta coll_cx
        ldy #2
        clc
        lda (sp_ptr),y
        adc ai_sy
        sta coll_cy
        sep #$20
        .LONGA OFF
        lda #$FF                     ; en_solid names a THING blocker in sol_i and
        sta sol_i                    ;   tests the player before any: $FF = him
        jsr en_solid
        bne ?hit
        jsr ai_move.ai_step          ; P_TryMove's lines, heights and the commit
        beq ?wall                    ;   (its own en_solid is clear, by the above)
        dec ai_fn
        bne ?half
        rts
?wall   lda #0                       ; "else mo->momx = mo->momy = 0": the next
        ldx #>TH_FVX                 ;   tic finds no momentum and lands it
        jsr ai_put
        ldx #>TH_FVY
        jmp ai_put
?hit    lda RANDOM                   ; ((P_Random()%8)+1) * MT_SKULL damage
        and #7
        inc @
        sta m_a
        ldy #MK_SKDMG
        jsr ai_mul
        ldx sol_i
        cpx #$FF
        bne ?thing
        ldx ai_t                     ; the player: P_DamageMobj (player, skull,
        phx                          ;   skull) -- the attacker +1 for
        inx                          ;   P_DeathThink's turn
        stx pl_src
        jsr en_plr_hurt
        plx
        stx ai_t
        jmp ?land                    ; (the landing sits at the top, out of reach)
?thing  stx ai_vt                    ; a thing: aif_dmg (a decoration is not
        jsr aif_dmg                  ;   shootable and takes nothing)
        jmp ?land
.endp
        .endseg

;--------------------------------------------------------------
; ai_flyhit -- ai_hurt's arm for a victim with MF_SKULLFLY (ai_t): P_DamageMobj
;   zeroes its momentum (the next tic lands it) and skips the painstate -- so
;   no A_Pain either: en_hurt_snd's roll and the sound it queued are taken back.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_flyhit
        lda #0
        ldx #>TH_FVX
        jsr ai_put
        ldx #>TH_FVY
        jsr ai_put
        lda en_painr
        beq ?out
        stz en_painr
        lda #$FF                     ; en_snd_q's "the monster said nothing"
        sta en_snd_q
?out    rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
ai_flyn dta 0                        ; things with MF_SKULLFLY at the last sweep
                                     ;   (+ launches since): 0 = ai_tick skips
ai_fi   dta 0                        ; ai_flyall's sweep index
ai_fn   dta 0                        ; ai_fly: halves left this tic
        .endseg
