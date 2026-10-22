;--------------------------------------------------------------
; fps.asm -- the 'F' frame-rate readout, top-left of the 3D view:
;   200 / (VBLANKs of the last 4 frames) on PAL.
;--------------------------------------------------------------
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
        .segment B1
.proc hud_tail
        lda fd_sum                   ; this frame joins the window
        clc
        adc dt_vbl
        bcc ?ns
        lda #255                     ; saturate rather than wrap: a wrapped sum
?ns     sta fd_sum                   ;   reads as a fast frame, which is a lie
    .if POSLINE
        jsl pos_tick                 ; the position line (below, bank 0), on with 'F'
    .endif
        lda fps_on
        beq ?out
        jmp fps_draw2
?out    rts
.endp
        .endseg
    .if * > FPSTEN_END+1
        ert 'hud_tail outgrew FPSTEN_BASE..END (memory_map.inc)'
    .endif

        org FPSDIG_BASE
;--------------------------------------------------------------
; fps_tens -- A = the integer part, 10..50: draw its TENS digit and hand the
;   units back in A. Only a very fast frame gets here (10 fps is a frame under
;   5 VBLANKs). It shared FPSTEN with hud_tail until hud_tail grew the window
;   accumulator.
;--------------------------------------------------------------
        .segment B1
.proc fps_tens
        ldy #0
?lp     sbc #10
        iny
        cmp #10
        bcs ?lp
                                      ; 2026-09-22 (65816-style): the units ride the
        pha                          ;   stack across the tens' blit
        tya
        jsr fps_dig
        pla
        rts
.endp
        .endseg

;--------------------------------------------------------------
; fps_dig -- A = a digit 0..9, in the big STTNUM face. Those ARE in HUD_TAB
;   (indices HUD_DIG0..+9), so this is hud_entry's own path -- and hud_entry
;   hands back the glyph's width, which is what the pen advances by: STTNUM1 is
;   three bytes narrower than the rest and a fixed pitch would gap around it.
;--------------------------------------------------------------
        .segment B1
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
        .endseg
    .if * > FPSDIG_END+1
        ert 'fps_dig outgrew FPSDIG_BASE..END (memory_map.inc)'
    .endif

        org FPSGLY_BASE
;--------------------------------------------------------------
; fps_glyph -- the decimal comma, STCFN044 out of DOOM's own message font.
;--------------------------------------------------------------
        .segment B1
.proc fps_glyph
        lda #<HUDV_COMMA
        sta fps_rec
        lda #>HUDV_COMMA
        sta fps_rec+1
        lda #HUDV_COMMAH
        sta fps_rec+4
        lda #[FPS_COMMAY&$FF]        ; negative: hud_blit subtracts it
        sta fps_rec+6
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>fps_emit             ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > FPSGLY_END+1
        ert 'fps_glyph outgrew FPSGLY_BASE..END (memory_map.inc)'
    .endif

        org FPSEMIT_BASE
;--------------------------------------------------------------
; fps_emit -- blit whatever fps_rec describes at the pen, then move the pen on.
;   hud_blit takes its 7-byte record through zp_ptr and does not care that every
;   other caller's comes out of HUD_TAB.
;--------------------------------------------------------------
        .segment B1
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
        .endseg

;--------------------------------------------------------------
; fps_blit -- zp_ptr = a glyph's 7-byte row, X = the pen, Y = the row: RECORD
;   it for the strip's chain (strip.asm st_glyph) instead of drawing it. The
;   readout is 320 now, on the strip; the pen is in its pixels.
;--------------------------------------------------------------
        .segment B1
.proc fps_blit
        stx st_tx
        sty st_ty
        lda st_ng
        cmp #ST_NGL
        bcs ?out                     ; (never: "NN,NN" is ST_NGL)
        asl
        asl
        asl
        adc st_ng                    ; *9: st_ng < 32, the asl's shift out 0s
        tax
        ldy #0
?c      lda (zp_ptr),y               ; the row, as hud_blit would have read it
        sta st_gl,x
        inx
        iny
        cpy #7
        bne ?c
        lda st_tx
        sta st_gl,x
        lda st_ty
        sta st_gl+1,x
        inc st_ng
?out    rts
.endp
        .endseg
    .if * > FPSEMIT_END+1
        ert 'fps_emit/fps_blit outgrew FPSEMIT_BASE..END (memory_map.inc)'
    .endif

        org FPSFET_BASE
;--------------------------------------------------------------
; fps_fetch -- fd_d0/d1/d2 = the three decimal digits of the window's EXACT
;   rate. C=0 means the window is not full yet (at boot, or the first frame
;   after a toggle -- sum < 4 is precisely the old mean==0 test): fps_draw2
;   retries next frame rather than paint a number it never fetched.
;--------------------------------------------------------------
        .segment B1
.proc fps_fetch
        lda fd_sum
        cmp #4                       ; four 1-VBLANK frames is the fastest
        bcc ?none                    ;   possible full window
        sbc #4                       ; carry is set: bcc just fell through
        tax
        lda FPS_SUMI,x
        sta fd_d0
        lda FPS_SUMD1,x
        sta fd_d1
        lda FPS_SUMD2,x
        sta fd_d2
        rts
?none   clc
        rts
.endp
        .endseg
    .if * > FPSFET_END+1
        ert 'fps_fetch outgrew FPSFET_BASE..END (memory_map.inc)'
    .endif

        org FPSD2_BASE
;--------------------------------------------------------------
; fps_draw2 -- "N,NN" (or "NN,NN") at the top-left of the view.
;--------------------------------------------------------------
        .segment B1
.proc fps_draw2
        dec fd_hold
        bpl ?out                     ; held: the strip's chain has these digits
        jsr fps_fetch
        bcc ?out                     ; NOTHING TIMED YET -- and the hold is armed
        stz fd_sum                   ; ...and open the next window
        lda #FPS_HOLD                ;   only AFTER a fetch that worked. Arming it
        sta fd_hold                  ;   first was the "0,00" flicker: the bail
                                     ;   skipped the paint but left the hold set, ...
        stz st_ng                    ; a new rate: its glyphs, recorded for the
        inc st_cur                   ;   chains (strip.asm) -- once, not a frame
        lda #FPS_VX*2                ; the pen, in the 320 strip's pixels
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
        .endseg
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
        .segment B1
.proc fps_key
        cmp #KEY_F
        bne ?no
        lda mn_arm
        beq ?no                      ; still held from the press that acted
        dec mn_arm                   ; 1 -> 0: this press is spent
        bra fps_tog
?no     jmp mn_pend                  ; carry on down read_keys' old tail
.endp
        .endseg
    .if * > FPSKEY_END+1
        ert 'fps_key outgrew FPSKEY_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; fps_tog -- the press: flip the readout. It used to buy a status-bar repaint
;   as well, to rub the digits off the ARMS box on the way out; the digits are
;   in the VIEW now and the next frame's render erases them unasked.
;--------------------------------------------------------------
        .segment B1
.proc fps_tog
        lda fps_on
        eor #1
        sta fps_on
        jmp mn_pend
.endp
        .endseg

        org FPSDRW_BASE
fps_rec   dta a(0), [HUDV_COMMA>>16], HUDV_YSW, HUDV_COMMAH, 0, 0
                                     ; hud_blit's record for the glyphs that are
                                     ;   not in HUD_TAB: u24 vram, w, h, left,
                                     ;   top.
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

        .segment D0
;--------------------------------------------------------------
; The EXACT-rate tables (see fps_fetch): entry s-4 holds the three decimal
; digits of 200/s, s = the 4-frame window's VBLANK sum, 4..255. Truncated,
; never rounded up -- the readout may understate by 0,01 but never flatter.
; Parked in the win2 pages the SQ2 mirror vacated (2026-08-31): three reads
; per ~0.7 s is what x11.2 was made for.
;--------------------------------------------------------------
FPS_SUMI
        .rept 252,#
        dta [20000/[#+4]]/100
        .endr
FPS_SUMD1
        .rept 252,#
        dta [[20000/[#+4]]/10]%10
        .endr
FPS_SUMD2
        .rept 252,#
        dta [20000/[#+4]]%10
        .endr
        .endseg

;==============================================================
; THE POSITION LINE (2026-10-19, a diagnostic): with the 'F' readout on, the
; player's "x,y,angle" -- ZP_PX, ZP_PY, ZP_ANG, exactly what the bench's --at
; takes -- as the message line: 17 cells of a 5x7 face composed into ST_MSGV
; through the window whenever the position changes, behind 14 blank cells so
; the readout's digits (FPS_VX, 16 rows) stay clear of it. msg_i/msg_t are
; held at POS_MSG, so st_frame keeps the line up and fetches nothing for it
; (st_mshown = POS_MSG too); off, the line goes with the readout.
; In the $6500 hole (POSLINE_BASE, bank 0), code and data: bank $01 and the
; D0 segment are both full (MADS: "Segment .. error"), and this is cold --
; hud_tail reaches it with jsl, it ends in rtl.
;==============================================================
POSLINE  equ 1                       ; 0: not assembled
    .if POSLINE
POS_MSG  equ $FF                     ; no HU line has this strip index
POS_GW   equ 6                       ; a cell: 5 px of face + 1 of air
POS_LEAD equ 14                      ; blank cells under the readout's digits
POS_NCH  equ POS_LEAD+17             ; + "sxxxxx,syyyyy,aaa"
POS_W    equ POS_NCH*POS_GW          ; the line's width, 186 px (MSG_WMAX 242)
POS_COL  equ 231                     ; the face's colour (PLAYPAL: yellow)
POS_MINUS equ 10                     ; the face: digits 0-9, then these
POS_COMMA equ 11
POS_SP   equ 12
POS_WIN  equ MEMW16+[[ST_MSGV>>12]&3]*$1000+[ST_MSGV&$FFF]   ; ST_MSGV in the window
    .if POS_W > MSG_WMAX || TITLE_H < 7
        ert 'the position line must fit the message line (strip.asm st_chain)'
    .endif

        org POSLINE_BASE
;--------------------------------------------------------------
; pos_tick -- hud_tail's first act, every frame (jsl). Clobbers A/X/Y, zp_ptr.
;--------------------------------------------------------------
.proc pos_tick
        lda fps_on
        beq ?off
        rep #$20                     ; the line is composed again only when the
        .LONGA ON                    ;   position moved (standing: nothing)
        lda ZP_PX
        cmp pos_last
        bne ?new
        lda ZP_PY
        cmp pos_last+2
        bne ?new
        lda ZP_ANG                   ; (a byte: the word read drags the next in)
        and #$00FF
        cmp pos_last+4
        beq ?same
?new    jsr pos_draw                 ; (16-bit M in and out)
?same   .LONGA OFF
        sep #$20
        lda #POS_MSG                 ; the line stays up: st_frame shows msg_i
        sta msg_i                    ;   while msg_t > 0, and fetches nothing
        sta st_mshown                ;   for the index ST_MSGV already holds
        lda #$FF
        sta msg_t
        lda #POS_W
        sta st_mw
        rtl
?off    lda st_mshown                ; the readout went off: the line with it
        cmp #POS_MSG
        bne ?out
        stz msg_t
        stz st_mshown
?out    rtl
.endp

;--------------------------------------------------------------
; pos_draw -- pos_str = the position's 17 cells, then the line: ST_MSGV's
;   POS_W x TITLE_H bytes cleared and the cells' faces set through the window
;   (parked back on the overhead bank). 16-bit M in and out.
;--------------------------------------------------------------
.proc pos_draw
        .LONGA ON
        lda ZP_PX
        sta pos_last
        ldx #POS_LEAD
        jsr pos_dec
        lda #POS_COMMA               ; (a word store: its 0 lands on the next
        sta pos_str,x                ;   cell, written next)
        inx
        lda ZP_PY
        sta pos_last+2
        jsr pos_dec
        lda #POS_COMMA
        sta pos_str,x
        inx
        lda ZP_ANG
        and #$00FF
        sta pos_last+4
        jsr pos_dec.d3
        .LONGA OFF
        sep #$20
        lda #BANK_EN|[ST_MSGV>>12]   ; the window on the line
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        lda #POS_WIN                 ; the line to 0 (index 0 shows through), a
        sta zp_ptr                   ;   row a pass, a word a store
        ldx #TITLE_H
?row    lda #0
        ldy #0
?cl     sta (zp_ptr),y
        iny
        iny
        cpy #POS_W                   ; (186 > 127: counting UP, Y's bit 7 is
        bne ?cl                      ;   not a sign here)
        lda zp_ptr
        clc
        adc #POS_W
        sta zp_ptr
        dex
        bne ?row
        .LONGA OFF                   ; the faces, 8-bit: a byte a pixel
        sep #$20
        stz pos_i
?ch     lda pos_i                    ; zp_ptr = the cell's first byte, row 0:
        asl                          ;   POS_WIN + i*6 (i*6 <= 180: a byte, no
        adc pos_i                    ;   carry until the base is added)
        asl
        adc #<POS_WIN
        sta zp_ptr
        lda #>POS_WIN
        adc #0
        sta zp_ptr+1
        ldx pos_i
        lda pos_str,x
        sta pos_g                    ; X = the face's first row: index*7
        asl
        asl
        asl
        sec
        sbc pos_g
        tax
        lda #7
        sta pos_r
?fr     lda pos_font,x               ; the row's five pixels, bits 7..3
        sta pos_g
        ldy #0
?px     asl pos_g
        bcc ?np
        lda #POS_COL
        sta (zp_ptr),y
?np     iny
        cpy #5
        bne ?px
        inx
        lda zp_ptr                   ; the next row
        clc
        adc #<POS_W
        sta zp_ptr
        bcc ?nr
        inc zp_ptr+1
?nr     dec pos_r
        bne ?fr
        inc pos_i
        lda pos_i
        cmp #POS_NCH
        bne ?ch
        lda #BANK_EN|BANK_OVERHEAD   ; the window back where the frame has it
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        rts
        .LONGA OFF
.endp

;--------------------------------------------------------------
; pos_dec -- A = a value (16-bit M), X = its cell in pos_str: a sign cell
;   (space or minus) and five digits, X past them. d3: three digits and no
;   sign (the angle). Keeps M 16-bit; a digit's store lands its zero high
;   byte on the next cell, which is written after it.
;--------------------------------------------------------------
.proc pos_dec
        .LONGA ON
        ldy #POS_SP
        cmp #$8000
        bcc ?pos
        eor #$FFFF                   ; negative: its magnitude, a minus
        inc @
        ldy #POS_MINUS
?pos    pha                          ; (no sty abs,x: through A, zero-extended)
        tya
        sta pos_str,x
        pla
        inx
        ldy #0                       ; the powers, 10000 first
        bra ?pw
d3      ldy #4                       ; 100 first
?pw     stz pos_dig
?sub    cmp pos_pow,y
        bcc ?dn
        sbc pos_pow,y                ; (C = 1: the cmp)
        inc pos_dig
        bra ?sub
?dn     pha
        lda pos_dig
        sta pos_str,x
        pla
        inx
        iny
        iny
        cpy #10
        bne ?pw
        rts
        .LONGA OFF
.endp
pos_font                             ; 5x7, a row a byte, bits 7..3: 0-9 - , space
        dta $70,$88,$98,$A8,$C8,$88,$70
        dta $20,$60,$20,$20,$20,$20,$70
        dta $70,$88,$08,$10,$20,$40,$F8
        dta $F8,$10,$20,$10,$08,$88,$70
        dta $10,$30,$50,$90,$F8,$10,$10
        dta $F8,$80,$F0,$08,$08,$88,$70
        dta $38,$40,$80,$F0,$88,$88,$70
        dta $F8,$08,$10,$20,$40,$40,$40
        dta $70,$88,$88,$70,$88,$88,$70
        dta $70,$88,$88,$78,$08,$10,$E0
        dta $00,$00,$00,$F8,$00,$00,$00
        dta $00,$00,$00,$00,$00,$60,$40
        dta $00,$00,$00,$00,$00,$00,$00
pos_last  dta a(0), a(0), a(0)       ; x, y, angle the line was composed for
pos_pow   dta a(10000), a(1000), a(100), a(10), a(1)
pos_str   :POS_LEAD dta POS_SP       ; the cells: the blank lead, then the text
          :17 dta 0
          dta 0                      ;   (a digit's word store spills a 0 here)
pos_dig   dta a(0)                   ; pos_dec's digit (a word: 16-bit stz/inc)
pos_i     dta 0                      ; pos_draw's cell
pos_g     dta 0                      ; ...its face row
pos_r     dta 0                      ; ...rows left
    .if * > POSLINE_END+1
        ert 'the position line outgrew POSLINE_BASE..END (memory_map.inc)'
    .endif
    .endif                           ; POSLINE
        org fps_resume
