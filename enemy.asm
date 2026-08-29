;==============================================================
; enemy.asm -- DAMAGE + DEATH (2026-07-30). p_inter.c P_DamageMobj/P_KillMobj and
; p_pspr.c P_GunShot, reduced to what this port can carry.
;
; THE DATA. pack_things.py puts info.c's spawnhealth in the things blob, u16 per
; SPRITE table entry (one monster type = one spawn sprite, and a level has ~30
; sprites against up to 255 things -- the per-thing form overflowed E1M6's blob).
; en_init expands that into TH_HPL/TH_HPH, 256 u16 in Rapidus SRAM bank $01 above
; the map: 512 B exists nowhere in base RAM, and this is cold data -- written at
; level init and on a hit, never in the frame path. 0 = not shootable, which is
; what every test here keys on, so decorations and pickups need no flag.
;
; THE AIM. Not a blockmap trace. spr_add already built this frame's vissprite
; list, and a vissprite is BY DEFINITION visible and wall-clipped -- so "what is
; under the crosshair" is the vissprite whose column span covers SCREEN_HALF with
; the largest scale (scale falls monotonically with Z, which is why it doubles as
; the sort key in spr_add). That gets line-of-sight for free: a monster behind a
; wall never became a vissprite. The cost is one frame of lag, the same
; granularity DOOM's tics have anyway.
;
; DELIBERATELY NOT DOOM, all three worth knowing:
;   * P_Random is POKEY's LFSR ($D20A), not DOOM's rndtable. hud.asm already does
;     this for the face pick and notes it: `and #3` with 3 -> 2 is biased, and so
;     is DOOM's own M_Random%3.
;   * damage IS per weapon now (p_pspr.c, verified against the source): the
;     pistol and chaingun roll P_GunShot's 5*(rnd%3+1) once, the shotgun rolls
;     it SEVEN times (A_FireShotgun's pellet loop) and the fist/chainsaw use
;     A_Punch/A_Saw's 2*(rnd%10+1). What is NOT DOOM: the seven pellets all
;     land on the same target, because the aim is one vissprite rather than
;     seven spread traces -- and there is no berserk multiply (no pw_strength).
;   * no painstate, no death animation, no retaliation. At <= 0 the thing's
;     THING_ALIVE bit is cleared and it stops being drawn -- P_KillMobj's corpse,
;     height>>2 and the deathstate chain need sprite frames in VRAM (see the
;     PLAN note at the end of this file).
;==============================================================
        org ENINIT_BASE

;--------------------------------------------------------------
; en_init -- per level: TH_HP[i] = hp_table[thing[i].sid]. Called from init_level
;   AFTER load_things has cached th_things (the blob's header pointers).
;   zp_ptr+2 already holds MAP_EXT_BANK -- init_level sets it and nothing else
;   writes it (collision.asm's note), so the long stores below need no setup.
;--------------------------------------------------------------
.proc en_init
        ; sp_tab / sp_ptr borrowed as the two (zp),y readers -- they are sprites.asm
        ; per-frame scratch and init_level runs long before the first frame. My own
        ; variables live at $FEDD, which (zp),y cannot address.
        lda THINGS_BASE+16           ; p_hp: the u16-per-sprite table (HEADER+16;
        sta sp_tab                   ;   the other pointers sit at +5/+11/+13/+14
        lda THINGS_BASE+17           ;   and are untouched by that append)
        sta sp_tab+1
        lda th_things                ; walk the thing records with a running
        sta sp_ptr                   ;   pointer: index*8 would overflow a byte
        lda th_things+1              ;   past thing 31
        sta sp_ptr+1
        jsr wrot_init                ; cache the per-level stored-view count
                                     ;   (this block is full: the body lives
                                     ;   with spr_wrot at WROT_BASE)
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        ldx #0                       ; X = thing index
?lp     cpx THINGS_BASE              ; thing count (the packer caps it at 255)
        bcs ?done
        ldy #6                       ; thing record +6 = sprite id
        lda (sp_ptr),y
        asl                          ; *2: the table is u16 (sid < 128 always --
        tay                          ;   a level has at most ~32 sprites)
        lda (sp_tab),y
        sta en_t
        iny
        lda (sp_tab),y
        sta en_t+1
        txa
        tay                          ; Y = thing index -> the bank $01 page offset
        lda en_t
        sta [zp_ptr],y               ; TH_HPL[i]
        inc zp_ptr+1                 ; $6400 -> $6500 = TH_HPH
        lda en_t+1
        sta [zp_ptr],y
        dec zp_ptr+1
        jsr wrot_dir                 ; TH_DIR[i] = the spawn facing (flags bits
                                     ;   4-6) -- P_SpawnMapThing's angle
        clc                          ; next record
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inx
        bne ?lp                      ; (count <= 255, so this always loops back)
?done   lda #<TH_STATE               ; nothing is dying at level start -- RAM in
        sta zp_ptr                   ;   bank $01 is whatever the last level left
        lda #>TH_STATE
        sta zp_ptr+1
        lda #0
        tay
?cl     sta [zp_ptr],y
        iny
        bne ?cl
        jsr blk_fill                 ; the blockmap, BEFORE the first move test:
                                     ;   move_player runs earlier in the frame
                                     ;   than the rebuild (enemy_ai.asm)
        jsr en_radfill               ; TH_RAD, the radius en_solid sweeps (it and
                                     ;   its variables live in the THCOLL block --
                                     ;   this one is full, see the note above)
        jmp en_kfill                 ; TH_KIND for every thing (WROT block: this
.endp                                ;   one is full) -- and IT tail-jumps the
                                     ;   ai_reset that used to sit here.

; (en_kind_of MOVED to the WROT block 2026-08-03: wrot_dir/wrot_init pushed
;  this block 6 B over, and wrot_idle calls it anyway -- same neighbourhood.)

;--------------------------------------------------------------
; en_gunshot -- roll the READY WEAPON's damage (p_pspr.c) and fire it into
;   en_shoot. Called once per shot from wp_fire_a. Cold, so it lives in the
;   ENINIT block: the hot $FEDD one is full. Clobbers A/X/Y.
;
;   THE SPREAD (2026-08-05). P_GunShot's `angle += (P_Random()-P_Random())<<18`
;   is an ANGLE, and this port aims by screen COLUMN -- but those are the same
;   thing here: SCREEN_HALF is the horizontal focal length (90 deg FOV), so a
;   shot turned by theta lands at column SCREEN_HALF + SCREEN_HALF*tan(theta).
;   The full +-255 roll is +-5.6 deg = +-7.85 columns, i.e. the roll rounded
;   over 32 (en_aimcol). Nothing else has to change: a column that misses the
;   target's span picks no vissprite, and one that lands on the NEXT thing along
;   -- the imp behind it, or the BARREL beside it -- hits that instead, which is
;   what DOOM's seven separate traces do.
;   Who rolls it, p_pspr.c verbatim:
;     pistol / chaingun  P_GunShot(mo, !player->refire): the FIRST shot of a
;                        burst is dead accurate, every held-trigger one after
;                        it is not (A_ReFire counts them in wp_refire)
;     shotgun            seven P_GunShot(mo, false), each with its OWN roll
;     fist / chainsaw    A_Punch / A_Saw roll the same <<18 -- at MELEERANGE the
;                        target fills the view, so it still almost always lands
;     rocket / plasma    P_SpawnPlayerMissile: no spread at all (it autoaims)
;--------------------------------------------------------------
.proc en_gunshot
        lda #0
        sta en_hit                   ; en_shoot raises it when the shot CONNECTS
        sta en_melee                 ;   (wp_fire_a picks punch/sawhit off it)
        sta pf_mel                   ; a bullet, until ?melee says otherwise
        lda #SCREEN_HALF             ; the aim column: dead centre = an ACCURATE
        sta en_col                   ;   shot; the branches below roll it off
        ldy #SCREEN_HALF-1           ; ...and THE AIM CELL around it. DOOM's trace
        sty en_cl                    ;   is a zero-width line at an angle it can
        ldy #SCREEN_HALF+1           ;   express to 1/2^32 of a circle; this port
        sty en_ch                    ;   has 256 of them, so "fire at BAM a" really
                                     ;   means "somewhere in the 1.41 deg cell
                                     ;   around a", and half a cell is one column
                                     ;   (SCREEN_HALF is the focal length). Without
                                     ;   it a thing past ~1000 units projects to a
                                     ;   SINGLE column and exactly one of the 256
                                     ;   angles can hit it -- 3 with the cell
                                     ;   (tools/_dbg_aimgrid.py). Only the AIMED
                                     ;   shot gets it: en_aimcol collapses the cell
                                     ;   again, so the spread keeps DOOM's own
                                     ;   hit rate (tools/_verify_gunspread.py).
        ldx wp_cur
        cpx #WP_SHOTGUN
        beq ?shotgun
        cpx #WP_MISSILE
        beq ?rocket
        cpx #WP_PLASMA
        beq ?plasma
        cpx #WP_FIST
        beq ?melee
        cpx #WP_CHAINSAW             ; A_Saw rolls A_Punch's damage (p_pspr.c:
        beq ?melee                   ;   2*(P_Random()%10+1) for both)
        lda wp_refire                ; pistol / chaingun: ONE P_GunShot, and it
        beq ?acc                     ;   is accurate only while refire == 0 --
        jsr en_aimcol                ;   A_ReFire has counted the held trigger
?acc    jsr en_r5
        jsr en_shoot                 ;   (A_FirePistol, A_FireCGun)
        jmp pf_shot                  ; ...and a miss leaves a puff on the wall
?rocket jmp en_rocket                ; A_FireMissile: a direct hit + A_Explode
?plasma jmp en_plasma                ; A_FirePlasma
        ; --- A_FireShotgun: `for (i=0 ; i<7 ; i++) P_GunShot(mo, false)`. SEVEN
        ;     INDEPENDENT pellets since 2026-08-05: each rolls its own aim column
        ;     and its own 5*(rnd%3+1), so the spread decides how many of them
        ;     land. It used to sum the seven rolls into one guaranteed 14..105
        ;     hit, which made the shotgun a sniper rifle.
?shotgun lda #7
        sta en_pel                   ; en_shoot clobbers en_t, so the count
?pellet jsr en_aimcol                ;   cannot live there (and not in X either)
        jsr en_r5
        jsr en_shoot
        dec en_pel
        bne ?pellet
        jmp pf_shot                  ; all seven missed -> one puff on the wall
        ; --- A_Punch / A_Saw: damage = 2*(P_Random()%10+1), i.e. 2..20, times
        ;     TEN with berserk (p_pspr.c) -- 20..200, and 200 still fits a byte.
        ;     MELEERANGE: en_shoot only accepts a target within arm's reach when
        ;     en_melee is up -- the saw used to kill across the room.
?melee  inc en_melee
        inc pf_mel                   ; ...and its puff is the MELEERANGE one
        jsr en_aimcol                ; both swings roll the <<18 as well
        lda RANDOM
        and #15                      ; 0..15 -> 0..9, with the same doubled
        cmp #10                      ;   frequency on 0..5 the file's header
        bcc ?m1                      ;   already accepts for `and #3`
        sbc #10
?m1     clc
        adc #1                       ; 1..10
        asl                          ; *2 -> 2..20
        sta en_t
        lda PW_FLAGS                 ; "if (player->powers[pw_strength])
        and #PWF_BERSERK             ;    damage *= 10"
        beq ?msend
        lda en_t
        asl
        asl
        asl                          ; d*8
        clc
        adc en_t
        adc en_t                     ; + 2d = d*10
        bne ?mgo                     ; (always: the roll is 20..200)
?msend  lda en_t
?mgo    jsr en_shoot
        jmp pf_shot                  ; blood on what it hit, or the MELEERANGE
.endp                                ;   puff on the wall it did not

;--------------------------------------------------------------
; en_r5 -- P_GunShot's damage: 5*(P_Random()%3+1) = 5, 10 or 15. One roll per
;   PELLET (the shotgun calls it seven times). Clobbers A and en_t.
;--------------------------------------------------------------
.proc en_r5
        lda RANDOM                   ; POKEY LFSR (see the header note)
        and #3
        cmp #3
        bne ?ok
        lda #2                       ; 3 -> 2, the same bias hud.asm accepts
?ok     clc
        adc #1                       ; 1..3
        sta en_t
        asl
        asl                          ; *4
        clc
        adc en_t                     ; *5
        rts
.endp

;--------------------------------------------------------------
; en_hurt_snd / en_die_snd -- the voice, from info.c via mk_tables.inc.
;   DOOM plays painsound out of A_Pain, which the pain state only reaches when
;   P_Random() < painchance (p_inter.c P_DamageMobj), so the roll is here too --
;   without it a burst of pistol fire makes one long scream. Clobbers A/X.
;--------------------------------------------------------------
.proc en_hurt_snd
        lda #0                       ; the roll ALSO drives MF_JUSTHIT (p_inter.c
        sta en_painr                 ;   :895 sets it in the same if), so ai_hurt
        ldx en_kind                  ;   reads the answer out of here
        beq ?no                      ; 0 = not a monster (a barrel, a decoration)
        lda RANDOM                   ; POKEY LFSR, like the rest of this file
        cmp mk_chance,x
        bcs ?no                      ; >= painchance -> it takes it silently
        inc en_painr                 ; ...but it DID flinch: fight back
        lda mk_pain,x
        bmi ?no                      ; $FF = this type has no sound in the build
        sta en_snd_q                 ; NOT snd_pending: wp_fire_a stores the
?no     rts                          ;   gunshot AFTER this runs and would stomp it
.endp

; (en_die_snd MOVED to the MKTAB block 2026-08-04: the A_Scream variant roll
;  -- podth1..3 / bgdth1..2 via mk_dthn -- outgrew this block, and it reads
;  those tables anyway.)

                                     ; mk_tables.inc MOVED to the AI block at
                                     ; $8700 (enemy_ai.asm): the AI half of it
                                     ; -- mk_ctic/mk_wst/mk_wsh/mk_spd and the
                                     ; two step tables -- added 72 B and this
                                     ; block ran past $EFFF. The tables are
                                     ; plain absolute-indexed data, so where
                                     ; they sit does not matter to either reader.

en_dmg  dta 0                        ; damage of the shot being resolved
en_best dta 0                        ; vissprite under the crosshair ($FF = none)
en_bsc  dta 0,0                      ; its scale, i.e. how near it is
en_t    dta 0,0                      ; 16-bit scratch (health, the *5)
en_kind dta 0                        ; monster kind of the thing being hit
; The monster's voice, handed to wp_fire_a. One digi channel means a shot that
; HITS can only play one thing, and the grunt is the informative one -- the
; gunshot is the same on every trigger pull, and a miss still plays it. DOOM's
; painchance roll keeps it from firing on every single hit.
en_snd_q dta $FF                     ; $FF = the monster said nothing this shot
en_k2   dta 0,0                      ; en_kind_of scratch (sprite id * 8)
en_painr dta 0                       ; 1 = the last painchance roll passed
en_hit  dta 0                        ; 1 = the last player shot/swing CONNECTED
en_melee dta 0                       ; 1 = it was A_Punch/A_Saw (MELEERANGE gate)
en_pel  dta 0                        ; A_FireShotgun's pellet counter
en_last dta 0                        ; the thing the last shot CONNECTED with
; en_ovk / en_gib are EQUATES into the $5BDB hole, not dta here: this block is
; full to the byte and three more would push en_init out of it. See memory_map.
en_ovk  = ENGIB_VARS                 ; how far past zero the last damage went --
                                     ;   p_inter.c:719 gibs on more than
                                     ;   spawnhealth of it, and both damage sites
                                     ;   clamp health at 0, so it has to be kept
                                     ;   at the moment of the subtraction
en_gib  = ENGIB_VARS+2               ; 1 = that kill earned S_x_XDIE
en_col  dta SCREEN_HALF              ; AIM COLUMN of the shot being resolved: the
                                     ;   span test in en_shoot and the clip-window
                                     ;   lookup in en_seen both key on it, so
                                     ;   moving it off SCREEN_HALF IS the spread
en_cl   dta SCREEN_HALF-1            ; ...and the aim CELL around it, derived once
en_ch   dta SCREEN_HALF+1            ;   per shot at the top of en_shoot
    .if * > ENINIT_END+1
        ert 'en_init + vars outgrew ENINIT_BASE..END (memory_map.inc)'
    .endif
        org ENEMY_BASE

;--------------------------------------------------------------
; en_shoot -- A = damage. Aim, subtract, kill at <= 0. Clobbers A/X/Y.
;--------------------------------------------------------------
.proc en_shoot
        sta en_dmg
        lda #0                       ; best scale so far = 0 (nothing beats "none")
        sta en_bsc
        sta en_bsc+1
        lda #$FF
        sta en_best
        lda #<TH_HPL                 ; set up ONCE: the loop probes health through
        sta zp_ptr                   ;   it and ?have re-reads the winner with it
        lda #>TH_HPL
        sta zp_ptr+1
        ldx #0
?lp     cpx sp_n                     ; vissprites collected this frame
        bcs ?have
        lda vs_xb,x                  ; last column >= the aim cell's LEFT edge?
        cmp en_cl                    ;   (en_col is SCREEN_HALF for an accurate
        bcc ?nx                      ;   shot, off centre for a spread one)
        lda vs_x1h,x                 ; first column <= its RIGHT edge? (x1 is
        bmi ?xok                     ;   signed 16 -- negative = starts left of
        bne ?nx                      ;   the screen; hi > 0 = starts right of it)
        lda en_ch
        cmp vs_x1l,x
        bcc ?nx
?xok    jsr en_seen                  ; and is it actually VISIBLE in that column?
        beq ?nx                      ;   (a ledge lip, a closing door -- en_seen)
        ldy vs_th,x                  ; SHOOTABLE at all? p_map.c:867 -- DOOM's
        lda [zp_ptr],y               ;   traverse callback returns TRUE (= keep
        sta en_t                     ;   going) for a non-shootable thing, so a
        inc zp_ptr+1                 ;   decoration in the line of fire must NOT
        lda [zp_ptr],y               ;   eat the shot. Testing it HERE instead of
        dec zp_ptr+1                 ;   after the pick is the whole fix: picking
        ora en_t                     ;   the nearest and then bailing made anything
        beq ?nx                      ;   behind a prop unkillable.
        lda vs_sch,x                 ; nearer than the best so far? (scale falls
        cmp en_bsc+1                 ;   with Z, so bigger scale = nearer)
        bcc ?nx
        bne ?better
        lda vs_scl,x
        cmp en_bsc
        bcc ?nx
        beq ?nx
?better lda vs_scl,x
        sta en_bsc
        lda vs_sch,x
        sta en_bsc+1
        stx en_best
?nx     inx
        bne ?lp                      ; (sp_n <= VIS_MAX = 40)
?have   jsr en_reach                 ; X = en_best; C=0 = nothing under the
        bcc ?out                     ;   crosshair OR a melee swing out of
                                     ;   MELEERANGE (the gate lives with the
                                     ;   grind procs -- this block is full)
        lda vs_sid,x                 ; its VOICE, before X is reused below
        jsr en_kind_of               ;   (en_kind = 0 for anything not a monster)
        ldx en_best
        ldy vs_th,x                  ; Y = thing index (zp_ptr is still TH_HPL)
        sty en_last                  ; ...and pf_gore's victim: where the blood
        lda pj_hold                  ;   goes (proj.asm)
        bne ?out                     ; the ROCKET only wanted to know WHO: it
                                     ;   hurts it when it lands (pj_aim/pj_hit)
        lda [zp_ptr],y
        sta en_t
        inc zp_ptr+1                 ; zp_ptr now points at TH_HPH
        lda [zp_ptr],y
        sta en_t+1
        ora en_t
        beq ?out                     ; health 0 -> a decoration, or already dead
        sec                          ; P_DamageMobj: health -= damage
        lda en_t
        sbc en_dmg
        sta en_t
        lda en_t+1
        sbc #0
        sta en_t+1
        jsr en_ovkill                ; the overkill (the gib test, p_inter.c:719)
                                     ;   and then the clamp -- UNCONDITIONAL now:
                                     ;   the `bcs ?store` that used to skip it read
                                     ;   "no borrow -> still above zero", which is
                                     ;   wrong for EXACTLY zero. en_ovkill owns the
                                     ;   whole `health <= 0` test now (see there)
?store  lda en_t+1                   ; write it back (zp_ptr is on the HI page)
        sta [zp_ptr],y
        dec zp_ptr+1
        lda en_t
        sta [zp_ptr],y
        ora en_t+1
        beq ?dead
        tya                          ; survived: it yells, if the pain roll says so
        pha
        jsr en_hurt_snd
        pla
        tay
        jsr en_thrust_plr            ; ...and takes P_DamageMobj's kick, away
        ldy en_last                  ;   from the player (en_thrust wants Y for
                                     ;   itself, en_last is the same thing)
        jmp ai_hurt                  ; p_inter.c:902 "we're awake now": clear its
                                     ;   reactiontime, and MF_JUSTHIT if it flinched
?dead   tya                          ; P_KillMobj: the death cry, then the death
        pha                          ;   CHAIN -- en_kill parks the thing on its
        jsr en_thrust_plr            ;   first DIE frame and en_tick walks it.
                                     ;   The KICK first, though: p_inter.c:806
                                     ;   runs it before the health test, so a
                                     ;   corpse slides (en_slide, enemy_ai.asm)
        jsr en_die_snd
        pla                          ;   (en_die_snd clobbers X, hence the stack.
        tay                          ;   A kind with no chain still just vanishes:
        jmp en_kill                  ;   en_kill tail-calls thing_kill for that.)
?out    rts
.endp

;--------------------------------------------------------------
; en_rocket -- A_FireMissile, folded into this port's aim model.
;   DOOM spawns an MT_ROCKET, flies it, and on the first thing it touches
;   PIT_CheckThing rolls ((P_Random()&7)+1) * mobjinfo.damage (20 for the rocket,
;   so 20..160) and P_ExplodeMissile runs A_Explode = P_RadiusAttack(...,128).
;   NOT DOOM: there is no missile mobj, so the rocket lands the same tic it is
;   fired, on the vissprite under the crosshair -- the same reduction the shotgun's
;   seven pellets already take (enemy.asm's header). Consequences, all real:
;     * a rocket that hits nothing does nothing. DOOM's would burst on the wall
;       it reached and splash from there; there is no impact point here.
;     * the splash goes off at the THING that was hit, and that thing is by
;       definition visible -- but the blast itself has no sight table (en_lfind
;       only finds barrels), so it does reach through the wall behind its victim.
;     * the player IS in range of his own rocket, exactly as in DOOM.
;--------------------------------------------------------------
.proc en_rocket
        lda RANDOM                   ; ((P_Random()&7)+1) * 20
        and #7
        clc
        adc #1
        asl
        asl                          ; n*4
        sta en_t+1
        asl
        asl                          ; n*16
        clc
        adc en_t+1                   ; n*20 = 20..160, still a byte
        jmp en_rocket2               ; the aim + blast + the VISIBLE missile
.endp                                ;   (proj.asm -- this block is full)

;--------------------------------------------------------------
; sh_trace -- the rocket that hit NO thing: burst it on the wall instead
;   ("a rocket that hits nothing does nothing" was a real gap, not a wash --
;   in DOOM a point-blank rocket into a wall wounds the SHOOTER, and
;   PIT_RadiusAttack has no bombsource exemption, p_map.c:1194).
;   The wall is found by marching the aim ray in RKW_STEP jumps of (cos,sin)
;   and asking collide_blocked -- the PLAYER'S OWN wall test -- at every
;   sample. The first version asked locate_floor instead, "is the floor here
;   at or above the eye", and that CANNOT see a one-sided wall: a point in the
;   void behind one still descends to a leaf whose sector is the open room next
;   to it, so every rocket marched the full RKW_N steps and burst 1280 units
;   away, through the wall (2026-08-04: "ked s raketou vystrelim oproti muru,
;   nic sa nestane"). collide_blocked answers the real question -- is a
;   BLOCKING seg (one-sided, or an opening under PLAYER_H) within PLAYER_R of
;   this point -- and it also still catches the shut door and the low lintel
;   the old test was written for.
;   The step is PLAYER_R, not more: the test is a circle of that radius, so a
;   longer stride could jump clean over a wall and out into the void again.
;   The blast goes off at the LAST OPEN sample, in front of the wall -- a point
;   inside it belongs to no rendered leaf, and the burst sprite would be
;   invisible there. Then A_Explode, en_boom's own shape minus the exploding
;   thing: en_k2 = $FF (the sweep skips nobody), en_lp = 0 (no barrel grid --
;   same as every non-barrel blast).
;   If RKW_N steps stay open the blast goes off at the ray end, which is past
;   BOOM_DMG range for the player by construction (RKW_STEP*RKW_N >> 128+r).
;--------------------------------------------------------------
;--------------------------------------------------------------
; sh_trace -- p_map.c PTR_ShootTraverse, the geometry half: walk the leaves the
;   aim ray crosses and stop at the first line that stops a BULLET.
;   IN : A = how many SH_STEP samples to walk (SH_NBULL / SH_NROCK).
;   OUT: en_bx/en_by = the impact point, C=1 if a wall was found. C=0 = the ray
;        ran out; en_bx/by is then the ray end, which is what en_march did too.
;   Clobbers A/X/Y, m_*, zp_ptr/zp_sptr/zp_nid/zp_segcnt, USE_PT_A/B, USE_SS.
;
;   WHY THIS REPLACED en_march (2026-08-05). The old one stepped
;   collide_blocked every 16 units, and collide_blocked costs 18077 cycles a
;   sample against a ~125000-cycle frame (tools/cycle_estimate.py). Measured on
;   E1M1 with tools/_dbg_puffcost.py, one rocket fired down the first corridor
;   ran 1550400 cycles -- TWELVE FRAMES of freeze for a single shot. It also
;   asked the wrong question: "is a blocking seg within PLAYER_R of this point"
;   is the circle test for a MOVING BODY, not a ray-vs-line crossing.
;
;   The shape here is try_use's, which is already 99.61% P_UseLines
;   (tools/_verify_useray.py): the samples only ENUMERATE the subsectors, and
;   the crossing test always runs against the whole ray, so a coarse step costs
;   accuracy nowhere except in a subsector narrower than SH_STEP. One sample is
;   a BSP descent (2455 cycles) plus that leaf's segs, and the walk stops at the
;   first leaf that blocks -- so shooting AT a wall, the case that matters, pays
;   three or four of them.
;
;   NOT try_use: no door opens, no switch fires, no EXIT_REQ. A bullet is not a
;   USE press and PTR_ShootTraverse activates nothing (p_map.c:955-975 only ever
;   spawns a puff). That is the whole reason sh_leaf exists beside use_leaf.
;
;   THE DISTANCE. use_seg_hit answers "crosses" with four signs and no divide,
;   so there is no intersection point to read. Instead the RAY LENGTH is binary
;   searched: sh_leaf's answer is monotone in it, and seven halvings of a 1024
;   ray land inside 8 units. Re-running the whole LEAF each time (not just the
;   seg that blocked) is what makes it pick the NEAREST crossing in that leaf --
;   a shorter ray simply stops reaching the farther one. The point kept is the
;   last length that did NOT block, i.e. just in FRONT of the wall: a point
;   inside it belongs to no rendered leaf, and a sprite there is invisible.
;--------------------------------------------------------------
rkw_resume = *
        org ROCKW_BASE
SH_STEP  equ 32                      ; sample spacing. It only has to land in
                                     ;   every subsector the ray crosses -- the
                                     ;   crossing test itself uses the whole ray
SH_NBULL equ 32                      ; 1024 units, same reach as the rocket. It
                                     ;   was 16 on the theory that a puff past
                                     ;   512 is under two pixels and not worth
                                     ;   the samples -- but E1M1's very first
                                     ;   corridor is longer than that, so the
                                     ;   shot that most wants a puff got none.
                                     ;   The cost is bounded elsewhere: pf_shot
                                     ;   will not trace while a puff is showing.
SH_NROCK equ 32                      ; 1024 units, the reach en_march had
SH_NMELEE equ 3                      ; MELEERANGE is 64, and this is 96: the
                                     ;   crossing test needs the ray to pass
                                     ;   THROUGH the line, so a ray that ends
                                     ;   exactly on the wall you are punching
                                     ;   finds nothing. DOOM hits the same
                                     ;   wrinkle and answers it the same way --
                                     ;   A_Saw uses MELEERANGE+1, "so the puff
                                     ;   doesn't skip the flash" (p_pspr.c).
                                     ;   32 is the step, so 96 is the nearest
                                     ;   one up. Still nowhere near a bullet.
SH_REF   equ 7                       ; binary-search steps -> 1024/128 = 8 units

.proc sh_trace
        sta sh_n
        lda zp_px                    ; USE_PT_A = the real player position: the
        sta USE_PT_A                 ;   BSP descent below reads zp_px/zp_py, so
        lda zp_px+1                  ;   the walk borrows them and ?done puts
        sta USE_PT_A+1               ;   them back (try_use's own dance)
        lda zp_py
        sta USE_PT_A+2
        lda zp_py+1
        sta USE_PT_A+3
        lda sh_n                     ; sh_hi = the full ray = n * SH_STEP
        sta sh_hi
        lda #0
        sta sh_hi+1
        ldx #5
?x32    asl sh_hi
        rol sh_hi+1
        dex
        bne ?x32
        lda sh_hi
        sta sh_d
        lda sh_hi+1
        sta sh_d+1
        jsr sh_setb                  ; USE_PT_B = the ray end (a loop constant)
        lda #$FF
        sta USE_SS                   ; no leaf tested yet ($FFFF is not a leaf id)
        sta USE_SS+1
        lda #0
        sta sh_d                     ; sample 0 = the player's own subsector
        sta sh_d+1
?loop   jsr sh_dist                  ; zp_px/zp_py = A + sh_d*(cos,sin)
        jsr use_locate               ; zp_nid = the leaf there
        lda zp_nid
        cmp USE_SS
        bne ?test
        lda zp_nid+1
        cmp USE_SS+1
        beq ?step                    ; same leaf as the last sample: nothing new
?test   lda zp_nid
        sta USE_SS
        lda zp_nid+1
        sta USE_SS+1
        jsr sh_leaf                  ; C=1: a crossed seg stops a bullet
        bcs ?found
?step   clc
        lda sh_d
        adc #SH_STEP
        sta sh_d
        bcc ?nc
        inc sh_d+1
?nc     dec sh_n
        bne ?loop
        lda sh_hi                    ; nothing in reach: the ray END is the point
        sta sh_d                     ;   (out of blast range by construction)
        lda sh_hi+1
        sta sh_d+1
        jsr sh_dist
        clc
        jmp sh_end                   ; C=0: no wall, the point is the ray end
?found  jmp sh_refine                ; the wall is in [0, sh_hi]: the PUFF block
.endp                                ;   has the room, this one has two bytes

; en_rockwall (trace + blast in one) is GONE since 2026-08-05: the two halves
; happen a second apart now -- pj_aim traces for the flight target and pj_hit
; blasts when the rocket gets there (proj.asm).

rkw2_resume = *
        org BOOMAT_BASE
.proc en_boomat
        lda en_k2                    ; --- A_Explode at (en_bx, en_by): en_boom
        pha                          ;     minus en_thing/en_lfind ---
        lda en_k2+1
        pha
        lda en_kind
        pha
        lda #$FF
        sta en_k2                    ; no exploding THING: the sweep skips nobody
        lda #0
        sta en_lp                    ; and no LOS grid
        sta en_lp+1
        sec                          ; --- the player (PIT_RadiusAttack verbatim)
        lda en_bx
        sbc zp_px
        sta m_a
        lda en_bx+1
        sbc zp_px+1
        sta m_a+1
        sec
        lda en_by
        sbc zp_py
        sta m_b
        lda en_by+1
        sbc zp_py+1
        sta m_b+1
        jsr en_dist
        bcc ?things
        jsr en_plr_hurt
?things jsr en_bthings               ; --- and everything else in range
        pla
        sta en_kind
        pla
        sta en_k2+1
        pla
        sta en_k2
        rts
.endp
    .if * > BOOMAT_END+1
        ert 'en_boomat outgrew BOOMAT_BASE..END (memory_map.inc)'
    .endif
        org rkw2_resume
                                     ; (the sh_* variables live with sh_leaf in
                                     ;  the death block -- this one is full)
    .if * > ROCKW_END+1
        ert 'en_rockwall outgrew ROCKW_BASE..END (memory_map.inc)'
    .endif
        org rkw_resume

;--------------------------------------------------------------
; en_plasma -- A_FirePlasma. MT_PLASMA's PIT_CheckThing roll is the rocket's with
;   mobjinfo.damage 5 instead of 20: ((P_Random()&7)+1)*5 = 5..40, and no
;   A_Explode -- the bolt hurts what it hits and nothing else. Same reduction as
;   the rest: it lands the tic it is fired, on the vissprite under the crosshair.
;
;   THE LAST BYTE OF THIS PROC MAY NOT REACH $FFEA (2026-08-11, "I fired the
;   plasma and the game froze"). This block ended at $FFEA and urom_init writes
;   the 65816 NATIVE-mode NMI vector to $FFEA/$FFEB -- on top of the high byte
;   of the `jmp en_plasma2` operand, which turned $8347 into $A847 at every
;   boot. Firing the plasma then jumped into RAM no segment ever loaded. Only
;   the plasma, because this is the one proc whose tail sat on the vector.
;   ENEMY_END is $FFE9 now and the roll below is the 18-byte form so it fits:
;   ((r&7)+1)*5 == (r&7)*5 + 5, and A <= 7 after the mask means neither shift
;   nor either add can carry, so the two CLCs the old version needed are gone.
;--------------------------------------------------------------
.proc en_plasma
        lda RANDOM
        and #7                       ; A <= 7 -> C stays 0 through the whole sum
        sta en_t
        asl
        asl                          ; n*4
        adc en_t                     ; n*5
        adc #5                       ; (n+1)*5 = 5..40
        jmp en_plasma2               ; the hit + the VISIBLE bolt (proj.asm)
.endp

;--------------------------------------------------------------
; PLAN, so the next step does not have to re-derive it:
;   DEATH ANIMATION needs the deathstate chain from info.c (POSS: DIE1..DIE5 at
;   5 tics each, DIE5 tics = -1 = a frozen corpse) plus TH_STATE/TH_TICS arrays --
;   both fit next to TH_HP in bank $01 at $6600/$6700. The tic clock already
;   exists three times over (wp_think, doors, movers all turn dt_vbl into DOOM
;   tics with a Q8 remainder).
;   The REAL cost is VRAM: 5 DIE frames per type, single-rotation, and only the
;   types a level actually spawns -- 3 on E1M1, 5 on E1M6. Free VRAM is ~33 KB
;   against ~18-30 KB of frames, so it fits without room to spare, and the
;   per-level sprite slot (256 sectors) has to grow. MEASURE it before promising.
;--------------------------------------------------------------
    .if * > ENEMY_END+1
        ert 'enemy.asm outgrew ENEMY_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; DEATH ANIMATION -- p_mobj.c P_SetMobjState walking info.c's deathstate chain,
; reduced to a table walk. The frames live in Rapidus bank $01 (DTAB_ROWS,
; pack_things.pack_death); TH_STATE[i] is 0 for a live thing and otherwise the
; row index + 1, so spr_proj resolves a dying thing with one test and one shift.
; The row's own TICS byte ends the chain: $FF = corpse for good, $80|n = play n
; then vanish (the barrel), n = play n then step to the next row.
;==============================================================
enanim_resume = *
        org ENANIM_BASE

;--------------------------------------------------------------
; en_row -- en_k2+1 (a TH_STATE value, row+1) -> zp_ptr = &DTAB_ROWS[row].
;   zp_ptr+2 is already MAP_EXT_BANK (init_level sets it once). Clobbers A.
;--------------------------------------------------------------
.proc en_row
        lda en_k2+1
        sec
        sbc #1
        sta zp_ptr
        lda #0
        sta zp_ptr+1
        asl zp_ptr
        rol zp_ptr+1
        asl zp_ptr
        rol zp_ptr+1
        asl zp_ptr
        rol zp_ptr+1                 ; row * 8
        clc
        lda zp_ptr
        adc #<DTAB_ROWS
        sta zp_ptr
        lda zp_ptr+1
        adc #>DTAB_ROWS
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; en_kill -- Y = thing index, en_kind set. Start the death chain; if this kind
;   has none, fall back to the old behaviour (the thing just stops being drawn).
;--------------------------------------------------------------
.proc en_kill
        sty en_k2
        jsr en_dropmark              ; P_KillMobj's "Drop stuff": the zombieman's
                                     ;   clip / the shotgun guy's gun ride on the
                                     ;   corpse (see the F_DROP note)
        ldy en_k2                    ; (en_dropmark walks the thing table)
        lda #<TH_WROW                ; STOP CHASING, now -- not at the AI's next
        sta zp_ptr                   ;   state expiry. ai_state does notice a dead
        lda #>TH_WROW                ;   thing, but only when its RUN state runs
        sta zp_ptr+1                 ;   out (2-4 tics), and until then the corpse
        lda #0                       ;   keeps taking steps. Clearing TH_WROW is
        sta [zp_ptr],y               ;   what stops it.
                                     ; It stays in the draw table on purpose: the
                                     ; corpse lies where it FELL, and that table is
                                     ; the only thing that draws a thing from the
                                     ; subsector it is actually in rather than the
                                     ; one pack_things sorted it into. Untracking
                                     ; here handed the corpse back to the packed
                                     ; prefix and a body on a staircase was clipped
                                     ; away by geometry it had already walked past.
                                     ; A corpse never moves, so its entry stays
                                     ; correct for good.
        jsr en_gibq                  ; p_inter.c:719: overkill past spawnhealth
                                     ;   goes to xdeathstate instead, and en_gibq
                                     ;   leaves zp_ptr on whichever header won
        ldy en_kind                  ; the per-kind first-row index
        lda [zp_ptr],y
        cmp #$FF
        beq ?none
        clc
        adc #1
        sta en_k2+1
        jsr en_row
        ldy #7
        lda [zp_ptr],y               ; the first row's tics
        and #$3F                     ; bits 6/7 are the A_Explode / last flags
        sta en_t
        lda #<TH_STATE
        sta zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        ldy en_k2
        lda en_k2+1
        sta [zp_ptr],y
        lda #>TH_TICS
        sta zp_ptr+1
        lda en_t
        sta [zp_ptr],y
        rts                          ; the chain runs; A_BossDeath waits for its
                                     ;   LAST frame, which is bd_at's job now
                                     ;   (2026-08-20). This was `jmp en_bossdie`
                                     ;   and it made an M8 end on the instant the
                                     ;   boss lost its last hit point -- 140 tics
                                     ;   before DOOM does, i.e. the spider's whole
                                     ;   death animation, unseen.
?none   ldx en_k2                    ; ...but a kind whose frames did not fit VRAM
        jsr thing_kill               ;   has NO death chain to hang it on, so this
        jmp en_bossdie               ;   exit still fires it off the kill. (Which
.endp                                ;   is why pack_death refuses to ship the
                                     ;   BOSS a chain it had to cut short: full
                                     ;   chain or none, never half of one.)

    .if * > ENANIM_END+1
        ert 'en_row/en_kill outgrew ENANIM_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; en_bossdie -- p_enemy.c A_BossDeath, all three episodes.
;
;   THE GATE. DOOM's is a switch on gameepisode: map 8 of episode 1 fires on
;   MT_BRUISER, of episode 2 on MT_CYBORG, of episode 3 on MT_SPIDER. Nothing
;   else in the game fires it at all -- which is why E3M9's cyberdemon and every
;   baron on E1M1..E1M7 die without the world moving. pack_things.py resolves
;   that switch at PACK time (boss_type_of) and hands the answer over as a KIND
;   BYTE in the .things header at +34, so this is one compare and no episode
;   number anywhere in the engine. It was `cmp #MK_BOSS` until 2026-08-20, when
;   the cyberdemon and the spider stopped being stand-in barons and a constant
;   stopped being able to say it.
;
;   WHAT IT DOES. On episode 1 DOOM fabricates a JUNK LINE tagged 666 and runs
;   EV_DoFloor(lowerFloorToLowest) on the sectors carrying it -- on E1M8 that is
;   sector 22, floor == ceil == 208, the wall between the boss room and the
;   level's ONLY exit. E1M8 has no exit LINEDEF at all: the exit is the
;   special-11 sector behind that wall, which update_damage's damage class 4
;   ends the level on. On episodes 2 and 3 there is no 666 sector and no exit
;   line either -- A_BossDeath falls through to G_ExitLevel and the map simply
;   ENDS on the last boss death. Either way, without this the M8s cannot be
;   finished.
;
;   WHY IT WAS MISSING (episode 1): every other trigger in this engine is found
;   by walking LINEDEFS, and no linedef in the WAD carries tag 666 -- the tag
;   lives on the SECTOR and the line is invented at runtime by the C code.
;   pack_things.py synthesises that record (rooms -32768 and no seg addresses,
;   so neither a walkover nor USE nor a bullet can reach it) and parks its index
;   at THINGS_BASE+31, the count of bosses still standing at +32 and the kind
;   they have to be at +34. Index $FE is the "end the level instead" sentinel.
;
;   DOOM re-walks the thinker list looking for a live boss OF THE SAME TYPE;
;   counting down is the same answer for a tenth of the 6502, and it is exact
;   because en_kill runs exactly ONCE per thing: en_shoot bails on "health 0 ->
;   already dead" and en_bthings skips anything whose TH_STATE is set.
;
;   WHEN. From bd_at, on the tic the boss's death chain reaches its FROZEN row --
;   p_enemy.c hangs A_BossDeath off a state (S_BOSS_DIE7 / S_CYBER_DIE10 /
;   S_SPID_DIE11), never off P_KillMobj, and all three are that corpse row. Until
;   2026-08-20 this fired from en_kill instead, so an M8 ended on the frame the
;   boss ran out of hit points and nobody ever saw the spider mastermind fall
;   over. en_kill's ?none exit STILL fires it off the kill, for a kind whose
;   frames did not fit VRAM and so has no last frame to hang it on; pack_death
;   makes sure that is the only way a BOSS can end up chainless.
;
;   Parked at BOSSDIE_BASE: the ENANIM block en_kill lives in has no room, and
;   this is cold -- one compare per monster death, the body only on a boss.
;--------------------------------------------------------------
bd_resume = *
        org BOSSDIE_BASE
.proc en_bossdie
        lda en_kind                  ; en_kill leaves it set; en_row and the
        cmp THINGS_BASE+34           ;   TH_STATE/TH_TICS stores above do not
        bne ?out                     ;   touch it. +34 = the kind A_BossDeath
                                     ;   fires on HERE (0 = no boss hook, and
                                     ;   en_kind is never 0 for a thing that
                                     ;   reached the death chain)
        lda THINGS_BASE+32           ; bosses still standing. 0 = this level has
        beq ?out                     ;   no record, so nothing to fire -- the
                                     ;   belt to the kind byte's braces
        dec THINGS_BASE+32           ; the blob is re-read on every level load
        bne ?out                     ;   (and on a death restart), so this counter
                                     ;   comes back with it
        lda THINGS_BASE+31           ; the tag-666 record -- fired exactly the way
        cmp #$FE                     ;   a walkover fires one. $FE (2026-08-18) is
        bne ?fire                    ;   pack_things' sentinel for E2M8/E3M8:
        inc EXIT_REQ                 ;   A_BossDeath there is G_ExitLevel, not a
        rts                          ;   666 floor -- main consumes the flag
                                     ;   after the flip, same as an EXIT seg.
                                     ;   INC and not `lda #1 / sta`: 0 -> 1 is
                                     ;   exact here and the block had one byte,
                                     ;   not three. It IS 0 -- the counter above
                                     ;   lets this run once per level, and
                                     ;   pack_things asserts that a map using
                                     ;   the sentinel carries no exit line and
                                     ;   no exit sector, which are the only
                                     ;   other writers.
?fire   sta mv_i                     ;   (mv_i is also what
                                     ;   mv_change reads to find its colour pair)
        lda m_prod                   ; en_bhit parks the blast damage here and
        pha                          ;   en_thrust_bl still wants it after we
        jsr mv_ptr                   ;   return -- mv_ptr uses m_prod as its
        jsr trig_fire                ;   *16 scratch. A barrel CAN kill a baron.
        pla
        sta m_prod
?out    rts
.endp
    .if * > BOSSDIE_END+1
        ert 'en_bossdie outgrew BOSSDIE_BASE..BOSSDIE_END (memory_map.inc)'
    .endif
        org bd_resume

        org ENANIM2_BASE

;--------------------------------------------------------------
; en_adv -- en_k2 = thing, en_k2+1 = the state whose tics just ran out.
;--------------------------------------------------------------
.proc en_adv
        jsr en_row
        ldy #7
        lda [zp_ptr],y
        bmi ?gone                    ; $80|n -> the chain ended: no corpse
        inc en_k2+1                  ; step to the next row
        jsr en_row
        ldy #7
        lda [zp_ptr],y
        cmp #$FF
        beq ?put                     ; $FF -> park here for good
        pha                          ; DOOM runs the state's action on ENTRY:
        and #DT_BOOM                 ;   BEXP D is {A_Explode}, so the blast goes
        beq ?nb                      ;   off here, three frames into the barrel
        jsr en_boom
?nb     pla
        and #$3F
?put    pha                          ; the new row's tics, over the TH_STATE
        lda #<TH_STATE               ;   store -- on the STACK and not in en_t
        sta zp_ptr                   ;   since 2026-08-20. Four bytes cheaper
        lda #>TH_STATE               ;   than the pair of absolute accesses, and
        sta zp_ptr+1                 ;   four is what paid for the jmp below:
        ldy en_k2                    ;   ENANIM2 ends where snd_dispatch begins
        lda en_k2+1                  ;   and had not one byte spare. The push is
        sta [zp_ptr],y               ;   balanced over straight-line code (the
        lda #>TH_TICS                ;   only jsr on this path, en_boom, is
        sta zp_ptr+1                 ;   already above with a pha/pla of its own)
        pla
        sta [zp_ptr],y
        jmp bd_at                    ; was the row we just entered the FROZEN
                                     ;   one? Then it is info.c's last death
                                     ;   frame and A_BossDeath goes off there
?gone   lda #<TH_STATE
        sta zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        ldy en_k2
        lda #0
        sta [zp_ptr],y               ; back to "not animating"...
        ldx en_k2
        jmp thing_kill               ;   ...and gone from the world
.endp

;--------------------------------------------------------------
; bd_at -- en_adv's tail: A = the tics byte it just stored, Y = en_k2 (the
;   thing), zp_ptr = TH_TICS. p_enemy.c does not hang A_BossDeath off the KILL,
;   it hangs it off a STATE -- S_BOSS_DIE7, S_CYBER_DIE10, S_SPID_DIE11 -- and
;   all three are the `-1 tics` corpse row at the end of the chain, which is
;   DT_FREEZE here. So "the row we just entered is $FF" IS "the death animation
;   reached its last frame", and that is the whole test.
;
;   It costs every OTHER corpse in the game one compare, once, on the tic it
;   stops moving -- and the two bytes en_adv spent are the two ENANIM2 had.
;
;   TH_KIND and not en_kind_of: en_kfill prefills it for EVERY thing at level
;   init, so a boss killed in its sleep answers as well as one that charged, and
;   the lookup is two instructions instead of a sprite-table walk (which would
;   also have eaten en_k2 -- en_tick still needs it when we return).
;
;   Parked out of the block because ENANIM2 has NOTHING left: en_adv ends at
;   $BD49 and snd_dispatch starts at $BD4A. (ENANIM2_END says $BD7F and has been
;   wrong since the day sound.asm claimed that run -- do not trust it.)
;--------------------------------------------------------------
bdat_resume = *
        org BDAT_BASE
.proc bd_at
        cmp #$FF                     ; DT_FREEZE: the corpse row, i.e. the last
        beq ?boss                    ;   death frame -- every other row just ran
        rts
?boss   lda #>TH_KIND                ; zp_ptr's low byte is still 0: every
        sta zp_ptr+1                 ;   per-thing AI page is 256 B aligned and
        lda [zp_ptr],y               ;   en_adv left it pointing at TH_TICS
        sta en_kind
        jmp en_bossdie               ; ...which answers "not the boss" for all
.endp                                ;   but three things in the whole game
    .if * > BDAT_END+1
        ert 'bd_at outgrew BDAT_BASE..BDAT_END (memory_map.inc)'
    .endif
        org bdat_resume

;--------------------------------------------------------------
; en_tick -- one DOOM tic of every dying thing. Called from the game loop.
;   Parked at ENTICK_BASE: the trimmed idle path grew it out of ENANIM2.
;--------------------------------------------------------------
entick_resume = *
        org ENTICK_BASE
.proc en_tick
        lda #<TH_STATE               ; the live path is trimmed like ai_tick's:
        sta zp_ptr                   ;   one read and the loop step, no page
        lda #>TH_STATE               ;   reload until something is dying
        sta zp_ptr+1
        ldy #0
?lp     lda [zp_ptr],y
        bne ?dying
?next   iny
        bne ?lp
        jmp an_tick                  ; the idle rings ride the SAME DOOM tic
                                     ;   (sprites.asm). Chained, not a second jsr
                                     ;   in wp_think: that block is full
?dying  sta en_k2+1
        lda #>TH_TICS
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp #$FF
        beq ?back                    ; the corpse: nothing left to do
        sec
        sbc #1
        sta [zp_ptr],y
        bne ?back
        sty en_k2                    ; the row is over -> next frame
        jsr en_adv
        ldy en_k2
        lda #<TH_STATE               ; en_adv walked pages of its own
        sta zp_ptr
?back   lda #>TH_STATE
        sta zp_ptr+1
        jmp ?next
.endp
    .if * > ENTICK_END+1
        ert 'en_tick outgrew ENTICK_BASE..END (memory_map.inc)'
    .endif
        org entick_resume

    .if * > ENANIM2_END+1
        ert 'en_adv/en_tick outgrew ENANIM2_BASE..END (memory_map.inc)'
    .endif
        org ENBOOM_BASE

;--------------------------------------------------------------
; en_boom -- A_Explode: P_RadiusAttack(spot, ..., 128) reduced to the player.
;   PIT_RadiusAttack verbatim: dx/dy are absolute, dist is the LARGER of the two
;   (Chebyshev, not Euclidean), thing->radius comes off it, negatives clamp to 0,
;   dist >= bombdamage is out of range, and the damage is bombdamage - dist.
;   SIGHT: en_lfind picks up this barrel's precomputed visibility grid (bank $01,
;   tools/pack_los.py) and en_dist consults it for every candidate, so the blast
;   stops at a wall the way PIT_RadiusAttack's P_CheckSight makes it.
;   en_k2 = the exploding thing. Clobbers A/Y, m_a, m_b, m_prod, sp_ptr.
;--------------------------------------------------------------
.proc en_boom
        lda en_k2                    ; en_tick/en_adv own these -- the sweep below
        pha                          ;   calls en_kill, which reuses them
        lda en_k2+1
        pha
        lda en_kind
        pha
        jsr en_thing                 ; sp_ptr = the exploding thing's record
        ldy #0                       ; remember where the blast went off
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
        jsr en_lfind                 ; this barrel's sight grid -> en_lp (en_dist
                                     ;   reads it for the player AND the sweep)
        sec                          ; --- the player
        lda en_bx
        sbc zp_px
        sta m_a
        lda en_bx+1
        sbc zp_px+1
        sta m_a+1
        sec
        lda en_by
        sbc zp_py
        sta m_b
        lda en_by+1
        sbc zp_py+1
        sta m_b+1
        jsr en_dist
        bcc ?things
        jsr en_plr_hurt
?things jsr en_bthings               ; --- and everything else in range
        pla
        sta en_kind
        pla
        sta en_k2+1
        pla
        sta en_k2
        rts
.endp

    .if * > ENBOOM_END+1
        ert 'en_boom outgrew ENBOOM_BASE..END (memory_map.inc)'
    .endif
enboom_resume = *
        org ENTHING_BASE

;--------------------------------------------------------------
; en_thing -- the exploding thing (en_k2) -> sp_ptr = its 8-byte record;
;   en_th2 is the same from an index already in A.
;--------------------------------------------------------------
ensolid_resume = *
        org THCOLL_BASE
;--------------------------------------------------------------
; en_solid -- p_map.c PIT_CheckThing, reduced to the half this port can hit:
;   the MF_SOLID block test. Monsters used to walk through the player and
;   through each other because nothing ever ran it.
;   IN : coll_cx/coll_cy = the candidate position, sol_self = the thing that is
;        moving ($FF = the player)
;   OUT: A/Z nonzero = something solid is already there
;
;   DOOM's test is a SQUARE, not a circle:
;       blockdist = thing->radius + tmthing->radius;
;       if (abs(thing->x - tmx) >= blockdist || abs(thing->y - tmy) >= blockdist)
;           return true;                          // didn't hit it
;   i.e. BOTH axes have to be inside to block. Kept verbatim -- a circle test
;   would let a monster corner-clip through a doorway that DOOM keeps shut.
;
;   Not solid: radius 0 (pickups, player starts -- pack_things only gives a
;   radius to C_MONSTER and C_OBSTACLE), a cleared THING_ALIVE bit (picked up,
;   exploded), and TH_STATE != 0 -- that is the death chain, and P_KillMobj
;   clears MF_SOLID, so corpses are walk-through here too.
;--------------------------------------------------------------
.proc en_solid
        lda #<TH_RAD                 ; every per-thing page is 256 B aligned, so
        sta zp_ptr                   ;   the low byte is 0 for all of them and
        lda #>TH_RAD                 ;   only zp_ptr+1 moves below
        sta zp_ptr+1                 ;   (zp_ptr+2 = MAP_EXT_BANK, set by init_level)
        lda sol_self
        cmp #$FF
        bne ?mrad
        lda #MK_PLRAD                ; the player's own radius (info.c MT_PLAYER)
        bne ?haver                   ;   -- 16, so never the zero branch
?mrad   ldy sol_self
        lda [zp_ptr],y
?haver  sta sol_rad
        lda sol_self                 ; --- the player is a solid thing too,
        cmp #$FF                     ;     unless it is the one moving
        beq ?things
        lda #MK_PLRAD
        jsr ?bdist
        lda zp_px
        sta sol_ox
        lda zp_px+1
        sta sol_ox+1
        lda zp_py
        sta sol_oy
        lda zp_py+1
        sta sol_oy+1
        jsr ?hit
        beq ?things
        jmp ?yes
        ; --- p_maputl.c P_BlockThingsIterator: the 3x3 cells around the target
        ;     and nothing else. The sweep used to read the RECORD of all 255
        ;     things (34k cycles, paid by every walking monster per step).
?things jsr blk_tgt                  ; which cell is the target in?
        lda #0
        sta sol_n
?cell   ldx sol_n
        lda sol_cx
        clc
        adc blk_ox,x
        and #7
        sta sol_c
        lda sol_cy
        clc
        adc blk_oy,x
        and #7
        asl
        asl
        asl
        ora sol_c
        tay
        lda #>BLK_HEAD
        sta zp_ptr+1
        lda [zp_ptr],y               ; the first thing filed in that cell
?item   cmp #$FF
        beq ?ncell
        sta sol_i
        cmp sol_self                 ; p_map.c: "don't clip against self"
        beq ?nitem
        ldy sol_i
        lda #>TH_RAD
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?nitem                   ; radius 0 -> not MF_SOLID
        sta sol_or
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?nitem                   ; dying / a corpse -> MF_SOLID is gone
        ldx sol_i
        jsr ?alive
        beq ?nitem                   ; removed from the level
        lda sol_or
        jsr ?bdist
        lda sol_i
        jsr en_thing.en_th2          ; sp_ptr = its record (x @ +0, y @ +2)
        ldy #0
        lda (sp_ptr),y
        sta sol_ox
        iny
        lda (sp_ptr),y
        sta sol_ox+1
        iny
        lda (sp_ptr),y
        sta sol_oy
        iny
        lda (sp_ptr),y
        sta sol_oy+1
        jsr ?hit
        beq ?nitem
        jmp ?yes
?nitem  ldy sol_i                    ; ...next thing in the same cell
        lda #>TH_BNEXT
        sta zp_ptr+1
        lda [zp_ptr],y
        jmp ?item
?ncell  inc sol_n
        lda sol_n
        cmp #9
        bcs ?no
        jmp ?cell
?no     lda #0
        rts
?yes    lda #1
        rts
;   A = the other radius -> sol_bd = blockdist (16-bit: 128+128 overflows a byte)
?bdist  clc
        adc sol_rad
        sta sol_bd
        lda #0
        adc #0
        sta sol_bd+1
        rts
;   sol_ox/sol_oy vs coll_cx/coll_cy against sol_bd. A nonzero = blocked.
?hit    sec
        lda sol_ox
        sbc coll_cx
        sta m_a
        lda sol_ox+1
        sbc coll_cx+1
        sta m_a+1
        jsr ?absa
        sec                          ; |dx| >= blockdist -> DOOM's early "no hit"
        lda m_a
        sbc sol_bd
        lda m_a+1
        sbc sol_bd+1
        bcs ?miss
        sec
        lda sol_oy
        sbc coll_cy
        sta m_a
        lda sol_oy+1
        sbc coll_cy+1
        sta m_a+1
        jsr ?absa
        sec
        lda m_a
        sbc sol_bd
        lda m_a+1
        sbc sol_bd+1
        bcs ?miss
        lda #1
        rts
?miss   lda #0
        rts
?absa   lda m_a+1                    ; m_a = |m_a|
        bpl ?ap
        jsr m_neg
?ap     rts
;   X = thing index -> A/Z = its THING_ALIVE bit (thing_kill clears it)
?alive  txa
        and #7
        tay
        txa
        lsr
        lsr
        lsr
        tax
        lda THING_ALIVE,x
        and mv_bit,y
        rts
.endp



sol_self dta 0                       ; who is moving ($FF = the player)
sol_rad dta 0                        ;   ...and its info.c radius
sol_i   dta 0                        ; sweep index
sol_or  dta 0                        ; the candidate blocker's radius
sol_bd  dta 0,0                      ; blockdist = the two radii (max 128+128)
sol_ox  dta 0,0                      ; the blocker's position
sol_oy  dta 0,0
sol_n   dta 0                        ; which of the nine cells the sweep is on
sol_c   dta 0                        ;   ...and that cell's index, being built
radf_resume = *
        org RADFILL_BASE
;--------------------------------------------------------------
; en_radfill -- from en_init: TH_RAD[thing] = its PIT_CheckThing radius, for
;   every thing on the level. The rule rad_of applies is checked at BUILD time
;   by tools/pack_things.py _check_radius_rule.
;--------------------------------------------------------------
.proc en_radfill
        lda th_things
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        lda #<TH_RAD
        sta zp_ptr
        lda #>TH_RAD
        sta zp_ptr+1
        lda #0
        sta sol_i
?l      lda sol_i
        cmp THINGS_BASE
        bcs ?done
        jsr rad_of
        ldy sol_i
        ldx #>TH_RAD
        stx zp_ptr+1
        sta [zp_ptr],y
        clc
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inc sol_i
        bne ?l
?done   rts
.endp
    .if * > RADFILL_END+1
        ert 'en_radfill outgrew RADFILL_BASE..END (memory_map.inc)'
    .endif

        org RADOF_BASE
;--------------------------------------------------------------
; rad_of -- sp_ptr = a thing record -> A = its PIT_CheckThing radius. The
;   classification half of en_radfill (see there); it lives out here because
;   the THCOLL block is full to the byte. Clobbers A/X/Y and en_kind/en_k2.
;--------------------------------------------------------------
.proc rad_of
        ldy #7                       ; record +7 = flags
        lda (sp_ptr),y
        and #1
        bne ?zero                    ; a pickup: walk through it
        ldy #6                       ; record +6 = sprite id
        lda (sp_ptr),y
        jsr en_kind_of               ; en_kind = 0 for anything not a monster
        ldy en_kind
        beq ?obs
        lda mk_rad,y
        rts                          ; (no real kind has radius 0)
?obs    ldy #7
        lda (sp_ptr),y
        and #2
        beq ?zero                    ; not an obstacle either
        lda #MK_OBSTR
        rts
?zero   lda #0
        rts
.endp
    .if * > RADOF_END+1
        ert 'rad_of outgrew RADOF_BASE..END (memory_map.inc)'
    .endif

        org BLKTAB_BASE
blk_ox  dta $FF,0,1,$FF,0,1,$FF,0,1  ; en_solid's 3x3 neighbourhood (wrapped)
blk_oy  dta $FF,$FF,$FF,0,0,0,1,1,1
    .if * > BLKTAB_END+1
        ert 'the blockmap tables outgrew BLKTAB_BASE..END (memory_map.inc)'
    .endif
        org radf_resume



    .if * > THCOLL_END+1
        ert 'en_solid outgrew THCOLL_BASE..THCOLL_END (memory_map.inc)'
    .endif
        org ensolid_resume

.proc en_thing
        lda en_k2
en_th2  sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc th_things
        sta sp_ptr
        lda m_prod+1
        adc th_things+1
        sta sp_ptr+1
        rts
.endp
    .if * > ENTHING_END+1
        ert 'en_thing outgrew ENTHING_BASE..END (memory_map.inc)'
    .endif
        org enboom_resume

        org ENDIST_BASE

;--------------------------------------------------------------
; en_dist -- PIT_RadiusAttack's test, verbatim. IN m_a/m_b = signed dx/dy.
;   OUT C=1 and A = bombdamage - dist, or C=0 = out of range.
;   PIT_RadiusAttack opens with `if (!P_CheckSight (thing, bombspot)) return`,
;   so the sight bit is tested here too -- it has to happen BEFORE the absolute
;   values below eat the signs, and putting it here gets both callers (the
;   player in en_boom, every thing in en_bthings) with one line.
;--------------------------------------------------------------
.proc en_dist
        jsr en_los
        bcs ?see
        rts                          ; blocked: C=0 reads as "out of range"
?see    lda m_a+1
        bpl ?dx
        jsr m_neg
?dx     lda m_b+1
        bpl ?dy
        jsr m_negb
?dy     lda m_b+1                    ; dist = the LARGER of the two (Chebyshev)
        cmp m_a+1
        bcc ?max
        bne ?useb
        lda m_b
        cmp m_a
        bcc ?max
?useb   lda m_b
        sta m_a
        lda m_b+1
        sta m_a+1
?max    lda m_a+1
        bne ?out                     ; >= 256 units: nowhere near
        lda m_a
        sec
        sbc #BOOM_R                  ; dist -= radius, clamped at 0
        bcs ?pos
        lda #0
?pos    cmp #BOOM_DMG
        bcs ?out                     ; dist >= bombdamage -> out of range
        sta m_b
        sec
        lda #BOOM_DMG
        sbc m_b
        rts                          ; C=1 from the sbc chain
?out    clc
        rts
.endp
;--------------------------------------------------------------
; coll_mon -- the AI's wall probe: collide_blocked at the KIND's radius.
;   ai_step calls this where it called collide_blocked, same three bytes.
;   Parked in this block because collision.asm's own two are full; it is one
;   absolute jsr either way.
;--------------------------------------------------------------
.proc coll_mon
        ldx ai_k                     ; info.c radius -> the power-of-two bucket
        lda mk_rad,x
        ldy #0
        cmp #32                      ; ROUND DOWN, never up: at R32 a demon is
        bcc ?set                     ;   64 wide and DOOM's 64-unit doorways
        ldy #1                       ;   would stop letting it through, which is
        cmp #128                     ;   a fault DOOM has not got. Rounding down
        bcc ?set                     ;   can only ever be MORE permissive than
        ldy #3                       ;   DOOM, the direction this port was
                                     ;   already wrong in -- so nothing that
                                     ;   moves today stops moving.
                                     ; 16,20,24,30,31 -> R16   40 -> R32
                                     ; 128            -> R128 (exact)
?set    sty coll_k
        lda coll_rtab,y
        sta coll_rp1
        jmp collide_blocked
.endp

    .if * > ENDIST_END+1
        ert 'en_dist outgrew ENDIST_BASE..END (memory_map.inc)'
    .endif
        org enboom_resume
    .if * > ENBOOM_END+1
        ert 'en_boom outgrew ENBOOM_BASE..END (memory_map.inc)'
    .endif
        org ENBVAR_BASE
en_bx   dta 0,0                      ; where the blast went off
en_by   dta 0,0
en_bi   dta 0                        ; the sweep's thing index
en_bself dta 0                       ; ...and the exploding thing, so it is skipped
en_lp   dta 0,0                      ; this blast's LOS record in bank $01 (0 = none)
en_lt   dta 0,0                      ; en_los: the 16-bit cell arithmetic
en_lt2  dta 0                        ; en_los: the byte offset inside the row
    .if * > ENBVAR_END+1
        ert 'en_boom scratch outgrew ENBVAR_BASE..END (memory_map.inc)'
    .endif
        org ENLOS_BASE

;--------------------------------------------------------------
; en_los -- P_CheckSight for the blast, read straight out of the grid en_lfind
;   found. IN m_a/m_b = the SIGNED (blast - target) deltas, which is what
;   en_dist has in hand before it takes their absolute values.
;   OUT C=1 = the target is visible (or this thing has no grid, so nothing is
;   restricted and the old behaviour stands). m_a/m_b are preserved.
;   Clobbers A/X/Y, en_lt/en_lt2 and zp_ptr (zp_ptr+2 is already MAP_EXT_BANK --
;   init_level sets it and nothing else writes it).
;   A target outside the blast square lands on a meaningless cell; the shifts are
;   16-bit so the read still stays inside the record, and en_dist's own range
;   test throws it away right after. Cold: once per candidate per explosion.
;--------------------------------------------------------------
.proc en_los
        lda en_lp
        ora en_lp+1
        bne ?go
        sec                          ; no grid for this thing -> everything visible
        rts
?go     lda m_a
        ldx m_a+1
        jsr ?cell                    ; A = column
        pha
        lsr
        lsr
        lsr                          ; col >> 3 = which byte of the row
        sta en_lt2
        lda m_b
        ldx m_b+1
        jsr ?cell                    ; A = row
        asl
        asl                          ; * LOS_ROW (4 -- that is why it is 4)
        clc
        adc en_lt2
        adc #2                       ; past the record's index byte + pad
        tay
        lda en_lp
        sta zp_ptr
        lda en_lp+1
        sta zp_ptr+1
        pla
        and #7                       ; the bit, counted from the MSB: shift it
        tax                          ;   out through carry rather than build a
        inx                          ;   mask -- (col&7)+1 ASLs land it in C
        lda [zp_ptr],y
?rot    asl
        dex
        bne ?rot
        rts
; A/X = a signed (blast - target) delta -> A = its cell, (LOS_BIAS - d) >> 4.
; d is in -143..143 for anything the blast can reach, so the result is 0..18.
?cell   sta en_lt
        stx en_lt+1
        sec
        lda #LOS_BIAS
        sbc en_lt
        sta en_lt
        lda #0
        sbc en_lt+1
        sta en_lt+1
        ldx #4                       ; >> 4 = 16 world units per cell
?sh     lsr en_lt+1
        ror en_lt
        dex
        bne ?sh
        lda en_lt
        rts
.endp
    .if * > ENLOS_END+1
        ert 'en_los outgrew ENLOS_BASE..END (memory_map.inc)'
    .endif
        org ENLFIND_BASE

;--------------------------------------------------------------
; en_lfind -- en_k2 = the exploding thing -> en_lp = its LOS record in bank $01,
;   or 0 if it has none: not a barrel at all, or the level had more barrels than
;   LOS_NMAX, in which case en_los lets everything through and that one barrel
;   blasts through walls like the whole game used to. Once per explosion.
;   Clobbers A/X/Y and zp_ptr.
;--------------------------------------------------------------
.proc en_lfind
        lda #<LOS_EXT
        sta zp_ptr
        lda #>LOS_EXT
        sta zp_ptr+1
        ldy #0                       ; +0 of every record = the thing index
        ldx #LOS_NMAX
?rec    lda [zp_ptr],y
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
        lda #0
        sta en_lp
        sta en_lp+1
        rts
?found  lda zp_ptr
        sta en_lp
        lda zp_ptr+1
        sta en_lp+1
        rts
.endp
    .if * > ENLFIND_END+1
        ert 'en_lfind outgrew ENLFIND_BASE..END (memory_map.inc)'
    .endif
        org ENBTH_BASE

;--------------------------------------------------------------
; en_bthings -- the rest of P_RadiusAttack: every OTHER shootable thing in range
;   takes bombdamage - dist, and dies into its own chain if that finishes it.
;   That is what makes barrels set each other off, exactly as DOOM does -- and
;   en_dist's sight test (en_los) is what keeps the chain from jumping a wall
;   into the next room.
;--------------------------------------------------------------
.proc en_bthings
        lda en_k2
        sta en_bself                 ; en_kind_of below reuses en_k2 as scratch
        lda #0
        sta en_bi
?lp     lda en_bi
        cmp THINGS_BASE              ; thing count
        bcs ?done
        cmp en_bself
        beq ?next
        ldy en_bi
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
        lda en_bi
        jsr en_thing.en_th2
        ldy #0
        sec
        lda en_bx
        sbc (sp_ptr),y
        sta m_a
        iny
        lda en_bx+1
        sbc (sp_ptr),y
        sta m_a+1
        ldy #2
        sec
        lda en_by
        sbc (sp_ptr),y
        sta m_b
        iny
        lda en_by+1
        sbc (sp_ptr),y
        sta m_b+1
        jsr en_bdist                 ; PIT_RadiusAttack's boss exemption, THEN
        bcc ?next                    ;   its range test (enemy_ai.asm). Same
        jsr en_bhit                  ;   three bytes the `jsr en_dist` here used
        jsr en_thrust_bl             ;   to be, which is all this block had.
?next   inc en_bi                    ;   ...and P_DamageMobj's kick, if it lived
        bne ?lp
?done   rts
.endp
    .if * > ENBTH_END+1
        ert 'en_bthings outgrew ENBTH_BASE..END (memory_map.inc)'
    .endif
        org ENBHIT_BASE

;--------------------------------------------------------------
; en_bhit -- A = damage, en_bi = the thing. P_DamageMobj's arithmetic only.
;--------------------------------------------------------------
.proc en_bhit
        sta m_prod
        ldy en_bi
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
        bne ?out
        jmp en_bkill                 ; it died: hand it its own chain
?out    rts
.endp
    .if * > ENBHIT_END+1
        ert 'en_bhit outgrew ENBHIT_BASE..END (memory_map.inc)'
    .endif
        org ENBKILL_BASE

;--------------------------------------------------------------
; en_bkill -- the blast finished off thing en_bi: give it its voice and its
;   death chain, the same two steps a bullet kill takes.
;--------------------------------------------------------------
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

engib_resume = *
        org OVKILL_BASE
;--------------------------------------------------------------
; en_ovkill -- P_DamageMobj's tail, for both damage sites: en_t is the health
;   the subtraction just produced. Health still ABOVE zero -> return, touching
;   nothing. Health <= 0 -> en_ovk = -en_t (the overkill p_inter.c:719 gibs on)
;   and then the clamp to 0 both sites used to do inline.
;   Clobbers A.
;
;   THE <= 0 TEST LIVES HERE NOW (2026-08-11, "the shotgun sometimes gibs
;   them"). Both callers used to make the call on the BORROW alone -- `bcs
;   ?store`, commented "no borrow -> still above zero". It is not: a hit that
;   lands health on EXACTLY ZERO borrows nothing, and p_inter.c:707 kills on
;   `health <= 0`. So that kill ran with an en_ovk left over from the PREVIOUS
;   one and en_gibq gibbed it with, typically, a rocket's overkill. The shotgun
;   showed it because it rolls 5/10/15 seven times in one shot, so bringing a
;   20 hp zombieman to exactly 0 is ordinary. Zero in gives overkill 0 here,
;   which is DOOM: `0 < -20` is false, so it dies the plain way.
;   Parked at OVKILL_BASE because the ENGIB block is full to the byte and the
;   enemy block now stops at $FFE9 (the 65816 native vectors).
;--------------------------------------------------------------
.proc en_ovkill
        lda en_t+1                   ; > 0 -> nothing died: leave en_ovk alone
        bmi ?kill                    ;   (negative: always a kill)
        ora en_t
        bne ?out                     ; exactly zero falls through -- it IS a kill
?kill   sec
        lda #0
        sbc en_t
        sta en_ovk
        lda #0
        sbc en_t+1
        sta en_ovk+1
        lda #0                       ; ...and only now clamp (DOOM's <= 0 test)
        sta en_t
        sta en_t+1
?out    rts
.endp
    .if * > OVKILL_END+1
        ert 'en_ovkill outgrew OVKILL_BASE..END (memory_map.inc)'
    .endif
        org ENGIB_BASE               ; kill-time only, and every block around
                                     ; en_bhit/en_bkill is full
;--------------------------------------------------------------
; en_gibq -- en_gib = 1 iff this kill is p_inter.c:719's:
;     health - damage < -spawnhealth   <=>   overkill > spawnhealth
;   AND info.c gives the kind an xdeathstate at all (XTAB_EXT != $FF). Runs
;   with en_kind already resolved; idempotent, so both kill paths may call it.
;   Clobbers A/Y.
;
;   IT ALSO QUEUES THE CRY (2026-08-19, "a barrel/rocket kill still yells the
;   ordinary death sound"). info.c hangs A_Scream off the plain S_x_DIE chain
;   and A_XScream off S_x_XDIE, and p_enemy.c:1572 is the whole of A_XScream:
;       void A_XScream (mobj_t* actor) { S_StartSound (actor, sfx_slop); }
;   -- one fixed sound, no family roll, and it REPLACES the death cry rather
;   than joining it. en_die_snd only ever knew the A_Scream side, so a gibbed
;   zombieman screamed podth1..3 while it came apart. Doing it HERE and not in
;   en_die_snd is what makes both kill paths right without a byte at either
;   call site: en_kill runs en_gibq last on both of them (the bullet path calls
;   en_die_snd first, en_bkill calls it in between), so this store is the one
;   that survives into the frame's single voice slot.
;   Doom 1 gives an xdeathstate to exactly three monsters -- zombieman, shotgun
;   guy, imp (info.c S_POSS/SPOS/TROO_XDIE1) -- plus the player; every other
;   kind keeps $FF here and never reaches this store.
;
;   The block was full to the byte, so the room came from DTAB_EXT and
;   XTAB_EXT sharing page $8C: the high half of the pointer is the same for
;   both chains and is written once, before the split, instead of twice after
;   it -- and `ldy en_kind` now serves the mk_hp compare AND the chain lookup.
;--------------------------------------------------------------
.proc en_gibq
        lda #0
        sta en_gib
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
        sta en_snd_q
        rts                          ; zp_ptr already on XTAB_EXT
?no     lda #<DTAB_EXT               ; the ordinary chain, and en_kill reads
        sta zp_ptr                   ;   zp_ptr straight out of here
        rts
.endp
    .if * > ENGIB_END+1
        ert 'en_ovkill/en_gibq outgrew ENGIB_BASE..END (memory_map.inc)'
    .endif
        org engib_resume
    .if * > ENBKILL_END+1
        ert 'en_bkill outgrew ENBKILL_BASE..END (memory_map.inc)'
    .endif
        org ENHURT_BASE

;--------------------------------------------------------------
; en_plr_hurt -- A = damage to the player. P_DamageMobj for the player, and the
;   ONLY one: update_damage (the nukage floors) comes through here too now, so
;   there is one death path, one grunt and one armour split for every source.
;   The armour itself is pl_armsub's (movers.asm, next to update_damage -- this
;   block has no room for it). Death restarts the level.
;--------------------------------------------------------------
.proc en_plr_hurt
        tay                          ; the damage, across the two tests below
        lda pl_dead                  ; P_DamageMobj's second line: "if
        bne ?out                     ;   (target->health <= 0) return" -- a barrel
                                     ;   can still go off next to the corpse, and
                                     ;   without this it would grunt for it
        lda PW_INVUL                 ; ...and its invulnerability test: "damage
        ora PW_INVUL+1               ;   < 1000 && powers[pw_invulnerability]"
        bne ?out                     ;   -> the hit does nothing at all
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
?out    rts                          ;   and a keypress restarts (pl_death.asm).
                                     ;   pl_dieq, not pl_die: A is still
                                     ;   health - damage and the carry above is
                                     ;   the only place that number survives, so
                                     ;   the gib test (p_inter.c:719, -100 for
                                     ;   MT_PLAYER) has to be made from here.
                                     ;   Costs this block nothing: same jmp, and
                                     ;   ENHURT is full to the byte.
.endp
    .if * > ENHURT_END+1
        ert 'en_plr_hurt outgrew ENHURT_BASE..END (memory_map.inc)'
    .endif
        org SPRDYN_BASE

;--------------------------------------------------------------
; spr_dyn -- A = thing index. If the thing is DYING, copy its current death row
;   out of bank $01 into sp_drow and point sp_tab at it, returning C=1: the
;   caller then reads an ordinary 8-byte sprite-table row and needs no other
;   change. C=0 = a live thing, use the real sprite table. Preserves X.
;   zp_ptr is saved/restored -- the BSP walk owns it while spr_add runs.
;--------------------------------------------------------------
.proc spr_dyn
        stx sp_dsx
        tax
        lda zp_ptr
        pha
        lda zp_ptr+1
        pha
        lda #0                       ; default: no mirrored view (spr_wrot sets
        sta sp_dflip                 ;   it; the death path must not inherit one)
        lda #<TH_STATE
        sta zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        txa
        tay
        lda [zp_ptr],y
        bne ?row                     ; dying: TH_STATE is the death row+1
        lda #>TH_WROW                ; not dying -- is it CHASING? TH_WROW is the
        sta zp_ptr+1                 ;   walk row+1, and a walk row IS a death row:
        lda [zp_ptr],y               ;   same 8 bytes in the same DTAB_ROWS array,
        beq ?live                    ;   so everything below reads it unchanged.
                                     ;   (Both pages are 256 B aligned and share
                                     ;   the low byte, so only zp_ptr+1 moves.)
        jsr spr_wrot                 ; + the rotation slot for how it faces the
                                     ;   viewer (walk and attack rows both --
                                     ;   DOOM's attack frames rotate too)
?row    sta en_k2+1
        jsr en_row                   ; zp_ptr -> DTAB_ROWS + row*8
        ldy #7
?cp     lda [zp_ptr],y
        sta sp_drow,y
        dey
        bpl ?cp
        jsr wrot_left                ; a mirrored view anchors from its other
                                     ;   edge (r_things.c: tx -= width - offset)
                                     ; (the frame id in the copied row's byte 0
                                     ;   is all spr_one's spr_fget needs -- the
                                     ;   T4-era directory hook died with B1)
        lda #<sp_drow
        sta sp_tab
        lda #>sp_drow
        sta sp_tab+1
        pla
        sta zp_ptr+1
        pla
        sta zp_ptr
        ldx sp_dsx
        sec
        rts
?live   jsr wrot_idle                ; an IDLE monster faces its SPAWN angle
        bcs ?row                     ;   (walk image 0's rotation group)
        pla
        sta zp_ptr+1
        pla
        sta zp_ptr
        ldx sp_dsx
        clc
        rts
.endp
sp_drow dta 0,0,0,0,0,0,0,0
sp_dsx  dta 0
    .if * > SPRDYN_END+1
        ert 'spr_dyn outgrew SPRDYN_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; spr_wrot -- A = TH_WROW (walk row+1; ai_setrow already multiplied the image
;   by NSTOR), Y = thing index, zp_ptr = a bank-$01 page pointer (lo byte 0).
;   Returns A = row+1 + the ROTATION SLOT for how the thing faces the viewer,
;   and sets sp_dflip bit7 when the view is a MIRRORED one (DOOM rots 6 and 7).
;   rot = (octant(viewer-thing) - TH_DIR) & 7 with octant() = sign quadrant +
;   |dx| vs |dy|*2.25 compares, and viewer-thing = -(zp_rx, zp_ry), i.e.
;   octant(zp_rx, zp_ry) + 4 -- which is r_things.c's
;   `(R_PointToAngle(thing) - thing->angle + ANG45/2*9) >> 29` in octants.
;   Attack rows (TH_MODE bit0: those have no rotation neighbours), front-only
;   builds (wrot_nst != 4) and DI_NODIR things return A unchanged; sp_dflip
;   was cleared by spr_dyn. Preserves Y (the thing index). X is free here.
;--------------------------------------------------------------
wrot_resume = *
        org WROT_BASE
.proc spr_wrot
        sta swr_row
        lda sp_dfix                  ; draw-time REPLAY: spr_one hands back the
        cmp #$FF                     ;   byte chosen at projection ($FF = fresh
        beq ?live                    ;   zp_rx/ry, compute it now)
        sta sp_dflip
        and #$03
        clc
        adc swr_row
        rts
?live   lda wrot_nst                 ; 4 stored views, or a front-only build?
        cmp #4                       ;   (attack rows rotate exactly like walk
        bne ?out                     ;   rows since 2026-08-03 -- DOOM's attack
                                     ;   frames carry rotations too, and the
                                     ;   packer stores them state-major x 3)
        lda #>TH_DIR
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp #8                       ; DI_NODIR -> keep the front view
        bcc ?go
?out    lda swr_row                  ; the epilogue sits UP HERE: the octant
        rts                          ;   body below is past branch range
?go     sta swr_dir
        sty swr_y
        lda zp_rx                    ; the viewer-relative vector spr_proj
        sta swr_vx                   ;   computed (thing - player)
        lda zp_rx+1
        sta swr_vx+1
        lda zp_ry
        sta swr_vy
        lda zp_ry+1
        sta swr_vy+1
        jsr oct_of                   ; A = its octant, 0..7
        clc                          ; rot = (octant + 4 - TH_DIR) & 7: the +4
        adc #4                       ;   is the 180-deg flip (thing->viewer)
        sec                          ;   DOOM's formula folds in
        sbc swr_dir
        and #7
        tax
        lda swr_rot4,x               ; -> slot (bits 0-1) + flip (bit 7)
        sta sp_dflip
        and #$03
        clc
        adc swr_row
        ldy swr_y
        rts
.endp

;--------------------------------------------------------------
; oct_of -- A = the 8-sector angle (octant) of the 16-bit signed vector
;   (swr_vx, swr_vy): 0 = +x (east), counting CCW, each sector 45 deg wide
;   centred on its axis/diagonal. No atan: sign quadrant + |dx| vs |dy|*2.25
;   compares (the 2.25 sits the boundary at 24 deg instead of 22.5 -- 1.4 deg
;   of skew, pinned by tools/_verify_rot.py). Clobbers A/X, preserves Y.
;--------------------------------------------------------------
.proc oct_of                          ; THE THUNK -- see bank01.asm.
        jsl B1CODE_BASE+b1_oct_of
        rts                          ; a bank-0 `jmp oct_of` still works: it lands
.endp
swr_vx  dta a(0)
swr_vy  dta a(0)

;--------------------------------------------------------------
; en_kind_of -- A = sprite id -> en_kind = that sprite's MONSTER KIND byte.
;   It rides in the LAST byte of the sprtab row, which the pickups use for their
;   bonus id -- a sprite is never both, and pack_things.py asserts it. Cold: once
;   per shot that hits something, plus wrot_idle's per-visible-idle-monster call.
;   Clobbers A/X/Y and the sp_tab scratch -- X because the *8 below is a dex/bne
;   shift loop, so it always returns X = 0. (That was NOT documented and cost a
;   boot hang when en_radfill kept its loop index in X.)
;   2026-08-03: moved out of the packed ENINIT block, next to its new caller.
;--------------------------------------------------------------
.proc en_kind_of
        sta en_k2                    ; id*8 = the sprtab row offset
        lda #0
        sta en_k2+1
        ldx #3
?sh     asl en_k2
        rol en_k2+1
        dex
        bne ?sh
        clc
        lda en_k2
        adc th_sprtab
        sta sp_tab
        lda en_k2+1
        adc th_sprtab+1
        sta sp_tab+1
        ldy #7
        lda (sp_tab),y
        sta en_kind
        rts
.endp

;--------------------------------------------------------------
; aif_oct -- A = octant(ai_t -> ITS TARGET), and it leaves swr_vx/vy holding
;   that vector with swr_ax/ay = its normalised |legs| (oct_of's own scratch).
;   The target is TH_TARG (0 = the player, else thing+1 -- infight retaliation
;   included). Tic-time: sp_ptr/m_prod are render-frame scratch, free here
;   (en_gunshot's rule). Two callers, and they want DIFFERENT things with it:
;     * A_FaceTarget (ai_atk_row) STORES it in TH_DIR -- every attack action
;       begins by turning the monster to its target, so the attack frames show
;       it facing what it shoots at, and the next A_Chase step's movedir
;       overwrites it again, exactly like DOOM's mobj angle;
;     * ai_front (A_Look's 180-degree test) only COMPARES it with TH_DIR and
;       must not touch the facing at all.
;   Hence the bare octant here and the two-line store at the A_FaceTarget
;   call site: a wrapper for it pushed this block over SIGHT_BASE.
;--------------------------------------------------------------
.proc aif_oct
        jsr aif_tpos                 ; ai_tx/ai_ty = the target (player or the
                                     ;   infight victim -- infight.asm resolves
                                     ;   it for the melee/newdir tests already)
        lda ai_t
        jsr en_thing.en_th2          ; sp_ptr = MY record
        ldy #0
        sec
        lda ai_tx                    ; vector = target - me
        sbc (sp_ptr),y
        sta swr_vx
        iny
        lda ai_tx+1
        sbc (sp_ptr),y
        sta swr_vx+1
        iny
        sec
        lda ai_ty
        sbc (sp_ptr),y
        sta swr_vy
        iny
        lda ai_ty+1
        sbc (sp_ptr),y
        sta swr_vy+1
        jmp oct_of                   ; -> A = the octant, 0..7
.endp
; DOOM rot (0 = facing the viewer) -> stored slot (bits 0-1) + mirror (bit 7).
; pack_things STORED_ROTS stores lump digits 1/2/3/5, so SIX of DOOM's eight
; views are its own pixels: rot 0 the front, 1 the 3/4 front and 7 that same
; image mirrored (the WAD ships A2A8 as ONE lump), 2 the profile and 6 its
; mirror (A3A7), 4 the back. The other two -- the 3/4-BACK views, rots 3 and 5
; -- fall back on the plain back, so the table below reads slot 3 three times.
; (2026-08-25: this said SEVEN and then listed six. Measured on the shipped
;  bytes: drive spr_wrot over all eight TH_DIRs and six distinct slot/mirror
;  pairs come back -- tools/tests/_verify_arena.py's sibling check.)
; WHY four and not five: digit 4 is left out because a monster's back is what
; the player looks at least. The reason USED to be "the 24 KB coltab run at
; $01:9400 has no room"; that run moved to bank $08 and is 57 KB now
; (2026-08-21), but a fifth view still does not fit -- E3M9 already spends 254
; of the 254 usable FRAME IDS, and the id is a byte.
;   BEFORE 2026-08-07 only digits 1/3/5 were stored and rots 1 and 7 collapsed
;   onto the FRONT, i.e. the front view was 135 deg wide instead of 45: every
;   monster within 67 deg of the player's line stared straight at him.
swr_rot4 dta $00,$01,$02,$03,$03,$03,$82,$81
swr_row  dta 0
swr_y    dta 0
swr_dir  dta 0
swr_ax   dta a(0)
swr_ay   dta a(0)
swr_t    dta a(0)

;--------------------------------------------------------------
; wrot_init -- per level (from en_init, whose block is full): cache the
;   stored-view count out of bank $01. pack_things wn[0] = 3 with rotations,
;   1 for a front-only build; 0 means a pre-rotation .dtab -- treat as 1.
;--------------------------------------------------------------
.proc wrot_init
        lda #<WTAB_N
        sta zp_ptr
        lda #>WTAB_N
        sta zp_ptr+1
        ldy #0
        lda [zp_ptr],y
        bne ?nst
        lda #1
?nst    sta wrot_nst
        lda #0                       ; zp_ptr low byte back to the page pattern
        sta zp_ptr                   ;   every other bank-$01 reader assumes
        rts
.endp

;--------------------------------------------------------------
; wrot_dir -- en_init's per-thing tail: TH_DIR[thing] = the SPAWN FACING from
;   the record's flags bits 4-6 (P_SpawnMapThing's ANG45*(mthing->angle/45),
;   packed by pack_things). The AI overwrites it with the movedir at wake --
;   which is DOOM too: an idle monster faces its map angle, a walking one its
;   direction of travel. Y = thing, (sp_ptr) = its record, zp_ptr = the TH_HPL
;   page pointer, which is RESTORED for en_init's loop.
;--------------------------------------------------------------
.proc wrot_dir
        sty swr_y                    ; the record read below needs Y
        ldy #7
        lda (sp_ptr),y
        lsr
        lsr
        lsr
        lsr
        and #7
        sta swr_dir
        lda #>TH_DIR
        sta zp_ptr+1
        lda swr_dir
        ldy swr_y
        sta [zp_ptr],y
        lda #>TH_HPL                 ; hand the page back to the caller's loop
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; wrot_idle -- spr_dyn's ?live tail: an IDLE MONSTER still rotates (it faces
;   its spawn angle, DOOM's P_SpawnMapThing), so give it walk image 0's
;   rotation group instead of the flat sprtab row. C=1 -> A = row+1 to copy
;   (spr_wrot picked the slot from TH_DIR = the seeded spawn octant); C=0 ->
;   not a monster (or no walk rows in this level): the static path stands.
;   Y = thing, zp_ptr = a bank-$01 page pointer.
;   2026-08-03: reads TH_KIND, which en_kfill prefilled for EVERY thing at
;   level init -- one bank byte replaces the two hp probes AND en_kind_of's
;   sprite-table walk, twice per visible thing per frame (projection + draw).
;   The answers are identical by construction: TH_KIND is the same kind byte
;   en_kind_of returns, gated on the same "has hit points".
;--------------------------------------------------------------
.proc wrot_idle
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y               ; 0 = not a monster (or a shootable this
        bne ?mons                    ;   port has no kind for): static path
        clc
        rts
?mons   sty swr_y2
        tay                          ; wfirst = WTAB_EXT[kind] ($FF = this level
        lda #<WTAB_EXT               ;   ships no walk rows for the kind -- the
        sta zp_ptr                   ;   barrel, or a walk-less build)
        lda #>WTAB_EXT
        sta zp_ptr+1
        lda [zp_ptr],y
        ldy #0                       ; zp_ptr low byte back to the page pattern
        sty zp_ptr                   ;   BEFORE spr_wrot reads TH_MODE/TH_DIR
        cmp #$FF
        beq ?flat
        clc
        adc #1                       ; row+1, like TH_WROW carries it
        ldy swr_y2
        jsr spr_wrot                 ; idle: TH_MODE bit0 clear, TH_DIR = spawn
        sec                          ;   octant -> the facing-correct slot
        rts
?flat   ldy swr_y2
        clc
        rts
.endp

;--------------------------------------------------------------
; en_kfill -- en_init's third pass (chained off it: the ENINIT block is full):
;   TH_KIND[i] for EVERY thing -- the sprtab kind byte when the thing has hit
;   points, else 0. Exactly what ai_start used to cache at wake, precomputed
;   so wrot_idle and ai_wake read one byte per frame instead of probing hp
;   and walking the sprite table. Tail-jumps ai_reset (en_init used to).
;--------------------------------------------------------------
.proc en_kfill
        lda th_things
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        ldx #0
?lp     cpx THINGS_BASE              ; the packed thing count
        bcs ?done
        ldy #6
        lda (sp_ptr),y               ; the record's sprite id
        sta en_k2
        txa
        tay
        lda #>TH_HPL                 ; a monster is exactly "it has hit points"
        sta zp_ptr+1
        lda [zp_ptr],y
        sta en_t
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora en_t
        beq ?zero
        lda en_k2                    ; th_sprtab + sid*8 + 7 = the kind byte
        sta en_t                     ;   (shared with the bonus id, but hp>0
        lda #0                       ;   says which reading is the true one)
        sta en_t+1
        asl en_t
        rol en_t+1
        asl en_t
        rol en_t+1
        asl en_t
        rol en_t+1
        clc
        lda en_t
        adc th_sprtab
        sta sp_tab
        lda en_t+1
        adc th_sprtab+1
        sta sp_tab+1
        ldy #7
        lda (sp_tab),y
        bne ?put
?zero   lda #0
?put    sta en_t
        txa
        tay
        lda #>TH_KIND
        sta zp_ptr+1
        lda en_t
        sta [zp_ptr],y
        clc                          ; next record
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inx
        bne ?lp
?done   jmp ai_reset                 ; ...and nothing chases in a fresh level
.endp
swr_y2  dta 0

;--------------------------------------------------------------
; wrot_left -- spr_dyn's post-copy fixup: a MIRRORED view anchors from its
;   other edge -- r_things.c R_ProjectSprite does `tx -= spritewidth - offset`
;   when the frame is flipped, against `tx -= offset` normally. The row copy
;   is private (sp_drow), so the left-offset byte is simply rewritten there.
;--------------------------------------------------------------
.proc wrot_left
        bit sp_dflip
        bpl ?out
        sec
        lda sp_drow+3                ; w
        sbc sp_drow+5                ; - left
        sta sp_drow+5
?out    rts
.endp
    .if * > WROT_END+1
        ert 'spr_wrot/wrot_* outgrew WROT_BASE..END (memory_map.inc)'
    .endif
        org wrot_resume
        org enanim_resume
