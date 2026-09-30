;--------------------------------------------------------------
; menu.asm -- DOOM's title screen and main menu (m_menu.c), at boot and on ESC.
;   Runs as an overlay in MENU_RUN ($1000-$14FF), RAM that is dead while paused.
;--------------------------------------------------------------
        icl 'menu_syms.inc'          ; m_menu.c's geometry (generated)

KEY_RET  equ $0C                     ; RETURN: select, like DOOM's KEY_ENTER.
COLDSV   equ $E477                   ; OS cold start -- QUIT DOOM's exit

;==============================================================
; PART 1 -- the MAP-SLOT half: boot only, dead after load_level_c.
;   These two cannot be in the overlay: every loader streams through TEX_STAGE
;   ($1000-$13FF), which is where the overlay RUNS. So the loads happen from
;   here, with the overlay still in VRAM, and mn_open fetches it down in the
;   gaps between them.
;==============================================================

;--------------------------------------------------------------
; mn_dtab -- where the menu's TWO DEFLATE streams (make_atr_doom.py: chunks
;   0-33, then 83-93) go once they sit depacked at MENU_BOUNCE: 8 B a row for
;   spr_fcopy -- sf_src (3), sp_addr (3, VRAM), sf_size (2). Rows are literal
;   for the 2026-09-26 chunk map; the ert below trips if pack_menu moves it.
;--------------------------------------------------------------
mnld_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
mn_dtab                              ; --- phase A: pakA at MENU_BOUNCE ---
        dta $00,$00,$74, $00,$00,$02, $00,$80   ; title+pristine 1/3 -> $020000
        dta $00,$80,$74, $00,$80,$02, $00,$80   ; ... 2/3
        dta $00,$00,$75, $00,$00,$03, $00,$D0   ; ... 3/3
        dta $00,$D0,$75, $00,$B0,$00, $00,$30   ; the M_* patches -> $00B000
        dta $00,$00,$76, $00,$E0,$00, $00,$20   ; menu+savegame CODE -> $00E000
MN_D_B  equ * - mn_dtab              ; --- phase B: pakB at MENU_BOUNCE ---
        dta $00,$00,$74, $00,$D0,$03, $00,$30   ; episode picker + M_DOOM
        dta $00,$30,$74, $00,$00,$05, $00,$80   ; the intermission run
MN_D_N  equ * - mn_dtab
    .if MENU_TCHUNKS<>29 || MENU_PCHUNKS<>3 || MENU_OCHUNKS<>2 || MENU_TBANK<>$20 || MENU_PBANK<>$0B || MENU_OBANK<>$0E || MENU_LVCH<>83 || MENU_LVCHUNKS<>3 || MENU_WICH<>86 || MENU_WICHUNKS<>8 || MENU_LVBANK<>$3D || WI_BANK<>$50 || MENU_BOUNCE<>$740000
        ert 'mn_dtab rows are literal for the 2026-09-26 menu.bin chunk map -- regenerate them'
    .endif
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org mnld_resume              ;   memory_map.inc for why it moved

;--------------------------------------------------------------
; mn_binf -- inflate one menu stream (ll_sec pre-set) into MENU_BOUNCE.
; mn_dist -- hand rows [X, A) of mn_dtab from the bounce to VRAM: spr_fcopy
;   does the window walk. RAM-to-VRAM only -- after mn_binf the title needs
;   no more SIO at all, so the picture is up ~1,100 sectors sooner than the
;   plain chunk walk (2026-09-26).
;--------------------------------------------------------------
.proc mn_binf
        stz inf_out                  ; MENU_BOUNCE = $74:0000
        stz inf_out+1
        lda #MENU_BOUNCE>>16
        sta inf_out+2
        jsl B1CODE_BASE+mn_vrel_w1   ; inflate, and the overlays' VBXE addresses
        rts
.endp
;--------------------------------------------------------------
; mn_vrel -- a VBXE at $D7xx (2026-09-28). The boot loader has stepped the
;   engine's register operands (mn_vbase with them); the code overlays come
;   in the menu's streams, so theirs are stepped here, in the bounce, before
;   mn_dist hands them to VRAM: mn_binf's inflate comes through here. A group
;   of mn_vtab a stream, pakA's first: 24-bit bounce addresses, a 0 bank ends
;   the group (tools/vbxe_reloc.py fills it).
;--------------------------------------------------------------
MN_VMAX equ 32                       ; the entries a group holds
MN_VGB  equ [MN_VMAX+1]*3            ; group B's first (pakB's overlays)
        .segment B1
.proc mn_vrel
        jsr inflate
        lda.l B1CODE_BASE+mn_vbase+1
        cmp #$D7
        bne ?r
        lda.l B1CODE_BASE+mn_vgrp    ; this stream's group, the next one's after
        tax
        lda #MN_VGB
        sta.l B1CODE_BASE+mn_vgrp
?e      lda.l B1CODE_BASE+mn_vtab+2,x
        beq ?r
        sta zp_ptr+2
        lda.l B1CODE_BASE+mn_vtab+1,x
        sta zp_ptr+1
        lda.l B1CODE_BASE+mn_vtab,x
        sta zp_ptr
        lda [zp_ptr]
        inc @
        sta [zp_ptr]
        inx
        inx
        inx
        bra ?e
?r      rts
.endp
mn_vrel_w1 jsr mn_vrel               ; (mn_binf, bank 0, jsl's it)
        rtl
mn_vbase dta a(VBXE_BASE)
mn_vgrp dta 0
mn_vtab :2*MN_VGB dta 0
        .endseg
.proc mn_dist
        sta mn_le
?l      stx mn_li
        lda mn_dtab,x
        sta sf_src
        lda mn_dtab+1,x
        sta sf_src+1
        lda mn_dtab+2,x
        sta sf_src+2
        lda mn_dtab+3,x
        sta sp_addr
        lda mn_dtab+4,x
        sta sp_addr+1
        lda mn_dtab+5,x
        sta sp_addr+2
        lda mn_dtab+6,x
        sta sf_size
        lda mn_dtab+7,x
        sta sf_size+1
        jsl B1CODE_BASE+spr_fcopy_w1
        lda mn_li
        clc
        adc #8
        tax
        cpx mn_le
        bcc ?l
        rts
.endp
mn_li   dta 0
mn_le   dta 0

;--------------------------------------------------------------
; mn_readthis -- M_ReadThis (m_menu.c:1030), the registered-WAD flow: HELP1,
;   a key, HELP2, a key, back to the menu (M_FinishReadThis).
;--------------------------------------------------------------
.proc mn_readthis                    ; BOOT ONLY -- ?read is what tests mn_ing
        jsr mn_quiet                 ; the select SFX must be OFF the mixer
                                     ;   before SIO takes POKEY (the overlay is ...
        jsl B1CODE_BASE+rd_pages_w1  ; every page at 320, a key each (PART 2)
        lda #>MENU_SRXDL             ; ...and the TITLE back onto the screen:
        sta VBXE_XDLA1               ;   the pages landed in $010000 and the
        lda #[MENU_SRXDL>>16]        ;   picture at $020000 was never touched
        sta VBXE_XDLA2
        jsr snd_pokey_t ; SIO owned POKEY through the streams: put
                                     ;   the mixer back (AUDCTL 0, voices idle, ...
        pla                          ; DROP mn_run's return address, exactly as
        pla                          ;   ?ng does and for exactly its reason:
                                     ;   `?read` got here by JMP, so that frame ...
        lda #BANK_EN | MENU_OBANK    ; the streams ate the overlay (TEX_STAGE):
        ldx #MN_E_BOOT               ;   copy it back and re-enter over the
        jmp mn_open                  ;   restored title
.endp

;--------------------------------------------------------------
; menu_boot -- what boot calls INSTEAD of load_level_c. Everything here has to
;   happen before that load: it overwrites the map slot this code is staged in
;   and the VRAM the title picture is in. Replacing the existing call rather
;   than adding one is deliberate -- the $2000 engine segment has no spare bytes
;   at all, and check_xex fails the build over six of them.
;--------------------------------------------------------------
.proc menu_boot
        stz sg_pend                  ; ...and no deferred LOAD until one is picked
        stz SOUNDR_R                 ; the OS's "noisy I/O" beeping, off: from
                                     ;   here on there is a picture on screen
                                     ;   and every load is behind it
        lda #1
        sta mn_arm                   ; mn_key's ESC edge, and the skull's row:
        lda #MENU_SKULLY             ;   both are permanent bytes the engine
        sta mn_sy                    ;   never writes otherwise, so random RAM
                                     ;   would eat the first ESC of the session ...
        jsl B1CODE_BASE+con_msg_w1   ; "M_Init: ..." -- the whole boot runs
                                     ;   on the TEXT console (console.asm)
        lda #<MENU_SEC1              ;   (2026-09-26): the title comes up at
        sta ll_sec                   ;   the END, fully loaded, like the PC
        lda #>MENU_SEC1
        sta ll_sec+1
        jsr mn_binf                  ; pakA: title + patches + CODE overlays
        ldx #0
        lda #MN_D_B
        jsr mn_dist
        lda #<MENU_PAKB_SEC
        sta ll_sec
        lda #>MENU_PAKB_SEC
        sta ll_sec+1
        jsr mn_binf                  ; pakB: episode picker + intermission
        ldx #MN_D_B
        lda #MN_D_N
        jsr mn_dist
        jsl B1CODE_BASE+con_msg_w1   ; (an empty entry: a spare call site)
        jsl B1CODE_BASE+con_msg_w1   ; "R_Init: ... - [ ]", the dots gate up
        jsr load_textures_t ; the WHOLE tex+spr pool (B2: one blob for all
                                     ;   27 levels): inflate ticks a dot per
                                     ;   32 KB -- the PC's R_Init line, real
        jsl B1CODE_BASE+con_msg_w1   ; "P_Init/I_Init/I_Startup*", dots down
                                     ;   (sound + net print from load_sounds)
        jsr load_sounds_t ; ... the digi SFX, the weapon psprites, the
                                     ;   songs and the world maps
        jsr snd_init_t ; the mixer, now that its samples are in
                                     ; (NO MUSIC HERE.
        jsl B1CODE_BASE+con_msg_w1   ; "HU_Init/ST_Init"
        jsr load_palette_t ; PLAYPAL -> the VBXE palettes. Without this the
                                     ;   title is BLACK: TITLEPIC is palette INDICES ...
        jsl B1CODE_BASE+con_off_w1   ; the console's last word
        stz zback_hi                 ; paint AND show FRAME_A (see the header)
        lda #BANK_EN | MENU_OBANK
        ldx #MN_E_TITLE
        jsr mn_open                  ; the picture is UP, everything loaded
        lda #BANK_EN | MENU_OBANK    ; NOW the title is dismissable, and the
        ldx #MN_E_BOOT               ;   menu comes up behind the keypress
        jsr mn_open
        jsr mn_togame_t ; ...and the 320-wide screen goes away with
        jmp load_level_c_t ;   it: DST_STEPY, the zoom and the display
.endp                                ;   list all back to the renderer's (PART 2b)

;==============================================================
; PART 2 -- the two PERMANENT stubs. Everything else about the menu is either
;   boot-only (above) or in the overlay (below); these 53 bytes are what makes
;   ESC work, and they live in two holes the RAM budget had left.
;==============================================================
mn_resume = *

;--------------------------------------------------------------
; mn_open -- A = the overlay's VRAM bank byte, X = entry index. Put its FIRST
;   page back at MENU_RUN and jump into it; that page copies the other four
;   itself, with the window still pointing at the bank, and dispatches on X.
;--------------------------------------------------------------
        org MNOPEN_BASE
.proc mn_open
                                      ; DRAC_PLAN 3b: 16 KB window
        sta VBXE_BANK_SEL
        and #3                       ; page 0 of chunk A: MEMW16+(A&3)*$1000
        asl
        asl
        asl
        asl
        ora #>MEMW16
        sta ?by+2
        ldy #0
?by     lda MEMW16,y
        sta MENU_RUN,y
        iny
        bne ?by
        jmp MENU_RUN
.endp
    .if * > MNOPEN_END+1
        ert 'mn_open outgrew MNOPEN_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mn_key -- read_keys' tail: ESC opens the control panel (m_menu.c:1699).
;--------------------------------------------------------------
        org MNKEY_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_key
                                      ; 2026-09-23 (rapidus-bus-timing): read_keys' tail comes
        lda SKSTAT                   ;   in at mnk_rk with ITS sample (kb_sk) -- one I/O
        bra ?have                    ;   read a frame instead of two. The automap path
mnk_rk  lda kb_sk                    ;   (am_kgate, no read_keys) still reads SKSTAT
?have   and #4                       ; bit2 = 0 while a key is held
        bne ?up
        lda KBCODE
        and #$3F                     ; bare code (no shift/ctrl)
        cmp #KEY_ESC
        bne ?ret
        lda mn_arm                   ; acts once, then stays disarmed for as long
        beq ?ret                     ;   as ESC is held -- NOT `dec/bne`, which
        lda ZFRONT                   ;   comes back round to zero after 255 held
        bne ?ret                     ;   frames and re-opens the menu by itself.
        sta mn_arm
        lda #BANK_EN | MENU_OBANK
        ldx #MN_E_INGAME
        jsl mn_open_w0                  ; ... which lands in mn_ingame, whose rts
        rts                          ;   (tail call across the bank line)
                                     ;   goes straight to read_keys' caller.
?up     lda #1
        sta mn_arm
?ret    jmp am_key                   ; TAB = the automap (automap.asm), which
                                     ;   tail-calls fps_key -- the 'F' FPS
                                     ;   toggle still rides this tail (hud.asm).
.endp                                ;     which tail-calls vw_frame
        .endseg
    .if * > MNKEY_END+1
        ert 'mn_key outgrew MNKEY_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mn_pend -- a LOAD GAME picked at the TITLE, fired on the first frame of the
;   game that came up behind it. It cannot happen any earlier: menu_boot's
;   caller still has load_things to run, and that resets THING_ALIVE and
;   re-streams the things blob -- straight over a restored save.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_pend
        lda rd_pend                  ; READ THIS! picked from the in-game menu
        beq ?nord
        stz rd_pend
        jsr mn_rdgame
?nord
        lda sg_pend
        beq ?no
        stz sg_pend
        lda #BANK_EN | SGOVL_BANK
        ldx #SG_E_LOAD
        jsl mn_open_w0
        rts                          ;   (tail call across the bank line)
?no     jmp vw_frame                 ; read_keys' own tail call, unchanged
.endp
        .endseg

;--------------------------------------------------------------
; mn_rdgame -- BUG FIX 2026-09-15 ("readme v hre: nic sa nezobrazi"). M_ReadThis
;   works in-game in DOOM (m_menu.c:1030); here ?read only closed the menu,
;   because mn_readthis lives in the map slot and the pages stream through
;   TEX_STAGE, which is the overlay's own RAM.
;   The last page stays up (list R) until the game's first flip, and
;   arena_init fills the pool under its lower half: list R goes BLANK first.
;--------------------------------------------------------------
RD_WXDL equ MEMW16+[VRAM_XDL_R&$3FFF]          ; list R, in the window as parked
RD_XOFF equ XDLC_OVOFF|XDLC_MAPOFF|[[XDLC_ATT|XDLC_END]<<8]  ; ctrl1, ctrl2
RD_XATT equ XDL_ATT_BASE|FL_PAL_NORM|[PRI_ALL<<8]            ; the lists' ATT pair
    .if [VRAM_XDL_R&$FFC000] <> [VRAM_OVERHEAD&$FFC000]
        ert 'mn_rdgame: list R must sit in the 16 KB the window is parked on'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_rdgame
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a)
        lda #$40                     ;   DRAC_PLAN 4a: siov_r banks the ROM in)
        sta NMIEN
        cli
        jsl snd_stop_w0              ; the DAC quiet before SIO takes POKEY
        stz SOUNDR_R
        jsr rd_pages
        lda RTCLOK3                  ; in the blank, no list being read: list R
?vb     cmp RTCLOK3                  ;   = ONE entry, overlay off and END. Black
        beq ?vb                      ;   until swap_buffers' XDLA1
        rep #$20
        .LONGA ON
        lda #RD_XOFF
        sta RD_WXDL
        lda #RD_XATT
        sta RD_WXDL+2
        .LONGA OFF
        sep #$20
        sei
                                      ; 2026-09-22 idiom: rom_out inlined (-12)
        lda PORTB
        and #$FE
        sta PORTB
        jsr snd_pokey                ; POKEY back from SIO (snd_pokey ends with
        sei                          ;   cli; the frame loop wants IRQs masked)
        jsr arena_init               ; the arena lost its first 32 KB: re-warm it
        lda #MAP_EXT_BANK            ; arena_prefetch exits with zp_ptr+2 on
        sta zp_ptr+2                 ;   SPRCOL_BANK; init_level sets the engine-
                                     ;   wide MAP_EXT_BANK after a level load and
                                     ;   nothing runs it here.
        lda RTCLOK3                  ; the pages' time is not the game's: no walk,
        sta fps_last                 ;   door or light takes it (as mn_ingame)
        jmp vw_apply                 ; the border columns (TEX_STAGE = solid_arr).
.endp                                ;   FRAME_A and the SR bar were not touched.

;--------------------------------------------------------------
; rd_pages -- every READ THIS! page, a key each: boot (mn_readthis) and game
;   (mn_rdgame). A page is 320x200 SR with its list in the padding: a DEFLATE
;   stream, depacked to MENU_BOUNCE and copied to MENU_VRAM = FRAME_B + the
;   pool's first 32 KB, both dead while it is up.
;   The list is blitted to VRAM_XDL_R in bank 0, so XDLA2 ends 0 and the
;   game's first flip (XDLA1 alone) takes the display back by itself.
;--------------------------------------------------------------
RD_SEC0 equ MENU_PLAIN_SEC + [MENU_HELP_CH-34]*32  ; HELP1: a page's stream
                                     ;   starts its own 512 sectors in the menu
                                     ;   region's middle (make_atr_doom.py)
RD_VRAM equ MENU_HBANK*4096
    .if MENU_HCHUNKS*32 <> 512
        ert 'rd_pages steps ll_sec+1 by 2 a page: a page must be 512 sectors'
    .endif
    .if [RD_VRAM&$FFFF] <> 0 || MENU_HCHUNKS <> 16 || MENU_BNC_CH < 16 || [MENU_BOUNCE&$FFFF] <> 0
        ert 'rd_pages copies a page as two halves of 32 KB from a bank line to a bank line'
    .endif
.proc rd_pages
        lda #0
?pg     pha
        asl                          ; page*2 into the high byte: page < 128, so
        adc #>RD_SEC0                ;   the asl leaves C = 0
        sta ll_sec+1
        lda #<RD_SEC0                ; (inflate advanced ll_sec: every pass)
        sta ll_sec
        stz VBXE_VCTL                ; black while the page lands over the one
        lda zp_sptr+2                ;   on show. inf_out is zp_sptr: the level's
        pha                          ;   seg bank rides the stack
        stz inf_out
        stz inf_out+1
        lda #MENU_BOUNCE>>16
        sta inf_out+2
        jsr inflate
        pla
        sta zp_sptr+2
        rep #$20
        .LONGA ON
        stz sf_src                   ; the bounce -> VRAM, 32 KB a call: sf_size
        stz sp_addr                  ;   is a word
        lda #$8000
        sta sf_size
        .LONGA OFF
        sep #$20
        lda #MENU_BOUNCE>>16
        sta sf_src+2
        lda #RD_VRAM>>16
        sta sp_addr+2
        jsr spr_fcopy                ; (keeps both addresses, eats sf_size;
        lda #$80                     ;   MEMAC back on the overhead bank)
        sta sf_src+1
        sta sp_addr+1
        sta sf_size+1
        jsr spr_fcopy
        rep #$20
        .LONGA ON
        lda #MENU_HXDL&$FFFF
        ldx #[MENU_HXDL>>16]
        jsr xdl_to_r                 ; the page's list to bank 0, and on screen
        .LONGA OFF                   ;   (it returns 8-bit)
?up     lda SKSTAT                 ; the key that picked READ THIS! comes UP,
        and #4                       ;   then the next press turns the page (the
        beq ?up                      ;   boot menu is silent: no music to tick)
?dn     lda SKSTAT
        and #4
        bne ?dn
        pla
        inc @
        cmp #MENU_HPAGES
        bcc ?pg
        rts
.endp

;--------------------------------------------------------------
; xdl_to_r -- A (16-bit) : X = an SR list in VRAM (page-aligned): blit its
;   MENU_HXDLN bytes to VRAM_XDL_R as rows of 160 -- the HUD BCB template's own
;   strides, so hud_blit finds them intact -- and show it with the display on.
;   The blitter must be idle (the BCB is rewritten). Returns with 8-bit A.
;--------------------------------------------------------------
.proc xdl_to_r
        .LONGA ON                    ; the BCB as bus WORDS (rapidus-bus-timing)
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR      ; [0-1] SRC lo/mid
        txa                                    ; X is 8-bit: B = 0, then
        ora #SCREEN_WIDTH<<8                   ; [2] SRC bank, [3] SRC_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #$0100                             ; [4] SRC_STEPY hi 0, [5] SRC_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #VRAM_XDL_R&$FFFF                  ; [6-7] DST lo/mid
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        lda #SCREEN_WIDTH<<8                   ; [8] DST bank 0, [9] DST_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #SCREEN_WIDTH-1                    ; [12-13] WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        stz MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1   ; [10]
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; [20] BLT_COPY
        stz MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18]
        lda #RD_XDLROWS-1                      ; [14]
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jsl hud_fire_w0
        jsr blitw_hard               ; the list lands before the display reads it
show    stz XDLA_PEND                ; list R up (melt.asm mt_show comes in here):
                                     ;   no pending flip may take it away again
        lda #>VRAM_XDL_R
        sta VBXE_XDLA1
        stz VBXE_XDLA2
        lda #VC_XDL_ON | VC_NO_TRANS
        sta VBXE_VCTL
        rts
.endp
RD_XDLROWS equ [MENU_HXDLN + SCREEN_WIDTH - 1] / SCREEN_WIDTH
    .if RD_XDLROWS*SCREEN_WIDTH <> MENU_HXDLN || [MENU_HXDL & $FF] <> 0 || [MENU_LDXDL & $FF] <> 0
        ert 'xdl_to_r copies a list as whole 160-byte rows from a page boundary'
    .endif
rd_pages_w1 jsr rd_pages             ; mn_readthis' jsl from bank 0
        rtl
xdl_to_r_w1 jsr xdl_to_r             ; the finale's (f_finale.asm fin_show):
        rtl                          ;   16-bit A in, 8-bit A out

;--------------------------------------------------------------
; sr_half -- A = the destination bank (0 FRAME_A, 1 FRAME_B): the SR screen
;   whose row 0 is at sr_src, sr_step bytes a row, every second pixel, as a
;   160x200 copy -- what the 160 world (the finale's control panel) shows
;   of a 320 screen. Leaves the BCB on the template's strides
;   (DST_STEPY = SCREEN_WIDTH) and the copy landed.
;--------------------------------------------------------------
.proc sr_half
        pha                          ; the destination bank
        jsr blitw_hard               ; the last blit, before the BCB moves
        pla
        rep #$20                     ; the BCB as bus WORDS (rapidus-bus-timing)
        .LONGA ON
        and #$00FF                   ; (B is junk from the 8-bit pla)
        ora #SCREEN_WIDTH<<8                   ; [8] DST bank, [9] DST_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda sr_src                             ; [0-1] row 0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda sr_src+2                           ; [2] SRC bank, [3] SRC_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda sr_step+1                          ; [4] SRC_STEPY hi, [5] SRC_STEPX =
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ;   sr_sx: every second pixel
        stz MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; [6-7] row 0
        lda #SCREEN_WIDTH-1                    ; [12-13] WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        stz MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1   ; [10]
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; [20] BLT_COPY
        stz MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18]
        lda #SCREEN_HEIGHT-1                   ; [14] all 200 rows
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jsl hud_fire_w0
        jmp blitw_hard
.endp
sr_half_w1 jsr sr_half               ; f_finale.asm's (stage 2, bank 0)
        rtl

;--------------------------------------------------------------
; sr_put -- zp_ptr = a 7-byte patch row (u24 vram, w, h, left, top), sr_x =
;   the column (a word, 0..319), Y = the row: V_DrawPatch 1:1 onto the SR
;   surface at MENU_SRVRAM, the patch's own offsets applied, mode hb_ctrl.
;   The intermission's patches at DOOM's own 320 (wi.asm wi_put). The caller
;   has the blitter idle: the BCB is written before hud_fire's wait.
;--------------------------------------------------------------
.proc sr_put
        tya                          ; the row less the patch's top (signed; no
        ldy #6                       ;   patch here reaches above row 0)
        sec
        sbc (zp_ptr),y
        tax
        lda row_hi,x                 ; B:A = row*160 ...
        xba
        lda row_lo,x
        rep #$20                     ; the BCB as bus WORDS (rapidus-bus-timing)
        .LONGA ON
        asl @                        ; ... *2 = row*320, <= 63680: no carry out
        sta sr_t
        dey                          ; Y = 5: [left, top] as a word -- the left
        lda (zp_ptr),y               ;   alone, sign-extended AND negated at once:
        and #$00FF                   ;   -((l ^ $80) - $80) = ~(l ^ $80) + 1 + $80
        eor #$FF7F
        sec
        adc #$0080
        clc
        adc sr_x                     ; x - left
        clc
        adc sr_t                     ; + row*320 = the surface offset
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; [6-7]
        lda (zp_ptr)                           ; [0-1] SRC lo/mid
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        ldy #2
        lda (zp_ptr),y                         ; [2] SRC bank, [3] SRC_STEPY lo = w
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #$0100                             ; [4] SRC_STEPY hi 0, [5] SRC_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda #[MENU_SRVRAM>>16]|[[MENU_SRW&$FF]<<8]   ; [8] DST bank, [9] DST_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        iny                                    ; Y = 3: [12-13] WIDTH = w-1 (the
        lda (zp_ptr),y                         ;   word read drags h in: the and)
        and #$00FF
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        lda #>MENU_SRW                         ; [10] DST_STEPY hi
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        iny                                    ; [14] HEIGHT = h-1
        lda (zp_ptr),y
        dec @
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        stz MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18] 1:1
        lda hb_ctrl                            ; [20]
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsl hud_fire_w0
        rts
.endp
sr_put_w1 jsr sr_put                 ; wi.asm's (stage 2, bank 0)
        rtl

        .endseg
        .segment D0                  ; DRAC_PLAN 3a
rd_pend dta 0                        ; 1 = mn_rdgame on the next mn_pend
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;==============================================================
; PART 2b -- THE MENU'S BLITTER: DOOM's 320 on an SR screen, boot and game.
;==============================================================
mnsr_resume = *
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; mn_sdraw -- zp_ptr = a 7-byte menu_tab/epi.tab/hud row, X = the column and
;   Y = the row in DOOM pixels: V_DrawPatch 1:1 onto the menu's SR screen
;   (mn_dbk: the title at boot, MT_SR in game, the stats surface). The row's
;   bank byte carries the width's ninth bit (ROW_W9: M_EPI1 is 263 wide) and
;   ROW_HALF, a halved strip drawn zoomed 2x (the level names). The BCB goes
;   over the bus as words (rapidus-bus-timing).
;--------------------------------------------------------------
ROW_W9   equ $80                     ; tools/pack_menu.py's ROW_W9 / ROW_HALF
ROW_HALF equ $40
    .if BLT_ZOOM_2X <> 1 || ROW_HALF <> $40
        ert 'mn_sdraw turns ROW_HALF into the zoom by two shifts and a rol'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_sdraw
        stx mn_sx                    ; the column, a word below
        stz mn_sx+1
        tya                          ; the row less the patch's top (the skull's
        ldy #6                       ;   -1 draws it a row lower)
        sec
        sbc (zp_ptr),y
        sta mn_sy2
        dey                          ; Y = 5: [left, top] as a word -- the left
        rep #$20                     ;   alone, sign-extended and negated at once:
        .LONGA ON                    ;   -((l ^ $80) - $80) = ~(l ^ $80) + 1 + $80
        lda (zp_ptr),y
        and #$00FF
        eor #$FF7F
        sec
        adc #$0080
        clc
        adc mn_sx
        sta mn_sx                    ; x - left
        lda (zp_ptr)                 ; [0-1] SRC lo/mid
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        ldy #2
        lda (zp_ptr),y               ; w << 8 | the bank byte
        pha                          ;   (parked: the flags, for the zoom)
        and #$FF07                   ; [2] SRC bank, [3] SRC_STEPY lo = w
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda 1,s
        xba                          ; flags << 8 | w
        cmp #$8000                   ; C = ROW_W9, the width's ninth bit
        and #$00FF
        bcs ?w9                      ; (M_EPI1 alone: out of line)
?w8     dec @                        ; [12-13] WIDTH = w-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        inc @
        xba                          ; [4] SRC_STEPY hi = w >> 8, [5] SRC_STEPX 1
        and #$00FF
        ora #$0100
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        ldy #4                       ; [14] HEIGHT = h-1, [15] AND $FF
        lda (zp_ptr),y
        and #$00FF
        dec @
        ora #$FF00
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        .LONGA OFF
        sep #$20
        pla                          ; the flags: ROW_HALF -> b7 -> C -> 1, the
        and #ROW_HALF                ;   zoom 2x; 0 stays 0 (1:1)
        asl @
        asl @
        rol @
        sta MEMW+MEMW_HD_OFF+BCB_ZOOM
        pla                          ; (w: done with)
        lda hb_ctrl                  ; BSTENCIL for a patch, COPY for a page
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr mn_sdst
        jsl hud_fire_w0              ; hud_blit's own "wait, then start" tail
        rts                          ; DRAC_PLAN 4b (xbank_fix.py)
        .LONGA ON
?w9     ora #$0100                   ; the ninth bit
        bra ?w8
        .LONGA OFF
.endp

;--------------------------------------------------------------
; mn_sdst -- (mn_sx, a word; mn_sy2) in DOOM pixels -> mn_st, its offset on
;   the menu's screen, and the BCB's destination: [6-7], [8] the screen's bank
;   and [9] DST_STEPY lo (mn_dbk is that pair), [10] its hi, [11] DST_STEPX.
;--------------------------------------------------------------
.proc mn_sdst
        ldx mn_sy2
        lda row_hi,x                 ; B:A = row*160
        xba
        lda row_lo,x
        rep #$21
        .LONGA ON
        asl @                        ; row*320 <= 63680: C = 0
        adc mn_sx
        sta mn_st
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; [6-7]
        lda mn_dbk                             ; [8] bank, [9] DST_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #$0100|[MENU_SRW>>8]               ; [10] DST_STEPY hi, [11] DST_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; mn_togame -- hand the machine back to the renderer. menu_boot calls it on the
;   way to load_level_c. THE LOADING SCREEN is the SR title itself: the level
;   load's arena_prefetch fills the pool it lives in, so rows 0-99 go to
;   FRAME_A and 100-199 to WIPE_START (untouched until the first flip: clear_both
;   spares FRAME_A, and the first frame renders into FRAME_B) and list T shows
;   them from bank 0 -- swap_buffers pokes XDLA1 alone. xdl_to_r leaves the
;   BCB's DST_STEPY at SCREEN_WIDTH, which the game's hud_blit relies on.
;--------------------------------------------------------------
    .if MENU_LDLO <> WIPE_START || MENU_LDSPLIT*MENU_SRW > VRAM_XDL_A || MENU_LDSPLIT*MENU_SRW + WIPE_START > FRAME_C
        ert 'mn_togame: the loading screen halves must be FRAME_A and WIPE_START'
    .endif
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_togame
                                      ; the BCB as bus WORDS (rapidus-bus-timing)
        rep #$20
        .LONGA ON
        stz MEMW+MEMW_HD_OFF+BCB_SRC_ADDR      ; [0-1] the title's row 0
        lda #[MENU_SRVRAM>>16]|[[MENU_SRW&$FF]<<8]   ; [2] SRC bank, [3] SRC_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #[MENU_SRW>>8]|$0100               ; [4] SRC_STEPY hi, [5] SRC_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        stz MEMW+MEMW_HD_OFF+BCB_DST_ADDR      ; [6-7] FRAME_A
        lda #[MENU_SRW&$FF]<<8                 ; [8] bank 0, [9] DST_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #MENU_SRW-1                        ; [12-13] WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        lda #>MENU_SRW                         ; [10] DST_STEPY hi
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY+1
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; [20] BLT_COPY
        stz MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18]
        lda #MENU_LDSPLIT-1                    ; [14] rows 0-99
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jsl hud_fire_w0
        jsr blitw_hard               ; the BCB is rewritten next
        rep #$20
        .LONGA ON
        lda #MENU_LDSPLIT*MENU_SRW             ; [0-1] the title's row 100
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #WIPE_START&$FFFF                  ; [6-7]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        .LONGA OFF
        sep #$20
        lda #[WIPE_START>>16]                  ; [8]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        jsl hud_fire_w0
        jsr blitw_hard
        rep #$20
        .LONGA ON
        lda #MENU_LDXDL&$FFFF
        ldx #[MENU_LDXDL>>16]
        jmp xdl_to_r                 ; list T to bank 0, and on screen
        .LONGA OFF
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; mn_sbox -- mb_x/mb_y/mb_w/mb_h (160 units across: two DOOM pixels, so a box
;   restores a pixel more at worst) back to the BACKGROUND: the pristine copy
;   at the same offset (mn_sbk's bank: the title's, the stats'), or -- mn_sbk
;   0, in game -- the frozen frame in FRAME_A, zoomed 2x the way mn_frz built
;   the screen out of it. The menu never draws below its row 168.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mn_sbox
        lda mb_y
        sta mn_sy2
        rep #$20
        .LONGA ON
        lda mb_x                     ; 160 units -> DOOM px (the word read drags
        and #$00FF                   ;   mb_y in: the and)
        asl @
        sta mn_sx
        .LONGA OFF
        sep #$20
        jsr mn_sdst                  ; [6-11], mn_st
        lda mn_sbk                   ; (rep keeps Z)
        rep #$20
        .LONGA ON
        beq ?zm
        lda mn_st                    ; [0-1] the same offset in the pristine copy
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda mn_sbk                   ; [2] its bank, [3] SRC_STEPY lo
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #$0100|[MENU_SRW>>8]     ; [4] SRC_STEPY hi, [5] SRC_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda mb_w                     ; [12-13] WIDTH = 2(w+1)-1, nine bits (the
        and #$00FF                   ;   word read drags mb_h in: the and)
        asl @
        ora #1
        ldx #BLT_ZOOM_1X
        bra ?w
?zm     lda mn_st                    ; [0-1] row*160 + x: the frame's offset
        lsr @
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #[VRAM_SCREEN>>16]|[SCREEN_WIDTH<<8]   ; [2] FRAME_A, [3] SRC_STEPY 160
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #$0100                   ; [4] SRC_STEPY hi 0, [5] SRC_STEPX 1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda mb_w                     ; [12-13] WIDTH: w+1 bytes, each drawn twice
        and #$00FF
        ldx #BLT_ZOOM_2X
?w      sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda mb_h                     ; [14] HEIGHT, [15] AND $FF (the ora drops
        ora #$FF00                   ;   the byte above mb_h)
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        .LONGA OFF
        sep #$20
        stx MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18]
    .if BLT_COPY != 0
        ert 'BLT_COPY is not 0: mn_sbox stz-es the ctrl byte'
    .endif
        stz MEMW+MEMW_HD_OFF+BCB_CTRL          ; [20] BLT_COPY
        jsl hud_fire_w0
        rts                          ; DRAC_PLAN 4b (xbank_fix.py)
.endp

;--------------------------------------------------------------
; mn_frz -- the pause (M_StartControlPanel): what is on screen onto MT_SR at
;   320 and up through list R (melt.asm mt_show) -- FRAME_A, because mn_key
;   opens the panel only while it is the front buffer, and fin_panel puts the
;   finale there -- and the menu pointed at it: patches onto MT_SR, boxes back
;   out of FRAME_A zoomed (mn_sbk = 0). Over the automap the screen is its
;   surface, and FRAME_A gets it halved for the boxes.
;--------------------------------------------------------------
mn_frz_w1
        lda #MT_BK
        sta mn_dbk
        stz mn_sbk
        lda mn_fin                   ; over a finale: FRAME_A holds it (fin_panel)
        bne ?v
        lda am_on
        bne ?am
?v      lda #MT_GRAB
        jsr mt_show
        bra ?out
?am     jsr mt_gsel                  ; over the automap: its surface as it stands,
        jsr mt_show                  ;   and halved into FRAME_A, which the boxes
        rep #$20                     ;   restore out of (mn_sbox)
        .LONGA ON
        stz sr_src
        lda #MT_BK|[[MT_W&$FF]<<8]   ; MT_SR's bank, 320 a row
        sta sr_src+2
        .LONGA OFF
        sep #$20
        lda #>MT_W
        sta sr_step+1
        lda #[VRAM_SCREEN>>16]
        jsr sr_half
?out    stz mn_fin                   ; a one-shot: fin_panel sets it each time
        rtl

;--------------------------------------------------------------
; mn_tmpl -- the menu is over: the BCB template back to the game's strides
;   (hud_blit writes neither DST_STEPY nor ZOOM).
;--------------------------------------------------------------
mn_tmpl_w1
        rep #$20
        .LONGA ON
        lda #SCREEN_WIDTH                      ; [9-10] DST_STEPY 160
        sta MEMW+MEMW_HD_OFF+BCB_DST_STEPY
        .LONGA OFF
        sep #$20
        stz MEMW+MEMW_HD_OFF+BCB_ZOOM          ; [18] 1:1
        rtl

;--------------------------------------------------------------
; mn_sname -- A = level: its NAME at DOOM's width, beside slot mn_it's digit on
;   row mn_y. The line comes out of SDRAM (pack_wi.py's HU lines, by strip
;   index = level) into the slot's own 2 KB of the strips' VRAM -- nothing
;   runs the strips under the menu, and the next frame rebuilds them whole.
;--------------------------------------------------------------
MN_NAMEV equ ST_STRIPA
    .if MSG_WMAX*TITLE_H > $800 || SAVE_SLOTS*$800 > 3*ST_SIZE || [MN_NAMEV&$7FF] <> 0
        ert 'mn_sname: a slot line is 2 KB of the strips VRAM, six of them'
    .endif
mn_sname_w1
        tax                          ; the strip index
        lda #[MN_NAMEV>>16]
        sta sp_addr+2
        sta mn_nrow+2                ; [2] bank, 1:1
        stz sp_addr
        stz mn_nrow
        lda mn_it                    ; the slot's 2 KB: mid byte + slot*8 (< 48:
        asl @                        ;   C = 0 for the add)
        asl @
        asl @
        adc #>MN_NAMEV
        sta sp_addr+1
        sta mn_nrow+1                ; [0-1]
        jsr st_hufetch               ; (takes zp_ptr: the row goes in after)
        sta mn_nrow+3                ; [3] w
        lda #<mn_nrow
        sta zp_ptr
        lda #>mn_nrow
        sta zp_ptr+1
        ldx #SLOT_X+24
        ldy mn_y
        jsr mn_sdraw
        rtl
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
mn_sx   dta a(0)                     ; mn_sdst's column (a word) and row, after
mn_sy2  dta 0                        ;   V_DrawPatch's offsets
mn_st   dta a(0)                     ; ...and the offset it computes, which
                                     ;   mn_sbox re-uses for the SOURCE
mn_bx   dta 0
mn_by   dta 0
mn_bw   dta 0                        ;   ... width - 1
mn_bh   dta 0                        ;   ... height - 1
mn_sbk  dta [MENU_SRBG>>16], <MENU_SRW   ; mn_sbox's background: a pristine
                                     ;   copy's bank (the title's; WI_SRBG at the
                                     ;   intermission) or 0, the frozen frame in
                                     ;   game -- with DST_STEPY lo, one BCB word
mn_dbk  dta [MENU_SRVRAM>>16], <MENU_SRW ; the screen the menu draws on: the
                                     ;   title's bank, MT_SR's in game (mn_frz),
                                     ;   WI_SRVRAM's at the intermission
mn_fin  dta 0                        ; 1 = the next panel opens over a finale
                                     ;   (fin_panel): mt_show takes all 200 rows
                                     ;   of FRAME_A and no bar
sr_src  dta 0,0,0                    ; sr_half's source: row 0 (u24), then its
sr_step dta a(0)                     ;   pitch, and SRC_STEPX -- five + one bytes
sr_sx   dta 2                        ;   read as the BCB's words [0-1] [2-3] [4-5]
sr_x    dta a(0)                     ; sr_put's column (wi.asm's wi_px)
sr_t    dta a(0)                     ; ...and its row*320
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;==============================================================
; PART 3 -- THE OVERLAY. Assembled for MENU_RUN ($1000-$14FF), parked in the
;   XEX at MNOVL_STAGE and lifted out of it by tools/split_menu_ovl.py.
;   Everything in here is dead RAM the moment the menu returns.
;==============================================================
        org MENU_RUN, MNOVL_STAGE

;--------------------------------------------------------------
; mn_head -- the overlay's own bootstrap, and the FIRST bytes at MENU_RUN, so
;   mn_open's `jmp MENU_RUN` lands here. The window is still on the overlay's
;   bank; take the other four pages, put it back where every other blitter user
;   expects it (the overhead bank), and dispatch.
;--------------------------------------------------------------
    .if [MENU_OBANK & 3] <> [[MEMW-MEMW16] >> 12]
        ert 'mn_head reads the overlay at MEMW: MENU_OBANK must sit there in the 16 KB window'
    .endif
.proc mn_head
        ldy #0
                                      ; 2026-09-22 (65816-style: a byte sweep read as words)
        rep #$20
        .LONGA ON
?p      lda MEMW+$100,y
        sta MENU_RUN+$100,y
        lda MEMW+$200,y
        sta MENU_RUN+$200,y
        lda MEMW+$300,y
        sta MENU_RUN+$300,y
        lda MEMW+$400,y
        sta MENU_RUN+$400,y
        iny
        iny
        bne ?p
        sep #$20
        .LONGA OFF
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        inc snd_menu                 ; the menu's SFX keep a flat pitch
                                     ;   (sound.asm snd_pstep; the game's first
                                     ;   snd_dispatch drops it again)
        cpx #MN_E_TITLE
        bne ?n1
        jmp show_title
?n1     cpx #MN_E_INGAME
        beq ?ig
        cpx #MN_E_PICK
        beq ?pk
        jmp mn_boot
?ig     jmp mn_ingame
?pk     jmp mn_pick
.endp

menu_tab
        ins 'build/assets/menu/menu.tab'   ; u24 vram, u8 w, u8 h, i8 left, i8 top

;--------------------------------------------------------------
; mn_draw -- A = lump index (MI_*), X = column, Y = row. Points zp_ptr at the
;   7-byte menu_tab row and lets mn_sdraw do the work.
;--------------------------------------------------------------
.proc mn_draw
                                      ; 2026-09-23: mn_tabptr moves A only, so X/Y ride
        sty mn_y                     ;   through it; mn_y is still stored (mn_slotdig
        jsr mn_tabptr                ;   re-uses the row)
        jmp mn_sdraw_t               ; 320 SR at boot and in game (PART 2b)
go      ldx mn_x                     ; (mn_slotdig comes in here with zp_ptr
        ldy mn_y                     ;  already on its HUD_TAB row)
        jmp mn_sdraw_t
.endp

;--------------------------------------------------------------
; mn_tabptr -- A = lump index -> zp_ptr = its 7-byte menu_tab row. One copy:
;   mn_wbox used to carry this multiply inline (2026-08-10) and the overlay is
;   bytes from MENU_RUN_END -- the room matters more than mn_draw's 12 cycles.
;--------------------------------------------------------------
.proc mn_tabptr
        sta mn_i                     ; index * 7
        asl
        asl
        asl                          ; *8
        sec
        sbc mn_i                     ; ...-1 = *7, and 8i >= i leaves C=1: that
        adc #<[menu_tab-1]           ;   is the +1 of a 16-bit add of menu_tab-1
        sta zp_ptr
        lda #>[menu_tab-1]
        adc #0
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; show_title -- TITLEPIC, and the display switched on. DOOM shows the title on a
;   timer or a keypress (d_main.c D_PageTicker); the keypress alone is the
;   reduction, and it is mn_boot that waits for it -- the loads go in between.
;--------------------------------------------------------------
.proc show_title
                                     ; NOTHING IS BLITTED.
;--------------------------------------------------------------
; mn_vbxe_on -- switch the overlay on. (Falls out of show_title; main no longer
;   does this at all, which gave the $2000 segment 18 bytes back.)
;--------------------------------------------------------------
        lda #VC_XDL_ON | VC_NO_TRANS
        sta VBXE_VCTL
        lda #<MENU_SRXDL             ; = 0, like every other list's low byte:
        sta VBXE_XDLA0               ;   nothing writes XDLA0 again, and every
        lda #>MENU_SRXDL             ;   switch after this pokes XDLA1/2 only
        sta VBXE_XDLA1
        lda #[MENU_SRXDL>>16]
        sta VBXE_XDLA2
        rts
.endp

;--------------------------------------------------------------
; mn_boot -- the boot entry: dismiss the title, then the menu, over TITLEPIC.
;--------------------------------------------------------------
.proc mn_boot
        stz mn_ing                   ; boot: NEW GAME just returns (menu_boot
                                     ;   does the loading)
        jsr mn_anykey                ; (mn_arm and mn_sy are seeded by menu_boot:
                                     ;  they are PERMANENT bytes, so their init ...
?again  jsr mn_run
        beq ?go                      ; NEW GAME -> menu_boot loads the level
        cmp #2                       ; LOAD -> let the boot chain finish first
        bne ?wipe                    ;   and fire it on the first frame (mn_pend)
        sta sg_pend
        jsr mn_quiet                 ; SAME RULE AS ?ng AND mn_readthis, and the
                                     ;   one path that never got it (2026-08-13): ...
        lda #0
        rts
?wipe   jsr mn_wipe                  ; ESC -> M_ClearMenu: mn_sbox lifts the menu
        jsr mn_anykey                ;   off the picture out of the PRISTINE copy
        bra ?again                   ;   and TITLEPIC is on its own again, at 320
                                     ;   -- the display list never moved
?go     rts
.endp

;--------------------------------------------------------------
; mn_ingame -- ESC during play: M_StartControlPanel over the frozen frame.
;   Returns to read_keys' caller with the frame loop's invariants restored.
;--------------------------------------------------------------
.proc mn_ingame
        lda #1
        sta mn_ing
        jsl B1CODE_BASE+mn_frz_w1    ; the frozen frame at 320: the menu's screen
        jsr mn_run                   ; $FF = just closed, 1 = SAVE, 2 = LOAD.
        sta mn_ret                   ;   (in-game NEW GAME tail-jumps out of the
                                     ;    overlay and QUIT never returns at all)
        jsl B1CODE_BASE+mn_tmpl_w1   ; the BCB template back to the game's
        lda RTCLOK3                  ; (no release-wait: mn_key will not re-arm
                                     ;  its ESC edge until every key is up)                  ; PollControls: the paused jiffies are not
        sta fps_last                 ;   door/lift/timer time (WL_PLAY.C:813 does
                                     ;   the same thing for the same reason)
        jsr vw_apply_t                 ; THE ONE THING THE OVERLAY BREAKS. $1000 is
                                     ;   solid_arr, and the border columns outside ...
        lda #1
        sta zback_hi                 ; list R shows MT_SR until the next flip;
                                     ;   render the next frame into FRAME_B
        lda #VC_XDL_ON | VC_NO_TRANS ; turn display back ON before returning
        sta VBXE_VCTL
        ldx mn_ret
        bmi ?out                     ; $FF = just closed
        dex                          ; 1 = SAVE, 2 = LOAD -> SG_E_SAVE (0),
        bmi ?out                     ;   SG_E_LOAD (1). The dex IS the dispatch;
                                     ;   the second bmi keeps a 0 that cannot
                                     ;   happen in-game (NEW GAME never returns)
                                     ;   from opening the overlay on entry $FF.
        lda #BANK_EN | SGOVL_BANK
        jmp mn_open
?out    rts
.endp

;--------------------------------------------------------------
; mn_run -- M_DrawMainMenu + M_Responder, for MainMenu[] only. Returns 0 when
;   the menu is done with (NEW GAME at boot, or ESC in-game) and 1 for in-game
;   NEW GAME; QUIT DOOM never returns.
;--------------------------------------------------------------
MN_SYLAST equ MENU_SKULLY + (MENU_NITEMS-1)*MENU_LINEH
; LoadDef/SaveDef = { ..., 80, 54 } and M_DrawLoad puts its banner at (72,28)
; (m_menu.c:1218/1263), in DOOM's own pixels.
SLOT_X      equ 80                   ; LoadDef.x
SLOT_Y      equ 54                   ; LoadDef.y
SLOT_SKULLX equ 48                   ; x + SKULLXOFF
SLOT_SKULLY equ 49                   ; y - 5
SLOT_TITLEX equ 72                   ; M_LOADG / M_SAVEG at (72,28)
SLOT_TITLEY equ 28

.proc mn_run
        lda #BLT_BSTENCIL            ; V_DrawPatch: the patches are transparent.
        sta hb_ctrl                  ;   In-game whatever drew last owns hb_ctrl,
                                     ;   and BLT_COPY would make every menu line
                                     ;   an opaque block.
        stz mn_mode                  ; MainMenu[] first, always
        lda #MENU_SKULLY
        sta mn_top
        lda #MENU_NITEMS             ; ...and how long the list is: at the title
        ldx mn_ing                   ;   SAVE GAME is not on it at all (see
        bne ?six                     ;   mn_lumpof)
        lda #MENU_NITEMS-1
?six    sta mn_n
mn_enter lda mn_n                    ; mn_bot = the LAST row (top + (n-1)*16)
        dec @
        asl
        asl
        asl
        asl                          ; (n-1)*16 < 256 (ert below): the asl's shift
        adc mn_top                   ;   out 0s, so C=0 for the add
        sta mn_bot
    .if [MENU_NITEMS-1]*16 > 255 || [SAVE_SLOTS-1]*16 > 255
        ert 'mn_run: (n-1)*16 carries -- put the clc back'
    .endif
        lda mn_mode                  ; the drawer for whichever menu this is
        beq ?dmain
        jsr mn_slotitems
        bra ?drawn
?dmain  jsr mn_items
?drawn  ldx #SFX_SWTCHN              ; M_StartControlPanel's own sound: the menu
        jsr snd_play_t ;   opening IS a switch throw (m_menu.c:1545)
        stz mn_sk
        lda #MN_REST                 ; the key that opened the menu is down: the
        sta mn_arm2                  ;   controls rest before it picks an item
        lda #MENU_SKTICS
        sta mn_tic
        jsr mn_skdraw
?loop   jsr mn_vsync
        dec mn_tic                   ; skullAnimCounter (m_menu.c:1836-1839)
        bne ?nb
        lda #MENU_SKTICS
        sta mn_tic
        jsr mn_erase                 ; the two frames differ, so the box has to go
        lda mn_sk                    ;   back to the background between them
        eor #1
        sta mn_sk
        jsr mn_skdraw
?nb     jsr mn_press
        bcs ?act
        lda mn_arm2                  ; at rest: a frame less to wait
        beq ?loop
        dec @
        sta mn_arm2
?back   bra ?loop
?act    ldx #MN_REST                 ; a press counts when the controls had
        lda mn_arm2                  ;   rested: not while held, not in the
        stx mn_arm2                  ;   bounce of a contact
        bne ?loop
        lda TRIG0
        lsr
        bcc ?sel                   ; (?sel is out of branch range from here
        ;jmp ?sel                     ;  now that the slot picker is in the
?ntrig  lda STICK0                   ;  dispatch below it)
        lsr                          ; bit0 = UP
        bcc ?up
        lsr                          ; bit1 = DOWN
        bcc ?down
        lda SKSTAT
        and #4
        bne ?back                    ; let go mid-scan
        lda KBCODE
        and #$3F                     ; bare code (no shift/ctrl)
        cmp #KEY_RET
        beq ?sel
        cmp #KEY_ESC
        beq ?esc
        cmp #KEY_MINUS               ; the Atari's up arrow
        beq ?up
        cmp #KEY_EQUALS              ; ... and its down arrow
        bne ?back
?down   lda mn_sy
        clc
        adc #MENU_LINEH
        cmp mn_bot
        beq ?mv
        bcc ?mv
        lda mn_top                   ; M_Responder wraps both ways
        bcs ?mv                      ;   (always taken)
?up     lda mn_sy
        sec
        sbc #MENU_LINEH
        cmp mn_top
        bcs ?mv
        lda mn_bot
?mv     pha
        jsr mn_erase                 ; lift the skull off the OLD row first
        pla
        sta mn_sy
        jsr mn_skdraw
        ldx #SFX_PSTOP               ; every cursor step, m_menu.c:1629/1639
        jsr snd_play_t
        jmp ?loop
?back2  jmp ?loop                    ; ?back is out of branch range from down here
                                     ;   now that ESC is in the key scan
?esc    ldx #SFX_SWTCHX              ; M_ClearMenu, and the panel closing is the
        jsr snd_play_t ;   switch coming back (m_menu.c:1710)
        lda mn_mode
        beq ?escout
        jsr mn_wipeslots             ; the picker backs out to MainMenu[] first
        lda mn_sysav                 ;   (M_Responder's KEY_ESCAPE pops ONE menu)
        sta mn_sy                    ; ...and mn_run's own head puts the list
        jmp mn_run                   ;    back: mode, first row, count
?escout lda #$FF                     ; ...and the caller puts back whatever the
        rts                          ;   menu was covering
?sel    ldx #SFX_PISTOL              ; KEY_ENTER on a plain item (m_menu.c:1675)
        jsr snd_play_t
        lda mn_mode
        bne ?selslot
        lda mn_sy                    ; the ROW -> MainMenu[]'s own index, so the
        sec                          ;   title's five-line list dispatches by the
        sbc mn_top                   ;   same numbers as the six-line one
        lsr
        lsr
        lsr
        lsr
        jsr mn_lumpof
        sec
        sbc #MI_ITEM0
        beq ?ng                      ; 0 = NEW GAME
        cmp #2
        beq ?load                    ; 2 = LOAD GAME
        cmp #3
        beq ?save                    ; 3 = SAVE GAME
        cmp #4
        beq ?read                    ; 4 = READ THIS! (mn_readthis, PART 1)
        cmp #5
        bne ?back2                   ; 1 = options: no submenu
        lda #BANK_EN | SGOVL_BANK    ; quitdoom: the quit sound, ENDOOM and the
        ldx #SG_E_QUIT               ;   reboot are the OTHER overlay's
        jmp mn_open                  ;   (quit.asm quit_doom) -- QUIT never
                                     ;   comes back
?read   lda mn_ing                   ; IN-GAME mn_readthis IS NOT THERE. It is
        bne ?rdcl                    ;   staged in the map slot ($4A5C) with the
        jsr mn_wipe                  ;   boot code. The reader is 320 SR like the
        jmp mn_readthis              ;   title and has its own list (rd_pages);
                                     ;   the title is untouched and comes back
                                     ;   with one XDLA store.
?rdcl
        inc rd_pend                  ; IN-GAME READ THIS! (2026-09-15): mn_pend runs
        lda #$FF                     ;   wrote a map over it, so the mn_ing test
        rts                          ;   it used to carry could never run -- the
                                     ;   jmp went into map data and took POKEY
                                     ;   with it.
?load   lda #2                       ; M_LoadGame / M_SaveGame -> the slot picker
        bne ?slots                   ;   (always)
?save   ldx mn_ing                   ; SAVE needs a game to save: DOOM answers
        beq ?back2                   ;   "you can't save if you aren't playing"
        lda #1                       ;   (m_menu.c:1170) and this port has no
?slots  sta sg_mode                  ;   message line to answer with. LOAD is
        lda mn_sy                    ;   offered at the title, as in DOOM.
        sta mn_sysav                 ; (MainDef.lastOn, kept across the picker)
        jsr mn_wipe                  ; MainMenu[] comes off the background first
        lda #BANK_EN | SGOVL_BANK    ; ...then the OTHER overlay reads what is in
        ldx #SG_E_SCAN               ;   the six slots (the drive lives over
        jmp mn_open                  ;   there) and hands us back at MN_E_PICK
?selslot
        lda mn_sy                    ; the row IS the slot: (row - top) / 16
        sec
        sbc mn_top
        lsr
        lsr
        lsr
        lsr
        sta sg_slot                  ; (A is still the slot index)
        ldx sg_mode                  ; LOAD ON AN EMPTY SLOT IS NOT AN ACTION
        dex                          ;   (2026-08-13). 1 = SAVE: every slot is a
        beq ?slotok                  ;   valid target, empty ones especially.
        tax                          ;   2 = LOAD: sg_scan has ALREADY put $FF in
        lda sg_lvl,x                 ;   sg_lvl for every slot with no 'DM'
        bpl ?slotok                  ;   header, and mn_slotitems already draws
        jmp ?loop                    ;   those as a bare number -- the picker
                                     ;   knew and the SELECT ignored it.
?slotok lda mn_sysav                 ; itemOn back on the MainMenu[] row this
        sta mn_sy                    ;   picker was opened from -- it is a
                                     ;   PERMANENT byte, and left on the ...
        lda sg_mode                  ; 1 = SAVE, 2 = LOAD; mn_ingame hands both
        rts                          ;   to savegame.asm once the game is back
?ng     jsr mn_quiet                 ; the mixer has to be EMPTY before the
                                     ;   picker's own tail hands POKEY to SIO
        pla                          ; DROP mn_run's return address. m_menu.c's
        pla                          ;   M_NewGame does not start a game -- it
                                     ;   does M_SetupNextMenu(&EpiDef) -- and the ...
        lda #BANK_EN | EPIOVL_BANK
        ldx #0
        jmp mn_open                  ; ...which lands in ep_head
.endp

;--------------------------------------------------------------
; mn_items -- M_DrawMainMenu: the M_DOOM banner and MainMenu[]'s six lines,
;   over whatever is on screen, exactly as DOOM draws them.
;--------------------------------------------------------------
.proc mn_items
        lda #MENU_SKULLX
        sta mn_skx
        lda #MI_DOOM
        ldx #MENU_DOOMX
        ldy #MENU_DOOMY
        jsr mn_draw
        stz mn_it
?it     lda mn_it
        asl
        asl
        asl
        asl                          ; i * LINEHEIGHT (16): i < MENU_NITEMS, so
        adc #MENU_Y                  ;   the asl's shift out 0s -- no clc
        tay
        lda mn_it
        jsr mn_lumpof
        ldx #MENU_X
        jsr mn_draw
        inc mn_it
        lda mn_it
        cmp mn_n
        bcc ?it
        rts
.endp

;--------------------------------------------------------------
; mn_lumpof -- A = MainMenu[] row -> the patch that goes on it.
;   In game the six lines are DOOM's six, in order. At the TITLE there is
;--------------------------------------------------------------
.proc mn_lumpof
        ldx mn_ing
        bne ?ok
        cmp #3                       ; 3 = SAVE GAME (m_menu.c:255)
        bcc ?ok
        inc @
?ok     clc
        adc #MI_ITEM0
        rts
.endp

;--------------------------------------------------------------
; mn_pick -- the picker, entered from the save overlay once sg_lvl[] is filled.
;   It does NOT re-freeze the frame: the menu is already up and the background
;   behind it has not moved.
;--------------------------------------------------------------
.proc mn_pick
        lda #BLT_BSTENCIL            ; (the other overlay owned hb_ctrl meanwhile)
        sta hb_ctrl
                                      ; 2026-09-22 (drac030 RELOAD): A = BLT_BSTENCIL = 1
        ert BLT_BSTENCIL<>1
        sta mn_mode
        lda #SLOT_SKULLY
        sta mn_top
        sta mn_sy
        lda #SAVE_SLOTS
        sta mn_n
        jmp mn_run.mn_enter
.endp

;--------------------------------------------------------------
; mn_slotitems -- M_DrawLoad / M_DrawSave. DOOM draws its banner and then six
;   empty slot boxes with the save NAME typed into them in the small HU font.
;--------------------------------------------------------------
.proc mn_slotitems
        lda #SLOT_SKULLX
        sta mn_skx
        jsr mn_title
        jsr mn_draw
        stz mn_it
?i      jsr mn_slotrow               ; A = digit, X = col, Y = row
        jsr mn_slotdig
        ldx mn_it                    ; ...and, when the slot holds a game, the
        lda sg_lvl,x                 ;   LEVEL it holds -- E1M<n>, the one thing
        bmi ?nx                      ;   about a saved game this port can say
        jsl B1CODE_BASE+mn_sname_w1  ;   without a font ($FF = the slot is empty
?nx     inc mn_it                    ;   and stays a bare number)
        lda mn_it
        cmp #SAVE_SLOTS
        bcc ?i
        rts
.endp

;--------------------------------------------------------------
; mn_nrow -- the 7-byte row mn_sname builds for a slot's level name.
;--------------------------------------------------------------
mn_nrow dta 0, 0, 0, 0, TITLE_H, 0, -4   ; top -4 centres it on the digit

;--------------------------------------------------------------
; mn_wipeslots -- and off again, so MainMenu[] can come back under it.
;--------------------------------------------------------------
.proc mn_wipeslots
        jsr mn_erase                 ; the cursor first: it overhangs the row
        jsr mn_title
        jsr mn_wbox
        lda #SLOT_X/2-1              ; the six rows come off as ONE box: they are
        sta mb_x                     ;   a single column of digits, and six
        lda #SLOT_Y                  ;   little boxes cost bytes this overlay
        sta mb_y                     ;   does not have
        lda #SCREEN_WIDTH-SLOT_X/2   ; digit + the level name: SLOT_X-2 to the
        sta mb_w                     ;   screen's right edge (160 units)
        lda #SAVE_SLOTS*MENU_LINEH-1
        sta mb_h
        jmp mn_box
.endp

;--------------------------------------------------------------
; mn_title -- A/X/Y = the picker's banner lump and where it goes. M_LOADG and
;   M_SAVEG are MainMenu[]'s own lines: DOOM uses the same two patches for the
;   menu item and for the banner over the slot list.
;--------------------------------------------------------------
.proc mn_title
        lda sg_mode
        cmp #2
        beq ?ld
        lda #MI_ITEM0+3              ; M_SAVEG
        bne ?go                      ; (always)
?ld     lda #MI_ITEM0+2              ; M_LOADG
?go     ldx #SLOT_TITLEX
        ldy #SLOT_TITLEY
        rts
.endp

;--------------------------------------------------------------
; mn_slotrow -- slot mn_it -> A = the digit to show (1..6), X/Y = where.
;--------------------------------------------------------------
.proc mn_slotrow
        lda mn_it
        asl
        asl
        asl
        asl                          ; i * LINEHEIGHT (16): i < SAVE_SLOTS, the
        adc #SLOT_Y                  ;   asl's shift out 0s -- no clc
        tay
        lda mn_it
        inc @                        ; the slots read 1..6, not 0..5
        ldx #SLOT_X
        rts
.endp

;--------------------------------------------------------------
; mn_slotdig -- one status-bar digit. HUD_TAB has
;   the same 7-byte rows menu_tab does, so hud_entry + hud_blit place it exactly
;   the way a menu patch is placed, V_DrawPatch offsets and all.
;--------------------------------------------------------------
.proc mn_slotdig
        stx mn_x
        sty mn_y                     ; (mn_sname re-uses the row)
        clc
        adc #HUD_DIG0
        jsr hud_entry_t                ; -> zp_ptr; clobbers Y
        jmp mn_draw.go               ; ...the X/Y reload + hud_blit tail
.endp


;--------------------------------------------------------------
; mn_skdraw -- the skull cursor at the current row, current blink frame.
;--------------------------------------------------------------
.proc mn_skdraw
        lda mn_sk
        clc
        adc #MI_SKULL
        ldx mn_skx
        ldy mn_sy
        jmp mn_draw
.endp

;--------------------------------------------------------------
; mn_box -- put the mb_w+1 x mb_h+1 box (160 units across) at (mb_x, mb_y)
;   back to what the BACKGROUND has there: mn_sbox, at boot and in game.
;--------------------------------------------------------------
mn_box  = mn_sbox_t

;--------------------------------------------------------------
; mn_erase -- the skull's 10x19 box, so the cursor can move and blink without a
;   full repaint. The row is mn_sy+1 -- M_SKULL1/2 carry topoffset -1, which
;   hud_blit applies to the DRAW, so the erase has to apply it too.
;--------------------------------------------------------------
.proc mn_erase
        ldx mn_sy
        inx
        stx mb_y
        lda mn_skx                   ; the skull's 20 px from any x are 11 of
        lsr @                        ;   the box's 2-px units at most
        sta mb_x
        lda #10
        sta mb_w
        lda #18                      ; 19 rows - 1
        sta mb_h
        jmp mn_box
.endp

;--------------------------------------------------------------
; mn_wipe -- M_ClearMenu's other half: take the whole menu back off the picture.
;--------------------------------------------------------------
.proc mn_wipe
        jsr mn_erase                 ; the cursor first: it overhangs the row
        lda #MI_DOOM
        ldx #MENU_DOOMX
        ldy #MENU_DOOMY
        jsr mn_wbox
        lda #MENU_X/2-1              ; (160 units)
        sta mb_x
        lda #MENU_Y
        sta mb_y
                                      ; 2026-09-22 (drac030 RELOAD): A = MENU_Y = 64, the width the
        ert MENU_Y<>64               ;   widest MainMenu[] line (125 px) needs
        sta mb_w
        lda #MENU_NITEMS*MENU_LINEH-1
        sta mb_h
        jmp mn_box
.endp

;--------------------------------------------------------------
; mn_wbox -- A = lump, X = column, Y = row: restore that lump's rectangle out of
;   the background. mn_draw's inverse for a patch that carries no V_DrawPatch
;   offset, which every lump here but the skull does not (menu.tab).
;--------------------------------------------------------------
.proc mn_wbox
        sty mb_y
        jsr mn_tabptr                ; index * 7, exactly as mn_draw does it (A
        txa                          ;   only: X/Y ride through)
        lsr @                        ; the first 2-px unit the patch touches ...
        sta mb_x
        txa
        ldy #3
        clc
        adc (zp_ptr),y               ; ... and the last: (x + w - 1) / 2 (x + w
        dec @                        ;   < 256 for every lump that comes here)
        lsr @
        sec
        sbc mb_x
        sta mb_w
        iny
        lda (zp_ptr),y               ; height
        dec @
        sta mb_h
        jmp mn_box
.endp

;--------------------------------------------------------------
; mn_press -- C set while stick 0, TRIG0 or ANY key is active. Read straight off
;   the hardware (PIA/GTIA/POKEY) like the in-game input, so it does not care
;   what the OS is doing with the keyboard.
;--------------------------------------------------------------
.proc mn_press
        lda STICK0
        ora #$F0                     ; stick 1 is not ours
        inc @                        ; $FF = centred -> 0: inc IS the cmp #$FF
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

;--------------------------------------------------------------
; mn_anykey -- D_PageTicker's keypress, with the music ticking under it. The
;   release wait first: whatever was held while 350 KB streamed in must be let
;   go before it counts as "dismiss the title".
;--------------------------------------------------------------
.proc mn_anykey
?rel    jsr mn_vsync                 ; (mn_vsync feeds D_INTRO a frame)
        jsr mn_press
        bcs ?rel
?wait   jsr mn_vsync
        jsr mn_press
        bcc ?wait
        rts
.endp

;--------------------------------------------------------------
; mn_quiet -- spin until the mixer is empty. snd_arm sets POKMSK bit0 when a
;   sample starts and snd_disarm zeroes the byte when the last voice ends, so
;   bit0 IS "something is playing".
;--------------------------------------------------------------
.proc mn_quiet
?w      lda POKMSK_R
        lsr                          ; bit0 = Timer-1 armed -> C
        bcc ?done
        jsr mn_vsync
        bra ?w
?done   jmp snd_stop
.endp                                ;   snd_stop zeroes all four AUDCn, so no
                                     ;   note is left hanging over the load
                                     ;   (SIO owns POKEY from here).

;--------------------------------------------------------------
; mn_vsync -- one frame. The OS VBI is running at boot (main enables NMIEN
;   before menu_boot, for SIO) and urom_init's RAM vectors keep it running with
;   the ROM banked out in game, so RTCLOK3 ticks either way. The menu never
;   flips buffers.
;--------------------------------------------------------------
.proc mn_vsync
        lda RTCLOK3
?w      cmp RTCLOK3
        beq ?w
        rts
.endp

mn_x    dta 0
mn_y    dta 0
mn_i    dta 0
mn_it   dta 0                        ; mn_items' loop counter (mn_i is mn_draw's)
mn_sk   dta 0                        ; whichSkull
                                     ; (mn_sy -- itemOn -- is NOT here: every ...
mn_tic  dta 0                        ; skullAnimCounter
mn_arm2 dta 0                        ; frames the controls still rest (MN_REST)
mn_ing  = mn_ing_p                   ; 1 = the ESC panel (NEW GAME restarts the
                                     ;     game); 0 = the boot menu
mb_x    = mn_bx                      ; mn_box's rectangle -- PERMANENT bytes
mb_y    = mn_by                      ;   (PART 2b) for the same reason mn_ing is:
mb_w    = mn_bw                      ;   m_episode.asm's picker is a different
mb_h    = mn_bh                      ;   overlay in this same window and sets them
mn_mode dta 0                        ; 0 = MainMenu[], 1 = the save/load slots
mn_top  dta MENU_SKULLY              ; the skull's first row in this menu
mn_bot  dta MENU_SKULLY              ;   ... and its last (mn_run recomputes it)
mn_n    dta MENU_NITEMS              ;   ... and how many rows there are
mn_skx  dta MENU_SKULLX              ;   ... and which column it sits in
mn_ret  dta 0                        ; mn_run's answer, held across the cleanup
mn_sysav = mn_sysav_p                ; MainDef.lastOn while the slot picker owns
                                     ;   mn_sy (m_menu.c keeps one per menu);
                                     ;   permanent for the same reason

    .if * > MENU_RUN_END+1
        ert 'the menu overlay outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
        org mn_resume
