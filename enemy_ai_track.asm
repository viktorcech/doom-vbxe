;--------------------------------------------------------------
; A chasing thing is drawn from the subsector it is ACTUALLY in (AI_DMAX side
;   table), not its packed spawn subsector -- else it gets a far clip window.
;   The table is a LIVE-chaser budget: when full, ai_evict takes a corpse's slot.
;--------------------------------------------------------------

;--------------------------------------------------------------
; ai_track -- ai_t = thing, zp_nid = the leaf locate_floor just reached. Insert
;   or refresh its entry. Called on every committed step and once on waking.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_track
        lda ai_t
        jsr ai_ischase
        beq ?add
        dex                          ; ai_ischase leaves X = slot+1
        bpl ?old                     ; (always)
?add    ldx ai_dn
        cpx #AI_DMAX
        bcs ?ev                      ; full -> take a corpse's slot instead
        inc ai_dn                    ; (X = the OLD count = the new slot)
        bcc ?st                      ; (always: the cpx left C=0)
?ev     jsr ai_evict
        bcc ?full                    ; AI_DMAX LIVE chasers: the spawn-leaf fallback
                                      ; 2026-09-23: ldy abs,x -- no lda/tay
?old    ldy ai_dsl,x                 ; the entry leaves its old gate bucket
        lda ai_dcnt,y
        dec @
        sta ai_dcnt,y
?st     lda ai_t
        sta ai_dth,x
        lda zp_nid
        sta ai_dsl,x
        tay                          ; ...and enters the new one
        lda ai_dcnt,y
        inc @
        sta ai_dcnt,y
        lda zp_nid+1
        and #$7F                     ; the leaf flag is not part of the id
        sta ai_dsh,x
?full   inc blk_dirty                ; it moved: the blockmap has to be rebuilt
        rts                          ;   before the next frame's move tests
.endp
        .endseg

;--------------------------------------------------------------
; ai_evict -- the table is full and a LIVE chaser wants in. Find a slot held by
;   a CORPSE and hand it over: C=1 and X = that slot, C=0 if all AI_DMAX of them
;   are still chasing (then the caller keeps today's spawn-subsector fallback).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_evict
                                      ; 2026-09-22 idiom: ai_bank inlined (see ai_look)
        stz zp_ptr                   ; zp_ptr = TH_WROW (bank $01)
        lda #>TH_WROW
        sta zp_ptr+1
                                      ; 2026-09-22 (6502-idioms: counting UP to zero):
        ldx #256-AI_DMAX             ;   X = slot + 256-AI_DMAX, the base says so, and
?lp     ldy ai_dth+AI_DMAX-256,x     ;   both exits hand the caller the slot as before
        lda [zp_ptr],y               ;   (ai_track reads X, then only C)
        beq ?got                     ; not chasing -> en_kill cleared it -> a body
        inx
        bne ?lp
        ldx #AI_DMAX                 ; (X as the old loop left it)
        clc                          ; every slot is a live chaser
        rts
?got    txa                          ; X back to the slot
                                      ; 2026-09-23: X >= 256-AI_DMAX, so this sbc cannot
        sec                          ;   borrow -- it leaves the C=1 the caller wants
        sbc #256-AI_DMAX
        tax
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_ischase -- A = thing index. Z=0 and X = slot+1 if it is tracked, Z=1 if it
;   is not. Called per thing in spr_add's prefix loop, so it stays a plain scan
;   over at most AI_DMAX bytes and the caller checks ai_dn first.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_ischase
        ldx ai_dn
                                      ; 2026-09-23: dex/bne closes the loop (no bra a
        beq ?no                      ;   pass), and both ways to ?no arrive with
?lp     cmp ai_dth-1,x               ;   X = 0 and Z = 1 already
        beq ?yes
        dex
        bne ?lp
?no     rts                          ; Z=1 = not tracked
?yes    txa                          ; X = slot+1, so it is never 0: Z=0 = tracked.
        rts                          ;   WITHOUT this the flag came from the CMP
.endp                                ;   above, which is Z=1 on a match -- the same
        .endseg
                                     ;   answer as "not found". spr_add's dedup then ...

;--------------------------------------------------------------
; spr_chase -- from spr_add, for the subsector in zp_nid: project every tracked
;   chaser standing in it. Same projection the prefix loop uses, so it needs the
;   same thing-record pointer and the same alive test.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_chase
        ldx zp_nid                   ; the gate: no entry shares this leaf's low
        lda ai_dcnt,x                ;   byte -> nothing to scan (most leaves)
        beq ?out
        ldx ai_dn
                                      ; 2026-09-23: zp_nid stays in A across the misses
?re     lda zp_nid                   ;   (reloaded only after a hit or a high miss)
?lp     dex
        bmi ?out
        cmp ai_dsl,x
        bne ?lp
        lda zp_nid+1
        and #$7F
        cmp ai_dsh,x
        bne ?re
        phx                          ; the scan cursor, across spr_proj
        lda ai_dth,x
        sta ai_t
        sta sp_i                     ; spr_proj reads the THING INDEX for vs_th
                                     ;   out of sp_i, and the hitscan aims by
                                     ;   vs_th.
        tax
        TALIVE                                ; a corpse is the prefix loop's business (inlined 2026-09-26)
        beq ?next
        lda ai_t
        jsr en_thing.en_th2          ; sp_ptr = the thing record
        ldy #7
        lda (sp_ptr),y
        and #F_DROP
        bne ?drop                    ; a body with its drop beside it
?proj   jsr spr_proj
?next   plx
        lda sp_n
        cmp #VIS_MAX
        bcc ?re
?out    rts
?drop   jsr spr_ditem                ; the item first (sprites.asm)
        bra ?proj
.endp
        .endseg
