/* split_b1 -- DRAC_PLAN phase 2: the bank-$01 code out of the XEX, back in as
 * boot-time chunks (2026-11-05: the C of build/py/split_b1.py, which it
 * replaced).
 *
 * drac.txt: the code goes to $010000-$01FFFF. In the source that is a MADS
 * segment (`.segdef B1 ... 1`, `.segment B1` ... `.endseg` around each moved
 * proc): MADS lays the procs out one after another, checks the segment length,
 * and tags every label with bank 1. But MADS writes each segment block into the
 * XEX at its 16-bit address, and the boot loader would store that in BANK 0.
 *
 * So this runs right after mads and the menu overlay split, and:
 *   * finds the segment blocks -- the listing marks them "01,AAAA-EEEE>" -- and
 *     takes them out of the XEX;
 *   * writes build/assets/code/b1code.bin (the 64 KB bank image) + b1code.map
 *     (the used ranges) for the simulators and tools;
 *   * keeps only the EARLY run (b1e_start..b1e_end: inflate + the console) for
 *     the XEX and writes the two late runs to b1late.map -- make_atr_doom ships
 *     them as DEFLATE streams the boot reads under the R_Init dots;
 *   * puts the early bytes back as STAGED chunks: a segment at B1STAGE holding
 *     [dst lo, dst hi, len lo, len hi] + payload, then an INIT segment to
 *     b1_stage_copy, which copies the payload to $01:dst while the XEX is still
 *     loading. The chunks go right behind the XEX block that carries
 *     b1_stage_copy, so the bank is complete long before main runs.
 *
 *   build/exe/split_b1.exe [build/doom_bsp.xex]
 */
#include "code_map.h"

typedef struct { int lo, hi; const unsigned char *d; int n; } BLK;
typedef struct { int lo, hi; } RUN;

static int run_cmp(const void *a, const void *b)
{
    const RUN *x = (const RUN *)a, *y = (const RUN *)b;
    return x->lo != y->lo ? (x->lo < y->lo ? -1 : 1) : (x->hi < y->hi ? -1 : x->hi > y->hi);
}
/* runs_of(): sorted, adjacent ranges merged */
static int runs_of(RUN *in, int n, RUN *out)
{
    int k, m = 0;
    RUN *s = (RUN *)malloc((n + 1) * sizeof(RUN));
    memcpy(s, in, n * sizeof(RUN));
    qsort(s, n, sizeof(RUN), run_cmp);
    for (k = 0; k < n; k++) {
        if (m && s[k].lo == out[m - 1].hi + 1) out[m - 1].hi = s[k].hi;
        else out[m++] = s[k];
    }
    free(s);
    return m;
}
static void json_runs(const char *path, RUN *r, int n)
{
    FILE *f = fopen(path, "w");
    int k;
    if (!f) die("split_b1: cannot write %s", path);
    fputc('[', f);
    for (k = 0; k < n; k++) fprintf(f, "%s[%d, %d]", k ? ", " : "", r[k].lo, r[k].hi);
    fputc(']', f);
    fclose(f);
}
static int lab_or_none(const char *name, int *bank, int *addr) { return lab_find(name, bank, addr) == 0; }

int main(int argc, char **argv)
{
    char xex[MAX_PATH], b1bin[MAX_PATH], b1map[MAX_PATH], b1late[MAX_PATH], dir[MAX_PATH], *sl;
    unsigned char *xd, *ld, *im;
    int xl, ll, nb = 0, cap = 256, nmk, i, j, nused = 0, nkeep = 0, has_b1 = 0;
    BLK *blocks, *keep;
    LBLK *marks;
    RUN *used;
    cm_init();
    strcpy(xex, argc > 1 ? argv[1] : XEX);
    img(b1bin, "build", "assets", "code", "b1code.bin");
    img(b1map, "build", "assets", "code", "b1code.map");
    img(b1late, "build", "assets", "code", "b1late.map");
    strcpy(dir, b1bin);
    if ((sl = strrchr(dir, '\\')) != 0) { *sl = 0; CreateDirectoryA(dir, 0); }
    xd = read_file(xex, &xl);
    if (!xd) die("split_b1: cannot read %s", xex);
    /* xex_blocks: a repeated $FFFF header is skipped 2 bytes at a time */
    blocks = (BLK *)malloc(cap * sizeof(BLK));
    {
        int p = (xl >= 2 && xd[0] == 0xFF && xd[1] == 0xFF) ? 2 : 0;
        while (p + 4 <= xl) {
            int lo = xd[p] | xd[p + 1] << 8, hi = xd[p + 2] | xd[p + 3] << 8, n = hi - lo + 1, a, e;
            if (lo == 0xFFFF) { p += 2; continue; }
            if (nb == cap) { cap *= 2; blocks = (BLK *)realloc(blocks, cap * sizeof(BLK)); }
            a = p + 4 < xl ? p + 4 : xl; e = p + 4 + n < xl ? p + 4 + n : xl;
            blocks[nb].lo = lo; blocks[nb].hi = hi; blocks[nb].d = xd + a; blocks[nb].n = e > a ? e - a : 0;
            nb++;
            p += 4 + n;
        }
    }
    ld = read_file(LST, &ll);
    if (!ld) die("split_b1: cannot read %s", LST);
    nmk = listing_blocks(ld, ll, &marks);
    for (i = 0; i < nmk; i++) if (marks[i].bank) has_b1 = 1;
    im = (unsigned char *)calloc(0x10000, 1);
    if (!has_b1) {
        write_file(b1bin, im, 0x10000);
        json_runs(b1map, 0, 0);
        printf("split_b1: no bank segment in the listing\n");
        return 0;
    }
    keep = (BLK *)malloc((nb + 1) * sizeof(BLK));
    used = (RUN *)malloc((nmk + 1) * sizeof(RUN));
    for (i = 0, j = 0; i < nmk; i++) {
        int lo = marks[i].lo, hi = marks[i].hi, bk = marks[i].bank, k;
        BLK *blk = j < nb ? &blocks[j] : 0;
        if (!blk || blk->lo != lo || blk->hi != hi) {
            if (bk == 0) continue;               /* lifted overlay */
            die("split_b1: bank-$%02X listing block $%04X-$%04X is not in the XEX -- run order or listing is stale", bk, lo, hi);
        }
        j++;
        if (bk == 0) { keep[nkeep++] = *blk; continue; }
        if (bk != 1) die("split_b1: a segment in bank $%02X -- only $01 is wired", bk);
        for (k = 0; k < nused; k++) if (lo <= used[k].hi && hi >= used[k].lo) die("split_b1: bank-$01 blocks overlap at $%04X", lo);
        if (blk->n != hi - lo + 1) die("split_b1: block $%04X-$%04X is cut short in the XEX", lo, hi);
        memcpy(im + lo, blk->d, (size_t)blk->n);
        used[nused].lo = lo; used[nused].hi = hi; nused++;
    }
    {
        long long v;
        int stage, smax, cb, copier, e0b, e0, e1b, e1, base, nruns, nearly = 0, nlate = 0, nlr, ner, k, at = -1;
        RUN *runs = (RUN *)malloc((nused + 1) * sizeof(RUN)), *early = (RUN *)malloc((nused + 1) * sizeof(RUN));
        RUN *late = (RUN *)malloc((nused + 1) * sizeof(RUN)), *lruns = (RUN *)malloc((nused + 1) * sizeof(RUN));
        RUN *eruns = (RUN *)malloc((nused + 1) * sizeof(RUN));
        BUF out = {0}, chunks = {0};
        int nchunks = 0, total = 0, etot = 0;
        if (equ("memory_map.inc", "B1STAGE", &v)) die("split_b1: B1STAGE is not a plain equ in memory_map.inc");
        stage = (int)v;
        if (equ("memory_map.inc", "B1STAGE_MAX", &v)) die("split_b1: B1STAGE_MAX is not a plain equ in memory_map.inc");
        smax = (int)v;
        if (!lab_or_none("b1_stage_copy", &cb, &copier) || cb != 0)
            die("split_b1: b1_stage_copy is not a bank-0 label in doom_bsp.lab");
        nruns = runs_of(used, nused, runs);
        {
            int ok0 = lab_or_none("b1e_start", &e0b, &e0), ok1 = lab_or_none("b1e_end", &e1b, &e1);
            if (!ok0 || !ok1 || e0b != 1 || e1b != 1) die("split_b1: b1e_start/b1e_end are not bank-$01 labels");
        }
        for (k = 0; k < nused; k++) {
            if (e0 <= used[k].lo && used[k].hi < e1) early[nearly++] = used[k];
            if (used[k].hi < e0 || used[k].lo >= e1) late[nlate++] = used[k];
        }
        if (nearly + nlate != nused) die("split_b1: a bank-$01 block straddles the early run $%04X-$%04X", e0, e1 - 1);
        nlr = runs_of(late, nlate, lruns);
        if (equ("memory_map.inc", "B1SEG_BASE", &v)) die("split_b1: B1SEG_BASE is not a plain equ in memory_map.inc");
        base = (int)v;
        if (nlr != 2 || lruns[0].lo != base || lruns[0].hi >= e0 || lruns[1].lo != e1) {
            TXT t = {0};
            tf(&t, "split_b1: the late code is not one run from $%04X below the early run and one from b1e_end $%04X: [", base, e1);
            for (k = 0; k < nlr; k++) tf(&t, "%s[%d, %d]", k ? ", " : "", lruns[k].lo, lruns[k].hi);
            tf(&t, "] (inflate816.asm b1_late depacks exactly those two)");
            die("%s", t.b);
        }
        ner = runs_of(early, nearly, eruns);
        for (k = 0; k < ner; k++) {
            int a = eruns[k].lo, hi = eruns[k].hi, room = smax - 4;
            while (a <= hi) {
                int n = room < hi - a + 1 ? room : hi - a + 1;
                unsigned char h[8];
                int lo2 = stage, hi2 = stage + 4 + n - 1;
                h[0] = (unsigned char)lo2; h[1] = (unsigned char)(lo2 >> 8); h[2] = (unsigned char)hi2; h[3] = (unsigned char)(hi2 >> 8);
                bput(&chunks, h, 4);
                h[0] = (unsigned char)(a & 0xFF); h[1] = (unsigned char)(a >> 8); h[2] = (unsigned char)(n & 0xFF); h[3] = (unsigned char)(n >> 8);
                bput(&chunks, h, 4);
                bput(&chunks, im + a, n);
                h[0] = 0xE2; h[1] = 0x02; h[2] = 0xE3; h[3] = 0x02; h[4] = (unsigned char)(copier & 0xFF); h[5] = (unsigned char)(copier >> 8);
                bput(&chunks, h, 6);
                nchunks += 2;
                a += n;
            }
        }
        for (k = 0; k < nkeep; k++) if (keep[k].lo <= copier && copier <= keep[k].hi) { at = k; break; }
        if (at < 0) die("split_b1: no XEX block carries b1_stage_copy ($%04X)", copier);
        {
            unsigned char ff[2] = {0xFF, 0xFF};
            bput(&out, ff, 2);
            for (k = 0; k < nkeep; k++) {
                unsigned char h[4];
                h[0] = (unsigned char)keep[k].lo; h[1] = (unsigned char)(keep[k].lo >> 8);
                h[2] = (unsigned char)keep[k].hi; h[3] = (unsigned char)(keep[k].hi >> 8);
                bput(&out, h, 4);
                bput(&out, keep[k].d, keep[k].n);
                if (k == at) bput(&out, chunks.b, chunks.n);
            }
        }
        if (write_file(xex, out.b, out.n)) die("split_b1: cannot write %s", xex);
        write_file(b1bin, im, 0x10000);
        json_runs(b1map, runs, nruns);
        json_runs(b1late, lruns, nlr);
        for (k = 0; k < nruns; k++) total += runs[k].hi - runs[k].lo + 1;
        for (k = 0; k < nearly; k++) etot += early[k].hi - early[k].lo + 1;
        printf("split_b1: %d segment blocks, %d B into bank $01 (%d runs): %d B early -> %d staged chunks at $%04X, %d B late (b1late.map)\n",
               nused, total, nruns, etot, nchunks / 2, stage, total - etot);
    }
    return 0;
}
