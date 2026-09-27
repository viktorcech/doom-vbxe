;--------------------------------------------------------------
; f_finale.asm -- the end-of-episode finale (f_finale.c): story text, then the
;   picture / bunny scroll. MAP_HFINEP in the level header selects it.
;--------------------------------------------------------------
FIN_TICQ8   equ 179                  ; 35/50 in Q8 -- the same 50 Hz -> DOOM tic
                                     ;   accumulator wi_tic runs on
FIN_TROWS   equ 4                    ; flat tiles down a 200-row screen

;==============================================================
; PART 1 -- the RESIDENT stub. Everything else here is overlay.
;==============================================================
fin_resume = *

;--------------------------------------------------------------
; fin_exit -- the frame loop's EXIT_REQ tail. main's `jsr wi_exit` points HERE
;   instead; the intermission's own stub is one `jmp` further on, so a level
;   that is not an ExM8 behaves exactly as it always did.
;--------------------------------------------------------------
        org FINEXIT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fin_exit
        ldx EXIT_REQ
        dex                          ; X = mn_open's entry index (WI_E_INTER)
        bne ?wi
        lda MAP_HFINEP               ; still readable: the map slot is untouched
        beq ?wi                      ;   until exit_level runs
        lda #BANK_EN | FINOVL_BANK
        jsl mn_open_w0 ; ...which lands in fin_head below
        rts                          ; DRAC_PLAN 4b (xbank_fix.py)
?wi     jmp wi_exit                  ; (same bank; the B1 segment moved it out
.endp                                ;   of a branch's reach)
        .endseg

;--------------------------------------------------------------
; fin_esc -- M_StartControlPanel from inside the finale, and the ONE part of
;   this that cannot live in the overlay: NEW GAME reloads a level, and a level
;   load streams a map straight over stage 2 in the slot.
;--------------------------------------------------------------
.proc fin_esc
        lda #BANK_EN | MENU_OBANK
        ldx #MN_E_INGAME
        jsr mn_open                  ; ...lands in mn_ingame, whose rts comes back
        lda EXIT_REQ
        beq ?out
        jmp FIN2_RESUME
?out    rts
.endp
    .if * > FINEXIT_END+1
        ert 'fin_exit/fin_esc outgrew FINEXIT_BASE..END (memory_map.inc)'
    .endif
        org fin_resume

;==============================================================
; PART 2 -- STAGE 1, the bootstrap, at MENU_RUN ($1000-$14FF). Parked in the
;   MEMAC window's address space, which carries no XEX segment of its own;
;   tools/split_menu_ovl.py lifts the block out of the XEX and into menu.bin's
;   reserved chunk before check_xex.py ever sees it.
;==============================================================
        org MENU_RUN, FINOVL_STAGE

;--------------------------------------------------------------
; fin_head -- the FIRST bytes at MENU_RUN, so mn_open's `jmp MENU_RUN` lands
;   here with the window still on FINOVL_BANK. mn_open copied page 0 (this),
;   which is the whole of stage 1: pages 1-4 are never needed, because the
;   finale NEVER LOADS A LEVEL. wi.asm's stage 1 has to keep an across-the-load
;--------------------------------------------------------------
FIN2_WIN        equ MEMW16+[[FIN2_BANK&3]<<12]     ; DRAC_PLAN 3b: 16 KB window: stage 2's chunk
.proc fin_head
        lda #BANK_EN | FIN2_BANK
        sta VBXE_BANK_SEL
                                      ; 2026-09-23: pages in any order (no overlap):
        ldx #FIN2_PAGES-1            ;   count down, dex/bpl, no cpx
?s2     txa                          ; page X of the chunk -> page X of the slot
        clc
        adc #>FIN2_WIN
        sta ?src+2                   ; >FIN2_WIN+X cannot carry (ert below), so
        adc #<[[>FIN2_RUN]-[>FIN2_WIN]]  ;   the second add rides on C=0 and A
        sta ?dst+2                   ;   instead of a fresh txa/clc (wi_head's)
    .if [>FIN2_WIN] + [[FIN2_END+1-FIN2_RUN]/256] > 255
        ert 'fin_head: >FIN2_WIN + page carries -- put the txa/clc back'
    .endif
        ldy #0
?src    lda FIN2_WIN,y
?dst    sta FIN2_RUN,y
        iny
        bne ?src
        dex
        bpl ?s2
        lda #BANK_EN | BANK_OVERHEAD ; the BCBs live there, and every blit from
        sta VBXE_BANK_SEL            ;   here on writes one
        jmp FIN2_RUN
.endp

    .if * > MENU_RUN_END+1
        ert 'f_finale.asm STAGE 1 outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif

;==============================================================
; PART 3 -- STAGE 2, in the map slot. Two-address `org`: it RUNS at FIN2_RUN,
;   where wi.asm's stage 2 runs too (they can never both be live), and is PARKED
;   at FIN2_STAGE so split_menu_ovl.py can tell the two segments apart.
;==============================================================
        org FIN2_RUN, FIN2_STAGE
        jmp fin_main                 ; fin_head's `jmp FIN2_RUN` lands here, so
                                     ;   the tables below can come first
        jmp fin_back                 ; ...and FIN2_RESUME right behind it: where
                                     ;   fin_esc comes back when the control
                                     ;   panel was only closed
    .if FIN2_RESUME != FIN2_RUN+3
        ert 'FIN2_RESUME must be the SECOND jmp of stage 2 (memory_map.inc)'
    .endif

        icl 'fin_syms.inc'           ; the geometry, the glyph widths and the
                                     ;   END patch table (tools/pack_fin.py)

; The three texts are read a byte at a time through the MEMAC window, so each
; one has to sit inside a SINGLE 4 KB chunk -- fin_getc maps one bank and never
; steps it.
    .if [FIN_TEXT1 >> 12] != [[FIN_TEXT1+FIN_TLEN1] >> 12]
        ert 'E1TEXT crosses a 4 KB chunk -- fin_getc reads through ONE window'
    .endif
    .if [FIN_TEXT2 >> 12] != [[FIN_TEXT2+FIN_TLEN2] >> 12]
        ert 'E2TEXT crosses a 4 KB chunk -- fin_getc reads through ONE window'
    .endif
    .if [FIN_TEXT3 >> 12] != [[FIN_TEXT3+FIN_TLEN3] >> 12]
        ert 'E3TEXT crosses a 4 KB chunk -- fin_getc reads through ONE window'
    .endif
    .if FIN_TROWS*FIN_TILE_H < SCREEN_HEIGHT
        ert 'fin_bg: FIN_TROWS tile rows do not cover SCREEN_HEIGHT'
    .endif
; The finale's data is the LAST thing in the intermission's consecutive bank run
; (pack_menu.py), so the top of that run is the top of everything the boot
; stream owns. The TEXT stage's SR surface starts right above it and ends below
; FRAME_C: it spans WIPE_START, which only the melt and the weapon fuzz use --
; and neither runs during a finale (it loads no level). Nothing the ESC menu
; does reaches it either, so the text needs no save across the control panel.
    .if [[FIN_BANK+FIN_CHUNKS]*4096] > FIN_TXSR || FIN_TXSR+FIN_SR_W*SCREEN_HEIGHT > FRAME_C || [FIN_TXSR & $FFFF] <> 0
        ert 'the text surface: bank-aligned, above the WI+FIN run, below FRAME_C'
    .endif

; Where the streamed art LANDS: each episode's finpic.bin section at FIN_ARENA
; -- its stage-1 art, then its font and flat (pack_fin.py). Stage 1 is 320x200
; SR: a page shows through its own list, the bunny pair through a list on the
; 640-wide surface that fin_pan slides.
FIN_ENDA    equ FIN_ARENA + FIN_END_OFF
FIN_PGXDL   equ FIN_ARENA + FIN_PAGE_XDL          ; HELP2 / VICTORY2's list
FIN_TXL     equ FIN_VRAM + FIN_TXL_OFF            ; the text stage's list
FIN_BNXDL   equ FIN_ARENA + FIN_BUN_XDL           ; the bunny pair's (scrolled 320)
FIN_ENDD    equ FIN_ARENA + FIN_END_Y*FIN_BUN_W + FIN_END_X   ; the END box...
FIN_ETWIN    equ FIN_ENDD + FIN_SR_W               ; ...and its copy, off screen
FIN_WXDL    equ MEMW16+[[[VRAM_XDL_R>>12]&3]<<12]+[VRAM_XDL_R&$FFF]  ; list R
    .if FIN_ARENA_P <> FIN_ARENA
        ert 'pack_fin.py FIN_ARENA_VRAM is not memory_map.inc FIN_ARENA'
    .endif

;--------------------------------------------------------------
; fin_main -- F_StartFinale, then F_Ticker/F_Drawer once per DOOM tic.
;--------------------------------------------------------------
.proc fin_main
        stz am_on                    ; AM_Stop (G_DoCompleted)
        lda MAP_HFINEP               ; 1-3. The slot only holds a MAP below
        sta fn_ep                    ;   $4100, and this is at $401D
        jsr fin_setup
        jsr fin_load                 ; the art, the font and the flat -> the arena
        jsr fin_bg                   ; the tiled floor FIRST and the list AFTER
        jsr fin_show                 ;   it
fin_loop jsr fin_tic
        inc fn_cnt                   ; finalecount++
        bne ?nc
        inc fn_cnt+1
?nc     jsr fin_kbd                  ; C=1 = ESC, and it is the only key that
        bcc ?run                     ;   does anything at all here
        jsr fin_panel                ; what the panel draws over: THIS screen
        jmp fin_esc                  ;   -- and NO stack frame of ours
?run    lda fn_stage
        bne ?st1
        jsr fin_type                 ; F_TextWrite, one character at a time
                                      ; 2026-09-23: one word compare (sep keeps C)
        rep #$20
        .LONGA ON
        lda fn_cnt                   ; finalecount > strlen*TEXTSPEED + TEXTWAIT
        cmp fn_wait
        .LONGA OFF
        sep #$20
        bcc fin_loop
?adv    jsr fin_stage1
        bra fin_loop
?st1    lda fn_ep                    ; stage 1 just SITS there, exactly as DOOM
        cmp #3                       ;   does -- F_Ticker never leaves it and
        bne fin_loop                 ;   F_Responder eats nothing
        jsr fin_bunny                ; F_BunnyScroll, episode 3 only
        bra fin_loop
.endp

;--------------------------------------------------------------
; fin_back -- FIN2_RESUME: the control panel was closed, so put the finale's own
;   screen back and carry on where the clock left off. Nothing streamed while
;   the menu was up (it runs at MENU_RUN and reads no sectors), so every byte of
;   stage 2 -- code, tables and the tic counter -- is exactly as it was. The
;   panel's screen is MT_SR, which IS the text stage's surface: that one is
;   drawn again (fin_redo). A page or the bunny pair lives in the arena.
;--------------------------------------------------------------
.proc fin_back
        lda #BANK_EN | BANK_OVERHEAD ; the menu left the window on ITS bank
        sta VBXE_BANK_SEL
        lda fn_stage
        bne ?show
        jsr fin_redo
?show   jsr fin_show
        bra fin_main.fin_loop
.endp
    .if FIN_TXSR <> MT_SR
        ert 'fin_back redraws the text because the panel draws on MT_SR = FIN_TXSR'
    .endif

;--------------------------------------------------------------
; fin_redo -- the text stage again, at once: the floor, then every character
;   the typewriter has read so far (up to fin_getc's operand, parked on the
;   stack while the replay walks it from the text's start).
;--------------------------------------------------------------
.proc fin_redo
        rep #$20
        .LONGA ON
        lda fin_getc.fin_rd+1        ; how far the typewriter got: a word, parked
        pha
        .LONGA OFF
        sep #$20
        jsr fin_bg
        ldx fn_ep
        dex
        lda fin_txlo,x               ; finaletext's start (fin_setup's)
        sta fin_getc.fin_rd+1
        lda fin_txhi,x
        sta fin_getc.fin_rd+2
        stz fn_tdone
        rep #$20
        .LONGA ON
        lda #FIN_CX0
        sta fn_cx
        lda #FIN_CY0*FIN_SR_W
        sta fn_row
        bra ?c1
?c      rep #$20
?c1     lda fin_getc.fin_rd+1        ; back where it was? One word compare
        cmp 1,s
        .LONGA OFF
        sep #$20                     ; (sep keeps Z)
        beq ?done
        jsr fin_char
        bra ?c
?done   pla
        pla
        rts
.endp

;--------------------------------------------------------------
; fin_panel -- ESC: D_Display draws M_Drawer over F_Drawer (d_main.c:255/315),
;   so the control panel goes over THIS screen, with no view and no status bar.
;   The panel builds its 320 screen out of FRAME_A zoomed 2x and restores its
;   boxes out of it (menu.asm mn_frz / mn_sbox): FRAME_A gets the 160 copy of
;   the screen as shown -- row 0 and pitch straight out of list R's first
;   entry, so the text, a page and the bunny pair mid-scroll are all one case
;   -- all 200 rows of it (mn_fin: no bar).
;--------------------------------------------------------------
.proc fin_panel
        jsr blitter_wait_t           ; the screen complete before it is copied
        lda #BANK_EN | [VRAM_XDL_R>>12]
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        lda FIN_WXDL+3               ; entry 0's OVADR lo/mid ...
        sta sr_src
        lda FIN_WXDL+5               ; ... its bank, and OVSTEP lo
        sta sr_src+2
        .LONGA OFF
        sep #$20
        lda FIN_WXDL+7               ; OVSTEP hi
        sta sr_step+1
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        lda #[VRAM_SCREEN>>16]       ; FRAME_A: all 200 rows
        jsl B1CODE_BASE+sr_half_w1
        lda #1
        sta mn_fin
        rts
.endp

;--------------------------------------------------------------
; fin_setup -- F_StartFinale's per-episode picks (f_finale.c:116) plus the
;   typewriter's own state. fn_ep is already in.
;--------------------------------------------------------------
.proc fin_setup
        ldx fn_ep
        dex                          ; 0-2
        lda fin_txlo,x               ; finaletext, as a window address
        sta fin_getc.fin_rd+1
        lda fin_txhi,x
        sta fin_getc.fin_rd+2
        lda fin_txbk,x
        sta fn_tbk
        lda fin_ftlo,x               ; the font, from this episode's section
        sta fn_font
        lda fin_ftmi,x
        sta fn_font+1
        lda fin_ftbk,x
        sta fn_font+2
        lda fin_wtlo,x
        sta fn_wait
        lda fin_wthi,x
        sta fn_wait+1
        stz fn_stage                 ; finalestage
        stz fn_cnt                   ; finalecount
        stz fn_cnt+1
        stz fn_tdone
        stz fn_tacc
        stz fn_karm                  ; the key that threw the EXIT switch is
                                     ;   still DOWN: it has to come up first
        rep #$20
        .LONGA ON
        lda #FIN_CX0                 ; cx, 0..320: a word
        sta fn_cx
        lda #FIN_CY0*FIN_SR_W        ; cy as its row's offset on the surface
        sta fn_row
        lda #FIN_SR_W                ; every blit steps a 320 row, until THE END
        sta fb_dpitch
        .LONGA OFF
        sep #$20
        lda #10+FIN_SPEED            ; count = (finalecount-10)/TEXTSPEED, so
        sta fn_tsp                   ;   the first glyph lands on tic 13
        lda #$FF
        sta fn_endst                 ; no END letter yet (fin_show seeds fn_scrv)
        rts
.endp

;--------------------------------------------------------------
; fin_tic -- wait for the next DOOM tic, exactly as wi_tic does: one VBLANK at
;   a time, with a Q8 accumulator turning 50 Hz into 35.
;--------------------------------------------------------------
.proc fin_tic
?v      lda RTCLOK3
?w      cmp RTCLOK3
        beq ?w
        lda fn_tacc
        clc
        adc #FIN_TICQ8
        sta fn_tacc
        bcc ?v
        rts
.endp

;--------------------------------------------------------------
; fin_show -- the finale's screen, and nothing about to take it away again:
;   an SR list blitted to list R (menu.asm xdl_to_r). Stage 0 is the text on
;   FIN_TXSR; stage 1 the art in FIN_ARENA -- episode 3's list says scrolled =
;   320, so fin_scroll slides it to where the clock is, also after fin_back.
;--------------------------------------------------------------
.proc fin_show
                                      ; 2026-09-23: the blits are async now -- the
        jsr blitter_wait_t           ;   picture complete before it is shown
        stz zback_hi
        stz ZFRONT
        stz XDLA_PEND                ; $00 = rom_nmi's "nothing pending"
        ldy fn_ep
        lda fn_stage                 ; Z = the text stage (rep keeps Z)
        rep #$20
        .LONGA ON
        beq ?text
        lda #FIN_SR_W                ; what episode 3's list shows (the others
        sta fn_scrv                  ;   never read it)
        lda #FIN_PGXDL&$FFFF
        ldx #[FIN_PGXDL>>16]
        cpy #3
        bne ?go
        lda #FIN_BNXDL&$FFFF
        ldx #[FIN_BNXDL>>16]
        bra ?go
?text   lda #FIN_TXL&$FFFF
        ldx #[FIN_TXL>>16]
?go     jsl B1CODE_BASE+xdl_to_r_w1  ; returns 8-bit
        .LONGA OFF
        lda fn_stage                 ; (the blit wait inside took Y)
        beq ?out
        lda fn_ep
        cmp #3
        jeq fin_scroll               ; the bunny list to the clock's position
?out    rts
.endp

;--------------------------------------------------------------
; fin_kbd -- ESC, edge triggered: C=1 once per press. read_keys does not run
;   here (the frame loop is stopped for the whole finale), so this is mn_key's
;   test done by hand -- SKSTAT bit2 for "a key is down", KBCODE for which.
;--------------------------------------------------------------
.proc fin_kbd
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        bne ?up
        lda KBCODE
        and #$3F                     ; bare code (no shift/ctrl)
        cmp #KEY_ESC
        bne ?no
        lda fn_karm
        beq ?no
        stz fn_karm
        sec
        rts
?up     lda #1
        sta fn_karm
?no     clc
        rts
.endp

;--------------------------------------------------------------
; fin_load -- this episode's finpic.bin section (its stage-1 art, font and
;   flat) into the sprite/texture arena. Legal for the same reason
;   mn_readthis' HELP pages are: the pool holds the level's own graphics, and
;   by the time a finale runs the level is over. The screen is black while it
;   streams: nothing of the finale is up yet, and the level's frame is not.
;--------------------------------------------------------------
.proc fin_load
        stz VBXE_VCTL                ; black (fin_show's xdl_to_r turns it on)
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a): so is rom_in_t
        lda #$40
        sta NMIEN
        cli
        jsr snd_stop                 ; the DAC silent and Timer-1 disarmed
        stz SOUNDR_R                 ;   BEFORE SIO takes the chip, or the tone
                                     ;   it was mid-way through squeals for the
                                     ;   whole read (the 2026-08-04 bug)
        ldx fn_ep                    ; the episode's PACKED stream (2026-09-26):
        dex                          ;   inflate -> MENU_BOUNCE -> the arena,
        jsl B1CODE_BASE+fin_pak_w1   ;   half the old ~2,400-sector read
        sei
        jsr rom_out_t
        jmp snd_pokey_t ; ...and POKEY back the way snd_init left it
.endp

;--------------------------------------------------------------
; fin_bg -- F_TextWrite's tiled background (f_finale.c:274). DOOM memcpy's the
;   flat row by row; the blitter tiles it as 5 x 4 rectangles out of ONE 64x64
;   copy of the flat, which is why pack_fin.py ships the flat and not a page.
;   The bottom row is clipped: 200 is not a multiple of 64.
;--------------------------------------------------------------
.proc fin_bg
        ldx fn_ep
        dex
        lda fin_flo,x
        sta fb_src
        lda fin_fmi,x
        sta fb_src+1
        lda fin_fbk,x
        sta fb_src+2
        lda #FIN_TILE_W              ; (fb_stride+1 is 0 until THE END)
        sta fb_stride
        lda #FIN_TILE_W-1
        sta fb_w
        lda #BLT_COPY
        sta fb_ctrl
        lda #[FIN_TXSR>>16]          ; the surface's bank, for every tile
        sta fb_dst+2
        stz fn_ti
?row    ldx fn_ti
        lda fin_tht,x
        sta fb_h
        txa
        asl
        tax                          ; X = row*2, the word table's index
        rep #$20
        .LONGA ON
        lda fin_tyo,x                ; the row's leftmost tile, y*320
        sta fb_dst
        .LONGA OFF
        sep #$20
        lda #FIN_SR_W/FIN_TILE_W     ; five tiles across
        sta fn_tx
?col    jsr fin_blit                 ; (8-bit: it reads the blitter's BUSY first)
        rep #$21
        .LONGA ON
        lda fb_dst                   ; one tile right: a row ends <= 64000, so
        adc #FIN_TILE_W              ;   nothing carries into the bank
        sta fb_dst
        .LONGA OFF
        sep #$20
        dec fn_tx
        bne ?col
        inc fn_ti
        lda fn_ti
        cmp #FIN_TROWS
        bcc ?row
        rts
.endp
    .if FIN_SR_W % FIN_TILE_W <> 0
        ert 'fin_bg: the flat does not tile a 320 row exactly'
    .endif

;--------------------------------------------------------------
; fin_type -- F_TextWrite's inner loop (f_finale.c:290), one character per
;   TEXTSPEED tics instead of "all of them, every frame". cx/cy carry over from
;   tic to tic, which is what makes that equivalent.
;--------------------------------------------------------------
.proc fin_type
        lda fn_tdone                 ; the NUL, or a line that ran off the right
        bne ?out                     ;   edge -- DOOM breaks out of the loop
        dec fn_tsp
        beq ?go
?out    rts
?go     lda #FIN_SPEED
        sta fn_tsp
        ert *<>fin_char              ; fall through
.endp

;--------------------------------------------------------------
; fin_char -- one character of finaletext: read, then drawn or stepped over.
;   fin_redo replays the text through here.
;--------------------------------------------------------------
.proc fin_char
        jsr fin_getc
        bne ?ch
        inc fn_tdone                 ; fn_tdone is 0 here (fin_type's bne, and
                                     ;   fin_redo's stz), so the inc alone IS
        rts                          ;   "= 1" -- no store first
?ch     cmp #$0A                     ; '\n': cx = 10, cy += 11 (cy as its row's
        bne ?g                       ;   offset on the surface: += 11*320)
        rep #$21
        .LONGA ON
        lda #FIN_CX0
        sta fn_cx
        lda fn_row
        adc #FIN_LINEH*FIN_SR_W
        sta fn_row
        .LONGA OFF
        sep #$20
        rts
?g      sec
        sbc #FIN_FIRST               ; c = toupper(c) - HU_FONTSTART. The texts
        bcc ?sp                      ;   are packed upper-cased already
        cmp #FIN_LAST-FIN_FIRST+1
        bcs ?sp
        tax
        lda fin_fw,x                 ; w = SHORT(hu_font[c]->width)
        sta fn_gw                    ;   (fn_gw+1 stays 0: read as a word)
        rep #$21
        .LONGA ON
        lda fn_gw                    ; if (cx+w > SCREENWIDTH) break
        adc fn_cx
        cmp #FIN_SR_W+1
        .LONGA OFF
        sep #$20                     ; (sep keeps C)
        bcs ?stop
        jsr fin_putc                 ; X = the glyph
        rep #$21
        .LONGA ON
        lda fn_cx
        adc fn_gw
        sta fn_cx
        .LONGA OFF
        sep #$20
        rts
?sp     rep #$21                     ; not a glyph -- space and friends: cx += 4
        .LONGA ON
        lda fn_cx
        adc #FIN_SPACEW
        sta fn_cx
        .LONGA OFF
        sep #$20
        rts
?stop   lda #1
        sta fn_tdone
        rts
.endp

;--------------------------------------------------------------
; fin_putc -- V_DrawPatch(cx, cy, hu_font[X]). The font is a FIXED-STRIDE cell
;   block, so a glyph's address is a shift and not a table lookup; the DRAWN
;   width is the real one (fin_fw), which is why the source pitch has to be set
;   independently of it -- hud_blit's 7-byte row cannot express that.
;   BLT_BSTENCIL: index 0 is the transparent surround, so the flat shows through.
;--------------------------------------------------------------
.proc fin_putc
        lda fn_font+2                ; the episode's font (fin_setup); no glyph
        sta fb_src+2                 ;   of it crosses a bank (ert below)
        lda #[FIN_TXSR>>16]
        sta fb_dst+2
        txa                          ; index * FIN_GLYPH (128) as a word: the
        rep #$20                     ;   index * 256 by xba, halved by lsr -- and
        .LONGA ON                    ;   the lsr's C is the dropped bit 0 of
        and #$00FF                   ;   index*256: 0, so the adc needs no clc
        xba
        lsr @
        adc fn_font
        sta fb_src
        lda fn_row                   ; the surface at (cx, cy): cy's row + cx
        clc
        adc fn_cx
        sta fb_dst
        .LONGA OFF
        sep #$20
        lda #FIN_CELL                ; (fb_stride+1 is 0 until THE END)
        sta fb_stride
        lda fn_gw
        dec @
        sta fb_w
        lda #FIN_FONT_H-1
        sta fb_h
        lda #BLT_BSTENCIL
        sta fb_ctrl
        jmp fin_blit
.endp
    .if FIN_GLYPH <> 128
        ert 'fin_putc: a glyph is index*256/2 -- FIN_GLYPH must be 128'
    .endif
    .if [[FIN_ARENA+FIN_FONTA1]>>16] <> [[FIN_ARENA+FIN_FONTA1+FIN_GLYPH*[FIN_LAST-FIN_FIRST+1]-1]>>16] || [[FIN_ARENA+FIN_FONTA3]>>16] <> [[FIN_ARENA+FIN_FONTA3+FIN_GLYPH*[FIN_LAST-FIN_FIRST+1]-1]>>16]
        ert 'fin_putc: a font crosses a 64 KB bank'
    .endif


; fin_getc -- the next character of finaletext. The texts stay in VRAM: 1.6 KB
;   of 6502 RAM is 1.6 KB this port does not have, and one byte a tic is the
;   whole cost. The read address is the instruction's own operand, so there is
;   no zero-page pointer either -- fin_setup seeds it and this walks it.
;--------------------------------------------------------------
.proc fin_getc
        lda fn_tbk
        sta VBXE_BANK_SEL
fin_rd  lda $FFFF                    ; patched by fin_setup
        ldx #BANK_EN | BANK_OVERHEAD ; the BCBs, before anything blits again
        stx VBXE_BANK_SEL
        inc fin_rd+1                 ; memory incs: A keeps the byte, so no
        bne ?nc                      ;   pha/pla -- only Z has to be rebuilt
        inc fin_rd+2                 ;   for the caller's bne (ora #0)
?nc     ora #0
        rts
.endp

;--------------------------------------------------------------
; fin_stage1 -- F_Ticker's stage change (f_finale.c:223): finalecount = 0,
;   finalestage = 1. The art is already in FIN_ARENA (fin_load): showing it is
;   a list switch, and episode 3's scroll moves that list, not the pixels.
;--------------------------------------------------------------
.proc fin_stage1
        lda #1
        sta fn_stage
        stz fn_cnt
        stz fn_cnt+1
        jmp fin_show
.endp

;--------------------------------------------------------------
; fin_bunny -- one tic of F_BunnyScroll (f_finale.c:644).
;--------------------------------------------------------------
.proc fin_bunny
        jsr fin_scroll
        jmp fin_ends
.endp

;--------------------------------------------------------------
; fin_scroll -- scrolled = 320 - (finalecount-230)/2, clamped 0..320: DOOM's
;   own numbers, one pixel every two tics. Screen column x is surface column
;   x+scrolled of the 640-wide PFUB2|PFUB1 pair, so a move is fin_pan adding
;   the change to the list -- no pixel is copied.
;--------------------------------------------------------------
.proc fin_scroll
        rep #$20
        .LONGA ON
        sec
        lda fn_cnt
        sbc #FIN_BUN_T0
        bcc ?full                    ; finalecount < 230: nothing has moved yet
        lsr @
        cmp #FIN_SR_W
        bcs ?zero                    ; long past the end
        eor #$FFFF                   ; 320-d as ~d + 321 (C = 0: the bcs fell
        adc #FIN_SR_W+1              ;   through)
        bra ?h
?zero   lda #0
        bra ?h
?full   lda #FIN_SR_W
?h      sec
        sbc fn_scrv                  ; the move since the list was last set
        beq ?same
        sta fn_dlt
        clc
        adc fn_scrv                  ; = the new position again
        sta fn_scrv
        .LONGA OFF
        sep #$20
        bra fin_pan
?same   sep #$20
        rts
.endp

;--------------------------------------------------------------
; fin_pan -- fn_dlt (signed 16-bit) onto every entry's OVADR in list R, in
;   place through the window: [zp_tsrc],y with bank byte zp_savex = 0 has no
;   indexed dummy read (load_vram's pointer). The low word adds 16-bit, the
;   bank byte takes the carry and the delta's sign. Runs right after fin_tic's
;   VBLANK, well inside the blank for 81 entries.
;--------------------------------------------------------------
.proc fin_pan
        ldx #0                       ; the bank byte's addend: 0 or $FF by sign
        lda fn_dlt+1
        bpl ?p
        dex
?p      stx ?ext+1                   ; (stage-2 RAM code: self-mod is ok)
        lda #BANK_EN | [VRAM_XDL_R>>12]
        sta VBXE_BANK_SEL
        stz zp_savex
        ldx #FIN_XDL_N
        ldy #0                       ; the first entry's OVADR at +3; ATT puts
        rep #$20                     ;   every later one 2 further on: y = 2
        .LONGA ON
        lda #FIN_WXDL+3
        sta zp_tsrc
?e      lda [zp_tsrc],y              ; OVADR lo/mid
        clc
        adc fn_dlt
        sta [zp_tsrc],y
        .LONGA OFF
        sep #$20
        iny
        iny
        lda [zp_tsrc],y              ; OVADR bank + the carry + the sign
?ext    adc #0
        sta [zp_tsrc],y
        rep #$21                     ; C = 0 for the step to the next entry
        .LONGA ON
        lda zp_tsrc
        adc #8
        sta zp_tsrc
        ldy #2
        dex
        bne ?e
        .LONGA OFF
        sep #$20
        lda #BANK_EN | BANK_OVERHEAD ; the BCBs, before anything blits again
        sta VBXE_BANK_SEL
        rts
.endp

;--------------------------------------------------------------
; fin_ends -- END0 at finalecount 1130, then one more letter every five tics
;   from 1180 (f_finale.c:672), with sfx_pistol behind each one. DOOM re-reads
;   `stage` off the clock every frame; a countdown says the same thing without
;   a divide.
;--------------------------------------------------------------
.proc fin_ends
        lda fn_endst
        bpl ?run
                                      ; 2026-09-23: one word compare (sep keeps C)
        rep #$20
        .LONGA ON
        lda fn_cnt                   ; nothing at all before 1130
        cmp #FIN_BUN_END0
        .LONGA OFF
        sep #$20
        bcc ?out
?go     stz fn_endst
        lda #FIN_BUN_ST0-FIN_BUN_END0+FIN_BUN_STEP
        sta fn_estep                 ; END0 holds until 1180, then +1 per step
        bra fin_endblit
?run    dec fn_estep
        bne ?out
        lda #FIN_BUN_STEP
        sta fn_estep
        lda fn_endst
        cmp #FIN_BUN_LAST
        bcs ?out                     ; END6 is the last one -- "THE END"
        inc fn_endst
        ldx #SFX_PISTOL
        jsr snd_play_t
        bra fin_endblit
?out    rts
.endp

;--------------------------------------------------------------
; fin_endblit -- V_DrawPatch(FIN_END_X, FIN_END_Y, ENDn) onto the bunny
;   surface, whose left half is the screen by now (scrolled = 0 from tic 870,
;   END0 is at 1130). END0: the whole box goes to its twin in the off-screen
;   right half first -- pristine PFUB2 for later. END n (pack_fin.py ships only
;   the rectangle where it differs from END n-1): that rectangle comes back
;   from the twin, then the crop is stencilled over it -- outside it the screen
;   already shows END n. Every blit steps the 640 surface, so the BCB's
;   DST_STEPY is 640 around them and back to SCREEN_WIDTH after (hud_blit).
;--------------------------------------------------------------
.proc fin_endblit
        lda #BLT_COPY
        sta fb_ctrl
        rep #$20
        .LONGA ON
        lda #FIN_BUN_W               ; the 640 surface both ways: the pitch every
        sta fb_dpitch                ;   blit from here on writes, and the box's
        sta fb_stride                ;   SRC_STEPY
        .LONGA OFF
        sep #$20
        lda fn_endst
        bne ?rest
        lda #FIN_END_RW-1            ; END0: the whole box -> its twin
        sta fb_w
        lda #FIN_END_RH-1
        sta fb_h
        lda #[FIN_ENDD>>16]
        sta fb_src+2
        lda #[FIN_ETWIN>>16]
        sta fb_dst+2
        rep #$20
        .LONGA ON
        lda #FIN_ENDD&$FFFF
        sta fb_src
        lda #FIN_ETWIN&$FFFF
        sta fb_dst
        .LONGA OFF
        sep #$20
        bra ?box
?rest   tax                          ; END n: its rectangle, twin -> screen
        jsr fin_erect                ;   (fb_dst, w/h, Y = n*2)
        rep #$21
        .LONGA ON
        lda fin_end_d,y
        adc #FIN_ETWIN&$FFFF
        sta fb_src
        .LONGA OFF
        sep #$20                     ; (C survives the sep)
        lda #[FIN_ETWIN>>16]
        adc #0
        sta fb_src+2
?box    jsr fin_blit
        ldx fn_endst                 ; the letter: END n's crop, stencilled
        jsr fin_erect
        stz fb_stride+1
        lda fin_end_w,x              ; its own width as the pitch
        sta fb_stride
        lda #BLT_BSTENCIL
        sta fb_ctrl
        rep #$21
        .LONGA ON
        lda fin_end_s,y
        adc #FIN_ENDA&$FFFF
        sta fb_src
        .LONGA OFF
        sep #$20
        lda #[FIN_ENDA>>16]
        adc #0
        sta fb_src+2
        jmp fin_blit
.endp

;--------------------------------------------------------------
; fin_erect -- X = END n: fb_w/fb_h = its rectangle, fb_dst = where it sits on
;   the surface (FIN_ENDD + d[n]), Y = n*2 for the word tables. Keeps X.
;--------------------------------------------------------------
.proc fin_erect
        lda fin_end_w,x
        dec @
        sta fb_w
        lda fin_end_h,x
        dec @
        sta fb_h
        txa
        asl
        tay
        rep #$21
        .LONGA ON
        lda fin_end_d,y
        adc #FIN_ENDD&$FFFF
        sta fb_dst
        .LONGA OFF
        sep #$20                     ; (C survives the sep)
        lda #[FIN_ENDD>>16]
        adc #0
        sta fb_dst+2
        rts
.endp


; fin_blit -- one rectangle: fb_src -> fb_dst, fb_w+1 bytes by fb_h+1 rows,
;   source pitch fb_stride, destination pitch fb_dpitch (both 16-bit: 320 for
;   the text surface, 640 for the bunny pair), mode fb_ctrl. The AND/XOR masks
;   and the zoom are the ones setup_bcbs left in the HUD control block
;   ($FF/$00/0); fin_tmpl puts the template's pitch back for the panel.
;--------------------------------------------------------------
.proc fin_blit
                                      ; 2026-09-23 (vbxe-blitter: fire early, wait late):
        jsr blitter_wait_t           ;   wait BEFORE the BCB (not latched), none after
                                      ; 2026-09-22 (rapidus-bus-timing): the BCB as bus
        lda fb_stride                ;   WORDS. B = [3] SRC_STEPY lo
        xba
        lda fb_src+2                 ; A = [2] SRC bank
        rep #$20
        .LONGA ON
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2    ; [2-3]
        lda fb_src
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR      ; [0-1]
        lda fb_stride+1                        ; [4] SRC_STEPY hi, [5] SRC_STEPX =
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ;   fb_sx (1): draw_weapon SCALES here
        lda fb_dst
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; [6-7]
        lda fb_dst+2                           ; [8] DST bank, [9] DST_STEPY lo:
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2    ;   fb_dpitch sits right behind
        lda fb_w                               ; [12-13] WIDTH, high byte 0 (the word
        and #$00FF                             ;   read drags fb_h in above it)
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        lda fb_dpitch+1                        ; [10] DST_STEPY hi
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        lda fb_h                               ; [14]
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        lda fb_ctrl                            ; [20]
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jmp hud_blit.hud_fire        ; no wait after (wait late)
.endp

;==============================================================
; The per-episode tables. Three entries each, indexed by MAP_HFINEP-1.
;==============================================================
;   finaletext, as a MEMAC window address + the bank byte it is in
                                      ; DRAC_PLAN 3b: 16 KB window
fin_txlo  dta <[MEMW16+[[[FIN_BANK+[FIN_TEXT1>>12]]&3]<<12]+[FIN_TEXT1&$FFF]], <[MEMW16+[[[FIN_BANK+[FIN_TEXT2>>12]]&3]<<12]+[FIN_TEXT2&$FFF]], <[MEMW16+[[[FIN_BANK+[FIN_TEXT3>>12]]&3]<<12]+[FIN_TEXT3&$FFF]]
                                      ; DRAC_PLAN 3b: 16 KB window
fin_txhi  dta >[MEMW16+[[[FIN_BANK+[FIN_TEXT1>>12]]&3]<<12]+[FIN_TEXT1&$FFF]], >[MEMW16+[[[FIN_BANK+[FIN_TEXT2>>12]]&3]<<12]+[FIN_TEXT2&$FFF]], >[MEMW16+[[[FIN_BANK+[FIN_TEXT3>>12]]&3]<<12]+[FIN_TEXT3&$FFF]]
fin_txbk  dta BANK_EN|[FIN_BANK+[FIN_TEXT1>>12]], BANK_EN|[FIN_BANK+[FIN_TEXT2>>12]], BANK_EN|[FIN_BANK+[FIN_TEXT3>>12]]
;   strlen(finaletext)*TEXTSPEED + TEXTWAIT + 1 -- F_Ticker's `>` made a `>=`
fin_wtlo  dta <[FIN_TLEN1*FIN_SPEED+FIN_WAIT+1], <[FIN_TLEN2*FIN_SPEED+FIN_WAIT+1], <[FIN_TLEN3*FIN_SPEED+FIN_WAIT+1]
fin_wthi  dta >[FIN_TLEN1*FIN_SPEED+FIN_WAIT+1], >[FIN_TLEN2*FIN_SPEED+FIN_WAIT+1], >[FIN_TLEN3*FIN_SPEED+FIN_WAIT+1]
;   finaleflat: FLOOR4_8 / SFLR6_1 / MFLR8_4, one 64x64 tile each, and the
;   font: where the episode's finpic.bin section puts them in the arena
fin_flo   dta <[FIN_ARENA+FIN_FLATA1], <[FIN_ARENA+FIN_FLATA2], <[FIN_ARENA+FIN_FLATA3]
fin_fmi   dta >[FIN_ARENA+FIN_FLATA1], >[FIN_ARENA+FIN_FLATA2], >[FIN_ARENA+FIN_FLATA3]
fin_fbk   dta [[FIN_ARENA+FIN_FLATA1]>>16], [[FIN_ARENA+FIN_FLATA2]>>16], [[FIN_ARENA+FIN_FLATA3]>>16]
fin_ftlo  dta <[FIN_ARENA+FIN_FONTA1], <[FIN_ARENA+FIN_FONTA2], <[FIN_ARENA+FIN_FONTA3]
fin_ftmi  dta >[FIN_ARENA+FIN_FONTA1], >[FIN_ARENA+FIN_FONTA2], >[FIN_ARENA+FIN_FONTA3]
fin_ftbk  dta [[FIN_ARENA+FIN_FONTA1]>>16], [[FIN_ARENA+FIN_FONTA2]>>16], [[FIN_ARENA+FIN_FONTA3]>>16]
;   the episode's finpic.bin section on the ATR: first sector and chunk count
fin_pklo dta <FIN_PAK1_SEC, <FIN_PAK2_SEC, <FIN_PAK3_SEC   ; the episodes'
fin_pkhi dta >FIN_PAK1_SEC, >FIN_PAK2_SEC, >FIN_PAK3_SEC   ;   DEFLATE streams
fin_nch   dta FIN_NCH1, FIN_NCH2, FIN_NCH3
                                     ; (fin_pak itself lives in diskio.asm:
                                     ;  this co-staged block is laid out to
                                     ;  the byte and takes DATA only)
;   the flat tiling grid: each tile row's offset on the surface (y*320), and
;   its height-1 -- the last one clipped, because 200 is not a multiple of 64
fin_tyo   dta a(0), a(FIN_TILE_H*FIN_SR_W), a(FIN_TILE_H*2*FIN_SR_W), a(FIN_TILE_H*3*FIN_SR_W)
fin_tht   dta FIN_TILE_H-1, FIN_TILE_H-1, FIN_TILE_H-1, [SCREEN_HEIGHT-FIN_TILE_H*3-1]

;==============================================================
; Stage 2's variables. Dead RAM the moment exit_level runs, so they live here
; rather than costing the engine a byte it does not have.
;==============================================================
fn_ep       dta 0                    ; gameepisode, 1-3 (MAP_HFINEP)
fn_stage    dta 0                    ; finalestage: 0 = text, 1 = the picture
fn_cnt      dta 0,0                  ; finalecount
fn_tacc     dta 0                    ; the 50 Hz -> 35 Hz Q8 accumulator
fn_wait     dta 0,0                  ; when stage 0 is over
fn_tsp      dta 0                    ; tics to the next character
fn_tdone    dta 0                    ; the text has stopped growing
fn_cx       dta a(0)                 ; cx, 0..320
fn_row      dta a(0)                 ; cy as its row's offset on the surface
fn_gw       dta a(0)                 ; this glyph's advance (high byte 0: a word)
fn_font     dta 0,0,0                ; the episode's font in the arena
fn_tbk      dta 0                    ; the text's VRAM bank byte
fn_karm     dta 0                    ; 0 = a key is down and must come up first
fn_scrv     dta a(0)                 ; `scrolled` as list R shows it (0..320)
fn_endst    dta 0                    ; the END letter now on screen, $FF = none
fn_estep    dta 0                    ; tics to the next one
fn_dlt      dta a(0)                 ; fin_pan's move, signed
fn_ti       dta 0                    ; fin_bg's tile row...
fn_tx       dta 0                    ; ...and column
fb_src      dta 0,0,0
fb_dst      dta 0,0,0
fb_dpitch   dta a(0)                 ; DST_STEPY -- right behind fb_dst+2: fin_blit
                                     ;   stores bank + pitch lo as ONE word
fb_stride   dta a(0)                 ; SRC_STEPY; the high byte is 0 but for
fb_sx       dta 1                    ;   the END box -- fin_blit reads it with
                                     ;   fb_sx (SRC_STEPX) as ONE word
fb_w        dta 0
fb_h        dta 0
fb_ctrl     dta 0

    .if * > FIN2_END+1
        ert 'f_finale.asm STAGE 2 outgrew the map slot (FIN2_RUN..FIN2_END)'
    .endif
    .if [* - FIN2_RUN] > FIN2_PAGES*256
        ert 'f_finale.asm STAGE 2 is more pages than fin_head copies (FIN2_PAGES)'
    .endif
