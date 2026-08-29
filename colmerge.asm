;==============================================================
; colmerge.asm -- draw a screen column ONCE, then copy it sideways
;--------------------------------------------------------------
; On a wall close to the player the texture is magnified: 4-8 neighbouring
; screen columns read the SAME texture column and, because the wall's plane
; accumulators barely move over those few columns, they also land on the same
; integer rows. Their pixels are therefore bit-identical -- and the renderer was
; recomputing and re-blitting every one of them: calc_u, tw_setup, the
; draw_twall_col prologue, the 8x expander check and 3-6 blitter round-trips per
; column, all to produce a copy of the column next door.
;
; So: draw the first column of such a run normally, then DEFER its twins. When
; the run ends, one blitter copy replicates the drawn column across them --
; source X step 0, dest X step 1, so the blitter re-reads the same source column
; for every destination column. Per deferred column the renderer then pays a
; 13-byte signature compare and the occlusion bookkeeping instead of ~2500
; cycles and several blits.
;
; The signature is everything the drawn pixels depend on:
;   window [rs_top, rs_bot]     -- the clip range, and the copy's row range
;   rs_ycacc / rs_yfacc  hi     -- front ceiling/floor rows (integer part)
;   rs_ybcacc / rs_ybfacc hi    -- back rows (portals; constant on solid segs)
;   rs_dscr                     -- drives tpr/S/spy/rpt via tw_setup's memo
;   rs_uacc+1                   -- the texture column (before masking: equal u
;                                  implies equal tex_x; a masked-equal miss just
;                                  costs a merge, never correctness)
; Colours, textures, peg rows and rs_vsh* are per SEG, so they are constant
; inside one column loop and need no comparison.
;
; A run must be CONTIGUOUS: any column the loop skips (already solid, or its
; window closed) flushes the pending copy first, as does the end of the seg.
;
; The copy reuses the textured-wall BCB (VRAM_BCB_TWALL): only SRC_STEPY and
; WIDTH differ from what draw_twall_col leaves there, and WIDTH is put back to 0
; right after the start (the blitter latches the whole BCB at BL_START -- the
; same guarantee tw_blit already relies on).
;==============================================================

        org COLMERGE_BASE

;--------------------------------------------------------------
; cm_reset -- called once per seg, before its column loop.
;--------------------------------------------------------------
.proc cm_reset
        lda #0
        sta cm_n
        lda #$FF
        sta cm_x                     ; no source column yet
        rts
.endp

;--------------------------------------------------------------
; cm_test -- C = 1 if the CURRENT column would draw exactly what the pending
;   source column already drew. Preserves X/Y. Clobbers A.
;--------------------------------------------------------------
.proc cm_test
        lda cm_x
        bmi ?no                      ; nothing drawn yet / run broken
        lda rs_top
        cmp cm_top
        bne ?no
        lda rs_bot
        cmp cm_bot
        bne ?no
        lda rs_ycacc+1
        cmp cm_sig
        bne ?no
        lda rs_ycacc+2
        cmp cm_sig+1
        bne ?no
        lda rs_yfacc+1
        cmp cm_sig+2
        bne ?no
        lda rs_yfacc+2
        cmp cm_sig+3
        bne ?no
        lda rs_ybcacc+1
        cmp cm_sig+4
        bne ?no
        lda rs_ybcacc+2
        cmp cm_sig+5
        bne ?no
        lda rs_ybfacc+1
        cmp cm_sig+6
        bne ?no
        lda rs_ybfacc+2
        cmp cm_sig+7
        bne ?no
        lda rs_rpt                   ; the painter's per-column scale. It was
        cmp cm_sig+8                 ;   rs_dscr until 2026-08-27, and rs_dscr
        bne ?no                      ;   went with tw_setup; rpt is the stricter
        lda rs_rpt+1                 ;   test anyway -- it is what the texel walk
        cmp cm_sig+9                 ;   actually uses, and the accumulator bytes
        bne ?no                      ;   above already pin dscr to within 1/16 row
        lda rs_uacc+1
        cmp cm_sig+10
        bne ?no
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; cm_save -- the current column (X) was DRAWN: make it the run's source and
;   record the occlusion state it produced, so the deferred twins can replay it.
;   Preserves X/Y. Clobbers A.
;--------------------------------------------------------------
.proc cm_save
        stx cm_x
        lda #0
        sta cm_n
        lda rs_top
        sta cm_top
        lda rs_bot
        sta cm_bot
        lda rs_ycacc+1
        sta cm_sig
        lda rs_ycacc+2
        sta cm_sig+1
        lda rs_yfacc+1
        sta cm_sig+2
        lda rs_yfacc+2
        sta cm_sig+3
        lda rs_ybcacc+1
        sta cm_sig+4
        lda rs_ybcacc+2
        sta cm_sig+5
        lda rs_ybfacc+1
        sta cm_sig+6
        lda rs_ybfacc+2
        sta cm_sig+7
        lda rs_rpt                   ; ... and the same in the saved signature
        sta cm_sig+8
        lda rs_rpt+1
        sta cm_sig+9
        lda rs_uacc+1
        sta cm_sig+10
        lda solid_arr,x              ; the post-state, whichever path drew it
        sta cm_solid
        lda ytopc_arr,x
        sta cm_nt
        lda ybotc_arr,x
        sta cm_nb
        rts
.endp

;--------------------------------------------------------------
; cm_defer -- identical column: skip the drawing, replay the occlusion state.
;   Preserves X/Y. Clobbers A.
;--------------------------------------------------------------
.proc cm_defer
        inc cm_n
        lda cm_nt
        sta ytopc_arr,x
        lda cm_nb
        sta ybotc_arr,x
        lda cm_solid
        beq ?done                    ; portal still open -> nothing else to do
        sta solid_arr,x              ; closed: same early-out bookkeeping as the
        dec cols_open                ;   drawing paths do
        bne ?done
        sta frame_done
?done   rts
.endp

;--------------------------------------------------------------
; cm_flush -- replicate the source column across the deferred ones (one blit),
;   then break the run. Called before drawing a different column, before any
;   skipped column, and at the end of the seg. Preserves X/Y. Clobbers A.
;--------------------------------------------------------------
.proc cm_flush
        lda cm_n
        beq ?none
        stx cm_savex
    .if TEX_RUNS
        jsr ptc_fire_wait            ; the source column's spans may still sit in
                                     ;   the OPEN chain: launch it, then wait
    .else
        jsr blitter_wait             ; the source column's own blits must be done
    .endif
        ldx cm_top                   ; row -> framebuffer offset
        lda row_lo,x
        clc
        adc cm_x
        sta MEMW+MEMW_TW_OFF+BCB_SRC_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_TW_OFF+BCB_SRC_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_TW_OFF+BCB_SRC_ADDR+2
        lda row_lo,x                 ; destination starts one column right
        sec                          ; (sec: the +1 comes free with the carry)
        adc cm_x
        sta MEMW+MEMW_TW_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_TW_OFF+BCB_DST_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_TW_OFF+BCB_DST_ADDR+2
        lda #<SCREEN_WIDTH           ; walk the SOURCE down a column too
        sta MEMW+MEMW_TW_OFF+BCB_SRC_STEPY
        lda #>SCREEN_WIDTH
        sta MEMW+MEMW_TW_OFF+BCB_SRC_STEPY+1
        lda #0
        sta MEMW+MEMW_TW_OFF+BCB_ZOOM
        sta MEMW+MEMW_TW_OFF+BCB_WIDTH+1
        lda cm_n                     ; WIDTH-1 = deferred columns - 1
        sec
        sbc #1
        sta MEMW+MEMW_TW_OFF+BCB_WIDTH
        sec                          ; HEIGHT-1 = bot - top
        lda cm_bot
        sbc cm_top
        sta MEMW+MEMW_TW_OFF+BCB_HEIGHT
        lda #<VRAM_BCB_TWALL
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_TWALL
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_TWALL>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START            ; async -- AND THE BCB IS *NOT* LATCHED HERE
                                     ;   (2026-08-29, the real-hardware stripes).
                                     ;   That the whole 21-byte block is captured
                                     ;   by the write is an ALTIRRA property, not
                                     ;   a VBXE one: its BLITTER_START handler
                                     ;   calls LoadBlitter() inline ('we have to
                                     ;   load the first entry immediately because
                                     ;   some demos are a bit creative and
                                     ;   overwrite the first entry without
                                     ;   checking blitter status', vbxe.cpp:1361).
                                     ;   The FX core FETCHES those 21 bytes out of
                                     ;   VRAM afterwards, on whatever DMA cycles
                                     ;   the display leaves it -- and the two
                                     ;   instructions that used to sit here
                                     ;   ('hand the BCB back as a 1-byte-wide
                                     ;   column', ~10 cycles, far fewer on a
                                     ;   Rapidus) beat that fetch to BCB_WIDTH.
                                     ;   The copy then ran ONE column wide instead
                                     ;   of cm_n, so every twin but the first kept
                                     ;   what the back buffer held three frames
                                     ;   ago: the 2-5 column stripes of stale
                                     ;   ceiling/floor colour people photographed
                                     ;   (3.png -- x-cols 29-30, 37-38, 41-42,
                                     ;   45-46, 58-61, 66-70, 76-77, each one
                                     ;   exactly a merged run).
                                     ;   Nothing needs the reset any more: with
                                     ;   TEX_RUNS=1 cm_flush is the ONLY user of
                                     ;   the TWALL BCB and it writes WIDTH on
                                     ;   every call. draw_vspan, which did rely on
                                     ;   the 1-px invariant, is compiled out.
        lda #0
    .if !TEX_RUNS
        sta MEMW+MEMW_TW_OFF+BCB_WIDTH   ; draw_vspan never sets WIDTH itself
    .endif
        sta cm_n
        ldx cm_savex
?none   lda #$FF                     ; the run is over either way
        sta cm_x
        rts
.endp

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
.proc bg_fill
        ldx vw_x0                    ; only the view window: outside it every
?scan   lda solid_arr,x              ; closed columns are fully painted
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
        jmp ?ext
?emit   jsr bg_blit
        cpx vw_xend
        bcc ?scan
        rts
?nx     inx
        cpx vw_xend
        bcc ?scan
        rts
.endp

;--------------------------------------------------------------
; bg_blit -- one rectangle of background colour: columns bg_x0..+bg_w-1,
;   rows bg_top..bg_bot. Uses the vline fill BCB (AND 0 / XOR colour) with its
;   width widened for the run, and hands it back 1 byte wide. Preserves X.
;--------------------------------------------------------------
.proc bg_blit
        stx cm_savex
    .if TEX_RUNS
        jsr ptc_fire_wait            ; normally a plain wait (ptc_fbg already
                                     ;   fired the walk's last chain)
    .else
        jsr blitter_wait
    .endif
        ldx bg_top
        lda row_lo,x
        clc
        adc bg_x0
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+2
        sec
        lda bg_bot
        sbc bg_top
        sta MEMW+MEMW_VL_OFF+BCB_HEIGHT
        lda bg_w
        sec
        sbc #1
        sta MEMW+MEMW_VL_OFF+BCB_WIDTH
        lda #BG_COLOUR
        sta MEMW+MEMW_VL_OFF+BCB_XOR
        lda #<VRAM_BCB_VLINE
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_VLINE
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_VLINE>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START            ; async, and the BCB is NOT captured by this
                                     ;   write on real VBXE -- see the long note
                                     ;   in cm_flush. The reset that used to
                                     ;   follow raced the core's own fetch of
                                     ;   BCB_WIDTH and collapsed the background
                                     ;   rectangle to ONE column, which is the
                                     ;   wide "jumping fragment" version of the
                                     ;   same bug: a gap the BSP walk left open
                                     ;   kept the buffer's three-frames-old
                                     ;   picture instead of BG_COLOUR.
                                     ;   bg_blit sets WIDTH from bg_w on every
                                     ;   call, and with TEX_RUNS=1 it is the only
                                     ;   user of the VLINE BCB's slot 0, so the
                                     ;   invariant it restored has no reader left.
    .if !TEX_RUNS
        lda #0                       ; back to a 1-pixel column for draw_vspan
        sta MEMW+MEMW_VL_OFF+BCB_WIDTH
    .endif
        ldx cm_savex
        rts
.endp

bg_top     dta 0
bg_bot     dta 0
bg_x0      dta 0
bg_w       dta 0

;--------------------------------------------------------------
; clear_both -- wipe BOTH framebuffers once at boot. The frame loop does not
;   clear any more (bg_fill only repaints the gaps), so a buffer's very first
;   frame would otherwise show whatever VRAM powered up with. Leaves zback_hi
;   as it found it.
;
;   OUT OF THE FAST BLOCK (2026-08-09). Everything else in this file runs per
;   column, per seg or per frame and has to stay in the Rapidus window; this one
;   is called ONCE, from main (bsp_main.asm), before the game loop -- never from
;   init_level and never from a frame. So it pays the slow window with ~30
;   cycles at boot (the two clear_screen calls, which do all the work, do not
;   move) and hands 23 B back to the $1B80 block, which had 6 left.
;--------------------------------------------------------------
cbo_resume = *
        org CLRBOTH_BASE
.proc clear_both
        lda #$01                     ; clear FRAME_B (back buffer)
        sta zback_hi
        lda #BG_COLOUR
        jsr clear_screen
        lda #$07                     ; clear FRAME_C (triple buffer)
        sta zback_hi
        lda #BG_COLOUR
        jsr clear_screen
        lda #$00                     ; leave pointing to FRAME_A, skip clearing
        sta zback_hi                 ; it (displayed) to avoid black flash
        rts
.endp
    .if * > CLRBOTH_END+1
        ert 'clear_both outgrew CLRBOTH_BASE..END (memory_map.inc)'
    .endif
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
; with N = 8 on a 160-column screen the error stays well under a texel except on
; extremely oblique walls -- the same trade Doom8088 makes with its "approx"
; math. Cost per column drops from ~1000 cycles to ~2*1000/N + ~40, i.e. ~4x.
;
; Anchors recompute BOTH ends of the block (u at x and at x+N) and derive the
; per-column step by a shift, so no error accumulates across blocks: every
; anchor re-syncs to the exact perspective value.
;==============================================================
CU_SUB    equ 8                      ; columns per block (power of two)
CU_SHIFT  equ 3                      ; log2(CU_SUB)

;--------------------------------------------------------------
; cu_seg_init -- call once per seg, before its column loop.
;--------------------------------------------------------------
.proc cu_seg_init
        lda #0
        sta cu_cnt                   ; 0 -> the first column is an anchor
        lda #$FF                     ; ... and no look-ahead u carries over: the
        sta cu_cx                    ;   t1/t2 tracks are this seg's now
        rts
.endp

;--------------------------------------------------------------
; calc_u_sub -- drop-in replacement for `jsr calc_u` in the column loop.
;   Preserves X (the column index). Clobbers A/Y + the math scratch.
;   Per-column paths only; the block-start body is cu_anchor below.
;--------------------------------------------------------------
.proc calc_u_sub
        lda tws_exact                ; steep block (tw_setup_sub's verdict): the
        bne ?exact                   ;   affine step tears whole texels there, so
        dec cu_cnt                   ;   u is exact per column while it holds
        bmi ?far
        clc                          ; interpolate: rs_uacc += cu_step (24-bit)
        lda rs_uacc
        adc cu_step
        sta rs_uacc
        lda rs_uacc+1
        adc cu_step+1
        sta rs_uacc+1
        lda rs_uacc+2
        adc cu_sgn
        sta rs_uacc+2
        rts
?far    jmp cu_anchor
?exact  jsr calc_u                   ; exact u at THIS column (calc_u keeps X)
        lda #0
        sta cu_cnt                   ; leaving steep mode re-anchors immediately
        rts
.endp

cu_cnt   dta 0                       ; columns left in this block
cu_step  dta 0,0                     ; per-column u step (Q8, 16-bit)
cu_sgn   dta 0                       ; its sign extension for the 24-bit add
cu_u0    dta 0,0,0                   ; exact u at the block's first column
cu_save  dta 0,0,0,0,0,0             ; rs_t1/rs_t2 across the look-ahead
cu_sx    dta 0
cu_ah    dta 0,0,0                   ; exact u at the column the look-ahead hit
cu_cx    dta $FF                     ; ... and which column that was ($FF = none)


;--------------------------------------------------------------
; cu_anchor -- calc_u_sub's block start: exact u here AND las_n columns ahead,
;   linear step in between. Entered by jmp, returns straight to the column loop.
;   Fast block on purpose: both calc_u calls and the track walk are hot.
;--------------------------------------------------------------
.proc cu_anchor
        stx cu_sx                    ; calc_u preserves X, but the t1/t2 shuffle
        cpx cu_cx                    ; did the LAST block's look-ahead land
        bne ?fresh                   ;   exactly here? then u is already known
        ldy #2
?cp     lda cu_ah,y
        sta cu_u0,y
        dey
        bpl ?cp
        bmi ?have0                   ; always (dey wrapped to $FF)
?fresh  jsr calc_u                   ; exact u at THIS column
        lda rs_uacc                  ; keep it: the block starts here
        sta cu_u0
        lda rs_uacc+1
        sta cu_u0+1
        lda rs_uacc+2
        sta cu_u0+2
?have0  jsr twlas_room               ; F6: never walk past the seg's right edge
        ; --- t1/t2 las_n columns ahead (they advance by constants per column) --
        ldy #0
?sv     lda rs_t1,y                  ; save both tracks (3 bytes each)
        sta cu_save,y
        iny
        cpy #6
        bne ?sv
        ldy las_n
?adv    clc                          ; t1 += scR, t2 -= scL, las_n times
        lda rs_t1
        adc rs_utR
        sta rs_t1
        lda rs_t1+1
        adc rs_utR+1
        sta rs_t1+1
        lda rs_t1+2
        adc #0
        sta rs_t1+2
        sec
        lda rs_t2
        sbc rs_utL
        sta rs_t2
        lda rs_t2+1
        sbc rs_utL+1
        sta rs_t2+1
        lda rs_t2+2
        sbc #0
        sta rs_t2+2
        dey
        bne ?adv
        jsr calc_u                   ; exact u at column x + las_n
        ldy #2                       ; ... which is where the NEXT anchor starts,
?sa     lda rs_uacc,y                ;   so hand it the answer instead of making
        sta cu_ah,y                  ;   it divide for the same number again
        dey
        bpl ?sa
        txa                          ; X is still this anchor's column
        clc
        adc las_n
        sta cu_cx
        ldy #0
?rs     lda cu_save,y                ; put the real tracks back
        sta rs_t1,y
        iny
        cpy #6
        bne ?rs
        sec                          ; step = (u_ahead - u0) >> las_sh (signed)
        lda rs_uacc
        sbc cu_u0
        sta cu_step
        lda rs_uacc+1
        sbc cu_u0+1
        sta cu_step+1
        lda rs_uacc+2
        sbc cu_u0+2
        sta cu_sgn                   ; the difference's sign/high byte
        ldy las_sh
        beq ?shdone                  ; las_n = 1: the step is never consumed
?sh     lda cu_sgn                   ; arithmetic shift right of the 24-bit delta
        cmp #$80
        ror cu_sgn
        ror cu_step+1
        ror cu_step
        dey
        bne ?sh
?shdone lda cu_sgn                   ; keep only the sign for the 24-bit adds
        bpl ?pos
        lda #$FF
        bne ?ssv                     ; always taken
?pos    lda #0
?ssv    sta cu_sgn
        lda cu_u0                    ; the block starts at the exact value
        sta rs_uacc
        lda cu_u0+1
        sta rs_uacc+1
        lda cu_u0+2
        sta rs_uacc+2
        ldy las_n
        dey
        sty cu_cnt
        ldx cu_sx
        rts
.endp

;==============================================================
; tw_setup_sub -- the same subdivision, applied to the texel RATE
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
; (max 327 -> 18 tpr LSBs over an E1M1 spawn frame; tools/tests/_probe_tpr3.py).
; What is left here is the F3 steep verdict, which the perspective-u track still
; needs (calc_u_sub reads tws_exact), and the block counter that paces it.
;==============================================================
.proc tw_seg_init
        lda #0
        sta tws_cnt
        sta tws_exact                ; steep mode never leaks across segs
        rts
.endp

.proc tw_setup_sub
        dec tws_cnt                  ; the rate itself needs nothing per column
        bmi ?far                     ;   now -- this only paces the steep re-test
        rts
?far    jmp tws_anchor
.endp

tws_cnt   dta 0
tws_exact dta 0                      ; 1 = steep block: per-column exact u

    .if * > COLMERGE_END
        ert 'colmerge.asm (fast block) outgrew its hole -- see memory_map.inc'
    .endif

;==============================================================
; TWANCHOR block -- tw_setup_sub's anchor body, relocated to the RAM under the
; OS ROM (memory_map.inc TWANCHOR_BASE). It only ever runs inside the frame
; loop, i.e. after bsp_main's rom_out, exactly like seg_yoff ($CD80) -- and its
; time is dominated by the two tw_setup calls, which are ALSO in slow RAM
; ($8D00), so the relocation costs the anchor little. The per-column paths and
; the calc_u-hot cu_anchor stay in the $1B80 fast-window block above.
;
; Together the two anchors carry the close-wall/turning deformation fixes
; (tools/_verify_twdeform.py, variant "ASM NOW" = F6+F2+F1+F3):
;   F6  the look-ahead used to walk CU_SUB columns past the seg's right edge:
;       t2 = scL*(sxR-x) goes negative there, wraps the 24-bit track and the
;       whole final block interpolates toward garbage -- the "tripled switch"
;       (5.png). twlas_room shrinks the look-ahead to what fits before sxR.
;   F2  tws_step was Q8-truncated (>>3 drops 7 LSB); across a block, times the
;       (row - pegrow) lever arm, that is whole-texel phase staircasing. The
;       step is Q16 now (see tw_setup_sub above).
;   F1  the look-ahead tw_setup call could HIT the dscr memo and silently keep
;       the current INTERPOLATED rs_tpr as "rate ahead" (the memo also ignores
;       tw_dsh -- same dscr with a different shift is a 2x rate). Both calls
;       invalidate the memo now; the memo still pays off between anchors.
;   F3  on a steep AND tall block (screen height changes >= 1/8 of itself over
;       one block) linear u/rate interpolation is off by texels even with exact
;       anchors -- so those columns run EXACT u + rate, per column, while the
;       flag holds. Costs the two udiv24s only where the tearing was visible.
;==============================================================
twa_resume = *
        org TWANCHOR_BASE

;--------------------------------------------------------------
; twlas_room -- look-ahead room check (F6): from column X (preserved), clamp the
;   block to the largest power of two <= min(CU_SUB, rs_sxR - X). las_n = 1, 2,
;   4 or 8 columns, las_sh = its shift. rs_sxR >= X always (X <= xb <= sxR).
;   The old code always walked CU_SUB columns ahead: past the seg's right edge
;   t2 = scL*(sxR-x) goes NEGATIVE, wraps the 24-bit track, and the whole final
;   block interpolates toward garbage -- the "tripled switch" (5.png).
;--------------------------------------------------------------
.proc twlas_room
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
        lda #1                       ; room 0..1: anchor-only block (the step is
        sta las_n                    ;   dead -- las_n-1 = 0 columns follow it)
        lda #0
        beq ?ssh                     ; always
?n2     lda #2
        sta las_n
        lda #1
        bne ?ssh
?n4     lda #4
        sta las_n
        lda #2
        bne ?ssh
?full   lda #CU_SUB
        sta las_n
        lda #CU_SHIFT
?ssh    sta las_sh
        rts
.endp

las_n     dta 0                      ; look-ahead block: columns (1/2/4/8)
las_sh    dta 0                      ; ... and its shift (0/1/2/3)
;--------------------------------------------------------------
; tws_anchor -- tw_setup_sub's block start. First the F3 steep test; a steep
;   column gets the exact rate (+ ladder) and keeps anchoring every column.
;   Otherwise the normal look-ahead anchor with F6 room + F1 memo + F2 Q16 step.
;--------------------------------------------------------------
.proc tws_anchor
        stx tws_sx
        ; ---- F3 steep test: D = yfacc - ycacc (24-bit, the wall's screen
        ;      height in Q8 rows); steep <=> D >= 4096 AND |yfS-ycS|<<6 >= D
        ;      (the height moves by >= D/8 across one CU_SUB block) ----
        sec
        lda rs_yfacc
        sbc rs_ycacc
        sta m_prod
        lda rs_yfacc+1
        sbc rs_ycacc+1
        sta m_prod+1
        lda rs_yfacc+2
        sbc rs_ycacc+2
        sta m_prod+2
        bpl ?dok                     ; D < 0: sliver/degenerate -> interpolate
        jmp ?nosteep
?dok    bne ?big                     ; D >= 65536 > 4096
        lda m_prod+1
        cmp #$10                     ; D >= 4096 <=> mid byte >= $10 (hi = 0)
        bcc ?nosteep
?big    lda #0                       ; dS = yfS - ycS as SIGNED 17-bit: both are
        sta m_res                    ;   s16, so the plain 16-bit difference can
        sta m_res+1                  ;   wrap -- extend both before subtracting
        lda rs_yfS+1
        bpl ?ya
        dec m_res                    ; m_res   = sign of yfS
?ya     lda rs_ycS+1
        bpl ?yb
        dec m_res+1                  ; m_res+1 = sign of ycS
?yb     sec
        lda rs_yfS
        sbc rs_ycS
        sta m_a
        lda rs_yfS+1
        sbc rs_ycS+1
        sta m_a+1
        lda m_res
        sbc m_res+1
        sta m_b                      ; (m_b, m_a+1, m_a) = dS, 24-bit
        bpl ?abs
        jsr m_neg                    ; |dS|
        lda #0
        sbc m_b
        sta m_b
?abs    ldy #6                       ; |dS| << 6 (<= 17 bits in -> fits 24)
?shl    asl m_a
        rol m_a+1
        rol m_b
        dey
        bne ?shl
        lda m_b                      ; steep <=> |dS|<<6 >= D
        cmp m_prod+2
        bcc ?nosteep
        bne ?steep
        lda m_a+1
        cmp m_prod+1
        bcc ?nosteep
        bne ?steep
        lda m_a
        cmp m_prod
        bcc ?nosteep
?steep  lda #1
        sta tws_exact
        lda #0
        sta tws_cnt                  ; cnt 0 -> re-test steepness NEXT column too
        ldx tws_sx
        rts
?nosteep
        lda #0                       ; F6: the block still ends where the u track's
        sta tws_exact                ;   does, so the two stay in step -- but with
        jsr twlas_room               ;   nothing to interpolate that is all an
        ldy las_n                    ;   anchor has left to do
        dey
        sty tws_cnt
        ldx tws_sx
        rts
.endp

; anchor-only state (nothing per-column reads this)
tws_sx    dta 0

    .if * > TWANCHOR_END
        ert 'TWANCHOR block outgrew its hole -- see memory_map.inc'
    .endif
        org twa_resume
