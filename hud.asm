;--------------------------------------------------------------
; hud.asm -- the DOOM status bar, 1:1 from the WAD (tools/pack_hud.py): glyphs in
;   VRAM, HUD_TAB gives address/size/offsets, the layout is st_stuff.c.
;--------------------------------------------------------------
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
                                      ;   hd_dig copy was never read -- hud_glyph_left
        adc #HUD_DIG0
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
        ldy #ST_NUMY
                                      ; 2026-09-22: bar_blit opens with `stx hd_x`
        jmp bar_blit                 ;   and returns `ldx hd_x` -- the save and the
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
                                      ; 2026-09-22: the row offset stays < 256 (29 rows,
        asl                          ;   the ert below) and HUD_TAB is page-aligned:
        sta m_a+1                    ;   no shift or add carries, so no clc, and
        asl                          ;   index*6 IS zp_ptr's low byte
        adc m_a+1
        sta zp_ptr
        rep #$20
        .LONGA ON
        lda #[MAP_EXT_BANK<<8]|[>HUD_TAB]   ; page + BANK BYTE (set, not inherited:
        sta zp_ptr+1                 ;   the .else side says why) as one word
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
.endp
        .endseg
    .if * > HUDENT_END+1
        ert 'hud_entry outgrew HUDENT_BASE..END (memory_map.inc)'
    .endif
    .if [HUD_TAB&$FF] != 0 .or HUDTAB_BYTES > 42*6
        ert 'hud_entry: HUD_TAB must be page-aligned and index*6 must stay < 256'
    .endif
        org hent_resume

;--------------------------------------------------------------
; hud_keys -- ST_drawKeys / w3d hud_draw_keys: one STKEYS glyph per PS_KEYS bit
;   (blue/yellow/red) at DOOM x=239 (ST_KEYX), rows 171/181/191. A missing key
;   shows the bar background, exactly like DOOM. Parked at HUDKEYS_BASE: this
;   widget region ($AF40) is tight.
;--------------------------------------------------------------
hk_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_keys
?l      ldx hk_i
        lda hk_bit,x
        and PSTATE+PS_KEYS
        beq ?next
                                      ; 2026-09-22: X IS hk_i (loaded above)
        txa
        clc
        adc #HUD_KEY0                ; STKEYS0..2 = blue/yellow/red card
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org hk_resume

;--------------------------------------------------------------
; draw_hud_gate -- the per-frame overlay entry (replaces draw_hud in the main
;   loop): the weapon psprites first (they are part of the VIEW and go down every
;   frame), then the face animation, then the full bar repaint while
;   hud_dirty > 0.
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
                                      ; 2026-09-22: C is known on both paths -- 0 after
        lda #0                       ;   bne (A = 0..2 < 3), 1 here (A was 3): the
?r                                   ;   carry IS the +1, no clc
        adc face_base
        cmp face_cur
        beq ?same
        sta face_cur
                                      ; 2026-09-22 (drac030 inline): hud_faceup2 -- facefix's rts
        lda hud_dirty                ;   now comes back HERE, where the
        bne ?same                    ;   tail branch returned to anyway
        jsr hud_facefix
                                     ;   nothing if a full repaint is pending
?same   lda #FACE_VB
?keep   sta face_t
        rts
.endp
        .endseg

;--------------------------------------------------------------
; hud_hurt -- ST_updateFaceWidget priorities 7 and 6, the ones the port never
;   had (2026-08-07, "tvar v HUDe by sa mala menit pri damage, pri zasahu,
;   alebo ked stoji v kyseline").
;--------------------------------------------------------------
hp_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_hurtfx                      ; A = the damage that got through
        jsr fl_damage                ; damagecount += it (the red screen flash)
        pha                          ; ...and hand its A back untouched: the E1M8
                                     ;   finale test in update_damage reads it
                                      ; THE TINT AT THE EVENT (2026-09-15, "ked
        phx                          ;   stojim v kyseline ... s texturami
        jsr update_flash             ;   neblika"). The frame's own update_flash
        plx                          ;   runs after wp_think, whose tic batch
                                     ;   6-7 VBLANKs, sometimes left 1).
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org hp_resume

;--------------------------------------------------------------
; hud_ammo -- ST_Ticker's w_ready widget: the big red number is the READY
;   WEAPON's ammo type, not always bullets (st_stuff.c indexes
;   weaponinfo[readyweapon].ammo). The fist is am_noammo, and DOOM draws no
;   number at all for it.
;--------------------------------------------------------------
ham_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org ham_resume

;--------------------------------------------------------------
; pickup_bonus -- snd_bonus + the dirty-HUD marks, C = "taken" like snd_bonus.
;   Lives HERE and not inline in spr_pickup: the sprites segment ends flush at
;   $B7C0 (mv_ptr is next), so the wrapper keeps it byte-identical.
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
;--------------------------------------------------------------
FF_X      equ ST_FACEX+3             ; 146: every face lump has left = -3
FF_Y      equ HUD_BAR_Y+1            ; 169: the earliest face top (hud.tab)
FF_W      equ 24                     ; DOOM pixels -- a byte is one on the bar
FF_H      equ 31
FF_ROW    equ FF_Y-HUD_BAR_Y         ; ...and the bar's OWN row, 0-based
FF_SRCOFF equ FF_ROW*HUDV_BARW+FF_X
hffx_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_faceup2
        lda hud_dirty                ; a full repaint is pending and includes
        beq hud_facefix                    ;   the face -> nothing to do here
        ;bra hud_facefix
?skip   rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc hud_facefix
                                      ; 2026-09-22: constant fields as bus words --
        rep #$20                     ;   bytes 0-5 (SRC, SRC_STEPY = the bar's 320,
        .LONGA ON                    ;   SRC_STEPX = 1), 6-7 (DST lo/mid), 12-13
        lda #[HUDV_STBAR+FF_SRCOFF]&$FFFF     ;   (WIDTH; its high byte is 0 anyway)
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #[[HUDV_STBAR+FF_SRCOFF]>>16]|[[HUDV_BARW&$FF]<<8]
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #[HUDV_BARW>>8]|$0100
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #[VRAM_BAR320+FF_ROW*HUDV_BARW+FF_X]&$FFFF
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        lda #FF_W-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        lda #[VRAM_BAR320>>16]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; BLT_COPY = 0: opaque
        lda #FF_H-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jsr bar_fire                 ; wait out the previous blit, fire this one
        stz MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; ...and the 16-bit step back to
                                     ;   a byte: the BCB is LATCHED at start ...
        lda face_cur                 ; ...and the face itself: ONE stencil blit
        ldx #ST_FACEX                ;   (hb_ctrl rests at BLT_BSTENCIL)
        jmp hud_top
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org hffx_resume

;==============================================================
; THE MESSAGE LINE (2026-08-16, "ked nieco vezmem, hore sa zjavi popisok").
;==============================================================
mtk_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; msg_tick -- HU_Ticker + HU_Drawer in one, called as draw_hud_gate's TAIL (it
;   inherits the frame's blitter state and the MEMAC window on BANK_OVERHEAD)
;   and leaving through hud_tail, which is the tail it displaced.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc msg_tick
        jmp st_frame                 ; 2026-09-24: the line at 320, on the view's
.endp                                ;   own SR strip (strip.asm) -- the clock,
                                     ;   the FPS window and hud_tail go with it
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org mtk_resume

mst_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; msg_set -- Y = the bonus id that was just TAKEN -> the message for it, armed
;   for MSG_VB. p_inter.c assigns player->message inside every arm of the
;   switch; here the id indexes the strip array, so one routine covers them all.
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org mst_resume

hud_split_resume = *
        org HUDBLIT_BASE             ; the blit half lives below the MEMAC window
;--------------------------------------------------------------
; hud_blit -- blit the entry at zp_ptr to column X, row Y of the FRAMEBUFFER:
;   160 bytes a row, one byte = two hardware pixels. The gun, the message strip,
;   the FPS readout, the menus, the intermission and the finale all come through
;   here.
;--------------------------------------------------------------
.proc hud_blit
        ; 2026-09-09 (drac030 style), 8-BIT ON PURPOSE: the boot menu calls ...
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
        lda hb_ctrl
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
hud_fire                             ; menu.asm's mn_erase builds its own BCB
                                     ;   (a background sub-rectangle, which the ...
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
.endp

hb_ctrl dta BLT_BSTENCIL             ; COPY for the bar, stencil for the glyphs
                                     ; (hb_dbnk is hud_blit's other parameter and ...
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
                                      ; 2026-09-22 (rapidus-bus-timing): BCB bytes 0-5
        rep #$20                     ;   -- SRC (3), SRC_STEPY (2), SRC_STEPX -- as
        .LONGA ON                    ;   three bus WORDS: the second byte of each
        lda (zp_ptr)                 ;   does not wait. hud_ent is vram lo, mid,
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR     ;   bank, width: its bytes 2-3 ARE
        ldy #2                                ;   SRC bank + SRC_STEPY lo
        lda (zp_ptr),y
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #$0100                   ; SRC_STEPY hi = 0, SRC_STEPX = 1: draw_weapon
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1  ;   shares this BCB and scales
        .LONGA OFF
        sep #$20
        iny                          ; Y = 3: width -> WIDTH = width-1
        lda (zp_ptr),y
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
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
                                      ; 2026-09-22: the constant fields as bus words
        rep #$20                     ;   (bytes 0-5 SRC/STEPY/STEPX, 6-7 DST lo/mid,
        .LONGA ON                    ;   12-13 WIDTH)
        lda #HUDV_STBAR&$FFFF
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #[HUDV_STBAR>>16]|[[HUDV_BARW&$FF]<<8]
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #[HUDV_BARW>>8]|$0100    ; STEPY hi, STEPX = 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #VRAM_BAR320&$FFFF       ; VRAM_BAR320, row 0 column 0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        lda #HUDV_BARW-1             ; 319 -- the one blit in the port that needs
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH         ;   WIDTH's ninth bit
        .LONGA OFF
        sep #$20
        lda #HUDV_BARH-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
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
;   (draw_weapon, fps_emit). So the 320 goes on right
;   before the start and comes off right after it -- the same "poke it and put
;   it back" hud_blit's hb_dbnk does for the destination bank.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bar_fire
                                      ; each STEPY as ONE bus word (rapidus-bus-timing:
        rep #$20                     ;   the second byte of a 16-bit access waits for
        .LONGA ON                    ;   nothing)
        lda #HUDV_BARW
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY
        .LONGA OFF
        sep #$20
        jsl hud_fire_w0              ; wait out the previous blit, fire this one
        rep #$20
        .LONGA ON
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg
