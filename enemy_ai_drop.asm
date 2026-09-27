;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): P_KillMobj's dropped ammo, give_bonus,
;   spr_take/drop.
;--------------------------------------------------------------

;--------------------------------------------------------------
; en_dropmark -- Y = the thing that just died, en_kind = its kind. Flags the
;   corpse as carrying a dropped item, for spr_pickup to hand over.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_dropmark
        lda en_kind
        cmp #MK_POSS                 ; zombieman -> MT_CLIP
        beq ?mark
        cmp #MK_SPOS                 ; shotgun guy -> MT_SHOTGUN
        bne ?out
?mark   sty ai_t2                    ; en_th2 clobbers Y
        tya
        jsr en_thing.en_th2          ; sp_ptr = its record
        ldy #7
        lda (sp_ptr),y
        ora #F_DROP
        sta (sp_ptr),y
                                      ; 2026-09-22 idiom: pk_dropadd inlined (the tail
        lda ai_t2                    ;   jmp went: -3) ...and the pickup list must
        jsr pk_append                ;   learn the corpse (sp_ptr = its record)
        ldy ai_t2
        rts
                                     ;   corpse (sp_ptr = its record; restores
                                     ;   Y and returns): spr_pickup walks the
                                     ;   LIST now, not the whole thing table.
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; en_seen -- X = vissprite. Z=0 if the thing is actually VISIBLE in the centre
;   column of the view, i.e. the shot can reach it.
;--------------------------------------------------------------
                                     ;   split four ways (memory_map.inc)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_seen
        ldy #>CLIP_BASE
        sty zp_tmp+1
        lda vs_cpl,x
        lsr                          ; bit0 = uniform -> C, the block/2 in A
        bcs ?uni                     ; one window for every column -> offset 0
        asl                          ; the block, 2 B aligned (bit 0 clear)
        sta zp_tmp
        lda vs_x1h,x                 ; xa = max(x1, 0), as spr_one rebuilds it
        bmi ?xa0
        lda vs_x1l,x
        bra ?off
?xa0    lda #0
?off    sta en_t                     ; (aim column - xa) * 2 -- the window this
        sec                          ;   sprite snapshotted for the column being
        lda vs_xb,x                  ;   shot at. en_shoot accepts the whole aim
        sbc en_t                     ;   CELL (en_col-1 .. en_col+1, see there),
        sta en_t+1                   ;   so en_col itself can sit one column OFF
        sec                          ;   the sprite -- clamp into [xa..xb] rather
        lda en_col                   ;   than index past the block, or a far thing
        sbc en_t                     ;   would answer out of the NEXT sprite's
        bcs ?hi                      ;   window (or skip the test outright) and
        lda #0                       ;   take the shot through a wall
        beq ?idx                     ; (always)
?hi     cmp en_t+1
        bcc ?idx
        lda en_t+1
?idx    asl
        bcs ?yes                     ; > 127 columns in: cannot happen, be safe
                                      ; 2026-09-23: the offset rides in Y -- (zp),y does
        tay                          ;   the carry into the page the add/inc did
?read   lda (zp_tmp),y
        cmp #255
        beq ?no                      ; column fully closed by nearer geometry
        sta en_t                     ; en_t = wtop
        iny
        lda (zp_tmp),y
        sta en_t+1                   ; en_t+1 = wbot
        lda vs_yth,x                 ; the sprite's first row, clamped to a byte
        bmi ?t0                      ;   (signed 16: < 0 = it starts above the
        beq ?tlo                     ;   screen, so 0; hi > 0 = below it, so 255)
        lda #255
        bne ?tcmp                    ; (always: A = 255)
?t0     lda #0
        beq ?tcmp                    ; (always: A = 0)
?tlo    lda vs_ytl,x
?tcmp   cmp en_t+1                   ; ytop > wbot -> ALL of it is below the
        beq ?bot                     ;   opening: the thing stands on a ledge
        bcs ?no                      ;   whose lip closed the column under it,
?bot    lda vs_ybt,x                 ;   or it is sunk in a pit
        cmp en_t                     ; ybot < wtop -> all of it is above the
        bcc ?no                      ;   opening (the door that came down)
?yes    lda #1
        rts
?no     lda #0
        rts
?uni    asl                          ; (the uniform block: bit 0 back to 0, offset 0)
        sta zp_tmp
        ldy #0
        bra ?read
.endp
        .endseg

;--------------------------------------------------------------
; en_aimcol -- roll P_GunShot's INACCURATE aim into en_col. Parked in the DROP
;   block's slack beside en_seen, the only other reader of en_col; the ENINIT
;   block that owns en_gunshot has ~30 B left and this is one call per pellet,
;   i.e. as cold as everything else in here.
;   Range 72..88. Clobbers A/X and en_t.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_aimcol
        lda RANDOM                   ; POKEY's LFSR, this port's P_Random
        sta en_t
        lda RANDOM
        sec
        sbc en_t                     ; r, with C=1 when it came out >= 0
        ldx #SCREEN_HALF-8           ; r < 0: the left half of the cone
        bcc ?add
        ldx #SCREEN_HALF             ; r >= 0: the right half
?add    clc
        adc #16                      ; round to the nearest column
                                      ; 2026-09-23: the 9-bit sum >> 5 -- ror brings the
        ror                          ;   carry in (a carry means a low byte < 16, so
                                     ;   the old flat 8 is exactly this)
        lsr
        lsr
        lsr
        lsr
?fin    stx en_t
        clc
        adc en_t
        sta en_col
        sta en_cl                    ; a rolled column has NO aim cell: the cell
        sta en_ch                    ;   compensates the 256-angle grid the player
        rts                          ;   aims on, and a pellet's angle is random
.endp                                ;   anyway. Widening it here would hand the
        .endseg
                                     ;   shotgun 19% pellet loss at 512 units where
                                     ;   DOOM has 36% (tools/_verify_gunspread.py).

;--------------------------------------------------------------
; give_bonus -- Y = bonus id. Applies it to PSTATE; C=1 if it was used, C=0 if
;   it could not be (already at the cap), in which case the caller leaves the
;   item on the floor. Moved here from sprites.asm's $0600 hole -- see there.
;   MF_DROPPED (bn_drop) halves the amount, which is p_inter.c's
;   P_GiveAmmo(am_clip, 0) = clipammo[]/2: an enemy's clip is 5, not 10.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc give_bonus
        lda BN_AMT,y
        ldx bn_drop
        beq ?amt
        lsr
?amt    sta bn_qty
        ldx BN_STAT,y
        cpx #9
        bcs ?power                   ; 9 = a POWER (ids 25..31, powerups.asm)
        cpx #8
        bcs ?bits
        lda BN_MAX,y                 ; the cap, once: with a backpack every AMMO
        cpy #BN_CLIP                 ;   cap doubles (ids 8..15) and health and
        bcc ?cap0                    ;   armour do not (P_GiveBackpack touches
        cpy #16                      ;   maxammo[] alone)
        bcs ?cap0
        jsr pw_max
?cap0   sta bn_cap
        lda PSTATE,x                 ; counters: health/armor/ammo
        cmp bn_cap
        bcs ?no                      ; already full -> not usable (C = 0 past it)
        adc bn_qty
        bcs ?cap                     ; wrapped a byte
        cmp bn_cap
        bcc ?set
?cap    lda bn_cap
?set    sta PSTATE,x
        cpx #PS_ARMOR                ; the armour ids (5 bonus, 6 green, 7 blue)
        bne ?done                    ;   carry a TYPE as well as points -- and the
        jsr pl_armset                ;   type is what decides how much of a hit it
?done   sec                          ;   eats (P_GiveArmor, p_inter.c:254)
        rts
?power  jmp pw_map                   ; C and Y come back from there. pw_map is
                                     ;   pw_give with the Computer Map leg in ...
?bits   cpy #22                      ; 16-21 = a WEAPON: ONE routine does all of
        bcc wp_give                  ;   P_GiveWeapon (the owned bit, the ammo,
                                     ;   the raise) and answers C from there, so ...
        lda BN_AMT,y                 ; 22-24 = a key: a bit set, always taken and
        ora PSTATE+PS_KEYS           ;   never halved by MF_DROPPED. Absolute, not
        sta PSTATE+PS_KEYS           ;   PSTATE,x -- X only ever held PS_KEYS here
        ;sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; wp_give -- P_GiveWeapon (p_inter.c), THE WHOLE OF IT IN ONE PLACE. Tail-called
;   by give_bonus's bit-set branch and by nothing else.
;   IN:  Y = bonus id 16..21 (BN_AMT[y] is that weapon's bit, i.e. 1<<wp_*).
;   OUT: C = p_inter.c's `gaveweapon || gaveammo`. C=0 means NOTHING was given,
;        so snd_bonus stays silent and spr_take leaves the thing on the floor --
;        the same refusal P_TouchSpecialThing makes. Y is preserved: snd_bonus
;        picks the pickup SFX from the bonus id after give_bonus returns.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wp_give
        lda PSTATE+PS_WEAPONS        ; DID THIS PICKUP ADD ANYTHING? the set with
        ora BN_AMT,y                 ;   this weapon in it, EORed with the set
        tax                          ;   before -> the bit we actually added, and
        eor PSTATE+PS_WEAPONS        ;   ZERO means the player already owned it
        sta bn_qty                   ;   (p_inter.c's `gaveweapon`). bn_qty is
        stx PSTATE+PS_WEAPONS        ;   free on this path: only the COUNTER
                                     ;   branch of give_bonus reads it
                                      ; 2026-09-22 (drac030): phy ... ply
        phy                          ; the bonus id, for Y on the way out
        tya                          ;   (and #7 below needs it in A too)
        and #7                       ; 16..21 -> 0..5 (the ids are $10..$15, so
        tax                          ;   the mask is the subtraction, one byte up)
        lda wi_ofbonus,x             ; bonus id -> wp_*
        tax
        ldy wi_ammo,x
        bmi ?nog                     ; am_noammo (chainsaw): the gun is all it is
        lda wi_amax,x                ; the backpack doubles maxammo[] here too
        jsr pw_max                   ;   (and it preserves X and Y)
        sta bn_cap
        lda wi_give,x                ; "one clip with a dropped weapon, two with
        bit bn_drop                  ;   a found one". BIT and not `ldy bn_drop`:
        bpl ?amt                     ;   the flag is $80 (memory_map.inc) so bit7
        lsr                          ;   answers it and Y stays on the counter
?amt    clc
        adc PSTATE,y
        bcs ?cap                     ; wrapped a byte
        cmp bn_cap
        bcc ?put
?cap    lda bn_cap
?put    cmp PSTATE,y                 ; DID THE COUNTER MOVE? equal = it was already
        sta PSTATE,y                 ;   at the cap, i.e. P_GiveAmmo's `return
        bne ?ans                     ;   false` -- and the compare that says it did
                                     ;   move leaves C=1, which IS gaveammo
?nog    clc                          ; the ammo gave nothing (full, or am_noammo)
?ans    lda bn_qty                   ; already owned -> NO raise: p_inter.c sets
        beq ?fin                     ;   pendingweapon only for a weapon you did
        txa                          ;   not have. This used to be an
        jsr wp_select                ;   unconditional `jmp wp_select`, so every
        sec                          ;   duplicate shotgun lowered and raised the
                                     ;   gun in your hands.
?fin    ply                          ; the bonus id back in Y for snd_bonus
        rts                          ; C = gaveweapon || gaveammo
.endp
        .endseg

;--------------------------------------------------------------
; spr_take -- spr_pickup found something under the player: sp_ptr = its record,
;   sp_i = its index, sp_pick = which flag bit matched. Lives here because
;   adding the second path pushed spr_pickup past its block.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_take
        lda sp_pick
        and #F_DROP
        bne spr_drop                 ; a corpse's ammo: no sprtab id, no kill
        ldy #6                       ; sprite id -> its sprtab entry -> bonus id:
        lda (sp_ptr),y               ;   id*8 (8 B records) + th_sprtab, all in a
        rep #$20                     ;   16-bit A (an id is a byte: the asl's
        .LONGA ON                    ;   carry out 0, the adc needs no clc)
        and #$FF
        asl @
        asl @
        asl @
        adc th_sprtab
        sta sp_tab
        sep #$20
        .LONGA OFF
        ldy #7
        lda (sp_tab),y
        beq ?out                     ; no bonus behind this sprite
        tay
        jsr pickup_bonus             ; snd_bonus + the HUD repaint / grin marks
        bcc ?out                     ; could not be used now -> leave it lying
        ldx sp_i
        jmp thing_kill
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_drop -- the player is standing on a corpse that carries a drop.
;   sp_ptr = its record, sp_i = its index. The BODY is not removed -- only the
;   drop bit is cleared, so you cannot farm the same zombieman twice.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_drop
        ldy sp_i
        lda #<TH_KIND
        sta zp_ptr
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp #MK_POSS
        bne ?spos
        ldy #BN_CLIP                 ; 5 bullets once MF_DROPPED halves it
        bne ?give                    ; (8, never 0)
?spos   cmp #MK_SPOS
        bne ?out
        ldy #BN_SHOTGUN              ; the gun + 4 shells, not 8
?give   lda #$80                     ; $80 and not 1: wp_give tests this with BIT
        sta bn_drop                  ;   (see there), give_bonus with a plain BEQ
        jsr pickup_bonus             ; C=1 = it was usable
        stz bn_drop                  ; (stz leaves C alone)
        bcc ?out                     ; ammo full -> leave it on the body
        lda sp_i                     ; rebuild sp_ptr: pickup_bonus reaches into
        jsr en_thing.en_th2          ;   wp_give/wp_select and must not be
        ldy #7                       ;   trusted to have left it alone
        lda (sp_ptr),y
        and #255-F_DROP
        sta (sp_ptr),y
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pl_armset -- P_GiveArmor's other half: Y = the bonus id give_bonus just
;   applied (5 = the +1 armour bonus, 6 = green, 7 = blue) -> pl_armt.
;--------------------------------------------------------------
plarm_resume = *
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_armset
        tya
        sec
        sbc #5                       ; 5 -> 0 (bonus), 6 -> 1, 7 -> 2
        bne ?put
        lda pl_armt
        bne ?out
        lda #1
?put    sta pl_armt
?out    rts
.endp
        .endseg
        org plarm_resume

    .if * > GB_END+1
        ert 'give_bonus..wp_give outgrew GB_BASE..GB_END (memory_map.inc)'
    .endif

