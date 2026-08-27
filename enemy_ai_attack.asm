; Part of enemy_ai.asm -- AUTO-SPLIT out of it 2026-08-09 -- assembled in place via icl at the
; exact point the text was cut from, so every org and every block guard below is
; unchanged (verified: build/doom_bsp.xex is byte-identical).
;   A_Chase's ATTACK half + the damage rolls (AIATK_BASE, AICDMG_BASE)
;==============================================================
; A_CHASE'S ATTACK HALF (2026-07-31) -- p_enemy.c, parked at AIATK_BASE.
;
; RATE, straight out of A_Chase. Everything below happens once per RUN state,
; i.e. every mk_ctic tics (POSS 4, TROO 3, SARG 2):
;   1. reactiontime--                       (info.c mk_rt = 8 for every kind)
;   2. MF_JUSTATTACKED set -> clear it, P_NewChaseDir, and do NOT attack. This
;      is what stops a monster firing on two consecutive states.
;   3. melee: meleestate && dist < MELEERANGE-20+player_radius = 60 units
;   4. missile: movecount MUST be 0 (P_TryWalk reloads it with P_Random()&15,
;      so this comes round about every 8 states), reactiontime 0, and then
;      P_CheckMissileRange's own roll: dist = approx - 64, another -128 if the
;      kind has no meleestate (POSS/SPOS "fire more"), clamped to 200, and
;      P_Random() < dist means DO NOT fire. So P(fire) = (256-dist)/256 --
;      point blank is certain, 200 units away is about one state in five.
;
; SKILL: the port ships skill 2 (sk_medium, pack_things SKILL). The only
; skill-dependent lines in A_Chase are `gameskill < sk_nightmare` on the
; movecount gate and `gameskill != sk_nightmare` on the JUSTATTACKED pause --
; both TRUE here, so this is the standard rule set. sk_baby's `damage >>= 1`
; (p_inter.c) does not apply either.
;
; NOT DOOM (the missing half): the CACODEMON and the LOST SOUL still do no
; damage -- mk_atk is 0 for both. The caco wants MT_HEADSHOT and the soul wants
; A_SkullAttack, which is a charge, not a missile, and neither has a path here
; yet. Everything else lands: the hitscan pair (POSS/SPOS, and the SPIDER
; MASTERMIND on the same id), the two melee attacks (TROO's claw, SARG's bite),
; and the three MISSILES ball.asm carries -- the imp's, the baron's and the
; CYBERDEMON's rocket. A_FaceTarget is not modelled: the sprite has 8 rotations
; but the attack frames are one image.
;
; ONE MISSILE IN FLIGHT, globally (ball.asm): a second thrower whose shot found
; the slot busy just animates, which doubles as the fire-rate limit. It is why
; the cyberdemon's three-rocket A_CyberAttack chain lands one rocket per pass
; and not three.
;==============================================================
        org AIATK_BASE

;--------------------------------------------------------------
; ai_try_atk -- A_Chase's attack branches. C=1: it attacked (or is in the
;   post-attack pause), so A_Chase returns without moving.
;--------------------------------------------------------------
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
        bcc ?nort
        sec
        sbc #1<<AIM_RTSH
        sta ai_amode
?nort   lda ai_amode                 ; --- "do not attack twice in a row"
        and #AIM_JATK
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
                                     ;   wall-clipped. OFF SCREEN it is the
                                     ;   cached ray instead -- ai_look writes
                                     ;   every ray's answer to TH_SEEN and
                                     ;   aif_pvis reads it, so the vissprite list
                                     ;   stopped being the only source of truth
                                     ;   when ai_look landed. (This comment still
                                     ;   said "TH_SEEN has never been written"
                                     ;   until 2026-08-25.)
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
        jmp ?fire
?range  lda ai_amode                 ; reactiontime still running -> not yet
        cmp #1<<AIM_RTSH
        bcs ?nope
        jsr ai_mrange                ; P_CheckMissileRange's roll
        bcc ?nope
?fire
        lda #>TH_MODE                ; MF_JUSTATTACKED: the NEXT state cannot
        jsr ai_get                   ;   attack again
        ora #AIM_JATK
        ldx #>TH_MODE
        jsr ai_put
        jmp ai_atk_enter
?nope   clc
        rts
.endp

;--------------------------------------------------------------
; ai_hurt -- Y = the thing that just took damage. p_inter.c P_DamageMobj:
;       target->reactiontime = 0;        // we're awake now...
;   and, when the painchance roll passed, MF_JUSTHIT -- which makes the very
;   next P_CheckMissileRange return true regardless of reactiontime OR range.
;   Together these are why a zombieman you shoot at across a room shoots back
;   instead of finishing its wind-up. Clobbers A/X.
;   aif_retal is the rest of that same if-block (p_inter.c:904): the hit also
;   points the victim at whoever landed it, ai_src -- which is the player on
;   every path but a monster's own gunshot.
;--------------------------------------------------------------
.proc ai_hurt
        sty ai_t
        jsr aif_retal
        lda #>TH_MODE
        jsr ai_get
        and #255-AIM_RTMASK          ; reactiontime = 0
        ldx en_painr
        beq ?put
        ora #AIM_JHIT
?put    ldx #>TH_MODE
        jmp ai_pain_row              ; ...which stores it and then, on the same
.endp                                ;   roll, drops the FLINCH frame in. It is
                                     ;   a jmp and not a jsr on purpose: this
                                     ;   block is full to the byte, so the tail
                                     ;   call had to stay exactly three bytes

;--------------------------------------------------------------
; ai_isvis -- C=1 if ai_t is in this frame's vissprite list. Clobbers A/X.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; ai_pdist -- ai_ad = P_AproxDistance(target - thing): dx+dy/2 with the larger
;   term whole, which is DOOM's own cheap distance (m_fixed.c). The target is
;   the player until something else shoots this monster (infight.asm).
;--------------------------------------------------------------
.proc ai_pdist
        jsr aif_tpos                 ; -> ai_tx/ai_ty
        lda ai_t
        jsr en_thing.en_th2
        sec                          ; |target.x - thing.x|
        ldy #0
        lda ai_tx
        sbc (sp_ptr),y
        sta ai_ax
        iny
        lda ai_tx+1
        sbc (sp_ptr),y
        sta ai_ax+1
        jsr ?abs_x
        sec                          ; |target.y - thing.y|
        ldy #2
        lda ai_ty
        sbc (sp_ptr),y
        sta ai_ay
        iny
        lda ai_ty+1
        sbc (sp_ptr),y
        sta ai_ay+1
        jsr ?abs_y
        sec                          ; which is larger?
        lda ai_ax
        sbc ai_ay
        lda ai_ax+1
        sbc ai_ay+1
        bcs ?xbig
        lda ai_ax                    ; dy is larger: ad = dy + dx/2
        sta ai_t2
        lda ai_ax+1
        lsr
        ror ai_t2
        clc
        lda ai_ay
        adc ai_t2
        sta ai_ad
        lda ai_ay+1
        adc #0
        sta ai_ad+1
        rts
?xbig   lda ai_ay                    ; dx is larger: ad = dx + dy/2
        sta ai_t2
        lda ai_ay+1
        lsr
        ror ai_t2
        clc
        lda ai_ax
        adc ai_t2
        sta ai_ad
        lda ai_ax+1
        adc #0
        sta ai_ad+1
        rts
?abs_x  lda ai_ax+1
        bpl ?xok
        sec
        lda #0
        sbc ai_ax
        sta ai_ax
        lda #0
        sbc ai_ax+1
        sta ai_ax+1
?xok    rts
?abs_y  lda ai_ay+1
        bpl ?yok
        sec
        lda #0
        sbc ai_ay
        sta ai_ay
        lda #0
        sbc ai_ay+1
        sta ai_ay+1
?yok    rts
.endp

;--------------------------------------------------------------
; ai_mrange -- P_CheckMissileRange's distance roll. C=1 = fire.
;   dist = ad - 64; kinds with no meleestate get another -128 ("fire more");
;   clamp to 200; fire unless P_Random() < dist.
;--------------------------------------------------------------
.proc ai_mrange
        sec
        lda ai_ad
        sbc #64
        sta ai_t2
        lda ai_ad+1
        sbc #0
        bmi ?point                   ; inside 64 units: always fires
        bne ?far                     ; >= 256 left over -> clamp
        ldx ai_k
        lda mk_hmel,x
        bne ?have
        sec                          ; no meleestate: 128 units closer to firing
        lda ai_t2
        sbc #128
        bcc ?point
        sta ai_t2
?have   lda ai_t2
        cmp #200                     ; DOOM clamps dist at 200
        bcc ?roll
?far    lda #200
        sta ai_t2
?roll   lda RANDOM
        cmp ai_t2                    ; P_Random() < dist -> do NOT fire
        bcc ?no
        sec
        rts
?no     clc
        rts
?point  sec
        rts
.endp

;--------------------------------------------------------------
; ai_atk_enter -- P_SetMobjState(missilestate/meleestate): attack state 0.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; ai_atk_next -- the current ATTACK state ran out. AT_LAST hands the thing back
;   to the RUN chain (info.c's last attack state points at S_x_RUN1), otherwise
;   step to the next one.
;
;   ...unless the chain LOOPS. S_SPID_ATK4 is the one last attack state in DOOM
;   that does NOT point at S_x_RUN1 -- p_enemy.c A_SpidRefire sends it back to
;   S_SPID_ATK2 and the spider mastermind keeps firing. ai_refire is that test,
;   and it answers C=1 with ai_awst ALREADY back to 0, so ?step's own +1 lands on
;   chain state 1 and this arm costs five bytes: a jsr and a branch.
;--------------------------------------------------------------
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
        clc
        adc #1
        ldx #>TH_WST
        jsr ai_put
        jmp ai_atk_row
.endp

;--------------------------------------------------------------
; ai_atk_row -- point TH_WROW at the ATTACK row for the current TH_WST, take
;   its tics, and run the action if the row carries AT_FIRE.
;--------------------------------------------------------------
.proc ai_atk_row
        jsr aif_oct                  ; A_FaceTarget: every attack action turns
        ldx #>TH_DIR                 ;   the monster to its target first (the
        jsr ai_put                   ;   store lives here, see aif_oct)
        jsr ai_atk_tics
        sta ai_atics                 ; NOT ai_t2: ai_put below overwrites that
        and #AT_TICS                 ; bits 0-5 are info.c's own tics
        ldx #>TH_WTIC
        jsr ai_put
        lda ai_arow                  ; TH_WROW is row+1 (0 = not chasing)
        clc
        adc #1
        ldx #>TH_WROW
        jsr ai_put
        lda ai_atics
        and #AT_FIRE
        beq ?done
        jmp ai_fire
?done   rts
.endp

;--------------------------------------------------------------
; ai_atk_tics -- ai_arow = ATAB_EXT[kind] + TH_WST, A = that row's tics byte.
;   The attack rows share DTAB_ROWS with the death and walk frames (8 B each,
;   tics at +7 -- see the DTAB note in memory_map.inc).
;--------------------------------------------------------------
.proc ai_atk_tics
        lda #>TH_WST
        jsr ai_get
        sta ai_awst
        sta ai_asc                   ; the state, scaled by the stored-view
        lda wrot_nst                 ;   count: attack rows are state-major
        cmp #4                       ;   x NSTOR since the rotation slice (all
        bne ?flat                    ;   NSTOR slots carry the SAME tics byte, so
        lda ai_awst                  ;   reading slot 0 is exact)
        asl                          ; *4. This said *3, and pack_things has
        asl                          ;   documented "NSTOR is 4 or 1 and NOTHING
        sta ai_asc                   ;   ELSE" since STORED_ROTS went to four
                                     ;   digits -- so the scale NEVER happened and
                                     ;   an attacking monster walked rows 0,1,2 =
                                     ;   the four VIEWS of its first attack state
                                     ;   instead of states 0,1,2. That is the
                                     ;   baron spinning on the spot before he
                                     ;   throws (2026-08-08).
?flat   ldy ai_k
        lda #<ATAB_EXT
        sta zp_ptr
        lda #>ATAB_EXT
        sta zp_ptr+1
        lda [zp_ptr],y               ; the kind's first attack row
        clc
        adc ai_asc
        sta ai_arow
        lda #0                       ; row * 8 -> offset into DTAB_ROWS
        sta m_prod+1
        lda ai_arow
        sta m_prod
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc #<DTAB_ROWS
        sta zp_ptr
        lda m_prod+1
        adc #>DTAB_ROWS
        sta zp_ptr+1
        ldy #7
        lda [zp_ptr],y
        rts
.endp

;--------------------------------------------------------------
; ai_fire -- the damage rolls, p_enemy.c verbatim. mk_atk says which:
;     1 A_PosAttack   pistol, ((P_Random()%5)+1)*3
;     2 A_SPosAttack  shotgun, THREE of the same roll
;     3 A_TroopAttack claw (P_Random()%8+1)*3 in melee range, else the fireball
;     4 A_HeadAttack  the CACODEMON (2026-08-20): claw (P_Random()%6+1)*10 in
;                     melee range, else MT_HEADSHOT -- the red BAL2 ball, damage
;                     5. Until now it was mk_atk 0: the one monster in the game
;                     that chased the player and could not touch him. It sits on
;                     4, the slot A_SargAttack used to waste, so at_tables.inc
;                     keeps all four MISSILE rows contiguous and does not grow
;                     (there is no 30 B block left anywhere -- ram_map.py).
;     5 A_BruisAttack claw (P_Random()%8+1)*10 in melee range, else the same
;                     fireball with MT_BRUISERSHOT's damage byte (8, not 3)
;     6 A_CyberAttack MT_ROCKET and nothing else -- no melee arm, no range test
;                     (2026-08-20). The SPIDER MASTERMIND needs no id of its
;                     own: its missile state runs A_SPosAttack, so it is a 2 and
;                     shares the shotgun guy's three-pellet burst, exactly as
;                     info.c has it.
;     7 A_SargAttack  bite ((P_Random()%10)+1)*4 -- melee range only, and the
;                     only action here that throws nothing, which is why it and
;                     not a missile action holds the id outside 3..6.
;   The hitscan pair rolls DOOM's angle spread instead of tracing it: the shot
;   lands within about +-0.41*dist of the aim point, so it hits the player's
;   16-unit radius when |spread| * dist is small enough. That keeps a zombieman
;   across a room from being a guaranteed hit, which a bare damage call would be.
;--------------------------------------------------------------
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
                                     ;   BUT P_SpawnMissile. It has no melee
                                     ;   branch and mobjinfo gives it no
                                     ;   meleestate, so it never tests the range:
                                     ;   point blank it fires a rocket too
        bcc ?claw                    ; 3/4/5: imp / CACODEMON / baron -- one shape
                                     ;   (2026-08-20: this used to be four
                                     ;   compares picking 3 and 5 out of a range
                                     ;   with the demon in the middle. With
                                     ;   A_SargAttack moved to 7 the three
                                     ;   melee-then-missile actions are
                                     ;   CONSECUTIVE, so the carry off `cmp #6`
                                     ;   sorts them in two bytes instead of eight)
;   WHAT ?claw SERVES (the three melee-then-missile actions):
;   3: imp / 5: baron -- A_BruisAttack is A_TroopAttack's
                                     ;   shape exactly (same melee gate, same
                                     ;   sfx_claw, same "else launch a missile");
                                     ;   only the two damage bytes differ, and
                                     ;   ai_cdmg / bl_roll read those off ai_k.
                                     ; 4: CACODEMON. A_HeadAttack is the same shape
                                     ;   AGAIN -- melee gate, else
                                     ;   P_SpawnMissile(MT_HEADSHOT) -- so it lands
                                     ;   here too and ball.asm throws the red ball
                                     ;   off at_tables (damage 5). Its melee roll
                                     ;   is TWO REDUCTIONS, both forced by RAM:
                                     ;     p_enemy.c  (P_Random()%6+1)*10  = 10..60
                                     ;     here       (P_Random()%8+1)*10  = 10..80
                                     ;   (?r8 is shared; a %6 loop is 15 B and the
                                     ;   whole engine has no 24 B block left --
                                     ;   ram_map.py), and the bite plays sfx_claw
                                     ;   where A_HeadAttack is silent (info.c gives
                                     ;   MT_HEAD no attacksound). The MISSILE half,
                                     ;   which is the half that was missing
                                     ;   entirely, is exact.
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
        sta snd_pending              ;   damage so en_plr_hurt's grunt does not
        rts                          ;   overwrite it -- one sound slot
?claw   lda ai_ad+1                  ; the imp's claw, same range test
        bne ?throw
        lda ai_ad
        cmp #60
        bcs ?throw                   ; out of reach -> A_TroopAttack's else:
        jsr ?r8                      ; (P_Random()%8+1) * the kind's damage byte
        jsr ?x3                      ; ...*3 imp / *10 baron. A CALL, not a jump:
        lda #SFX_CLAW                ;   A_TroopAttack plays sfx_claw inside its
        sta snd_pending              ;   P_CheckMeleeRange branch, i.e. exactly
        rts                          ;   when the scratch connects -- but
                                     ;   en_plr_hurt queues the player's own
                                     ;   grunt (sfx_plpain) on the way through,
                                     ;   and there is ONE sound slot. Written
                                     ;   before the damage the claw is silently
                                     ;   overwritten and never heard; DOOM has
                                     ;   both on separate channels.
?throw  jmp ball_spawn               ; P_SpawnMissile: the ball flies, hits and
                                     ;   bursts in ball.asm. WHOSE missile it is
                                     ;   (damage 3 or 8) is decided there, from
                                     ;   ai_k -- see bl_roll
?hitscan
        jsr aif_block                ; PTR_ShootTraverse's thing half: does the
                                     ;   bullet reach what it was aimed at, or
                                     ;   stop in whoever is standing in the way?
                                     ;   That second case is where infighting
                                     ;   comes from -- p_map.c has no species
                                     ;   test on a hitscan at all.
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
?voice  sta en_snd_q                 ;   own grunt. en_snd_q is the voice DOOM
?out    rts                          ;   plays attacksound on -- S_StartSound
                                     ;   (actor, ...) -- and snd_dispatch starts
                                     ;   it on a channel of its own, so now BOTH
                                     ;   are heard, exactly as they are in DOOM.
                                     ;   (SFX_PISTOL is 9, so the `bne` is a
                                     ;   two-byte unconditional jump.)
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
                                     ;   (P_Random() - P_Random()) -- and TRIPLE
                                     ;   that when the player carries the blur
                                     ;   sphere, which is A_FaceTarget's whole
                                     ;   MF_SHADOW branch (powerups.asm)
        lda ai_ad
        sta m_b
        lda ai_ad+1
        sta m_b+1
        jsr umul16                   ; m_prod = |spread| * dist
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
        jmp ?m5
?d5     clc
        adc #1
        rts
?r8     lda RANDOM
        and #7
        clc
        adc #1
        rts
?r10    lda RANDOM
?m10    cmp #10
        bcc ?d10
        sbc #10
        jmp ?m10
?d10    clc
        adc #1
        rts
.endp

    .if * > AIATK_END+1
        ert 'the A_Chase attack block outgrew AIATK_BASE..END (memory_map.inc)'
    .endif
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
        org AIVARS_BASE
ai_ad   dta 0,0                      ; P_AproxDistance(player, thing)
ai_ax   dta 0,0                      ; its two |deltas|
ai_ay   dta 0,0
ai_arow dta 0                        ; the ATTACK row the current state draws
ai_awst dta 0                        ; the ATTACK state it came from
ai_asc  dta 0                        ; ... scaled x NSTOR (rows are state-major)
ai_atics dta 0                       ; that row's tics byte, flags and all
ai_amode dta 0                       ; the working copy of TH_MODE
    .if * > AIVARS_END+1
        ert 'the AI attack scratch outgrew AIVARS_BASE..END (memory_map.inc)'
    .endif
        org aivar_resume

;==============================================================
; A_SpidRefire (p_enemy.c, 2026-08-20) -- the one attack chain in DOOM that does
; not end when its last state does.
;
;   void A_SpidRefire (mobj_t* actor)
;   {
;       A_FaceTarget (actor);
;       if (P_Random () < 10)  return;                  // keep firing, blind
;       if (!actor->target || actor->target->health <= 0
;           || !P_CheckSight (actor, actor->target))
;           P_SetMobjState (actor, actor->info->seestate);
;   }
;
; S_SPID_ATK4's nextstate is S_SPID_ATK2, so that bare `return` means ATK2 (fire)
; -> ATK3 (fire) -> ATK4 (test) round again: six pellets every NINE tics, for as
; long as the spider mastermind can see you. That loop is what E3M8's boss is --
; 3000 hit points and a chaingun. Without it the port ran the chain once and fell
; back to A_Chase, which is six pellets and then a walk, and the gunfire was one
; short blast where DOOM has a rattle.
;
; A_FaceTarget is NOT repeated here: ai_atk_row turns the monster to its target
; on entry to every attack state (aif_oct), which covers both of DOOM's calls.
; The `target dead` arm is aif_isvis' too -- a monster target that died is out of
; TH_TARG, and the player's own death restarts the level.
;
; TWO procs for 27 bytes, the same bargain the FLINCH struck: ram_map.py has no
; 27 B run left in the machine, so this is split over the two biggest gaps it has
; -- the tail of door_force_open's block and the tail of pj_frameN's. ai_refire
; ends on a jmp into ai_refire2 WITH THE CARRY LIVE; nothing else may claim
; either run (AIRF_BASE / AIRF2_BASE in memory_map.inc).
;==============================================================
airf_resume = *
        org AIRF_BASE

;--------------------------------------------------------------
; ai_refire -- ai_atk_next's AT_LAST arm. C=1: keep firing, and ai_awst is
;   already 0 so the caller's own +1 lands on chain state 1 -- S_x_ATK2 in every
;   info.c refire chain, which pack_things pack_atk asserts at PACK time.
;   C=0: this chain really is over, fall back to the RUN cycle.
;--------------------------------------------------------------
.proc ai_refire
        jsr ai_atk_tics              ; the tics byte again -- ai_atk_next spent
        and #AT_REFIRE               ;   its copy on the AT_LAST test, and this
        beq ?no                      ;   runs once per attack PASS, not per tic
        lda RANDOM                   ; `if (P_Random () < 10) return` -- about one
        cmp #10                      ;   pass in 25 keeps firing without even
        jmp ai_refire2               ;   asking whether the target is still there
?no     clc
        rts
.endp
    .if * > AIRF_END+1
        ert 'ai_refire outgrew AIRF_BASE..AIRF_END (memory_map.inc)'
    .endif

        org AIRF2_BASE
;--------------------------------------------------------------
; ai_refire2 -- entered with C = (P_Random() >= 10), i.e. C=0 already means
;   "keep firing" and only C=1 pays for the sight test.
;--------------------------------------------------------------
.proc ai_refire2
        bcc ?yes
        jsr aif_isvis                ; the port's P_CheckSight -- the same oracle
        bcc ?no                      ;   ai_try_atk decided to open fire on
?yes    lda #0                       ; ai_atk_next's ?step reads ai_awst and adds
        sta ai_awst                  ;   one, so 0 here IS P_SetMobjState(ATK2)
        sec
        rts
?no     clc
        rts
.endp
    .if * > AIRF2_END+1
        ert 'ai_refire2 outgrew AIRF2_BASE..AIRF2_END (memory_map.inc)'
    .endif
        org airf_resume

;==============================================================
; THE FLINCH -- info.c's painstate (2026-08-16). p_inter.c P_DamageMobj:
;       if (P_Random () < info->painchance && !(flags & MF_SKULLFLY))
;       {   flags |= MF_JUSTHIT;
;           P_SetMobjState (target, info->painstate);   }
; The roll and MF_JUSTHIT have been here since the pain SOUND landed (the
; en_painr in enemy.asm's en_hurt_snd is that same P_Random); this is the FRAME
; that was missing -- monsters took a shotgun blast without moving a pixel.
;
; NOT A STATE MACHINE, and that is the whole design. A pain chain is two states
; of ONE image falling straight into S_x_RUN1, so instead of a third chain
; beside RUN and ATTACK -- a mode bit, a per-kind state count, a dispatch in
; ai_state, an AT_LAST exit -- the port drops the flinch row into TH_WROW and
; puts the kind's tics on TH_WTIC. Whatever ai_state reaches for next takes
; TH_WROW back on its own (ai_setrow off the RUN state, or ai_atk_row
; mid-attack), and
; that IS the fall back to RUN1. Nothing is added to the per-tic path, no bit
; is added to a full TH_MODE, and the whole feature is 46 bytes.
;
; The rows are one image in the walk cycle's NSTOR views (pack_things
; pack_pain), so spr_wrot turns the flinch with the monster exactly like a walk
; frame. PTAB_EXT[kind] is $FF when the level's coltab run could not afford the
; frame -- that kind then keeps its old flinch-less behaviour rather than
; failing the build, the same bargain the gib chains strike.
;
; The HOLD is info.c's own, per kind, since 2026-08-26: PTIC_EXT (a tenth DTAB
; header, pack_things.pain_tics) carries the painstate chain's length in tics
; and ai_pain2 puts THAT on TH_WTIC. It used to be PAIN_TICS, one number -- 6
; -- and info.c wants 4 for the imp, the demon and the baron, 6 for the two
; zombies / the lost soul / the spider, 10 for the CYBERDEMON and 12 for the
; cacodemon, so five of the nine kinds that flinch flinched for the wrong
; length. The byte is free: base RAM had no room for a per-kind table, the
; row array had 16 B spare (E1M6, the busiest level, packs 222 of 236).
;
; DELIBERATELY NOT DOOM, both worth knowing:
;   * a monster hit MID-ATTACK keeps its attack chain (P_SetMobjState would
;     have dropped it). The flinch shows, then the wind-up carries on.
;   * the CACODEMON's chain is three states, E(3) E(3) F(6), and F is a
;     DIFFERENT image -- the port holds E for the whole 12. The duration is
;     exact, the second image is not, and a second row plus a chain step is
;     the pain STATE machine this block exists to avoid. Every other kind's
;     chain is one image, so every other kind is exact.
;
; TWO procs for one job: ram_map.py's answer to "where does a new .proc go" is
; "not one block of 32 B is left", so this is split over the last two gaps in
; the map -- PAINROW_BASE ($8105, 27 B) and PAINRW2_BASE ($1827, 25 B).
;==============================================================
pain_resume = *
        org PAINROW_BASE

;--------------------------------------------------------------
; ai_pain_row -- ai_hurt's tail. Reached with A = the thing's new TH_MODE and
;   X = #>TH_MODE, which is precisely what ai_hurt's own `jmp ai_put` wanted,
;   so taking the call over costs that block nothing.
;   Leaves Y = the kind and zp_ptr on PTAB_EXT for ai_pain2. zp_ptr+2 is the
;   engine-wide MAP_EXT_BANK $01 that init_level seeds -- bank $01 is where
;   every AI page and the whole .dtab live, so there is nothing to park back.
;--------------------------------------------------------------
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
        jmp ai_pain2
?out    rts
.endp

    .if * > PAINROW_END+1
        ert 'ai_pain_row outgrew PAINROW_BASE..END (memory_map.inc)'
    .endif
        org PAINRW2_BASE

;--------------------------------------------------------------
; ai_pain2 -- Y = kind, zp_ptr = PTAB_EXT: the flinch row into TH_WROW and the
;   kind's own painstate duration onto the clock. The $FF test is not a nicety
;   -- TH_WROW is row+1 and 0 means "not chasing", so $FF+1 would stop the
;   monster dead and ai_tick would never look at it again.
;
;   THE TICS COME OFF PTIC_EXT (2026-08-26), not off a constant. It is the
;   next 16 B page up from PTAB_EXT on purpose: `sta zp_ptr` with a new LOW
;   byte is the whole address change, since zp_ptr+1 is $8C for both and
;   zp_ptr+2 is the engine-wide bank $01. Four bytes, and this block had five.
;
;   The order is TICS FIRST because ai_put eats both zp_ptr and Y -- the row
;   waits on the stack while the tics read still has the pointer it needs.
;--------------------------------------------------------------
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

    .if * > PAINRW2_END+1
        ert 'ai_pain2 outgrew PAINRW2_BASE..END (memory_map.inc)'
    .endif
        org pain_resume

;--------------------------------------------------------------
; ai_cdmg / ai_mul -- the CLAW half of A_TroopAttack and A_BruisAttack, which
;   p_enemy.c writes twice with one number changed:
;       imp:   damage = (P_Random()%8+1)*3
;       baron: damage = (P_Random()%8+1)*10
;   so ?claw serves both and the number comes off the kind. IN: m_a = the 1..8
;   roll. Falls through to aif_hurt, exactly as the old inline *3 did.
;
;   Parked here because the AIATK block has SEVEN spare bytes, not the 384 its
;   _END advertised (PJGO_BASE is $5480). $5BDE and not $5BDB: the first three
;   bytes of that "free" block are ENGIB_VARS, which the RAM budget cannot see.
;--------------------------------------------------------------
cdmg_resume = *
        org AICDMG_BASE
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

;   A = m_a * Y, for Y >= 1. Max 8*10 = 80, so no carry ever leaves the loop
;   and the clc can sit outside it.
.proc ai_mul
        lda #0
        clc
?m      adc m_a
        dey
        bne ?m
        rts
.endp
    .if * > AICDMG_END+1
        ert 'ai_cdmg/ai_mul outgrew AICDMG_BASE..END (memory_map.inc)'
    .endif
        org cdmg_resume

