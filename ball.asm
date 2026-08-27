;==============================================================
; BALL (2026-08-04) -- the imp's fireball: MT_TROOPSHOT, reduced.
;   _pomocne/_doomsrc is the authority:
;     * A_TroopAttack (p_enemy.c): out of melee range -> P_SpawnMissile
;       (MT_TROOPSHOT); ai_fire's ?throw lands here.
;     * P_SpawnMissile (p_mobj.c): spawn at (x, y, z+32), play the missile's
;       seesound (sfx_firsht), momx/y = speed toward the target.
;     * MT_TROOPSHOT (info.c): speed 10*FRACUNIT/tic = 7 units/VBLANK (PAL),
;       radius 6, height 8, damage byte 3 -> a hit rolls ((P_Random()&7)+1)*3
;       (PIT_CheckThing), deathsound sfx_firxpl (P_ExplodeMissile).
;     * momz (p_mobj.c:917): dist/speed tics of flight, so momz =
;       (dest->z - source->z)/(dist/speed) -- the ball arrives at the
;       target's z + 32 exactly as it arrives in XY. Here dz rides the SAME
;       shift-reduce and the SAME k7 factor as dx/dy, which is that formula
;       verbatim (all three axes share one flight time). Without it a ledge
;       imp threw level over the player's head -- the 2026-08-04 report.
;   NOT DOOM, on purpose (one ball, no mobj):
;     * ONE ball in flight -- an imp with the slot taken just animates, which
;       doubles as the fire-rate limit.
;     * no BAL1 C-E burst frames yet (they fit no more than 4 of 9 level
;       arenas -- pack_things): the ball stops existing + sfx_firxpl.
;     * the ball is NOT a thing. It rides a pseudo thing record (bl_rec) and
;       spr_chaseb projects it from the leaf it is actually in -- the same
;       side-table idea ai_track uses for chasers. vs_th = 255 with
;       TH_HPL/TH_STATE[255] = 0, so en_shoot cannot target it and spr_dyn
;       treats it as alive; DOOM's fireballs are unshootable the same way.
;   AIM: dx/dy = target - shooter, arithmetic-shifted until BOTH fit
;   [-127,127]; the larger lands in [8,127] and k7[max] = round(7*256/max)
;   makes its Q8 step ~7 u/VB. An [8,15] window cost up to 6 degrees of aim
;   (asr floors negatives: -17,15 >> 1 = -9,7) -- the long table keeps the
;   error under 1 degree (_verify_ball.py measures it). Chebyshev, not
;   Euclid: a diagonal ball runs up to 1.41x DOOM's speed -- the same corner
;   DOOM's own monsters cut with xspeed[]*47000/65536 left uncut.
;   Contract: tools/_verify_ball.py. Split over two holes: ball_frame is in
;   its own block (BALLF) -- one proc, one block, the ram_map rule.
;==============================================================
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
                                     ;   DOOM rolls it in PIT_CheckThing, at the
                                     ;   IMPACT; this rolls it at the SPAWN and
                                     ;   carries it, which is the same thing here
                                     ;   -- the roll is independent of everything
                                     ;   in between and the port's P_Random is
                                     ;   POKEY's RANDOM, not DOOM's shared table,
                                     ;   so nothing downstream depends on WHEN a
                                     ;   number is drawn. It buys the impact path
                                     ;   its multiply back: BALLF has 9 spare
                                     ;   bytes (pf_tan starts at $6DD3).
bl_a    dta 0                        ; the ATTACK ACTION that threw the missile
                                     ;   in flight -- mk_atk of whoever fired,
                                     ;   which is the index into at_tables.inc.
                                     ;   Carried, not looked up again: the burst
                                     ;   happens long after ball_spawn returned
                                     ;   and ai_k is whatever monster the AI is
                                     ;   chewing on by then -- the ball is not a
                                     ;   thing and has no kind of its own to ask.
                                     ;   bl_roll parks it (it has the byte in a
                                     ;   register already)
bl_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0 (not a pickup)

;--------------------------------------------------------------
; ball_spawn -- from ai_fire ?throw: ai_t = the imp, ai_tx/ai_ty = its target
;   (ai_pdist just refreshed both, and ai_ad >= 60). Arms the ball + queues
;   sfx_firsht. Clobbers A/X/Y, m_a/m_b/m_prod, sp_ptr (render scratch).
;--------------------------------------------------------------
.proc ball_spawn
        lda bl_on
        bne ?out                     ; the slot is taken: the thrower just animates
        jsr bl_pick                  ; WHOSE ball -> bl_id/bl_xid, A = the id
        bpl ?a                       ; $FF: this level packed no such fireball
?out    rts
?a      jsr bl_roll                  ; ...and how hard it will hit (ai_k again)
        lda ai_t
        jsr en_thing.en_th2          ; sp_ptr = the shooter's thing record
        ldy #0
        lda (sp_ptr),y               ; ball starts at the imp...
        sta bl_x
        iny
        lda (sp_ptr),y
        sta bl_x+1
        iny
        lda (sp_ptr),y
        sta bl_y
        iny
        lda (sp_ptr),y
        sta bl_y+1
        iny
        lda (sp_ptr),y               ; ...z = its floor anchor + 32
        clc                          ;   (P_SpawnMissile's 4*8*FRACUNIT)
        adc #32
        sta bl_z
        iny
        lda (sp_ptr),y
        adc #0
        sta bl_z+1
        lda #0
        sta bl_xf
        sta bl_yf
        sta bl_zf
        sec                          ; the aim vector, target - shooter
        lda ai_tx
        sbc bl_x
        sta bl_dx
        lda ai_tx+1
        sbc bl_x+1
        sta bl_dx+1
        sec
        lda ai_ty
        sbc bl_y
        sta bl_dy
        lda ai_ty+1
        sbc bl_y+1
        sta bl_dy+1
        sec                          ; dz = dest->z - source->z (p_mobj.c:923),
        lda zp_pz                    ;   feet to feet: player feet = eye - 41,
        sbc #9                       ;   imp feet = bl_z - 32, so
        sta bl_dz                    ;   dz = (zp_pz-41) - (bl_z-32)
        lda zp_pz+1                  ;      =  zp_pz - 9 - bl_z
        sbc #0
        sta bl_dz+1
        sec
        lda bl_dz
        sbc bl_z
        sta bl_dz
        lda bl_dz+1
        sbc bl_z+1
        sta bl_dz+1
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
        bne ?shr                     ;   Seven bytes cheaper than the dx/dy
        jmp ?aim                     ;   form, and they pay for ?zs below.
?shr    lda bl_dx+1                  ; asr all three -- direction AND the
        cmp #$80                     ;   descent slope survive together (they
        ror bl_dx+1                  ;   share the flight time)
        ror bl_dx
        lda bl_dy+1
        cmp #$80
        ror bl_dy+1
        ror bl_dy
        lda bl_dz+1                  ; ...but dz rounds TOWARD ZERO, not down.
        bpl ?zs                      ;   An arithmetic shift is FLOOR: -1 halves
        inc bl_dz                    ;   to -1 for ever while +1 halves to 0, so
        bne ?zs                      ;   every trajectory leaned DOWN -- measured
        inc bl_dz+1                  ;   -8.6 units of drop on average and -31 at
        lda bl_dz+1                  ;   3000. Adding 1 first when dz is negative
?zs     cmp #$80                     ;   makes the two directions symmetric and
        ror bl_dz+1                  ;   the mean error 0.0. (dx/dy keep the plain
        ror bl_dz                    ;   asr: they are large, so their floor is
        jmp ?red                     ;   under 1 % and it costs nothing.)
?aim    lda bl_dx
        jsr bl_abs
        sta bl_ax
        lda bl_dy
        jsr bl_abs
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
        jsr bl_abs
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
        jsr bl_abs                     ;   same shifts, same k7 factor, so the
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
        lda #0
        sta bl_rec+7
        inc bl_on
        ldx bl_a                     ; P_SpawnMissile plays the MISSILE's own
        lda at_lsnd-ATM_LO,x         ;   seesound at the LAUNCH: sfx_firsht for
        sta snd_pending              ;   the two fireballs, sfx_rlaunc for the
        rts                          ;   cyberdemon's rocket (at_tables.inc)
?mul    sta m_a                      ; m_prod = A * bl_f (umul16, high half 0)
        lda #0
        sta m_a+1
        sta m_b+1
        lda bl_f
        sta m_b
        jmp umul16
?neg    sec                          ; m_prod = -m_prod (16-bit)
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+1
        sta m_prod+1
        rts
.endp

;--------------------------------------------------------------
; mv_frameb -- the main loop's mv_frame call, retargeted here: movers first,
;   then the ball's tic. Zero growth in the $2000 segment.
;--------------------------------------------------------------
.proc mv_frameb
        jsr mv_frame
        jmp ball_frame               ; (its own block -- BALLF)
.endp

;--------------------------------------------------------------
; spr_chaseb -- spr_add's chase hook, retargeted: the tracked chasers first,
;   then the ball, projected from the leaf ball_frame located it in. Same
;   contract as spr_chase: zp_nid = the subsector being collected.
;--------------------------------------------------------------
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
        jsr spr_proj
?out    rts
.endp

;--------------------------------------------------------------
; bl_boom -- P_ExplodeMissile's OTHER half, for a missile whose death chain
;   carries one. X = bl_a (ball_frame's ?burst already has it there).
;
;   info.c gives MT_ROCKET the deathstate S_EXPLODE1, and S_EXPLODE1 is
;   {A_Explode} = P_RadiusAttack(spot, target, 128). The imp's S_TBALLX1..3 and
;   the baron's S_BRBALLX1..3 carry no action at all, so those two only ever
;   hurt what they land ON -- which is what this port did for ALL THREE, and it
;   is most of what the cyberdemon was missing: in DOOM a rocket that lands
;   NEAR you still takes 128 - dist off, and one that lands near another
;   monster starts a fight. at_boom (at_tables.inc) is that distinction, read
;   off the chain by pack_things._explodes rather than hardcoded.
;
;   en_boomat is the barrel's A_Explode with no exploding THING -- exactly the
;   shape a missile wants, since the ball is not a thing either. It takes the
;   spot in en_bx/en_by, which is why the four bytes are copied: bl_x/bl_y and
;   en_bx/en_by are each an adjacent pair, so one 4-byte loop does it.
;   PIT_RadiusAttack's boss exemption rides along for free -- en_bthings goes
;   through en_bdist now, so a cyberdemon's own rocket cannot splash a
;   cyberdemon, which is p_map.c verbatim.
;--------------------------------------------------------------
.proc bl_boom
        lda at_boom-ATM_LO,x
        beq ?no                      ; a fireball: the burst is cosmetic
        ldx #3
?c      lda bl_x,x
        sta en_bx,x
        dex
        bpl ?c
        jmp en_boomat
?no     rts
.endp

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
.proc bl_abs
        bpl ?pos
        eor #$FF
        clc
        adc #1
?pos    rts
.endp
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
.proc bl_subs
        ldx fps_n
        ldy bl_a
        lda at_ssh-ATM_LO,y
        beq ?done
        txa
        asl
        tax
?done   rts
.endp
    .if * > BLSUBS_END+1
        ert 'bl_subs outgrew BLSUBS_BASE..END (memory_map.inc)'
    .endif
        org blsub_resume

;--------------------------------------------------------------
; bl_roll -- PIT_CheckThing's ((P_Random()%8)+1) * mobjinfo.damage, for whichever
;   monster is throwing. ai_k is still the SHOOTER's kind here, and mk_atk says
;   which p_enemy.c ACTION it is throwing with -- which is what decides the
;   missile, because that is where info.c and p_enemy.c put it: A_TroopAttack
;   (3) launches MT_TROOPSHOT, damage 3; A_BruisAttack (5) MT_BRUISERSHOT,
;   damage 8; A_CyberAttack (6) MT_ROCKET, damage 20 (2026-08-20). The three
;   damage bytes are at_mdmg (at_tables.inc), straight out of info.c.
;
;   Called from INSIDE ball_spawn, past the bl_on guard -- one missile flies at
;   a time in this port, and a baron who found the slot busy must not re-arm the
;   imp's ball in flight.
;
;   Parked in en_boom's tail ($03C5, the OS block this port reclaimed): the ball
;   blocks have 12 and 9 spare bytes.
;--------------------------------------------------------------
;--------------------------------------------------------------
; bl_pick -- which missile is being thrown. Same table, same index: at_mspr
;   turns the shooter's ATTACK ACTION into the .things header offset where that
;   missile's flight sprite id lives -- +18 BAL1 (the imp's), +33 BAL7 (the
;   baron's green one), +20 MISL (the cyberdemon's rocket, which the player's
;   launcher already puts on every level). One ball flies at a time here, so the
;   pair of ids is simply re-chosen at every spawn -- which is why this runs
;   INSIDE ball_spawn, past the bl_on guard: a cyberdemon who found the slot
;   busy must not repaint the imp's ball in flight.
;
;   pack_things packs each set flight-frame-then-burst, back to back, so the
;   burst is always the flight frame's id + 1 and only ONE id has to be stored.
;   OUT: A = bl_id ($FF = this level packed no such missile, and ball_spawn
;   gives up on the shot). Clobbers A/X/Y.
;--------------------------------------------------------------
blp_resume = *
        org BLPICK_BASE
.proc bl_pick
        ldx ai_k                     ; the SHOOTER's kind -> its attack action
        ldy mk_atk,x                 ;   -> where the .things header keeps that
        ldx at_mspr-ATM_LO,y         ;   action's missile
        lda THINGS_BASE,x
        bpl ?set
        lda THINGS_BASE+18           ; not packed -> BAL1, and $FF there means
?set    sta bl_id                    ;   ball_spawn drops the shot entirely
        clc
        adc #1                       ; the burst follows the flight frame
        sta bl_xid
        lda bl_id
        rts
.endp
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
.proc bl_roll
        ldx ai_k
        lda mk_atk,x
        tax
        stx bl_a                     ; the flight and the burst both need it
        ldy at_mdmg-ATM_LO,x         ; info.c's damage byte for THIS missile
        lda RANDOM
        and #7
        clc
        adc #1                       ; 1..8
        sta m_a
        jsr ai_mul                   ; ...* the damage byte (max 160, a rocket)
        sta bl_dmg
        rts
.endp
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

.proc ball_frame
        lda current_level            ; new level: forget the ball, learn its
        cmp bl_lvl                   ;   BAL1 id, and park index 255 as "no
        beq ?same                    ;   thing": health 0 (en_shoot skips it),
        sta bl_lvl                   ;   state 0 (spr_dyn draws it live)
        lda #0
        sta bl_on
        sta.l $010000+TH_HPL+TH_NOTHING
        sta.l $010000+TH_HPL+$100+TH_NOTHING
        sta.l $010000+TH_STATE+TH_NOTHING
        sta.l $010000+TH_KIND+TH_NOTHING    ; en_kfill fills TH_KIND only up to the
                                     ;   thing COUNT, so 255 is uninitialised
                                     ;   SRAM: nonzero and wrot_idle takes the
                                     ;   ball down the monster path, into a
                                     ;   garbage walk row (proj.asm, same fix)
        lda THINGS_BASE+18           ; pack_things header: the flight id...
        sta bl_id
        lda THINGS_BASE+19           ; ...and the burst's first id (C)
        sta bl_xid
?same   lda bl_on
        bne ?run
?out    rts
?run    cmp #2                       ; 2..4 = the burst is playing: 6 DOOM tics
        bcc ?fly0                    ;   (9 VB) per frame, C -> D -> E -> gone
        sec                          ;   (info.c S_TBALLX1..3), parked where it
        lda bl_ttl                   ;   died -- no movement, no hit test.
        sbc fps_n                    ; DOWN BY fps_n, not by one: this runs once
        sta bl_ttl                   ;   a FRAME and a frame is 4-6 VBLANKs, so
        bcc ?nx                      ;   a `dec` stretched the 27-VBLANK burst
        bne ?out                     ;   over two seconds (proj.asm, same fix)
?nx     inc bl_on
        lda bl_on
        cmp #5
        bcc ?nxf
        lda #0                       ; E ran out: the ball is gone
        sta bl_on
        rts
?nxf    inc bl_rec+6                 ; D, then E -- consecutive sprtab ids
        lda #9
        sta bl_ttl
        rts
?fly0   jsr bl_subs                  ; sub-steps of ~7 u each, so a whole-frame
?step   clc                          ;   step could tunnel through the player's
        lda bl_xf                    ;   22-unit window. TWO per VBLANK for the
                                     ;   rocket (info.c speed 20 against the k7
                                     ;   scale's 10) -- same three bytes the
                                     ;   `ldx fps_n` here used to be
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
        bne ?fly
        jmp ?gone                    ; flew its 5 s: vanish (DOOM balls only
?fly    sec                          ;   die on impact; this is a runaway guard)
        lda bl_x                     ; the player? |dx| < 22 (radius 6 + 16)
        sbc zp_px
        sta m_a
        lda bl_x+1
        sbc zp_px+1
        jsr ?a16
        bne ?miss
        lda m_a
        cmp #22
        bcs ?miss
        sec                          ; |dy| < 22
        lda bl_y
        sbc zp_py
        sta m_a
        lda bl_y+1
        sbc zp_py+1
        jsr ?a16
        bne ?miss
        lda m_a
        cmp #22
        bcs ?miss
        sec                          ; z: feet <= ball <= feet+56, feet =
        lda bl_z                     ;   zp_pz - EYE(41) -> 0 <= z-pz+41 <= 56
        sbc zp_pz
        sta m_a
        lda bl_z+1
        sbc zp_pz+1
        sta m_a+1
        clc
        lda m_a
        adc #41
        sta m_a
        lda m_a+1
        adc #0
        bne ?miss
        lda m_a
        cmp #57
        bcs ?miss
        jsr pl_thrust                ; P_DamageMobj, both halves: the shove first
                                     ;   (p_inter.c:806 kicks BEFORE the health
                                     ;   test), then the `lda bl_dmg / jsr
                                     ;   en_plr_hurt` that stood here, which
                                     ;   pl_kick.asm makes itself -- that is
                                     ;   what pays for this call, ball_frame
                                     ;   being full to the byte.
                                     ;   Damage is PIT_CheckThing's
                                     ;   ((P_Random()&7)+1) * the mobj's byte
                                     ;   (see bl_dmg): 3..24 from an imp, 8..64
                                     ;   from a baron. The pain grunt queues
                                     ;   inside en_plr_hurt.
        jmp ?burst
?miss   stx bl_ax                    ; sub-step counter (bl_ax is spawn scratch,
        jsr ?chk                     ;   dead in flight). Leaf + floor/lintel on
        bcs ?burst                   ;   EVERY sub-step: the old once-per-frame
        ldx bl_ax                    ;   test tunneled a thin shut door whole
        dex                          ;   (fps_n x 7 u between samples vs the 8 u
        bne ?more                    ;   the door sector is thick) -- the imp's
        jmp ?rec                     ;   ball flew through closed doors
?more   jmp ?step
?gone   lda #0                       ; expired mid-air: vanish in silence
        sta bl_on
        rts
?burst  ldx bl_a                     ; P_ExplodeMissile: the deathsound of the
        lda at_xsnd-ATM_LO,x         ;   missile that is actually flying --
        sta snd_pending              ;   sfx_firxpl for a fireball, sfx_barexp
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
?chk    lda zp_px                    ; which leaf is the ball in? locate_floor
        pha                          ;   reads zp_px/py, so borrow them,
        lda zp_px+1                  ;   use_ray-style. C=1: it hit something.
        pha
        lda zp_py
        pha
        lda zp_py+1
        pha
        lda bl_x
        sta zp_px
        lda bl_x+1
        sta zp_px+1
        lda bl_y
        sta zp_py
        lda bl_y+1
        sta zp_py+1
        jsr locate_floor             ; zp_nid = leaf, loc_floor, zp_ptr = sector
        lda zp_nid
        sta bl_ss
        lda zp_nid+1
        and #$7F
        sta bl_ss+1
        pla
        sta zp_py+1
        pla
        sta zp_py
        pla
        sta zp_px+1
        pla
        sta zp_px
        sec                          ; floor at/above the ball -> it hit a step,
        lda loc_floor                ;   a riser, a raised platform
        sbc bl_z
        lda loc_floor+1
        sbc bl_z+1
        bpl ?hit
        ldy #2                       ; ceiling below it -> lintel / shut door
        sec                          ;   (zp_ptr still points at the sector)
        lda (zp_ptr),y
        sbc bl_z
        iny
        lda (zp_ptr),y
        sbc bl_z+1
        bmi ?hit
        jmp bl_wall                  ; ...and only now the WALL. Tail call: its
                                     ;   C IS this routine's answer.
?hit    sec
        rts
?rec    lda bl_x
        sta bl_rec
        lda bl_x+1
        sta bl_rec+1
        lda bl_y
        sta bl_rec+2
        lda bl_y+1
        sta bl_rec+3
        sec                          ; anchor = flight z - 8: the 15 px ball
        lda bl_z                     ;   hangs centred on its path
        sbc #8
        sta bl_rec+4
        lda bl_z+1
        sbc #0
        sta bl_rec+5
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

    .if * > BALLF_END+1
        ert 'ball_frame outgrew BALLF_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; bl_wall -- ?chk's third test: is there a WALL where the ball now is?
;
;   Everything ?chk did before this was VERTICAL -- locate_floor's floor and the
;   sector's ceiling, both against bl_z -- so a plain one-sided wall was
;   invisible to the ball. The BSP descent returns the leaf on the FAR side
;   perfectly happily, nothing in the file has ever looked at a seg, and the
;   flight carried straight on through the brickwork until the ~5 s runaway
;   guard fired. That guard exits through ?gone, which is the SILENT one: no
;   S_TBALLX1..3, no sfx_firxpl, the ball just stops existing somewhere behind
;   the wall (2026-08-13, "imp gula po naraze do steny nema animaciu.. ani
;   bossovej plazmy" -- both fireballs ride this one path, bl_pick only swaps
;   BAL1 for BAL7). tools/tests/_dbg_ballwall.py measures it: from E1M1's spawn
;   the ball used to fly its whole 1785-unit guard down every axis, through
;   one-sided walls 64 to 736 units out, and land on bl_on = 0 each time.
;
;   collide_blocked is the answer already in the box -- the same BSP range query
;   every player and every monster step runs, so the ball inherits its exactness
;   for nothing. Two notes on the fit:
;     * RADIUS. It tests PLAYER_R where MT_TROOPSHOT's is 6, so the burst can
;       land a few units short of the wall face. At 160x168 with a 15x15 ball
;       that is inside a pixel or two -- not worth carrying a second radius.
;     * OPENING, which is NOT cosmetic. coll_seg blocks a 2-sided line whose
;       opening is under PLAYER_H (56). That is the PLAYER's clearance and has
;       nothing to do with a fireball: DOOM flies MT_TROOPSHOT (height 8)
;       through any gap it fits in, and ?chk's floor/lintel pair has ALREADY
;       answered the vertical question against bl_z. Left alone, this fix would
;       have burst every ball on the frame of a low window instead of letting it
;       through -- a fresh bug traded for the old one. So the threshold byte
;       (coll_seg.cs_hmin) goes to 0 for the call and straight back after:
;       one-sided and ML_BLOCKING segs still block (coll_seg branches to ?wall
;       long before the opening test), every open 2-sided line now passes, and
;       the player/monster path never sees anything but PLAYER_H.
;   OUT: C=1 = it hit a wall. Tail-called from ?chk, so this IS ?chk's answer.
;--------------------------------------------------------------
bw_resume = *
        org BLWALL_BASE
.proc bl_wall
        ldx #3                       ; bl_x/bl_y are four contiguous bytes and so
?cp     lda bl_x,x                   ;   are coll_cx/coll_cy: one loop at 10 B
        sta coll_cx,x                ;   instead of eight loads and eight stores
        dex                          ;   -- which is what makes this fit the hole
        bpl ?cp
        lda #0                       ; a fireball's clearance, not the player's
        sta coll_seg.cs_hmin
        jsr coll_plr       
        ldx #PLAYER_H                ; ...back before anything else can read it
        stx coll_seg.cs_hmin
        lsr                          ; A is exactly 0 or 1 -> C = "blocked"
        rts
.endp
    .if * > BLWALL_END+1
        ert 'bl_wall outgrew BLWALL_BASE..END (memory_map.inc)'
    .endif
        org bw_resume
