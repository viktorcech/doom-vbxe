/* inflate816_ok -- can inflate816.asm depack this raw-DEFLATE stream?
 * A C program (2026-11-05; it replaced inflate816_ok.py, the same verdicts
 * and reasons on 22728 real and damaged streams), built by build_atr.ps1
 * with tools/tcc into build/exe/inflate816_ok.exe.
 *
 *   inflate816_ok [bytearray] < stream
 *     stdout: nothing if inflate816 can take it, else the one-line reason
 *     (the 'bytearray' argument words a read past the end as the Python did
 *     for a bytearray). Exit code 0 either way; 1 = could not read stdin.
 *
 * inflate816.asm counts the codes of each length in WORDS since 2026-09-28
 * (the zlib6502 depacker before it kept one BYTE per length, and a block with
 * 256 or more codes of one length -- E3M1's map stream had 258 of 9 bits --
 * never ended). What is left to refuse is what no DEFLATE reader takes: the
 * reserved block type and a stream that does not parse.
 * tools/tests/_verify_inflate.py runs a block of 256 nine-bit codes on the
 * built code.
 *
 *   problem(stream) -> None if inflate816 can take it, else a one-line reason
 *     "block N: reserved block type 3" / "block N: a repeat runs past the K
 *     code lengths" / "block N: unparsable (bad code | index out of range |
 *     list index out of range)".
 * Used by build/py/make_atr_doom.py (_deflate picks only streams that pass)
 * and by tools/tests/_bench_frame.py (every stream the zlib hook stands in for).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>

#define EXPORT static
typedef int64_t i64;

enum { OK, TYPE3, REPEAT, BADCODE, PAST_END, NO_INDEX };

static const int LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0};
static const int DEXT[32] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 16, 21};
static const int ORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

typedef struct { const unsigned char *d; i64 len, pos; } BS;   /* pos in bits */

static int get(BS *b, int k, int *v)          /* PAST_END or OK */
{
    int i, r = 0;
    if (!k) { *v = 0; return OK; }           /* get(0) never reads */
    if (b->pos + k > b->len * 8) return PAST_END;
    for (i = 0; i < k; i++, b->pos++) r |= ((b->d[b->pos >> 3] >> (b->pos & 7)) & 1) << i;
    *v = r;
    return OK;
}

typedef struct { i64 start[16]; int cnt[16], first[16]; int sym[320]; } TAB;

static void table(const int *len, int n, TAB *t)
{   /* canonical codes in symbol order, per length */
    i64 code = 0;
    int L, s, k = 0;
    for (L = 1; L < 16; L++) {
        t->start[L] = code;
        t->first[L] = k;
        t->cnt[L] = 0;
        for (s = 0; s < n; s++) if (len[s] == L) { t->sym[k++] = s; t->cnt[L]++; }
        code = (code + t->cnt[L]) << 1;
    }
}

static int dec(BS *b, const TAB *t, int *s)   /* bit by bit; no code in 16 bits = BADCODE */
{
    i64 code = 0;
    int L = 0, bit;
    for (;;) {
        if (get(b, 1, &bit)) return PAST_END;
        code = (code << 1) | bit;
        L++;
        if (L <= 15 && code >= t->start[L] && code < t->start[L] + t->cnt[L]) {
            *s = t->sym[t->first[L] + (int)(code - t->start[L])];
            return OK;
        }
        if (L > 15) return BADCODE;
    }
}

static TAB FLT, FDT;

#define TRY(x) do { int e_ = (x); if (e_) return e_; } while (0)

static int walk(const unsigned char *stream, int slen, int *info)
{
    static int init;
    BS b;
    int blk = 0;
    if (!init) {
        int ll[288], dl[32], i;
        for (i = 0; i < 288; i++) ll[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
        for (i = 0; i < 32; i++) dl[i] = 5;
        table(ll, 288, &FLT);
        table(dl, 32, &FDT);
        init = 1;
    }
    b.d = stream; b.len = slen; b.pos = 0;
    for (;;) {
        int final, typ;
        info[0] = blk;
        TRY(get(&b, 1, &final));
        TRY(get(&b, 2, &typ));
        if (typ == 0) {
            i64 p = (b.pos + 7) >> 3;            /* the bits left in the byte are dropped */
            if (p + 1 >= slen) return PAST_END;  /* LEN = stream[p] | stream[p + 1] << 8 */
            b.pos = (p + 4 + (stream[p] | (stream[p + 1] << 8))) * 8;
        } else if (typ == 3) {
            return TYPE3;
        } else {
            static TAB lt, dt, ct;
            const TAB *L, *D;
            if (typ == 1) { L = &FLT; D = &FDT; }
            else {
                int hlit, hdist, hclen, i, cl[19], lens[320], nl = 0, v, s;
                TRY(get(&b, 5, &hlit));
                TRY(get(&b, 5, &hdist));
                TRY(get(&b, 4, &hclen));
                hlit += 257; hdist += 1; hclen += 4;
                memset(cl, 0, sizeof cl);
                for (i = 0; i < hclen; i++) TRY(get(&b, 3, &cl[ORDER[i]]));
                table(cl, 19, &ct);
                while (nl < hlit + hdist) {
                    int rep, val, k;
                    TRY(dec(&b, &ct, &s));
                    if (s < 16) { lens[nl++] = s; continue; }
                    if (s == 16) { if (!nl) return NO_INDEX; val = lens[nl - 1]; TRY(get(&b, 2, &v)); rep = 3 + v; }
                    else if (s == 17) { val = 0; TRY(get(&b, 3, &v)); rep = 3 + v; }
                    else { val = 0; TRY(get(&b, 7, &v)); rep = 11 + v; }
                    if (nl + rep > hlit + hdist) { info[1] = hlit + hdist; return REPEAT; }
                    for (k = 0; k < rep; k++) lens[nl++] = val;
                }
                table(lens, hlit, &lt);
                table(lens + hlit, hdist, &dt);
                L = &lt; D = &dt;
            }
            for (;;) {
                int s, d, v;
                TRY(dec(&b, L, &s));
                if (s < 256) continue;
                if (s == 256) break;
                s -= 257;
                if (s > 28) return NO_INDEX;     /* LEXT[s] */
                TRY(get(&b, LEXT[s], &v));
                TRY(dec(&b, D, &d));
                TRY(get(&b, DEXT[d], &v));
            }
        }
        if (final) return OK;
        blk++;
    }
}

EXPORT int i816_check(const unsigned char *stream, int slen, int *info)
{
    info[0] = info[1] = 0;
    if (!slen) return OK;
    return walk(stream, slen, info);
}

/* ---- the program ------------------------------------------------------------ */
int main(int argc, char **argv)
{
    unsigned char *buf = 0;
    size_t n = 0, cap = 0, got;
    int info[2], k, ba = argc > 1 && !strcmp(argv[1], "bytearray");
    _setmode(_fileno(stdin), _O_BINARY);
    for (;;) {
        if (n == cap) {
            unsigned char *t;
            cap = cap ? cap * 2 : 1 << 16;
            t = (unsigned char *)realloc(buf, cap);
            if (!t) { fprintf(stderr, "inflate816_ok: out of memory\n"); return 1; }
            buf = t;
        }
        got = fread(buf + n, 1, cap - n, stdin);
        if (!got) break;
        n += got;
    }
    k = i816_check(buf, (int)n, info);
    switch (k) {
    case OK:       break;
    case TYPE3:    printf("block %d: reserved block type 3", info[0]); break;
    case REPEAT:   printf("block %d: a repeat runs past the %d code lengths", info[0], info[1]); break;
    case BADCODE:  printf("block %d: unparsable (bad code)", info[0]); break;
    case PAST_END: printf("block %d: unparsable (%sindex out of range)", info[0], ba ? "bytearray " : ""); break;
    default:       printf("block %d: unparsable (list index out of range)", info[0]); break;
    }
    free(buf);
    return 0;
}

