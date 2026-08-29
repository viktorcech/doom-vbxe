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
        org PWMAP_BASE
;--------------------------------------------------------------
; pw_map -- P_GivePower(pw_allmap), in front of pw_give. Y = bonus id, and it
;   must come back untouched (snd_bonus reads it), so the test is a cpy.
;   28 is the Computer Area Map: am_walls draws every line the BSP walk has not
;   lit yet while this bit is up (am_map.c's pw_allmap branch). 29, the visor,
;   still stores nothing -- this build has no light amp.
;   PARKED HERE and not in pw_give: that block ends ON POWER_END.
;--------------------------------------------------------------
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
    .if * > PWMAP_END+1
        ert 'pw_map outgrew PWMAP_BASE..PWMAP_END (memory_map.inc)'
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
        sec                          ; 28 map / 29 visor: nothing to store
        rts
?invis  lda #<INVISTICS
        ldx #>INVISTICS
        sta PW_INVIS
        stx PW_INVIS+1
        sec
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
?zerk   lda PW_FLAGS
        ora #PWF_BERSERK
        sta PW_FLAGS
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
pw_aidx dta PS_BULLETS, PS_SHELLS, PS_ROCKETS, PS_CELLS
pw_clip dta 10, 4, 1, 20             ; p_inter.c clipammo[]
pw_amax dta 200, 50, 50, 255         ; ...and maxammo[] (cells 300 -> a byte)

;--------------------------------------------------------------
; pw_max -- A = DOOM's maxammo[] for some ammo type -> the cap that applies right
;   now. Preserves X and Y (give_bonus holds the PSTATE index in X, wp_give the
;   weapon in X and the ammo in Y).
;--------------------------------------------------------------
    .if * > POWER_END+1
        ert 'pw_give outgrew POWER_BASE..POWER_END (memory_map.inc)'
    .endif
        org PWMAX_BASE               ; 2026-08-11 win2 evacuation: powerups split
                                     ;   four ways (memory_map.inc POWER/PWMAX/
                                     ;   PWTIC/LFSG)
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

;--------------------------------------------------------------
; pw_tic -- ONE DOOM tic of P_PlayerThink's powers[] half. wp_tic calls THIS
;   instead of fl_tic and this passes it on: the flash block has no room left
;   for another instruction, and both are the same 35 Hz clock anyway.
;--------------------------------------------------------------
    .if * > PWMAX_END+1
        ert 'pw_max outgrew PWMAX_BASE..PWMAX_END (memory_map.inc)'
    .endif
        org PWTIC_BASE
.proc pw_tic
        jsr fl_tic                   ; the palette-flash counters (weapon.asm)
        ldx #4                       ; three u16 counters, 2 B apart
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
        rts
.endp

;--------------------------------------------------------------
; pw_shield -- X = the sector's damage class (1..4, movers.asm). C=1 = this tic's
;   damage is blocked. p_spec.c P_PlayerInSpecialSector: ironfeet stops nukage
;   and slime outright, lets SUPER HELLSLIME through on "P_Random () < 5", and
;   does nothing at all about special 11 (E1M8's finale, class 4). Invulnerability
;   is P_DamageMobj's own test, above all of it. Preserves X.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; pw_spread -- m_a:m_a+1 = |the monster's aim error| in ai_fire's units (a full
;   P_Random spread = 255, and the pellet lands if |spread| * dist < 16 * 620).
;   A_PosAttack rolls (P_Random()-P_Random())<<20; with the blur sphere on the
;   player A_FaceTarget has ALREADY added (P_Random()-P_Random())<<21, so the
;   port sums r1 + 2*r2 -- SIGNED, so the two rolls can still cancel exactly as
;   they do in DOOM. Clobbers A/X and m_b (ai_fire fills m_b right after).
;--------------------------------------------------------------
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
        asl m_b                      ; <<21 = twice <<20
        rol m_b+1
        clc
        lda m_a
        adc m_b
        sta m_a
        lda m_a+1
        adc m_b+1
        sta m_a+1
?abs    lda m_a+1
        bpl ?out
        jsr m_neg                    ; |s|, 16-bit (it can reach 765 now)
?out    rts
;   one P_Random() - P_Random(), sign-extended: A = lo, X = hi (0 or $FF)
?tri    lda RANDOM
        sec
        sbc RANDOM
        ldx #0
        bcs ?p
        ldx #$FF
?p      rts
.endp

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
.proc pw_level
        lda #0
        ldx #6
?z      sta PW_INVIS-1,x
        dex
        bpl ?z
        lda PW_FLAGS
        and #PWF_BPACK
        sta PW_FLAGS
        rts
.endp

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
.proc leaf_segs
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
        rts
.endp

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
.proc sh_dist
        ldx #0                       ; pass 0 = x/cos, pass 2 = y/sin
?lp     lda sh_d
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
        jsr smul_14                  ; m_res = d*cos, then d*sin
        pla
        tax
        clc
        lda USE_PT_A,x
        adc m_res
        sta zp_px,x
        lda USE_PT_A+1,x
        adc m_res+1
        sta zp_px+1,x
        inx
        inx
        cpx #4
        bne ?lp
        rts
.endp

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

    .if * > LFSG_END+1
        ert 'leaf_segs+sh_dist outgrew LFSG_BASE..LFSG_END (memory_map.inc)'
    .endif
        org pw_resume
