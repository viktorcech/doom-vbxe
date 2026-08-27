; m_episode.asm -- WHICH EPISODE? (m_menu.c EpiDef / M_Episode).
;   NEW GAME does not start a game in DOOM: `M_NewGame` runs
;   `M_SetupNextMenu(&EpiDef)` for every non-commercial gamemode, and the
;   episode the player picks becomes `G_DeferedInitNew(skill, epi+1, 1)` -- map
;   1 of that episode. This IWAD is `registered`, so `M_Init` drops the fourth
;   entry (`EpiDef.numitems--`) and there are three.
;
;   WHY IT IS AN OVERLAY OF ITS OWN, and not a third mode of mn_run: the menu
;   overlay is 1272 bytes of a 1280-byte window. Everything the picker would
;   want to borrow -- mn_draw, mn_box, mn_press, and menu.tab itself -- lives
;   INSIDE that window and is gone the moment another overlay is copied down.
;   So this is a second, smaller copy of the same four helpers plus its own
;   6-row table (tools/pack_menu.py writes epi.tab: M_EPISOD, M_EPI1..3, and
;   the two skull frames, whose rows point back into the patch stream).
;
;   WHERE THE PIXELS ARE: the top 12 KB of the sprite arena (memory_map.inc
;   ARENA_SPR_TOP). That arena is a bump cache with a flush-when-full, so it is
;   the ONE region in the VRAM map that can give space up for a few more
;   flushes instead of breaking something. The three chunks sit directly in
;   front of the HU strips so the two share one mn_ld_tab row -- menu.asm's
;   table is three bytes from full and had no room for a row of its own.
;
;   THE SKILL MENU IS NOT HERE. DOOM goes EpiDef -> NewDef -> M_ChooseSkill;
;   this port ships one skill (tools/pack_things.py SKILL), so there is nothing
;   to choose and the pick starts the game, exactly as NEW GAME did before the
;   episode screen existed.

        org MENU_RUN, EPIOVL_STAGE

;--------------------------------------------------------------
; ep_head -- mn_open's `jmp MENU_RUN` lands here with the window still on
;   EPIOVL_BANK, and page 0 already copied down. The rest of the picker follows
;   it out of the same bank.
;--------------------------------------------------------------
.proc ep_head
        ldx #1
?pg     txa                          ; page X of the chunk -> page X of the run
        clc
        adc #>MEMW
        sta ?src+2
        txa
        clc
        adc #>MENU_RUN
        sta ?dst+2
        ldy #0
?src    lda MEMW,y
?dst    sta MENU_RUN,y
        iny
        bne ?src
        inx
        cpx #EP_PAGES
        bne ?pg
        lda #BANK_EN | BANK_OVERHEAD ; the BCBs live there, and every blit from
        sta VBXE_BANK_SEL            ;   here on writes one
        ; fall through
.endp

;--------------------------------------------------------------
; ep_main -- M_SetupNextMenu(&EpiDef) and the picker loop. The cursor starts on
;   ep1 (EpiDef.lastOn), which unlike MainDef's is NOT remembered across opens:
;   DOOM's EpiDef.lastOn is a fixed initialiser and M_SetupNextMenu copies it in.
;--------------------------------------------------------------
.proc ep_main
        lda #0
        sta ep_sel
        sta ep_sk
        jsr ep_paint
        lda #MENU_SKTICS
        sta ep_tic
        lda #0
        sta ep_arm                   ; the key that picked NEW GAME is still
                                     ;   down: it must come up before this menu
                                     ;   takes a press of its own
?loop   jsr ep_vsync
        dec ep_tic                   ; skullAnimCounter (m_menu.c:1836-1839)
        bne ?nb
        lda #MENU_SKTICS
        sta ep_tic
        jsr ep_erase                 ; the two frames differ, so the box goes
        lda ep_sk                    ;   back to the background between them
        eor #1
        sta ep_sk
        jsr ep_skull
?nb     jsr ep_press
        bcs ?act
        lda #1
        sta ep_arm                   ; everything released -> arm the next press
        bne ?loop                    ; (always)
?act    lda ep_arm
        beq ?loop                    ; still held: one press = one action
        lda #0
        sta ep_arm
        lda TRIG0
        lsr
        bcc ?sel                     ; fire = select
        lda STICK0
        lsr
        bcc ?up                      ; bit0 = UP
        lsr
        bcc ?down                    ; bit1 = DOWN
        lda KBCODE
        and #$3F
        cmp #KEY_ESC
        beq ?back                    ; ESC -> the previous menu (EpiDef.prevMenu
        cmp #KEY_RET                 ;   is &MainDef)
        beq ?sel
        cmp #KEY_MINUS               ; the Atari's up arrow
        beq ?up
        cmp #KEY_EQUALS              ; ... and its down arrow
        bne ?loop
?down   lda ep_sel
        clc
        adc #1
        cmp #EPI_N
        bcc ?mv
        lda #0
        beq ?mv                      ; (always) -- m_menu.c wraps both ways
?up     lda ep_sel
        bne ?dec
        lda #EPI_N
?dec    sec
        sbc #1
?mv     sta ep_move                  ; the cursor moved: erase, then redraw it
        jsr ep_erase                 ;   where it now is
        lda ep_move
        sta ep_sel
        ldx #SFX_PSTOP               ; m_menu.c:1651 -- the cursor's own sound
        jsr snd_play
        jsr ep_skull
        jmp ?loop
?back   ldx #SFX_SWTCHX              ; M_ClearMenu, and the panel closing is the
        jsr snd_play                 ;   switch coming back (m_menu.c:1681) --
                                     ;   the same sound and the same "pop ONE
                                     ;   menu" mn_run gives the save/load picker
        jsr ep_wipe                  ; EpiDef.prevMenu is &MainDef: take the
        lda #BANK_EN | MENU_OBANK    ;   episode screen off the background FIRST
        ldx mn_ing                   ;   -- mn_ingame freezes what is on screen
        beq ?bboot                   ;   as its own backdrop, and mn_boot draws
        ldx #MN_E_INGAME             ;   the menu over it
        bne ?bopen                   ; (always)
?bboot  ldx #MN_E_BOOT               ; (the title's "press a key" comes round
?bopen  jmp mn_open                  ;  once more on the way back at boot)
?sel    ldx #SFX_PISTOL              ; KEY_ENTER on an item (m_menu.c:1675)
        jsr snd_play
        jsr ep_quiet                 ; ...and the mixer EMPTY before either tail
        ldx ep_sel                   ;   hands POKEY to SIO -- the same rule the
        lda ep_lvl,x                 ;   old NEW GAME had (menu.asm ?ng)
        sta current_level
        lda mn_ing
        beq ?boot
        jmp pl_restart               ; G_InitNew in game. A TAIL jump: pl_restart
                                     ;   reloads the level THROUGH TEX_STAGE,
                                     ;   i.e. over this very code
?boot   lda #0                       ; ...and at BOOT the loading is menu_boot's,
        rts                          ;   whose `jsr mn_open` frame is what this
.endp                                ;   returns to (menu.asm ?ng drops mn_run's)

;--------------------------------------------------------------
; ep_paint -- M_DrawEpisode: the M_EPISOD banner and the three names, then the
;   cursor. Once per open; after that only the skull's box changes.
;   THE BACKGROUND GOES DOWN FIRST. DOOM redraws the whole screen every frame,
;   so M_SetupNextMenu(&EpiDef) wipes MainMenu[] by simply not drawing it again;
;   this port paints a menu ONCE over the background and leaves it there, so
;   without this the six main-menu lines stay on screen underneath the episode
;   names (menu.png, 2026-08-18).
;--------------------------------------------------------------
.proc ep_paint
        jsr ep_wipe
        lda #BLT_BSTENCIL            ; V_DrawPatch: the patches are transparent
        sta hb_ctrl
        lda #EPI_I_TITLE
        ldx #EPI_TITLEX
        ldy #EPI_TITLEY
        jsr ep_draw
        lda #0
        sta ep_it
?it     lda ep_it
        asl
        asl
        asl
        asl                          ; i * LINEHEIGHT (16)
        clc
        adc #EPI_Y
        tay
        lda ep_it
        clc
        adc #EPI_I_ITEM0
        ldx #EPI_X
        jsr ep_draw
        inc ep_it
        lda ep_it
        cmp #EPI_N
        bcc ?it
        ; fall through -- the cursor goes on last
.endp

;--------------------------------------------------------------
; ep_skull -- the blinking cursor at (EPI_SKULLX, EPI_SKULLY + sel*16).
;--------------------------------------------------------------
.proc ep_skull
        jsr ep_srow
        tay
        lda ep_sk
        clc
        adc #EPI_I_SKULL
        ldx #EPI_SKULLX
        ; fall through
.endp

;--------------------------------------------------------------
; ep_draw -- A = epi.tab row, X = column, Y = row. The 7-byte row IS hud.tab's
;   layout, so the resident hud_blit does all of it.
;--------------------------------------------------------------
.proc ep_draw
        stx ep_x
        sty ep_y
        sta ep_i                     ; row * 7
        asl
        asl
        asl                          ; *8
        sec
        sbc ep_i                     ; ...-1 = *7
        clc
        adc #<epi_tab
        sta zp_ptr
        lda #>epi_tab
        adc #0
        sta zp_ptr+1
        ldx ep_x
        ldy ep_y
        jmp hud_blit
.endp

;--------------------------------------------------------------
; ep_srow -- A = the cursor's screen row for the current selection.
;--------------------------------------------------------------
.proc ep_srow
        lda ep_sel
        asl
        asl
        asl
        asl
        clc
        adc #EPI_SKULLY
        rts
.endp

;--------------------------------------------------------------
; ep_erase -- put the skull's 10x19 box back to what the BACKGROUND has there,
;   so the cursor can blink and move without repainting the screen. Same
;   arithmetic as menu.asm's mn_box, and the same mn_bgh: $80 sources it out of
;   TITLEPIC at boot, 0 out of FRAME_B in game, and both are VRAM bank $01.
;   The row is +1 because M_SKULL1/2 carry topoffset -1 and hud_blit applies it
;   to the DRAW, so the erase has to apply it too.
;--------------------------------------------------------------
.proc ep_erase
        jsr ep_srow
        tax
        inx
        lda row_lo,x
        clc
        adc #EPI_SKULLX
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda row_hi,x
        adc #0                       ; row*160+x <= $7CA0, so this never carries
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        adc mn_bgh                   ; ... and neither does + $8000
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        lda #BLT_COPY                ; = 0, and so are the other two: opaque, the
        sta MEMW+MEMW_HD_OFF+BCB_CTRL          ; destination is bank 0 and the
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2    ; source pitch fits in one byte
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #[MENU_VRAM>>16]         ; = FRAME_B>>16: bank $01 either way
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #SCREEN_WIDTH            ; the source is a screen-wide picture, so a
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY     ; sub-rectangle of it steps by
        lda #1                                 ; 160, not by its own width
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #9                       ; 10 bytes wide - 1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #18                      ; 19 rows - 1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jmp hud_blit.hud_fire        ; hud_blit's own "wait, then start" tail
.endp

;--------------------------------------------------------------
; ep_wipe -- the whole background back onto the screen, so the episode screen
;   leaves nothing behind. menu.asm's mn_wipe with the box fixed at 160x200;
;   the source is mn_bgh's picture at the same coordinates, exactly as ep_erase.
;--------------------------------------------------------------
.proc ep_wipe
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        sta MEMW+MEMW_HD_OFF+BCB_CTRL          ; BLT_COPY
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda mn_bgh
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        lda #[MENU_VRAM>>16]
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #SCREEN_WIDTH-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #SCREEN_HEIGHT-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jmp hud_blit.hud_fire
.endp

;--------------------------------------------------------------
; ep_press / ep_vsync / ep_quiet -- menu.asm's mn_press, mn_vsync and mn_quiet,
;   one copy each. They are eight, four and three instructions; reaching the
;   originals would mean keeping the menu overlay resident, which the window
;   cannot do.
;--------------------------------------------------------------
.proc ep_press
        lda STICK0
        ora #$F0                     ; stick 1 is not ours
        cmp #$FF                     ; $FF = centred
        bne ?yes
        lda TRIG0
        lsr                          ; bit0 = 0 while fire is held
        bcc ?yes
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        beq ?yes
        clc
        rts
?yes    sec
        rts
.endp

.proc ep_vsync
        lda RTCLOK3
?w      cmp RTCLOK3
        beq ?w
        rts
.endp

.proc ep_quiet
        lda #$FF                     ; the select SFX must be OFF the mixer
        sta snd_pending              ;   before SIO takes POKEY, or the tone it
        jmp snd_stop                 ;   was mid-way through squeals for the
.endp                                ;   whole read

;--------------------------------------------------------------
; The tables. epi_tab is generated (tools/pack_menu.py) and is six 7-byte rows
; in hud.tab's layout; ep_lvl is the level index each episode starts on, which
; is the build's own disk order and not 9*n -- a subset build renumbers.
;--------------------------------------------------------------
epi_tab
        ins 'build/assets/menu/epi.tab'
ep_lvl  dta EPI_FIRST1, EPI_FIRST2, EPI_FIRST3
    .if EPI_N != 3
        ert 'ep_lvl has three entries -- EPI_N (pack_menu.py) says otherwise'
    .endif

ep_sel  dta 0                        ; itemOn
ep_sk   dta 0                        ; which skull frame
ep_tic  dta 0                        ; skullAnimCounter
ep_arm  dta 0                        ; 0 = a key is down and must come up first
ep_move dta 0
ep_it   dta 0
ep_i    dta 0
ep_x    dta 0
ep_y    dta 0

EP_PAGES equ [* - MENU_RUN + 255] / 256
    .if * > MENU_RUN + EPIOVL_MAX
        ert 'm_episode.asm outgrew EPIOVL_MAX (memory_map.inc)'
    .endif
    .if * > MENU_RUN_END+1
        ert 'm_episode.asm outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
