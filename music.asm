;--------------------------------------------------------------
; music.asm -- the intermission song as a stream of POKEY register writes,
;   rendered at build time by tools/pack_musstream.py.
;--------------------------------------------------------------
        icl 'music_syms.inc'         ; MUS_BANK0/COUNT/BYTES + one equ per song
; The songs must sit ABOVE the SDRAM level cache: read_sectors' tee parks every
; cached ATR sector at PREn_BASE + (sec - PREn_SEC)*128 on its first drive
; read, and at $550000 (2026-09-11..13) that was E2M5's .sprcol slot -- the
; first E2M5 load wrote over the songs. Same guard SPRCOL_BANK has.
    .if [MUS_BANK0<<16] < PRE_END
        ert 'MUS_BANK0 sits inside the SDRAM level cache (atr_layout.inc PRE_END) -- raise pack_musstream.py MUS_BASE'
    .endif
    .if MUS_BANK0 = SPRCOL_BANK
        ert 'MUS_BANK0 is SPRCOL_BANK -- pack_musstream.py MUS_BASE'
    .endif
    .if [MUS_BANK0<<16]+[MUS_CHUNKS*4096] > $F00000
        ert 'the songs run past the Rapidus SDRAM ($EF:FFFF)'
    .endif

; mus_p -- the 24-bit read cursor. Long indirect needs DIRECT PAGE, and zero
; page here is FULL (the block at $80 in bsp_main.asm runs past $FF). So it
; aliases render-only scratch, exactly as paint.asm aliases zp_tsrc/mv_ss:
; zp_sptr is "-> current seg record", written by every BSP walk and read by
; nobody else. The stats screen runs no render_world at all, so the cell is
; dead for the whole time the music plays.
;   IF MUSIC EVER PLAYS DURING GAMEPLAY, THIS HAS TO MOVE. In the frame loop
;   zp_sptr is live on every seg.
mus_p    = zp_sptr

mus_resume = *
        org MUSICLD_BASE             ; the loader first, in its own hole
;--------------------------------------------------------------
; load_music -- MUS_CHUNKS x 4 KB from sector MUS_SEC1 into Rapidus SDRAM at
;   bank MUS_BANK0, offset 0.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_music
        lda #<MUS_SEC1               ; the songs: ONE DEFLATE stream too
        sta ll_sec                   ;   (2026-09-26) -- POKEY register runs
        lda #>MUS_SEC1               ;   pack to a quarter of their sectors
        sta ll_sec+1
        stz inf_out
        stz inf_out+1
        lda #MUS_BANK0
        sta inf_out+2
        jsr inflate
 .if WIM_CHUNKS > 0
        lda #<WIM_SEC1               ; ...then the world maps: the next
        sta ll_sec                   ;   stream, straight into their banks
        lda #>WIM_SEC1
        sta ll_sec+1
        stz inf_out
        stz inf_out+1
        lda #WIMAP_BANK
        sta inf_out+2
        jsr inflate
 .endif
        lda #MAP_EXT_BANK            ; put ll_bank back the way load_weapons
        sta ll_bank                  ;   used to -- load_dtab/load_los assume it
        rts
.endp
        .endseg
    .if * > MUSICLD_END+1
        ert 'load_music outgrew MUSICLD_BASE..END (memory_map.inc)'
    .endif
    .if [WIM_CHUNKS > 0] .and [WIM_SEC1 != MUS_SEC1+MUS_PAK_SECT]
        ert 'the world-map stream must follow the packed songs (make_atr_doom.py)'
    .endif
    .if [WIM_CHUNKS > 0] .and [WIMAP_BANK >= MUS_BANK0] .and [WIMAP_BANK <= MUS_BANK0+[[MUS_CHUNKS*4096-1]>>16]]
        ert 'WIMAP_BANK overlaps the songs (MUS_BANK0 + MUS_CHUNKS)'
    .endif

        org MUSIC_BASE               ; ...then the per-frame player



;--------------------------------------------------------------
; mus_reset -- A = song index (MUS_INTER). Point the cursor at its first frame.
;   music_tabs.inc holds the 24-bit SDRAM address of each song, split lo/mid/hi
;   so this is three indexed loads and no arithmetic.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mus_reset
        tax
        stx mus_cur                  ; remembered so the $FF marker can loop
        inc mus_on                   ; ...and arm mus_play (mus_stop disarms)
        stz snd_vmax                 ; and take channels 2/3/4 off the SFX
                                     ;   allocator: every effect on this screen ...
        lda mus_b0,x
        sta mus_p
        lda mus_b1,x
        sta mus_p+1
        lda mus_b2,x
        sta mus_p+2
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mus_adv -- mus_p++, 24-bit. A song is 29 KB so the middle byte carries often
;   and the bank byte carries once; both are handled here rather than at the
;   three call sites.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mus_adv
        inc mus_p
        bne ?d
        inc mus_p+1
        bne ?d
        inc mus_p+2
?d      rts
.endp
        .endseg

;--------------------------------------------------------------
; mus_play -- ONE frame. Call it once per VBLANK; the stream is authored at the
;   PAL frame rate, so one record = one frame and nothing here tracks time.
;   Preserves nothing but returns with X = 8.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mus_play
        lda mus_on                   ; ARMED? wi_melt calls wi_tic -- and so
        beq ?off                     ;   this -- BEFORE wi_pre has run mus_reset
                                     ;   (wi_head takes the melt entry without
                                     ;   touching wi_pre).
                                      ; 2026-09-23 (6502-idioms: stream bytes): Y walks the
        lda [mus_p]                  ;   record (<= 1+8 bytes; [dp],y carries into the
        cmp #$FF                     ;   bank itself) and the cursor moves ONCE, by the
        beq ?loop                    ;   record's length -- no jsr mus_adv a byte. At
        sta mus_mask                 ;   $FF mus_reset re-points it anyway
        ldy #1                       ; Y = the next value byte
        ldx #0                       ; X = register index: $D200 + X
?bit    lsr mus_mask                 ; bit 0 first, so X walks up with it
        bcc ?next
        lda [mus_p],y                ; consume the value byte EITHER WAY, so the
        iny                          ;   cursor never desyncs from the mask
        cpx #2                       ; CHANNEL 1 IS NEVER TOUCHED (bits 0-1: see
        bcc ?next                    ;   the .else)
        sta mus_shad-2,x             ; into the SHADOW, not into POKEY
?next   inx
        cpx #8
        bne ?bit
        tya                          ; mus_p += the record's length, 24-bit
        clc
        adc mus_p
        sta mus_p
        bcc ?emit
        inc mus_p+1
        bne ?emit
        inc mus_p+2

        ; ---- RE-ASSERT EVERY FRAME ---------------------------------------
        ; The stream is a DELTA stream: a register that does not change carries
        ; no byte, and stretches of 20+ unchanged frames are normal.
                                      ; 2026-09-22 (rapidus-bus-timing): X and long,x --
?emit   ldx #4                       ;   an abs,y store dummy-reads POKEY first (a chip
?e      lda mus_shad,x               ;   cycle), and there is no long,y. X is free here
        sta.l AUDF1_R+2,x            ;   (the ?bit loop spent it already).
        lda mus_shad+1,x
        sta.l AUDF1_R+3,x
        dex
        dex
        bpl ?e
        rts
?loop   lda mus_cur                  ; DOOM loops the intermission song for as
        jsr mus_reset                ;   long as the screen is up
        bra ?emit                    ; the shadow still wants re-asserting today
?off    rts
.endp
        .endseg

;--------------------------------------------------------------
; mus_stop -- silence the three voices. AUDC only: AUDF is left alone so the
;   next mus_play does not have to re-send a frequency the stream thinks is
;   already there.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mus_stop
        stz mus_on                   ; disarm first: wi_tic can still run after
                                     ;   this on the way out of the screen
        lda #SND_VTOP                ; give the SFX mixer its four voices back
        sta snd_vmax
        stz mus_shad+1               ; and blank the shadow's three AUDCs, so a
        stz mus_shad+3               ;   later mus_reset cannot re-assert the
        stz mus_shad+5               ;   note this screen died on
        stz AUDC1_R+2                ; AUDC2
        stz AUDC1_R+4                ; AUDC3
        stz AUDC1_R+6                ; AUDC4
        rts
.endp
        .endseg

    .if * > MUSIC_END+1              ; check the CODE before the org moves
        ert 'music.asm outgrew MUSIC_BASE..END (memory_map.inc)'
    .endif

        org MUSICDAT_BASE            ; the state and the song table live in
                                     ;   their own hole -- the player block is
                                     ;   140 B and the code fills it
snd_vmax dta SND_VTOP                ; snd_alloc's ceiling (doubled voice index).
mus_on   dta 0                       ; 0 = mus_play does nothing. Load-time zero
                                     ;   from the XEX, so the first melt of the
                                     ;   first level is already safe.
mus_mask dta 0                       ; the frame's mask, shifted as it is used
mus_cur  dta 0                       ; song index, for the loop at $FF
mus_shad dta 0,0,0,0,0,0             ; AUDF2,AUDC2,AUDF3,AUDC3,AUDF4,AUDC4 --
                                     ;   what the song WANTS POKEY to hold
        icl 'music_tabs.inc'         ; mus_b0/mus_b1/mus_b2
    .if * > MUSICDAT_END+1
        ert 'music.asm data outgrew MUSICDAT_BASE..END (memory_map.inc)'
    .endif

        org mus_resume
