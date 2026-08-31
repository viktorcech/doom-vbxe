;--------------------------------------------------------------
; RAM BUDGET: 948 B free, biggest contiguous block 128 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------
;==============================================================
; wolf3d - VBXE register & constant reference
;--------------------------------------------------------------
; Authoritative VBXE register map for FX core v1.20+
; (sources: vbxe.txt tutorial + vbxenavod1.txt + xdl-nove.txt).
;
; Addresses are absolute, assuming VBXE base at $D600.
; If runtime detection finds base at $D700, all VBXE_* targets
; shift by +$100 — handled by patching dispatch routines.
;==============================================================

;--------------------------------------------------------------
; Atari hardware registers (used by harness)
;--------------------------------------------------------------

SDMCTL          equ $022F     ; OS shadow of DMACTL
COLOR2_SH       equ $02C6     ; COLPF2 shadow (text background)
COLBK_SH        equ $02C8     ; COLBK shadow
RTCLOK2         equ $0013     ; jiffy counter, high byte (+1 every 256 VBLANKs)
RTCLOK3         equ $0014     ; jiffy frame counter
DMACTL          equ $D400
PAL             equ $D014     ; GTIA PAL register (low nibble bits 1-3:
                              ;   0 = NTSC, non-zero = PAL chip)
NMIEN           equ $D40E
PORTB           equ $D301
PMBASE          equ $D407

;--------------------------------------------------------------
; OS CIO entry + IOCB 0 fields (for the VBXE-missing error screen).
;--------------------------------------------------------------
CIOV            equ $E456
ICCOM           equ $0342     ; IOCB 0 command byte
ICBAL           equ $0344     ; buffer addr lo
ICBAH           equ $0345     ; buffer addr hi
ICBLL           equ $0348     ; buffer length lo
ICBLH           equ $0349     ; buffer length hi
ICAX1           equ $034A     ; aux 1 (OPEN: dir mode bits)
ICAX2           equ $034B     ; aux 2

;--------------------------------------------------------------
; VBXE registers (base $D600; +$100 when base is $D700)
;--------------------------------------------------------------
VBXE_BASE       equ $D600
VBXE_BASE_ALT   equ $D700

VBXE_VCTL       equ VBXE_BASE+$40   ; w: VIDEO_CONTROL  r: CORE_VERSION
VBXE_XDLA0      equ VBXE_BASE+$41   ; w: XDL addr lo   r: MINOR_REVISION
VBXE_XDLA1      equ VBXE_BASE+$42   ; w: XDL addr mid
VBXE_XDLA2      equ VBXE_BASE+$43   ; w: XDL addr hi
VBXE_CSEL       equ VBXE_BASE+$44   ; w: color index   (auto-inc on CB write)
VBXE_PSEL       equ VBXE_BASE+$45   ; w: palette index (0..3)
VBXE_CR         equ VBXE_BASE+$46   ; w: red
VBXE_CG         equ VBXE_BASE+$47   ; w: green
VBXE_CB         equ VBXE_BASE+$48   ; w: blue (commits, advances CSEL)
VBXE_COLMASK    equ VBXE_BASE+$49
VBXE_COLCLR     equ VBXE_BASE+$4A   ; r: COLDETECT
VBXE_BL_ADR0    equ VBXE_BASE+$50   ; w: blitter list addr lo
VBXE_BL_ADR1    equ VBXE_BASE+$51   ; w: blitter list addr mid
VBXE_BL_ADR2    equ VBXE_BASE+$52   ; w: blitter list addr hi
VBXE_BL_START   equ VBXE_BASE+$53   ; w: write 1 to start
VBXE_BL_BUSY    equ VBXE_BASE+$53   ; r: non-zero while running
VBXE_IRQ_CTL    equ VBXE_BASE+$54   ; w: IRQ control   r: IRQ status
VBXE_MEMAC_B    equ VBXE_BASE+$5D   ; legacy MEMAC-B
VBXE_MEMAC_CTL  equ VBXE_BASE+$5E   ; MEMAC-A control
VBXE_BANK_SEL   equ VBXE_BASE+$5F   ; MEMAC-A bank select

CORE_FX_1XX     equ $10        ; expected value of VBXE_VCTL (read)
MINOR_MASK      equ $70
MINOR_V120      equ $20

;--------------------------------------------------------------
; VIDEO_CONTROL bits (write to VBXE_VCTL)
;--------------------------------------------------------------
VC_XDL_ON       equ $01
VC_XCOLOR       equ $02
VC_NO_TRANS     equ $04        ; disable color-0 transparency
VC_TRANS15      equ $08

;--------------------------------------------------------------
; MEMAC-A control byte (VBXE_MEMAC_CTL)
;   bits 0-1: window size  00=4K 01=8K 10=16K 11=32K
;   bit  2:   MAE (ANTIC access enable)
;   bit  3:   MCE (CPU access enable)
;   bits 4-7: window base addr high nibble (window = $X000)
;--------------------------------------------------------------
MC_4K           equ %00
MC_8K           equ %01
MC_16K          equ %10
MC_32K          equ %11
MC_ANTIC        equ $04
MC_CPU          equ $08

;--------------------------------------------------------------
; MEMAC-A bank select byte (VBXE_BANK_SEL)
;   bit 7:    MGE (global enable)
;   bits 6-0: bank number  (4K banks: 0..$7F)
;--------------------------------------------------------------
BANK_EN         equ $80

;--------------------------------------------------------------
; XDL control bits — byte 1
;--------------------------------------------------------------
XDLC_TMON       equ $01
XDLC_GMON       equ $02
XDLC_OVOFF      equ $04
XDLC_MAPON      equ $08
XDLC_MAPOFF     equ $10
XDLC_RPTL       equ $20
XDLC_OVADR      equ $40
XDLC_OVSCRL     equ $80

;--------------------------------------------------------------
; XDL control bits — byte 2
;--------------------------------------------------------------
XDLC_CHBASE     equ $01
XDLC_MAPADR     equ $02
XDLC_MAPPAR     equ $04
XDLC_ATT        equ $08
XDLC_HR         equ $10
XDLC_LR         equ $20
XDLC_END        equ $80

;--------------------------------------------------------------
; XDL ATT byte 1 - overlay width and palette assignment
;--------------------------------------------------------------
OV_NARROW       equ $00        ; 256 hw pixels
OV_NORMAL       equ $01        ; 320 hw pixels
OV_WIDE         equ $02        ; 336 hw pixels
OV_PAL0         equ $00
OV_PAL1         equ $10
OV_PAL2         equ $20
OV_PAL3         equ $30
PF_PAL0         equ $00
PF_PAL1         equ $40
PF_PAL2         equ $80
PF_PAL3         equ $C0

;--------------------------------------------------------------
; XDL ATT byte 2 - priority bitmask
;   $FF = overlay above everything (safe across FX1.24/1.26)
;--------------------------------------------------------------
PRI_ALL         equ $FF

;--------------------------------------------------------------
; Blitter modes (BCB byte 20, bits 0-2)
;--------------------------------------------------------------
BLT_COPY        equ $00
BLT_BSTENCIL    equ $01        ; byte stencil (skip src=0)
BLT_ADD         equ $02
BLT_OR          equ $03
BLT_AND         equ $04
BLT_XOR         equ $05
BLT_NSTENCIL    equ $06        ; nibble stencil (HR)
BLT_NEXT        equ $08        ; chain to next BCB

;--------------------------------------------------------------
; BCB layout (21 bytes total)
;   0-2   src addr (3 bytes)
;   3-4   src step Y
;   5     src step X
;   6-8   dst addr
;   9-10  dst step Y
;   11    dst step X
;   12-13 width-1
;   14    height-1
;   15    AND mask (src)
;   16    XOR mask (src)
;   17    collision mask
;   18    zoom (zx 0-2, intlve 3, zy 4-6)
;   19    pattern (bit7=on, bits 0-5 = width-1)
;   20    ctrl (mode 0-2, NEXT 3, SX 4, SY 5, DX 6, DY 7)
;--------------------------------------------------------------
BCB_SIZE        equ 21
BCB_SRC_ADDR    equ 0
BCB_SRC_STEPY   equ 3
BCB_SRC_STEPX   equ 5
BCB_DST_ADDR    equ 6
BCB_DST_STEPY   equ 9
BCB_DST_STEPX   equ 11
BCB_WIDTH       equ 12
BCB_HEIGHT      equ 14
BCB_AND         equ 15
BCB_XOR         equ 16
BCB_COLLIDE     equ 17
BCB_ZOOM        equ 18
BCB_PATTERN     equ 19
BCB_CTRL        equ 20
