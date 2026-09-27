;--------------------------------------------------------------
; Part of enemy.asm (icl in place): the MOVING sprite + its rotations -- spr_dyn, spr_wrot, oct_of, en_kind_of, aif_oct, wrot_*, en_kfill.
;--------------------------------------------------------------
        org SPRDYN_BASE

;--------------------------------------------------------------
; spr_dyn -- A = thing index. If the thing is DYING, copy its current death row
;   out of bank $01 into sp_drow and point sp_tab at it, returning C=1: the
;   caller then reads an ordinary 8-byte sprite-table row and needs no other
;   change. C=0 = a live thing, use the real sprite table. Preserves X.
;   zp_ptr is saved/restored -- the BSP walk owns it while spr_add runs.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_dyn
                                      ; 2026-09-23: X parked on the stack (under the
        phx                          ;   pei), not in sp_dsx
        tax
        pei (zp_ptr)
	stz sp_dflip
                                      ; 2026-09-27 (65816-modes-banks: long,x): both
        lda.l EXT_BASE+TH_STATE,x   ;   tests read their page straight --
        bne ?row                     ;   zp_ptr+2 IS MAP_EXT_BANK while the walk runs
                                     ;   (bsp_main sets it once). dying: TH_STATE is
                                     ;   the death row+1
        lda.l EXT_BASE+TH_WROW,x    ; not dying -- is it CHASING? TH_WROW
        beq ?live                    ;   is the walk row+1, and a walk row IS a death
                                     ;   row: same 8 bytes in the same DTAB_ROWS array
        stz zp_ptr                   ; spr_wrot: zp_ptr = a page pointer (lo 0),
        txy                          ;   Y = the thing
        jsr spr_wrot                 ; + the rotation slot for how it faces the
                                     ;   viewer (walk and attack rows both --
                                     ;   DOOM's attack frames rotate too)
?row    sta en_k2+1
        jsr en_row                   ; zp_ptr -> DTAB_ROWS + row*8
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
	.LONGA ON
	ldy #8-2		;can't fully unroll, doesn't fit in the assigned RAM block
?cp	lda [zp_ptr],y
	sta sp_drow,y
	dey
	dey
	bpl ?cp
                                      ; 2026-09-23: sp_tab and zp_ptr in the copy's own
	lda #sp_drow                 ;   window, then wrot_left inline (its jsr and a
	sta sp_tab                   ;   sep/rep pair gone)
	pla
	sta zp_ptr
	sep #$20
	.LONGA OFF
        bit sp_dflip                 ; a mirrored view anchors from its other
        bpl ?nf                      ;   edge (r_things.c: tx -= width - offset)
        sec
        lda sp_drow+3                ; w
        sbc sp_drow+5                ; - left
        sta sp_drow+5
?nf     plx
        sec
        rts
?live   stz zp_ptr                   ; (wrot_idle: zp_ptr lo 0, Y = the thing)
        txy
        jsr wrot_idle                ; an IDLE monster faces its SPAWN angle
        bcs ?row                     ;   (walk image 0's rotation group)
        pla
        sta zp_ptr
        pla
        sta zp_ptr+1
        plx
        rts
.endp
        .endseg
sp_drow dta 0,0,0,0,0,0,0,0
sp_dsx  dta 0
    .if * > SPRDYN_END+1
        ert 'spr_dyn outgrew SPRDYN_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; spr_wrot -- A = TH_WROW (walk row+1; ai_setrow already multiplied the image
;   by NSTOR), Y = thing index, zp_ptr = a bank-$01 page pointer (lo byte 0).
;   Returns A = row+1 + the ROTATION SLOT for how the thing faces the viewer,
;   and sets sp_dflip bit7 when the view is a MIRRORED one (DOOM rots 6 and 7).
;   was cleared by spr_dyn. Preserves Y (the thing index). X is free here.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_wrot
        sta swr_row
        lda sp_dfix                  ; draw-time REPLAY: spr_one hands back the
        cmp #$FF                     ;   byte chosen at projection ($FF = fresh
        beq ?live                    ;   zp_rx/ry, compute it now)
        sta sp_dflip
        and #$03
        adc swr_row
        rts
?live   lda wrot_nst                 ; 4 stored views, or a front-only build?
        cmp #4                       ;   (attack rows rotate exactly like walk
        bne ?out                     ;   rows since 2026-08-03 -- DOOM's attack
                                     ;   frames carry rotations too, and the
                                     ;   packer stores them state-major x 3)
        lda #>TH_DIR
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp #8                       ; DI_NODIR -> keep the front view
        bcc ?go
?out    lda swr_row                  ; the epilogue sits UP HERE: the octant
        rts                          ;   body below is past branch range
                                      ; 2026-09-23: b1_oct_of keeps Y (no swr_y round
?go     sta swr_dir                  ;   trip) and is entered past its rep, still
        rep #$20                     ;   16-bit (this window's sep and its rep were
        .LONGA ON                    ;   an empty pair)
        lda zp_rx
        sta swr_vx
        lda zp_ry
        sta swr_vy
        jsl B1CODE_BASE+b1_oct_of.oo_w16
        .LONGA OFF
        eor #4                       ; rot = (octant + 4 - TH_DIR) & 7; octant is
        sec                          ;   0..7, so +4 mod 8 is eor #4 (no clc)
        sbc swr_dir
        and #7
        tax
        lda swr_rot4,x               ; -> slot (bits 0-1) + flip (bit 7)
        sta sp_dflip
        and #$03
        clc
        adc swr_row
        rts
.endp
        .endseg

;--------------------------------------------------------------
; oct_of -- A = the 8-sector angle (octant) of the 16-bit signed vector
;   (swr_vx, swr_vy): 0 = +x (east), counting CCW, each sector 45 deg wide
;   centred on its axis/diagonal. No atan: sign quadrant + |dx| vs |dy|*2.25
;   compares (the 2.25 sits the boundary at 24 deg instead of 22.5 -- 1.4 deg
;   of skew, pinned by tools/_verify_rot.py). Clobbers A/X, preserves Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc oct_of                          ; THE THUNK -- see bank01.asm.
        jsl B1CODE_BASE+b1_oct_of
        rts                          ; a bank-0 `jmp oct_of` still works: it lands
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
swr_vx  dta a(0)
swr_vy  dta a(0)

;--------------------------------------------------------------
; en_kind_of -- A = sprite id -> en_kind = that sprite's MONSTER KIND byte.
;   It rides in the LAST byte of the sprtab row, which the pickups use for their
;   bonus id -- a sprite is never both, and pack_things.py asserts it. Cold: once
;   per shot that hits something, plus wrot_idle's per-visible-idle-monster call.
;   Clobbers A/X/Y and the sp_tab scratch -- X because the *8 below is a dex/bne
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_kind_of
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
	sta en_k2
;	clc
;	lda en_k2
        adc th_sprtab
        sta sp_tab
	sep #$20
	.LONGA OFF
        ldy #7
        lda (sp_tab),y
        sta en_kind
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_oct -- A = octant(ai_t -> ITS TARGET), and it leaves swr_vx/vy holding
;   that vector with swr_ax/ay = its normalised |legs| (oct_of's own scratch).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_oct
        jsr aif_tpos                 ; ai_tx/ai_ty = the target (player or the
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
        sep #$20
                                     ;   infight victim -- infight.asm resolves
                                     ;   it for the melee/newdir tests already)
        lda ai_t
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = MY record
	.LONGA ON
	sec
	lda ai_tx
	sbc (sp_ptr)
	sta swr_vx

	ldy #2
	sec
	lda ai_ty
	sbc (sp_ptr),y
	sta swr_vy
                                      ; 2026-09-23: past b1_oct_of's rep, still 16-bit
        jsl B1CODE_BASE+b1_oct_of.oo_w16 ; -> A = the octant, 0..7
        .LONGA OFF
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
; DOOM rot (0 = facing the viewer) -> stored slot (bits 0-1) + mirror (bit 7).
; pack_things STORED_ROTS stores lump digits 1/2/3/5, so SIX of DOOM's eight
; views are its own pixels: rot 0 the front, 1 the 3/4 front and 7 that same
; image mirrored (the WAD ships A2A8 as ONE lump), 2 the profile and 6 its
; mirror (A3A7), 4 the back. The other two -- the 3/4-BACK views, rots 3 and 5
; -- fall back on the plain back, so the table below reads slot 3 three times.
; (2026-08-25: this said SEVEN and then listed six. Measured on the shipped
;  bytes: drive spr_wrot over all eight TH_DIRs and six distinct slot/mirror
;  pairs come back -- tools/tests/_verify_arena.py's sibling check.)
; WHY four and not five: digit 4 is left out because a monster's back is what
; the player looks at least. The reason USED to be "the 24 KB coltab run at
; $01:9400 has no room"; that run moved to bank $08 and is 57 KB now
; (2026-08-21), but a fifth view still does not fit -- E3M9 already spends 254
; of the 254 usable FRAME IDS, and the id is a byte.
;   BEFORE 2026-08-07 only digits 1/3/5 were stored and rots 1 and 7 collapsed
;   onto the FRONT, i.e. the front view was 135 deg wide instead of 45: every
;   monster within 67 deg of the player's line stared straight at him.
swr_rot4 dta $00,$01,$02,$03,$03,$03,$82,$81
swr_row  dta 0
swr_y    dta 0
swr_dir  dta 0
swr_ax   dta a(0)
swr_ay   dta a(0)
swr_t    dta a(0)

;--------------------------------------------------------------
; wrot_init -- per level (from en_init, whose block is full): cache the
;   stored-view count out of bank $01. pack_things wn[0] = 3 with rotations,
;   1 for a front-only build; 0 means a pre-rotation .dtab -- treat as 1.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wrot_init
        lda #<WTAB_N
        sta zp_ptr
        lda #>WTAB_N
        sta zp_ptr+1
        lda [zp_ptr]
        bne ?nst
        lda #1
?nst    sta wrot_nst
	stz zp_ptr
        rts
.endp
        .endseg

;--------------------------------------------------------------
; wrot_dir -- en_init's per-thing tail: TH_DIR[thing] = the SPAWN FACING from
;   the record's flags bits 4-6 (P_SpawnMapThing's ANG45*(mthing->angle/45),
;   packed by pack_things).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wrot_dir
                                      ; 2026-09-23: the page first, Y on the stack --
        lda #>TH_DIR                 ;   the facing stays in A to its store
        sta zp_ptr+1
        phy                          ; the record read below needs Y
        ldy #7
        lda (sp_ptr),y
        lsr
        lsr
        lsr
        lsr
        and #7
        sta swr_dir
        ply
        sta [zp_ptr],y
        lda #>TH_HPL                 ; hand the page back to the caller's loop
        sta zp_ptr+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; wrot_idle -- spr_dyn's ?live tail: an IDLE MONSTER still rotates (it faces
;   its spawn angle, DOOM's P_SpawnMapThing), so give it walk image 0's
;   rotation group instead of the flat sprtab row.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wrot_idle
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y               ; 0 = not a monster (or a shootable this
        bne ?mons                    ;   port has no kind for): static path
        clc
        rts
                                      ; 2026-09-23: Y parked on the stack and pulled
?mons   phy                          ;   ONCE, before the $FF test (ply sets N/Z,
        tay                          ;   the cmp after it decides)
        lda #<WTAB_EXT
        sta zp_ptr
        lda #>WTAB_EXT
        sta zp_ptr+1
        lda [zp_ptr],y
	stz zp_ptr
        ply
        cmp #$FF
        beq ?flat
	inc
        jsr spr_wrot                 ; idle: TH_MODE bit0 clear, TH_DIR = spawn
        sec                          ;   octant -> the facing-correct slot
        rts
?flat   clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_kfill -- en_init's third pass (chained off it: the ENINIT block is full):
;   TH_KIND[i] for EVERY thing -- the sprtab kind byte when the thing has hit
;   points, else 0. Exactly what ai_start used to cache at wake, precomputed
;   so wrot_idle and ai_wake read one byte per frame instead of probing hp
;   and walking the sprite table. Tail-jumps ai_reset (en_init used to).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_kfill
        lda th_things
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        ldx #0
?lp     cpx THINGS_BASE              ; the packed thing count
        bcs ?done
        ldy #6
        lda (sp_ptr),y               ; the record's sprite id
        sta en_k2
        txy
        lda #>TH_HPL                 ; a monster is exactly "it has hit points"
        sta zp_ptr+1
        lda [zp_ptr],y
        sta en_t
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora en_t
        beq ?zero

        lda en_k2                    ; th_sprtab + sid*8 + 7 = the kind byte
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
	sta en_t
;	clc
	adc th_sprtab
	sta sp_tab
	sep #$20
	.LONGA OFF
        ldy #7
        lda (sp_tab),y
        bne ?put
?zero   lda #0
                                      ; 2026-09-23: the page through Y, so the kind
?put    ldy #>TH_KIND                ;   stays in A (no en_t round trip)
        sty zp_ptr+1
        txy
        sta [zp_ptr],y
        clc                          ; next record
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inx
        bne ?lp
?done   jmp ai_reset                 ; ...and nothing chases in a fresh level
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
swr_y2  dta 0

;--------------------------------------------------------------
; wrot_left -- spr_dyn's post-copy fixup: a MIRRORED view anchors from its
;   other edge -- r_things.c R_ProjectSprite does `tx -= spritewidth - offset`
;   when the frame is flipped, against `tx -= offset` normally. The row copy
;   is private (sp_drow), so the left-offset byte is simply rewritten there.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wrot_left                       ; (2026-09-23: inlined in spr_dyn, its only caller)
.endp
        .endseg

