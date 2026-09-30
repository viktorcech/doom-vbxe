;--------------------------------------------------------------
; automap.asm -- DOOM's automap (am_map.c) on TAB. The drawing code is an overlay in
;   the MENU_RUN window; the per-level tables ride at the end of the SEG region.
;--------------------------------------------------------------
; am_mark -- r_segs.c:398, `linedef->flags |= ML_MAPPED`: the seg about to be
;   drawn belongs to a line the player has now SEEN, so the automap may draw it.
;   INLINED in process_seg since 2026-09-15 (seg_draw.asm, beside the seg's
;   length); the proc itself had no caller and went on 2026-09-28 with seg_len.
;--------------------------------------------------------------
am_resume = *
        org AMMARK_BASE

;--------------------------------------------------------------
; sg_amout / sg_amin -- BUG FIX 2026-09-15: the SEEN marks go into the save.
;--------------------------------------------------------------
AM_SEEN_N equ [MAP_AMFLG-MAP_AMSEEN]/2
    .if AM_SEEN_N > 2*128*8
        ert 'AMSEEN holds more linedefs than the save bitmap page (SGK_AMB)'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_amout                       ; AMSEEN -> SG_BUF (save)
        jsr sg_amptr
        ldx #0
?byte   lda #8
        sta sg_ambc
?bit    lda zp_ptr                   ; past the table? AMFLG follows it: a 0 bit
        cmp #<MAP_AMFLG
        lda zp_ptr+1
        sbc #>MAP_AMFLG
        bcc ?in
        clc
        bcc ?put                     ; (always)
                                      ; 2026-09-21 (drac030: [dp] without the index): same
?in     lda [zp_ptr]                 ;   word test, Y = 1 at the end as before, -2 cycles
        ldy #1                       ;   a bit (8-bit on purpose: the savegame path)
        ora [zp_ptr],y
        cmp #1                       ; C = the slot is non-zero (SEEN)
?put    rol SG_BUF,x
        jsr sg_amnext
        dec sg_ambc
        bne ?bit
        inx
        bpl ?byte
        lda #MAP_EXT_BANK            ; the parked bank back, then home (a jsl'd
        sta zp_ptr+2                 ;   proc carries its own rtl: b1_check)
        rtl
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_amin                        ; SG_BUF -> AMSEEN (load, over the fresh zeros)
        jsr sg_amptr
        ldx #0
?byte   lda #8
        sta sg_ambc
?bit    asl SG_BUF,x                 ; bit 7 first, the order sg_amout rol'd in
        bcc ?nx
        lda zp_ptr                   ; never past the table (that is AMFLG)
        cmp #<MAP_AMFLG
        lda zp_ptr+1
        sbc #>MAP_AMFLG
        bcs ?nx
        ldy #0                       ; the slot's OWN address, which is exactly
        lda zp_ptr                   ;   what am_mark stores there
        sta [zp_ptr],y
        iny
        lda zp_ptr+1
        sta [zp_ptr],y
?nx     jsr sg_amnext
        dec sg_ambc
        bne ?bit
        inx
        bpl ?byte
        lda #MAP_EXT_BANK            ; the parked bank back, then home (a jsl'd
        sta zp_ptr+2                 ;   proc carries its own rtl: b1_check)
        rtl
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_amptr                       ; zp_ptr = AMSEEN slot of bit sg_src*8, bank $03
                                      ; 2026-09-21 (drac030 #41: shifts belong in A): the low
        lda sg_src+1                 ;   byte stays in the accumulator through the loop and
        sta zp_ptr+1                 ;   into the add -- asl @ is 2 cycles, asl zp 5, and the
        lda sg_src                   ;   sta/lda round trip goes. STILL 8-BIT ON PURPOSE: the
        ldx #4                       ;   savegame path never proves native mode (no rep here).
?s      asl @                        ; *16: 8 bits a byte, 2 B a slot
        rol zp_ptr+1
        dex
        bne ?s
        clc
        adc #<MAP_AMSEEN
        sta zp_ptr
        lda zp_ptr+1
        adc #>MAP_AMSEEN
        sta zp_ptr+1
        lda #MAP_SEG_BANK
        sta zp_ptr+2
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_amnext                      ; zp_ptr += 2 (the next linedef's slot)
        lda zp_ptr
        clc
        adc #2
        sta zp_ptr
        bcc ?r
        inc zp_ptr+1
?r      rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a
sg_ambc dta 0                        ; bits left in the current bitmap byte
        .endseg
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
; am_gate -- draw the map instead of the world. Since 2026-08-31 the overlay
;   lives in Rapidus bank $01, so the gate is one long jump into b1_amgate
;   (bank01.asm), which tests am_on, serves the overlay's first page and jml's
;   into it -- or into render_world. The overlay's own rts still returns to
;   main: jml pushes nothing.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc am_gate
        jml B1CODE_BASE+b1_amgate    ; the WHOLE gate runs in bank $01 now
.endp                                ;   (b1_amgate: test am_on, serve page 1 of
        .endseg
                                     ;   the overlay from AMOVL_EXT, jml into ...
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; am_kgate -- AM_Responder eats only the automap's own keys and G_Responder
;   gets the rest (am_map.c:AM_Responder returns false for them): while the
;   map is up, a ZOOM key ('-'/'=' and '<'/'>', the view-size keys otherwise)
;   skips read_keys and goes straight to mn_key -- ESC, TAB and 'F' ride that
;   chain -- and every other key, USE among them, is read_keys' as always.
;--------------------------------------------------------------
    .if [KEY_MINUS^KEY_EQUALS] <> 1 || [KEY_LT^KEY_GT] <> 1 || [KEY_MINUS&1] <> 0 || [KEY_LT&1] <> 0
        ert 'am_kgate: each zoom pair is one even code and the odd one after it'
    .endif
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc am_kgate
        lda am_on
        bne ?am                      ; the map up: out of line
?keys   jmp read_keys
?am     lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        bne ?keys
        lda KBCODE
        and #$FE                     ; a pair to one code
        cmp #KEY_MINUS
        beq ?map
        cmp #KEY_LT
        bne ?keys
?map    jmp mn_key
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; am_wgate -- no player sprite over the map. DOOM's automap replaces the view,
;   gun and all; the status bar stays, which is why only draw_weapon is gated
;   and draw_hud_gate's other three calls run as usual.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc am_wgate
        lda am_on
        bne ?skip
        jmp draw_weapon
?skip   rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; am_key -- TAB toggles the map (AM_STARTKEY / AM_ENDKEY, am_map.c:96-97).
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc am_key
        cmp #KEY_TAB
        bne ?ret
        lda mn_arm
        beq ?ret
        dec mn_arm                   ; acts once per press (mn_arm was 1)
        lda am_on
        eor #1                       ; toggle 0 <-> 1: the flag stopped carrying
        sta am_on                    ;   a VRAM bank when the overlay moved to
                                     ;   Rapidus bank $01 (am_gate jsl's ...
        beq ?v                       ; AM_Stop: the lists follow by themselves
        jsr am_open                  ; AM_Start (st_frame switches the lists)
?v      lda #3                       ; ...and re-arm the BORDER repaint, ONCE.
        sta vw_dirty                 ;   render_world only re-opens the columns
                                     ;   vw_x0..vw_xend (renderer.asm), so ...
?ret    jmp fps_key                  ; the tail this displaced
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; am_open -- AM_Start's share of the 320 automap (the rest is strip.asm's:
;   st_frame puts lists A/B on the surfaces, one frame at a time, and the HU
;   on them): the two surfaces' clear chains into the grab area's tail, and
;   the title line fetched again (the strips it is staged behind ran).
;--------------------------------------------------------------
AM_W      equ 320                    ; the surfaces: 320 x VIEW_HEIGHT SR,
AM_S0     equ MT_SR                  ;   S0 in MT_SR (nothing else runs while
AM_S1     equ FRAME_B                ;   the map is up), S1 in FRAME_B's view
AM_S1B2   equ FRAME_C                ;   rows over FRAME_C's: the 3D view is
AM_S1B    equ 84                     ;   not drawn under the map. S1 goes on in
AM_S1E    equ 33                     ;   FRAME_C at row 84, list entry 33
AM_CLRV   equ MT_GRABV+$80           ; the clear chains, behind mt_show's six BCBs
AM_CWIN   equ MEMW16+[AM_CLRV&$3FFF]
    .if AM_S1B*AM_W > FRAME_B+VIEW_HEIGHT*SCREEN_WIDTH-AM_S1 || [VIEW_HEIGHT-AM_S1B]*AM_W > VIEW_HEIGHT*SCREEN_WIDTH || AM_S0+VIEW_HEIGHT*AM_W > MT_SR+WIPE_H*AM_W
        ert 'automap.asm: a surface half does not fit where it is put'
    .endif
    .if [AM_CLRV>>12] <> [MT_GRABV>>12] || [AM_CLRV&$FF]+3*BCB_SIZE > $FF
        ert 'automap.asm: the clear chains share the grab area chunk and page'
    .endif
        .segment B1
.proc am_open
        lda #$FF
        sta st_tlev
        lda #BANK_EN | [AM_CLRV>>12]
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        ldx #3*BCB_SIZE-1            ; 32 words (the last is the pad)
?w      lda.l B1CODE_BASE+am_cimg,x  ; long,x both ways: bank $01 data, and no
        sta.l AM_CWIN,x              ;   dummy read of the window
        dex
        dex
        bpl ?w
        .LONGA OFF
        sep #$20
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp
;   AM_clearFB: S0 in one fill, S1 as two (AND 0, XOR = BACKGROUND)
am_cimg dta 0, 0, 0, a(0), 0, <AM_S0, >AM_S0, [AM_S0>>16], a(AM_W), 1
        dta a(AM_W-1), VIEW_HEIGHT-1, 0, AM_BG, 0, 0, 0, BLT_COPY
        dta 0, 0, 0, a(0), 0, <AM_S1, >AM_S1, [AM_S1>>16], a(AM_W), 1
        dta a(AM_W-1), AM_S1B-1, 0, AM_BG, 0, 0, 0, BLT_COPY|BLT_NEXT
        dta 0, 0, 0, a(0), 0, <AM_S1B2, >AM_S1B2, [AM_S1B2>>16], a(AM_W), 1
        dta a(AM_W-1), VIEW_HEIGHT-AM_S1B-1, 0, AM_BG, 0, 0, 0, BLT_COPY
        dta 0

;--------------------------------------------------------------
; am_arot -- AM_drawPlayers' player_arrow (am_map.c:161), R = 8*PLAYERRADIUS/7
;   map units, rotated by the player's angle (AM_rotate) into am_apt: nine
;   points, player-relative world units -- what am_proj takes.
;--------------------------------------------------------------
AM_NARP equ 9
am_arp  dta [-16]&$FF, 0,  18, 0,  9, 5,  9, [-5]&$FF        ; -R+R/8, R, R-R/2 +-R/4
        dta [-21]&$FF, 5,  [-21]&$FF, [-5]&$FF               ; -R-R/8 +-R/4
        dta [-11]&$FF, 0,  [-16]&$FF, 5,  [-16]&$FF, [-5]&$FF ; -R+3R/8, -R+R/8 +-R/4
am_arot_w1
        lda #AM_NARP-1
        sta am_ri
?p      jsr ?x                       ; the partial sums ride the stack across
        ldx #zp_cos-zp_sin           ;   smul_14, which takes X and Y
        jsr am_m1                    ; x cos
        .LONGA ON
        pha
        .LONGA OFF
        sep #$20
        jsr ?y
        ldx #0
        jsr am_m1                    ; y sin
        .LONGA ON
        eor #$FFFF                   ; x' = x cos - y sin
        sec
        adc 1,s
        sta 1,s
        .LONGA OFF
        sep #$20
        jsr ?x
        ldx #0
        jsr am_m1                    ; x sin
        .LONGA ON
        pha
        .LONGA OFF
        sep #$20
        jsr ?y
        ldx #zp_cos-zp_sin
        jsr am_m1                    ; y cos
        .LONGA ON
        clc
        adc 1,s                      ; y' = x sin + y cos
        sta 1,s
        lda am_ri                    ; (the byte above it: the and)
        and #$00FF
        asl @
        asl @
        tax
        pla
        sta am_apt+2,x
        pla
        sta am_apt,x
        .LONGA OFF
        sep #$20
        dec am_ri
        bpl ?p
        rtl
?x      lda am_ri                    ; A = point am_ri's x (smul_14 takes X/Y)
        asl @
        tax
        lda.l B1CODE_BASE+am_arp,x
        rts
?y      lda am_ri                    ; ... and its y
        asl @
        tax
        lda.l B1CODE_BASE+am_arp+1,x
        rts
    .if zp_cos-zp_sin <> 2
        ert 'am_arot: zp_cos is zp_sin+2'
    .endif

;--------------------------------------------------------------
; am_m1 -- A = a signed byte, X = 0 sin / 2 cos: A (16-bit on return) = the
;   byte times the player's sin/cos (Q14), >> 14 (smul_14).
;--------------------------------------------------------------
.proc am_m1
        rep #$20
        .LONGA ON
        and #$00FF                   ; sign-extended: (b ^ $80) - $80
        eor #$0080
        sec
        sbc #$0080
        sta m_a
        lda zp_sin,x
        sta m_b
        .LONGA OFF
        sep #$20
        jmp smul_14                  ; (returns 16-bit, A = m_res)
.endp
        .endseg

        org am_amb

;==============================================================
; THE OVERLAY -- everything below runs only while the map is UP.
;--------------------------------------------------------------
; It is assembled for MENU_RUN ($1000) but PARKED at AMOVL_STAGE with MADS's
; two-address org, exactly like menu.asm and savegame.asm. 2026-08-31: it is
; NOT lifted into menu.bin any more -- the XEX carries the $D800 segment
; (STAGED in ram_map.py) and b1_to_ext copies it into Rapidus bank $01 at
; AMOVL_EXT at boot, because the day's HU-strip growth moved the melt over the
; overlay's old VRAM chunk and the VRAM map's "free" chunks all turned out to
; have tenants (the XDLs, MENUPATCH, the savegame overlay). Bank $01 has 20 KB
; spare and the copy-down is the same ~0.7 ms as the MEMW window was.
;
; IT IS RE-COPIED EVERY FRAME, not once on the TAB press. am_gate runs
; b1_amopen unconditionally while am_on is set, and that buys three things
; worth far more than the 0.7 ms --
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
; WIDTH DISCIPLINE. Every rep/sep is bracketed by .LONGA so MADS sizes the
; immediates; X goes 16-bit only for the bank-$03 arrays, loaded from two-byte
; cells.
;
; WHAT IT DRAWS -- am_map.c AM_Drawer at DOOM's own 320 x 168, on one of two
; SR surfaces (am_open): the one not on screen, shown through list A (S0) or
; B (S1) -- strip.asm's st_frame switches that list's view entries onto it.
;   AM_clearFB     a blitter fill of the surface.
;   AM_drawWalls   the seg loop, with AM_drawWalls' colour ladder verbatim,
;                  and the computer map's unseen lines in GRAYS+3.
;   AM_drawPlayers player_arrow's seven lines in map units, rotated.
;   AM_drawCrosshair the centre pixel.
;   HU_Drawer      the level's name, the message, the readout: strip.asm's
;                  chains 3/4, fired at the frame's tail.
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
;     at 4 world units per pixel the longest episode-1 line is ~1000 steps.
;==============================================================

; ---- am_map.c's palette. These are PLAYPAL indices and DOOM's own values ----
AM_BG       equ 0                    ; BACKGROUND = BLACK
AM_WALL     equ 176                  ; WALLCOLORS = REDS   (256-5*16)
AM_TELE     equ 176+8                ; WALLCOLORS + WALLRANGE/2 (teleporter)
AM_FDWALL   equ 64                   ; FDWALLCOLORS = BROWNS  (4*16): floor step
AM_CDWALL   equ 231                  ; CDWALLCOLORS = YELLOWS (256-32+7): ceiling
AM_YOU      equ 209                  ; YOURCOLORS = WHITE  (256-47)
AM_GRAY     equ 96+3                 ; GRAYS+3: the computer map's unseen lines
AM_XHAIR    equ 96                   ; XHAIRCOLORS = GRAYS
AM_CX       equ AM_W/2               ; the player's column ...
AM_CY       equ VIEW_HEIGHT/2        ;   ... and row: follow mode pins him here
AM_SHMIN    equ 2                    ; zoom limits: world units per pixel =
AM_SHMAX    equ 6                    ;   1<<am_sh, on both axes (320 SR: a pixel
AM_SH0      equ 3                    ;   is square). 8 u/px: near DOOM's start

        org MENU_RUN, AMOVL_STAGE

;--------------------------------------------------------------
; am_head -- THE FIRST PAGE. am_gate (via b1_amgate) has copied it down from
;   Rapidus bank $01 (AMOVL_EXT) and jumped here; the other four pages are one
;   X-indexed long-read loop away -- X, not Y, because `lda.l abs24,y` does not
;   exist on the 65816. Same bootstrap shape as menu.asm's mn_head; no entry
;   index, this overlay has one way in.
;--------------------------------------------------------------
.proc am_head
        ldx #0
?p      lda.l EXT_BASE+AMOVL_EXT+$100,x
        sta MENU_RUN+$100,x
        lda.l EXT_BASE+AMOVL_EXT+$200,x
        sta MENU_RUN+$200,x
        lda.l EXT_BASE+AMOVL_EXT+$300,x
        sta MENU_RUN+$300,x
        lda.l EXT_BASE+AMOVL_EXT+$400,x
        sta MENU_RUN+$400,x
        inx
        bne ?p
        lda #BANK_EN | BANK_OVERHEAD ; the window ONTO the BCB bank
        sta VBXE_BANK_SEL
?pend   lda XDLA_PEND                ; the last flip published: ZFRONT is the
        bne ?pend                    ;   list on screen
        ldx #1                       ; the page: S0 on list A, unless list A is
        lda ZFRONT                   ;   up -- then S1 on list B. The one drawn
        beq ?pg                      ;   is never the one shown
        dex
?pg     stx zback_hi                 ; swap_buffers publishes list A or B
        lda am_psp,x                 ; am_plot for this surface: where S1's
        sta am_plot.sp+1             ;   second half starts (S0: never) and
        lda am_pc0,x                 ;   the halves' MEMAC chunk bases
        sta am_plot.c0+1
        lda am_pc1,x
        sta am_plot.c1+1
        lda am_pclr,x                ; AM_clearFB: the surface's clear chain
        pha
        jsr blitter_wait_t
        pla
        sta VBXE_BL_ADR0
        lda #>AM_CLRV
        sta VBXE_BL_ADR1
        lda #1
        sta VBXE_BL_START
        jsr am_keys                  ; AM_Ticker: the zoom keys, under the clear
        jsr blitter_wait_t           ; the CPU plots next
        jsr am_walls                 ; AM_drawWalls
        jmp am_arrow                 ; AM_drawPlayers, AM_drawCrosshair
.endp

;--------------------------------------------------------------
; am_keys -- AM_Ticker's half that survived the reductions: the zoom keys.
;   '-'/'<' out, '='/'>' in -- DOOM's AM_ZOOMOUTKEY/AM_ZOOMINKEY, and the same
;   two keys the 3D view is resized with, which is why am_kgate keeps read_keys
;   out of the way while the map is up.
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
;--------------------------------------------------------------
.proc am_walls
        rep #$20                     ; ---- 16-bit A: the three counters and the
        .LONGA ON                    ;   bound are words
        stz am_i2                    ; the loop variable is the AMSEG STRIDE (i*2)
        stz am_i8                    ;   rather than i, and x8 (the seg record)
        stz am_iskip                 ;   and >>3 (the AMSKIP byte) walk with it
        lda MAP_HNSEG                ; bound = this level's seg count x2
        asl @
        sta am_nseg2
        sep #$20
        .LONGA OFF
        lda #1
        sta am_smask
?loop   rep #$20                     ; one word compare, not a byte chain
        .LONGA ON
        lda am_i2
        cmp am_nseg2
        sep #$20                     ; (C survives)
        .LONGA OFF
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
?vis    stz am_gry                   ; 0: the ladder decides the colour
        rep #$10                     ; --- AMSEG[i] = &AMSEEN[its linedef] ---
        ldx am_i2
        lda.l AMSEG_EXT,x
        sta am_slot
        lda.l AMSEG_EXT+1,x
        sta am_slot+1
        ldx am_slot                  ; --- ML_MAPPED? am_mark wrote a non-zero
        lda.l AM_BANK0,x             ;     address here the first time this line
        ora.l AM_BANK0+1,x           ;     was rendered (r_segs.c:398)
        bne ?seen
        lda PW_FLAGS                 ; not lit by the walk -- but the COMPUTER MAP
        and #PWF_ALLMAP              ;   reveals it anyway, in GRAYS+3 (am_map.c:
        beq ?none                    ;   the pw_allmap arm of AM_drawWalls). ?seen
        lda #AM_GRAY                 ;   still drops LINE_NEVERSEE, which is what
        sta am_gry                   ;   that arm does too
        bra ?seen
?none
        sep #$10                     ; never seen and no map -> nothing
        jmp ?next
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
        lda am_gry
        bne ?col
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
        beq ?next 
        ;bra ?next                    ; same floor AND ceiling -> invisible, as
?cd     lda #AM_CDWALL               ;   in DOOM (only the IDDT cheat shows it)
?col    sta am_col
        jsr am_draw
?next   rep #$21                     ; ---- 16-bit A, C=0: i2 += 2, i8 += 8
        .LONGA ON
        lda am_i2
        inc @
        inc @
        sta am_i2
        lda am_i8
        adc #8
        sta am_i8
        sep #$20
        .LONGA OFF
        asl am_smask                 ; ... and the AMSKIP bit walks with it
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
?one    rep #$20                     ; ---- 16-bit A: id*8 + MAP_SECTORS, in A
        .LONGA ON
        and #$FF                     ; (the byte load left junk in B)
        asl @
        asl @
        asl @                        ; a sector id is < 8192: the shifts carry 0,
        adc #MAP_SECTORS             ;   so no clc
        sta zp_ptr,x                 ; x=0 -> zp_ptr, x=3 -> zp_tsrc (the .if above
        sep #$20                     ;   guards the adjacency); +2, the bank
        .LONGA OFF                   ;   byte, is not touched
        rts
.endp

;--------------------------------------------------------------
; am_cmp -- Y = field offset (0 = floor_h, 2 = ceil_h). Z=1 if the front and
;   back sectors agree on it. Clobbers A/Y.
;--------------------------------------------------------------
.proc am_cmp
        rep #$20                     ; ---- 16-bit A: one compare (Z survives the sep)
        .LONGA ON
        lda (zp_ptr),y
        cmp (zp_tsrc),y
        sep #$20
        .LONGA OFF
        rts
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
        jsr load_vertex_t
        ldx #0                       ; am_proj stores THROUGH X -- see below
        jsr am_proj
        lda am_v2
        sta zp_vidx
        lda am_v2+1
        sta zp_vidx+1
        jsr load_vertex_t
        ldx #am_x2-am_x1
        jsr am_proj
        jmp am_line
.endp

;--------------------------------------------------------------
; am_proj -- MTOF: zp_rx/zp_ry (world, player-relative) -> the line end X selects
;   (X = 0 -> am_x1/am_y1, X = 4 -> am_x2/am_y2; the two points are adjacent
;   4-byte {x,y} pairs at the bottom of the scratch block, which is what makes
;   the index work). 2026-08-14: this REPLACED a separate am_sx/am_sy landing
;--------------------------------------------------------------
.proc am_proj
        rep #$20                     ; ---- 16-bit A: the arithmetic shifts in the
        .LONGA ON                    ;   accumulator (cmp #$8000 puts the sign in
        lda zp_rx                    ;   C, ror brings it back in on top)
        ldy am_sh                    ; sx = 160 + (rx >> sh)
?xs     cmp #$8000
        ror @
        dey
        bne ?xs
        clc
        adc #AM_CX
        sta am_x1,x
        lda zp_ry                    ; sy = 84 - (ry >> sh)
        ldy am_sh
?ys     cmp #$8000
        ror @
        dey
        bne ?ys
        eor #$FFFF                   ; AM_CY - t, as ~t + 1 + AM_CY
        sec
        adc #AM_CY
        sta am_y1,x
        sep #$20
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; am_line -- (am_x1,am_y1)-(am_x2,am_y2), signed 16-bit, colour am_col.
;--------------------------------------------------------------
.proc am_line
        rep #$20                     ; ---- 16-bit A for the whole line, am_plot
        .LONGA ON                    ;   included
        lda am_x1
        and am_x2
        bmi ?rej                     ; both x < 0
        lda am_y1
        and am_y2
        bmi ?rej                     ; both y < 0
        sec
        lda am_x1
        sbc #AM_W
        sta am_t
        sec
        lda am_x2
        sbc #AM_W
        ora am_t
        bpl ?rej                     ; both x >= 320
        sec
        lda am_y1
        sbc #VIEW_HEIGHT
        sta am_t
        sec
        lda am_y2
        sbc #VIEW_HEIGHT
        ora am_t
        bmi ?ok                      ; at least one is above the bottom edge
?rej    sep #$20
        .LONGA OFF
        rts
?ok     .LONGA ON                    ; (still 16-bit on this path)
                                      ; 2026-09-23: a step is ONE `inc/dec am_x1|am_y1`
        sec                          ;   (16-bit RMW) whose opcode is patched here
        lda am_x2                    ;   once a line, in one loop per major axis: no
        sbc am_x1                    ;   `lda am_x1,x / clc / adc am_stx,x / sta`, and
        bpl ?dxp                     ;   err is stored once (-12 a pixel, -29 on a
        eor #$FFFF                   ;   minor step). Same decisions, same pixels.
        inc @
        ldx #$CE                     ; `dec abs`: x runs down
        bra ?dxs
?dxp    ldx #$EE                     ; `inc abs`: x runs up
?dxs    sta am_dx
        stx ?xmj                     ; (the overlay runs in bank-0 RAM: plain stores)
        stx ?xmn
        sec
        lda am_y2
        sbc am_y1
        bpl ?dyp
        eor #$FFFF
        inc @
        ldx #$CE
        bra ?dys
?dyp    ldx #$EE
?dys    sta am_dy
        stx ?ymj
        stx ?ymn
        lda am_dx
        cmp am_dy
        bcc ?ymaj                    ; dx < dy: y is the major axis (dx = dy: x)
        lsr @                        ; err = major >> 1 ; n = major + 1
        sta am_err
        lda am_dx
        inc @
        sta am_n
?lx     jsr am_plot                  ; (16-bit in and out)
        sec
        lda am_err
        sbc am_dy                    ; err -= minor
        bpl ?nsx
        adc am_dx                    ; err += major (C = 0: the sbc borrowed)
        sta am_err
?ymn    inc am_y1                    ; SMC: the MINOR step
        bra ?jx
?nsx    sta am_err
?jx
?xmj    inc am_x1                    ; SMC: the MAJOR step
        dec am_n
        bne ?lx
        sep #$20
        .LONGA OFF
        rts
        .LONGA ON
?ymaj   lda am_dy
        lsr @
        sta am_err
        lda am_dy
        inc @
        sta am_n
?ly     jsr am_plot
        sec
        lda am_err
        sbc am_dx                    ; minor = dx here
        bpl ?nsy
        adc am_dy
        sta am_err
?xmn    inc am_x1                    ; SMC: the MINOR step
        bra ?jy
?nsy    sta am_err
?jy
?ymj    inc am_y1                    ; SMC: the MAJOR step
        dec am_n
        bne ?ly
        sep #$20
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; am_dec -- the loop tail. n counts the MAJOR axis and a line is n+1 pixels
;   long, so the test comes AFTER the plot. Returns Z=1 when done.
;--------------------------------------------------------------



;--------------------------------------------------------------
; am_plot -- one pixel of am_col at (am_x1,am_y1) onto this frame's surface,
;   through the MEMAC window: row*320 + x in its half, the half's chunk base
;   (am_head patches sp/c0/c1 for S0 or S1). Anything outside the view is
;   dropped by UNSIGNED compares (a negative is a huge word). Entered and left
;   in 16-bit A (am_line's loop).
;--------------------------------------------------------------
.proc am_plot
        .LONGA ON
        lda am_x1
        cmp #AM_W
        bcs ?out
        lda am_y1
        cmp #VIEW_HEIGHT
        bcs ?out
        sep #$20
        .LONGA OFF
        tay                          ; the row (< VIEW_HEIGHT)
sp      cpy #VIEW_HEIGHT             ; SMC: S1's split row -- S0's never comes
        bcs ?bot                     ;   (out of line: S0 and S1's top fall through)
c0      lda #0                       ; SMC: the first half's chunk base
?h      sta am_ck
        lda row_hi,y                 ; B:A = row*160
        xba
        lda row_lo,y
        rep #$21
        .LONGA ON
        asl @                        ; row*320 + x < 53760: no carry anywhere
        adc am_x1
        sta zp_ptr
        .LONGA OFF
        sep #$20
        xba                          ; A = its page
        tay
        lsr @
        lsr @
        lsr @
        lsr @                        ; its 4 KB chunk in the half
        ora am_ck
        cmp am_lastbk
        bne ?bk                      ; a new 4 KB chunk: out of line (rare)
?same   tya
        and #$3F                     ; the 14-bit offset in the 16 KB page
        ora #>MEMW16
        sta zp_ptr+1
        lda am_col
        sta (zp_ptr)
        rep #$20
        .LONGA ON
?out    rts
        .LONGA OFF
?bot    tya                          ; (C = 1) the second half's own row
        sbc #AM_S1B
        tay
c1      lda #0                       ; SMC: ... and its chunk base
        bra ?h
?bk     sta am_lastbk
        sta VBXE_BANK_SEL
        bra ?same
.endp
;   per page (0 = S0 on list A, 1 = S1 on list B)
am_psp  dta VIEW_HEIGHT, AM_S1B
am_pc0  dta BANK_EN|[AM_S0>>12], BANK_EN|[AM_S1>>12]
am_pc1  dta 0, BANK_EN|[AM_S1B2>>12]
am_pclr dta <AM_CLRV, <[AM_CLRV+BCB_SIZE]

;--------------------------------------------------------------
; am_arrow -- AM_drawPlayers: player_arrow's seven lines, in MAP units and
;   rotated by the player's angle (am_arot), so it grows and shrinks with the
;   zoom as DOOM's does; then AM_drawCrosshair's one pixel at the centre.
;--------------------------------------------------------------
AM_NARL equ 7
.proc am_arrow
        jsl B1CODE_BASE+am_arot_w1
        lda #AM_YOU
        sta am_col
        ldx #2*AM_NARL-2             ; the lines, last first (the line index
?l      phx                          ;   rides the stack: am_proj takes X and Y)
        ldy am_alin,x                ; the line's first point -> am_x1/am_y1
        ldx #0
        jsr am_ppt
        plx
        phx
        ldy am_alin+1,x              ; ... and its second -> am_x2/am_y2
        ldx #am_x2-am_x1
        jsr am_ppt
        jsr am_line
        plx
        dex
        dex
        bpl ?l
        lda #AM_XHAIR                ; fb[(f_w*(f_h+1))/2]: (160, 84)
        sta am_col
        rep #$20
        .LONGA ON
        lda #AM_CX
        sta am_x1
        lda #AM_CY
        sta am_y1
        jsr am_plot
        .LONGA OFF
        sep #$20
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp
;   player_arrow's lines as pairs of am_apt offsets (point * 4)
am_alin dta 0*4,1*4, 1*4,2*4, 1*4,3*4, 0*4,4*4, 0*4,5*4, 6*4,7*4, 6*4,8*4

;--------------------------------------------------------------
; am_ppt -- Y = a point's offset in am_apt, X = which end: am_proj.
;--------------------------------------------------------------
.proc am_ppt
        rep #$20
        .LONGA ON
        lda am_apt,y
        sta zp_rx
        lda am_apt+2,y
        sta zp_ry
        .LONGA OFF
        sep #$20
        jmp am_proj
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
am_ck    dta 0                       ; am_plot: the half's chunk base
am_gry   dta 0                       ; am_walls: GRAYS+3, or 0 (the ladder)
am_ri    dta 0                       ; am_arot's point
am_apt   :AM_NARP*4 dta 0            ; player_arrow, rotated: {x, y} words
am_t     dta a(0)
am_lastbk dta $FF                    ; the MEMAC bank last selected ($FF = none,
                                     ;   so the first plot of a frame always
                                     ;   writes VBXE_BANK_SEL)

    .if * > MENU_RUN_END+1
        ert 'the automap overlay outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
        org am_amb
