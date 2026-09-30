#!/usr/bin/env python3
"""Package wadconv as ONE Windows file -> exe/wadconv.exe

  python tools/make_exe.py

WHAT COMES OUT: exe/wadconv.exe, and nothing else. Somebody is handed that one
file, puts a WAD in it, and gets an ATR beside the WAD. No install, no Python,
no folder of parts to keep together.

HOW IT HOLDS TOGETHER. Converting is not "read a WAD, write a file": it runs
build_atr.ps1, which drives a dozen packers and mads.exe and assembles the
actual 6502 engine for the levels being converted. So the whole port -- every
.asm, every .inc, tools/*.py, build_atr.ps1, mads.exe -- rides INSIDE the EXE,
and PyInstaller unpacks it for the life of the run. The EXE is also its own
interpreter: it puts itself in DOOM_PY, build_atr.ps1 runs each packer through
$py, and every one of those lands back in wadconv_exe.py. The user needs no
Python at all.

Nothing survives the run, and nothing needs to -- a conversion repacks
everything from its own WAD pair anyway. The ATR is written beside the WAD.

DOOM.WAD IS NOT IN HERE and must not be: it is id Software's. The tool asks for
the user's own copy, exactly as every DOOM source port does.
"""
import os
import shutil
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJ = os.path.dirname(_HERE)
OUT = os.path.join(_PROJ, 'exe')
ENTRY = os.path.join(_HERE, 'wad', 'wadconv_exe.py')

# The engine tree, by extension where a whole class is wanted and by name where
# it is not. Everything build_atr.ps1 reads has to be in here, or the packaged
# tool dies halfway through a conversion on a missing file.
KEEP_EXT = ('.asm', '.inc', '.py', '.ps1')
KEEP_NAME = ('mads.exe', 'VERSION', 'res')
SKIP_DIRS = {'build', 'exe', 'wads-mapy', '__pycache__', '.git', 'bench',
             'sram', 'mads-src', 'alt-src', '_doomsrc',
             'tests'}
# Never ship a commercial IWAD.
SKIP_FILES = {'doom.wad', 'doom2.wad', 'tnt.wad', 'plutonia.wad'}


def _wanted(fn):
    low = fn.lower()
    if low in SKIP_FILES or low.endswith('.wad'):
        return False
    return fn in KEEP_NAME or os.path.splitext(fn)[1].lower() in KEEP_EXT


def stage_engine(dst):
    """The engine tree, copied to `dst` for PyInstaller to swallow."""
    n = 0
    for root, dirs, files in os.walk(_PROJ):
        rel = os.path.relpath(root, _PROJ)
        parts = set() if rel == '.' else set(rel.split(os.sep))
        if parts & SKIP_DIRS or any(p.startswith('__') for p in parts):
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs
                   if d not in SKIP_DIRS and not d.startswith('__')
                   and not d.startswith('.')]
        for fn in files:
            if not _wanted(fn):
                continue
            out = os.path.join(dst, fn) if rel == '.' \
                else os.path.join(dst, rel, fn)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            shutil.copy2(os.path.join(root, fn), out)
            n += 1
    # THE DOOM C SOURCE COMES TOO. doomstates.py reads info.c for what every
    # monster does when it is shot, and doomspecs.py reads p_switch.c,
    # p_doors.c and p_spec.c for the line specials -- at BUILD time, not once
    # into a table. Leave it out and the packaged tool dies on the first
    # conversion with "info.c missing". It is linuxdoom-1.10, GPL, so it
    # travels legitimately; only the .c/.h, not the whole checkout.
    src = os.path.join(_PROJ, '_doomsrc')
    if os.path.isdir(src):
        for fn in sorted(os.listdir(src)):
            if os.path.splitext(fn)[1].lower() in ('.c', '.h'):
                out = os.path.join(dst, '_doomsrc', fn)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                shutil.copy2(os.path.join(src, fn), out)
                n += 1
    os.makedirs(os.path.join(dst, 'build'), exist_ok=True)
    return n


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='wadconv_stage_')
    engine = os.path.join(tmp, 'engine')
    try:
        n = stage_engine(engine)
        work = os.path.join(tmp, 'work')
        cmd = [sys.executable, '-m', 'PyInstaller', '--noconfirm',
               '--name', 'wadconv', '--onefile',
               # CONSOLE, not --windowed, and not by accident: build_atr.ps1
               # reads what the packers print, and a windowed PyInstaller build
               # hands them sys.stdout = None -- the first print() in the first
               # packer would end the conversion. The window hides the console
               # itself when it opens (wadconv_exe.hide_console).
               '--console',
               '--add-data', f'{engine}{os.pathsep}engine',
               '--distpath', OUT, '--workpath', work, '--specpath', work,
               '--hidden-import', 'numpy', '--hidden-import', 'PIL',
               '--hidden-import', 'PIL.Image', '--hidden-import', 'tkinter',
               '--collect-submodules', 'numpy',
               ENTRY]
        print(f'staged {n} engine files')
        r = subprocess.run(cmd, cwd=_PROJ)
        if r.returncode:
            sys.exit('PyInstaller failed')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    exe = os.path.join(OUT, 'wadconv.exe')
    print(f'\n-> {exe}  ({os.path.getsize(exe) / 1e6:.0f} MB)')
    left = [x for x in sorted(os.listdir(OUT))
            if x not in ('wadconv.exe', 'wadconv.json')]  # .json is the
                                        # tool's own remembered settings
    if left:
        print(f'   POZOR, v exe/ je aj: {", ".join(left)}')


if __name__ == '__main__':
    main()
