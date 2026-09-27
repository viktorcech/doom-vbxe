;--------------------------------------------------------------
; ball.asm -- the imp's fireball (MT_TROOPSHOT, reduced): spawn, flight, impact.
;--------------------------------------------------------------
        org BALL_BASE

bl_on   dta 0                        ; 0 = idle, 1 = in flight, 2/3/4 = the
                                     ;   burst frames C/D/E (S_TBALLX1..3)
bl_lvl  dta $FF                      ; the level the vars below belong to
bl_id   dta $FF                      ; BAL1A's sprtab id (things header +18)
bl_xid  dta $FF                      ; the burst's FIRST id, C of C/D/E (+19)
bl_x    dta a(0)                     ; position, whole units...
bl_y    dta a(0)
bl_z    dta a(0)
bl_xf   dta 0                        ; ...and the Q8 fraction per axis
bl_yf   dta 0
bl_zf   dta 0
bl_sx   dta a(0)                     ; step per VBLANK, Q8 signed
bl_sy   dta a(0)
bl_sz   dta a(0)                     ; ...the momz reduction (header note)
bl_sxe  dta 0                        ; its sign extension ($00/$FF)
bl_sye  dta 0
bl_sze  dta 0
bl_ttl  dta 0                        ; VBLANKs left (runaway guard, ~5 s)
bl_ss   dta a(0)                     ; the leaf the ball is in (locate_floor)
bl_dx   dta a(0)                     ; spawn scratch: the aim vector
bl_dy   dta a(0)
bl_dz   dta a(0)
bl_ax   dta 0                        ; |dx8|
bl_f    dta 0                        ; k7 factor
bl_dmg  dta 0                        ; what this ball will take off the player.
bl_a    dta 0                        ; the ATTACK ACTION that threw the missile
                                     ;   in flight -- mk_atk of whoever fired,
                                     ;   which is the index into at_tables.inc.
bl_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0 (not a pickup)

;--------------------------------------------------------------
; ball_spawn -- from ai_fire ?throw: ai_t = the imp, ai_tx/ai_ty = its target
;   (ai_pdist just refreshed both, and ai_ad >= 60). Arms the ball + queues
;   sfx_firsht. Clobbers A/X/Y, m_a/m_b/m_prod, sp_ptr (render scratch).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ball_spawn
        lda bl_on
        bne ?out                     ; the slot is taken: the thrower just animates
        jsr bl_pick                  ; WHOSE ball -> bl_id/bl_xid, A = the id
        bpl ?a                       ; $FF: this level packed no such fireball
?out    rts
?a      jsr bl_roll                  ; ...and how hard it will hit (ai_k again)
                                      ; 2026-09-22 p_mobj.c:905 th->target = source: the
        lda ai_k                     ;   thrower and its kind, for PIT_CheckThing's
        sta bl_ok                    ;   species rule and P_DamageMobj's source
        lda ai_t
        sta bl_own
        jsr en_thing.en_th2w          ; sp_ptr = the shooter's thing record; 16-bit, C = 0
	.LONGA ON
	lda (sp_ptr)
	sta bl_x
	ldy #2
	lda (sp_ptr),y
	sta bl_y
	ldy #4
	lda (sp_ptr),y
	adc #32
	sta bl_z

        ldy #0
        sty bl_xf
        sty bl_yf
        sty bl_zf

        sec                          ; the aim vector, target - shooter
        lda ai_tx
        sbc bl_x
        sta bl_dx

        sec
        lda ai_ty
        sbc bl_y
        sta bl_dy

        sec                          ; dz = dest->z - source->z (p_mobj.c:923),
        lda zp_pz                    ;   feet to feet: player feet = eye - 41,
        sbc #9                       ;   imp feet = bl_z - 32, so
	sec
	sbc bl_z
        sta bl_dz                    ;   dz = (zp_pz-41) - (bl_z-32)
        	                     ;      =  zp_pz - 9 - bl_z
	sep #$20
	.LONGA OFF
        jsr bl_spread                ; the blur sphere turns the aim (powerups.asm)
?red    lda bl_dx                    ; shrink until BOTH deltas fit [-127,127]:
        clc                          ;   v+127 lands in [0,254] exactly then.
        adc #127                     ;   hi+carry != 0 is "outside"; lo = $FF
        tax                          ;   is the one impostor (v = +128, whose
        lda bl_dx+1                  ;   |v| would index past k7's 120 rows).
        adc #0                       ;   ai_ad >= 60 keeps the larger >= 8, so
        bne ?shr                     ;   the k7 row always exists.
        cpx #$FF
        beq ?shr

        lda bl_dy
        clc
        adc #127
        tax
        lda bl_dy+1
        adc #0
        bne ?shr
        cpx #$FF
        beq ?shr

        lda bl_dz                    ; dz only has to fit bl_abs -- it NEVER
        asl                          ;   indexes k7, so the cheap test does:
        lda bl_dz+1                  ;   hi + (lo>>7) is 0 exactly when dz is
        adc #0                       ;   its own sign extension, i.e. -128..127.
	jeq ?aim
?shr
	rep #$20
	.LONGA ON
	lda bl_dx
	cmp #$8000
	ror
	sta bl_dx
	lda bl_dy
	cmp #$8000
	ror
	sta bl_dy

	lda bl_dz
	bpl ?zs
	inc
?zs	cmp #$8000
	ror
	sta bl_dz
	sep #$20
	.LONGA OFF
        bra ?red                     ;   under 1 % and it costs nothing.)

?aim    lda bl_dx
                                              ; 2026-09-22 (drac030 inline): bl_abs
        bpl ?b1
        eor #$FF
        inc @
?b1
        sta bl_ax
        lda bl_dy
                                              ; 2026-09-22 (drac030 inline): bl_abs
        bpl ?b2
        eor #$FF
        inc @
?b2
        cmp bl_ax                    ; max(|dx|,|dy|) -> the k7 row. The XY
        bcs ?ymax                    ;   max sets the flight speed; a huge dz
        lda bl_ax                    ;   can shift it under 8 (a tower imp,
?ymax   cmp #8                       ;   impossible in E1) -- clamp so k7-8,x
        bcs ?mok                     ;   never reads below the table.
        lda #8
?mok    tax
        lda k7-8,x
        sta bl_f
        lda bl_ax                    ; step X = |dx| * k7 (Q8), re-signed
        jsr ?mul
        ldx #0
        lda bl_dx+1
        bpl ?px
        jsr ?neg
        ldx #$FF
?px     lda m_prod
        sta bl_sx
        lda m_prod+1
        sta bl_sx+1
        stx bl_sxe
        lda bl_dy                    ; step Y likewise
                                              ; 2026-09-22 (drac030 inline): bl_abs
        bpl ?b3
        eor #$FF
        inc @
?b3
        jsr ?mul
        ldx #0
        lda bl_dy+1
        bpl ?py
        jsr ?neg
        ldx #$FF
?py     lda m_prod
        sta bl_sy
        lda m_prod+1
        sta bl_sy+1
        stx bl_sye
        lda bl_dz                    ; step Z: the momz reduction (header) --
                                              ; 2026-09-22 (drac030 inline): bl_abs
        bpl ?b4
        eor #$FF
        inc @
?b4
        jsr ?mul                     ;   ball meets the target's z+32 exactly
        ldx #0                       ;   when it meets its XY
        lda bl_dz+1
        bpl ?pz
        jsr ?neg
        ldx #$FF
?pz     lda m_prod
        sta bl_sz
        lda m_prod+1
        sta bl_sz+1
        stx bl_sze
        lda #250                     ; ~5 s of PAL flight, then it just expires
        sta bl_ttl
        lda bl_id
        sta bl_rec+6
        stz bl_rec+7
        inc bl_on
        ldx bl_a                     ; P_SpawnMissile plays the MISSILE's own
        lda at_lsnd-ATM_LO,x         ;   seesound at the LAUNCH: sfx_firsht for
        jmp snd_qp_ai                ;   the two fireballs, sfx_rlaunc for the
                                     ;   (STEREO: from the imp, ai_t)
                                     ;   2026-09-22 idiom: jsr X / rts -> jmp X (both
                                     ;   bank $01, snd_qp_ai returns with rts)

?mul    sta m_a                      ; m_prod = A * bl_f (umul16, high half 0)
        stz m_a+1
        stz m_b+1
        lda bl_f
        sta m_b
        phx                          ; the tail call kept X: umul16 no longer does
        jsr umul16
        plx
        rts

?neg    sec                          ; m_prod = -m_prod (16-bit)
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+1
        sta m_prod+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mv_frameb -- the main loop's mv_frame call, retargeted here: movers first,
;   then the ball's tic. Zero growth in the $2000 segment.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_frameb
        jsr mv_frame
        jmp ball_frame               ; (its own block -- BALLF)
.endp
        .endseg

;--------------------------------------------------------------
; spr_chaseb -- spr_add's chase hook, retargeted: the tracked chasers first,
;   then the ball, projected from the leaf ball_frame located it in. Same
;   contract as spr_chase: zp_nid = the subsector being collected.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_chaseb
        jsr spr_chase
        lda bl_on
        beq ?out
        lda zp_nid
        cmp bl_ss
        bne ?out
        lda zp_nid+1
        and #$7F
        cmp bl_ss+1
        bne ?out
        lda sp_n
        cmp #VIS_MAX
        bcs ?out
        lda #TH_NOTHING              ; vs_th: not a thing (see the header note)
        sta sp_i
        lda #<bl_rec
        sta sp_ptr
        lda #>bl_rec
        sta sp_ptr+1
        jmp spr_proj
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; bl_boom -- P_ExplodeMissile's OTHER half, for a missile whose death chain
;   carries one. X = bl_a (ball_frame's ?burst already has it there).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_boom
        lda at_boom-ATM_LO,x
        beq ?no                      ; a fireball: the burst is cosmetic
        ldx #3
?c      lda bl_x,x
        sta en_bx,x
        dex
        bpl ?c
                                      ; 2026-09-22 A_Explode(mo, mo->target): the
        lda bl_own                   ;   bombsource is the thrower, +1 (en_boomat
        inc @                        ;   puts en_bsrc back to 0 = the player)
        sta en_bsrc
        jmp en_boomat
?no     rts
.endp
        .endseg

    .if * > BALL_END+1
        ert 'ball.asm (spawn half) outgrew BALL_BASE..END (memory_map.inc)'
    .endif

blabs_resume = *
        org BLABS_BASE
;--------------------------------------------------------------
; bl_abs -- A = |A|. Evicted from ball_spawn: the toward-zero dz shift (?zs)
;   needed thirteen bytes and the spawn block had three. It is a leaf, it
;   touches no ball state, and it is called four times from ?aim -- so it was
;   the cheapest thing in the block to move out.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_abs
        bpl ?pos
        eor #$FF
	inc
?pos    rts
.endp
        .endseg
    .if * > BLABS_END+1
        ert 'bl_abs outgrew BLABS_BASE..BLABS_END (memory_map.inc)'
    .endif
        org blabs_resume

blsub_resume = *
        org BLSUBS_BASE
;--------------------------------------------------------------
; bl_subs -- X = the sub-steps ball_frame runs this VBLANK, from at_ssh.
;   0 = MT_TROOPSHOT's rate (the k7 scale IS its 10*FRACUNIT/tic = 7 u/VB on
;   PAL), 1 = twice that, which is MT_ROCKET's 20. The runaway guard halves with
;   it -- bl_ttl is decremented per SUB-STEP, so a rocket lives 2.5 s instead of
;   5 -- and at 700 u/s that is still 1750 units, wider than any DOOM 1 arena.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_subs
        ldx dt_vbl
        ldy bl_a
        lda at_ssh-ATM_LO,y
        beq ?done
        txa
        asl
        tax
?done   rts
.endp
        .endseg
    .if * > BLSUBS_END+1
        ert 'bl_subs outgrew BLSUBS_BASE..END (memory_map.inc)'
    .endif
        org blsub_resume

;--------------------------------------------------------------
; bl_roll -- PIT_CheckThing's ((P_Random()%8)+1) * mobjinfo.damage, for whichever
;   monster is throwing. ai_k is still the SHOOTER's kind here, and mk_atk says
;   which p_enemy.c ACTION it is throwing with -- which is what decides the
;   missile, because that is where info.c and p_enemy.c put it: A_TroopAttack
;--------------------------------------------------------------
;--------------------------------------------------------------
; bl_pick -- which missile is being thrown.
;   OUT: A = bl_id ($FF = this level packed no such missile, and ball_spawn
;   gives up on the shot). Clobbers A/X/Y.
;--------------------------------------------------------------
blp_resume = *
        org BLPICK_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_pick
        ldx ai_k                     ; the SHOOTER's kind -> its attack action
        ldy mk_atk,x                 ;   -> where the .things header keeps that
        ldx at_mspr-ATM_LO,y         ;   action's missile
        lda THINGS_BASE,x
        bpl ?set
        lda THINGS_BASE+18           ; not packed -> BAL1, and $FF there means
?set    sta bl_id                    ;   ball_spawn drops the shot entirely
	inc
        sta bl_xid
        lda bl_id
        rts
.endp
        .endseg
    .if * > BLPICK_END+1
        ert 'bl_pick outgrew BLPICK_BASE..END (memory_map.inc)'
    .endif
        org blp_resume

attab_resume = *
        org ATTAB_BASE               ; the two ball procs are full to a couple of
        icl 'at_tables.inc'          ;   bytes each and data indexes the same
    .if * > ATTAB_END+1              ;   from anywhere -- the k7 table went to
        ert 'at_tables.inc outgrew ATTAB_BASE..END (memory_map.inc)'
    .endif                           ;   the SNDTAB annex for the same reason
        org attab_resume

blr_resume = *
        org BLROLL_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_roll
        ldx ai_k
        lda mk_atk,x
        tax
        stx bl_a                     ; the flight and the burst both need it
        ldy at_mdmg-ATM_LO,x         ; info.c's damage byte for THIS missile
        lda RANDOM
        and #7
	inc
        sta m_a
        jsr ai_mul                   ; ...* the damage byte (max 160, a rocket)
        sta bl_dmg
        rts
.endp
        .endseg
    .if * > BLROLL_END+1
        ert 'bl_roll outgrew BLROLL_BASE..END (memory_map.inc)'
    .endif
        org blr_resume

;==============================================================
; The per-frame half, in its own hole (one proc, one block). The k7 table
; lives in the SNDTAB annex (sound.asm) -- both ball holes filled up, and
; data indexes the same from anywhere.
;==============================================================
        org BALLF_BASE

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ball_frame
        lda current_level            ; new level: forget the ball, learn its
        cmp bl_lvl                   ;   BAL1 id, and park index 255 as "no
        beq ?same                    ;   thing": health 0 (en_shoot skips it),
        sta bl_lvl                   ;   state 0 (spr_dyn draws it live)
        lda #0
        sta bl_on
        sta.l EXT_BASE+TH_HPL+TH_NOTHING
        sta.l EXT_BASE+TH_HPL+$100+TH_NOTHING
        sta.l EXT_BASE+TH_STATE+TH_NOTHING
        sta.l EXT_BASE+TH_KIND+TH_NOTHING    ; en_kfill fills TH_KIND only up to the
                                     ;   thing COUNT, so 255 is uninitialised ...
        lda THINGS_BASE+18           ; pack_things header: the flight id...
        sta bl_id
        lda THINGS_BASE+19           ; ...and the burst's first id (C)
        sta bl_xid
?same   lda bl_on
        bne ?run
?out    rts
?run    cmp #2                       ; 2..4 = the burst is playing: 6 DOOM tics
        bcc ?fly0                    ;   (9 VB) per frame, C -> D -> E -> gone
        lda bl_ttl                   ;   (info.c S_TBALLX1..3), parked where it
                                     ;   died -- no movement, no hit test. C = 1
                                     ;   past the bcc: the sbc needs no sec
        sbc dt_vbl                    ; DOWN BY dt_vbl, not by one: this runs once
        sta bl_ttl                   ;   a FRAME and a frame is 4-6 VBLANKs, so
        bcc ?nx                      ;   a `dec` stretched the 27-VBLANK burst
        bne ?out                     ;   over two seconds (proj.asm, same fix)
?nx     inc bl_on
        lda bl_on
        cmp #5
        bcc ?nxf
        stz bl_on
        rts
?nxf    inc bl_rec+6                 ; D, then E -- consecutive sprtab ids
        lda #9
        sta bl_ttl
        rts
?fly0   jsr bl_subs                  ; sub-steps of ~7 u each, so a whole-frame
?step   clc                          ;   step could tunnel through the player's
        lda bl_xf                    ;   22-unit window. TWO per VBLANK for the
                                     ;   rocket (info.c speed 20 against the k7 ...
        adc bl_sx
        sta bl_xf
        lda bl_x
        adc bl_sx+1
        sta bl_x
        lda bl_x+1
        adc bl_sxe
        sta bl_x+1
        clc
        lda bl_yf
        adc bl_sy
        sta bl_yf
        lda bl_y
        adc bl_sy+1
        sta bl_y
        lda bl_y+1
        adc bl_sye
        sta bl_y+1
        clc                          ; the momz descent/climb (ball_spawn)
        lda bl_zf
        adc bl_sz
        sta bl_zf
        lda bl_z
        adc bl_sz+1
        sta bl_z
        lda bl_z+1
        adc bl_sze
        sta bl_z+1
        dec bl_ttl
        beq ?gone 
        ;bra ?gone                    ; flew its 5 s: vanish (DOOM balls only

?fly    rep #$20                     ; ---- 16-bit A: |x - px| < 22 and |y - py|
        .LONGA ON                    ;   < 22 (radius 6 + 16), each one subtract,
        sec                          ;   one negate in A and one compare -- the
        lda bl_x                     ;   ?a16 + high-byte tests collapsed, as in
        sbc zp_px                    ;   pj_frame (|d| >= 256 fails the compare
        bpl ?ax                      ;   here just as it failed the hi test)
        eor #$FFFF
        inc @
?ax     cmp #22
        bcs ?miss16
        sec                          ; |dy| < 22
        lda bl_y
        sbc zp_py
        bpl ?ay
        eor #$FFFF
        inc @
?ay     cmp #22
        bcs ?miss16
        sec                          ; z: feet <= ball <= feet+56, feet =
        lda bl_z                     ;   zp_pz - EYE(41) -> 0 <= z-pz+41 <= 56
        sbc zp_pz
        clc
        adc #41
        sta m_a
        sep #$20
        .LONGA OFF
        xba
        bne ?miss
        lda m_a
        cmp #57
        bcs ?miss
                                      ; 2026-09-22 P_DamageMobj(player, missile,
        lda bl_own                   ;   missile->target): the thrower, +1, is the
        inc @                        ;   attacker P_DeathThink turns to
        sta pl_src
        jsr pl_thrust                ; P_DamageMobj, both halves: the shove first
        bra ?burst
?miss16 sep #$20                     ; (falls into ?miss below)
        .LONGA OFF

                                      ; 2026-09-22 p_map.c P_CheckPosition: the THINGS
?miss   phx                          ;   first (bl_thing, PIT_CheckThing's missile
        jsr bl_thing                 ;   half), then the leaf + floor/lintel + wall
        bcs ?mhit                    ;   (plx keeps C)
        jsr ?chk
?mhit   plx
        bcs ?burst
        dex                          ;   (dt_vbl x 7 u between samples vs the 8 u
	jeq ?rec
	jmp ?step

?gone
        stz bl_on
        rts
?burst  ldx bl_a                     ; P_ExplodeMissile: the deathsound of the
        lda at_xsnd-ATM_LO,x         ;   missile that is actually flying --
        jsr snd_qp_ball              ;   sfx_firxpl for a fireball, sfx_barexp
                                     ;   (STEREO: from bl_x/bl_y; X survives)
        jsr bl_boom                  ;   for the cyberdemon's rocket... and, if
                                     ;   info.c hung an A_Explode off that
                                     ;   chain, the BLAST (X is still bl_a)
        lda bl_xid
        bmi ?gone                    ; no burst frames packed: just vanish
        sta bl_rec+6                 ; ...and S_TBALLX1: park on frame C WHERE
        jsr ?rec                     ;   IT DIED (sub-step exact), 6 DOOM tics
        lda #2                       ;   (9 VB) per frame
        sta bl_on
        lda #9
        sta bl_ttl
        rts

?chk
	pei (zp_px)
	pei (zp_py)

	rep #$20
	.LONGA ON
        lda bl_x
        sta zp_px
        lda bl_y
        sta zp_py
	sep #$20
	.LONGA OFF
        jsr locate_floor             ; zp_nid = leaf, loc_floor, zp_ptr = sector
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
	.LONGA ON
        lda zp_nid
	and #$7fff
        sta bl_ss
	
	pla
	sta zp_py
	pla
	sta zp_px

	lda loc_floor
	cmp bl_z
	bpl ?hitw

        ldy #2                       ; ceiling below it -> lintel / shut door
        lda (zp_ptr),y               ;   (zp_ptr still points at the sector)
        cmp bl_z
	sep #$20
	.LONGA OFF
	jpl bl_wall
?hit	sec
        rts
?hitw	sep #$21
	.LONGA OFF
	rts

?rec
	rep #$20
	.LONGA ON
	lda bl_x
        sta bl_rec
        lda bl_y
        sta bl_rec+2
        sec                          ; anchor = flight z - 8: the 15 px ball
        lda bl_z                     ;   hangs centred on its path
        sbc #8
        sta bl_rec+4
	sep #$20
	.LONGA OFF	
        rts

?a16    bpl ?ap                      ; m_a(16, A=hi) = |m_a|; Z flags hi = 0
        eor #$FF
        tay
        sec
        lda #0
        sbc m_a
        sta m_a
        tya
        adc #0
?ap     rts
.endp
        .endseg

    .if * > BALLF_END+1
        ert 'ball_frame outgrew BALLF_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; bl_thing -- p_map.c PIT_CheckThing's missile half at bl_x/bl_y/bl_z. C=1: the
;   missile stops in a solid thing, and a shootable one of another species than
;   the thrower takes bl_dmg from bl_own ("same species: explode, no damage").
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_thing
        lda #6                       ; info.c radius: the three fireballs 6,
        ldx bl_a                     ;   MT_ROCKET 11 (bl_a 6 = A_CyberAttack,
        cpx #6                       ;   at_tables.inc)
        bne ?r
        lda #11
?r      sta sol_rad
        stz sol_bd+1                 ; blockdist <= 128 + 11: the high byte stays 0
        rep #$20
        .LONGA ON
        lda bl_x                     ; blk_tgt reads coll_cx/coll_cy
        sta coll_cx
        lda bl_y
        sta coll_cy
        .LONGA OFF
        sep #$20
        jsr blk_tgt                  ; sol_cx/sol_cy = the ball's cell
        stz zp_ptr                   ; every per-thing page is 256 B aligned
                                      ; 2026-09-23: the cell counter lives in X at the
        ldx #0                       ;   loop's ends (no inc/lda/cmp in memory), and
?cell   stx sol_n                    ;   sol_cy/blk_oy are rows * 8 (blk_tgt)
        lda sol_cx                   ; P_BlockThingsIterator: the 3x3 cells
        clc
        adc blk_ox,x
        and #7
        sta sol_c
        lda sol_cy
        clc
        adc blk_oy,x
        and #$38
        ora sol_c
        tay
        lda #>BLK_HEAD
        sta zp_ptr+1
        lda [zp_ptr],y               ; the first thing filed in that cell
        bra ?item
?ncell  ldx sol_n
        inx
        cpx #9
        bcc ?cell
        clc                          ; C=0: nothing in the way (the cmp left C=1)
        rts
        .LONGA ON
?miss16 sep #$20
        .LONGA OFF
?nitem  ldy sol_i                    ; ...the next thing in the same cell
        lda #>TH_BNEXT
        sta zp_ptr+1
        lda [zp_ptr],y
?item   cmp #$FF
        beq ?ncell
        sta sol_i
        cmp bl_own                   ; the thrower itself: passed through
        beq ?nitem
        tay
        lda #>TH_RAD
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?nitem                   ; radius 0: not MF_SOLID
        clc
        adc sol_rad
        sta sol_bd
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?nitem                   ; dying / a corpse: MF_SOLID is gone
        tya                          ; THING_ALIVE: removed from the level?
        and #7
        tax
        tya
        lsr
        lsr
        lsr
        tay
        lda THING_ALIVE,y
        and mv_bit,x
        beq ?nitem
        lda sol_i
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record (x +0, y +2, z +4)
        .LONGA ON
        lda (sp_ptr)                 ; |x - bx| < blockdist
        sec
        sbc coll_cx
        bpl ?ax
        eor #$FFFF
        inc @
?ax     cmp sol_bd
        bcs ?miss16
        ldy #2                       ; |y - by| < blockdist
        lda (sp_ptr),y
        sec
        sbc coll_cy
        bpl ?ay
        eor #$FFFF
        inc @
?ay     cmp sol_bd
        bcs ?miss16
        ldy #4                       ; z <= ball <= z + 56: the player test's own
        lda bl_z                     ;   window (a thing's height is not stored)
        sec
        sbc (sp_ptr),y
        cmp #57
        bcs ?miss16
        sep #$20
        .LONGA OFF
        ldy sol_i                    ; it stops here: shootable, and alive?
        jsr aif_live
        bcc ?stop                    ; a solid decoration: explode, no damage
        lda #>TH_KIND                ; (aif_live left zp_ptr on a TH_ page)
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp bl_ok
        beq ?stop                    ; the thrower's own species: no damage
        lda ai_t                     ; P_DamageMobj(thing, missile, missile->target)
        pha
        lda bl_own
        sta ai_t
        sty ai_vt
        lda bl_dmg
        jsr aif_dmg
        pla
        sta ai_t
?stop   sec
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
bl_own  dta 0                        ; the thrower (missile->target), a thing index
bl_ok   dta 0                        ; ...and its kind (TH_KIND), for the species rule
        .endseg

;--------------------------------------------------------------
; bl_wall -- ?chk's third test: is there a WALL where the ball now is?
;   OUT: C=1 = it hit a wall. Tail-called from ?chk, so this IS ?chk's answer.
;--------------------------------------------------------------
bw_resume = *
        org BLWALL_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_wall
        ldx #3                       ; bl_x/bl_y are four contiguous bytes and so
?cp     lda bl_x,x                   ;   are coll_cx/coll_cy: one loop at 10 B
        sta coll_cx,x                ;   instead of eight loads and eight stores
        dex                          ;   -- which is what makes this fit the hole
        bpl ?cp
        pha                          ; (DRAC_PLAN 2b) cs_hmin is an operand byte
        lda #0                       ;   inside coll_seg, which runs in bank $01:
        sta.l B1CODE_BASE+coll_seg.cs_hmin ; a long store (no long stz), A kept.
        pla                          ;   Not phk/plb: an NMI in that window ran
                                     ;   rom_nmi with DBR = $01
        jsr coll_plr       
        ldx #PLAYER_H                ; ...back before anything else can read it
        pha                          ; (long store again; A holds coll_plr's
        txa                          ;   answer for the lsr, so save it)
        sta.l B1CODE_BASE+coll_seg.cs_hmin
        pla
        lsr                          ; A is exactly 0 or 1 -> C = "blocked"
        rts
.endp
        .endseg
    .if * > BLWALL_END+1
        ert 'bl_wall outgrew BLWALL_BASE..END (memory_map.inc)'
    .endif
        org bw_resume
