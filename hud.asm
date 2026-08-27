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
.proc draw_hud
        lda #HUD_BAR                 ; background first
        ldx #0
        jsr hud_blit_bg
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

;--------------------------------------------------------------
; hud_top -- A = HUD_TAB index, X = x: a graphic that sits on the bar's top row.
;--------------------------------------------------------------
.proc hud_top
        jsr hud_entry
        ldy #HUD_BAR_Y
        jmp hud_blit
.endp

;--------------------------------------------------------------
; hud_num -- A = value (0..255), X = right edge column. STlib_drawNum: digits are
;   emitted right to left and leading zeros are not drawn.
;--------------------------------------------------------------
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
?have   sta hd_dig
        stx hd_val
        clc                          ; each glyph is one width to the left
        lda hd_dig
        adc #HUD_DIG0
        ldx hd_x
        jsr hud_glyph_left
        stx hd_x                     ; hud_glyph_left returns the new left edge
        lda hd_val
        bne ?dloop
        rts
.endp

;--------------------------------------------------------------
; hud_glyph / hud_glyph_left -- A = HUD_TAB index, X = x. hud_glyph puts the
;   glyph's LEFT edge at x; hud_glyph_left puts its RIGHT edge there and returns
;   the new left edge in X (that is how the number loop walks leftwards).
;--------------------------------------------------------------
.proc hud_glyph_left
        jsr hud_entry                ; -> zp_ptr, width in A
        sta hd_dig                   ; width
        txa
        sec
        sbc hd_dig
        tax
        stx hd_x
        ldy #ST_NUMY
        jsr hud_blit
        ldx hd_x
        rts
.endp

.proc hud_glyph
        jsr hud_entry
        ldy #ST_NUMY
        jmp hud_blit
.endp

;--------------------------------------------------------------
; hud_entry -- A = HUD_TAB index -> zp_ptr = &entry, A = width.
;--------------------------------------------------------------
.proc hud_entry
        sta m_a                      ; index*7 = *8 - *1
        lda #0
        sta m_a+1
        lda m_a
        asl
        asl
        asl
        sec
        sbc m_a
        clc
        adc #<HUD_TAB
        sta zp_ptr
        lda #0
        adc #>HUD_TAB
        sta zp_ptr+1
        ldy #3
        lda (zp_ptr),y
        rts
.endp

;--------------------------------------------------------------
; hud_keys -- ST_drawKeys / w3d hud_draw_keys: one STKEYS glyph per PS_KEYS bit
;   (blue/yellow/red) at DOOM x=239 (ST_KEYX), rows 171/181/191. A missing key
;   shows the bar background, exactly like DOOM. Parked at HUDKEYS_BASE: this
;   widget region ($AF40) is tight.
;--------------------------------------------------------------
hk_resume = *
        org HUDKEYS_BASE
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
        jsr hud_blit
?next   inc hk_i
        lda hk_i
        cmp #3
        bcc ?l
        lda #0                       ; rewind for the next frame
        sta hk_i
        rts
.endp
hk_bit  dta 1,2,4                    ; PS_KEYS bits (= BN_AMT of bonus ids 22-24)
hk_row  dta ST_KEY0Y, ST_KEY0Y+10, ST_KEY0Y+20
hk_i    dta 0
    .if * > HUDKEYS_END+1
        ert 'hud_keys outgrew HUDKEYS_BASE..END (memory_map.inc)'
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
.proc draw_hud_gate
        jsr update_flash             ; ST_doPaletteStuff: the damage/pickup tint
        jsr am_wgate                 ; = draw_weapon, unless the AUTOMAP is up:
                                     ;   DOOM's map replaces the view, gun and
                                     ;   all, but keeps the status bar below

        jsr hud_face_upd             ; the look-around animation (hud_hurt owns
                                     ;   the pain face, off fl_damage itself)
        lda hud_dirty
        beq ?fps
        sta fps_shown                ; the repaint covers the FPS digits: force a
                                     ;   redraw (A=1 never matches a real fps_val)
        dec hud_dirty
        jsr draw_hud
?fps    jmp msg_tick                 ; HU_Drawer's message line -- and msg_tick
.endp                                ;   tails into fps_tick, so this frame is
                                     ;   still counted (no byte left here for a
                                     ;   jsr of its own: see HUDDYN in
                                     ;   memory_map.inc)

;--------------------------------------------------------------
; fps_tick -- the 'F' FPS readout's clock, every frame (msg_tick's tail, and
;   msg_tick is draw_hud_gate's).
;   Counts RENDERED frames against the VBI jiffy counter in windows of one
;   second (50 jiffies, PAL): a finished window's frame count IS the
;   frames-per-second, updated once a second, no division anywhere. The
;   counters run from boot (toggling 'F' on shows the last finished second at
;   once); only the drawing is gated (fps_disp).
;   8-BIT ARITHMETIC, DELIBERATELY: in-game the VBI is rom_nmi (underrom.asm),
;   which ticks ONLY RTCLOK3 -- $13 never carries -- so a 16-bit elapsed
;   count closed the window early at every $14 wrap (a 1/12/50 flicker every
;   5.12 s at high frame rates). (RTCLOK3 - fps_w16) mod 256 is correct under
;   BOTH VBIs, menu and game. A >256-jiffy load hitch aliases mod 256 and can
;   stretch one window; the value self-corrects the next second.
;--------------------------------------------------------------
.proc fps_tick
        inc fps_f                    ; one more rendered frame this window
        lda RTCLOK3
        sec
        sbc fps_w16                  ; elapsed jiffies, mod 256
        cmp #50
        bcs ?win                     ; one second is up
        jmp fps_disp                 ; still open: redraw only if stale
?win    jmp fps_win
.endp

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
.proc hud_face_upd
        lda face_t                   ; VBLANK countdown, like the door timers
        sec
        sbc fps_n
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
        lda #1                       ; new face -> repaint the shared bar
        sta hud_dirty
?same   lda #FACE_VB
?keep   sta face_t
        rts
.endp

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
;   VBLANK of the frame -- seven of them at 5 fps -- so fl_tic had already
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
        org HUDPAIN_BASE
.proc pl_hurtfx                      ; A = the damage that got through
        jsr fl_damage                ; damagecount += it (the red screen flash)
        pha                          ; ...and hand its A back untouched: the E1M8
                                     ;   finale test in update_damage reads it
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
    .if * > HUDPAIN_END+1
        ert 'hud_pain outgrew HUDPAIN_BASE..HUDPAIN_END (memory_map.inc)'
    .endif
        org hp_resume

;--------------------------------------------------------------
; hud_ammo -- ST_Ticker's w_ready widget: the big red number is the READY
;   WEAPON's ammo type, not always bullets (st_stuff.c indexes
;   weaponinfo[readyweapon].ammo). The fist is am_noammo, and DOOM draws no
;   number at all for it. Lives here rather than inline in draw_hud: that block
;   ($AF40) ends flush against sprites.asm at $B000.
;   2026-08-10: parked at HUDAMMO_BASE -- fps_tick needed its HUDDYN bytes.
;--------------------------------------------------------------
ham_resume = *
        org HUDAMMO_BASE
.proc hud_ammo
        ldx wp_cur
        ldy wi_ammo,x
        bmi ?none
        lda PSTATE,y
        ldx #ST_AMMOX
        jmp hud_num
?none   rts
.endp
    .if * > HUDAMMO_END+1
        ert 'hud_ammo outgrew HUDAMMO_BASE..END (memory_map.inc)'
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
    .if * > HUDDYN_END+1
        ert 'draw_hud_gate/fps_tick/hud_face_upd/pickup_bonus outgrew HUDDYN (memory_map.inc)'
    .endif
        org hdyn_resume

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
; the lifts follow (fps_n = frame_dt). 4 seconds is 4 seconds at 5 fps and at
; 50. It counts down one frame late: the frame that takes msg_t to zero still
; draws. Making that exact costs a second branch and this block has one byte
; left; a single frame of a 4-second message is not visible.
;==============================================================
mtk_resume = *
        org MSGTICK_BASE
;--------------------------------------------------------------
; msg_tick -- HU_Ticker + HU_Drawer in one, called as draw_hud_gate's TAIL (it
;   inherits the frame's blitter state and the MEMAC window on BANK_OVERHEAD)
;   and leaving through fps_tick, which is the tail it displaced.
;--------------------------------------------------------------
.proc msg_tick
        lda msg_t                    ; nothing showing -> the whole widget is
        beq ?none                    ;   two loads and a branch
        sec
        sbc fps_n                    ; VBLANKs, not frames (see the header)
        bcs ?keep
        lda #0                       ; expired: floor it, do not wrap
?keep   sta msg_t
        lda msg_i                    ; the strip pack_menu.py rasterised for this
        ldx #MSG_Y                   ;   bonus id -- hu_stuff.c HU_MSGX/Y = 0,0
        jsr am_title.strip_blit
?none   jmp fps_tick                 ; ...and on to the readout's clock
.endp
    .if * > MSGTICK_END+1
        ert 'msg_tick outgrew MSGTICK_BASE..END (memory_map.inc)'
    .endif
        org mtk_resume

mst_resume = *
        org MSGSET_BASE
;--------------------------------------------------------------
; msg_set -- Y = the bonus id that was just TAKEN -> the message for it, armed
;   for MSG_VB. p_inter.c assigns player->message inside every arm of the
;   switch; here the id indexes the strip array, so one routine covers all 31.
;   The +MSG_IDX0 is the nine automap level names sharing the array (the strips
;   are one table so ONE blitter serves both -- automap.asm's header).
;--------------------------------------------------------------
.proc msg_set
        tya
        clc
        adc #MSG_IDX0
        sta msg_i
        lda #MSG_VB
        sta msg_t
        rts
.endp
    .if * > MSGSET_END+1
        ert 'msg_set outgrew MSGSET_BASE..END (memory_map.inc)'
    .endif
        org mst_resume

;==============================================================
; THE 'F' FPS READOUT -- the rest of it, parked piecewise: RAM has no single
; hole left that holds it whole (tools/ram_map.py), so each piece sits in its
; own gap with the usual org + ert guard. Flow per frame:
;   draw_hud_gate -> msg_tick -> fps_tick (HUDDYN, above) -> fps_win on a
;   closed window -> fps_disp -> fps_draw2 when the bar shows a stale value.
; The 'F' key itself hangs off mn_key's tail (fps_key/fps_tog below).
;==============================================================
fpsw_resume = *
        org FPSWIN_BASE
;--------------------------------------------------------------
; fps_win -- the one-second window just closed: its frame count IS the fps.
;   Latch it and restart the window at NOW -- the few jiffies a slow frame
;   overshot stay out of the next second. (fps_w16+1 is unused since the
;   8-bit rework -- see fps_tick -- and stays reserved.)
;--------------------------------------------------------------
.proc fps_win
        lda RTCLOK3
        sta fps_w16
        lda fps_f
        sta fps_val
        lda #0
        sta fps_f
        jmp fps_disp
.endp
    .if * > FPSWIN_END+1
        ert 'fps_win outgrew FPSWIN_BASE..END (memory_map.inc)'
    .endif

        org FPSDISP_BASE
;--------------------------------------------------------------
; fps_disp -- draw_hud_gate's true tail: paint fps_val on the bar IF the
;   readout is on and what is on screen is stale (a new window's value, or the
;   gate poked fps_shown because a full bar repaint just went over the digits).
;--------------------------------------------------------------
.proc fps_disp
        lda fps_on
        beq ?out
        lda fps_val
        cmp fps_shown
        beq ?out
        sta fps_shown
        jmp fps_draw2
?out    rts
.endp
    .if * > FPSDISP_END+1
        ert 'fps_disp outgrew FPSDISP_BASE..END (memory_map.inc)'
    .endif

        org FPSDRW_BASE
;--------------------------------------------------------------
; fps_draw2 -- STARMS goes down first (hud_top blits it BLT_COPY-free but the
;   bar behind the box is opaque, so it erases the old digits), then the count
;   in the big red STTNUM digits, right edge FPS_NUMX: frames per second.
;--------------------------------------------------------------
.proc fps_draw2
        lda #HUD_ARMS
        ldx #ST_ARMSX
        jsr hud_top
        lda fps_val
        ldx #FPS_NUMX
        jmp hud_num
.endp
fps_f     dta 0                      ; frames in the open window
fps_w16   dta 0                      ; RTCLOK3 at the window start. ONE byte: the
                                     ;   window is 8-bit arithmetic (see fps_tick),
                                     ;   so the old high byte was never read.
fps_val   dta 0                      ; last finished window = fps in tenths
fps_shown dta 0                      ; what the bar shows now
fps_on    dta 0                      ; 'F': 1 = readout visible
    .if * > FPSDRW_END+1
        ert 'fps_draw2 outgrew FPSDRW_BASE..END (memory_map.inc)'
    .endif

        org FPSKEY_BASE
;--------------------------------------------------------------
; fps_key -- mn_key's tail ('F' = FPS readout on/off). A is mn_key's leavings:
;   the $3F-masked key code while a key is down, 1 (never KEY_F) off the
;   re-arm path, 0 for a held ESC. The mn_arm edge is SHARED with ESC -- only
;   one key can be down at a time, so each press still acts exactly once.
;--------------------------------------------------------------
.proc fps_key
        cmp #KEY_F
        bne ?no
        lda mn_arm
        beq ?no                      ; still held from the press that acted
        dec mn_arm                   ; 1 -> 0: this press is spent
        jmp fps_tog
?no     jmp mn_pend                  ; carry on down read_keys' old tail
.endp
    .if * > FPSKEY_END+1
        ert 'fps_key outgrew FPSKEY_BASE..END (memory_map.inc)'
    .endif

        org FPSTOG_BASE
;--------------------------------------------------------------
; fps_tog -- the press: flip the readout and buy one bar repaint, which both
;   erases the digits on the way OFF and (via the gate's fps_shown poke)
;   paints them straight back on the way ON with the last window's value.
;--------------------------------------------------------------
.proc fps_tog
        lda fps_on
        eor #1
        sta fps_on
        lda #1
        sta hud_dirty
        jmp mn_pend
.endp
    .if * > FPSTOG_END+1
        ert 'fps_tog outgrew FPSTOG_BASE..END (memory_map.inc)'
    .endif
        org fpsw_resume

hud_split_resume = *
        org HUDBLIT_BASE             ; the blit half lives below the MEMAC window
;--------------------------------------------------------------
; hud_blit / hud_blit_bg -- blit the entry at zp_ptr to column X, row Y.
;   The bar goes down with BLT_COPY, glyphs with BLT_BSTENCIL (index 0 = clear).
;--------------------------------------------------------------
.proc hud_blit_bg
        jsr hud_entry                ; NOTE: this clobbers Y, so the row is set
        ldy #HUD_BAR_Y               ; AFTER it (that cost one broken screenshot)
        lda #BLT_COPY
        sta hb_ctrl
        jsr hud_blit
        lda #BLT_BSTENCIL
        sta hb_ctrl
        rts
.endp

.proc hud_blit
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
        lda #[VRAM_SCREEN>>16]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
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
.endp

hb_ctrl dta BLT_BSTENCIL             ; COPY for the bar, stencil for the glyphs
        org hud_split_resume
