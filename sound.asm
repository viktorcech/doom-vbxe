;==============================================================
; sound.asm -- DOOM digitized SFX on POKEY, SND_NV voices (Rapidus-resident)
;--------------------------------------------------------------
; Ported from w3d/src/sound.asm (HW-verified there). It started as ONE digi
; channel, grew a second for the monsters (2026-08-05) and is now a proper
; little mixer: SND_NV = 4 independent voices, one per POKEY channel, with a
; voice allocator instead of "last trigger wins".
;
; How it works
;   POKEY Timer-1 (AUDF1 = 15, AUDCTL = 0) interrupts at ~3959 Hz (PAL). Each
;   interrupt writes ONE 4-bit sample to EVERY live voice as $10|nibble -- a
;   volume-only DAC per channel. POKEY sums the four channel volumes into one
;   output pin, so four volume-only channels ARE four samples at once: no
;   software mixing, one store each. Two samples per byte (hi nibble first), so
;   a byte lasts two interrupts and one voice costs ~1980 B/s.
;   tools/wadsound.py builds the blob and sound_tables.inc (sfx_lo/hi/bnk = the
;   24-bit sample address, sfx_nlo/nhi = -length).
;
; Why four
;   Channel 1 is the timer AND a voice: the volume-only bit only forces the
;   channel's audio output high, the divider that raises the IRQ keeps counting
;   either way. So all four channels are usable and the voice index doubles as
;   the AUDCn offset -- `sta AUDC1_R,x` with X = voice*2 hits $D201/3/5/7.
;   Checked in the emulator the port is tested on: pokey.cpp FireTimer<0> raises
;   the IRQ from mIRQEN bit0 alone and never looks at AUDC1, and
;   pokeyrenderer.cpp folds mVolumeOnlyMask in for every channel index the same
;   way -- channel 0 included.
;
;   The four voices land in POKEY's ONE non-linear output stage (Altirra
;   pokey.cpp: linear to ~0.14 of full scale, then an exponential squash), so
;   the more voices are live the more the mix compresses. That is a limiter,
;   not clipping -- it goes quieter and softer, it does not crackle. If it ever
;   sounds too mushy, SND_NV is the single knob: 3 gives back ~3 dB per voice.
;
; The voices are interchangeable
;   snd_alloc hands out an IDLE voice, and only when all SND_NV are busy does it
;   steal -- the one nearest its own end, so what is cut is a sample that had
;   milliseconds left anyway. Nothing is pinned to a channel any more: the
;   weapon, the monster's cry, the door and the lift each simply take a voice.
;
;   That is what killed the old dropouts. Before, EVERY trigger restarted voice
;   A on top of whatever was playing, and worse, the voice-A end-of-sample path
;   disarmed Timer-1 without asking whether voice B still had work -- a gunshot
;   ending mid-scream froze the scream where it stood until the next trigger
;   re-armed the timer ("gaps of silence", 2026-08-06). The timer is now
;   disarmed only when the scan finds every voice idle.
;
; Placement
;   The player is org'd at SOUND_BASE ($0400), the OS cassette-buffer/user area
;   -- free here because the port boots from an ATR with no DOS and never
;   touches cassette, CIO or the floating-point pack. The samples are in
;   Rapidus SRAM (SND_EXT), so the IRQ's fetch is one 65816 `lda.l`: no MEMAC-B
;   window to borrow, no blitter to synchronise against, and no restriction on
;   where this code lives (both of which the VBXE-resident era had).
;
; Wiring (see the call sites): load_sounds (diskio.asm) streams the blob at boot,
; snd_init hooks the IRQ, snd_dispatch starts what the frame's events queued,
; and the game code queues by calling the tiny snd_q_* / snd_door_toggle /
; snd_bonus wrappers at the bottom of this file -- kept HERE so the callers grow
; by 3 bytes each (the port's segments have no room for more).
;==============================================================

; ---- POKEY / OS ------------------------------------------------------------
AUDF1_R  equ $D200                   ; Timer-1 divisor (KBCODE/SKSTAT are reads
AUDC1_R  equ $D201                   ;   of the same block -- see memory_map.inc)
                                     ; AUDC1/2/3/4 = $D201 + 2*channel, which is
                                     ;   why a voice's index is kept DOUBLED: X =
                                     ;   0,2,4,6 indexes both the state arrays
                                     ;   and `sta AUDC1_R,x`
AUDCTL_R equ $D208
STIMER_R equ $D209                   ; write: restart the timers
IRQEN_R  equ $D20E                   ; write: interrupt enable
IRQST_R  equ $D20E                   ; read:  interrupt status (bit0 = 0 -> Timer-1)
POKMSK_R equ $0010                   ; OS shadow of IRQEN
SOUNDR_R equ $0041                   ; OS "noisy I/O" flag (SIO load noise)
VIMIRQ_R equ $0216                   ; OS immediate IRQ vector (OS: CLD, JMP (VIMIRQ))

; ---- the mixer's one knob --------------------------------------------------
SND_PITCHVAR equ 1                   ; 0 = every sound plays at its own rate.
                                     ;   DOOM's per-play pitch roll (s_sound.c
                                     ;   :326) stopped being audible in v1.4:
                                     ;   the DMX API changed its parameter count
                                     ;   and id swapped the separation and pitch
                                     ;   arguments at every call site. Both are
                                     ;   int, so it compiled and shipped, and
                                     ;   from 1.4 on the engine handed DMX the
                                     ;   STEREO POSITION as the pitch. Romero
                                     ;   (2019) called the feature "mostly
                                     ;   experimental" and was glad it went.
                                     ;   1 here is NOT the pre-1.4 behaviour: it
                                     ;   is the roll narrowed to the chainsaw
                                     ;   band for every sound (see snd_pstep).
                                     ;   The full pre-1.4 width is in the table --
                                     ;   snd_pitch.inc and its generator stay in
                                     ;   the tree either way.
                                     ;   doomwiki.org/wiki/Random_sound_pitch_removed
SND_NV   equ 4                       ; simultaneous voices (POKEY has 4 channels)
SND_VTOP equ (SND_NV-1)*2            ; the top DOUBLED voice index -- every loop
                                     ;   here is `ldx #SND_VTOP` ... `dex:dex`
                                     ;   ... `bpl`, so SND_NV is the only line to
                                     ;   touch if the mix ever wants fewer

        org SOUND_BASE

;--------------------------------------------------------------
; load_sounds -- stream the SFX blob (tools/wadsound.py) into its Rapidus
;   REGIONS: SND_RCHn x 4 KB chunks into bank SND_RBKn, in blob order (T5,
;   2026-08-03: the 60 KB single-bank cap died -- each SFX carries its own
;   bank byte and load walks the regions). Map-independent -> once at boot.
;   RELOCATED to SNDLD2_BASE ($8300): the region loop outgrew the packed
;   $0400 block (which also had to find 5 B for snd_play's bank seed).
;--------------------------------------------------------------
sndld_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDLD2_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_sounds
    .if SND_CHUNKS = 0               ; no blob on the ATR (wadsound.py not run):
        jmp load_weapons             ;   silent build.
    .else
        lda #<SND_SEC1
        sta ll_sec
        lda #>SND_SEC1
        sta ll_sec+1
        ldx #0
?reg    lda snd_rch,x                ; chunks in this region (0 = skip, do NOT
        beq ?next                    ;   stop: a later region may still be live)
        sta snd_ldn
 .if 1
        stz ll_dst                   ;   own bank, and never crosses it (a
        stz ll_dst+1                 ;   region is at most one 64 KB bank)
 .else
        lda #0                       ; every region starts at offset 0 of its
        sta ll_dst                   ;   own bank, and never crosses it (a
        sta ll_dst+1                 ;   region is at most one 64 KB bank)
 .endif
        lda snd_rbk,x
        sta ll_bank
        stx snd_ldi
?chunk  lda #32                      ; a chunk at a time: ll_left is a byte and
        sta ll_left                  ;   read_ext carries ll_dst/ll_sec forward
        jsr read_ext
        dec snd_ldn
        bne ?chunk
        ldx snd_ldi
?next   inx
        cpx #SND_NREG
        bcc ?reg
        lda #MAP_EXT_BANK            ; hand read_ext back to the map bank -- every
        sta ll_bank                  ;   other caller assumes it
        jmp load_weapons             ; the weapon psprites ride along (the $2000
                                     ;   segment has no room for another jsr in
                                     ;   main's boot sequence)
    .endif
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
snd_rbk dta SND_RBK0, SND_RBK1       ; ONE row per wadsound.py REGION, and the
snd_rbk_e                            ;   ert is not decoration: the weapon loader
snd_rch dta SND_RCH0, SND_RCH1       ;   once read past a short table and
snd_rch_e                            ;   streamed 44 KB over FRAME_A
snd_ldi dta 0
    .if snd_rbk_e - snd_rbk != SND_NREG || snd_rch_e - snd_rch != SND_NREG
        ert 'snd_rbk/snd_rch rows != SND_NREG -- add a row per wadsound REGION'
    .endif
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDLD2_END+1
        ert 'load_sounds outgrew SNDLD2_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sndld_resume

;--------------------------------------------------------------
; snd_fetch -- X = voice*2. Fetch that voice's next sample byte out of Rapidus
;   SRAM into sv_cur,x. The 24-bit address lives in the voice's OWN sv_al/ah/ab
;   and is copied into the `lda.l` operand here, so all SND_NV voices share one
;   long read and there is no zero-page pointer and no Y to save in the IRQ.
;   Clobbers A.
;   2026-07-31: this used to map a 16 KB VBXE bank through MEMAC-B, read, and
;   unmap -- three stores and a window borrow per sample, and it had to wait for
;   the blitter because a VRAM read during a blit can come back as garbage. In
;   Rapidus RAM there is no window and no blitter, so it is one instruction and
;   there is nothing to synchronise against.
;--------------------------------------------------------------
.proc snd_fetch
        lda sv_al,x
        sta sf_rd+1
        lda sv_ah,x
        sta sf_rd+2
        lda sv_ab,x                  ; the sound's own Rapidus bank (multi-bank
        sta sf_rd+3                  ;   blob since 2026-08-03, wadsound REGIONS)
sf_rd   lda.l SND_EXT                ; SMC operand = this voice's byte address
        sta sv_cur,x
        rts
.endp

;--------------------------------------------------------------
; snd_alloc -- pick the voice the next sample gets. Returns Y = voice*2;
;   preserves X (snd_play still needs the SFX id there) and clobbers A.
;
;   An IDLE voice always wins, scanned from the top so voice 0 (POKEY channel 1,
;   the one that also clocks the IRQ) is the last to be used. Only when all
;   SND_NV are busy does anything get cut, and then it is the voice NEAREST ITS
;   OWN END: sv_rh counts UP to $00, so the largest unsigned high byte is the
;   sample with the fewest bytes left. That is the whole difference between this
;   and the old "last trigger wins" -- a new sound can still interrupt an old
;   one, but only one that was about to stop anyway.
;
;   The HIGH byte alone, deliberately: it buckets the survivors 256 sample bytes
;   = 65 ms apart, which is finer than anyone can hear in "which of these do I
;   sacrifice", and a full 16-bit compare needs X (the SFX id is in it) plus a
;   second temp -- 13 more bytes in a 53-byte block. Ties keep the incumbent, so
;   the choice is still deterministic: the highest-numbered voice in the bucket.
;
;   Lives in the block snd_play2 vacated (SNDPLAY2_BASE): the $0400 player is
;   full to the byte.
;--------------------------------------------------------------
snda_resume = *
        org SNDALLOC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_alloc
 .if 1
        ldy snd_vmax                 ; the TOP voice the allocator may hand out
?free   lda sv_act,y                 ;   music.asm drops it to 0 while the
        beq ?got                     ;   intermission song plays, so every SFX
        dey                          ;   lands on POKEY channel 1 and the song
        dey                          ;   keeps channels 2/3/4 to itself. Sharing
        bpl ?free                    ;   them cost either a stolen voice (one or
        ldy snd_vmax                 ;   two tones instead of three) or a click
                                     ;   on every sample, depending on which
                                     ;   side gave way.
 .else
        ldy #SND_VTOP
?free   lda sv_act,y
        beq ?got                     ; idle -> take it, no one loses anything
        dey
        dey
        bpl ?free
        ldy #SND_VTOP                ; all busy: steal the one closest to done
 .endif
        sty snd_best
        lda sv_rh,y                  ; A = the best -remaining seen so far
?scan   dey
        dey
        bmi ?take
        cmp sv_rh,y
        bcs ?scan                    ; the incumbent is still nearer the end
        lda sv_rh,y
        sty snd_best
        bcc ?scan                    ; (always -- we just took the bigger one)
?take   ldy snd_best
?got    rts                          ; (the pitch roll would fit beautifully as
.endp                                ;   a tail call from here -- Y = voice*2
        .endseg
                                     ;   and X = the SFX id are exactly
                                     ;   snd_pstep's inputs -- but this block
                                     ;   ends flush at $BE52 with PLTHR5 next,
                                     ;   so snd_play makes the call instead.)
    .if * > SNDALLOC_END+1
        ert 'snd_alloc outgrew SNDALLOC_BASE..END (memory_map.inc)'
    .endif
        org snda_resume

;--------------------------------------------------------------
; snd_init -- one-time POKEY setup + VIMIRQ hook. Call ONCE at boot, after all
;   SIO loading is done (SIO drives AUDC4 as the serial clock, so sound and SIO
;   cannot coexist). Leaves interrupts ENABLED but Timer-1 DISARMED: POKMSK is
;   $00 until the first sound, which also silences the OS key click and disables
;   BREAK. snd_arm turns the timer on, and the IRQ turns it back off when the
;   last voice goes quiet -- no interrupt at all in a silent frame.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_init
 .if 1
        sei
        stz AUDCTL_R                 ; 64 kHz base, no channel pairing
        stz POKMSK_R                 ; POKMSK only ever holds $00 or $01 from
 .else
        sei
        lda #0
        sta AUDCTL_R                 ; 64 kHz base, no channel pairing
        sta POKMSK_R                 ; POKMSK only ever holds $00 or $01 from
 .endif
                                     ;   here on: no OS key click, no BREAK, no
 .if 1
                                     ;   serial -- the OS boots it at $C0
        stz VBXE_MEMAC_B             ; window off
 .else
                                     ;   serial -- the OS boots it at $C0
        sta VBXE_MEMAC_B             ; window off
 .endif
        jsl snd_stop_w0 ; every voice idle, every AUDCn at 0, timer
                                     ;   off (and IRQEN with it)
        lda #$FF
        sta snd_pending
        lda #15
        sta AUDF1_R                  ; Timer-1 -> ~3959 Hz (PAL)
        lda VIMIRQ_R                 ; chain: keep the OS vector for foreign IRQs
        sta snd_old_irq
        lda VIMIRQ_R+1
        sta snd_old_irq+1
        lda #<snd_irq
        sta VIMIRQ_R
        lda #>snd_irq
        sta VIMIRQ_R+1
        cli
        rts
.endp
        .endseg

;--------------------------------------------------------------
; snd_play -- start SFX X (0..SFX_COUNT-1) on whichever voice snd_alloc hands
;   out. Call from the game loop only. Clobbers A, X and Y.
;   Nothing is "the" channel any more: the sample lands wherever there is room,
;   and only a full mixer costs anything (see snd_alloc).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_play
    .if SND_CHUNKS = 0               ; silent build: no blob on the ATR
        rts
    .else
        sei
        jsr snd_alloc                ; -> Y = voice*2, X still the SFX id
        jsr snd_pstep                ; ...and THIS PLAY'S PITCH into the voice
                                     ;   (s_sound.c:326-345). Same X and Y, and
                                     ;   it gives both back. The 3 bytes come
                                     ;   out of the IRQ below, which got shorter
                                     ;   when the nibble phase moved into sv_frc.
        lda.l SFX_LO_EXT,x           ; the five arrays are in Rapidus bank $01
        sta sv_al,y                  ;   since 2026-08-25 (SNDX_EXT) -- staged in
        lda.l SFX_HI_EXT,x           ;   the map slot, copied up by recip_to_ext.
        sta sv_ah,y                  ;   Five long reads once per sound STARTED is
        lda.l SFX_BNK_EXT,x          ;   the whole price; what it bought is 280 B
        sta sv_ab,y                  ;   of fast window for sg_shut (SGZ_BASE).
        lda.l SFX_NLO_EXT,x          ; byte count, NEGATED: the IRQ counts UP to
        sta sv_rl,y                  ;   $0000 with inc/bne instead of comparing
        lda.l SFX_NHI_EXT,x          ;   a 16-bit end pointer
        sta sv_rh,y
        tya
        tax                          ; the SFX id is spent -- X is the voice now
        jsl snd_fetch_w0 ; prime the first byte. No blitter wait any
                                     ;   more: the samples are in Rapidus RAM.
        jsr snd_vgo                  ; STEREO: the trigger's pan -> this voice,
                                     ;   then sv_act = 1 (the old two lines
                                     ;   moved out with it: this segment ends
                                     ;   FLUSH, and the jsr is 2 B SHORTER
                                     ;   than what it replaced)
        ; fall through
    .endif
.endp
        .endseg

;--------------------------------------------------------------
; snd_arm -- start Timer-1, the clock EVERY voice runs on. Whichever snd_play
;   starts a sample arms it; the IRQ disarms it only when every voice has gone
;   quiet. If it is already running it is left ALONE: writing STIMER restarts
;   the divider, which would shorten one tick for the voices already playing --
;   a click on the old sound every time a new one starts.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_arm
        lda #15                      ; re-assert the rate: nothing else programs
        sta AUDF1_R                  ;   POKEY, but a stray write must not detune
        lda POKMSK_R
        lsr                          ; bit0 = Timer-1 enable -> C
        bcs ?on                      ; already ticking: do not touch the divider
        lda #$01                     ; Timer-1 only: no keyboard IRQ (no OS key
        sta POKMSK_R                 ;   click), no BREAK, no serial
        sta IRQEN_R
        sta STIMER_R                 ; restart the timer -> first IRQ in ~250 us
?on     cli
        rts
.endp
        .endseg

;--------------------------------------------------------------
; snd_irq -- Timer-1 handler: ONE 4-bit sample for every live voice, then the
;   timer is switched off if that emptied the mixer. The OS enters it with CLD +
;   JMP (VIMIRQ) and does NOT save anything, hence the pha/pla; X is saved too
;   (it walks the voices) but Y is never touched. The port stays in 6502
;   emulation mode -- no rep/sep anywhere -- so the 8-bit push is the whole X.
;
;   X is the voice index DOUBLED, counted DOWN: it indexes sv_*,x and, because
;   POKEY's AUDCn are two bytes apart, `sta AUDC1_R,x` is the voice's own
;   channel with no table and no second register.
;--------------------------------------------------------------
.proc snd_irq
        rep #$10                     ; X 16-BIT FIRST, and push it at that width
        phx                          ;   (2026-08-14). An interrupt INHERITS M/X
                                     ;   from the interrupted code, so a handler
                                     ;   that uses X has to pin 8-bit before it
                                     ;   can -- but `sep #$10` ZEROES the high
                                     ;   bytes of X and Y, and the RTI's pulled P
                                     ;   restores the WIDTH BITS, never the bytes.
                                     ;   So a 16-bit index held across an
                                     ;   interrupt lost its top byte, at 3958 Hz
                                     ;   while a sound plays: automap.asm's
                                     ;   am_mark marked the wrong linedef and
                                     ;   am_walls read the wrong seg record --
                                     ;   the stray lines the map grew whenever
                                     ;   anything made a noise.
                                     ;   It was invisible until udiv24 stopped
                                     ;   leaving the CPU in emulation mode
                                     ;   (math.asm), where m/x are read-only and
                                     ;   every index was 8-bit whatever it asked.
                                     ; A needs none of this: sep #$20 leaves the
                                     ;   accumulator's high half in B.
                                     ; Y IS NOT SAVED, and that is a RULE, not an
                                     ;   oversight: the only `rep #$10` in the
                                     ;   engine is automap.asm's, which uses X
                                     ;   alone. Anything that ever puts a value in
                                     ;   a 16-bit Y has to add phy/ply here -- the
                                     ;   block has no room for them today
                                     ;   (SOUND_END).
        sep #$30                     ; 8-bit A/X/Y for the body, as before
        pha
        lda IRQST_R
        and #$01
        beq ?mine                    ; bit0 = 0 -> Timer-1, ours
        lda PORTB                    ; foreign IRQ. snd_old_irq points INTO THE
        lsr                          ;   OS ROM, and the frame loop runs with it
        bcs ?chain                   ;   banked OUT (rom_out + urom_init), so the
        lda POKMSK_R                 ;   old chain jumped into whatever RAM lies
        sta IRQEN_R                  ;   under $E000-$FFFF and, never acking, came
        jmp ?out                     ;   straight back -- the freeze the 2026-08-07
                                     ;   trace caught parked here. ROM in (bit0=1)
                                     ;   means SIO owns POKEY mid-load: chain, the
                                     ;   OS is really there. ROM out: every POKEY
                                     ;   IRQ but Timer-1 is masked, so re-writing
                                     ;   IRQEN from POKMSK resets the stray latch
                                     ;   (a 0 bit clears its IRQST bit) and rti.
?chain  pla                          ; A back (one byte: the `pha` above ran with
        rep #$10                     ;   M pinned 8-bit in either mode), then X
        plx                          ;   AT THE WIDTH `phx` PUSHED IT. THAT MIRROR
        sep #$10                     ;   IS THE WHOLE FIX (2026-08-29).
                                     ; What was here was `pla / pla / pla`: pop A
                                     ;   plus the TWO bytes a 16-bit `phx` leaves,
                                     ;   discarding X because "no 16-bit index is
                                     ;   live on this path". The count was the
                                     ;   error. This path is gated on PORTB bit0 =
                                     ;   1, i.e. ROM IN -- and rom_in/rom_out pin
                                     ;   ROM IN <=> EMULATION MODE (underrom.asm,
                                     ;   THE 65816 MODE INVARIANT). In emulation
                                     ;   the index width is FORCED 8-bit and
                                     ;   `rep #$10` cannot clear it, so `phx`
                                     ;   pushed ONE byte, `pha` one more -- two on
                                     ;   the stack against three popped. The third
                                     ;   `pla` ate the P the interrupt had pushed,
                                     ;   and the OS handler's RTI then pulled PCL
                                     ;   as P and PCH as PCL and went to lunch.
                                     ;   So the "native mode" the old comment
                                     ;   reasoned from is the one mode this path
                                     ;   can NEVER be in; the unwind was wrong
                                     ;   every single time it ran.
                                     ; WHAT IT COST: an ordinary SIO load. Every
                                     ;   serial IRQ during one arrives with the
                                     ;   ROM in, is not Timer-1, and lands here --
                                     ;   so the stack rots on the first one and
                                     ;   the machine is gone. It only ever booted
                                     ;   off an IDE+/SIDE (or IDE+'s own US SIO),
                                     ;   which loads with no POKEY serial IRQ at
                                     ;   all. Reported from real hardware
                                     ;   2026-08-29; the disassembly at $0491 in
                                     ;   irq.png is this exact frame.
                                     ; The pair mirrors ?out's `pla / rep #$10 /
                                     ;   plx` -- which is why ?out was correct in
                                     ;   both modes all along and this was not.
                                     ;   `sep #$10` hands the OS handler the 8-bit
                                     ;   X its 6502 code expects; it is a no-op in
                                     ;   emulation, where we always are, and cheap
                                     ;   insurance if the invariant ever moves.
                                     ;   X and A now arrive RESTORED, not
                                     ;   discarded, which the old path had no way
                                     ;   to do and the OS is entitled to.
        jmp (snd_old_irq)
 .if 1
?mine
        stz IRQEN_R                  ; ack Timer-1: drop bit 0, then restore it.
        lda POKMSK_R                 ;   POKMSK is $01 here -- this IS its timer,
        sta IRQEN_R                  ;   and snd_init/snd_disarm are the only
                                     ;   writers (it holds $00 or $01, never
                                     ;   more) -- so `and #$FE` of it is 0
 .else
?mine
        lda POKMSK_R                 ; ack Timer-1: drop bit 0, then restore it
        and #$FE
        sta IRQEN_R
        lda POKMSK_R
        sta IRQEN_R                  ; (X is already saved, full width, at entry)
 .endif

        ldx #SND_VTOP
?voice  lda sv_act,x                 ; 0 = idle, 1 = playing
        beq ?next
        ; --- WHICH NIBBLE: bit 7 of the voice's fraction. sv_frc counts the
        ;     position inside the sample BYTE in 1/128ths, so its top bit IS
        ;     the old phase flag -- 0 = high nibble, 1 = low -- and the two
        ;     no longer have to be kept in step with each other.
 .if 1
        lda sv_cur,x
        bit sv_frc,x                 ; N = bit 7 (A untouched): the LOW nibble
        bmi ?nib                     ;   is current
        lsr                          ; (NOT `?out` -- that is the handler's own
 .else
        lda sv_frc,x
        asl
        lda sv_cur,x
        bcs ?nib                     ; C = bit 7: the LOW nibble is current
        lsr                          ; (NOT `?out` -- that is the handler's own
 .endif
        lsr                          ;  exit label further down, and reusing it
        lsr                          ;  silently pointed the empty-mixer sweep's
        lsr                          ;  `beq ?out` back INTO this loop)
?nib    and #$0F
        ora #$10
        bit sv_side,x                ; snd_out INLINE on the sample path
        bmi ?so_r                    ;   (2026-09-15: the jsr/rts went, ~3,960
        sta AUDC1_R,x                ;   times a second while anything plays).
        bvs ?so_d                    ;   N = right-only, V = left-only, 0 = both
?so_r   sta AUDC1_R+$10,x
?so_d                                ; output ASAP -- less jitter. STEREO
                                     ;   (2026-08-31): the voice's side routes
                                     ;   it to POKEY1/POKEY2/both -- same 3 B
                                     ;   as the old `sta AUDC1_R,x`, this block
                                     ;   is full. A mono machine mirrors $D21x
                                     ;   onto $D20x (pokey.cpp mAddressMask),
                                     ;   so every side is audible there
        ; --- ADVANCE by this play's pitch. DOOM walks the sample with a
        ;     fractional step (i_sound.c:599-603, channelstepremainder); this
        ;     is the same walk one byte wide. SND_PITCH_ONE (128) is half a
        ;     byte an interrupt = the fixed rate the port always had, and the
        ;     carry out is "a whole sample byte has been consumed". A step
        ;     never exceeds 152, so a carry can never happen twice in a row
        ;     and one byte per interrupt is still the ceiling.
        lda sv_frc,x
        clc
        adc sv_stp,x
        sta sv_frc,x
        bcc ?next                    ; still inside this byte
        inc sv_rl,x                  ; count UP toward $0000 = sample finished
        bne ?adv
        inc sv_rh,x
        bne ?adv
        inc sv_fin                   ; a voice just went quiet -- the ONLY way
                                     ;   the mixer can empty, so the sweep below
                                     ;   is owed exactly here (see ?any)
        lda #0                       ; done: this voice only. The timer belongs
        sta sv_act,x                 ;   to ALL of them, so only the sweep after
        jsr snd_out                  ;   the loop may switch it off. snd_out's
        beq ?next                    ; (always: BIT with A=0 leaves Z=1, and
                                     ;   both stores keep it -- the contract
                                     ;   this beq was already leaning on)
?adv    inc sv_al,x                  ; advance this voice's read address
        bne ?fetch
        inc sv_ah,x                  ;   (a sound never crosses a bank end, so
                                     ;    sv_ab is never touched -- wadsound.py)
        ; --- fetch the next byte. The blitter-busy retry is gone with the move
        ;     to Rapidus RAM: there is no VRAM read to collide with a blit.
?fetch  jsr snd_fetch
?next   dex
        dex
        bpl ?voice

        ; --- did that empty the mixer? Then stop interrupting: a silent frame
        ;     costs the renderer nothing. (The bug this replaces: the old voice
        ;     A disarmed the timer the moment ITS sample ended, freezing voice B
        ;     mid-scream until the next trigger re-armed it.)
        ;     ONLY WHEN A VOICE ACTUALLY ENDED. This handler fires 3959 times a
        ;     second (tools/tests/_dbg_irqcost.py: 184-289 cycles each, i.e.
        ;     3.6-5.7 % of every frame while anything is playing) and a voice
        ;     ends a handful of times a second, so the four-voice sweep was
        ;     running some 3900 times for nothing. If nothing ended, the set of
        ;     live voices is exactly what it was on entry -- and the timer was
        ;     armed then, so it must stay armed. Same behaviour, ~36 cycles less
        ;     on almost every interrupt.
 .if 1
        lda sv_fin
        beq ?out
        stz sv_fin
        ldx #SND_VTOP
 .else
        lda sv_fin
        beq ?out
        lda #0
        sta sv_fin
        ldx #SND_VTOP
 .endif
        lda #0
?any    ora sv_act,x
        dex
        dex
        bpl ?any
        cmp #0
        bne ?out
        jsr snd_disarm
?out    pla                          ; A ...
        rep #$10                     ; ... then X at the FULL width the entry
        plx                          ;     pushed it
        rti                          ; (RTI's pulled P puts the real widths back)
.endp

;--------------------------------------------------------------
; snd_stop -- silence EVERY voice and disarm Timer-1. Clobbers A and X.
;--------------------------------------------------------------
.proc snd_stop
        ldx #SND_VTOP
        lda #0
?z      sta sv_act,x
        jsr snd_out                  ; both chips where the side says so; a
        dex                          ;   left-only voice never wrote POKEY2,
        dex                          ;   so there is nothing to clear there
        bpl ?z
        ; fall through
.endp
.proc snd_disarm
 .if 1
        stz POKMSK_R                 ; NOT `POKMSK and #$FE`. A mid-game load
        stz IRQEN_R                  ;   (exit_level / pl_reload -> snd_sio) hands
                                     ;   POKEY to SIO, and snd_resume's snd_stop
 .else
        lda #0                       ; NOT `POKMSK and #$FE`. A mid-game load
        sta POKMSK_R                 ;   (exit_level / pl_reload -> snd_sio) hands
        sta IRQEN_R                  ;   POKEY to SIO, and snd_resume's snd_stop
 .endif
        rts                          ;   lands here to take it back -- so masking
                                     ;   one bit KEEPS whatever serial bits SIO
                                     ;   left, and foreign POKEY IRQs come back on
                                     ;   behind snd_irq's back. snd_init is the
                                     ;   only other place that zeroes POKMSK and
                                     ;   it runs ONCE at boot (bsp_main.asm:279),
                                     ;   which is why E1M1 was fine and a level
                                     ;   reached through exit_level froze:
                                     ;   IRQST=$F7 (bit3 = serial output done) in
                                     ;   snd_irq, 2026-08-07 Altirra trace.
                                     ;   POKMSK only ever holds $00 or $01 (see
                                     ;   snd_init) -- so write the $00 outright.
.endp

;--------------------------------------------------------------
; STEREO FOR THE MONSTERS (2026-09-09, "aby bolo pocut zvuky priser odtial ako
;   stoja"). snd_setpan (doors.asm) already pans a DOOR: the quadrant its
;   soundorg lies in against the facing, out of the signs in sda_sx/sda_sy. The
;   same routine pans a THING once those hold player - thing. What was missing
;   was WHO cried: en_snd_q and snd_pending are one byte each and carry the SFX
;   id alone, so every monster voice started at the centre. The queue sites go
;   through the helpers below now -- the same 3 bytes as the `sta` each of them
;   replaced, so no packed block grew -- and park the thing beside the id;
;   snd_dispatch pans the voice from it right before snd_play.
;   The monster's voice (en_snd_q) is queued by en_hurt_snd (pain), en_die_snd,
;   en_gibq (the gib scream) and ai_atk's grunt; the first three key on en_last
;   -- en_shoot's victim, and en_bhit sets it to en_bi for a blast kill, infight
;   to ai_vt -- the grunt on ai_t. A_Look's seesound goes into snd_pending
;   (ai_start), the slot the player's own sounds share -- as do the A_Chase
;   grunt, hoof/metal, the bite and the claw (all ai_t), the ball's launch (its
;   imp) and the two bursts (the ball's and the missile's own position). Those
;   pan at QUEUE time into snd_ppan, and snd_pid remembers which id was queued
;   that way, so a gunshot stored over it stays at the centre.
;--------------------------------------------------------------
sndpth_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDPTH_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qm_last                    ; A = SFX -> the monster voice; en_last cried
        sta en_snd_q
        lda en_last
        sta en_snd_th
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qm_ai                      ; ... ai_t cried (the attack grunt)
        sta en_snd_q
        lda ai_t
        sta en_snd_th
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qp_ai                      ; A = SFX -> the frame's SFX slot, from
        sta snd_pending              ;   where thing ai_t stands (A_Look's
        sta snd_pid                  ;   seesound, the A_Chase grunt, hoof/metal,
        lda ai_t                     ;   the bite and the claw, the ball's
        jsr snd_panth                ;   launch). Preserves X and Y.
        bra snd_qp_take
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qp_ball                    ; A = SFX at the imp's ball (bl_x/bl_y):
        sta snd_pending              ;   the fireball's burst. Preserves X/Y.
        sta snd_pid
        rep #$20                     ; ---- 16-bit A: player - ball
        .LONGA ON
        sec
        lda zp_px
        sbc bl_x
        sta sda_sx
        sec
        lda zp_py
        sbc bl_y
        sta sda_sy
        sep #$20
        .LONGA OFF
        bra snd_qp_pan
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qp_pj                      ; A = SFX at the player's missile (pj_x/pj_y
        sta snd_pending              ;   of the slot pj_load swapped in): the
        sta snd_pid                  ;   rocket/plasma burst. Preserves X/Y.
        rep #$20                     ; ---- 16-bit A: player - missile
        .LONGA ON
        sec
        lda zp_px
        sbc pj_x
        sta sda_sx
        sec
        lda zp_py
        sbc pj_y
        sta sda_sy
        sep #$20
        .LONGA OFF
        ; fall through
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qp_pan                     ; sda_sx/sda_sy -> the pending pan
        phx
        jsl snd_setpan_w0               ; quadrant x facing -> snd_side (eats X)
        plx
        ; fall through
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_qp_take                    ; snd_side -> snd_ppan. The pan is computed
        bcs ?far                     ;   at QUEUE time and parked here: snd_side
        lda snd_side                 ;   itself goes to the NEXT snd_play, which
        sta snd_ppan                 ;   would be the monster voice snd_dispatch
        stz snd_side                 ;   starts first, not this sound
        rts
?far    lda #$FF                     ; past S_CLIPPING_DIST: s_sound.c plays
        sta snd_pending              ;   nothing at all -- unqueue it
        rts
.endp
        .endseg
;--------------------------------------------------------------
; snd_panth -- A = the thing whose voice snd_play starts next ($FF = nobody:
;   the centre stays). Preserves X (the SFX id snd_play wants). Native mode
;   only (the frame loop): en_th2 and the word subtracts are 16-bit blocks.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_panth
        cmp #$FF
        beq ?none
        phx
        phy
        jsr en_thing.en_th2          ; sp_ptr = its record: x @0, y @2
        rep #$20                     ; ---- 16-bit A: player - thing, both axes,
        .LONGA ON                    ;   whole words -- snd_setpan reads the
        sec                          ;   SIGN out of sda_sx+1/sda_sy+1
        lda zp_px
        sbc (sp_ptr)
        sta sda_sx
        ldy #2
        sec
        lda zp_py
        sbc (sp_ptr),y
        sta sda_sy
        sep #$20
        .LONGA OFF
        jsl snd_setpan_w0               ; angle x facing -> snd_side; C=1 = too
        ply                          ;   far to hear at all (S_CLIPPING_DIST)
        plx
        rts
?none   clc                          ; nobody: audible, centre (the cmp left C=1)
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_dispatch
 .if 1
        stz snd_menu                 ; the game is running: the pitch rolls again
        ldx en_snd_q                 ; the monster's voice takes a voice of its
        bmi ?sfx                     ;   own: the cry and the gunshot both play,
        lda #$FF                     ;   and neither has to lose a channel to
        sta en_snd_q                 ;   the other. DOOM mixes eight; this mixes
        lda en_snd_th                ;   SND_NV, in POKEY itself.
        jsr snd_panth                ; STEREO (2026-09-09): the cry comes from
        lda #$FF                     ;   where the monster stands -- snd_side for
        sta en_snd_th                ;   the voice snd_play is about to take
        bcs ?sfx                     ;   (X survives snd_panth). C=1: too far
        jsr snd_play                 ;   to hear (S_CLIPPING_DIST) -- dropped
?sfx    ldx snd_pending
        bmi ?done                    ; $FF = nothing queued
        lda #$FF
        sta snd_pending
        cpx snd_pid                  ; still the id a monster (or a burst)
        bne ?pl                      ;   queued? then the pan it was queued with
        lda snd_ppan                 ;   goes to the voice; the player's own
        sta snd_side                 ;   sounds never match it (posit/bgsit/
?pl     jsr snd_play                 ;   claw/firxpl... are never his)
        rts                          ;   (tail call across the bank line)
 .else
        ldx en_snd_q                 ; the monster's voice takes a voice of its
        bmi ?sfx                     ;   own: the cry and the gunshot both play,
        lda #$FF                     ;   and neither has to lose a channel to
        sta en_snd_q                 ;   the other. DOOM mixes eight; this mixes
        jsr snd_play                 ;   SND_NV, in POKEY itself.
?sfx    ldx snd_pending
        bmi ?done                    ; $FF = nothing queued
        lda #$FF
        sta snd_pending
        jmp snd_play
 .endif
?done   rts                          ; (2026-08-08: this tail-called mus_play
                                     ;  for one afternoon -- music.asm's only
                                     ;  hook into the frame loop. The songs are
                                     ;  out again: the RMT renderings did not
                                     ;  sound right. Everything else about that
                                     ;  path still works and is still tested --
                                     ;  see music.asm's header for how to put
                                     ;  the four hooks back.)
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
en_snd_th dta $FF                    ; who queued en_snd_q ($FF = nobody)
snd_menu  dta 0                      ; nonzero = the MENU is up (mn_head bumps
                                     ;   it, the frame loop's snd_dispatch
                                     ;   zeroes it): its sounds play at the
                                     ;   fixed pitch -- snd_pstep (2026-09-09,
                                     ;   "rychlost zvukov sa meni aj v menu")
snd_ppan  dta 0                      ; the pan snd_pending's sound was queued with
snd_pid   dta $FF                    ;   ...and the id it was queued as, so a
                                     ;   player sound stored over it (a different
                                     ;   id) plays at the centre
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDPTH_END+1
        ert 'snd_panth + the stereo queue helpers outgrew SNDPTH_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sndpth_resume

;--------------------------------------------------------------
; snd_setpan -- sda_sx/sda_sy = player - source (16-bit, the WHOLE difference).
;   C=1: inaudible -- max(|dx|,|dy|) >= 1200 (s_sound.c S_CLIPPING_DIST; the
;   Chebyshev reach snd_q_door_at already used). C=0: snd_side = the ear for
;   the NEXT snd_play. DOOM's S_AdjustSoundParams pans by
;       sep = 128 - 96 * sin(angle(listener -> source) - listener->angle)
;   i.e. a source ahead or behind sits at the centre and one beside the
;   player at the far ear. POKEY has three states per voice (snd_out), so the
;   relative direction is folded onto OCTANTS: 0 (ahead) and 4 (behind) are
;   the centre, 1-3 (counter-clockwise from the facing = the LEFT) POKEY1,
;   5-7 POKEY2. The octant of the source is sign-quadrant x dominance, with
;   "diagonal" = neither axis twice the other, so the ahead/behind lanes are
;   ~53 degrees wide -- where DOOM's sep sits within +-43 of the centre.
;   ASSUMES BAM 0 = east, 64 = north (counter-clockwise, like oct_of), +y =
;   north, POKEY1 = the left ear: if the ears come out MIRRORED, swap the
;   $40/$80 in side_tab -- nothing else changes. Clobbers A/X/Y, sda_sx/sy
;   (they come back as |dx|/|dy|) and sda_f. Cold: one call per queued
;   sound. Native mode only (the frame loop).
;--------------------------------------------------------------
sndpan2_resume = *
        org SNDPAN2_BASE
.proc snd_setpan
        ldy #0                       ; Y = sign quadrant of the SOURCE: bit1 =
        lda sda_sx+1                 ;   west of the player, bit0 = south
        bmi ?e                       ;   (player - source < 0 <=> source east)
        iny
        iny
?e      lda sda_sy+1
        bmi ?n
        iny
?n      sty sda_f
        rep #$20                     ; ---- 16-bit A: |dx|, |dy|, the reach test
        .LONGA ON                    ;   and the dominance, one word each
        lda sda_sx
        bpl ?ax
        eor #$FFFF
        inc @
?ax     sta sda_sx                   ; |dx|
        lda sda_sy
        bpl ?ay
        eor #$FFFF
        inc @
?ay     sta sda_sy                   ; |dy|
        cmp sda_sx
        bcs ?mx                      ; max(|dx|,|dy|) in A
        lda sda_sx
?mx     cmp #1200
        bcs ?far                     ; C=1: nothing to hear
        ldx #1                       ; dominance: 1 = diagonal...
        lda sda_sy
        asl @
        cmp sda_sx
        bcc ?xd                      ; 2|dy| < |dx| -> 0, along x
        lda sda_sx
        asl @
        cmp sda_sy
        bcs ?have                    ; 2|dx| >= |dy| -> diagonal
        inx                          ; 2|dx| < |dy| -> 2, along y
        bra ?have
?xd     dex
?have   sep #$20
        .LONGA OFF
        lda sda_f                    ; quadrant*3 + dominance -> oct_tab
        asl @
        adc sda_f                    ; (C=0: the asl of a value <= 3)
        sta sda_f
        txa
        adc sda_f
        tax
        lda zp_ang                   ; the facing, rounded to its octant
        clc
        adc #16                      ;   (BAM 240..255 wraps to octant 0: right)
        lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        sta sda_f
        lda oct_tab,x                ; the source's octant, counter-clockwise
        sec                          ;   from east...
        sbc sda_f                    ;   ...relative to the facing
        and #7
        tax
        lda side_tab,x
        sta snd_side
        clc                          ; C=0: audible, and the ear is set
        rts
        .LONGA ON
?far    sep #$20                     ; (C=1 survives the sep)
        .LONGA OFF
        rts
.endp
oct_tab dta 0,1,2                    ; source E & N of the player: along x, diag, along y
        dta 0,7,6                    ;   E & S
        dta 4,3,2                    ;   W & N
        dta 4,5,6                    ;   W & S
side_tab dta $00,$40,$40,$40         ; relative octant 0 (ahead) centre, 1-3 LEFT
        dta $00,$80,$80,$80          ;   4 (behind) centre, 5-7 RIGHT

    .if * > SNDPAN2_END+1
        ert 'snd_setpan outgrew SNDPAN2_BASE..END (memory_map.inc)'
    .endif
        org sndpan2_resume

; snd_pstep's CODE (2026-09-09): out of SNDPITCH, which is full to the byte
;   (the per-voice data and snd_pitch stay there for the IRQ), into its own
;   hole -- SNDPAN2 could not take both.
sndpst_resume = *
        org SNDPST_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_pstep
        lda #0
        sta sv_frc,y
 .if SND_PITCHVAR
        cpx #SFX_ITEMUP
        beq ?flat                    ; s_sound.c: this one is never varied
        lda snd_menu                 ; ...and neither is anything the MENU plays
        bne ?flat                    ;   (2026-09-09): the switch and the pistol
                                     ;   there sounded different on every press
        stx snd_sid                  ; X is the SFX id and the caller still
                                     ;   wants it; the table read needs X too
        lda RANDOM                   ; POKEY's LFSR -- the port's M_Random
        and #$07                     ; NORMAL..FASTER, never slower: index
        clc                          ;   9..16 is delta +7..0, x1.000..x1.083,
        adc #9                       ;   0.00..+1.31 semitones -- eight steps,
                                     ;   one of them exactly SND_PITCH_ONE.
                                     ;   DOOM's own roll is SYMMETRIC -- `pitch
                                     ;   += 16 - (M_Random()&31)` spans delta
                                     ;   +16..-15, so it plays sounds slower as
                                     ;   often as faster. The slow half is what
                                     ;   made effects sound thick and dragged on
                                     ;   this hardware, so only the upper half is
                                     ;   rolled here. Deliberately NOT the
                                     ;   original behaviour.
        tax
        lda snd_pitch,x
        ldx snd_sid
        sta sv_stp,y
        rts
 .endif
?flat   lda #SND_PITCH_ONE
        sta sv_stp,y
        rts
.endp
        .endseg
    .if * > SNDPST_END+1
        ert 'snd_pstep outgrew SNDPST_BASE..END (memory_map.inc)'
    .endif
        org sndpst_resume

;--------------------------------------------------------------
; snd_out -- A = the AUDC byte, X = slot*2 (both preserved): route it by the
;   voice's side. POKEY2 is the STEREO mod at $D210 (address bit4); on a mono
;   machine the decoder masks bit4 away (alt-src pokey.cpp mAddressMask $0F),
;   so a "right" write lands on POKEY1's same channel and mono hears every
;   voice -- stereo needs no detection and no option. CONTRACT: A=0 exits
;   with Z=1 (BIT of 0 sets Z, the stores keep it) -- snd_irq's silence path
;   does `beq (always)` after this. Parked below $B000: the IRQ calls it
;   with the ROM in OR out, so an under-ROM home would fetch OS bytes.
;--------------------------------------------------------------
sout_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDOUT_BASE
 .endif
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
.proc snd_out
        bit sv_side,x                ; N = right-only, V = left-only, 0 = centre
        bmi ?r
        sta AUDC1_R,x                ; POKEY1: the left half or the centre
        bvs ?done                    ; left only -> POKEY2 stays silent
?r      sta AUDC1_R+$10,x            ; POKEY2: the right half or the centre
?done   rts
.endp
sv_side dta 0,0,0,0,0,0,0            ; per voice slot: 0 centre / $40 L / $80 R
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDOUT_END+1
        ert 'snd_out outgrew SNDOUT_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sout_resume

;==============================================================
; Trigger wrappers -- called BY the game code. The id-only ones sit in their own
; hole (SNDQ2_BASE, always-RAM below the MEMAC window): the $0400 block ran out
; when SWTCHN's table entries landed (+4 B x 4 arrays). They have moved twice
; and are cold enough that where they live does not matter -- the last move
; (2026-08-20) was to hand $3D90-$3DAF to the per-kind tables, which the two
; final bosses had outgrown.
;--------------------------------------------------------------
; Every one of these costs the caller exactly one `jsr` (3 bytes), which is all
; the port's packed segments can spare (see the RAM-BUDGET block). They queue an
; id; snd_dispatch starts it at the next frame boundary. All of them clobber A
; and the flags and preserve X and Y unless noted.
;==============================================================
sndq2_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDQ2_BASE
 .endif

;--------------------------------------------------------------
; snd_dispatch -- start what this frame's events queued: the monster's cry and
;   the frame's SFX, each on a voice of its own. Called once per frame from the
;   main loop (clobbers A/X/Y -- snd_play does), so every trigger site can be a
;   3-byte `jsr snd_q_*` with no thought about when it is safe to touch POKEY.
;   The two queue bytes are the ceiling on NEW sounds per frame, not on
;   simultaneous ones: SND_NV voices keep playing across frames underneath.
;--------------------------------------------------------------
; (snd_dispatch lived at SNDDISP_BASE until 2026-09-09; it rides in the
;  SNDPTH block with the stereo helpers now -- see there. $BD4A-$BD64 is free.)                                ;   cry from surviving into a later frame.

; snd_q_dorcls lived here and had NO caller left. Every "a door starts closing"
; site went positional when snd_q_door_at landed: update_doors' dwell end
; (doors.asm ?dwend) and door_force_open's ?shut both `jsr snd_q_door_at`, and
; the manual toggle queues SFX_DORCLS itself in snd_door_toggle below. Deleted
; 2026-08-14 (6 B).

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_noway                    ; USE pressed and nothing there
        lda #SFX_NOWAY
        sta snd_pending
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_pstart                   ; lift/floor starts moving
        lda #SFX_PSTART
        sta snd_pending
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_pstop                    ; lift back at the top
        lda #SFX_PSTOP
        sta snd_pending
        rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDQ2_END+1
        ert 'the snd_q_* wrappers outgrew SNDQ2_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sndq2_resume

;--------------------------------------------------------------
; snd_door_toggle -- door_toggle + the right door SFX. A = door index, exactly
;   like door_toggle, which leaves the index in X so the new state can be read
;   back: 1 = opening, 3 = closing. Replaces the `jsr door_toggle` in try_use.
;
;   OUT OF THE $0400-$05A7 BLOCK (2026-08-25). snd_play's five table reads
;   became `lda.l` when the per-SFX arrays moved to bank $01 (SNDX_EXT) and that
;   is five bytes this block did not have -- it ends where urom_init begins.
;   This proc is a keypress-only 23 B, so it went to the free hole ram_map.py
;   has been naming for weeks instead.
;--------------------------------------------------------------
snddt_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDDT_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_door_toggle
        jsr door_toggle
        lda.l DOOR_STATE,x
        cmp #3
        beq ?cls
        lda #SFX_DOROPN
        sta snd_pending
        rts
?cls    lda #SFX_DORCLS
        sta snd_pending
        rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDDT_END+1
        ert 'snd_door_toggle outgrew SNDDT_BASE..END (memory_map.inc)'
    .endif
 .endif
        org snddt_resume

;--------------------------------------------------------------
; snd_bonus -- give_bonus + the right pickup SFX. Y = bonus id, C = "was taken"
;   on return, both exactly like give_bonus, which it replaces in spr_pickup.
;   Bonus ids (see BN_STAT in sprites.asm): 1-15 health/armor/ammo, 16-21
;   weapons, 22-24 keys. DOOM: sfx_wpnup for a weapon, sfx_itemup for the rest
;   (DSGETPOW is not in DOOM.WAD, so powerups use itemup too).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_bonus
        jsr give_bonus
        bcc ?no                      ; not usable now -> left on the floor, silent
        lda #SFX_ITEMUP
        cpy #16
        bcc ?q
        cpy #22
        bcs ?q                       ; 22-24 keys -> itemup
        lda #SFX_WPNUP               ; 16-21 weapons
?q      sta snd_pending
        sec                          ; restore give_bonus' "taken" answer
        rts
?no     clc
        rts
.endp
        .endseg

;==============================================================
; The level-exit SIO bracket -- exit_level (bsp_main.asm) swaps its
; `jsr load_level_c` / `jmp init_level` for these two, so the $1B00 block
; grows by zero bytes. WHY ("kvicavy ton" on EXIT, 2026-08-04): SIOV owns
; POKEY for the whole load -- serial-clock bits in AUDCTL, channel 3/4
; frequencies, the OS SOUNDR load noise -- and restores none of it, while
; our Timer-1 IRQ + DAC were still armed and snd_play never re-asserts
; AUDCTL. The squeal was POKEY caught between the two owners; it happened
; with no SFX queued at all. Covers the death-restart reload too
; (pl_reload flows through the same two calls).
;==============================================================
sndsio_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SNDSIO_BASE
 .endif

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_sio                        ; BEFORE the loaders: DAC silent, Timer-1
 .if 1
        jsl snd_stop_w0 ;   disarmed, and the OS load noise off
        stz SOUNDR_R                 ;   for mid-game loads (boot keeps it: the
                                     ;   OS cold-starts SOUNDR back to 3)
 .else
        jsr snd_stop                 ;   disarmed, and the OS load noise off
        lda #0                       ;   for mid-game loads (boot keeps it: the
        sta SOUNDR_R                 ;   OS cold-starts SOUNDR back to 3)
 .endif
        jmp load_level_c
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_pokey                      ; AFTER them: put POKEY back the way
 .if 1
        sei                          ;   snd_init left it
        stz AUDCTL_R                 ; 64 kHz base, no serial pairing
 .else
        sei                          ;   snd_init left it
        lda #0
        sta AUDCTL_R                 ; 64 kHz base, no serial pairing
 .endif
        jsl snd_stop_w0 ; every voice idle + Timer-1 off (SIO left
                                     ;   AUDCTL and channels 3/4 its way)
        lda #15
        sta AUDF1_R                  ; Timer-1 -> ~3959 Hz (PAL)
        lda #$FF
        sta snd_pending              ; whatever the old level queued, drop it
        sta en_snd_q                 ;   -- including a cry from a monster that
        cli                          ;   does not exist on the new map
        rts
.endp
        .endseg

; BOOT takes the same medicine since the menu moved snd_init in FRONT of the
; loaders (bsp_main.asm): every one of them hands POKEY to SIO and hands it back
; detuned, which is the 2026-08-04 squeal. main calls snd_pokey on its own, so
; the restore and "now start the level" are two labels instead of one.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_resume
        jsr snd_pokey
        jmp init_level               ; (DRAC_PLAN 4b) snd_resume is bank-$01 code too
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SNDSIO_END+1
        ert 'snd_sio/snd_resume outgrew SNDSIO_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sndsio_resume

;==============================================================
; State + the generated sample tables
;--------------------------------------------------------------
; THE VOICE ARRAYS. Indexed by the DOUBLED voice number (0,2,4,6) so the same X
; also addresses POKEY: `sta AUDC1_R,x`. The odd slots are the price of that --
; 3 bytes an array, against a table lookup plus a second index register in the
; hottest interrupt in the port.
;==============================================================
sv_act :SND_VTOP+1 dta 0             ; 0 = idle, 1 = playing (the nibble phase
                                     ;   moved into sv_frc's top bit)
sv_cur :SND_VTOP+1 dta 0             ; the sample byte being played
sv_al  :SND_VTOP+1 dta 0             ; the 24-bit read address, seeded from
sv_ah  :SND_VTOP+1 dta 0             ;   sfx_lo/hi/bnk and walked by the IRQ
sv_ab  :SND_VTOP+1 dta 0             ;   (snd_fetch copies it into the `lda.l`)
sv_rl  :SND_VTOP+1 dta 0             ; NEGATED bytes left; $0000 = finished, and
sv_rh  :SND_VTOP+1 dta 0             ;   snd_alloc steals by the HIGH byte
sv_fin        dta 0                  ; a voice ended inside snd_irq -> the
                                     ;   "is the mixer empty" sweep is owed
snd_best      dta 0                  ; snd_alloc's running "nearest the end"
snd_pending   dta $FF                ; SFX queued this frame ($FF = none)
snd_old_irq   dta a(0)               ; saved VIMIRQ (chain for foreign IRQs)
snd_ldn       dta 0                  ; load_sounds: 4 KB chunks left to stream
                                     ; (snd_bank is gone with the MEMAC-B window)

;==============================================================
; DOOM'S PER-PLAY PITCH (s_sound.c:326-345). Every S_StartSound rolls the
; playback rate before the sound is handed to the mixer:
;     saw group        pitch += 8  - (M_Random()&15)
;     everything else  pitch += 16 - (M_Random()&31)   except itemup and tink
; around NORM_PITCH = 128, and i_sound.c:415 turns that into a step of
; 2^(delta/64) -- 0.850x to 1.189x, i.e. -2.81 to +3.00 semitones, with the
; sound coming out that much shorter or longer. It is why the same shotgun
; never sounds twice the same in DOOM, and the port had none of it: snd_irq
; walked every sample at exactly one nibble per interrupt, so a repeated sound
; was a bit-for-bit photocopy.
;
; THE TWO BYTES A VOICE NEEDS live here and not with the other voice arrays,
; because the SOUND block ($0400-$05FF) is full to rom_nmi. They must stay
; BELOW $8000: snd_irq touches them three times per voice, 3958 times a second,
; and $8000-$BFFF is off the Rapidus fast shadow (see memory_map.inc).
;
; sv_frc is the position inside the current sample BYTE in 1/128ths -- its top
; bit is the nibble the IRQ is playing, the rest is the fraction -- and sv_stp
; is how far to move per interrupt. SND_PITCH_ONE (128) is half a byte, the
; rate the port always ran at, so a step of 128 reproduces the old behaviour
; exactly, sample for sample.
;==============================================================
sndp_resume = *
        org SNDPITCH_BASE
sv_frc :SND_VTOP+1 dta 0             ; 1/128ths into the byte; b7 = which nibble
sv_stp :SND_VTOP+1 dta SND_PITCH_ONE ; this play's rate, 128 = the old fixed one
snd_sid       dta 0                  ; the SFX id, parked across the table read

        icl 'snd_pitch.inc'          ; snd_pitch: 32 steps, index = rnd & 31

;--------------------------------------------------------------
; snd_pstep -- roll one play's pitch. snd_alloc tail-calls it, so the inputs
;   are the ones it already had:
;     IN  X = SFX id, Y = voice*2      OUT both unchanged, sv_frc/sv_stp seeded
;   sv_frc starts at 0, which is DOOM's "play from the first sample" AND the
;   high nibble, so nothing else needs initialising.
;   The two exceptions are DOOM's own: sfx_itemup and sfx_tink never vary
;   (tink has no lump in DOOM.WAD, so ITEMUP is the only one the port ships).
;   The chainsaw's narrower roll reads the SAME table 8 rows in -- (rnd&15)+8
;   is delta +8..-7, which is exactly `8 - (M_Random()&15)`.
;--------------------------------------------------------------
; (snd_pstep is CODE and moved to the SNDPAN2 block on 2026-09-09 -- this
;  block was full to the byte: SNDPITCH_END said $3AFF and $3AF1 is the next
;  segment, check_xex caught the 5 B the menu test added. The per-voice data
;  and the table stay here, below $8000, for the IRQ.)
    .if SFX_SAWHIT != SFX_SAWUP+2
        ert 'SAWUP/SAWIDL/SAWHIT are no longer three consecutive SFX ids -- the range test in snd_pstep assumes it (wadsound.py SFX order)'
    .endif
    .if * > SNDPITCH_END+1
        ert 'the pitch block outgrew SNDPITCH_BASE..END (memory_map.inc)'
    .endif
        org sndp_resume

    .if * > SOUND_END
        ert 'sound.asm overran the OS free area at SOUND_END -- see memory_map.inc'
    .endif

; The generated per-SFX arrays are not in base RAM at all any more (2026-08-25).
; They are STAGED into the map slot here and recip_to_ext copies them up to
; Rapidus bank $01 (SNDX_EXT) before the first load_level -- the exact road the
; reciprocal tables took on 2026-07-31. snd_play is their ONLY reader and it
; reads them five times per sound STARTED, so a `lda.l` costs nothing; what it
; buys is 280 B of $0000-$3FFF, a Rapidus-FAST window, which a lookup table has
; no use for and the sight ray's z test does (memory_map.inc SGZ_BASE).
sndtab_resume = *
        org SNDX_STAGE
snd_stage
        icl 'sound_tables.inc'       ; SFX_* ids + sfx_lo/hi/nlo/nhi/bnk
    .if SFX_COUNT != SNDX_N
        ert 'SNDX_N (memory_map.inc) drifted from sound_tables.inc SFX_COUNT'
    .endif
    .if * - snd_stage > SNDX_BYTES
        ert 'the per-SFX arrays outgrew SNDX_BYTES -- see memory_map.inc'
    .endif
        org SNDTAB_BASE

; T_MoveFloor's sfx_stnmov (2026-08-04). Both movers blocks are full to the
; byte, so update_movers grinds by RETARGETING two jsrs (zero growth there):
; ?climb calls mv_raiseg instead of mv_raise, ?fall calls mv_stepg instead of
; mv_step. The code rides in this block's slack behind the SFX tables.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_grind                    ; every 8th jiffy (p_floor.c gates on
        lda RTCLOK3                  ;   leveltime&7 too), WEAK-queued: the
        and #7                       ;   grind must never eat a real event -- a
        bne ?no                      ;   landing pstop queues first and wins the
        lda snd_pending              ;   slot. Preserves X (the mover slot).
        bpl ?no
        lda #SFX_STNMOV
        sta snd_pending
?no     rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_raiseg                      ; a state-4 raise IS T_MoveFloor: stairs,
        jsr mv_raise                 ;   the donut, every to-target floor --
        jmp snd_q_grind              ;   they all grind on the way up
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_stepg                       ; the state-1 descent: a STAY slot is a
        jsr mv_step                  ;   W1/SR FLOOR (T_MoveFloor grinds), no
        ldx mv_slot                  ;   STAY is a lift (T_PlatRaise slides in
        lda MV_STAY,x                ;   silence). ?rise keeps calling mv_step
        bmi snd_q_grind              ;   directly -- a lift must not grind.
        rts
.endp
        .endseg

; en_reach -- en_shoot's ?have gate, parked in this block's slack because the
; ENEMY block is full to the byte. X = en_best on exit; C=0 = nothing under
; the crosshair, or an A_Punch/A_Saw swing out of MELEERANGE: scale is
; VFOCAL*256/Z, so "within arm's reach" (Z <= ~96, 64 + the fat demon's
; radius) means scale >= $01AB. A whiff does no damage and makes no thump.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_reach
        ldx en_best
        bmi ?no                      ; $FF -> nothing under the crosshair
        lda en_melee
        beq ?yes                     ; a bullet: any distance
        ; --- MELEERANGE, per TARGET (p_map.c). The swing reaches MELEERANGE past
        ;     the player's centre and connects with whatever radius reaches into
        ;     that, so the centre-to-centre limit is MELEERANGE + the thing's own
        ;     radius -- 74 for a barrel, 84 for an imp, 94 for a demon. This used
        ;     to be one flat scale threshold (Z <= 96 for everything), which was
        ;     22 units generous on a barrel. TH_RAD is en_radfill's per-thing
        ;     radius, the same number PIT_CheckThing uses.
        ;     scale = VFOCAL*256/Z, so "Z <= MELEERANGE + rad" is
        ;     scale * (MELEERANGE + rad) >= VFOCAL*256: one multiply, no divide.
        ;     Integer truncation costs at most one unit of reach.
        ldy vs_th,x
        lda #>TH_RAD                 ; zp_ptr is still en_shoot's TH_HPL pointer,
        sta zp_ptr+1                 ;   and every per-thing page is 256 B aligned
        lda [zp_ptr],y               ;   -- only the hi byte moves, the bank byte
        clc                          ;   stays as init_level left it
        adc #MELEERANGE              ; the radius is CONSUMED here, so the pointer
        sta m_a                      ;   restore below can wait and the pha/pla
        lda #>TH_HPL                 ;   pair that used to straddle it is gone
        sta zp_ptr+1                 ; ...and back: en_shoot reads the health
                                     ;   through zp_ptr the moment we return
        stz m_a+1                    ; 65816 stz: A is reloaded next anyway
        lda en_bsc                   ; the winner's scale (en_shoot's sort key)
        sta m_b
        lda en_bsc+1
        sta m_b+1
        jsr umul16
        lda m_prod+2
        bne ?yes                     ; >= 65536 -> well inside arm's reach
        lda m_prod+1
        cmp #>(VFOCAL*256)
        bcc ?no                      ; the product never reached VFOCAL*256
?yes    inc en_hit                   ; the shot/swing CONNECTS (wp_fire_a's ear)
        sec
        rts
?no     clc
        rts
.endp
        .endseg

; en_die_snd -- P_KillMobj's cry, from info.c via mk_tables. The A_Scream
; variant roll made it outgrow the ENINIT block (and MKTAB is 14 B too small):
; mk_death is the family BASE (podth1/bgdth1) and mk_dthn how many consecutive
; ids follow -- same contract as mk_see/mk_seen, same roll + bias as ai_start.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_die_snd
        ldx en_kind
        beq ?no
        lda mk_death,x
        bmi ?no                      ; $FF = this type has no sound in the build
        ldy mk_dthn,x
        dey
        beq ?one                     ; one variant -> the base id as-is
        pha
        lda RANDOM                   ; POKEY LFSR, the port's P_Random
        and #3
        cmp mk_dthn,x
        bcc ?pick                    ; (C = 1 past it: no sec)
        sbc mk_dthn,x
?pick   sta en_t
        pla
        clc
        adc en_t
?one    jsr snd_qm_last              ; NOT snd_pending: wp_fire_a queues the
?no     rts                          ;   grunt AFTER the gunshot (enemy.asm).
                                     ;   STEREO: en_last is the one that died
.endp
        .endseg

; snd_q_nowayx -- try_use's miss, one hop out of the use-ray run (which ends
; 9 B short of ENLFIND_BASE): the "plain wall" that stopped the ray may be the
; EXIT switch -- then the click is p_switch.c's swtchx (specials 11/51), not
; the "uh-uh". EXIT_REQ is still up here; main consumes it after the flip.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_nowayx
        lda EXIT_REQ
        beq ?wall
        lda #SFX_SWTCHX
        sta snd_pending
        rts
?wall   jmp snd_q_noway
.endp
        .endseg

; k7 -- ball.asm's aim table, round(7*256/m) for m = 8..127: MT_TROOPSHOT's
; 7 units/VBLANK over the reduced aim deltas. Data only; both ball holes
; ($4E80 + $6BE7) are full, this block still had the room.
k7      dta 224,199,179,163,149,138,128,119,112,105
        dta 100, 94, 90, 85, 81, 78, 75, 72, 69, 66
        dta  64, 62, 60, 58, 56, 54, 53, 51, 50, 48
        dta  47, 46, 45, 44, 43, 42, 41, 40, 39, 38
        dta  37, 37, 36, 35, 34, 34, 33, 33, 32, 31
        dta  31, 30, 30, 29, 29, 28, 28, 28, 27, 27
        dta  26, 26, 26, 25, 25, 25, 24, 24, 24, 23
        dta  23, 23, 22, 22, 22, 22, 21, 21, 21, 21
        dta  20, 20, 20, 20, 19, 19, 19, 19, 19, 18
        dta  18, 18, 18, 18, 18, 17, 17, 17, 17, 17
        dta  17, 16, 16, 16, 16, 16, 16, 16, 15, 15
        dta  15, 15, 15, 15, 15, 15, 14, 14, 14, 14

; wp_sawidl -- A_WeaponReady's saw putter (the same full-run story as above:
; the head of wp_ready lives here). WS_SAW entries only -- every other swap of
; the idle pair, DOOM's own S_SAW gate -- and WEAK-queued: the putter must
; never eat a real event. Clobbers A/X.
;   ...and it is not in the annex any more (2026-08-20): the two FINAL BOSSES
;   brought four sight/death cries, four SFX are 20 more bytes of the five
;   per-SFX arrays, and this block had ONE byte left. It went to WPSAWI_BASE,
;   which fits it to the byte.
sawidl_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org WPSAWI_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wp_sawidl
        ldx wp_cur
        cpx #WP_CHAINSAW
        bne ?no
        lda wp_state
        cmp #WS_SAW
        bne ?no
        lda snd_pending
        bpl ?no
        lda #SFX_SAWIDL
        sta snd_pending
?no     rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > WPSAWI_END+1
        ert 'wp_sawidl outgrew WPSAWI_BASE..END (memory_map.inc)'
    .endif
 .endif
        org sawidl_resume
    .if * > SNDTAB_END+1
        ert 'sound_tables.inc + snd_q_grind outgrew SNDTAB_BASE..END -- see memory_map.inc'
    .endif
        org sndtab_resume
