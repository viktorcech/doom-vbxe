;==============================================================
; powerups.asm -- p_inter.c's POWERS + the backpack (2026-08-01).
;
; Until now the engine walked straight through all seven: pack_things.py's BONUS
; table had no id for their sprites, so spr_take read a 0 out of the sprtab row
; and left the thing lying there for ever. They are pickups in every other
; respect -- wadthings already flags C_POWER/C_AMMO things "can be picked up",
; and the id rides in the sprtab byte that is already in the blob, so none of
; this costs a byte of level data.
;
; What each one DOES here, and why two of them do nothing:
;   25 backpack  P_GiveBackpack: doubles every ammo cap (pw_max, read on demand
;                -- there is no maxammo[] array to rewrite) and hands over one
;                clip of each type. DOOM's doubled caps are 400/100/100/600;
;                PSTATE counters are BYTES, so bullets and cells saturate at 255
;                (the port already clipped cells at 255 without a backpack).
;   26 blur      MF_SHADOW. A_FaceTarget adds (P_Random()-P_Random())<<21 to a
;                monster's aim when its target carries it -- TWICE the <<20
;                spread A_PosAttack rolls anyway. pw_spread is that sum.
;                The other two MF_SHADOW sites (2026-09-15): P_SpawnMissile
;                turns a fireball by <<20 (bl_spread), and R_DrawPSprite draws
;                the gun and its flash as shadow, blinking out over the last
;                4*32 tics (weapon.asm wp_shadow).
;   27 radsuit   P_PlayerInSpecialSector's ironfeet test (pw_shield).
;   28 map       TAKEN and thrown away: there is no automap to reveal.
;   29 visor     likewise -- the renderer has no light diminishing at all (see
;                the extralight note above FLASH_BASE in memory_map.inc), so
;                there is nothing for a light amplifier to amplify. Both are
;                still picked up: an item you can never make disappear reads as
;                a bug, an item that quietly does nothing does not.
;   30 invuln    P_DamageMobj's "damage < 1000 && powers[pw_invulnerability]"
;                -> no damage at all, from monsters OR from the floor. No
;                inverse palette: VBXE has four palettes and update_flash
;                already spends all four (FL_PAL_*).
;   31 berserk   P_GivePower(pw_strength): P_GiveBody(100), the fist becomes the
;                pending weapon, and A_Punch's damage is multiplied by 10
;                (en_gunshot). It also completes G_BuildTiccmd's '1' rule in
;                wp_select, which until now had no pw_strength to test.
; 30 and 31 are not reachable in episode 1 at the skill the engine ships (SKILL
; 2 in pack_things.py); they are here so a UV build or episode 2 needs no
; engine change.
;
; The three timers count DOOM TICS, down from d_player.h's own constants, one
; per tic out of pw_tic -- which IS wp_tic's old `jsr fl_tic`, so the per-tic
; cost lands in this block and not in the flash block, which is full to the byte
; ($F789, with en_bthings at $F78A).
;==============================================================
pwm_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org PWMAP_BASE
 .endif
;--------------------------------------------------------------
; pw_map -- P_GivePower(pw_allmap), in front of pw_give. Y = bonus id, and it
;   must come back untouched (snd_bonus reads it), so the test is a cpy.
;   28 is the Computer Area Map: am_walls draws every line the BSP walk has not
;   lit yet while this bit is up (am_map.c's pw_allmap branch). 29, the visor,
;   still stores nothing -- this build has no light amp.
;   PARKED HERE and not in pw_give: that block ends ON POWER_END.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_map
        cpy #BN_MAP
        bne ?go
        lda PW_FLAGS                 ; NOT `tsb`: tools/tests/sim6502.py has no
        ora #PWF_ALLMAP              ;   opcode $0C, so every _verify_* test would
        sta PW_FLAGS                 ;   run past it blind. Three bytes more, and
                                     ;   this hole has 38. A is free -- pw_give
                                     ;   dispatches on Y alone.
?go     jmp pw_give
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > PWMAP_END+1
        ert 'pw_map outgrew PWMAP_BASE..PWMAP_END (memory_map.inc)'
    .endif
 .endif
        org pwm_resume

pw_resume = *
        org POWER_BASE

;--------------------------------------------------------------
; pw_give -- give_bonus' third class: Y = bonus id 25..31, and Y is LIVE for the
;   caller (snd_bonus picks the SFX off it), so it comes back untouched. C=1 =
;   taken; only P_GivePower(pw_allmap) can refuse in DOOM and the map does
;   nothing here, so everything is taken.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_give
        cpy #BN_INVIS
        beq ?invis
        cpy #BN_IRON
        beq ?iron
        cpy #BN_INVUL
        beq ?invul
        cpy #BN_BPACK
        beq ?pack
        cpy #BN_BERSERK
        beq ?zerk
        cpy #BN_VISOR
        beq ?visor
        sec                          ; 28 map: nothing to store
        rts
?visor  lda #<INFRATICS              ; p_inter.c:307 -- P_GivePower REFRESHES
        ldx #>INFRATICS              ;   the visor to full instead of refusing a
        sta PW_VISOR                 ;   second pickup, unlike the others
        stx PW_VISOR+1
        bra ?ok                      ; share the sec/rts below
?invis  lda #<INVISTICS
        ldx #>INVISTICS
        sta PW_INVIS
        stx PW_INVIS+1
?ok     sec
        rts
?iron   lda #<IRONTICS
        ldx #>IRONTICS
        sta PW_IRON
        stx PW_IRON+1
        sec
        rts
?invul  lda #<INVULNTICS
        ldx #>INVULNTICS
        sta PW_INVUL
        stx PW_INVUL+1
        sec
        rts
;   P_GivePower(pw_strength): heal to 100 (P_GiveBody caps at MAXHEALTH, it does
;   NOT go to 200), then "if (readyweapon != wp_fist) pendingweapon = wp_fist".
?zerk   jsr fl_zon                   ; the flag AND st_stuff.c's red (ZERK_BASE)
        lda PSTATE+PS_HEALTH
        cmp #100
        bcs ?zwp
        lda #100
        sta PSTATE+PS_HEALTH
?zwp    lda wp_cur
        cmp #WP_FIST
        beq ?ztk
        lda #WP_FIST                 ; straight into wp_pending, NOT through
        sta wp_pending               ;   wp_select: DOOM's berserk hands you the
?ztk    sec                          ;   fist even though you own the chainsaw
        rts
;   P_GiveBackpack: the FIRST one doubles maxammo[], every one gives a clip of
;   each type (clipammo[] = 10 bullets / 4 shells / 1 rocket / 20 cells).
?pack   lda PW_FLAGS
        ora #PWF_BPACK
        sta PW_FLAGS                 ; (pw_max applies the doubling from here on)
        ldx #3
?pk     lda pw_amax,x                ; the type's cap, doubled by the backpack
        jsr pw_max
        sta bn_cap
        ldy pw_aidx,x                ; ...and the clip on top of what is stocked
        clc
        lda PSTATE,y
        adc pw_clip,x
        bcs ?pcap                    ; wrapped a byte
        cmp bn_cap
        bcc ?pput
?pcap   lda bn_cap
?pput   sta PSTATE,y
        dex
        bpl ?pk
        ldy #BN_BPACK                ; Y is the caller's bonus id: put it back
        sec
        rts
.endp
        .endseg
pw_aidx dta PS_BULLETS, PS_SHELLS, PS_ROCKETS, PS_CELLS
pw_clip dta 10, 4, 1, 20             ; p_inter.c clipammo[]
pw_amax dta 200, 50, 50, 255         ; ...and maxammo[] (cells 300 -> a byte)
PW_VISOR dta 0,0                     ; u16 DOOM tics of light-amp VISOR left.
                                     ;   Data, not an equ, so the loader zeroes
                                     ;   it -- lt_seg reads it per seg and a
                                     ;   random byte here would light the whole
                                     ;   level full bright from the first frame.
vis_lit  dta 0                       ; $FF = the visor lights this tic. pw_tic
                                     ;   sets it, lt_seg/lt_seg_flash read it.
kb_last  dta $FF                     ; last code seen down by kb_scan ($FF = none)
kb_new   dta $FF                     ; a NEW press, waiting for cht_key

;--------------------------------------------------------------
; pw_max -- A = DOOM's maxammo[] for some ammo type -> the cap that applies right
;   now. Preserves X and Y (give_bonus holds the PSTATE index in X, wp_give the
;   weapon in X and the ammo in Y).
;--------------------------------------------------------------
    .if * > POWER_END+1
        ert 'pw_give outgrew POWER_BASE..POWER_END (memory_map.inc)'
    .endif
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org PWMAX_BASE               ; 2026-08-11 win2 evacuation: powerups split
 .endif
                                     ;   four ways (memory_map.inc POWER/PWMAX/
                                     ;   PWTIC/LFSG)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_max
        pha
        lda PW_FLAGS
        and #PWF_BPACK
        beq ?plain
        pla
        asl                          ; 400 and 600 do not fit a byte counter, so
        bcc ?out                     ;   the port's real doubled caps are 255 for
        lda #255                     ;   bullets and cells, 100 for the other two
?out    rts
?plain  pla
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pw_tic -- ONE DOOM tic of P_PlayerThink's powers[] half. wp_tic calls THIS
;   instead of fl_tic and this passes it on: the flash block has no room left
;   for another instruction, and both are the same 35 Hz clock anyway.
;--------------------------------------------------------------
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > PWMAX_END+1
        ert 'pw_max outgrew PWMAX_BASE..PWMAX_END (memory_map.inc)'
    .endif
 .endif
        org PWTIC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_tic
        jsr fl_ztic                  ; the berserk's red fade, then fl_tic --
                                     ;   the palette-flash counters (weapon.asm)
        ldx #4                       ; three u16 counters, 2 B apart
 .if 1
	rep #$20
	.LONGA ON
?lp	lda PW_INVIS,x
	beq ?nx
	dec
	sta PW_INVIS,x
?nx	dex
	dex
	bpl ?lp
	lda PW_VISOR                 ; the FOURTH counter, and it cannot join the
  .if 1                               ;   loop above: PW_FLAGS occupies the slot a
	beq ?nov0                    ;   fourth u16 would have needed
	dec
	sta PW_VISOR
	sep #$20
	.LONGA OFF
	jmp pw_vislit                ; tail call (its rts is this proc's)
	.LONGA ON
?nov0	sep #$20                     ; NO VISOR (2026-09-15): A = 0 is already
	.LONGA OFF                   ;   pw_vislit's answer -- it would reload both
	sta vis_lit                  ;   bytes just to find that out (-16 a tic)
	rts
  .else
	beq ?nov
	dec
	sta PW_VISOR
?nov	sep #$20
	.LONGA OFF
	jmp pw_vislit                ; tail call (its rts is this proc's)
  .endif
 .else
?lp     lda PW_INVIS,x
        ora PW_INVIS+1,x
        beq ?nx                      ; already expired: it parks at zero
        lda PW_INVIS,x
        bne ?lo
        dec PW_INVIS+1,x
?lo     dec PW_INVIS,x
?nx     dex
        dex
        bpl ?lp
 .endif
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pw_shield -- X = the sector's damage class (1..4, movers.asm). C=1 = this tic's
;   damage is blocked. p_spec.c P_PlayerInSpecialSector: ironfeet stops nukage
;   and slime outright, lets SUPER HELLSLIME through on "P_Random () < 5", and
;   does nothing at all about special 11 (E1M8's finale, class 4). Invulnerability
;   is P_DamageMobj's own test, above all of it. Preserves X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_shield
        lda PW_INVUL
        ora PW_INVUL+1
        bne ?block
        cpx #4
        bcs ?no                      ; E1M8's exit damage: nothing stops that
        lda PW_IRON
        ora PW_IRON+1
        beq ?no
        cpx #3
        bcc ?block                   ; nukage / slime: stopped dead
        lda RANDOM                   ; super slime: it leaks 5 times in 256
        cmp #5
        bcc ?no
?block  sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pw_spread -- m_a:m_a+1 = |the monster's aim error| in ai_fire's units (a full
;   P_Random spread = 255, and the pellet lands if |spread| * dist < 16 * 620).
;   A_PosAttack rolls (P_Random()-P_Random())<<20; with the blur sphere on the
;   player A_FaceTarget has ALREADY added (P_Random()-P_Random())<<21, so the
;   port sums r1 + 2*r2 -- SIGNED, so the two rolls can still cancel exactly as
;   they do in DOOM. Clobbers A/X and m_b (ai_fire fills m_b right after).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_spread
        jsr ?tri
        sta m_a
        stx m_a+1

        lda PW_INVIS
        ora PW_INVIS+1
        beq ?abs                     ; visible: the plain <<20 spread

        jsr ?tri
        sta m_b
        stx m_b+1
 .if 1
	rep #$20
	.LONGA ON
	lda m_b
	asl
	clc
	adc m_a
	sta m_a
	sep #$20
	.LONGA OFF
 .else
        asl m_b                      ; <<21 = twice <<20
        rol m_b+1
        clc
        lda m_a
        adc m_b
        sta m_a
        lda m_a+1
        adc m_b+1
        sta m_a+1
 .endif
?abs    lda m_a+1
        bpl ?out
 .if 1
	jmp m_neg
 .else
        jsr m_neg                    ; |s|, 16-bit (it can reach 765 now)
 .endif
?out    rts
;   one P_Random() - P_Random(), sign-extended: A = lo, X = hi (0 or $FF)
?tri    lda RANDOM
        sec
        sbc RANDOM
        ldx #0
        bcs ?p
 .if 1
	dex
 .else
        ldx #$FF
 .endif
?p      rts
.endp
        .endseg

;--------------------------------------------------------------
; bl_spread -- P_SpawnMissile's "fuzzy player" (p_mobj.c:909): with MF_SHADOW on
;   the target, an += (P_Random()-P_Random())<<20. ball_spawn aims by VECTOR,
;   so the turn goes onto bl_dx/bl_dy as the small-angle rotation
;       dx' = dx - t*dy        dy' = dy + t*dx        t = r * 2pi/4096 rad
;   with t in Q14 for smul_14: 2pi/4096 * 16384 = 25.13 -> r*25, 0.5 % short.
;   At the extreme |r| = 255 (22.4 deg) the linear form turns 1 deg less than
;   the sine would and lengthens the vector by 7.4 %; ?red and k7 normalise
;   the step right after, so only the heading survives. dz is left alone.
;   A_FaceTarget's <<21 does NOT reach a missile -- P_SpawnMissile re-aims from
;   the positions -- so this is the whole missile half; pw_spread is the
;   hitscan half. Native only (ai_fire -> ball_spawn). Clobbers A/X/Y and
;   m_a/m_b/m_prod/m_res/m_sign; ball_spawn re-fills m_a/m_b/m_prod in ?aim.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bl_spread
        lda PW_INVIS
        ora PW_INVIS+1
        beq ?out                     ; visible: no turn
        lda RANDOM                   ; r = P_Random() - P_Random(), -255..255,
        sec                          ;   C = no borrow = r >= 0
        sbc RANDOM
        rep #$20                     ; ---- 16-bit A. rep and `and` leave C alone
        .LONGA ON
        and #$00FF
        bcs ?pos
        ora #$FF00                   ; borrowed: r = A - 256
?pos    sta m_b                      ; t = r*25 = (r*5)*5, |t| <= 6375
        asl @
        asl @
        clc                          ; LOAD-BEARING: |r| <= 255 makes bit 14 the
        adc m_b                      ;   sign, so the second asl leaves C = 1 for
        sta m_b                      ;   every negative r
        asl @
        asl @
        clc                          ; (|5r| <= 1275: the same bit, same carry)
        adc m_b
        sta m_b                      ; t
        pha                          ; ...and a copy for the second product
        lda bl_dy
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul_14                  ; m_res = t*dy
        rep #$20
        .LONGA ON
        pla
        sta m_b                      ; smul_14 left |t| there: re-arm it
        lda m_res
        pha                          ; t*dy, held until dx has been used
        lda bl_dx
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul_14                  ; m_res = t*dx
        rep #$21                     ; C = 0
        .LONGA ON
        lda m_res
        adc bl_dy
        sta bl_dy                    ; dy' = dy + t*dx
        pla
        eor #$FFFF                   ; dx' = dx - t*dy = dx + ~(t*dy) + 1
        sec
        adc bl_dx
        sta bl_dx
        sep #$20
        .LONGA OFF
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pw_level -- G_PlayerFinishLevel: "memset (p->powers, 0, sizeof(p->powers))".
;   The BACKPACK is not a power -- it and the doubled caps survive the
;   intermission; only G_PlayerReborn (load_things' boot path) takes them back.
;   The MESSAGE is dropped here too (G_DoLoadLevel: "player->message = NULL")
;   and it costs NOTHING: msg_t is the byte below PW_INVIS (memory_map.inc), so
;   the memset only has to start one lower and run one longer -- `ldx #6` and
;   `PW_INVIS-1,x`, same two instructions, same 19 bytes. This block is full to
;   the byte (PWTIC_END) and a third store did not fit. Without the clear, the
;   last pickup of the old level would hang over the first frames of the new
;   one, and boot would blit whatever strip index random RAM held.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_level
 .if 1
        ldx #6
?z      stz PW_INVIS-1,x
 .else
        lda #0
        ldx #6
?z      sta PW_INVIS-1,x
 .endif
        dex
        bpl ?z
        lda PW_FLAGS
        and #PWF_BPACK
        sta PW_FLAGS
        rts
.endp
        .endseg

;--------------------------------------------------------------
; leaf_segs -- zp_nid -> that leaf's seg run: zp_sptr = the first seg's record,
;   zp_segcnt = how many. Lifted out of use_leaf 2026-08-05 so the HITSCAN
;   traverse (sh_leaf) can walk the same segs -- it is the only part of use_leaf
;   a bullet shares, since a bullet opens no doors. It lives HERE and not there
;   because the door block ended four bytes past ENLFIND_BASE the moment
;   use_leaf grew a jsr; lifting the body out gave that block 55 B back.
;   zp_sptr+2 (the SEG bank) is set per level and is not touched.
;--------------------------------------------------------------
    .if * > PWTIC_END+1
        ert 'pw_tic..pw_level outgrew PWTIC_BASE..PWTIC_END (memory_map.inc)'
    .endif
        org LFSG_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc leaf_segs
 .if 1
	rep #$20
	.LONGA ON
	lda zp_nid
	asl
	asl
;	clc
	adc #MAP_SSECT
	sta zp_ptr

	ldy #2
	lda [zp_ptr],y
	sta zp_segcnt

	lda [zp_ptr]
	asl
	asl
	asl
;	clc
	adc #MAP_SEGS
	sta zp_sptr
	sep #$20
	.LONGA OFF
 .else
        lda zp_nid                   ; zp_ptr = MAP_SSECT + (nid & $7FFF)*4
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4
        clc
        lda m_prod
        adc #<MAP_SSECT
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SSECT
        sta zp_ptr+1

        ldy #2                       ; count -> zp_segcnt
        lda [zp_ptr],y
        sta zp_segcnt
        iny
        lda [zp_ptr],y
        sta zp_segcnt+1

        ldy #0                       ; first seg -> zp_sptr = MAP_SEGS + first*SEG_SIZE
        lda [zp_ptr],y
        sta m_a
        iny
        lda [zp_ptr],y
        sta m_a+1

        jsr m_x8                     ; *8
        clc
        lda m_prod
        adc #<MAP_SEGS
        sta zp_sptr
        lda m_prod+1
        adc #>MAP_SEGS
        sta zp_sptr+1
 .endif
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sh_dist -- zp_px/zp_py = USE_PT_A + sh_d*(cos,sin): where the hitscan ray is
;   at length sh_d (enemy.asm sh_trace). use_sample's 16-bit twin -- that one
;   takes the distance in A and so stops at 255 units, while the shot ray runs
;   to 1024. Every point is derived from the ORIGIN, never from the previous
;   one: use_sample's own reason (a truncated step drifts), and the binary
;   search jumps around anyway.
;   Parked in this block because the two that own sh_trace and sh_leaf are both
;   full to a dozen bytes; nothing here is a powerup but the slack is.
;--------------------------------------------------------------
;   ONE LOOP, not two copies (2026-08-09, -18 B). The x and y halves differ only
;   in which trig factor and which of two ADJACENT 16-bit cells they use, and the
;   engine's layout lines all three pairs up: zp_py = zp_px+2 ($9E/$A0),
;   USE_PT_A+2 is the origin's y, and zp_cos = zp_sin+2 ($A3/$A5) -- the trig
;   pair the other way round, which is what the `eor #2` on the index is for.
;   X (0 then 2) is the pass, and it rides the stack across smul_14, which
;   clobbers X and Y. Proved bit-identical over 624 (d, sin, cos, origin) cases
;   against the two-copy version: tools/tests/_verify_shdist.py.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_dist
        ldx #0                       ; pass 0 = x/cos, pass 2 = y/sin
 .if 1
 	rep #$20
	.LONGA ON
 .else
	;nothing
 .endif
?lp
 .if 1
	lda sh_d
	sta m_a
	phx
        txa                          ; trig index runs the OTHER way: 0 -> cos
        eor #2                       ;   ($A5 = zp_sin+2), 2 -> sin ($A3)
	tax
	lda zp_sin,x
	sta m_b
	sep #$20
	.LONGA OFF
 .else
	lda sh_d
        sta m_a
        lda sh_d+1
        sta m_a+1
        txa                          ; trig index runs the OTHER way: 0 -> cos
        eor #2                       ;   ($A5 = zp_sin+2), 2 -> sin ($A3)
        tay
        lda.w zp_sin,y
        sta m_b
        lda.w zp_sin+1,y
        sta m_b+1
        txa
        pha
 .endif
        jsr smul_14                  ; m_res = d*cos, then d*sin
 .if 1
	plx
	rep #$21
	.LONGA ON
        lda USE_PT_A,x
        adc m_res
        sta zp_px,x
 .else
        pla
        tax
        clc
        lda USE_PT_A,x
        adc m_res
        sta zp_px,x
        lda USE_PT_A+1,x
        adc m_res+1
        sta zp_px+1,x
 .endif
        inx
        inx
        cpx #4
        bne ?lp
 .if 1
	sep #$20
	.LONGA OFF
 .else
	;nothing
 .endif
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sprcol_read -- read SPRC_SECTORS sectors with read_ext, in passes of 128,
;   because ll_left is a byte and the .sprcol blob is bigger than 255 sectors
;   since the coltab run left bank $01. read_ext writes ll_dst back and
;   read_sectors advances ll_sec, so every pass but the first needs nothing
;   except the count -- which is why this is a loop and not a rewrite of
;   read_ext into 16 bits.
;   Parked HERE and not in load_sprcol: that block is 47 B with one to spare,
;   and one absolute jsr costs the caller nothing it was not already spending.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sprcol_read
        ldx #SPRC_PASSES
?p      lda #128
        cpx #1                       ; the last pass is the remainder
        bne ?full
        lda #SPRC_LAST
?full   sta ll_left
        phx                          ; read_ext does `ldx ll_pass` and counts it
        jsr read_ext                 ;   down -- X is NOT ours across the call
        plx
        dex
        bne ?p
        rts
.endp
        .endseg

    .if * > LFSG_END+1
        ert 'leaf_segs+sh_dist outgrew LFSG_BASE..LFSG_END (memory_map.inc)'
    .endif

;==============================================================
; THE BERSERK'S RED (2026-08-30, "ked vezmem ciernu lekarnicku, obraz by mal
; scervenat"). st_stuff.c ST_doPaletteStuff opens with THREE terms, not two:
;
;     cnt = plyr->damagecount;
;     if (plyr->powers[pw_strength])
;     {
;         bzc = 12 - (plyr->powers[pw_strength]>>6);   // slowly fade it out
;         if (bzc > cnt) cnt = bzc;
;     }
;     if (cnt) palette = STARTREDPALS + ((cnt+7)>>3);
;     else if (plyr->bonuscount) ...
;
; The port had the damage and bonus terms and not this one, so the pack healed
; you, handed you the fist and multiplied A_Punch by ten -- and the screen never
; went red, which is the half of it a player actually SEES.
;
; powers[pw_strength] counts UP one per tic from 1 (P_PlayerThink) and never
; expires; only the palette fades, and it fades exactly one step every 64 tics.
; So the port keeps `bzc` itself, 12 down to 0 -- one byte instead of DOOM's
; 16-bit counter, the same twelve steps over the same 768 tics (~22 s), and
; update_flash's existing (cnt+7)>>3 does the rest.
;
; UP HERE because both blocks that wanted it are full to their last byte (FLASH
; ends at $F7FD, POWER at $5F00). All three routines are cold -- once a frame,
; once a tic, once a pickup -- so the x11.2 chip-bus fetches above $8000 do not
; matter (see ZERK_BASE in memory_map.inc).
;==============================================================
zerk_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org ZERK_BASE
 .endif
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
fl_zerk dta 0                        ; bzc: 12 at pickup, 0 = faded out
fl_zt   dta 0                        ; tics left in the current bzc step

;--------------------------------------------------------------
; fl_zon -- P_GivePower(pw_strength)'s own half: the flag every damage site
;   reads, and the red. pw_give's ?zerk calls this INSTEAD of setting the flag
;   inline, which is why that block did not have to grow.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fl_zon
        lda PW_FLAGS
        ora #PWF_BERSERK
        sta PW_FLAGS
        lda #12                      ; bzc at powers[pw_strength] = 1
        sta fl_zerk
        lda #63
        sta fl_zt
        rts
.endp
        .endseg

;--------------------------------------------------------------
; fl_ztic -- one DOOM tic of the fade, then fl_tic (the damage/bonus counters).
;   pw_tic calls this where it called fl_tic, so that block did not grow either.
;   The flag is the gate, so pw_level needs no line: it drops PWF_BERSERK on
;   every level start (G_PlayerFinishLevel clears powers[]) and the red goes
;   with it.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fl_ztic
        lda PW_FLAGS
        and #PWF_BERSERK
 .if 1
        bne ?on
        sta fl_zerk                  ; A = 0 out of the and: no berserk, no red
?done   jmp fl_tic                   ; the common path FALLS into the tail call
?on     lda fl_zerk                  ;   instead of an always-taken beq (-3 a tic)
        beq ?done                    ; already faded out
        dec fl_zt
        bpl ?done                    ; only every 64th tic moves bzc
        lda #63
        sta fl_zt
        dec fl_zerk
        jmp fl_tic
 .else
        bne ?on
        sta fl_zerk                  ; A = 0 out of the and: no berserk, no red
        beq ?done                    ; (always)
?on     lda fl_zerk
        beq ?done                    ; already faded out
        dec fl_zt
        bpl ?done                    ; only every 64th tic moves bzc
        lda #63
        sta fl_zt
        dec fl_zerk
?done   jmp fl_tic
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; fl_cnt -- ST_doPaletteStuff's cnt: max(damagecount, bzc). update_flash calls
;   this where it read fl_dmg, so it is the same three bytes -- and BOTH arms
;   end on an `lda`, because the caller's next instruction is `beq ?bon` and a
;   cmp's Z would answer a different question.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fl_cnt
        lda fl_dmg
        cmp fl_zerk
        bcs ?out                     ; the damage flash is the redder of the two
        lda fl_zerk
?out    ora #0                       ; ...and A decides Z, not the cmp above
        rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > ZERK_END+1
        ert 'the berserk red outgrew ZERK_BASE..ZERK_END (memory_map.inc)'
    .endif
 .endif
        org zerk_resume

        org pw_resume


;--------------------------------------------------------------
; pw_vislit -- p_user.c:371. The light-amp visor is SOLID while more than 4*32
;   tics are left; below that it lights only while bit 3 is set, so it blinks 8
;   tics on, 8 off, as it runs out. Decided once a tic: lt_seg runs ~140 times a
;   frame and only reads the answer. Lives in the run pw_give vacated -- pw_tic's
;   own block is full to the byte.
;--------------------------------------------------------------
vsl_resume = *
        org VISLIT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_vislit
        lda PW_VISOR+1
        bne ?von                     ; more than 255 tics left: solid
        lda PW_VISOR
        beq ?vst                     ; expired -- and A is already 0 to store
        cmp #129
        bcs ?von                     ; > 4*32: still solid
        and #8                       ; ...below that, bit 3 IS the blink: 0 or 8, and
        bra ?vst                     ;   lt_seg only ever tests it with bne
?von        lda #$FF
?vst        sta vis_lit
        rts
.endp
        .endseg

;--------------------------------------------------------------
; hud_god -- ST_updateFaceWidget's priority 4: CF_GODMODE or pw_invulnerability
;   shows STFGOD0 and outranks the pain levels. This port has no IDDQD, so the
;   invulnerability sphere is the only way in -- but it IS one, and the face was
;   missing on every sphere until now. C=1 = handled, leave the face alone.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_god
        lda PW_INVUL
        ora PW_INVUL+1
        beq ?no
        lda #HUD_FACE_GOD
        cmp face_cur
        beq ?yes                     ; already showing it
        sta face_cur
        inc hud_dirty                ; the bar repaints to show it
?yes    sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; hud_god_gate -- what draw_hud_gate calls instead of hud_face_upd: the god
;   face outranks the look-around animation, and hud_face_upd's own block had
;   not three bytes left for the test.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_god_gate
 .if 1
        lda PW_INVUL                 ; hud_god's test INLINE (2026-09-15): a frame
        ora PW_INVUL+1               ;   without the sphere goes straight on to
        jne hud_god                  ;   hud_face_upd, no jsr/clc/rts/bcs (-16);
        jmp hud_face_upd             ;   with it, hud_god re-tests and sets C=1,
 .else                                ;   which nobody after draw_hud_gate reads
        jsr hud_god
        bcs ?out
        jmp hud_face_upd
?out    rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; kb_scan -- ONE keyboard sample per VBLANK, from rom_nmi. read_keys samples
;   once per RENDERED frame (~140 ms at this port's fps) and cht_key therefore
;   cannot see a DOUBLED letter: KBCODE latches, so the second press of the same
;   key looks like the first one still held. That is why the port shipped one
;   cheat -- IDKFA, which has no doubled letter -- and why IDDQD could not work.
;   At 20 ms this sees the release between them.
;   A-ONLY: rom_nmi saves nothing but A, and deliberately leaves X/Y alone so a
;   16-bit index survives the VBI.
;--------------------------------------------------------------
.proc kb_scan
        lda SKSTAT
        and #4                       ; bit2 low = a key IS down
        bne ?up
        lda KBCODE
        cmp kb_last
        beq ?out                     ; same key still held: not a new press
        sta kb_last
        sta kb_new                   ; ...and hand it to cht_key
        rts
?up     lda #$FF                     ; released: the NEXT press counts as new
        sta kb_last                  ;   even if it is the same key
?out    rts
.endp
    .if * > VISLIT_END+1
        ert 'pw_vislit + hud_god outgrew VISLIT_BASE..END (memory_map.inc)'
    .endif
        org vsl_resume

cht_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org CHEAT_BASE
 .endif

;--------------------------------------------------------------
; cht_scan -- read_keys calls this instead of cht_key. kb_scan (in the VBI) has
;   already turned the keyboard into PRESS EDGES, so a doubled letter is visible
;   and a second cheat becomes possible. Feeds the one byte to both matchers,
;   then consumes it.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cht_scan
        lda kb_new
        cmp #$FF
        beq ?out                     ; nothing new since the last frame
        pha
        jsr cht_key                  ; IDKFA
        pla
        jsr cht_dqd                  ; IDDQD
        lda #$FF
        sta kb_new
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; cht_dqd -- IDDQD. A = a new key press. Same shape as cht_key, minus the
;   held-key test: kb_new IS the edge, so the doubled D matches.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cht_dqd
        ldx dqd_n
        cpx #DQD_LEN                 ; boot RAM must not index past the table
        bcs ?rst
        cmp dqd_tab,x
        bne ?rst
        inx
        cpx #DQD_LEN
        bcc ?set
        jsr dqd_give
?rst    ldx #0
?set    stx dqd_n
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
dqd_tab dta KEY_I, KEY_D, KEY_D, KEY_Q, KEY_D
DQD_LEN equ * - dqd_tab
dqd_n   dta 0

;--------------------------------------------------------------
; dqd_give -- st_stuff.c's IDDQD: CF_GODMODE. The port has no cheats field, so
;   it does what godmode DOES -- full health and the invulnerability the face
;   already reads (hud_god). Not a timer: DOOM's godmode does not run out, so
;   this parks PW_INVUL at its maximum instead of counting down to it.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc dqd_give
        lda #100
        sta PSTATE+PS_HEALTH
        lda #$FF
        sta PW_INVUL
        sta PW_INVUL+1
        lda #1
        sta hud_dirty
        rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > CHEAT_END+1
        ert 'the cheat matchers outgrew CHEAT_BASE..END (memory_map.inc)'
    .endif
 .endif
        org cht_resume