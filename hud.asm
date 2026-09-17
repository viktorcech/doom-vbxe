;==============================================================
; hud.asm -- the DOOM status bar, 1:1 from the WAD.
;--------------------------------------------------------------
; Graphics come from tools/pack_hud.py: STBAR and every glyph, halved
; horizontally (our byte covers two DOOM pixels, like the rest of the picture)
; and streamed into VBXE VRAM $078000 by load_hud. HUD_TAB (in the XEX) gives
; each one its VRAM address, size and patch offsets. (zp_ptr is free here: the
; HUD is drawn after render_world and before the buffer flip.)
;
; Layout is st_stuff.c: the bar covers rows 168..199, ammo/health/armour are big
; red STTNUM digits right-aligned at x=44/90/221 (DOOM pixels) on y=171, with
; STTPRCNT drawn at the same x as the number's right edge. Values come from
; PSTATE, which spr_pickup fills. Numbers are blitted with BLT_BSTENCIL so the
; bar shows through the glyph gaps, the bar itself with BLT_COPY.
;
; REPAINT MODEL (2026-07-28, = w3d hud.asm): the bar + widgets are static
; between events and the 3D view never touches rows 168+, so the full repaint
; below runs only while hud_dirty > 0 (set by init_doors, a taken pickup, a
; face change). The steady-state frame draws NOTHING (the face timer + two
; loads). The old code repainted everything every frame: ~16 blits with a
; blitter_wait each, against w3d's idle cost of one load.
; 2026-08-03: hud_dirty is 1, not 2 -- the bar rows are SHARED between the two
; buffers now (VRAM_HUDROWS + the XDL's second entry), so one repaint is the
; whole job and hud_blit always targets bank 0.
;==============================================================
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc draw_hud
        jsr bar_bg                   ; background first -- 320x32, its own BCB
        jsr hud_ammo                 ; the ready weapon's own ammo type
        lda PSTATE+PS_HEALTH
        ldx #ST_HEALTHX
        jsr hud_num
        lda #HUD_PCT
        ldx #ST_HEALTHX
        jsr hud_glyph
        lda PSTATE+PS_ARMOR
        ldx #ST_ARMORX
        jsr hud_num
        lda #HUD_PCT
        ldx #ST_ARMORX
        jsr hud_glyph
        lda #HUD_ARMS                ; single player: STARMS covers the FRAG box
        ldx #ST_ARMSX
        jsr hud_top
        lda face_cur                 ; the face (hud_face_upd animates it)
        ldx #ST_FACEX
        jsr hud_top
        jmp hud_keys                 ; STKEYS icons for the PS_KEYS bits
.endp
        .endseg

;--------------------------------------------------------------
; hud_top -- A = HUD_TAB index, X = x: a graphic that sits on the bar's top row.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_top
        jsr hud_entry
        ldy #HUD_BAR_Y
        jmp bar_blit                 ; ...which is bank $01 too: a plain jsr
.endp
        .endseg

;--------------------------------------------------------------
; hud_num -- A = value (0..255), X = right edge column. STlib_drawNum: digits are
;   emitted right to left and leading zeros are not drawn.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_num
        sta hd_val
        stx hd_x
?dloop  ldx #0                       ; digit = val mod 10, val /= 10
        lda hd_val
?div    cmp #10
        bcc ?have
        sbc #10
        inx
        bne ?div
?have   stx hd_val                   ; (A = the digit: sta sets no flags and the
        clc                          ;   hd_dig copy was never read -- hud_glyph_left
        adc #HUD_DIG0                ;   overwrites it with the width)
        ldx hd_x
        jsr hud_glyph_left
        stx hd_x                     ; hud_glyph_left returns the new left edge
        lda hd_val
        bne ?dloop
        rts
.endp
        .endseg

;--------------------------------------------------------------
; hud_glyph / hud_glyph_left -- A = HUD_TAB index, X = x. hud_glyph puts the
;   glyph's LEFT edge at x; hud_glyph_left puts its RIGHT edge there and returns
;   the new left edge in X (that is how the number loop walks leftwards).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_glyph_left
        jsr hud_entry                ; -> zp_ptr, width in A
        sta hd_dig                   ; width
        txa
        sec
        sbc hd_dig
        tax
        stx hd_x
        ldy #ST_NUMY
        jsr bar_blit
        ldx hd_x
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_glyph
        jsr hud_entry
        ldy #ST_NUMY
        jmp bar_blit
.endp
        .endseg

;--------------------------------------------------------------
; hud_entry -- A = HUD_TAB index -> zp_ptr = &entry, A = width.
;--------------------------------------------------------------
;   X IS THE CALLER'S COLUMN AND MUST SURVIVE. hud_top, hud_glyph and
;   hud_glyph_left all take it in X, hud_blit's first instruction is `stx hd_x`,
;   and hud_glyph_left does `txa` the moment this returns. The first attempt at
;   the move below indexed the table with X (`lda.l HUD_TAB_EXT,x`) and wrecked
;   every graphic's position on the bar -- 2026-08-30, and no test caught it
;   because none of them draw the HUD. tools/tests/_verify_hudtab.py does now.
;   So: A and Y only.
;   HUD_TAB lives in Rapidus bank $01 (bank01.asm), six bytes a row -- the u24's
;   high byte is HUD_TAB_HI, one constant for the whole table. The row is copied
;   DOWN into hud_ent, so hud_blit, fps_emit, the automap's and the finale's
;   entries into it all read exactly the seven bytes they always read.
hent_resume = *
        org HUDENT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_entry
 .if 1
        asl                          ; index*6 = *4 + *2 (six, not seven: see
        sta m_a+1                    ;   HUD_TAB_HI above): *2 parked, *4 in A
        asl
        clc
        adc m_a+1
        clc
        adc #<HUD_TAB                ; HUD_TAB is an OFFSET inside bank $01
        sta zp_ptr
        lda #0
        adc #>HUD_TAB
        sta zp_ptr+1
        lda #MAP_EXT_BANK            ; SET THE BANK BYTE, do not inherit it (the
        sta zp_ptr+2                 ;   .else side says why)
        rep #$20                     ; ---- 16-bit A: the 6-byte record as three
        .LONGA ON                    ;   words -- vram lo/mid, then w/h and
        lda [zp_ptr]                 ;   left/top one byte up (HUD_TAB_HI sits
        sta hud_ent                  ;   between them in hud_ent). The two byte
        ldy #2                       ;   loops were ~110 cycles; this is ~45.
        lda [zp_ptr],y
        sta hud_ent+3
        ldy #4
        lda [zp_ptr],y
        sta hud_ent+5
        lda #hud_ent                 ; ...and zp_ptr -> the copy (one word store)
        sta zp_ptr
        sep #$20
        .LONGA OFF
        lda #HUD_TAB_HI              ; ...and the byte the table stopped storing
        sta hud_ent+2
        lda hud_ent+3                ; the width, as before
        rts
 .else
        sta m_a                      ; index*6 = *4 + *2 (six, not seven: see
        asl                          ;   HUD_TAB_HI above)
        sta m_a+1
        asl
        clc
        adc m_a+1
        clc
        adc #<HUD_TAB                ; HUD_TAB is an OFFSET inside bank $01
        sta zp_ptr
        lda #0
        adc #>HUD_TAB
        sta zp_ptr+1
        lda #MAP_EXT_BANK            ; SET THE BANK BYTE, do not inherit it:
                                     ;   (HUD_TAB sits in bank01.asm's block,
                                     ;   and b1_to_ext copies that block into
                                     ;   the DATA bank too, 2026-09-13 -- so
                                     ;   this and every map reader after it
                                     ;   agree on the bank)
        sta zp_ptr+2                 ;   init_level parks it here for the map
                                     ;   readers, but the save/load picker draws
                                     ;   these digits at the TITLE too, before
                                     ;   init_level has ever run
        ldy #1                       ; the VRAM address' low 16 bits
?vram   lda [zp_ptr],y
        sta hud_ent,y
        dey
        bpl ?vram
        lda #HUD_TAB_HI              ; ...and the byte the table stopped storing
        sta hud_ent+2
        ldy #5                       ; w, h, left, top -> hud_ent+3..+6
?rest   lda [zp_ptr],y
        sta hud_ent+1,y
        dey
        cpy #1
        bne ?rest
        lda #<hud_ent
        sta zp_ptr
        lda #>hud_ent
        sta zp_ptr+1
        lda hud_ent+3                ; the width, as before
        rts
 .endif
.endp
        .endseg
    .if * > HUDENT_END+1
        ert 'hud_entry outgrew HUDENT_BASE..END (memory_map.inc)'
    .endif
        org hent_resume

;--------------------------------------------------------------
; hud_keys -- ST_drawKeys / w3d hud_draw_keys: one STKEYS glyph per PS_KEYS bit
;   (blue/yellow/red) at DOOM x=239 (ST_KEYX), rows 171/181/191. A missing key
;   shows the bar background, exactly like DOOM. Parked at HUDKEYS_BASE: this
;   widget region ($AF40) is tight.
;--------------------------------------------------------------
hk_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org HUDKEYS_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_keys
?l      ldx hk_i
        lda hk_bit,x
        and PSTATE+PS_KEYS
        beq ?next
        clc
        lda #HUD_KEY0                ; STKEYS0..2 = blue/yellow/red card
        adc hk_i
        jsr hud_entry                ; -> zp_ptr (clobbers Y)
        ldx hk_i
        ldy hk_row,x
        ldx #ST_KEYX
        jsr bar_blit
?next   inc hk_i
        lda hk_i
        cmp #3
        bcc ?l
        stz hk_i                     ; rewind for the next frame
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
hk_bit  dta 1,2,4                    ; PS_KEYS bits (= BN_AMT of bonus ids 22-24)
hk_row  dta ST_KEY0Y, ST_KEY0Y+10, ST_KEY0Y+20
hk_i    dta 0
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > HUDKEYS_END+1
        ert 'hud_keys outgrew HUDKEYS_BASE..END (memory_map.inc)'
    .endif
 .endif
        org hk_resume

;--------------------------------------------------------------
; draw_hud_gate -- the per-frame overlay entry (replaces draw_hud in the main
;   loop): the weapon psprites first (they are part of the VIEW and go down every
;   frame), then the face animation, then the full bar repaint while
;   hud_dirty > 0. The idle frame draws nothing but the gun. w3d draw_hud, DOOM
;   widgets. draw_weapon is called from HERE and not from the frame loop because
;   the $2000 engine segment ends flush against VWQ34_BASE ($2705).
;--------------------------------------------------------------
hdyn_resume = *
        org HUDDYN_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc draw_hud_gate
        jsr update_flash             ; ST_doPaletteStuff: the damage/pickup tint
        jsr am_wgate                 ; = draw_weapon, unless the AUTOMAP is up:
                                     ;   DOOM's map replaces the view, gun and
                                     ;   all, but keeps the status bar below

        jsr hud_god_gate             ; STFGOD0 first (priority 4), else the
                                     ;   look-around animation. Both in
                                     ;   powerups.asm -- this block is full.
        lda hud_dirty
        beq ?tail
        dec hud_dirty
        jsr draw_hud
?tail   jmp msg_tick                 ; HU_Drawer's message line, which tail-calls
.endp                                ;   hud_tail (no byte left here for a jsr of
        .endseg
                                     ;   its own: see HUDDYN in memory_map.inc)

;--------------------------------------------------------------
; hud_face_upd -- ST_updateFaceWidget's idle branch: every ST_FACECOUNT
;   (0.5 s) pick one of the three look-around faces (st_randomnumber % 3).
;   A weapon pickup parks the evil grin in face_cur for GRIN_VB first
;   (spr_pickup sets it, like priority 8 in st_stuff.c). A CHANGED face marks
;   hud_dirty so the shared bar is repainted once.
;   hud_pain runs FIRST -- it is what the frame loop calls, and it falls in
;   here. Pain outranks the idle face (priority 7/6 against nothing), which is
;   the order st_stuff.c walks.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_face_upd
        lda face_t                   ; VBLANK countdown, like the door timers
        sec
        sbc dt_vbl
        bcs ?keep
        lda PSTATE+PS_HEALTH         ; DOOM ST_calcPainOffset: the face tracks
        cmp #67                      ;   HEALTH. 3 levels instead of DOOM's 5 --
        bcs ?f0                      ;   that is what fits the HUD VRAM slot.
        cmp #34
        lda #HUD_FACE_CRIT
        bcc ?have
        lda #HUD_FACE_HURT
        bne ?have                    ; (never 0)
?f0     lda #HUD_FACE
?have   sta face_base
        lda RANDOM                   ; 0..3; 3 -> straight (slight centre bias,
        and #3                       ;   M_Random%3 is biased too)
        cmp #3
        bne ?r
        lda #1
?r      clc
        adc face_base
        cmp face_cur
        beq ?same
        sta face_cur
        jsr hud_faceup2              ; face-only: 2 blits (hud_facefix), or
                                     ;   nothing if a full repaint is pending
?same   lda #FACE_VB
?keep   sta face_t
        rts
.endp
        .endseg

;--------------------------------------------------------------
; hud_hurt -- ST_updateFaceWidget priorities 7 and 6, the ones the port never
;   had (2026-08-07, "tvar v HUDe by sa mala menit pri damage, pri zasahu,
;   alebo ked stoji v kyseline"). Called from fl_damage, which is where EVERY
;   source of pain funnels: a monster's hit (enemy.asm) and the nukage floor
;   (update_damage, movers.asm) both go through it.
;
;   IT HAS TO HANG OFF fl_damage AND NOT OFF fl_dmg. Reading the counter once a
;   frame was the obvious thing and it silently missed the acid: update_pz
;   tail-calls update_damage and then wp_think, and wp_think runs a DOOM tic per
;   VBLANK of the frame -- seven of them at five frames a second -- so fl_tic had already
;   decayed the nukage's 5 points back to zero before the HUD ever looked. The
;   monster hits only worked because they are bigger than a frame's worth of
;   decay. The EVENT is the truth here, not the counter.
;
;   WHICH FACE, out of st_stuff.c and not out of a guess. DOOM splits the
;   branch three ways -- ouch face, turn toward the attacker, rampage face --
;   but the ouch arm is dead code in vanilla:
;       if (plyr->health - st_oldhealth > ST_MUCHPAIN)   // ouch
;   and st_oldhealth is LAST tic's health (st_stuff.c:994), so taking damage
;   makes that difference NEGATIVE and it can never clear +20. What actually
;   shows is ST_RAMPAGEOFFSET -- STFKILL -- for a hit with no attacker (the
;   nukage, a crusher) and for a monster standing head-on; only the turn-left/
;   turn-right pair differs, and those are six more patches than the HUD VRAM
;   slot has room for (pack_hud.py).
;
;   The evil grin outranks it (8 > 7), which is why it is tested here: the port
;   has no `priority` variable, the face id itself carries the rank.
;
;   ONE PLACE FOR "IT HURT" (the player asked for it in as many words: "nevies to
;   proste zjednotit? damage hocijake.. zvuk, plus face"). The grunt and the
;   dirty-bar mark used to be copy-pasted into en_plr_hurt and update_damage, ten
;   bytes each, and the face would have been a third copy. They are one event, so
;   they live in one routine on the one path both take. The KILLING blow does not
;   come through here -- both callers branch to pl_die before fl_damage -- which
;   is also what DOOM does: P_KillMobj plays the death scream and never enters
;   the pain state, so the grunt no longer talks over the death cry.
;--------------------------------------------------------------
hp_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org HUDPAIN_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_hurtfx                      ; A = the damage that got through
        jsr fl_damage                ; damagecount += it (the red screen flash)
        pha                          ; ...and hand its A back untouched: the E1M8
                                     ;   finale test in update_damage reads it
 .if 1                                ; THE TINT AT THE EVENT (2026-09-15, "ked
        phx                          ;   stojim v kyseline ... s texturami
        jsr update_flash             ;   neblika"). The frame's own update_flash
        plx                          ;   runs after wp_think, whose tic batch
 .else                                ;   decays fl_dmg first: a textured frame is
        ;nothing                     ;   14-16 VBLANKs = ~10 tics, so the
 .endif                               ;   nukage's 5 was always back to 0 (flat,
                                     ;   6-7 VBLANKs, sometimes left 1). The
                                     ;   hud_hurt note above, for the palette.
                                     ;   X is update_damage's damage class and
                                     ;   xdl_att takes X; Y is not touched.
        lda #SFX_PLPAIN              ; A_Pain: MT_PLAYER painchance is 255, so a
        sta snd_pending              ;   hit that lands always grunts
        lda #1
        sta hud_dirty                ; health/armour changed -> repaint the bar
        lda face_cur
        cmp #HUD_FACE_GRIN           ; a weapon pickup is priority 8
        beq ?out
        lda PSTATE+PS_HEALTH         ; ST_calcPainOffset, the same three levels
        cmp #67                      ;   the look-around faces use
        bcs ?f0
        cmp #34
        lda #HUD_FACE_RAGE+2
        bcc ?have
        lda #HUD_FACE_RAGE+1
        bne ?have                    ; (never 0)
?f0     lda #HUD_FACE_RAGE
?have   cmp face_cur
        beq ?arm                     ; already grimacing: just hold it there
        sta face_cur
?arm    lda #TURN_VB                 ; ST_TURNCOUNT. Every nukage tic re-arms it
        sta face_t                   ;   and they come every DMG_VB 46 < 50, so
?out    pla                          ;   the face never lets go while you stand
        rts                          ;   in it
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > HUDPAIN_END+1
        ert 'hud_pain outgrew HUDPAIN_BASE..HUDPAIN_END (memory_map.inc)'
    .endif
 .endif
        org hp_resume

;--------------------------------------------------------------
; hud_ammo -- ST_Ticker's w_ready widget: the big red number is the READY
;   WEAPON's ammo type, not always bullets (st_stuff.c indexes
;   weaponinfo[readyweapon].ammo). The fist is am_noammo, and DOOM draws no
;   number at all for it. Lives here rather than inline in draw_hud: that block
;   ($AF40) ends flush against sprites.asm at $B000.
;   2026-08-10: parked at HUDAMMO_BASE -- the HUDDYN bytes were wanted elsewhere.
;--------------------------------------------------------------
ham_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org HUDAMMO_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_ammo
        ldx wp_cur
        ldy wi_ammo,x
        bmi ?none
        lda PSTATE,y
        ldx #ST_AMMOX
        jmp hud_num
?none   rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > HUDAMMO_END+1
        ert 'hud_ammo outgrew HUDAMMO_BASE..END (memory_map.inc)'
    .endif
 .endif
        org ham_resume

;--------------------------------------------------------------
; pickup_bonus -- snd_bonus + the dirty-HUD marks, C = "taken" like snd_bonus.
;   Lives HERE and not inline in spr_pickup: the sprites segment ends flush at
;   $B7C0 (mv_ptr is next), so the wrapper keeps it byte-identical.
;   A taken pickup repaints the bar (w3d hud_mark_dirty), a WEAPON parks the
;   evil grin for 2 s (ST_updateFaceWidget priority 8), and every one of them
;   sets the MESSAGE (P_TouchSpecialThing's `player->message = ...`).
;   THE MESSAGE HANGS OFF THE SAME "taken" ANSWER as the sound and the flash:
;   in p_inter.c every arm that can refuse (`if (!P_GiveBody...) return`) does
;   so BEFORE the assignment, so a medikit at full health must stay silent and
;   say nothing -- which is exactly the bcc above.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pickup_bonus
        jsr snd_bonus                ; Y = bonus id, preserved
        bcc ?out                     ; not usable -> nothing changed
        lda #1
        sta hud_dirty
        cpy #16                      ; bonus 16-21 = a weapon
        bcc ?tk
        cpy #22
        bcs ?tk
        lda #HUD_FACE_GRIN           ; P_GiveWeapon itself ran back in give_bonus
        sta face_cur                 ;   (wp_give, one routine) -- and it already
        lda #GRIN_VB                 ;   said "taken", or we branched out above,
        sta face_t                   ;   so there is nothing to call here
?tk     jsr msg_set                  ; player->message (Y is still the bonus id)
        jsr fl_bonusadd              ; ST_doPaletteStuff's gold flash
        sec                          ; restore "taken"
?out    rts
.endp
        .endseg
    .if * > HUDDYN_END+1
        ert 'draw_hud_gate/hud_face_upd/pickup_bonus outgrew HUDDYN (memory_map.inc)'
    .endif
        org hdyn_resume

;--------------------------------------------------------------
; hud_facefix -- the look-around face swap WITHOUT the full bar repaint
;   (2026-08-31): hud_face_upd used to set hud_dirty every FACE_VB and buy
;   draw_hud's ~14 blits (each behind a blitter_wait) for a 12x31 cell.
;   Two blits instead: restore the cell out of the STBAR GRAPHIC -- a
;   sub-rectangle, so the BCB is built by hand; the 7-byte HUD_TAB format
;   cannot say SRC_STEPY != WIDTH, the same reason mn_box exists -- then
;   stencil face_cur over it.
;   THE CELL IS CONSTANT, and that is load-bearing: every face lump in
;   hud.tab is w=12 with left=-3 (so every face draws at x=74..85) and the
;   tops are 169/170, bottoms 198/199 -- x74,y169,12x31 covers ANY old face
;   under ANY new one. A different-height lump only arrives with a health
;   tier change or the grin, and both of those come through paths that set
;   hud_dirty (pl_hurtfx, pickup_bonus, savegame) -> the full repaint runs
;   and hud_faceup2 skips this proc.
;--------------------------------------------------------------
FF_X      equ ST_FACEX+3             ; 146: every face lump has left = -3
FF_Y      equ HUD_BAR_Y+1            ; 169: the earliest face top (hud.tab)
FF_W      equ 24                     ; DOOM pixels -- a byte is one on the bar
FF_H      equ 31
FF_ROW    equ FF_Y-HUD_BAR_Y         ; ...and the bar's OWN row, 0-based
FF_SRCOFF equ FF_ROW*HUDV_BARW+FF_X
hffx_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org HUDFFIX_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_faceup2
        lda hud_dirty                ; a full repaint is pending and includes
        bne ?skip                    ;   the face -> nothing to do here
        jmp hud_facefix
?skip   rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_facefix
        lda #<[HUDV_STBAR+FF_SRCOFF] ; SRC = STBAR + row 1, column 146: the
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR      ; cell's own pixels inside the
        lda #>[HUDV_STBAR+FF_SRCOFF]           ; bar image. A CONSTANT now --
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1    ; STBAR left HUD_TAB when it grew
        lda #[[HUDV_STBAR+FF_SRCOFF]>>16]      ; past the row's width byte, so
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2    ; there is no entry to look up
        lda #<HUDV_BARW              ; sub-rectangle: the source steps by the
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY     ; BAR's row (320), not by its
        lda #>HUDV_BARW                        ; width -- which is why this
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; builds its own BCB at all
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #<[VRAM_BAR320+FF_ROW*HUDV_BARW+FF_X]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; DST = the same cell on the bar,
        lda #>[VRAM_BAR320+FF_ROW*HUDV_BARW+FF_X]      ; also a constant
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        lda #[VRAM_BAR320>>16]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; BLT_COPY = 0: opaque
        lda #FF_W-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #FF_H-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jsr bar_fire                 ; wait out the previous blit, fire this one
        stz MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; ...and the 16-bit step back to
                                     ;   a byte: the BCB is LATCHED at start
                                     ;   (alt-src vbxe.cpp LoadBlitter reads all
                                     ;   21 bytes), so this cannot disturb the
                                     ;   blit that is running
        lda face_cur                 ; ...and the face itself: ONE stencil blit
        ldx #ST_FACEX                ;   (hb_ctrl rests at BLT_BSTENCIL)
        jmp hud_top
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > HUDFFIX_END+1
        ert 'hud_facefix outgrew HUDFFIX_BASE..END (memory_map.inc)'
    .endif
 .endif
        org hffx_resume

;==============================================================
; THE MESSAGE LINE (2026-08-16, "ked nieco vezmem, hore sa zjavi popisok").
; hu_stuff.c's w_message: what P_TouchSpecialThing parks in player->message
; shows across the TOP of the view for HU_MSGTIMEOUT (4*TICRATE = 4 s) and then
; goes. DOOM keeps a char* and re-composes the line from hu_font every frame;
; this port keeps a STRIP INDEX and blits one rectangle -- the text was
; rasterised at pack time with the same STCFN glyphs (tools/pack_menu.py), and
; am_title.strip_blit already knew how to draw one. So the whole widget is the
; two routines below: ~40 bytes, which is what the fast windows had left.
;
; WHY IT NEEDS NO ERASE. The message sits inside the VIEW, and the view is
; repainted from the BSP walk every single frame into whichever back buffer the
; triple buffer hands out -- so a frame that does not draw the message has
; already erased it. (The status bar's widgets need hud_dirty for exactly the
; opposite reason: rows 168+ are never touched by the renderer.)
;
; THE TIMER IS IN VBLANKs, not frames -- the same rule the face, the doors and
; the lifts follow (dt_vbl = frame_dt). 4 seconds is 4 seconds at five frames and at
; 50. It counts down one frame late: the frame that takes msg_t to zero still
; draws. Making that exact costs a second branch and this block has one byte
; left; a single frame of a 4-second message is not visible.
;==============================================================
mtk_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org MSGTICK_BASE
 .endif
;--------------------------------------------------------------
; msg_tick -- HU_Ticker + HU_Drawer in one, called as draw_hud_gate's TAIL (it
;   inherits the frame's blitter state and the MEMAC window on BANK_OVERHEAD)
;   and leaving through hud_tail, which is the tail it displaced.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc msg_tick
        lda msg_t                    ; nothing showing -> the whole widget is
        beq ?none                    ;   two loads and a branch
        sec
        sbc dt_vbl                    ; VBLANKs, not frames (see the header)
        bcs ?keep
        lda #0                       ; expired: floor it, do not wrap
?keep   sta msg_t
        lda msg_i                    ; the strip pack_menu.py rasterised for this
        ldx #MSG_Y                   ;   bonus id -- hu_stuff.c HU_MSGX/Y = 0,0
        jsr am_title.strip_blit
?none   jmp hud_tail                 ; ...and on to whatever draws over the view
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > MSGTICK_END+1
        ert 'msg_tick outgrew MSGTICK_BASE..END (memory_map.inc)'
    .endif
 .endif
        org mtk_resume

mst_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org MSGSET_BASE
 .endif
;--------------------------------------------------------------
; msg_set -- Y = the bonus id that was just TAKEN -> the message for it, armed
;   for MSG_VB. p_inter.c assigns player->message inside every arm of the
;   switch; here the id indexes the strip array, so one routine covers them all.
;   The +MSG_IDX0 is the automap level names sharing the array (the strips
;   are one table so ONE blitter serves both -- automap.asm's header).
;   GOTMEDINEED (2026-08-31): the medikit's other line. Vanilla tests
;   health<25 AFTER P_GiveBody(25) (p_inter.c:477-480), which can never be
;   true -- the famous unreachable message. This is the INTENT instead: the
;   pickup was usable, so POST-add health < 50 is EXACTLY pre-add < 25 (the
;   cap at 100 cannot pull a sum below 50). Y is preserved for the caller.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc msg_set
        cpy #2                       ; the medikit is bonus id 2 (GOTMEDIKIT)
        bne ?norm
        lda PSTATE+PS_HEALTH
        cmp #50
        bcs ?norm
        lda #35+MSG_IDX0             ; GOTMEDINEED's strip (pack_menu.py)
        bne ?arm                     ; (always: MSG_IDX0 > 0)
?norm   tya
        clc
        adc #MSG_IDX0
msg_arm                              ; A = a RAW strip index: door_keymsg's
?arm    sta msg_i                    ;   entry (msg_set.msg_arm) for lines
                                     ;   that are not bonus ids
        lda #MSG_VB
        sta msg_t
        rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > MSGSET_END+1
        ert 'msg_set outgrew MSGSET_BASE..END (memory_map.inc)'
    .endif
 .endif
        org mst_resume

hud_split_resume = *
        org HUDBLIT_BASE             ; the blit half lives below the MEMAC window
;--------------------------------------------------------------
; hud_blit -- blit the entry at zp_ptr to column X, row Y of the FRAMEBUFFER:
;   160 bytes a row, one byte = two hardware pixels. The gun, the message strip,
;   the FPS readout, the menus, the intermission and the finale all come through
;   here. THE STATUS BAR DOES NOT ANY MORE -- it is a 320-byte-a-row SR surface
;   of its own and bar_blit draws it (2026-09-16).
;   hud_blit_bg went with it: the only caller was draw_hud's STBAR fill, and at
;   320 that is 320 bytes wide -- more than the 7-byte record's width byte can
;   say -- so it is bar_bg's hand-built BCB now.
;--------------------------------------------------------------
.proc hud_blit
 .if 1
        ; 2026-09-09 (drac030 style), 8-BIT ON PURPOSE: the boot menu calls
        ; this with the ROM in (E=1), where rep/sep do nothing -- so no 16-bit
        ; block here, only the idioms: (zp) without an index, dec A for the
        ; -1s, stz, and the patch offsets subtracted straight from the
        ; operand instead of through m_a. The row leaves in X, not hd_dig.
        stx hd_x
        sty hd_dig                   ; row (parked: Y indexes the entry below)
        lda (zp_ptr)                 ; SRC = the graphic in VRAM
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        ldy #1
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        iny
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        iny                          ; width: SRC_STEPY = width, WIDTH = width-1
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        stz MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; draw_weapon shares this BCB and
        lda #1                       ;   SCALES the source with the view window
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX     ;   (SRC_STEPX/STEPY > 1). The bar is
        iny                          ;   always 1:1, so undo that here.
        lda (zp_ptr),y               ; height
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        iny                          ; V_DrawPatch: the patch's own offsets shift it
        lda hd_x                     ;   (STFST01 has left=-3 bytes, top=-2 --
        sec                          ;   without this the face sits 3 bytes left
        sbc (zp_ptr),y               ;   and 2 rows high of where DOOM puts it)
        sta hd_x
        iny
        lda hd_dig
        sec
        sbc (zp_ptr),y
        tax                          ; DST = row(y) + x -- ALWAYS bank 0: rows
        lda row_lo,x                 ;   168+ are the SHARED bar (VRAM_HUDROWS,
        clc                          ;   FRAME_A's own bar area) that the XDL's
        adc hd_x                     ;   second entry shows under BOTH buffers,
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR    ; so the bar is painted ONCE
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
hb_dbnk                              ; ...and hb_dbnk+1 IS the bank byte (below)
        lda #[VRAM_SCREEN>>16]       ; bank 0 for the BAR (rows 168+ are SHARED
                                     ;   between the buffers, so the bar is painted
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2  ; once) -- but the BACK BUFFER's bank
                                     ;   for anything drawn inside the VIEW.
                                     ;   THE OPERAND ITSELF is hb_dbnk: a view-side
                                     ;   caller pokes the immediate and puts it
                                     ;   back; nothing else touches it.
        lda hb_ctrl
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
hud_fire                             ; menu.asm's mn_erase builds its own BCB
                                     ;   (a background sub-rectangle, which the
                                     ;   7-byte table format cannot express) and
                                     ;   jumps in HERE to fire it -- the tail is
                                     ;   the same wait-and-start either way
        jsr blitter_wait_t
        lda #<VRAM_BCB_HUD
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_HUD
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_HUD>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START
        ldx hd_x
        rts
 .else
        stx hd_x
        sty hd_dig                   ; row
        ldy #0                       ; SRC = the graphic in VRAM
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        iny
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        iny
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        iny                          ; width: SRC_STEPY = width, WIDTH = width-1
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #0                       ; draw_weapon shares this BCB and SCALES the
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; source with the view window
        lda #1                       ; (SRC_STEPX/STEPY > 1). The status bar is
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX     ; always 1:1, so undo that here.
        iny                          ; height
        lda (zp_ptr),y
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        ldy #5                       ; V_DrawPatch: the patch's own offsets shift it
        lda (zp_ptr),y               ; (STFST01 has left=-3 bytes, top=-2 -- without
        sta m_a                      ;  this the face sits 3 bytes left and 2 rows
                                     ;  high of where DOOM puts it). The `sec`/
                                     ;  `sbc #0` that used to sit here subtracted
                                     ;  nothing at all -- 3 B and 4 cycles.
        sec
        lda hd_x
        sbc m_a
        sta hd_x
        ldy #6
        lda (zp_ptr),y
        sta m_a
        sec
        lda hd_dig
        sbc m_a
        sta hd_dig
        ldx hd_dig                   ; DST = row(y) + x -- ALWAYS bank 0: rows
        lda row_lo,x                 ;   168+ are the SHARED bar (VRAM_HUDROWS,
        clc                          ;   FRAME_A's own bar area) that the XDL's
        adc hd_x                     ;   second entry shows under BOTH buffers,
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR    ; so the bar is painted ONCE
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
hb_dbnk                              ; ...and hb_dbnk+1 IS the bank byte (below)
        lda #[VRAM_SCREEN>>16]       ; bank 0 for the BAR (rows 168+ are SHARED
                                     ;   between the buffers, so the bar is painted
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2  ; once) -- but the BACK BUFFER's bank
                                     ;   for anything drawn inside the VIEW.
                                     ;   THE OPERAND ITSELF is hb_dbnk: this run
                                     ;   had ONE byte left, and `lda abs` is one
                                     ;   more than `lda #`. A view-side caller
                                     ;   pokes the immediate and puts it back;
                                     ;   nothing else touches it.
        lda hb_ctrl
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
hud_fire                             ; menu.asm's mn_erase builds its own BCB
                                     ;   (a background sub-rectangle, which the
                                     ;   7-byte table format cannot express) and
                                     ;   jumps in HERE to fire it -- the tail is
                                     ;   the same wait-and-start either way
        jsr blitter_wait
        lda #<VRAM_BCB_HUD
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_HUD
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_HUD>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START
        ldx hd_x
        rts
 .endif
.endp

hb_ctrl dta BLT_BSTENCIL             ; COPY for the bar, stencil for the glyphs
                                     ; (hb_dbnk is hud_blit's other parameter and
                                     ;  is the immediate operand above, not a
                                     ;  variable: this run had ONE byte left)
    .if * > HUDBLIT_END+1
        ert 'hud_blit outgrew HUDBLIT_BASE..END (memory_map.inc)'
    .endif
        org hud_split_resume

;==============================================================
; THE SR STATUS BAR (2026-09-16).
;--------------------------------------------------------------
; The bar is not part of the framebuffer any more. The XDL's bottom eight
; entries scan VRAM_BAR320 in SR -- 320 bytes a row, one byte per hardware
; pixel -- while everything above them stays LR at 160 (xdl.asm), so STBAR, the
; big red digits and the face have twice the horizontal samples they used to.
;
; That makes the bar a SECOND SURFACE, and the three routines below are what
; hud_blit would be if its destination were that surface instead of the
; framebuffer. They differ in exactly two things, which is also the whole list
; of what menu.asm's mn_sdraw/mn_sdst differ in (same trick, same reason -- the
; boot menu draws into the 320-wide title picture):
;
;   * the destination steps 320 bytes a row, not SCREEN_WIDTH. That is a
;     property of the SCREEN, so bar_fire sets it around the start and puts it
;     back -- the HUD BCB is shared with the gun, the message strip and the FPS
;     readout, which are all still 160-wide;
;   * the row is row_lo/row_hi DOUBLED, and the column is NOT doubled at all:
;     x is a DOOM pixel and a byte is a DOOM pixel here. The x equs went back to
;     st_stuff.c's own numbers (memory_map.inc ST_AMMOX 44, ST_HEALTHX 90 ...).
;
; NO ZOOM. mn_sdraw blits 160-wide patches into a 320-wide picture and leans on
; BLT_ZOOM_2X to stretch them; these lumps are packed at full width
; (tools/pack_hud.py), so the zoom stays 0 and the pixels are DOOM's own.
;==============================================================
    .if [VRAM_BAR320 & $FF] != 0
        ert 'VRAM_BAR320 must be page-aligned: bar_blit adds only its HIGH byte'
    .endif
    .if VRAM_BAR320 + HUDV_BARW*HUDV_BARH > $080000
        ert 'the SR bar runs past the 512 KB VRAM top and would wrap onto FRAME_A'
    .endif
    .if HUDV_BARH != 200-HUD_BAR_Y
        ert 'STBAR is not ST_HEIGHT rows -- the XDL scans exactly 32 (xdl.asm)'
    .endif
;   DRAC_PLAN 3a: NO org and NO ert -- this is bank-$01 code, and the B1
;   segment has no fixed block addresses. MADS fails the build itself when it
;   outgrows B1SEG_LEN (memory_map.inc).
;--------------------------------------------------------------
; bar_blit -- zp_ptr = a 7-byte hud_ent, X = column, Y = row. hud_blit's
;   contract exactly, so hud_top/hud_glyph/hud_num/hud_keys reach it by swapping
;   one jsr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bar_blit
        stx hd_x
        sty hd_dig                   ; row (parked: Y indexes the entry below)
        lda (zp_ptr)                 ; SRC = the graphic in VRAM
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        ldy #1
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        iny
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        iny                          ; width: SRC_STEPY = width, WIDTH = width-1
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        stz MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; draw_weapon shares this BCB and
        lda #1                                 ;   SCALES the source with the
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX     ;   view window; the bar is 1:1
        iny
        lda (zp_ptr),y               ; height
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        iny                          ; V_DrawPatch: the patch's own offsets shift
        lda hd_x                     ;   it (every face lump has left = -3)
        sec
        sbc (zp_ptr),y
        sta hd_x
        iny
        lda hd_dig
        sec
        sbc (zp_ptr),y
        sec
        sbc #HUD_BAR_Y               ; ...and the screen row becomes the BAR's
        tax                          ;   own row, 0..31
        lda row_lo,x                 ; row*160 DOUBLED is row*320 -- mn_sdst's
        asl                          ;   trick, and the reason there is no second
        pha                          ;   table. The low half is PARKED, not
        lda row_hi,x                 ;   stored: two bytes and no RAM cell
        rol                          ; C OUT is bit 7 of row_hi, and the biggest
                                     ;   row_hi here is 31*160>>8 = $13 -- so C
                                     ;   is 0 and the adc below adds exactly
        adc #>VRAM_BAR320            ; (its low byte is 0: the ert above)
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        pla
        clc
        adc hd_x                     ; + the column, UNDOUBLED: one byte is one
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; DOOM pixel on an SR surface
        bcc ?nc
        inc MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
?nc     lda #[VRAM_BAR320>>16]       ; row*320 + x <= 10,167, so the bank byte is
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2    ; a constant -- no carry into it
        lda hb_ctrl
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr bar_fire
        ldx hd_x
        rts
.endp
        .endseg

;--------------------------------------------------------------
; bar_bg -- the whole 320x32 STBAR onto the bar, opaque. draw_hud's first act.
;   Its own BCB because the 7-byte record holds the width in ONE byte and this
;   one is 320 wide -- which is also why STBAR left HUD_TAB (tools/pack_hud.py)
;   and arrives as the HUDV_STBAR constant.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bar_bg
        lda #<HUDV_STBAR
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #>HUDV_STBAR
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        lda #[HUDV_STBAR>>16]
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #<HUDV_BARW              ; the source IS the screen here, so its row
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY     ; pitch is the bar's own 320
        lda #>HUDV_BARW
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #<[HUDV_BARW-1]          ; 319 -- the one blit in the port that needs
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH         ; WIDTH's ninth bit
        lda #>[HUDV_BARW-1]
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        lda #HUDV_BARH-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        stz MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; VRAM_BAR320, row 0 column 0
        lda #>VRAM_BAR320
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        lda #[VRAM_BAR320>>16]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; BLT_COPY = 0: opaque
        jsr bar_fire
        stz MEMW+MEMW_HD_OFF+BCB_WIDTH+1       ; ...and the two 16-bit fields
        stz MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ;   back to bytes for everyone
        rts                          ;   else. Safe after the start: the BCB is
.endp                                ;   LATCHED (alt-src vbxe.cpp LoadBlitter
        .endseg                      ;   reads all 21 bytes before the first row)

;--------------------------------------------------------------
; bar_fire -- the destination stride is a property of the SCREEN, not of the
;   graphic, and this BCB is shared with everything that draws in the VIEW
;   (draw_weapon, strip_blit, fps_emit, the menus). So the 320 goes on right
;   before the start and comes off right after it -- the same "poke it and put
;   it back" hud_blit's hb_dbnk does for the destination bank.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bar_fire
        lda #<HUDV_BARW
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY
        lda #>HUDV_BARW
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        jsl hud_fire_w0              ; wait out the previous blit, fire this one
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY
        stz MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        rts
.endp
        .endseg
