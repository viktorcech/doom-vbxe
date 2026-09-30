;--------------------------------------------------------------
; Part of enemy.asm (icl in place): the player's weapons -- en_gunshot, en_shoot (hitscan), sh_trace, en_rocket, en_boomat, en_plasma.
;--------------------------------------------------------------
;--------------------------------------------------------------
; en_gunshot -- roll the READY WEAPON's damage (p_pspr.c) and fire it into
;   en_shoot. Called once per shot from wp_fire_a. Cold, so it lives in the
;   ENINIT block: the hot $FEDD one is full. Clobbers A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_gunshot
        stz en_hit                   ; en_shoot raises it when the shot CONNECTS
        stz en_melee                 ;   (wp_fire_a picks punch/sawhit off it)
        stz pf_mel                   ; a bullet, until ?melee says otherwise
        lda #SCREEN_HALF             ; the aim column: dead centre = an ACCURATE
        sta en_col                   ;   shot; the branches below roll it off
        ldy #SCREEN_HALF-1           ; ...and THE AIM CELL around it. DOOM's trace
        sty en_cl                    ;   is a zero-width line at an angle it can
        ldy #SCREEN_HALF+1           ;   express to 1/2^32 of a circle; this port
        sty en_ch                    ;   has 256 of them, so "fire at BAM a" really
                                     ;   means "somewhere in the 1.41 deg cell
                                     ;   around a", and half a cell is one column
                                     ;   (SCREEN_HALF is the focal length).
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
        ; --- A_FireShotgun: `for (i=0 ; i<7 ; i++) P_GunShot(mo, false)`.
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
?melee  inc en_melee
        inc pf_mel                   ; ...and its puff is the MELEERANGE one
        jsr en_aimcol                ; both swings roll the <<18 as well
        lda RANDOM
        and #15                      ; 0..15 -> 0..9, with the same doubled
        cmp #10                      ;   frequency on 0..5 the file's header
        bcc ?m1                      ;   already accepts for `and #3`
        sbc #10
?m1
	inc
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
	bra ?mgo
?msend  lda en_t
?mgo    jsr en_shoot
        jmp pf_shot                  ; blood on what it hit, or the MELEERANGE
.endp                                ;   puff on the wall it did not
        .endseg

;--------------------------------------------------------------
; en_r5 -- P_GunShot's damage: 5*(P_Random()%3+1) = 5, 10 or 15. One roll per
;   PELLET (the shotgun calls it seven times). Clobbers A and en_t.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_r5
        lda RANDOM                   ; POKEY LFSR (see the header note)
        and #3
        cmp #3
        bne ?ok
        lda #2                       ; 3 -> 2, the same bias hud.asm accepts
?ok
	inc
        sta en_t
        asl
        asl                          ; *4
        clc
        adc en_t                     ; *5
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_hurt_snd / en_die_snd -- the voice, from info.c via mk_tables.inc.
;   DOOM plays painsound out of A_Pain, which the pain state only reaches when
;   P_Random() < painchance (p_inter.c P_DamageMobj), so the roll is here too --
;   without it a burst of pistol fire makes one long scream. Clobbers A/X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_hurt_snd
	stz en_painr
        ldx en_kind                  ;   reads the answer out of here
        beq ?no                      ; 0 = not a monster (a barrel, a decoration)
        lda RANDOM                   ; POKEY LFSR, like the rest of this file
        cmp mk_chance,x
        bcs ?no                      ; >= painchance -> it takes it silently
        inc en_painr                 ; ...but it DID flinch: fight back
        lda mk_pain,x
        bmi ?no                      ; $FF = this type has no sound in the build
                                      ; 2026-09-22 idiom: snd_qm_last inlined (a 12-cycle
        sta en_snd_q                 ;   body under a 12-cycle jsr/rts)
        lda en_last
        sta en_snd_th
?no     rts                          ;   gunshot AFTER this runs and would stomp it.
                                     ;   STEREO: en_last is the one in pain
.endp
        .endseg

; (en_die_snd MOVED to the MKTAB block 2026-08-04: the A_Scream variant roll
;  -- podth1..3 / bgdth1..2 via mk_dthn -- outgrew this block, and it reads
;  those tables anyway.)

                                     ; mk_tables.inc MOVED to the AI block at ...

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
                                     ;   p_inter.c:719 gibs on more than ...
en_gib  = ENGIB_VARS+2               ; 1 = that kill earned S_x_XDIE
en_col  dta SCREEN_HALF              ; AIM COLUMN of the shot being resolved: the
                                     ;   span test in en_shoot and the clip-window ...
en_cl   dta SCREEN_HALF-1            ; ...and the aim CELL around it, derived once
en_ch   dta SCREEN_HALF+1            ;   per shot at the top of en_shoot
    .if * > ENINIT_END+1
        ert 'en_init + vars outgrew ENINIT_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; en_shoot -- A = damage. Aim, subtract, kill at <= 0. Clobbers A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_shoot
        sta en_dmg
        stz en_bsc
        stz en_bsc+1
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
                                     ;   and then the clamp -- UNCONDITIONAL now: ...
?store  lda en_t+1                   ; write it back (zp_ptr is on the HI page)
        sta [zp_ptr],y
        dec zp_ptr+1
        lda en_t
        sta [zp_ptr],y
        ora en_t+1
        beq ?dead
	phy
        jsr en_hurt_snd
	ply
        jsr en_thrust_plr            ; ...and takes P_DamageMobj's kick, away
        ldy en_last                  ;   from the player (en_thrust wants Y for
                                     ;   itself, en_last is the same thing)
        jmp ai_hurt                  ; p_inter.c:902 "we're awake now": clear its
                                     ;   reactiontime, and MF_JUSTHIT if it flinched
?dead
	phy
        jsr en_thrust_plr            ;   first DIE frame and en_tick walks it.
        jsr en_die_snd
	ply
        jmp en_kill                  ;   en_kill tail-calls thing_kill for that.)
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; en_rocket -- A_FireMissile, folded into this port's aim model.
;   DOOM spawns an MT_ROCKET, flies it, and on the first thing it touches
;   PIT_CheckThing rolls ((P_Random()&7)+1) * mobjinfo.damage (20 for the rocket,
;   so 20..160) and P_ExplodeMissile runs A_Explode = P_RadiusAttack(...,128).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_rocket
        lda RANDOM                   ; ((P_Random()&7)+1) * 20
        and #7
 	inc
        asl
        asl                          ; n*4
        sta en_t+1
        asl
        asl                          ; n*16
        clc
        adc en_t+1                   ; n*20 = 20..160, still a byte
        jmp en_rocket2               ; the aim + blast + the VISIBLE missile
.endp                                ;   (proj.asm -- this block is full)
        .endseg

;--------------------------------------------------------------
; sh_trace -- the rocket that hit NO thing: burst it on the wall instead
;   ("a rocket that hits nothing does nothing" was a real gap, not a wash --
;   in DOOM a point-blank rocket into a wall wounds the SHOOTER, and
;   PIT_RadiusAttack has no bombsource exemption, p_map.c:1194).
;--------------------------------------------------------------
;--------------------------------------------------------------
; sh_trace -- p_map.c PTR_ShootTraverse, the geometry half: walk the leaves the
;   aim ray crosses and stop at the first line that stops a BULLET.
;   IN : A = how many SH_STEP samples to walk (SH_NBULL / SH_NROCK).
;   OUT: en_bx/en_by = the impact point, C=1 if a wall was found. C=0 = the ray
;        ran out; en_bx/by is then the ray end, which is what en_march did too.
;   Clobbers A/X/Y, m_*, zp_ptr/zp_sptr/zp_nid/zp_segcnt, USE_PT_A/B, USE_SS.
;--------------------------------------------------------------
SH_STEP  equ 32                      ; sample spacing. It only has to land in
                                     ;   every subsector the ray crosses -- the
                                     ;   crossing test itself uses the whole ray
SH_NBULL equ 32                      ; 1024 units
SH_NROCK equ 255                     ; 8160 units: a missile has NO range in DOOM
                                     ;   (p_mobj.c flies it until P_TryMove fails)
SH_NMELEE equ 3                      ; MELEERANGE is 64, and this is 96: the
                                     ;   crossing test needs the ray to pass ...
SH_REF   equ 10                      ; binary-search steps -> 8160/1024 = 8 units

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_trace
        sta sh_n
	rep #$20
	.LONGA ON
	lda zp_px
	sta USE_PT_A
        lda zp_py
        sta USE_PT_A+2
	lda sh_n
	and #$00ff
	asl
	asl
	asl
	asl
	asl
	sta sh_hi
	sta sh_d
	sep #$20
	.LONGA OFF
        jsr sh_setb                  ; USE_PT_B = the ray end (a loop constant)
        lda #$FF
        sta USE_SS                   ; no leaf tested yet ($FFFF is not a leaf id)
        sta USE_SS+1
        stz sh_d                     ; sample 0 = the player's own subsector
        stz sh_d+1
?loop   jsr sh_dist                  ; zp_px/zp_py = A + sh_d*(cos,sin)
                                    ; 2026-09-22 (65816-windows): sh_dist returns 16-bit
        sep #$20
        jsr use_locate               ; zp_nid = the leaf there
	.LONGA ON                    ; (2026-09-26: use_locate returns 16-bit, A = zp_nid)
	cmp USE_SS
	beq ?step
	sta USE_SS
	sep #$20
	.LONGA OFF
        jsr sh_leaf                  ; C=1: a crossed seg stops a bullet
        bcs ?found
	rep #$20
	.LONGA ON
	sec
?step	lda sh_d
	adc #SH_STEP-1
	sta sh_d
	sep #$20
	.LONGA OFF
	dec sh_n
        bne ?loop

        lda sh_hi                    ; nothing in reach: the ray END is the point
        sta sh_d                     ;   (out of blast range by construction)
        lda sh_hi+1
        sta sh_d+1
        jsr sh_dist
                                    ; sh_end takes 16-bit (its rep is idempotent)
        clc
        jmp sh_end                   ; C=0: no wall, the point is the ray end
?found  jmp sh_refine                ; the wall is in [0, sh_hi]: the PUFF block
.endp                                ;   has the room, this one has two bytes
        .endseg

; en_rockwall (trace + blast in one) is GONE since 2026-08-05: the two halves
; happen a second apart now -- pj_aim traces for the flight target and pj_hit
; blasts when the rocket gets there (proj.asm).

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_boomat
        lda en_k2                    ; --- A_Explode at (en_bx, en_by): en_boom
        pha                          ;     minus en_thing/en_lfind ---
        lda en_k2+1
        pha
        lda en_kind
        pha
        lda #$FF
        sta en_k2                    ; no exploding THING: the sweep skips nobody
	rep #$20
	.LONGA ON
        stz en_lp                    ; and no LOS grid
        sec                          ; --- the player (PIT_RadiusAttack verbatim)
        lda en_bx
        sbc zp_px
        sta m_a
        sec
        lda en_by
        sbc zp_py
        sta m_b
	sep #$20
	.LONGA OFF
        jsr en_dist
        bcc ?things
                                      ; 2026-09-22: the bombsource hurts the player
        ldx en_bsrc                  ;   (0: the player's own rocket = no attacker)
        stx pl_src
        jsr en_plr_hurt
?things jsr en_bthings               ; --- and everything else in range
        stz en_bsrc                  ; 2026-09-22: back to 0 = the player (bl_boom set it)
        pla
        sta en_kind
        pla
        sta en_k2+1
        pla
        sta en_k2
        rts
.endp
        .endseg
                                     ; (the sh_* variables live with sh_leaf in
                                     ;  the death block -- this one is full)

;--------------------------------------------------------------
; en_plasma -- A_FirePlasma. MT_PLASMA's PIT_CheckThing roll is the rocket's with
;   mobjinfo.damage 5 instead of 20: ((P_Random()&7)+1)*5 = 5..40, and no
;   A_Explode -- the bolt hurts what it hits and nothing else. Same reduction as
;   the rest: it lands the tic it is fired, on the vissprite under the crosshair.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg
