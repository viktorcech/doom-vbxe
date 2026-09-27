;--------------------------------------------------------------
; strip.asm -- the top of the view at DOOM's own 320 (2026-09-24): the message
;   line (hu_stuff.c HU_Drawer) and the 'F' frame-rate readout.
;   VBXE shows ONE overlay mode a scan line, so 320 text cannot sit on the 160
;   view. While either shows, the list of the buffer being drawn shows view
;   rows 0-19 (its entries 0-7) in SR out of a 320x20 STRIP, which ONE blit
;   chain fills every frame: the view's own rows zoomed 2x, then the message
;   and the digits 1:1 over them. A strip, a chain and a list per buffer
;   (A/B/C): list X is never on screen while buffer X is drawn -- the triple
;   buffer -- so neither the list rewrite nor the chain can tear.
;   The chain is rebuilt only when what it shows changes (st_cur, a version):
;   a frame writes no BCB byte at all, it sets BL_ADR and STARTs
;   (rapidus-bus-timing: every BCB field is a slow bus write).
;   The AUTOMAP (automap.asm) is 320 too: while it is up, lists A/B show its
;   two SR surfaces on every view row -- the same mode switch, on the list of
;   the buffer being drawn -- and chains 3/4 put HU_Drawer on them: the
;   level's name, the message, the readout.
;--------------------------------------------------------------
ST_ROWS   equ 20                     ; view rows the strip covers: entries 0-7
ST_NENT   equ 8
ST_PITCH      equ 320                    ; the strip's pitch
ST_SIZE   equ ST_PITCH*ST_ROWS           ; 6400 B a strip
ST_STRIPA equ MENU_RUNEND            ; the three strips, right above the WI+FIN
ST_STRIPB equ ST_STRIPA+ST_SIZE      ;   run (and the episode patches at its end)
ST_STRIPC equ ST_STRIPB+ST_SIZE      ;   and below MT_SR (memory_map.inc VRAM map)
ST_BANK   equ ST_STRIPA>>16
ST_CHAINV equ $009A00                ; + list*$100: seven BCBs a chain -- in
                                     ;   BANK 0, behind list R: every START in the
                                     ;   port writes BL_ADR0/1 only and leaves
                                     ;   BL_ADR2 at 0 for good (bsp_main_video)
ST_NSLOT  equ 7                      ; the zoom, the message, five glyphs
ST_NGL    equ 5                      ; "NN,NN" -- the most fps_draw2 records
ST_MSGV   equ ST_STRIPC+ST_SIZE      ; the message line, 1:1 (st_mfetch)
ST_TITV   equ ST_STRIPA+$3000        ; the automap's level name (st_tfetch): the
                                     ;   strips are idle under it, and menu.asm's
                                     ;   mn_sname has the six 2 KB before it
ST_CWIN   equ MEMW16+[ST_CHAINV&$3FFF]   ; the chains, in the lists' window
MSG_DIRX  equ [WIMAP_BANK+MSG_BK]<<16    ; the SDRAM directory (pack_wi.py)
    .if [MENU_RUNEND&$FFF] <> 0 || ST_MSGV+MSG_WMAX*TITLE_H > FIN_TXSR
        ert 'strip.asm: the strips and the line must sit between the WI+FIN run and FIN_TXSR'
    .endif
    .if [ST_STRIPC+ST_SIZE-1]>>16 <> ST_BANK || ST_STRIPC+ST_SIZE > ST_MSGV || [ST_CHAINV&$FF] <> 0
        ert 'strip.asm: the strips share one bank, below the line; the chains page-aligned'
    .endif
    .if [ST_CHAINV>>16] <> 0 || [ST_CHAINV&$FFC000] <> [VRAM_XDL_A&$FFC000] || ST_NSLOT*21 > $100
        ert 'strip.asm: the chains sit in bank 0, in the lists'' 16 KB window, $100 each'
    .endif
    .if ST_CHAINV < VRAM_XDL_R+MENU_HXDLN || ST_CHAINV+$500 > VRAM_OVERHEAD
        ert 'strip.asm: the five chains go between list R and the overhead bank'
    .endif
    .if [[VRAM_XDL_A|VRAM_XDL_B|VRAM_XDL_C]&$FF] <> 0 || [VRAM_XDL_A&$FFC000] <> [VRAM_XDL_B&$FFC000] || [VRAM_XDL_A&$FFC000] <> [VRAM_XDL_C&$FFC000]
        ert 'st_list: lists A/B/C are page-aligned in one 16 KB window'
    .endif
    .if ST_TITV+MSG_WMAX*TITLE_H > ST_MSGV
        ert 'strip.asm: the automap title line runs into the message line'
    .endif
    .if TITLE_H <> 8 || MSG_Y+TITLE_H > ST_ROWS
        ert 'st_mfetch: a line is width*8 bytes, inside the strip'
    .endif

;--------------------------------------------------------------
; st_frame -- the frame's tail over the view (draw_hud_gate's, where msg_tick
;   was): HU_Ticker's clock, the FPS window, and the list of the buffer being
;   drawn in the mode the frame wants -- 0 the view, 1 the strip (the message
;   or the readout shows), 2 the automap's surface (automap.asm) -- with its
;   chain fired: the strip's, or the automap's HU (title, line, readout).
;--------------------------------------------------------------
        .segment B1
.proc st_frame
        lda msg_t                    ; HU_Ticker: the message's VBLANKs
        beq ?m0
        sec
        sbc dt_vbl
        bcs ?mk
        lda #0                       ; expired: floor it, do not wrap
?mk     sta msg_t
?m0     jsr hud_tail                 ; the FPS window: fps_draw2 bumps st_cur
                                     ;   when it records a new rate
        lda msg_t                    ; the line that should show: msg_i, or 0 --
        beq ?mo                      ;   msg_i never is (MSG_IDX0 + an id >= 1)
        lda msg_i
?mo     cmp st_mon
        beq ?ms
        sta st_mon
        inc st_cur
        tax                          ; (Z from A: gone, nothing to fetch)
        beq ?ms
        cmp st_mshown
        beq ?ms
        jsr st_mfetch                ; a new line: SDRAM -> ST_MSGV
?ms     lda fps_on
        cmp st_fpsw
        beq ?fs
        sta st_fpsw
        inc st_cur
?fs     lda am_on
        bne ?am                      ; the automap: out of line
        lda st_mon
        ora fps_on                   ; non-zero: the strip is wanted
        beq ?m
        lda #1
?m      ldy zback_hi                 ; the buffer being drawn: 0 A, 1 B, 7 C
        cpy #FRAME_C_BANK
        bne ?y
        ldy #2
?y      cmp st_lmode,y
        beq ?l
        jsr st_mode                  ; its entries over to the wanted mode
?l      lda st_lmode,y
        beq ?out
        cmp #2                       ; the automap's chains are 3 (S0) and 4 (S1)
        bcc ?c
        iny
        iny
        iny
?c      lda st_cur
        cmp st_ver,y
        beq ?fire
        sta st_ver,y
        jsr st_chain
?fire   jsr blitw_hard               ; the frame's own blits first: START is
        lda #<ST_CHAINV               ;   ignored while the blitter runs (keeps Y)
        sta VBXE_BL_ADR0
        tya                          ; chain Y at ST_CHAINV + Y*$100 (Y <= 4,
        clc                          ;   and C is not known here)
        adc #>ST_CHAINV
        sta VBXE_BL_ADR1
        lda #1                       ; (BL_ADR2 stays 0: the chains are bank 0)
        sta VBXE_BL_START
?out    rts
?am     lda current_level            ; the automap: its title line staged?
        cmp st_tlev
        beq ?tl
        jsr st_tfetch
?tl     lda #2
        bra ?m
.endp

;--------------------------------------------------------------
; st_mfetch -- A = msg_i: its line into ST_MSGV, its width into st_mw.
; st_tfetch -- this level's name into ST_TITV (the automap's HU_TITLE).
;--------------------------------------------------------------
.proc st_mfetch
        sta st_mshown
        tax
        lda #<ST_MSGV
        sta sp_addr
        lda #>ST_MSGV
        sta sp_addr+1
        lda #[ST_MSGV>>16]
        sta sp_addr+2
        jsr st_hufetch
        sta st_mw
        rts
.endp
.proc st_tfetch
        sta st_tlev                  ; A = current_level (the strip index)
        tax
        lda #<ST_TITV
        sta sp_addr
        lda #>ST_TITV
        sta sp_addr+1
        lda #[ST_TITV>>16]
        sta sp_addr+2
        jsr st_hufetch
        sta st_tw
        inc st_cur                   ; the automap's chains carry its width
        rts
.endp

;--------------------------------------------------------------
; st_hufetch -- X = a strip index, sp_addr = where in VRAM: that HU line at
;   DOOM's width out of SDRAM (pack_wi.py's directory, lo/hi/width/bank by
;   strip index, read in place). Returns A = its width.
;--------------------------------------------------------------
.proc st_hufetch
        lda.l MSG_DIRX,x
        sta sf_src
        lda.l MSG_DIRX+MSG_STRIDE,x
        sta sf_src+1
        lda.l MSG_DIRX+3*MSG_STRIDE,x  ; the lines run on past their first bank
        clc
        adc #[WIMAP_BANK+MSG_BK]
        sta sf_src+2
        lda.l MSG_DIRX+2*MSG_STRIDE,x
        pha                          ; the width, returned
        rep #$20                     ; width * TITLE_H (8) bytes: the byte's three
        .LONGA ON                    ;   shifts cannot carry out
        and #$00FF
        asl @
        asl @
        asl @
        sta sf_size
        .LONGA OFF
        sep #$20
        jsr spr_fcopy                ; (parks the window on the overhead bank)
        pla
        rts
.endp

;--------------------------------------------------------------
; st_mode -- A = the mode list Y (0 A, 1 B, 2 C) is wanted in, st_lmode,y the
;   one it is in. Onto the automap: all its view entries; off it: all of them
;   back on the buffer, then rows 0-19 on the strip if that is wanted; 0 <-> 1
;   rows 0-19 alone. Keeps Y.
;--------------------------------------------------------------
.proc st_mode
        ldx st_lmode,y
        sta st_lmode,y
        cmp #2
        beq ?all
        cpx #2
        bne ?top
        pha                          ; off the automap
        lda #0
        ldx #XDL_NVIEW+1
        jsr st_list
        pla
        beq ?out
?top    ldx #ST_NENT
        jmp st_list
?all    ldx #XDL_NVIEW+1
        jmp st_list
?out    rts
.endp

;--------------------------------------------------------------
; st_list -- Y = list, A = the mode (0 the buffer at 160, 1 the strip at 320,
;   2 the automap's surface at 320: S0 in MT_SR, S1 in FRAME_B going on in
;   FRAME_C at entry st_spl), X = how many view entries from the top. Only
;   their ctrl2, OVADR and OVSTEP: RPTL stays, and so does entry 0's ATT pair
;   (xdl_att's damage tint). Rows go 0-3, 4 twice, 5-8, 9 twice ...: an entry's
;   OVADR is the last one's + 4W after a first-of-pair, + W after a doubled
;   row. Keeps Y.
;--------------------------------------------------------------
.proc st_list
        sty st_y
        stx st_n
        tax                          ; (the mode)
        pei (zp_tsrc)                ; zp_tsrc/zp_savex ARE the renderer's zp_pt
        lda zp_savex                 ;   (paint.asm) and its bank byte -- live
        pha                          ;   across frames: parked, not borrowed
        lda #BANK_EN | [VRAM_XDL_A>>12]
        sta VBXE_BANK_SEL            ; lists A, C, B: one 16 KB window
        stz zp_savex                 ; [zp_tsrc],y: bank 0 -- no indexed dummy
        stz zp_tsrc                  ;   read of the window (rapidus-bus-timing)
        lda st_lwin,y
        sta zp_tsrc+1
        stz st_spl                   ; no second half (X never reads 0 below)
        stz st_c2                    ; SR: neither HR nor LR
        rep #$20
        .LONGA ON
        stz st_off
        lda #ST_PITCH
        sta st_w
        .LONGA OFF
        sep #$20
        dex
        bmi ?lr
        beq ?sr
        lda am_sbk,y                 ; 2: the automap's surface
        sta st_bk
        lda am_ssp,y                 ; S1's split entry k, as X counts it:
        beq ?go                      ;   k - n (mod 256)
        sec
        sbc st_n
        sta st_spl
        bra ?go
?sr     lda #ST_BANK                 ; 1: the strip
        sta st_bk
        lda st_srlo,y
        sta st_off
        lda st_srhi,y
        sta st_off+1
        bra ?go
?lr     lda #XDLC_LR                 ; 0: the buffer
        sta st_c2
        lda st_lrbk,y
        sta st_bk
        lda #SCREEN_WIDTH
        sta st_w
        stz st_w+1
?go     lda st_n                     ; X runs k - n up to 0, so its parity is
        lsr @                        ;   k's flipped when n is odd: the two
        lda #$90                     ;   parity branches are bcc/bcs or bcs/bcc
        bcc ?ev                      ;   (patched only when that changes)
        lda #$B0
?ev     cmp.l B1CODE_BASE+?b1
        beq ?e0
        sta.l B1CODE_BASE+?b1
        eor #$20
        sta.l B1CODE_BASE+?b2
?e0     ldy #1                       ; --- entry 0: the ATT pair's ctrl2, a
        lda st_c2                    ;   first-of-pair step, and 10 bytes long
        ora #XDLC_ATT
        sta [zp_tsrc],y              ; [1] ctrl2
        ldy #5
        lda st_bk
        sta [zp_tsrc],y              ; [5] OVADR bank
        rep #$20
        .LONGA ON
        ldy #3
        lda st_off
        sta [zp_tsrc],y              ; [3-4] OVADR lo/mid
        ldy #6
        lda st_w
        sta [zp_tsrc],y              ; [6-7] OVSTEP
        asl @                        ; the next row is 4W on (4W <= 1280: C = 0)
        asl @
        adc st_off
        sta st_off
        lda zp_tsrc                  ; entry 1 is 10 bytes on (no carry: C = 0)
        adc #10
        sta zp_tsrc
        .LONGA OFF
        sep #$20
        lda #1                       ; X = 1 - n: entries 1..n-1, up to 0
        sec
        sbc st_n
        tax
?e      cpx st_spl                   ; S1's second half starts here (one entry
        beq ?sp                      ;   of 65: out of line)
?h      rep #$20
        .LONGA ON
        ldy #3
        lda st_off
        sta [zp_tsrc],y              ; [3-4] OVADR lo/mid
        txa                          ; (X is 8-bit: B = 0)
        lsr @                        ; C = X's parity
        lda st_w
?b1     bcc ?s                       ; SMC: a doubled row steps 0
        lda #0
?s      ldy #6
        sta [zp_tsrc],y              ; [6-7] OVSTEP
        .LONGA OFF
        sep #$20
        dey                          ; Y = 5: [5] OVADR bank
        lda st_bk
        sta [zp_tsrc],y
        lda st_c2
        ldy #1
        sta [zp_tsrc],y              ; [1] ctrl2
        rep #$20
        .LONGA ON
        txa
        lsr @                        ; C = X's parity again: after a doubled row
        lda st_w                     ;   the next pair is W on, else the doubled
?b2     bcs ?n                       ;   row is 4W on -- SMC, as ?b1
        asl @
        asl @                        ; (4W <= 1280: no carry out, C = 0)
?n      clc
        adc st_off
        sta st_off
        lda zp_tsrc                  ; the next entry, 8 bytes on (an OVADR <
        adc #8                       ;   64K: C = 0)
        sta zp_tsrc
        .LONGA OFF
        sep #$20
        inx
        bne ?e
        lda #BANK_EN | BANK_OVERHEAD ; the window back where the blits want it
        sta VBXE_BANK_SEL
        jmp st_unpark
?sp     stz st_off                   ; FRAME_C, row 0 of it
        stz st_off+1
        lda #FRAME_C_BANK
        sta st_bk
        bra ?h
.endp
    .if [AM_S1B % 5] <> 4 || AM_S1E <> [AM_S1B/5]*2+1
        ert 'st_list: S1 must go on in FRAME_C at a doubled row, entry AM_S1E'
    .endif

;--------------------------------------------------------------
; st_chain -- Y = chain (0-2: list Y's strip, 3/4: the automap's S0/S1): it is
;   rebuilt from the state. Slot 0 zooms the buffer's rows 0-19 onto the strip,
;   or is the level's name at the automap's HU_TITLEY; slot 1 is the message or
;   a no-op; slots 2-6 the readout's glyphs or no-ops. No-ops keep every NEXT
;   bit static: one byte copied onto itself, 21 blitter cycles. The last slot
;   ends the chain. Each BCB is built in RAM (st_img) and goes over the bus as
;   words (st_put). Keeps Y.
;--------------------------------------------------------------
.proc st_chain
        sty st_y
        pei (zp_tsrc)                ; the renderer's zp_pt, parked (st_list)
        lda zp_savex
        pha
        lda #BANK_EN | [VRAM_XDL_A>>12]   ; the lists' window holds the chains
        sta VBXE_BANK_SEL
        stz zp_savex
        stz zp_tsrc
        tya
        clc
        adc #>ST_CWIN
        sta zp_tsrc+1                ; chain Y in the window
        lda st_srlo,y                ; the target's row 0, lo/mid, and its bank
        sta st_base
        lda st_srhi,y
        sta st_base+1
        lda st_dbkt,y
        sta st_dbk
        lda #1
        sta st_img+5                 ; [5] SRC_STEPX
        sta st_img+11                ; [11] DST_STEPX
        lda #<ST_PITCH               ; [9-10] DST_STEPY 320
        sta st_img+9
        lda #>ST_PITCH
        sta st_img+10
        lda #$FF
        sta st_img+15                ; [15] AND: the source counts
        stz st_img+16                ; [16] XOR, [17] COLLIDE, [19] PATTERN
        stz st_img+17
        stz st_img+19
        stz st_img+13                ; [13] WIDTH hi, [4] SRC_STEPY hi
        stz st_img+4
        cpy #3
        bcs ?ttl
        lda st_lrbk,y                ; --- slot 0: the view's rows, zoomed 2x
        sta st_img+2                 ; [2] SRC bank: the buffer
        stz st_img                   ; [0-1] row 0
        stz st_img+1
        lda #SCREEN_WIDTH            ; [3] SRC_STEPY 160
        sta st_img+3
        lda #SCREEN_WIDTH-1          ; [12] WIDTH: 160 source bytes ...
        sta st_img+12
        lda #ST_ROWS-1               ; [14]
        sta st_img+14
        lda #BLT_ZOOM_2X             ; [18] ... each drawn twice
        sta st_img+18
        lda #BLT_COPY | BLT_NEXT     ; [20]
        sta st_img+20
        jsr st_dst0                  ; [6-8] the strip itself
        bra ?s0
?ttl    lda #<ST_TITV                ; --- slot 0: HU_TITLE, the level's name at
        sta st_img                   ;   (0, HU_TITLEY) -- in S1's second half
        lda #>ST_TITV                ;   there, so its own DST
        sta st_img+1
        lda #[ST_TITV>>16]
        sta st_img+2
        lda st_tw                    ; [3] SRC_STEPY = its width, [12] WIDTH-1
        sta st_img+3
        dec @
        sta st_img+12
        lda #TITLE_H-1
        sta st_img+14
        stz st_img+18                ; 1:1
        lda #BLT_BSTENCIL | BLT_NEXT
        sta st_img+20
        lda st_tdl-3,y
        sta st_img+6
        lda st_tdh-3,y
        sta st_img+7
        lda st_tdb-3,y
        sta st_img+8
?s0     jsr st_put
        lda st_mon                   ; --- slot 1: the message line
        beq ?mnop
        lda #<ST_MSGV
        sta st_img
        lda #>ST_MSGV
        sta st_img+1
        lda #[ST_MSGV>>16]
        sta st_img+2
        lda st_mw                    ; [3] SRC_STEPY = its width, [12] WIDTH-1
        sta st_img+3
        dec @
        sta st_img+12
        lda #TITLE_H-1
        sta st_img+14
        stz st_img+18                ; 1:1
        lda #BLT_BSTENCIL | BLT_NEXT ; index 0 is the view showing through
        sta st_img+20
        rep #$21
        .LONGA ON
        lda st_base                  ; hu_stuff.c HU_MSGX/Y = 0, MSG_Y
        adc #MSG_Y*ST_PITCH
        sta st_img+6
        .LONGA OFF
        sep #$20
        lda st_dbk
        sta st_img+8
        jsr st_put
        bra ?gl
?mnop   jsr st_nop
?gl     ldx #[ST_NGL-1]*9            ; --- slots 2-6: the readout's glyphs,
        lda #ST_NGL-1                ;   the last record first (any order: the
        sta st_g                     ;   slots are independent)
?g      lda st_fpsw
        beq ?gnop
        lda st_g
        cmp st_ng
        bcs ?gnop
        jsr st_glyph                 ; X = its record in st_gl
        bra ?gn
?gnop   jsr st_nop
?gn     txa
        sec
        sbc #9
        tax
        dec st_g
        bpl ?g
        rep #$20                     ; the last slot ends the chain: its CTRL
        .LONGA ON                    ;   again, NEXT off (st_img still holds it)
        dec zp_tsrc
        .LONGA OFF
        sep #$20
        lda st_img+20
        and #$FF^BLT_NEXT
        sta [zp_tsrc]
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        ert *<>st_unpark             ; fall through
.endp

;--------------------------------------------------------------
; st_unpark -- st_list's and st_chain's tail: zp_savex and zp_tsrc back off
;   the stack (the renderer's zp_pt), Y = the list again.
;--------------------------------------------------------------
.proc st_unpark
        pla
        sta zp_savex
        rep #$20
        .LONGA ON
        pla
        sta zp_tsrc
        .LONGA OFF
        sep #$20
        ldy st_y
        rts
.endp
    .if ST_NSLOT <> 2+ST_NGL
        ert 'st_chain: the zoom/title, the message and ST_NGL glyphs are ST_NSLOT slots'
    .endif

;--------------------------------------------------------------
; st_glyph -- X = a record in st_gl (7-byte row, x, y): its BCB, the patch's
;   own offsets applied (V_DrawPatch), stencilled onto the target. Keeps X.
;--------------------------------------------------------------
.proc st_glyph
        lda st_gl+8,x                ; y - top: the glyph's first row
        sec
        sbc st_gl+6,x
        phx
        tax
        lda row_hi,x                 ; B:A = row*160 ...
        xba
        lda row_lo,x
        plx
        rep #$20
        .LONGA ON
        asl @                        ; ... *2 = row*320 (a small row: C = 0)
        adc st_base
        sta st_t
        lda st_gl+5,x                ; [left, top]: the left alone, sign-extended
        and #$00FF                   ;   and negated at once:
        eor #$FF7F                   ;   -((l ^ $80) - $80) = ~(l ^ $80) + 1 + $80
        sec
        adc #$0080
        clc
        adc st_t
        sta st_t
        lda st_gl+7,x                ; + x (a byte)
        and #$00FF
        clc
        adc st_t
        sta st_img+6                 ; [6-7] DST
        lda st_gl,x                  ; [0-1] SRC lo/mid
        sta st_img
        lda st_gl+3,x                ; [w, h]: the width alone
        and #$00FF
        sta st_img+3                 ; [3-4] SRC_STEPY = w
        dec @
        sta st_img+12                ; [12-13] WIDTH = w-1
        .LONGA OFF
        sep #$20
        lda st_gl+2,x
        sta st_img+2                 ; [2] SRC bank
        lda st_dbk
        sta st_img+8                 ; [8]
        lda st_gl+4,x
        dec @
        sta st_img+14                ; [14] HEIGHT = h-1
        stz st_img+18                ; 1:1
        lda #BLT_BSTENCIL | BLT_NEXT
        sta st_img+20
        ert *<>st_put                ; fall through
.endp

;--------------------------------------------------------------
; st_put -- st_img (one BCB) into the window at [zp_tsrc], as ten words and a
;   byte, and zp_tsrc on to the next slot. Keeps X.
;--------------------------------------------------------------
.proc st_put
        rep #$20
        .LONGA ON
        ldy #0
?w      lda st_img,y
        sta [zp_tsrc],y
        iny
        iny
        cpy #20
        bne ?w
        .LONGA OFF
        sep #$20
        lda st_img+20
        sta [zp_tsrc],y
        rep #$21
        .LONGA ON
        lda zp_tsrc
        adc #21
        sta zp_tsrc
        .LONGA OFF
        sep #$20
        rts
.endp

;--------------------------------------------------------------
; st_nop -- a slot that does nothing: one target byte copied onto itself.
;--------------------------------------------------------------
.proc st_nop
        jsr st_dst0
        lda st_base                  ; [0-2] SRC = the same byte
        sta st_img
        lda st_base+1
        sta st_img+1
        lda st_dbk
        sta st_img+2
        stz st_img+12                ; 1 x 1
        stz st_img+13
        stz st_img+14
        stz st_img+18
        lda #BLT_COPY | BLT_NEXT
        sta st_img+20
        bra st_put
.endp

;--------------------------------------------------------------
; st_dst0 -- [6-8] DST = the target's first byte.
;--------------------------------------------------------------
.proc st_dst0
        lda st_base
        sta st_img+6
        lda st_base+1
        sta st_img+7
        lda st_dbk
        sta st_img+8
        rts
.endp

        .endseg

        .segment D0
st_cur    dta 0                      ; the state's version: bumped on every change
st_ver    dta $FF,$FF,$FF,$FF,$FF    ; per chain: the version it was built for
st_lmode  dta 0,0,0                  ; per list: 0 the view, 1 the strip, 2 the automap
st_fpsw   dta 0                      ; fps_on, as the chains know it
st_mon    dta 0                      ; the line showing, as the chains know it
st_mshown dta 0                      ; the msg_i whose line is in ST_MSGV
st_mw     dta 0                      ; ...and its width
st_tlev   dta $FF                    ; the level whose name is in ST_TITV
st_tw     dta 0                      ; ...and its width
st_ng     dta 0                      ; glyphs fps_draw2 recorded
st_gl     :ST_NGL*9 dta 0            ; per glyph: the 7-byte row, x, y
st_img    :21 dta 0                  ; the BCB being built
st_off    dta a(0)                   ; st_list's running OVADR
st_w      dta a(0)                   ; ...its pitch
st_base   dta a(0)                   ; the target's row 0, lo/mid
st_t      dta a(0)
st_bk     dta 0
st_c2     dta 0
st_n      dta 0                      ; st_list's entry count
st_spl    dta 0                      ; ...and where S1's second half starts
st_dbk    dta 0                      ; st_chain's target bank
st_y      dta 0
st_g      dta 0
st_tx     dta 0
st_ty     dta 0
;   per list (0 A, 1 B, 2 C): its window page, its buffer's bank; the automap's
;   surface on lists A/B: S0's bank, S1's first half's, and S1's split entry
st_lwin   dta >[MEMW16+[VRAM_XDL_A&$3FFF]], >[MEMW16+[VRAM_XDL_B&$3FFF]], >[MEMW16+[VRAM_XDL_C&$3FFF]]
st_lrbk   dta [VRAM_SCREEN>>16], [FRAME_B>>16], FRAME_C_BANK
am_sbk    dta [AM_S0>>16], [AM_S1>>16]
am_ssp    dta 0, AM_S1E                ; (0: no second half)
;   per chain (0-2 the strips, 3/4 the automap's S0/S1): the target's row 0
;   and bank; the automap's HU_TITLE row
st_srlo   dta <ST_STRIPA, <ST_STRIPB, <ST_STRIPC, <AM_S0, <AM_S1
st_srhi   dta >ST_STRIPA, >ST_STRIPB, >ST_STRIPC, >AM_S0, >AM_S1
st_dbkt   dta ST_BANK, ST_BANK, ST_BANK, [AM_S0>>16], [AM_S1>>16]
st_tdl    dta <[AM_S0+TITLE_Y*AM_W], <[AM_S1B2+[TITLE_Y-AM_S1B]*AM_W]
st_tdh    dta >[AM_S0+TITLE_Y*AM_W], >[AM_S1B2+[TITLE_Y-AM_S1B]*AM_W]
st_tdb    dta [[AM_S0+TITLE_Y*AM_W]>>16], [[AM_S1B2+[TITLE_Y-AM_S1B]*AM_W]>>16]
        .endseg
