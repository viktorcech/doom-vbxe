;--------------------------------------------------------------
; RAM BUDGET: 755 B free, biggest contiguous block 397 B.
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
; AUTO-SPLIT from renderer.asm -- assembled in place via icl (org wrap stays in renderer.asm).

;==============================================================
; use_ray.asm -- the geometry half of try_use (DOOM P_UseLines / PTR_UseTraverse).
;   Assembled INSIDE the $2000 engine segment: the $1B00 relocation block holds
;   the door state machine + try_use itself and had no room left, while deleting
;   three dead math procs (sdiv_prod/clamp_tb/screenx) freed exactly this much
;   here. Called by use_leaf in doors.asm.
;==============================================================

;--------------------------------------------------------------
; use_side -- sign helper for the crossing test: A = 1 if
;   cross(PT[Y] - PT[X], PT[USE_K] - PT[X]) > 0, i.e. point k is LEFT of the
;   directed line PT[X] -> PT[Y]. X/Y/USE_K are byte offsets into USE_PT
;   (0 = ray start, 4 = ray end, 8 = seg v1, 12 = seg v2).
;   Points are 4 B: x lo/hi, y lo/hi. Tail-calls cross_pos (sign only, no divide).
;   Parked at USESIDE_BASE (the BALL hole's tail since 2026-08-04 -- E1M6's
;   things blob wanted its old $CE80 home): the $2000 segment has no room for
;   all three procs, and this one only runs when USE is pressed.
;--------------------------------------------------------------
us_resume = *
        org USESIDE_BASE
.proc use_side
        sec                          ; cx_a = PTx[j] - PTx[i]
        lda USE_PT,y
        sbc USE_PT,x
        sta cx_a
        lda USE_PT+1,y
        sbc USE_PT+1,x
        sta cx_a+1
        sec                          ; cx_c = PTy[j] - PTy[i]
        lda USE_PT+2,y
        sbc USE_PT+2,x
        sta cx_c
        lda USE_PT+3,y
        sbc USE_PT+3,x
        sta cx_c+1
        ldy USE_K
        sec                          ; cx_b = PTy[k] - PTy[i]
        lda USE_PT+2,y
        sbc USE_PT+2,x
        sta cx_b
        lda USE_PT+3,y
        sbc USE_PT+3,x
        sta cx_b+1
        sec                          ; cx_d = PTx[k] - PTx[i]
        lda USE_PT,y
        sbc USE_PT,x
        sta cx_d
        lda USE_PT+1,y
        sbc USE_PT+1,x
        sta cx_d+1
        jmp cross_pos                ; A = 1 if cx_a*cx_b - cx_c*cx_d > 0
.endp
    .if * > PJGO_BASE
        ert 'use_side overran its $5432 slot (pj_go at $5480; memory_map.inc)'
    .endif
        org us_resume                ; back to the $2000 engine-code segment


;--------------------------------------------------------------
; use_seg_hit -- zp_sptr -> seg. A = 1 if the USE ray (USE_PT_A..USE_PT_B) crosses
;   this seg. Both segments straddle each other's line -- the textbook 4-sign test,
;   which needs no intersection point (so no divide).
;--------------------------------------------------------------
.proc use_seg_hit
        ldy #0                       ; v1 -> USE_PT_P
        lda [zp_sptr],y
        sta m_a
        iny
        lda [zp_sptr],y
        sta m_a+1
        jsr coll_vptr                ; zp_ptr = &MAP_VERTS[idx] (EXT bank)
        ldy #3
?cp1    lda [zp_ptr],y
        sta USE_PT_P,y
        dey
        bpl ?cp1
        ldy #2                       ; v2 -> USE_PT_Q
        lda [zp_sptr],y
        sta m_a
        iny
        lda [zp_sptr],y
        sta m_a+1
        jsr coll_vptr
        ldy #3
?cp2    lda [zp_ptr],y
        sta USE_PT_Q,y
        dey
        bpl ?cp2
        lda #0                       ; do the ray's ENDS straddle the seg's line?
        sta USE_K                    ;   (rejects most segs on the first two signs)
        ldx #8
        ldy #12
        jsr use_side
        sta m_ma                     ; side(P->Q, A)
        lda #4
        sta USE_K
        ldx #8
        ldy #12
        jsr use_side
        cmp m_ma
        beq ?miss                    ; same side -> no crossing
        lda #8                       ; ... and do the seg's ENDS straddle the ray?
        sta USE_K
        ldx #0
        ldy #4
        jsr use_side
        sta m_ma
        lda #12
        sta USE_K
        ldx #0
        ldy #4
        jsr use_side
        cmp m_ma
        beq ?miss
        lda #1
        rts
?miss   lda #0
        rts
.endp

;--------------------------------------------------------------
; use_shut -- zp_sptr -> two-sided seg. A = 1 if its opening is <= 0, i.e.
;   p_maputl.c P_LineOpening: opentop = min(fceil, bceil),
;   openbottom = max(ffloor, bfloor), shut when opentop <= openbottom.
;
;   THE SHORTCUT THAT USED TO BE HERE WAS NOT AN IDENTITY (2026-08-07, "enemies
;   see me through the closed door", E1M4 (14,170)). It read
;       openrange > 0  <=>  fceil > bfloor AND bceil > ffloor
;   -- two CROSS compares, which never weigh a sector against ITSELF. A shut door
;   whose own floor stands above the neighbouring floor passes both: E1M4's tag-1
;   doors are floor 144 / ceil 144 against neighbours at floor 136, so bceil (144)
;   > ffloor (136) and the seg read as OPEN with openrange 0. Sight, bullets and
;   the USE ray all went through, and the 8-unit lip is the "door not quite
;   seated" the player could see. It held on E1M1 -- every door sector there
;   shares its neighbours' floor -- which is why tools/_verify_useray.py signed it
;   off. tools/tests/_verify_openrange.py counts 26 such lines in episode 1, on
;   every map but E1M1. The min/max pair is the only correct answer.
;
;   All three compares stay "<=", not "<": a ceiling sitting exactly ON a floor is
;   shut, and that is the normal state of every closed door in the WAD. The extra
;   -1 comes free from starting the last subtraction with CLC instead of SEC.
;--------------------------------------------------------------
.proc use_shut
        ldy #SEG_FRONT               ; front sector -> coll_ax = floor, coll_ay = ceil
        lda [zp_sptr],y
        sta m_a
        lda #0
        sta m_a+1
        jsr coll_secheights
        lda coll_ax                  ; keep the front pair (coll_secheights reuses it)
        sta coll_bx
        lda coll_ax+1
        sta coll_bx+1
        lda coll_ay
        sta coll_by
        lda coll_ay+1
        sta coll_by+1
        ldy #SEG_BACK                ; back sector -> coll_ax/coll_ay
        lda [zp_sptr],y
        sta m_a
        lda #0
        sta m_a+1
        jsr coll_secheights
        clc                          ; fceil - ffloor - 1 < 0 <=> fceil <= ffloor:
        lda coll_by                  ;   the FRONT sector is collapsed. This one
        sbc coll_bx                  ;   stays here because us_open's hole holds
        lda coll_by+1                ;   only three; the seg records of a shut
        sbc coll_bx+1                ;   door's OWN subsector are exactly these
        bvc ?f3                      ;   (10 of E1M4's 104 shut segs), so leaving
        eor #$80                     ;   it out kept them answering "open".
?f3     bmi ?shut
        jmp us_open                  ; the other three, out at USSHUT_BASE: they
                                     ;   do not fit in this block (it ends at
                                     ;   BLKCELL/RADFILL $E3C0, not USERAY_END).
                                     ;   A jmp, not a jsr -- us_open's rts returns
                                     ;   straight to use_shut's caller, A set.
?shut   lda #1
        rts
.endp

;--------------------------------------------------------------
; us_open -- use_shut's tail. coll_ax/coll_ay = the BACK sector's floor/ceil,
;   coll_bx/coll_by = the FRONT sector's. A = 1 if the opening is <= 0.
;   min(fc,bc) <= max(ff,bf) is FOUR ORed compares -- the two CROSS ones this
;   used to have, plus each sector against itself. Three of them live here; the
;   fourth (fceil <= ffloor) stayed back in use_shut, because this hole holds
;   only three and use_shut's own block had room for exactly one.


;--------------------------------------------------------------
usop_resume = *
        org USSHUT_BASE
.proc us_open
        clc                          ; bceil - bfloor - 1 < 0 <=> bceil <= bfloor:
        lda coll_ay                  ;   the BACK sector is collapsed, i.e. this
        sbc coll_ax                  ;   IS a shut door. Without it a door whose
        lda coll_ay+1                ;   floor stands ABOVE its neighbour's reads
        sbc coll_ax+1                ;   as open -- E1M4's tag-1 doors are 144/144
        bvc ?f0                      ;   against neighbours at 136, and that lip
        eor #$80                     ;   is the "door not quite seated" the player
?f0     bmi ?shut                    ;   can see. 26 such lines in episode 1.
        clc                          ; fceil - bfloor - 1 < 0  <=>  fceil <= bfloor
        lda coll_by
        sbc coll_ax
        lda coll_by+1
        sbc coll_ax+1
        bvc ?f1
        eor #$80
?f1     bmi ?shut
        clc                          ; bceil - ffloor - 1 < 0  <=>  bceil <= ffloor
        lda coll_ay
        sbc coll_bx
        lda coll_ay+1
        sbc coll_bx+1
        bvc ?f2
        eor #$80
?f2     bmi ?shut
        lda #0
        rts
?shut   lda #1
        rts
.endp
    .if * > USSHUT_END+1
        ert 'us_open outgrew USSHUT_BASE..USSHUT_END (memory_map.inc)'
    .endif
        org usop_resume
