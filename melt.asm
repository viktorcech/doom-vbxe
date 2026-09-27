;--------------------------------------------------------------
; melt.asm -- f_wipe.c wipe_doMelt at DOOM's own 320 (2026-09-24): 160 columns
;   two pixels wide, on ONE SR screen (MT_SR, shown through list R). No copy of
;   the old picture is kept: every tic each running column's old part moves
;   down IN PLACE, bottom-up (negative steps), and the rows it uncovers come
;   from the new picture. Three BCBs a column in one chain, built once
;   (mt_init) and then only their changing words rewritten per tic (mt_step).
;   MT_SR is outside the pool: the stats screen stays on it through the level
;   load (mt_keep), and the second melt starts from there. The data is wi.asm
;   stage 1's (bank 0, $1000): no melt runs without it.
;--------------------------------------------------------------
MT_SR     equ WI_MTSR                ; 320x200 + one spare row (pack_wi.py)
MT_W      equ 320
MT_BOT    equ [WIPE_H-1]*MT_W        ; row 199: where every shift starts
MT_SPARE  equ WIPE_H*MT_W            ; row 200, never shown: the no-ops' target
MT_BK     equ MT_SR>>16
MT_CHAIN  equ $000000                ; 160 x 3 BCBs = 10,080 B in FRAME_A: no
MT_CWIN   equ MEMW16+[MT_CHAIN&$3FFF] ;   frame is drawn while a melt runs
MT_COL    equ 3*BCB_SIZE             ; one column: shift, new top, new bar
MT_GRABV  equ $007D00                ; mt_show's three BCBs, past FRAME_A's rows
MT_GWIN   equ MEMW16+[MT_GRABV&$3FFF]
MT_BOFS   equ [[VRAM_BAR320&$FFFF]-VIEW_HEIGHT*MT_W]&$FFFF  ; screen row -> bar row
    .if [MT_SR&$FFFF] <> 0 || MT_SR+MT_SPARE+MT_W > FRAME_C || MT_SR < ST_MSGV+MSG_WMAX*TITLE_H
        ert 'melt.asm: MT_SR is a bank of its own between the message line and FRAME_C'
    .endif
    .if MT_CHAIN+SCREEN_WIDTH*MT_COL+1 > MT_CHAIN+$4000 || [MT_CHAIN>>16] <> 0 || MT_GRABV < WIPE_H*SCREEN_WIDTH || MT_GRABV+3*BCB_SIZE+1 > VRAM_XDL_A
        ert 'melt.asm: the chain fits one 16 KB window of bank 0; the grab BCBs sit between FRAME_A and the lists'
    .endif
    .if [MT_GRABV&$FF] <> 0 || [VRAM_BAR320>>16] <> [[VRAM_BAR320+MT_W*[WIPE_H-VIEW_HEIGHT]-1]>>16]
        ert 'melt.asm: mt_show adds the start to BL_ADR0 alone; the bar is one bank'
    .endif

        .segment B1
;--------------------------------------------------------------
; mt_init -- X = 0: into the intermission (the new picture is its surface,
;   1:1), 1: out of it (the next level's view, 160 zoomed 2x, over the bar).
;   f_wipe.c wipe_initMelt's y[], then the whole chain: every slot a no-op.
;--------------------------------------------------------------
.proc mt_init
        lda ZFRONT                   ; slot A's source: the view shown ...
        cpx #0
        bne ?z
        lda #[WI_SRVRAM>>16]         ; ... or the stats surface
?z      sta mt_img+BCB_SIZE+BCB_SRC_ADDR+2
        lda mt_pst,x                 ; [3] SRC_STEPY lo (hi is 1 or 0: [4])
        sta mt_img+BCB_SIZE+BCB_SRC_STEPY
        lda mt_psth,x
        sta mt_img+BCB_SIZE+BCB_SRC_STEPY+1
        lda mt_pw,x                  ; [12] WIDTH-1: 2 bytes, or 1 zoomed 2x
        sta mt_img+BCB_SIZE+BCB_WIDTH
        lda mt_pz,x
        sta mt_img+BCB_SIZE+BCB_ZOOM
        lda mt_psp,x                 ; the row the bar starts at (200: none), as
        sta.l B1CODE_BASE+mt_step.sp1+1   ;   the operand of mt_step's four
        sta.l B1CODE_BASE+mt_step.sp2+1   ;   cmp #/lda # (their high bytes are
        sta.l B1CODE_BASE+mt_step.sp3+1   ;   assembled 0)
        sta.l B1CODE_BASE+mt_step.sp4+1
        lda mt_pop,x                 ; nop, or lsr @: the view's offset is half
        sta.l B1CODE_BASE+mt_step.smc
        jsr blitw_hard               ; FRAME_A is not read any more (the grab)
        pei (zp_ptr)                 ; zp_ptr: parked, not borrowed
        lda zp_ptr+2
        pha
        stz zp_ptr+2                 ; [zp_ptr],y in bank 0: no indexed dummy
        lda #BANK_EN | [MT_CHAIN>>12] ;   read of the window (rapidus-bus-timing)
        sta VBXE_BANK_SEL
        lda RANDOM                   ; y[0] = -(rnd % 16) -- RANDOM is I/O: read
        rep #$30                     ;   8-bit, B is junk until the and
        .LONGA ON
        .LONGI ON
        and #$000F
        eor #$FFFF
        inc @
        ldx #2*[SCREEN_WIDTH-1]      ; X = 2 * column, counting down: the walk
?y      sta mt_r,x                   ;   runs right to left, DOOM's mirrored --
        dex                          ;   the same distribution, and no compare
        dex                          ;   a pass
        bmi ?yd
        sep #$20
        lda RANDOM
        rep #$20
        and #$0003                   ; r = (rnd % 3) - 1, 3 counting as 0
        asl @
        tay
        lda mt_r3,y
        clc
        adc mt_r+2,x                 ; y[i] = y[i+1] + r
        bmi ?ng
        lda #0                       ; "if (y[i] > 0) y[i] = 0"
        bra ?y
?ng     cmp #$FFF0                   ; "else if (y[i] == -16) y[i] = -15"
        bne ?y
        inc @
        bra ?y
?yd     lda #MT_CWIN                 ; slot k is column 159-k (X counts down, the
        sta zp_ptr                   ;   slots up: each word loop's pad byte lands
        ldx #2*[SCREEN_WIDTH-1]      ;   on a slot not written yet). Any order
        clc                          ;   will do: the columns are independent
?c      txa                          ; S: row 199 onto itself; A, B: the spare
        adc #MT_BOT                  ;   row (C = 0: nothing below carries)
        sta mt_img+BCB_SRC_ADDR
        sta mt_img+BCB_DST_ADDR
        txa
        adc #MT_SPARE                ; (MT_BOT + 318 < 64K: C = 0)
        sta mt_img+BCB_SIZE+BCB_DST_ADDR
        sta mt_img+2*BCB_SIZE+BCB_DST_ADDR
        ldy #MT_COL-1                ; 32 words: the pad byte lands on the next
?w      lda mt_img,y                 ;   column's first, which it then rewrites
        sta [zp_ptr],y
        dey
        dey
        bpl ?w
        lda zp_ptr                   ; (C = 0 still: the adcs above do not carry,
        adc #MT_COL                  ;   and loads, stores and dey leave C alone)
        sta zp_ptr
        dex
        dex
        bpl ?c
        .LONGA OFF
        .LONGI OFF
        sep #$30
        lda #BLT_COPY                ; the last column's bar slot ends the chain
        sta MT_CWIN+SCREEN_WIDTH*MT_COL-1
        jmp mt_out
.endp
mt_init_w1 jsr mt_init               ; wi.asm stage 1's (bank 0)
        rtl

;--------------------------------------------------------------
; mt_step -- one wipe_doMelt tic: the last tic's chain waited for, every
;   running column's words rewritten, the chain fired. C = 1 while a column
;   has not landed. Chain order per column: the shift reads rows y..199-dy
;   before the new rows y..y+dy-1 overwrite them. A landed column's slots
;   stay as they were: its shift is a row copied onto itself, its fills copy
;   the new picture onto itself -- no-ops.
;--------------------------------------------------------------
.proc mt_step
        jsr blitw_hard               ; wait late: a tic ago it was fired
        pei (zp_ptr)
        lda zp_ptr+2
        pha
        stz zp_ptr+2
        lda #BANK_EN | [MT_CHAIN>>12]
        sta VBXE_BANK_SEL
        rep #$30
        .LONGA ON
        .LONGI ON
        lda #MT_CWIN                 ; slot k is column 159-k, as mt_init laid
        sta zp_ptr                   ;   them out
        stz mt_busy
        ldx #2*[SCREEN_WIDTH-1]      ; X = 2 * column: the screen offset too
        bra ?col
?lo     asl @                        ; the first steps (y < 16): dy = y+1, so
        inc @                        ;   ny = 2y+1 <= 31 (C = 0: the bcc, the asl)
        sta mt_r,x
        sta mt_n
        sta mt_busy
        eor #$FFFF                   ; HEIGHT-1 = 199 - ny = ~ny + 200
        adc #WIPE_H
        ora #$FF00                   ; [14] HEIGHT-1, [15] AND $FF
        ldy #BCB_HEIGHT
        sta [zp_ptr],y
        lda mt_y                     ; the source: row 199 - dy
        inc @
        asl @
        tay
        txa
        sec
        sbc mt_r320,y
        clc
        adc #MT_BOT
        bra ?sd
?clamp  lda #WIPE_H                  ; the landing step: to the bottom, and
        sta mt_r,x                   ;   nothing left to move -- row 199 onto
        sta mt_n                     ;   itself
        sta mt_busy
        lda #$FF00
        ldy #BCB_HEIGHT
        sta [zp_ptr],y
        txa
        clc
        adc #MT_BOT
        bra ?sd
?wait   inc @                        ; "if (y[i] < 0) y[i]++"
        sta mt_r,x
        inc mt_busy
        bra ?next
?land   bra ?next                    ; landed: its slots stay as they are
?col    lda mt_r,x
        bmi ?wait
        cmp #WIPE_H
        bcs ?land
        sta mt_y
        cmp #16                      ; dy = y < 16 ? y+1 : 8 -- the running
        bcc ?lo                      ;   column falls through every test
        adc #8-1                     ; (C = 1) ny = y + 8
        cmp #WIPE_H
        bcs ?clamp                   ; ny >= 200: the landing step
        sta mt_r,x                   ; (C = 0 from here: the bcs)
        sta mt_n
        sta mt_busy
        eor #$FFFF                   ; HEIGHT-1 = 199 - ny = ~ny + 200: ny < 200,
        adc #WIPE_H                  ;   so it carries -- C = 1
        ora #$FF00
        ldy #BCB_HEIGHT
        sta [zp_ptr],y
        txa                          ; the source: row 199 - 8 of this column (the
        adc #MT_BOT-8*MT_W-1         ;   -1 takes C)
?sd     sta [zp_ptr]                 ; [0-1] SRC
        lda mt_y                     ; --- A: the new picture's rows y..
sp1     cmp #WIPE_H                  ; SMC: the split (mt_init)
        bcs ?fb                      ; all under the split: A's last rows are
        asl @                        ;   new already -- left as a no-op copy
        tay
        txa
        adc mt_r320,y                ; (C = 0: bcs, and 2y < 400)
        ldy #BCB_SIZE+BCB_DST_ADDR
        sta [zp_ptr],y
smc     nop                          ; lsr @ out of the intermission: the view is
        ldy #BCB_SIZE+BCB_SRC_ADDR   ;   160 a row, one byte a column
        sta [zp_ptr],y
        lda mt_n                     ; ... to min(ny, split): C = 0 into the sbc
sp2     cmp #WIPE_H                  ;   (the -1 of HEIGHT) -- SMC: the split
        bcc ?a1                      ; (bcc taken: C = 0 already)
sp3     lda #WIPE_H                  ; SMC: the split
        clc
?a1     sbc mt_y
        ora #$FF00
        ldy #BCB_SIZE+BCB_HEIGHT
        sta [zp_ptr],y
?fb
sp4     lda #WIPE_H                  ; --- B: the bar's rows max(y, split)..ny-1
        cmp mt_n
        bcc ?fbx                     ; ny > split (melt 2's last steps): out of line
?next   lda zp_ptr
        clc
        adc #MT_COL
        sta zp_ptr
        dex
        dex
        bpl ?col
        lda mt_busy
        .LONGA OFF
        .LONGI OFF
        sep #$30
        clc                          ; C = 0: every column has landed
        beq mt_out
        lda #<MT_CHAIN
        sta VBXE_BL_ADR0
        lda #>MT_CHAIN               ; (BL_ADR2 stays 0: bank 0)
        sta VBXE_BL_ADR1
        lda #1
        sta VBXE_BL_START
        sec
        bra mt_out
        .LONGA ON
        .LONGI ON
?fbx    cmp mt_y                     ; (A = the split) r0 = max(y, split)
        bcs ?b1
        lda mt_y
?b1     sta mt_t
        asl @                        ; (r0 < 200: C = 0)
        tay
        txa
        adc mt_r320,y                ; (< 64000: C = 0)
        ldy #2*BCB_SIZE+BCB_DST_ADDR
        sta [zp_ptr],y
        adc #MT_BOFS
        ldy #2*BCB_SIZE+BCB_SRC_ADDR
        sta [zp_ptr],y
        lda mt_n
        clc
        sbc mt_t
        ora #$FF00
        ldy #2*BCB_SIZE+BCB_HEIGHT
        sta [zp_ptr],y
        bra ?next
        .LONGA OFF
        .LONGI OFF
.endp
mt_step_w1 jsr mt_step               ; wi.asm stage 1's: C = still melting
        rtl

;--------------------------------------------------------------
; mt_out -- mt_init's and mt_step's tail: the window back on the overhead
;   bank, zp_ptr off the stack. Keeps C.
;--------------------------------------------------------------
.proc mt_out
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        pla
        sta zp_ptr+2
        rep #$20
        .LONGA ON
        pla
        sta zp_ptr
        .LONGA OFF
        sep #$20
        rts
.endp

;--------------------------------------------------------------
; mt_show -- A = the chain in mt_bimg to run onto MT_SR (MT_GRAB: the frame
;   shown at 320; MT_BAR: the bar alone, the automap's S0 being MT_SR; MT_AMS1:
;   the automap's S1 and the bar; MT_KEEP: the stats surface), and MT_SR on
;   screen through list R.
;   The list is melt.asm's own out of SDRAM (the pool may be a level's): it
;   is copied by the CPU while the blit runs. With mn_fin set (the control
;   panel over a finale) FRAME_A holds all 200 rows and there is no bar.
;--------------------------------------------------------------
MT_GRAB equ 0
MT_BAR  equ BCB_SIZE
MT_KEEP equ 2*BCB_SIZE
MT_AMS1 equ 3*BCB_SIZE
MT_XDLX equ [[WIMAP_BANK]<<16]+WI_MTXOFF  ; WIMAP0's bank: every build has it
.proc mt_show
        pha
        lda #BANK_EN | [MT_GRABV>>12]
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        ldx #6*BCB_SIZE-2            ; 63 words
?w      lda.l B1CODE_BASE+mt_bimg,x  ; long,x both ways: bank $01 data, and no
        sta.l MT_GWIN,x              ;   dummy read of the window
        dex
        dex
        bpl ?w
        .LONGA OFF
        sep #$20
        lda ZFRONT                   ; [2] the view's buffer
        sta MT_GWIN+BCB_SRC_ADDR+2
        lda mn_fin
        beq ?bar
        lda #WIPE_H-1                ; [14] all 200 rows, [20] and no bar after
        sta MT_GWIN+BCB_HEIGHT
        lda #BLT_COPY
        sta MT_GWIN+BCB_CTRL
?bar    lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        jsr blitw_hard               ; the game's (or the stats') last blits
        pla
        sta VBXE_BL_ADR0             ; <MT_GRABV is 0 (ert above)
        lda #>MT_GRABV
        sta VBXE_BL_ADR1
        lda #1
        sta VBXE_BL_START            ; fire early ...
        lda #[MT_XDLX>>16]           ; ... the list while it runs ...
        sta sf_src+2
        stz sp_addr+2                ;   (list R is bank 0)
        rep #$20
        .LONGA ON
        lda #MT_XDLX&$FFFF
        sta sf_src
        lda #VRAM_XDL_R&$FFFF
        sta sp_addr
        lda #WI_MTXLEN
        sta sf_size
        .LONGA OFF
        sep #$20
        jsr spr_fcopy
        jsr blitw_hard               ; ... wait late: landed before it shows
        jmp xdl_to_r.show
.endp
mt_grab_w1                           ; wi_main's: the last frame, at 320
        jsr mt_gsel
        jsr mt_show
        stz am_on                    ; AM_Stop (G_DoCompleted): the lists go back
        rtl                          ;   to the view by themselves (st_frame)

;--------------------------------------------------------------
; mt_gsel -- A = the grab of what is on screen: the view zoomed 2x and the bar,
;   or with the automap up its surface as it stands (ZFRONT: S0 is MT_SR
;   itself, S1 is copied in) and the bar.
;--------------------------------------------------------------
.proc mt_gsel
        lda am_on
        beq ?v
        lda ZFRONT
        beq ?s0
        lda #MT_AMS1
        rts
?s0     lda #MT_BAR
        rts
?v      lda #MT_GRAB
        rts
.endp
mt_keep_w1                           ; ...and the stats, for the level load
        lda #MT_KEEP
        jsr mt_show
        rtl

;   mt_show's: the view zoomed 2x and the bar (MT_GRAB), the surface (MT_KEEP)
mt_bimg   dta 0, 0, 0, a(SCREEN_WIDTH), 1
          dta <MT_SR, >MT_SR, MT_BK, a(MT_W), 1, a(SCREEN_WIDTH-1), VIEW_HEIGHT-1, $FF, 0, 0, BLT_ZOOM_2X, 0, BLT_COPY|BLT_NEXT
          dta <VRAM_BAR320, >VRAM_BAR320, [VRAM_BAR320>>16], a(MT_W), 1
          dta <[MT_SR+VIEW_HEIGHT*MT_W], >[MT_SR+VIEW_HEIGHT*MT_W], MT_BK, a(MT_W), 1, a(MT_W-1), WIPE_H-VIEW_HEIGHT-1, $FF, 0, 0, 0, 0, BLT_COPY
          dta <WI_SRVRAM, >WI_SRVRAM, [WI_SRVRAM>>16], a(MT_W), 1
          dta <MT_SR, >MT_SR, MT_BK, a(MT_W), 1, a(MT_W-1), WIPE_H-1, $FF, 0, 0, 0, 0, BLT_COPY
          dta <AM_S1, >AM_S1, [AM_S1>>16], a(MT_W), 1           ; the automap's S1
          dta <MT_SR, >MT_SR, MT_BK, a(MT_W), 1, a(MT_W-1), AM_S1B-1, $FF, 0, 0, 0, 0, BLT_COPY|BLT_NEXT
          dta <AM_S1B2, >AM_S1B2, [AM_S1B2>>16], a(MT_W), 1
          dta <[MT_SR+AM_S1B*MT_W], >[MT_SR+AM_S1B*MT_W], MT_BK, a(MT_W), 1, a(MT_W-1), VIEW_HEIGHT-AM_S1B-1, $FF, 0, 0, 0, 0, BLT_COPY|BLT_NEXT
          dta <VRAM_BAR320, >VRAM_BAR320, [VRAM_BAR320>>16], a(MT_W), 1
          dta <[MT_SR+VIEW_HEIGHT*MT_W], >[MT_SR+VIEW_HEIGHT*MT_W], MT_BK, a(MT_W), 1, a(MT_W-1), WIPE_H-VIEW_HEIGHT-1, $FF, 0, 0, 0, 0, BLT_COPY
    .if MT_GRABV+6*BCB_SIZE > AM_CLRV
        ert 'melt.asm: mt_show's six BCBs run into the automap's clear chains'
    .endif
        .endseg

