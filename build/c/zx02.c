/*
 * zx02 -- ZX0 v2.2 optimal data compressor by Einar Saukas (mads-src/
 * compression/zx2/pc/src: zx02.c, optimize.c, compress.c, memory.c), in one
 * file and FASTER, the output byte for byte the same (2026-11-05).
 *
 * What changed is optimize(): the original allocates a new literal BLOCK for
 * every offset at every input byte that does not match there (~340 M blocks for
 * the 26 KB engine XEX) although almost none of them is ever used. Here a
 * literal is LAZY -- per offset only (the match it follows, the index) -- and
 * becomes a real block only when something chains to it: a repeat match at
 * that offset, or optimal[index]. The choice of optimal[index] keeps the
 * original's rule exactly (the FIRST candidate in offset order with the fewest
 * bits wins), so the chain compress() walks is the same chain.
 *
 * (c) Copyright 2021 by Einar Saukas. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * The name of its author may not be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FALSE 0
#define TRUE 1

typedef struct block_t {
    struct block_t *chain;
    struct block_t *ghost_chain;
    int bits;
    int index;
    int offset;
    int references;
} BLOCK;

typedef struct zx02_state_t {
    unsigned char *input_data;
    int input_size;
    int skip;
    int initial_offset;
    int backwards_mode;
    int elias_short_code;
    int elias_ending_bit;
    int zx1_mode;
    int offset_limit;
} zx02_state;

/* ---- memory.c ------------------------------------------------------------ */
#define QTY_BLOCKS 10000

static BLOCK *ghost_root = NULL;
static BLOCK *dead_array = NULL;
static int dead_array_size = 0;

static void release(BLOCK *b)                 /* one reference less */
{
    if (b && !--b->references) {
        b->ghost_chain = ghost_root;
        ghost_root = b;
    }
}

static BLOCK *allocate(int bits, int index, int offset, BLOCK *chain)
{
    BLOCK *ptr;
    if (ghost_root) {
        ptr = ghost_root;
        ghost_root = ptr->ghost_chain;
        if (ptr->chain && !--ptr->chain->references) {
            ptr->chain->ghost_chain = ghost_root;
            ghost_root = ptr->chain;
        }
    } else {
        if (!dead_array_size) {
            dead_array = (BLOCK *)malloc(QTY_BLOCKS * sizeof(BLOCK));
            if (!dead_array) {
                fprintf(stderr, "Error: Insufficient memory\n");
                exit(1);
            }
            dead_array_size = QTY_BLOCKS;
        }
        ptr = &dead_array[--dead_array_size];
    }
    ptr->bits = bits;
    ptr->index = index;
    ptr->offset = offset;
    if (chain)
        chain->references++;
    ptr->chain = chain;
    ptr->references = 0;
    return ptr;
}

static void assign(BLOCK **ptr, BLOCK *chain)
{
    chain->references++;
    if (*ptr && !--(*ptr)->references) {
        (*ptr)->ghost_chain = ghost_root;
        ghost_root = *ptr;
    }
    *ptr = chain;
}

/* ---- optimize.c ------------------------------------------------------------ */
#define MAX_SCALE 50

static int offset_ceiling(zx02_state *s, int index)
{
    return index > s->offset_limit     ? s->offset_limit
           : index < s->initial_offset ? s->initial_offset
                                       : index;
}

static int elias_gamma_bits(zx02_state *s, int value)
{
    int bits = 1;
    if (value < 1 || value > 0x100)
        return 1024;
    if (s->elias_short_code && value == 0x100)
        bits = -1;
    while (value >>= 1)
        bits += 2;
    return bits;
}

static int elias_gamma_bits_1(zx02_state *s, int value)
{
    if (value == 1)
        return elias_gamma_bits(s, 256);
    else if (value > 256)
        return 1024;
    else
        return elias_gamma_bits(s, value - 1);
}

static int offset_bits(zx02_state *s, int value)
{
    if (s->zx1_mode)
        return (value > 127) ? 17 : 9;
    else
        return 8 + elias_gamma_bits(s, value / 128 + 1);
}

/* elias_gamma_bits(length) for length 0..257 (past 256 it is 1024 anyway) */
static int EG[258];

/* WHICH OFFSETS NEED WORK at an index (2026-11-05). The original walks every
   offset 1..max at every index. An offset where the byte does NOT match only
   resets its match length and, if it has a match behind it, extends its
   literal run by one byte -- the same literal, one byte longer. So only two
   kinds of offset need work: the ones whose byte matches here (found through a
   list of the earlier positions of every byte value) and the ones that matched
   at the previous index and stop here. Every other offset sits in a LITERAL
   RUN whose cost here is
       lm->bits + 1 + EG(L) + 8 L     (lm its last match, L = index - lm->index)
     = (lm->bits - 8 lm->index) + 8 index + 1 + EG(L)
   -- a constant per run plus 8 index plus EG(L), and EG(L) takes 10 values
   (L = 1, 2-3, 4-7 .. 128-255, 256, past 256). So the runs live in 10 heaps,
   one per EG class, ordered (constant, offset); a run moves on to the next
   class at a scheduled index. The cheapest literal is the best of the 10 tops.
   The winner of optimal[index] is chosen as the original chooses it: the
   fewest bits, and among equal bits the SMALLEST offset (it walks offsets
   upward and only a strictly better candidate replaces the one it has). */
#define NCLS 10
static int EGC[NCLS];

static int cls_of(int L)
{
    int c = 0;
    if (L > 256) return 9;
    if (L == 256) return 8;
    while (L >>= 1) c++;
    return c;
}
static int next_threshold(int c)              /* the L at which class c ends */
{
    static const int T[NCLS] = {2, 4, 8, 16, 32, 64, 128, 256, 257, 0};
    return T[c];
}

typedef struct { int C, off, ver; } HE;
typedef struct { HE *h; int n, cap; } HEAP;
static HEAP HP[NCLS];

static int he_less(const HE *a, const HE *b) { return a->C < b->C || (a->C == b->C && a->off < b->off); }
static void heap_push(HEAP *q, int C, int off, int ver)
{
    int i;
    if (q->n == q->cap) {
        q->cap = q->cap ? q->cap * 2 : 1024;
        q->h = (HE *)realloc(q->h, q->cap * sizeof(HE));
        if (!q->h) { fprintf(stderr, "Error: Insufficient memory\n"); exit(1); }
    }
    i = q->n++;
    q->h[i].C = C; q->h[i].off = off; q->h[i].ver = ver;
    while (i) {
        int p = (i - 1) >> 1;
        HE t;
        if (!he_less(&q->h[i], &q->h[p])) break;
        t = q->h[i]; q->h[i] = q->h[p]; q->h[p] = t;
        i = p;
    }
}
static void heap_pop(HEAP *q)
{
    int i = 0;
    q->h[0] = q->h[--q->n];
    for (;;) {
        int l = 2 * i + 1, r = l + 1, m = i;
        HE t;
        if (l < q->n && he_less(&q->h[l], &q->h[m])) m = l;
        if (r < q->n && he_less(&q->h[r], &q->h[m])) m = r;
        if (m == i) break;
        t = q->h[i]; q->h[i] = q->h[m]; q->h[m] = t;
        i = m;
    }
}

/* scheduled class changes: index -> (offset, version) */
typedef struct { int off, ver, next; } EV;
static EV *EVS; static int NEV, EVCAP;
static int *EVHEAD;

static int *VER, *CLS, *CV;                   /* per offset: run version, class (-1: none), constant */
static BLOCK **LM;                            /* = last_match */

static void schedule(int at, int off, int ver, int size)
{
    if (at >= size) return;
    if (NEV == EVCAP) {
        EVCAP = EVCAP ? EVCAP * 2 : 4096;
        EVS = (EV *)realloc(EVS, EVCAP * sizeof(EV));
        if (!EVS) { fprintf(stderr, "Error: Insufficient memory\n"); exit(1); }
    }
    EVS[NEV].off = off; EVS[NEV].ver = ver; EVS[NEV].next = EVHEAD[at];
    EVHEAD[at] = NEV++;
}

/* offset off starts a literal run at index (its last match LM[off]) */
static void run_enter(int off, int index, int size)
{
    BLOCK *lm = LM[off];
    int c, t;
    if (!lm) return;
    c = cls_of(index - lm->index);
    VER[off]++;
    CLS[off] = c;
    CV[off] = lm->bits - 8 * lm->index;
    heap_push(&HP[c], CV[off], off, VER[off]);
    t = next_threshold(c);
    if (t) schedule(lm->index + t, off, VER[off], size);
}
static void run_leave(int off) { VER[off]++; CLS[off] = -1; }

static BLOCK *optimize(zx02_state *s)
{
    BLOCK **last_match;
    BLOCK **optimal;
    BLOCK **llb;                              /* last_literal[offset], a real block */
    int *match_length;
    int *best_length;
    int *mat_at;                              /* the last index the offset matched at */
    int *cur, *prv, ncur = 0, nprv = 0;
    int *prev_same, last_pos[256];
    int best_length_size;
    int bits;
    int index;
    int offset;
    int length;
    int bits2;
    int dots = 2;
    int k, size;
    unsigned char *data;

    if (s->initial_offset >= s->input_size)
        s->initial_offset = s->input_size - 1;

    int max_offset = offset_ceiling(s, s->input_size - 1);
    size = s->input_size;

    for (k = 0; k < 258; k++) EG[k] = elias_gamma_bits(s, k);
    EGC[0] = EG[1]; EGC[1] = EG[2]; EGC[2] = EG[4]; EGC[3] = EG[8]; EGC[4] = EG[16];
    EGC[5] = EG[32]; EGC[6] = EG[64]; EGC[7] = EG[128]; EGC[8] = EG[256]; EGC[9] = 1024;

    last_match = (BLOCK **)calloc(max_offset + 1, sizeof(BLOCK *));
    llb = (BLOCK **)calloc(max_offset + 1, sizeof(BLOCK *));
    optimal = (BLOCK **)calloc(size, sizeof(BLOCK *));
    match_length = (int *)calloc(max_offset + 1, sizeof(int));
    best_length = (int *)calloc(size, sizeof(int));
    mat_at = (int *)malloc((max_offset + 1) * sizeof(int));
    cur = (int *)malloc((max_offset + 1) * sizeof(int));
    prv = (int *)malloc((max_offset + 1) * sizeof(int));
    prev_same = (int *)malloc(size * sizeof(int));
    VER = (int *)calloc(max_offset + 1, sizeof(int));
    CLS = (int *)malloc((max_offset + 1) * sizeof(int));
    CV = (int *)calloc(max_offset + 1, sizeof(int));
    EVHEAD = (int *)malloc((size + 1) * sizeof(int));
    if (!last_match || !llb || !optimal || !match_length || !best_length || !mat_at || !cur ||
        !prv || !prev_same || !VER || !CLS || !CV || !EVHEAD) {
        fprintf(stderr, "Error: Insufficient memory\n");
        exit(1);
    }
    LM = last_match;
    for (k = 0; k <= max_offset; k++) { mat_at[k] = -2; CLS[k] = -1; }
    for (k = 0; k <= size; k++) EVHEAD[k] = -1;
    for (k = 0; k < 256; k++) last_pos[k] = -1;
    data = s->input_data;
    for (k = 0; k < s->skip; k++) { prev_same[k] = last_pos[data[k]]; last_pos[data[k]] = k; }
    if (size > 1)
        best_length[1] = 1;

    /* start with fake block */
    assign(&last_match[s->initial_offset],
           allocate(-1, s->skip - 1, s->initial_offset, NULL));
    run_enter(s->initial_offset, s->skip, size);

    printf("[");

    for (index = s->skip; index < size; index++) {
        BLOCK *best = 0;
        int best_bits = 0, best_off = 0, have = 0, lit_off = 0, e, j;
        max_offset = offset_ceiling(s, index);
        best_length_size = 1;
        /* runs that reach their next EG class here */
        for (e = EVHEAD[index]; e >= 0; e = EVS[e].next) {
            int o = EVS[e].off, c, t;
            if (VER[o] != EVS[e].ver || CLS[o] < 0) continue;
            c = cls_of(index - LM[o]->index);
            CLS[o] = c;
            heap_push(&HP[c], CV[o], o, VER[o]);
            t = next_threshold(c);
            if (t) schedule(LM[o]->index + t, o, VER[o], size);
        }
        /* the offsets whose byte matches here, smallest offset first */
        ncur = 0;
        if (index != s->skip) {
            int p;
            for (p = last_pos[data[index]]; p >= 0 && index - p <= max_offset; p = prev_same[p])
                cur[ncur++] = index - p;
        }
        /* the ones that matched at index-1 and stop here: a literal run starts */
        for (j = 0; j < nprv; j++) {
            int o = prv[j];
            if (index != s->skip && index >= o && data[index] == data[index - o]) continue;
            match_length[o] = 0;
            run_enter(o, index, size);
        }
        for (j = 0; j < ncur; j++) {
            offset = cur[j];
            if (mat_at[offset] != index - 1) {
                /* it was in a literal run at index-1: the original's
                   last_literal[offset] is that run's block at index-1 */
                BLOCK *lm = last_match[offset];
                if (lm && index - 1 >= s->skip && offset <= offset_ceiling(s, index - 1)) {
                    int L = index - 1 - lm->index;
                    BLOCK *b = allocate(lm->bits + 1 + (L <= 257 ? EG[L] : 1024) + L * 8, index - 1, 0, lm);
                    b->references++;
                    if (llb[offset]) release(llb[offset]);
                    llb[offset] = b;
                }
                run_leave(offset);
            }
            /* copy from last offset, only if code at this offset was a literal */
            if (llb[offset]) {
                length = index - llb[offset]->index;
                bits = llb[offset]->bits + 1 + elias_gamma_bits(s, length);
                assign(&last_match[offset], allocate(bits, index, offset, llb[offset]));
                if (!have || best_bits > bits) { best = last_match[offset]; best_bits = bits; best_off = offset; have = 1; }
            }
            /* copy from new offset */
            match_length[offset]++;
            if (best_length_size < match_length[offset]) {
                bits = optimal[index - best_length[best_length_size]]->bits +
                       elias_gamma_bits_1(s, best_length[best_length_size]);
                do {
                    best_length_size++;
                    bits2 = optimal[index - best_length_size]->bits +
                            elias_gamma_bits_1(s, best_length_size);
                    if (bits2 <= bits) {
                        best_length[best_length_size] = best_length_size;
                        bits = bits2;
                    } else {
                        best_length[best_length_size] = best_length[best_length_size - 1];
                    }
                } while (best_length_size < match_length[offset]);
            }
            length = best_length[match_length[offset]];
            bits = optimal[index - length]->bits + offset_bits(s, offset) + elias_gamma_bits_1(s, length);
            if (!last_match[offset] || last_match[offset]->index != index || last_match[offset]->bits > bits) {
                assign(&last_match[offset], allocate(bits, index, offset, optimal[index - length]));
                if (!have || best_bits > bits) { best = last_match[offset]; best_bits = bits; best_off = offset; have = 1; }
            }
            mat_at[offset] = index;
        }
        /* the cheapest literal run: the best of the class heaps' tops */
        {
            int c, lbits = 0, loff = 0, lhave = 0;
            for (c = 0; c < NCLS; c++) {
                HEAP *q = &HP[c];
                while (q->n && (VER[q->h[0].off] != q->h[0].ver || CLS[q->h[0].off] != c)) heap_pop(q);
                if (q->n) {
                    int b = q->h[0].C + 8 * index + 1 + EGC[c];
                    if (!lhave || b < lbits || (b == lbits && q->h[0].off < loff)) { lbits = b; loff = q->h[0].off; lhave = 1; }
                }
            }
            if (lhave && (!have || lbits < best_bits || (lbits == best_bits && loff < best_off))) {
                best_bits = lbits; lit_off = loff; have = 1;
            }
        }
        if (lit_off) best = allocate(best_bits, index, 0, last_match[lit_off]);
        if (best) assign(&optimal[index], best);
        prev_same[index] = last_pos[data[index]];
        last_pos[data[index]] = index;
        memcpy(prv, cur, ncur * sizeof(int));
        nprv = ncur;

        if (index * MAX_SCALE / size > dots) {
            printf(".");
            fflush(stdout);
            dots++;
        }
    }

    printf("]\n");

    return optimal[size - 1];
}

/* ---- compress.c ------------------------------------------------------------ */
static unsigned char *output_data;
static int output_index;
static int input_index;
static int bit_index;
static int bit_mask;
static int diff;
static int backtrack;
static int bit_size;

static void read_bytes(int n, int *delta)
{
    input_index += n;
    diff += n;
    if (*delta < diff)
        *delta = diff;
}

static void write_byte(int value)
{
    output_data[output_index++] = value;
    bit_size += 8;
    diff--;
}

static void write_bit(int value)
{
    if (backtrack) {
        if (value)
            output_data[output_index - 1] |= 1;
        backtrack = FALSE;
    } else {
        if (!bit_mask) {
            bit_mask = 128;
            bit_index = output_index;
            output_data[output_index++] = 0;
            diff--;
        }
        if (value)
            output_data[bit_index] |= bit_mask;
        bit_mask >>= 1;
        bit_size++;
    }
}

static void write_interlaced_elias_gamma(zx02_state *s, int value)
{
    int i;
    if (!value)
        value = 0x100;
    for (i = 2; i <= value; i <<= 1)
        ;
    i >>= 1;
    while (i >>= 1) {
        write_bit(!s->elias_ending_bit);
        if (s->elias_short_code && i == 1 && value == 0x100)
            break;
        write_bit(value & i);
    }
    if (!s->elias_short_code || value != 0x100)
        write_bit(!!s->elias_ending_bit);
}

static unsigned char *compress(BLOCK *optimal, zx02_state *s, int *output_size, int *delta)
{
    BLOCK *prev;
    BLOCK *next;
    int length;
    int optbits = optimal->bits;
    int i;
    int last_offset = s->initial_offset;

    if (s->zx1_mode) {
        *output_size = (optimal->bits + 9 + 7) / 8;
        optbits = optimal->bits + 9;
    } else {
        *output_size = (optimal->bits + 18 + 7) / 8;
        optbits = optimal->bits + 18;
    }

    output_data = (unsigned char *)malloc(*output_size);
    bit_size = 0;
    if (!output_data) {
        fprintf(stderr, "Error: Insufficient memory\n");
        exit(1);
    }

    /* un-reverse optimal sequence */
    prev = NULL;
    while (optimal) {
        next = optimal->chain;
        optimal->chain = prev;
        prev = optimal;
        optimal = next;
    }

    diff = *output_size - s->input_size + s->skip;
    *delta = 0;
    input_index = s->skip;
    output_index = 0;
    bit_mask = 0;
    backtrack = TRUE;

    int last_literal = 0;
    for (optimal = prev->chain; optimal; prev = optimal, optimal = optimal->chain) {
        length = optimal->index - prev->index;
        if (!optimal->offset) {
            write_bit(0);
            write_interlaced_elias_gamma(s, length);
            for (i = 0; i < length; i++) {
                write_byte(s->input_data[input_index]);
                read_bytes(1, delta);
            }
            last_literal = 1;
        } else if (optimal->offset == last_offset && last_literal) {
            write_bit(0);
            write_interlaced_elias_gamma(s, length);
            read_bytes(length, delta);
            last_literal = 0;
        } else {
            write_bit(1);
            if (s->zx1_mode) {
                int off = optimal->offset - 1;
                if (off < 128)
                    write_byte(off << 1);
                else {
                    write_byte((off >> 7) | 1);
                    write_byte(off & 255);
                }
            } else {
                write_interlaced_elias_gamma(s, (optimal->offset - 1) / 128 + 1);
                write_byte(((optimal->offset - 1) % 128) << 1);
                backtrack = TRUE;
            }
            write_interlaced_elias_gamma(s, length - 1);
            read_bytes(length, delta);
            last_offset = optimal->offset;
            last_literal = 0;
        }
    }

    /* end marker */
    write_bit(1);
    if (s->zx1_mode)
        write_byte(255);
    else
        write_interlaced_elias_gamma(s, 256);

    int real_size = (bit_size + 7) / 8;
    if (real_size != *output_size) {
        fprintf(stderr, "WARNING: optimal/real sizes mismatch by %d bytes\n",
                *output_size - real_size);
        *output_size = real_size;
    }
    fprintf(stderr, "bit size data: opt %d bits (%d bytes), real %d bits (%d bytes)\n", optbits,
            *output_size, bit_size, (bit_size + 7) / 8);
    return output_data;
}

/* ---- zx02.c ------------------------------------------------------------------ */
#define MAX_OFFSET_ZX02  32640
#define MAX_OFFSET_ZX102 32511
#define MAX_OFFSET_FAST 2176

static void reverse(unsigned char *first, unsigned char *last)
{
    unsigned char c;
    while (first < last) {
        c = *first;
        *first++ = *last;
        *last-- = c;
    }
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [-f] [-c] [-b] [-q] input [output.zx02]\n"
            "  -f      Force overwrite of output file\n"
            "  -b      Compress backwards\n"
            "  -s      Use shorted Elias codes\n"
            "  -e      Inverted Elias code end bit\n"
            "  -1      ZX1 offset format\n"
            "  -o <n>  Use 'n' as starting offset\n"
            "  -p <n>  Skip 'n' bytes at input (compress with pre-buffer)\n"
            "  -m <n>  Compress with max offset 'n' bytes\n"
            "  -q      Quick non-optimal compression\n",
            prog);
    exit(1);
}

int main(int argc, char *argv[])
{
    zx02_state *s = calloc(sizeof(zx02_state), 1);
    int set_max_offset = 0;
    int force_overwrite = FALSE;
    char *input_name = 0;
    char *output_name = 0;
    unsigned char *output_data_;
    FILE *ifp;
    FILE *ofp;
    int output_size;
    int partial_counter;
    int total_counter;
    int delta;
    int i;

    s->initial_offset = 1;
    s->offset_limit = MAX_OFFSET_ZX02;

    printf("ZX0 v2.2: Optimal data compressor by Einar Saukas\n");

    for (i = 1; i < argc; i++) {
        int num = 0;
        const char *arg = argv[i];
        if (*arg == '-') {
            char opt = arg[1];
            switch (opt) {
            case 'f': force_overwrite = TRUE; break;
            case 'b': s->backwards_mode = TRUE; break;
            case 's': s->elias_short_code = TRUE; break;
            case 'e': s->elias_ending_bit = TRUE; break;
            case 'q': s->offset_limit = MAX_OFFSET_FAST; break;
            case '1':
                s->zx1_mode = 1;
                if (s->offset_limit > MAX_OFFSET_ZX102)
                    s->offset_limit = MAX_OFFSET_ZX102;
                break;
            case 'o':
            case 'p':
            case 'm':
                if (arg[2] == ':' || arg[2] == '=')
                    num = atoi(arg + 3);
                else if (!arg[2] && i < argc - 1)
                    num = atoi(argv[++i]);
                else {
                    fprintf(stderr, "ERROR: option '-%c' needs integer argument\n", opt);
                    print_usage(argv[0]);
                }
                if (opt == 'o') {
                    s->initial_offset = num;
                } else if (opt == 'm') {
                    set_max_offset = num;
                } else {
                    if (num < 0) {
                        fprintf(stderr, "ERROR: skipped bytes must be positive.\n");
                        exit(1);
                    }
                    s->skip = num;
                }
                break;
            default:
                if (opt != 'h')
                    fprintf(stderr, "ERROR: unknown option '-%c'\n", opt);
                print_usage(argv[0]);
            }
        } else if (!input_name)
            input_name = argv[i];
        else if (!output_name)
            output_name = argv[i];
        else {
            fprintf(stderr, "ERROR: extra argument '%s'\n", argv[i]);
            print_usage(argv[0]);
        }
    }

    if (set_max_offset) {
        if (set_max_offset > s->offset_limit || set_max_offset < 1) {
            fprintf(stderr, "ERROR: max offset must be between 1 and %d.\n", s->offset_limit);
            exit(1);
        }
        s->offset_limit = set_max_offset;
    }
    if (s->initial_offset < 1 || s->initial_offset > s->offset_limit) {
        fprintf(stderr, "ERROR: initial offset must be between 1 and %d.\n", s->offset_limit);
        exit(1);
    }
    if (!input_name) {
        fprintf(stderr, "ERROR: missing input filename\n");
        print_usage(argv[0]);
    }
    if (!output_name) {
        output_name = (char *)malloc(strlen(input_name) + 6);
        strcpy(output_name, input_name);
        strcat(output_name, ".zx02");
    }
    ifp = fopen(input_name, "rb");
    if (!ifp) {
        fprintf(stderr, "ERROR: Cannot access input file %s\n", input_name);
        exit(1);
    }
    fseek(ifp, 0L, SEEK_END);
    s->input_size = ftell(ifp);
    fseek(ifp, 0L, SEEK_SET);
    if (!s->input_size) {
        fprintf(stderr, "ERROR: Empty input file %s\n", input_name);
        exit(1);
    }
    if (s->skip >= s->input_size) {
        fprintf(stderr, "ERROR: Skipping entire input file %s\n", input_name);
        exit(1);
    }
    s->input_data = (unsigned char *)malloc(s->input_size);
    if (!s->input_data) {
        fprintf(stderr, "ERROR: Insufficient memory\n");
        exit(1);
    }
    total_counter = 0;
    do {
        partial_counter = fread(s->input_data + total_counter, sizeof(char),
                                s->input_size - total_counter, ifp);
        total_counter += partial_counter;
    } while (partial_counter > 0);
    if (total_counter != s->input_size) {
        fprintf(stderr, "ERROR: Cannot read input file %s\n", input_name);
        exit(1);
    }
    fclose(ifp);
    if (!force_overwrite && fopen(output_name, "rb") != NULL) {
        fprintf(stderr, "ERROR: Already existing output file %s\n", output_name);
        exit(1);
    }
    ofp = fopen(output_name, "wb");
    if (!ofp) {
        fprintf(stderr, "ERROR: Cannot create output file %s\n", output_name);
        exit(1);
    }
    if (s->backwards_mode)
        reverse(s->input_data, s->input_data + s->input_size - 1);

    BLOCK *optim = optimize(s);
    output_data_ = compress(optim, s, &output_size, &delta);

    if (s->backwards_mode)
        reverse(output_data_, output_data_ + output_size - 1);
    if ((int)fwrite(output_data_, sizeof(char), output_size, ofp) != output_size) {
        fprintf(stderr, "ERROR: Cannot write output file %s\n", output_name);
        exit(1);
    }
    fclose(ofp);
    printf("File%s compressed%s from %d to %d bytes! (delta %d)\n",
           (s->skip ? " partially" : ""), (s->backwards_mode ? " backwards" : ""),
           s->input_size - s->skip, output_size, delta);
    return 0;
}
