;--------------------------------------------------------------
; sprites.asm -- DOOM things (items, decorations, monsters) as billboards:
;   collection and projection. Data comes from tools/pack_things.py.
;--------------------------------------------------------------
gb_resume = *
;   give_bonus MOVED to the DROP block (enemy_ai.asm) 2026-07-31: the MF_DROPPED
;   halving grew it 12 B and the $0600 hole it shared with calc_u had none. Its
;   TABLES stay here -- they are absolute-indexed, so where the code sits does
;   not matter to them.
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
;   never stuck. Keeps X; clobbers Y (= X >> 3). Two 256-byte tables instead
;   of txa/and/tay/txa/lsr x3/tax: 16 cycles for 24 (long,x has no page cost).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc thing_alive_bit
        lda.l B1CODE_BASE+ta_shr3,x  ; X >> 3: the bitmap byte
        tay
        lda THING_ALIVE,y
        and.l B1CODE_BASE+ta_bit8,x  ; 1 << (X & 7), = mv_bit[X & 7]
        rts
.endp
ta_shr3 :256 dta #/8
ta_bit8 :256 dta 1<<[#&7]
        .endseg
;--------------------------------------------------------------
; TALIVE -- thing_alive_bit's body INLINE (2026-09-26, drac_flow
;   SMALL: 4 instructions, and the jsr/rts was 12 cycles of its ~28). Same
;   contract: X = thing index -> A = the bit, Z from the `and`; Y clobbered.
;--------------------------------------------------------------
.macro TALIVE
        lda.l B1CODE_BASE+ta_shr3,x
        tay
        lda THING_ALIVE,y
        and.l B1CODE_BASE+ta_bit8,x
.endm
    .if * > THALIVE_END+1
        ert 'thing_alive_bit outgrew the $0E78 hole -- see memory_map.inc'
    .endif

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org ta_resume

;--------------------------------------------------------------
sr_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_reset                      ;   spr_add's two chase hooks pushed that
	stz sp_n
        stz sp_clip                  ;   (once per frame, one absolute jsr;
    .if [CLIP_BASE & $FF] != 0       ;    <CLIP_BASE = 0)
        ert 'CLIP_BASE is not page-aligned -- put the lda #< back (sprites.asm)'
    .endif
        lda #>CLIP_BASE
        sta sp_clip+1
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org sr_resume

;--------------------------------------------------------------
; spr_add -- collect the things of subsector (zp_nid & $7FFF). Called by
;   render_subsector BEFORE its segs, mirroring DOOM's R_Subsector order
;   (R_AddSprites first, then R_AddLine). Things are sorted by subsector, so the
;   prefix table gives the range [prefix[s], prefix[s+1]).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_add
        jsr spr_chased               ; a CHASING monster is drawn from the
                                     ;   subsector it walked to, not the one it ...
        lda sp_n                     ; vissprite table full? (front-to-back, so
        cmp #VIS_MAX-2               ; the ones already collected are the
        bcs ?ret                     ; nearest). Two short: the ball and the
                                     ; missile keep a slot each.
;       clc                          ; prefix entry = th_ss + ssid
        lda zp_nid
        adc th_ss
        sta sp_ptr
        lda zp_nid+1
        and #$7F
        adc th_ss+1
        sta sp_ptr+1
        lda (sp_ptr)                ; first thing of this subsector
        sta sp_i
        ldy #1
        lda (sp_ptr),y               ; first thing of the next one
        sta sp_last
        cmp sp_i
        bne ?loop
?ret    rts

?loop   ldx sp_i                     ; already picked up -> do not draw it
        TALIVE                                ; (inlined 2026-09-26)
	jeq ?skip
	lda sp_i                     ; spr_chase already drew it, from where it
        jsr ai_ischase               ;   actually stands
        bne ?skip

        lda sp_i                     ; thing record = th_things + i*8
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
        adc th_things
        sta sp_ptr
        ldy #6
        lda (sp_ptr),y               ; (the sprite id, the flags)
        and #F_DROP<<8
        bne ?drop                    ; a body with its drop beside it
                                     ; 2026-09-22 (65816-windows): spr_proj past its
?proj   jsr spr_proj.spj_w16         ;   rep, still 16-bit (this sep and that rep were
        .LONGA OFF                   ;   an empty pair)

?skip   inc sp_i
        lda sp_n
        cmp #VIS_MAX-2               ; ...the same two reserved slots
        bcs ?ret
        lda sp_i
        cmp sp_last
        bne ?loop
        rts
?drop   .LONGA ON
        sep #$20
        .LONGA OFF
        jsr spr_ditem
        rep #$20
        .LONGA ON
        bra ?proj
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; spr_proj -- project the thing at (sp_ptr) and, if visible, append a vissprite
;   plus a snapshot of the open window over its columns.
;   Thing record: i16 x, i16 y, i16 z (anchor = sector floor), u8 sprite id.
;--------------------------------------------------------------
; 16-BIT (2026-08-29): the thing's position, both differences, the Z test and
; the scale are 16-bit quantities. `lda (sp_ptr),y` reads a whole coordinate in
; one go, so the `iny` between the halves goes with them; transform/scale_z are
; 8-bit code. M only -- X/Y stay 8-bit (sound.asm:316).
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_proj
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
spj_w16                              ; (2026-09-22: 16-bit callers enter here)
        sec
        lda (sp_ptr)
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
                                     ; 2026-09-22: transform returns 16-bit now
        .LONGA ON
;       lda zp_Z                     ; transform ends `adc / sta zp_Z / rts`: A IS zp_Z
        bmi ?skip16                  ;   and N/Z are the adc's (the same value)
        cmp #SPR_MINZ                ; (unsigned 16-bit: Z >= 256 passes it too)
        bcs ?zok
?skip16 .LONGA OFF
        sep #$20
?skip   rts
                                      ; 2026-09-23: A IS Z here (16-bit): scale_z's 16-bit
?zok    jsr scale_z.sz_a16           ;   entry, and it returns 16-bit with A = m_quot
        .LONGA ON
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
        ; --- 16-BIT A for the table-entry math and the header copy ...
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
;       clc
        adc th_sprtab
        sta sp_tab
?have   ldy #3
        lda (sp_tab),y               ; w @3, h @4
        sta sp_w
        ldy #5
        lda (sp_tab),y               ; left @5, top @6
        sta sp_left
                                      ; screenx_signed: 16-bit in and out (2026-09-23)
        jsr screenx_signed.sx_w16    ; m_xs = centre column (unclamped, signed)
        .LONGA ON                    ; x1 = centre - (leftoffset*hs)>>8: both
        lda sp_hs                    ;   operands as words in the window sx_w16
        sta m_a                      ;   returns in (sp_left's word read drags
        lda sp_left                  ;   sp_top in: masked, then sign-extended
        and #$00FF                   ;   as (x ^ $80) - $80 (2026-09-29): N is
        eor #$0080                   ;   the operand's sign for sm_w16)
        sec
        sbc #$0080
        sta m_b
        jsr smul32.sm_w16            ; (16-bit in and out)
        .LONGA ON
        sec
        lda m_xs
        sbc m_prod+1
        sta sp_x1
	lda sp_w
	and #$00ff
	sta m_a
        lda sp_hs
        sta m_b
	sep #$20
	.LONGA OFF
        jsr umul16                   ; (no phx/plx: spr_proj's main path clobbers X
                                     ;   anyway -- transform's FMUL -- so no caller
                                     ;   keeps anything in it)

	rep #$21		;absorb CLC
	.LONGA ON
        lda m_prod+1
	bne ?w1ok
	inc
?w1ok	adc sp_x1                    ; (the width stayed in A: no m_a round trip,
	dec                          ;  2026-09-15)
        sta m_b
	sep #$20
	.LONGA OFF
	xba			;set NZ acc. to MSB value
        bmi ?skip2                   ; entirely off the left edge
        bne ?xbclamp                 ; >= 256 -> clamp to the right edge
        lda m_b
        cmp #SCREEN_WIDTH
        bcc ?xbok
?xbclamp lda #SCREEN_WIDTH-1
?xbok   sta sp_xb
        lda sp_x1+1                  ; xa = max(x1, 0); x1 >= 160 -> off the right
        bmi ?xazero
        bne ?skip2
	lda sp_x1
        cmp #SCREEN_WIDTH
        bcs ?skip2
        sta sp_xa
	bra ?xaok
?skip2  rts
?xazero stz sp_xa


?xaok   lda sp_xb
        cmp sp_xa
        bcc ?skip2

        lda sp_h                     ; on-screen height = (h*scale)>>8
        sta m_a
        stz m_a+1
        lda sp_scale
        sta m_b
        lda sp_scale+1
        sta m_b+1

        jsr umul16                   ; (no phx/plx: spr_proj's main path clobbers X
                                     ;   anyway -- transform's FMUL -- so no caller
                                     ;   keeps anything in it)

        lda m_prod+1
        sta sp_rows
        lda m_prod+2
        sta sp_rows+1
        ora sp_rows
        beq ?skip2
	rep #$21		;absorb CLC
	.LONGA ON
        ldy #4                       ; world height of the sprite's top row
        lda sp_top                   ;   = thing z + topoffset, relative to the eye
	and #$00ff
;	clc
	adc (sp_ptr),y
	sec
        sbc zp_pz
        sta m_a

        lda sp_scale
        sta m_b                      ; 2026-09-29: A = m_b, N its sign (track_calc's entry)
        jsr track_calc               ; m_prod[0..2] = horizon - world*scale (Q8),
                                     ;   returned 16-bit
        .LONGA ON                    ; screen row of texture row 0, the two
                                     ;   visibility tests on the WORD, and the
        lda m_prod+1                 ;   bottom row off the same A (2026-09-15)
        sta sp_ytop
        bmi ?vis                     ; above the horizon -> definitely not below screen
        cmp #SCREEN_HEIGHT
        bcc ?vis
        .LONGA OFF
        sep #$20                     ; row >= 200 -> below the screen
?bail	rts
        .LONGA ON
?vis    clc                          ; bottom row = ytop + rows - 1
        adc sp_rows
	dec
        sta sp_ybot
	sep #$20
	.LONGA OFF
        bmi ?bail                    ; entirely above the screen

        ; --- snapshot the open window over [xa..xb] into the clip pool ---
        lda sp_xb
        sec
        sbc sp_xa
        sta sp_cnt                   ; columns - 1

?csize
	rep #$20
	.LONGA ON
	lda sp_cnt
	and #$00ff
	inc
	asl
;	clc
	adc sp_clip
	cmp #CLIP_END
	sep #$20
	.LONGA OFF
        bcc ?cfit
        ; --- POOL TOO TIGHT.
        lda sp_cnt
        beq ?bail                    ; already one window: the page really is full
	stz sp_cnt
	bra ?csize

?cfit   lda sp_clip                  ; block base (the pool is one page: hi = $07)
        sta sp_cbase
        lda #1                       ; assume one window covers every column
        sta sp_uni

        ldx sp_xa
                                      ; 2026-09-15: the window pair rides A:B (top
?snap   lda solid_arr,x              ;   low, bottom high) -- ONE 16-bit store into
        bne ?solid                   ;   the pool, ONE 16-bit compare against the
?win    lda ytopc_arr,x              ;   first column's pair, the pointer step a
        cmp ybotc_arr,x              ;   16-bit inc/inc. ~83 cycles a column, was
        beq ?open                    ;   ~96; the bytes written are the same
        bcs ?closed                  ; top > bot -> nothing open in this column
?open   xba
        lda ybotc_arr,x              ; window bottom -> B, top back to A
        xba
        bra ?put
?solid  lda.l SSCL_LO,x              ; closed by a wall FARTHER than this sprite
        cmp sp_scale                 ;   (an earlier leaf's, e.g. a pillar's other
        lda.l SSCL_HI,x              ;   face): the sprite gets the window that
        sbc sp_scale+1               ;   wall closed (r_things.c R_DrawSprite
        bcc ?win                     ;   skips a seg with scale < spr->scale)
?closed lda #255                     ; 255/255 = fully covered by nearer geometry
        xba
        lda #255
        ; --- uniform test: 90% of sprites see ONE window over all their columns
        ;     (measured, tools/_dbg_sprcap.py).
?put    ldy sp_clip                  ; first column? (Y: A/B hold the pair, and
        cpy sp_cbase                 ;   the pool is one page, so the low byte says)
        rep #$20
        .LONGA ON
        sta (sp_clip)                ; window top, bottom
        bne ?ucmp
        sta sp_t0                    ; the first: remember it (sp_b0 follows sp_t0)
        bra ?s2
?ucmp   cmp sp_t0
        beq ?s2
        ldy #0
        sty sp_uni
?s2     lda sp_clip
        inc
        inc
        sta sp_clip
        sep #$20
        .LONGA OFF
        inx
        dec sp_cnt
        bpl ?snap

        lda sp_uni
        beq ?keep                    ; per-column windows: keep the whole block
        lda sp_t0
        cmp #255
        bne ?uni                     ; every column closed -> nothing to draw at
        lda sp_cbase                 ; all: hand the whole block back and drop it
        sta sp_clip                  ; (a hidden sprite must not eat a vissprite)
	rts

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
        lda sp_i                     ; and the THING index: the hitscan needs the
        sta vs_th,x                  ;   thing (its health), not the sprite
        lda sp_cbase                 ; clip block, low byte; bit 0 = uniform window
        ora sp_uni                   ; (blocks are 2 B aligned, so bit 0 is spare)
        sta vs_cpl,x
        ; --- slot it into the draw order, NEAREST first ----------------------
        ; The BSP walk hands sprites over front-to-back already, so this insertion
        ; usually stops at the first compare (~10 inversions per frame, measured).
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
	bra ?ins
?place  lda sp_n
        sta vs_ord,x
        inc sp_n
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_pickup -- once per frame: take everything the player REACHED FOR.
;--------------------------------------------------------------
pk_resume = *
        org PICKUP_BASE              ; moved out of the $B000 segment -- see the
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_pickup                     ;   PICKUP_BASE note in memory_map.inc
        lda pk_valid                 ; the level's PICKUP LIST (PK_*, memory_map
        bne ?walk                    ;   .inc): en_init cleared the flag, so the
        jsr pk_build                 ;   first frame scans all things ONCE; every
?walk   stz pk_j
pk_loop                              ;   270 things (_bench_subsys 2026-08-31)
?loop   ldx pk_j                     ; (pk_rm re-enters at pk_loop: same slot,
        cpx pk_n                     ;   done when the list is out)
        bcc ?go
        rts
?go     lda.l PK_IDX,x               ; the thing index -- spr_take's and the
        sta sp_i                     ;   alive bit's key -- and its record
        tax                          ;   address, precomputed by pk_build: the
        TALIVE                       ;   i*8 shift run left this FLUSH block
                                     ;   (2026-09-27: inline -- the far-x exit
        bne ?have                    ;   above freed the branch reach)
?spent  jmp pk_rm                    ; taken item / collected drop: it can never
?have   ldx pk_j                     ;   match again -- swap-remove the slot and
        lda.l PK_ALO,x               ;   rescan it, so the walked list SHRINKS
        sta sp_ptr                   ;   toward zero as the level gets played
        lda.l PK_AHI,x
        sta sp_ptr+1
        ldy #7                       ; bit0 = a map pickup, bit2 = a corpse that
        lda (sp_ptr),y               ;   P_KillMobj dropped ammo on (en_kill sets
        and #1|F_DROP                ;   it for the zombieman and the shotgun guy)
        beq ?spent
        sta sp_pick                  ; remember WHICH -- the bonus id and the
        rep #$20                     ; |x - pk_x| < PICKUP_R ?  (pk_x/pk_y, NOT
        .LONGA ON                    ;   zp_px/zp_py: the point move_player ASKED
        sec                          ;   for -- see the header and memory_map.inc)
        lda (sp_ptr)                 ; 2026-09-15: each axis ONE word subtract and
        sbc pk_x                     ;   one unsigned range test: d + R in [0, 2R)
        clc                          ;   <=> d in [-R, R-1], exactly the set the
        adc #PICKUP_R                ;   old ?near's four byte tests accepted
        cmp #2*PICKUP_R
        bcc ?xin                     ; 2026-09-27: out of reach on x is the COMMON
        sep #$20                     ;   case -- it falls through to the next entry
        .LONGA OFF                   ;   (was bcs ?far16 / sep / bra ?next / inc /
        inc pk_j                     ;   bra: two taken branches fewer)
        bra ?loop
        .LONGA ON
?xin    ldy #2                       ; |y - pk_y| < PICKUP_R ?
        sec
        lda (sp_ptr),y
        sbc pk_y
        clc
        adc #PICKUP_R
        cmp #2*PICKUP_R
        .LONGA OFF
        sep #$20
        bcs ?next
        lda pl_air                   ; MID-AIR only: P_TouchSpecialThing's
        beq ?take                    ;   delta = special->z - toucher->z, out
        rep #$21                     ;   of reach above PLAYER_H or 8 below
        .LONGA ON                    ;   his feet
        ldy #4
        lda (sp_ptr),y
        sbc pl_z
        clc                          ; (C was 0: delta-1, so +9 below)
        adc #9                       ; delta + 8 in [0, PLAYER_H + 8]
        cmp #PLAYER_H+9
        sep #$20
        .LONGA OFF
        bcs ?next
?take   jsr spr_take                 ; the whole "hand it over" tail moved to the
                                     ;   DROP block: adding the dropped-ammo path
                                     ;   inline pushed this proc past PICKUP_END
?next   inc pk_j
        jmp ?loop                    ; (2026-09-27: TALIVE inline put ?loop out of
.endp                                ;   bra reach; jmp abs is 3 cycles as well)
        .endseg
    .if * > PICKUP_END+1
        ert 'spr_pickup outgrew PICKUP_BASE..END (memory_map.inc)'
    .endif
        icl 'enemy.asm'              ; damage + death: en_init / en_gunshot
        org pk_resume

;--------------------------------------------------------------
; pk_build -- fill the pickup list from the records: every thing with bit0
;   (map pickup). ONCE per level entry -- en_init clears pk_valid, the next
;   spr_pickup lands here. Fresh level, restart and load-game all stream
;   fresh records, so F_DROP is never set at build time; en_dropmark appends
;   those corpses live as they happen. Cost = one old-style full scan, once.
;--------------------------------------------------------------
pkb_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pk_build
        ;lda #0
        stz pk_n
        stz pk_i
?lp     lda pk_i
        cmp THINGS_BASE              ; the packed thing count
        bcs ?done
        jsr en_thing.en_th2          ; sp_ptr = the record (A = index; clobbers Y)
        ldy #7
        lda (sp_ptr),y
        and #1                       ; map pickups only -- see the header
        beq ?nx
        lda pk_i
        jsr pk_append
?nx     inc pk_i
        bra ?lp
?done   lda #1
        sta pk_valid
        rts
.endp
        .endseg
;--------------------------------------------------------------
; pk_append -- A = thing index, sp_ptr = its record: one more list row.
;   Also en_dropmark's live append (a corpse that just got its F_DROP).
;   Never overflows: at most one row per thing, and the count is a byte.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pk_append
        ldx pk_n
        sta.l PK_IDX,x
        lda sp_ptr
        sta.l PK_ALO,x
        lda sp_ptr+1
        sta.l PK_AHI,x
        inc pk_n
        rts
.endp
        .endseg
;--------------------------------------------------------------
; pk_dropadd -- en_dropmark's tail (its block is full to the byte): append
;   the corpse whose F_DROP it just set, put its caller's Y back, return.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pk_dropadd
        lda ai_t2                    ; the thing index en_dropmark parked
        jsr pk_append
        ldy ai_t2
        rts
.endp
        .endseg
;--------------------------------------------------------------
; pk_rm -- spr_pickup's spent slot (taken item, or a corpse whose drop was
;   collected -- bit0 is static and F_DROP is set once, so neither can ever
;   match again): copy the LAST row over slot pk_j, shrink, rescan the slot.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pk_rm
        dec pk_n
        ldx pk_n
        lda.l PK_IDX,x
        pha
        lda.l PK_ALO,x
        pha
        lda.l PK_AHI,x
        ldx pk_j
        sta.l PK_AHI,x
        pla
        sta.l PK_ALO,x
        pla
        sta.l PK_IDX,x
        jmp spr_pickup.pk_loop
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
pk_valid dta 0                       ; 0 = rebuild (en_init clears it per level)
pk_n     dta 0                       ; rows in the list
pk_j     dta 0                       ; spr_pickup's cursor
pk_i     dta 0                       ; pk_build's thing counter
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org pkb_resume

        icl 'spr_draw.asm'           ; billboard drawing: spr_draw / spr_one / spr_blit


;==============================================================
; IDLE ANIMATION (2026-08-07, "barely by mali byt animovane.. a aj ine veci").
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

;--------------------------------------------------------------
; an_step -- X = slot: its ring is due, so walk to the next row and put that
;   frame into the sprite table. Clobbers A/Y, zp_ptr, sp_ptr, en_k2+1.
;   Safe here: this runs in the GAME loop, like ai_wake, not the draw path.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        stz an_i,x
?ok     txa
        ora #$10                     ; +$10 = ITAB_FIRST
        tay
        lda [zp_ptr],y
        clc
        adc an_i,x
        sta en_k2+1                  ; en_row takes the row + 1 (a TH_STATE value)
        inc en_k2+1
	txy
        lda [zp_ptr],y
        sta an_n
        jsr en_row                   ; zp_ptr = &DTAB_ROWS[row], bank $01
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
	.LONGA ON
	lda an_n
	and #$00ff
	asl
	asl
	asl
;	clc
        adc th_sprtab
        sta sp_ptr
	sep #$20
	.LONGA OFF

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
        .endseg
    .if * > ANTICK_END+1
        ert 'an_tick/an_step outgrew ANTICK_BASE..END (memory_map.inc)'
    .endif

        org ANINIT_BASE
;--------------------------------------------------------------
; an_init -- per level: park every ring one row BEFORE frame A with a single tic
;   left, so the first DOOM tic wraps it to A and copies the row.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc an_init
        lda #<ITAB_SID
        sta zp_ptr
        lda #>ITAB_SID
        sta zp_ptr+1
        ldx #ITAB_MAX-1
?lp
        stz an_t,x                   ; assume the slot is empty
	txy
        lda [zp_ptr],y               ; a sprite id, or $FF for "no ring"
        cmp #$FF
        beq ?nx
        txa
        ora #$20                     ; ITAB_N
        tay
        lda [zp_ptr],y
	dec
        sta an_i,x
        inc an_t,x
?nx     dex
        bpl ?lp
        rts
.endp
        .endseg
    .if * > ANINIT_END+1
        ert 'an_init outgrew ANINIT_BASE..END (memory_map.inc)'
    .endif
        org an_resume
