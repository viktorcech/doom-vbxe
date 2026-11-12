/* code_map.h -- what the XEX puts where, from the MADS listing, byte-exact
 * against the XEX itself (2026-11-05: the C of build/py/code_map.py, which it
 * replaced; header-only, #included by every program that reads the listing:
 * code_map.c, b1_check.c, code_xref.c, split_b1.c, split_menu_ovl.c,
 * vbxe_reloc.c).
 *
 * Every listing line that emits bytes gets a run address (where the CPU sees
 * it), a load address (where the XEX stores it -- differs inside `org run,
 * load`), a size (address delta to the next line, so long `dta` runs are
 * counted whole), a kind (code / data / other), the enclosing .proc and the
 * program bank it runs in. On top of that: the procs and the static
 * control-flow graph (jsr/jsl/jmp/jml/brl/branch targets decoded from the
 * listed bytes) between them.
 *
 * Text is handled as the Python did on a latin-1 str read in universal-newline
 * mode: lines end at \r\n, \r or \n; whitespace is str.isspace(); lower() and
 * upper() are latin-1's. Output text is written as UTF-8.
 */
#ifndef CODE_MAP_H
#define CODE_MAP_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <windows.h>

#define NONE (-1)

/* ---- text ------------------------------------------------------------------ */
static int ws(unsigned char c)
{
    return c == ' ' || (c >= 9 && c <= 13) || (c >= 0x1c && c <= 0x1f) || c == 0x85 || c == 0xa0;
}
static unsigned char low(unsigned char c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 0xc0 && c <= 0xde && c != 0xd7)) return c + 32;
    return c;
}
static int isw(unsigned char c)               /* re's \w on a latin-1 str */
{
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' ||
           c == 170 || c == 178 || c == 179 || c == 181 || c == 185 || c == 186 ||
           (c >= 188 && c <= 190) || (c >= 192 && c != 215 && c != 247);
}
static int hexv(unsigned char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static int uhex(unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'); }

/* a string: n = NONE is Python's None */
typedef struct { const unsigned char *p; int n; } STR;
static const STR SNONE = {0, NONE};

static STR mk(const char *s) { STR r; r.p = (const unsigned char *)s; r.n = (int)strlen(s); return r; }
static int seq(STR a, STR b) { return a.n == b.n && (a.n <= 0 || !memcmp(a.p, b.p, (size_t)a.n)); }
static int seqs(STR a, const char *b) { return a.n >= 0 && seq(a, mk(b)); }
static int scmp(STR a, STR b)                 /* Python str ordering */
{
    int n = a.n < b.n ? a.n : b.n, c = n > 0 ? memcmp(a.p, b.p, (size_t)n) : 0;
    return c ? c : a.n - b.n;
}
static STR sstrip(STR s)
{
    while (s.n > 0 && ws(*s.p)) { s.p++; s.n--; }
    while (s.n > 0 && ws(s.p[s.n - 1])) s.n--;
    return s;
}
static STR shead(STR s, int k) { if (s.n > k) s.n = k; return s; }
static int sfind(STR s, const char *t)       /* t in s */
{
    int n = (int)strlen(t), i;
    for (i = 0; i + n <= s.n; i++) if (!memcmp(s.p + i, t, (size_t)n)) return 1;
    return 0;
}
static STR before(STR s, unsigned char c)    /* s.split(c, 1)[0] */
{
    int i;
    for (i = 0; i < s.n; i++) if (s.p[i] == c) { s.n = i; break; }
    return s;
}
/* latin-1 lower()/upper() into buf (upper: ß -> SS; µ and ÿ, whose upper()
   leaves latin-1, keep a byte of their own that nothing else maps to) */
static STR slower(STR s, unsigned char *buf)
{
    int i;
    STR r;
    for (i = 0; i < s.n; i++) buf[i] = low(s.p[i]);
    r.p = buf; r.n = s.n < 0 ? 0 : s.n;
    return r;
}
static STR supper(STR s, unsigned char *buf)
{
    int i, n = 0;
    STR r;
    for (i = 0; i < s.n; i++) {
        unsigned char c = s.p[i];
        if (c == 0xdf) { buf[n++] = 'S'; buf[n++] = 'S'; continue; }
        if ((c >= 'a' && c <= 'z') || (c >= 0xe0 && c <= 0xfe && c != 0xf7)) c -= 32;
        buf[n++] = c;
    }
    r.p = buf; r.n = n;
    return r;
}

/* growable text: latin-1 bytes in, UTF-8 out */
typedef struct { char *b; int n, cap; } TXT;
static void tput(TXT *t, const char *s, int n)
{
    if (t->n + n + 1 > t->cap) {
        t->cap = (t->n + n + 1) * 2;
        t->b = (char *)realloc(t->b, (size_t)t->cap);
        if (!t->b) { fprintf(stderr, "out of memory\n"); exit(1); }
    }
    memcpy(t->b + t->n, s, (size_t)n);
    t->n += n;
    t->b[t->n] = 0;
}
static void tstr(TXT *t, STR s) { if (s.n > 0) tput(t, (const char *)s.p, s.n); }
static void tf(TXT *t, const char *fmt, ...)
{
    char b[4096];
    int n;
    va_list a;
    va_start(a, fmt);
    n = vsnprintf(b, sizeof b, fmt, a);
    va_end(a);
    if (n > (int)sizeof b - 1) n = (int)sizeof b - 1;
    tput(t, b, n);
}
/* f'{s:w}' / f'{s:>w}': pad a latin-1 string to w characters */
static void tpad(TXT *t, STR s, int w, int right)
{
    int n = s.n < 0 ? 0 : s.n;
    if (right) while (n < w) { tput(t, " ", 1); n++; }
    tstr(t, s);
    if (!right) while (n < w) { tput(t, " ", 1); n++; }
}
static void utf8_write(FILE *f, const char *s, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x80) fputc(c, f);
        else { fputc(0xc0 | (c >> 6), f); fputc(0x80 | (c & 0x3f), f); }
    }
}

/* ---- files and paths ------------------------------------------------------- */
static unsigned char *read_file(const char *path, int *len)
{
    FILE *f = fopen(path, "rb");
    unsigned char *b;
    long n;
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    b = (unsigned char *)malloc((size_t)n + 16);
    if (!b) { fclose(f); return 0; }
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(b); return 0; }
    fclose(f);
    memset(b + n, 0, 16);
    *len = (int)n;
    return b;
}
static int write_file(const char *path, const void *d, int n)
{
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(d, 1, (size_t)n, f);
    fclose(f);
    return 0;
}

static char ROOT[MAX_PATH];                   /* the repo root: build/exe/.. /.. */
static char IMG[64];                          /* DOOM_IMG: '' or '_ant2' */
static char LST[MAX_PATH], LAB[MAX_PATH], XEX[MAX_PATH];

/* ROOT\a\b\c with the image's suffix in front of the extension (code_map.img) */
static char *img(char *out, const char *a, const char *b, const char *c, const char *d)
{
    const char *parts[4];
    int i;
    char *slash, *dot;
    parts[0] = a; parts[1] = b; parts[2] = c; parts[3] = d;
    strcpy(out, ROOT);
    for (i = 0; i < 4 && parts[i]; i++) { strcat(out, "\\"); strcat(out, parts[i]); }
    slash = strrchr(out, '\\');
    dot = strrchr(out, '.');
    if (dot && dot > slash + 1) {               /* splitext: not a leading dot */
        char ext[MAX_PATH];
        strcpy(ext, dot);
        *dot = 0;
        strcat(out, IMG);
        strcat(out, ext);
    } else strcat(out, IMG);
    return out;
}
static char *rootp(char *out, const char *a, const char *b, const char *c, const char *d)
{
    const char *parts[4];
    int i;
    parts[0] = a; parts[1] = b; parts[2] = c; parts[3] = d;
    strcpy(out, ROOT);
    for (i = 0; i < 4 && parts[i]; i++) { strcat(out, "\\"); strcat(out, parts[i]); }
    return out;
}

static void cm_init(void)
{
    char *p;
    const char *e;
    int k;
    GetModuleFileNameA(0, ROOT, MAX_PATH);
    for (k = 0; k < 3; k++) if ((p = strrchr(ROOT, '\\')) != 0) *p = 0;   /* exe, exe\, build\ */
    e = getenv("DOOM_IMG");
    strncpy(IMG, e ? e : "", sizeof IMG - 1);
    img(LST, "build", "doom_bsp.lst", 0, 0);
    img(LAB, "build", "doom_bsp.lab", 0, 0);
    img(XEX, "build", "doom_bsp.xex", 0, 0);
}

static void die(const char *fmt, ...)
{
    va_list a;
    va_start(a, fmt);
    vfprintf(stderr, fmt, a);
    va_end(a);
    fputc('\n', stderr);
    exit(1);
}

static int next_line(const unsigned char *d, int len, int *pos, int *ls, int *le);
static int ssplit(STR s, int max, STR *out);

/* int(s, 16) as Python takes it: sign, 0x, underscores between digits */
static int pyhex(STR s, long long *v)
{
    int i = 0, neg = 0, nd = 0, us = 0;
    long long r = 0;
    s = sstrip(s);
    if (i < s.n && (s.p[i] == '+' || s.p[i] == '-')) { neg = s.p[i] == '-'; i++; }
    if (i + 1 < s.n && s.p[i] == '0' && (s.p[i + 1] == 'x' || s.p[i + 1] == 'X')) { i += 2; us = 1; }
    for (; i < s.n; i++) {
        if (s.p[i] == '_') { if (us == 2 || (!nd && us != 1)) return -1; us = 2; continue; }
        if (hexv(s.p[i]) < 0) return -1;
        r = r * 16 + hexv(s.p[i]); nd++; us = 0;
    }
    if (!nd || us == 2) return -1;
    *v = neg ? -r : r;
    return 0;
}

/* `NAME equ $1234` / `NAME equ 45056` out of a MADS include in ROOT:
   ^\s*NAME\s+equ\s+(\$?[0-9A-Fa-f]+), re.M, the first match. 0 = found. */
static int equ(const char *rel, const char *name, long long *val)
{
    char p[MAX_PATH];
    int len, pos = 0, ls, le, nl = (int)strlen(name);
    unsigned char *d = read_file(rootp(p, rel, 0, 0, 0), &len);
    if (!d) die("cannot read %s", p);
    while (next_line(d, len, &pos, &ls, &le)) {
        int q = ls, s0, dollar = 0, k;
        long long v = 0;
        while (q < len && ws(d[q])) q++;
        if (q + nl > len || memcmp(d + q, name, (size_t)nl)) continue;
        q += nl;
        if (q >= len || !ws(d[q])) continue;
        while (q < len && ws(d[q])) q++;
        if (q + 3 > len || memcmp(d + q, "equ", 3)) continue;
        q += 3;
        if (q >= len || !ws(d[q])) continue;
        while (q < len && ws(d[q])) q++;
        if (q < len && d[q] == '$') { dollar = 1; q++; }
        s0 = q;
        while (q < len && hexv(d[q]) >= 0) q++;
        if (q == s0) continue;
        for (k = s0; k < q; k++) {
            if (dollar) v = v * 16 + hexv(d[k]);
            else if (d[k] >= '0' && d[k] <= '9') v = v * 10 + (d[k] - '0');
            else die("invalid literal for int() with base 10: '%.*s'", q - s0, d + s0);
        }
        free(d);
        *val = v;
        return 0;
    }
    free(d);
    return -1;
}

/* the first .lab line `BANK ADDR NAME` whose NAME.upper() is name.upper() */
static int lab_find(const char *name, int *bank, int *addr)
{
    int len, pos = 0, ls, le;
    unsigned char *d = read_file(LAB, &len), ub1[4096], ub2[4096];
    STR want;
    if (!d) die("cannot read %s", LAB);
    want = supper(shead(mk(name), 2000), ub1);
    while (next_line(d, len, &pos, &ls, &le)) {
        STR line, p[4];
        long long b, a;
        line.p = d + ls; line.n = le - ls;
        if (ssplit(line, 3, p) != 3) continue;
        if (!seq(supper(shead(p[2], 2000), ub2), want)) continue;
        if (pyhex(p[0], &b) || pyhex(p[1], &a)) die("invalid literal for int() with base 16 in %s", LAB);
        free(d);
        *bank = (int)b; *addr = (int)a;
        return 0;
    }
    free(d);
    return -1;
}

/* equ() or exit with "<who>: NAME is not in PATH" */
static int equ_or_die(const char *who, const char *rel, const char *name)
{
    long long v;
    if (equ(rel, name, &v)) die("%s: %s is not in %s", who, name, rel);
    return (int)v;
}

/* split_menu_ovl.overlays(): the code overlays lifted into menu.bin --
   (staging address, which source, byte offset in menu.bin), and the shared
   reserve's offset and chunk count */
#define CHUNK 4096
typedef struct { int stage; const char *who; int off; } OVL;
static int overlays(OVL *o, int *off, int *nch)
{
    const char *W = "split_menu_ovl";
    *off = equ_or_die(W, "menu_syms.inc", "MENU_OVL_OFF");
    *nch = equ_or_die(W, "menu_syms.inc", "MENU_OVL_N");
    o[0].stage = equ_or_die(W, "memory_map.inc", "MNOVL_STAGE"); o[0].who = "menu.asm"; o[0].off = *off + 0 * CHUNK;
    o[1].stage = equ_or_die(W, "memory_map.inc", "SGOVL_STAGE"); o[1].who = "savegame.asm"; o[1].off = *off + 1 * CHUNK;
    o[2].stage = equ_or_die(W, "memory_map.inc", "WIOVL_STAGE"); o[2].who = "wi.asm stage 1";
    o[2].off = equ_or_die(W, "menu_syms.inc", "WI_OVL_OFF");
    o[3].stage = equ_or_die(W, "memory_map.inc", "WI2_RUN"); o[3].who = "wi.asm stage 2";
    o[3].off = equ_or_die(W, "menu_syms.inc", "WI_OVL2_OFF");
    o[4].stage = equ_or_die(W, "memory_map.inc", "FINOVL_STAGE"); o[4].who = "f_finale.asm stage 1";
    o[4].off = equ_or_die(W, "menu_syms.inc", "FIN_OVL_OFF");
    o[5].stage = equ_or_die(W, "memory_map.inc", "FIN2_STAGE"); o[5].who = "f_finale.asm stage 2";
    o[5].off = equ_or_die(W, "menu_syms.inc", "FIN_OVL2_OFF");
    o[6].stage = equ_or_die(W, "memory_map.inc", "EPIOVL_STAGE"); o[6].who = "m_episode.asm";
    o[6].off = equ_or_die(W, "menu_syms.inc", "MENU_LVCH") * CHUNK;
    return 7;
}

/* growable bytes */
typedef struct { unsigned char *b; int n, cap; } BUF;
static void bput(BUF *x, const void *d, int n)
{
    if (x->n + n > x->cap) {
        x->cap = (x->n + n) * 2 + 64;
        x->b = (unsigned char *)realloc(x->b, (size_t)x->cap);
        if (!x->b) die("out of memory");
    }
    memcpy(x->b + x->n, d, (size_t)n);
    x->n += n;
}

/* ---- the XEX ------------------------------------------------------------- */
typedef struct { int lo, hi; const unsigned char *d; int n; } XBLK;

static int xex_blocks(const unsigned char *d, int len, XBLK **out)
{
    int i = (len >= 2 && d[0] == 0xFF && d[1] == 0xFF) ? 2 : 0, n = 0, cap = 64;
    XBLK *b = (XBLK *)malloc(cap * sizeof(XBLK));
    while (i + 4 <= len) {
        int lo = d[i] | (d[i + 1] << 8), hi = d[i + 2] | (d[i + 3] << 8), k;
        i += 4;
        if (lo == 0xFFFF) continue;
        k = hi - lo + 1;
        if (n == cap) { cap *= 2; b = (XBLK *)realloc(b, cap * sizeof(XBLK)); }
        b[n].lo = lo; b[n].hi = hi; b[n].d = d + (i < len ? i : len);
        b[n].n = k <= 0 ? 0 : (i + k <= len ? k : (len > i ? len - i : 0));
        n++;
        i += k;
    }
    *out = b;
    return n;
}

/* ---- the listing ----------------------------------------------------------- */
typedef struct Line {
    int n, lst;                    /* listing line number */
    int run, run_none, load, size;
    const unsigned char *bytes; int nbytes;
    int plus;
    int kind;                      /* 0 code, 1 data, 2 other */
    STR mn, op, label, proc, src;
    int bank, blk, ovl;
} Line;

static const char *KIND[3] = {"code", "data", "other"};

static const char *INSN[] = {"adc","and","asl","bcc","bcs","beq","bit","bmi","bne","bpl","bra","brk","brl","bvc","bvs","clc","cld",
"cli","clv","cmp","cop","cpx","cpy","dea","dec","dex","dey","eor","ina","inc","inx","iny","jml","jmp","jsl","jsr","lda",
"ldx","ldy","lsr","mvn","mvp","nop","ora","pea","pei","per","pha","phb","phd","phk","php","phx","phy","pla","plb","pld",
"plp","plx","ply","rep","rol","ror","rti","rtl","rts","sbc","sec","sed","sei","sep","sta","stp","stx","sty","stz","tax",
"tay","tcd","tcs","tdc","trb","tsb","tsc","tsx","txa","txs","txy","tya","tyx","wai","wdm","xba","xce",
"jeq","jne","jcc","jcs","jmi","jpl","jvc","jvs","seq","sne","scc","scs","smi","spl","svc","svs",
"req","rne","rcc","rcs","rmi","rpl","rvc","rvs","add","sub","adb","sbb","adw","sbw","phr","plr","inw","inl","ind",
"dew","del","ded","mva","mvx","mvy","mwa","mwx","mwy","cpb","cpw","cpl","cpd",0};
static const char *DATA[] = {"dta",".byte",".by",".word",".wo",".long",".dword",".he",".sb",".cb","ins",".ds",".fl",0};

static int in_list(const char **l, const unsigned char *b, int n)
{
    int k;
    for (k = 0; l[k]; k++) if ((int)strlen(l[k]) == n && !memcmp(l[k], b, (size_t)n)) return 1;
    return 0;
}

/* str.split(None, max) over a STR: up to max splits, the remainder keeps its tail */
static int ssplit(STR s, int max, STR *out)
{
    int i = 0, e = s.n, k = 0;
    for (;;) {
        int j;
        while (i < e && ws(s.p[i])) i++;
        if (i >= e) break;
        if (max >= 0 && k == max) { out[k].p = s.p + i; out[k].n = e - i; k++; break; }
        j = i;
        while (j < e && !ws(s.p[j])) j++;
        out[k].p = s.p + i; out[k].n = j - i; k++;
        i = j;
    }
    return k;
}
static int shas(STR s, unsigned char c) { int i; for (i = 0; i < s.n; i++) if (s.p[i] == c) return 1; return 0; }

/* base(t): lower, lstrip(':'), drop a trailing .b/.w/.l/.z/.q -> buf */
static int mbase(STR t, unsigned char *buf)
{
    int i = 0, n = 0;
    while (i < t.n && t.p[i] == ':') i++;
    for (; i < t.n; i++) buf[n++] = low(t.p[i]);
    if (n >= 2 && buf[n - 2] == '.' && buf[n - 1] && strchr("bwlzq", buf[n - 1])) n -= 2;
    return n;
}

/* _split(src) -> label, mnemonic (into mnb), operand */
static int split_src(STR src, STR *lab, unsigned char *mnb, int *mnn, STR *op)
{
    STR s = before(src, ';'), toks[3], t2[3];
    int nt, col0;
    unsigned char b[4096];
    while (s.n > 0 && ws(s.p[s.n - 1])) s.n--;
    *lab = SNONE; op->p = s.p; op->n = 0; *mnn = 0;
    if (!sstrip(s).n) return 0;
    col0 = !ws(s.p[0]);
    nt = ssplit(s, 2, toks);
    if (toks[0].n > 4000) return -1;
    {
        int bn = mbase(toks[0], b);
        if (col0 && !in_list(INSN, b, bn) && !in_list(DATA, b, bn) && toks[0].p[0] != '.' && toks[0].p[0] != ':') {
            int i;
            *lab = toks[0];
            for (i = 1; i < nt; i++) toks[i - 1] = toks[i];
            nt--;
            if (nt == 1) {
                STR r[2];
                ssplit(s, 1, r);
                if (shas(sstrip(r[1]), ' ')) nt = ssplit(sstrip(r[1]), 1, toks);
            }
        }
    }
    if (!nt) return 0;
    {
        STR mn = toks[0];
        if (nt > 1) *op = toks[1];
        if (mn.n && mn.p[0] == ':') {
            int k = ssplit(*op, 1, t2);
            if (k) mn = t2[0]; else { mn.p = op->p; mn.n = 0; }
            if (k > 1) *op = t2[1]; else op->n = 0;
        }
        if (mn.n > 4000) return -1;
        if (mn.n && mn.p[0] == '.') { int i; for (i = 0; i < mn.n; i++) mnb[i] = low(mn.p[i]); *mnn = mn.n; }
        else *mnn = mbase(mn, mnb);
    }
    return 0;
}

/* BLK / ADDR on a token: 1 = matched (bank -1 = none) */
static int m_addr(STR t, int blk, int *bank, int *lo, int *hi)
{
    const unsigned char *p = t.p;
    int n = t.n, i;
    *bank = -1;
    if (n >= 3 && uhex(p[0]) && uhex(p[1]) && p[2] == ',') {
        int rest = n - 3;
        if ((!blk && rest == 4) || (blk && rest == 10)) { *bank = hexv(p[0]) * 16 + hexv(p[1]); p += 3; n -= 3; }
    }
    if (!blk) {
        if (n != 4) return 0;
        for (i = 0; i < 4; i++) if (!uhex(p[i])) return 0;
        *lo = (hexv(p[0]) << 12) | (hexv(p[1]) << 8) | (hexv(p[2]) << 4) | hexv(p[3]);
        return 1;
    }
    if (n != 10 || p[4] != '-' || p[9] != '>') return 0;
    for (i = 0; i < 4; i++) if (!uhex(p[i]) || !uhex(p[5 + i])) return 0;
    *lo = (hexv(p[0]) << 12) | (hexv(p[1]) << 8) | (hexv(p[2]) << 4) | hexv(p[3]);
    *hi = (hexv(p[5]) << 12) | (hexv(p[6]) << 8) | (hexv(p[7]) << 4) | hexv(p[8]);
    return 1;
}

/* the next line of a universal-newline text: [*ls, *le), 0 at the end */
static int next_line(const unsigned char *d, int len, int *pos, int *ls, int *le)
{
    int p = *pos;
    if (p >= len) return 0;
    *ls = p;
    while (p < len && d[p] != '\r' && d[p] != '\n') p++;
    *le = p;
    if (p < len) { if (d[p] == '\r' && p + 1 < len && d[p + 1] == '\n') p += 2; else p++; }
    *pos = p;
    return 1;
}

/* LINE: ^\s*(\d+) (.*)$ -> rest */
static int m_line(const unsigned char *d, int ls, int le, STR *rest)
{
    int i = ls, j;
    while (i < le && ws(d[i])) i++;
    j = i;
    while (j < le && d[j] >= '0' && d[j] <= '9') j++;
    if (j == i || j >= le || d[j] != ' ') return 0;
    rest->p = d + j + 1; rest->n = le - j - 1;
    return 1;
}

typedef struct { int lo, hi, bank; } LBLK;

/* _listing_blocks(): (lo, hi, bank) of every block line */
static int listing_blocks(const unsigned char *d, int len, LBLK **out)
{
    int pos = 0, ls, le, nb = 0, cap = 64;
    LBLK *b = (LBLK *)malloc(cap * sizeof(LBLK));
    while (next_line(d, len, &pos, &ls, &le)) {
        STR rest, f, ft[3];
        int k, b2, st, lo, hi;
        if (!m_line(d, ls, le, &rest)) continue;
        f = before(rest, '\t');
        k = ssplit(f, 2, ft);
        st = k && seqs(ft[0], "FFFF>");
        if (k > st && m_addr(ft[st], 1, &b2, &lo, &hi)) {
            if (nb == cap) { cap *= 2; b = (LBLK *)realloc(b, cap * sizeof(LBLK)); }
            b[nb].lo = lo; b[nb].hi = hi; b[nb].bank = b2 < 0 ? 0 : b2;
            nb++;
        }
    }
    *out = b;
    return nb;
}

/* load()'s line loop: the Line records (strings point into d or into a pool) */
static int listing_lines(const unsigned char *d, int len, Line **out)
{
    int pos = 0, ls, le, lno = -1, n = 0, cap = 4096, bi = -1;
    int load_off = 0, load_off_none = 0, pending = -1, org_hint = NONE, two_addr_bank = 0, nproc = 0;
    STR org_text, procs[256];
    Line *L = (Line *)malloc(cap * sizeof(Line));
    unsigned char *pool = (unsigned char *)malloc((size_t)len * 2 + 64);
    int np = 0;
    static STR TOKS[512];
    static const unsigned char QM[] = "?";
    org_text.p = d; org_text.n = 0;
    while (next_line(d, len, &pos, &ls, &le)) {
        STR rest, field, src, lab, op, *toks = TOKS;
        unsigned char mnb[4096];
        int mnn, is_blk, addr_field = 0, seg_bank, plus = 0, nhx, hx0, nt, i, lo, hi, bank;
        lno++;
        if (!m_line(d, ls, le, &rest)) continue;
        {
            int k, tab = -1, pl = -1;
            for (k = 0; k < rest.n; k++) if (rest.p[k] == '\t') { tab = k; break; }
            if (tab >= 0) { field.p = rest.p; field.n = tab; src.p = rest.p + tab + 1; src.n = rest.n - tab - 1; }
            else {
                for (k = 0; k + 2 < rest.n; k++)
                    if (rest.p[k] == ' ' && rest.p[k + 1] == '+' && rest.p[k + 2] == ' ') { pl = k; break; }
                if (pl >= 0) { field.p = rest.p; field.n = pl + 2; src.p = rest.p + pl + 3; src.n = rest.n - pl - 3; }
                else { field = rest; src.p = rest.p + rest.n; src.n = 0; }
            }
            while (src.n > 0 && src.p[0] == '\t') { src.p++; src.n--; }
            field = sstrip(field);
        }
        if (split_src(src, &lab, mnb, &mnn, &op)) die("code_map: listing line %d: a token past 4000 characters", lno + 1);
        if (mnn == 5 && !memcmp(mnb, ".proc", 5)) {
            STR t[2];
            if (nproc >= 256) die("code_map: .proc nested past 256");
            if (op.n) { if (!ssplit(op, 1, t)) die("code_map: listing line %d: .proc without a name", lno + 1); procs[nproc++] = t[0]; }
            else { procs[nproc].p = QM; procs[nproc].n = 1; nproc++; }
        } else if (mnn == 5 && !memcmp(mnb, ".endp", 5)) {
            if (nproc) nproc--;
        } else if (mnn == 7 && !memcmp(mnb, ".endseg", 7)) {
            org_text.n = 0;
        } else if (mnn == 3 && !memcmp(mnb, "org", 3)) {
            org_text = op; org_hint = NONE;
        }
        if (!field.n || field.p[0] == '=') {
            if (field.n && shas(org_text, ',') && org_hint == NONE) {
                /* =\s*(?:[0-9A-F]{2},)?([0-9A-F]{4}) */
                const unsigned char *q = field.p + 1, *e = field.p + field.n;
                int ok = 0, v = 0, j;
                while (q < e && ws(*q)) q++;
                if (q + 7 <= e && uhex(q[0]) && uhex(q[1]) && q[2] == ',' &&
                    uhex(q[3]) && uhex(q[4]) && uhex(q[5]) && uhex(q[6])) { q += 3; ok = 1; }
                else if (q + 4 <= e && uhex(q[0]) && uhex(q[1]) && uhex(q[2]) && uhex(q[3])) ok = 1;
                if (ok) { for (j = 0; j < 4; j++) v = v * 16 + hexv(q[j]); org_hint = v; }
            }
            continue;
        }
        nt = ssplit(field, 511, toks);
        if (nt >= 512) die("code_map: listing line %d: more than 511 fields", lno + 1);
        hx0 = nt && seqs(toks[0], "FFFF>") ? 1 : 0;
        if (nt <= hx0) continue;
        is_blk = m_addr(toks[hx0], 1, &bank, &lo, &hi);
        seg_bank = NONE;
        if (is_blk) { bi++; addr_field = lo; if (bank >= 0) seg_bank = bank; }
        else if (m_addr(toks[hx0], 0, &bank, &lo, &hi)) { addr_field = lo; if (bank >= 0) seg_bank = bank; }
        else continue;
        nhx = 0;
        {
            int bo = np;
            for (i = hx0 + 1; i < nt; i++) {
                STR t = toks[i];
                if (seqs(t, "+")) { plus = 1; break; }
                if (t.n != 2 || hexv(t.p[0]) < 0 || hexv(t.p[1]) < 0)
                    die("code_map: listing line %d: cannot read the byte field", lno + 1);
                pool[np++] = (unsigned char)(hexv(t.p[0]) * 16 + hexv(t.p[1]));
                nhx++;
            }
            if (!nhx && !is_blk) {
                if (shas(org_text, ',') && org_hint == NONE && !(mnn == 3 && !memcmp(mnb, "org", 3)))
                    org_hint = addr_field;
                np = bo;
                continue;
            }
            if (n == cap) { cap *= 2; L = (Line *)realloc(L, cap * sizeof(Line)); }
            {
                Line *r = &L[n];
                memset(r, 0, sizeof *r);
                r->n = r->lst = lno + 1;
                r->plus = plus; r->blk = bi;
                r->bytes = pool + bo; r->nbytes = nhx;
                memcpy(pool + np, mnb, (size_t)mnn); r->mn.p = pool + np; r->mn.n = mnn; np += mnn;
                r->op = op; r->label = lab;
                r->proc = nproc ? procs[nproc - 1] : SNONE;
                r->src = src;
                if (is_blk) {
                    int two = shas(org_text, ',') && seg_bank == NONE;
                    r->load = addr_field;
                    r->run = two ? 0 : addr_field; r->run_none = two;
                    if (seg_bank != NONE) two_addr_bank = seg_bank;
                    else if (two) {
                        unsigned char ub[4096];
                        two_addr_bank = sfind(supper(shead(org_text, 2000), ub), "B1CODE") ? 1 : 0;
                    } else two_addr_bank = 0;
                    r->bank = two_addr_bank;
                    load_off = 0; load_off_none = two;
                    pending = two ? n : -1;
                    if (two && org_hint != NONE) {
                        r->run = org_hint; r->run_none = 0;
                        load_off = org_hint - addr_field; load_off_none = 0;
                        pending = -1;
                    }
                    if (two) org_hint = NONE;
                } else {
                    if (pending >= 0) {
                        Line *pr = &L[pending];
                        if (pr->plus) die("code_map: listing line %d: cannot place a two-address block (long first line)", pr->lst);
                        load_off = addr_field - (pr->load + pr->nbytes); load_off_none = 0;
                        pr->run = pr->load + load_off; pr->run_none = 0;
                        pending = -1;
                    }
                    r->run = addr_field;
                    r->load = addr_field - (load_off_none ? 0 : load_off);
                    r->bank = seg_bank != NONE ? seg_bank : two_addr_bank;
                }
                n++;
            }
        }
    }
    *out = L;
    return n;
}

/* ---- the map --------------------------------------------------------------- */
typedef struct { int bank; STR name; int tbank; STR tname; int cnt; } CALL;
typedef struct {
    STR name; int bank, lo, hi, code, data, other;
    STR file;
    CALL *calls; int ncalls, ccap;      /* (bank, name) -> count, insertion order */
    int ncallers;
} PROC;
typedef struct { int fk, tk; const char *kind; Line *ln; int tgt, tb, has_tgt; } EDGE;

typedef struct {
    Line *lines; int nlines;
    XBLK *blocks; int nblocks;
    int mismatches;
    PROC *proc; int nproc;
    LBLK *lblocks; int nlblocks;
    int *xmap;                          /* listing block -> XEX block, NONE */
    int *starts[256]; int nstarts[256]; /* bank -> proc indices sorted by (lo, name) */
    EDGE *edges; int nedges;
    unsigned char *lst_data, *xex_data;
} MAP;

/* proc_file_map(): .proc NAME -> the .asm/.inc in ROOT that declares it
   (^\s*\.proc\s+(\w+), re.I; the first file in name order wins) */
typedef struct { unsigned char name[128]; int n; char file[MAX_PATH]; } PFM;
static PFM *PF; static int NPF;

static int pf_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void proc_file_map(void)
{
    WIN32_FIND_DATAA fd;
    HANDLE h;
    char pat[MAX_PATH], *names[4096];
    int nn = 0, k, cap = 1024;
    PF = (PFM *)malloc(cap * sizeof(PFM)); NPF = 0;
    rootp(pat, "*", 0, 0, 0);
    h = FindFirstFileA(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            int l = (int)strlen(fd.cFileName);
            if (nn < 4096 && l > 4 && (!strcmp(fd.cFileName + l - 4, ".asm") || !strcmp(fd.cFileName + l - 4, ".inc")))
                names[nn++] = _strdup(fd.cFileName);
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    qsort(names, nn, sizeof(char *), pf_cmp);
    for (k = 0; k < nn; k++) {
        char path[MAX_PATH];
        int len, pos = 0, ls, le;
        unsigned char *d = read_file(rootp(path, names[k], 0, 0, 0), &len);
        if (!d) continue;
        while (next_line(d, len, &pos, &ls, &le)) {
            int i = ls, j, m;
            unsigned char nm[128];
            while (i < le && ws(d[i])) i++;
            if (i + 5 > le || d[i] != '.' || low(d[i + 1]) != 'p' || low(d[i + 2]) != 'r' ||
                low(d[i + 3]) != 'o' || low(d[i + 4]) != 'c') continue;
            i += 5;
            if (i >= le || !ws(d[i])) continue;
            while (i < le && ws(d[i])) i++;
            j = i;
            while (j < le && isw(d[j])) j++;
            if (j == i || j - i > 127) continue;
            for (m = 0; m < j - i; m++) nm[m] = low(d[i + m]);
            for (m = 0; m < NPF; m++) if (PF[m].n == j - i && !memcmp(PF[m].name, nm, (size_t)(j - i))) break;
            if (m < NPF) continue;                       /* setdefault */
            if (NPF == cap) { cap *= 2; PF = (PFM *)realloc(PF, cap * sizeof(PFM)); }
            memcpy(PF[NPF].name, nm, (size_t)(j - i)); PF[NPF].n = j - i;
            strcpy(PF[NPF].file, names[k]);
            NPF++;
        }
        free(d);
    }
}
static STR pf_get(STR proc)
{
    unsigned char b[4096];
    STR l = slower(shead(proc, 4000), b);
    int m;
    for (m = 0; m < NPF; m++)
        if (PF[m].n == l.n && !memcmp(PF[m].name, l.p, (size_t)l.n)) return mk(PF[m].file);
    return mk("?");
}

static int find_proc(MAP *m, int bank, STR name)
{
    static int last = -1;
    int k;
    if (last >= 0 && last < m->nproc && m->proc[last].bank == bank && seq(m->proc[last].name, name)) return last;
    for (k = 0; k < m->nproc; k++) if (m->proc[k].bank == bank && seq(m->proc[k].name, name)) return last = k;
    return -1;
}

static MAP *SORTM; static int SORTB;
static int start_cmp(const void *a, const void *b)
{
    const PROC *p = &SORTM->proc[*(const int *)a], *q = &SORTM->proc[*(const int *)b];
    if (p->lo != q->lo) return p->lo < q->lo ? -1 : 1;
    if (p->bank != q->bank) return p->bank < q->bank ? -1 : 1;
    return scmp(p->name, q->name);
}

/* Map.proc_at: the proc (index) whose [lo, hi] holds addr in bank, NONE */
static int proc_at(MAP *m, int bank, int addr)
{
    int *st, n, lo = 0, hi, i;
    if (bank < 0 || bank > 255) return NONE;
    st = m->starts[bank]; n = m->nstarts[bank];
    hi = n;
    while (lo < hi) { int mid = (lo + hi) >> 1; if (m->proc[st[mid]].lo <= addr) lo = mid + 1; else hi = mid; }
    i = lo - 1;
    if (i < 0) return NONE;
    return (m->proc[st[i]].lo <= addr && addr <= m->proc[st[i]].hi) ? st[i] : NONE;
}

static int is_branch(int op)
{
    return op == 0x90 || op == 0xB0 || op == 0xF0 || op == 0xD0 || op == 0x30 || op == 0x10 ||
           op == 0x50 || op == 0x70 || op == 0x80;
}

static void add_call(PROC *p, int tb, STR tn)
{
    int k;
    for (k = 0; k < p->ncalls; k++) if (p->calls[k].tbank == tb && seq(p->calls[k].tname, tn)) { p->calls[k].cnt++; return; }
    if (p->ncalls == p->ccap) { p->ccap = p->ccap ? p->ccap * 2 : 8; p->calls = (CALL *)realloc(p->calls, p->ccap * sizeof(CALL)); }
    p->calls[p->ncalls].tbank = tb; p->calls[p->ncalls].tname = tn; p->calls[p->ncalls].cnt = 1;
    p->ncalls++;
}

/* code_map.load(lst, xex) */
static MAP *cm_load(const char *lst, const char *xex)
{
    MAP *m = (MAP *)calloc(1, sizeof(MAP));
    int ll, xl, i, j, k, bad = 0;
    XBLK *bl;
    int nbl;
    m->xex_data = read_file(xex, &xl);
    if (!m->xex_data) die("code_map: cannot read %s", xex);
    nbl = xex_blocks(m->xex_data, xl, &bl);
    /* split_b1 inserts blocks MADS never listed: each bank-$01 chunk staged at
       B1STAGE plus the INIT block behind it -- drop them */
    {
        char p[MAX_PATH];
        int ml, stage = -1, pos = 0, ls, le;
        unsigned char *md = read_file(rootp(p, "memory_map.inc", 0, 0, 0), &ml);
        if (!md) die("code_map: cannot read %s", p);
        /* ^\s*B1STAGE\s+equ\s+\$([0-9A-Fa-f]+), re.M: the first line start
           from which (whitespace and newlines skipped) it matches */
        while (stage < 0 && next_line(md, ml, &pos, &ls, &le)) {
            int q = ls, v = 0, nd = 0;
            while (q < ml && (ws(md[q]))) q++;
            if (q + 7 > ml || memcmp(md + q, "B1STAGE", 7)) continue;
            q += 7;
            if (q >= ml || !ws(md[q])) continue;
            while (q < ml && ws(md[q])) q++;
            if (q + 3 > ml || memcmp(md + q, "equ", 3)) continue;
            q += 3;
            if (q >= ml || !ws(md[q])) continue;
            while (q < ml && ws(md[q])) q++;
            if (q >= ml || md[q] != '$') continue;
            q++;
            while (q < ml && hexv(md[q]) >= 0) { v = v * 16 + hexv(md[q]); q++; nd++; }
            if (nd) stage = v;
        }
        free(md);
        if (stage >= 0) {
            int skip_init = 0, n2 = 0;
            for (i = 0; i < nbl; i++) {
                if (bl[i].lo == stage) { skip_init = 1; continue; }
                if (skip_init && bl[i].lo == 0x02E2 && bl[i].hi == 0x02E3) { skip_init = 0; continue; }
                skip_init = 0;
                bl[n2++] = bl[i];
            }
            nbl = n2;
        }
    }
    m->blocks = bl; m->nblocks = nbl;
    m->lst_data = read_file(lst, &ll);
    if (!m->lst_data) die("code_map: cannot read %s", lst);
    m->nlines = listing_lines(m->lst_data, ll, &m->lines);
    m->nlblocks = listing_blocks(m->lst_data, ll, &m->lblocks);
    m->xmap = (int *)malloc((m->nlblocks + 1) * sizeof(int));
    for (i = 0, j = 0; i < m->nlblocks; i++) {
        if (m->lblocks[i].bank) { m->xmap[i] = NONE; continue; }
        if (j < nbl && bl[j].lo == m->lblocks[i].lo && bl[j].hi == m->lblocks[i].hi) m->xmap[i] = j++;
        else m->xmap[i] = NONE;
    }
    if (j != nbl) die("code_map: only %d of %d XEX blocks line up with the listing", j, nbl);
    for (i = 0; i < m->nlines; i++) {
        Line *ln = &m->lines[i], *nx = i + 1 < m->nlines ? &m->lines[i + 1] : 0;
        int b = ln->blk < 0 ? ln->blk + m->nlblocks : ln->blk;
        if (nx && nx->blk == ln->blk) ln->size = nx->load - ln->load;
        else ln->size = m->lblocks[b].hi - ln->load + 1;
        ln->ovl = m->xmap[b] == NONE && !m->lblocks[b].bank;
        ln->kind = in_list(INSN, ln->mn.p, ln->mn.n) ? 0 : in_list(DATA, ln->mn.p, ln->mn.n) ? 1 : 2;
        if (ln->run_none) die("code_map: listing line %d: a two-address block whose run address never showed", ln->lst);
    }
    for (i = 0; i < m->nlines; i++) {
        Line *ln = &m->lines[i];
        int b = ln->blk < 0 ? ln->blk + m->nlblocks : ln->blk, off;
        XBLK *x;
        if (m->xmap[b] == NONE) continue;
        x = &bl[m->xmap[b]];
        off = ln->load - x->lo;
        if (off < 0 || off + ln->nbytes > x->n || memcmp(x->d + off, ln->bytes, (size_t)ln->nbytes)) {
            bad++;
            if (bad <= 5) {
                TXT t = {0};
                tf(&t, "code_map: MISMATCH listing line %d load $%04X: ", ln->lst, ln->load);
                tstr(&t, shead(ln->src, 60));
                tput(&t, "\n", 1);
                utf8_write(stderr, t.b, t.n);
                free(t.b);
            }
        }
    }
    m->mismatches = bad;
    /* Map.__init__: the procs */
    proc_file_map();
    {
        int cap = 256;
        m->proc = (PROC *)calloc(cap, sizeof(PROC));
        for (i = 0; i < m->nlines; i++) {
            Line *ln = &m->lines[i];
            PROC *p;
            if (ln->proc.n == NONE) continue;
            k = find_proc(m, ln->bank, ln->proc);
            if (k < 0) {
                if (m->nproc == cap) { cap *= 2; m->proc = (PROC *)realloc(m->proc, cap * sizeof(PROC)); memset(m->proc + m->nproc, 0, (cap - m->nproc) * sizeof(PROC)); }
                k = m->nproc++;
                p = &m->proc[k];
                p->name = ln->proc; p->bank = ln->bank;
                p->lo = ln->run; p->hi = ln->run + ln->size - 1;
                p->file = pf_get(ln->proc);
            }
            p = &m->proc[k];
            if (ln->run < p->lo) p->lo = ln->run;
            if (ln->run + ln->size - 1 > p->hi) p->hi = ln->run + ln->size - 1;
            if (ln->kind == 0) p->code += ln->size; else if (ln->kind == 1) p->data += ln->size; else p->other += ln->size;
        }
    }
    /* _index: bank -> procs sorted by (lo, key) */
    for (k = 0; k < m->nproc; k++) {
        int b = m->proc[k].bank & 255;
        m->starts[b] = (int *)realloc(m->starts[b], (m->nstarts[b] + 1) * sizeof(int));
        m->starts[b][m->nstarts[b]++] = k;
    }
    SORTM = m;
    for (k = 0; k < 256; k++) if (m->nstarts[k]) qsort(m->starts[k], m->nstarts[k], sizeof(int), start_cmp);
    /* _edges */
    m->edges = (EDGE *)malloc((m->nlines + 1) * sizeof(EDGE));
    for (i = 0; i < m->nlines; i++) {
        Line *ln = &m->lines[i];
        const unsigned char *b = ln->bytes;
        int nb = ln->nbytes, op, tgt = 0, tb = 0, has = 0;
        const char *kind;
        EDGE *e;
        if (ln->kind != 0 || !nb) continue;
        op = b[0];
        if (is_branch(op) && nb == 5 && b[1] == 3 && b[2] == 0x4C) { op = 0x4C; b += 2; nb -= 2; }
        if ((op == 0x20 || op == 0x4C) && nb >= 3) { tgt = b[1] | b[2] << 8; tb = ln->bank; has = 1; kind = op == 0x20 ? "jsr" : "jmp"; }
        else if ((op == 0x22 || op == 0x5C) && nb >= 4) { tgt = b[1] | b[2] << 8; tb = b[3]; has = 1; kind = op == 0x22 ? "jsl" : "jml"; }
        else if (is_branch(op) && nb == 2) { tgt = (ln->run + 2 + (b[1] > 127 ? b[1] - 256 : b[1])) & 0xFFFF; tb = ln->bank; has = 1; kind = "br"; }
        else if (op == 0x82 && nb == 3) { int o = b[1] | b[2] << 8; tgt = (ln->run + 3 + (o > 32767 ? o - 65536 : o)) & 0xFFFF; tb = ln->bank; has = 1; kind = "brl"; }
        else if (op == 0x6C) kind = "jmp()";
        else if (op == 0x7C) kind = "jmp(,x)";
        else if (op == 0xFC) kind = "jsr(,x)";
        else if (op == 0xDC) kind = "jml[]";
        else continue;
        e = &m->edges[m->nedges++];
        e->fk = ln->proc.n != NONE ? find_proc(m, ln->bank, ln->proc) : NONE;
        e->tk = has ? proc_at(m, tb, tgt) : NONE;
        e->kind = kind; e->ln = ln; e->tgt = tgt; e->tb = tb; e->has_tgt = has;
        if (e->fk != NONE && e->tk != NONE && e->fk != e->tk) {
            add_call(&m->proc[e->fk], m->proc[e->tk].bank, m->proc[e->tk].name);
            m->proc[e->tk].ncallers++;
        }
    }
    return m;
}

/* ---- 65816 opcodes (code_xref.OPS) ----------------------------------------- */
static const char *OPS_T =
"brk imm8|ora dpxi|cop imm8|ora sr|tsb dp|ora dp|asl dp|ora dpil|php imp|ora immm|asl acc|phd imp|tsb abs|ora abs|asl abs|ora long|"
"bpl rel|ora dpiy|ora dpi|ora sriy|trb dp|ora dpx|asl dpx|ora dpily|clc imp|ora absy|inc acc|tcs imp|trb abs|ora absx|asl absx|ora longx|"
"jsr abs|and dpxi|jsl long|and sr|bit dp|and dp|rol dp|and dpil|plp imp|and immm|rol acc|pld imp|bit abs|and abs|rol abs|and long|"
"bmi rel|and dpiy|and dpi|and sriy|bit dpx|and dpx|rol dpx|and dpily|sec imp|and absy|dec acc|tsc imp|bit absx|and absx|rol absx|and longx|"
"rti imp|eor dpxi|wdm imm8|eor sr|mvp bm|eor dp|lsr dp|eor dpil|pha imp|eor immm|lsr acc|phk imp|jmp abs|eor abs|lsr abs|eor long|"
"bvc rel|eor dpiy|eor dpi|eor sriy|mvn bm|eor dpx|lsr dpx|eor dpily|cli imp|eor absy|phy imp|tcd imp|jml long|eor absx|lsr absx|eor longx|"
"rts imp|adc dpxi|per rel16|adc sr|stz dp|adc dp|ror dp|adc dpil|pla imp|adc immm|ror acc|rtl imp|jmp absi|adc abs|ror abs|adc long|"
"bvs rel|adc dpiy|adc dpi|adc sriy|stz dpx|adc dpx|ror dpx|adc dpily|sei imp|adc absy|ply imp|tdc imp|jmp absxi|adc absx|ror absx|adc longx|"
"bra rel|sta dpxi|brl rel16|sta sr|sty dp|sta dp|stx dp|sta dpil|dey imp|bit immm|txa imp|phb imp|sty abs|sta abs|stx abs|sta long|"
"bcc rel|sta dpiy|sta dpi|sta sriy|sty dpx|sta dpx|stx dpy|sta dpily|tya imp|sta absy|txs imp|txy imp|stz abs|sta absx|stz absx|sta longx|"
"ldy immx|lda dpxi|ldx immx|lda sr|ldy dp|lda dp|ldx dp|lda dpil|tay imp|lda immm|tax imp|plb imp|ldy abs|lda abs|ldx abs|lda long|"
"bcs rel|lda dpiy|lda dpi|lda sriy|ldy dpx|lda dpx|ldx dpy|lda dpily|clv imp|lda absy|tsx imp|tyx imp|ldy absx|lda absx|ldx absy|lda longx|"
"cpy immx|cmp dpxi|rep imm8|cmp sr|cpy dp|cmp dp|dec dp|cmp dpil|iny imp|cmp immm|dex imp|wai imp|cpy abs|cmp abs|dec abs|cmp long|"
"bne rel|cmp dpiy|cmp dpi|cmp sriy|pei dp|cmp dpx|dec dpx|cmp dpily|cld imp|cmp absy|phx imp|stp imp|jml absil|cmp absx|dec absx|cmp longx|"
"cpx immx|sbc dpxi|sep imm8|sbc sr|cpx dp|sbc dp|inc dp|sbc dpil|inx imp|sbc immm|nop imp|xba imp|cpx abs|sbc abs|inc abs|sbc long|"
"beq rel|sbc dpiy|sbc dpi|sbc sriy|pea abs|sbc dpx|inc dpx|sbc dpily|sed imp|sbc absy|plx imp|xce imp|jsr absxi|sbc absx|inc absx|sbc longx";
static char OPMN[256][4], OPMODE[256][8];

static void ops_init(void)
{
    const char *p = OPS_T;
    int k;
    for (k = 0; k < 256; k++) {
        int i = 0;
        while (*p != ' ') OPMN[k][i++] = *p++;
        OPMN[k][i] = 0; p++; i = 0;
        while (*p && *p != '|') OPMODE[k][i++] = *p++;
        OPMODE[k][i] = 0;
        if (*p) p++;
    }
}

/* code_xref.group(ln): the listing block for code that runs somewhere other
   than where the XEX puts it, else NONE */
static int group(const Line *ln) { return (ln->ovl || ln->load != ln->run) ? ln->blk : NONE; }

/* sorted [(lo, hi_excl, line)] by lo, stable; hit() = the last range whose lo
   <= addr, if addr is inside it */
typedef struct { int lo, hi; Line *ln; } RNG;
typedef struct { RNG *r; int n, cap; } RNGS;
static void rng_add(RNGS *s, int lo, int hi, Line *ln)
{
    if (s->n == s->cap) { s->cap = s->cap ? s->cap * 2 : 256; s->r = (RNG *)realloc(s->r, s->cap * sizeof(RNG)); }
    s->r[s->n].lo = lo; s->r[s->n].hi = hi; s->r[s->n].ln = ln; s->n++;
}
static void rng_sort(RNGS *s)                 /* stable by lo (insertion sort on runs) */
{
    int i;
    RNG *tmp = (RNG *)malloc((s->n + 1) * sizeof(RNG));
    /* merge sort, stable */
    int w;
    for (w = 1; w < s->n; w *= 2) {
        for (i = 0; i < s->n; i += 2 * w) {
            int a = i, am = i + w < s->n ? i + w : s->n, b = am, bm = i + 2 * w < s->n ? i + 2 * w : s->n, o = i;
            while (a < am && b < bm) tmp[o++] = s->r[b].lo < s->r[a].lo ? s->r[b++] : s->r[a++];
            while (a < am) tmp[o++] = s->r[a++];
            while (b < bm) tmp[o++] = s->r[b++];
        }
        memcpy(s->r, tmp, s->n * sizeof(RNG));
    }
    free(tmp);
}
static Line *rng_hit(const RNGS *s, int addr)
{
    int lo = 0, hi = s->n, i;
    while (lo < hi) { int mid = (lo + hi) >> 1; if (s->r[mid].lo <= addr) lo = mid + 1; else hi = mid; }
    i = lo - 1;
    return (i >= 0 && s->r[i].lo <= addr && addr < s->r[i].hi) ? s->r[i].ln : 0;
}

/* IDENT.findall(text): [A-Za-z_?@][\w?@.]* */
static int idents(STR s, STR *out, int max)
{
    int i = 0, n = 0;
    while (i < s.n && n < max) {
        unsigned char c = s.p[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '?' || c == '@') {
            int j = i + 1;
            while (j < s.n && (isw(s.p[j]) || s.p[j] == '?' || s.p[j] == '@' || s.p[j] == '.')) j++;
            out[n].p = s.p + i; out[n].n = j - i; n++;
            i = j;
        } else i++;
    }
    return n;
}

#endif
