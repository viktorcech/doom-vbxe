;--------------------------------------------------------------
; RAM BUDGET: 0 B free, biggest contiguous block 0 B.
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
; renderer.asm -- M2b: BSP front-to-back walk + per-column occlusion.
;   Walks the prebuilt BSP from the player, near child first, so segs
;   arrive front-to-back; solid_arr[] marks filled columns so only the
;   NEAREST wall paints each column. Backface-culled. Still full-height
;   (real wall heights = M2c).
;==============================================================



ZNEAR     equ 4

;--------------------------------------------------------------
; frame_setup -- load sin/cos for zp_ang.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; walk_init -- rs_mpass = 0, then on into the frame entry it displaced.
;   rs_mpass lives at $131A, INSIDE the $1000-$14FF window every overlay runs
;   in, and the automap's own code puts $AD there (`lda am_dx+1`). Nothing
;   clears it while the map is up -- render_world does not run at all then --
;   so the FIRST walk after the map closes reads a non-zero masked-pass flag and
;   takes midtex.asm's replay branches for every seg: mtx_occ re-opens each
;   seg's columns from mseg_prime, so the "every column solid -> drop the seg"
;   cull never fires, and am_mark marks nearly everything the walk reaches. One
;   TAB open+close was measured at +50 linedefs on E1M1's spawn (29 -> 79), and
;   it repeats on every level and every overlay whose byte at $131A is not zero.
;   mseg_draw's early-out DOES zero it, but at the END of that same
;   render_world -- one frame after the damage.
;   Parked out here because render_world's segment ends one byte below
;   load_dtab: `jsr ptc_frame` is RETARGETED to this instead of a jsr being
;   added, so that segment does not grow by a byte (the same trick automap.asm
;   uses for its four gates).
;--------------------------------------------------------------
wki_resume = *
        org WALKINIT_BASE
.proc walk_init
        lda #0
        sta rs_mpass
    .if TEX_RUNS
        jmp ptc_frame                ; the call this routine displaced
    .else
        jmp spr_reset
    .endif
.endp
    .if * > WALKINIT_END+1
        ert 'walk_init outgrew WALKINIT_BASE..END (memory_map.inc)'
    .endif
        org wki_resume

;--------------------------------------------------------------
; render_world -- clear occlusion, walk the BSP from the root.
;--------------------------------------------------------------
.proc render_world
        ; Only the VIEW WINDOW is re-opened (viewsize.asm): outside it every
        ; column stays solid from vw_apply, which is what makes a smaller window
        ; cheaper -- the walk, the column loops, bg_fill and the sprite clip
        ; snapshots all skip a solid column for free.
        ldx vw_x0
?cl     lda #0
        sta solid_arr,x
        lda vw_y0
        sta ytopc_arr,x              ; open window top
        lda vw_y1
        sta ybotc_arr,x              ; open window bottom (status bar starts below)
        inx
        cpx vw_xend
        bne ?cl
        lda vw_ncol                  ; early-out: columns still open
        sta cols_open
        lda #0
        sta frame_done
        lda #0                       ; iterative-walk stack empty
        sta bsp_sp
        sta ms_n                     ; ... and no deferred struts yet (midtex.asm;
                                     ;   the clip pool they share with the
                                     ;   sprites is reset by spr_reset, and
                                     ;   rs_mpass by mseg_draw's own early-out
                                     ;   -- this segment ends ONE byte below
                                     ;   load_dtab, so neither could go here)
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
    .if TEX_RUNS
        jsr walk_init                ; rs_mpass = 0 (the overlay window wrote
                                     ;   over it), then ptc_frame: zback stamp +
                                     ;   chain builder reset; it tail-calls
                                     ;   spr_reset itself
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
                                     ; DOOM interleaves the two instead:
                                     ;   R_DrawSprite scans the drawsegs and, the
                                     ;   moment one is BEHIND the sprite it is
                                     ;   about to draw, renders that masked range
                                     ;   there and then (r_things.c:891) and
                                     ;   marks the columns done
                                     ;   (maskedtexturecol[x] = MAXSHORT), so its
                                     ;   final sweep only picks up what no sprite
                                     ;   ever covered. That is per SPRITE and per
                                     ;   COLUMN; matching it needs a depth key
                                     ;   per masked seg and a merge of the two
                                     ;   back-to-front walks, and the 6502 map
                                     ;   has no bytes left for it. Of the two
                                     ;   flat orders this is the right one: the
                                     ;   struts stand ON the walls of the room
                                     ;   the player is in, so nearly everything
                                     ;   that shares the screen with them --
                                     ;   lamps, barrels, corpses -- is in FRONT
                                     ;   (l1.png/l2.png: a candelabra swallowed
                                     ;   by the braces). midtex.asm
.endp

;--------------------------------------------------------------
; calc_nodeptr -- zp_nodeptr = MAP_NODES + (zp_nid & $7FFF)*NODE_SIZE
;--------------------------------------------------------------
.proc calc_nodeptr
        lda zp_nid
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4                     ; m_prod = nid*28 via shifts (= *32 - *4).
        lda m_prod
        sta m_ma
        lda m_prod+1
        sta m_ma+1                   ; m_ma = nid*4
        asl m_prod
        rol m_prod+1                 ; nid*8
        asl m_prod
        rol m_prod+1                 ; nid*16
        asl m_prod
        rol m_prod+1                 ; nid*32
        sec
        lda m_prod
        sbc m_ma
        sta m_prod
        lda m_prod+1
        sbc m_ma+1
        sta m_prod+1                 ; nid*28
        clc
        lda m_prod
        adc #<MAP_NODES              ; MAP_NODES = offset inside the EXT bank; the
        sta zp_nodeptr               ;   readers go [zp_nodeptr],y (long indirect)
        lda m_prod+1                 ;   with zp_nodeptr+2 = MAP_EXT_BANK, set ONCE
        adc #>MAP_NODES              ;   by init_level -- nothing else writes +2
        sta zp_nodeptr+1
        rts
.endp

;--------------------------------------------------------------
; point_on_side -- A = 0 (front/right) or 1 (back/left) for the player
;   vs the node partition. side0 iff (ndy*dxp - dyp*ndx) > 0.
;   node: x@0 y@2 dx@4 dy@6.
;--------------------------------------------------------------
.proc point_on_side
        sec                          ; dxp = px - node.x  -> cx_b
        ldy #0
        lda zp_px
        sbc [zp_nodeptr],y
        sta cx_b
        iny
        lda zp_px+1
        sbc [zp_nodeptr],y
        sta cx_b+1
        sec                          ; dyp = py - node.y  -> cx_c
        ldy #2
        lda zp_py
        sbc [zp_nodeptr],y
        sta cx_c
        iny
        lda zp_py+1
        sbc [zp_nodeptr],y
        sta cx_c+1
        ldy #6                       ; cx_a = node.dy
        lda [zp_nodeptr],y
        sta cx_a
        iny
        lda [zp_nodeptr],y
        sta cx_a+1
        ldy #4                       ; cx_d = node.dx
        lda [zp_nodeptr],y
        sta cx_d
        iny
        lda [zp_nodeptr],y
        sta cx_d+1
        ; --- tips #2: axis-aligned fast paths (74% of DOOM nodes -> no smul32) ---
        ;   cross = ndy*dxp - dyp*ndx ; side0 iff cross>0. For an axis node one
        ;   term is 0, so the sign is just a sign-bit XOR (verified bit-exact vs
        ;   cross_pos over 35200 cases). cross==0 -> side1 (matches cross_pos).
        lda cx_d                     ; node.dx == 0 ? -> vertical split: cross = ndy*dxp
        ora cx_d+1
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

;--------------------------------------------------------------
; render_node -- recursive BSP walk. zp_nid = node id (bit15=leaf).
;--------------------------------------------------------------
; tips #5: ITERATIVE walk with an explicit far-child stack (bsp_stack) instead of
; recursion -> no per-node jsr/rts, frees the CPU stack for deep maps. Same
; near-first (front-to-back) visit order as the old recursion -> identical render.
.proc render_node
?walk   lda frame_done               ; early-out: whole screen already solid
        beq ?live
        jmp ?done
?live   lda zp_nid+1
        and #$80
        beq ?node
        jmp ?leaf
?node
        jsr calc_nodeptr
        jsr point_on_side            ; A = side
        pha
        ldy #8                       ; zp_near = child_r
        lda [zp_nodeptr],y
        sta zp_near
        iny
        lda [zp_nodeptr],y
        sta zp_near+1
        ldy #10                      ; zp_far = child_l
        lda [zp_nodeptr],y
        sta zp_far
        iny
        lda [zp_nodeptr],y
        sta zp_far+1
        pla
        beq ?side0                   ; side0: near=R(bbox@12), far=L(bbox@20)
        lda zp_near                  ; side1: swap near/far + their bbox offsets
        ldx zp_far
        sta zp_far
        stx zp_near
        lda zp_near+1
        ldx zp_far+1
        sta zp_far+1
        stx zp_near+1
        lda #12                      ; near=child_l -> bbox@20, far=child_r -> bbox@12
        sta cb_fbb                   ;   (only the FAR offset is ever read: the near
        jmp ?have                    ;    child is always walked, so the cb_nbb this
?side0  lda #20                      ;    used to store beside it was written twice a
        sta cb_fbb                   ;    node and never read -- 10 B + ~8 cyc/node)
?have; R_CheckBBox on the FAR child only, exactly like DOOM's R_RenderBSPNode:
        ; the near side always gets walked, the far side is skipped when every
        ; screen column its bounding box covers is already solid. That throws
        ; away the whole subtree BEFORE one seg of it is transformed, and with
        ; textures off the per-seg work is 91 % of the frame. Measured x1.03
        ; (E1M8) to x2.38 (E1M3), with the painted image proven identical over
        ; every THING position in all 9 maps x 16 angles (E1M1 alone = 2208
        ; views) -- tools/_verify_bboxcull.py. That sweep used to be a 3x3 grid
        ; around the SPAWN only, i.e. the starting room; it was widened on
        ; 2026-07-31 while chasing a black gap seen mid-level.
        ; (The old "over-culls" warning predates the 2026-07-27 saturation fix
        ;  in screenx_signed: the span used to WRAP. Saturation only ever widens
        ;  a span, so it cannot cull something visible.)
        lda cb_fbb
        sta cb_off
        jsr check_bbox               ; A=1 -> subtree wholly invisible
        bne ?skipfar
        ldx bsp_sp                   ; push far child onto the walk stack
        lda zp_far
        sta bsp_stack,x
        lda zp_far+1
        sta bsp_stack+1,x
        inx
        inx
        stx bsp_sp
?skipfar
        lda zp_near                  ; descend near side first
        sta zp_nid
        lda zp_near+1
        sta zp_nid+1
        jmp ?walk
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
        jmp ?walk
?done   rts
.endp

;==============================================================
; The $1B00 block: code relocated out of the tight $2000 segment (spare RAM after
; the frac tables). Same org-redirect trick as the collision block: save the
; $2000 PC, org away, org back.
;   checkbbox.asm IS assembled again (2026-07-29): render_node calls it on every
;   far child. See the note at that call site for the measurements.
;   $1B00-$1F6F is the doors block, $1F70-$1FFF is seg_yoff (SEGYOFF_BASE).
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
                                     ;   its own org wrap (READKEYS_BASE), so it
                                     ;   adds NOTHING to the doors block above --
                                     ;   it sits here because try_use is its one
                                     ;   under-ROM callee, and it used to be the
                                     ;   tail of doors.asm for that same reason.
        org COLMERGE_BASE            ; the fast RAM doors.asm gave up
        icl 'colmerge.asm'           ; per-column run merging (drives the copy blit)
        org cb_resume                ; back to the $2000 engine-code segment


;==============================================================
; calc_u -- perspective-correct horizontal texture coordinate for the current
;   column. The two weights t1 = scaleR*(x-sxL) and t2 = scaleL*(sxR-x) are
;   linear in screen x (tracked in the column loop), and
;       u = L * t1 / (t1 + t2)
;   is the exact perspective mapping. Interpolating u itself linearly -- what
;   this renderer used to do -- is only correct for a wall parallel to the
;   screen; on an angled wall seen from close up it smears a single texel column
;   across half the wall (the "walls turn brown up close" artefact).
;   Relocated to $0610 (fast RAM on Rapidus, see memory_map.inc).
;==============================================================
cu_resume = *
        org CALCU_BASE
.proc calc_u
        stx cu_savex                 ; X is the column loop's index -- umul16/udiv24
        clc                          ; clobber it (this cost one pink screen)
                                     ; den = (t1 + t2) >> 8
        lda rs_t1+1
        adc rs_t2+1
        sta m_den
        lda rs_t1+2
        adc rs_t2+2
        sta m_den+1
        ora m_den
        bne ?ok
        inc m_den                    ; degenerate span: never divide by zero
?ok     lda #0                       ; num = (t1 >> 8) << 8
        sta m_prod
        lda rs_t1+1
        sta m_prod+1
        lda rs_t1+2
        sta m_prod+2
        jsr udiv24                   ; m_quot = 256 * t1/(t1+t2)  (Q8 ratio 0..256)
        lda rs_uflip
        beq ?nofl
        sec                          ; flipped seg: u runs L .. 0
        lda #0
        sbc m_quot
        sta m_quot
        lda #1
        sbc m_quot+1
        sta m_quot+1
?nofl   lda rs_seglen                ; u = (L * ratio) >> 8
        sta m_a
        lda rs_seglen+1
        sta m_a+1
        lda m_quot
        sta m_b
        lda m_quot+1
        sta m_b+1
        jsr umul16
        lda #0                       ; u = seg_offset + L*ratio. rs_segoff is
        sta rs_uacc                  ;   DOOM's seg->offset: how far along the
        clc                          ;   LINEDEF this seg starts, so a wall the
        lda m_prod+1                 ;   BSP cut in half keeps one continuous
        adc rs_segoff                ;   texture instead of restarting at 0 on
        sta rs_uacc+1                ;   each piece (9 % of E1's segs had a
        lda m_prod+2                 ;   visible seam). u is Q8, the offset is
        adc rs_segoff+1              ;   whole world units -> it lands in bytes
        sta rs_uacc+2                ;   1-2, same as the product.
        ldx cu_savex
        rts
.endp
        org cu_resume

;--------------------------------------------------------------
; render_subsector -- draw all segs of subsector (zp_nid & $7FFF).
;--------------------------------------------------------------
.proc render_subsector
        jsr spr_add                  ; things first, then the segs (R_Subsector order)
        lda zp_nid                   ; ssptr = MAP_SSECT + ssid*4
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4                     ; m_prod = ssid*4 via shifts (tips #3)
        clc
        lda m_prod
        adc #<MAP_SSECT
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SSECT
        sta zp_ptr+1
        ldy #0                       ; first seg index -> m_a (and rs_segi: seg_yoff
        lda [zp_ptr],y               ;   keys MAP_YBITS by seg INDEX, and the seg
        sta m_a                      ;   loop below only tracks the pointer)
        sta rs_segi
        iny
        lda [zp_ptr],y
        sta m_a+1
        sta rs_segi+1
        ldy #2                       ; count -> zp_segcnt
        lda [zp_ptr],y
        sta zp_segcnt
        iny
        lda [zp_ptr],y
        sta zp_segcnt+1
        jsr m_x8                     ; m_prod = first*8 via shifts (SEG_SIZE; tips #3)
        clc
        lda m_prod
        adc #<MAP_SEGS
        sta zp_sptr
        lda m_prod+1
        adc #>MAP_SEGS
        sta zp_sptr+1
?sloop
        lda zp_segcnt
        ora zp_segcnt+1
        beq ?done
        jsr process_seg
        clc
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        lda zp_sptr+1
        adc #0
        sta zp_sptr+1
        inc rs_segi                  ; the seg index walks with the pointer
        bne ?nohi
        inc rs_segi+1
?nohi   lda zp_segcnt
        bne ?declo
        dec zp_segcnt+1
?declo  dec zp_segcnt
        jmp ?sloop
?done   rts
.endp

;--------------------------------------------------------------
; locate_floor -- floor height of the sector containing (zp_px, zp_py).
;   BSP descent from MAP_ROOT taking the side the point is on (reuses
;   calc_nodeptr + point_on_side, which read zp_px/zp_py). At the leaf
;   subsector, reads its first seg's front_sec -> sector floor_h (i16) into
;   loc_floor. This is the spec's m.eye_height() point-location, minus the +EYE.
;   Clobbers zp_nid, zp_nodeptr, zp_ptr, zp_sptr, m_*, cx_*, A/X/Y.
;--------------------------------------------------------------
lf_resume = *
        org LOCFLOOR_BASE
.proc locate_floor
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
?walk   lda zp_nid+1
        and #$80
        bne ?leaf
        jsr calc_nodeptr             ; zp_nodeptr = node record
        jsr point_on_side            ; A=0 -> side0 (child_r), A=1 -> side1 (child_l)
        bne ?left
        ldy #8                       ; side0 -> child_r @ node+8
        bne ?desc
?left   ldy #10                      ; side1 -> child_l @ node+10
?desc   lda [zp_nodeptr],y
        sta zp_nid
        iny
        lda [zp_nodeptr],y
        sta zp_nid+1
        jmp ?walk
?leaf   ; ssid = zp_nid & $7FFF ; zp_ptr = MAP_SSECT + ssid*4
        lda zp_nid
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4                     ; ssid*4
        clc
        lda m_prod
        adc #<MAP_SSECT
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SSECT
        sta zp_ptr+1
        ldy #0                        ; first seg index @ ssect+0
        lda [zp_ptr],y
        sta m_a
        iny
        lda [zp_ptr],y
        sta m_a+1
        jsr m_x8                     ; zp_sptr = MAP_SEGS + first*SEG_SIZE (=*8)
        clc
        lda m_prod
        adc #<MAP_SEGS
        sta zp_sptr
        lda m_prod+1
        adc #>MAP_SEGS
        sta zp_sptr+1
        ldy #SEG_FRONT                ; front_sec (u8) @ seg+4
        lda [zp_sptr],y
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod                    ; zp_ptr = MAP_SECTORS + front_sec*8
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1                  ; front_sec*8
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        ldy #0                        ; floor_h (i16) @ sector+0
        lda (zp_ptr),y
        sta loc_floor
        iny
        lda (zp_ptr),y
        sta loc_floor+1
        rts
.endp
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
.proc update_pz
        jsr pl_zfloor                 ; locate_floor, then P_ZMovement (gravity,
                                      ;   the fall, the landing) and zp_pz =
                                      ;   pl_z + pl_vh. All of it lives in the
                                      ;   FALL block (bsp_main.asm): this one is
                                      ;   32 bytes, not the 48 UPDPZ_END claims
                                      ;   -- USE_PT starts at $E740.
                                      ; locate_floor still leaves zp_ptr on the
                                      ;   player's sector, which is what
                                      ;   update_damage below reads.
        jsr wi_tick                   ; locate_floor left zp_ptr on the sector the
                                      ;   player stands in -- that IS the nukage
                                      ;   test, so it has to run HERE.
                                      ; wi_tick is update_damage with two things
                                      ;   in front of it: the level clock and
                                      ;   P_PlayerInSpecialSector's `case 9`
                                      ;   (wi.asm). It tail-chains into
                                      ;   update_damage, so this call is the same
                                      ;   three bytes it always was -- which is
                                      ;   the only reason it fits.
        jsr update_door30             ; and the 16/76 reopen countdown rides
        jsr wp_think                  ;   along, then the weapon psprites (they
                                      ;   only need to be after move_player and
                                      ;   before snd_dispatch, and the $2000
                                      ;   segment has no room for the jsr)
        jmp update_scroll             ;   and finally the scrolling wall (48)
.endp                                 ;   (see the note in bsp_main's frame loop)
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
        org COLLISION_BASE
        icl 'collision.asm'
    .if * > COLLISION_END
        ert 'collision.asm outgrew the old TWRUNS slot at $AAF0 -- see memory_map.inc'
    .endif
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
