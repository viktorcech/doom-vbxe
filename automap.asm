;--------------------------------------------------------------
; RAM BUDGET: see the RAM-BUDGET block at the top of memory_map.inc, or run
; `python tools/ram_map.py`. Some RAM looks free to MADS and is NOT ($1000
; TEX_STAGE, $4000 map slot, $9000 MEMAC window): code assembled there is
; overwritten at runtime with no error and boots to a flat pink screen.
;--------------------------------------------------------------
;==============================================================
; automap.asm -- DOOM's automap (am_map.c), on TAB.
;--------------------------------------------------------------
; WHAT IT COSTS. Nothing that had a tenant:
;   * the DRAWING code is an OVERLAY in the MENU_RUN window, the same mechanism
;     menu.asm and savegame.asm already use -- the bytes live in VBXE VRAM and
;     are copied down on the TAB press. See the overlay's own header below.
;   * the per-level TABLES ride at the end of the streamed SEG region in
;     Rapidus bank $03 (pack_map._automap): no loader, no base RAM, and they
;     re-zero themselves on a level load.
;   * this file's one PERMANENT routine, am_mark, is 21 bytes in a 21-byte hole.
;
; WHAT IS IN THIS FILE, and why the two halves are so far apart:
;   am_mark  runs in the RENDER path, every frame, whether or not the map is
;            open -- it is what makes the map remember. It has to be resident.
;   the rest runs only while the map is UP, so it is overlay code and pays no
;            rent at all.
;==============================================================

;--------------------------------------------------------------
; am_mark -- r_segs.c:398, `linedef->flags |= ML_MAPPED`: the seg about to be
;   drawn belongs to a line the player has now SEEN, so the automap may draw it.
;
;   IT IS NOT CALLED. process_seg's one `jsr seg_len` is RETARGETED here and
;   this tail-jumps into seg_len -- which costs the seg segment (full to the
;   byte, $30DA-$3BC2 with load_dtab hard against it) exactly zero bytes. The
;   site is right: seg_len is reached once per seg that has already survived the
;   backface test, the near clip, the screen-range clip AND the solid-column
;   cull, which is precisely where R_StoreWallRange marks (r_bsp.c calls it from
;   R_ClipSolidWallSegment / R_ClipPassWallSegment, i.e. after the clip).
;
;   HOW IT IS 21 BYTES. The frame loop already runs in 65816 NATIVE mode
;   (underrom.asm's ROM-OUT <=> native invariant), so `rep #$30` buys a 16-bit
;   A and X for 2 bytes and no clc/xce pair. Then the packer does the rest of
;   the work: AMSEG holds the ADDRESS of the line's AMSEEN slot rather than a
;   linedef index, so there is no shift, no add and no mask here -- and the
;   address it just read is itself non-zero, which is the "seen" value, so
;   there is not even a constant to load.
;
;   MARKS BOTH SIDES on purpose. AMSKIP decides which side is DRAWN; marking is
;   unconditional, because for half the two-sided lines a player ever meets, the
;   back side is the only one he faces -- DOOM sets ML_MAPPED on the LINEDEF, so
;   which side rendered it is not a question the automap gets to ask.
;
;   Clobbers A/X. Both are dead at the call site (the occlusion scan's X is not
;   read again, and the next instruction after seg_len returns reloads A).
;--------------------------------------------------------------
am_resume = *
        org AMMARK_BASE
.proc am_mark
        rep #$30                     ; 16-bit A + X (native mode, see above)
        lda rs_segi                  ; A = seg index
        asl                          ;   ... x2: AMSEG is a u16 array
        tax
        lda.l AMSEG_EXT,x            ; A = &AMSEEN[this seg's linedef], bank $03
        tax
        sta.l AM_BANK0,x             ; ...and store it INTO that slot: any
                                     ;   non-zero value means SEEN, and the
                                     ;   address is one, so no constant is needed
        sep #$30                     ; back to the frame loop's 8-bit discipline
        jmp seg_len                  ; the call this routine displaced
.endp
    .if * > AMMARK_END+1
        ert 'am_mark outgrew AMMARK_BASE..END (memory_map.inc)'
    .endif
        org am_resume
am_amb = *                           ; the ambient PC: everything below orgs its
                                     ;   own home, so this file emits nothing
                                     ;   where it happens to be icl'd

;==============================================================
; THE FOUR GATES -- the whole of the automap's wiring into the frame loop.
;--------------------------------------------------------------
; None of them ADDS a call. Each one RETARGETS a `jsr`/`jmp` that was already
; there, so main's $2000 segment (which has no spare byte -- check_xex caught a
; +6 once) and hud.asm pay exactly zero:
;     main   jsr render_world   -> jsr am_gate
;     main   jsr read_keys      -> jsr am_kgate
;     hud    jsr draw_weapon    -> jsr am_wgate
;     mn_key jmp fps_key        -> jmp am_key
; All four are cold (once a frame) and all four live in win2 holes, which is the
; block that is slow forever (MEMAC-A) and therefore the right place for them.
;==============================================================

;--------------------------------------------------------------
; am_gate -- draw the map instead of the world. am_on doubles as mn_open's
;   argument (BANK_EN|AMOVL_BANK), so opening it is a jmp with A already right.
;   mn_open copies the overlay's first page down from VRAM and jumps into it;
;   the overlay's own rts is what returns to main.
;--------------------------------------------------------------
        org AMGATE_BASE
.proc am_gate
        lda am_on
        beq ?world
        jmp mn_open                  ; A = the overlay's VRAM bank
?world  jmp render_world
.endp
    .if * > AMGATE_END+1
        ert 'am_gate outgrew AMGATE_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; am_kgate -- while the map is up, read_keys must NOT run: '-'/'=' are the ZOOM
;   keys then, not the view-size keys, and USE/weapon-select have no business
;   firing at a map. Jumping straight to mn_key keeps the rest of the chain --
;   ESC (the control panel), TAB (am_key, below) and 'F' (the FPS readout) --
;   which is what DOOM's automap also leaves working.
;--------------------------------------------------------------
        org AMKGATE_BASE
.proc am_kgate
        lda am_on
        beq ?keys
        jmp mn_key
?keys   jmp read_keys
.endp
    .if * > AMKGATE_END+1
        ert 'am_kgate outgrew AMKGATE_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; am_wgate -- no player sprite over the map. DOOM's automap replaces the view,
;   gun and all; the status bar stays, which is why only draw_weapon is gated
;   and draw_hud_gate's other three calls run as usual.
;--------------------------------------------------------------
        org AMWGATE_BASE
.proc am_wgate
        lda am_on
        bne ?skip
        jmp draw_weapon
?skip   rts
.endp
    .if * > AMWGATE_END+1
        ert 'am_wgate outgrew AMWGATE_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; am_key -- TAB toggles the map (AM_STARTKEY / AM_ENDKEY, am_map.c:96-97).
;
;   IT READS NEITHER SKSTAT NOR KBCODE, and that is not laziness -- there is no
;   room for them here. It is mn_key's tail, and A at mn_key's `?ret` can only
;   be one of four things:
;       1  no key is held at all      (?up: lda #1 / sta mn_arm)
;       0  ESC is held but disarmed   (lda mn_arm / beq ?ret)
;       ZFRONT, which is $01 or $07   (the FRAME_A-only gate)
;       KBCODE & $3F, a key IS held and it is not ESC
;   KEY_TAB is $2C and none of the other three can be, so `cmp #KEY_TAB` alone
;   means "a key is down and it is TAB". If mn_key's tail ever grows a fifth
;   path, this is the line that has to be re-read.
;
;   The press edge is mn_arm, SHARED with ESC on purpose: only one key can be
;   down on an Atari keyboard at a time, and mn_key re-arms it the moment
;   everything is released -- so TAB cannot repeat while held, and the TAB that
;   opens the map cannot also be the TAB that closes it.
;--------------------------------------------------------------
        org AMKEY_BASE
.proc am_key
        cmp #KEY_TAB
        bne ?ret
        lda mn_arm
        beq ?ret
        dec mn_arm                   ; acts once per press (mn_arm was 1)
        lda am_on
        eor #BANK_EN | AMOVL_BANK    ; toggle 0 <-> the overlay's bank byte
        sta am_on
        lda #3                       ; ...and re-arm the BORDER repaint, ONCE.
        sta vw_dirty                 ;   render_world only re-opens the columns
                                     ;   vw_x0..vw_xend (renderer.asm), so
                                     ;   nothing in the frame path ever paints
                                     ;   OUTSIDE the view window -- while the
                                     ;   overlay's clear_screen covers rows
                                     ;   0..167 at FULL WIDTH, map lines and all.
                                     ;   Without this the map's leftovers sat in
                                     ;   the border until the next resize
                                     ;   (2026-08-19, 1.png). Three is
                                     ;   vw_apply's own count, one paint per
                                     ;   buffer. menu.asm answers the same
                                     ;   problem with `jsr vw_apply` when ITS
                                     ;   overlay closes ("THE ONE THING THE
                                     ;   OVERLAY BREAKS").
                                     ;   ON THE EDGE, not every frame: vw_frame
                                     ;   runs EARLIER in the frame than am_gate
                                     ;   (bsp_main.asm:404 vs :435) and its
                                     ;   clear_screen is a whole rows-0..167
                                     ;   blit, so arming it per frame puts a
                                     ;   SECOND full clear in every frame and
                                     ;   the picture comes apart -- tried, and
                                     ;   it flickered black.
                                     ;   Arming it on the OPENING press too is
                                     ;   free: those three paints land under the
                                     ;   map's own clear.
                                     ;   A is 3 at ?ret, which fps_key reads --
                                     ;   3 is not KEY_F, so the tail is safe.
?ret    jmp fps_key                  ; the tail this displaced
.endp
    .if * > AMKEY_END+1
        ert 'am_key outgrew AMKEY_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; am_title / strip_blit -- ALL of hu_stuff.c's HU_Drawer, in one blit.
;   DOOM draws exactly two lines of text over the game: w_title, the level name
;   in the bottom-left `if (automapactive)` (hu_stuff.c:491, at HU_TITLEX = 0,
;   HU_TITLEY = 167 - the font's height), and w_message, player->message across
;   the TOP of the view. This port draws both through the same rectangle:
;     am_title     the automap's line -- level name, at TITLE_Y. No arguments.
;     strip_blit   A = strip index, X = screen row. msg_tick (hud.asm) calls it
;                  for the message; anything else with a line to show can too.
;
;   NO FONT AT RUNTIME. DOOM composes a line from hu_font (the STCFN* lumps)
;   one glyph at a time; this port has no font at all -- menu.asm's header says
;   why ("every line is a patch, so no font is needed") -- and giving it one
;   costs a glyph table, a string table and a per-character loop. So
;   tools/pack_menu.py rasterises every line with the SAME STCFN glyphs at pack
;   time, one strip each, and this blits one rectangle. Same trade the whole
;   menu already makes, and it is only affordable because the set of lines is
;   CLOSED: nine level names and one message per bonus id.
;
;   The strips are TITLE_STRIDE (1024) apart, which is what keeps the address
;   arithmetic to two shifts: only the middle byte of the source address moves,
;   by 4 per strip (40 strips = $A0, so it cannot carry into the bank byte).
;   All of them are padded to TITLE_W, so there is no width table -- and the
;   padding is index 0, which BLT_BSTENCIL leaves alone.
;
;   It builds its OWN BCB rather than calling hud_blit, and that is the whole
;   reason it is resident instead of overlay code: hud_blit forces the
;   destination bank to 0 because the status bar rows are shared between the
;   buffers, while both TITLE_Y and MSG_Y are inside the view and have to follow
;   zback_hi. Everything else is hud_blit's, and it leaves through the same
;   hud_fire the menu's mn_box uses.
;
;   The MEMAC window must be on BANK_OVERHEAD here: am_arrow puts it back
;   there on its way out, which is why am_head calls this last. In a normal
;   frame it never left -- every borrower parks it back (spr_draw, weapon...).
;
;   2026-08-16: the two entry points cost NOTHING over the old am_title. The
;   index load and the row load simply moved to the top, and the strip's low
;   address byte (a constant) moved down into their place.
;--------------------------------------------------------------
        org AMTITLE_BASE
.proc am_title                       ; the AUTOMAP's line: this level's name
        ldx #TITLE_Y
        lda current_level
strip_blit                           ; ...and the shared entry: A = strip index,
        asl                          ;     X = screen row. Stride 1024 = 4
        asl                          ;     banks-of-256 per strip, so the low
        clc                          ;     byte never moves and the middle one
        adc #>TITLE_VRAM             ;     cannot carry
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        lda #<TITLE_VRAM             ; --- SRC = TITLE_VRAM + index*TITLE_STRIDE
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda #[TITLE_VRAM>>16]
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #TITLE_W                 ; SRC_STEPY = the strip's own row pitch
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #0                       ; draw_weapon SCALES this BCB's source for
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1   ; the view window; undo that, the
        lda #1                       ; strip is 1:1 (hud_blit does the same)
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda #TITLE_W-1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #TITLE_H-1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        lda row_lo,x                 ; --- DST = column 0 of row X, in the BACK
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR    ;   buffer (NOT bank 0 -- header)
        lda row_hi,x
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #BLT_BSTENCIL            ; index 0 = clear: the padding costs nothing
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jmp hud_blit.hud_fire        ; ...and out through hud_blit's own tail
                                     ;   (the .proc-scoped name menu.asm uses)
.endp
    .if * > AMTITLE_END+1
        ert 'am_title outgrew AMTITLE_BASE..END (memory_map.inc)'
    .endif
        org am_amb

;==============================================================
; THE OVERLAY -- everything below runs only while the map is UP.
;--------------------------------------------------------------
; It is assembled for MENU_RUN ($1000) but PARKED at AMOVL_STAGE with MADS's
; two-address org, exactly like menu.asm and savegame.asm;
; tools/split_menu_ovl.py lifts the block out of the XEX and into menu.bin, and
; load_menu streams it to VBXE VRAM bank AMOVL_BANK. So it costs no base RAM,
; no XEX segment and no drive access.
;
; IT IS RE-COPIED EVERY FRAME, not once on the TAB press. am_gate calls mn_open
; unconditionally while am_on is set: 1280 bytes through the MEMAC window is
; ~0.7 ms, and it buys three things worth far more than that --
;   * the game keeps RUNNING under the map (DOOM's automap does not pause), and
;     move_player's collision rebuilds bsp_stack at $1400 every frame -- which
;     is the overlay's fifth page;
;   * ESC still works: the menu overlay lands in the same window and would
;     otherwise leave the automap in pieces when it closes;
;   * so nothing here has to be re-entrant or self-cleaning.
; The price is the one rule that matters: NO STATE MAY LIVE IN THIS BLOCK. Every
; cell below is per-frame scratch, written before it is read inside one frame.
; What has to survive (am_on, am_sh, am_karm) lives in the win2 state block --
; see memory_map.inc, and menu.asm's mn_sy for the same lesson learned the hard
; way.
;
; WIDTH DISCIPLINE. MADS does not track the 65816's M/X flags -- it sizes an
; immediate by its VALUE (math.asm's 16-bit block says so, and only switches M
; for that reason). So A stays 8-bit through all of this and only X goes 16-bit,
; for the bank-$03 arrays; X is then loaded ONLY from two-byte cells, never from
; an immediate. `tax` is avoided outright: with M=1 and X=0 it moves the full
; 16-bit C register, not A.
;
; WHAT IT DRAWS -- am_map.c AM_Drawer, minus what the reductions below name:
;   AM_clearFB   clear_screen (resident) paints rows 0..167 of the back buffer.
;                It clears VIEW_HEIGHT, not 200, so the status bar survives.
;   AM_drawWalls the seg loop, with AM_drawWalls' colour ladder verbatim.
;   AM_drawPlayers the arrow, rotated by the player's angle.
;
; THE REDUCTIONS, all deliberate and all of them named:
;   * FOLLOW MODE ONLY. m_x/m_y are the player, always, so the projection is
;     load_vertex's own `vertex - player` and the overlay needs no vertex
;     reader, no window origin and no pan. DOOM's 'f' toggle, the arrow keys
;     and the grid ('g') and marks ('m'/'c') are not here yet.
;   * ZOOM IS A SHIFT, not DOOM's continuous 1.02x/tic scale_mtof. Whole powers
;     of two mean the projection is a shift loop instead of two FixedMuls per
;     vertex, which is most of what keeps this inside 1280 bytes.
;   * NO PARAMETRIC CLIP. A line is trivially rejected against the four edges
;     and then drawn with a per-pixel bounds test, so a line that crosses the
;     view diagonally costs its full length in steps. AM_SHMIN bounds that:
;     at 4 world units per row the longest episode-1 line is ~1000 steps.
;   * pw_allmap (the Computer Area Map) is still thrown away by powerups.asm,
;     so the "seen it all" branch of AM_drawWalls has nothing to switch on yet.
;==============================================================

; ---- am_map.c's palette. These are PLAYPAL indices and DOOM's own values ----
AM_BG       equ 0                    ; BACKGROUND = BLACK
AM_WALL     equ 176                  ; WALLCOLORS = REDS   (256-5*16)
AM_TELE     equ 176+8                ; WALLCOLORS + WALLRANGE/2 (teleporter)
AM_FDWALL   equ 64                   ; FDWALLCOLORS = BROWNS  (4*16): floor step
AM_CDWALL   equ 231                  ; CDWALLCOLORS = YELLOWS (256-32+7): ceiling
AM_YOU      equ 209                  ; YOURCOLORS = WHITE  (256-47)
AM_CX       equ SCREEN_WIDTH/2       ; the player's column ...
AM_CY       equ VIEW_HEIGHT/2        ;   ... and row: follow mode pins him here
AM_SHMIN    equ 2                    ; zoom limits: world units per screen ROW
AM_SHMAX    equ 6                    ;   = 1<<am_sh (columns get one shift more,
AM_SH0      equ 4                    ;   because an LR pixel is two hw pixels)

        org MENU_RUN, AMOVL_STAGE

;--------------------------------------------------------------
; am_head -- THE FIRST PAGE. mn_open has copied it down and jumped here with the
;   MEMAC window still on the overlay's bank, so the other four pages are one
;   loop away. Same bootstrap as menu.asm's mn_head; no entry index, this
;   overlay has one way in.
;--------------------------------------------------------------
.proc am_head
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
        lda #BANK_EN | BANK_OVERHEAD ; the window goes back to the BCB bank: the
        sta VBXE_BANK_SEL            ;   blitter's control blocks live there and
                                     ;   clear_screen is about to poke them
        jsr am_keys                  ; AM_Ticker: the zoom keys
        lda #AM_BG
        jsr clear_screen             ; AM_clearFB (resident: rows 0..167 only)
        jsr am_walls                 ; AM_drawWalls
        jsr am_arrow                 ; AM_drawPlayers
        jmp am_title                 ; HU_Drawer's `if (automapactive)` half: the
.endp                                ;   level name. LAST, because am_arrow is
                                     ;   what puts the MEMAC window back on the
                                     ;   BCB bank -- and its tail (hud_fire's
                                     ;   rts) returns to main's frame loop, where
                                     ;   render_world's would have

;--------------------------------------------------------------
; am_keys -- AM_Ticker's half that survived the reductions: the zoom keys.
;   '-'/'<' out, '='/'>' in -- DOOM's AM_ZOOMOUTKEY/AM_ZOOMINKEY, and the same
;   two keys the 3D view is resized with, which is why am_kgate keeps read_keys
;   out of the way while the map is up.
;   ONE STEP PER PRESS: DOOM zooms continuously while the key is held (1.02x a
;   tic) and a power-of-two shift cannot, so the edge is the honest reading.
;   am_sh is range-checked rather than initialised anywhere: it lives in the
;   win2 state block, which is boot RAM until something writes it (cht_key does
;   the same for cht_n, and says why).
;--------------------------------------------------------------
.proc am_keys
        lda am_sh
        cmp #AM_SHMIN
        bcc ?init
        cmp #AM_SHMAX+1
        bcc ?ok
?init   lda #AM_SH0
        sta am_sh
?ok     ldx #0                       ; X = the zoom key down this frame
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        bne ?edge
        lda KBCODE
        inx                          ; 1 = '-' / '<' -> zoom OUT
        cmp #KEY_MINUS
        beq ?edge
        cmp #KEY_LT
        beq ?edge
        inx                          ; 2 = '=' / '>' -> zoom IN
        cmp #KEY_EQUALS
        beq ?edge
        cmp #KEY_GT
        beq ?edge
        ldx #0                       ; some other key -- TAB and ESC are handled
?edge   cpx am_karm                  ;   by am_key/mn_key, outside the overlay
        beq ?ret
        stx am_karm
        dex
        bmi ?ret                     ; release
        beq ?out
        lda am_sh                    ; zoom IN = fewer world units per pixel
        cmp #AM_SHMIN
        beq ?ret
        dec am_sh
        rts
?out    lda am_sh
        cmp #AM_SHMAX
        beq ?ret
        inc am_sh
?ret    rts
.endp

;--------------------------------------------------------------
; am_walls -- AM_drawWalls (am_map.c:1114), over SEGS instead of linedefs.
;   The colour ladder is DOOM's, in DOOM's order, and every test it makes is a
;   test this port can actually answer:
;       no back sector          -> WALLCOLORS      (a solid wall)
;       special 39              -> WALLCOLORS+8    (a teleporter)
;       ML_SECRET               -> WALLCOLORS      (a secret door LOOKS solid)
;       back.floor != front.floor -> FDWALLCOLORS  (a step)
;       back.ceil  != front.ceil  -> CDWALLCOLORS  (a lintel)
;       otherwise               -> not drawn
;   The heights come from MAP_SECTORS in base RAM and are read LIVE, so a door
;   that has opened or a lift that has moved changes colour exactly as it does
;   in DOOM -- they are not baked at pack time.
;--------------------------------------------------------------
.proc am_walls
        lda #0                       ; the loop variable is the AMSEG STRIDE (i*2)
        sta am_i2                    ;   rather than i: it is the one index that
        sta am_i2+1                  ;   is needed on every pass, and dropping a
        sta am_i8                    ;   second 16-bit counter pays for itself
        sta am_i8+1
        sta am_iskip
        sta am_iskip+1
        lda #1
        sta am_smask
        lda MAP_HNSEG                ; bound = this level's seg count x2
        asl
        sta am_nseg2
        lda MAP_HNSEG+1
        rol
        sta am_nseg2+1
?loop   lda am_i2+1
        cmp am_nseg2+1
        bcc ?go
        bne ?dn
        lda am_i2
        cmp am_nseg2
        bcc ?go
?dn     rts                          ; every seg walked -- the exit is HERE and
                                     ;   not at the bottom, so the test that
                                     ;   reaches it stays a short branch
?go
        rep #$10                     ; --- AMSKIP: the BACK side of a two-sided
        ldx am_iskip                 ;     line is MARKED but never drawn (its
        lda.l AMSKIP_EXT,x           ;     front side's segs tile the same line)
        sep #$10
        and am_smask
        beq ?vis
?nx     jmp ?next                    ; ?next is out of branch range from up here,
                                     ;   so the early exits go through this
?vis    rep #$10                     ; --- AMSEG[i] = &AMSEEN[its linedef] ---
        ldx am_i2
        lda.l AMSEG_EXT,x
        sta am_slot
        lda.l AMSEG_EXT+1,x
        sta am_slot+1
        ldx am_slot                  ; --- ML_MAPPED? am_mark wrote a non-zero
        lda.l AM_BANK0,x             ;     address here the first time this line
        ora.l AM_BANK0+1,x           ;     was rendered (r_segs.c:398)
        bne ?seen
        sep #$10                     ; never seen -> nothing. DOOM's pw_allmap
        jmp ?next                    ;   branch would go here (powerups.asm
                                     ;   still throws the Computer Map away)
?seen   lda.l AMFLG_EXT_D,x          ; ... and its flags, same X, fixed delta
        sep #$10
        sta am_flg
        and #AMF_DONTDRAW            ; LINE_NEVERSEE: never on the automap
        bne ?nx
        rep #$10                     ; --- the seg record ---
        ldx am_i8
        lda.l SEGS_EXT+SEG_BACK,x
        sta am_back
        lda.l SEGS_EXT+SEG_FRONT,x
        sta am_front
        lda.l SEGS_EXT+SEG_V1,x
        sta am_v1
        lda.l SEGS_EXT+SEG_V1+1,x
        sta am_v1+1
        lda.l SEGS_EXT+SEG_V2,x
        sta am_v2
        lda.l SEGS_EXT+SEG_V2+1,x
        sta am_v2+1
        sep #$10
        ; --- the colour ladder ---
        lda #AM_WALL
        ldx am_back
        cpx #NO_SECTOR
        beq ?col                     ; one-sided -> a solid wall
        lda am_flg
        and #AMF_TELEPORT            ; DOOM tests special 39 BEFORE ML_SECRET
        beq ?nt
        lda #AM_TELE
        bne ?col                     ; (always)
?nt     lda am_flg
        and #AMF_SECRET
        beq ?nsec
        lda #AM_WALL                 ; a secret door must read as a WALL
        bne ?col                     ; (always)
?nsec   jsr am_secptr                ; zp_ptr = front sector, zp_tsrc = back
        ldy #0                       ; floor_h
        jsr am_cmp
        beq ?nf
        lda #AM_FDWALL
        bne ?col                     ; (always)
?nf     ldy #2                       ; ceil_h
        jsr am_cmp
        bne ?cd
        jmp ?next                    ; same floor AND ceiling -> invisible, as
?cd     lda #AM_CDWALL               ;   in DOOM (only the IDDT cheat shows it)
?col    sta am_col
        jsr am_draw
?next   clc                          ; i2 += 2
        lda am_i2
        adc #2
        sta am_i2
        bcc ?n2
        inc am_i2+1
?n2     clc                          ; i8 += 8
        lda am_i8
        adc #8
        sta am_i8
        bcc ?n3
        inc am_i8+1
?n3     asl am_smask                 ; ... and the AMSKIP bit walks with it
        bne ?lp
        lda #1
        sta am_smask
        inc am_iskip
        bne ?lp
        inc am_iskip+1
?lp     jmp ?loop
.endp

;--------------------------------------------------------------
; am_secptr -- zp_ptr -> MAP_SECTORS[am_front], zp_tsrc -> [am_back].
;   Both are base RAM, so these are plain (zp),y pointers and the bank bytes
;   (which belong to the map readers) are not touched.
;--------------------------------------------------------------
    .if zp_tsrc != zp_ptr+3
        ert 'am_secptr indexes zp_ptr by 3 to reach zp_tsrc -- the zero page block in bsp_main.asm moved'
    .endif
.proc am_secptr
        lda am_front
        ldx #0
        jsr ?one
        lda am_back
        ldx #3
?one    sta am_t                     ; t = sector id * 8 (SECTORS are 8 B)
        lda #0
        sta am_t+1
        asl am_t
        rol am_t+1
        asl am_t
        rol am_t+1
        asl am_t
        rol am_t+1
        clc
        lda am_t
        adc #<MAP_SECTORS
        sta zp_ptr,x                 ; x=0 -> zp_ptr, x=3 -> zp_tsrc. Both are
        lda am_t+1                   ;   render/loader scratch, which is exactly
        adc #>MAP_SECTORS            ;   what the automap is standing in for
        sta zp_ptr+1,x               ;   this frame (the .if above guards the
        rts                          ;   adjacency the index relies on)
.endp

;--------------------------------------------------------------
; am_cmp -- Y = field offset (0 = floor_h, 2 = ceil_h). Z=1 if the front and
;   back sectors agree on it. Clobbers A/Y.
;--------------------------------------------------------------
.proc am_cmp
        lda (zp_ptr),y
        cmp (zp_tsrc),y
        bne ?out
        iny
        lda (zp_ptr),y
        cmp (zp_tsrc),y
?out    rts
.endp


;--------------------------------------------------------------
; am_draw -- project the seg's two vertices and draw the line between them.
;   In FOLLOW MODE the map's centre IS the player, so load_vertex's own
;   `vertex - player` is already the map-space delta -- which is why there is no
;   vertex reader in this overlay and no m_x/m_y to keep.
;--------------------------------------------------------------
.proc am_draw
        lda am_v1
        sta zp_vidx
        lda am_v1+1
        sta zp_vidx+1
        jsr load_vertex
        ldx #0                       ; am_proj stores THROUGH X -- see below
        jsr am_proj
        lda am_v2
        sta zp_vidx
        lda am_v2+1
        sta zp_vidx+1
        jsr load_vertex
        ldx #am_x2-am_x1
        jsr am_proj
        jmp am_line
.endp

;--------------------------------------------------------------
; am_proj -- MTOF: zp_rx/zp_ry (world, player-relative) -> the line end X selects
;   (X = 0 -> am_x1/am_y1, X = 4 -> am_x2/am_y2; the two points are adjacent
;   4-byte {x,y} pairs at the bottom of the scratch block, which is what makes
;   the index work). 2026-08-14: this REPLACED a separate am_sx/am_sy landing
;   pad and the two 12-byte copy loops that moved it to one end or the other --
;   `sta am_x1,x` is the same three bytes `sta am_sx` was, so the copies were
;   30 bytes bought for nothing. They paid for the arrow below.
;     sx = 80 + (rx >> (sh+1))      sy = 84 - (ry >> sh)
;   The extra x shift is the ASPECT: this framebuffer is 160 LR pixels across
;   the width DOOM draws 320 in, so one column covers two of DOOM's. Without it
;   the map is squashed to half width. y is subtracted because world y grows
;   north while screen rows grow down.
;   `cmp #$80 : ror hi : ror lo` is the arithmetic shift right -- the cmp puts
;   the sign bit into C and the ror feeds it back into bit 7.
;--------------------------------------------------------------
.proc am_proj
        lda zp_rx
        sta am_t
        lda zp_rx+1
        sta am_t+1
        ldy am_sh
        iny
?xs     lda am_t+1
        cmp #$80
        ror am_t+1
        ror am_t
        dey
        bne ?xs
        clc
        lda am_t
        adc #AM_CX
        sta am_x1,x
        lda am_t+1
        adc #0
        sta am_x1+1,x
        lda zp_ry
        sta am_t
        lda zp_ry+1
        sta am_t+1
        ldy am_sh
?ys     lda am_t+1
        cmp #$80
        ror am_t+1
        ror am_t
        dey
        bne ?ys
        sec
        lda #AM_CY
        sbc am_t
        sta am_y1,x
        lda #0
        sbc am_t+1
        sta am_y1+1,x
        rts
.endp

;--------------------------------------------------------------
; am_line -- (am_x1,am_y1)-(am_x2,am_y2), signed 16-bit, colour am_col.
;   Trivially rejected against the four edges, then plain Bresenham with a
;   per-pixel bounds test instead of a parametric clip (see the reductions in
;   this file's header: it costs a line that crosses the view diagonally its
;   full length in steps, and AM_SHMIN is what bounds that).
;
;   The two reject idioms are NOT interchangeable: "both endpoints left of 0" is
;   an AND of the two sign bits (both negative), while "both past the right
;   edge" is an ORA of the two (x - 160) sign bits (neither negative).
;
;   ONE loop, not one per octant: when y is the major axis the two DELTAS are
;   exchanged and am_ymaj flips, so the body always subtracts am_dy from the
;   error and always steps am_dx's axis. Two near-identical loops cost 110
;   bytes more, and this overlay has 1280 in total.
;--------------------------------------------------------------
.proc am_line
        lda am_x1+1
        and am_x2+1
        bmi ?rej                     ; both x < 0
        lda am_y1+1
        and am_y2+1
        bmi ?rej                     ; both y < 0
        sec
        lda am_x1
        sbc #SCREEN_WIDTH
        lda am_x1+1
        sbc #0
        sta am_t
        sec
        lda am_x2
        sbc #SCREEN_WIDTH
        lda am_x2+1
        sbc #0
        ora am_t
        bpl ?rej                     ; both x >= 160
        sec
        lda am_y1
        sbc #VIEW_HEIGHT
        lda am_y1+1
        sbc #0
        sta am_t
        sec
        lda am_y2
        sbc #VIEW_HEIGHT
        lda am_y2+1
        sbc #0
        ora am_t
        bmi ?ok                      ; at least one is above the bottom edge
?rej    rts
?ok     sec                          ; dx = |x2-x1|, am_stx = its direction
        lda am_x2
        sbc am_x1
        sta am_dx
        lda am_x2+1
        sbc am_x1+1
        sta am_dx+1
        bpl ?dxp
        sec
        lda #0
        sbc am_dx
        sta am_dx
        lda #0
        sbc am_dx+1
        sta am_dx+1
        lda #$FF
        bmi ?dxs                     ; (always)
?dxp    lda #1
?dxs    sta am_stx
        sec                          ; dy = |y2-y1|, am_sty = its direction
        lda am_y2
        sbc am_y1
        sta am_dy
        lda am_y2+1
        sbc am_y1+1
        sta am_dy+1
        bpl ?dyp
        sec
        lda #0
        sbc am_dy
        sta am_dy
        lda #0
        sbc am_dy+1
        sta am_dy+1
        lda #$FF
        bmi ?dys                     ; (always)
?dyp    lda #1
?dys    sta am_sty
        ldx #0                       ; which axis is the major one?
        stx am_ymaj
        lda am_dx+1
        cmp am_dy+1
        bcc ?swap
        bne ?run
        lda am_dx
        cmp am_dy
        bcs ?run
?swap   inc am_ymaj                  ; y is major: exchange the two deltas, and
        ldx #1                       ;   the step calls below follow the flag
?sw     lda am_dx,x                  ; (through the stack: there is no STY abs,X)
        pha
        lda am_dy,x
        sta am_dx,x
        pla
        sta am_dy,x
        dex
        bpl ?sw
?run    lda am_dx+1                  ; err = major >> 1 ; n = major
        lsr
        sta am_err+1
        lda am_dx
        ror
        sta am_err
        lda am_dx
        sta am_n
        lda am_dx+1
        sta am_n+1
?l      jsr am_plot
        sec                          ; err -= minor
        lda am_err
        sbc am_dy
        sta am_err
        lda am_err+1
        sbc am_dy+1
        sta am_err+1
        bpl ?ns
        clc                          ; err += major, and step the MINOR axis
        lda am_err
        adc am_dx
        sta am_err
        lda am_err+1
        adc am_dx+1
        sta am_err+1
        lda am_ymaj
        bne ?minx
        jsr am_stepy
        jmp ?ns
?minx   jsr am_stepx
?ns     lda am_ymaj                  ; ... and always the MAJOR one
        bne ?majy
        jsr am_stepx
        jmp ?cnt
?majy   jsr am_stepy
?cnt    jsr am_dec
        bne ?l
        rts
.endp

;--------------------------------------------------------------
; am_dec -- the loop tail. n counts the MAJOR axis and a line is n+1 pixels
;   long, so the test comes AFTER the plot. Returns Z=1 when done.
;--------------------------------------------------------------
.proc am_dec
        lda am_n
        ora am_n+1
        beq ?out                     ; n == 0 -> the last pixel is drawn
        lda am_n
        bne ?lo
        dec am_n+1
?lo     dec am_n
        lda #1                       ; Z=0: keep going
?out    rts
.endp

.proc am_stepx
        lda am_stx
        bmi ?dn
        inc am_x1
        bne ?r
        inc am_x1+1
        rts
?dn     lda am_x1
        bne ?d
        dec am_x1+1
?d      dec am_x1
?r      rts
.endp

.proc am_stepy
        lda am_sty
        bmi ?dn
        inc am_y1
        bne ?r
        inc am_y1+1
        rts
?dn     lda am_y1
        bne ?d
        dec am_y1+1
?d      dec am_y1
?r      rts
.endp

;--------------------------------------------------------------
; am_plot -- one pixel of am_col at (am_x1,am_y1) into the BACK buffer, through
;   the MEMAC-A window. Silently drops anything outside the view: an UNSIGNED
;   compare rejects negatives for free (a negative high byte is non-zero).
;   The window's bank is re-selected only when it actually changes -- a VBXE
;   register write goes over the 1.79 MHz chip bus, and an x-major line crosses
;   a 4 KB boundary about once every 25 rows.
;--------------------------------------------------------------
.proc am_plot
        lda am_x1+1
        bne ?out
        lda am_x1
        cmp #SCREEN_WIDTH
        bcs ?out
        lda am_y1+1
        bne ?out
        lda am_y1
        cmp #VIEW_HEIGHT
        bcs ?out
        tax                          ; vaddr = row*160 + col
        clc
        lda row_lo,x
        adc am_x1
        sta zp_ptr
        lda row_hi,x
        adc #0
        sta am_t
        lsr                          ; bank = (zback_hi<<4) | (vaddr>>12)
        lsr
        lsr
        lsr
        sta am_t2
        lda zback_hi
        asl
        asl
        asl
        asl
        ora am_t2
        ora #BANK_EN
        cmp am_lastbk
        beq ?same
        sta am_lastbk
        sta VBXE_BANK_SEL
?same   lda am_t
        and #$0F
        ora #>MEMW
        sta zp_ptr+1
        ldy #0
        lda am_col
        sta (zp_ptr),y
?out    rts
.endp

;--------------------------------------------------------------
; am_arrow -- AM_drawPlayers. DOOM rotates a SEVEN-line arrow whose points are in
;   MAP units (am_map.c:161 player_arrow, R = 8*PLAYERRADIUS/7 ~ 18 units), so it
;   shrinks as you zoom out -- at DOOM's own starting scale on E1M1 the whole
;   thing is about three pixels. This draws ONE line, a plain shaft from tail to
;   tip, at a fixed pixel size. The shape is not DOOM's; the position (always the
;   centre, because follow mode is the only mode), the colour (WHITE) and the
;   facing are.
;   The facing costs no trig of its own: zp_sin/zp_cos are this frame's Q14
;   sine and cosine, built by frame_setup for move_player before anything here
;   runs. Their HIGH byte is the value x64, so FOUR arithmetic shifts make it
;   x4 -- a 4-pixel nose over a 2-pixel tail.
;   2026-08-14: it used to be two shifts (x16), a 24-pixel shaft that swamped the
;   map. Four is the power-of-two step nearest "80 % smaller" and lands within
;   2x of DOOM's real on-screen size at the default zoom. The extra shifts are
;   paid for by am_proj's indexed store (see there).
;   Leaves the MEMAC window back on the OVERHEAD bank: hud_blit pokes its BCB
;   there on the very next call in the frame loop.
;--------------------------------------------------------------
.proc am_arrow
        lda #AM_YOU
        sta am_col
        lda zp_cos+1                 ; --- x: cos x 4 (the Q14 high byte is x64,
        cmp #$80                     ;     so four arithmetic shifts make it x4)
        ror
        cmp #$80
        ror
        cmp #$80
        ror
        cmp #$80
        ror
        sta am_t2
        clc                          ; the TIP: centre + the facing vector
        adc #AM_CX                   ;   |offset| <= 16 against a centre of 80,
        sta am_x2                    ;   so this never leaves 0..255 and every
        lda #0                       ;   high byte below is a plain zero
        sta am_x2+1
        lda am_t2                    ; the TAIL: centre - half of it
        cmp #$80
        ror
        sta am_t
        sec
        lda #AM_CX
        sbc am_t
        sta am_x1
        lda #0
        sta am_x1+1
        lda zp_sin+1                 ; --- y, subtracted: screen rows grow DOWN
        cmp #$80                     ;     while world y grows north
        ror
        cmp #$80
        ror
        cmp #$80
        ror
        cmp #$80
        ror
        sta am_t2
        sta am_t
        sec
        lda #AM_CY
        sbc am_t
        sta am_y2
        lda #0
        sta am_y2+1
        lda am_t2
        cmp #$80
        ror
        sta am_t
        clc
        lda #AM_CY
        adc am_t
        sta am_y1
        lda #0
        sta am_y1+1
        jsr am_line
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp

; ---- per-frame scratch. NOT STATE: the overlay is re-copied every frame, so
;      every cell below is back to the value here before anything reads it. What
;      must survive a frame (am_on, am_sh, am_karm) is in the win2 state block.
;      am_x1/am_x2 are two ADJACENT 4-byte {x,y} points on purpose: am_proj
;      indexes between them with X (0 or 4) instead of copying.
am_x1    dta a(0)                    ; am_proj's output -- the line, and the
                                     ;   point Bresenham walks
am_y1    dta a(0)
am_x2    dta a(0)                    ; ... and its far end
am_y2    dta a(0)
am_i2    dta a(0)                    ; seg index x2 (AMSEG's stride) -- the loop
am_i8    dta a(0)                    ;   variable -- and x8 (the seg record)
am_iskip dta a(0)                    ;   ... >>3 (the AMSKIP byte) ...
am_smask dta 1                       ;   ... and 1 << (i & 7)
am_nseg2 dta a(0)                    ; the level's seg count x2, the loop bound
am_slot  dta a(0)                    ; &AMSEEN[this seg's linedef]
am_flg   dta 0                       ; that line's AMFLG byte
am_front dta 0
am_back  dta 0
am_v1    dta a(0)
am_v2    dta a(0)
am_col   dta 0
am_dx    dta a(0)                    ; Bresenham: MAJOR delta after the swap ...
am_dy    dta a(0)                    ;   ... and MINOR
am_err   dta a(0)
am_n     dta a(0)
am_stx   dta 0                       ; the two axes' directions, never swapped:
am_sty   dta 0                       ;   each step routine reads its own
am_ymaj  dta 0                       ; 1 = y is the major axis
am_t     dta a(0)
am_t2    dta 0
am_lastbk dta $FF                    ; the MEMAC bank last selected ($FF = none,
                                     ;   so the first plot of a frame always
                                     ;   writes VBXE_BANK_SEL)

    .if * > MENU_RUN_END+1
        ert 'the automap overlay outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
        org am_amb
