/* deflate_far -- raw DEFLATE with FAR matches: a match reaches back through
 * the whole blob, not 32 KB. A C program (2026-11-05; it replaced
 * deflate_far.py byte for byte), built by build_atr.ps1 with tools/tcc into
 * build/exe/deflate_far.exe. Binary data in on stdin, out on stdout; an
 * error is one line on stderr and exit code 1 (2: pack's stream does not
 * unpack to the data).
 *
 * The stream is RFC 1951 with its two reserved distance symbols in use:
 *     30   distance  32769 + 16 extra bits   (..   98304)
 *     31   distance  98305 + 21 extra bits   (.. 2195456)
 * Block types, headers and code order are DEFLATE's.
 *
 *   deflate_far pack [passes]   stdin: u32 LE len(base), base (a DEFLATE stream
 *                               of the data, zopfli's), the data. stdout: the
 *                               stream with far matches in -- base itself when
 *                               nothing was gained. Its parse is kept; every
 *                               stretch a far match codes in fewer bits is
 *                               replaced and each block's codes are rebuilt.
 *   deflate_far inflate         stdin: a blob that starts with a stream (plain
 *                               DEFLATE too). stdout: u32 LE bytes the stream
 *                               took, then the data.
 *   deflate_far unpack          stdin: a stream. stdout: the data.
 *   deflate_far hasfar          stdin: a stream. stdout: 1 if a distance is past
 *                               32 KB, else 0.
 *
 * pack keeps the order of the Python it replaced, ties included:
 *   Far       the numpy prefix doubling (stable sort by rank, next, index)
 *   _refit    including the iteration order of the set {p + ln, P[j]}
 *   _lengths  package-merge with sorted()'s stable tie order
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>

#define EXPORT static
typedef int64_t i64;
typedef uint64_t u64;

static const int LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const int LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0};
static const int DBASE[32] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    32769, 98305};
static const int DEXT[32] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 16, 21};
static const int ORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
#define NEAR 32768
#define FAR_MAX (98305 + (1 << 21) - 1)
#define UNUSED 11

static unsigned char FIXED_LL[288], FIXED_DL[32];
static int LSYM_S[259], LSYM_X[259], LSYM_V[259];

static void init_tables(void)
{
    static int done;
    int i, s, x, set[259];
    if (done) return;
    done = 1;
    for (i = 0; i < 288; i++) FIXED_LL[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
    for (i = 0; i < 32; i++) FIXED_DL[i] = 5;
    memset(set, 0, sizeof set);
    for (s = 0; s < 29; s++)
        for (x = 0; x < (1 << LEXT[s]); x++) {
            int L = LBASE[s] + x;
            if (L <= 258 && !set[L]) { set[L] = 1; LSYM_S[L] = s; LSYM_X[L] = LEXT[s]; LSYM_V[L] = x; }
        }
    LSYM_S[258] = 28; LSYM_X[258] = 0; LSYM_V[258] = 0;
}

static int dsym(i64 d)                    /* bisect_right(DBASE, d) - 1 */
{
    int t = 0;
    while (t < 31 && DBASE[t + 1] <= d) t++;
    return t;
}

/* ---- canonical codes, tables -------------------------------------------- */
static int codes(const unsigned char *len, int n, unsigned *out)
{
    int count[16], nxt[16], code = 0, b, s;
    memset(count, 0, sizeof count);
    for (s = 0; s < n; s++) count[len[s]]++;
    count[0] = 0;
    nxt[0] = 0;
    for (b = 1; b < 16; b++) { code = (code + count[b - 1]) << 1; nxt[b] = code; }
    for (s = 0; s < n; s++) {
        int l = len[s];
        out[s] = 0;
        if (l) {
            /* the code's binary digits (at least l of them) read backwards: an
               over-subscribed length has codes of more than l digits */
            unsigned c = (unsigned)nxt[l], r = 0;
            int k, m = l;
            while (m < 32 && (c >> m)) m++;
            for (k = 0; k < m; k++) { r = (r << 1) | (c & 1); c >>= 1; }
            out[s] = r;
            nxt[l]++;
        }
    }
    return 0;
}

/* the stream's next 15 bits -> symbol << 4 | length; -1 when a code does not
   fill its 2^(15-l) slots (only an over-subscribed length gets there) */
static int table(const unsigned char *len, int n, int *tab)
{
    unsigned c[288];
    int s;
    codes(len, n, c);
    memset(tab, 0, 32768 * sizeof(int));
    for (s = 0; s < n; s++) {
        int l = len[s], i;
        if (!l) continue;
        if (c[s] >= (1u << l)) return -1;
        for (i = (int)c[s]; i < 32768; i += 1 << l) tab[i] = (s << 4) | l;
    }
    return 0;
}

/* ---- parse ---------------------------------------------------------------- */
typedef struct {
    i64 *sy; int n, cap;                  /* every block's symbols, in order */
    int nb, bcap; int *bs;                /* block b = sy[bs[b] .. bs[b+1]) */
    unsigned char *ll, *dl; char *st;     /* 288 / 32 lengths a block, stored? */
    i64 used;                             /* the bytes the stream took */
} PB;

static void pb_free(PB *p)
{
    free(p->sy); free(p->bs); free(p->ll); free(p->dl); free(p->st);
    memset(p, 0, sizeof *p);
}

static int pb_push(PB *p, i64 s)
{
    if (p->n == p->cap) {
        int nc = p->cap ? p->cap * 2 : 65536;
        i64 *t = (i64 *)realloc(p->sy, (size_t)nc * sizeof(i64));
        if (!t) return -1;
        p->sy = t; p->cap = nc;
    }
    p->sy[p->n++] = s;
    return 0;
}

static int pb_block(PB *p, const unsigned char *ll, const unsigned char *dl, int stored)
{   /* closes block p->nb, whose symbols began at bs[nb] */
    if (p->nb + 1 >= p->bcap) {
        int nc = p->bcap ? p->bcap * 2 : 64;
        int *b = (int *)realloc(p->bs, (size_t)(nc + 1) * sizeof(int));
        unsigned char *l = (unsigned char *)realloc(p->ll, (size_t)nc * 288);
        unsigned char *d = (unsigned char *)realloc(p->dl, (size_t)nc * 32);
        char *s = (char *)realloc(p->st, (size_t)nc);
        if (b) p->bs = b;
        if (l) p->ll = l;
        if (d) p->dl = d;
        if (s) p->st = s;
        if (!b || !l || !d || !s) return -1;
        p->bcap = nc;
    }
    p->st[p->nb] = (char)stored;
    if (stored) { memset(p->ll + p->nb * 288, 0, 288); memset(p->dl + p->nb * 32, 0, 32); }
    else { memcpy(p->ll + p->nb * 288, ll, 288); memcpy(p->dl + p->nb * 32, dl, 32); }
    p->nb++;
    p->bs[p->nb] = p->n;
    return 0;
}

/* the stream as the reader sees it: its bytes, 8 zero bytes (the Python's
   padding: an index past them is an IndexError), then nothing but zeros */
static i64 DPAD;                          /* slen + 8 */
static i64 DALLOC;                        /* slen + 16: the buffer */

static u64 rd(const unsigned char *d, i64 bp)
{
    u64 v = 0;
    i64 o = bp >> 3;
    if (o + 8 <= DALLOC) memcpy(&v, d + o, 8);
    else { int k; for (k = 0; k < 8; k++) if (o + k < DALLOC) v |= (u64)d[o + k] << (8 * k); }
    return v >> (bp & 7);
}

static int LT[32768], DT[32768], CT[32768];

static const char *PERR;                  /* why parse() said -1 */
static const char IDXERR[] = "index out of range";   /* the Python's IndexError */
#define FAIL(m) do { PERR = (m); goto out; } while (0)

/* 0 = parsed (p filled), -1 = a stream that does not parse (PERR says why) */
static int parse(const unsigned char *s, int slen, PB *p)
{
    unsigned char *d = (unsigned char *)calloc((size_t)slen + 16, 1);
    i64 end = (i64)slen * 8, bp = 0;
    int r = -1;
    memset(p, 0, sizeof *p);
    PERR = "out of memory";
    if (!d) return -1;
    memcpy(d, s, (size_t)slen);
    DPAD = (i64)slen + 8;
    DALLOC = (i64)slen + 16;
    p->bs =(int *)malloc(65 * sizeof(int));
    if (!p->bs) goto out;
    p->bcap = 64; p->bs[0] = 0;
    p->ll = (unsigned char *)malloc(64 * 288);
    p->dl = (unsigned char *)malloc(64 * 32);
    p->st = (char *)malloc(64);
    if (!p->ll || !p->dl || !p->st) goto out;
    for (;;) {
        u64 v;
        int final, typ;
        unsigned char ll[288], dl[32];
        if (bp >= end) FAIL("the stream ends inside a block");
        v = rd(d, bp);
        final = (int)(v & 1); typ = (int)((v >> 1) & 3);
        bp += 3;
        if (typ == 3) FAIL("reserved block type 3");
        if (typ == 0) {
            /* LEN read from the padded bytes; the literals are what of
               d[i + 4 : i + 4 + n] the padded bytes hold */
            i64 i = (bp + 7) >> 3, k;
            int n;
            if (i + 1 >= DPAD) FAIL(IDXERR);
            n = d[i] | (d[i + 1] << 8);
            for (k = i + 4; k < i + 4 + n && k < DPAD; k++) if (pb_push(p, d[k])) FAIL("out of memory");
            bp = (i + 4 + n) * 8;
            if (pb_block(p, 0, 0, 1)) FAIL("out of memory");
            if (final) { r = 0; break; }
            continue;
        }
        if (typ == 1) {
            memcpy(ll, FIXED_LL, 288); memcpy(dl, FIXED_DL, 32);
        } else {
            int hlit, hdist, hclen, i, nl = 0;
            unsigned char cl[19], lens[320 + 140];
            v >>= 3;
            hlit = (int)(v & 31) + 257; hdist = (int)((v >> 5) & 31) + 1; hclen = (int)((v >> 10) & 15) + 4;
            bp += 14;
            memset(cl, 0, sizeof cl);
            for (i = 0; i < hclen; i++) {
                if ((bp >> 3) + 1 >= DPAD) FAIL(IDXERR);
                cl[ORDER[i]] =(unsigned char)(((d[bp >> 3] | (d[(bp >> 3) + 1] << 8)) >> (bp & 7)) & 7);
                bp += 3;
            }
            if (table(cl, 19, CT)) FAIL("bad code-length code");
            while (nl < hlit + hdist) {
                int e, l, sy, k, rep;
                unsigned char val;
                v = rd(d, bp);
                e = CT[v & 0x7FFF]; l = e & 15;
                if (!l) FAIL("bad code-length code");
                sy = e >> 4;
                v >>= l;
                if (sy < 16) { lens[nl++] = (unsigned char)sy; }
                else {
                    if (sy == 16) { if (!nl) FAIL("a repeat with no length before it"); val = lens[nl - 1]; rep = 3 + (int)(v & 3); l += 2; }
                    else if (sy == 17) { val = 0; rep = 3 + (int)(v & 7); l += 3; }
                    else { val = 0; rep = 11 + (int)(v & 127); l += 7; }
                    if (nl + rep > hlit + hdist) FAIL("a repeat runs past the code lengths");
                    for (k = 0; k < rep; k++) lens[nl++] = val;
                }
                bp += l;
            }
            memset(ll, 0, 288); memset(dl, 0, 32);
            memcpy(ll, lens, (size_t)hlit);
            memcpy(dl, lens + hlit, (size_t)hdist);
        }
        if (table(ll, 288, LT) || table(dl, 32, DT)) FAIL("over-subscribed code lengths");
        for (;;) {
            int e, l, sy, x, k, t;
            i64 ln;
            if (bp >= end) FAIL("the stream ends inside a block");
            v = rd(d, bp);
            e = LT[v & 0x7FFF]; l = e & 15;
            if (!l) FAIL("bad literal/length code");
            sy = e >> 4;
            if (sy < 256) { if (pb_push(p, sy)) FAIL("out of memory"); bp += l; continue; }
            if (sy == 256) { bp += l; break; }
            sy -= 257;
            if (sy > 28) FAIL("length symbol past 285");
            x = LEXT[sy];
            ln = LBASE[sy] + (i64)((v >> l) & ((1u << x) - 1));
            l += x;
            e = DT[(v >> l) & 0x7FFF]; k = e & 15;
            if (!k) FAIL("bad distance code");
            t = e >> 4;
            x = DEXT[t];
            if (pb_push(p, (ln << 24) | (DBASE[t] + (i64)((v >> (l + k)) & ((1u << x) - 1))))) FAIL("out of memory");
            bp += l + k + x;
        }
        if (pb_block(p, ll, dl, 0)) FAIL("out of memory");
        if (final) { r = 0; break; }
    }
    p->used = (bp + 7) >> 3;
out:
    free(d);
    if (r) pb_free(p);
    return r;
}

/* the stream unpacks to exactly data[0..n)? 1 yes, 0 no, -1 Python raises */
static int unpack_eq(const unsigned char *s, int slen, const unsigned char *data, int n)
{
    PB p;
    unsigned char *o;
    i64 len = 0;
    int i, r = 1;
    if (parse(s, slen, &p)) return -1;
    o = (unsigned char *)malloc((size_t)n + 1);
    if (!o) { pb_free(&p); return -1; }
    for (i = 0; i < p.n && r == 1; i++) {
        i64 sy = p.sy[i];
        if (sy < 256) {
            if (len >= n || (unsigned char)sy != data[len]) r = 0;
            else o[len++] = (unsigned char)sy;
        } else {
            i64 ln = sy >> 24, dd = sy & 0xFFFFFF, q = len - dd, k;
            if (q < 0) { r = -1; break; }
            for (k = 0; k < ln; k++) {
                if (len >= n || o[q + k] != data[len]) { r = 0; break; }
                o[len] = o[q + k]; len++;
            }
        }
    }
    if (r == 1 && len != n) r = 0;
    free(o);
    pb_free(&p);
    return r;
}

/* ---- Far: the suffix order --------------------------------------------- */
static int *SA, *INV;
static const unsigned char *FD;
static int FN;

static int far_init(const unsigned char *data, int n)
{
    int *rank = (int *)malloc((size_t)n * sizeof(int)), *nxt = (int *)malloc((size_t)n * sizeof(int));
    int *tmp = (int *)malloc((size_t)n * sizeof(int)), *nr = (int *)malloc((size_t)n * sizeof(int));
    int *sa = (int *)malloc((size_t)n * sizeof(int)), *cnt = (int *)malloc(((size_t)n + 3) * sizeof(int));
    int i, k = 1, maxr = 255;
    if (!rank || !nxt || !tmp || !nr || !sa || !cnt) return -1;
    for (i = 0; i < n; i++) rank[i] = data[i];
    for (;;) {
        int m, t;
        for (i = 0; i < n; i++) nxt[i] = i + k < n ? rank[i + k] + 1 : 0;
        /* stable by next (from index order), then stable by rank */
        m = maxr + 2;
        memset(cnt, 0, (size_t)(m + 1) * sizeof(int));
        for (i = 0; i < n; i++) cnt[nxt[i] + 1]++;
        for (i = 0; i < m; i++) cnt[i + 1] += cnt[i];
        for (i = 0; i < n; i++) tmp[cnt[nxt[i]]++] = i;
        m = maxr + 1;
        memset(cnt, 0, (size_t)(m + 1) * sizeof(int));
        for (i = 0; i < n; i++) cnt[rank[i] + 1]++;
        for (i = 0; i < m; i++) cnt[i + 1] += cnt[i];
        for (i = 0; i < n; i++) { int j = tmp[i]; sa[cnt[rank[j]]++] = j; }
        nr[sa[0]] = 0;
        for (t = 1; t < n; t++) {
            int a = sa[t], b = sa[t - 1];
            nr[a] = nr[b] + (rank[a] != rank[b] || nxt[a] != nxt[b]);
        }
        maxr = nr[sa[n - 1]];
        memcpy(rank, nr, (size_t)n * sizeof(int));
        if (k >= 2048 || maxr == n - 1) break;
        k *= 2;
    }
    for (i = 0; i < n; i++) rank[sa[i]] = i;
    free(nxt); free(tmp); free(nr); free(cnt);
    SA = sa; INV = rank; FD = data; FN = n;
    return 0;
}

static void far_free(void) { free(SA); free(INV); SA = INV = 0; }

static int far_best(int p, int *bq_out)
{
    int lim = p - NEAR, r, cap, bl = 0, bq = 0, step;
    if (lim <= 0) { *bq_out = 0; return 0; }
    r = INV[p];
    cap = FN - p < 258 * 64 ? FN - p : 258 * 64;
    for (step = -1; step <= 1; step += 2) {
        int j = r + step, c;
        for (c = 0; c < 64; c++) {
            int q;
            if (j < 0 || j >= FN) break;
            q = SA[j];
            if (q < lim && p - q <= FAR_MAX) {
                int l = 0;
                while (l < cap && FD[p + l] == FD[q + l]) l++;
                if (l > bl) { bl = l; bq = q; }
                break;
            }
            j += step;
        }
    }
    *bq_out = bq;
    return bl;
}

/* ---- _refit ---------------------------------------------------------------- */
typedef struct { i64 *sy; int n, cap; int *bs; } OB;   /* bs[b] .. bs[b+1] */

static int ob_push(OB *o, i64 s)
{
    if (o->n == o->cap) {
        int nc = o->cap ? o->cap * 2 : 65536;
        i64 *t = (i64 *)realloc(o->sy, (size_t)nc * sizeof(i64));
        if (!t) return -1;
        o->sy = t; o->cap = nc;
    }
    o->sy[o->n++] = s;
    return 0;
}

static const unsigned char *EL, *ED;    /* est: nb x 288, nb x 32 */

static i64 price(int b, i64 s)
{
    const unsigned char *ll = EL + b * 288, *dl = ED + b * 32;
    int L, t;
    if (s < 256) return ll[s] ? ll[s] : UNUSED;
    L = (int)(s >> 24);
    t = dsym(s & 0xFFFFFF);
    return (ll[257 + LSYM_S[L]] ? ll[257 + LSYM_S[L]] : UNUSED) + LSYM_X[L]
         + (dl[t] ? dl[t] : (t < 30 ? UNUSED : 6)) + DEXT[t];
}

static int nchunks(int total, int *out)      /* _chunks */
{
    int k = 0, r = total % 258, i;
    for (i = 0; i < total / 258; i++) out[k++] = 258;
    if (r) {
        if (r < 3 && k) { out[k - 1] -= 3 - r; r = 3; }
        out[k++] = r;
    }
    return k;
}

static int bisr(const int *P, int len, i64 x)   /* bisect_right */
{
    int lo = 0, hi = len;
    while (lo < hi) { int mid = (lo + hi) >> 1; if (x < P[mid]) hi = mid; else lo = mid + 1; }
    return lo;
}

/* CPython's set of two ints, {a, b}: which one does iteration give first?
   (a 8-slot table, a inserted first, b probes i*5 + 1 + perturb) */
static int set_order_b_first(i64 a, i64 b)
{
    u64 mask = 7, sa = (u64)a & mask, i = (u64)b & mask, perturb = (u64)b;
    while (i == sa) { perturb >>= 5; i = (i * 5 + 1 + perturb) & mask; }
    return i < sa;
}


static int refit(const unsigned char *data, const PB *bl, OB *o)
{
    int n = bl->n, nb = bl->nb, i, b, k, margin = 3, r = -1, curb = 0;
    int *P = (int *)malloc(((size_t)n + 1) * sizeof(int)), *B = (int *)malloc(((size_t)n + 1) * sizeof(int));
    i64 *C = (i64 *)malloc(((size_t)n + 1) * sizeof(i64)), skip = 0;
    const i64 *F = bl->sy;
    int ch[16384];
    o->n = 0;
    o->bs = (int *)malloc(((size_t)nb + 1) * sizeof(int));
    if (!P || !B || !C || !o->bs) goto out;
    {
        int p = 0;
        for (b = 0; b < nb; b++)
            for (k = bl->bs[b]; k < bl->bs[b + 1]; k++) {
                P[k] = p; B[k] = b;
                p += F[k] < 256 ? 1 : (int)(F[k] >> 24);
            }
        P[n] = p;
    }
    C[0] = 0;
    for (i = 0; i < n; i++) C[i + 1] = C[i] + price(B[i], F[i]);
    o->bs[0] = 0;
    i = 0;
    while (i < n) {
        int p = P[i];
        i64 s = F[i];
        int bb = B[i], ln, q;
        while (curb < bb) o->bs[++curb] = o->n;
        if (p < skip) {
            int e = P[i + 1];
            if (e > skip) {
                if (e - skip >= 3) { if (ob_push(o, ((i64)(e - skip) << 24) | (s & 0xFFFFFF))) goto out; }
                else { i64 c; for (c = skip; c < e; c++) if (ob_push(o, data[c])) goto out; }
                skip = e;
            }
            i++;
            continue;
        }
        ln = far_best(p, &q);
        if (ln >= 4) {
            int d = p - q, have = 0, ne, ci, j, cand[2];
            i64 gain = 0;
            int best_e = 0;
            j = bisr(P, n + 1, (i64)p + ln) - 1;
            if ((i64)p + ln == P[j]) { cand[0] = p + ln; ne = 1; }
            else if (set_order_b_first((i64)p + ln, P[j])) { cand[0] = P[j]; cand[1] = p + ln; ne = 2; }
            else { cand[0] = p + ln; cand[1] = P[j]; ne = 2; }
            for (ci = 0; ci < ne; ci++) {
                int e = cand[ci], nc, c;
                i64 old, tail, nw;
                if (e - p < 4) continue;
                j = bisr(P, n + 1, e) - 1;
                if (j < n && P[j] < e) {
                    int rem = P[j + 1] - e;
                    old = C[j + 1] - C[i];
                    if (rem >= 3) tail = price(B[j], ((i64)rem << 24) | (F[j] & 0xFFFFFF));
                    else { tail = 0; for (c = 0; c < rem; c++) tail += price(B[j], data[e + c]); }
                } else { old = C[j] - C[i]; tail = 0; }
                nc = nchunks(e - p, ch);
                nw = tail;
                for (c = 0; c < nc; c++) nw += price(bb, ((i64)ch[c] << 24) | d);
                if (old - nw > margin && (!have || old - nw > gain)) { have = 1; gain = old - nw; best_e = e; }
            }
            if (have) {
                int nc = nchunks(best_e - p, ch), c;
                for (c = 0; c < nc; c++) if (ob_push(o, ((i64)ch[c] << 24) | d)) goto out;
                skip = best_e;
                continue;
            }
        }
        if (ob_push(o, s)) goto out;
        skip = P[i + 1];
        i++;
    }
    while (curb < nb) o->bs[++curb] = o->n;
    r = 0;
out:
    free(P); free(B); free(C);
    return r;
}

/* ---- writing ------------------------------------------------------------- */
typedef struct { i64 w; int l, r, sym; } NODE;
static NODE POOL[300 * 20];

static void count_leaves(int k, unsigned char *out)
{
    if (POOL[k].sym >= 0) { out[POOL[k].sym]++; return; }
    count_leaves(POOL[k].l, out);
    count_leaves(POOL[k].r, out);
}

static void lengths(const i64 *freq, int nf, int limit, unsigned char *out)
{
    int items[300], ni = 0, pk[600], npk, np = 0, i, j, round, pkg[300], ng, a, b, m, merged[600];
    memset(out, 0, (size_t)nf);
    for (i = 0; i < nf; i++)
        if (freq[i]) { POOL[np].w = freq[i]; POOL[np].sym = i; POOL[np].l = POOL[np].r = -1; items[ni++] = np++; }
    /* stable insertion sort by weight (equal weights keep symbol order) */
    for (i = 1; i < ni; i++) {
        int x = items[i];
        j = i - 1;
        while (j >= 0 && POOL[items[j]].w > POOL[x].w) { items[j + 1] = items[j]; j--; }
        items[j + 1] = x;
    }
    if (ni == 1) { out[POOL[items[0]].sym] = 1; return; }
    memcpy(pk, items, (size_t)ni * sizeof(int));
    npk = ni;
    for (round = 0; round < limit - 1; round++) {
        ng = 0;
        for (i = 0; i + 1 < npk; i += 2) {
            POOL[np].w = POOL[pk[i]].w + POOL[pk[i + 1]].w;
            POOL[np].l = pk[i]; POOL[np].r = pk[i + 1]; POOL[np].sym = -1;
            pkg[ng++] = np++;
        }
        a = b = m = 0;
        while (a < ni || b < ng) {
            if (b >= ng || (a < ni && POOL[items[a]].w <= POOL[pkg[b]].w)) merged[m++] = items[a++];
            else merged[m++] = pkg[b++];
        }
        memcpy(pk, merged, (size_t)m * sizeof(int));
        npk = m;
    }
    m = 2 * ni - 2;
    if (m > npk) m = npk;
    for (i = 0; i < m; i++) count_leaves(pk[i], out);
}

typedef struct { int s, x, v; } RLE;

static int rle(const unsigned char *seq, int n, RLE *out)
{
    int k = 0, i = 0;
    while (i < n) {
        int v = seq[i], j = i, run;
        while (j < n && seq[j] == v) j++;
        run = j - i;
        i = j;
        if (v == 0) {
            while (run >= 11) { int c = run < 138 ? run : 138; out[k].s = 18; out[k].x = 7; out[k].v = c - 11; k++; run -= c; }
            if (run >= 3) { out[k].s = 17; out[k].x = 3; out[k].v = run - 3; k++; run = 0; }
        } else {
            out[k].s = v; out[k].x = 0; out[k].v = 0; k++;
            run--;
            while (run >= 3) { int c = run < 6 ? run : 6; out[k].s = 16; out[k].x = 2; out[k].v = c - 3; k++; run -= c; }
        }
        while (run-- > 0) { out[k].s = v; out[k].x = 0; out[k].v = 0; k++; }
    }
    return k;
}

typedef struct { unsigned char *b; int n, cap; u64 acc; int nb; int err; } BW;

static void bw_byte(BW *w, unsigned char c)
{
    if (w->n == w->cap) {
        int nc = w->cap ? w->cap * 2 : 65536;
        unsigned char *t = (unsigned char *)realloc(w->b, (size_t)nc);
        if (!t) { w->err = 1; return; }
        w->b = t; w->cap = nc;
    }
    w->b[w->n++] = c;
}

static void put(BW *w, u64 v, int k)
{
    w->acc |= v << w->nb;
    w->nb += k;
    while (w->nb >= 8) { bw_byte(w, (unsigned char)w->acc); w->acc >>= 8; w->nb -= 8; }
}

static void align(BW *w) { if (w->nb) put(w, 0, 8 - w->nb); }

/* one symbol's (value, bits) under codes lc/ll, dc/dl */
static int symbits(i64 s, const unsigned *lc, const unsigned char *ll, const unsigned *dc,
                   const unsigned char *dl, u64 *val)
{
    int L, ls, t, k;
    i64 d;
    u64 v;
    if (s < 256) { *val = lc[s]; return ll[s]; }
    L = (int)(s >> 24); ls = LSYM_S[L];
    d = s & 0xFFFFFF; t = dsym(d);
    v = lc[257 + ls]; k = ll[257 + ls];
    v |= (u64)LSYM_V[L] << k; k += LSYM_X[L];
    v |= (u64)dc[t] << k; k += dl[t];
    v |= (u64)(d - DBASE[t]) << k; k += DEXT[t];
    *val = v;
    return k;
}

static i64 body_bits(const i64 *sy, int n, const unsigned *lc, const unsigned char *ll,
                     const unsigned *dc, const unsigned char *dl)
{
    i64 bits = 0;
    int i;
    u64 v;
    for (i = 0; i < n; i++) bits += symbits(sy[i], lc, ll, dc, dl, &v);
    return bits + ll[256];
}

static void body_put(BW *w, const i64 *sy, int n, const unsigned *lc, const unsigned char *ll,
                     const unsigned *dc, const unsigned char *dl)
{
    int i, k;
    u64 v;
    for (i = 0; i < n; i++) { k = symbits(sy[i], lc, ll, dc, dl, &v); put(w, v, k); }
    put(w, lc[256], ll[256]);
}

static int encode(const unsigned char *data, const OB *o, int nb, BW *w)
{
    int b, last = -1, pos = 0;
    unsigned flc[288], fdc[32];
    codes(FIXED_LL, 288, flc);
    codes(FIXED_DL, 32, fdc);
    memset(w, 0, sizeof *w);
    for (b = 0; b < nb; b++) if (o->bs[b + 1] > o->bs[b]) last = b;
    for (b = 0; b < nb; b++) {
        const i64 *sy = o->sy + o->bs[b];
        int n = o->bs[b + 1] - o->bs[b], i, size = 0, final = b == last, hlit, hdist, hclen, nr;
        i64 lf[286], df[32], cf[19], head, dyn_bits, fix_bits, stored;
        unsigned char ll[286], dl[32], cl[19], seq[286 + 32];
        unsigned lc[286], dc[32], cc[19];
        RLE r[320];
        if (!n) continue;
        memset(lf, 0, sizeof lf); memset(df, 0, sizeof df);
        lf[256] = 1;
        for (i = 0; i < n; i++) {
            i64 s = sy[i];
            if (s < 256) { lf[s]++; size++; }
            else { lf[257 + LSYM_S[s >> 24]]++; df[dsym(s & 0xFFFFFF)]++; size += (int)(s >> 24); }
        }
        lengths(lf, 286, 15, ll);
        lengths(df, 32, 15, dl);
        for (i = 0; i < 2; i++) {
            int t, cnt = 0;
            for (t = 0; t < 32; t++) cnt += dl[t] != 0;
            if (cnt < 2 && !dl[i]) dl[i] = 1;
        }
        for (hlit = 286; !ll[hlit - 1]; hlit--) ;
        for (hdist = 32; !dl[hdist - 1]; hdist--) ;
        memcpy(seq, ll, (size_t)hlit);
        memcpy(seq + hlit, dl, (size_t)hdist);
        nr = rle(seq, hlit + hdist, r);
        memset(cf, 0, sizeof cf);
        for (i = 0; i < nr; i++) cf[r[i].s]++;
        lengths(cf, 19, 7, cl);
        for (hclen = 19; !cl[ORDER[hclen - 1]]; hclen--) ;
        if (hclen < 4) hclen = 4;
        head = 14 + 3 * hclen;
        for (i = 0; i < nr; i++) head += cl[r[i].s] + r[i].x;
        if (codes(ll, 286, lc) || codes(dl, 32, dc) || codes(cl, 19, cc)) return -1;
        dyn_bits = body_bits(sy, n, lc, ll, dc, dl);
        fix_bits = body_bits(sy, n, flc, FIXED_LL, fdc, FIXED_DL);
        stored = 8 * (i64)size + 40 * ((size + 65534) / 65535);
        if (stored + 7 < (head + dyn_bits < fix_bits ? head + dyn_bits : fix_bits)) {
            int o2;
            for (o2 = 0; o2 < size; o2 += 65535) {
                int end = o2 + 65535 < size ? o2 + 65535 : size, len = end - o2, c;
                put(w, (final && o2 + 65535 >= size) ? 1 : 0, 3);
                align(w);
                put(w, (u64)len | ((u64)(len ^ 0xFFFF) << 16), 32);
                for (c = 0; c < len; c++) put(w, data[pos + o2 + c], 8);
            }
        } else if (fix_bits <= head + dyn_bits) {
            put(w, (u64)(final | 2), 3);
            body_put(w, sy, n, flc, FIXED_LL, fdc, FIXED_DL);
        } else {
            put(w, (u64)(final | 4), 3);
            put(w, (u64)((hlit - 257) | ((hdist - 1) << 5) | ((hclen - 4) << 10)), 14);
            for (i = 0; i < hclen; i++) put(w, cl[ORDER[i]], 3);
            for (i = 0; i < nr; i++) put(w, cc[r[i].s] | ((u64)r[i].v << cl[r[i].s]), cl[r[i].s] + r[i].x);
            body_put(w, sy, n, lc, ll, dc, dl);
        }
        pos += size;
    }
    if (w->nb) put(w, 0, 8 - w->nb);
    return w->err ? -1 : 0;
}

static void set_est(const PB *p, unsigned char *el, unsigned char *ed)
{
    int b;
    for (b = 0; b < p->nb; b++) {
        if (p->st[b]) { memset(el + b * 288, 8, 288); memset(ed + b * 32, 0, 32); }
        else { memcpy(el + b * 288, p->ll + b * 288, 288); memcpy(ed + b * 32, p->dl + b * 32, 32); }
    }
}

/* deflate_far.pack(base, data, passes) for len(data) in (NEAR, FAR_MAX]:
   >= 0 the length of the stream written to out (cap >= blen),
   -1 let the Python do it (it raises), -2 the far stream does not unpack */
EXPORT int df_pack(const unsigned char *base, int blen, const unsigned char *data, int dlen,
                   int passes, unsigned char *out, int cap)
{
    PB bl, got;
    unsigned char *el = 0, *ed = 0, *best = 0;
    int bestlen = blen, pass, r = -1, nb;
    init_tables();
    if (cap < blen) return -1;
    if (parse(base, blen, &bl)) return -1;
    nb = bl.nb;
    el = (unsigned char *)malloc((size_t)nb * 288);
    ed = (unsigned char *)malloc((size_t)nb * 32);
    if (!el || !ed || far_init(data, dlen)) goto done;
    set_est(&bl, el, ed);
    EL = el; ED = ed;
    for (pass = 0; pass < passes; pass++) {
        OB o;
        BW w;
        int ne = 0, b, u;
        memset(&o, 0, sizeof o);
        if (refit(data, &bl, &o)) { free(o.sy); free(o.bs); goto done; }
        if (encode(data, &o, nb, &w)) { free(o.sy); free(o.bs); free(w.b); goto done; }
        for (b = 0; b < nb; b++) ne += o.bs[b + 1] > o.bs[b];
        free(o.sy); free(o.bs);
        u = unpack_eq(w.b, w.n, data, dlen);
        if (u != 1) { free(w.b); r = u == 0 ? -2 : -1; goto done; }
        if (w.n < bestlen) { free(best); best = w.b; bestlen = w.n; }
        if (parse(w.b, w.n, &got)) { if (best != w.b) free(w.b); goto done; }
        if (best != w.b) free(w.b);
        if (got.nb != ne || got.nb != nb) { pb_free(&got); break; }
        set_est(&got, el, ed);
        pb_free(&got);
    }
    memcpy(out, best ? best : base, (size_t)bestlen);
    r = bestlen;
done:
    far_free();
    pb_free(&bl);
    free(el); free(ed); free(best);
    return r;
}

/* ---- the program ------------------------------------------------------------ */
static int fail(const char *m)
{
    fprintf(stderr, "deflate_far: %s\n", m);
    return 1;
}

static unsigned char *read_all(size_t *len)
{
    unsigned char *buf = 0;
    size_t n = 0, cap = 0, got;
    for (;;) {
        if (n == cap) {
            unsigned char *t;
            cap = cap ? cap * 2 : 1 << 20;
            t = (unsigned char *)realloc(buf, cap + 16);
            if (!t) { free(buf); return 0; }
            buf = t;
        }
        got = fread(buf + n, 1, cap - n, stdin);
        if (!got) break;
        n += got;
    }
    *len = n;
    return buf ? buf : (unsigned char *)malloc(16);
}

/* the data of a parsed stream -> stdout (with the bytes used in front) */
static int write_data(const PB *p, int with_used)
{
    unsigned char *o;
    i64 n = 0, len = 0;
    int i;
    for (i = 0; i < p->n; i++) n += p->sy[i] < 256 ? 1 : p->sy[i] >> 24;
    o = (unsigned char *)malloc((size_t)n + 1);
    if (!o) return fail("out of memory");
    for (i = 0; i < p->n; i++) {
        i64 sy = p->sy[i];
        if (sy < 256) { o[len++] = (unsigned char)sy; continue; }
        {
            i64 ln = sy >> 24, d = sy & 0xFFFFFF, q = len - d, k;
            if (q < 0) { free(o); return fail("a match from before the start"); }
            for (k = 0; k < ln; k++) { o[len] = o[q + k]; len++; }
        }
    }
    if (with_used) {
        unsigned char u[4];
        u[0] = (unsigned char)p->used; u[1] = (unsigned char)(p->used >> 8);
        u[2] = (unsigned char)(p->used >> 16); u[3] = (unsigned char)(p->used >> 24);
        fwrite(u, 1, 4, stdout);
    }
    fwrite(o, 1, (size_t)len, stdout);
    free(o);
    return 0;
}

int main(int argc, char **argv)
{
    unsigned char *in;
    size_t n;
    const char *mode = argc > 1 ? argv[1] : "";
    int r;
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    init_tables();
    in = read_all(&n);
    if (!in) return fail("out of memory");
    if (!strcmp(mode, "pack")) {
        int passes = argc > 2 ? atoi(argv[2]) : 2;
        unsigned blen;
        unsigned char *out;
        if (n < 4) return fail("pack: no length in front");
        blen = in[0] | (in[1] << 8) | (in[2] << 16) | ((unsigned)in[3] << 24);
        if ((size_t)blen > n - 4) return fail("pack: the base is shorter than its length");
        {
            const unsigned char *base = in + 4, *data = in + 4 + blen;
            size_t dlen = n - 4 - blen;
            if (dlen <= NEAR || dlen > FAR_MAX) { fwrite(base, 1, blen, stdout); return 0; }
            out = (unsigned char *)malloc((size_t)blen + 1);
            if (!out) return fail("out of memory");
            r = df_pack(base, (int)blen, data, (int)dlen, passes, out, (int)blen);
            if (r == -2) { fprintf(stderr, "deflate_far: the stream does not unpack to the data\n"); return 2; }
            if (r < 0) return fail(PERR ? PERR : "the base stream does not parse");
            fwrite(out, 1, (size_t)r, stdout);
        }
        return 0;
    }
    if (!strcmp(mode, "inflate") || !strcmp(mode, "unpack") || !strcmp(mode, "hasfar")) {
        PB p;
        int i, far = 0;
        if (parse(in, (int)n, &p)) return fail(PERR);
        if (!strcmp(mode, "hasfar")) {
            for (i = 0; i < p.n; i++) if (p.sy[i] >= 256 && (p.sy[i] & 0xFFFFFF) > NEAR) { far = 1; break; }
            printf("%d", far);
            return 0;
        }
        return write_data(&p, mode[0] == 'i');
    }
    return fail("usage: deflate_far pack [passes] | inflate | unpack | hasfar  (data on stdin)");
}

