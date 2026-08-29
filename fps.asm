;==============================================================
; fps.asm -- THE 'F' FRAME-RATE READOUT, top-left of the 3D view.
;--------------------------------------------------------------
; It lived in hud.asm while it was drawn ON the status bar. It is not on the
; bar any more, so it is not in that file any more either (2026-08-28).
;
; WHAT IT SHOWS, AND WHY IT IS EXACT. doors.asm's frame_dt already measures
; dt_vbl = the VBLANKs the last frame took, and on PAL the frame rate is 50/dt_vbl
; -- a frame of 8 VBLANKs is 6.25 frames a second, not "about 6". The readout
; this replaced counted RENDERED FRAMES in a one-second window, which can only
; ever produce a whole number and is a second out of date; it threw away
; precision the engine already had.
;
; NO DIVISION AT RUNTIME. 5000/n for every frame time n can take (1..DOOR_DTMAX
; = 64) is 64 rows of three decimal digits, built by MADS at assembly time
; (bank01.asm fps_tab, a .rept) and parked in Rapidus bank $01 -- 192 B of a
; bank with ~26 KB spare, against 273 B of free base RAM in the whole machine.
; Reading it is three lda.l.
;
; PARKED PIECEWISE. Base RAM has no hole that holds this whole, so each proc
; sits in its own gap with the usual org + ert guard. Per frame:
;   draw_hud_gate -> msg_tick -> hud_tail -> fps_draw2 -> fps_fetch (the digits)
;   -> fps_dig / fps_glyph (one glyph each) -> hud_blit.
;
; IT REDRAWS EVERY FRAME and that is not waste: the digits are inside the view,
; so the next frame's render erases them for free. That is also why the old
; "repaint only when the value is stale" machinery (fps_shown, fps_val, fps_win)
; is gone -- it existed because the STATUS BAR persists.
;
; THE FONT IS THE BIG ONE. STTNUM is 14x16 DOOM pixels, which is 7x16 of our
; bytes; the small STYSNUM set is 4x6, i.e. TWO pixels wide once the port halves
; it horizontally, and two pixels is not a digit ("necitatelne, zly font",
; 2026-08-28). STTNUM is variable width -- 14 for most, 11 for the '1' -- so the
; pen advances by the width hud_entry hands back, not by a constant.
;==============================================================
fps_resume = *
        org FPSTEN_BASE
;--------------------------------------------------------------
; hud_tail -- msg_tick's tail, i.e. the last thing drawn over the view.
;   Named for the slot rather than for the readout: it is where anything else
;   that wants the finished frame would go.
;--------------------------------------------------------------
;   It also closes the window the readout averages over -- every frame, whether
;   the readout is on or not, so switching it on shows a full window and not a
;   partial one.
;
;   WHY IT AVERAGES AT ALL. 50/dt_vbl is the exact rate of ONE frame, and this
;   engine's frame time genuinely alternates: against a wall it measured 10, 2,
;   10, 2 VBLANKs, so sampling one frame in eight showed 5,00 and 25,00 by
;   turns ("blika to.. napr 5.00 a 25.00"). Both readings were true and neither
;   was useful. The mean of that window is 6 VBLANKs = 8,33 fps, which is the
;   number a person wants. FPS_HOLD+1 is a power of two, so the divide is two
;   shifts and the sum stays in a byte.
;--------------------------------------------------------------
.proc hud_tail
        lda fd_sum                   ; this frame joins the window
        clc
        adc dt_vbl
        bcc ?ns
        lda #255                     ; saturate rather than wrap: a wrapped sum
?ns     sta fd_sum                   ;   reads as a fast frame, which is a lie
        lda fps_on
        beq ?out
        jmp fps_draw2
?out    rts
.endp
    .if * > FPSTEN_END+1
        ert 'hud_tail outgrew FPSTEN_BASE..END (memory_map.inc)'
    .endif

        org FPSDIG_BASE
;--------------------------------------------------------------
; fps_tens -- A = the integer part, 10..50: draw its TENS digit and hand the
;   units back in A. Only a very fast frame gets here (10 fps is a frame under
;   5 VBLANKs). It shared FPSTEN with hud_tail until hud_tail grew the window
;   accumulator.
;
;   IT MUST NOT TOUCH fd_d0, and that was the bug behind "blika 0.00 a real
;   fps": it used to leave the units there. The readout paints every frame but
;   fetches once per window, so frame 1 drew 50,00 and frames 2..4 re-read a
;   fd_d0 that now held 50's UNITS -- zero -- and drew 0,00. Same mechanism
;   turned 25,00 into 5,00. The draw may not edit what it draws from.
;--------------------------------------------------------------
.proc fps_tens
        ldy #0
        sec
?lp     sbc #10
        iny
        cmp #10
        bcs ?lp
        sta fd_w                     ; the units, parked across the tens' blit
        tya
        jsr fps_dig
        lda fd_w
        rts
.endp

;--------------------------------------------------------------
; fps_dig -- A = a digit 0..9, in the big STTNUM face. Those ARE in HUD_TAB
;   (indices HUD_DIG0..+9), so this is hud_entry's own path -- and hud_entry
;   hands back the glyph's width, which is what the pen advances by: STTNUM1 is
;   three bytes narrower than the rest and a fixed pitch would gap around it.
;--------------------------------------------------------------
.proc fps_dig
        clc
        adc #HUD_DIG0
        jsr hud_entry                ; -> zp_ptr, width in A
        pha                          ; the width, across the blit -- the STACK,
        ldx fd_x                     ;   not fd_w, because fps_tens needs fd_w
        ldy #FPS_VY                  ;   to survive this call (and pha/pla is
        jsr fps_blit                 ;   four bytes cheaper than a variable)
        pla
        sec                          ; pen += width + 1 (one byte of air between
        adc fd_x                     ;   glyphs) -- the carry IS the +1
        sta fd_x
        rts
.endp
    .if * > FPSDIG_END+1
        ert 'fps_dig outgrew FPSDIG_BASE..END (memory_map.inc)'
    .endif

        org FPSGLY_BASE
;--------------------------------------------------------------
; fps_glyph -- the decimal comma, STCFN044 out of DOOM's own message font.
;   It is NOT in HUD_TAB: pack_hud.py stops that table at HUD_TAB_ENGINE = 29
;   entries because HUDTAB_BASE..END is 240 B with the vissprite arrays right
;   above it. (Asking hud_entry for an index past the end was the 2026-08-28
;   "press F and the game falls into garbage" -- it read off the table.) So the
;   comma is addressed by its VRAM address from the generated hud_syms.inc and
;   ridden into hud_blit on a record of our own.
;   FPS_COMMAY drops it to the digits' baseline: the glyph is 4 rows and they
;   are 16, and hud_blit SUBTRACTS the record's top from the row.
;--------------------------------------------------------------
.proc fps_glyph
        lda #<HUDV_COMMA
        sta fps_rec
        lda #>HUDV_COMMA
        sta fps_rec+1
        lda #HUDV_COMMAH
        sta fps_rec+4
        lda #[FPS_COMMAY&$FF]        ; negative: hud_blit subtracts it
        sta fps_rec+6
        jmp fps_emit
.endp
    .if * > FPSGLY_END+1
        ert 'fps_glyph outgrew FPSGLY_BASE..END (memory_map.inc)'
    .endif

        org FPSEMIT_BASE
;--------------------------------------------------------------
; fps_emit -- blit whatever fps_rec describes at the pen, then move the pen on.
;   hud_blit takes its 7-byte record through zp_ptr and does not care that every
;   other caller's comes out of HUD_TAB.
;--------------------------------------------------------------
.proc fps_emit
        lda #<fps_rec
        sta zp_ptr
        lda #>fps_rec
        sta zp_ptr+1
        ldx fd_x
        ldy #FPS_VY
        jsr fps_blit
        lda fd_x
        clc
        adc #FPS_DIGW
        sta fd_x
        rts
.endp

;--------------------------------------------------------------
; fps_blit -- hud_blit with the destination bank borrowed. hud_blit defaults to
;   bank 0, which is right for the status bar (rows 168+ are SHARED between the
;   buffers and painted once) and wrong for every row above it: the readout is
;   inside the view and has to land in the BACK buffer. Put back immediately,
;   so no other caller can be surprised.
;--------------------------------------------------------------
.proc fps_blit
        lda zback_hi
        sta hud_blit.hb_dbnk+1
        jsr hud_blit
        lda #[VRAM_SCREEN>>16]
        sta hud_blit.hb_dbnk+1
        rts
.endp
    .if * > FPSEMIT_END+1
        ert 'fps_emit/fps_blit outgrew FPSEMIT_BASE..END (memory_map.inc)'
    .endif

        org FPSFET_BASE
;--------------------------------------------------------------
; fps_fetch -- the window's MEAN frame time -> fd_d0/d1/d2, the three decimal
;   digits of 50/mean. C=0 means the window is not full yet (at boot, or the
;   first frame after a toggle): fps_draw2 retries next frame rather than paint
;   a number it never fetched.
;   FPS_HOLD+1 frames per window and that is 4, so the divide is two shifts.
;   frame_dt clamps dt_vbl to DOOR_DTMAX = 64 and hud_tail saturates the sum, so
;   the mean lands in 1..64 -- exactly the table's length, and the index cannot
;   run off the end.
;--------------------------------------------------------------
.proc fps_fetch
        lda fd_sum
        lsr
        lsr                          ; / 4 -- the window's mean frame time
        beq ?none                    ; not four frames' worth yet
        sec
        sbc #1
        sta fd_t
        asl
        clc
        adc fd_t                     ; *3
        tax
        lda.l FPS_TAB_EXT,x
        sta fd_d0
        lda.l FPS_TAB_EXT+1,x
        sta fd_d1
        lda.l FPS_TAB_EXT+2,x
        sta fd_d2
        sec
        rts
?none   clc
        rts
.endp
    .if * > FPSFET_END+1
        ert 'fps_fetch outgrew FPSFET_BASE..END (memory_map.inc)'
    .endif

        org FPSD2_BASE
;--------------------------------------------------------------
; fps_draw2 -- "N,NN" (or "NN,NN") at the top-left of the view.
;   The value STANDS for FPS_HOLD frames while the digits are re-blitted every
;   frame. 50/dt_vbl is exact but it is ONE frame's rate, and a scene whose
;   frames alternate 7 and 8 VBLANKs flipped the readout between 7,14 and 6,25
;   every frame ("fps musi byt presne a stabilne"). Nothing is averaged, so
;   nothing is blurred -- what stands is still one real frame's real rate.
;--------------------------------------------------------------
.proc fps_draw2
        dec fd_hold
        bpl ?paint
        jsr fps_fetch
        bcc ?out                     ; NOTHING TIMED YET -- and the hold is armed
        lda #0
        sta fd_sum                   ; ...and open the next window
        lda #FPS_HOLD                ;   only AFTER a fetch that worked. Arming it
        sta fd_hold                  ;   first was the "0,00" flicker: the bail
                                     ;   skipped the paint but left the hold set,
                                     ;   so the next eight frames drew fd_d0/d1/d2
                                     ;   as they had been left -- and their initial
                                     ;   value is zero, which is a reading no row
                                     ;   of the table can produce (they run 50,00
                                     ;   down to 0,78). Retry next frame instead.
?paint  lda #FPS_VX
        sta fd_x
        lda fd_d0
        cmp #10
        bcc ?ones                    ; 10 fps and up (a frame under 5 VBLANKs)
        jsr fps_tens                 ;   needs a tens digit; nothing else does
?ones   jsr fps_dig                  ; A is the units either way -- fps_tens
                                     ;   returns them and `cmp` did not touch A
        jsr fps_glyph                ; (no index: fps_glyph IS the comma)
        lda fd_d1
        jsr fps_dig
        lda fd_d2
        jsr fps_dig
?out    rts
.endp
    .if * > FPSD2_END+1
        ert 'fps_draw2 outgrew FPSD2_BASE..END (memory_map.inc)'
    .endif

        org FPSKEY_BASE
;--------------------------------------------------------------
; fps_key -- mn_key's tail ('F' = readout on/off). A is mn_key's leavings: the
;   $3F-masked key code while a key is down, 1 (never KEY_F) off the re-arm
;   path, 0 for a held ESC. The mn_arm edge is SHARED with ESC -- only one key
;   can be down at a time, so each press still acts exactly once.
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
; fps_tog -- the press: flip the readout. It used to buy a status-bar repaint
;   as well, to rub the digits off the ARMS box on the way out; the digits are
;   in the VIEW now and the next frame's render erases them unasked.
;--------------------------------------------------------------
.proc fps_tog
        lda fps_on
        eor #1
        sta fps_on
        jmp mn_pend
.endp
    .if * > FPSTOG_END+1
        ert 'fps_tog outgrew FPSTOG_BASE..END (memory_map.inc)'
    .endif

        org FPSDRW_BASE
fps_rec   dta a(0), [HUDV_COMMA>>16], HUDV_YSW, HUDV_COMMAH, 0, 0
                                     ; hud_blit's record for the glyphs that are
                                     ;   not in HUD_TAB: u24 vram, w, h, left,
                                     ;   top. Only the comma uses it, so the
                                     ;   bank and the width are set once here.
fps_on    dta 0                      ; 'F': 1 = readout visible
fd_hold   dta 0                      ; frames left in the window
fd_sum    dta 0                      ; VBLANKs accumulated in it (saturating)
fd_x      dta 0                      ; the pen, in byte columns
fd_w      dta 0                      ; the glyph width hud_entry handed back
fd_t      dta 0                      ; row*3 scratch
fd_d0     dta 0                      ; the three digits of 50/dt_vbl
fd_d1     dta 0
fd_d2     dta 0
    .if * > FPSDRW_END+1
        ert 'the fps_* state outgrew FPSDRW_BASE..END (memory_map.inc)'
    .endif
        org fps_resume
