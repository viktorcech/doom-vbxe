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
        org SNDLD2_BASE
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
        lda #0                       ; every region starts at offset 0 of its
        sta ll_dst                   ;   own bank, and never crosses it (a
        sta ll_dst+1                 ;   region is at most one 64 KB bank)
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
snd_rbk dta SND_RBK0, SND_RBK1       ; ONE row per wadsound.py REGION, and the
snd_rbk_e                            ;   ert is not decoration: the weapon loader
snd_rch dta SND_RCH0, SND_RCH1       ;   once read past a short table and
snd_rch_e                            ;   streamed 44 KB over FRAME_A
snd_ldi dta 0
    .if snd_rbk_e - snd_rbk != SND_NREG || snd_rch_e - snd_rch != SND_NREG
        ert 'snd_rbk/snd_rch rows != SND_NREG -- add a row per wadsound REGION'
    .endif
    .if * > SNDLD2_END+1
        ert 'load_sounds outgrew SNDLD2_BASE..END (memory_map.inc)'
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
.proc snd_alloc
        ldy #SND_VTOP
?free   lda sv_act,y
        beq ?got                     ; idle -> take it, no one loses anything
        dey
        dey
        bpl ?free
        ldy #SND_VTOP                ; all busy: steal the one closest to done
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
?got    rts
.endp
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
.proc snd_init
        sei
        lda #0
        sta AUDCTL_R                 ; 64 kHz base, no channel pairing
        sta POKMSK_R                 ; POKMSK only ever holds $00 or $01 from
                                     ;   here on: no OS key click, no BREAK, no
                                     ;   serial -- the OS boots it at $C0
        sta VBXE_MEMAC_B             ; window off
        jsr snd_stop                 ; every voice idle, every AUDCn at 0, timer
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

;--------------------------------------------------------------
; snd_play -- start SFX X (0..SFX_COUNT-1) on whichever voice snd_alloc hands
;   out. Call from the game loop only. Clobbers A, X and Y.
;   Nothing is "the" channel any more: the sample lands wherever there is room,
;   and only a full mixer costs anything (see snd_alloc).
;--------------------------------------------------------------
.proc snd_play
    .if SND_CHUNKS = 0               ; silent build: no blob on the ATR
        rts
    .else
        sei
        jsr snd_alloc                ; -> Y = voice*2, X still the SFX id
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
        jsr snd_fetch                ; prime the first byte. No blitter wait any
                                     ;   more: the samples are in Rapidus RAM.
        lda #1
        sta sv_act,x                 ; 1 = phase 0 (hi nibble) next
        ; fall through
    .endif
.endp

;--------------------------------------------------------------
; snd_arm -- start Timer-1, the clock EVERY voice runs on. Whichever snd_play
;   starts a sample arms it; the IRQ disarms it only when every voice has gone
;   quiet. If it is already running it is left ALONE: writing STIMER restarts
;   the divider, which would shorten one tick for the voices already playing --
;   a click on the old sound every time a new one starts.
;--------------------------------------------------------------
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
?mine
        lda POKMSK_R                 ; ack Timer-1: drop bit 0, then restore it
        and #$FE
        sta IRQEN_R
        lda POKMSK_R
        sta IRQEN_R                  ; (X is already saved, full width, at entry)

        ldx #SND_VTOP
?voice  lda sv_act,x                 ; 0 = idle, 1 = hi nibble next, 2 = lo next
        beq ?next
        lsr                          ; 1 -> C=1 (phase 0), 2 -> C=0 (phase 1)
        bcc ?lo
        ; --- phase 0: high nibble ---
        lda sv_cur,x
        lsr
        lsr
        lsr
        lsr
        ora #$10
        sta AUDC1_R,x                ; output ASAP -- less jitter
        lda #2
        sta sv_act,x
        bne ?next                    ; (always)
        ; --- phase 1: low nibble, then advance to the next byte ---
?lo     lda sv_cur,x
        and #$0F
        ora #$10
        sta AUDC1_R,x
        lda #1
        sta sv_act,x
        inc sv_rl,x                  ; count UP toward $0000 = sample finished
        bne ?adv
        inc sv_rh,x
        bne ?adv
        inc sv_fin                   ; a voice just went quiet -- the ONLY way
                                     ;   the mixer can empty, so the sweep below
                                     ;   is owed exactly here (see ?any)
        lda #0                       ; done: this voice only. The timer belongs
        sta sv_act,x                 ;   to ALL of them, so only the sweep after
        sta AUDC1_R,x                ;   the loop may switch it off
        beq ?next                    ; (always)
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
        lda sv_fin
        beq ?out
        lda #0
        sta sv_fin
        ldx #SND_VTOP
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
        sta AUDC1_R,x
        dex
        dex
        bpl ?z
        ; fall through
.endp
.proc snd_disarm
        lda #0                       ; NOT `POKMSK and #$FE`. A mid-game load
        sta POKMSK_R                 ;   (exit_level / pl_reload -> snd_sio) hands
        sta IRQEN_R                  ;   POKEY to SIO, and snd_resume's snd_stop
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
        org SNDQ2_BASE

;--------------------------------------------------------------
; snd_dispatch -- start what this frame's events queued: the monster's cry and
;   the frame's SFX, each on a voice of its own. Called once per frame from the
;   main loop (clobbers A/X/Y -- snd_play does), so every trigger site can be a
;   3-byte `jsr snd_q_*` with no thought about when it is safe to touch POKEY.
;   The two queue bytes are the ceiling on NEW sounds per frame, not on
;   simultaneous ones: SND_NV voices keep playing across frames underneath.
;--------------------------------------------------------------
snddisp_resume = *
        org SNDDISP_BASE
.proc snd_dispatch
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
?done   rts                          ; (2026-08-08: this tail-called mus_play
                                     ;  for one afternoon -- music.asm's only
                                     ;  hook into the frame loop. The songs are
                                     ;  out again: the RMT renderings did not
                                     ;  sound right. Everything else about that
                                     ;  path still works and is still tested --
                                     ;  see music.asm's header for how to put
                                     ;  the four hooks back.)
.endp
    .if * > SNDDISP_END+1
        ert 'snd_dispatch outgrew SNDDISP_BASE..END (memory_map.inc)'
    .endif
        org snddisp_resume                                ;   cry from surviving into a later frame.

; snd_q_dorcls lived here and had NO caller left. Every "a door starts closing"
; site went positional when snd_q_door_at landed: update_doors' dwell end
; (doors.asm ?dwend) and door_force_open's ?shut both `jsr snd_q_door_at`, and
; the manual toggle queues SFX_DORCLS itself in snd_door_toggle below. Deleted
; 2026-08-14 (6 B).

.proc snd_q_noway                    ; USE pressed and nothing there
        lda #SFX_NOWAY
        sta snd_pending
        rts
.endp

.proc snd_q_pstart                   ; lift/floor starts moving
        lda #SFX_PSTART
        sta snd_pending
        rts
.endp

.proc snd_q_pstop                    ; lift back at the top
        lda #SFX_PSTOP
        sta snd_pending
        rts
.endp
    .if * > SNDQ2_END+1
        ert 'the snd_q_* wrappers outgrew SNDQ2_BASE..END (memory_map.inc)'
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
        org SNDDT_BASE
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
    .if * > SNDDT_END+1
        ert 'snd_door_toggle outgrew SNDDT_BASE..END (memory_map.inc)'
    .endif
        org snddt_resume

;--------------------------------------------------------------
; snd_bonus -- give_bonus + the right pickup SFX. Y = bonus id, C = "was taken"
;   on return, both exactly like give_bonus, which it replaces in spr_pickup.
;   Bonus ids (see BN_STAT in sprites.asm): 1-15 health/armor/ammo, 16-21
;   weapons, 22-24 keys. DOOM: sfx_wpnup for a weapon, sfx_itemup for the rest
;   (DSGETPOW is not in DOOM.WAD, so powerups use itemup too).
;--------------------------------------------------------------
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
        org SNDSIO_BASE

.proc snd_sio                        ; BEFORE the loaders: DAC silent, Timer-1
        jsr snd_stop                 ;   disarmed, and the OS load noise off
        lda #0                       ;   for mid-game loads (boot keeps it: the
        sta SOUNDR_R                 ;   OS cold-starts SOUNDR back to 3)
        jmp load_level_c
.endp

.proc snd_pokey                      ; AFTER them: put POKEY back the way
        sei                          ;   snd_init left it
        lda #0
        sta AUDCTL_R                 ; 64 kHz base, no serial pairing
        jsr snd_stop                 ; every voice idle + Timer-1 off (SIO left
                                     ;   AUDCTL and channels 3/4 its way)
        lda #15
        sta AUDF1_R                  ; Timer-1 -> ~3959 Hz (PAL)
        lda #$FF
        sta snd_pending              ; whatever the old level queued, drop it
        sta en_snd_q                 ;   -- including a cry from a monster that
        cli                          ;   does not exist on the new map
        rts
.endp

; BOOT takes the same medicine since the menu moved snd_init in FRONT of the
; loaders (bsp_main.asm): every one of them hands POKEY to SIO and hands it back
; detuned, which is the 2026-08-04 squeal. main calls snd_pokey on its own, so
; the restore and "now start the level" are two labels instead of one.
.proc snd_resume
        jsr snd_pokey
        jmp init_level
.endp
    .if * > SNDSIO_END+1
        ert 'snd_sio/snd_resume outgrew SNDSIO_BASE..END (memory_map.inc)'
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
sv_act :SND_VTOP+1 dta 0             ; 0 = idle, 1 = hi nibble next, 2 = lo next
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

.proc mv_raiseg                      ; a state-4 raise IS T_MoveFloor: stairs,
        jsr mv_raise                 ;   the donut, every to-target floor --
        jmp snd_q_grind              ;   they all grind on the way up
.endp

.proc mv_stepg                       ; the state-1 descent: a STAY slot is a
        jsr mv_step                  ;   W1/SR FLOOR (T_MoveFloor grinds), no
        ldx mv_slot                  ;   STAY is a lift (T_PlatRaise slides in
        lda MV_STAY,x                ;   silence). ?rise keeps calling mv_step
        bmi snd_q_grind              ;   directly -- a lift must not grind.
        rts
.endp

; en_reach -- en_shoot's ?have gate, parked in this block's slack because the
; ENEMY block is full to the byte. X = en_best on exit; C=0 = nothing under
; the crosshair, or an A_Punch/A_Saw swing out of MELEERANGE: scale is
; VFOCAL*256/Z, so "within arm's reach" (Z <= ~96, 64 + the fat demon's
; radius) means scale >= $01AB. A whiff does no damage and makes no thump.
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

; en_die_snd -- P_KillMobj's cry, from info.c via mk_tables. The A_Scream
; variant roll made it outgrow the ENINIT block (and MKTAB is 14 B too small):
; mk_death is the family BASE (podth1/bgdth1) and mk_dthn how many consecutive
; ids follow -- same contract as mk_see/mk_seen, same roll + bias as ai_start.
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
        bcc ?pick
        sec
        sbc mk_dthn,x
?pick   sta en_t
        pla
        clc
        adc en_t
?one    sta en_snd_q                 ; NOT snd_pending: wp_fire_a queues the
?no     rts                          ;   grunt AFTER the gunshot (enemy.asm)
.endp

; snd_q_nowayx -- try_use's miss, one hop out of the use-ray run (which ends
; 9 B short of ENLFIND_BASE): the "plain wall" that stopped the ray may be the
; EXIT switch -- then the click is p_switch.c's swtchx (specials 11/51), not
; the "uh-uh". EXIT_REQ is still up here; main consumes it after the flip.
.proc snd_q_nowayx
        lda EXIT_REQ
        beq ?wall
        lda #SFX_SWTCHX
        sta snd_pending
        rts
?wall   jmp snd_q_noway
.endp

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
        org WPSAWI_BASE
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
    .if * > WPSAWI_END+1
        ert 'wp_sawidl outgrew WPSAWI_BASE..END (memory_map.inc)'
    .endif
        org sawidl_resume
    .if * > SNDTAB_END+1
        ert 'sound_tables.inc + snd_q_grind outgrew SNDTAB_BASE..END -- see memory_map.inc'
    .endif
        org sndtab_resume
