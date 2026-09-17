;==============================================================
; music.asm -- the intermission song as a stream of POKEY register writes.
;
; NOT an RMT player. The RMT player is 1178 B (measured off
; mads-src/players/rmt_player_relocator/example/_rmt_player_demo.obx, segments
; $3182/$3200/$3300) and the biggest contiguous free block in this machine is
; 173 B, so it could only live in the MENU_RUN overlay window -- which the
; intermission's OWN overlay already occupies. tools/pack_musstream.py settled
; this from the start: "the player runs HERE instead, once, at build time".
; RMT stays the authoring format (mus/D_INTER.rmt, editable in the tracker);
; what ships is the register stream it renders to.
;
; THE STREAM (tools/pack_musstream.py encode()), per frame:
;     mask byte -- bit n set = register $D200+n changed this frame
;     values    -- one byte per set bit, low bit first
;     $FF       -- end of song; mus_play loops back to the start
; A frame that changes nothing is one zero byte, which is why 202 s of music
; is 29,714 B.
;
; CHANNEL 1 IS NEVER WRITTEN. Bits 0 and 1 of the mask are never set, because
; pack_musstream seeds its `prev` with 0 for $D200/$D201: AUDF1 is the divisor
; sound.asm's Timer-1 digi mixer clocks itself with, and while that IRQ is
; enabled channel 1 cannot be deferred (Altirra pokey.cpp), so a note there
; multiplies POKEY's event rate. The music gets $D202-$D207 -- three voices.
; AUDCTL is not in the stream either; it must stay 0 for the same mixer.
;==============================================================
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
;   bank MUS_BANK0, offset 0. A straight copy of load_weapons (diskio.asm):
;   read_ext carries ll_dst/ll_sec forward, and ll_dst wrapping to 0 between
;   chunks is how the run detects it crossed into the next 64 KB bank -- which
;   is why pack_musstream puts the songs at a BANK-ALIGNED MUS_BANK0:0000 and
;   not at the first free SDRAM byte.
;   Boot path: ROM is in and the CPU is in emulation mode here, so this stays
;   8-bit throughout (no rep/sep -- they are no-ops with E=1).
;   2026-09-16: and then a SECOND walk, WIM_CHUNKS into WIMAP_BANK:0000 -- the
;   episode 2/3 intermission world maps (tools/pack_wi.py wimaps.bin, wi.asm
;   wi_bgsel). make_atr_doom.py lays them down right behind the songs, so
;   ll_sec is already there when the first walk ends.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_music
        lda #<MUS_SEC1
        sta ll_sec
        lda #>MUS_SEC1
        sta ll_sec+1
        lda #MUS_BANK0               ; A = bank, X = chunks, offset 0 of it
        ldx #MUS_CHUNKS
 .if WIM_CHUNKS > 0
        jsr ?run                     ; the songs...
        lda #WIMAP_BANK              ; ...then the world maps, the next region
        ldx #WIM_CHUNKS              ;   on the disk
 .endif
?run    sta ll_bank
        stx mus_i
        stz ll_dst
        stz ll_dst+1
?chunk  lda #32                      ; one 4 KB chunk per read_ext pass
        sta ll_left
        jsr read_ext
        lda ll_dst
        ora ll_dst+1
        bne ?same
        inc ll_bank
?same   dec mus_i
        bne ?chunk
        lda #MAP_EXT_BANK            ; put ll_bank back the way load_weapons
        sta ll_bank                  ;   does -- load_dtab/load_los assume it
        rts
.endp
        .endseg
mus_i    dta 0                       ; load_music chunk counter
    .if * > MUSICLD_END+1
        ert 'load_music outgrew MUSICLD_BASE..END (memory_map.inc)'
    .endif
    .if [WIM_CHUNKS > 0] .and [WIM_SEC1 != MUS_SEC1+MUS_CHUNKS*32]
        ert 'load_music reads the world maps on from the songs: WIM_SEC1 must follow MUS'
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
                                     ;   allocator: every effect on this screen
                                     ;   plays on channel 1, which the song does
                                     ;   not use anyway
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
                                     ;   touching wi_pre). Without this gate the
                                     ;   first melt of every level plays from a
                                     ;   garbage mus_p: zp_sptr is whatever the
                                     ;   last BSP walk left in it.
        lda [mus_p]                  ; the mask
        jsr mus_adv
        cmp #$FF                     ; end of song?
        beq ?loop
        sta mus_mask
        ldx #0                       ; X = register index: $D200 + X
?bit    lsr mus_mask                 ; bit 0 first, so X walks up with it
        bcc ?next
        lda [mus_p]
        jsr mus_adv                  ; consume the value byte EITHER WAY (A is
                                     ;   untouched by mus_adv), so the cursor
                                     ;   never desyncs from the mask
        cpx #2                       ; CHANNEL 1 IS NEVER TOUCHED. pack_musstream
        bcc ?next                    ;   seeds prev[0..1] = 0, so bits 0-1 are
                                     ;   never set in a well-formed stream -- but
                                     ;   AUDF1 is the digi IRQ's Timer-1 divisor
                                     ;   and one stray write retunes the whole
                                     ;   mixer. Dropping the STORE and not the
                                     ;   byte is what keeps the cursor aligned.
        sta mus_shad-2,x             ; into the SHADOW, not into POKEY
?next   inx
        cpx #8
        bne ?bit

        ; ---- RE-ASSERT EVERY FRAME ---------------------------------------
        ; The stream is a DELTA stream: a register that does not change carries
        ; no byte, and stretches of 20+ unchanged frames are normal. POKEY is
        ; not ours alone across a level boundary, so the shadow is re-sent every
        ; frame rather than trusted to still be in the chip. mus_reset has taken
        ; channels 2/3/4 off the SFX allocator (snd_vmax), so nothing else
        ; writes them while this runs -- which is what finally gave three voices
        ; instead of one or two.
?emit   ldy #4                       ; register pair: 4 = ch4, 2 = ch3, 0 = ch2
?e      lda mus_shad,y
        sta AUDF1_R+2,y              ; AUDF
        lda mus_shad+1,y
        sta AUDF1_R+3,y              ; AUDC
        dey
        dey
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
                                     ;   SND_VTOP normally, 0 while the song is
                                     ;   up. It lives HERE and not in sound.asm
                                     ;   because that file's data sits in the
                                     ;   pitch block, which has no spare byte --
                                     ;   and because SND_VTOP/snd_vtop would be
                                     ;   the SAME label: MADS is case-insensitive.
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
