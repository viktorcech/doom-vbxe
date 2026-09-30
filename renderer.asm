;--------------------------------------------------------------
; renderer.asm -- the BSP front-to-back walk with per-column occlusion.
;--------------------------------------------------------------
ZNEAR     equ 4

;--------------------------------------------------------------
; frame_setup -- load sin/cos for zp_ang.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc frame_setup
        lda zp_ang                    ; tips #4: skip the ~7.5k-cyc rebuild when the
        cmp frame_ang                ;   angle is unchanged (walking straight) -- zp_sin/
        beq ?same                    ;   zp_cos AND the frac tables are still valid then
        sta frame_ang
        ldx zp_ang                   ; the tables live in Rapidus bank $01 now
        lda.l TRGX_SIN_LO,x          ;   (memory_map.inc TRIG_EXT): +1 cycle a
        sta zp_sin                   ;   read, on the one path that reads them,
        lda.l TRGX_SIN_HI,x          ;   and only when the angle changed at all
        sta zp_sin+1
        lda.l TRGX_COS_LO,x
        sta zp_cos
        lda.l TRGX_COS_HI,x
        sta zp_cos+1
        jmp build_frac_tables        ; rebuild |sin|/|cos| product tables for fmul_*
?same   rts
.endp
        .endseg

;--------------------------------------------------------------
; walk_init -- rs_mpass = 0, then on into the frame entry it displaced.
;--------------------------------------------------------------
wki_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc walk_init
        stz rs_mpass
    .if TEX_RUNS
        jmp ptc_frame                ; the call this routine displaced
    .else
        jmp spr_reset
    .endif
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org wki_resume

;--------------------------------------------------------------
; render_world -- clear occlusion, walk the BSP from the root.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc render_world
        ; Only the VIEW WINDOW is re-opened (viewsize.asm): outside it every ...
                                      ; 2026-09-22 (6502-idioms: an index counting UP to
        rep #$21                     ;   zero): X runs x0-xend .. 255 and the three store
        .LONGA ON                    ;   bases are the arrays + xend - 256, patched once a
        lda vw_xend                  ;   frame -- the wrap to 0 is the exit, no cpx (-2 a
        and #$00FF                   ;   column, 160 a frame). A store costs the same
        adc #solid_arr-256           ;   across a page (alt-src cpu65c816: abs,x writes
        sta.l B1CODE_BASE+rwc0+1     ;   ALWAYS take the extra cycle) and its dummy read
        adc #ytopc_arr-solid_arr     ;   is plain RAM. C = 0 all along: < $10000
        sta.l B1CODE_BASE+rwc1+1
        adc #ybotc_arr-ytopc_arr
        sta.l B1CODE_BASE+rwc2+1
        .LONGA OFF
        sep #$20
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
        lda vw_y0                    ;   TWO columns a pass. The rows go into the
        sta.l B1CODE_BASE+rwct+1     ;   loop's immediates as y|y<<8 words; every
        sta.l B1CODE_BASE+rwct+2     ;   vw_tab window is an EVEN count of columns
        lda vw_y1                    ;   from an even x0, so X still ends on 0
        sta.l B1CODE_BASE+rwcb+1
        sta.l B1CODE_BASE+rwcb+2
        lda vw_x0                    ; X = x0 - xend (mod 256): 256 - the columns
        sec
        sbc vw_xend
        tax
        rep #$20
        .LONGA ON
?cl
rwc0    stz solid_arr,x              ; (the five operands are patched above)
rwct    lda #$0000                   ; y0 | y0<<8
rwc1    sta ytopc_arr,x              ; open window top
rwcb    lda #$0000                   ; y1 | y1<<8
rwc2    sta ybotc_arr,x              ; open window bottom (status bar starts below)
        inx
        inx
        bne ?cl
        sep #$20                     ; A = y1, B = y1: what the byte loop left in B
        .LONGA OFF

        lda vw_ncol                  ; early-out: columns still open
        sta cols_open
        inc vc_frame                 ; the vertex cache's frame stamp (seg_draw.asm
        bne ?vcok                    ;   vc_look): 1..255; on the wrap every stamp
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
        ldx #0                       ;   the 256 stamps two a store (vc_look): 1..255;
        rep #$20                     ;   on the wrap every stamp is cleared so an old
        .LONGA ON                    ;   frame's entry can never match
        lda #$0000
?vcz    sta.l VCACHE_BASE+VC_STAMP,x
        inx
        inx
        bne ?vcz
        sep #$20
        .LONGA OFF
        lda vw_y1                    ; A = 0, B = y1: exactly what the byte loop left
        xba
        lda #0
        inc vc_frame
?vcok   lda vc_frame                 ; 2026-09-26: the stamp into VC_LOOK's two
        sta.l B1CODE_BASE+process_seg.VC_LOOK0.ps_v1stc+1   ;   `cmp #` operands, once a
        sta.l B1CODE_BASE+process_seg.VC_LOOK1.ps_v2stc+1   ;   frame (no load per lookup)
        lda #$FF                     ; the frame's first portal patches the column
        sta ps_shut                  ;   loop for itself (seg_draw.asm ?shp)
        stz frame_done
        stz bsp_sp
	stz ms_n
                                     ;   sprites is reset by spr_reset, and ...
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
    .if TEX_RUNS
        jsr walk_init                ; rs_mpass = 0 (the overlay window wrote
                                     ;   over it), then ptc_frame: zback stamp + ...
        jsr render_node
        jsr ptc_fbg                  ; the walk's last open chain, THEN bg_fill
    .else
        jsr walk_init                ; rs_mpass = 0, then spr_reset: no
                                     ;   vissprites yet this frame
        jsr render_node
        jsr bg_fill                  ; paint only what the walk left open (colmerge.asm)
    .endif
        jsr mseg_draw                ; the two-sided MIDDLE textures -- the struts
                                     ;   and fences you look THROUGH -- go over
                                     ;   whatever the walk painted behind them,
                                     ;   and UNDER the billboards.
        jmp spr_draw                 ; billboards last, back to front.
.endp
        .endseg

;--------------------------------------------------------------
; calc_nodeptr -- zp_nodeptr = MAP_NODES + (zp_nid & $7FFF)*NODE_SIZE
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc calc_nodeptr
        ; 16-BIT A (2026-08-31, from a reader of the disassembly): the old ...
        rep #$20
        .LONGA ON
cnp_w16                              ; (2026-09-22: 16-bit callers enter here)
        lda zp_nid                   ; no `and #$7FFF`: the NODE_LEAF bit (and
        asl @                        ;   bit 14) fall out of these two shifts,
        asl @                        ;   so nid*4 is already clean -- drac030's
        sta m_ma                     ;   drac030 point 1, applied everywhere
        asl @
        asl @
        asl @                        ; nid*32
        sec
        sbc m_ma                     ; nid*28 = NODE_SIZE
	adc #MAP_NODES-1	;C=1 here
        sta zp_nodeptr               ;   readers go [zp_nodeptr],y (long indirect)
        .LONGA OFF                   ;   with zp_nodeptr+2 = MAP_EXT_BANK, set ONCE
                                    ; 2026-09-22 (65816-windows): calc_nodeptr returns 16-bit
        rts
.endp
        .endseg

;--------------------------------------------------------------
; point_on_side -- A = 0 (front/right) or 1 (back/left) for the player
;   vs the node partition. side0 iff (ndy*dxp - dyp*ndx) > 0.
;   node: x@0 y@2 dx@4 dy@6.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc point_on_side
                                      ; 2026-09-22 (65816-windows): rep FIRST, so the
	rep #$20                     ;   16-bit callers (calc_nodeptr returns 16-bit now)
	.LONGA ON                    ;   enter at pos_w16 past it; rep and sec commute
pos_w16 sec                          ; dxp = px - node.x  -> cx_b
        lda zp_px
        sbc [zp_nodeptr]
        sta cx_b

        sec                          ; dyp = py - node.y  -> cx_c
	ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        sta cx_c

        ldy #6                       ; cx_a = node.dy
        lda [zp_nodeptr],y
        sta cx_a

        ldy #4                       ; cx_d = node.dx
        lda [zp_nodeptr],y
        sta cx_d
	sep #$20
	.LONGA OFF
        bne ?nv
        lda cx_b                     ; dxp == 0 -> cross 0 -> side1
        ora cx_b+1
        beq ?s1
        lda cx_a+1                   ; sign(ndy) XOR sign(dxp)
        eor cx_b+1
        bmi ?s1                      ; different signs -> cross<0 -> side1
        bpl ?s0                      ; same signs     -> cross>0 -> side0
?nv     lda cx_a                     ; node.dy == 0 ? -> horizontal split: cross = -dyp*ndx
        ora cx_a+1
        bne ?gen
        lda cx_c                     ; dyp == 0 -> cross 0 -> side1
        ora cx_c+1
        beq ?s1
        lda cx_c+1                   ; sign(dyp) XOR sign(ndx)
        eor cx_d+1
        bmi ?s0                      ; opposite signs -> -dyp*ndx>0 -> side0
        bpl ?s1                      ; same signs     -> side1
?gen    jsr cross_pos                ; general node: A=1 if cross>0 (side0)
        eor #1                       ; -> 0 = side0, 1 = side1
        rts
?s0     lda #0
        rts
?s1     lda #1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; node_side -- calc_nodeptr + point_on_side FUSED for the descents that only
;   want the child (2026-09-26: locate_floor, use_locate, mv_sector). IN: 16-bit
;   A = zp_nid, a node (bit 15 clear). OUT: 16-bit, zp_nodeptr set, Y = 8 (side0,
;   child_r) or 10 (side1, child_l) -- the caller reads [zp_nodeptr],y. The same
;   tests as point_on_side in 16-bit A (a word's Z/N = the byte pair's ora/eor),
;   and no 0/1 answer to test again: one jsr/rts and two rep/sep pairs less.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc node_side
        .LONGA ON
        asl @                        ; zp_nodeptr = MAP_NODES + nid*28 (calc_nodeptr)
        asl @
        sta m_ma
        asl @
        asl @
        asl @
        sec
        sbc m_ma
        adc #MAP_NODES-1             ; C=1 here
        sta zp_nodeptr
                                      ; 2026-09-26 (2nd pass): the axis splits decide
        ldy #4                       ;   from registers -- the four cx_* cells only
        lda [zp_nodeptr],y           ;   feed cross_pos, so only ?gen writes them.
        bne ?nv                      ; node.dx == 0 -> vertical split
        sec                          ; dxp = px - node.x
        lda zp_px
        sbc [zp_nodeptr]
        beq ?s1                      ; dxp == 0 -> cross 0 -> side1
        ldy #6
        eor [zp_nodeptr],y           ; sign(ndy) XOR sign(dxp): differ -> side1
        bmi ?s1
?s0     ldy #8
        rts
?nv     ldy #6                       ; node.dy == 0 -> horizontal split
        lda [zp_nodeptr],y
        bne ?gen
        sec                          ; dyp = py - node.y
        ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        beq ?s1                      ; dyp == 0 -> side1
        ldy #4
        eor [zp_nodeptr],y           ; sign(dyp) XOR sign(ndx): opposite -> side0
        bmi ?s0
        bra ?s1
?gen    sta cx_a                     ; cx_a = node.dy (A, the bne's)
        sec                          ; dxp = px - node.x -> cx_b
        lda zp_px
        sbc [zp_nodeptr]
        sta cx_b
        sec                          ; dyp = py - node.y -> cx_c
        ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        sta cx_c
        ldy #4                       ; cx_d = node.dx
        lda [zp_nodeptr],y
        sta cx_d
        jsr cross_pos.cp_w16         ; A=1 (Z=0) if cross>0 -> side0; returns 8-bit
        rep #$20
        bne ?s0
?s1     ldy #10
        rts
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; render_node -- recursive BSP walk. zp_nid = node id (bit15=leaf).
;--------------------------------------------------------------
; tips #5: ITERATIVE walk with an explicit far-child stack (bsp_stack) instead of
; recursion -> no per-node jsr/rts, frees the CPU stack for deep maps. Same
; near-first (front-to-back) visit order as the old recursion -> identical render.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc render_node
        bra ?walk                    ; (the leaf half sits in front of the walk,
?done   rts                          ;   so ?live reaches it with a short bmi;
                                      ;   2026-09-27: ?done too, so ?walk's frame_done
                                      ;   test falls through on the 99 % path)
?leaf   jsr render_subsector
?pop    ldx bsp_sp                   ; pop next far child (LIFO)
        beq ?done                    ; stack empty -> whole tree walked
        dex
        dex
        stx bsp_sp
        lda bsp_stack,x
        sta zp_nid
        lda bsp_stack+1,x
        sta zp_nid+1
?walk   lda frame_done               ; early-out: whole screen already solid
        bne ?done
?live   bit zp_nid+1                 ; bit 15 = leaf (A is no input there)
        bmi ?leaf
        ; calc_nodeptr + point_on_side INLINED (2026-09-15): ONE 16-bit window ...
        rep #$20
        .LONGA ON
        lda zp_nid                   ; zp_nodeptr = MAP_NODES + nid*28
        asl @
        asl @
        sta m_ma
        asl @
        asl @
        asl @
        sec
        sbc m_ma
        adc #MAP_NODES-1             ; C=1 here (calc_nodeptr)
        sta zp_nodeptr
                                      ; 2026-09-26: the axis splits decide in 16-bit
        ldy #4                       ;   A from the node words (as node_side): the
        lda [zp_nodeptr],y           ;   cx_* cells only feed cross_pos, so only
        bne ?pnv                     ;   ?pgen writes them. node.dx == 0: vertical
        sec                          ; dxp = px - node.x
        lda zp_px
        sbc [zp_nodeptr]
        beq ?side1w                  ; dxp == 0 -> cross 0 -> side1
        ldy #6
        eor [zp_nodeptr],y           ; sign(ndy) XOR sign(dxp)
        bmi ?side1w
        bra ?side0w
?pnv    ldy #6                       ; node.dy == 0 ? -> horizontal split
        lda [zp_nodeptr],y
        bne ?pgen
        sec                          ; dyp = py - node.y
        ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        beq ?side1w                  ; dyp == 0 -> cross 0 -> side1
        ldy #4
        eor [zp_nodeptr],y           ; sign(dyp) XOR sign(ndx)
        bmi ?side0w
        bra ?side1w
?pgen   sta cx_a                     ; cx_a = node.dy (A, the bne's)
        sec                          ; dxp = px - node.x  -> cx_b
        lda zp_px
        sbc [zp_nodeptr]
        sta cx_b
        sec                          ; dyp = py - node.y  -> cx_c
        ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        sta cx_c
        ldy #4                       ; cx_d = node.dx
        lda [zp_nodeptr],y
        sta cx_d
        jsr cross_pos.cp_w16         ; general node: A=1 if cross>0 (side0), 8-bit
        .LONGA OFF
        eor #1                       ; -> 0 = side0, falls into the test below

                                      ; 2026-09-15: the side picks the LOAD ORDER
        bne ?side1                   ;   -- no pha/pla, no swap, and the far
?side0  rep #$20                     ;   bbox offset goes straight to cb_off
	.LONGA ON                    ;   (cb_fbb only ever fed it)
?side0w ldy #8
        lda [zp_nodeptr],y           ; side0: near = child_r, far = child_l
        sta zp_near
        ldy #10
        lda [zp_nodeptr],y
        sta zp_far
	sep #$20
	.LONGA OFF
        lda #20                      ; far = child_l -> bbox@20
        sta cb_off
        bra ?have
?side1  rep #$20
	.LONGA ON
?side1w ldy #10
        lda [zp_nodeptr],y           ; side1: near = child_l, far = child_r
        sta zp_near
        ldy #8
        lda [zp_nodeptr],y
        sta zp_far
	sep #$20
	.LONGA OFF
        lda #12                      ; far = child_r -> bbox@12
        sta cb_off
?have; R_CheckBBox on the FAR child only, exactly like DOOM's R_RenderBSPNode:
        ; the near side always gets walked, the far side is skipped when every
        ; screen column its bounding box covers is already solid.
        jsr check_bbox               ; A=1 -> subtree wholly invisible (cb_off was
                                     ;   set with the children above)
	rep #$20
	.LONGA ON
        bne ?skipfar
        ldx bsp_sp                   ; push far child onto the walk stack
        lda zp_far
        sta bsp_stack,x
        inx
        inx
        stx bsp_sp
?skipfar
        lda zp_near                  ; descend near side first
        sta zp_nid
	sep #$20
	.LONGA OFF
        jmp ?walk

.endp
        .endseg

;==============================================================
; The $1B00 block: code relocated out of the tight $2000 segment (spare RAM after
; the frac tables). Same org-redirect trick as the collision block: save the
; $2000 PC, org away, org back.
;==============================================================
cb_resume = *
        org CHECKBBOX_BASE           ; R_CheckBBox: cold-ish (once per far child),
        icl 'checkbbox.asm'          ;   and it must NOT sit in the $2000 segment
    .if * > CHECKBBOX_END+1
        ert 'checkbbox.asm outgrew CHECKBBOX_BASE..END (memory_map.inc)'
    .endif
;   2026-07-25: doors.asm MOVED to the RAM under the OS ROM (DOORS_BASE). It is
;   cold code -- update_doors returns on one load while nothing moves, try_use
;   only runs on a keypress -- and the 1089 B it held at $1B00 are the fast RAM
;   the per-column texture path needs (see underrom.asm + docs/SPEED-TEXTURES.md).
;   The main loop reaches it through the t_* trampolines in underrom.asm.
        org DOORS_BASE
        icl 'doors.asm'
    .if * > DOORS_END
        ert 'the doors block outgrew its under-ROM slot (see memory_map.inc)'
    .endif
        icl 'read_keys.asm'          ; the engine's one keyboard reader. It brings
                                     ;   its own org wrap (READKEYS_BASE), so it ...
        org COLMERGE_BASE            ; the fast RAM doors.asm gave up
        icl 'colmerge.asm'           ; per-column run merging (drives the copy blit)
        org cb_resume                ; back to the $2000 engine-code segment


;==============================================================
; calc_u -- perspective-correct horizontal texture coordinate for the current
;   column. The two weights t1 = scaleR*(x-sxL) and t2 = scaleL*(sxR-x) are
;   linear in screen x (tracked in the column loop), and
;       u = L * t1 / (t1 + t2)
;==============================================================
cu_resume = *
        org CALCU_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc calc_u
        phx                          ; (2026-09-15: the stack, not cu_savex, -1/call)
	rep #$21		;absorb CLC
	.LONGA ON
        lda rs_t1+1
        adc rs_t2+1
	bne ?ok
	inc
?ok	sta m_den
	stz m_prod                   ; byte 0 = 0 (a 16-bit stz: bytes 0-1), then
        lda rs_t1+1                  ;   bytes 1-2 = t1 >> 8 -- and A still holds
        sta m_prod+1                 ;   them, which is what udiv24_q8 takes:
	.LONGA OFF                   ;   no sep/rep, no prelude (2026-09-15)
  .ifdef ANTONIA2
	sep #$20                     ; drac030's udiv24a_v2.asm is icl'd verbatim and
	jsr udiv24                   ;   has no 16-bit entry: it starts in 8-bit A
  .else
	jsr udiv24.udiv24_q8         ; m_quot = 256 * t1/(t1+t2)  (Q8 ratio 0..256)
  .endif

	rep #$20
	.LONGA ON
	UDQ                          ; A = m_quot (2026-09-26: no reload), so the
        ldy rs_uflip                 ;   flag goes through Y (UMUL16I clobbers it)
	beq ?have
	eor #$FFFF                   ; flipped seg: u runs L .. 0 -- 256 - ratio
	sec                          ;   = ~q + 1 + 256, straight to m_b
	adc #256
?have	sta m_b
	lda rs_seglen                ; u = (L * ratio) >> 8
        sta m_a
	sep #$20
	.LONGA OFF
        UMUL16I 0, 1 ; (inlined 2026-09-26; A = m_a lo already: no reload)
	                       ; u = seg_offset + L*ratio. rs_segoff is
        stz rs_uacc                  ;   DOOM's seg->offset: how far along the
        rep #$21                     ;   LINEDEF this seg starts, so a wall the
        .LONGA ON                    ;   BSP cut in half keeps one continuous
                                     ;   texture instead of restarting at 0 on
                                     ;   each piece (9 % of E1's segs had a
        lda m_prod+1                 ;   visible seam). u is Q8, the offset is
        adc rs_segoff                ;   whole world units -> it lands in bytes
        sta rs_uacc+1                ;   1-2, same as the product.
	sep #$20
	.LONGA OFF
        plx
        rts
.endp
        .endseg
        org cu_resume

;--------------------------------------------------------------
; render_subsector -- draw all segs of subsector (zp_nid & $7FFF).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc render_subsector
        jsr spr_add                  ; things first, then the segs (R_Subsector order)
        ; ONE 16-bit window, subsector to seg pointer (2026-08-31, drac030): ...
        rep #$20
        .LONGA ON
        lda zp_nid
        asl @
        asl @                        ; ssid*4 (the leaf bit just fell out)
;       clc
        adc #MAP_SSECT
        sta zp_ptr
        ldy #2                       ; count -> zp_segcnt, one 16-bit read
        lda [zp_ptr],y
	beq ?done
        sta zp_segcnt
	lda [zp_ptr]
        sta rs_segi                  ;   seg loop below only tracks the pointer)
        asl @
        asl @
        asl @                        ; *8 = SEG_SIZE
;       clc
        adc #MAP_SEGS
        sta zp_sptr
?sloop	jsr process_seg.ps_w16	; 16-bit on both ways in: past process_seg's rep #$20
	rep #$21		;absorb CLC
	.LONGA ON
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        inc rs_segi                  ; the seg index walks with the pointer
	dec zp_segcnt
	bne ?sloop
?done	sep #$20
	.LONGA OFF
	rts
.endp
        .endseg

;--------------------------------------------------------------
; locate_floor -- floor height of the sector containing (zp_px, zp_py).
;   Clobbers zp_nid, zp_nodeptr, zp_ptr, zp_sptr, m_*, cx_*, A/X/Y.
;--------------------------------------------------------------
lf_resume = *
        org LOCFLOOR_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc locate_floor
                                      ; 2026-09-26: the whole descent in 16-bit A, one
        rep #$20                     ;   node_side per node (calc_nodeptr + point_on_side
        .LONGA ON                    ;   fused, Y = the child's offset); the child word's
        lda MAP_HROOT                ;   N is the leaf test, A the next node -- no reload
        sta zp_nid                   ; root node index (map header, per level)
?walk   bmi ?leaf
        jsr node_side
        lda [zp_nodeptr],y
        sta zp_nid
        bra ?walk
?leaf   ; ssid = zp_nid & $7FFF ; zp_ptr = MAP_SSECT + ssid*4 (A = zp_nid, 16-bit)
        asl @                        ; ssid*4 -- NO and #$7FFF: the two shifts
        asl @                        ;   push the leaf bit out (drac030)
;       clc
        adc #MAP_SSECT
        sta zp_ptr
	lda [zp_ptr]
        asl @                         ;   accumulator -- the m_a staging, the
        asl @                         ;   jsr m_x8 and the byte-halved adds are
        asl @                         ;   gone (drac030's fused form)
;       clc
        adc #MAP_SEGS
        sta zp_sptr

        ldy #SEG_FRONT                ; front_sec (u8) @ seg+4 (@5 rides the
        lda [zp_sptr],y               ;   16-bit load, the mask drops it)
        and #$FF
        asl @
        asl @
        asl @                         ; front_sec*8
;       clc
        adc #MAP_SECTORS
        sta zp_ptr
        lda (zp_ptr)
        sta loc_floor
        .LONGA OFF
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        rts
.endp
        .endseg
    .if * > LOCFLOOR_END+1
        ert 'locate_floor outgrew LOCFLOOR_BASE..END (memory_map.inc)'
    .endif
        org lf_resume

;--------------------------------------------------------------
; update_pz -- floor-follow: zp_pz = floor(zp_px,zp_py) + EYE(41). Makes the
;   eye height track the sector floor, so stairs/steps raise & lower the view
;   (spec: gui.py pz = m.eye_height()). Call each frame after the move.
;--------------------------------------------------------------
upz_resume = *
        org UPDPZ_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_pz
        jsr pl_zfloor                 ; locate_floor, then P_ZMovement (gravity,
                                      ;   the fall, the landing) and zp_pz =
                                      ;   pl_z + pl_vh.
        jsr wi_tick                   ; locate_floor left zp_ptr on the sector the
                                      ;   player stands in -- that IS the nukage
                                      ;   test, so it has to run HERE.
        jsr update_door30             ; and the 16/76 reopen countdown rides
        jsr wp_think                  ;   along, then the weapon psprites (they
                                      ;   only need to be after move_player and ...
        jmp update_scroll             ;   and finally the scrolling wall (48)
.endp                                 ;   (see the note in bsp_main's frame loop)
        .endseg
    .if * > UPDPZ_END+1
        ert 'update_pz outgrew UPDPZ_BASE..UPDPZ_END (memory_map.inc)'
    .endif
        org upz_resume

;==============================================================
; The collision code is RELOCATED out of the tight $2000..$3FFF segment (which
; butts against the streamed map at $4000) into the free RAM the boot loader
; leaves behind ($0900..$0FFF; see memory_map.inc). We save the $2000-segment PC,
; org to $0900 for the collision block, then org back so the renderer's remaining
; code (load_vertex..) keeps packing the $2000 segment. Keeps RAM tidy.
;==============================================================
coll_seg_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        icl 'collision.asm'
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org coll_seg_resume          ; back to the $2000 engine-code segment

seg_resume = *
        org USERAY_BASE              ; USE-ray geometry (try_use's helpers). Cold:
        icl 'use_ray.asm'            ; it only runs on a USE keypress, and its only
    .if * > USERAY_END               ; caller (use_leaf in doors.asm) is under the
        ert 'use_ray.asm outgrew its under-ROM slot -- see memory_map.inc'
    .endif                           ; ROM already, so the whole USE path banks
        org seg_resume               ; in and out exactly once
        icl 'seg_draw.asm'           ; per-seg drawing: process_seg + its helpers
        icl 'midtex.asm'             ; the two-sided MIDDLE texture (see-through
                                     ;   struts/fences): the deferred second pass
                                     ;   process_seg's three rs_mpass tests serve
