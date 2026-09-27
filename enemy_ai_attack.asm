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
        lda mk_atk,x                 ; 0 = this kind has no attack the port can
        bne ?can                     ;   do (projectile-only: HEAD/BOSS/SKUL)
        clc                          ;   -- ?nope is out of branch range now
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
        lda #>TH_MODE
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
?mel    cpx #MK_WSND                 ; MT_CYBORG, MT_SPIDER: dist >>= 1
        bcc ?one
        cmp #$8000
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
        cmp #6
        beq ?throw                   ; 6: cyberdemon -- A_CyberAttack is nothing
                                     ;   BUT P_SpawnMissile.
        bcc ?claw                    ; 3/4/5: imp / CACODEMON / baron -- one shape
                                     ;   (2026-08-20: this used to be four
                                     ;   compares picking 3 and 5 out of a range
                                     ;   with the demon in the middle.
;   WHAT ?claw SERVES (the three melee-then-missile actions):
;   3: imp / 5: baron -- A_BruisAttack is A_TroopAttack's
                                     ;   shape exactly (same melee gate, same ...
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
?throw  jmp ball_spawn               ; P_SpawnMissile: the ball flies, hits and
                                     ;   bursts in ball.asm.
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
?out    rts                          ;   plays attacksound on -- S_StartSound
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
        jsr ai_atk_tics              ; the tics byte again -- ai_atk_next spent
        and #AT_REFIRE               ;   its copy on the AT_LAST test, and this
        beq ?no                      ;   runs once per attack PASS, not per tic
        lda RANDOM                   ; `if (P_Random () < 10) return` -- about one
        cmp #10                      ;   pass in 25 keeps firing without even
        bra ai_refire2               ;   asking whether the target is still there
?no     clc
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

