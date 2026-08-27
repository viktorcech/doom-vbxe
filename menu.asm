;==============================================================
; menu.asm -- DOOM's title screen and main menu (m_menu.c), 1:1 -- at boot AND
;             in-game on ESC (M_StartControlPanel / M_ClearMenu).
;--------------------------------------------------------------
; COSTS NO PERMANENT RAM: 53 bytes, and even those are two stubs.
;
; WHAT THE IN-GAME MENU NEEDS THAT THE BOOT MENU DID NOT. The whole thing used
; to be staged in the MAP SLOT ($4000-$4BFF) plus bsp_stack -- RAM that is dead
; until the first load_level and never again. On ESC that RAM is the LEVEL. So
; the menu proper had to move to RAM that is dead WHILE THE GAME IS PAUSED, and
; there is exactly one such block: $1000-$14FF (MENU_RUN, memory_map.inc) --
; the per-frame render arrays, the per-seg scratch and the BSP walk's stack, all
; rebuilt from nothing by the next render_world, plus the 1 KB SIO staging
; buffer, which nothing is loading into while a menu is up.
;
; So the menu is an OVERLAY. It is assembled for $1000 but LOADS at $C000
; (`org MENU_RUN, MNOVL_STAGE` -- MADS's two-address ORG), and
; tools/split_menu_ovl.py lifts that block out of the XEX and into the menu
; asset blob, so it never touches base RAM at boot at all. load_menu streams it
; into VBXE VRAM at $00E000 and mn_open copies it back down whenever the menu is
; wanted: no drive, ~1 ms, and the game's own RAM is untouched.
;
; THE GRAPHICS SPLIT THE SAME WAY (tools/pack_menu.py):
;   TITLEPIC  -> $018000, the sprite arena. Boot-only, so borrowing the pool is
;                free -- arena_init wipes it at the first load_level anyway.
;   M_DOOM, MainMenu[]'s six lines, both skulls -> $00B000, one of the FIXED
;                4 KB holes the weapon regions freed. The ESC menu draws them
;                mid-level, so they cannot live in anything a level load owns.
; The table tools/pack_menu.py emits is byte-for-byte hud.tab's layout, so
; hud_blit draws a menu patch with no new blitter at all. DOOM's main menu is
; NOT text: every line is a patch and the cursor is the two-frame skull, so no
; font is needed and the colours are 1:1 for free.
;
; THE MENU IS SINGLE-BUFFERED, and it has to be: hud_blit's destination bank is
; hardcoded to 0 (FRAME_A, memory_map.inc), which is also the buffer the XDL
; shows at boot. So menu_boot parks zback_hi on FRAME_A and nothing here calls
; swap_buffers -- a flip would put the EMPTY FRAME_B on screen. In-game
; mn_freeze does the same job the hard way: it copies whichever buffer the last
; flip left on screen into the other one, and makes sure the one on screen is
; FRAME_A. That single blit is the whole "pause" -- FRAME_A is what the menu is
; painted over, FRAME_B is the clean copy mn_erase lifts the skull's box out of,
; and neither costs a byte of VRAM that was not already a framebuffer.
;
; WHAT EACH ITEM DOES. MainMenu[] is m_menu.c:250-259 in full and in order:
; NEW GAME / OPTIONS / LOAD GAME / SAVE GAME / READ THIS! / QUIT DOOM (the
; six-item shareware+registered layout -- M_Init only drops READ THIS! for
; commercial, m_menu.c:1866-1872). NEW GAME starts E1M1: DOOM chains an episode
; and a skill menu behind it, and this port has neither those patches nor a
; skill setting to feed, so that chain is the one reduction. In-game NEW GAME is
; G_InitNew -- level 0 with a reborn player (pl_restart). QUIT DOOM cold starts
; the machine, which on this ATR boots the game again. The middle four draw
; their real DOOM line and do nothing -- their submenus do not exist, and faking
; one would be a mechanic DOOM does not have.
;==============================================================

        icl 'menu_syms.inc'          ; m_menu.c's geometry (generated)

KEY_RET  equ $0C                     ; RETURN: select, like DOOM's KEY_ENTER.
                                     ;   Up/down are '-' and '=' (KEY_MINUS /
                                     ;   KEY_EQUALS): those ARE the Atari's arrow
                                     ;   keys, and they are the view-size keys
                                     ;   in game for exactly the same reason.
                                     ;   (KEY_ESC is in memory_map.inc -- mn_key
                                     ;   needs it too.)
COLDSV   equ $E477                   ; OS cold start -- QUIT DOOM's exit

;==============================================================
; PART 1 -- the MAP-SLOT half: boot only, dead after load_level_c.
;   These two cannot be in the overlay: every loader streams through TEX_STAGE
;   ($1000-$13FF), which is where the overlay RUNS. So the loads happen from
;   here, with the overlay still in VRAM, and mn_open fetches it down in the
;   gaps between them.
;==============================================================

;--------------------------------------------------------------
; mn_ld_tab -- menu.bin's three streams: first sector, chunk count, VBXE bank.
;   The sector arithmetic is done by the packer (menu_syms.inc), so load_menu
;   is a four-store loop.
;--------------------------------------------------------------
mnld_resume = *
        org MNLDTAB_BASE             ; ...and it does not live in the staging
mn_ld_tab                            ;   block: see MNLDTAB_BASE in
        dta a(MENU_SEC1), MENU_TCHUNKS, MENU_TBANK
        dta a(MENU_SEC1 + MENU_TCHUNKS*32), MENU_PCHUNKS, MENU_PBANK
        dta a(MENU_SEC1 + [MENU_TCHUNKS+MENU_PCHUNKS]*32), MENU_OCHUNKS, MENU_OBANK
        dta a(MENU_SEC1 + MENU_ACHUNK*32), 1, AMOVL_BANK
                                     ; the AUTOMAP overlay needs a row of its
                                     ; own: load_vram walks CONSECUTIVE banks and
                                     ; the one after the savegame overlay's $0F
                                     ; is FRAME_B. See AMOVL_BANK in
                                     ; memory_map.inc for where it does go.
        dta a(MENU_SEC1 + MENU_WICH*32), MENU_WICHUNKS, WI_BANK
                                     ; the INTERMISSION (wi.asm): pixels, then
                                     ; the 7-byte rows, then its code overlay --
                                     ; three things in ONE consecutive bank run,
                                     ; because that is what this table has room
                                     ; for (MNLDTAB_BASE..END is one row from
                                     ; full). pack_wi.py lays them out that way
                                     ; on purpose.
        dta a(MENU_SEC1 + MENU_LVCH*32), MENU_LVCHUNKS, MENU_LVBANK
                                     ; ...and one for the automap's LEVEL TITLES
                                     ; (hu_stuff.c HU_TITLE, drawn by am_title).
                                     ; They are map-independent, so they ride the
                                     ; boot stream and land in the free VRAM at
                                     ; $040000 -- NOT $018000, which is the level
                                     ; asset pool and gone the moment a level
                                     ; streams in.
MN_LD_N equ * - mn_ld_tab
    .if * > MNLDTAB_END+1
        ert 'mn_ld_tab outgrew MNLDTAB_BASE..END (memory_map.inc)'
    .endif
        org mnld_resume              ;   memory_map.inc for why it moved

;--------------------------------------------------------------
; load_menu -- stream the title, the patches and the code overlay into VRAM.
;   Mirrors load_hud exactly; must run with the OS VBI on and IRQs enabled
;   (SIOV), i.e. inside the same window load_level_c uses.
;--------------------------------------------------------------
.proc load_menu
        ldx #0
?l      stx mn_li
        lda mn_ld_tab,x
        sta ll_sec
        lda mn_ld_tab+1,x
        sta ll_sec+1
        lda mn_ld_tab+2,x
        sta ld_chunks
        lda mn_ld_tab+3,x
        sta ld_bank0
        jsr load_vram
        lda mn_li
        clc
        adc #4
        tax
        cpx #MN_LD_N
        bcc ?l
        rts
.endp
mn_li   dta 0

;--------------------------------------------------------------
; mn_readthis -- M_ReadThis (m_menu.c:1030), the registered-WAD flow: HELP1,
;   a key, HELP2, a key, back to the menu (M_FinishReadThis). The pages are
;   streamed into TITLEPIC's own arena slot -- same 320x200, so the title's
;   blit geometry shows them -- and TITLEPIC is streamed back afterwards.
;   Lives in the MAP-SLOT half with the other boot loaders: every stream runs
;   through TEX_STAGE, which is ALSO the RAM the menu overlay runs in, so this
;   cannot be overlay code. That makes it BOOT-ONLY in the hard sense -- at
;   $4A5C, which load_level_c writes a map over -- so the "in-game READ THIS!
;   just closes the menu" answer is `?read`'s (overlay, always resident) and
;   NOT this routine's. It used to be here, four bytes that in-game were map
;   data, and the jmp that reached them took the screen and POKEY with it
;   (2026-08-21).
;   When the pages are done it re-opens the overlay at MN_E_BOOT (title up,
;   key, menu) and DROPS mn_run's return address on the way, exactly as ?ng
;   does: `?read` got here by jmp, so that frame is this routine's, and
;   mn_open(MN_E_BOOT) restarts mn_boot from the top with a `jsr mn_run` frame
;   of its own. Leaving the old one parked is what made the NEXT New Game die
;   in m_episode's depth-dependent `?boot rts` (2026-08-21).
;--------------------------------------------------------------
.proc mn_readthis                    ; BOOT ONLY -- ?read is what tests mn_ing
        jsr mn_quiet                 ; the select SFX must be OFF the mixer
                                     ;   before SIO takes POKEY (the overlay is
                                     ;   still resident here), or the tone it
                                     ;   was mid-way through sticks and squeals
                                     ;   for the whole read -- same rule as ?ng
        lda #0                       ; HELP1: stream, show, wait for a key
        jsr ?page
        lda #2                       ; HELP2
        jsr ?page
        lda #4                       ; the credits page (DOOM VBXE / AUTHOR: W1K
        jsr ?page                    ;   / AI CODE / 2026 / V0.n / build stamp
                                     ;   -- pack_menu.py)
        lda #6                       ; TITLEPIC back into the arena slot...
        jsr ?stream
        jsr ?show                    ; ...and back ONTO THE SCREEN: MN_E_BOOT
                                     ;   assumes the title is already up, and
                                     ;   without this the menu came up over the
                                     ;   stale HELP2 and every wipe uncovered
                                     ;   title patches (menu2/menu3.png ghosts)
        jsr snd_pokey                ; SIO owned POKEY through the streams: put
                                     ;   the mixer back (AUDCTL 0, voices idle,
                                     ;   Timer-1 rate), like main does after
                                     ;   its loaders
        pla                          ; DROP mn_run's return address, exactly as
        pla                          ;   ?ng does and for exactly its reason:
                                     ;   `?read` got here by JMP, so that frame
                                     ;   is ours, and mn_open(MN_E_BOOT) below
                                     ;   restarts mn_boot FROM THE TOP -- which
                                     ;   pushes a `jsr mn_run` frame of its own.
                                     ;   Without this the old one is left parked
                                     ;   and the NEXT New Game dies on it: ?ng
                                     ;   drops one frame, and m_episode's
                                     ;   depth-dependent `?boot rts` then lands
                                     ;   on mn_boot's ?again ($10E3) instead of
                                     ;   menu_boot's `jsr mn_open` -- an address
                                     ;   the picker's own overlay now occupies,
                                     ;   where $10E8 is a DB and the 65816 STOPS.
        lda #BANK_EN | MENU_OBANK    ; the streams ate the overlay (TEX_STAGE):
        ldx #MN_E_BOOT               ;   copy it back and re-enter over the
        jmp mn_open                  ;   restored title
?page   jsr ?stream
        jsr ?show
?up     lda SKSTAT                   ; D_PageTicker's keypress, minimal: wait
        and #4                       ;   for the advancing key to come UP, then
        beq ?up                      ;   for the next press. The boot menu is
?dn     lda SKSTAT                   ;   silent, so there is no music to tick
        and #4                       ;   under the wait (mn_anykey's job).
        bne ?dn
        rts
?show   lda #BLT_COPY                ; the pages are OPAQUE, like the title
        sta hb_ctrl
        lda #<rd_tab                 ; a private tab row: menu_tab is overlay
        sta zp_ptr                   ;   RAM and the stream just ate it
        lda #>rd_tab
        sta zp_ptr+1
        ldx #0
        ldy #0
        jsr hud_blit
        lda #BLT_BSTENCIL
        sta hb_ctrl
        jmp blitter_wait
?stream tax                          ; A = rd_secs index: 0/2/4 = HELP1/2/title
        lda rd_secs,x
        sta ll_sec
        lda rd_secs+1,x
        sta ll_sec+1
        lda #MENU_HCHUNKS            ; every page is title-sized (8 chunks)
        sta ld_chunks
        lda #MENU_TBANK              ; ...and lands in the title's VBXE bank
        sta ld_bank0
        jmp load_vram
.endp
rd_secs dta a(MENU_SEC1 + MENU_HELP_CH*32)
        dta a(MENU_SEC1 + [MENU_HELP_CH+MENU_HCHUNKS]*32)
        dta a(MENU_SEC1 + [MENU_HELP_CH+2*MENU_HCHUNKS]*32)
        dta a(MENU_SEC1)
rd_tab  dta a(MENU_VRAM & $FFFF)     ; the title blit's 7-byte tab row (vram24,
        dta [MENU_VRAM >> 16] & $FF  ;   w, h, left, top), private main-RAM copy
        dta 160, 200, 0, 0           ; 160 BYTES a row (one per halved pixel)

;--------------------------------------------------------------
; menu_boot -- what boot calls INSTEAD of load_level_c. Everything here has to
;   happen before that load: it overwrites the map slot this code is staged in
;   and the VRAM the title picture is in. Replacing the existing call rather
;   than adding one is deliberate -- the $2000 engine segment has no spare bytes
;   at all, and check_xex fails the build over six of them.
;--------------------------------------------------------------
.proc menu_boot
        lda #0
        sta sg_pend                  ; ...and no deferred LOAD until one is picked
        sta SOUNDR_R                 ; the OS's "noisy I/O" beeping, off: from
                                     ;   here on there is a picture on screen
                                     ;   and every load is behind it
        lda #1
        sta mn_arm                   ; mn_key's ESC edge, and the skull's row:
        lda #MENU_SKULLY             ;   both are permanent bytes the engine
        sta mn_sy                    ;   never writes otherwise, so random RAM
                                     ;   would eat the first ESC of the session
                                     ;   and put the cursor nowhere. mn_sy is
                                     ;   itemOn = currentMenu->lastOn from here
                                     ;   on (m_menu.c:1546).
        jsr load_menu
        jsr load_palette             ; PLAYPAL -> the VBXE palettes. Without this the
                                     ;   title is BLACK: TITLEPIC is palette INDICES
                                     ;   and boot does not install a palette until
                                     ;   after the first level (bsp_main's load_palette
                                     ;   "MUST STAY LAST" among the level loaders).
                                     ;   It reads its own ATR region (PAL_SEC1), so it
                                     ;   needs no level, and running it twice is free.
        lda #0
        sta zback_hi                 ; paint AND show FRAME_A (see the header)
        lda #BANK_EN | MENU_OBANK
        ldx #MN_E_TITLE
        jsr mn_open                  ; the picture goes up on 41 KB of SIO...
        jsr load_sounds              ; ... and the other 310 KB stream in BEHIND
                                     ;   it: the digi SFX, the weapon psprites
                                     ;   and the songs (load_sounds tail-calls
                                     ;   load_weapons, which tail-calls
                                     ;   load_music). main used to do this
                                     ;   before the menu, which meant a black
                                     ;   screen for the whole wait.
                                     ;   It also streams through TEX_STAGE, so
                                     ;   the overlay is gone by the time it
                                     ;   returns -- hence the second mn_open.
        jsr snd_init                 ; the mixer, now that its samples are in
                                     ; (NO MUSIC HERE. DOOM starts mus_intro
                                     ;  with TITLEPIC, and it was wired up and
                                     ;  working -- D_INTRO as song 9, ticked by
                                     ;  mn_vsync -- but the RMT conversion of
                                     ;  that particular piece sounds wrong, so
                                     ;  the menu is silent apart from its own
                                     ;  SFX. tools/pack_musstream.py takes the
                                     ;  song name on the command line if it is
                                     ;  ever worth another try.)
        lda #BANK_EN | MENU_OBANK    ; NOW the title is dismissable, and the
        ldx #MN_E_BOOT               ;   menu comes up behind the keypress
        jsr mn_open
        jmp load_level_c
.endp

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
;   Splitting the copy this way is not tidiness -- a full five-page copier does
;   not fit in the RAM this port has left, and one page does.
;   X survives (the loop is Y-indexed), which is how the entry index gets in.
;   The bank is a PARAMETER because there are two overlays in the same window:
;   menu.asm's and savegame.asm's (memory_map.inc).
;--------------------------------------------------------------
        org MNOPEN_BASE
.proc mn_open
        sta VBXE_BANK_SEL
        ldy #0
?by     lda MEMW,y
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
;   read_keys already samples POKEY twice a frame for the cheat sniffer and
;   says why; this is the third read on the same cold path, and it buys the
;   menu its own edge state instead of threading ESC through read_keys' toggle
;   scan, which has not one spare byte.
;   The edge is one byte: a press acts once and nothing re-arms it until every
;   key is up, so the ESC that OPENS the menu cannot also be the ESC that
;   closes it -- and the release-wait on the way out (mn_ingame) cannot let the
;   held key re-open it either.
;   read_keys is skipped while the player is dead, so ESC is too: a corpse gets
;   the restart-on-any-key prompt instead, which is the screen he is looking at.
;--------------------------------------------------------------
        org MNKEY_BASE
.proc mn_key
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        bne ?up
        lda KBCODE
        and #$3F                     ; bare code (no shift/ctrl)
        cmp #KEY_ESC
        bne ?ret
        lda mn_arm                   ; acts once, then stays disarmed for as long
        beq ?ret                     ;   as ESC is held -- NOT `dec/bne`, which
        lda ZFRONT                   ;   comes back round to zero after 255 held
        bne ?ret                     ;   frames and re-opens the menu by itself.
                                     ; ZFRONT gate (2026-08-11 triple buffer):
                                     ;   open only with FRAME_A on screen (<= 2
                                     ;   frames away; ESC outlives them at this
                                     ;   frame rate) -- mn_freeze's zback^1 math
                                     ;   and mn_box's bank-1 pristine copy both
                                     ;   assume A is the one being shown. The
                                     ;   gate also leaves A = 0 for the disarm:
        sta mn_arm
        lda #BANK_EN | MENU_OBANK
        ldx #MN_E_INGAME
        jmp mn_open                  ; ... which lands in mn_ingame, whose rts
                                     ;   goes straight to read_keys' caller.
                                     ;   vw_frame is skipped for that one frame:
                                     ;   the border repaint is a countdown, and
                                     ;   mn_ingame re-arms it anyway.
?up     lda #1
        sta mn_arm
?ret    jmp am_key                   ; TAB = the automap (automap.asm), which
                                     ;   tail-calls fps_key -- the 'F' FPS
                                     ;   toggle still rides this tail (hud.asm).
                                     ;   am_key reads A, not KBCODE: see its
                                     ;   header for the four values that reach
                                     ;   here and why only TAB can be $2C
                                     ; ... then on to the deferred title LOAD,
.endp                                ;     which tail-calls vw_frame
    .if * > MNKEY_END+1
        ert 'mn_key outgrew MNKEY_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mn_pend -- a LOAD GAME picked at the TITLE, fired on the first frame of the
;   game that came up behind it. It cannot happen any earlier: menu_boot's
;   caller still has load_things to run, and that resets THING_ALIVE and
;   re-streams the things blob -- straight over a restored save. By here the
;   boot chain is finished and savegame.asm's own reload can take over.
;   The cost of doing it this way is one wasted level load at boot, which is
;   the same load the player would have sat through anyway.
;--------------------------------------------------------------
        org MNPEND_BASE
.proc mn_pend
        lda sg_pend
        beq ?no
        lda #0
        sta sg_pend
        lda #BANK_EN | SGOVL_BANK
        ldx #SG_E_LOAD
        jmp mn_open
?no     jmp vw_frame                 ; read_keys' own tail call, unchanged
.endp
    .if * > MNPEND_END+1
        ert 'mn_pend outgrew MNPEND_BASE..END (memory_map.inc)'
    .endif

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
.proc mn_head
        ldy #0
?p      lda MEMW+$100,y
        sta MENU_RUN+$100,y
        lda MEMW+$200,y
        sta MENU_RUN+$200,y
        lda MEMW+$300,y
        sta MENU_RUN+$300,y
        lda MEMW+$400,y
        sta MENU_RUN+$400,y
        iny
        bne ?p
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
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
;   7-byte menu_tab row and lets hud_blit do the work.
;--------------------------------------------------------------
.proc mn_draw
        stx mn_x
        sty mn_y
        jsr mn_tabptr
go      ldx mn_x                     ; (mn_slotdig comes in here with zp_ptr
        ldy mn_y                     ;  already on its HUD_TAB row)
        jmp hud_blit
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
        sbc mn_i                     ; ...-1 = *7
        clc
        adc #<menu_tab
        sta zp_ptr
        lda #>menu_tab
        adc #0
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; show_title -- TITLEPIC, and the display switched on. DOOM shows the title on a
;   timer or a keypress (d_main.c D_PageTicker); the keypress alone is the
;   reduction, and it is mn_boot that waits for it -- the loads go in between.
;   Switching the DISPLAY on belongs HERE, once the picture is actually in VRAM:
;   main used to do it only after every loader had run, so the title was drawn
;   into a framebuffer nobody was looking at yet -- that, not the palette, is
;   why the first cut of this menu was a black screen in a key-wait loop.
;--------------------------------------------------------------
.proc show_title
        lda #BLT_COPY                ; the title is OPAQUE: index 0 is a real
        sta hb_ctrl                  ;   colour in TITLEPIC, and the stencil the
        lda #MI_TITLEPIC             ;   patches use would punch boot garbage
        ldx #0                       ;   through it
        ldy #0
        jsr mn_draw
        lda #BLT_BSTENCIL            ; back to V_DrawPatch behaviour for the menu
        sta hb_ctrl
        jsr blitter_wait             ; the blit is async -- do not show a half-
                                     ;   painted title
;--------------------------------------------------------------
; mn_vbxe_on -- switch the overlay on. (Falls out of show_title; main no longer
;   does this at all, which gave the $2000 segment 18 bytes back.)
;--------------------------------------------------------------
        lda #VC_XDL_ON | VC_NO_TRANS
        sta VBXE_VCTL
        lda #<VRAM_XDL_A             ; list A -- it reads FRAME_A, which is what
        sta VBXE_XDLA0               ;   the menu paints and never flips off
        lda #>VRAM_XDL_A             ;   (swap_buffers rewrites XDLA1 alone)
        sta VBXE_XDLA1
        lda #[VRAM_XDL_A>>16]
        sta VBXE_XDLA2
        rts
.endp

;--------------------------------------------------------------
; mn_boot -- the boot entry: dismiss the title, then the menu, over TITLEPIC.
;--------------------------------------------------------------
.proc mn_boot
        lda #0
        sta mn_ing                   ; boot: NEW GAME just returns (menu_boot
                                     ;   does the loading), and the skull's
        lda #>[MENU_VRAM & $FFFF]    ;   background -- what ESC uncovers and what
        sta mn_bgh                   ;   the cursor blinks over -- is TITLEPIC
        jsr mn_anykey                ; (mn_arm and mn_sy are seeded by menu_boot:
                                     ;  they are PERMANENT bytes, so their init
                                     ;  belongs outside the overlay -- which is
                                     ;  nine bytes from its ceiling)
?again  jsr mn_run
        beq ?go                      ; NEW GAME -> menu_boot loads the level
        cmp #2                       ; LOAD -> let the boot chain finish first
        bne ?wipe                    ;   and fire it on the first frame (mn_pend)
        sta sg_pend
        jsr mn_quiet                 ; SAME RULE AS ?ng AND mn_readthis, and the
                                     ;   one path that never got it (2026-08-13):
                                     ;   our caller's tail is `jmp load_level_c`,
                                     ;   so POKEY goes to SIO from here -- and
                                     ;   ?sel has just played SFX_PISTOL. A 3959
                                     ;   Hz Timer-1 IRQ across the transfer does
                                     ;   not just squeal: read_sectors takes any
                                     ;   sector whose SIO status is not 1 and
                                     ;   SKIPS it (`cpy #1 / bne ?adv` -- no
                                     ;   retry), so the level came up with random
                                     ;   holes in it, different every boot, or
                                     ;   sat in the transfer for good (load.png,
                                     ;   PC parked in read_sectors' ?tee).
        lda #0
        rts
?wipe   jsr mn_wipe                  ; ESC -> M_ClearMenu: the menu comes off and
        jsr mn_anykey                ;   TITLEPIC is on its own again, until the
        jmp ?again                   ;   next key brings the menu back
?go     rts
.endp

;--------------------------------------------------------------
; mn_ingame -- ESC during play: M_StartControlPanel over the frozen frame.
;   DOOM freezes single player while the menu is up (P_Ticker returns early on
;   menuactive) and draws the menu straight over the view, so that is what this
;   does: one blit to make the last rendered frame stand still, the same
;   mn_run the boot menu uses, and the game picks up where it stopped.
;   Returns to read_keys' caller with the frame loop's invariants restored.
;--------------------------------------------------------------
.proc mn_ingame
        lda #1
        sta mn_ing
        lda #0
        sta mn_bgh                   ; the skull's background is FRAME_B, the
                                     ;   clean copy mn_freeze just made
        jsr mn_freeze
        jsr mn_run                   ; $FF = just closed, 1 = SAVE, 2 = LOAD.
        sta mn_ret                   ;   (in-game NEW GAME tail-jumps out of the
                                     ;    overlay and QUIT never returns at all)
        lda RTCLOK3                  ; (no release-wait: mn_key will not re-arm
                                     ;  its ESC edge until every key is up)                  ; PollControls: the paused jiffies are not
        sta fps_last                 ;   door/lift/timer time (WL_PLAY.C:813 does
                                     ;   the same thing for the same reason)
        jsr vw_apply                 ; THE ONE THING THE OVERLAY BREAKS. $1000 is
                                     ;   solid_arr, and the border columns outside
                                     ;   the view window are marked solid ONCE, by
                                     ;   vw_apply -- "nothing in the frame path
                                     ;   ever writes solid_arr outside
                                     ;   [vw_x0,vw_x1]" (viewsize.asm). Running
                                     ;   the menu on top of that array wipes the
                                     ;   marks, and the next BSP walk would draw
                                     ;   straight through the border. vw_apply
                                     ;   re-marks them AND sets vw_dirty = 2,
                                     ;   which is the border repaint (into both
                                     ;   buffers) the menu needs anyway.
                                     ;   Everything else down there is per-frame
                                     ;   scratch or a cache whose key mn_head's
                                     ;   zeros can only make MISS: tw_lastsrc 0
                                     ;   matches no real column. (tw_lastdscr
                                     ;   was the other one; it went with the
                                     ;   dscr memo on 2026-08-14.)
        lda #1
        sta zback_hi                 ; FRAME_A is on screen and carries the menu;
                                     ;   render the next frame into FRAME_B, and
                                     ;   FRAME_A is repainted whole before it is
                                     ;   ever shown again
        ; --- and only NOW, with the game's own invariants back, hand a picked
        ;     slot to savegame.asm. It is the OTHER overlay in this window, so
        ;     this has to be a TAIL jump: the moment mn_open runs, everything
        ;     here is overwritten. DOOM closes the menu on both (M_DoSave /
        ;     M_DoLoad both call M_ClearMenu), which is exactly what returning
        ;     from savegame.asm does. ---
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
; mn_freeze -- the pause, in one blit. hud_blit only ever writes bank 0, so the
;   menu can only be painted into FRAME_A, and FRAME_A has to be the buffer on
;   screen. Copy whichever buffer the last flip left showing into the other one
;   and put list A up: after this FRAME_A is the frozen picture the menu paints
;   over and FRAME_B is the untouched copy mn_erase restores the cursor box
;   from. No extra VRAM -- the second framebuffer IS the backing store.
;--------------------------------------------------------------
.proc mn_freeze
        lda zback_hi                 ; the BACK buffer; the other one is shown
        eor #1
        sta mn_fsrc
        eor #1
        sta mn_fdst
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR      ; both buffers start at row 0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        sta MEMW+MEMW_HD_OFF+BCB_CTRL          ; BLT_COPY: opaque, whole frame
        lda mn_fsrc
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda mn_fdst
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #SCREEN_WIDTH-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #VIEW_HEIGHT-1           ; rows 0..167 -- the status bar is SHARED
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT        ;   (bank 0) and needs no copy
        jsr hud_blit.hud_fire        ; hud_blit's own "wait, then start" tail
        jsr blitter_wait             ; ...and this one is 26 KB: let it finish
        lda #>VRAM_XDL_A             ; show FRAME_A (a no-op when it already is)
        sta VBXE_XDLA1
        rts
.endp

;--------------------------------------------------------------
; mn_run -- M_DrawMainMenu + M_Responder, for MainMenu[] only. Returns 0 when
;   the menu is done with (NEW GAME at boot, or ESC in-game) and 1 for in-game
;   NEW GAME; QUIT DOOM never returns.
;   itemOn is kept AS the skull's row (mn_sy) rather than as an index: every
;   user of it here wants the row, and the two ends of the list are two
;   comparisons either way.
;--------------------------------------------------------------
MN_SYLAST equ MENU_SKULLY + (MENU_NITEMS-1)*MENU_LINEH
; LoadDef/SaveDef = { ..., 80, 54 } and M_DrawLoad puts its banner at (72,28)
; (m_menu.c:1218/1263). x halved like everything else the port draws.
SLOT_X      equ 40                   ; LoadDef.x 80 halved
SLOT_Y      equ 54                   ; LoadDef.y
SLOT_SKULLX equ 24                   ; x + SKULLXOFF, halved
SLOT_SKULLY equ 49                   ; y - 5
SLOT_TITLEX equ 36                   ; M_LOADG / M_SAVEG at (72,28)
SLOT_TITLEY equ 28

.proc mn_run
        lda #BLT_BSTENCIL            ; V_DrawPatch: the patches are transparent.
        sta hb_ctrl                  ;   In-game whatever drew last owns hb_ctrl,
                                     ;   and BLT_COPY would make every menu line
                                     ;   an opaque block. This is also the value
                                     ;   the HUD wants at rest, so nothing has to
                                     ;   put it back.
        lda #0
        sta mn_mode                  ; MainMenu[] first, always
        lda #MENU_SKULLY
        sta mn_top
        lda #MENU_NITEMS             ; ...and how long the list is: at the title
        ldx mn_ing                   ;   SAVE GAME is not on it at all (see
        bne ?six                     ;   mn_lumpof)
        lda #MENU_NITEMS-1
?six    sta mn_n
mn_enter lda mn_n                    ; mn_bot = the LAST row (top + (n-1)*16)
        sec
        sbc #1
        asl
        asl
        asl
        asl
        clc
        adc mn_top
        sta mn_bot
        lda mn_mode                  ; the drawer for whichever menu this is
        beq ?dmain
        jsr mn_slotitems
        jmp ?drawn
?dmain  jsr mn_items
?drawn  ldx #SFX_SWTCHN              ; M_StartControlPanel's own sound: the menu
        jsr snd_play                 ;   opening IS a switch throw (m_menu.c:1545)
        lda #0
        sta mn_sk
        sta mn_arm2                  ; the key that opened the menu has to be
                                     ;   released before it can pick an item too
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
        lda #1
        sta mn_arm2                  ; everything released -> arm the next press
?back   jmp ?loop
?act    lda mn_arm2
        beq ?back                    ; still held: one press = one action
        lda #0
        sta mn_arm2
        lda TRIG0
        lsr
        bcs ?ntrig                   ; (?sel is out of branch range from here
        jmp ?sel                     ;  now that the slot picker is in the
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
        jsr snd_play
        jmp ?loop
?back2  jmp ?loop                    ; ?back is out of branch range from down here
                                     ;   now that ESC is in the key scan
?esc    ldx #SFX_SWTCHX              ; M_ClearMenu, and the panel closing is the
        jsr snd_play                 ;   switch coming back (m_menu.c:1710)
        lda mn_mode
        beq ?escout
        jsr mn_wipeslots             ; the picker backs out to MainMenu[] first
        lda mn_sysav                 ;   (M_Responder's KEY_ESCAPE pops ONE menu)
        sta mn_sy                    ; ...and mn_run's own head puts the list
        jmp mn_run                   ;    back: mode, first row, count
?escout lda #$FF                     ; ...and the caller puts back whatever the
        rts                          ;   menu was covering
?sel    ldx #SFX_PISTOL              ; KEY_ENTER on a plain item (m_menu.c:1675)
        jsr snd_play
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
        lda #BANK_EN | SGOVL_BANK    ; quitdoom -- the body is in the OTHER
        ldx #SG_E_QUIT               ;   overlay (savegame.asm) because this one
        jmp mn_open                  ;   has no room, and QUIT never comes back
?read   lda mn_ing                   ; IN-GAME mn_readthis IS NOT THERE. It is
        bne ?rdcl                    ;   staged in the map slot ($4A5C) with the
        jmp mn_readthis              ;   other boot loaders and load_level_c
?rdcl   lda #$FF                     ;   wrote a map over it, so the mn_ing test
        rts                          ;   it used to carry could never run -- the
                                     ;   jmp went into map data and took POKEY
                                     ;   with it. Overlay code is always
                                     ;   resident, so the test belongs HERE.
                                     ;   $FF = "menu closed", what ?closed used
                                     ;   to answer through this same frame.
                                     ; (boot: main RAM, because the page streams
                                     ;   would eat THIS code)
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
                                     ;   knew and the SELECT ignored it. Taking
                                     ;   one used to cost a whole level load
                                     ;   before anything checked: mn_boot only
                                     ;   parks sg_pend, menu_boot's tail streams
                                     ;   E1M1 regardless, and sg_load's magic
                                     ;   test does not run until mn_pend fires a
                                     ;   frame later -- so "load an empty slot"
                                     ;   sat the player through the whole load
                                     ;   and dropped him on E1M1. Now the RETURN
                                     ;   just does not take, which is what the
                                     ;   skull sitting on an empty row means.
?slotok lda mn_sysav                 ; itemOn back on the MainMenu[] row this
        sta mn_sy                    ;   picker was opened from -- it is a
                                     ;   PERMANENT byte, and left on the
                                     ;   picker's 49+16i grid it matches none of
                                     ;   the row compares in this dispatch: the
                                     ;   next menu drew its skull off-grid and
                                     ;   then ignored every RETURN
        lda sg_mode                  ; 1 = SAVE, 2 = LOAD; mn_ingame hands both
        rts                          ;   to savegame.asm once the game is back
?ng     jsr mn_quiet                 ; the mixer has to be EMPTY before the
                                     ;   picker's own tail hands POKEY to SIO
        pla                          ; DROP mn_run's return address. m_menu.c's
        pla                          ;   M_NewGame does not start a game -- it
                                     ;   does M_SetupNextMenu(&EpiDef) -- and the
                                     ;   episode picker is an overlay of its own,
                                     ;   so the moment mn_open runs, mn_run and
                                     ;   everything else in this window is gone
                                     ;   and its frame can never be returned
                                     ;   through. What is left underneath is
                                     ;   exactly what mn_run's CALLER had, which
                                     ;   is what m_episode.asm rts-es to at boot.
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
        lda #0
        sta mn_it
?it     lda mn_it
        asl
        asl
        asl
        asl                          ; i * LINEHEIGHT (16)
        clc
        adc #MENU_Y
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
;   nothing to save, so SAVE GAME is dropped and everything below it moves up --
;   which is DOOM's own way of shortening this menu: M_Init does exactly this to
;   READ THIS! for the commercial build (m_menu.c:1866-1872), copying the later
;   entry over the dropped one and decrementing the count.
;--------------------------------------------------------------
.proc mn_lumpof
        ldx mn_ing
        bne ?ok
        cmp #3                       ; 3 = SAVE GAME (m_menu.c:255)
        bcc ?ok
        clc
        adc #1
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
        lda #1
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
;   This port has no font (the whole menu is patches), so the slot is drawn as
;   its NUMBER, out of the status bar's own digits -- which are already in VRAM,
;   already the right red, and cost no new asset at all. The mechanic is DOOM's:
;   six slots, pick one with the skull.
;--------------------------------------------------------------
.proc mn_slotitems
        lda #SLOT_SKULLX
        sta mn_skx
        jsr mn_title
        jsr mn_draw
        lda #0
        sta mn_it
?i      jsr mn_slotrow               ; A = digit, X = col, Y = row
        jsr mn_slotdig
        ldx mn_it                    ; ...and, when the slot holds a game, the
        lda sg_lvl,x                 ;   LEVEL it holds -- E1M<n>, the one thing
        bmi ?nx                      ;   about a saved game this port can say
        clc                          ;   without a font ($FF = the slot is empty
        adc #1                       ;   and stays a bare number)
        jsr mn_slotrow2
        jsr mn_slotdig
?nx     inc mn_it
        lda mn_it
        cmp #SAVE_SLOTS
        bcc ?i
        rts
.endp

;--------------------------------------------------------------
; mn_slotrow2 -- as mn_slotrow, but the SECOND column of the row (A survives).
;--------------------------------------------------------------
.proc mn_slotrow2
        pha
        jsr mn_slotrow
        pla
        ldx #SLOT_X+10
        rts
.endp

;--------------------------------------------------------------
; mn_wipeslots -- and off again, so MainMenu[] can come back under it.
;--------------------------------------------------------------
.proc mn_wipeslots
        jsr mn_erase                 ; the cursor first: it overhangs the row
        jsr mn_title
        jsr mn_wbox
        lda #SLOT_X-1                ; the six rows come off as ONE box: they are
        sta mb_x                     ;   a single column of digits, and six
        lda #SLOT_Y                  ;   little boxes cost bytes this overlay
        sta mb_y                     ;   does not have
        lda #21
        sta mb_w
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
        asl                          ; i * LINEHEIGHT (16)
        clc
        adc #SLOT_Y
        tay
        lda mn_it
        clc
        adc #1                       ; the slots read 1..6, not 0..5
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
        sty mn_y
        clc
        adc #HUD_DIG0
        jsr hud_entry                ; -> zp_ptr; clobbers Y
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
; mn_box -- put the mb_w+1 x mb_h+1 box at (mb_x, mb_y) back to what the
;   BACKGROUND has there. Same BCB as hud_blit, but the SOURCE is the background
;   at the SAME screen coordinates (mn_bgh:row*160 + x), which is what makes
;   this a background restore rather than a black box: the menu is drawn OVER
;   the picture, as in DOOM.
;   mn_bgh is the only thing that differs between the two menus -- $80 puts the
;   source in TITLEPIC ($018000) at boot, 0 puts it in FRAME_B ($010000)
;   in-game. Both are bank $01, which is why one byte covers it.
;--------------------------------------------------------------
.proc mn_box
        ldx mb_y
        lda row_lo,x
        clc
        adc mb_x
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
        lda mb_w
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda mb_h
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        jmp hud_blit.hud_fire        ; hud_blit's own "wait, then start" tail
.endp

;--------------------------------------------------------------
; mn_erase -- the skull's 10x19 box, so the cursor can move and blink without a
;   full repaint. The row is mn_sy+1 -- M_SKULL1/2 carry topoffset -1, which
;   hud_blit applies to the DRAW, so the erase has to apply it too.
;--------------------------------------------------------------
.proc mn_erase
        ldx mn_sy
        inx
        stx mb_y
        lda mn_skx
        sta mb_x
        lda #9                       ; 10 bytes wide - 1
        sta mb_w
        lda #18                      ; 19 rows - 1
        sta mb_h
        jmp mn_box
.endp

;--------------------------------------------------------------
; mn_wipe -- M_ClearMenu's other half: take the whole menu back off the picture.
;   Only the title menu needs it (the ESC panel's background is the frozen
;   frame, which the game repaints whole on the next tic anyway). The banner
;   comes off as its own patch-shaped box; the LINES come off as one tall box
;   over the whole column -- six little ones cost bytes this overlay has not
;   got, and the background restore is the same picture either way.
;--------------------------------------------------------------
.proc mn_wipe
        jsr mn_erase                 ; the cursor first: it overhangs the row
        lda #MI_DOOM
        ldx #MENU_DOOMX
        ldy #MENU_DOOMY
        jsr mn_wbox
        lda #MENU_X-1
        sta mb_x
        lda #MENU_Y
        sta mb_y
        lda #64                      ; the widest MainMenu[] line is 63 bytes
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
        stx mb_x
        sty mb_y
        jsr mn_tabptr                ; index * 7, exactly as mn_draw does it
        ldy #3
        lda (zp_ptr),y               ; width
        sec
        sbc #1
        sta mb_w
        iny
        lda (zp_ptr),y               ; height
        sec
        sbc #1
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
;   bit0 IS "something is playing". It must be 0 before either caller reaches
;   the loaders: SIO takes POKEY over whole -- serial bits in AUDCTL, channels
;   3/4, the lot -- and a 3959 Hz Timer-1 IRQ running across a transfer is the
;   2026-08-04 squeal at best. DOOM gets this for free (the pistol shot plays
;   while the level loads); here the two share one chip.
;--------------------------------------------------------------
.proc mn_quiet
?w      lda POKMSK_R
        lsr                          ; bit0 = Timer-1 armed -> C
        bcc ?done
        jsr mn_vsync
        jmp ?w
?done   jmp snd_stop                 ; ... and the MUSIC's channels with it:
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
                                     ; (mn_sy -- itemOn -- is NOT here: every
                                     ;  mn_open reloads this page from VRAM, so a
                                     ;  variable that has to survive one lives in
                                     ;  memory_map.inc's permanent byte instead)
mn_tic  dta 0                        ; skullAnimCounter
mn_arm2 dta 0                        ; 0 = a control is still held from last time
mn_ing  = mn_ing_p                   ; 1 = the ESC panel (NEW GAME restarts the
                                     ;     game); 0 = the boot menu
mn_bgh  = mn_bgh_p                   ; mn_box's background page (see there).
                                     ;   BOTH are in permanent RAM (memory_map)
                                     ;   because the picker leaves this overlay
                                     ;   and comes back, and an overlay variable
                                     ;   is reset by every mn_open.
mb_x    dta 0                        ; mn_box's rectangle
mb_y    dta 0
mb_w    dta 0                        ;   ... width - 1
mb_h    dta 0                        ;   ... height - 1
mn_fsrc dta 0                        ; mn_freeze: the buffer that is on screen
mn_fdst dta 0                        ;   ... and the one it is copied into
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
