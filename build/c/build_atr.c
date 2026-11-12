/* build_atr -- build the BOOTABLE DOOM ATR: boot loader + engine XEX + every
 * level. A C program (2026-11-05: it replaced build_atr.ps1 step for step),
 * at the repo root as build_atr.exe:
 *
 *     tools\tcc\tcc.exe -o build_atr.exe build\c\build_atr.c
 *
 * Boots from the ATR so the OS cold-starts cleanly (valid VIMIRQ) and the
 * engine's SIO level streaming works. Mount the result as D1: and boot it.
 * Usage:  build_atr.exe               every level, INCREMENTAL
 *         build_atr.exe -Full         re-pack every asset from the WAD
 *         build_atr.exe -Time         + seconds per step
 *         build_atr.exe -Keep         keep the .xex files in build/
 *         build_atr.exe -Fx127:false  the VBXE FX 1.26 build (FX127 is on by default)
 *         build_atr.exe E1M1 E1M2     only these levels
 * EVERY run writes BOTH images: build/doom.atr (stock, Rapidus) and
 * build/doom_bsp_ant2.atr (ANTONIA II hardware mul/div).
 *
 * WHY THE SWITCHES (2026-08-11). Three packers (pack_map, pack_textures,
 * pack_things) only ever read the WAD; editing an .asm file cannot change one
 * byte of what they emit, so the default build reuses build/assets. They still
 * run whenever anything they READ moved -- a packer or library in build\py, the
 * WAD, a missing output or a different level set (map_syms.inc/mk_tables.inc
 * carry capacities sized over the BUILT set). -Full forces them.
 * THIS ONLY BUILDS (2026-11-05). The checks are separate programs, run by hand:
 * build\exe\b1_check.exe, build\exe\check_overlap.exe, build\py\check_xex.py,
 * build\py\bank_map.py --check, build\py\_verify_useside.py, tools\tests\_verify_*.py,
 * tools\tests\check_boot.py.
 *
 * THE C PROGRAMS: build\c\*.c -> build\exe\*.exe with tools\tcc, whenever the
 * .c (or any build\c\*.h) is newer than its .exe. A source without a main() is
 * a library (build\exe\*.dll) until its callers are C too. This program's own
 * source is not built there: when build\c\build_atr.c is newer than the running
 * build_atr.exe it says so.
 */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int FULL, TIME, KEEP, FX127 = 1;
static char PY[MAX_PATH * 2] = "python";
static char MADS[MAX_PATH], TCC[MAX_PATH], ROOTD[MAX_PATH];
static const char *LVLS[256];
static int NLV;
static LARGE_INTEGER FREQ, T_ALL, T_STEP;

/* ---- small things ------------------------------------------------------- */
static void fail(const char *fmt, ...)
{
    va_list a;
    fflush(stdout);
    fprintf(stderr, "build_atr: ");
    va_start(a, fmt);
    vfprintf(stderr, fmt, a);
    va_end(a);
    fputc('\n', stderr);
    exit(1);
}
static int exists(const char *p) { return GetFileAttributesA(p) != INVALID_FILE_ATTRIBUTES; }
static int mtime(const char *p, ULONGLONG *t)
{
    WIN32_FILE_ATTRIBUTE_DATA d;
    if (!GetFileAttributesExA(p, GetFileExInfoStandard, &d)) return 0;
    *t = ((ULONGLONG)d.ftLastWriteTime.dwHighDateTime << 32) | d.ftLastWriteTime.dwLowDateTime;
    return 1;
}
static double secs(LARGE_INTEGER since)
{
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (double)(now.QuadPart - since.QuadPart) / (double)FREQ.QuadPart;
}
static void comma(char *s) { for (; *s; s++) if (*s == '.') *s = ','; }
static void lap(const char *what)            /* -Time: one line per step */
{
    if (TIME) {
        char b[64];
        sprintf(b, "%6.2f", secs(T_STEP));
        comma(b);
        printf("  [%ss] %s\n", b, what);
        fflush(stdout);
    }
    QueryPerformanceCounter(&T_STEP);
}
static char *joinlv(char *out, const char *sep)
{
    int k;
    out[0] = 0;
    for (k = 0; k < NLV; k++) { if (k) strcat(out, sep); strcat(out, LVLS[k]); }
    return out;
}
static void setenv_(const char *k, const char *v) { SetEnvironmentVariableA(k, (v && *v) ? v : NULL); }
static const char *getenv_(const char *k, char *buf, int n)
{
    DWORD r = GetEnvironmentVariableA(k, buf, n);
    if (!r || (int)r >= n) buf[0] = 0;
    return buf;
}

/* ---- running programs --------------------------------------------------- */
typedef struct { HANDLE proc, thr, rd; char *buf; size_t n, cap; DWORD code; } JOB;

static DWORD WINAPI reader(LPVOID arg)
{
    JOB *j = (JOB *)arg;
    char b[8192];
    DWORD got;
    while (ReadFile(j->rd, b, sizeof b, &got, 0) && got) {
        if (j->n + got + 1 > j->cap) { j->cap = (j->n + got + 1) * 2; j->buf = (char *)realloc(j->buf, j->cap); }
        memcpy(j->buf + j->n, b, got);
        j->n += got;
        j->buf[j->n] = 0;
    }
    return 0;
}

/* a command line for prog + args; a .cmd/.bat interpreter goes through cmd /c */
static void cmdline(char *out, const char *prog, const char *args)
{
    size_t n = strlen(prog);
    int batch = n > 4 && (!_stricmp(prog + n - 4, ".cmd") || !_stricmp(prog + n - 4, ".bat"));
    if (batch) sprintf(out, "cmd.exe /c \"\"%s\" %s\"", prog, args);
    else sprintf(out, "\"%s\" %s", prog, args);
}

/* start; capture = stdout (and stderr if merge) into j->buf */
static void start(JOB *j, const char *prog, const char *args, int capture, int merge)
{
    static char cl[32768];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa;
    HANDLE wr = 0;
    memset(j, 0, sizeof *j);
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (capture) {
        sa.nLength = sizeof sa; sa.lpSecurityDescriptor = 0; sa.bInheritHandle = TRUE;
        if (!CreatePipe(&j->rd, &wr, &sa, 0)) fail("cannot make a pipe");
        SetHandleInformation(j->rd, HANDLE_FLAG_INHERIT, 0);
        si.hStdOutput = wr;
        if (merge) si.hStdError = wr;
    }
    cmdline(cl, prog, args);
    fflush(stdout); fflush(stderr);
    if (!CreateProcessA(0, cl, 0, 0, TRUE, 0, 0, ROOTD, &si, &pi)) fail("cannot run %s", cl);
    CloseHandle(pi.hThread);
    j->proc = pi.hProcess;
    if (capture) {
        CloseHandle(wr);
        j->thr = CreateThread(0, 0, reader, j, 0, 0);
    }
}
static DWORD finish(JOB *j)
{
    WaitForSingleObject(j->proc, INFINITE);
    GetExitCodeProcess(j->proc, &j->code);
    CloseHandle(j->proc);
    if (j->thr) { WaitForSingleObject(j->thr, INFINITE); CloseHandle(j->thr); CloseHandle(j->rd); }
    if (!j->buf) { j->buf = (char *)calloc(1, 1); }
    return j->code;
}
static DWORD run(const char *prog, const char *args)        /* output straight through */
{
    JOB j;
    start(&j, prog, args, 0, 0);
    return finish(&j);
}
static DWORD py(const char *args) { return run(PY, args); }

/* the output's lines: print the first n / the last n (trailing blank ones dropped) */
static void print_lines(const char *s, int first, int last)
{
    const char *p;
    int nl = 0, k = 0, from;
    size_t len = strlen(s);
    while (len && (s[len - 1] == '\n' || s[len - 1] == '\r')) len--;
    if (!len) return;
    for (p = s; p < s + len; p++) if (*p == '\n') nl++;
    nl++;
    from = last ? (nl > last ? nl - last : 0) : 0;
    for (p = s; p < s + len && (!first || k < first); k++) {
        const char *e = memchr(p, '\n', (size_t)(s + len - p));
        size_t n = e ? (size_t)(e - p) : (size_t)(s + len - p);
        if (n && p[n - 1] == '\r') n--;
        if (k >= from) { fwrite(p, 1, n, stdout); fputc('\n', stdout); }
        if (!e) break;
        p = e + 1;
    }
    fflush(stdout);
}

/* ---- the C programs --------------------------------------------------------- */
static void build_c(void)
{
    WIN32_FIND_DATAA fd;
    HANDLE h;
    ULONGLONG newest_h = 0, t;
    char pat[MAX_PATH];
    CreateDirectoryA("build\\exe", 0);
    h = FindFirstFileA("build\\c\\*.h", &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            char p[MAX_PATH];
            sprintf(p, "build\\c\\%s", fd.cFileName);
            if (mtime(p, &t) && t > newest_h) newest_h = t;
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    strcpy(pat, "build\\c\\*.c");
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        char src[MAX_PATH], bin[MAX_PATH], base[MAX_PATH], args[MAX_PATH * 3], *dot;
        int is_exe = 0;
        ULONGLONG ts, tb;
        FILE *f;
        if (!_stricmp(fd.cFileName, "build_atr.c")) continue;
        sprintf(src, "build\\c\\%s", fd.cFileName);
        strcpy(base, fd.cFileName);
        if ((dot = strrchr(base, '.')) != 0) *dot = 0;
        if ((f = fopen(src, "r")) != 0) {
            char line[4096];
            while (fgets(line, sizeof line, f)) if (!strncmp(line, "int main(", 9)) { is_exe = 1; break; }
            fclose(f);
        }
        sprintf(bin, "build\\exe\\%s.%s", base, is_exe ? "exe" : "dll");
        mtime(src, &ts);
        if (newest_h > ts) ts = newest_h;
        if (!mtime(bin, &tb) || tb < ts) {
            char def[MAX_PATH];
            sprintf(args, is_exe ? "-o %s %s" : "-shared -o %s %s", bin, src);
            if (run(TCC, args)) fail("tcc failed: %s", fd.cFileName);
            sprintf(def, "build\\exe\\%s.def", base);
            DeleteFileA(def);
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    {
        char self[MAX_PATH];
        ULONGLONG ts, te;
        GetModuleFileNameA(0, self, MAX_PATH);
        if (mtime("build\\c\\build_atr.c", &ts) && mtime(self, &te) && ts > te)
            printf("NOTE: build\\c\\build_atr.c is newer than build_atr.exe -- rebuild it: "
                   "tools\\tcc\\tcc.exe -o build_atr.exe build\\c\\build_atr.c\n");
    }
}

/* the XEX minus its 6-byte header (the $FFFF and one block header) */
static void strip6(const char *xex, const char *bin)
{
    FILE *f = fopen(xex, "rb"), *o;
    static unsigned char b[1 << 20];
    size_t n;
    if (!f) fail("cannot read %s", xex);
    n = fread(b, 1, sizeof b, f);
    fclose(f);
    if (!(o = fopen(bin, "wb"))) fail("cannot write %s", bin);
    if (n > 6) fwrite(b + 6, 1, n - 6, o);
    fclose(o);
}

/* newest / oldest of a set of paths (patterns allowed) */
typedef struct { char name[MAX_PATH]; ULONGLONG t; int have; } PICK;
static void pick(PICK *pk, const char *pattern, int newest)
{
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        ULONGLONG t = ((ULONGLONG)fd.ftLastWriteTime.dwHighDateTime << 32) | fd.ftLastWriteTime.dwLowDateTime;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (!pk->have || (newest ? t > pk->t : t < pk->t)) { pk->have = 1; pk->t = t; strcpy(pk->name, fd.cFileName); }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}

/* ---- the mads runs -------------------------------------------------------- */
static JOB MJ[4];
static void mads_start(JOB *j, const char *opts)
{
    char a[1024];
    sprintf(a, "-i:. %s bsp_main.asm %s", FX127 ? "-d:FX127=1" : "", opts);
    start(j, MADS, a, 1, 0);
}
static void mads_end(JOB *j, const char *what, int show)
{
    finish(j);
    if (show || j->code) print_lines(j->buf, 0, 0);
    if (j->code) fail("%s failed", what);
}

/* ANTONIA II steps: quiet unless one fails */
static void ant_step(const char *what, const char *prog, const char *args)
{
    JOB j;
    start(&j, prog, args, 1, 0);
    finish(&j);
    if (j.code) {
        setenv_("DOOM_IMG", 0);
        print_lines(j.buf, 0, 20);
        fail("ANTONIA II image: %s failed", what);
    }
}

int main(int argc, char **argv)
{
    static const char *ALL[] = {"E1M1","E1M2","E1M3","E1M4","E1M5","E1M6","E1M7","E1M8","E1M9",
        "E2M1","E2M2","E2M3","E2M4","E2M5","E2M6","E2M7","E2M8","E2M9",
        "E3M1","E3M2","E3M3","E3M4","E3M5","E3M6","E3M7","E3M8","E3M9"};
    char lv_sp[4096], lv_cm[4096], a[8192], env1[MAX_PATH], env2[4096], *p;
    int k, v = 0;
    QueryPerformanceFrequency(&FREQ);
    QueryPerformanceCounter(&T_ALL);
    T_STEP = T_ALL;
    for (k = 1; k < argc; k++) {
        const char *s = argv[k];
        if (s[0] == '-') {
            if (!_stricmp(s, "-Full")) FULL = 1;
            else if (!_stricmp(s, "-Time")) TIME = 1;
            else if (!_stricmp(s, "-Keep")) KEEP = 1;
            else if (!_stricmp(s, "-Fx127") || !_stricmp(s, "-Fx127:$true") || !_stricmp(s, "-Fx127:true")) FX127 = 1;
            else if (!_stricmp(s, "-Fx127:$false") || !_stricmp(s, "-Fx127:false") || !_stricmp(s, "-Fx127:0")) FX127 = 0;
            else if (!_stricmp(s, "-Quick") || !_stricmp(s, "-Antonia2")) { /* accepted and ignored: both images every run */ }
            else fail("unknown switch %s", s);
        } else if (NLV < 256) LVLS[NLV++] = s;
    }
    if (!NLV) for (k = 0; k < 27; k++) LVLS[NLV++] = ALL[k];
    joinlv(lv_sp, " ");
    joinlv(lv_cm, ",");
    /* the repo root is where this program lives */
    GetModuleFileNameA(0, ROOTD, MAX_PATH);
    if ((p = strrchr(ROOTD, '\\')) != 0) *p = 0;
    SetCurrentDirectoryA(ROOTD);
    setenv_("DOOM_FX127", FX127 ? "1" : "0");
    /* WHICH INTERPRETER RUNS THE PACKERS: 'python', or DOOM_PY (wadconv points
       it at build\py\wad\custom\py.cmd; the project pins the Thonny Python) */
    getenv_("DOOM_PY", a, sizeof a);
    if (a[0]) strcpy(PY, a);
    setenv_("PYTHONDONTWRITEBYTECODE", "1");         /* no __pycache__ beside the tools */
    {
        char parent[MAX_PATH];
        strcpy(parent, ROOTD);
        if ((p = strrchr(parent, '\\')) != 0) *p = 0;
        sprintf(MADS, "%s\\mads.exe", parent);
        if (!exists(MADS)) sprintf(MADS, "%s\\mads.exe", ROOTD);
    }
    sprintf(TCC, "%s\\tools\\tcc\\tcc.exe", ROOTD);
    CreateDirectoryA("build", 0);
    build_c();

    /* 1b. digitized SFX blob + sound_tables.inc (inputs to the layout below) */
    if (py("build\\py\\wadsound.py")) fail("sound extract failed");

    /* 1c. weapon psprites + weap_tables.inc. Skipped when its blobs are there
       and newer than the packer + WAD (pack_weap imports pack_things, which
       reads the DOOM source tree at import time). -Full forces the repack. */
    {
        static const char *outs[2] = {"build\\assets\\weap\\weap.bin", "build\\assets\\weap\\weap.tab"};
        int doit = FULL || !exists(outs[0]) || !exists(outs[1]);
        if (!doit) {
            PICK in = {0}, out = {0};
            pick(&in, "build\\py\\pack_weap.py", 1);
            pick(&in, "build\\py\\DOOM.WAD", 1);
            pick(&out, outs[0], 0);
            pick(&out, outs[1], 0);
            if (in.have && out.t < in.t) doit = 1;
        }
        if (doit) { if (py("build\\py\\pack_weap.py")) fail("weapon extract failed"); }
        else printf("weapon psprites up to date -- pack_weap skipped. Force with -Full\n");
    }
    /* 1c-2. COLORMAP -> cmap.bin; 1c-2b. the sky -> sky.bin; 1c-3. the status bar */
    if (py("build\\py\\pack_cmap.py")) fail("colormap extract failed");
    if (py("build\\py\\pack_sky.py")) fail("sky extract failed");
    if (py("build\\py\\pack_hud.py")) fail("hud pack failed");
    lap("wad assets (sound/weap/cmap/hud)");

    /* 1c-bis0. the build version: VERSION holds the minor number, every build
       bumps it, and pack_menu bakes it into the READ THIS! screen */
    {
        FILE *f = fopen("VERSION", "r");
        char line[64];
        if (f) { if (fgets(line, sizeof line, f)) { char *e; long x = strtol(line, &e, 10); while (*e == ' ' || *e == '\t' || *e == '\r' || *e == '\n') e++; v = (*e || e == line) ? 0 : (int)x; } fclose(f); }
        v++;
        if (!(f = fopen("VERSION", "w"))) fail("cannot write VERSION");
        fprintf(f, "%d\n", v);
        fclose(f);
        printf("build version %d.%02d\n", v / 100, v % 100);
    }
    /* 1c-bis. intermission, finale, then the title + menu (which swallows both) */
    sprintf(a, "build\\py\\pack_wi.py --levels %s", lv_cm);
    if (py(a)) fail("wi pack failed");
    if (py("build\\py\\pack_fin.py")) fail("finale pack failed");
    sprintf(a, "build\\py\\pack_menu.py --levels %s", lv_cm);
    if (py(a)) fail("menu pack failed");
    lap("menu + version");

    /* 1d. the per-level blobs. EVERY output of the three must exist and be
       newer than every packer/library in build\py and the WAD; the WAD pair,
       the level list and the texture format are stamped too. */
    {
        static char outs[4096][MAX_PATH];
        int no = 0, repack = FULL, i;
        char why[1024] = "forced (-Full)", want[8192], have[8192] = "";
        strcpy(outs[no++], "map_syms.inc");
        strcpy(outs[no++], "mk_tables.inc");
        strcpy(outs[no++], "build\\assets\\textures\\playpal.bin");
        strcpy(outs[no++], "build\\assets\\things\\sprpool.bin");
        for (k = 0; k < NLV; k++) {
            static const char *f1[] = {"wadmaps\\%s.bin", "textures\\%s.tex", "textures\\%s.texix", "textures\\%s.textab",
                "textures\\%s.segtex", "things\\%s.things", "things\\%s.dtab", "things\\%s.los", "things\\%s.sprcol",
                "things\\%s.sprmeta"};
            for (i = 0; i < 10; i++) {
                char t[MAX_PATH];
                sprintf(t, f1[i], LVLS[k]);
                sprintf(outs[no++], "build\\assets\\%s", t);
            }
        }
        if (!repack)
            for (i = 0; i < no; i++) if (!exists(outs[i])) { repack = 1; sprintf(why, "%s is missing", outs[i]); break; }
        if (!repack) {
            PICK in = {0}, out = {0};
            pick(&in, "build\\py\\pack_*.py", 1);
            pick(&in, "build\\py\\wad*.py", 1);
            pick(&in, "build\\py\\doom*.py", 1);
            pick(&in, "build\\py\\texruns.py", 1);
            pick(&in, "build\\py\\DOOM.WAD", 1);
            for (i = 0; i < no; i++) pick(&out, outs[i], 0);
            if (in.have && out.have && out.t < in.t) { repack = 1; sprintf(why, "%s is newer than %s", in.name, out.name); }
        }
        getenv_("DOOMWAD", env1, sizeof env1);
        getenv_("DOOMPWAD", env2, sizeof env2);
        sprintf(want, "%s|%s|%s|fx127=%s", env1, env2, lv_sp, FX127 ? "1" : "0");
        if (!repack) {
            FILE *f = fopen("build\\.packed.stamp", "r");
            if (f) { if (!fgets(have, sizeof have, f)) have[0] = 0; fclose(f); }
            have[strcspn(have, "\r\n")] = 0;
            if (strcmp(have, want)) { repack = 1; strcpy(why, "the WAD pair, level set or texture format changed"); }
        }
        if (repack) {
            FILE *f;
            printf("packing levels: %s\n", why);
            sprintf(a, "build\\py\\pack_map.py %s", lv_sp);
            if (py(a)) fail("map pack failed");
            sprintf(a, "build\\py\\pack_textures.py %s", lv_sp);
            if (py(a)) fail("texture pack failed");
            sprintf(a, "build\\py\\pack_things.py %s", lv_sp);
            if (py(a)) fail("things pack failed");
            if (!(f = fopen("build\\.packed.stamp", "w"))) fail("cannot write build\\.packed.stamp");
            fprintf(f, "%s\n", want);
            fclose(f);
        } else printf("level assets up to date -- pack_map/pack_textures/pack_things skipped (~35 s). Force with -Full\n");
    }
    lap("level assets");

    /* 2. level layout (atr_layout.inc) BEFORE building the XEX */
    sprintf(a, "build\\py\\make_atr_doom.py --dir %s", lv_sp);
    if (py(a)) fail("layout emit failed");
    /* 2b. the boot loader -> raw boot.bin, after the layout (its machine check
       probes up to the top bank THIS build uses; its screen shows the version) */
    if (py("build\\py\\boot_cfg.py")) fail("boot config failed");
    sprintf(a, "-i:. %s boot.asm -o:build/boot.xex", FX127 ? "-d:FX127=1" : "");
    if (run(MADS, a)) fail("boot assemble failed");
    CreateDirectoryA("build\\assets", 0);
    CreateDirectoryA("build\\assets\\code", 0);
    strip6("build\\boot.xex", "build\\assets\\code\\boot.bin");
    sprintf(a, "-i:. %s -d:ANTONIA2=1 boot.asm -o:build/boot_ant2.xex", FX127 ? "-d:FX127=1" : "");
    if (run(MADS, a)) fail("boot assemble (ANTONIA II) failed");
    strip6("build\\boot_ant2.xex", "build\\assets\\code\\boot_ant2.bin");
    lap("boot loader");

    /* 3. the engine: ALL FOUR assemblies side by side -- the engine, the same
       with VBXE_D7, and the ANTONIA II pair step 4-ant picks up later */
    mads_start(&MJ[0], "-o:build/doom_bsp.xex -l:build/doom_bsp.lst -t:build/doom_bsp.lab");
    mads_start(&MJ[1], "-d:VBXE_D7=1 -o:build/doom_bsp_d7.xex");
    mads_start(&MJ[2], "-d:ANTONIA2=1 -o:build/doom_bsp_ant2.xex -l:build/doom_bsp_ant2.lst -t:build/doom_bsp_ant2.lab");
    mads_start(&MJ[3], "-d:ANTONIA2=1 -d:VBXE_D7=1 -o:build/doom_bsp_d7_ant2.xex");
    mads_end(&MJ[0], "assemble", 1);
    /* 3-bis. which bytes move with a VBXE at $D7xx, BEFORE the splits */
    mads_end(&MJ[1], "assemble (VBXE_D7)", 0);
    if (run("build\\exe\\vbxe_reloc.exe", "")) fail("VBXE relocation failed");
    DeleteFileA("build\\doom_bsp_d7.xex");
    lap("mads");

    /* 3a. the menu CODE overlays out of the XEX into menu.bin's chunks */
    if (run("build\\exe\\split_menu_ovl.exe", "")) fail("menu overlay split failed");
    /* 3a'. the bank-$01 code out of the XEX, back in as INIT chunks */
    if (run("build\\exe\\split_b1.exe", "")) fail("bank $01 split failed");
    lap("overlay split");

    /* 4. the bootable ATR */
    sprintf(a, "build\\py\\make_atr_doom.py %s", lv_sp);
    if (py(a)) fail("atr build failed");
    lap("ATR image");

    /* 4-ant. THE ANTONIA II IMAGE, every run, after the stock one. DOOM_IMG gives
       every file of this pass its own name. Quiet unless it fails. */
    mads_end(&MJ[2], "ANTONIA II image: assemble", 0);
    mads_end(&MJ[3], "ANTONIA II image: assemble (VBXE_D7)", 0);
    setenv_("DOOM_IMG", "_ant2");
    ant_step("VBXE relocation", "build\\exe\\vbxe_reloc.exe", "");
    DeleteFileA("build\\doom_bsp_d7_ant2.xex");
    ant_step("menu overlay split", "build\\exe\\split_menu_ovl.exe", "");
    ant_step("bank $01 split", "build\\exe\\split_b1.exe", "");
    sprintf(a, "build\\py\\make_atr_doom.py %s", lv_sp);
    ant_step("atr build", PY, a);
    setenv_("DOOM_IMG", 0);
    lap("ANTONIA II image");

    {
        char b[64];
        sprintf(b, "%.1f", secs(T_ALL));
        comma(b);
        printf("OK -> build/doom.atr + build/doom_bsp_ant2.atr (ANTONIA II ONLY, not Rapidus)  (%ss)\n", b);
    }
    /* build/ keeps the two ATRs, doom_bsp[_ant2].lst/.lab (wadconv reads them;
       NEVER deleted) and the folders; the XEXs go unless -Keep */
    if (!KEEP) {
        WIN32_FIND_DATAA fd;
        HANDLE h = FindFirstFileA("build\\*.xex", &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do { char x[MAX_PATH]; sprintf(x, "build\\%s", fd.cFileName); DeleteFileA(x); } while (FindNextFileA(h, &fd));
            FindClose(h);
        }
    }
    return 0;
}
