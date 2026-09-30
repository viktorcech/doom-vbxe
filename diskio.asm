;--------------------------------------------------------------
; diskio.asm -- ATR/SIO streaming (no DOS): load_level, read_sectors, the SDRAM
;   level cache and the one-shot asset loaders.
;--------------------------------------------------------------
SIOV    equ $E459
DDEVIC  equ $0300
DUNIT   equ $0301
DCOMND  equ $0302
DSTATS  equ $0303
DBUFLO  equ $0304
DBUFHI  equ $0305
DTIMLO  equ $0306
DBYTLO  equ $0308
DBYTHI  equ $0309
DAUX1   equ $030A
DAUX2   equ $030B

ll_sec  dta a(0)                     ; current ATR sector (1-based, 16-bit)
ll_cnt  dta a(0)                     ; sectors left to read (16-bit; maps can exceed 255)
sio_status dta 0                     ; last SIOV status (Y on return; 1 = success)
current_level dta 0                  ; level index to (re)load (0-based)
tex_chunk  dta 0                     ; load_textures: current 4KB chunk (survives read_sectors)

;--------------------------------------------------------------
; load_level -- stream `current_level` from the ATR. Fixed stride:
;   base_sec = LVL_SEC1 + current_level*LVL_SECTORS (atr_layout.inc).
;--------------------------------------------------------------
ll_dst  dta a(0)                     ; under-ROM copy destination
ll_left dta 0                        ; HIGH sectors still to read
ll_pass dta 0                        ; sectors in the current staging pass
ll_bank dta MAP_EXT_BANK             ; read_ext's destination BANK. The map owns
                                     ;   it; load_sounds borrows it for the SFX
                                     ;   blob in bank $02 and puts it back.
;--------------------------------------------------------------
; lvl_offset -- ll_sec += current_level * ll_stride. Every per-level asset on the
;   ATR sits at a FIXED stride (atr_layout.inc), so this one routine positions the
;   map, the textures, the sprite pixels and the things blob. The three asset
;   loaders used to skip it entirely and always read level 0's data -- invisible
;   while there was only one level.
;--------------------------------------------------------------
ll_stride dta a(0)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lvl_offset
        ldx current_level
        beq ?done
                                      ; the running sum stays in 16-bit A, stored once
        rep #$20                     ;   (bank $01: native, 65816-windows)
        .LONGA ON
        lda ll_sec
?add    clc
        adc ll_stride
        dex
        bne ?add
        sta ll_sec
        .LONGA OFF
        sep #$20
?done   rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_level
        lda #<LVL_SEC1               ; base_sec = LVL_SEC1 + current_level*LVL_SECTORS
        sta ll_sec
        lda #>LVL_SEC1
        sta ll_sec+1
        lda #<LVL_SECTORS
        sta ll_stride
        lda #>LVL_SECTORS
        sta ll_stride+1
        jsr lvl_offset
        lda #MAP_LOW_SECT            ; --- LOW region: $4000 ---
        sta ll_left
        lda #<MAP_LOAD
        sta ll_dst
        lda #>MAP_LOAD
        sta ll_dst+1
        jsr read_urom                ; leaves ll_sec on the first HIGH sector
        lda #<MAP_LOAD_HI            ; --- HIGH region: staged, then under the ROM ---
        sta ll_dst
        lda #>MAP_LOAD_HI
        sta ll_dst+1
        lda #MAP_HI_SECT
        sta ll_left
        jsr read_urom
        lda #<MAP_VERTS              ; --- EXT region: VERTS+NODES into the Rapidus
        sta ll_dst                   ;     SRAM bank (MAP_VERTS = offset $0100:
                                     ;     $01:0000-00FF is the page the Rapidus
                                     ;     may remap to page zero -- pack_map.py)
        lda #>MAP_VERTS
        sta ll_dst+1
        lda #MAP_EXT_SECT
        sta ll_left
        jsr read_ext
        lda #<MAP_SEGS               ; --- SEG region: the seg records into a bank
        sta ll_dst                   ;     of their OWN (bank $01 is 40 KB full).
        lda #>MAP_SEGS               ;     MAP_SEGS = offset $100 in MAP_SEG_BANK,
        sta ll_dst+1                 ;     and the AUTOMAP's three side tables
                                     ;     (MAP_AMSEG/AMFLG/AMSEEN) ride at the ...
        lda #MAP_SEG_BANK
        sta ll_bank
        sta zp_sptr+2                ; ...and the seg pointer's bank byte, for good.
        sta zp_nodeptr+2             ;   NODES ride the SEG bank too (2026-08-18,
                                     ;   E2/E3: 28 B x 817 nodes blew EXT's $6400) ...
    .if MAP_SEG_SECT > 255           ; the NODES move pushed the region past a
        lda #255                     ;   byte of sectors: two passes -- read_ext
        sta ll_left                  ;   advances ll_sec AND ll_dst, so the
        jsr read_ext                 ;   second call simply continues
        lda #[MAP_SEG_SECT-255]
    .else
        lda #MAP_SEG_SECT
    .endif
        sta ll_left
        jsr read_ext
        lda #MAP_EXT_BANK            ; put ll_bank back: load_dtab/load_los stream
        sta ll_bank                  ;   into bank $01 and do not set it themselves
        rts
.endp
        .endseg
    .if MAP_SEG_SECT > 510
        ert 'MAP_SEG_SECT > 510 sectors -- a Rapidus bank cannot hold it anyway'
    .endif
    .if MAP_LOW_SECT > 255
        ert 'load_level: read_urom counts MAP_LOW_SECT in a byte'
    .endif

;--------------------------------------------------------------
; cache_run -- ll_left sectors from ll_sec: C = 1 and zp_vptr -> them when
;   the SDRAM cache serves sectors (ld_src) and holds the whole run, first
;   sector to last, in one of its ranges (pre_map). Clobbers A/X, m_a, zp_ptr.
; cache_cp -- ... those sectors, [zp_vptr] -> [zp_ptr], a word a pass, two
;   sectors a block; ll_sec and both cursors behind them, ll_left = 0.
;   Clobbers A/X/Y. The caller puts zp_vptr+2 back (MAP_EXT_BANK).
;--------------------------------------------------------------
        .segment B1
.proc cache_run
        lda ld_src
        beq ?no
        jsr pre_map                  ; the first sector
        bcc ?no
        stx m_b                      ; ... its range
        rep #$20
        .LONGA ON
        lda zp_ptr
        sta zp_vptr
        lda ll_sec
        pha
        sep #$20
        .LONGA OFF
        lda zp_ptr+2
        sta zp_vptr+2
        lda ll_left
        dec @
        clc
        adc ll_sec
        sta ll_sec
        bcc ?l1
        inc ll_sec+1
?l1     jsr pre_map                  ; the last one
        rep #$20
        .LONGA ON
        pla
        sta ll_sec
        sep #$20
        .LONGA OFF
        bcc ?no                      ; (C is pre_map's)
        cpx m_b
        bne ?no
        rts                          ; C = 1
?no     clc
        rts
.endp
.proc cache_cp
        lda ll_left
        lsr @
        tax                          ; blocks, C = a sector on its own
        rep #$20
        .LONGA ON
        bcc ?blk
        ldy #0
?h      lda [zp_vptr],y
        sta [zp_ptr],y
        iny
        iny
        bpl ?h
        lda zp_ptr                   ; (C = 1: + 128)
        adc #127
        sta zp_ptr
        lda zp_vptr
        clc
        adc #128
        sta zp_vptr
        bcc ?blk
        sep #$20
        inc zp_vptr+2
        rep #$20
?blk    txa                          ; (A = 00:X)
        beq ?end
?pg     ldy #0
?w      lda [zp_vptr],y
        sta [zp_ptr],y
        iny
        iny
        bne ?w
        inc zp_ptr+1                 ; (words at +1: the page and the bank)
        inc zp_vptr+1
        dex
        bne ?pg
?end    sep #$20
        .LONGA OFF
        lda ll_left
        clc
        adc ll_sec
        sta ll_sec
        bcc ?e1
        inc ll_sec+1
?e1     stz ll_left
        rts
.endp
        .endseg

;--------------------------------------------------------------
; read_ext -- read ll_left sectors from ll_sec into bank MAP_EXT_BANK at offset
;   (ll_dst): the Rapidus SRAM at $01:0000+ (448 KB, always mapped -- Altirra
;   rapidus.cpp Init). SIOV cannot address other banks, so it stages exactly like
;   read_urom and the copy crosses with a 65816 long store (sta [zp],y works in
;   emulation mode). No ROM banking games needed: banks $01+ ignore PORTB.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc read_ext
        jsr cache_run
        bcc ?pass
        lda ll_dst
        sta zp_ptr
        lda ll_dst+1
        sta zp_ptr+1
        lda ll_bank
        sta zp_ptr+2
        jsr cache_cp
        lda #MAP_EXT_BANK
        sta zp_vptr+2
        lda zp_ptr                   ; the next read goes on where this one
        sta ll_dst                   ;   stopped
        lda zp_ptr+1
        sta ll_dst+1
        rts
?pass   lda ll_left
        bne ?go
        rts
?go     cmp #8                       ; 8 sectors = the 1 KB staging buffer
        bcc ?part
        lda #8
?part   sta ll_pass
        sta ll_cnt
        stz ll_cnt+1
        lda #<TEX_STAGE
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        jsr read_sectors             ; advances ll_sec by ll_pass
        lda #<TEX_STAGE
        sta zp_tsrc
        lda #>TEX_STAGE
        sta zp_tsrc+1
        lda ll_dst
        sta zp_ptr
        lda ll_dst+1
        sta zp_ptr+1
        lda ll_bank                  ; usually MAP_EXT_BANK; the SFX blob streams
        sta zp_ptr+2                 ;   to bank $02 (sound.asm load_sounds)
        ldx ll_pass
?sec    ldy #127
?by     lda (zp_tsrc),y
        sta [zp_ptr],y               ; long store -> $01:xxxx
        dey
        bpl ?by
        lda zp_tsrc                  ; += 128: TEX_STAGE is 128-aligned (ert
        eor #$80                     ;   below), so the low byte is $00 or $80 and
        sta zp_tsrc                  ;   flipping bit 7 IS the add -- it carries
        bmi ?tnc                     ;   exactly when the bit was set (N = 0 now)
        inc zp_tsrc+1
?tnc    clc
        lda zp_ptr
        adc #128
        sta zp_ptr
        lda zp_ptr+1
        adc #0
        sta zp_ptr+1
        dex
        bne ?sec
        lda zp_ptr                   ; next pass continues where this one stopped
        sta ll_dst
        lda zp_ptr+1
        sta ll_dst+1
        sec
        lda ll_left
        sbc ll_pass
        sta ll_left
        bra ?pass
.endp
        .endseg

;==============================================================
; The COLD half of the streaming code, moved out of the $2000 engine segment
; into the RAM the seg table vacated (2026-07-31). Every proc below runs only
; while a level (or the boot set) is loading, never in the frame path, and all
; of them drive SIOV -- so they must stay below $C000, which DISKIO2_BASE is.
;==============================================================
dio2_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; read_urom -- read ll_left sectors from ll_sec into (ll_dst), which is RAM UNDER
;   THE OS ROM. SIOV is in that ROM, so it cannot write there directly: read into
;   the staging buffer 2 KB at a time and copy across with the ROM banked out.
;   Used for the map's HIGH region and for the THINGS blob.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc read_urom
        jsr cache_run
        bcc ?pass
        lda ll_dst
        sta zp_ptr
        lda ll_dst+1
        sta zp_ptr+1
        lda zp_ptr+2
        pha
        stz zp_ptr+2                 ; bank 0, long: no read of the target
        lda PORTB                    ;   first. The ROM out, as below
        and #$FE
        sta PORTB
        jsr cache_cp
        pla
        sta zp_ptr+2
        lda #MAP_EXT_BANK
        sta zp_vptr+2
        lda zp_ptr
        sta ll_dst
        lda zp_ptr+1
        sta ll_dst+1
        lda #$40                     ; ... and the interrupts, as below
        sta NMIEN
        cli
        rts
?pass   lda ll_left
        bne ?go
        rts
?go     cmp #8                       ; 8 sectors = 1 KB, the staging buffer's size
        bcc ?part                    ;   (2 KB until 2026-07-28, when tw_setup --
        lda #8                       ;   CODE -- moved to $1500; see TEX_STAGE)
?part   sta ll_pass
        sta ll_cnt
        stz ll_cnt+1
        lda #<TEX_STAGE
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        jsr read_sectors             ; advances ll_sec by ll_pass
        lda #<TEX_STAGE
        sta zp_tsrc
        lda #>TEX_STAGE
        sta zp_tsrc+1
        lda ll_dst
        sta zp_ptr
        lda ll_dst+1
        sta zp_ptr+1
        ; The ROM has to go out to reach $D800, and while it IS out the vectors at
        ; $FFFA/$FFFE are RAM -- which urom_init has not necessarily filled yet on
        ; the very first load.
        sei
        stz NMIEN
                                      ; 2026-09-22 idiom: rom_out inlined (-12)
        lda PORTB
        and #$FE
        sta PORTB
        ldx ll_pass                  ; copy ll_pass x 128 B (SECTORS, not pages: the
?sec    jsr cp128_ur                 ;   HIGH region is not a whole number of pages)
        lda zp_tsrc                  ;   -- the 128 B loop itself is in fast win1
        eor #$80                     ; += 128 as in read_ext: TEX_STAGE is
        sta zp_tsrc                  ;   128-aligned, the low byte is $00/$80
        bmi ?tnc
        inc zp_tsrc+1
?tnc    clc
        lda zp_ptr
        adc #128
        sta zp_ptr
        lda zp_ptr+1
        adc #0
        sta zp_ptr+1
        dex
        bne ?sec
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a)
        lda #$40
        sta NMIEN
        cli
        lda zp_ptr                   ; next pass continues where this one stopped
        sta ll_dst
        lda zp_ptr+1
        sta ll_dst+1
        sec
        lda ll_left
        sbc ll_pass
        sta ll_left
        jmp ?pass
.endp
        .endseg

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; cp128_ur -- read_urom's inner copy: 128 B (zp_tsrc) -> (zp_ptr). Split out
;   of the win2 shell into a fast win1 crumb (2026-08-17): the shell now
;   fetches ~3 instructions per sector here instead of ~512 at the x11.2
;   chip rate.
;--------------------------------------------------------------
        org CP128_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cp128_ur
        ldy #127
?by     lda (zp_tsrc),y
        sta (zp_ptr),y
        dey
        bpl ?by
        rts
.endp
        .endseg
    .if * > CP128_END+1
        ert 'cp128_ur outgrew CP128_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; read_sectors -- read ll_cnt sectors from ll_sec into (DBUFLO/HI), advancing
;   both. All non-constant DCB fields are rewritten each sector (SIOV may touch
;   them). 16-bit ll_cnt so >255-sector maps work.
;--------------------------------------------------------------
        org DIOFAST_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc read_sectors
?lp     lda ld_src
        bne ?sdram 
        ;bra ?sdram                   ; the SIO body below is past branch range
?sio    lda #$31                     ; disk drive serial id (D1:)
        sta DDEVIC
        lda #$01
        sta DUNIT
        lda #$52                     ; 'R' read sector
        sta DCOMND
        lda #$40                     ; input direction (device -> memory)
        sta DSTATS
        lda #128
        sta DBYTLO
        stz DBYTHI
        lda #$0F
        sta DTIMLO
        lda ll_sec
        sta DAUX1
        lda ll_sec+1
        sta DAUX2
        jsl siov_r_w0 ; DRAC_PLAN 4a: SIOV with the ROM banked in
        sty sio_status               ; capture SIO status (Y on return; 1 = success)
        dey                          ; anything else: the sector again
        bne ?sio
        jsr pre_map                  ; --- the TEE: every sector read off the
                                     ;     drive is ALSO parked in its SDRAM
                                     ;     home, so the NEXT read of this level
        bcc ?adv                     ;     is a memory copy (lvl_res gate)
        lda DBUFLO
        sta zp_tsrc
        lda DBUFHI
        sta zp_tsrc+1
        rep #$20
        .LONGA ON
        ldy #126
?tee    lda (zp_tsrc),y
        sta [zp_ptr],y
        dey
        dey
        bpl ?tee
        sep #$20
        .LONGA OFF
        bra ?adv
?sdram  jsr pre_map                  ; zp_ptr = this sector's SDRAM home
        bcc ?sio                    ;   (defensive: outside the mapped ranges
        ;bra ?sio                     ;   fall back to the drive)
?insd   lda DBUFLO                   ; the caller's target, indirect-capable
        sta zp_tsrc
        lda DBUFHI
        sta zp_tsrc+1
        rep #$20
        .LONGA ON
        ldy #126
?cp     lda [zp_ptr],y
        sta (zp_tsrc),y
        dey
        dey
        bpl ?cp
        sep #$20
        .LONGA OFF
        lda #1
        sta sio_status
?adv    inc ll_sec
        bne ?bok
        inc ll_sec+1
?bok    lda DBUFLO
        clc
        adc #128
        sta DBUFLO
        bcc ?cok
        inc DBUFHI
?cok    lda ll_cnt                   ; ll_cnt-- (16-bit), loop while != 0
        bne ?declo
        dec ll_cnt+1
?declo  dec ll_cnt
        lda ll_cnt
        ora ll_cnt+1
        beq ?out
        jmp ?lp
?out    rts
.endp
        .endseg
ld_src  dta 0                        ; 0 = SIO + the tee, 1 = SDRAM serves every
                                     ;   sector (load_level_c picks per level)

    .if * > DIOFAST_END+1
        ert 'read_sectors+ld_src outgrew DIOFAST_BASE..END (memory_map.inc)'
    .endif
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
                                     ;   two -- no single win2 hole held 637 B
                                     ;   (memory_map.inc DISKIO2/DISKIO2B)

;--------------------------------------------------------------
; pre_map -- zp_ptr(24) = ll_sec's home in the Rapidus SDRAM cache:
;   PREn_BASE + (ll_sec - PREn_SEC)*128, n by range. C=0 = the sector is in
;   neither mapped range (the XEX window, the unwired texture pool): the
;   caller stays on the drive and nothing is cached. Clobbers A/X, m_a.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pre_map
        ldx #0                       ; range 1 if sec >= PRE1_SEC
        lda ll_sec+1
        cmp #>PRE1_SEC
        bcc ?r0
        bne ?r1
        lda ll_sec
        cmp #<PRE1_SEC
        bcc ?r0
?r1     inx
?r0     sec                          ; delta = sec - PREn_SEC (16-bit)
        lda ll_sec
        sbc pre_slo,x
        sta m_a
        lda ll_sec+1
        sbc pre_shi,x
        sta m_a+1
        bcc ?no                      ; below the range base (the XEX window)
        cmp pre_chi,x                ; delta < PREn_CNT?
        bcc ?ok
        bne ?no                      ;   (>= : past the range -- the pool sits
        lda m_a                      ;    between range 0's end and range 1)
        cmp pre_clo,x
        bcs ?no
?ok     lsr m_a+1                    ; src24 = PREn_BASE + delta*128: the pair
        ror m_a                      ;   >> 1 lands in the mid/high bytes and
        lda #0                       ;   the dropped bit 0 becomes $80
        ror
        clc
        adc pre_b0,x
        sta zp_ptr
        lda m_a
        adc pre_b1,x
        sta zp_ptr+1
        lda m_a+1
        adc pre_b2,x
        sta zp_ptr+2
        sec
        rts
?no     clc
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
pre_slo dta <PRE0_SEC, <PRE1_SEC     ; the two cached ranges' first sectors
pre_shi dta >PRE0_SEC, >PRE1_SEC
pre_clo dta <PRE0_CNT, <PRE1_CNT     ; ... their lengths, sectors
pre_chi dta >PRE0_CNT, >PRE1_CNT
pre_b0  dta <PRE0_BASE, <PRE1_BASE   ; ... and their 24-bit SDRAM bases
pre_b1  dta >PRE0_BASE, >PRE1_BASE
pre_b2  dta [PRE0_BASE>>16], [PRE1_BASE>>16]

;--------------------------------------------------------------
; load_textures -- stream this level's .tex from the ATR into VBXE VRAM $020000+.
;   TEX_CHUNKS x 4KB: read 32 sectors -> $B000 staging (RAM, BASIC off), then copy
;   through the MEMAC window ($9000) into VBXE bank $20+chunk. Runs right after
;   load_level (map at $4000 survives; MEMW/$B000 are above it) with IRQs on (SIO).
;--------------------------------------------------------------
; !! $B000-$BFFF IS NOT FREE RAM !! It looks free to MADS and carries no XEX
;    segment, but load_textures streams 4 KB texture chunks through it at boot,
;    so anything assembled here is destroyed before the first frame -- silently,
;    with a flat pink screen as the only symptom. tools/ram_map.py lists it as
;    reserved and tools/check_xex.py fails the build on it. It IS reclaimable
;    after the last level load, if you ever want the 4 KB back.
; The SIO staging buffer sits in the PER-FRAME array area ($1000-$13FF): that
; 1 KB is solid_arr/ytopc/ybotc + the rs_* scratch -- all rebuilt from scratch
; every frame, so using it at load time costs nothing. It was 2 KB (up to $17FF)
; until 2026-07-28, when tw_setup -- CODE, which must survive level loads --
; moved into the Rapidus-fast $1500 page: the first load then streamed sectors
; straight over the per-column engine (pink screen, found with an Altirra write
; watchpoint on $1500). A 4 KB VBXE bank is now filled in four 1 KB passes.
TEX_STAGE   equ $1000                ; 1KB SIO staging buffer (per-frame arrays)
    .if TEX_STAGE & $7F
        ert 'TEX_STAGE is not 128-aligned: read_ext/read_urom flip bit 7 for += 128'
    .endif
TEX_BANK0   equ $18                  ; first VBXE 4KB bank = VRAM $018000 (right
                                     ;   above FRAME_B -- pack_textures.py base)
ld_chunks   dta 0                    ; load_vram: 4KB chunks to stream
ld_bank0    dta 0                    ; load_vram: first VBXE bank
ld_half     dta 0                    ; load_vram: MEMW page offset of the current
                                     ;   1 KB quarter (0/4/8/12)
; 2026-08-14, THE EPISODE POOL. There is no per-level .tex any more: all nine
; maps share ONE blob (pack_textures.TexPool), so this streams it ONCE and every
; later level load finds its textures already in SDRAM. Across E1 that is 974 KB
; of SIO down to 287 KB -- measured per level by tools/pool_plan.py -- and from
; the second map on, a level's textures cost nothing at all to enter.
; The read still goes through the 1 KB staging buffer purely so read_sectors'
; TEE parks every sector in its SDRAM home; nothing is kept in base RAM.
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_textures
        lda pool_res                 ; already streamed -> nothing to do, on
        bne ?done                    ;   EVERY level including this one's reload
        inc pool_res
        lda #<POOL_SEC               ; the pool is ONE DEFLATE stream on the
        sta ll_sec                   ;   disk now (2026-09-26, make_atr_doom):
        lda #>POOL_SEC               ;   inflate depacks it straight onto its
        sta ll_sec+1                 ;   SDRAM home -- the tee never sees it
        lda #[LVL_TEXSD_C]&$FF       ;   (POOL_SEC sits past PRE0's end)
        sta inf_out
        lda #[LVL_TEXSD_C>>8]&$FF
        sta inf_out+1
        lda #LVL_TEXSD_C>>16
        sta inf_out+2
        jsr inflate
?done   rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
pool_res dta 0                       ; 1 = the episode texture blob is in SDRAM


;--------------------------------------------------------------
; load_vram -- stream ld_chunks x 4KB from ll_sec into VBXE banks ld_bank0+n,
;   via the $B000 staging buffer and the MEMAC window. Used for the level's wall
;   textures (.tex) and its sprite pixels (.spr).
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_vram
        ldx #0
?chunk  stx tex_chunk
        lda tex_chunk               ; MEMAC window -> VBXE bank ld_bank0 + chunk
        clc
        adc ld_bank0
        ora #BANK_EN
        sta VBXE_BANK_SEL
        stz ld_half
?half   lda #<TEX_STAGE             ; read 8 sectors (1KB) -> staging
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        lda #8
        sta ll_cnt
        stz ll_cnt+1
        jsr read_sectors
                                      ; 2026-09-22 (rapidus-bus-timing): the WINDOW is
        stz zp_savex                 ;   written through [zp_tsrc],y (its bank byte
        lda #<TEX_STAGE              ;   zp_savex = 0) and the staging read through
        sta zp_ptr                   ;   (zp_ptr),y: a (dp),y store dummy-reads the
        lda #>TEX_STAGE              ;   window first, a chip cycle for every byte
        sta zp_ptr+1
        lda #<MEMW16
        sta zp_tsrc
        lda tex_chunk                ; the chunk's place in its page
        clc
        adc ld_bank0
        and #3
        asl
        asl
        asl
        asl
        ora #>MEMW16
        clc
        adc ld_half
        sta zp_tsrc+1
        ldx #4
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
?pg     ldy #0                       ;   two bytes a pass into the window
        rep #$20
        .LONGA ON
?by     lda (zp_ptr),y
        sta [zp_tsrc],y
        iny
        iny
        bne ?by
        sep #$20
        .LONGA OFF
        inc zp_ptr+1
        inc zp_tsrc+1
        dex
        bne ?pg
        lda ld_half
        clc
        adc #4
        cmp #16                     ; 4 quarters fill the 4 KB bank
        bcs ?filled
        sta ld_half
        bra ?half
?filled ldx tex_chunk
        inx
        cpx ld_chunks
        bne ?chunk
        lda #BANK_EN | BANK_OVERHEAD ; park MEMAC back on the overhead bank
        sta VBXE_BANK_SEL
        rts                          ; (the 8x scratch holds a column of the
                                     ;  PREVIOUS level here -- same VRAM ...
.endp
        .endseg

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org dio2_resume

;--------------------------------------------------------------
; load_hud -- stream the status bar graphics (STBAR + the number glyphs, halved
;   horizontally by pack_hud.py) into VBXE VRAM $078000+, above the sprites.
;   Map-independent, so it is loaded once at boot.
;--------------------------------------------------------------
; (2026-09-28: load_palette is lights.asm gm_apply -- the palettes ride the
;  gamma block in SDRAM, no drive read)

; ---------------------------------------------------------------
; load_things2 -- the .things blob's SECOND read (2026-08-29).
; ---------------------------------------------------------------
thg2_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_things2
    .if THG_SECTORS > THINGS_SECT
        lda #<THINGS2_BASE
        sta ll_dst
        lda #>THINGS2_BASE
        sta ll_dst+1
        lda #[THG_SECTORS-THINGS_SECT]
        sta ll_left
        jsr read_urom
    .endif
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>load_dtab            ;   next byte of this segment -- fall through
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
    .if [THG_SECTORS-THINGS_SECT]*128 > [THINGS2_END+1-THINGS2_BASE]
        ert 'the .things blob piece 2 overruns THINGS2_BASE..END'
    .endif
        .endseg
        org thg2_resume

; ---------------------------------------------------------------
; load_dtab -- stream this level's death-animation frame table (pack_things
;   pack_death) into Rapidus SRAM bank $01 at DTAB_EXT. Chained off the end of
;   load_things2, so it runs inside the same SIO window with the OS ROM in.
;   Parked at DTBLD_BASE: read_ext drives SIOV, which must stay below $C000.
; ---------------------------------------------------------------
dtbld_resume = *
        org DTBLD_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_dtab
    .if DTB_SECTORS = 0
        rts
    .else
        lda #<DTB_SEC1
        sta ll_sec
        lda #>DTB_SEC1
        sta ll_sec+1
        lda #<DTB_SECTORS
        sta ll_stride
        lda #>DTB_SECTORS
        sta ll_stride+1
        jsr lvl_offset               ; + level index * DTB_SECTORS
        lda #<DTAB_EXT
        sta ll_dst
        lda #>DTAB_EXT
        sta ll_dst+1
        lda #DTB_SECTORS
        sta ll_left
        jsr read_ext
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>load_los             ;   next byte of this segment -- fall through
    .endif
.endp
        .endseg
    .if * > DTBLD_END+1
        ert 'load_dtab outgrew DTBLD_BASE..END (memory_map.inc)'
    .endif
        org dtbld_resume

; ---------------------------------------------------------------
; load_los -- stream this level's barrel line-of-sight table (tools/pack_los.py)
;   into Rapidus SRAM bank $01 at LOS_EXT. Chained off load_dtab, under the same
;   rule: read_ext drives SIOV, so this must live below $C000.
; ---------------------------------------------------------------
losld_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_los
    .if LOS_SECTORS = 0
        jmp load_sprcol              ; the T4 column tables still ride along
    .else
        lda #<LOS_SEC1
        sta ll_sec
        lda #>LOS_SEC1
        sta ll_sec+1
        lda #<LOS_SECTORS
        sta ll_stride
        lda #>LOS_SECTORS
        sta ll_stride+1
        jsr lvl_offset               ; + level index * LOS_SECTORS
        lda #<LOS_EXT
        sta ll_dst
        lda #>LOS_EXT
        sta ll_dst+1
        lda #LOS_SECTORS
        sta ll_left
        jsr read_ext
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>load_sprcol          ;   next byte of this segment -- fall through
    .endif
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org losld_resume

; ---------------------------------------------------------------
; load_sprcol -- stream this level's T4 sprite column tables (pack_things
;   emit_sprcol, contract tools/_verify_sprcrop.py) into Rapidus SRAM bank $01
;   at SPRCOL_EXT. The END of the per-level chain: it is the one that marks
;   the level SDRAM-resident. Same rule as its siblings: read_ext drives SIOV,
;   so it must stay below $C000 -- parked at SPRCLD_BASE.
; ---------------------------------------------------------------
scld_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_sprcol
    .if SPRC_SECTORS = 0
        jmp lvl_mark                 ; still the end of the per-level chain
    .else
        lda #<SPRC_SEC1
        sta ll_sec
        lda #>SPRC_SEC1
        sta ll_sec+1
        lda #<SPRC_SECTORS
        sta ll_stride
        lda #>SPRC_SECTORS
        sta ll_stride+1
        jsr lvl_offset               ; + level index * SPRC_SECTORS
        stz ll_dst                   ; SPRCOL_EXT is $0000: the blob owns the
        stz ll_dst+1                 ;   whole of bank SPRCOL_BANK from the bottom
                                     ;   (NOT $08 any more -- that bank is the
                                     ;   SDRAM level cache, memory_map.inc)
        lda #SPRCOL_BANK             ; ...and into ITS bank, not the map's;
        sta ll_bank                  ;   arena_init puts ll_bank back, this
        jsr sprcol_read              ;   block being 47 B with no room for it.
                                     ; MORE THAN 255 SECTORS -- ll_left is a
                                     ;   byte, so the read is passes of 128
        jsr arena_init               ; B1: FARENA clear + arena bounds + the
                                     ;   .spr's SDRAM base for spr_fget
                                      ; 2026-09-22 (drac030 inline): lvl_mark
        ldx current_level            ; the WHOLE per-level chain is in now:
        lda #1
        sta lvl_res,x
        rts
                                     ;   the next load of this level comes out
                                     ;   of the SDRAM cache (load_level_c)
    .endif
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
    .if SPRC_LAST > 128 || SPRC_PASSES < 1
        ert 'SPRC_PASSES/SPRC_LAST are not a 128-sector split of SPRC_SECTORS'
    .endif
    .if SPRC_PASSES > 255
        ert 'SPRC_PASSES does not fit the X counter -- widen sprcol_read'
    .endif
        .endseg
        org scld_resume

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_hud
        lda #<HUD_SEC1               ; the status bar: ONE DEFLATE stream
        sta ll_sec                   ;   (2026-09-26) -> MENU_BOUNCE (free:
        lda #>HUD_SEC1               ;   this runs before menu_boot claims
        sta ll_sec+1                 ;   it), then spr_fcopy hands the 24 KB
        stz inf_out                  ;   to VRAM through the MEMAC window
        stz inf_out+1
        lda #MENU_BOUNCE>>16
        sta inf_out+2
        jsr inflate
        stz sf_src
        stz sf_src+1
        lda #MENU_BOUNCE>>16
        sta sf_src+2
        lda #[HUD_BANK0*4096]&$FF
        sta sp_addr
        lda #[[HUD_BANK0*4096]>>8]&$FF
        sta sp_addr+1
        lda #[HUD_BANK0*4096]>>16
        sta sp_addr+2
        lda #[HUD_CHUNKS*4096]&$FF
        sta sf_size
        lda #[[HUD_CHUNKS*4096]>>8]&$FF
        sta sf_size+1
        jmp spr_fcopy
.endp
        .endseg
    .if HUD_CHUNKS*4096 > $10000
        ert 'load_hud hands spr_fcopy a 16-bit size'
    .endif

;--------------------------------------------------------------
; fin_pak -- X = fn_ep-1: that episode's packed finale -> MENU_BOUNCE ->
;   the arena, a 4 KB spr_fcopy call per chunk (sf_size is 16-bit and E3's
;   run is 37 chunks). fin_pklo/fin_nch sit in the finale overlay
;   (f_finale.asm), which is in place for the whole finale.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fin_pak
        lda fin_pklo,x
        sta ll_sec
        lda fin_pkhi,x
        sta ll_sec+1
        lda fin_nch,x
        sta ld_chunks                ; free: no other loader runs mid-finale
        stz inf_out
        stz inf_out+1
        lda #MENU_BOUNCE>>16
        sta inf_out+2
        jsr inflate
        stz sf_src
        stz sf_src+1
        lda #MENU_BOUNCE>>16
        sta sf_src+2
        stz sp_addr
        lda #[[FIN_ARBANK*4096]>>8]&$FF
        sta sp_addr+1
        lda #[FIN_ARBANK*4096]>>16
        sta sp_addr+2
?ch     stz sf_size
        lda #$10                     ; 4 KB a call
        sta sf_size+1
        jsr spr_fcopy                ; preserves sf_src/sp_addr (reads only)
        lda sf_src+1                 ; both cursors += $1000
        clc
        adc #$10
        sta sf_src+1
        bcc ?s1
        inc sf_src+2
?s1     lda sp_addr+1
        clc
        adc #$10
        sta sp_addr+1
        bcc ?s2
        inc sp_addr+2
?s2     dec ld_chunks
        bne ?ch
        rts
.endp
fin_pak_w1 jsr fin_pak               ; fin_load's jsl from the bank-0 overlay
        rtl
        .endseg

;--------------------------------------------------------------
; load_weapons -- stream the weapon psprite MASTER (tools/pack_weap.py) into
;   Rapidus SRAM at WEAP_EXT ($04:0000), once at boot -- the same read_ext
;   chunk walk load_sounds does for the SFX blob in bank $02. VRAM keeps only
;   the 24 KB active-weapon slot (WEAP_SLOT), which wp_wload (weapon.asm)
;--------------------------------------------------------------
wld_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_weapons
        lda #<WEAP_SEC1              ; weapons + colormap + sky: ONE DEFLATE
        sta ll_sec                   ;   stream (2026-09-26) across the whole
        lda #>WEAP_SEC1              ;   $04:0000-$05:E09F run -- inflate's
        sta ll_sec+1                 ;   24-bit cursor crosses the bank line
        stz inf_out                  ;   the old chunk walk stepped by hand
        stz inf_out+1
        lda #WEAP_EXT_BANK
        sta inf_out+2
        jsr inflate
        jmp load_music               ; TAIL CALL: the song rides behind, and
                                     ;   load_music restores ll_bank for
                                     ;   load_dtab/load_los itself.
.endp
        .endseg
; ---- per-level VRAM pool split (make_atr_doom.py -> atr_levels.inc) ---------
;   LVL_TEXCH:  how many 4 KB chunks of level n's .tex to stream to $018000
;   LVL_SPRSEG: the sprite REGION LIST (A2): 6 x (first bank, chunks) per
;               level, chunks 0 = end -- pool run above the .tex, then the
;               whole-frame spills into the fixed scraps (pack_things.SCRAPS)
;   Pure data read by load_textures/load_sprites with ,x (x = current_level).
        icl 'atr_levels.inc'
; ---- per-level DEFLATE directory (make_atr_doom.py, 2026-09-26) -----------
;   lvp_<r>_lo/_hi = each level's stream start for region r; a _hi column
;   sits exactly NUM_LEVELS behind its _lo (lvl_pak indexes one pointer).
;   Parked in the $561C-$5BC4 ram_map free hole.
LVPTAB_BASE equ $5940
lvptab_resume = *
        org LVPTAB_BASE
        icl 'lvlpak.inc'
; lvl_pak's per-region row: directory column (2), home base (3), step (3).
;   home(n) = base + n*step -- where the old tee parked the region's slot.
lvp_par dta a(lvp_map_lo)
        dta [PRE0_BASE]&$FF, [PRE0_BASE>>8]&$FF, [PRE0_BASE>>16]&$FF
        dta [LVL_SECTORS*128]&$FF, [[LVL_SECTORS*128]>>8]&$FF, [[LVL_SECTORS*128]>>16]&$FF
        dta a(lvp_thg_lo)
        dta [PRE1_BASE+[THG_SEC1-PRE1_SEC]*128]&$FF, [[PRE1_BASE+[THG_SEC1-PRE1_SEC]*128]>>8]&$FF, [[PRE1_BASE+[THG_SEC1-PRE1_SEC]*128]>>16]&$FF
        dta [THG_SECTORS*128]&$FF, [[THG_SECTORS*128]>>8]&$FF, [[THG_SECTORS*128]>>16]&$FF
        dta a(lvp_dtb_lo)
        dta [PRE1_BASE+[DTB_SEC1-PRE1_SEC]*128]&$FF, [[PRE1_BASE+[DTB_SEC1-PRE1_SEC]*128]>>8]&$FF, [[PRE1_BASE+[DTB_SEC1-PRE1_SEC]*128]>>16]&$FF
        dta [DTB_SECTORS*128]&$FF, [[DTB_SECTORS*128]>>8]&$FF, [[DTB_SECTORS*128]>>16]&$FF
        dta a(lvp_los_lo)
        dta [PRE1_BASE+[LOS_SEC1-PRE1_SEC]*128]&$FF, [[PRE1_BASE+[LOS_SEC1-PRE1_SEC]*128]>>8]&$FF, [[PRE1_BASE+[LOS_SEC1-PRE1_SEC]*128]>>16]&$FF
        dta [LOS_SECTORS*128]&$FF, [[LOS_SECTORS*128]>>8]&$FF, [[LOS_SECTORS*128]>>16]&$FF
        dta a(lvp_spc_lo)
        dta [PRE1_BASE+[SPRC_SEC1-PRE1_SEC]*128]&$FF, [[PRE1_BASE+[SPRC_SEC1-PRE1_SEC]*128]>>8]&$FF, [[PRE1_BASE+[SPRC_SEC1-PRE1_SEC]*128]>>16]&$FF
        dta [SPRC_SECTORS*128]&$FF, [[SPRC_SECTORS*128]>>8]&$FF, [[SPRC_SECTORS*128]>>16]&$FF
lvp_i   dta 0
    .if LVL_SEC1<>PRE0_SEC || DTB_SECTORS=0 || LOS_SECTORS=0 || SPRC_SECTORS=0
        ert 'lvl_pak prices five live regions with LVL_SEC1 = PRE0_SEC'
    .endif
    .if * > $5BC4+1
        ert 'the lvl_pak directory outgrew the $561C-$5BC4 free hole'
    .endif
        org lvptab_resume
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org wld_resume

; (load_sounds -- the SFX blob's equivalent of load_hud -- lives in sound.asm:
;  this $2000 segment is full to within a handful of bytes, and the $0400 sound
;  segment has room. It drives ld_chunks/ld_bank0/load_vram exactly like the
;  loaders above.)

;==============================================================
; SDRAM LEVEL CACHE (2026-08-03) -- the Rapidus carries 16 MB of SDRAM (linear
; at $08:0000-$EF:FFFF, always mapped, fast bus -- alt-src rapidus.cpp:128).
;==============================================================
prld_resume = *
        org PRELOAD_BASE

;--------------------------------------------------------------
; load_level_c -- both level-load call sites (boot + exit_level/pl_reload)
;   enter HERE (same 3 bytes as the old direct jsr): pick the SDRAM cache when
;   this level has already been streamed once, else the drive + the tee.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_level_c
        stz pk_valid                 ; new records -> new pickup list: the next
                                     ;   spr_pickup rebuilds it (pk_build).
        jsr lvl_first                ; first visit: depack the level's five
        jmp load_level               ;   streams onto the cache; ld_src = 1
.endp
        .endseg
lvl_res :32 dta 0                    ; 1 = level n's whole chain (map, tex, spr,
                                     ;   things, dtab, los) is in the SDRAM ...

;--------------------------------------------------------------
; lvl_mark -- the per-level chain finished: everything this level streams is
;   teed into SDRAM now, so flag it resident. (Reached from load_los, i.e.
;   only when load_things -> load_dtab -> load_los all completed.)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lvl_mark
        ldx current_level
        lda #1
        sta lvl_res,x
        rts
.endp

;--------------------------------------------------------------
; lvl_first / lvl_pak -- a level's FIRST load (2026-09-26): the plain slots
;   left the disk, so depack its five DEFLATE streams (lvlpak.inc directory)
;   straight onto the SDRAM cache homes the tee used to fill, mark the level
;   resident, and let the untouched chain read it all back with ld_src = 1.
;--------------------------------------------------------------
.proc lvl_first
        ldx current_level
        lda lvl_res,x
        bne ?res
        jsr lvl_pak
        ldx current_level
        lda #1
        sta lvl_res,x
?res    sta ld_src                   ; both paths arrive with A = 1
        rts
.endp

.proc lvl_pak
        stz lvp_i
?reg    ldx lvp_i
        lda lvp_par,x                ; the region's directory column: zp_tmp
        sta zp_tmp                   ;   -> lvp_<r>_lo, +NUM_LEVELS = _hi
        lda lvp_par+1,x              ;   (B1 code cannot patch its own
        sta zp_tmp+1                 ;   operands: sta abs writes DBR 0)
        lda lvp_par+2,x              ; the region's slot-0 home...
        sta inf_out
        lda lvp_par+3,x
        sta inf_out+1
        lda lvp_par+4,x
        sta inf_out+2
        lda lvp_par+5,x              ; ...and the slot stride, bytes (24-bit)
        sta m_a
        lda lvp_par+6,x
        sta m_a+1
        lda lvp_par+7,x
        sta m_b
        ldy current_level
        lda (zp_tmp),y               ; the stream's first sector
        sta ll_sec
        tya
        clc
        adc #NUM_LEVELS
        tay
        lda (zp_tmp),y
        sta ll_sec+1
        ldx current_level            ; home += level x stride (27 adds at
        beq ?go                      ;   most -- cold, like lvl_offset)
?add    clc
        lda inf_out
        adc m_a
        sta inf_out
        lda inf_out+1
        adc m_a+1
        sta inf_out+1
        lda inf_out+2
        adc m_b
        sta inf_out+2
        dex
        bne ?add
?go     jsr inflate
        lda lvp_i
        clc
        adc #8
        sta lvp_i
        cmp #5*8
        bcc ?reg
        rts
.endp
        .endseg
    .if * > PRELOAD_END+1
        ert 'load_level_c outgrew PRELOAD_BASE..END (memory_map.inc)'
    .endif
        org prld_resume




