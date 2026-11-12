/* split_menu_ovl -- lift the menu CODE overlays out of the XEX and into the
 * menu asset blob (2026-11-05: the C of build/py/split_menu_ovl.py, which it
 * replaced).
 *
 * menu.asm's third part is assembled for $1000 (MENU_RUN -- the per-frame render
 * arrays, which are dead RAM while the game is paused) but PARKED at $C000
 * (MNOVL_STAGE) with MADS's two-address ORG, so the block that comes out of the
 * assembler carries the right code with the wrong load address. It must never
 * reach base RAM: $C000 is the THINGS slot, and the boot loader writing 1 KB of
 * menu there would be overwritten by the first load_things anyway. The other
 * overlays (savegame, wi, f_finale, m_episode) are parked the same way.
 *
 * So this runs between mads and check_xex and does two things:
 *   * writes each block's payload into build/assets/menu/menu.bin at its
 *     chunk (pack_menu reserved them). load_menu streams the chunks into VBXE
 *     VRAM and mn_open copies one down on demand.
 *   * rewrites the XEX WITHOUT the blocks, so the ATR carries one copy of each,
 *     in the asset blob, and check_xex never sees a segment in reserved RAM.
 *
 * The addresses are read out of the sources (memory_map.inc, menu_syms.inc).
 * BANK-$01 BLOCKS ARE NOT CANDIDATES (2026-09-16): the B1 segment walks through
 * the $9000-$9FFF parking hole, and the listing marks its blocks "01,AAAA-EEEE>".
 *
 *   build/exe/split_menu_ovl.exe [build/doom_bsp.xex]
 */
#include "code_map.h"

typedef struct { int s, e, hdr, tail; } SEG;

/* segments(blob): (start, end, header offset, end offset) */
static int segments(const unsigned char *b, int len, SEG *out, int max)
{
    int i = 2, n = 0;
    while (i + 4 <= len) {
        int s = b[i] | b[i + 1] << 8, e = b[i + 2] | b[i + 3] << 8, k;
        if (s == 0xFFFF) { i += 2; continue; }
        k = e - s + 1;
        if (n < max) { out[n].s = s; out[n].e = e; out[n].hdr = i; out[n].tail = i + 4 + k; }
        n++;
        i += 4 + k;
    }
    return n;
}

int main(int argc, char **argv)
{
    char xex[MAX_PATH], binp[MAX_PATH], outp[MAX_PATH];
    OVL ovls[16];
    int nov, off, nch, shared = 0, i, mlen, xlen, nmk;
    unsigned char *menu, *blob, *ld;
    LBLK *marks;
    static SEG segs[4096];
    cm_init();
    strcpy(xex, argc > 1 ? argv[1] : XEX);
    nov = overlays(ovls, &off, &nch);
    for (i = 0; i < nov; i++) if (off <= ovls[i].off && ovls[i].off < off + nch * CHUNK) shared++;
    if (shared > nch)
        die("split_menu_ovl: %d overlays in the shared reserve, only %d chunks -- raise OVL_CHUNKS in build/py/pack_menu.py", shared, nch);
    rootp(binp, "build", "assets", "menu", "menu.bin");
    menu = read_file(binp, &mlen);
    if (!menu) die("split_menu_ovl: cannot read %s", binp);
    if (mlen < off + nch * CHUNK)
        die("split_menu_ovl: menu.bin is %d B, no room reserved at %d -- run build/py/pack_menu.py first", mlen, off);
    blob = read_file(xex, &xlen);
    if (!blob) die("split_menu_ovl: cannot read %s", xex);
    {
        int ll;
        ld = read_file(LST, &ll);
        if (!ld) die("split_menu_ovl: cannot read %s", LST);
        nmk = listing_blocks(ld, ll, &marks);
    }
    for (i = 0; i < nov; i++) {
        int ns = segments(blob, xlen, segs, 4096), k, hits = 0, h = -1, clen;
        for (k = 0; k < ns && k < 4096; k++) {
            int j, isb1 = 0;
            if (segs[k].s != ovls[i].stage) continue;
            for (j = 0; j < nmk; j++) if (marks[j].bank && marks[j].lo == segs[k].s && marks[j].hi == segs[k].e) { isb1 = 1; break; }
            if (isb1) continue;
            hits++; h = k;
        }
        if (hits != 1)
            die("split_menu_ovl: expected exactly ONE segment at $%04X, found %d -- did %s lose its two-address `org`?",
                ovls[i].stage, hits, ovls[i].who);
        {
            int a = segs[h].hdr + 4, b = segs[h].tail;
            if (a > xlen) a = xlen;
            if (b > xlen) b = xlen;
            clen = b > a ? b - a : 0;
            if (clen > CHUNK) die("split_menu_ovl: %s is %d B, a chunk holds %d", ovls[i].who, clen, CHUNK);
            if (mlen < ovls[i].off + CHUNK)
                die("split_menu_ovl: %s wants menu.bin +%d, the file is %d B", ovls[i].who, ovls[i].off, mlen);
            memcpy(menu + ovls[i].off, blob + a, (size_t)clen);
            memset(menu + ovls[i].off + clen, 0, (size_t)(CHUNK - clen));
            /* del blob[hdr:tail] */
            {
                int dh = segs[h].hdr < xlen ? segs[h].hdr : xlen, dt = segs[h].tail < xlen ? segs[h].tail : xlen;
                if (dt > dh) { memmove(blob + dh, blob + dt, (size_t)(xlen - dt)); xlen -= dt - dh; }
            }
        }
        printf("  %-12s overlay %4d B: $%04X block -> menu.bin +%d (chunk %d)\n",
               ovls[i].who, clen, ovls[i].stage, ovls[i].off, ovls[i].off / CHUNK);
    }
    img(outp, "build", "assets", "menu", "menu.bin");
    if (write_file(outp, menu, mlen)) die("split_menu_ovl: cannot write %s", outp);
    if (write_file(xex, blob, xlen)) die("split_menu_ovl: cannot write %s", xex);
    return 0;
}
