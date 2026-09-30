;--------------------------------------------------------------
; m_episode.asm -- the episode picker (m_menu.c EpiDef / M_Episode): an overlay of
;   its own, the menu overlay's window is full.
;--------------------------------------------------------------
        org MENU_RUN, EPIOVL_STAGE

;--------------------------------------------------------------
; ep_head -- mn_open's `jmp MENU_RUN` lands here with the window still on
;   EPIOVL_BANK, and page 0 already copied down. The rest of the picker follows
;   it out of the same bank.
;--------------------------------------------------------------
EPOVL_WIN       equ MEMW16+[[EPIOVL_BANK&3]<<12]   ; DRAC_PLAN 3b: 16 KB window: the picker's chunk
.proc ep_head
                                      ; 2026-09-23: pages EP_PAGES-1..1 downwards (no
        ldx #EP_PAGES-1              ;   overlap between the window and MENU_RUN):
?pg     txa                          ; page X of the chunk -> page X of the run
        clc
        adc #>EPOVL_WIN
        sta ?src+2                   ; $90+X cannot carry (X < 4: ert below), so
        adc #<[[>MENU_RUN]-[>EPOVL_WIN]]  ;   the second add rides on C=0 and A
        sta ?dst+2                   ;   instead of a fresh txa/clc
    .if [>EPOVL_WIN] + [EPIOVL_MAX/256] > 255
        ert 'ep_head: >EPOVL_WIN + page carries -- put the txa/clc back'
    .endif
        ldy #0
?src    lda EPOVL_WIN,y
?dst    sta MENU_RUN,y
        iny
        bne ?src
        dex
        bne ?pg
        lda #BANK_EN | BANK_OVERHEAD ; the BCBs live there, and every blit from
        sta VBXE_BANK_SEL            ;   here on writes one
        ert *<>ep_main               ; fall through
.endp

;--------------------------------------------------------------
; ep_main -- M_SetupNextMenu(&EpiDef) and the picker loop. The cursor starts on
;   ep1 (EpiDef.lastOn), which unlike MainDef's is NOT remembered across opens:
;   DOOM's EpiDef.lastOn is a fixed initialiser and M_SetupNextMenu copies it in.
;--------------------------------------------------------------
.proc ep_main
        stz ep_sel
        stz ep_sk
        jsr ep_paint
        lda #MENU_SKTICS
        sta ep_tic
        lda #MN_REST                 ; the key that picked NEW GAME is down: the
        sta ep_arm                   ;   controls rest before this menu takes a
                                     ;   press of its own
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
        lda ep_arm                   ; at rest: a frame less to wait
        beq ?loop
        dec @
        sta ep_arm
        bra ?loop
?act    ldx #MN_REST                 ; a press counts when the controls had
        lda ep_arm                   ;   rested: not while held, not in the
        stx ep_arm                   ;   bounce of a contact
        bne ?loop
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
        inc @                        ; (C dies at ?mv's sta: inc, not clc/adc #1)
        cmp #EPI_N
        bcc ?mv
        lda #0
        beq ?mv                      ; (always) -- m_menu.c wraps both ways
?up     lda ep_sel
        bne ?dec
        lda #EPI_N
?dec    dec @
?mv     pha                          ; the cursor moved: erase, then redraw it
        jsr ep_erase                 ;   where it now is -- the new row waits on
        pla                          ;   the stack, not in a RAM cell
        sta ep_sel
        ldx #SFX_PSTOP               ; m_menu.c:1651 -- the cursor's own sound
        jsr snd_play_t
        jsr ep_skull
        bra ?loop
?back   ldx #SFX_SWTCHX              ; M_ClearMenu, and the panel closing is the
        jsr snd_play_t ;   switch coming back (m_menu.c:1681) --
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
        jsr snd_play_t
        jsr ep_quiet                 ; ...and the mixer EMPTY before either tail
        ldx ep_sel                   ;   hands POKEY to SIO -- the same rule the
        lda ep_lvl,x                 ;   old NEW GAME had (menu.asm ?ng)
        sta current_level
        lda mn_ing
        beq ?boot
        jsl B1CODE_BASE+mn_tmpl_w1   ; the BCB template back to the game's
        jmp pl_restart_t ; G_InitNew in game. A TAIL jump: pl_restart
                                     ;   reloads the level THROUGH TEX_STAGE,
                                     ;   i.e. over this very code
?boot   rts                          ; ...and at BOOT the loading is menu_boot's,
                                     ;   whose `jsr mn_open` frame is what this
                                     ;   returns to (menu.asm ?ng drops mn_run's).
.endp                                ;   returns to (menu.asm ?ng drops mn_run's)

;--------------------------------------------------------------
; ep_paint -- M_DrawEpisode: the M_EPISOD banner and the three names, then the
;   cursor. Once per open; after that only the skull's box changes.
;--------------------------------------------------------------
.proc ep_paint
        jsr ep_wipe
        lda #BLT_BSTENCIL            ; V_DrawPatch: the patches are transparent
        sta hb_ctrl
        lda #EPI_I_TITLE
        ldx #EPI_TITLEX
        ldy #EPI_TITLEY
        jsr ep_draw
        stz ep_it
?it     lda ep_it
        asl
        asl
        asl
        asl                          ; i * LINEHEIGHT (16): i <= 2, so the asl's
        adc #EPI_Y                   ;   shift out 0s (C=0, no clc) and the sum
        tay                          ;   stays < 256 (ert below): C=0 again
        lda ep_it
        adc #EPI_I_ITEM0             ;   ... so this adc needs no clc either
        ldx #EPI_X
        jsr ep_draw
        inc ep_it
        lda ep_it
        cmp #EPI_N
        bcc ?it
    .if [EPI_N-1]*16 + EPI_Y > 255
        ert 'ep_paint: i*16 + EPI_Y carries -- put the clc back'
    .endif
        ert *<>ep_skull              ; fall through -- the cursor goes on last
.endp

;--------------------------------------------------------------
; ep_skull -- the blinking cursor at (EPI_SKULLX, EPI_SKULLY + sel*16).
;--------------------------------------------------------------
.proc ep_skull
        jsr ep_srow                  ; (C=0 on return: ert in ep_srow)
        tay
        lda ep_sk
        adc #EPI_I_SKULL
        ldx #EPI_SKULLX
        ert *<>ep_draw               ; fall through
.endp

;--------------------------------------------------------------
; ep_draw -- A = epi.tab row, X = column, Y = row. The 7-byte row IS hud.tab's
;   layout, so menu.asm's mn_sdraw does all of it: 1:1 onto the menu's SR
;   screen, at boot and in game alike.
;--------------------------------------------------------------
.proc ep_draw
        sta ep_i                     ; row * 7
        asl
        asl
        asl                          ; *8
        sec
        sbc ep_i                     ; ...-1 = *7, and 8i >= i leaves C=1: that
        adc #<[epi_tab-1]            ;   is the +1 of a 16-bit add of epi_tab-1
        sta zp_ptr                   ;   (menu.asm mn_tabptr does the same)
        lda #>[epi_tab-1]
        adc #0
        sta zp_ptr+1
        jmp mn_sdraw_t               ; X and Y still hold the column and row
.endp

;--------------------------------------------------------------
; ep_srow -- A = the cursor's screen row for the current selection.
;--------------------------------------------------------------
.proc ep_srow
        lda ep_sel
        asl
        asl
        asl
        asl                          ; sel*16: sel <= 2 -> the asl's shift out 0s,
        adc #EPI_SKULLY              ;   C=0 without a clc; and the sum stays < 256
                                     ;   (ert below), so C=0 on return as well --
                                     ;   ep_skull and ep_erase both lean on that
    .if [EPI_N-1]*16 + EPI_SKULLY > 255
        ert 'ep_srow: sel*16 + EPI_SKULLY carries -- put the clc back in ep_skull/ep_erase'
    .endif
        rts
.endp

;--------------------------------------------------------------
; ep_erase -- put the skull's box back to what the BACKGROUND has there, so
;   the cursor can blink and move without repainting the screen: menu.asm's
;   mn_sbox, 160 units across (the skull's 20 px are 11 of them at most).
;--------------------------------------------------------------
.proc ep_erase
        jsr ep_srow
        tax
        inx
        stx mb_y
        lda #EPI_SKULLX/2
        sta mb_x
        lda #10
        sta mb_w
        lda #18                      ; 19 rows - 1
        sta mb_h
        jmp mn_sbox_t
.endp

;--------------------------------------------------------------
; ep_wipe -- the whole background back onto the screen, so the episode screen
;   leaves nothing behind: MENU_SRBGH rows, all the picker ever draws on
;   (pack_menu.py _sr_bg_rows checks that) and above the status bar in game.
;--------------------------------------------------------------
.proc ep_wipe
        stz mb_x
        stz mb_y
        lda #SCREEN_WIDTH-1
        sta mb_w
        lda #MENU_SRBGH-1
        sta mb_h
        jmp mn_sbox_t
.endp
    .if MENU_SRBGH > VIEW_HEIGHT
        ert 'ep_wipe: in game the background above VIEW_HEIGHT is the frozen view'
    .endif

;--------------------------------------------------------------
; ep_press / ep_vsync / ep_quiet -- menu.asm's mn_press, mn_vsync and mn_quiet,
;   one copy each. They are eight, four and three instructions; reaching the
;   originals would mean keeping the menu overlay resident, which the window
;   cannot do.
;--------------------------------------------------------------
.proc ep_press
        lda STICK0
        ora #$F0                     ; stick 1 is not ours
        inc @                        ; $FF = centred -> 0: inc IS the cmp #$FF,
        bne ?yes                     ;   and A is dead past the branch
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
ep_arm  dta 0                        ; frames the controls still rest (MN_REST)
                                     ; (ep_move: the cursor's new row rides the
                                     ;  stack across ep_erase now -- see ?mv)
ep_it   dta 0
ep_i    dta 0
ep_x    dta 0
ep_y    dta 0

EP_PAGES equ [* - MENU_RUN + 255] / 256
    .if EP_PAGES < 2
        ert 'ep_head copies pages EP_PAGES-1..1 downwards: it needs EP_PAGES >= 2'
    .endif
    .if * > MENU_RUN + EPIOVL_MAX
        ert 'm_episode.asm outgrew EPIOVL_MAX (memory_map.inc)'
    .endif
    .if * > MENU_RUN_END+1
        ert 'm_episode.asm outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
