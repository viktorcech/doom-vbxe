;==============================================================
; sprites.asm -- DOOM THINGS (items, decorations, monsters) as billboards.
;--------------------------------------------------------------
; Spec + verification: docs/THINGS.md, tools/render_tex.py (the Python renderer
; this ports) and tools/_verify_things.py. Data comes from tools/pack_things.py:
;   {map}.spr     rectangular column-major sprite pixels -> VBXE VRAM $071000+.
;                 A transparent texel is palette index 0 and BLT_BSTENCIL skips
;                 it, so no post/mask tables are needed (same trick as w3d).
;   {map}.things  RAM blob at THINGS_BASE ($B000): per-subsector prefix table,
;                 the things, the sprite table, and PLAYPAL.
;
; CLIPPING -- why this needs no drawsegs: the BSP walk is strictly front-to-back
; and the occlusion arrays are add-only, so when a subsector is reached,
; solid_arr/ytopc_arr/ybotc_arr describe exactly what the NEARER geometry left
; open. spr_add snapshots that window over the sprite's columns; spr_draw runs
; after the whole walk, back-to-front, and clips to the snapshot. Nearer walls
; (already painted) cut the sprite; farther walls (painted after its subsector
; was visited) are covered by it.
;
; VERTICAL SCALE -- SRC_STEPY is an integer, so a raw column can only be sampled
; at 1, 2, 3.. texels per row: a sprite would snap between 1x/2x/4x instead of
; growing smoothly. Same problem the wall texturing has, same fix: blow the
; column up S times vertically into VRAM_TEX8 (tw_expand, one blit) and sample
; that with SRC_STEPY = round(S*256/scale), which makes the ladder S times finer.
; S is picked per sprite as the largest power of two with S*h <= 1 KB (scratch),
; and skipped entirely for sprites minified 4x or more (nothing to gain).
;==============================================================

;--------------------------------------------------------------
; spr_reset -- per frame (render_world): no vissprites, clip pool empty.
;--------------------------------------------------------------
; give_bonus + its tables sit in the $0600 hole next to calc_u: fast RAM on a
; Rapidus and out of this block, which is up against the wall-blit code.
gb_resume = *
;   give_bonus MOVED to the DROP block (enemy_ai.asm) 2026-07-31: the MF_DROPPED
;   halving grew it 12 B and the $0600 hole it shared with calc_u had none. Its
;   TABLES stay here -- they are absolute-indexed, so where the code sits does
;   not matter to them.
        org BNTAB_BASE
; bonus id -> (counter index | 8 = bit set, amount | bit, cap). Index 0 is unused.
;        --  1 stim  2 medi  3 hbon  4 soul  5 abon  6 grn   7 blue
BN_STAT dta 0, PS_HEALTH, PS_HEALTH, PS_HEALTH, PS_HEALTH, PS_ARMOR, PS_ARMOR, PS_ARMOR
;        --  8 clip  9 box   10 shel 11 sbox 12 rckt 13 rbox 14 cell 15 cpack
        dta PS_BULLETS, PS_BULLETS, PS_SHELLS, PS_SHELLS, PS_ROCKETS, PS_ROCKETS, PS_CELLS, PS_CELLS
;        -- 16..21 weapons, 22..24 keys (bit sets)
        dta 8,8,8,8,8,8, 8,8,8
;        -- 25 bpack 26 blur 27 suit 28 map 29 visor 30 invul 31 berserk
        dta 9,9,9,9,9,9,9            ; 9 = a POWER: give_bonus hands it to pw_give
;        -- 32..34 SKULL keys (2026-08-31): the E2/E3 skulls got ids of their
;        own so the message says "skull key" (pack_things/pack_menu); the BITS
;        are the cards' own 1/2/4, so give_bonus's key branch (cpy #22 / bcs)
;        and every PS_KEYS reader work unchanged.
        dta 8,8,8
BN_AMT  dta 0, 10, 25, 1, 100, 1, 100, 200
        dta 10, 50, 4, 20, 1, 5, 20, 100
; 16..21 weapons: the bit is 1<<wp_*, so PS_WEAPONS IS DOOM's weapon bitfield
; and weapon.asm can test `wp_bit[wp] & PSTATE[PS_WEAPONS]` (2026-07-30 -- these
; used to be 1,2,4.. starting at the shotgun, which collided with the "pistol"
; bit the player spawns with). 22..24 keys, unchanged.
        dta 4, 8, 16, 32, 64, 128,  1, 2, 4
        dta 0,0,0,0,0,0,0            ; the powers carry no amount: pw_give knows
        dta 1, 2, 4                  ; 32..34 skulls: the SAME key bits as 22..24
BN_MAX  dta 0, 100, 100, 200, 200, 200, 100, 200
        dta 200, 200, 50, 50, 50, 50, 255, 255
        dta 0,0,0,0,0,0, 0,0,0
        dta 0,0,0,0,0,0,0            ; ...and no cap either
        dta 0,0,0                    ; 32..34 skulls: bits, no cap
    .if * > BNTAB_END+1
        ert 'the BN_* tables outgrew BNTAB_BASE..END (memory_map.inc)'
    .endif
        org gb_resume

;--------------------------------------------------------------
; thing_alive_bit / thing_kill -- the THING_ALIVE bitmap accessors, parked in
; the fast $0D30/$0E78 holes (memory_map.inc): the $B000 segment is packed to
; the byte, adding them inline pushed it into the textures.asm org at $B7C1.
;--------------------------------------------------------------
ta_resume = *
        org THALIVE_BASE
;--------------------------------------------------------------
; thing_alive_bit -- X = thing index -> A = its ALIVE bit (0 = taken).
;   1 bit per thing (256 things / 32 B, mv_bit masks): the old byte-per-thing
;   table only covered 128, and idx >= 128 read PSTATE / the $1000 render
;   scratch instead -- E1M3 sprites vanished as the view changed and pickups
;   never stuck. Clobbers X,Y; callers reload the index from sp_i.
;--------------------------------------------------------------
.proc thing_alive_bit
        txa
        and #7
        tay
        txa
        lsr
        lsr
        lsr
        tax
        lda THING_ALIVE,x
        and mv_bit,y
        rts
.endp
    .if * > THALIVE_END+1
        ert 'thing_alive_bit outgrew the $0E78 hole -- see memory_map.inc'
    .endif

        org THKILL_BASE
.proc thing_kill                     ; X = thing index -> clear its ALIVE bit
        txa
        and #7
        tay
        txa
        lsr
        lsr
        lsr
        tax
        lda mv_bit,y
        eor #$FF
        and THING_ALIVE,x
        sta THING_ALIVE,x
        rts
.endp
    .if * > THKILL_END+1
        ert 'thing_kill outgrew the $0D30 hole -- see memory_map.inc'
    .endif
        org ta_resume

;--------------------------------------------------------------
sr_resume = *
        org SPRRESET_BASE            ; moved out of the $B000 segment 2026-07-31:
.proc spr_reset                      ;   spr_add's two chase hooks pushed that
        lda #0                       ;   segment into en_boom at $B715, and this
        sta sp_n                     ;   is the cheapest whole proc to lift out
        lda #<CLIP_BASE              ;   (once per frame, one absolute jsr).
        sta sp_clip
        lda #>CLIP_BASE
        sta sp_clip+1
        rts
.endp
    .if * > SPRRESET_END+1
        ert 'spr_reset outgrew SPRRESET_BASE..END (memory_map.inc)'
    .endif
        org sr_resume

;--------------------------------------------------------------
; spr_add -- collect the things of subsector (zp_nid & $7FFF). Called by
;   render_subsector BEFORE its segs, mirroring DOOM's R_Subsector order
;   (R_AddSprites first, then R_AddLine). Things are sorted by subsector, so the
;   prefix table gives the range [prefix[s], prefix[s+1]).
;--------------------------------------------------------------
.proc spr_add
        jsr spr_chased               ; a CHASING monster is drawn from the
                                     ;   subsector it walked to, not the one it
                                     ;   was packed into (enemy_ai.asm) -- and
                                     ;   the imp's fireball + the player's
                                     ;   missile ride the same hook (proj.asm
                                     ;   wraps ball.asm's spr_chaseb wrapper).
                                     ; It runs BEFORE the table-full test now:
                                     ;   the scenery of a subsector must never
                                     ;   take the slot a MISSILE the player just
                                     ;   fired needs. That is what made the
                                     ;   rocket vanish with no pattern -- the
                                     ;   room's items filled all 40 slots first
                                     ;   in some views and not in others.
        lda sp_n                     ; vissprite table full? (front-to-back, so
        cmp #VIS_MAX-2               ; the ones already collected are the
        bcs ?ret                     ; nearest). Two short: the ball and the
                                     ; missile keep a slot each.
        clc                          ; prefix entry = th_ss + ssid
        lda zp_nid
        adc th_ss
        sta sp_ptr
        lda zp_nid+1
        and #$7F
        adc th_ss+1
        sta sp_ptr+1
        ldy #0
        lda (sp_ptr),y               ; first thing of this subsector
        sta sp_i
        iny
        lda (sp_ptr),y               ; first thing of the next one
        sta sp_last
        cmp sp_i
        bne ?loop
?ret    rts
?loop   ldx sp_i                     ; already picked up -> do not draw it
        jsr thing_alive_bit
        bne ?live
        jmp ?skip
?live   lda sp_i                     ; spr_chase already drew it, from where it
        jsr ai_ischase               ;   actually stands
        bne ?skip
        lda sp_i                     ; thing record = th_things + i*8
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc th_things
        sta sp_ptr
        lda m_prod+1
        adc th_things+1
        sta sp_ptr+1
        jsr spr_proj
?skip   inc sp_i
        lda sp_n
        cmp #VIS_MAX-2               ; ...the same two reserved slots
        bcs ?ret
        lda sp_i
        cmp sp_last
        bne ?loop
        rts
.endp

;--------------------------------------------------------------
; spr_proj -- project the thing at (sp_ptr) and, if visible, append a vissprite
;   plus a snapshot of the open window over its columns.
;   Thing record: i16 x, i16 y, i16 z (anchor = sector floor), u8 sprite id.
;--------------------------------------------------------------
; 16-BIT (2026-08-29): the thing's position, both differences, the Z test and
; the scale are 16-bit quantities. `lda (sp_ptr),y` reads a whole coordinate in
; one go, so the `iny` between the halves goes with them; transform/scale_z are
; 8-bit code. M only -- X/Y stay 8-bit (sound.asm:316).
.proc spr_proj
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        ldy #0                       ; rx = x - px, ry = y - py
        sec
        lda (sp_ptr),y
        sbc zp_px
        sta zp_rx
        ldy #2
        sec
        lda (sp_ptr),y
        sbc zp_py
        sta zp_ry
        .LONGA OFF
        sep #$20
        jsr transform                ; -> zp_X, zp_Z (view space)
        rep #$20
        .LONGA ON
        lda zp_Z                     ; too close / behind the eye?
        bmi ?skip16
        cmp #SPR_MINZ                ; (unsigned 16-bit: Z >= 256 passes it too)
        bcs ?zok
?skip16 .LONGA OFF
        sep #$20
?skip   rts
?zok    .LONGA OFF
        sep #$20
        jsr scale_z                  ; m_quot = VFOCAL*256/Z (Q8, vertical)
        rep #$20
        .LONGA ON
        lda m_quot
        sta sp_scale
        lsr                          ; horizontal scale = vertical/2 (FOCAL 80:160)
        sta sp_hs
        cmp #SPR_HSMIN               ; too far to be worth a vissprite
        .LONGA OFF
        sep #$20
        bcc ?skip
?wide   ldy #$FF                     ; $FF = COMPUTE the rotation (zp_rx/ry are
        sty sp_dfix                  ;   fresh here); spr_one replays instead
        lda sp_i                     ; dying? then the frame comes from the death
        jsr spr_dyn                  ;   table, already in sp_tab (enemy.asm)
        ; --- 16-BIT A for the table-entry math and the header copy
        ;     (2026-08-31, the drac030 hand-review): id*8 was an 8-bit
        ;     shift ladder through m_prod and the header four lda/sta pairs --
        ;     ~100 cycles a sprite; this is ~63. sp_w/sp_h/sp_left/sp_top are
        ;     CONTIGUOUS in record order (memory_map.inc), so two 16-bit moves
        ;     copy all four; @7 rides into the id load and `and #$FF` drops it.
        bcc ?comp
        rep #$20                     ; dying: spr_dyn already set sp_tab
        .LONGA ON
        bra ?have
        .LONGA OFF
?comp   ldy #6                       ; sprite table entry = th_sprtab + id*8
        rep #$20
        .LONGA ON
        lda (sp_ptr),y
        and #$FF
        asl @
        asl @
        asl @
        clc
        adc th_sprtab
        sta sp_tab
?have   ldy #3
        lda (sp_tab),y               ; w @3, h @4
        sta sp_w
        ldy #5
        lda (sp_tab),y               ; left @5, top @6
        sta sp_left
        .LONGA OFF
        sep #$20
        jsr screenx_signed           ; m_xs = centre column (unclamped, signed)
        ldx #0                       ; x1 = centre - (leftoffset*hs)>>8
        lda sp_left
        sta m_a
        bpl ?lp2
        dex                          ; sign-extend the signed offset
?lp2    stx m_a+1
        lda sp_hs
        sta m_b
        lda sp_hs+1
        sta m_b+1
        jsr smul32
        sec
        lda m_xs
        sbc m_prod+1
        sta sp_x1
        lda m_xs+1
        sbc m_prod+2
        sta sp_x1+1
        lda sp_w                     ; on-screen width = (w*hs)>>8
        sta m_a
        lda #0
        sta m_a+1
        lda sp_hs
        sta m_b
        lda sp_hs+1
        sta m_b+1
        jsr umul16
        lda m_prod+1
        sta m_a
        lda m_prod+2
        sta m_a+1
        ora m_a
        bne ?w1ok                    ; sub-column: DOOM has no far cull at all --
        inc m_a                      ;   R_ProjectSprite draws a distant barrel as
                                     ;   a SLIVER, and P_LineAttack reaches it out
                                     ;   to MISSILERANGE (2048). Dropping it here
                                     ;   made it both invisible and unshootable
                                     ;   past 1664 units (tools/_dbg_shotrange.py),
                                     ;   so a thing that projects to less than a
                                     ;   column gets exactly one. SPR_HSMIN still
                                     ;   ends the sprite at Z 2560, past DOOM's
                                     ;   bullet range.
?w1ok   clc                          ; xb = x1 + width - 1
        lda sp_x1
        adc m_a
        sta m_b
        lda sp_x1+1
        adc m_a+1
        sta m_b+1
        sec
        lda m_b
        sbc #1
        sta m_b
        lda m_b+1
        sbc #0
        sta m_b+1
        bmi ?skip2                   ; entirely off the left edge
        bne ?xbclamp                 ; >= 256 -> clamp to the right edge
        lda m_b
        cmp #SCREEN_WIDTH
        bcc ?xbok
?xbclamp lda #SCREEN_WIDTH-1
?xbok   sta sp_xb
        lda sp_x1+1                  ; xa = max(x1, 0); x1 >= 160 -> off the right
        bmi ?xazero
        beq ?xalow
?skip2  rts
?xalow  lda sp_x1
        cmp #SCREEN_WIDTH
        bcs ?skip2
        sta sp_xa
        jmp ?xaok
?xazero lda #0
        sta sp_xa
?xaok   lda sp_xb
        cmp sp_xa
        bcc ?skip2
        lda sp_h                     ; on-screen height = (h*scale)>>8
        sta m_a
        lda #0
        sta m_a+1
        lda sp_scale
        sta m_b
        lda sp_scale+1
        sta m_b+1
        jsr umul16
        lda m_prod+1
        sta sp_rows
        lda m_prod+2
        sta sp_rows+1
        ora sp_rows
        beq ?skip2
        ldy #4                       ; world height of the sprite's top row
        lda (sp_ptr),y               ;   = thing z + topoffset, relative to the eye
        sta m_a
        iny
        lda (sp_ptr),y
        sta m_a+1
        clc
        lda m_a
        adc sp_top
        sta m_a
        lda m_a+1
        adc #0
        sta m_a+1
        sec
        lda m_a
        sbc zp_pz
        sta m_a
        lda m_a+1
        sbc zp_pz+1
        sta m_a+1
        lda sp_scale
        sta m_b
        lda sp_scale+1
        sta m_b+1
        jsr track_calc               ; m_prod[0..2] = horizon - world*scale (Q8)
        lda m_prod+1                 ; screen row of texture row 0
        sta sp_ytop
        lda m_prod+2
        sta sp_ytop+1
        bmi ?vis                     ; above the horizon -> definitely not below screen
        beq ?vchk                    ; row >= 256 -> below the screen
?bail   jmp ?skip2                   ; (trampoline: ?skip2 is out of branch range)
?vchk   lda sp_ytop
        cmp #SCREEN_HEIGHT
        bcs ?bail
?vis    clc                          ; bottom row = ytop + rows - 1
        lda sp_ytop
        adc sp_rows
        sta sp_ybot
        lda sp_ytop+1
        adc sp_rows+1
        sta sp_ybot+1
        sec
        lda sp_ybot
        sbc #1
        sta sp_ybot
        lda sp_ybot+1
        sbc #0
        sta sp_ybot+1
        bmi ?bail                    ; entirely above the screen
        ; --- snapshot the open window over [xa..xb] into the clip pool ---
        lda sp_xb
        sec
        sbc sp_xa
        sta sp_cnt                   ; columns - 1
?csize  lda #0                       ; bytes needed = 2*(cnt+1)
        sta m_a+1
        lda sp_cnt
        sta m_a
        inc m_a
        bne ?n1
        inc m_a+1
?n1     asl m_a
        rol m_a+1
        clc
        lda sp_clip
        adc m_a
        lda sp_clip+1
        adc m_a+1
        cmp #>CLIP_END
        bcc ?cfit
        ; --- POOL TOO TIGHT. Dropping the sprite here was a real bug and not
        ;     just a cosmetic one: en_shoot aims at the VISSPRITE list, so a
        ;     monster that lost its slot was invisible AND unkillable, and the
        ;     more of them were on screen the more often it happened ("some
        ;     enemies don't die", "corpses disappear", 2026-07-31).
        ;     A per-column block is 2*(columns+1) bytes and a near sprite can
        ;     want 80+ of the 256 the page holds, so three of them exhaust it.
        ;     Collapse to ONE window over the whole sprite instead -- 2 bytes,
        ;     the same shape the uniform case already produces, and the only
        ;     cost is that a sprite straddling two different windows is clipped
        ;     by its leftmost column's. Far better than not existing.
        lda sp_cnt
        beq ?bail                    ; already one window: the page really is full
        lda #0
        sta sp_cnt
        jmp ?csize
?cfit   lda sp_clip                  ; block base (the pool is one page: hi = $07)
        sta sp_cbase
        lda #1                       ; assume one window covers every column
        sta sp_uni
        ldx sp_xa
?snap   lda solid_arr,x
        bne ?closed
        lda ytopc_arr,x
        cmp ybotc_arr,x
        beq ?open
        bcs ?closed                  ; top > bot -> nothing open in this column
?open   ldy #0
        sta (sp_clip),y              ; window top (A = ytopc)
        iny
        lda ybotc_arr,x
        sta (sp_clip),y              ; window bottom
        jmp ?sadv
?closed ldy #0
        lda #255                     ; 255 = fully covered by nearer geometry
        sta (sp_clip),y
        iny
        sta (sp_clip),y
        ; --- uniform test: 90% of sprites see ONE window over all their columns
        ;     (measured, tools/_dbg_sprcap.py). Those keep just the first pair and
        ;     spr_one re-reads it with a step of 0 -- that is what keeps the pool
        ;     inside a single page at VIS_MAX 40.
?sadv   lda sp_clip                  ; first column? -> remember its window
        cmp sp_cbase
        bne ?ucmp
        ldy #0
        lda (sp_clip),y
        sta sp_t0
        iny
        lda (sp_clip),y
        sta sp_b0
        jmp ?s2
?ucmp   ldy #0
        lda (sp_clip),y
        cmp sp_t0
        bne ?unot
        iny
        lda (sp_clip),y
        cmp sp_b0
        beq ?s2
?unot   lda #0
        sta sp_uni
?s2     clc
        lda sp_clip
        adc #2
        sta sp_clip
        bcc ?s3
        inc sp_clip+1
?s3     inx
        dec sp_cnt
        bpl ?snap
        lda sp_uni
        beq ?keep                    ; per-column windows: keep the whole block
        lda sp_t0
        cmp #255
        bne ?uni                     ; every column closed -> nothing to draw at
        lda sp_cbase                 ; all: hand the whole block back and drop it
        sta sp_clip                  ; (a hidden sprite must not eat a vissprite)
        jmp ?skip2
?uni    clc                          ; uniform: give the pool everything back but
        lda sp_cbase                 ; the one pair (hi stays $07 -- see CLIP_BASE)
        adc #2
        sta sp_clip
?keep
        ; --- append the vissprite (X = its number: the arrays are parallel) ---
        ldx sp_n
        lda sp_xb                    ; (xa is not stored: spr_one gets it from x1)
        sta vs_xb,x
        lda sp_x1
        sta vs_x1l,x
        lda sp_x1+1
        sta vs_x1h,x
        lda sp_ytop
        sta vs_ytl,x
        lda sp_ytop+1
        sta vs_yth,x
        lda sp_ybot+1                ; ...and the LAST row, clamped into one byte:
        beq ?ybl                     ;   en_seen needs the sprite's OWN vertical
        lda #255                     ;   extent to answer "is it visible in the
        bne ?ybs                     ;   centre column", and >= 256 reads as
?ybl    lda sp_ybot                  ;   "below the view" to every test it makes.
?ybs    sta vs_ybt,x                 ;   (ybot < 0 already bailed above.)
        lda sp_scale                 ; the scale doubles as the sort key: it falls
        sta vs_scl,x                 ; monotonically with Z, so ascending scale IS
        lda sp_scale+1               ; back-to-front
        sta vs_sch,x
        ldy #6                       ; sprite id (spr_one rebuilds the table pointer)
        lda (sp_ptr),y
        sta vs_sid,x
        lda sp_dflip                 ; the ROTATION spr_wrot chose at projection
        sta vs_flip,x                ;   (slot bits 0-1, bit7 = mirrored; 0 for
                                     ;   statics/death -- spr_dyn clears it).
                                     ;   spr_one replays it: zp_rx/ry are stale
                                     ;   by draw time, so it must NOT recompute
        lda sp_i                     ; and the THING index: the hitscan needs the
        sta vs_th,x                  ;   thing (its health), not the sprite
        lda sp_cbase                 ; clip block, low byte; bit 0 = uniform window
        ora sp_uni                   ; (blocks are 2 B aligned, so bit 0 is spare)
        sta vs_cpl,x
        ; --- slot it into the draw order, NEAREST first ----------------------
        ; The BSP walk hands sprites over front-to-back already, so this insertion
        ; usually stops at the first compare (~10 inversions per frame, measured).
        ; That is why there is no selection sort any more: at 40 sprites its 1600
        ; probes would cost more than the whole billboard pass.
?ins    cpx #0
        beq ?place
        ldy vs_ord-1,x               ; sprite one slot nearer than the hole
        lda vs_sch,y
        cmp sp_scale+1
        bcc ?shift                   ; it is FARTHER than the new one -> move it out
        bne ?place
        lda vs_scl,y
        cmp sp_scale
        bcs ?place
?shift  tya
        sta vs_ord,x
        dex
        jmp ?ins
?place  lda sp_n
        sta vs_ord,x
        inc sp_n
        rts
.endp

;--------------------------------------------------------------
; spr_pickup -- once per frame: take everything the player REACHED FOR. Modelled
;   on w3d/src/sprites.asm try_pickup + give_bonus: a thing flagged "pickup"
;   within PICKUP_R in both axes is offered to give_bonus, and only removed if
;   the bonus could actually be used -- a medikit at full health stays on the
;   floor, exactly like the original. Removal = THING_ALIVE[i] = 0, which also
;   stops spr_add from ever drawing it again. Called from the main loop after
;   move_player.
;
;   IT TESTS pk_x/pk_y, NOT zp_px/zp_py (2026-08-12, "niektore items ked su
;   vyssie, nedaju sa zobrat"). p_map.c hands items over inside
;   P_CheckPosition(thing, x, y) -- the PIT_CheckThing loop, against the
;   DESTINATION, and it is the first thing P_TryMove does. All three of
;   P_TryMove's refusals (doesn't fit / step > 24 / dropoff) come afterwards and
;   none of them undoes the pickup, so in DOOM a move that was REFUSED still
;   takes the item: you get what is on a ledge you cannot climb by walking INTO
;   the ledge, and what is behind a wall by walking into the wall. Testing where
;   the player ENDED UP made every such item unobtainable -- 118 of them across
;   episode 1, E1M2's green armour in its 32-high alcove at (0,976) among them,
;   which is the one that was reported. The alcove line is 40 units of opening
;   against PLAYER_H 56, so collide_blocked holds him 16 off it and the 24-unit
;   move grid leaves him 53 away from a 36-unit reach; the point he asked for is
;   16 away. Only ONE point is tested per frame, not the swept path: the port's
;   frame is one 24-unit step where DOOM ticks 3-4 smaller ones, and 24 is well
;   inside the 72-unit pickup box, so nothing slips through the gap.
;--------------------------------------------------------------
pk_resume = *
        org PICKUP_BASE              ; moved out of the $B000 segment -- see the
.proc spr_pickup                     ;   PICKUP_BASE note in memory_map.inc
        lda #0
        sta sp_i
?loop   lda sp_i                     ; done when i == n_things
        cmp THINGS_BASE
        bcc ?go
        rts
?go     ldx sp_i
        jsr thing_alive_bit
        bne ?have
?jnext  jmp ?next                    ; already taken (trampoline: ?next is far)
?have
        lda #0                       ; record = th_things + i*8, with the low half
        sta m_prod+1                 ;   kept in A the whole way (spr_take does the
        lda sp_i                     ;   same): it is the adc's operand already, so
        asl                          ;   the three shifts cost one byte each
        rol m_prod+1                 ;   instead of two and there is no store to
        asl                          ;   m_prod at all. -7 B, which is what pays
        rol m_prod+1                 ;   for pk_x/pk_y below -- this block ends
        asl                          ;   FLUSH at $FEAB and enemy.asm is org'd at
        rol m_prod+1                 ;   $FEAC (GUNFIRE_BASE).
        clc
        adc th_things
        sta sp_ptr
        lda m_prod+1
        adc th_things+1
        sta sp_ptr+1
        ldy #7                       ; bit0 = a map pickup, bit2 = a corpse that
        lda (sp_ptr),y               ;   P_KillMobj dropped ammo on (en_kill sets
        and #1|F_DROP                ;   it for the zombieman and the shotgun guy)
        beq ?jnext
        sta sp_pick                  ; remember WHICH -- the bonus id and the
        ldy #0                       ; |x - pk_x| < PICKUP_R ?  (pk_x/pk_y, NOT
        sec                          ;   zp_px/zp_py: the point move_player ASKED
        lda (sp_ptr),y               ;   for -- see the header and memory_map.inc)
        sbc pk_x
        sta m_a
        iny
        lda (sp_ptr),y
        sbc pk_x+1
        jsr ?near
        bcc ?jnext
        ldy #2                       ; |y - pk_y| < PICKUP_R ?
        sec
        lda (sp_ptr),y
        sbc pk_y
        sta m_a
        iny
        lda (sp_ptr),y
        sbc pk_y+1
        jsr ?near
        bcc ?jnext
        jsr spr_take                 ; the whole "hand it over" tail moved to the
                                     ;   DROP block: adding the dropped-ammo path
                                     ;   inline pushed this proc past PICKUP_END
?next   inc sp_i
        jmp ?loop
        ; A = delta hi, m_a = delta lo -> C set if |delta| < PICKUP_R
?near   bmi ?neg
        bne ?far
        lda m_a
        cmp #PICKUP_R
        bcc ?in
?far    clc
        rts
?neg    cmp #$FF
        bne ?far
        lda m_a
        cmp #256-PICKUP_R
        bcc ?far
?in     sec
        rts
.endp
    .if * > PICKUP_END+1
        ert 'spr_pickup outgrew PICKUP_BASE..END (memory_map.inc)'
    .endif
        icl 'enemy.asm'              ; damage + death: en_init / en_gunshot
        org pk_resume

        icl 'spr_draw.asm'           ; billboard drawing: spr_draw / spr_one / spr_blit


;==============================================================
; IDLE ANIMATION (2026-08-07, "barely by mali byt animovane.. a aj ine veci").
; info.c gives the barrel a two-frame spawnstate (S_BAR1 <-> S_BAR2, 6 tics) and
; most pickups a ping-pong -- BON1/BON2/SOUL/PMAP are ABCDCB, PINS ABCD, the
; keycards AB at 10 tics, the red torch ABCD at 4. This port drew frame A and
; left it there.
;
; THE CHEAP WAY, and why it is also the RIGHT one. Every item of a kind spawns
; on the same tic in DOOM, so they all run the same phase for the whole level --
; there is nothing per-THING to keep. One ring per animated SPRITE is enough,
; and a ring is a walk over DTAB rows, the same 8-byte rows the death, walk and
; attack machines already use. A row's bytes 0..6 are frame id / 2 spare / w / h
; / left / top, which IS the sprite table's own layout, so a step is a 7-byte
; copy over the sprtab entry and every billboard drawn afterwards picks up the
; new frame with no test anywhere in the draw path. Byte 7 of the row is the
; tics, i.e. the next countdown; byte 7 of the SPRTAB is the bonus/kind id, and
; the copy stops at 6 so it survives.
;
; COST, measured on E1M1 (5 rings): 552 cycles per DOOM tic, and a 5 fps frame
; earns ~7 tics -- 3.9k of 2.5M, 0.16%, with nothing at all added to
; render_world. Dividing a global counter per sprite per frame would have cost
; more and drifted.
;==============================================================
ANVARS = ANVARS_BASE
an_i    = ANVARS                     ; [16] which row of its ring each slot shows
an_t    = ANVARS+16                  ; [16] DOOM tics left on it (0 = no ring)
an_n    = ANVARS+32                  ; scratch: the ring length, then its sprite
    .if ANVARS+33 > ANVARS_END+1
        ert 'the idle-ring vars outgrew ANVARS_BASE..END (memory_map.inc)'
    .endif

an_resume = *
        org ANTICK_BASE
;--------------------------------------------------------------
; an_tick -- ONE DOOM tic of every idle ring. Chained off en_tick, which is in
;   the same tic loop: one clock, one rate.
;--------------------------------------------------------------
.proc an_tick
        ldx #ITAB_MAX-1
?lp     lda an_t,x
        beq ?nx                      ; 0 = this slot holds no ring
        dec an_t,x
        bne ?nx
        jsr an_step
?nx     dex
        bpl ?lp
        rts
.endp

;--------------------------------------------------------------
; an_step -- X = slot: its ring is due, so walk to the next row and put that
;   frame into the sprite table. Clobbers A/Y, zp_ptr, sp_ptr, en_k2+1.
;   Safe here: this runs in the GAME loop, like ai_wake, not the draw path.
;--------------------------------------------------------------
.proc an_step
        lda #<ITAB_SID               ; the three ITAB arrays share one page, so
        sta zp_ptr                   ;   one pointer serves all three
        lda #>ITAB_SID
        sta zp_ptr+1
        txa
        ora #$20                     ; +$20 = ITAB_N (slot is 0..15)
        tay
        lda [zp_ptr],y
        sta an_n
        inc an_i,x                   ; next row of the ring, wrapping
        lda an_i,x
        cmp an_n
        bcc ?ok
        lda #0
        sta an_i,x
?ok     txa
        ora #$10                     ; +$10 = ITAB_FIRST
        tay
        lda [zp_ptr],y
        clc
        adc an_i,x
        sta en_k2+1                  ; en_row takes the row + 1 (a TH_STATE value)
        inc en_k2+1
        txa                          ; ...and the ring's SPRITE, before en_row
        tay                          ;   walks zp_ptr off the ITAB
        lda [zp_ptr],y
        sta an_n
        jsr en_row                   ; zp_ptr = &DTAB_ROWS[row], bank $01
        lda #0                       ; sp_ptr = th_sprtab + id*8, the shifts in
        sta sp_ptr+1                 ;   the ACCUMULATOR (a level can carry 50
        lda an_n                     ;   sprites, so id*8 is 9 bits and the carry
        asl                          ;   has to chain into the high byte)
        rol sp_ptr+1
        asl
        rol sp_ptr+1
        asl
        rol sp_ptr+1
        clc
        adc th_sprtab
        sta sp_ptr
        lda sp_ptr+1
        adc th_sprtab+1
        sta sp_ptr+1
        ldy #6                       ; row 0..6 IS sprtab 0..6; byte 7 is the
?cp     lda [zp_ptr],y               ;   bonus/kind id and must survive
        sta (sp_ptr),y
        dey
        bpl ?cp
        ldy #7
        lda [zp_ptr],y               ; ...and the row's tics is the next countdown
        sta an_t,x
        rts
.endp
    .if * > ANTICK_END+1
        ert 'an_tick/an_step outgrew ANTICK_BASE..END (memory_map.inc)'
    .endif

        org ANINIT_BASE
;--------------------------------------------------------------
; an_init -- per level: park every ring one row BEFORE frame A with a single tic
;   left, so the first DOOM tic wraps it to A and copies the row. Called from
;   lt_init, i.e. at the END of init_level's mv_reset chain -- NOT from
;   load_dtab, which is where it went first: read_ext walks zp_ptr and so does
;   this, and load_los then streamed through a pointer it had moved (a flat pink
;   screen, 2026-08-07).
;--------------------------------------------------------------
.proc an_init
        lda #<ITAB_SID
        sta zp_ptr
        lda #>ITAB_SID
        sta zp_ptr+1
        ldx #ITAB_MAX-1
?lp     lda #0
        sta an_t,x                   ; assume the slot is empty
        txa
        tay
        lda [zp_ptr],y               ; a sprite id, or $FF for "no ring"
        cmp #$FF
        beq ?nx
        txa
        ora #$20                     ; ITAB_N
        tay
        lda [zp_ptr],y
        sec
        sbc #1                       ; one before row 0: the first tic wraps
        sta an_i,x
        lda #1
        sta an_t,x
?nx     dex
        bpl ?lp
        rts
.endp
    .if * > ANINIT_END+1
        ert 'an_init outgrew ANINIT_BASE..END (memory_map.inc)'
    .endif
        org an_resume
