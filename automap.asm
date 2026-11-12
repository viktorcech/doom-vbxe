am_resume = *
        org AMMARK_BASE

;--------------------------------------------------------------
; sg_amout / sg_amin -- BUG FIX 2026-09-15: the SEEN marks go into the save.
;--------------------------------------------------------------
AM_SEEN_N equ [MAP_AMFLG-MAP_AMSEEN]/2
    .if AM_SEEN_N > 2*128*8
        ert 'AMSEEN holds more linedefs than the save bitmap page (SGK_AMB)'
    .endif
        .segment B1
.proc sg_amout                       ; AMSEEN -> SG_BUF (save)
        rep #$30                     ; BRIDGE: the savegame overlay calls 8-bit
        .LONGA ON
        .LONGI ON
        jsr sg_amptr
        ldx #0
?word   lda #16                      ; 16 bits = the two bitmap bytes at X
        sta sg_ambc
?bit    lda zp_ptr                   ; past the table? AMFLG follows it: a 0 bit
        cmp #MAP_AMFLG
        bcc ?in
        clc
        bcc ?put                     ; (always)
?in     lda [zp_ptr]                 ; the slot's word
        cmp #1                       ; C = the slot is non-zero (SEEN)
?put    rol sg_ambits
        jsr sg_amnext
        dec sg_ambc
        bne ?bit
        lda sg_ambits                ; the first bit is bit 15: xba puts it at
        xba                          ;   bit 7 of the byte at X, the order the
        sta SG_BUF,x                 ;   byte-wise rol made
        inx
        inx
        cpx #128
        bcc ?word
        sep #$30                     ; BRIDGE: back to the 8-bit overlay
        .LONGA OFF
        .LONGI OFF
        lda #MAP_EXT_BANK            ; the parked bank back, then home (a jsl'd
        sta zp_ptr+2                 ;   proc carries its own rtl: b1_check)
        rtl
.endp
        .endseg

        .segment B1
.proc sg_amin                        ; SG_BUF -> AMSEEN (load, over the fresh zeros)
        rep #$30                     ; BRIDGE: the savegame overlay calls 8-bit
        .LONGA ON
        .LONGI ON
        jsr sg_amptr
        ldx #0
?word   lda SG_BUF,x                 ; the two bitmap bytes, the byte at X in
        xba                          ;   the high half: its bit 7 is bit 15
        sta sg_ambits
        lda #16
        sta sg_ambc
?bit    asl sg_ambits                ; bit 15 first, the order sg_amout rol'd in
        bcc ?nx
        lda zp_ptr                   ; never past the table (that is AMFLG)
        cmp #MAP_AMFLG
        bcs ?nx
        lda zp_ptr                   ; the slot's OWN address, which is exactly
        sta [zp_ptr]                 ;   what am_mark stores there
?nx     jsr sg_amnext
        dec sg_ambc
        bne ?bit
        inx
        inx
        cpx #128
        bcc ?word
        sep #$30                     ; BRIDGE: back to the 8-bit overlay
        .LONGA OFF
        .LONGI OFF
        lda #MAP_EXT_BANK            ; the parked bank back, then home (a jsl'd
        sta zp_ptr+2                 ;   proc carries its own rtl: b1_check)
        rtl
.endp
        .endseg

        .segment B1
        .LONGA ON
        .LONGI ON
.proc sg_amptr                       ; zp_ptr = AMSEEN slot of bit sg_src*8, bank $03
        lda sg_src
        asl @                        ; *16: 8 bits a byte, 2 B a slot
        asl @
        asl @
        asl @
        clc
        adc #MAP_AMSEEN
        sta zp_ptr
        xba                          ; zp_ptr+1 again and the bank in zp_ptr+2:
        and #$00FF                   ;   one word, zp_tsrc behind it untouched
        ora #MAP_SEG_BANK*256
        sta zp_ptr+1
        rts
.endp
        .endseg

        .segment B1
.proc sg_amnext                      ; zp_ptr += 2 (the next linedef's slot)
        lda zp_ptr
        clc
        adc #2
        sta zp_ptr
        rts
.endp
        .LONGA OFF
        .LONGI OFF
        .endseg

        .segment D0
sg_ambc dta a(0)                     ; bits left in the current bitmap word
sg_ambits dta a(0)                   ; the bitmap word being shifted
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
        .segment B1
.proc am_gate
        jml B1CODE_BASE+b1_amgate    ; the WHOLE gate runs in bank $01 now
.endp                                ;   (b1_amgate: test am_on, serve page 1 of
        .endseg
                                     ;   the overlay from AMOVL_EXT, jml into ...

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
        .segment B1
.proc am_kgate
        rep #$30                     ; BRIDGE: game_loop calls 8-bit
        .LONGA ON
        .LONGI ON
        lda am_on
        and #$00FF                   ; (a byte: am_sh is behind it)
        bne ?am                      ; the map up: out of line
?keys   sep #$30                     ; BRIDGE: read_keys is 8-bit
        .LONGA OFF
        .LONGI OFF
        jmp read_keys
?am     sep #$30                     ; 8-bit: POKEY, and both exits are 8-bit
        lda SKSTAT
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

;--------------------------------------------------------------
; am_wgate -- no player sprite over the map. DOOM's automap replaces the view,
;   gun and all; the status bar stays, which is why only draw_weapon is gated
;   and draw_hud_gate's other three calls run as usual.
;--------------------------------------------------------------
        .segment B1
.proc am_wgate
        rep #$30                     ; BRIDGE: hud calls 8-bit
        .LONGA ON
        .LONGI ON
        lda am_on
        and #$00FF                   ; (a byte: am_sh is behind it)
        sep #$30                     ; BRIDGE: both exits are 8-bit (Z survives)
        .LONGA OFF
        .LONGI OFF
        bne ?skip
        jmp draw_weapon
?skip   rts
.endp
        .endseg

;--------------------------------------------------------------
; am_key -- TAB toggles the map (AM_STARTKEY / AM_ENDKEY, am_map.c:96-97).
;--------------------------------------------------------------
        .segment B1
.proc am_key
        rep #$30                     ; BRIDGE: mn_key jumps here 8-bit
        .LONGA ON
        .LONGI ON
        and #$00FF                   ; the key code (B was not ours)
        cmp #KEY_TAB
        bne ?ret
        lda mn_arm
        and #$00FF                   ; (a byte)
        beq ?ret
        dec mn_arm                   ; acts once per press (mn_arm was 1: no
                                     ;   borrow into the byte behind it)
        lda am_on                    ; the word am_on|am_sh: bit 0 flips, am_sh
        eor #1                       ;   is stored back as it was. Toggle 0 <-> 1:
        sta am_on                    ;   the flag stopped carrying a VRAM bank when
                                     ;   the overlay moved to Rapidus bank $01
        and #$00FF                   ;   (am_gate jsl's ...
        beq ?v                       ; AM_Stop: the lists follow by themselves
        jsr am_open                  ; AM_Start (st_frame switches the lists)
?v      lda #3                       ; ...and re-arm the BORDER repaint, ONCE.
        sep #$30                     ; (vw_dirty is a byte)
        .LONGA OFF
        .LONGI OFF
        sta vw_dirty                 ;   render_world only re-opens the columns
                                     ;   vw_x0..vw_xend (renderer.asm), so ...
?ret    sep #$30                     ; BRIDGE: fps_key is 8-bit
        jmp fps_key                  ; the tail this displaced
.endp
        .endseg

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
        sep #$20                     ; 8-bit: st_tlev is a byte (st_tw behind
        .LONGA OFF                   ;   it) and VBXE_BANK_SEL a register
        lda #$FF
        sta st_tlev
        lda #BANK_EN | [AM_CLRV>>12]
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
        .LONGI ON
        ldx #3*BCB_SIZE-1            ; 32 words (the last is the pad)
?w      lda.l B1CODE_BASE+am_cimg,x  ; long,x both ways: bank $01 data, and no
        sta.l AM_CWIN,x              ;   dummy read of the window
        dex
        dex
        bpl ?w
        sep #$20                     ; VBXE_BANK_SEL is a register
        .LONGA OFF
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
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
        pha
        jsr ?y
        ldx #0
        jsr am_m1                    ; y sin
        eor #$FFFF                   ; x' = x cos - y sin
        sec
        adc 1,s
        sta 1,s
        jsr ?x
        ldx #0
        jsr am_m1                    ; x sin
        pha
        jsr ?y
        ldx #zp_cos-zp_sin
        jsr am_m1                    ; y cos
        clc
        adc 1,s                      ; y' = x sin + y cos
        sta 1,s
        lda am_ri
        and #$00FF
        asl @
        asl @
        tax
        pla
        sta am_apt+2,x
        pla
        sta am_apt,x
        dec am_ri
        bpl ?p
        rtl
?x      lda am_ri                    ; A = point am_ri's x (smul_14 takes X/Y;
        asl @                        ;   am_m1 keeps the low byte of the word)
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
        and #$00FF                   ; sign-extended: (b ^ $80) - $80
        eor #$0080
        sec
        sbc #$0080
        sta m_a
        lda zp_sin,x
        sta m_b
        sep #$30                     ; BRIDGE: smul_14 (math.asm) is 8-bit ...
        .LONGA OFF
        .LONGI OFF
        jsr smul_14
        rep #$30                     ;   ... and returns with 16-bit A
        .LONGA ON
        .LONGI ON
        rts
.endp
        .LONGA OFF
        .LONGI OFF
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
        rep #$30                     ; BRIDGE: menu_run_w0 calls 8-bit
        .LONGA ON
        .LONGI ON
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
        inx
        cpx #$100
        bne ?p
        sep #$20                     ; 8-bit: VBXE registers, the byte flags
        .LONGA OFF                   ;   and the byte-wide patches below
        lda #BANK_EN | BANK_OVERHEAD ; the window ONTO the BCB bank
        sta VBXE_BANK_SEL
?pend   lda XDLA_PEND                ; the last flip published: ZFRONT is the
        bne ?pend                    ;   list on screen
        ldx #1                       ; the page: S0 on list A, unless list A is
        lda ZFRONT                   ;   up -- then S1 on list B. The one drawn
        beq ?pg                      ;   is never the one shown
        dex
?pg     txa                          ; swap_buffers publishes list A or B
        sta zback_hi                 ;   (a byte: a 16-bit stx would write two)
        lda am_psp,x                 ; am_plot for this surface: where S1's
        sta am_plot.sp+1             ;   second half starts (S0: never) and
        lda am_pc0,x                 ;   the halves' MEMAC chunk bases
        sta am_plot.c0+1
        lda am_pc1,x
        sta am_plot.c1+1
        lda am_pclr,x                ; AM_clearFB: the surface's clear chain
        pha
        sep #$10                     ; BRIDGE: blitter_wait is 8-bit
        .LONGI OFF
        jsr blitter_wait_t
        pla
        sta VBXE_BL_ADR0
        lda #>AM_CLRV
        sta VBXE_BL_ADR1
        lda #1
        sta VBXE_BL_START
        rep #$30
        .LONGA ON
        .LONGI ON
        jsr am_keys                  ; AM_Ticker: the zoom keys, under the clear
        sep #$30                     ; BRIDGE: blitter_wait is 8-bit
        .LONGA OFF
        .LONGI OFF
        jsr blitter_wait_t           ; the CPU plots next
        rep #$30
        .LONGA ON
        .LONGI ON
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
        and #$00FF                   ; (a byte: am_karm is behind it)
        cmp #AM_SHMIN
        bcc ?init
        cmp #AM_SHMAX+1
        bcc ?ok
?init   lda am_sh                    ; the word am_sh|am_karm: am_karm is
        and #$FF00                   ;   stored back as it was
        ora #AM_SH0
        sta am_sh
?ok     sep #$30                     ; 8-bit: POKEY, and the byte cells am_karm
        .LONGA OFF                   ;   and am_sh
        .LONGI OFF
        ldx #0                       ; X = the zoom key down this frame
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
        bra ?ret
?out    lda am_sh
        cmp #AM_SHMAX
        beq ?ret
        inc am_sh
?ret    rep #$30
        .LONGA ON
        .LONGI ON
        rts
.endp

;--------------------------------------------------------------
; am_walls -- AM_drawWalls (am_map.c:1114), over SEGS instead of linedefs.
;   The colour ladder is DOOM's, in DOOM's order, and every test it makes is a
;   test this port can actually answer:
;       no back sector          -> WALLCOLORS      (a solid wall)
;--------------------------------------------------------------
.proc am_walls
        stz am_i2                    ; the loop variable is the AMSEG STRIDE (i*2)
        stz am_i8                    ;   rather than i, and x8 (the seg record)
        stz am_iskip                 ;   and >>3 (the AMSKIP byte) walk with it
        lda MAP_HNSEG                ; bound = this level's seg count x2
        asl @
        sta am_nseg2
        lda #1
        sta am_smask
?loop   lda am_i2
        cmp am_nseg2
        bcc ?go
?dn     rts                          ; every seg walked -- the exit is HERE and
                                     ;   not at the bottom, so the test that
                                     ;   reaches it stays a short branch
?go
                                     ; --- AMSKIP: the BACK side of a two-sided
        ldx am_iskip                 ;     line is MARKED but never drawn (its
        lda.l AMSKIP_EXT,x           ;     front side's segs tile the same line)
        and am_smask                 ;   (a word with the high byte 0: the byte
        beq ?vis                     ;   behind the AMSKIP one drops out)
?nx     jmp ?next                    ; ?next is out of branch range from up here,
                                     ;   so the early exits go through this
?vis    stz am_gry                   ; 0: the ladder decides the colour
                                     ; --- AMSEG[i] = &AMSEEN[its linedef] ---
        ldx am_i2
        lda.l AMSEG_EXT,x
        sta am_slot
        ldx am_slot                  ; --- ML_MAPPED? am_mark wrote a non-zero
        lda.l AM_BANK0,x             ;     address here the first time this line
                                     ;     was rendered (r_segs.c:398)
        bne ?seen
        lda PW_FLAGS                 ; not lit by the walk -- but the COMPUTER MAP
        and #PWF_ALLMAP              ;   reveals it anyway, in GRAYS+3 (am_map.c:
        beq ?none                    ;   the pw_allmap arm of AM_drawWalls). ?seen
        lda #AM_GRAY                 ;   still drops LINE_NEVERSEE, which is what
        sta am_gry                   ;   that arm does too
        bra ?seen
?none
                                     ; never seen and no map -> nothing
        bra ?next
?seen   lda.l AMFLG_EXT_D,x          ; ... and its flags, same X, fixed delta
        sta am_flg                   ;   (the word: every test below is an and
        and #AMF_DONTDRAW            ;   with a byte mask) LINE_NEVERSEE: never on the automap
        bne ?nx
                                     ; --- the seg record ---
        ldx am_i8
        lda.l SEGS_EXT+SEG_BACK,x
        and #$00FF                   ; (bytes in the record)
        sta am_back
        lda.l SEGS_EXT+SEG_FRONT,x
        and #$00FF
        sta am_front
        lda.l SEGS_EXT+SEG_V1,x
        sta am_v1
        lda.l SEGS_EXT+SEG_V2,x
        sta am_v2
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
?next   clc                          ; ---- i2 += 2, i8 += 8
        lda am_i2
        inc @
        inc @
        sta am_i2
        lda am_i8
        adc #8
        sta am_i8
        asl am_smask                 ; ... and the AMSKIP bit walks with it
        lda am_smask                 ;   (a word: past bit 7 is the next byte)
        cmp #$0100
        bcc ?lp
        lda #1
        sta am_smask
        inc am_iskip
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
?one    and #$FF                     ; ---- id*8 + MAP_SECTORS, in A
        asl @
        asl @
        asl @                        ; a sector id is < 8192: the shifts carry 0,
        adc #MAP_SECTORS             ;   so no clc
        sta zp_ptr,x                 ; x=0 -> zp_ptr, x=3 -> zp_tsrc (the .if above
                                     ;   guards the adjacency); +2, the bank
                                     ;   byte, is not touched
        rts
.endp

;--------------------------------------------------------------
; am_cmp -- Y = field offset (0 = floor_h, 2 = ceil_h). Z=1 if the front and
;   back sectors agree on it. Clobbers A/Y.
;--------------------------------------------------------------
.proc am_cmp
        lda (zp_ptr),y
        cmp (zp_tsrc),y
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
        sep #$30                     ; BRIDGE: load_vertex is 8-bit
        .LONGA OFF
        .LONGI OFF
        jsr load_vertex_t
        rep #$30
        .LONGA ON
        .LONGI ON
        ldx #0                       ; am_proj stores THROUGH X -- see below
        jsr am_proj
        lda am_v2
        sta zp_vidx
        sep #$30                     ; BRIDGE: load_vertex is 8-bit
        .LONGA OFF
        .LONGI OFF
        jsr load_vertex_t
        rep #$30
        .LONGA ON
        .LONGI ON
        ldx #am_x2-am_x1
        jsr am_proj
        bra am_line
.endp

;--------------------------------------------------------------
; am_proj -- MTOF: zp_rx/zp_ry (world, player-relative) -> the line end X selects
;   (X = 0 -> am_x1/am_y1, X = 4 -> am_x2/am_y2; the two points are adjacent
;   4-byte {x,y} pairs at the bottom of the scratch block, which is what makes
;   the index work). 2026-08-14: this REPLACED a separate am_sx/am_sy landing
;--------------------------------------------------------------
.proc am_proj
        lda am_sh                    ; (a byte: am_karm is behind it)
        and #$00FF
        tay                          ; ---- the arithmetic shifts in the
        lda zp_rx                    ;   accumulator (cmp #$8000 puts the sign in
                                     ;   C, ror brings it back in on top)
                                     ; sx = 160 + (rx >> sh)
?xs     cmp #$8000
        ror @
        dey
        bne ?xs
        clc
        adc #AM_CX
        sta am_x1,x
        lda am_sh
        and #$00FF
        tay
        lda zp_ry                    ; sy = 84 - (ry >> sh)
?ys     cmp #$8000
        ror @
        dey
        bne ?ys
        eor #$FFFF                   ; AM_CY - t, as ~t + 1 + AM_CY
        sec
        adc #AM_CY
        sta am_y1,x
        rts
.endp

;--------------------------------------------------------------
; am_line -- (am_x1,am_y1)-(am_x2,am_y2), signed 16-bit, colour am_col.
;--------------------------------------------------------------
.proc am_line
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
?rej    rts
?ok
                                      ; 2026-09-23: a step is ONE `inc/dec am_x1|am_y1`
        sec                          ;   (16-bit RMW) whose opcode is patched here
        lda am_x2                    ;   once a line, in one loop per major axis: no
        sbc am_x1                    ;   `lda am_x1,x / clc / adc am_stx,x / sta`, and
        bpl ?dxp                     ;   err is stored once (-12 a pixel, -29 on a
        eor #$FFFF                   ;   minor step). Same decisions, same pixels.
        inc @
        ldx #$CE+[<am_x1]*256        ; `dec abs`: x runs down. X is a WORD: the
        bra ?dxs                     ;   opcode and the operand's low byte, which
?dxp    ldx #$EE+[<am_x1]*256        ;   the store writes back as it was
?dxs    sta am_dx                    ; `inc abs`: x runs up
        stx ?xmj                     ; (the overlay runs in bank-0 RAM: plain stores)
        stx ?xmn
        sec
        lda am_y2
        sbc am_y1
        bpl ?dyp
        eor #$FFFF
        inc @
        ldx #$CE+[<am_y1]*256
        bra ?dys
?dyp    ldx #$EE+[<am_y1]*256
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
        rts
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
        lda am_x1
        cmp #AM_W
        bcs ?out
        lda am_y1
        cmp #VIEW_HEIGHT
        bcs ?out
        tay                          ; the row (< VIEW_HEIGHT)
sp      cpy #VIEW_HEIGHT             ; SMC: S1's split row -- S0's never comes
        bcs ?bot                     ;   (out of line: S0 and S1's top fall through)
c0      lda #0                       ; SMC: the first half's chunk base
?h      sta am_ck
        lda row_lo,y                 ; row*160 out of the two byte tables:
        and #$00FF                   ;   the low byte ...
        sta am_t
        lda row_hi,y                 ;   ... and the high one, xba'd up
        xba
        and #$FF00
        ora am_t
        asl @                        ; row*320 + x < 53760: no carry anywhere
        adc am_x1                    ;   (row*160 < $8000: the asl leaves C = 0)
        sta zp_ptr                   ; the offset in the half, for now
        xba                          ; A = its page
        and #$00FF
        lsr @
        lsr @
        lsr @
        lsr @                        ; its 4 KB chunk in the half
        ora am_ck
        cmp am_lastbk
        bne ?bk                      ; a new 4 KB chunk: out of line (rare)
?same   lda zp_ptr                   ; the 14-bit offset in the 16 KB page,
        and #$3FFF                   ;   as one word: zp_ptr+2 (the bank) is
        ora #MEMW16                  ;   not touched
        sta zp_ptr
        sep #$20                     ; 8-bit: ONE pixel byte into VRAM
        .LONGA OFF
        lda am_col
        sta (zp_ptr)
        rep #$20
        .LONGA ON
?out    rts
?bot    tya                          ; (C = 1) the second half's own row
        sbc #AM_S1B
        tay
c1      lda #0                       ; SMC: ... and its chunk base
        bra ?h
?bk     sta am_lastbk
        sep #$20                     ; VBXE_BANK_SEL is a register
        .LONGA OFF
        sta VBXE_BANK_SEL
        rep #$20
        .LONGA ON
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
        lda am_alin,x                ; the line's first point -> am_x1/am_y1
        and #$00FF                   ;   (a byte table)
        tay
        ldx #0
        jsr am_ppt
        plx
        phx
        lda am_alin+1,x              ; ... and its second -> am_x2/am_y2
        and #$00FF
        tay
        ldx #am_x2-am_x1
        jsr am_ppt
        jsr am_line
        plx
        dex
        dex
        bpl ?l
        lda #AM_XHAIR                ; fb[(f_w*(f_h+1))/2]: (160, 84)
        sta am_col
        lda #AM_CX
        sta am_x1
        lda #AM_CY
        sta am_y1
        jsr am_plot
        sep #$30                     ; VBXE_BANK_SEL is a register -- and the
        .LONGA OFF                   ;   BRIDGE: am_head's caller is 8-bit
        .LONGI OFF
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp
;   player_arrow's lines as pairs of am_apt offsets (point * 4)
am_alin dta 0*4,1*4, 1*4,2*4, 1*4,3*4, 0*4,4*4, 0*4,5*4, 6*4,7*4, 6*4,8*4

;--------------------------------------------------------------
; am_ppt -- Y = a point's offset in am_apt, X = which end: am_proj.
;--------------------------------------------------------------
        .LONGA ON
        .LONGI ON
.proc am_ppt
        lda am_apt,y
        sta zp_rx
        lda am_apt+2,y
        sta zp_ry
        jmp am_proj
.endp
        .LONGA OFF
        .LONGI OFF

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
am_smask dta a(1)                    ;   ... and 1 << (i & 7)
am_nseg2 dta a(0)                    ; the level's seg count x2, the loop bound
am_slot  dta a(0)                    ; &AMSEEN[this seg's linedef]
am_flg   dta a(0)                    ; that line's AMFLG byte (+ the one behind it)
am_front dta a(0)
am_back  dta a(0)
am_v1    dta a(0)
am_v2    dta a(0)
am_col   dta a(0)
am_dx    dta a(0)                    ; Bresenham: MAJOR delta after the swap ...
am_dy    dta a(0)                    ;   ... and MINOR
am_err   dta a(0)
am_n     dta a(0)
am_ck    dta a(0)                    ; am_plot: the half's chunk base
am_gry   dta a(0)                    ; am_walls: GRAYS+3, or 0 (the ladder)
am_ri    dta a(0)                    ; am_arot's point
am_apt   :AM_NARP*4 dta 0            ; player_arrow, rotated: {x, y} words
am_t     dta a(0)
am_lastbk dta a($FF)                 ; the MEMAC bank last selected ($FF = none,
                                     ;   so the first plot of a frame always
                                     ;   writes VBXE_BANK_SEL)

    .if * > MENU_RUN_END+1
        ert 'the automap overlay outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif
        org am_amb
