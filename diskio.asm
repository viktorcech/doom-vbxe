; AUTO-SPLIT from bsp_main.asm 2026-07-24 -- assembled in place via icl (verified
; byte-identical). All ATR/SIO streaming: the DCB constants, load_level,
; read_sectors, load_vram (wall textures + sprite pixels into VBXE banks) and the
; one-shot loaders relocated to $8640 (load_sprites, load_things).
;==============================================================
; Disk level streaming -- raw ATR sectors via SIO (no DOS).
;--------------------------------------------------------------
; Reuses the woll3d diskio approach (read_sectors): command $52, single-density
; 128-byte sectors, via the OS SIOV. The map blob streams to MAP_LOAD ($4000) --
; exactly where the old `ins` embed put it, so map_syms.inc addresses stay valid.
; The engine is BOOTED from the ATR (boot.asm loader in sectors 1-3), so the OS
; has cold-started cleanly -- VIMIRQ + serial IRQ vectors are valid and SIOV
; works. (Running the bare XEX without a clean boot left VIMIRQ -> RAM -> BRK on
; every IRQ -> SIO hang.) SIOV waits on the serial IRQ, so it runs with the OS
; VBI on + IRQs enabled (NMIEN=$40 + CLI), then main SEIs back.
;==============================================================
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
; load_level -- stream `current_level` from the ATR. woll3d-style fixed stride:
;   base_sec = LVL_SEC1 + current_level*LVL_SECTORS (atr_layout.inc).
;
;   FOUR REGIONS since format v3 (pack_map.py): the level does not fit the
;   $4000..$85FF slot even compacted, so the blob is, in read order,
;       [ LOW:  header, sectors, textab, yoffs ] -> $4000,     MAP_LOW_SECT
;       [ HIGH: ssectors, doors, doorlock      ] -> $D800,     MAP_HI_SECT
;       [ EXT:  verts, nodes, segoff           ] -> $01:0000,  MAP_EXT_SECT
;       [ SEG:  seg records + the automap tables] -> $03:0100,  MAP_SEG_SECT
;   The HIGH half is RAM UNDER THE OS ROM, and SIOV is IN that ROM, so it cannot
;   be read there directly: it goes through the staging buffer a page at a time
;   and is copied across with the ROM briefly banked out (same trick load_vram
;   uses for VBXE banks). The two bank regions stage the same way, with a 65816
;   long store instead of the ROM banking (read_ext). Every region length is a
;   whole number of sectors by construction.
;   2026-07-31: SEG is new. The seg table was 14,896 of the LOW region's 17,644 B
;   and moving it to a bank of its own is what turned $4C00-$85FF back into
;   ordinary RAM -- see tools/ram_map.py and map_syms.inc.
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
.proc lvl_offset
        ldx current_level
        beq ?done
?add    clc
        lda ll_sec
        adc ll_stride
        sta ll_sec
        lda ll_sec+1
        adc ll_stride+1
        sta ll_sec+1
        dex
        bne ?add
?done   rts
.endp

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
        lda #<MAP_LOW_SECT           ; --- LOW region: straight to $4000 ---
        sta ll_cnt
        lda #>MAP_LOW_SECT
        sta ll_cnt+1
        lda #<MAP_LOAD
        sta DBUFLO
        lda #>MAP_LOAD
        sta DBUFHI
        jsr read_sectors             ; leaves ll_sec on the first HIGH sector
        lda #<MAP_LOAD_HI            ; --- HIGH region: staged, then under the ROM ---
        sta ll_dst
        lda #>MAP_LOAD_HI
        sta ll_dst+1
        lda #MAP_HI_SECT
        sta ll_left
        jsr read_urom
        lda #<MAP_VERTS              ; --- EXT region: VERTS+NODES into the Rapidus
        sta ll_dst                   ;     SRAM bank (MAP_VERTS = offset 0 there)
        lda #>MAP_VERTS
        sta ll_dst+1
        lda #MAP_EXT_SECT
        sta ll_left
        jsr read_ext
        lda #<MAP_SEGS               ; --- SEG region: the seg records into a bank
        sta ll_dst                   ;     of their OWN (bank $01 is 40 KB full).
        lda #>MAP_SEGS               ;     MAP_SEGS = offset $100 in MAP_SEG_BANK,
        sta ll_dst+1                 ;     and the AUTOMAP's three side tables
                                     ;     (MAP_AMSEG/AMFLG/AMSEEN) ride at the
                                     ;     end of the SAME region -- which is why
                                     ;     the automap needed no loader and no
                                     ;     region of its own (pack_map._automap).
                                     ;     AMSEEN ships as zeros, so "nothing seen
                                     ;     yet" resets itself on every level load.
        lda #MAP_SEG_BANK
        sta ll_bank
        sta zp_sptr+2                ; ...and the seg pointer's bank byte, for good.
        sta zp_nodeptr+2             ;   NODES ride the SEG bank too (2026-08-18,
                                     ;   E2/E3: 28 B x 817 nodes blew EXT's $6400)
                                     ;   -- both seeds belong in init_level, but
                                     ;   that block is the FULL 128 B at $1B00
                                     ;   and the value is already in A here
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
    .if MAP_SEG_SECT > 510
        ert 'MAP_SEG_SECT > 510 sectors -- a Rapidus bank cannot hold it anyway'
    .endif

;--------------------------------------------------------------
; read_ext -- read ll_left sectors from ll_sec into bank MAP_EXT_BANK at offset
;   (ll_dst): the Rapidus SRAM at $01:0000+ (448 KB, always mapped -- Altirra
;   rapidus.cpp Init). SIOV cannot address other banks, so it stages exactly like
;   read_urom and the copy crosses with a 65816 long store (sta [zp],y works in
;   emulation mode). No ROM banking games needed: banks $01+ ignore PORTB.
;--------------------------------------------------------------
.proc read_ext
?pass   lda ll_left
        bne ?go
        rts
?go     cmp #8                       ; 8 sectors = the 1 KB staging buffer
        bcc ?part
        lda #8
?part   sta ll_pass
        sta ll_cnt
        lda #0
        sta ll_cnt+1
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
        clc
        lda zp_tsrc
        adc #128
        sta zp_tsrc
        lda zp_tsrc+1
        adc #0
        sta zp_tsrc+1
        clc
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
        jmp ?pass
.endp

;==============================================================
; The COLD half of the streaming code, moved out of the $2000 engine segment
; into the RAM the seg table vacated (2026-07-31). Every proc below runs only
; while a level (or the boot set) is loading, never in the frame path, and all
; of them drive SIOV -- so they must stay below $C000, which DISKIO2_BASE is.
; This is the first tenant of $4C00-$85FF; without it the SEG pass added to
; load_level pushed the engine segment onto wp_fenter at $26E7.
;==============================================================
dio2_resume = *
        org DISKIO2_BASE

;--------------------------------------------------------------
; read_urom -- read ll_left sectors from ll_sec into (ll_dst), which is RAM UNDER
;   THE OS ROM. SIOV is in that ROM, so it cannot write there directly: read into
;   the staging buffer 2 KB at a time and copy across with the ROM banked out.
;   Used for the map's HIGH region and for the THINGS blob.
;--------------------------------------------------------------
.proc read_urom
?pass   lda ll_left
        bne ?go
        rts
?go     cmp #8                       ; 8 sectors = 1 KB, the staging buffer's size
        bcc ?part                    ;   (2 KB until 2026-07-28, when tw_setup --
        lda #8                       ;   CODE -- moved to $1500; see TEX_STAGE)
?part   sta ll_pass
        sta ll_cnt
        lda #0
        sta ll_cnt+1
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
        ; the very first load. IRQs are also ON here (SIO needs them). So mask both
        ; for the duration of the copy; SIO is idle by now, so nothing is missed.
        sei
        lda #0
        sta NMIEN
        jsr rom_out
        ldx ll_pass                  ; copy ll_pass x 128 B (SECTORS, not pages: the
?sec    jsr cp128_ur                 ;   HIGH region is not a whole number of pages)
        clc                          ;   -- the 128 B loop itself is in fast win1
        lda zp_tsrc
        adc #128
        sta zp_tsrc
        lda zp_tsrc+1
        adc #0
        sta zp_tsrc+1
        clc
        lda zp_ptr
        adc #128
        sta zp_ptr
        lda zp_ptr+1
        adc #0
        sta zp_ptr+1
        dex
        bne ?sec
        jsr rom_in
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

    .if * > DISKIO2_END+1
        ert 'read_urom outgrew DISKIO2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; cp128_ur -- read_urom's inner copy: 128 B (zp_tsrc) -> (zp_ptr). Split out
;   of the win2 shell into a fast win1 crumb (2026-08-17): the shell now
;   fetches ~3 instructions per sector here instead of ~512 at the x11.2
;   chip rate.
;--------------------------------------------------------------
        org CP128_BASE
.proc cp128_ur
        ldy #127
?by     lda (zp_tsrc),y
        sta (zp_ptr),y
        dey
        bpl ?by
        rts
.endp
    .if * > CP128_END+1
        ert 'cp128_ur outgrew CP128_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; read_sectors -- read ll_cnt sectors from ll_sec into (DBUFLO/HI), advancing
;   both. All non-constant DCB fields are rewritten each sector (SIOV may touch
;   them; woll3d's diskio does the same). 16-bit ll_cnt so >255-sector maps work.
;   2026-08-03: ld_src = 1 serves the sector out of the Rapidus SDRAM preload
;   instead (PREn_BASE + (sec - PREn_SEC)*128 -- boot_loadall filled it), so
;   every loader above this becomes a memory copy with no code change. The
;   advance tail is shared; zp_ptr/zp_tsrc/m_a are free here (every caller
;   seeds its own copy pointers AFTER this returns; init_level re-parks
;   zp_ptr+2 on MAP_EXT_BANK when the loads are done).
;   2026-08-17: moved to DIOFAST (fast win1) from the win2 SIO block -- this
;   proc IS the per-sector cost of every load (the DCB setup, the SDRAM tee
;   and the cached-copy loop all run per sector), and win2's x11.2 fetch rate
;   made it the single biggest CPU item of a level transition (_prof_wi).
;--------------------------------------------------------------
        org DIOFAST_BASE
.proc read_sectors
?lp     lda ld_src
        beq ?sio
        jmp ?sdram                   ; the SIO body below is past branch range
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
        lda #0
        sta DBYTHI
        lda #$0F
        sta DTIMLO
        lda ll_sec
        sta DAUX1
        lda ll_sec+1
        sta DAUX2
        jsr SIOV
        sty sio_status               ; capture SIO status (Y on return; 1 = success)
        cpy #1                       ; --- the TEE: every good sector read off
        bne ?adv                     ;     the drive is ALSO parked in its SDRAM
        jsr pre_map                  ;     home, so the NEXT read of this level
        bcc ?adv                     ;     is a memory copy (lvl_res gate)
        lda DBUFLO
        sta zp_tsrc
        lda DBUFHI
        sta zp_tsrc+1
        ldy #127
?tee    lda (zp_tsrc),y
        sta [zp_ptr],y
        dey
        bpl ?tee
        jmp ?adv
?sdram  jsr pre_map                  ; zp_ptr = this sector's SDRAM home
        bcs ?insd                    ;   (defensive: outside the mapped ranges
        jmp ?sio                     ;   fall back to the drive)
?insd   lda DBUFLO                   ; the caller's target, indirect-capable
        sta zp_tsrc
        lda DBUFHI
        sta zp_tsrc+1
        ldy #127
?cp     lda [zp_ptr],y
        sta (zp_tsrc),y
        dey
        bpl ?cp
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
ld_src  dta 0                        ; 0 = SIO + the tee, 1 = SDRAM serves every
                                     ;   sector (load_level_c picks per level)

    .if * > DIOFAST_END+1
        ert 'read_sectors+ld_src outgrew DIOFAST_BASE..END (memory_map.inc)'
    .endif
        org DISKIO2B_BASE            ; 2026-08-11: the cold SIO block split in
                                     ;   two -- no single win2 hole held 637 B
                                     ;   (memory_map.inc DISKIO2/DISKIO2B)

;--------------------------------------------------------------
; pre_map -- zp_ptr(24) = ll_sec's home in the Rapidus SDRAM cache:
;   PREn_BASE + (ll_sec - PREn_SEC)*128, n by range. C=0 = the sector is in
;   neither mapped range (the XEX window, the unwired texture pool): the
;   caller stays on the drive and nothing is cached. Clobbers A/X, m_a.
;--------------------------------------------------------------
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
;   read_sectors auto-advances ll_sec, so it walks the whole texture region.
;   Single-level for now (level 0 .tex at TEX_SEC1). Restores MEMAC to bank $0A.
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
.proc load_textures
        lda pool_res                 ; already streamed -> nothing to do, on
        bne ?done                    ;   EVERY level including this one's reload
        inc pool_res
        lda #<POOL_SEC
        sta ll_sec
        lda #>POOL_SEC
        sta ll_sec+1
        lda #<POOL_SECTORS           ; a whole number of 8-sector passes: the
        sta ld_drain                 ;   packer pads the blob to 1 KB so this
        lda #>POOL_SECTORS           ;   loop needs no tail case
        sta ld_drain+1
?pass   lda ld_drain
        ora ld_drain+1
        beq ?done
        lda #<TEX_STAGE
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        lda #8
        sta ll_cnt
        lda #0
        sta ll_cnt+1
        jsr read_sectors
        sec
        lda ld_drain
        sbc #8
        sta ld_drain
        lda ld_drain+1
        sbc #0
        sta ld_drain+1
        jmp ?pass
?done   rts
.endp
pool_res dta 0                       ; 1 = the episode texture blob is in SDRAM


;--------------------------------------------------------------
; load_vram -- stream ld_chunks x 4KB from ll_sec into VBXE banks ld_bank0+n,
;   via the $B000 staging buffer and the MEMAC window. Used for the level's wall
;   textures (.tex) and its sprite pixels (.spr).
;--------------------------------------------------------------
.proc load_vram
        ldx #0
?chunk  stx tex_chunk
        lda tex_chunk               ; MEMAC window -> VBXE bank ld_bank0 + chunk
        clc
        adc ld_bank0
        ora #BANK_EN
        sta VBXE_BANK_SEL
        lda #0
        sta ld_half
?half   lda #<TEX_STAGE             ; read 8 sectors (1KB) -> staging
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        lda #8
        sta ll_cnt
        lda #0
        sta ll_cnt+1
        jsr read_sectors            ; advances ll_sec by 8
        lda #<TEX_STAGE             ; copy 4 pages staging -> MEMW window quarter
        sta zp_tsrc
        lda #>TEX_STAGE
        sta zp_tsrc+1
        lda #<MEMW
        sta zp_ptr
        lda #>MEMW
        clc
        adc ld_half                 ; pass n lands at MEMW + n*$400
        sta zp_ptr+1
        ldx #4
?pg     ldy #0
?by     lda (zp_tsrc),y
        sta (zp_ptr),y
        iny
        bne ?by
        inc zp_tsrc+1
        inc zp_ptr+1
        dex
        bne ?pg
        lda ld_half
        clc
        adc #4
        cmp #16                     ; 4 quarters fill the 4 KB bank
        bcs ?filled
        sta ld_half
        jmp ?half
?filled ldx tex_chunk
        inx
        cpx ld_chunks
        bne ?chunk
        lda #BANK_EN | BANK_OVERHEAD ; park MEMAC back on the overhead bank
        sta VBXE_BANK_SEL
        rts                          ; (the 8x scratch holds a column of the
                                     ;  PREVIOUS level here -- same VRAM
                                     ;  addresses, new pixels -- and tw_lastsrc
                                     ;  was invalidated for it. tw_expand's
                                     ;  cache is gone since 2026-08-14, so
                                     ;  there is nothing stale to serve.)
.endp

    .if * > DISKIO2B_END+1
        ert 'pre_map..load_vram outgrew DISKIO2B_BASE..END (memory_map.inc)'
    .endif
        org dio2_resume

;--------------------------------------------------------------
; load_hud -- stream the status bar graphics (STBAR + the number glyphs, halved
;   horizontally by pack_hud.py) into VBXE VRAM $078000+, above the sprites.
;   Map-independent, so it is loaded once at boot.
;--------------------------------------------------------------
; The palette is read into the SIO staging buffer and installed from there, so it
; costs no permanent RAM (that 768 B is now movers.asm).
pld_resume = *
        org PALLD_BASE
.proc load_palette
        lda #<PAL_SEC1
        sta ll_sec
        lda #>PAL_SEC1
        sta ll_sec+1
        ldx #0
?pal    stx pld_i                    ; one palette per pass: the staging buffer is
        lda #PAL_SECTORS             ;   1 KB and a palette is 768 B, so they cannot
        sta ll_cnt                   ;   all be read first and installed after
        lda #0
        sta ll_cnt+1
        lda #<TEX_STAGE
        sta DBUFLO
        lda #>TEX_STAGE
        sta DBUFHI
        jsr read_sectors             ; leaves ll_sec on the next palette
        ldx pld_i
        lda pld_psel,x
        jsr setup_palette            ; -> VBXE palette pld_psel[x]
        ldx pld_i
        inx
        cpx #PAL_COUNT
        bcc ?pal
        rts
.endp
; PAL_SLOTS (pack_textures.py) -> VBXE palette. The XDL names one of these four
; and update_flash swaps between them, so the order here IS the FL_PAL_* map in
; memory_map.inc: normal, damage red (2 levels), pickup gold.
pld_psel dta 1, 2, 3                 ; ...and NEVER palette 0: see FL_PAL_GOLD
pld_i    dta 0
    .if * > PALLD_END+1
        ert 'load_palette outgrew PALLD_BASE..END (memory_map.inc)'
    .endif
        org pld_resume

; ---------------------------------------------------------------
; load_dtab -- stream this level's death-animation frame table (pack_things
;   pack_death) into Rapidus SRAM bank $01 at DTAB_EXT. Chained off the end of
;   load_things, so it runs inside the same SIO window with the OS ROM in.
;   Parked at DTBLD_BASE: read_ext drives SIOV, which must stay below $C000.
; ---------------------------------------------------------------
dtbld_resume = *
        org DTBLD_BASE
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
        jmp load_los                 ; the barrel sight table rides along too
    .endif
.endp
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
        org LOSLD_BASE
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
        jmp load_sprcol              ; the T4 column tables ride along too
    .endif
.endp
    .if * > LOSLD_END+1
        ert 'load_los outgrew LOSLD_BASE..END (memory_map.inc)'
    .endif
        org losld_resume

; ---------------------------------------------------------------
; load_sprcol -- stream this level's T4 sprite column tables (pack_things
;   emit_sprcol, contract tools/_verify_sprcrop.py) into Rapidus SRAM bank $01
;   at SPRCOL_EXT. The END of the per-level chain: it is the one that marks
;   the level SDRAM-resident. Same rule as its siblings: read_ext drives SIOV,
;   so it must stay below $C000 -- parked at SPRCLD_BASE.
; ---------------------------------------------------------------
scld_resume = *
        org SPRCLD_BASE
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
        stz ll_dst+1                 ;   whole of bank $08 from the bottom
        lda #SPRCOL_BANK             ; ...and into ITS bank, not the map's;
        sta ll_bank                  ;   arena_init puts ll_bank back, this
        jsr sprcol_read              ;   block being 47 B with no room for it.
                                     ; MORE THAN 255 SECTORS -- ll_left is a
                                     ;   byte, so the read is passes of 128
        jsr arena_init               ; B1: FARENA clear + arena bounds + the
                                     ;   .spr's SDRAM base for spr_fget
        jmp lvl_mark                 ; the WHOLE per-level chain is in now:
                                     ;   the next load of this level comes out
                                     ;   of the SDRAM cache (load_level_c)
    .endif
.endp
    .if * > SPRCLD_END+1
        ert 'load_sprcol outgrew SPRCLD_BASE..END (memory_map.inc)'
    .endif
    .if SPRC_LAST > 128 || SPRC_PASSES < 1
        ert 'SPRC_PASSES/SPRC_LAST are not a 128-sector split of SPRC_SECTORS'
    .endif
    .if SPRC_PASSES > 255
        ert 'SPRC_PASSES does not fit the X counter -- widen sprcol_read'
    .endif
        org scld_resume

.proc load_hud
        lda #<HUD_SEC1
        sta ll_sec
        lda #>HUD_SEC1
        sta ll_sec+1
        lda #HUD_CHUNKS
        sta ld_chunks
        lda #HUD_BANK0
        sta ld_bank0
        jmp load_vram
.endp

;--------------------------------------------------------------
; load_weapons -- stream the weapon psprite MASTER (tools/pack_weap.py) into
;   Rapidus SRAM at WEAP_EXT ($04:0000), once at boot -- the same read_ext
;   chunk walk load_sounds does for the SFX blob in bank $02. VRAM keeps only
;   the 24 KB active-weapon slot (WEAP_SLOT), which wp_wload (weapon.asm)
;   fills from this master on a weapon switch.
;   The blob is 19 chunks (76 KB), so it CROSSES into bank $05: read_ext's
;   ll_dst is 16-bit and wraps at $FFFF, which is exactly when ll_bank must
;   step -- the ora test below catches the wrap between chunks (a chunk is
;   4 KB, so the wrap can only fall on a chunk boundary).
;   Parked at WEAPLD2_BASE: it drives SIOV, so it MUST stay below $C000.
;--------------------------------------------------------------
wld_resume = *
        org WEAPLD2_BASE
.proc load_weapons
        lda #<WEAP_SEC1
        sta ll_sec
        lda #>WEAP_SEC1
        sta ll_sec+1
        lda #0
        sta ll_dst                   ; WEAP_EXT = offset 0 of its bank
        sta ll_dst+1
        lda #WEAP_EXT_BANK
        sta ll_bank
        lda #WEAP_CHUNKS
        sta wld_i
?chunk  lda #32                      ; one 4 KB chunk per read_ext pass
        sta ll_left
        jsr read_ext                 ; carries ll_dst/ll_sec forward
        lda ll_dst
        ora ll_dst+1
        bne ?same                    ; ll_dst wrapped to 0: the run crossed
        inc ll_bank                  ;   into the next 64 KB SRAM bank
?same   dec wld_i
        bne ?chunk
        lda #MAP_EXT_BANK            ; put ll_bank back: load_dtab/load_los
        sta ll_bank                  ;   stream into bank $01 and assume it
        rts                          ; (this tail-called load_music while the
                                     ;  songs were in the build -- see the note
                                     ;  in snd_dispatch)
.endp
wld_i   dta 0
; ---- per-level VRAM pool split (make_atr_doom.py -> atr_levels.inc) ---------
;   LVL_TEXCH:  how many 4 KB chunks of level n's .tex to stream to $018000
;   LVL_SPRSEG: the sprite REGION LIST (A2): 6 x (first bank, chunks) per
;               level, chunks 0 = end -- pool run above the .tex, then the
;               whole-frame spills into the fixed scraps (pack_things.SCRAPS)
;   Pure data read by load_textures/load_sprites with ,x (x = current_level).
        icl 'atr_levels.inc'
    .if * > WEAPLD2_END+1
        ert 'load_weapons + atr_levels.inc outgrew WEAPLD2_BASE..END (memory_map.inc)'
    .endif
        org wld_resume

; (load_sounds -- the SFX blob's equivalent of load_hud -- lives in sound.asm:
;  this $2000 segment is full to within a handful of bytes, and the $0400 sound
;  segment has room. It drives ld_chunks/ld_bank0/load_vram exactly like the
;  loaders above.)

;==============================================================
; SDRAM LEVEL CACHE (2026-08-03) -- the Rapidus carries 16 MB of SDRAM (linear
; at $08:0000-$EF:FFFF, always mapped, fast bus -- alt-src rapidus.cpp:128).
; The first visit of a level streams from the drive EXACTLY as before, but
; read_sectors' TEE parks every good sector in its SDRAM home as it passes
; through -- so a REVISIT (death restart, coming back a level) is a pure
; memory copy: zero SIO, a fraction of a second. Boot time is unchanged.
; (The full preload-everything-at-boot variant was tried first and read
; 4.4 MB through SIOV: minutes of drive chatter even on accelerated setups.)
;==============================================================
prld_resume = *
        org PRELOAD_BASE

;--------------------------------------------------------------
; load_level_c -- both level-load call sites (boot + exit_level/pl_reload)
;   enter HERE (same 3 bytes as the old direct jsr): pick the SDRAM cache when
;   this level has already been streamed once, else the drive + the tee.
;--------------------------------------------------------------
.proc load_level_c
        ldx current_level
        lda lvl_res,x
        sta ld_src
        jmp load_level
.endp
lvl_res :32 dta 0                    ; 1 = level n's whole chain (map, tex, spr,
                                     ;   things, dtab, los) is in the SDRAM
                                     ;   cache -- set by the END of the chain
                                     ;   (load_los), so a load that dies midway
                                     ;   never fakes residency

;--------------------------------------------------------------
; lvl_mark -- the per-level chain finished: everything this level streams is
;   teed into SDRAM now, so flag it resident. (Reached from load_los, i.e.
;   only when load_things -> load_dtab -> load_los all completed.)
;--------------------------------------------------------------
.proc lvl_mark
        ldx current_level
        lda #1
        sta lvl_res,x
        rts
.endp
    .if * > PRELOAD_END+1
        ert 'load_level_c outgrew PRELOAD_BASE..END (memory_map.inc)'
    .endif
        org prld_resume




