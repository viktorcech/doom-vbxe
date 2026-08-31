;--------------------------------------------------------------
; RAM BUDGET: 1257 B free, biggest contiguous block 253 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------
;==============================================================
; viewsize.asm -- '-' / '=' shrink and grow the 3D view, DOOM's screenblocks.
;
; WHY it makes the game faster: per-column CPU work (the seg column loop,
; calc_u_sub, tw_setup, one blit chain per column) scales with the view WIDTH,
; and the blitter's fill/copy work scales with the AREA. Half size therefore
; halves the column count and quarters the pixels; E1M1 goes from a full-width
; frame to roughly a third of the work at 80x84.
;
; WHY it still looks like DOOM: R_ExecuteSetViewSize scales the projection with
; the window (projection = centerx<<FRACBITS), so the FOV stays 90 degrees and
; the picture is simply drawn smaller -- it is NOT a crop, you lose no view.
; Here that costs one extra right shift inside the two reciprocal routines
; (vw_sh, folded into shr_prod32's count -- free) plus vw_q34x for the sizes
; that are not a power of two.
;
; Everything else is data: render_world seeds the occlusion arrays so that only
; the window's columns are open, with [vw_y0,vw_y1] as their row window. Wall
; spans (draw_clip), the background fill (bg_fill) and the sprite clip snapshots
; all already clip to exactly those, so a border column is just "already solid".
;==============================================================

vs_resume = *
        org VIEWSZ_BASE

;--------------------------------------------------------------
; vw_apply -- vw_size -> the eight window bytes + a border repaint.
;   Called from init_level (boot AND every level, so the size survives an exit)
;   and from read_keys on '-' / '='.
;--------------------------------------------------------------
.proc vw_apply
        lda vw_size
        asl                          ; *8 = vw_tab record
        asl
        asl
        tay
        ldx #0
?cp     lda vw_tab,y
        sta vw_x0,x
        iny
        inx
        cpx #8
        bne ?cp
        ; Every column starts CLOSED and only the window is re-opened per frame
        ; (render_world), so the border columns are marked ONCE, here: nothing in
        ; the frame path ever writes solid_arr outside [vw_x0,vw_x1].
        ; (the border columns need no scale for spr_one's new nearer-than test:
        ;  they are already solid when spr_proj snapshots, so the snapshot marks
        ;  them 255/255 and the sprite is cut there without ever reading them)
        ldx #SCREEN_WIDTH-1
        lda #1
?bd     sta solid_arr,x
        dex
        bpl ?bd
        lda #3                       ; repaint the border into ALL THREE buffers
        sta vw_dirty                 ;   (triple buffer, 2026-08-11)
        rts
.endp

;--------------------------------------------------------------
; vw_frame -- once per frame, off read_keys: paint the border after a resize.
;   Two frames = both buffers. The 3D view is redrawn every frame anyway, so
;   only the ring around it needs this (clear_screen covers rows 0..167; the
;   status bar owns the rest).
;--------------------------------------------------------------
.proc vw_frame
        lda vw_dirty
        beq ?ret
        dec vw_dirty
        lda #VIEW_BORDER
        jmp clear_screen             ; tail-call
?ret    rts
.endp

;--------------------------------------------------------------
; vw_smaller / vw_bigger -- one step down / up the ladder ('-' / '=').
;--------------------------------------------------------------
.proc vw_smaller
        lda vw_size
        cmp #VW_NSIZE-1
        bcs ?ret                     ; already the smallest
        inc vw_size
        jmp vw_apply
?ret    rts
.endp

.proc vw_bigger
        lda vw_size
        beq ?ret                     ; already full size
        dec vw_size
        jmp vw_apply
?ret    rts
.endp

vw_size dta 0                        ; the ONLY view-size state that has to survive
                                     ;   a level load; it lives here (in the XEX, so
                                     ;   the loader initialises it) instead of in
                                     ;   the $0F80 block, which has no segment and
                                     ;   would boot with whatever RAM held

; ---- the ladder: x0, x1, x1+1, y0, y1, ncol, sh, q34 (8 B per size) ---------
; k = 1, 3/4, 1/2, 3/8, 1/4 of 160x168, always centred on (80, 84) -- DOOM puts
; the window in the middle of the non-status area too, which is what keeps the
; horizon (HHFP) and the projection centre (SCREEN_HALF) constant.
vw_tab
        dta   0,159,160,   0,167, 160, 0,0    ; 160x168  full
        dta  20,139,140,  21,146, 120, 0,1    ; 120x126  3/4
        dta  40,119,120,  42,125,  80, 1,0    ;  80x84   1/2
        dta  50,109,110,  53,115,  60, 1,1    ;  60x63   3/8
        dta  60, 99,100,  63,104,  40, 2,0    ;  40x42   1/4

    .if * > VIEWSZ_END+1
        ert 'viewsize outgrew VIEWSZ_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; vw_q34x -- m_prod[0..1] *= 3/4, for the sizes that are not a power of two.
;   scale_z and screenx_signed call it right after shr_prod32, i.e. on the
;   reciprocal result: the vertical scale and the horizontal offset from the
;   view centre. Both must take the SAME factor or the picture stops being
;   square. Powers of two never get here -- they ride shr_prod32's shift count
;   (vw_sh) and cost nothing at all.
;   Parked in the row_lo/TWCHAIN hole because it is FAST RAM: ~400 calls a frame
;   from $A000 would cost a Rapidus milliseconds (that bank runs at bus speed).
;--------------------------------------------------------------
        org VWQ34_BASE
.proc vw_q34x
        lda vw_q34
        beq ?ret
        lda m_prod+1                 ; vw_t = v >> 2
        lsr
        sta vw_t+1
        lda m_prod
        ror
        lsr vw_t+1
        ror
        sta vw_t
        sec                          ; v -= v>>2   (= v * 3/4)
        lda m_prod
        sbc vw_t
        sta m_prod
        lda m_prod+1
        sbc vw_t+1
        sta m_prod+1
?ret    rts
.endp
    .if * > VWQ34_END+1
        ert 'vw_q34x outgrew VWQ34_BASE..END (memory_map.inc)'
    .endif

        org vs_resume
