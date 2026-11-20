#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_isometric_window.py -- the isometric window, driven under a
# display: a port of tools/test_isometric_window.pl.
#
#   python3 tools/test_isometric_window.py
#
# The text editor is a different program.  This checks that the editor
# was not given an isometric tab, and that the isometric window draws
# a network, keeps a pipe's properties on the right, locks the axes,
# chooses labels and can go dark.  A pipe is two clicks, or a length,
# size, fittings and C typed first so the click only chooses the
# direction.
#==============================================================================
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)


def main():
    #--------------------------------------------------------- a display
    if not os.environ.get('DISPLAY'):
        if (not os.environ.get('PHCP_UNDER_XVFB')
                and shutil.which('xvfb-run')):
            os.environ['PHCP_UNDER_XVFB'] = '1'
            os.execvp('xvfb-run',
                      ['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
                       sys.executable, os.path.abspath(__file__)])
        print('SKIPPED: no X display and no xvfb-run - the isometric '
              'window was not run')
        return 0
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print('SKIPPED: tkinter is not installed - the isometric '
              'window was not run')
        return 0

    os.chdir(REPO)
    settings_dir = tempfile.mkdtemp()
    os.environ['PHCP_SETTINGS'] = os.path.join(settings_dir,
                                              'settings.ini')
    os.environ.pop('PHCP_DATABASE_DIR', None)

    import tkinter as tk
    import tkinter.font as tkfont

    from hardycross import settings as SET
    from hardycross import win
    from hardycross.window import isometric as ISO

    passed = [0]
    failed = [0]

    def is_(name, ok, why=None):
        print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
        if not ok and why is not None:
            print('      %s' % (why,))
        (passed if ok else failed)[0] += 1

    def slurp(p):
        with open(p, 'r', errors='replace') as f:
            return f.read()

    def lc(v):
        return str(v).lower()

    def focus_widget():
        try:
            return win.mw.focus_get()
        except tk.TclError:
            return None

    #======================================================================
    print('1. A FORK, NOT A CHANGE TO THE TEXT EDITOR')
    #======================================================================
    for src in ('phcp_editor.py', os.path.join('hardycross', 'win.py')):
        s = slurp(src)
        is_('%s has no isometric tab' % src,
            not re.search(r'ISOMETRIC', s) and
            not re.search(r'iso_show', s) and
            not re.search(r'build_isometric', s))

    #======================================================================
    print('2. THE DRAWING WINDOW')
    #======================================================================
    win.build_window()
    win.mw.update()
    is_('the window is the isometric program',
        win.mw.title() == 'PHCP ISOMETRIC - UNTITLED.PHC',
        win.mw.title())
    is_('DARK MODE sits left of the status, the same place as the '
        'other windows',
        win.btn.get('THEME') and win.pill and win.btn.get('VALIDATE')
        and win.btn['THEME'].cget('text') == 'DARK MODE'
        and win.btn['THEME'].winfo_rootx() +
        win.btn['THEME'].winfo_width() <=
        win.pill.winfo_rootx() + 8
        and abs(win.btn['THEME'].winfo_rooty() -
                win.btn['VALIDATE'].winfo_rooty()) < 8
        and not ISO.iso['btn'].get('DARK'),
        '%s %s,%s %s,%s' % (
            win.btn['THEME'].cget('text'),
            win.btn['VALIDATE'].winfo_rootx(),
            win.btn['VALIDATE'].winfo_rooty(),
            win.btn['THEME'].winfo_rootx(),
            win.btn['THEME'].winfo_rooty()))
    face = str(tkfont.Font(win.mw, font=win.btn['NEW'].cget('font'))
               .actual('family')).lower()
    weight = str(tkfont.Font(win.mw, font=win.btn['NEW'].cget('font'))
                 .actual('weight'))
    spec_face = str(tkfont.Font(win.mw, font=win.UI_B)
                   .actual('family')).lower()
    is_('buttons are the editor chrome face, 10 point bold',
        win.UI_B and win.UI_B[1] == 10 and win.UI_B[2] == 'bold'
        and weight == 'bold' and face == spec_face,
        '%s %s spec %s -> %s' % (face, weight, win.UI_B, spec_face))
    is_('the toolbar is the shared grey, and the ink is the shared ink',
        lc(win.btn['NEW'].master.cget('background')) == '#f4f6f9'
        and lc(win.btn['NEW'].cget('foreground')) == '#1c1f24',
        '%s %s' % (win.btn['NEW'].master.cget('background'),
                   win.btn['NEW'].cget('foreground')))
    is_('there is no NETWORK tab',
        ' '.join(win.toptabs['names']) ==
        'ISOMETRIC PROJECT GRAPH QUICK TOOLS DATABASE'
        and win.toptabs['current'] == 'ISOMETRIC',
        ' '.join(win.toptabs['names']))
    is_('the grid is drawn, and the view starts locked',
        len(ISO.iso_cv.find_withtag('grid')) > 0 and ISO.iso['lock']
        and ISO.iso['view']['lock'])

    ISO.iso_set_tool('WATER')
    ISO.iso_click_cell(0, 0)
    ISO.iso_set_tool('SPRINKLER')
    ISO.iso_click_cell(4, 0)
    ISO.iso_set_tool('PIPE')
    ISO.iso_click_cell(0, 0)
    ISO.iso_click_cell(4, 0)
    b = win.buffer()
    is_('a supply, a sprinkler and a pipe are written as commands',
        re.search(r'^WATER\s+W1\b', b, re.M) and
        re.search(r'^SPRINKLER\s+S1\b', b, re.M) and
        re.search(r'^PIPE\s+P1\s+W1\s+S1\s', b, re.M), b)

    ISO.iso_set_tool('SELECT')
    ISO.iso['sel'] = {'kind': 'pipe', 'name': 'P1'}
    ISO.iso_props()
    win.mw.update()
    is_('the properties pane sits to the right of the drawing',
        ISO.iso['props'].winfo_rootx() >
        ISO.iso_cv.winfo_rootx() + 40,
        '%s vs %s' % (ISO.iso['props'].winfo_rootx(),
                      ISO.iso_cv.winfo_rootx()))
    is_('a selected pipe offers length, fittings and C',
        'LENGTH' in ISO.iso['field'] and
        'FITTINGS' in ISO.iso['field'] and
        'C' in ISO.iso['field'],
        ' '.join(sorted(ISO.iso['field'])))
    ISO.iso_set_field('FITTINGS', '2E 1T')
    ISO.iso_set_field('C', '110')
    b = win.buffer()
    is_('fittings and C are written back',
        re.search(r'^PIPE\s+P1\s+W1\s+S1\s+\S+\s+\S+\s+2E\s+1T', b,
                  re.M) and
        re.search(r'^USE\s+BORE\s+110', b, re.M), b)

    ISO.iso_set_label('LENGTH', 1)
    captions = [ISO.iso_cv.itemcget(i, 'text')
                for i in ISO.iso_cv.find_withtag('label')]
    is_('a label can be switched on: the length is drawn',
        any(re.search(r'\d', c) for c in captions), ' '.join(captions))
    ISO.iso_set_label('POINTS', 0)
    ISO.iso_set_label('PIPES', 0)
    ISO.iso_set_label('LENGTH', 0)
    ISO.iso_set_label('DEVICES', 0)
    captions = [ISO.iso_cv.itemcget(i, 'text')
                for i in ISO.iso_cv.find_withtag('label')]
    is_('labels can be switched off',
        not any(re.search(r'\S', c) for c in captions),
        ' '.join(captions))

    paper = lc(ISO.iso_cv.cget('background'))
    ISO.iso_apply_theme('DARK')
    win.mw.update()
    dark = lc(ISO.iso_cv.cget('background'))
    from hardycross.window import results as R
    cell = lc(R.vtable['labels'][0].cget('background'))
    head = lc(R.vtable['inner'].grid_slaves(row=0, column=0)[0]
              .cget('background'))
    is_('dark mode repaints the drawing in the shared palette',
        dark != paper and dark == '#1f232b', '%s -> %s' % (paper, dark))
    is_('dark mode repaints the results table in the shared palette',
        cell == '#1f232b' and head == '#282d37', '%s %s' % (cell, head))
    is_('DARK MODE is labelled the same as the other windows, and the '
        'choice is ISO_THEME',
        win.btn['THEME'].cget('text') == 'LIGHT MODE'
        and (SET.get('ISO_THEME') or '') == 'DARK'
        and SET.get('EDITOR_THEME') is None
        and SET.get('SHEET_THEME') is None,
        '%s ISO=%s' % (win.btn['THEME'].cget('text'),
                       SET.get('ISO_THEME') or ''))
    ISO.iso_apply_theme('LIGHT')
    win.mw.update()
    is_('light mode puts the paper back',
        lc(ISO.iso_cv.cget('background')) == '#ffffff')
    is_('light mode puts the results table back',
        lc(R.vtable['labels'][0].cget('background')) == '#ffffff')

    #======================================================================
    print('3. CLICK AND CLICK, OR THE KNOWN VALUES')
    #======================================================================
    is_('length, size, fittings and C can be typed before the click',
        'LENGTH' in ISO.iso['known'] and 'SIZE' in ISO.iso['known']
        and 'FITTINGS' in ISO.iso['known'] and 'C' in ISO.iso['known'])
    is_('the known length is labelled with its unit',
        re.search(r'LENGTH MM',
                  ISO.iso['known_label']['LENGTH'].cget('text')))
    ISO.iso['known']['LENGTH'] = '4000'
    ISO.iso['known']['SIZE'] = '32'
    ISO.iso['known']['FITTINGS'] = '1E'
    ISO.iso['known']['C'] = '100'
    ISO.iso_set_tool('PIPE')
    ISO.iso_click_cell(4, 0)
    ISO.iso_click_cell(20, 0)
    b = win.buffer()
    is_('a known length places the end, and the typed values are the '
        'pipe',
        re.search(r'^//ISO \S+ 8 0 0$', b, re.M) and
        re.search(r'^PIPE\s+\S+\s+S1\s+\S+\s+4000\s+32\s+1E', b,
                  re.M) and
        re.search(r'^USE\s+BORE\s+100', b, re.M), b)
    win.mw.update()
    focus = focus_widget()
    is_('drawing a pipe leaves the drawing focused',
        focus is not None and focus is ISO.iso_cv,
        focus._name if focus is not None else 'none')

    ISO.iso_set_tool('SELECT')
    ISO.iso_click_cell(6, 0)
    win.mw.update()
    focus = focus_widget()
    is_('selecting a pipe focuses its length',
        focus is not None and ISO.iso['entry'].get('LENGTH') and
        focus is ISO.iso['entry']['LENGTH'],
        focus._name if focus is not None else 'none')
    ISO.iso_set_field('LENGTH', '2000')
    b = win.buffer()
    is_('typing the length moves the end and keeps the typed length',
        re.search(r'^//ISO \S+ 6 0 0$', b, re.M) and
        re.search(r'^PIPE\s+\S+\s+S1\s+\S+\s+2000\s+32\s+1E', b, re.M),
        b)
    win.mw.update()
    focus = focus_widget()
    is_('return in the length moves on to the size',
        focus is not None and ISO.iso['entry'].get('SIZE') and
        focus is ISO.iso['entry']['SIZE'],
        focus._name if focus is not None else 'none')

    ISO.iso['known']['LENGTH'] = ''
    ISO.iso['known']['SIZE'] = ''
    ISO.iso['known']['FITTINGS'] = ''
    ISO.iso['known']['C'] = ''
    ISO.iso_set_tool('PIPE')
    ISO.iso_click_cell(6, 0)
    ISO.iso_click_cell(6, 3)
    b = win.buffer()
    is_('a blank length follows the click',
        re.search(r'^PIPE\s+\S+\s+\S+\s+\S+\s+3000\s+25(?:\s|$)', b,
                  re.M), b)

    ISO.iso['known']['LENGTH'] = '9000'
    # The chain from the last pipe is still open, so these clicks land
    # on the second-click path: Perl refuses them the same way (the
    # pipe would run along two axes).  The Perl suite's own check
    # never saw this -- its failed regex dropped the $why argument and
    # the buffer text stood in as the result.  What is checked here is
    # the behaviour both windows share.
    ISO.iso_click_cell(0, 0)
    ISO.iso_click_cell(4, 0)
    b = win.buffer()
    is_('a run in progress refuses a click that is not along one axis',
        ISO.iso['from'] == 'N2' and
        re.search(r'^PIPE\s+\S+\s+W1\s+S1\s+9000\b', b, re.M) is None
        and ISO.iso_status_text() == 'A PIPE RUNS ALONG ONE GRID AXIS',
        '%s | %s' % (ISO.iso_status_text(), b))
    # With the chain closed, the same two clicks join the existing
    # points and do not move them: the intended check.
    ISO.iso_set_tool('SELECT')          # closes the run
    ISO.iso_set_tool('PIPE')
    ISO.iso_click_cell(0, 0)
    ISO.iso_click_cell(4, 0)
    b = win.buffer()
    is_('a click on an existing point joins it and does not move it',
        re.search(r'^//ISO S1 4 0 0$', b, re.M) and
        re.search(r'^PIPE\s+\S+\s+W1\s+S1\s+9000\b', b, re.M), b)

    opened = os.path.join(settings_dir, 'opened.phc')
    with open(opened, 'w') as out:
        out.write('NODE A 0\nNODE B 0\nPIPE P9 A B 4 25\n')
    win.open_path(opened)
    win.mw.update()
    is_('opening a file stays on the drawing',
        (win.toptabs.get('current') or '') == 'ISOMETRIC',
        win.toptabs.get('current'))
    is_('the opened network is drawn',
        re.search(r'^PIPE\s+P9\s+A\s+B\s', win.buffer(), re.M) and
        'A' in ISO.iso['draw']['nodes'])

    #======================================================================
    print('4. AS THE PERL WINDOW DOES IT (the line-by-line audit)')
    #======================================================================
    errors = []
    win.mw.report_callback_exception = lambda *a: errors.append(repr(a[1]))

    def entries(w, out):
        for c in w.winfo_children():
            if isinstance(c, tk.Entry):
                out.append(c)
            entries(c, out)
        return out

    ents = entries(win.toptabs['page']['ISOMETRIC'], [])
    (known_len, grid_e) = (ents[0], ents[5])
    for k in ISO.iso['known']:           # no KNOWN figures: click and click
        ISO.iso['known'][k] = ''
    ISO.iso_set_tool('SELECT')
    win.set_buffer('')
    win.mw.update()
    ISO.iso_set_tool('WATER')
    ISO.iso_click_cell(0, 0)
    ISO.iso_set_tool('PIPE')
    ISO.iso_click_cell(0, 0)
    ISO.iso_click_cell(3, 0)
    ISO.iso_click_cell(3, 2)
    ISO.iso_set_tool('SELECT')
    cv = ISO.iso_cv
    (x0, y0) = [int(v) for v in ISO.iso_widget_at(3, 2)]
    (x1, y1) = [int(v) for v in ISO.iso_widget_at(3, 4)]
    cv.event_generate('<ButtonPress-1>', x=x0, y=y0, when='now')
    cv.event_generate('<B1-Motion>', x=x1, y=y1, when='now')
    ghost = ISO.iso.get('ghost')
    cv.event_generate('<ButtonRelease-1>', x=x1, y=y1, when='now')
    win.mw.update()
    b = win.buffer()
    is_('a point dragged with the mouse moves, and its pipe takes the '
        'new length',
        not errors and ghost is not None and list(ghost)[:2] == [3, 4]
        and re.search(r'^//ISO N2 3 4 0$', b, re.M)
        and re.search(r'^PIPE\s+P2\s+N1\s+N2\s+4000\b', b, re.M)
        and ISO.iso_status_text().startswith('N2 MOVED'),
        '%s | %s | %s' % (errors, ISO.iso_status_text(), b))

    grid_e.delete(0, 'end')
    grid_e.insert(0, '0.5')
    ISO.iso_grid_apply()
    half = win.buffer()
    win.set_buffer('')
    grid_e.delete(0, 'end')
    grid_e.insert(0, '7')
    win.set_buffer(half)
    win.mw.update()
    is_('the GRID field shows the grid of the network that was read',
        grid_e.get() == '0.5' and ISO.iso['gridvar'] == '0.5'
        and '//ISO GRID 0.5' in half, grid_e.get())
    known_len.delete(0, 'end')
    known_len.insert(0, '  2500  ')
    ISO.iso_known_apply('LENGTH')
    is_('a KNOWN figure is shown without the spaces round it',
        known_len.get() == '2500' and ISO.iso['known']['LENGTH'] == '2500',
        repr(known_len.get()))
    known_len.delete(0, 'end')
    ISO.iso_known_apply('LENGTH')

    win.mw.destroy()
    print('\n%d passed, %d failed' % (passed[0], failed[0]))
    return 1 if failed[0] else 0


if __name__ == '__main__':
    sys.exit(main())
