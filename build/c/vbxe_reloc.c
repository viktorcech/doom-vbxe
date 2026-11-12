/* vbxe_reloc -- the bytes that move with VBXE's base ($D6xx -> $D7xx)
 * (2026-11-05: the C of build/py/vbxe_reloc.py, which it replaced).
 *
 * build_atr.ps1 assembles the engine twice, the second time with VBXE_D7 set
 * (build/doom_bsp_d7.xex). The two XEX files are the same block for block; the
 * bytes that differ are the high bytes of the register addresses, $D6 in one and
 * $D7 in the other. This sorts them by where the byte IS when it has to move:
 *
 *   * the code overlays split_menu_ovl lifts into menu.bin: their addresses in
 *     the menu's depack bounce go into mn_vtab (menu.asm), which menu_boot
 *     steps before the streams reach VRAM. Written into the XEX here.
 *   * bank $01 outside the EARLY run (split_b1): it comes off the disk under
 *     the R_Init dots, so its addresses go into b1l_vtab (inflate816.asm
 *     b1_late), which steps them after the depack. Written into the XEX here.
 *   * everything else -- bank 0 at its load address, bank $01 at its own:
 *     build/assets/code/vbxe_reloc.bin, 3 B an entry (lo, hi, bank), $FF $FF $FF
 *     at the end. make_atr_doom puts it in front of the XEX's RUN vector and
 *     the boot loader walks it when it has found the VBXE at $D7xx (b_reloc).
 *
 * Any other difference between the two assemblies fails the build: a register
 * address nobody steps is a game that hangs on such a machine, silently.
 *
 * Run right after the two assemblies, BEFORE split_menu_ovl and split_b1.
 *
 *     build/exe/vbxe_reloc.exe
 */
#include "code_map.h"

typedef struct { int lo, hi, off; } XB;

static int blocks(const unsigned char *d, int len, XB *out, int max)
{
    int i = (len >= 2 && d[0] == 0xFF && d[1] == 0xFF) ? 2 : 0, n = 0;
    while (i + 4 <= len) {
        int lo = d[i] | d[i + 1] << 8, hi = d[i + 2] | d[i + 3] << 8;
        if (lo == 0xFFFF) { i += 2; continue; }
        if (n < max) { out[n].lo = lo; out[n].hi = hi; out[n].off = i + 4; }
        n++;
        i += 4 + hi - lo + 1;
    }
    return n;
}

static void lab_or_die(const char *name, int *bank, int *addr)
{
    if (lab_find(name, bank, addr)) die("vbxe_reloc: %s is not in the .lab", name);
}

typedef struct { int addr, bank; } BOOTE;
static int boot_cmp(const void *a, const void *b)
{
    const BOOTE *x = (const BOOTE *)a, *y = (const BOOTE *)b;
    if (x->bank != y->bank) return x->bank - y->bank;
    return x->addr - y->addr;
}
static int int_cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

static XB BA[8192], BB[8192];

int main(void)
{
    char xd7[MAX_PATH], outp[MAX_PATH], mp[MAX_PATH];
    unsigned char *a, *b, *ld, *src;
    int al, bl, nba, nbb, i, k, nmk, nov, off_, nch, a_ch, b_ch, bounce, vmax, e0b, e0, e1b, e1, slen;
    LBLK *marks;
    OVL ovls[16];
    BOOTE *boot; int nboot = 0;
    int *grp[2], ngrp[2] = {0, 0}, *late, nlate = 0;
    cm_init();
    img(xd7, "build", "doom_bsp_d7.xex", 0, 0);
    img(outp, "build", "assets", "code", "vbxe_reloc.bin");
    if (GetFileAttributesA(XEX) == INVALID_FILE_ATTRIBUTES) die("vbxe_reloc: %s is missing -- assemble both passes first", XEX);
    if (GetFileAttributesA(xd7) == INVALID_FILE_ATTRIBUTES) die("vbxe_reloc: %s is missing -- assemble both passes first", xd7);
    a = read_file(XEX, &al);
    b = read_file(xd7, &bl);
    if (!a || !b) die("vbxe_reloc: cannot read the XEX pair");
    nba = blocks(a, al, BA, 8192);
    nbb = blocks(b, bl, BB, 8192);
    if (nba > 8192 || nbb > 8192) die("vbxe_reloc: more than 8192 XEX blocks");
    if (al != bl || nba != nbb || memcmp(BA, BB, nba * sizeof(XB)))
        die("vbxe_reloc: the two assemblies are not the same block for block -- something but an address depends on VBXE_D7");
    {
        int ll;
        ld = read_file(LST, &ll);
        if (!ld) die("vbxe_reloc: cannot read %s", LST);
        nmk = listing_blocks(ld, ll, &marks);
    }
    nov = overlays(ovls, &off_, &nch);
    /* the menu's two streams (make_atr_doom): chunks [0, A) and [LVCH, end) --
       MENU_A_CH, MENU_PLAIN_CH = A, P in make_atr_doom's source */
    rootp(mp, "build", "py", "make_atr_doom.py", 0);
    src = read_file(mp, &slen);
    if (!src) die("vbxe_reloc: cannot read %s", mp);
    {
        const char *pat = "MENU_A_CH, MENU_PLAIN_CH = ";
        int pl = (int)strlen(pat), found = 0;
        for (i = 0; i + pl <= slen && !found; i++) {
            int q, x = 0, y = 0, nx = 0, ny = 0;
            if (memcmp(src + i, pat, (size_t)pl)) continue;
            q = i + pl;
            while (q < slen && src[q] >= '0' && src[q] <= '9') { x = x * 10 + src[q] - '0'; q++; nx++; }
            if (!nx || q + 2 > slen || src[q] != ',' || src[q + 1] != ' ') continue;
            q += 2;
            while (q < slen && src[q] >= '0' && src[q] <= '9') { y = y * 10 + src[q] - '0'; q++; ny++; }
            if (!ny) continue;
            a_ch = x; b_ch = x + y; found = 1;
        }
        if (!found) die("vbxe_reloc: MENU_A_CH is not in make_atr_doom.py any more");
    }
    {
        long long v;
        if (equ("atr_layout.inc", "MENU_BOUNCE", &v)) die("vbxe_reloc: MENU_BOUNCE is not in atr_layout.inc");
        bounce = (int)v;
        if (equ("menu.asm", "MN_VMAX", &v)) die("vbxe_reloc: MN_VMAX is not in menu.asm");
        vmax = (int)v;
    }
    lab_or_die("b1e_start", &e0b, &e0);
    lab_or_die("b1e_end", &e1b, &e1);
    if (e0b != 1 || e1b != 1) die("vbxe_reloc: b1e_start/b1e_end are not bank-$01 labels");
    boot = (BOOTE *)malloc((al + 1) * sizeof(BOOTE));
    grp[0] = (int *)malloc((al + 1) * sizeof(int)); grp[1] = (int *)malloc((al + 1) * sizeof(int));
    late = (int *)malloc((al + 1) * sizeof(int));
    for (i = 0; i < nba; i++) {
        int lo = BA[i].lo, hi = BA[i].hi, off = BA[i].off, n = hi - lo + 1, inb1, st = -1, j;
        if (lo == 0x2E0 || lo == 0x2E2) continue;
        if (off + n <= al && !memcmp(a + off, b + off, (size_t)n)) continue;
        inb1 = 0;
        for (j = 0; j < nmk; j++) if (marks[j].bank && marks[j].lo == lo && marks[j].hi == hi) { inb1 = 1; break; }
        for (j = 0; j < nov; j++) if (ovls[j].stage == lo) st = j;     /* the dict: the last one wins */
        for (k = 0; k < n; k++) {
            int x, y;
            if (off + k >= al) break;
            x = a[off + k]; y = b[off + k];
            if (x == y) continue;
            if (x != 0xD6 || y != 0xD7)
                die("vbxe_reloc: block $%04X-$%04X +$%04X differs $%02X/$%02X -- not a register address", lo, hi, k, x, y);
            if (inb1) {
                if (e0 <= lo + k && lo + k < e1) { boot[nboot].addr = lo + k; boot[nboot].bank = 1; nboot++; }
                else late[nlate++] = lo + k;
            } else if (st >= 0) {
                int o = ovls[st].off, ch = o / CHUNK;
                if (ch < a_ch) grp[0][ngrp[0]++] = bounce + o + k;
                else if (ch >= b_ch) grp[1][ngrp[1]++] = bounce + o - b_ch * CHUNK + k;
                else die("vbxe_reloc: %s is in neither menu stream", ovls[st].who);
            } else { boot[nboot].addr = lo + k; boot[nboot].bank = 0; nboot++; }
        }
    }
    /* --- the overlays' table, into the XEX */
    {
        int bank, addr, hits = 0, h = -1, base, g;
        lab_or_die("mn_vtab", &bank, &addr);
        for (i = 0; i < nba; i++) {
            int lo = BA[i].lo, hi = BA[i].hi, j, inb1 = 0, instage = 0;
            if (!(lo <= addr && addr <= hi)) continue;
            for (j = 0; j < nmk; j++) if (marks[j].bank && marks[j].lo == lo && marks[j].hi == hi) { inb1 = 1; break; }
            for (j = 0; j < nov; j++) if (ovls[j].stage == lo) instage = 1;
            if (inb1 != (bank == 1)) continue;
            if (!(bank || !instage)) continue;
            hits++; h = i;
        }
        if (bank > 1 || hits != 1) die("vbxe_reloc: mn_vtab ($%02X:%04X) is in %d blocks", bank, addr, hits);
        base = BA[h].off + addr - BA[h].lo;
        for (g = 0; g < 2; g++) {
            int p = base + g * (vmax + 1) * 3, e;
            if (ngrp[g] > vmax)
                die("vbxe_reloc: %d overlay addresses in stream %c, mn_vtab holds %d -- raise MN_VMAX (menu.asm)", ngrp[g], "AB"[g], vmax);
            for (k = p; k < p + (vmax + 1) * 3 && k < al; k++) if (a[k]) die("vbxe_reloc: mn_vtab is not empty -- run on a fresh assembly");
            for (e = 0; e < ngrp[g]; e++) {
                if (p + e * 3 + 2 >= al) die("vbxe_reloc: mn_vtab runs past the XEX");
                a[p + e * 3] = (unsigned char)grp[g][e];
                a[p + e * 3 + 1] = (unsigned char)(grp[g][e] >> 8);
                a[p + e * 3 + 2] = (unsigned char)(grp[g][e] >> 16);
            }
            for (e = 0; e < 3; e++) if (p + ngrp[g] * 3 + e < al) a[p + ngrp[g] * 3 + e] = 0;
        }
    }
    /* --- the late runs' table (inflate816.asm b1l_vtab), into the XEX */
    {
        int bank, addr, hits = 0, h = -1, p, lmax;
        long long v;
        lab_or_die("b1l_vtab", &bank, &addr);
        if (equ("inflate816.asm", "B1L_VMAX", &v)) die("vbxe_reloc: B1L_VMAX is not in inflate816.asm");
        lmax = (int)v;
        for (i = 0; i < nba; i++) {
            int lo = BA[i].lo, hi = BA[i].hi, j, inb1 = 0;
            if (!(lo <= addr && addr <= hi)) continue;
            for (j = 0; j < nmk; j++) if (marks[j].bank && marks[j].lo == lo && marks[j].hi == hi) { inb1 = 1; break; }
            if (!inb1) continue;
            hits++; h = i;
        }
        if (bank != 1 || hits != 1) die("vbxe_reloc: b1l_vtab ($%02X:%04X) is in %d blocks", bank, addr, hits);
        if (nlate > lmax) die("vbxe_reloc: %d late bank-$01 addresses, b1l_vtab holds %d -- raise B1L_VMAX (inflate816.asm)", nlate, lmax);
        p = BA[h].off + addr - BA[h].lo;
        for (k = p; k < p + (lmax + 1) * 2 && k < al; k++) if (a[k]) die("vbxe_reloc: b1l_vtab is not empty -- run on a fresh assembly");
        qsort(late, nlate, sizeof(int), int_cmp);
        for (k = 0; k < nlate; k++) {
            if (p + k * 2 + 1 >= al) die("vbxe_reloc: b1l_vtab runs past the XEX");
            a[p + k * 2] = (unsigned char)late[k];
            a[p + k * 2 + 1] = (unsigned char)(late[k] >> 8);
        }
    }
    if (write_file(XEX, a, al)) die("vbxe_reloc: cannot write %s", XEX);
    /* --- ... and the boot loader's */
    {
        BUF t = {0};
        unsigned char e3[3];
        int n0 = 0, n1 = 0;
        qsort(boot, nboot, sizeof(BOOTE), boot_cmp);
        for (k = 0; k < nboot; k++) {
            e3[0] = (unsigned char)boot[k].addr; e3[1] = (unsigned char)(boot[k].addr >> 8); e3[2] = (unsigned char)boot[k].bank;
            bput(&t, e3, 3);
            if (boot[k].bank) n1++; else n0++;
        }
        e3[0] = e3[1] = e3[2] = 0xFF;
        bput(&t, e3, 3);
        if (write_file(outp, t.b, t.n)) die("vbxe_reloc: cannot write %s", outp);
        DeleteFileA(xd7);
        printf("vbxe_reloc: %d addresses for the boot loader (%d in bank 0, %d in bank $01), %d late bank-$01 (b1_late), %d + %d in the overlays\n",
               nboot, n0, n1, nlate, ngrp[0], ngrp[1]);
    }
    return 0;
}
