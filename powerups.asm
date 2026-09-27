;--------------------------------------------------------------
; powerups.asm -- p_inter.c's powers + the backpack: pickup ids, timers, effects.
;--------------------------------------------------------------
pwm_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; pw_map -- P_GivePower(pw_allmap), in front of pw_give. Y = bonus id, and it
;   must come back untouched (snd_bonus reads it), so the test is a cpy.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_map
        cpy #BN_MAP
        bne ?go
                                      ; 2026-09-21: sim6502 has tsb/trb now, so
        lda #PWF_ALLMAP              ;   the reason below is gone. 8 B/10 cyc ->
        tsb PW_FLAGS                 ;   5 B/8 cyc. A is free -- pw_give
                                     ;   dispatches on Y alone.
?go
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>pw_give              ;   next byte of this segment -- fall through
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
                                      ; 2026-09-21: tsb (A reloaded at ?pk, flags by ldx)
?pack   lda #PWF_BPACK
        tsb PW_FLAGS                 ; (pw_max applies the doubling from here on)
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org PWTIC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_tic
        jsr fl_ztic                  ; the berserk's red fade, then fl_tic --
                                     ;   the palette-flash counters (weapon.asm)
        ldx #4                       ; three u16 counters, 2 B apart
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
                                      ;   loop above: PW_FLAGS occupies the slot a
                                     ;   fourth u16 would have needed.
                                     ; 2026-09-22: pw_vislit INLINE, on the word
        beq ?vst                     ;   still in A (0 left: A = 0 is the answer)
        dec
        sta PW_VISOR
        cmp #129                     ; p_user.c:371: > 4*32 tics left (256+ too):
        bcs ?von                     ;   solid; below, bit 3 IS the blink (0 or 8)
        and #8
        bra ?vst
?von    lda #$FF
?vst    sep #$20
        .LONGA OFF
        cmp vis_lit                  ; only a CHANGE re-points process_seg's shade
        beq ?same                    ;   call (lt_pick) -- lt_seg no longer tests
        sta vis_lit                  ;   the visor per seg
        jmp lt_pick
?same   rts
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
	rep #$20
	.LONGA ON
	lda m_b
	asl
	clc
	adc m_a
	sta m_a
	sep #$20
	.LONGA OFF
?abs    lda m_a+1
        bpl ?out
	jmp m_neg
?out    rts
;   one P_Random() - P_Random(), sign-extended: A = lo, X = hi (0 or $FF)
?tri    lda RANDOM
        sec
        sbc RANDOM
        ldx #0
        bcs ?p
	dex
?p      rts
.endp
        .endseg

;--------------------------------------------------------------
; bl_spread -- P_SpawnMissile's "fuzzy player" (p_mobj.c:909): with MF_SHADOW on
;   the target, an += (P_Random()-P_Random())<<20. ball_spawn aims by VECTOR,
;   so the turn goes onto bl_dx/bl_dy as the small-angle rotation
;       dx' = dx - t*dy        dy' = dy + t*dx        t = r * 2pi/4096 rad
;   hitscan half. Native only (ai_fire -> ball_spawn). Clobbers A/X/Y and
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
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit
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
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit,
        clc                          ;   and that rep also cleared C
        .LONGA ON
;       lda m_res                    ; smul_14 leaves m_res IN A
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
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pw_level
        ldx #6
?z      stz PW_INVIS-1,x
        dex
        bpl ?z
                                      ; 2026-09-21: trb -- clear all BUT the backpack.
        lda #$FF-PWF_BPACK           ;   A and Z differ on return; the one caller
        trb PW_FLAGS                 ;   (bsp_main_load ?psdone) loads A next
                                      ; 2026-09-22: the VISOR is a power too (its
        stz PW_VISOR                 ;   counter lives apart from the other three,
        stz PW_VISOR+1               ;   so the loop above never reached it). vis_lit
        lda #$FF                     ;   = $FF, not 0: the first pw_tic sees a CHANGE
        sta vis_lit                  ;   and re-points ltsj itself (lt_pick is 16-bit;
        rts
.endp
        .endseg

;--------------------------------------------------------------
; leaf_segs -- zp_nid -> that leaf's seg run: zp_sptr = the first seg's record,
;   zp_segcnt = how many. Lifted out of use_leaf 2026-08-05 so the HITSCAN
;   traverse (sh_leaf) can walk the same segs -- it is the only part of use_leaf
;   a bullet shares, since a bullet opens no doors.
;--------------------------------------------------------------
    .if * > PWTIC_END+1
        ert 'pw_tic..pw_level outgrew PWTIC_BASE..PWTIC_END (memory_map.inc)'
    .endif
        org LFSG_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc leaf_segs
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
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sh_dist -- zp_px/zp_py = USE_PT_A + sh_d*(cos,sin): where the hitscan ray is
;   at length sh_d (enemy.asm sh_trace). use_sample's 16-bit twin -- that one
;   takes the distance in A and so stops at 255 units, while the shot ray runs
;   to 1024.
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
                                      ; 2026-09-23: the passes are independent (each
        ldx #2                       ;   writes only zp_px,x): run 2 then 0 and end
 	rep #$20
	.LONGA ON
?lp
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
        jsr smul_14                  ; m_res = d*cos, then d*sin
	plx
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit,
        clc                          ;   and that rep also cleared C
	.LONGA ON
;       lda USE_PT_A,x               ; smul_14 leaves m_res IN A (plx keeps it):
        adc USE_PT_A,x               ;   add the other operand to it
        sta zp_px,x
        dex
        dex
        bpl ?lp                      ; 2 -> 0 -> $FE
                                    ; 2026-09-22 (65816-windows): sh_dist returns 16-bit
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sprcol_read -- read SPRC_SECTORS sectors with read_ext, in passes of 128,
;   because ll_left is a byte and the .sprcol blob is bigger than 255 sectors
;   since the coltab run left bank $01. read_ext writes ll_dst back and
;   read_sectors advances ll_sec, so every pass but the first needs nothing
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
;==============================================================
zerk_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
                                      ; 2026-09-21: tsb (A reloaded on the next line)
        lda #PWF_BERSERK
        tsb PW_FLAGS
        lda #12                     ; bzc at powers[pw_strength] = 1
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
        lda PW_INVUL                 ; hud_god's test INLINE (2026-09-15): a frame
        ora PW_INVUL+1               ;   without the sphere goes straight on to
        jne hud_god                  ;   hud_face_upd, no jsr/clc/rts/bcs (-16);
        jmp hud_face_upd             ;   with it, hud_god re-tests and sets C=1,
.endp
        .endseg

;--------------------------------------------------------------
; kb_scan -- ONE keyboard sample per VBLANK, from rom_nmi. read_keys samples
;   once per RENDERED frame (~140 ms at this port's fps) and cht_key therefore
;   cannot see a DOUBLED letter: KBCODE latches, so the second press of the same
;   key looks like the first one still held.
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org cht_resume