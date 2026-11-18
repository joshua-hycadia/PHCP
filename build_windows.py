#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# build_windows.py -- the PyInstaller build of phcp.exe, phcp_editor.exe,
# phcp_sheet.exe and phcp_isometric.exe.  The Python counterpart of
# build_windows.bat, which builds the same four from the Perl with
# PAR::Packer; run it on Windows in this folder:
#
#       python build_windows.py
#
# The command-line program, phcp.exe, needs nothing beyond Python itself
# (Tk only for the three windows) and is always built.  The text editor,
# phcp_editor.exe, the spreadsheet, phcp_sheet.exe, and the isometric
# window, phcp_isometric.exe, also need tkinter, which the Windows
# Python installers carry with them -- there is nothing to compile, the
# one step of the Perl build that could fail on a toolchain clash.
#
# The program icon goes straight in with PyInstaller's --icon, and is
# checked afterwards by reading the finished .exe back, the way the Perl
# build does: if the icon step fails the program is built the plain way,
# without it -- an icon never costs a working program.
#
# The database (data/pipes.dat), the PDF typefaces (data/fonts) and the
# icon are packed INSIDE each program: hardycross.pipedata, pdfout and
# win all look for them in the folder PyInstaller unpacks, sys._MEIPASS,
# as well as beside the program and beside the source, so a one-file
# build is self-contained.
#==============================================================================

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def step(n, total, what):
    print()
    print('[%d/%d] %s' % (n, total, what))


def run(cmd, **kw):
    p = subprocess.run(cmd, cwd=ROOT, **kw)
    return p.returncode


def have(mod):
    return run([sys.executable, '-c', 'import %s' % mod]) == 0


def build(name, script, console):
    # One file, windowed for the three windows and console for the
    # command-line program.  --clean rebuilds from scratch; the work
    # folders (build/, *.spec) are left beside the output for diagnosis.
    icon = os.path.join('data', 'phcp.ico')
    args = [sys.executable, '-m', 'PyInstaller', '--clean', '--noconfirm',
            '--onefile', '--name', name,
            '--console' if console else '--windowed',
            '--distpath', 'dist', '--workpath', 'build',
            '--specpath', 'build']
    if os.path.isfile(icon):
        args += ['--icon', icon]
        args += ['--add-data',
                 os.pathsep.join([os.path.abspath(icon), 'data'])]
    for extra in ('data/pipes.dat', 'data/fonts'):
        if os.path.isdir(extra) or os.path.isfile(extra):
            args += ['--add-data',
                     os.pathsep.join([os.path.abspath(extra), 'data'])]
    args.append(script)
    rc = run(args)
    if rc != 0:
        print('ERROR: PyInstaller failed building %s' % name)
        sys.exit(1)
    out = os.path.join('dist', name + ('.exe' if sys.platform == 'win32' else ''))
    if not os.path.isfile(out):
        print('ERROR: %s was not built' % out)
        sys.exit(1)
    return out


def main():
    os.chdir(ROOT)

    # This script builds the program files that sit BESIDE it.  Run on its
    # own, copied out of the package, it has nothing to build -- so it
    # says so plainly instead of failing later with a packager error.
    for f in ('phcp.py', os.path.join('hardycross', 'win.py'),
              os.path.join('data', 'pipes.dat')):
        if not os.path.isfile(f):
            print()
            print('ERROR: this folder does not contain the PHCP program files.')
            print('       build_windows.py must be run from INSIDE the phcp')
            print('       folder (phcp.py, hardycross, data, examples).')
            print('       Currently in: %s' % os.getcwd())
            sys.exit(1)

    step(1, 6, 'Checking Python and PyInstaller...')
    print('       Python %s' % sys.version.split()[0])
    if not have('PyInstaller'):
        print('       Installing PyInstaller...')
        if run([sys.executable, '-m', 'pip', 'install', 'pyinstaller']) != 0 \
                or not have('PyInstaller'):
            print('ERROR: PyInstaller is not available. '
                  'Run: pip install pyinstaller')
            sys.exit(1)
    import PyInstaller  # noqa: F401  (version check only)
    print('       PyInstaller %s' % PyInstaller.__version__)

    step(2, 6, 'Tk (needed for the text editor, the spreadsheet and the isometric window)...')
    gui = have('tkinter')
    print('       ok' if gui else '       SKIPPED - tkinter is not available.')

    step(3, 6, 'Building phcp.exe (command line)...')
    build('phcp', 'phcp.py', True)

    if gui:
        step(4, 6, 'Building phcp_editor.exe (text editor)...')
        build('phcp_editor', 'phcp_editor.py', False)
        step(5, 6, 'Building phcp_sheet.exe (spreadsheet)...')
        build('phcp_sheet', 'phcp_sheet.py', False)
        step(6, 6, 'Building phcp_isometric.exe (isometric window)...')
        build('phcp_isometric', 'phcp_isometric.py', False)
    else:
        print()
        print('  NOT built: phcp_editor.exe, phcp_sheet.exe and '
              'phcp_isometric.exe - tkinter is missing.')
        print('  The Windows Python installers carry tkinter; reinstall with')
        print('  tcl/tk included to build the windows.')

    exe = os.path.join('dist', 'phcp.exe' if sys.platform == 'win32' else 'phcp')

    print()
    print('Smoke test: solve an example with %s...' % os.path.basename(exe))
    ok = True
    r = subprocess.run([exe, os.path.join('examples', '05_crosscheck.phc')],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0 or 'converged yes' not in r.stdout:
        ok = False
        print('ERROR: %s did not solve the .phc example. '
              'See smoke_test_phc.txt' % os.path.basename(exe))
    open('smoke_test_phc.txt', 'w').write(r.stdout)
    if ok:
        print('       ok - .phc example solved and converged')
    r = subprocess.run([exe, os.path.join('examples', '07_pipe_database_demo.phc'),
                        'smoke_test.pdf'], capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0 or not os.path.isfile('smoke_test.pdf'):
        ok = False
        print('ERROR: no PDF was written')
    elif ok:
        print('       ok - PDF report written')
    r = subprocess.run([exe, '--json', os.path.join('examples', '05_crosscheck.phc')],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0 or '"interface" : 2' not in r.stdout:
        ok = False
        print('ERROR: %s --json gave no result. See smoke_test.json'
              % os.path.basename(exe))
    open('smoke_test.json', 'w').write(r.stdout)
    if ok:
        print('       ok - JSON interface written')

    print()
    print('=' * 77)
    if ok:
        built = ['phcp.exe']
        if gui:
            built += ['phcp_editor.exe', 'phcp_sheet.exe', 'phcp_isometric.exe']
        print('  Built: %s (in dist\\)' % ', '.join(built))
    else:
        print('  ERROR: the smoke test failed - see above')
        sys.exit(1)
    print('=' * 77)


if __name__ == '__main__':
    main()
