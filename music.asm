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

; (mus_p, the cursor borrowed from zp_sptr, went 2026-10-06: the player runs
; from the VBLANK now and reads through mus_pos -- see mus_play.)
MUS_SKCTL  = $D20F                   ; POKEY's SKCTL (write); the second chip's is +$10
MUS_STIMER = $D209                   ; STIMER: start the timers
MUS_VCOUNT = $D40B                   ; ANTIC's line counter / 2

mus_resume = *
        org MUSICLD_BASE             ; the loader first, in its own hole
;--------------------------------------------------------------
; load_music -- MUS_CHUNKS x 4 KB from sector MUS_SEC1 into Rapidus SDRAM at
;   bank MUS_BANK0, offset 0.
;--------------------------------------------------------------
        .segment B1
.proc load_music
        ; 2026-10-15 ("v atari nemam stereo") -- one POKEY or two is con_msg's
        ; test (console.asm), before the dots. A MONO machine plays the mono set
        ; (pack_musstream.py): its stream, every sound effect panned RIGHT
        ; (side_tab: snd_irqb stores the right sum last, so on the one chip that
        ; sum stays), and its five song tables -- they ride behind the depacked
        ; split (MUSM_TAB) and go over mus_b0..mus_ac: no resident byte for them
        ; (.claude/skills/6502-idioms/SKILL.md, "Code size is RAM"; one count-to-
        ; zero loop, 6502-loops-tables-smc). The sector waits in X/Y: no branch
        ; over the other one.
        ldx #<MUS_SEC1               ; the songs: ONE DEFLATE stream too
        ldy #>MUS_SEC1               ;   (2026-09-26) -- of their SPLIT form since
        lda mus_mono                 ;   2026-10-06, depacked into the level cache
        beq ?st                      ;   (idle until a level loads) and woven into
        lda #$80                     ;   the player's stream by mus_join
        ldx #7                       ; right only ($D21x = $D20x here)
?sd     sta side_tab,x               ; (bank 0, DBR 0)
        dex
        bpl ?sd
        ldx #<MUSM_SEC1
        ldy #>MUSM_SEC1
?st     stx ll_sec
        sty ll_sec+1
        stz inf_out
        stz inf_out+1
        lda #[MUS_TMP>>16]
        sta inf_out+2
        jsr inflate
        jsr mus_join
        lda mus_mono
        beq ?wm
        ldx #5*MUS_COUNT
?tm     lda.l MUS_TMP+MUSM_TAB-1,x
        sta.l B1CODE_BASE+mus_b0-1,x
        dex
        bne ?tm
?wm
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

;--------------------------------------------------------------
; mus_join -- 2026-10-06 ("lepsia kompresia hudby"): the disk carries the songs
;   SPLIT (pack_musstream.py split) -- per song its records' masks as one run
;   and each register's values as a run of its own, the same bytes sorted, 28 %
;   fewer sectors packed. This weaves them back: MUS_TMP -> the stream at
;   MUS_BANK0, as tools/pack_musstream.py weave does.
;   A block: frames (word) | end mark | 16 run lengths (words) | masks | runs.
;   Boot only, bank $01 (native). Borrows inflate's zero page: inf_src the
;   block, inf_out the stream, inf_n the frames to go, inf_ws the block's size.
;   A block is under 64 KB (the packer checks): a 16-bit Y reaches all of it.
;   Skills: 65816-windows (one block for the whole run), 6502-cycles-layout
;   (the bank carry is a stub), 6502-idioms (the carry is tracked, no clc).
;--------------------------------------------------------------
MUS_TMP equ $100000                  ; in the SDRAM level cache's first range
    .if MUS_TMP < PRE0_BASE || MUS_TMP+MUS_SPLIT > PRE0_BASE+PRE0_CNT*128 || [MUS_TMP&$FFFF]
        ert 'MUS_TMP: the split songs depack inside the level cache range 0, from a bank start'
    .endif
.proc mus_join
        lda #[MUS_TMP>>16]           ; the two pointers' bank bytes, then their low
        sta inf_src+2                ;   words in the block (65816-windows: the rep
        lda #MUS_BANK0               ;   moved up over a lone 2-byte store)
        sta inf_out+2
        rep #$30                     ; ---- ONE 16-bit window, A and X/Y, to ?done
        .LONGA ON
        .LONGI ON
        stz inf_src
        stz inf_out
?song   lda [inf_src]                ; the song's frames; 0: no more songs
        beq ?done
        sta inf_n
        asl @
        adc #35                      ; (C = 0: frames < 32768) run 0, from the block
        ldx #0
        ldy #3                       ; the 16 lengths
?o      sta.l B1CODE_BASE+mus_cv,x   ; each run's cursor, an offset into the block
        adc [inf_src],y              ; (C = 0: the adc before it, then the bcc
        iny                          ;   taken -- no clc; a block is under 64 KB)
        iny
        inx
        inx
        cpx #32
        bcc ?o
        sta inf_ws                   ; ... and the block's size
        ldy #35                      ; Y: the masks' cursor
?frame  ldx #$FFFE                   ; POKEY1's record: runs 0-7 (?nx steps first)
        jsr ?rec
        ldx #14                      ; POKEY2's: runs 8-15
        jsr ?rec
        dec inf_n
        bne ?frame
        ldy #2
        sep #$20                     ; the song's end mark, ONE byte: nothing
        .LONGA OFF                   ;   behind the last song's may be written
        lda [inf_src],y
        sta [inf_out]
        rep #$21                     ; (C = 0)
        .LONGA ON
        inc inf_out
        bne ?e1
        jsr ?bank
?e1     lda inf_src                  ; the next block: the low word here, the bank
        adc inf_ws                   ;   byte 8-bit and out of line (rare)
        sta inf_src
        bcc ?song
        sep #$20
        .LONGA OFF
        inc inf_src+2
        rep #$20
        .LONGA ON
        bra ?song
?done   sep #$30
        .LONGA OFF
        .LONGI OFF
        rts
; a record: its mask, then the next value of every register the mask names.
;   16-bit all through. A store writes TWO bytes: the second is junk the next
;   store covers (the end mark above is the one that must not). IN: Y the
;   masks' cursor, X the first run's index - 2.
        .LONGA ON
        .LONGI ON
?rec    lda [inf_src],y
        iny
        and #$00FF                   ; the mask alone
        sta [inf_out]
        inc inf_out
        beq ?w1                      ; (6502-cycles-layout: the bank's carry is a stub)
?nx     inx
        inx
        lsr @                        ; C = this register's bit, Z = none above it
        bcs ?put
        bne ?nx
        rts
?put    pha                          ; the mask and the masks' cursor wait
        phy                          ;   (65816-style: on the stack)
        lda.l B1CODE_BASE+mus_cv,x   ; this register's run: its next value ...
        tay
        inc @
        sta.l B1CODE_BASE+mus_cv,x
        lda [inf_src],y
        sta [inf_out]                ; ... goes behind the mask
        inc inf_out
        beq ?w2
?p1     ply
        pla
        bne ?nx
        rts
?w1     jsr ?bank
        bra ?nx
?w2     jsr ?bank
        bra ?p1
?bank   sep #$20                     ; the stream crossed a bank: A, X, Y kept
        .LONGA OFF
        inc inf_out+2
        rep #$20
        .LONGA ON
        rts
        .LONGA OFF
        .LONGI OFF
.endp
mus_cv  :32 dta 0                    ; mus_join's 16 run cursors (words)
        .endseg
    .if * > MUSICLD_END+1
        ert 'load_music outgrew MUSICLD_BASE..END (memory_map.inc)'
    .endif
    .if [mus_ac <> mus_b0+4*MUS_COUNT] .or [5*MUS_COUNT > 255]
        ert 'load_music copies the mono tables over mus_b0..mus_ac: five contiguous tables, X 8-bit'
    .endif
    .if [WIM_CHUNKS > 0] .and [WIM_SEC1 != MUS_SEC1+MUS_PAK_SECT]
        ert 'the world-map stream must follow the packed songs (make_atr_doom.py)'
    .endif
    .if [WIM_CHUNKS > 0] .and [WIMAP_BANK >= MUS_BANK0] .and [WIMAP_BANK <= MUS_BANK0+[[MUS_CHUNKS*4096-1]>>16]]
        ert 'WIMAP_BANK overlaps the songs (MUS_BANK0 + MUS_CHUNKS)'
    .endif

        org MUSIC_BASE               ; ...then the per-frame player

;--------------------------------------------------------------
; mus_reset -- A = song index (music_syms.inc): what played ends (mus_stop),
;   then this one starts. A, X lost.
; mus_start -- X = song: the cursor at its first frame, the chips its way, the
;   player armed LAST (it runs from the VBLANK, mus_nmi).
;--------------------------------------------------------------
        .segment B1
.proc mus_reset
        stz sv_act+2                 ; voices 2-4 are the song's: a sample still on
        stz sv_act+4                 ;   them ends HERE, before their AUDCs are
        stz sv_act+6                 ;   zeroed -- the player sends a value once
        pha                          ; 2026-10-06: what played ENDS first -- every flag
        jsr mus_stop                 ;   off, every AUDC of the song 0: the stream's
        plx                          ;   frame 0 starts from that
        ert * <> mus_start           ; (6502-mads: the fall-through, guarded)
.endp
.proc mus_start
        stx mus_cur                  ; remembered so the $FF marker can loop
        lda #0                       ; the shadow's AUDCs: 0, as the chips' are --
        ldx #6                       ;   frame 0 names only the ones that are not
?c      sta.l B1CODE_BASE+mus_shad+1,x
        sta.l B1CODE_BASE+mus_shad+17,x
        dex
        dex
        bpl ?c
        ldx mus_cur
        lda #3                       ; 2026-10-06 ("bicie v hre nepocut"): SIO leaves
        sta MUS_SKCTL                ;   SKCTL at $13 -- asynchronous receive, which
                                     ;   HOLDS timers 3 and 4 for a start bit: voices
                                     ;   3 and 4 of this chip were mute. 3 = keyboard only
        lda.l B1CODE_BASE+mus_ac,x   ; the second POKEY's AUDCTL: $28 = a level's bass
        sta AUDCTL_R+$10             ;   on its channels 3+4, joined (RMT's clean bass)
        lda.l B1CODE_BASE+mus_b0,x   ; 2026-10-06 (65816-windows, "the cheapest move
        sta mus_rd+1                 ;   is none"): the cursor IS mus_get's operand,
        lda.l B1CODE_BASE+mus_b1,x   ;   its only reader -- no cell, no copy a frame
        sta mus_rd+2
        lda.l B1CODE_BASE+mus_b2,x
        sta mus_rd+3
        lda mus_both                 ; BOTH: the mixer's four voices are software
        bne ?sw                      ;   (snd_irqb) and stay as they are
        lda.l B1CODE_BASE+mus_vm,x   ; snd_alloc's ceiling while this song plays:
        sta snd_vmax                 ;   0 = samples on voice 1 only
?sw     inc mus_on
        rts
.endp
        .endseg

;--------------------------------------------------------------
; mus_level -- the level's own song, looped, if the setting has one. Called
;   behind every init_level. mus_want is what mus_again restarts once a
;   mid-level SIO (a save) has handed POKEY back.
; mus_go -- A = a LEVEL's song, started the setting's way; Timer-1 must be off.
;   MUSIC: all eight voices (RMT's L1-L4, R1-R4) and no sample (snd_mute).
;   BOTH (2026-10-06): the samples are mixed in software into voice 1 of both
;   chips (snd_irqb), lent back to the song while none plays.
;--------------------------------------------------------------
        .segment B1
.proc mus_level
        lda mus_mode                 ; the SETTING (the menu's OPTIONS row steps it):
        beq ?none                    ;   sound effects -- four voices and no song
                                     ; (no mus_mono test: since 2026-10-15 a mono
                                     ;   machine has its own set of the songs)
        lda current_level            ; (a level past the packed songs: none)
        cmp #MUS_COUNT-MUS_LEVEL0
        bcc ?song
?none   lda #$FF
        sta mus_want
        rts
?song   adc #MUS_LEVEL0              ; (C = 0: the bcc)
        cmp mus_want                 ; the song a stop left waiting (the panel, the
        php                          ;   OPTIONS row)? It goes on -- mus_cont
        sta mus_want
        jsl snd_stop_w0              ; the mixer silent and its Timer-1 off: the song
        plp                          ;   takes voices, the handler may change
        beq mus_cont
        lda mus_want
        ert * <> mus_go
.endp
.proc mus_go
        jsr mus_reset
        ert * <> mus_flags
.endp
.proc mus_flags                      ; a level's song plays: the setting's flags
        inc mus_lvl                  ; voice 1 is the song's (mus_quiet)
        lda mus_mode
        lsr @                        ; 1 = MUSIC: C = 1; 2 = BOTH: C = 0
        bcc ?both
        inc snd_mute                 ; MUSIC: nothing else sounds (snd_play)
        rts
?both   lda #$80
        sta mus_both
        lda #SND_VTOP                ; four voices again: they need no channel each
        sta snd_vmax
        jmp snd_both_on
.endp
;--------------------------------------------------------------
; mus_cont -- 2026-10-06 ("ked ulozim hru, hudba hra nanovo?"): the level's song
;   goes ON from where a mus_stop left it -- a save, READ THIS, the panel. The
;   cursor is still mus_get's operand; the chips get back what the song had in
;   them (mus_shad), the setting its flags. Timer-1 must be off. A, X lost.
;--------------------------------------------------------------
.proc mus_cont
        lda mus_on
        bne ?no                      ; it plays
        jsr mus_flags
        ldx mus_cur
        lda #3                       ; (as mus_start: SIO left $13 there)
        sta MUS_SKCTL
        lda.l B1CODE_BASE+mus_ac,x
        sta AUDCTL_R+$10
        ldx #7                       ; all eight registers of both chips: a LEVEL's
?a      lda.l B1CODE_BASE+mus_shad+16,x ; song has voice 1 too, and no sample plays
        sta.l AUDF1_R+$10,x          ;   (long,x: no dummy read of the chip).
        lda.l B1CODE_BASE+mus_shad,x ;   2026-10-15: POKEY2 FIRST -- on a mono
        sta.l AUDF1_R,x              ;   machine it is POKEY1, whose value must stay
        dex
        bpl ?a
        inc mus_on
?no     rts
.endp
        .endseg

        .segment B1
.proc mus_again                      ; snd_pokey's tail: POKEY is the game's again
        lda mus_want                 ; $FF: no song on this level (mus_end)
        bmi ?no
        phx                          ; snd_pokey kept X before this tail
        jsr mus_cont
        plx
?no     rts
.endp
        .endseg

;--------------------------------------------------------------
; mus_nmi -- rom_nmi's call while a song is armed: ONE frame of it per VBLANK,
;   whatever the frame rate. IN: 8-bit A (rom_nmi's sep), any index width.
;   X and Y come back at the width they came in (drac030, as snd_irq).
;--------------------------------------------------------------
        .segment B1
.proc mus_nmi
        rep #$10
        phx
        phy
        sep #$10
        jsr mus_play
        rep #$10
        ply
        plx
        rtl
.endp
        .endseg

;--------------------------------------------------------------
; mus_play -- ONE frame of the song = one VBLANK. 8-bit A/X, no zero page (it
;   plays under the renderer and the loaders). A frame = POKEY1's record, then
;   POKEY2's: mask, values; bit n = the chip's register n (AUDF1 AUDC1 .. AUDC4)
;   CHANGES. The frame's FIRST byte $FF = loop, $FE = stop.
;   2026-10-06 (rapidus-bus-timing, "send only what changes"): a value goes
;   straight to its register and NOTHING is re-asserted -- 3 bus writes a frame
;   on average, not 16. So nothing else may write the song's voices while it
;   plays: mus_reset ends their samples, every snd_stop comes after a mus_stop.
;--------------------------------------------------------------
        .segment B1
.proc mus_play
        jsl mus_get                  ; POKEY1's mask
        cmp #$FE
        bcs ?end
        ldx #$FF                     ; its registers: $D200 + 0..7
        jsr ?rec
        jsl mus_get                  ; POKEY2's mask (2026-10-15: a mono machine plays
        ldx #15                      ;   the mono set, whose POKEY2 masks are 0 -- the
                                     ;   ?drop path went, 6502-idioms "delete what
                                     ;   nothing reads"). $D200 + 16..23
?rec    bit mus_both                 ; BOTH: voice 1 is lent to the mixer -- out of
        bmi ?v1                      ;   line, the other two settings fall through
?nx     inx
        lsr @                        ; C = this register's bit, Z = none above it:
        bcs ?put                     ;   an empty mask is done in one pass
        bne ?nx
        rts
?put    tay                          ; (65816-style: the mask waits in Y -- mus_get
        jsl mus_get                  ;   keeps it, mus_nmi saved it -- no RAM cell)
        sta.l B1CODE_BASE+mus_shad,x ; ... what the chip holds, for mus_cont
        sta.l AUDF1_R,x              ; long,x: no dummy read of the chip. (53 fast
        tya                          ;   cycles store to store: the 44..55 band)
        bne ?nx
        rts
?end    beq mus_stop                 ; (Z is the cmp's: $FE -- both in bank $01)
        jsr mus_quiet                ; $FF: DOOM loops the song -- every AUDC 0, where
        ldx mus_cur                  ;   frame 0 starts from; the level's flags stay
        jmp mus_start
; BOTH: a record's first two registers are voice 1's. A value goes to the shadow
; (what the mixer's disarm gives the chip back) and to the chip only while
; Timer-1 is off -- armed, AUDF1 is the mixer's rate and AUDC1 its DAC.
?v1     jsr ?v1r                     ; AUDF1 ...
        jsr ?v1r                     ; ... AUDC1 (Z: the mask's)
        bne ?nx
        rts
?v1r    inx
        lsr @
        bcc ?v1x
        tay                          ; (the mask waits in Y, as in ?put)
        jsl mus_get
        sta.l B1CODE_BASE+mus_shad,x
        pha
        lda POKMSK_R
        lsr @                        ; C = Timer-1 armed (the pla keeps it)
        pla
        bcs ?v1a
        sta.l AUDF1_R,x
?v1a    tya
?v1x    rts
.endp
mus_shad :24 dta 0                   ; what the song has in each register, by its
        .endseg                      ;   number: 0-7 POKEY1's, 16-23 POKEY2's

;--------------------------------------------------------------
; mus_stop -- the song ends: its voices silent (mus_quiet), the mixer its own
;   four voices and handler again, every level flag off. A, X lost.
; mus_end: the LEVEL is over too (snd_sio) -- no song for mus_again to restart.
; mus_quiet -- disarm and silence the song's voices (AUDC only); no flag moves.
;--------------------------------------------------------------
        .segment B1
mus_end lda #$FF
        sta mus_want
        ert * <> mus_stop            ; (6502-mads: the fall-through, guarded)
.proc mus_stop
        jsr mus_quiet
        lda mus_both
        beq ?hw
        jsr snd_both_off             ; a voice a channel again (a sample plays on)
        stz mus_both
?hw     stz mus_lvl
        stz snd_mute                 ; no song: the level's effects sound again
        lda #SND_VTOP                ; ... on the mixer's four voices
        sta snd_vmax
        rts
.endp
.proc mus_quiet
        stz mus_on                   ; disarm first: the VBLANK can come in here
        stz AUDCTL_R+$10             ; the second POKEY back on four 64 kHz voices
        lda #0                       ; 2026-10-06 (rapidus-bus-timing): long,x and
        ldx #4                       ;   plain abs -- no dummy read of the chip
?z      sta.l AUDC1_R+2,x            ; AUDC4, 3, 2 of both chips (mono: $D21x is
        sta.l AUDC1_R+$12,x          ;   $D20x again, and 0 either way)
        dex
        dex
        bpl ?z
        lda mus_lvl                  ; voice 1: off the chip if it is the song's now
        beq ?n                       ;   -- a level's has it, unless Timer-1 is armed
                                     ;   (BOTH: it is the mixer's DAC)
        lda POKMSK_R
        bne ?n
        stz AUDC1_R
        stz AUDC1_R+$10
?n      rts
.endp
        .endseg

    .if * > MUSIC_END+1              ; check the CODE before the org moves
        ert 'music.asm outgrew MUSIC_BASE..END (memory_map.inc)'
    .endif

        org MUSICDAT_BASE            ; the state, in its own hole of bank 0
snd_vmax dta SND_VTOP                ; snd_alloc's ceiling (doubled voice index).
mus_on   dta 0                       ; 0 = mus_play does nothing. Load-time zero
                                     ;   from the XEX, so the first melt of the
                                     ;   first level is already safe.
mus_cur  dta 0                       ; song index, for the loop at $FF
mus_mono dta 1                       ; 0 = two POKEYs (console.asm con_pok, at boot)
mus_want dta $FF                     ; the level's song, $FF = none (mus_level)
mus_mode dta 2                       ; the SETTING (the menu's OPTIONS row): what a
                                     ;   LEVEL sounds of -- 0 = its sound effects,
                                     ;   1 = its song (all eight voices), 2 = both
                                     ;   (the default since 2026-10-06)
snd_mute dta 0                       ; 1 = MUSIC's song plays: snd_play is silent
mus_lvl  dta 0                       ; 1 = a LEVEL's song plays: voice 1 is its own
mus_both dta 0                       ; $80 = BOTH's plays: ... and lent to the mixer
snd_accl dta 32                      ; snd_irqb's two sums of a tick, left and right
snd_accr dta 32                      ;   (bank 0: its adc/sta are plain abs)
; mus_get -- A = the stream's next byte (jsl from bank $01). The CURSOR is its
;   operand and steps here: bank 0, where `inc abs` reaches it (6502-loops-
;   tables-smc); the page wrap out of line (6502-cycles-layout).
mus_get
mus_rd  lda.l $000000
        inc mus_rd+1
        beq mus_gw
        rtl
mus_gw  inc mus_rd+2
        bne mus_gx
        inc mus_rd+3
mus_gx  rtl
    .if * > MUSICDAT_END+1
        ert 'music.asm data outgrew MUSICDAT_BASE..END (memory_map.inc)'
    .endif
        .segment B1                  ; 2026-10-06: the song tables, read long by
        icl 'music_tabs.inc'         ;   mus_reset: mus_b0/mus_b1/mus_b2/mus_vm
        .endseg

        org mus_resume
