        org COLMERGE_BASE

; (cm_reset, cm_test and cm_defer -- the per-seg reset, the "would this column
;  draw exactly what the last one drew" signature compare and the deferred
;  column's bookkeeping -- live INLINE in process_seg's column loop since
;  2026-09-15/26 (seg_draw.asm ?mh_prime, ?cm_have, ?cm_do). The dead copies
;  that stood here went on 2026-10-05: 6502-idioms "code size is RAM", bank
;  $01 was down to 627 free bytes.)

;--------------------------------------------------------------
; CM_EMIT -- one copy link: A = the LAST row, Y = rows-1. Clobbers A/X/Y.
;   The body of cm_flush's ?emit subroutine (a macro since 2026-10-05).
;--------------------------------------------------------------
    .if TEX_RUNS
.macro CM_EMIT
        phy
        pha
        lda tw_chn                   ; X = the OPEN buffer's restore list, read here:
        sec                          ;   ?link's launch above flips the buffer
        sbc #>[MEMW+MEMW_CHA_OFF]
        lsr
        lsr
        tax
        asl                          ; entry = list*CM_RMAX + count (count < CM_RMAX)
        asl
        ora cm_rc,x
        tay
        inc cm_rc,x
    .if CM_RMAX != 4
        ert 'cm_flush indexes its restore lists as list*4 + count'
    .endif
        rep #$20
        .LONGA ON
        lda zp_pt                    ; zp_pt -> the slot's DST field: back to its base
    .if PT_ZPOFF                     ;   (FX127: it is the base already)
        sec
        sbc #PT_ZPOFF
        sta zp_pt
    .endif
        .LONGA OFF
        sep #$20
        sta cm_rlo,y                 ; ... and the base is the restore entry
        xba
        sta cm_rhi,y
        rep #$20                     ; ptc_open's hook: `jsl cm_rest` over its bra
        .LONGA ON
  .if STRIP                    ; (2026-10-15: ps_rest, which puts the strips'
        lda #$22|[[[B1CODE_BASE+ps_rest]&$FF]<<8]   ;   slots back and then calls
        sta.l B1CODE_BASE+ptc_rsh                   ;   cm_rest itself)
        lda #[[[B1CODE_BASE+ps_rest]>>8]&$FFFF]
  .else
        lda #$22|[[[B1CODE_BASE+cm_rest]&$FF]<<8]
        sta.l B1CODE_BASE+ptc_rsh
        lda #[[[B1CODE_BASE+cm_rest]>>8]&$FFFF]
  .endif
        sta.l B1CODE_BASE+ptc_rsh+2
        .LONGA OFF
        sep #$20
        plx                          ; row -> framebuffer offset. A:B = row*160 + x:
        lda row_hi,x                 ;   the carry goes into B by the xba pair
        xba                          ;   (<= $7CFF: no carry out)
        lda row_lo,x
        clc
        adc cm_x
        xba
        adc #0
        xba
        rep #$20
        .LONGA ON
        sta [zp_pt]                  ; [0-1] SRC lo/mid: the source column
        inc @                        ; the destination starts one column right
        ldy #BCB_DST_ADDR
        sta [zp_pt],y                ; [6-7]
    .ifdef FX127                     ; the slot may have held a wall or a fill:
        lda #[$2000-SCREEN_WIDTH]>>8 ;   [4-5] SRC_STEPY hi, SRC_STEPX = 0 (a wall's
        ldy #BCB_SRC_STEPY+1         ;   step lo sat there)
        sta [zp_pt],y
        lda zback_hi                 ;   [2-3] SRC bank = the back buffer, SRC_STEPY
        and #$00FF                   ;   lo: -160, the SOURCE walks UP a column as
        ora #[[$2000-SCREEN_WIDTH]&$FF]<<8   ;   the slot's DST does
        ldy #BCB_SRC_ADDR+2
        sta [zp_pt],y
        .LONGA OFF
        sep #$20
        lda cm_n                     ;   [12] WIDTH-1 = deferred columns - 1 ([13]
        dec @                        ;   is the template's 0)
        ldy #BCB_WIDTH
        sta [zp_pt],y
        pla                          ;   [14] HEIGHT-1 = the strip's rows-1
        ldy #BCB_HEIGHT
        sta [zp_pt],y
        rep #$21
        .LONGA ON
        lda #$00FF                   ;   [15-16] AND = $FF, XOR = 0 (a fill's colour)
        iny
        sta [zp_pt],y
        lda #FX_PAT|[FX_CTL_F<<8]    ;   [19-20] pattern + CTRL: a chained copy
        ldy #BCB_PATTERN
        sta [zp_pt],y
        lda #$01|[[BCB_SLOT-BCB_SIZE-3]<<8]   ; [21-24] a relative jump (+3 from its
        ldy #BCB_SIZE                ;   4th byte) to the next slot OVER the raycasting
        sta [zp_pt],y                ;   container (its header was there: cm_rest
        lda #0                       ;   puts it back) -- a raycast cannot walk a
                                     ;   screen column
        ldy #BCB_SIZE+2
        sta [zp_pt],y
    .else
        lda #$2000-SCREEN_WIDTH      ; [3-4] SRC_STEPY = -160: the SOURCE walks UP a
        ldy #BCB_SRC_STEPY           ;   column as the slot's DST does (2026-09-28)
        sta [zp_pt],y
        .LONGA OFF
        sep #$20
        lda zback_hi                 ; [2] SRC bank = the back buffer
        dey
        sta [zp_pt],y
        lda cm_n                     ; [12] WIDTH-1 = deferred columns - 1 ([13] is
        dec @                        ;   the template's 0)
        ldy #BCB_WIDTH
        sta [zp_pt],y
        lda #$FF                     ; [15] AND = $FF: a straight copy
        xba
        pla                          ; [14] HEIGHT-1 = the strip's rows-1
        rep #$21
        .LONGA ON
        ldy #BCB_HEIGHT
        sta [zp_pt],y
    .endif
        lda zp_pt                    ; -> the next slot's DST field (C = 0)
        adc #BCB_SLOT+PT_ZPOFF
        sta zp_pt
        .LONGA OFF
        sep #$20
.endm
    .endif

;--------------------------------------------------------------
; cm_flush -- replicate the source column across the deferred ones (one blit),
;   then break the run. Called before drawing a different column, before any
;   skipped column, and at the end of the seg. Preserves X/Y. Clobbers A.
;--------------------------------------------------------------
        .segment B1
.proc cm_flush
        lda cm_n
        beq ?none
cm_go   stx cm_savex                 ; (draw_twall_clip enters HERE with cm_n != 0:
                                     ;   the early-out above is inlined there)
    .if TEX_RUNS
                                      ; 2026-09-22 (vbxe-blitter: fire early, wait late,
        lda tw_chn                   ;   fewer lists): the copy is a LINK of the open
        sec                          ;   chain now, behind the source column's spans --
        sbc #>[MEMW+MEMW_CHA_OFF]    ;   no launch, no wait here, no START of its own and
        lsr                          ;   no wait for it at the next ptc_fire (~32k cyc a
        lsr                          ;   frame of spin, _probe_bwait). X = the open
        tax                          ;   buffer's restore list (0 = A, 1 = B)
        lda cm_rc,x
        cmp #CM_RMAX-1               ; (2026-09-28: a flush may record TWO links)
        bcc ?link                    ; room: out of line below; full: the old way
        jsr ptc_fire_wait            ; the source column's spans may still sit in
                                     ;   the OPEN chain: launch it, then wait
    .else
        jsr blitter_wait             ; the source column's own blits must be done
    .endif
        ldx cm_top                   ; row -> framebuffer offset
                                      ; 2026-09-22 (rapidus-bus-timing): SRC, DST, SRC_STEPY
        lda row_hi,x                 ;   and WIDTH as bus WORDS (13 single bytes -> 4
        xba                          ;   words + 4). A:B = row*160 + x: the column's
        lda row_lo,x                 ;   carry goes into B by the xba pair (<= $7CA0:
        clc                          ;   no carry out)
        adc cm_x
        xba
        adc #0
        xba
        rep #$20
        .LONGA ON
        sta MEMW+MEMW_TW_OFF+BCB_SRC_ADDR      ; [0-1]
        inc @                        ; the destination starts one column right
        sta MEMW+MEMW_TW_OFF+BCB_DST_ADDR      ; [6-7]
        lda #SCREEN_WIDTH            ; [3-4] walk the SOURCE down a column too
        sta MEMW+MEMW_TW_OFF+BCB_SRC_STEPY
        lda cm_n                     ; [12-13] WIDTH-1 = deferred columns - 1, high
        dec @                        ;   byte 0 (the word read drags cm_top in)
        and #$00FF
        sta MEMW+MEMW_TW_OFF+BCB_WIDTH
        .LONGA OFF
        sep #$20
        lda zback_hi                 ; [2], [8] the back buffer
        sta MEMW+MEMW_TW_OFF+BCB_SRC_ADDR+2
        sta MEMW+MEMW_TW_OFF+BCB_DST_ADDR+2
        stz MEMW+MEMW_TW_OFF+BCB_ZOOM          ; [18]
        sec                          ; HEIGHT-1 = bot - top
        lda cm_bot
        sbc cm_top
        sta MEMW+MEMW_TW_OFF+BCB_HEIGHT
    .ifdef FX127
        lda #<VRAM_BCB_TWALL         ; (the templates share a page under FX127)
        sta VBXE_BL_ADR0
    .else
        stz VBXE_BL_ADR0             ; <VRAM_BCB_TWALL = 0 and its bank byte too
    .if [VRAM_BCB_TWALL & $FF] != 0
        ert 'VRAM_BCB_TWALL moved off a page: put the lda #< back'
    .endif
    .endif
        lda #>VRAM_BCB_TWALL
        sta VBXE_BL_ADR1
        stz VBXE_BL_ADR2
    .if [VRAM_BCB_TWALL >> 16] != 0
        ert 'VRAM_BCB_TWALL left bank 0: put the lda #>>16 back'
    .endif
        lda #1
        sta VBXE_BL_START            ; async -- AND THE BCB IS *NOT* LATCHED HERE
                                     ;   (2026-08-29, the real-hardware stripes).
    .if !TEX_RUNS
        stz MEMW+MEMW_TW_OFF+BCB_WIDTH   ; draw_vspan never sets WIDTH itself
    .endif
        stz cm_n
        ldx cm_savex
?none   lda #$FF                     ; the run is over either way
        sta cm_x
        rts
    .if TEX_RUNS
        ; ---- the copy as a chain link (2026-09-22). The slot's template (a painter
        ; link: SRC = the $FF byte, SRC_STEPY 0, WIDTH 0) is what the copy changes
        ; beyond the four bytes every span writes, so the slot is recorded and
        ; cm_rest puts SRC/SRC_STEPY/WIDTH back when ptc_open reopens the buffer --
        ; its chain has run by then (ptc_fire waited for it). Everything else the
        ; copy needs IS the template: SRC_STEPX 0 (the source column fans out),
        ; DST_STEPY 160, DST_STEPX 1, XOR 0, ZOOM 0, CTRL COPY|NEXT, and the DST
        ; bank byte the frame's stamp chain wrote. Y is kept (cm_flush's contract).
        ; FX127: the slot may have held a wall (its step, CTRL) or a constant fill
        ; (XOR = the colour), and every slot carries a raycasting container, so
        ; the copy writes those too and jumps over the container (CM_EMIT).
        ; 2026-09-28: ONLY THE ROWS THE COLUMN PAINTED. A closed column painted
        ; its whole window; an OPEN portal only top..nt-1 and nb+1..bot -- the
        ; window between is a later seg's (or bg_fill's) and was copied for
        ; nothing: a portal that painted no row still sent 159 x 168 through
        ; the blitter, 83k cycles a copy, and ptc_fire spun on it (_probe_bwait
        ; --fire: 26k cyc a frame standing, 62k walking). No strip = no link.
?link   phy
        lda cm_solid
        bne ?whole                   ; closed: cm_nt/cm_nb hold the scale
        sec
        lda cm_nt
        sbc cm_top                   ; rows above the window (nt >= top)
        beq ?lo
        dec @
        tay                          ; rows-1
        lda cm_bot                   ; a second strip to come and ONE slot left:
        cmp cm_nb                    ;   launch what is open first (ptc_fire
        beq ?up                      ;   keeps Y), both links go in one chain
        lda zp_pt
        cmp #<[BCB_SLOT*PT_LINKS+PT_ZPOFF]
        bne ?up
        jsr ptc_fire
?up     lda cm_nt                    ; (the links run BOTTOM-UP, paint.asm: a
        dec @                        ;   strip is named by its LAST row)
        jsr ?emit
        sec
        lda cm_bot
        sbc cm_nb                    ; rows below the window (nb <= bot)
        beq ?fire
        bra ?lo2
?lo     sec
        lda cm_bot
        sbc cm_nb
        beq ?lnf                     ; no row painted: no link, no launch
?lo2    dec @
        bra ?em
?whole  sec
        lda cm_bot
        sbc cm_top
?em     tay
        lda cm_bot
        jsr ?emit
?fire   jsr ptc_fire                 ; FIRE EARLY: launch the chain now, the copy as its
?lnf    ply                          ;   last link (holding it open to fill up measured
                                     ;   +8.8k cyc a frame: the blitter started later)
        stz cm_n
        ldx cm_savex
        bra ?none
        ; ---- one copy link: A = the LAST row, Y = rows-1. Clobbers A/X/Y.
        ;   (2026-10-05: writing it out at both sites put ?link's branches out
        ;    of reach; the subroutine stays)
?emit   CM_EMIT
        rts
    .endif
.endp
        .endseg
    .if TEX_RUNS
;--------------------------------------------------------------
; cm_rest -- ptc_open's hook while copy links are recorded (cm_flush patches
;   `jsl cm_rest` over ptc_rsh's `rts`): the buffer being reopened has run its
;   chain, so its copy slots get the painter template back -- SRC = the $FF
;   byte, SRC_STEPY 0, WIDTH 0 (AND, HEIGHT and DST lo/mid every span writes
;   itself); FX127: SRC_STEPY 0, WIDTH 0 and the raycasting container's header.
;   zp_pt is left as ptc_open set it. Keeps X, Y and P; clobbers A.
;--------------------------------------------------------------
        .segment B1                  ; 2026-09-22 (vbxe-blitter)
.proc cm_rest
        php
        phx
        phy
        lda tw_chn                   ; X = the reopened buffer's list
        sec
        sbc #>[MEMW+MEMW_CHA_OFF]
        lsr
        lsr
        tax
        lda cm_rc,x
        beq ?chk
        txa                          ; Y = its first entry
        asl
        asl
        tay
?ent    lda cm_rlo,y                 ; zp_pt = the copy slot's base (bank byte 0:
        sta zp_pt                    ;   ptc_open zeroed zp_savex)
        lda cm_rhi,y
        sta zp_pt+1
        phy
        rep #$20
        .LONGA ON
  .ifdef FX127                 ; (a wall link writes SRC itself, a fill is constant)
        lda #$0000                   ; [3-4] SRC_STEPY 0 = the raycast's row step,
        ldy #BCB_SRC_STEPY           ;   [12-13] WIDTH-1 = 0: one column
        sta [zp_pt],y
        ldy #BCB_WIDTH
        sta [zp_pt],y
        lda #FX_RC_HDR               ; [21-22] the raycasting container's header
        ldy #BCB_SIZE                ;   back over the copy's jump ([22] = X0 lo:
        sta [zp_pt],y                ;   a wall writes it)
        .LONGA OFF
        sep #$20
  .else
  .if STRIP                    ; (2026-10-15) the template is the $FF block's
        lda #PS_FFT&$FFFF            ;   top, read up the column (src stepY -1)
        sta [zp_pt]
        lda #$1FFF
        ldy #BCB_SRC_STEPY
        sta [zp_pt],y
        .LONGA OFF
        sep #$20
        ert [PS_FFT>>16]<>0
        lda #0                       ; [2] the block's bank, [12] WIDTH-1 = 0
  .else
        lda #VRAM_BCB_FF&$FFFF       ; [0-1] SRC = the painter links' $FF byte
        sta [zp_pt]
        lda #$0000                   ; [3-4] SRC_STEPY 0 (2026-09-28: both bytes,
        ldy #BCB_SRC_STEPY           ;   the copy's is -160)
        sta [zp_pt],y
        .LONGA OFF
        sep #$20
                                      ; A = 0 = the $FF byte's bank [2] ...
        ert [VRAM_BCB_FF>>16]<>0
  .endif
        dey
        sta [zp_pt],y
        ldy #BCB_WIDTH               ; ... = [12] WIDTH-1 = 0: one column
        sta [zp_pt],y
  .endif
        ply
        iny
        dec cm_rc,x
        bne ?ent
        lda #BCB_SLOT+PT_ZPOFF       ; zp_pt back to what ptc_open set: slot 1
        sta zp_pt
        lda tw_chn
        sta zp_pt+1
?chk    lda cm_rc                    ; nothing pending in either buffer: unhook
        ora cm_rc+1
        bne ?keep
        rep #$20
        .LONGA ON
        lda #$0060                   ; `rts` (60) over the jsl: ptc_rsh's own byte
        sta.l B1CODE_BASE+ptc_rsh
        .LONGA OFF
        sep #$20
?keep   ply
        plx
        plp
        rtl
.endp
        .endseg
        .segment D0                  ; 2026-09-22: cm_flush's copy-slot restore lists
CM_RMAX equ 4                        ; copy links a buffer may hold before cm_flush
cm_rc   dta 0,0                      ;   falls back to its own START; count per buffer
cm_rlo  :8 dta 0                     ; slot bases, list*4 + i
cm_rhi  :8 dta 0
        .endseg
    .endif

; ---- state ----------------------------------------------------------------
cm_x       dta $FF                   ; source column ($FF = no run pending)
cm_n       dta 0                     ; columns deferred behind it
cm_top     dta 0                     ; the source column's window = copy rows
cm_bot     dta 0
cm_solid   dta 0                     ; occlusion state the source column produced
cm_nt      dta 0
cm_nb      dta 0
cm_savex   dta 0
cm_sig     dta 0,0,0,0,0,0,0,0,0,0,0 ; 11 compared bytes (see the header)

    .if * > COLMERGE_END
        ert 'colmerge.asm outgrew its block -- see memory_map.inc'
    .endif

;==============================================================
; bg_fill -- paint ONLY what the BSP walk left unpainted
;--------------------------------------------------------------
; FastDoom's rule for slow machines: never draw what you are going to overwrite.
; The port cleared the whole 160x168 view every frame -- 26880 bytes through the
; blitter, ~4.5 ms -- and then painted almost all of it again with ceiling, wall
; and floor spans. By construction the only pixels the walk leaves untouched are
; the still-OPEN windows: solid_arr[x] = 0, rows ytopc_arr[x]..ybotc_arr[x]
; (everything outside a column's window has been painted by some seg).
;
; So the clear is gone from the frame loop and this runs instead, right after
; render_node and BEFORE the sprites (which must not be erased). Adjacent
; columns with the same window are emitted as ONE rectangle, so the common cases
; -- nothing open, or one wide gap where the walk ran out of segs -- cost one
; blit or none at all.
;==============================================================
        .segment B1
.proc bg_fill
        ldx vw_x0                    ; only the view window: outside it every
                                     ;   closed column is fully painted
                                      ; 2026-10-05 (65816-style "a byte sweep read as
?pair   rep #$20                     ;   words", as check_bbox ?sc / render_world): the
        .LONGA ON                    ;   closed columns -- nearly all of them -- go TWO
?scan2  lda solid_arr,x              ;   a read. x0 and xend are even (viewsize.asm,
        cmp #$0101                   ;   render_world), so a pair never straddles the
        bne ?some                    ;   end and [0,159] holds only 0/1. An open column
        inx                          ;   drops into the byte loop below, which emits
        inx                          ;   its run and comes back here on an even X.
        cpx vw_xend                  ;   10 cycles a closed column, was 15.
        bcc ?scan2
        sep #$20
        .LONGA OFF
        rts
        .LONGA ON                    ; (?some is reached 16-bit, from ?scan2's bne:
?some   bit #$00FF                   ;   an 8-bit `bit #` here left its third byte
        .LONGA OFF                   ;   to run as `jsr` -- 2026-10-19). Z = the
        sep #$20                     ;   even column is the open one
        beq ?scan
        inx                          ; else the odd one is
?scan   lda solid_arr,x
        bne ?nx
        lda ytopc_arr,x
        sta bg_top
        lda ybotc_arr,x
        sta bg_bot
        cmp bg_top
        bcc ?nx                      ; bot < top -> empty window
        stx bg_x0
        lda #1
        sta bg_w
?ext    inx                          ; grow the run while the window is identical
        cpx vw_xend
        bcs ?emit
        lda solid_arr,x
        bne ?emit
        lda ytopc_arr,x
        cmp bg_top
        bne ?emit
        lda ybotc_arr,x
        cmp bg_bot
        bne ?emit
        inc bg_w
        bra ?ext
?emit   jsr bg_blit
        cpx vw_xend
        bcc ?back
        rts
?nx     inx
        cpx vw_xend
        bcc ?back
        rts
?back   txa                          ; back to the pair scan on an even column;
        lsr @                        ;   an odd one takes one byte step first
        bcc ?pair
        bra ?scan
.endp
        .endseg

;--------------------------------------------------------------
; bg_blit -- one rectangle of background colour: columns bg_x0..+bg_w-1,
;   rows bg_top..bg_bot. Uses the vline fill BCB (AND 0 / XOR colour) with its
;   width widened for the run, and hands it back 1 byte wide. Preserves X.
;--------------------------------------------------------------
        .segment B1
.proc bg_blit
        stx cm_savex
    .if TEX_RUNS
        jsr ptc_fire_wait            ; normally a plain wait (ptc_fbg already
                                     ;   fired the walk's last chain)
    .else
        jsr blitter_wait
    .endif
?com    ldx bg_top
                                      ; 2026-09-22 (vbxe-blitter: write only what changes):
        lda row_hi,x                 ;   DST's bank byte is the FRAME's (ptc_frame stamps
        xba                          ;   it) and XOR = BG_COLOUR is set ONCE (setup_bcbs):
        lda row_lo,x                 ;   DST lo/mid as one bus word, HEIGHT, WIDTH. A:B =
        clc                          ;   row*160 + x0, the carry into B by the xba pair
        adc bg_x0
        xba
        adc #0
        xba
        rep #$20
        .LONGA ON
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR      ; [6-7]
        .LONGA OFF
        sep #$21                     ; 2026-09-23: 8-bit AND C = 1 for the sbc below
        lda bg_bot
        sbc bg_top
        sta MEMW+MEMW_VL_OFF+BCB_HEIGHT
        lda bg_w
	dec
        sta MEMW+MEMW_VL_OFF+BCB_WIDTH
                                      ; 2026-09-22: XOR = BG_COLOUR lives in the BCB since
    .if !TEX_RUNS
        ert 'bg_blit leaves XOR to setup_bcbs: draw_vspan (!TEX_RUNS) rewrites it per span'
    .endif
        lda #<VRAM_BCB_VLINE
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_VLINE
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_VLINE>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START            ; async, and the BCB is NOT captured by this
                                     ;   write on real VBXE -- see the long note
                                     ;   in cm_flush.
    .if !TEX_RUNS
        stz MEMW+MEMW_VL_OFF+BCB_WIDTH
    .endif
        ldx cm_savex
        rts
;   2026-09-23 BUG FIX (the text vanished in a reduced view): ovl_frame runs BEFORE
;   the render, and the DST bank byte is stamped by ptc_frame only INSIDE it -- so
;   its clear hit LAST frame's buffer, the one on screen with the text in it. This
;   entry stamps the bank itself (after the wait: the BCB is not latched).
bgb_ovl stx cm_savex
    .if TEX_RUNS
        jsr ptc_fire_wait
    .else
        jsr blitter_wait
    .endif
        lda zback_hi
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+2
        bra ?com
.endp
        .endseg

bg_top     dta 0
bg_bot     dta 0
bg_x0      dta 0
bg_w       dta 0

;--------------------------------------------------------------
; clear_both -- wipe BOTH framebuffers once at boot. The frame loop does not
;   clear any more (bg_fill only repaints the gaps), so a buffer's very first
;   frame would otherwise show whatever VRAM powered up with. Leaves zback_hi
;   as it found it.
;   OUT OF THE FAST BLOCK (2026-08-09). Everything else in this file runs per
;--------------------------------------------------------------
cbo_resume = *
        .segment B1
.proc clear_both
        lda #$01                     ; clear FRAME_B (back buffer)
        sta zback_hi
        lda #BG_COLOUR
        jsr clear_screen
        lda #$07                     ; clear FRAME_C (triple buffer)
        sta zback_hi
        lda #BG_COLOUR
        jsr clear_screen
                                     ; leave pointing to FRAME_A, skip clearing
        stz zback_hi                 ; it (displayed) to avoid black flash
        rts
.endp
        .endseg
        org cbo_resume

;==============================================================
; calc_u_sub -- perspective u by SUBDIVISION (the classic texture-mapper trick)
;--------------------------------------------------------------
; calc_u is exact perspective: u = L * t1/(t1+t2). That costs a udiv24 plus a
; umul16 -- ~1000 cycles -- on EVERY textured column, and with textures on that
; is the single most expensive thing the renderer does per column.
;
; Quake, Build and every fast software mapper solve this the same way: compute
; the exact value only at every Nth column and interpolate linearly in between.
; Inside one N-column block the texture is affine instead of perspective, and
; with N = 8 on a 160-column screen the error stays well under a texture pixel except on
; extremely oblique walls -- the same trade Doom8088 makes with its "approx"
; math. Cost per column drops from ~1000 cycles to ~2*1000/N + ~40, i.e. ~4x.
;
; Anchors recompute BOTH ends of the block (u at x and at x+N) and derive the
; per-column step by a shift, so no error accumulates across blocks: every
; anchor re-syncs to the exact perspective value.
;==============================================================
CU_SUB    equ 4                      ; columns per block (power of two). 4 since
CU_SHIFT  equ 2                      ;   2026-10-20 (was 8): the line between two
                                     ;   anchors is affine, the true u hyperbolic,
                                     ;   and on a near wall seen from the side the
                                     ;   8-column block put texture columns a
                                     ;   stored column off mid-block (E1M7's door
                                     ;   from the side). log2(CU_SUB) below.

; (cu_seg_init and calc_u_sub -- the per-seg reset and the per-column half of
;  the subdivision: steep -> exact, else rs_uacc += cu_step, an anchor every
;  CU_SUB columns -- live INLINE in process_seg's column loop since 2026-09-15
;  (seg_draw.asm ?mh_prime, mskr/?cu_done). Dead copies removed 2026-10-05.)

cu_cnt   dta 0                       ; columns left in this block
cu_step  dta 0,0                     ; per-column u step (Q8, 16-bit)
cu_sgn   dta 0                       ; its sign extension for the 24-bit add
cu_u0    dta 0,0,0                   ; exact u at the block's first column
cu_save  dta 0,0,0,0,0,0,0,0         ; rs_t1/rs_t2 (32-bit) across the look-ahead
cu_sx    dta 0
cu_ah    dta 0,0,0                   ; exact u at the column the look-ahead hit
cu_cx    dta $FF                     ; ... and which column that was ($FF = none)


;--------------------------------------------------------------
; cu_anchor -- calc_u_sub's block start: exact u here AND las_n columns ahead,
;   linear step in between. Entered by jmp, returns straight to the column loop.
;   Fast block on purpose: both calc_u calls and the track walk are hot.
;--------------------------------------------------------------
        .segment B1
;--------------------------------------------------------------
; CALC_DELTA -- (16-bit A) m_prod(32) = A << las_sh (0..CU_SHIFT). A macro
;   since 2026-09-26: cu_anchor's two calls (342 a frame) paid a jsr/rts each.
;--------------------------------------------------------------
.macro CALC_DELTA
	.LONGA ON
  .ifdef ANTONIA2                    ; 2026-10-15 (6502-idioms: compute in A): A * las_n
	sta.l ANT_MUL                ;   (= 1 << las_sh) on the card instead of the
	lda las_n                    ;   shift ladder; the product STAYS there -- the
	and #$00FF                   ;   adds read it with PRADC / PRSBC (las_sh is
	sta.l ANT_MUL+2              ;   las_n's neighbour: masked)
  .else
	stz m_prod+2
	ldy las_sh
	beq ?d_ok
?d_sh	asl
	rol m_prod+2
	dey
	bne ?d_sh
?d_ok	sta m_prod
  .endif
.endm
;--------------------------------------------------------------
; TWLAS_ROOM -- look-ahead room check (F6): from column X (preserved), clamp
;   the block to the largest power of two <= min(CU_SUB, rs_sxR - X). las_n =
;   1, 2, 4 or 8 columns, las_sh = its shift. rs_sxR >= X always (X <= xb <=
;   sxR). A macro since 2026-10-05 (6502-cycles-layout: inline what is smaller
;   than its 12-cycle call -- two callers, 106 calls a frame; was twlas_room).
;   OUT: Y = las_n, A = las_sh (6502-idioms "use what a routine already
;   produced": tws_anchor counts the block down from Y, no reload).
;--------------------------------------------------------------
.macro TWLAS_ROOM
        lda rs_sxR+1
        bne ?full                    ; sxR >= 256 -> room >= 97
        txa
        eor #$FF                     ; A = sxR - X (borrow impossible)
        sec
        adc rs_sxR
        cmp #CU_SUB
        bcs ?full
        cmp #4
        bcs ?n4
        cmp #2
        bcs ?n2
        ldy #1                       ; room 0..1: anchor-only block (the step is
        sty las_n                    ;   dead -- las_n-1 = 0 columns follow it)
        lda #0
        bra ?ssh                     ; always
?n2     ldy #2
        sty las_n
        lda #1
        bra ?ssh
?n4     ldy #4
        sty las_n
        lda #2
        bra ?ssh
?full   ldy #CU_SUB
        sty las_n
        lda #CU_SHIFT
?ssh    sta las_sh
.endm
; TWLAS_ROOM16 -- TWLAS_ROOM for a 16-bit caller (cu_anchor, 2026-10-16,
;   drac030: few rep/sep pairs): sxR - X as one word (sxR >= 256 lands in
;   ?full by itself), las_n and las_sh written as one word. OUT: Y = las_n.
.macro TWLAS_ROOM16
        .LONGA ON
        txa                          ; X: 8-bit, so B comes out 0
        eor #$FFFF                   ; A = sxR - X (borrow impossible)
        sec
        adc rs_sxR
        cmp #CU_SUB
        bcs ?full
        cmp #4
        bcs ?n4
        cmp #2
        bcs ?n2
        ldy #1                       ; room 0..1: anchor-only block
        lda #0*256+1
        bra ?ssh                     ; always
?n2     ldy #2
        lda #1*256+2
        bra ?ssh
?n4     ldy #4
        lda #2*256+4
        bra ?ssh
?full   ldy #CU_SUB
        lda #CU_SHIFT*256+CU_SUB
?ssh    sta las_n                    ; las_n, las_sh (bsp_main.asm: neighbours)
.endm
.proc cu_anchor
        stx cu_sx                    ; calc_u preserves X, but the t1/t2 shuffle
        cpx cu_cx                    ; did the LAST block's look-ahead land
        bne ?fresh                   ;   exactly here? then u is already known
	rep #$20
	.LONGA ON
	lda cu_ah		;0/1
	sta cu_u0
	lda cu_ah+1		;1/2
	sta cu_u0+1
        bra ?have0                   ; always (dey wrapped to $FF)
?fresh  jsr calc_u                   ; exact u at THIS column (16-bit A back)
	.LONGA ON
        lda rs_uacc                  ; keep it: the block starts here
        sta cu_u0
        lda rs_uacc+1
        sta cu_u0+1
?have0  TWLAS_ROOM16                 ; F6: never walk past the seg's right edge
                                     ;   (16-bit on both ways in, 2026-10-16)
        ; --- t1/t2 las_n columns ahead (they advance by constants per column) --
        .LONGA ON
                                     ; 2026-09-22 (65816-style): both 32-bit tracks
                                     ;   ride the stack, not a RAM cell (the restore
                                     ;   below pulls them in the reverse order).
        pei (rs_t1)                  ; 2026-09-26 (65816-idioms): pei, not lda/pha --
        pei (rs_t1+2)                ;   the same word pushed high byte first, 6
        pei (rs_t2)                  ;   cycles for 8, and A is reloaded right below
        pei (rs_t2+2)                ;   anyway (rs_t1/rs_t2 are zero page)
        lda rs_utR
        CALC_DELTA
        clc
        lda rs_t1
        PRADC 0                      ; (m_prod, or the card: math.asm, 2026-10-15)
        sta rs_t1
        lda rs_t1+2                  ; bytes 2-3 in one add: byte 2 is what the
        PRADC 2                      ;   8-bit add made (m_prod+3 is ?calc_delta's
        sta rs_t1+2                  ;   scratch, it only feeds the padding)
        lda rs_utL                   ; (CALC_DELTA starts with asl: no carry in)
        CALC_DELTA
        sec
        lda rs_t2
        PRSBC 0
        sta rs_t2
        lda rs_t2+2
        PRSBC 2
        sta rs_t2+2
        jsr calc_u                   ; exact u at column x + las_n (16-bit A in
	.LONGA ON                    ;   and out: calc_u opens with rep #$21)
	lda rs_uacc
	sta cu_ah
	lda rs_uacc+1
	sta cu_ah+1
	sep #$20
	.LONGA OFF
        txa                          ; X is still this anchor's column
        clc
        adc las_n
        sta cu_cx
        rep #$20                     ; put the real tracks back
        .LONGA ON
                                     ; (LIFO: rs_t2+2 was pushed last)
        pla
        sta rs_t2+2
        pla
        sta rs_t2
        pla
        sta rs_t1+2
        pla
        sta rs_t1                    ; (stays 16-bit: the step subtract below
                                     ;   used to reopen the same window)
        .LONGA ON                    ; (still 16-bit from the restore above)
        sec
        lda rs_uacc
        sbc cu_u0
        sta cu_step
        .LONGA OFF
        sep #$20
        lda rs_uacc+2
        sbc cu_u0+2
        sta cu_sgn                   ; the difference's sign/high byte

        ldy las_sh
        beq ?shdone                  ; las_n = 1: the step is never consumed
                                      ; 2026-09-22 idiom: A IS cu_sgn (stored 5 lines up;
?sh	cmp #$80
        ror
        ror cu_step+1
        ror cu_step
        dey
        bne ?sh
?shdone eor #$80                     ; keep only the sign for the 24-bit adds.
        cmp #$80                     ;   2026-09-27: A = the high byte on both ways
        lda #0                       ;   in (an arithmetic shift keeps its sign), so
        sbc #0                       ;   no store/reload: C = positive -> 0 - 0 - !C
        sta cu_sgn                   ;   = $00 / $FF, no branch
        lda cu_u0                    ; the block starts at the exact value: the
        sta rs_uacc                  ;   three bytes in 8 bits (2026-10-16,
        lda cu_u0+1                  ;   drac030: few rep/sep pairs -- the
        sta rs_uacc+1                ;   rep/sep round two words cost 2 cycles
        lda cu_u0+2                  ;   more than this)
        sta rs_uacc+2
        ldy las_n
        dey
        sty cu_cnt
        ldx cu_sx
        rts
.endp
        .endseg

;==============================================================
; tw_setup_sub -- the same subdivision, applied to the texture pixel RATE
;--------------------------------------------------------------
; tw_setup's tpr = 4096*worldH / dscr is the second udiv24 every textured column
; pays (its memo only hits when dscr is EXACTLY equal, i.e. on walls square to
; the view). dscr comes from the two plane accumulators, which advance by a
; constant step per column, so tpr varies smoothly along a seg -- exactly the
; case linear interpolation is made for.
;
; 2026-08-27: ALL OF THAT IS GONE. rs_tpr is the exact reciprocal of rs_rpt,
; which pt_seg already tracks exactly-linearly in the column, so paint.asm's
; pt_recip produces it by table off the memo paint_col already keeps -- no
; divide, no anchor, no interpolation, and a SMALLER error than the anchors had
; What is left here is the F3 steep verdict, which the perspective-u track still
; needs (calc_u_sub reads tws_exact), and the block counter that paces it.
;==============================================================
; (tw_seg_init and tw_setup_sub -- the per-seg reset and the per-column
;  `dec tws_cnt / bmi -> tws_anchor` -- live INLINE in process_seg since
;  2026-09-15 (seg_draw.asm ?mh_prime, ?cu_done). Dead copies removed
;  2026-10-05.)

tws_cnt   dta 0
tws_exact dta 0                      ; 1 = steep block: per-column exact u

    .if * > COLMERGE_END
        ert 'colmerge.asm (fast block) outgrew its hole -- see memory_map.inc'
    .endif

;==============================================================
; TWANCHOR block -- tw_setup_sub's anchor body, relocated to the RAM under the
; OS ROM (memory_map.inc TWANCHOR_BASE).
;==============================================================
twa_resume = *
        org TWANCHOR_BASE

; (twlas_room is the TWLAS_ROOM macro above since 2026-10-05: inline at both
;  callers, cu_anchor and tws_anchor.)

                                      ; 2026-09-21: in page 1 now (bsp_main.asm): fast writes
;--------------------------------------------------------------
; tws_anchor -- tw_setup_sub's block start. First the F3 steep test; a steep
;   column gets the exact rate (+ ladder) and keeps anchoring every column.
;   Otherwise the normal look-ahead anchor with F6 room + F1 memo + F2 Q16 step.
;   2026-10-05 (6502-cycles-layout "rare case out of line"): nosteep, the
;   common verdict, sits right behind the fast path -- the two early not-steep
;   exits reach it with a short branch (the tws_nsj jmp trampoline went, -3)
;   and the fast path falls into it (its `bra nosteep` went, -3). ?big (D >=
;   65536, a wall over 256 rows) moved out of line behind the steep exit.
;--------------------------------------------------------------
        .segment B1
.proc tws_anchor
        stx tws_sx
        ; ---- F3 steep test: D = yfacc - ycacc (24-bit, the wall's screen ...
        rep #$20                     ; D = yfacc - ycacc, 24-bit: the low word
        .LONGA ON                    ;   in one subtract (drac030, 2026-09-14)
        sec
        lda rs_yfacc
        sbc rs_ycacc
        sta m_prod
        .LONGA OFF
        sep #$20
        lda rs_yfacc+2
        sbc rs_ycacc+2               ; (2026-10-15, 6502-idioms: store only what is
  .ifndef ANTONIA2                   ;   read -- on ANTONIA2 D's top byte is ?big's
        sta m_prod+2                 ;   alone, so its sta moved there)
  .endif
	bmi nosteep
	bne ?big                     ; D >= 65536 > 4096: the 24-bit test below
        lda m_prod+1
        cmp #$10                     ; D >= 4096 <=> mid byte >= $10 (hi = 0)
        bcc nosteep
        ; ---- D in [4096, 65535]: the 16-bit fast path (2026-09-15). dS as ...
        rep #$20
        .LONGA ON
        lda rs_yfS                   ; C = 1: the bcc above fell through (rep keeps it)
        sbc rs_ycS
        bvs ?steep16
        bpl ?dsp
        eor #$FFFF
        inc
?dsp    cmp #1024
        bcs ?steep16
        asl
        asl
        asl
        asl
        asl
        asl
        cmp m_prod                   ; steep <=> |dS|<<6 >= D
        .LONGA OFF
        sep #$20
        bcs ?steep
nosteep                              ; (falls through: the common verdict)
                                     ; F6: the block still ends where the u track's
        stz tws_exact                ;   does, so the two stay in step -- but with
        TWLAS_ROOM                   ;   nothing to interpolate that is all an
        dey                          ;   anchor has left to do (inline, 2026-10-05:
        sty tws_cnt                  ;   Y = las_n comes out of the macro)
        ldx tws_sx
        rts
        .LONGA ON
?steep16 sep #$20                    ; (the fast path's 16-bit exits land here)
        .LONGA OFF
?steep  lda #1
        sta tws_exact
        stz tws_cnt                  ; cnt 0 -> re-test steepness NEXT column too
        ldx tws_sx
        rts
?big
  .ifdef ANTONIA2
        sta m_prod+2                 ; (A = D's top byte: the bne's)
  .endif
	                             ; dS = yfS - ycS as SIGNED 17-bit: both are
        stz m_res                   ;   s16, so the plain 16-bit difference can
        stz m_res+1                  ;   wrap -- extend both before subtracting
        lda rs_yfS+1
        bpl ?ya
        dec m_res                    ; m_res   = sign of yfS
?ya     lda rs_ycS+1
        bpl ?yb
        dec m_res+1                  ; m_res+1 = sign of ycS
?yb     rep #$20                     ; dS = yfS - ycS, the low word in one
        .LONGA ON                    ;   subtract (drac030, 2026-09-14)
        sec
        lda rs_yfS
        sbc rs_ycS
        sta m_a
        .LONGA OFF
        sep #$20
        lda m_res
        sbc m_res+1
        sta m_b                      ; (m_b, m_a+1, m_a) = dS, 24-bit
        bpl ?abs

        jsr m_neg                    ; |dS|
        lda #0
        sbc m_b
        sta m_b

                                      ; 2026-09-21 (drac030 #41/#44: a multi-byte shift belongs
        ; in the 16-bit accumulator, not in a byte loop over memory).
?abs    rep #$20
        .LONGA ON
        lda m_a+1                    ; = V >> 8
        lsr @
        lsr @                        ; = V >> 10
                                      ; 2026-09-23: ONE window -- the word store puts
        sta m_b                      ;   junk in m_b+1, which nothing here reads (the
        lda m_a
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @
        sta m_a                      ; bytes 1..0 of V << 6
        sep #$20
        .LONGA OFF
        ldy #0
        lda m_b                      ; steep <=> |dS|<<6 >= D
        cmp m_prod+2
        jcc nosteep                  ; (Jcc: out of line, the reach is long)
        bne ?steep
	rep #$20
	.LONGA ON
	lda m_a
	cmp m_prod
	sep #$20
	.LONGA OFF
        jcc nosteep
        bra ?steep
.endp
        .endseg

; anchor-only state (nothing per-column reads this)
                                      ; 2026-09-21: in page 1 now (bsp_main.asm): fast writes

    .if * > TWANCHOR_END
        ert 'TWANCHOR block outgrew its hole -- see memory_map.inc'
    .endif
        org twa_resume
