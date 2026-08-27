; f_finale.asm -- the END-OF-EPISODE FINALE (f_finale.c), episodes 1-3.
;   An ExM8 does NOT go to the intermission: g_game.c G_DoCompleted sees
;   `gamemap == 8` and hands straight to ga_victory / F_StartFinale, which types
;   the episode's story text over a tiled floor (stage 0) and then shows a
;   full-screen picture (stage 1) -- HELP2, VICTORY2, or the PFUB1 -> PFUB2
;   bunny scroll with END0..END6 spelling THE END. The engine has no episode
;   number at runtime, only a level index, so pack_map.py bakes the fact into
;   the level header: MAP_HFINEP, 0 = an ordinary exit, 1-3 = "this level ends
;   that episode".
;
;   THE THREE PARTS, laid out exactly like wi.asm:
;     fin_exit    the resident stubs -- main's EXIT_REQ tail, which picks the
;     fin_esc     finale over the intermission, and the ESC handler, which has
;                 to be resident because the menu behind it can load a level.
;                 The only bytes of this file that are in RAM all the time.
;     STAGE 1     at MENU_RUN, one 4 KB VRAM chunk (FINOVL_BANK). A bootstrap
;                 and nothing else: pull stage 2 into the map slot and jump.
;                 One page, because unlike wi.asm's stage 1 it needs no
;                 across-the-load driver -- see fin_head.
;     STAGE 2     at FIN2_RUN, in the map slot (FIN2_BANK). The whole finale.
;                 The slot is free for exactly as long as it is needed: the
;                 level is over, the header below $4100 is still readable (that
;                 is where MAP_HFINEP is), and nothing streams again until the
;                 player picks NEW GAME out of the control panel.
;
;   WHAT IS AND IS NOT MODELLED
;     * THE CAST CALL (finalestage 2) is DOOM II's -- `gamemode == commercial`,
;       gamemap 30. There is no commercial IWAD here, so F_StartCast /
;       F_CastTicker / F_CastDrawer are not ported at all.
;     * NO MUSIC. mus_victor and mus_bunny have nothing to play: MUS_CHUNKS is 0
;       in this build (tools/pack_musstream.py). The pistol shot behind every
;       END letter (f_finale.c:685) IS here -- that one is an SFX.
;     * F_TextWrite REDRAWS THE WHOLE PAGE every frame -- flat, then every
;       character typed so far. This draws only what is NEW since the last tic.
;       The background never changes and glyphs only ever add, so the picture is
;       identical to the byte and a tic costs ONE 4x8 blit instead of 160.
;     * F_BunnyScroll walks 320 columns through F_DrawPatchCol because a DOOM
;       patch is column-major. tools/pack_fin.py stores the pages ROW-major, so
;       the same composite is TWO blitter rectangles -- and it is only rebuilt
;       on the tics where `scrolled` actually moves, i.e. every fourth one.
;     * THE END. There is none, and that IS f_finale.c: F_Responder answers
;       false for both stages of a DOOM 1 finale (the skip is the
;       `gamemode == commercial` branch), F_Ticker sets no gameaction, and
;       episodes do not chain -- ga_victory is where the game stops. So the text
;       cannot be skipped, the picture stays up, and the only key that does
;       anything is ESC: the event falls through to M_Responder, i.e. the
;       control panel, and the player leaves through NEW GAME.

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
;   wi_exit is 12 bytes in a 12-byte hole and has nothing to spare, which is why
;   this is a block of its own (memory_map.inc FINEXIT_BASE).
;   TWO gates, and both are load-bearing:
;     EXIT_REQ-1 != 0   = EXIT_MELT, the melt AFTER the next level has loaded.
;                         That is the intermission overlay's job whatever level
;                         we came from -- and by then MAP_HFINEP is the NEW
;                         map's byte, so testing that alone would be wrong.
;     MAP_HFINEP == 0   = an ordinary exit switch.
;--------------------------------------------------------------
        org FINEXIT_BASE
.proc fin_exit
        ldx EXIT_REQ
        dex                          ; X = mn_open's entry index (WI_E_INTER)
        bne ?wi
        lda MAP_HFINEP               ; still readable: the map slot is untouched
        beq ?wi                      ;   until exit_level runs
        lda #BANK_EN | FINOVL_BANK
        jmp mn_open                  ; ...which lands in fin_head below
?wi     jmp wi_exit
.endp

;--------------------------------------------------------------
; fin_esc -- M_StartControlPanel from inside the finale, and the ONE part of
;   this that cannot live in the overlay: NEW GAME reloads a level, and a level
;   load streams a map straight over stage 2 in the slot. So the call has to be
;   made from resident RAM with nothing of the finale's left on the stack --
;   fin_main reaches this with a `jmp`, and the whole chain behind it
;   (main -> fin_exit -> mn_open -> fin_head -> fin_main) is jumps too, so the
;   only return address down there is main's own.
;   THE TWO WAYS OUT, told apart by one byte:
;     EXIT_REQ == 0  the menu started a game (NEW GAME's pl_restart, or a LOAD).
;                    init_level cleared it, the slot holds a MAP again and the
;                    finale no longer exists -- rts, and main draws the new level.
;     EXIT_REQ != 0  the menu was just closed. Nothing streamed, so stage 2 is
;                    still sitting in the slot: hand it back its own screen.
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
;   driver up at $1480 out of the SIO staging buffer's reach; DOOM 1's finale
;   ends nothing and starts nothing (f_finale.c: F_Ticker sets no gameaction for
;   a non-commercial episode), so there is nothing for one to do.
;--------------------------------------------------------------
.proc fin_head
        lda #BANK_EN | FIN2_BANK
        sta VBXE_BANK_SEL
        ldx #0
?s2     txa                          ; page X of the chunk -> page X of the slot
        clc
        adc #>MEMW
        sta ?src+2
        txa
        clc
        adc #>FIN2_RUN
        sta ?dst+2
        ldy #0
?src    lda MEMW,y
?dst    sta FIN2_RUN,y
        iny
        bne ?src
        inx
        cpx #FIN2_PAGES
        bne ?s2
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
; stream owns -- and the melt starts one byte later. Both ends are COMPUTED, and
; the 2026-08-18 growth of the run is exactly what walked over the old melt
; buffers, so say it here where the two numbers finally meet.
    .if [[FIN_BANK+FIN_CHUNKS]*4096] > WIPE_START
        ert 'the WI+FIN VRAM run has grown into WIPE_START (memory_map.inc)'
    .endif

; Where the streamed pages LAND. One arena base, three sections at fixed chunk
; distances inside it -- the same distances they have inside finpic.bin, because
; fin_load streams the whole run in one go (fin_syms.inc chunk indices).
FIN_PFUB1A  equ FIN_ARENA
FIN_PFUB2A  equ FIN_ARENA + [[FIN_PFUB2-FIN_PFUB1]*4096]
FIN_ENDA    equ FIN_ARENA + [[FIN_END_CH-FIN_PFUB1]*4096]

;--------------------------------------------------------------
; fin_main -- F_StartFinale, then F_Ticker/F_Drawer once per DOOM tic.
;--------------------------------------------------------------
.proc fin_main
        lda MAP_HFINEP               ; 1-3. The slot only holds a MAP below
        sta fn_ep                    ;   $4100, and this is at $401D
        jsr fin_setup
        jsr fin_bg                   ; the tiled floor FIRST and the buffer
        jsr fin_show                 ;   AFTER it: the other way round shows
                                     ;   whatever FRAME_A held two frames ago
                                     ;   until the flat covers it
        jsr fin_load                 ; this episode's stage-1 art -> the arena
fin_loop jsr fin_tic
        inc fn_cnt                   ; finalecount++
        bne ?nc
        inc fn_cnt+1
?nc     jsr fin_kbd                  ; C=1 = ESC, and it is the only key that
        bcc ?run                     ;   does anything at all here
        jsr fin_save                 ; the picture, so the panel can be closed
        jmp fin_esc                  ;   again -- and NO stack frame of ours
?run    lda fn_stage
        bne ?st1
        jsr fin_type                 ; F_TextWrite, one character at a time
        lda fn_cnt+1                 ; finalecount > strlen*TEXTSPEED + TEXTWAIT
        cmp fn_wait+1
        bcc fin_loop
        bne ?adv
        lda fn_cnt
        cmp fn_wait
        bcc fin_loop
?adv    jsr fin_stage1
        jmp fin_loop
?st1    lda fn_ep                    ; stage 1 just SITS there, exactly as DOOM
        cmp #3                       ;   does -- F_Ticker never leaves it and
        bne fin_loop                 ;   F_Responder eats nothing
        jsr fin_bunny                ; F_BunnyScroll, episode 3 only
        jmp fin_loop
.endp

;--------------------------------------------------------------
; fin_back -- FIN2_RESUME: the control panel was closed, so put the finale's own
;   screen back and carry on where the clock left off. Nothing streamed while
;   the menu was up (it runs at MENU_RUN and reads no sectors), so every byte of
;   stage 2 -- code, tables and the tic counter -- is exactly as it was.
;--------------------------------------------------------------
.proc fin_back
        lda #BANK_EN | BANK_OVERHEAD ; the menu left the window on ITS bank
        sta VBXE_BANK_SEL
        jsr fin_rest
        jsr fin_show
        jmp fin_main.fin_loop
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
        lda fin_wtlo,x
        sta fn_wait
        lda fin_wthi,x
        sta fn_wait+1
        lda #0
        sta fn_stage                 ; finalestage
        sta fn_cnt                   ; finalecount
        sta fn_cnt+1
        sta fn_tdone
        sta fn_tacc
        sta fn_karm                  ; the key that threw the EXIT switch is
                                     ;   still DOWN: it has to come up first
        lda #FIN_CX0
        sta fn_cx
        lda #FIN_CY0
        sta fn_cy
        lda #10+FIN_SPEED            ; count = (finalecount-10)/TEXTSPEED, so
        sta fn_tsp                   ;   the first glyph lands on tic 13
        lda #$FF
        sta fn_endst                 ; no END letter yet...
        sta fn_scrv                  ; ...and no scroll composite either, so the
        rts                          ;   first bunny tic always draws
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
; fin_show -- FRAME_A on screen, and nothing about to take it away again.
;   The same five stores as wi_show; the finale never flips, it paints in place.
;--------------------------------------------------------------
.proc fin_show
        lda #0
        sta zback_hi
        sta ZFRONT
        sta XDLA_PEND                ; $00 = rom_nmi's "nothing pending"
        lda #>VRAM_XDL_A
        sta VBXE_XDLA1
        rts
.endp

;--------------------------------------------------------------
; fin_kbd -- ESC, edge triggered: C=1 once per press. read_keys does not run
;   here (the frame loop is stopped for the whole finale), so this is mn_key's
;   test done by hand -- SKSTAT bit2 for "a key is down", KBCODE for which.
;   fn_karm starts at 0, so a key still held from the level exit has to come up
;   first, and a held ESC opens the panel once instead of every tic.
;   NO OTHER KEY DOES ANYTHING. f_finale.c's F_Responder answers false for both
;   stages of a DOOM 1 finale, so nothing skips the text and nothing dismisses
;   the picture -- the event falls through to M_Responder, i.e. to ESC.
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
        lda #0
        sta fn_karm
        sec
        rts
?up     lda #1
        sta fn_karm
?no     clc
        rts
.endp

;--------------------------------------------------------------
; fin_load -- this episode's stage-1 art into the sprite/texture arena. Legal
;   for the same reason mn_readthis' HELP pages are: the pool holds the level's
;   own graphics, and by the time a finale runs the level is over -- exit_level
;   streams the next one's over the top a minute later either way.
;   The whole SIO bracket is exit_level's, for exit_level's reasons: SIOV is in
;   the OS ROM, and it takes POKEY away from the DAC and hands it back detuned.
;--------------------------------------------------------------
.proc fin_load
        ldx fn_ep
        dex
        lda fin_seclo,x
        sta ll_sec
        lda fin_sechi,x
        sta ll_sec+1
        lda fin_nch,x
        sta ld_chunks
        lda #FIN_ARBANK
        sta ld_bank0
        jsr rom_in
        lda #$40
        sta NMIEN
        cli
        jsr snd_stop                 ; the DAC silent and Timer-1 disarmed
        lda #0                       ;   BEFORE SIO takes the chip, or the tone
        sta SOUNDR_R                 ;   it was mid-way through squeals for the
                                     ;   whole read (the 2026-08-04 bug)
        jsr load_vram
        sei
        jsr rom_out
        jmp snd_pokey                ; ...and POKEY back the way snd_init left it
.endp

;--------------------------------------------------------------
; fin_bg -- F_TextWrite's tiled background (f_finale.c:274). DOOM memcpy's the
;   flat row by row; the blitter tiles it as 5 x 4 rectangles out of ONE 32x64
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
        lda #FIN_TILE_W
        sta fb_stride
        lda #FIN_TILE_W-1
        sta fb_w
        lda #BLT_COPY
        sta fb_ctrl
        lda #0
        sta fn_ti
?row    ldx fn_ti
        lda fin_tht,x
        sta fb_h
        lda #0
        sta fn_tx
?col    ldx fn_ti
        ldy fin_tyt,x                ; the tile row's TOP screen row
        lda row_lo,y
        clc
        adc fn_tx
        sta fb_dst
        lda row_hi,y
        adc #0
        sta fb_dst+1
        lda #0
        sta fb_dst+2                 ; always FRAME_A: the finale owns bank 0,
        jsr fin_blit                 ;   status-bar rows and all
        lda fn_tx
        clc
        adc #FIN_TILE_W
        sta fn_tx
        cmp #SCREEN_WIDTH
        bcc ?col
        inc fn_ti
        lda fn_ti
        cmp #FIN_TROWS
        bcc ?row
        rts
.endp

;--------------------------------------------------------------
; fin_type -- F_TextWrite's inner loop (f_finale.c:290), one character per
;   TEXTSPEED tics instead of "all of them, every frame". cx/cy carry over from
;   tic to tic, which is what makes that equivalent.
;--------------------------------------------------------------
.proc fin_type
        lda fn_tdone                 ; the NUL, or a line that ran off the right
        bne ?out                     ;   edge -- DOOM breaks out of the loop
        dec fn_tsp
        bne ?out
        lda #FIN_SPEED
        sta fn_tsp
        jsr fin_getc
        bne ?ch
        sta fn_tdone                 ; A = 0 here...
        inc fn_tdone                 ;   ...so this is the cheapest "= 1"
?out    rts
?ch     cmp #$0A                     ; '\n': cx = 10, cy += 11
        bne ?g
        lda #FIN_CX0
        sta fn_cx
        lda fn_cy
        clc
        adc #FIN_LINEH
        sta fn_cy
        rts
?g      sec
        sbc #FIN_FIRST               ; c = toupper(c) - HU_FONTSTART. The texts
        bcc ?sp                      ;   are packed upper-cased already
        cmp #FIN_LAST-FIN_FIRST+1
        bcs ?sp
        tax
        lda fin_fw,x                 ; w = SHORT(hu_font[c]->width)
        sta fn_gw
        clc
        adc fn_cx
        cmp #SCREEN_WIDTH+1          ; if (cx+w > SCREENWIDTH) break
        bcs ?stop
        jsr fin_putc
        lda fn_cx
        clc
        adc fn_gw
        sta fn_cx
        rts
?sp     lda fn_cx                    ; not a glyph -- space and friends: cx += 4
        clc                          ;   (halved, like every x in this port)
        adc #FIN_SPACEW
        sta fn_cx
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
        txa                          ; index * FIN_GLYPH = index * 64, done as
        sta fb_src+1                 ;   (index << 8) >> 2
        lda #0
        sta fb_src
        lsr fb_src+1
        ror fb_src
        lsr fb_src+1
        ror fb_src
        lda fb_src
        clc
        adc #<[FIN_VRAM+FIN_FONT_OFF]
        sta fb_src
        lda fb_src+1
        adc #>[FIN_VRAM+FIN_FONT_OFF]
        sta fb_src+1
        lda #[[FIN_VRAM+FIN_FONT_OFF]>>16]
        adc #0
        sta fb_src+2
        lda #FIN_CELL
        sta fb_stride
        lda fn_gw
        sec
        sbc #1
        sta fb_w
        lda #FIN_FONT_H-1
        sta fb_h
        ldx fn_cy
        lda row_lo,x
        clc
        adc fn_cx
        sta fb_dst
        lda row_hi,x
        adc #0
        sta fb_dst+1
        lda #0
        sta fb_dst+2
        lda #BLT_BSTENCIL
        sta fb_ctrl
        jmp fin_blit
.endp

;--------------------------------------------------------------
; fin_getc -- the next character of finaletext. The texts stay in VRAM: 1.6 KB
;   of 6502 RAM is 1.6 KB this port does not have, and one byte a tic is the
;   whole cost. The read address is the instruction's own operand, so there is
;   no zero-page pointer either -- fin_setup seeds it and this walks it.
;--------------------------------------------------------------
.proc fin_getc
        lda fn_tbk
        sta VBXE_BANK_SEL
fin_rd  lda $FFFF                    ; patched by fin_setup
        pha
        inc fin_rd+1
        bne ?nc
        inc fin_rd+2
?nc     ldx #BANK_EN | BANK_OVERHEAD ; the BCBs, before anything blits again
        stx VBXE_BANK_SEL
        pla
        rts
.endp

;--------------------------------------------------------------
; fin_stage1 -- F_Ticker's stage change (f_finale.c:223): finalecount = 0,
;   finalestage = 1. Episodes 1 and 2 are ONE picture and it never changes, so
;   it goes up once here; episode 3 redraws itself every tic instead.
;   (DOOM forces a screen wipe here and starts mus_bunny. There is no music in
;    this build, and the melt lives in wi.asm's overlay -- which this one is
;    standing on top of. The page just appears.)
;--------------------------------------------------------------
.proc fin_stage1
        lda #1
        sta fn_stage
        lda #0
        sta fn_cnt
        sta fn_cnt+1
        lda fn_ep
        cmp #3
        beq ?bun
        lda #<FIN_ARENA
        sta fb_src
        lda #>FIN_ARENA
        sta fb_src+1
        lda #[FIN_ARENA>>16]
        sta fb_src+2
        jmp fin_full
?bun    rts
.endp

;--------------------------------------------------------------
; fin_full -- V_DrawPatch(0,0) of a whole 160x200 page from fb_src.
; fin_save / fin_rest -- and the same copy the other two ways, so ESC can put
;   the control panel over the finale and take it off again. WIPE_START is the
;   scratch: it is a full 200-row screen, and the melt -- its only other user --
;   cannot be running, because the finale never loads a level.
;--------------------------------------------------------------
.proc fin_save
        lda #0
        sta fb_src
        sta fb_src+1
        sta fb_src+2
        lda #<WIPE_START
        sta fb_dst
        lda #>WIPE_START
        sta fb_dst+1
        lda #[WIPE_START>>16]
        sta fb_dst+2
        jmp fin_page
.endp

.proc fin_rest
        lda #<WIPE_START
        sta fb_src
        lda #>WIPE_START
        sta fb_src+1
        lda #[WIPE_START>>16]
        sta fb_src+2
        ; fall through -- fin_full's destination IS the screen
.endp

.proc fin_full
        lda #0
        sta fb_dst
        sta fb_dst+1
        sta fb_dst+2
        ; fall through
.endp

.proc fin_page
        lda #SCREEN_WIDTH
        sta fb_stride
        lda #SCREEN_WIDTH-1
        sta fb_w
        lda #SCREEN_HEIGHT-1
        sta fb_h
        lda #BLT_COPY
        sta fb_ctrl
        jmp fin_blit
.endp

;--------------------------------------------------------------
; fin_bunny -- one tic of F_BunnyScroll (f_finale.c:644).
;--------------------------------------------------------------
.proc fin_bunny
        jsr fin_scroll
        jmp fin_ends
.endp

;--------------------------------------------------------------
; fin_scroll -- scrolled = 320 - (finalecount-230)/2, clamped 0..320, halved
;   into the port's 160. It moves one byte every FOUR tics, so three tics in
;   four have nothing to do at all.
;--------------------------------------------------------------
.proc fin_scroll
        sec
        lda fn_cnt
        sbc #<FIN_BUN_T0
        sta fn_d
        lda fn_cnt+1
        sbc #>FIN_BUN_T0
        sta fn_d+1
        bcc ?full                    ; finalecount < 230: nothing has moved yet
        lsr fn_d+1
        ror fn_d
        lsr fn_d+1
        ror fn_d                     ; (finalecount-230)/4 = the DOOM /2 halved
        lda fn_d+1
        bne ?zero                    ; >= 256, so long past the end
        lda fn_d
        cmp #SCREEN_WIDTH
        bcs ?zero
        sta fn_d
        lda #SCREEN_WIDTH
        sec
        sbc fn_d
        jmp ?have
?zero   lda #0
        beq ?have                    ; (always)
?full   lda #SCREEN_WIDTH
?have   cmp fn_scrv
        beq ?same                    ; the picture has not moved: nothing to do
        sta fn_scrv
        jmp fin_draws
?same   rts
.endp

;--------------------------------------------------------------
; fin_draws -- the composite for the scroll position in fn_scrv. Screen column
;   x shows column x+scrolled of the 320-wide [PFUB2 | PFUB1] pair, so it is two
;   sub-rectangles of two pages and not 160 column copies.
;--------------------------------------------------------------
.proc fin_draws
        lda #SCREEN_WIDTH
        sta fb_stride
        lda #SCREEN_HEIGHT-1
        sta fb_h
        lda #BLT_COPY
        sta fb_ctrl
        lda fn_scrv                  ; PFUB2 columns [s..159] -> screen [0..]
        cmp #SCREEN_WIDTH
        beq ?partb                   ; s = 160: none of PFUB2 is on screen
        clc
        adc #<FIN_PFUB2A
        sta fb_src
        lda #>FIN_PFUB2A
        adc #0
        sta fb_src+1
        lda #[FIN_PFUB2A>>16]
        adc #0
        sta fb_src+2
        lda #0
        sta fb_dst
        sta fb_dst+1
        sta fb_dst+2
        sec
        lda #SCREEN_WIDTH-1
        sbc fn_scrv
        sta fb_w
        jsr fin_blit
?partb  lda fn_scrv                  ; PFUB1 columns [0..s-1] -> the right edge
        beq ?out                     ; s = 0: PFUB1 has scrolled off
        lda #<FIN_PFUB1A
        sta fb_src
        lda #>FIN_PFUB1A
        sta fb_src+1
        lda #[FIN_PFUB1A>>16]
        sta fb_src+2
        sec
        lda #SCREEN_WIDTH
        sbc fn_scrv
        sta fb_dst
        lda #0
        sta fb_dst+1
        sta fb_dst+2
        lda fn_scrv
        sec
        sbc #1
        sta fb_w
        jmp fin_blit
?out    rts
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
        lda fn_cnt+1                 ; nothing at all before 1130
        cmp #>FIN_BUN_END0
        bcc ?out
        bne ?go
        lda fn_cnt
        cmp #<FIN_BUN_END0
        bcc ?out
?go     lda #0
        sta fn_endst
        lda #FIN_BUN_ST0-FIN_BUN_END0+FIN_BUN_STEP
        sta fn_estep                 ; END0 holds until 1180, then +1 per step
        jmp fin_endblit
?run    dec fn_estep
        bne ?out
        lda #FIN_BUN_STEP
        sta fn_estep
        lda fn_endst
        cmp #FIN_BUN_LAST
        bcs ?out                     ; END6 is the last one -- "THE END"
        inc fn_endst
        ldx #SFX_PISTOL
        jsr snd_play
        jmp fin_endblit
?out    rts
.endp

;--------------------------------------------------------------
; fin_endblit -- V_DrawPatch(FIN_END_X, FIN_END_Y, ENDn). The composite goes
;   back down underneath it first: the letters are drawn with a stencil, END5
;   and END6 are two rows taller than the rest, and without this the previous
;   letter would show through wherever the new one has a hole.
;--------------------------------------------------------------
.proc fin_endblit
        jsr fin_draws
        ldx fn_endst
        lda fin_end_lo,x
        clc
        adc #<FIN_ENDA
        sta fb_src
        lda fin_end_hi,x
        adc #>FIN_ENDA
        sta fb_src+1
        lda #[FIN_ENDA>>16]
        adc #0
        sta fb_src+2
        lda fin_end_w,x
        sta fb_stride
        sec
        sbc #1
        sta fb_w
        lda fin_end_h,x
        sec
        sbc #1
        sta fb_h
        ldx #FIN_END_Y
        lda row_lo,x
        clc
        adc #FIN_END_X
        sta fb_dst
        lda row_hi,x
        adc #0
        sta fb_dst+1
        lda #0
        sta fb_dst+2
        lda #BLT_BSTENCIL
        sta fb_ctrl
        jmp fin_blit
.endp

;--------------------------------------------------------------
; fin_blit -- one rectangle: fb_src -> fb_dst, fb_w+1 bytes by fb_h+1 rows,
;   source pitch fb_stride, mode fb_ctrl. wi_rect with the pitch unwelded from
;   SCREEN_WIDTH, which the font cell and the END patches both need.
;   The destination pitch, the AND/XOR masks and the zoom are the ones
;   setup_bcbs left in the HUD control block; nothing else in the port writes
;   them, so they stay 160/$FF/$00/0.
;--------------------------------------------------------------
.proc fin_blit
        ldx #2
?a      lda fb_src,x
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR,x
        lda fb_dst,x
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR,x
        dex
        bpl ?a
        lda fb_stride
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        lda #1                       ; draw_weapon SCALES with this pair; every
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX   ;   blit here is 1:1
        lda fb_w
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda fb_h
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        lda fb_ctrl
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr hud_blit.hud_fire
        jmp blitter_wait
.endp

;==============================================================
; The per-episode tables. Three entries each, indexed by MAP_HFINEP-1.
;==============================================================
;   finaletext, as a MEMAC window address + the bank byte it is in
fin_txlo  dta <[MEMW+[FIN_TEXT1&$FFF]], <[MEMW+[FIN_TEXT2&$FFF]], <[MEMW+[FIN_TEXT3&$FFF]]
fin_txhi  dta >[MEMW+[FIN_TEXT1&$FFF]], >[MEMW+[FIN_TEXT2&$FFF]], >[MEMW+[FIN_TEXT3&$FFF]]
fin_txbk  dta BANK_EN|[FIN_BANK+[FIN_TEXT1>>12]], BANK_EN|[FIN_BANK+[FIN_TEXT2>>12]], BANK_EN|[FIN_BANK+[FIN_TEXT3>>12]]
;   strlen(finaletext)*TEXTSPEED + TEXTWAIT + 1 -- F_Ticker's `>` made a `>=`
fin_wtlo  dta <[FIN_TLEN1*FIN_SPEED+FIN_WAIT+1], <[FIN_TLEN2*FIN_SPEED+FIN_WAIT+1], <[FIN_TLEN3*FIN_SPEED+FIN_WAIT+1]
fin_wthi  dta >[FIN_TLEN1*FIN_SPEED+FIN_WAIT+1], >[FIN_TLEN2*FIN_SPEED+FIN_WAIT+1], >[FIN_TLEN3*FIN_SPEED+FIN_WAIT+1]
;   finaleflat: FLOOR4_8 / SFLR6_1 / MFLR8_4, one 32x64 tile each in VRAM
fin_flo   dta <[FIN_VRAM+FIN_FLAT1], <[FIN_VRAM+FIN_FLAT2], <[FIN_VRAM+FIN_FLAT3]
fin_fmi   dta >[FIN_VRAM+FIN_FLAT1], >[FIN_VRAM+FIN_FLAT2], >[FIN_VRAM+FIN_FLAT3]
fin_fbk   dta [[FIN_VRAM+FIN_FLAT1]>>16], [[FIN_VRAM+FIN_FLAT2]>>16], [[FIN_VRAM+FIN_FLAT3]>>16]
;   the stage-1 art on the ATR: first sector and chunk count. Episode 3 takes
;   PFUB1, PFUB2 and the END letters in one run -- they are consecutive.
fin_seclo dta <[FIN_SEC1+FIN_HELP2*32], <[FIN_SEC1+FIN_VICTORY2*32], <[FIN_SEC1+FIN_PFUB1*32]
fin_sechi dta >[FIN_SEC1+FIN_HELP2*32], >[FIN_SEC1+FIN_VICTORY2*32], >[FIN_SEC1+FIN_PFUB1*32]
fin_nch   dta FIN_PAGE_CH, FIN_PAGE_CH, [FIN_PICCHUNKS-FIN_PFUB1]
;   the flat tiling grid: each row's top screen row, and its height-1 -- the
;   last one clipped, because 200 is not a multiple of 64
fin_tyt   dta 0, FIN_TILE_H, [FIN_TILE_H*2], [FIN_TILE_H*3]
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
fn_cx       dta 0
fn_cy       dta 0
fn_gw       dta 0                    ; this glyph's advance
fn_tbk      dta 0                    ; the text's VRAM bank byte
fn_karm     dta 0                    ; 0 = a key is down and must come up first
fn_scrv     dta 0                    ; the scroll position now on screen
fn_endst    dta 0                    ; the END letter now on screen, $FF = none
fn_estep    dta 0                    ; tics to the next one
fn_d        dta 0,0                  ; fin_scroll's 16-bit scratch
fn_ti       dta 0                    ; fin_bg's tile row...
fn_tx       dta 0                    ; ...and column
fb_src      dta 0,0,0
fb_dst      dta 0,0,0
fb_stride   dta 0
fb_w        dta 0
fb_h        dta 0
fb_ctrl     dta 0

    .if * > FIN2_END+1
        ert 'f_finale.asm STAGE 2 outgrew the map slot (FIN2_RUN..FIN2_END)'
    .endif
    .if [* - FIN2_RUN] > FIN2_PAGES*256
        ert 'f_finale.asm STAGE 2 is more pages than fin_head copies (FIN2_PAGES)'
    .endif
