#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# doc_screenshots.py -- the pictures in docs/USER_GUIDE.md, taken from the
# programs themselves.  Python port of doc_screenshots.pl.
#
#   python3 tools/doc_screenshots.py [outdir]        (default docs/images)
#
# Each window (the text editor, the spreadsheet and the isometric drawing) is
# opened on examples/02_full_network.phc, validated and calculated, and each
# tab the guide describes is saved as a PNG with ImageMagick's import.  The
# GRAPH tab is given examples/10_supply_graph.phg, so it has a graph to draw.
# So the guide shows the programs as they are, not as they were when it was
# written.
#
# Needs tkinter, ImageMagick and an X display.  With no display it re-runs
# itself under xvfb-run, the same arrangement as the window tests; CI's
# "screenshots" job runs it and keeps the pictures as an artifact.
#
# The three programs each keep their window in module state, so each runs in
# a process of its own (--one <program> <outdir>).
#==============================================================================
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, ROOT)
MODEL = os.path.join(ROOT, 'examples', '02_full_network.phc')


def die(msg):
    sys.stderr.write(msg + '\n')
    sys.exit(1)


def main():
    argv = sys.argv[1:]

    #--------------------------------------------------------- a display
    if not os.environ.get('DISPLAY'):
        if not os.environ.get('PHCP_UNDER_XVFB') and shutil.which('xvfb-run'):
            os.environ['PHCP_UNDER_XVFB'] = '1'
            os.execvp('xvfb-run', ['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
                                   sys.executable, os.path.abspath(__file__)] + argv)
        die('doc_screenshots: no X display and no xvfb-run')
    try:
        import tkinter  # noqa: F401
    except ImportError:
        die('doc_screenshots: tkinter is not installed')
    if not shutil.which('import'):
        die("doc_screenshots: ImageMagick's import is not installed")

    #--------------------------------------------------------- the parent
    if not (argv and argv[0] == '--one'):
        out = os.path.abspath(argv[0] if argv else os.path.join(ROOT, 'docs', 'images'))
        os.makedirs(out, exist_ok=True)
        bad = 0
        for prog in ('editor', 'sheet', 'isometric'):
            print('== %s' % prog)
            sys.stdout.flush()
            if subprocess.call([sys.executable, os.path.abspath(__file__), '--one', prog, out]) != 0:
                bad += 1
        sys.exit(1 if bad else 0)

    #--------------------------------------------------------- one program
    prog, outdir = argv[1], argv[2]
    os.chdir(ROOT)
    # Settings of this run's own, so a user's real ones are never read: every
    # picture is the program's defaults (light mode, the shipped database).
    settings_dir = tempfile.mkdtemp()
    os.environ['PHCP_SETTINGS'] = os.path.join(settings_dir, 'settings.ini')
    os.environ.pop('PHCP_DATABASE_DIR', None)

    from hardycross import win
    if prog == 'editor':
        app = win
    elif prog == 'sheet':
        from hardycross import sheetwindow as app
    elif prog == 'isometric':
        # Importing the isometric module patches the editor into the
        # isometric program, as phcp_isometric.py does.
        from hardycross.window import isometric as ISO
        app = win
    else:
        die('doc_screenshots: unknown program %s' % prog)

    app.build_window()
    mw = app.mw
    mw.update()
    if not app.open_path(MODEL):
        die('doc_screenshots: %s did not open' % MODEL)
    mw.update()
    app.validate()
    app.calculate()
    mw.update()

    # shot -- show the given tabs, then save the window as <program>_<name>.png.
    def shot(name, *tabs):
        tabs = list(tabs)
        while tabs:
            bar, tab = tabs[0], tabs[1]
            del tabs[:2]
            win.select_tab(bar, tab)
        mw.lift()
        mw.update()
        mw.update_idletasks()
        f = os.path.join(outdir, '%s_%s.png' % (prog, name))
        if subprocess.call(['import', '-window', str(mw.winfo_id()), f]) == 0:
            print('  %s' % f)
            sys.stdout.flush()
        else:
            die('doc_screenshots: import failed for %s' % f)

    top, res = app.toptabs, app.restabs
    if prog == 'editor':
        from hardycross.window import graph as GR
        shot('network', top, 'NETWORK', res, 'PIPES')
        shot('outlets', top, 'NETWORK', res, 'OUTLETS')
        shot('validation', top, 'NETWORK', res, 'VALIDATION')
        shot('report', top, 'NETWORK', res, 'REPORT')
        shot('project', top, 'PROJECT')
        if not GR.graph_open(os.path.join(ROOT, 'examples', '10_supply_graph.phg')):
            die('doc_screenshots: the graph did not open')
        shot('graph', top, 'GRAPH')
        shot('quick_tools', top, 'QUICK TOOLS')
        shot('orifice', top, 'ORIFICE PLATE')
        shot('database', top, 'DATABASE')
        win.toggle_theme()
        shot('dark', top, 'NETWORK', res, 'PIPES')
    elif prog == 'sheet':
        shot('system', top, 'SYSTEM', res, 'PIPES')
        shot('nodes', top, 'NODES', res, 'NODES')
        shot('supplies', top, 'SUPPLIES', res, 'OUTLETS')
        shot('devices', top, 'PRESSURE DEVICES', res, 'VALIDATION')
    else:
        win.select_tab(top, 'ISOMETRIC')
        ISO.iso_fit(1)          # the FIT button: the whole network in the canvas
        # FIT places the network 60 pixels into the canvas, but the canvas can
        # be left scrolled past that, cutting off the top of the drawing; show
        # it from the top of its scroll region (the whole drawing and its
        # margin).
        ISO.iso_cv.yview_moveto(0)
        ISO.iso_cv.xview_moveto(0)
        shot('drawing', top, 'ISOMETRIC')
    mw.destroy()
    sys.exit(0)


if __name__ == '__main__':
    main()
