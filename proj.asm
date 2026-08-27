;==============================================================
; proj.asm -- the player's VISIBLE missiles: MT_ROCKET and MT_PLASMA
;   (2026-08-04, "rakety ani nevidno").
;--------------------------------------------------------------
; WHO gets hit is still decided the tic the trigger is pulled (the port's
; crosshair reduction, enemy.asm: there is no moving hitbox to collide with).
; WHEN it gets hurt is not: since 2026-08-05 the ROCKET carries its victim and
; its damage roll with it and spends both at the impact (pj_aim -> pj_hit),
; which is p_mobj.c P_ExplodeMissile's moment. Before that the enemy died at
; the trigger pull and the rocket then flew to a corpse ("oneskorena smrt po
; zasahu raketou").
; Since 2026-08-09 the PLASMA carries its roll the same way ("zomrie skor ako
; ho plazma trafi"). The bolt is ONE instance and A_FirePlasma refires every
; 3 tics against a frame of ~7, so most shots find the slot taken -- those
; cannot each have a bolt, but their rolls do not land early either: they are
; ADDED to the roll the bolt in the air is already carrying and go off with
; it (en_plasma2). The same reduction the shotgun takes when its seven pellets
; share one puff. Nothing is lost: an aim that moves to another victim, or a
; sum that runs past 255, lands the bolt at once and arms a fresh one, so the
; damage per second is the weapon's whatever the frame rate does.
;
; From _pomocne/_doomsrc, verified:
;   info.c MT_ROCKET: MISL A in flight, S_EXPLODE1..3 = MISL B/C/D at 8/6/4
;     tics, seesound sfx_rlaunc, deathsound sfx_barexp, speed 20/tic.
;   info.c MT_PLASMA: PLSS A/B in flight, S_PLASEXP.. = PLSE A..E at 4 tics,
;     seesound sfx_plasma, deathsound sfx_firxpl, speed 25/tic, damage 5.
;   p_mobj.c P_SpawnPlayerMissile: spawns at the shooter, z + 32, momentum =
;     speed * (cos, sin), seesound at the LAUNCH.
;   p_map.c PIT_CheckThing:277 -- ((P_Random()%8)+1) * info->damage, and the
;     P_DamageMobj that spends it is on the MISSILE'S move, not on the trigger:
;     20..160 for the rocket, 5..40 for the bolt, both AT the impact.
; Reductions, same family as the imp's ball (ball.asm):
;   * ONE instance, rocket or plasma -- a new shot replaces the old sprite.
;   * one flight frame (no A/B flicker), three burst frames of PLSE's five.
;   * both fly at 2x the ball's k7 scale = 14 u/VB. The rocket's true PAL
;     rate is exactly 14; the plasma's would be 17.5 -- flattened to 14, the
;     x2.5 leg did not fit the free-RAM islands this engine lives in.
;   * the flight aims at the CENTRE of what it hit (or the wall point
;     en_march found): no z slope, it flies level at eye - 9.
; Thing index 254 is this missile's "not a thing" sentinel (the ball owns
; 255): health 0 so en_shoot skips it, state 0 so spr_dyn draws it live.
;==============================================================

;--------------------------------------------------------------
; The fire tails, out of the packed ENEMY block: en_rocket/en_plasma keep
; their damage roll and jmp here.
;--------------------------------------------------------------
        org PJSP_BASE

.proc en_plasma2
        pha                          ; the roll, while pj_pick eats A
        jsr pj_pick                  ; which bolt is this shot?
        beq ?busy
        pla                          ; A FREE SLOT: it gets its own, the way
?new    jsr pj_aim                   ;   P_SpawnPlayerMissile makes one mobj per
        jsr pj_pspawn                ;   A_FirePlasma -- victim and roll ride it
?sv     ldx pj_cur                   ;   and are spent in pj_hit when it lands
        jmp pj_save
?busy   inc pj_hold                  ; EVERY SLOT IS BUSY (the trigger refires
        pla                          ;   every 3 tics against a ~7 VBLANK frame,
        jsr en_shoot                 ;   so a burst outruns three bolts): find
        dec pj_hold                  ;   who this shot would hit, hurting nobody
        lda #$FF
        ldx en_best
        bmi ?cmp                     ; nothing under the crosshair -> a wall
        lda vs_th,x
?cmp    cmp pj_vic
        bne ?land                    ; somebody else: that bolt has to go now
        clc                          ; the SAME victim: this roll rides with the
        lda pj_dmg                   ;   bolt instead of landing early, which is
        adc en_dmg                   ;   what used to kill before the plasma
        bcs ?land                    ;   arrived -- the damage per second is the
        sta pj_dmg                   ;   weapon's either way
        jmp ?sv
?land   lda en_dmg                   ; the aim moved, or the sum ran past 255:
        pha                          ;   land that bolt on its own victim (pj_hit
        jsr pj_hit                   ;   eats en_dmg through en_bhit, hence the
        dec pj_on                    ;   stack) and give this shot the slot
        pla
        jmp ?new
.endp

;--------------------------------------------------------------
; pj_rspawn / pj_pspawn -- arm the shared missile for this shot's look.
;--------------------------------------------------------------
.proc pj_rspawn
        lda #SFX_BAREXP              ; MT_ROCKET deathsound (info.c:1981) -- and
        sta pj_bsnd                  ;   it is what tells pj_hit there IS an
                                     ;   A_Explode, so it goes in BEFORE the ?now
                                     ;   bail: a plasma bolt before this rocket
                                     ;   would otherwise leave FIRXPL standing
                                     ;   there and the blast would be skipped
        lda pj_rid
        bmi ?now                     ; $FF: the level packed no MISL, so there is
        sta pj_fid                   ;   no flight to wait for -- land it at once
                                     ;   rather than lose the shot entirely
        lda pj_rxid
        sta pj_xid
        lda #11                      ; S_EXPLODE1..3: 8/6/4 tics -> 11/9/6 VB
        sta pj_bt0
        lda #9
        sta pj_bt1
        lda #6
        sta pj_bt2
        jmp pj_go
?now    lda en_bx                    ; pj_go never ran, so hand pj_hit the impact
        sta pj_tx                    ;   point itself -- pj_tx/pj_ty is where it
        lda en_bx+1                  ;   looks for the blast, and it is the one
        sta pj_tx+1                  ;   copy a barrel going off mid-flight
        lda en_by                    ;   cannot move under it
        sta pj_ty
        lda en_by+1
        sta pj_ty+1
        jmp pj_hit
.endp

.proc pj_pspawn
        lda #SFX_FIRXPL              ; MT_PLASMA deathsound (info.c:2007), and
        sta pj_bsnd                  ;   the flag that keeps pj_hit's A_Explode
                                     ;   half off a bolt (info.c gives MT_PLASMA
                                     ;   none). Set before the ?now bail below.
                                     ; The slot itself is NOT tested here any
                                     ;   more: en_plasma2 only ever calls this
                                     ;   with the air clear -- a shot that finds
                                     ;   a bolt up there merges into it instead
                                     ;   of being dropped. One instance is still
                                     ;   the reduction the imp's ball takes
                                     ;   (ball.asm), re-arming per shot would
                                     ;   park the bolt at the muzzle forever.
        lda pj_pid
        bpl ?arm
        jmp pj_hit                   ; $FF: no PLSS packed, so there is no flight
                                     ;   to carry the roll -- spend it at once
                                     ;   rather than lose the shot entirely
?arm    sta pj_fid
        lda pj_pxid
        sta pj_xid
        lda #6                       ; S_PLASEXP: 4 tics -> 6 VB, all three
        sta pj_bt0
        sta pj_bt1
        sta pj_bt2
        jmp pj_go
.endp
    .if * > PJSP_END+1
        ert 'proj.asm spawn tails outgrew PJSP_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_go (part A) -- position, target, deltas, the ball's shrink loop.
;--------------------------------------------------------------
        org PJGO_BASE
.proc pj_go
        lda zp_px                    ; the missile leaves the player...
        sta pj_x
        lda zp_px+1
        sta pj_x+1
        lda zp_py
        sta pj_y
        lda zp_py+1
        sta pj_y+1
        sec                          ; ...at z + 32 over the feet: the eye is
        lda zp_pz                    ;   feet + 41, so eye - 9 (p_mobj.c:971)
        sbc #9
        sta pj_z
        lda zp_pz+1
        sbc #0
        sta pj_z+1
        lda #0
        sta pj_xf
        sta pj_yf
        lda en_bx                    ; the flight target: what the shot hit
        sta pj_tx
        lda en_bx+1
        sta pj_tx+1
        lda en_by
        sta pj_ty
        lda en_by+1
        sta pj_ty+1
        sec                          ; the aim vector, target - player
        lda pj_tx
        sbc pj_x
        sta pj_dx
        lda pj_tx+1
        sbc pj_x+1
        sta pj_dx+1
        sec
        lda pj_ty
        sbc pj_y
        sta pj_dy
        lda pj_ty+1
        sbc pj_y+1
        sta pj_dy+1
        lda #0                       ; count the shrinks: they ARE the distance's
        sta pj_sh                    ;   magnitude, and pj_go2 paces the flight
                                     ;   off it (pj_ctab)
?red    lda pj_dx                    ; shrink until BOTH fit [-127,127] --
        clc                          ;   ball_spawn's own loop, minus its z leg
        adc #127
        tax
        lda pj_dx+1
        adc #0
        bne ?shr
        cpx #$FF
        beq ?shr
        lda pj_dy
        clc
        adc #127
        tax
        lda pj_dy+1
        adc #0
        bne ?shr
        cpx #$FF
        beq ?shr
        jmp pj_go2                   ; part B: k7 aim + arm (its own island)
?shr    inc pj_sh
        lda pj_dx+1
        cmp #$80
        ror pj_dx+1
        ror pj_dx
        lda pj_dy+1
        cmp #$80
        ror pj_dy+1
        ror pj_dy
        jmp ?red
.endp

; m_prod = A * pj_f (umul16, high half 0)
.proc pj_mul
        sta m_a
        lda #0
        sta m_a+1
        sta m_b+1
        lda pj_f
        sta m_b
        jmp umul16
.endp

; m_prod = -m_prod (16-bit)
.proc pj_neg
        sec
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+1
        sta m_prod+1
        rts
.endp

; IN: A = |d| (byte), Y = the delta's high byte (its sign).
; OUT: m_prod = that axis' step, x2 k7 (Q8), re-signed.
;   The sign is STASHED before the multiply: pj_mul tail-jumps into umul16,
;   whose qsmul macro does `tay` four times, so Y is long gone by the time the
;   product is ready. Reading it back with `tya` tested whatever the quarter-
;   square tables left behind, so a NEGATIVE leg kept its positive step while
;   pj_sxe/pj_sye still said "negative" -- the two together make a 24-bit step
;   of $FF0DC0, i.e. -242 units per VBLANK instead of -13.75. The missile then
;   left the map on its first frame, was in no leaf the BSP walk visits, and
;   was never drawn again. Which shots broke depended on the FIRING DIRECTION
;   (only negative legs are affected) and on the operands -- exactly the "some
;   times you see the rocket, sometimes not, and I cannot tell you when".
.proc pj_leg
        sty pj_sgn
        jsr pj_mul
        asl m_prod
        rol m_prod+1
        lda pj_sgn
        bpl ?p
        jmp pj_neg
?p      rts
.endp

; A = |A| (the deltas fit a byte once pj_go's shrink loop is done)
.proc pj_abs
        bpl ?pos
        eor #$FF
        clc
        adc #1
?pos    rts
.endp

; |m_a(16)| with A = the high byte on entry; Z=1 iff the result is < 256.
.proc pj_a16
        sta m_a+1
        bpl ?p
        jsr m_neg
?p      lda m_a+1
        rts
.endp

;--------------------------------------------------------------
; pj_thit -- p_map.c PIT_CheckThing, the MF_MISSILE half, for the rocket where
;   it is RIGHT NOW. C=1 (and pj_vic = the thing) if it is inside something
;   shootable; C=0 to keep flying.
;
; WHY IT HAD TO EXIST. The rocket used to pick its victim at the trigger:
;   pj_aim ran the crosshair aim, and en_shoot only accepts a thing whose
;   screen columns overlap en_cl..en_ch -- SCREEN_HALF +-1, THREE columns
;   (enemy.asm). Miss the centre of an imp by a few pixels and it was not a
;   candidate at all, so the rocket flew to the wall behind and passed
;   straight through him. DOOM never aims a missile like that: P_SpawnPlayer-
;   Missile makes a real mobj of radius 11 and every P_TryMove of its flight
;   runs PIT_CheckThing against whatever it overlaps.
;   DOOM's test, verbatim: blockdist = thing->radius + tmthing->radius, hit iff
;   |dx| < blockdist AND |dy| < blockdist. Z is not tested here for the same
;   reason nothing else in this port tests it -- the missile flies level at
;   eye-9 and there are no floating things below Baron level in E1.
;   The shooter cannot be hit: the player is not in the thing table at all.
;--------------------------------------------------------------
PJ_ROCKR equ 11                      ; info.c MT_ROCKET radius
pjth_resume = *
        org PJTHIT_BASE              ; the PJGO block is full to the byte
; 2026-08-10: the sweep reads TH_HPL/HPH/STATE/RAD straight out of bank $01
;   with lda.l tab,x -- the tables are page arrays indexed by THING, so the
;   old form re-aimed [zp_ptr] at every page of every thing (four pointer
;   stores and 7-cycle reads where one 5-cycle read does). X is the cursor
;   now (the 65816 has long,X and no long,Y); the caller's sub-step count
;   parks in pj_ti and comes back on BOTH exits. en_th2 still builds the
;   record pointer, but only for the few candidates the health byte lets
;   through -- the sweep runs once per SUB-STEP, up to five a frame per
;   bolt, and the old form was most of a flying frame's budget.
.proc pj_thit
        stx pj_ti                    ; the caller's counter; X = the cursor
        ldx #$FF
?nx     inx
?lp     cpx THINGS_BASE              ; the level's thing count
        bcc ?try
        ldx pj_ti                    ; swept them all: nothing in the way
        clc
        rts
?try    lda.l $010000+TH_HPL,x       ; shootable at all? (a decoration has no
        bne ?alv                     ;   health, and PIT_CheckThing lets a
        lda.l $010000+TH_HPH,x       ;   non-shootable thing through). Two lda.l
        beq ?nx                      ;   and not an ora.l: lda long,X is the one
                                     ;   indexed long read the port's simulators
                                     ;   carry (tools/sim6502.py), and a live
                                     ;   thing skips the high byte entirely
?alv    lda.l $010000+TH_STATE,x     ; already dying -> its chain owns it
        bne ?nx
        lda.l $010000+TH_RAD,x       ; blockdist = its radius + the rocket's
        clc
        adc #PJ_ROCKR
        sta pj_bd
        bcs ?nx                      ; (a radius that wide cannot happen; if it
                                     ;  ever did, the byte compare below would
                                     ;  wrap and hit everything)
        txa
        jsr en_thing.en_th2          ; sp_ptr = its record: x at +0, y at +2
        ldy #0
        sec
        lda pj_x
        sbc (sp_ptr),y
        sta m_a
        iny
        lda pj_x+1
        sbc (sp_ptr),y
        jsr pj_a16                   ; |dx|
        bne ?nx                      ;   256 units or more: nowhere near
        lda m_a
        cmp pj_bd
        bcs ?nx
        ldy #2
        sec
        lda pj_y
        sbc (sp_ptr),y
        sta m_a
        iny
        lda pj_y+1
        sbc (sp_ptr),y
        jsr pj_a16                   ; |dy|
        bne ?nx
        lda m_a
        cmp pj_bd
        bcs ?nx
        stx pj_vic                   ; HIT: this is who the blast damages first,
        lda pj_x                     ;   and the burst happens HERE, not at the
        sta pj_tx                    ;   point the crosshair picked
        lda pj_x+1
        sta pj_tx+1
        lda pj_y
        sta pj_ty
        lda pj_y+1
        sta pj_ty+1
        ldx pj_ti                    ; the sub-step counter back
        sec
        rts
.endp
; pj_orup -- pj_any = OR of the eight pj_ons: pj_mirr's tail, so it is fresh
;   the moment any slot's mirror changes, and spr_chasec's one-load "is
;   ANYTHING flying" gate. The ldx pj_cur puts back the X every pj_save
;   caller holds (pj_save promises X preserved, and X is always pj_cur there).
.proc pj_orup
        ldx #PJ_NSLOT-1
        lda #0
?o      ora pj_ons,x
        dex
        bpl ?o
        sta pj_any
        ldx pj_cur
        rts
.endp
    .if * > PJTHIT_END+1
        ert 'pj_thit + pj_orup outgrew PJTHIT_BASE..END (memory_map.inc)'
    .endif
        org pjth_resume

;--------------------------------------------------------------
; pj_go2 -- k7 row, the x2 speed scale, sign, arm the flight.
;--------------------------------------------------------------
.proc pj_go2
        lda pj_dx
        jsr pj_abs
        sta pj_ax
        lda pj_dy
        jsr pj_abs
        cmp pj_ax                    ; max(|dx|,|dy|) -> the k7 row
        bcs ?ymax
        lda pj_ax
?ymax   cmp #8
        bcs ?mok                     ; clamp: k7-8,x never reads below the table
        lda #8
?mok    tax
        lda k7-8,x
        sta pj_f
        ldy pj_sh                    ; pace the FLIGHT, not just the speed: the
        lda pj_ctab,y                ;   shrink count is the distance's magnitude
        jsr pj_capdbl                ;   (the loop stops with the larger leg in
                                     ;   [64,127], so dist ~ 96 << sh), and
                                     ;   pj_ctab turns it into "sub-steps per
                                     ;   drawn frame". Without it the number of
                                     ;   frames the missile is EVER drawn in is
                                     ;   dist/70: two for a wall up close, ten
                                     ;   down a corridor -- the same shot looking
                                     ;   completely different for no reason the
                                     ;   player can see. The imp's ball never had
                                     ;   this: it flies TOWARDS the eye, so it
                                     ;   grows and is on screen the whole way,
                                     ;   while ours recedes and halves every
                                     ;   frame.
        lda pj_ax                    ; step X = |dx| * k7 * 2 (Q8), re-signed:
        ldy pj_dx+1                  ;   k7 normalises the larger leg to 7 u/VB
        jsr pj_leg                   ;   and the doubling makes it 14 -- the
        lda m_prod                   ;   rocket's exact PAL rate (20/tic * 0.7)
        sta pj_sx
        lda m_prod+1
        sta pj_sx+1
        ldx #0
        lda pj_dx+1
        bpl ?px
        dex
?px     stx pj_sxe
        lda pj_dy                    ; step Y likewise
        jsr pj_abs
        ldy pj_dy+1
        jsr pj_leg
        lda m_prod
        sta pj_sy
        lda m_prod+1
        sta pj_sy+1
        ldx #0
        lda pj_dy+1
        bpl ?py
        dex
?py     stx pj_sye
        lda #250                     ; ~5 s guard; arrival ends it long before
        sta pj_ttl
        lda pj_fid
        sta pj_frm                   ; the CONTEXT's frame, not pj_rec+6: that
                                     ;  record is shared scratch and pj_draw1
                                     ;  rebuilds it from here on every draw
                                     ; (pj_rec+7, the flags byte, is 0 from the
                                     ;  dta and nothing ever writes it -- the
                                     ;  block has
                                     ;  no room to re-zero what cannot change)
        lda #1
        sta pj_on
        jmp pj_zaim                  ; the z leg (its own island), and it ends
.endp                                ;   `jmp pj_leaf` -- seeding pj_ss + the
                                     ;   record NOW, because the draw hook runs
                                     ;   before the first pj_frame. Hooking the
                                     ;   TAIL is what kept this block, which has
                                     ;   three bytes left, at three bytes left.
    .if * > PJGO_END+1
        ert 'pj_go + helpers outgrew PJGO_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_frameb -- the frame loop's mv_frameb call, retargeted once more
;   (movers, the imp's ball, then this missile) -- and the once-per-level
;   id fetch, both out of the packed flight island.
;--------------------------------------------------------------
        org PJLV_BASE
.proc pj_frameb
        jsr mv_frameb
        jmp pj_frameN
.endp
.proc pj_relvl
        sta pj_lvl                   ; new level: forget every bolt (pj_clr at
        lda #0                       ;   the tail), learn the sprite ids, park
                                     ;   sentinel 254 as "not a thing" (255 is
                                     ;   the ball's)
        sta.l $010000+TH_HPL+TH_NOTHING
        sta.l $010000+TH_HPL+$100+TH_NOTHING
        sta.l $010000+TH_STATE+TH_NOTHING
        sta.l $010000+TH_KIND+TH_NOTHING    ; en_kfill stops at the thing count, so
                                     ;   254 is uninitialised SRAM on the metal
                                     ;   (the sim zeroes it) -- nonzero sends
                                     ;   wrot_idle down the monster path and
                                     ;   the draw reads a garbage DTAB row
        lda THINGS_BASE+20           ; pack_things header: MISL A id...
        sta pj_rid
        lda THINGS_BASE+21           ; ...MISL B (burst first of B/C/D)
        sta pj_rxid
        lda THINGS_BASE+22           ; ...PLSS A
        sta pj_pid
        lda THINGS_BASE+23           ; ...PLSE A (burst first of A/B/C)
        sta pj_pxid
        jmp pj_clr
.endp

;--------------------------------------------------------------
; pj_capdbl -- pj_go2's tail on pj_cap (A = pj_ctab's entry for this shot's
;   distance): the PLASMA gets twice the sub-steps per drawn frame. info.c
;   gives MT_PLASMA speed 25 against MT_ROCKET's 20 and it refires every 3 tics
;   where the rocket takes twenty-odd, so pacing the two the same was wrong
;   twice over: a point-blank bolt filled SEVEN drawn frames, which since
;   2026-08-09 is also how long its victim waits for the damage (the roll rides
;   the bolt now), and how long the ONE instance is busy -- i.e. how few of a
;   held trigger's shots ever get a sprite at all ("vidno len 1-2 strely").
;   Four frames now, measured by tools/tests/_verify_plasma.py.
;   Doubled it is still SLOWER than DOOM: a sub-step is the rocket's exact 14
;   units/VBLANK where the bolt's own rate is 17.5, and pj_frame never takes
;   more than fps_n of them in one frame however big the cap is.
;   It is in a hole of its own because every projectile block is full: PJGO has
;   two bytes left, PJHK ten, and the tails that LOOK spare belong to somebody
;   else -- $5BC5 is PFVAR_BASE and $8C9D is THRC_BASE, neither of which the
;   ert guards can see (check_xex.py is what says so).
;--------------------------------------------------------------
pjcap_resume = *
        org PJCAP_BASE
.proc pj_capdbl
        ldx pj_bsnd                  ; the deathsound is what says "rocket"
        cpx #SFX_BAREXP              ;   (MT_PLASMA has no A_Explode -- pj_hit)
        beq ?put
        asl
?put    sta pj_cap
        rts
.endp
    .if * > PJCAP_END+1
        ert 'pj_capdbl outgrew PJCAP_BASE..END (memory_map.inc)'
    .endif
        org pjcap_resume
    .if * > PJLV_END+1
        ert 'pj_frameb/pj_relvl outgrew PJLV_BASE..END (memory_map.inc)'
    .endif

        org PJFR_BASE
PJ_MAXSUB equ 24                     ; sub-steps (VBLANKs) per drawn frame, max.
                                     ;   A RUNAWAY GUARD now, not a pace: it
                                     ;   sits above any real fps_n, so
                                     ;   min(fps_n, pj_cap) is always fps_n and
                                     ;   the missile flies at its true 14
                                     ;   units/VBLANK. See pj_ctab.
.proc pj_frame                       ; ONE bolt, the one pj_load just swapped in
        lda pj_on                    ;   (the level check moved to pj_frameN --
        bne ?run                     ;   pj_relvl has to run with no bolt up too)
?out    rts
?run    cmp #2
        bcc ?fly0                    ; 2..4 = the burst frames (their own clock)
        jmp pj_btick
?fly0   ldx fps_n                    ; one sub-step per VBLANK, like the ball...
        cpx pj_cap                   ; ...but never more than pj_cap of them in
        bcc ?step                    ;   one DRAWN frame (pj_go2 sets it from the
                                     ;   distance, so a short shot is not over in
                                     ;   two frames and a long one still moves).
                                     ; The missile is only ever seen where a
                                     ; frame lands, and a frame here is ~10
                                     ; VBLANKs: at DOOM's true 14 u/VBLANK the
                                     ; drawn positions are 140 units apart, so
                                     ; a wall up close got two of them and a
                                     ; corridor ten. pj_cap evens that out.
                                     ; Where fps is high enough the cap never
                                     ; bites and the speed is DOOM's exact
                                     ; 20 units/tic. The damage DOES depend on
                                     ; this now -- both missiles spend their
                                     ; roll in pj_hit below, so pj_cap is also
                                     ; how long the victim has before it lands.
        ldx pj_cap
?step   clc
        lda pj_xf
        adc pj_sx
        sta pj_xf
        lda pj_x
        adc pj_sx+1
        sta pj_x
        lda pj_x+1
        adc pj_sxe
        sta pj_x+1
        clc
        lda pj_yf
        adc pj_sy
        sta pj_yf
        lda pj_y
        adc pj_sy+1
        sta pj_y
        lda pj_y+1
        adc pj_sye
        sta pj_y+1
        jsr pj_zstep                 ; ...and the z leg: p_mobj.c gives the
                                     ;   missile a momz, so it CLIMBS to a
                                     ;   monster on a ledge instead of flying
                                     ;   level under it
        dec pj_ttl
        beq ?gone
        sec                          ; arrived? |x - tx| < 16 AND |y - ty| < 16
        lda pj_x                     ;   (the step is 14, the window 32 wide --
        sbc pj_tx                    ;   no sample can jump across it)
        sta m_a
        lda pj_x+1
        sbc pj_tx+1
        jsr pj_a16
        bne ?miss
        lda m_a
        cmp #16
        bcs ?miss
        sec
        lda pj_y
        sbc pj_ty
        sta m_a
        lda pj_y+1
        sbc pj_ty+1
        jsr pj_a16
        bne ?miss
        lda m_a
        cmp #16
        bcc ?burst
?miss   jsr pj_thit                  ; p_map.c PIT_CheckThing: did this sub-step
        bcs ?burst                   ;   put the rocket INSIDE something? then it
                                     ;   bursts HERE (pj_thit moved pj_tx/pj_ty)
        dex
        beq ?done
        jmp ?step
?done   jmp pj_leaf                  ; track the leaf + refresh the record
?gone                                ; guard ran out mid-air: burst where it is,
                                     ;   so the shot still LANDS (it used to
                                     ;   vanish quietly, which cost nothing when
                                     ;   the damage went off at the trigger)
?burst  jsr pj_hit                   ; P_ExplodeMissile: NOW it hurts
        jmp pj_burst
.endp
    .if * > PJFR_END+1
        ert 'pj_frame outgrew PJFR_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_burst / pj_btick -- the impact: park, play the deathsound, walk the
;   burst frames on their own clocks (pj_bt0/1/2, VBLANKS).
;   The clock runs DOWN BY fps_n, not by one: pj_frame is called once a frame
;   and a frame is 4-6 VBLANKs here, so a `dec` made the 26-VBLANK burst last
;   26 FRAMES -- over two seconds of fireball standing in the air where DOOM
;   flashes it for half of one (2026-08-04: "splash ukazuje velmi dlho").
;   The flight loop never had the bug; it always stepped fps_n times.
;   The block is full to the byte, so both tails share pj_gone.
;--------------------------------------------------------------
        org PJF2_BASE
.proc pj_burst
        lda pj_bsnd
        sta snd_pending              ; barexp / firxpl AT the impact
        lda pj_xid
        bmi pj_gone                  ; no burst frames packed: just vanish
        sta pj_frm                   ; S_EXPLODE1 (info.c: MISL B, A_Explode)
        lda #2
        sta pj_on
        lda pj_bt0
        sta pj_ttl
        jmp pj_leaf                  ; the record parks WHERE it burst
.endp
.proc pj_gone                        ; the missile is done (both tails)
        lda #0
        sta pj_on
        rts
.endp
.proc pj_btick
        sec                          ; this frame ate fps_n VBLANKs of the frame
        lda pj_ttl                   ;   clock -- C=0 (it ran past) or Z=1 (it
        sbc fps_n                    ;   ran out exactly) both mean: next frame
        sta pj_ttl
        bcc ?adv
        bne ?out
?adv    inc pj_on
        lda pj_on
        cmp #5
        bcs pj_gone                  ; the third frame ran out: gone
        inc pj_frm                   ; next burst frame (consecutive ids)
        cmp #4
        beq ?b2
        lda pj_bt1
        bne ?set                     ; always (bt1 is 9 or 6, never 0)
?b2     lda pj_bt2
?set    sta pj_ttl
?out    rts
.endp
    .if * > PJF2_END+1
        ert 'pj_burst/pj_btick outgrew PJF2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_leaf -- which leaf is the missile in (spr_chasec projects it from
;   there), plus the pseudo-record refresh. locate_floor reads zp_px/py,
;   so borrow them, ball-style.
;--------------------------------------------------------------
        org PJF3_BASE
.proc pj_leaf
        lda zp_px
        pha
        lda zp_px+1
        pha
        lda zp_py
        pha
        lda zp_py+1
        pha
        lda pj_x
        sta zp_px
        lda pj_x+1
        sta zp_px+1
        lda pj_y
        sta zp_py
        lda pj_y+1
        sta zp_py+1
        jsr locate_floor             ; zp_nid = the leaf
        lda zp_nid
        sta pj_ss
        lda zp_nid+1
        and #$7F
        sta pj_ss+1
        pla
        sta zp_py+1
        pla
        sta zp_py
        pla
        sta zp_px+1
        pla
        sta zp_px
        ; fall through into the record refresh
.endp
.proc pj_rec_up
        lda pj_x
        sta pj_rec
        lda pj_x+1
        sta pj_rec+1
        lda pj_y
        sta pj_rec+2
        lda pj_y+1
        sta pj_rec+3
        sec                          ; anchor = flight z - 8, like the ball
        lda pj_z
        sbc #8
        sta pj_rec+4
        lda pj_z+1
        sbc #0
        sta pj_rec+5
        rts
.endp
    .if * > PJF3_END+1
        ert 'pj_leaf outgrew PJF3_BASE..END (memory_map.inc)'
    .endif


;--------------------------------------------------------------
; pj_zaim / pj_zaim2 / pj_zstep -- THE VERTICAL AIM (2026-08-19, "ked vystrelim
;   raketu alebo plazmu na enemies, ktory je vyssie, naboj leti tam.. ale u nas
;   to tak nie je"). From _pomocne/_doomsrc, p_mobj.c:934 P_SpawnPlayerMissile:
;       slope = P_AimLineAttack (source, an, 16*64*FRACUNIT);
;       ...
;       th->momz = FixedMul (th->info->speed, slope);
;   and P_AimLineAttack (p_map.c:1022) hands back PTR_AimTraverse's aimslope,
;   which is (thingtopslope + thingbottomslope)/2 -- the MIDDLE of the target's
;   vertical span. Finding nothing leaves slope 0, i.e. a level shot, and that
;   is what EVERY missile in this port did until now: pj_go set pj_z once and
;   nothing moved it again ("no z slope, it flies level at eye - 9").
;
;   Same shape as the imp's ball (ball.asm bl_dz/bl_sz/bl_sze): one Q8 step per
;   sub-step, on the SAME k7 scale pj_go2 gave the x and y legs, so all three
;   arrive together whatever the distance.
;   Two reductions, both deliberate:
;     * the aim point is the victim's z + 28 -- the middle of a 56-unit
;       monster, which is every Doom 1 kind but the baron (64). DOOM's aimslope
;       is that same midpoint; it just derives it from two slopes per frame.
;     * no topslope/bottomslope clamp (DOOM's +-100/160, about 32 deg). There
;       is no free look here and en_shoot already picked the victim by SCREEN
;       COLUMN, so a shot can only ever be as steep as the map makes it.
;   Hooked on pj_go2's TAIL and pj_frame's step, which is what kept both of
;   those blocks (3 and 11 bytes left) from having to move: pj_go2 ended
;   `jmp pj_leaf` and now ends `jmp pj_zaim`, which ends `jmp pj_leaf` itself.
;--------------------------------------------------------------
        org PJZ_BASE
.proc pj_zaim
        lda #0
        sta pj_zf
        sta pj_dz                    ; a WALL shot keeps DOOM's slope 0: dz 0
        sta pj_dz+1                  ;   falls through the same maths and comes
        lda pj_vic                   ;   out as a level flight
        bmi ?done                    ; $FF = a wall: dz stays 0, and the shared
        jsr en_thing.en_th2          ;   tail below is the only way out of here
                                     ;   anyway (the other island is 2 KB off,
                                     ;   so leaving is a jmp, not a branch --
                                     ;   sharing the one jmp is what made this
                                     ;   fit the 76 B hole).
                                     ; sp_ptr -> the victim's record
        sec                          ; the muzzle, less half a monster, so the
        lda pj_z                     ;   aim point comes out of ONE subtract
        sbc #28                      ;   instead of an add and then a subtract
        sta m_a
        lda pj_z+1
        sbc #0
        sta m_a+1
        ldy #4                       ; +4/+5 = its z (pack_things: x,y,z,sid,fl)
        sec
        lda (sp_ptr),y
        sbc m_a
        sta pj_dz
        iny
        lda (sp_ptr),y
        sbc m_a+1
        sta pj_dz+1
        ldy pj_sh                    ; ...brought down the same number of
        beq ?done                    ;   halvings pj_go's loop cost dx/dy, so
?sh     lda pj_dz+1                  ;   all three legs share one scale
        cmp #$80                     ;   (arithmetic: the sign has to survive)
        ror pj_dz+1
        ror pj_dz
        dey
        bne ?sh
?done   jmp pj_zaim2                 ; the other island, 2 KB off: a jmp, not a
.endp                                ;   branch
    .if * > PJZ_END+1
        ert 'pj_zaim outgrew PJZ_BASE..END (memory_map.inc)'
    .endif

        org PJZ2_BASE
.proc pj_zaim2                       ; dz (shrunk) -> the per-sub-step z leg
        ldx #0                       ; the sign FIRST: pj_leg tail-jumps into
        lda pj_dz+1                  ;   umul16, whose qsmul eats X and Y
        bpl ?p
        dex
?p      stx pj_sze
        lda pj_dz
        jsr pj_abs
        ldy pj_dz+1
        jsr pj_leg                   ; m_prod = |dz| * k7 * 2, re-signed
        lda m_prod
        sta pj_sz
        lda m_prod+1
        sta pj_sz+1
        jmp pj_leaf
.endp
.proc pj_zstep                       ; ONE sub-step of the z leg (pj_frame)
        clc
        lda pj_zf
        adc pj_sz
        sta pj_zf
        lda pj_z
        adc pj_sz+1
        sta pj_z
        lda pj_z+1
        adc pj_sze
        sta pj_z+1
        rts
.endp
pj_dz   dta a(0)                     ; SHARED, not per-bolt: it is only alive
                                     ;   inside pj_zaim, at the launch
    .if * > PJZ2_END+1
        ert 'pj_zaim2/pj_zstep outgrew PJZ2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; THE SLOT MACHINERY (2026-08-09). Nothing below the context swap knows there
;   is more than one bolt: pj_load puts a slot into the pj_* variables, the
;   shipped flight code ticks it exactly as it did when there was one, and
;   pj_save puts it back. The copies are 31 bytes each and happen once per
;   bolt per frame -- against a flight loop that runs up to five sub-steps and
;   a PIT_CheckThing sweep per bolt, they are noise.
;--------------------------------------------------------------
        org PJSLT_BASE
.proc pj_slot                        ; X = slot -> zp_ptr = its bank $01 block
        txa                          ;   (zp_ptr+2 is parked on MAP_EXT_BANK for
        asl                          ;    the whole game, like every other
        asl                          ;    [zp_ptr],y reader here)
        asl
        asl
        asl
        asl                          ; x64 = PJ_SLSTR. The stride outgrew a page
        sta zp_ptr                   ;   when the z leg joined the context, so
        lda #>PJSLOT_EXT             ;   slots 4-7 live on the SECOND page and
        adc #0                       ;   the sixth shift's carry is exactly that
        sta zp_ptr+1                 ;   bit (7*64 = $1C0, so it never needs two)
        rts
.endp
    .if * > PJSLT_END+1
        ert 'pj_slot outgrew PJSLT_BASE..END (memory_map.inc)'
    .endif

        org PJLD_BASE
.proc pj_load                        ; X = slot -> the context. Preserves X.
        jsr pj_slot
        ldy #PJ_CTXN-1
?c      lda [zp_ptr],y
        sta pj_ctx,y
        dey
        bpl ?c
        rts
.endp
    .if * > PJLD_END+1
        ert 'pj_load outgrew PJLD_BASE..END (memory_map.inc)'
    .endif

        org PJSV_BASE
.proc pj_save                        ; X = slot <- the context. Preserves X.
        jsr pj_slot
        ldy #PJ_CTXN-1
?c      lda pj_ctx,y
        sta [zp_ptr],y
        dey
        bpl ?c
        jmp pj_mirr
.endp
    .if * > PJSV_END+1
        ert 'pj_save outgrew PJSV_BASE..END (memory_map.inc)'
    .endif

        org PJMR_BASE
.proc pj_mirr                        ; X = slot: what spr_chasec reads per
        lda pj_on                    ;   SUBSECTOR, kept in fast base RAM so the
        sta pj_ons,x                 ;   walk never unpacks a slot to find out
        lda pj_ss                    ;   the bolt is somewhere else
        sta pj_ssl,x
        lda pj_ss+1
        sta pj_ssh,x
        jmp pj_orup                  ; ...and refresh pj_any (X comes back as
.endp                                ;   pj_cur, which is what X holds here)
    .if * > PJMR_END+1
        ert 'pj_mirr outgrew PJMR_BASE..END (memory_map.inc)'
    .endif

        org PJFN_BASE
.proc pj_frameN                      ; the frame hook: every bolt, in turn
        lda current_level            ; the level check is HERE and not in
        cmp pj_lvl                   ;   pj_frame any more: pj_relvl has to run
        beq ?go                      ;   even when no slot is live, and it now
        jsr pj_relvl                 ;   forgets every slot, not just one
?go     jmp pj_frameN2
.endp
    .if * > PJFN_END+1
        ert 'pj_frameN outgrew PJFN_BASE..END (memory_map.inc)'
    .endif

        org PJFN2_BASE
.proc pj_frameN2
        ldx #0
?lp     stx pj_cur
        lda pj_ons,x                 ; idle: not worth 62 bytes of copying
        beq ?nx
        jsr pj_load
        jsr pj_frame
        ldx pj_cur
        jsr pj_save
?nx     inx                          ; (pj_save left X = pj_cur; the skip path
        cpx #PJ_NSLOT                ;  never touched it)
        bne ?lp
        rts
.endp
    .if * > PJFN2_END+1
        ert 'pj_frameN2 outgrew PJFN2_BASE..END (memory_map.inc)'
    .endif

        org PJDR_BASE
.proc pj_draw1                       ; X = slot, and its leaf is the one the walk
        stx pj_cur                   ;   is in: unpack it and project it
        jsr pj_load
        jsr pj_rec_up                ; pj_rec = x, y, z-8 out of the context
        lda pj_frm                   ; the frame THIS bolt is on -- it used to
        sta pj_rec+6                 ;   reload pj_fid here, which is the FLIGHT
                                     ;   frame, so the three burst frames
                                     ;   pj_burst/pj_btick had just put in
                                     ;   pj_rec+6 were overwritten before
                                     ;   anything drew them: a rocket that hit a
                                     ;   wall simply parked there AS A ROCKET and
                                     ;   no explosion was ever seen (2026-08-19,
                                     ;   raketa.png)
        lda #TH_NOTHING              ; vs_th: the missile's "not a thing"
        sta sp_i
        lda #<pj_rec
        sta sp_ptr
        lda #>pj_rec
        sta sp_ptr+1
        jmp spr_proj
.endp
    .if * > PJDR_END+1
        ert 'pj_draw1 outgrew PJDR_BASE..END (memory_map.inc)'
    .endif

        org PJPK_BASE
.proc pj_pick                        ; the slot a NEW shot gets, context loaded.
        ldx #PJ_NSLOT-1              ;   Z=1 = it is somebody's LIVE bolt (every
?lp     lda pj_ons,x                 ;   slot was busy), so the caller has to
        cmp #1                       ;   merge into it or land it first.
        bne ?take                    ; idle or already bursting: reuse it
        dex
        bne ?lp                      ; slot 0 is the fallback
?take   stx pj_cur
        jsr pj_load
        lda pj_on
        cmp #1
        rts
.endp
    .if * > PJPK_END+1
        ert 'pj_pick outgrew PJPK_BASE..END (memory_map.inc)'
    .endif

        org PJRK_BASE
.proc en_rocket2
        pha                          ; the roll, while pj_pick eats A
        jsr pj_pick
        bne ?arm
        jsr pj_hit                   ; every slot busy: the missile in this one
        dec pj_on                    ;   lands NOW, on ITS victim and with ITS
?arm    pla                          ;   roll -- pj_aim is about to overwrite
        jsr pj_aim                   ;   both (it used to land after, so the new
        jsr pj_rspawn                ;   rocket's damage went off early on the
        ldx pj_cur                   ;   new target)
        jmp pj_save
.endp
    .if * > PJRK_END+1
        ert 'en_rocket2 outgrew PJRK_BASE..END (memory_map.inc)'
    .endif

        org PJCLR_BASE
.proc pj_clr                         ; a new level: forget every bolt
        lda #0
        sta pj_on
        sta pj_any                   ; ...and the walk's gate with them
        ldx #PJ_NSLOT-1
?z      sta pj_ons,x
        dex
        bpl ?z
        rts
.endp
    .if * > PJCLR_END+1
        ert 'pj_clr outgrew PJCLR_BASE..END (memory_map.inc)'
    .endif

        org PJMIR_BASE
pj_ons  dta 0,0,0,0,0,0,0,0          ; per slot: pj_on, and the leaf it is in --
pj_ssl  dta 0,0,0,0,0,0,0,0          ;   the only projectile state the render
pj_ssh  dta 0,0,0,0,0,0,0,0          ;   walk ever reads (PJ_NSLOT of each)
    .if * > PJMIR_END+1
        ert 'the pj draw mirrors outgrew PJMIR_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; spr_chasec -- spr_add's chase hook, retargeted a second time (sprites.asm
;   calls it instead of spr_chaseb): the ball's chain first, then every bolt
;   whose leaf is the one the walk is in.
;--------------------------------------------------------------
        org PJHK_BASE
.proc spr_chasec
        jsr spr_chaseb
        lda pj_any                   ; nothing flying anywhere (the usual
        beq ?out                     ;   frame): one load instead of an 8-slot
        ldx #PJ_NSLOT-1              ;   scan on EVERY subsector of the walk
?lp     lda pj_ons,x
        beq ?nx
        lda zp_nid
        cmp pj_ssl,x
        bne ?nx
        lda zp_nid+1
        and #$7F
        cmp pj_ssh,x
        bne ?nx
        lda sp_n
        cmp #VIS_MAX
        bcs ?nx
        jsr pj_draw1
        ldx pj_cur                   ; (pj_draw1 goes through spr_proj)
?nx     dex
        bpl ?lp
?out    rts
.endp

;--------------------------------------------------------------
; THE PER-BOLT CONTEXT (2026-08-09). One shot's whole flight, 31 bytes, and
;   the ONLY thing pj_load/pj_save move between here and the PJ_NSLOT slots
;   that live in Rapidus bank $01 (PJSLOT_EXT). Every proc below still reads
;   plain absolute pj_x/pj_on/... -- the slot is swapped IN around the tick
;   instead of the flight code being taught to index. KEEP IT CONTIGUOUS and
;   keep PJ_CTXN in step; the copy loop is the only thing that cares about the
;   order, but nothing else may be parked in the middle of it.
;--------------------------------------------------------------
pj_ctx
pj_on   dta 0                        ; 0 idle, 1 flying, 2/3/4 burst frames
pj_fid  dta 0                        ; this shot's flight frame
pj_xid  dta 0                        ; ...and its burst first frame
pj_bsnd dta 0                        ; ...and its deathsound
pj_bt0  dta 0                        ; burst frame clocks, VB
pj_bt1  dta 0
pj_bt2  dta 0
pj_x    dta a(0)                     ; position (whole units) + Q8 fraction
pj_xf   dta 0
pj_y    dta a(0)
pj_yf   dta 0
pj_z    dta a(0)                     ; flight height: eye - 9 at the launch, and
                                     ;   pj_zstep walks it from there (it was a
                                     ;   constant until the z leg landed)
pj_zf   dta 0                        ; ...its Q8 fraction, like pj_xf/pj_yf
pj_sz   dta a(0)                     ; the z step, Q8 + sign extension: DOOM's
pj_sze  dta 0                        ;   th->momz (p_mobj.c:983)
pj_tx   dta a(0)                     ; the impact point it flies to
pj_ty   dta a(0)
pj_sx   dta a(0)                     ; step per VBLANK, Q8 + sign extension
pj_sxe  dta 0
pj_sy   dta a(0)
pj_sye  dta 0
pj_ttl  dta 0                        ; flight guard / burst frame countdown
pj_ss   dta a(0)                     ; the leaf the missile is in
pj_cap  dta 1                        ; sub-steps per drawn frame for this shot
pj_vic  dta $FF                      ; the thing this shot will hurt when it
pj_dmg  dta 0                        ;   lands ($FF = none, it flies at a wall)
pj_frm  dta 0                        ; the frame it is SHOWING right now: pj_fid
                                     ;   while it flies, then the three burst ids
                                     ;   in turn. Per-bolt, because pj_rec is
                                     ;   shared scratch that every pj_draw1
                                     ;   rebuilds from scratch
PJ_CTXN equ *-pj_ctx                 ; 36: was 31, +4 for the z leg and +1 for
                                     ;   pj_frm -- which is why PJ_SLSTR had to
                                     ;   go 32 -> 64 (_verify_pjz checks both)
;--------------------------------------------------------------
; ...and the SHARED half: scratch and level state, one copy for all bolts.
;--------------------------------------------------------------
pj_cur  dta 0                        ; the slot the context above belongs to
pj_any  dta 0                        ; OR of the eight pj_ons (pj_orup): 0 = no
                                     ;   bolt anywhere, the render walk's first
                                     ;   and usually only question
pj_ti   dta 0                        ; pj_thit: the caller's X, parked (the
                                     ;   sweep cursor is X itself now)
pj_bd   dta 0                        ; ...and this candidate's blockdist
pj_hold dta 0                        ; 1 = en_shoot picks the victim and stops
                                     ;   there, hurting nobody (enemy.asm)
pj_lvl  dta $FF                      ; the level the ids below belong to
pj_rid  dta $FF                      ; MISL A sprtab id (things header +20)
pj_rxid dta $FF                      ; MISL B, burst first of B/C/D (+21)
pj_pid  dta $FF                      ; PLSS A (+22)
pj_pxid dta $FF                      ; PLSE A, burst first of A/B/C (+23)
pj_dx   dta a(0)                     ; spawn scratch: the aim vector
pj_dy   dta a(0)
pj_ax   dta 0                        ; |dx8|
pj_f    dta 0                        ; k7 factor
pj_sgn  dta 0                        ; a leg's sign, held across umul16
pj_sh   dta 0                        ; shrinks the aim vector needed = log2(dist)
; shrinks -> sub-steps per drawn frame. dist ~ 96 << sh, and a sub-step is 14
; units, so this keeps every shot at roughly 7-11 DRAWN frames whatever the
; range: 1 (dist < 128, ~7 frames), 2 (~192, 7), 4 (~384, 7), then the ceiling.
; PJ_MAXSUB is the ceiling -- past it the missile would jump so far between
; frames that it is never seen twice at the same size.
; pj_ctab -- sub-steps per drawn frame, indexed by pj_sh (the shrink count, so
;   the distance's magnitude: the loop stops with the larger leg in [64,127],
;   i.e. dist ~ 96 << sh).
;   IT USED TO PACE THE SHOT: 1,2,4 for the first three rows, so a missile
;   fired at something close crawled 14 units per DRAWN FRAME instead of per
;   VBLANK -- seven times slower than DOOM at point-blank range and 30-70 %
;   everywhere else ("raketa leti moc pomaly", 2026-08-19). The intent was to
;   stop a short shot being over in two frames, but info.c is unambiguous:
;   MT_ROCKET is 20*FRACUNIT a tic, which IS 14 units per PAL VBLANK, and in
;   DOOM a rocket really does cross a small room in two frames.
;   Flat now, so min(fps_n, pj_cap) is always fps_n. The row stays a table
;   rather than becoming one constant because pj_go2 already indexes it and
;   pj_capdbl already doubles it for the plasma -- there is no room in either
;   block to delete the machinery, and none of it costs a cycle in flight.
pj_ctab dta PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB
        dta PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB
pj_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0
    .if * > PJHK_END+1
        ert 'spr_chasec + pj vars outgrew PJHK_BASE..END (memory_map.inc)'
    .endif

pjhk_resume = *
;--------------------------------------------------------------
; pj_aim -- A_FireMissile's fire half (A = the damage roll). Runs the crosshair
;   aim to learn WHO the rocket is going to hit and WHERE that is, and stops
;   there: pj_hold makes en_shoot return the moment it has the victim, so
;   nothing takes damage and nothing dies yet. The flight target is the
;   victim's centre, or -- with nothing under the crosshair -- the wall point
;   sh_trace finds, exactly as before.
;--------------------------------------------------------------
        org PJAIM_BASE
.proc pj_aim
        inc pj_hold
        jsr en_shoot
        dec pj_hold
        lda en_dmg                   ; the roll travels with the rocket: DOOM
        sta pj_dmg                   ;   rolls at the impact, this rolls at the
        ldx en_best                  ;   launch, and nothing can observe the
        bmi ?wall                    ;   difference
        lda vs_th,x
        sta pj_vic
        jsr en_thing.en_th2          ; sp_ptr = its record -> the flight target
        ldy #0
        lda (sp_ptr),y
        sta en_bx
        iny
        lda (sp_ptr),y
        sta en_bx+1
        iny
        lda (sp_ptr),y
        sta en_by
        iny
        lda (sp_ptr),y
        sta en_by+1
        rts
?wall   lda #$FF
        sta pj_vic                   ; nobody to hurt -- just the blast, and
        lda #SH_NROCK                ;   pj_hit centres it where the rocket
        jmp sh_trace                 ;   stopped
.endp
    .if * > PJAIM_END+1
        ert 'pj_aim outgrew PJAIM_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; pj_hit -- p_mobj.c P_ExplodeMissile, at the moment the rocket ARRIVES: the
;   direct damage on the thing pj_aim picked, then A_Explode at the impact
;   point. Called from pj_frame (arrival, or the flight guard running out) and
;   from en_rocket2/en_plasma2 when a second shot takes the slot off one still
;   in the air -- always BEFORE pj_aim overwrites pj_vic/pj_dmg.
;   The victim may have died on the way -- a barrel chain, infighting, the
;   player's own gunfire -- so the health test is not optional: en_bhit on a
;   corpse would hand it a second death chain (a second cry, the animation
;   restarted). Health 0 IS "dying or dead": en_kill only ever runs at 0.
;   The blast centres on pj_tx/pj_ty, the point the flight aimed at, and it
;   skips nobody -- PIT_RadiusAttack does not spare the thing the rocket hit
;   (it only skips what is already dying, en_bthings). No pain grunt: the
;   barexp is on the same one digi channel and would drown it anyway.
;--------------------------------------------------------------
        org PJHIT_BASE
.proc pj_hit
        lda pj_vic
        bmi ?blast                   ; it was flying at a wall
        sta en_bi
        tay
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
        beq ?blast                   ; already dead: no second death chain
        lda pj_dmg
        jsr en_bhit                  ; P_DamageMobj + the voice + the chain
?blast  lda pj_bsnd                  ; MT_PLASMA has no A_Explode (info.c), so
        cmp #SFX_BAREXP              ;   the deathsound is what says "rocket":
        bne ?out                     ;   a bolt is done once its victim is hurt
        lda pj_tx
        sta en_bx
        lda pj_tx+1
        sta en_bx+1
        lda pj_ty
        sta en_by
        lda pj_ty+1
        sta en_by+1
        lda #$FF
        sta pj_vic                   ; spent: a re-arm must not land it twice
        jmp en_boomat                ; A_Explode(..., 128) where it went off
?out    rts
.endp
    .if * > PJHIT_END+1
        ert 'pj_hit outgrew PJHIT_BASE..END (memory_map.inc)'
    .endif
        org pjhk_resume

;==============================================================
; PUFF (2026-08-05) -- P_SpawnPuff, "ked strelim do steny, nic nevidno".
;   _pomocne/_doomsrc is the authority:
;     * p_map.c PTR_ShootTraverse:968 -- a hitscan that reaches a LINE spawns
;       MT_PUFF at the point it stopped and goes no further. :1006 -- a thing
;       with MF_NOBLOOD (the barrel) gets one too; anything else bleeds.
;     * p_mobj.c P_SpawnPuff: z jittered by (P_Random()-P_Random())<<10,
;       momz = FRACUNIT (it drifts UP a unit a tic), tics -= P_Random()&3.
;     * info.c S_PUFF1..4 = PUFF A/B/C/D, 4 tics each -- 16 tics, under half a
;       second. There are no bullet HOLES in DOOM: the puff is all there is.
;   NOT DOOM, the usual reductions:
;     * ONE puff. Seven shotgun pellets share it, the way the port already
;       shares one damage target between them (enemy.asm).
;     * no z jitter and no momz: it hangs where it was made. Both are sub-pixel
;       at 160x168 -- momz is 16 units over the whole life, and a wall at 300
;       units projects that as four rows.
;     * the FIRST frame is skipped for a melee swing in DOOM (S_PUFF3, "don't
;       make punches spark"); this port does not puff a punch at all yet.
;   It is NOT a thing: like the ball (255) and the missile (254) it rides a
;   pseudo record, here on sentinel 253, with health 0 so en_shoot cannot
;   target it and state 0 so spr_dyn draws it live.
;==============================================================
        org PUFF_BASE
PF_TICS  equ 6                       ; one PUFF frame: DOOM's 4 tics at 35 Hz is
                                     ;   5.7 VBLANKs at 50 -- the same tic->VB
                                     ;   conversion pj_rspawn's 8/6/4 -> 11/9/6 uses

PF_MAX   equ 7                       ; A_FireShotgun's pellet count -- SEVEN puffs
                                     ;   is what the spread LOOKS like; one can
                                     ;   only ever show a single hole
PF_TBLD  equ 11                      ; BLUD's 8 tics at 35 Hz -> VBLANKs at 50

pfv_resume = *
        org PFVAR_BASE               ; the state, out of the code block: seven
                                     ;   pellets and two chains filled it
pf_on   dta 0                        ; 0 = idle, else the frame number, 1-based
pf_lst  dta 5                        ; the frame number it dies ON: a puff is
                                     ;   1..4 so 5, blood from BLUD C is 1..3
pf_lvl  dta $FF                      ; the level the two ids below belong to
pf_id   dta $FF                      ; PUFF A's sprtab id (things header +24)
pf_bid  dta $FF                      ; BLUD C's, first of C/B/A (+25)
pf_mel  dta 0                        ; 1 = the shot was a punch or a saw
pf_ttl  dta 0                        ; VBLANKs left on the current frame
pf_tic  dta PF_TICS                  ; ...and how many each frame gets
pf_n    dta 0                        ; how many of the seven are live
pf_i    dta 0                        ; the spawn/draw cursor
pf_lat  dta a(0)                     ; one pellet's lateral offset at the wall
pf_ss   dta a(0)                     ; ONE leaf for all of them: they land within
                                     ;   ~50 units of each other on the same wall,
                                     ;   and the projection only needs the leaf to
                                     ;   be one the BSP walk reaches -- which the
                                     ;   wall you just shot is by definition
pf_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0 (not a pickup)
    .if * > PFVAR_END+1
        ert 'the puff state outgrew PFVAR_BASE..PFVAR_END (memory_map.inc)'
    .endif
        org pfv_resume

;--------------------------------------------------------------
; sh_refine -- sh_trace's tail: the walk found the leaf that stops the bullet
;   and sh_leaf left zp_sptr on the seg, so bisect the RAY LENGTH for where it
;   crosses. Out of the ROCKW block, which sh_trace fills to two bytes.
;
;   THE CHEAP TEST (the whole reason this is its own proc). use_seg_hit costs
;   2625 cycles -- four use_side calls -- and running it seven times here was
;   26000 of a 46000-cycle trace, i.e. most of the stutter on a trigger pull.
;   But only the ray END moves in this loop. The seg is fixed, and so is the
;   ray's DIRECTION, so use_seg_hit's second half ("do the seg's ends straddle
;   the ray's line") cannot change: shortening B scales that cross product, it
;   does not flip it. Only the first half is live, and it is ONE use_side:
;   is B on the far side of the seg's line from A? That flips exactly once as
;   B slides out, which is what makes the bisection exact.
;   use_seg_hit left the seg's v1/v2 in USE_PT_P/USE_PT_Q, so there is nothing
;   to set up.
;--------------------------------------------------------------
pf_resume = *
        org SHREF_BASE
.proc sh_refine
        lda #0
        sta sh_lo                    ; the wall is somewhere in [0, sh_hi], and
        sta sh_lo+1                  ;   sh_hi is still the full ray
        sta USE_K
        ldx #8                       ; side(v1 -> v2, the ray START). Constant --
        ldy #12                      ;   A never moves, so it comes out here
        jsr use_side
        sta sh_sa
        lda #SH_REF                  ; the count lives in MEMORY: smul_14 (under
        sta sh_n                     ;   sh_setb) eats X, and counting the
                                     ;   halvings in it hung the loop outright
?ref    clc                          ; mid = (lo + hi) / 2
        lda sh_lo
        adc sh_hi
        sta sh_d
        lda sh_lo+1
        adc sh_hi+1
        sta sh_d+1
        lsr sh_d+1
        ror sh_d
        jsr sh_setb                  ; shorten the ray to mid...
        lda #4
        sta USE_K
        ldx #8
        ldy #12
        jsr use_side                 ; ...and ask which side of the seg it ends
        cmp sh_sa
        beq ?rlo                     ; same side as A -> it has not reached it
        lda sh_d                     ; crossed -> the wall is at or before mid
        sta sh_hi
        lda sh_d+1
        sta sh_hi+1
        jmp ?rnx
?rlo    lda sh_d                     ; clear -> it is beyond mid
        sta sh_lo
        lda sh_d+1
        sta sh_lo+1
?rnx    dec sh_n
        bne ?ref
        lda sh_lo                    ; the last CLEAR length: just in FRONT of
        sta sh_d                     ;   the wall, where a sprite is still drawn
        lda sh_lo+1
        sta sh_d+1
        jsr sh_dist
        sec
        jmp sh_end                   ; C=1: a wall was found
.endp
; the seven pellets' impact points, parked with sh_refine: the puff block itself
; went full the moment one puff became seven.
pf_px   dta a(0),a(0),a(0),a(0),a(0),a(0),a(0)
pf_py   dta a(0),a(0),a(0),a(0),a(0),a(0),a(0)
    .if * > SHREF_END+1
        ert 'sh_refine + the pellet points outgrew SHREF_BASE..END'
    .endif
        org PFTAB_BASE
; tan(the pellet's angle) in Q14, one entry per aim column 72..88. SCREEN_HALF
; IS the focal length (90 deg FOV), so a shot landing Dx columns off centre has
; tangent Dx/80 -- in Q14 that is Dx * 16384/80 = Dx * 205. A table, not a
; multiply: the index is signed and there are only seventeen of them.
pf_tan  dta a(-1640),a(-1435),a(-1230),a(-1025),a(-820),a(-615),a(-410),a(-205)
        dta a(0)
        dta a(205),a(410),a(615),a(820),a(1025),a(1230),a(1435),a(1640)
    .if * > PFTAB_END+1
        ert 'pf_tan outgrew PFTAB_BASE..PFTAB_END (memory_map.inc)'
    .endif
        org pf_resume

;--------------------------------------------------------------
; pf_shot -- one call per trigger pull, from en_gunshot's hitscan tails.
;   A shot that CONNECTED leaves en_hit set and DOOM would spawn blood, not a
;   puff, so there is nothing to do. A shot that hit nothing gets the wall
;   traced and the puff put there.
;--------------------------------------------------------------
.proc pf_shot
        lda pf_on
        bne ?out                     ; one already showing: let it finish. There
                                     ;   is ONE instance, so re-arming per shot
                                     ;   would only move it -- and the chaingun
                                     ;   fires every 4 tics, which is about one
                                     ;   DRAWN frame here, so the trace would run
                                     ;   every frame and halve the frame rate.
                                     ;   Same reduction pj_pspawn takes for the
                                     ;   plasma bolt.
        lda en_hit
        beq ?wall
        jmp pf_gore                  ; it hit a THING: blood, or a puff if that
                                     ;   thing does not bleed (p_map.c:1005)
?wall   lda pf_id
        bmi ?out                     ; the level packed no PUFF frames
        lda #SH_NBULL
        ldx pf_mel
        beq ?rng                     ; a punch or a saw only reaches MELEERANGE,
        lda #SH_NMELEE               ;   so it cannot puff a wall across the room
?rng    jsr sh_trace                 ; en_bx/en_by = where the bullet stopped
        bcs ?hitwall                 ; C=0: nothing in reach -- DOOM's trace runs
?out    rts                          ;   out at MISSILERANGE the same way
?hitwall
        jsr gun_match                ; P_ShootSpecialLine: the wall this bullet
                                     ;   stopped on (zp_sptr, which sh_refine does
                                     ;   not move) may be a 46 -- E1M2's secret
                                     ;   door. Only the HITSCAN trace comes here;
                                     ;   a rocket activates no line in DOOM either
        ; ONE trace, SEVEN puffs. DOOM traces each pellet and puffs where each
        ; one lands; seven traces here would be seven times 28000..83000 cycles,
        ; four whole frames. But the pellets leave the same muzzle and reach the
        ; same wall -- only the ANGLE differs -- so the wall distance sh_trace
        ; just found serves all of them, and each puff is that impact point slid
        ; sideways by dist*tan(its own spread). Exact for a wall square to the
        ; shot, and off by the wall's slant otherwise, which at 160x168 is
        ; nothing. What it buys is the thing that was missing: you can SEE the
        ; spread, because there are seven holes and they scatter.
?go     ldx #1
        lda wp_cur
        cmp #WP_SHOTGUN
        bne ?n1
        ldx #PF_MAX
?n1     stx pf_n
        stx pf_i
?pel    jsr en_aimcol                ; the same roll the pellet itself took
        lda en_col                   ;   (enemy_ai.asm) -- same distribution,
        sec                          ;   fresh numbers: the pellets' own columns
        sbc #SCREEN_HALF-8           ;   are long gone by now. 0..16
        asl
        tay
        lda pf_tan,y                 ; m_b = tan(this pellet's angle), Q14
        sta m_b
        lda pf_tan+1,y
        sta m_b+1
        lda sh_d                     ; m_a = the wall distance sh_trace settled on
        sta m_a
        lda sh_d+1
        sta m_a+1
        jsr smul_14                  ; m_res = how far off the impact it lands
        lda m_res
        sta pf_lat
        lda m_res+1
        sta pf_lat+1
        lda pf_lat                   ; slide along the PERPENDICULAR (-sin, cos)
        sta m_a
        lda pf_lat+1
        sta m_a+1
        lda zp_sin
        sta m_b
        lda zp_sin+1
        sta m_b+1
        jsr smul_14
        ldx pf_i
        dex
        txa
        asl
        tax                          ; X = the pellet's slot * 2
        sec                          ; px = impact_x - lat*sin
        lda en_bx
        sbc m_res
        sta pf_px,x
        lda en_bx+1
        sbc m_res+1
        sta pf_px+1,x
        lda pf_lat
        sta m_a
        lda pf_lat+1
        sta m_a+1
        lda zp_cos
        sta m_b
        lda zp_cos+1
        sta m_b+1
        jsr smul_14
        ldx pf_i
        dex
        txa
        asl
        tax
        clc                          ; py = impact_y + lat*cos
        lda en_by
        adc m_res
        sta pf_py,x
        lda en_by+1
        adc m_res+1
        sta pf_py+1,x
        dec pf_i
        beq ?allset
        jmp ?pel                     ; (out of branch range: seven pellets of
?allset                              ;  vector maths is more than 127 bytes)
        sec                          ; they hang at eye - 9, level: the height the
        lda zp_pz                    ;   missiles fly at, and the shot is level
        sbc #9                       ;   too (this port has no aim slope)
        sta pf_rec+4
        lda zp_pz+1
        sbc #0
        sta pf_rec+5
        ldx #5                       ; PUFF A/B/C/D, so it dies on frame 5
        lda pf_id
        ldy pf_mel
        beq ?st
        clc                          ; "don't make punches spark on the wall"
        adc #2                       ;   (p_mobj.c): a melee puff starts at
        ldx #3                       ;   S_PUFF3, i.e. PUFF C, and shows two
?st     sta pf_rec+6
        stx pf_lst
        lda #PF_TICS
        sta pf_tic
        sta pf_ttl
        lda #1
        sta pf_on
        lda en_bx                    ; the LEAF comes off the traced impact point
        sta pf_rec
        lda en_bx+1
        sta pf_rec+1
        lda en_by
        sta pf_rec+2
        lda en_by+1
        sta pf_rec+3
        jmp pf_leaf
.endp

;--------------------------------------------------------------
; pf_gore -- PTR_ShootTraverse's THING branch (p_map.c:1000-1010): the shot
;   reached something, so it leaves BLOOD there -- or a puff, if the thing has
;   MF_NOBLOOD. Of everything shootable in E1 that is the barrel alone
;   (info.c MT_BARREL), and it has to be named: en_kind was 0 for it while
;   en_kind_of only knew MONSTERS, but the AI tables gave the barrel kind
;   MK_BEXP, so "kind 0" stopped meaning "does not bleed" and every shot at a
;   barrel sprayed blood (2026-08-05).
;
;   P_SpawnBlood, verbatim except for the reductions: the DAMAGE picks where
;   the chain starts, so a graze shows one frame and a shotgun three --
;     damage >= 13  S_BLOOD1 = BLUD C, all three frames
;     damage 9..12  S_BLOOD2 = BLUD B, two
;     damage <  9   S_BLOOD3 = BLUD A, one
;   Not modelled: the z jitter (+-4 units, sub-pixel here), momz = 2*FRACUNIT,
;   and `tics -= P_Random()&3`. Same three the wall puff drops.
;
;   POSITION. DOOM puts it 10 units in FRONT of the thing, along the trace
;   (p_map.c:995). This port has no intersection to step back from -- the aim
;   IS the vissprite -- so it goes on the thing's own centre. At 160x168 the
;   difference is inside the monster's own sprite.
;--------------------------------------------------------------
pfg_resume = *
        org GORE_BASE
.proc pf_gore
        lda en_kind                  ; MF_NOBLOOD -> a puff: kind 0 (a shootable
        beq ?puff                    ;   this port names no kind for) and the
        cmp #MK_BEXP                 ;   BARREL, which does have one
        bne ?blood
?puff   lda pf_id
        bmi ?out
        ldx #5                       ; PUFF A/B/C/D
        ldy #PF_TICS
        bne ?arm                     ; (always: PF_TICS is 6)
?blood  lda pf_bid
        bmi ?out
        ldy en_dmg                   ; P_SpawnBlood's damage gate
        cpy #13
        bcs ?bset                    ; >= 13: BLUD C, three frames
        ldx #3
        cpy #9
        bcs ?b2                      ; 9..12: BLUD B, two
        ldx #2
        clc
        adc #2                       ; < 9: BLUD A, one
        bne ?bt                      ; (always: an id is never 0 -- sprite 0 is
?b2     clc                          ;  a map thing, and BLUD is packed last)
        adc #1
        bne ?bt                      ; (always, same reason)
?bset   ldx #4                       ; BLUD C/B/A -> frames 1..3, dies on 4
?bt     ldy #PF_TBLD
?arm    sta pf_rec+6
        stx pf_lst
        sty pf_tic
        sty pf_ttl
        lda en_last                  ; the thing the shot connected with
        jsr en_thing.en_th2          ;   -> sp_ptr = its record (x, y at 0..3)
        ldy #0
        lda (sp_ptr),y
        sta pf_px
        sta pf_rec
        iny
        lda (sp_ptr),y
        sta pf_px+1
        sta pf_rec+1
        iny
        lda (sp_ptr),y
        sta pf_py
        sta pf_rec+2
        iny
        lda (sp_ptr),y
        sta pf_py+1
        sta pf_rec+3
        sec                          ; eye - 9, level, like the wall puff
        lda zp_pz
        sbc #9
        sta pf_rec+4
        lda zp_pz+1
        sbc #0
        sta pf_rec+5
        lda #1
        sta pf_n                     ; ONE gore sprite, never seven: the pellets
        sta pf_on                    ;   that connect all land on one vissprite
        jmp pf_leaf
?out    rts
.endp
    .if * > GORE_END+1
        ert 'pf_gore outgrew GORE_BASE..GORE_END (memory_map.inc)'
    .endif
        org pfg_resume

;--------------------------------------------------------------
; pf_leaf -- which subsector the puff hangs in, so spr_chased knows when to
;   project it. locate_floor reads zp_px/zp_py, so borrow them (pj_leaf's dance).
;--------------------------------------------------------------
.proc pf_leaf
        lda zp_px
        pha
        lda zp_px+1
        pha
        lda zp_py
        pha
        lda zp_py+1
        pha
        lda pf_rec
        sta zp_px
        lda pf_rec+1
        sta zp_px+1
        lda pf_rec+2
        sta zp_py
        lda pf_rec+3
        sta zp_py+1
        jsr locate_floor             ; zp_nid = the leaf
        lda zp_nid
        sta pf_ss
        lda zp_nid+1
        and #$7F
        sta pf_ss+1
        pla
        sta zp_py+1
        pla
        sta zp_py
        pla
        sta zp_px+1
        pla
        sta zp_px
        rts
.endp

;--------------------------------------------------------------
; pf_frameb -- the frame loop's projectile call, retargeted once more: the
;   missile's chain first (which starts with the movers), then the puff clock.
;--------------------------------------------------------------
.proc pf_frameb
        jsr pj_frameb
        lda current_level            ; a new level: forget the puff and learn
        cmp pf_lvl                   ;   this level's PUFF id
        beq ?same
        sta pf_lvl
        lda #0
        sta pf_on
        sta.l $010000+TH_HPL+TH_NOTHING     ; sentinel 253: health 0 so en_shoot skips
        sta.l $010000+TH_HPL+$100+TH_NOTHING ;  it, state 0 so spr_dyn draws it live,
        sta.l $010000+TH_STATE+TH_NOTHING   ;   kind 0 so wrot_idle does not send it
        sta.l $010000+TH_KIND+TH_NOTHING    ;   down the monster path (proj.asm's note)
        lda THINGS_BASE+24
        sta pf_id
        lda THINGS_BASE+25
        sta pf_bid
?same   lda pf_on
        beq ?out
        sec                          ; this drawn frame ate fps_n VBLANKs
        lda pf_ttl
        sbc fps_n
        sta pf_ttl
        bcc ?adv                     ; ran past, or out exactly -> next frame
        beq ?adv
        lda fps_n                    ; ...and one image per DRAWN frame once the
        cmp #4                       ;   frames get long. A drawn frame here is
        bcc ?out                     ;   ~5 VBLANKs and BLUD's 8 tics are 11, so
                                     ;   the tic clock alone held every image for
                                     ;   two or three frames -- a slideshow, and
                                     ;   the same complaint pj_cap was written
                                     ;   for ("the missile is only ever seen
                                     ;   where a frame lands"). Above 12 fps the
                                     ;   tic clock governs again and the timing
                                     ;   is DOOM's.
?adv    inc pf_on
        lda pf_on
        cmp pf_lst
        bcs ?gone                    ; the last frame ran out: S_NULL
        inc pf_rec+6                 ; every chain here is packed CONSECUTIVE
        lda pf_tic
        sta pf_ttl
?out    rts
?gone   lda #0
        sta pf_on
        rts
.endp

;--------------------------------------------------------------
; spr_chased -- spr_add's chase hook, retargeted a third time (sprites.asm
;   calls this one): the ball and the missile first, then the puff.
;--------------------------------------------------------------
pfh_resume = *
        org PFHK_BASE
.proc spr_chased
        jsr spr_chasec
        lda pf_on
        beq ?out
        lda zp_nid
        cmp pf_ss
        bne ?out
        lda zp_nid+1
        and #$7F
        cmp pf_ss+1
        bne ?out
        lda pf_n                     ; every live pellet's puff, one at a time
        sta pf_i                     ;   through the shared record
?one    lda sp_n
        cmp #VIS_MAX
        bcs ?out
        ldx pf_i
        dex
        txa
        asl
        tax
        lda pf_px,x
        sta pf_rec
        lda pf_px+1,x
        sta pf_rec+1
        lda pf_py,x
        sta pf_rec+2
        lda pf_py+1,x
        sta pf_rec+3
        lda #TH_NOTHING              ; vs_th: the puff's "not a thing"
        sta sp_i
        lda #<pf_rec
        sta sp_ptr
        lda #>pf_rec
        sta sp_ptr+1
        jsr spr_proj
        dec pf_i
        bne ?one
?out    rts
.endp
    .if * > PFHK_END+1
        ert 'spr_chased outgrew PFHK_BASE..PFHK_END (memory_map.inc)'
    .endif
        org pfh_resume
    .if * > PUFF_END+1
        ert 'the puff outgrew PUFF_BASE..PUFF_END (memory_map.inc)'
    .endif
