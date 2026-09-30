; Each song's 24-bit address in Rapidus SDRAM, as an offset into the stream
; load_music depacks at MUS_BANK0 (music_syms.inc): mus_reset loads mus_p
; from these by song index.
mus_b0
        dta $03
mus_b1
        dta $00
mus_b2
        dta MUS_BANK0
