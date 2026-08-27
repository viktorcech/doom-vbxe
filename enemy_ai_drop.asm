; Part of enemy_ai.asm -- AUTO-SPLIT out of it 2026-08-09 -- assembled in place via icl at the
; exact point the text was cut from, so every org and every block guard below is
; unchanged (verified: build/doom_bsp.xex is byte-identical).
;   P_KillMobj's dropped ammo, give_bonus, spr_take/drop (DROP_BASE)
;==============================================================
; P_KillMobj's "Drop stuff" -- the two kinds that leave ammo behind.
;==============================================================
        org DROP_BASE

;--------------------------------------------------------------
; en_dropmark -- Y = the thing that just died, en_kind = its kind. Flags the
;   corpse as carrying a dropped item, for spr_pickup to hand over.
;--------------------------------------------------------------
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
        ldy ai_t2
?out    rts
.endp

;--------------------------------------------------------------
; en_seen -- X = vissprite. Z=0 if the thing is actually VISIBLE in the centre
;   column of the view, i.e. the shot can reach it.
;
;   Why: en_shoot picks its target on the HORIZONTAL span alone, so without this
;   a monster behind a door that was still closing stayed shootable -- the door
;   narrows ytopc/ybotc but does not mark the columns solid until it is fully
;   shut, so the thing was still a vissprite and the hitscan took it.
;
;   The test uses the clip snapshot spr_add already took: 2 bytes (top, bottom)
;   per column at CLIP_BASE + (vs_cpl & $FE), stepped by 2 -- or ONE pair for
;   the whole sprite when vs_cpl bit0 says the window was uniform. top = 255
;   means nearer geometry closed that column outright.
;
;   2026-08-01, THE HEIGHT BUG: this used to ask whether the opening covered the
;   CROSSHAIR ROW (the horizon, view/2) instead of where the sprite actually is.
;   That silently made everything standing higher than the eye unkillable: a
;   step up sets the window bottom to the BACK sector's floor row (seg_draw.asm,
;   nb16 = min(nb16, pybf16)), and a floor above zp_pz (= floor + EYE_H 41)
;   projects ABOVE the horizon -- so wbot < crosshair and the shot was dropped
;   even though the barrel or the imp on that ledge was in plain sight. It cut
;   the other way too: firing DOWN through an opening whose ceiling is below eye
;   level put wtop below the crosshair and lost the shot the same way.
;
;   What it does now is p_map.c's rule, in screen space. PTR_AimTraverse clips
;   the aim to the line opening and then keeps the thing if ANY part of it is
;   still inside that range ("shot over the thing" / "shot under the thing" are
;   the only two rejects); the port's window IS that opening, projected, so the
;   answer is the overlap of the sprite's rows with it:
;       ytop <= wbot   (not entirely below the opening -- the ledge case)
;   AND ybot >= wtop   (not entirely above it   -- the closing door)
;   ytop is vs_ytl/vs_yth (signed 16: negative = it starts above the screen),
;   ybot the byte spr_add clamped into vs_ybt. Both are the whole sprite IMAGE,
;   margins included, which is the same box the billboard draws.
;--------------------------------------------------------------
    .if * > DROP_END+1
        ert 'en_dropmark outgrew DROP_BASE..DROP_END (memory_map.inc)'
    .endif
        org ESEEN_BASE               ; 2026-08-11 win2 evacuation: the drop block
                                     ;   split four ways (memory_map.inc)
.proc en_seen
        lda vs_cpl,x
        and #$FE                     ; the block, 2 B aligned (bit0 = uniform)
        sta zp_tmp
        lda #>CLIP_BASE
        sta zp_tmp+1
        lda vs_cpl,x
        and #1
        bne ?read                    ; one window for every column -> offset 0
        lda vs_x1h,x                 ; xa = max(x1, 0), as spr_one rebuilds it
        bmi ?xa0
        lda vs_x1l,x
        jmp ?off
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
        clc
        adc zp_tmp
        sta zp_tmp
        bcc ?read
        inc zp_tmp+1
?read   ldy #0
        lda (zp_tmp),y               ; window top
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
.endp

;--------------------------------------------------------------
; en_aimcol -- roll P_GunShot's INACCURATE aim into en_col. Parked in the DROP
;   block's slack beside en_seen, the only other reader of en_col; the ENINIT
;   block that owns en_gunshot has ~30 B left and this is one call per pellet,
;   i.e. as cold as everything else in here.
;
;   DOOM: `angle += (P_Random() - P_Random()) << 18` on a 32-bit angle_t. A
;   column is SCREEN_HALF + SCREEN_HALF*tan(theta) (SCREEN_HALF IS the focal
;   length at 90 deg), so for the triangular roll r = -255..255 the offset is
;       80 * tan(2*pi * r/16384)  =  r * 80/2600  =  r/32.5
;   -- 2600 at the wide end, 2608 as theta -> 0, the same shape as ai_fire's 620
;   for its <<20. >>5 is 32: 1.6% wide, a fifth of a column at full deflection.
;
;   ROUNDED, not shifted. A bare >>5 is a FLOOR, and a floor of a signed roll
;   biases the whole cone half a column LEFT -- E[offset] = -0.5, so the
;   crosshair sits on the edge of the peak bucket instead of in the middle of
;   it, and a shotgun blast pulls left every time. +16 before the shift is
;   round-to-nearest and puts the mean back on the crosshair (verified in
;   tools/_verify_gunspread.py: -0.5 -> +0.016 columns).
;
;   No sign-extend needed either. r+16+256 is 256*C + (lo+16) with C = the
;   borrow out of the subtract, so >>5 of it is 8*(C + the carry out of lo+16)
;   plus (lo+16)&255 >> 5 -- the 256s are whole multiples of 32. And when that
;   second carry fires, lo+16 is 256..271, whose low byte shifts to 0, so the
;   term is just 8. Taking the +256 back off is the -8 in the base.
;   Range 72..88. Clobbers A/X and en_t.
;--------------------------------------------------------------
    .if * > ESEEN_END+1
        ert 'en_seen outgrew ESEEN_BASE..ESEEN_END (memory_map.inc)'
    .endif
        org EAIM_BASE
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
        bcc ?sh
        lda #8                       ; carried out -> the shift would give 8 flat
        bne ?fin                     ; (always: A = 8)
?sh     lsr
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
                                     ;   shotgun 19% pellet loss at 512 units where
                                     ;   DOOM has 36% (tools/_verify_gunspread.py).

;--------------------------------------------------------------
; give_bonus -- Y = bonus id. Applies it to PSTATE; C=1 if it was used, C=0 if
;   it could not be (already at the cap), in which case the caller leaves the
;   item on the floor. Moved here from sprites.asm's $0600 hole -- see there.
;   MF_DROPPED (bn_drop) halves the amount, which is p_inter.c's
;   P_GiveAmmo(am_clip, 0) = clipammo[]/2: an enemy's clip is 5, not 10.
;--------------------------------------------------------------
    .if * > EAIM_END+1
        ert 'en_aimcol outgrew EAIM_BASE..EAIM_END (memory_map.inc)'
    .endif
        org GB_BASE
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
        bcs ?no                      ; already full -> not usable
        clc
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
?power  jmp pw_give                  ; C and Y come back from there
?bits   cpy #22                      ; 16-21 = a WEAPON: ONE routine does all of
        bcc wp_give                  ;   P_GiveWeapon (the owned bit, the ammo,
                                     ;   the raise) and answers C from there, so
                                     ;   the sound, the gold flash and thing_kill
                                     ;   all follow `gaveweapon || gaveammo`
                                     ;   instead of a blanket "taken". It used to
                                     ;   be spread over this branch, wp_give and
                                     ;   pickup_bonus, and no one of the three
                                     ;   could see the whole answer (2026-08-11)
        lda BN_AMT,y                 ; 22-24 = a key: a bit set, always taken and
        ora PSTATE+PS_KEYS           ;   never halved by MF_DROPPED. Absolute, not
        sta PSTATE+PS_KEYS           ;   PSTATE,x -- X only ever held PS_KEYS here
        sec
        rts
?no     clc
        rts
.endp

;--------------------------------------------------------------
; wp_give -- P_GiveWeapon (p_inter.c), THE WHOLE OF IT IN ONE PLACE. Tail-called
;   by give_bonus's bit-set branch and by nothing else.
;   IN:  Y = bonus id 16..21 (BN_AMT[y] is that weapon's bit, i.e. 1<<wp_*).
;   OUT: C = p_inter.c's `gaveweapon || gaveammo`. C=0 means NOTHING was given,
;        so snd_bonus stays silent and spr_take leaves the thing on the floor --
;        the same refusal P_TouchSpecialThing makes. Y is preserved: snd_bonus
;        picks the pickup SFX from the bonus id after give_bonus returns.
;   A found weapon comes with TWO clips of its ammo, one if an enemy dropped it
;   -- clipammo[] = 10/4/20/1, so 20/8/40/2 found and half that dropped. A
;   weapon with no art still banks its ammo.
;
;   THE TWO RULES THE SPLIT VERSION BROKE (2026-08-11, "when I already have the
;   gun it must not pop up again, and on full ammo I should not pick it up"):
;     * `if (player->weaponowned[weapon]) gaveweapon = false; else { ...;
;       player->pendingweapon = weapon; }` -- the raise belongs to the FIRST
;       pickup only. This used to end in an unconditional `jmp wp_select`, so
;       every duplicate shotgun lowered and raised the gun in your hands.
;     * P_GiveAmmo's first line after the type check is
;       `if (player->ammo[ammo] == player->maxammo[ammo]) return false`, so a
;       gun the player already owns, walked over with that counter FULL, gives
;       nothing at all and the pickup is refused whole -- idkfa and the shotgun
;       on E1M1 stays lying there. This used to answer a blanket "taken" with
;       the ammo never looked at, so the thing vanished and the sound played
;       for nothing.
;   gaveammo needs no flag byte: the clamp below already has the new counter in
;   A, and a clamped total is never BELOW what was there, so one compare against
;   the old value before the store says whether anything moved -- and it leaves
;   exactly the carry the tail wants (moved -> C=1, Z=0). The only other way out
;   of the ammo half is am_noammo, and that one clears it by hand.
;   The bytes came out of spr_take's *8 below, not out of another block: this
;   one is win1 and stays win1. Checked against p_inter.c over all 572
;   (weapon, owned, counter, MF_DROPPED, backpack) cases, on the shipped bytes
;   and through snd_bonus, by tools/tests/_verify_wpgive.py.
;--------------------------------------------------------------
.proc wp_give
        lda PSTATE+PS_WEAPONS        ; DID THIS PICKUP ADD ANYTHING? the set with
        ora BN_AMT,y                 ;   this weapon in it, EORed with the set
        tax                          ;   before -> the bit we actually added, and
        eor PSTATE+PS_WEAPONS        ;   ZERO means the player already owned it
        sta bn_qty                   ;   (p_inter.c's `gaveweapon`). bn_qty is
        stx PSTATE+PS_WEAPONS        ;   free on this path: only the COUNTER
                                     ;   branch of give_bonus reads it
        tya
        pha                          ; the bonus id, for Y on the way out
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
                                     ;   gun in your hands. A weapon that WAS new
                                     ;   is taken whatever the ammo did -- and
                                     ;   wp_select hands the carry back clobbered
?fin    pla
        tay                          ; the bonus id back in Y for snd_bonus
        rts                          ; C = gaveweapon || gaveammo
.endp

;--------------------------------------------------------------
; spr_take -- spr_pickup found something under the player: sp_ptr = its record,
;   sp_i = its index, sp_pick = which flag bit matched. Lives here because
;   adding the second path pushed spr_pickup past its block.
;--------------------------------------------------------------
.proc spr_take
        lda sp_pick
        and #F_DROP
        bne spr_drop                 ; a corpse's ammo: no sprtab id, no kill
        lda #0                       ; sprite id -> its sprtab entry -> bonus id.
        sta m_prod+1                 ;   id*8 (8 B records) in A:m_prod+1, NOT two
        ldy #6                       ;   zp bytes shifted three times each: the low
        lda (sp_ptr),y               ;   half never leaves the accumulator, and it
        asl                          ;   is the adc's operand already. -7 B, which
        rol m_prod+1                 ;   is where wp_give's ammo refusal above came
        asl                          ;   from -- the block is full to the byte and
        rol m_prod+1                 ;   nothing was going to move out of win1
        asl
        rol m_prod+1
        clc
        adc th_sprtab
        sta sp_tab
        lda m_prod+1
        adc th_sprtab+1
        sta sp_tab+1
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

;--------------------------------------------------------------
; spr_drop -- the player is standing on a corpse that carries a drop.
;   sp_ptr = its record, sp_i = its index. The BODY is not removed -- only the
;   drop bit is cleared, so you cannot farm the same zombieman twice.
;--------------------------------------------------------------
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
        ldx #0
        stx bn_drop                  ; (ldx/stx leave C alone)
        bcc ?out                     ; ammo full -> leave it on the body
        lda sp_i                     ; rebuild sp_ptr: pickup_bonus reaches into
        jsr en_thing.en_th2          ;   wp_give/wp_select and must not be
        ldy #7                       ;   trusted to have left it alone
        lda (sp_ptr),y
        and #255-F_DROP
        sta (sp_ptr),y
?out    rts
.endp

;--------------------------------------------------------------
; pl_armset -- P_GiveArmor's other half: Y = the bonus id give_bonus just
;   applied (5 = the +1 armour bonus, 6 = green, 7 = blue) -> pl_armt.
;   The POINTS are give_bonus's business (BN_AMT/BN_MAX already give DOOM's
;   100/200 caps and refuse a green suit at 100+); this is only the TYPE, which
;   is what pl_armsub reads to decide the share -- 1/3 green, 1/2 blue.
;   An armour BONUS keeps the type it finds: "if (!armortype) armortype = 1".
;   Parked at PLARM_BASE (the tail en_ovkill's move freed in the ENGIB block):
;   folding all of P_GiveWeapon into wp_give needed the bytes here, and this is
;   the coldest thing in the block -- three armour pickups a level.
;--------------------------------------------------------------
plarm_resume = *
        org PLARM_BASE
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
    .if * > PLARM_END+1
        ert 'pl_armset outgrew PLARM_BASE..END (memory_map.inc)'
    .endif
        org plarm_resume

    .if * > GB_END+1
        ert 'give_bonus..wp_give outgrew GB_BASE..GB_END (memory_map.inc)'
    .endif

