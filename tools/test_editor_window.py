#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_editor_window.py -- the editor WINDOW, driven under a display: a
# port of tools/test_editor_window.pl.
#
#   python3 tools/test_editor_window.py [--shot file.png]
#
# Needs tkinter and an X display.  With no display it re-runs itself under
# xvfb-run, a virtual display, if that is installed; with neither it says
# SKIPPED and exits 0, so the suite can run on a machine without either --
# the README says plainly whether the window has been run.
#
# tools/test_editor.py checks every decision the editor makes.  This checks
# that the window carries them out: the layout (toolbar, NETWORK and PROJECT
# tabs, the editor with its line numbers, the three lists, the results tabs
# below), the white, flat look, the syntax colours, the command strip,
# proposals and undo, the pick list, VALIDATE before CALCULATE and the
# VALIDATION tab, the tables with sorting, the column chooser and the HIDE
# boxes, the PROJECT tab, and the files.  Keys are sent as real X key events
# where tkinter delivers them reliably under a virtual display (Return, Tab,
# letters); the file dialogs are bypassed by passing the file name, as a
# user's choice would.
#
# --shot file.png saves a screenshot of the window after the calculation.
#==============================================================================
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)


def main():
    argv = sys.argv[1:]
    shot = None
    if '--shot' in argv:
        i = argv.index('--shot')
        shot = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]

    #--------------------------------------------------------- a display
    if not os.environ.get('DISPLAY'):
        if (not os.environ.get('PHCP_UNDER_XVFB')
                and shutil.which('xvfb-run')):
            os.environ['PHCP_UNDER_XVFB'] = '1'
            os.execvp('xvfb-run',
                      ['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
                       sys.executable, os.path.abspath(__file__)] + argv)
        print('SKIPPED: no X display and no xvfb-run - the editor window '
              'was not run')
        return 0
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print('SKIPPED: tkinter is not installed - the editor window was '
              'not run')
        return 0

    # Load the editor without starting its event loop: importing the
    # module builds nothing until build_window() is called.
    os.chdir(REPO)
    # Settings of our own, so the tests never read or write a user's
    # real ones; and no database folder from the environment.
    settings_dir = tempfile.mkdtemp()
    os.environ['PHCP_SETTINGS'] = os.path.join(settings_dir,
                                              'settings.ini')
    os.environ.pop('PHCP_DATABASE_DIR', None)

    import tkinter as tk

    from hardycross import editor
    from hardycross import settings as SET
    from hardycross import tools as tools_mod
    from hardycross import win
    from hardycross.window import database as DB
    from hardycross.window import graph as GR
    from hardycross.window import orifice as OR
    from hardycross.window import project as PJ
    from hardycross.window import results as R
    from hardycross.window import tools as TO

    passed = [0]
    failed = [0]

    def is_(name, ok, why=None):
        print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
        if not ok and why is not None:
            print('      %s' % why)
        (passed if ok else failed)[0] += 1

    def slurp(p):
        with open(p, 'r', errors='replace') as f:
            return f.read()

    TMP = tempfile.mkdtemp()

    # key -- send one real key press and release to the editor, then let
    # tkinter run.
    def key(sym):
        t = win.text_widget()
        t.focus_force()
        win.mw.update()
        t.event_generate('<KeyPress>', keysym=sym, when='now')
        t.event_generate('<KeyRelease>', keysym=sym, when='now')
        win.mw.update()

    def type_(s):
        m = {' ': 'space', '=': 'equal', '.': 'period', '/': 'slash'}
        for ch in s:
            key(m.get(ch, ch))

    def tags_on(i):
        return tuple(win.ed.tag_names(i))

    def flush():
        win.mw.update()
        if win.recolour_job:
            win.recolour_job.cancel()
        win.recolour()
        win.mw.update()

    def net_lines():
        l = win.buffer().split('\n')
        if l and l[-1] == '':
            l.pop()
        return l

    def lc(s):  # a colour, lowercased for comparing
        return str(s).lower()

    def descendants(w):
        for c in w.winfo_children():
            yield c
            yield from descendants(c)

    def widget_of(name):
        return win.mw.nametowidget(name) if isinstance(name, str) else name

    #==========================================================================
    print('1. THE WINDOW')
    #==========================================================================
    win.build_window()
    win.mw.update()
    is_('the window opens, titled in capitals',
        win.mw.title() == 'PHCP EDITOR - UNTITLED.PHC', win.mw.title())
    menubar = widget_of(win.mw.cget('menu'))
    end = menubar.index('end')
    casc = [i for i in range(end + 1)
            if menubar.type(i) == 'cascade']
    menus = [menubar.entrycget(i, 'label') for i in casc]
    is_('menus in capitals: FILE EDIT VIEW MODEL',
        menus == ['FILE', 'EDIT', 'VIEW', 'MODEL'], ' '.join(menus))
    view_i = [i for i in casc
              if menubar.entrycget(i, 'label') == 'VIEW'][0]
    vm = widget_of(menubar.entrycget(view_i, 'menu'))
    is_('VIEW: DARK MODE', vm.entrycget(0, 'label') == 'DARK MODE',
        vm.entrycget(0, 'label'))
    model_i = [i for i in casc
               if menubar.entrycget(i, 'label') == 'MODEL'][0]
    mm = widget_of(menubar.entrycget(model_i, 'menu'))
    mi = [mm.entrycget(i, 'label')
          for i in range(mm.index('end') + 1)
          if mm.type(i) == 'command']
    is_('MODEL: VALIDATE, then CALCULATE',
        mi == ['VALIDATE', 'CALCULATE'], ' '.join(mi))
    is_('white paper and the spreadsheet ink in the editor',
        lc(win.ed.cget('background')) == '#ffffff'
        and lc(win.ed.cget('foreground')) == '#1c1f24')
    is_('the window itself is white, not blue',
        lc(win.mw.cget('background')) == '#ffffff')
    try:
        import tkinter.font as tkfont
        have = {str(f).lower()
                for f in win.mw.tk.call('font', 'families')}

        def family_of(font_desc):
            return str(tkfont.Font(win.mw, font=font_desc)
                       .actual('family')).lower()

        mono = family_of(win.ed.cget('font'))
        ui = family_of(win.btn['NEW'].cget('font'))
        bar = win.btn['NEW'].master.master
        edge = [w for w in win.mw.winfo_children()
                if isinstance(w, tk.Frame) and int(w.cget('height')) == 1
                and lc(w.cget('background')) == '#d5dbe3']
        is_('the editor wears the spreadsheet look: grey bar, soft edge, '
            'Inter and JetBrains Mono',
            lc(bar.cget('background')) == '#f4f6f9'
            and edge
            and lc(win.list_head['ERRORS'].cget('background')) == '#f4f6f9'
            and lc(win.strip.cget('background')) == '#f4f6f9'
            and ('jetbrains mono' not in have
                 or 'jetbrains mono' in mono)
            and ('inter' not in have or 'inter' in ui),
            'bar %s edges %s mono %s ui %s'
            % (bar.cget('background'), edge, mono, ui))
    except Exception as e:  # pragma: no cover -- a font query failed
        is_('the editor wears the spreadsheet look: grey bar, soft edge, '
            'Inter and JetBrains Mono', False, repr(e))
    sizes = sorted(str(p.width()) for p in win._icon_photos)
    is_('the PHCP icon is set, at 16, 32 and 48 pixels',
        ' '.join(sizes).split() == ['16', '32', '48'] or
        re.search(r'\b16 32 48\b', ' '.join(sizes)), 'photos: %s' % sizes)
    is_('flat: no bevel on the buttons or the editor',
        all(win.btn[b].cget('relief') == 'flat'
            and int(win.btn[b].cget('borderwidth')) == 0
            for b in win.btn)
        and int(win.ed.cget('borderwidth')) == 0)
    strip = win.strip_commands()
    is_('the command strip lists the 30 network commands (PUMPDUTY, DPV, '
        'NRV, NRVMODEL, NRVLOSS, AREA, SCENARIO among them), no settings',
        len(strip) == 30
        and len([c for c in strip if c in ('PUMPDUTY', 'AREA', 'DPV',
                                           'NRV', 'NRVMODEL', 'NRVLOSS')]) == 6
        and strip[0] == 'USE' and strip[-1] == 'SCENARIO'
        and not [c for c in strip
                 if c in ('TITLE', 'PROJECT', 'UNITS', 'METHOD',
                          'OPTION')],
        ' '.join(strip))
    is_('NETWORK, PROJECT, GRAPH, QUICK TOOLS, ORIFICE PLATE and DATABASE '
        'tabs above; VALIDATION, PIPES, NODES, OUTLETS, REPORT below',
        win.toptabs['names'] == ['NETWORK', 'PROJECT', 'GRAPH',
                                 'QUICK TOOLS', 'ORIFICE PLATE',
                                 'DATABASE']
        and win.restabs['names'] == ['VALIDATION', 'PIPES', 'NODES',
                                     'OUTLETS', 'REPORT'])
    is_('the ERRORS, WARNINGS and NODES lists sit to the right of the editor',
        win.LIST['ERRORS'].winfo_rootx()
        > win.ed.winfo_rootx() + win.ed.winfo_width() - 5
        and win.LIST['NODES'].winfo_rooty()
        > win.LIST['ERRORS'].winfo_rooty())
    is_('the results sit below the editor',
        win.TABLE['PIPES']['page'].winfo_rooty()
        > win.ed.winfo_rooty() + win.ed.winfo_height())
    is_('a line-number gutter left of the editor',
        win.gutter.winfo_rootx() < win.ed.winfo_rootx()
        and win.gutter_numbers()[0] == '1')
    pw = [w for w in descendants(win.mw)
          if isinstance(w, tk.PanedWindow)]
    is_('three dividers (results, side lists, graph), each wide enough to '
        'grab (6 px), with the resize pointer',
        len(pw) == 3
        and not [w for w in pw if int(w.cget('sashwidth')) < 6]
        and len([w for w in pw
                 if str(w.cget('sashcursor')) == 'sb_v_double_arrow']) == 1)
    is_('sizes scale with the screen: px() multiplies by the scale, at '
        'least 1',
        win.SCALE >= 1 and win.px(10) == int(10 * win.SCALE + 0.5)
        and isinstance(win.px([2, 4]), list))
    is_('FITTING_BASIS is a drop-down that shows DEFAULT when blank',
        isinstance(win.form['FITTING_BASIS'], tk.Menubutton)
        and re.match(r'^DEFAULT', win.form['FITTING_BASIS'].cget('text')))
    is_('CALCULATE is off and the model NOT VALIDATED',
        not win.calculate_enabled()
        and win.state_text() == 'NOT VALIDATED')

    #==========================================================================
    print('2. OPEN: the network in the editor, the rest in the PROJECT tab')
    #==========================================================================
    EX7 = 'examples/07_pipe_database_demo.phc'
    win.open_path(EX7)
    flush()
    doc = editor.split_file(slurp(EX7))
    is_('the editor holds the network only',
        win.buffer() == doc['network']
        and not re.search(r'^(TITLE|PROJECT|UNITS)', win.buffer(), re.M))
    is_('the PROJECT tab holds the title, details and units',
        win.settings['title'] == 'LEVEL 2 SPRINKLER RANGE - DEMONSTRATION'
        and win.form['JOB'].get() == 'HYC-DEMO-017'
        and win.settings['units']['LENGTH'] == 'M'
        and re.match(r'^M\s', win.form['LENGTH'].cget('text')))
    is_('opening is not a change: no *',
        win.mw.title() == 'PHCP EDITOR - 07_PIPE_DATABASE_DEMO.PHC',
        win.mw.title())
    is_("the status bar shows the first line's template",
        re.match(r'^WATER NAME ELEVATION STATIC', win.status_text()),
        win.status_text())
    lines = net_lines()
    is_('a number for every line',
        int(win.gutter_numbers()[-1]) == len(lines) + 1)
    pl = [i for i in range(1, len(lines) + 1)
          if re.match(r'^PIPE\s+M1', lines[i - 1])][0]
    ul = [i for i in range(1, len(lines) + 1)
          if re.match(r'^USE\s+ASAM', lines[i - 1])][0]
    is_('syntax: the command word',
        'command' in tags_on('%d.1' % pl))
    is_("syntax: the pipe's name, its nodes, its length, its fittings",
        'name' in tags_on('%d.10' % pl)
        and 'ref' in tags_on('%d.13' % pl)
        and 'number' in tags_on('%d.21' % pl)
        and 'keyword' in tags_on('%d.30' % pl))
    is_('syntax: a pipe type', 'keyword' in tags_on('%d.11' % ul))
    win.ed.insert('1.0', '// A NOTE\n')
    flush()
    is_('syntax: a comment', 'comment' in tags_on('1.3'))
    win.set_buffer(doc['network'])
    is_('nothing is marked in a good model',
        not win.ed.tag_ranges('error')
        and not [n for n in ('ERRORS', 'WARNINGS', 'NODES')
                 if win.LIST[n].size()])
    is_('before a calculation the tables say how to get results',
        re.search(r'VALIDATE \(F4\), THEN CALCULATE \(F5\)',
                  R.header_text('PIPES', 0)))

    #==========================================================================
    print('3. LIVE CHECKS - the lists and the marks as you type')
    #==========================================================================
    n = len(lines) + 1
    win.ed.insert('end', 'PIPE Z1 H3 ZZ 3 32\nSPRINKLER S9 0\nPIPX\n'
                  'NODE LONE 0\n')
    win.ed.mark_set('insert', '1.0')
    flush()
    is_('a line in error has a pale red band',
        'error' in tags_on('%d.1' % (n + 2)))
    is_('   and its number is red',
        any(re.match(r'^\d+\.\d+$', str(r))
            and int(str(r).split('.')[0]) == n + 2
            for r in win.gutter.tag_ranges('bad')))
    er = list(win.LIST['ERRORS'].get(0, 'end'))
    is_('ERRORS names both lines, by editor line',
        any(re.match(r'^\s*%d\s+SPRINKLER NEEDS MINFLOW$' % (n + 1), x)
            for x in er)
        and any(re.match(r'^\s*%d\s+UNKNOWN COMMAND PIPX$' % (n + 2), x)
                for x in er),
        ' '.join(er))
    is_('   with a count in its heading',
        win.list_head['ERRORS'].cget('text') == 'ERRORS  2')
    no = list(win.LIST['NODES'].get(0, 'end'))
    is_('NODES lists ZZ and LONE',
        any(re.match(r'^\s*%d\s+ZZ - USED, BUT NOT DEFINED$' % n, x)
            for x in no)
        and any(x.endswith('LONE - DEFINED, BUT NOTHING CONNECTS TO IT')
                for x in no),
        ' '.join(no))
    win.LIST['ERRORS'].selection_clear(0, 'end')
    win.LIST['ERRORS'].selection_set(len(er) - 1)
    win.go_to_list('ERRORS')
    is_('clicking an error moves the cursor to its line',
        win.cursor()[0] == n + 2)
    win.ed.delete('%d.0' % n, 'end')
    flush()
    is_('removing the bad lines clears the lists and the marks',
        not win.LIST['ERRORS'].size()
        and not win.LIST['NODES'].size()
        and not win.ed.tag_ranges('error'))

    #==========================================================================
    print('4. THE COMMAND STRIP')
    #==========================================================================
    win.ed.mark_set('insert', 'end - 1 chars')
    win.start_command('SPRINKLER')
    cl = win.cursor()[0]
    is_('a click on SPRINKLER starts a SPRINKLER line',
        win.ed.get('%d.0' % cl, '%d.0 lineend' % cl) == 'SPRINKLER ',
        win.ed.get('%d.0' % cl, '%d.0 lineend' % cl))
    win.update_status()
    is_('   and the status bar shows its fields',
        re.match(r'^SPRINKLER NAME ELEVATION MINFLOW K',
                 win.status_text()), win.status_text())
    win.ed.mark_set('insert', '%d.4' % pl)
    win.start_command('NODE')
    cl = win.cursor()[0]
    is_('on a line in use, the command goes on a new line below it',
        cl == pl + 1
        and win.ed.get('%d.0' % cl, '%d.0 lineend' % cl) == 'NODE      ')
    win.set_buffer(doc['network'])

    #==========================================================================
    print('5. PROPOSALS - Enter offers, Tab and Enter accept, typing discards')
    #==========================================================================
    b3 = [i for i in range(1, len(lines) + 1)
          if re.match(r'^PIPE\s+B3', lines[i - 1])][0]
    win.ed.mark_set('insert', '%d.0 lineend' % b3)
    key('Return')
    is_('Enter after a pipe offers the next one, greyed',
        win.prop['active']
        and win.ed.get('pstart', 'pend') == 'PIPE B4 H3 H4 3.2 32'
        and 'proposal' in tags_on('pstart'))
    is_('   an offered line is not part of the model yet',
        'B4' not in win.buffer())
    key('Tab')
    is_('Tab accepts it as typed text',
        not win.prop['active']
        and re.search(r'^PIPE B4 H3 H4 3\.2 32$', win.buffer(), re.M))
    key('Return')
    key('Return')
    is_('Enter accepts and offers the one after',
        re.search(r'^PIPE B5 H4 H5 3\.2 32$', win.buffer(), re.M)
        and win.prop['active'])
    key('x')
    is_('typing anything else discards it and types the key',
        not win.prop['active']
        and 'B6' not in win.buffer()
        and win.ed.get('insert linestart', 'insert lineend') == 'x')
    win.undo()
    is_('undo: the discarded proposal does not come back',
        not re.search(r'x$', win.buffer(), re.M)
        and 'B6' not in win.buffer())
    for _ in range(3):
        if not re.search(r'^PIPE B5', win.buffer(), re.M):
            break
        win.undo()
    is_('further undo removes the accepted line',
        not re.search(r'^PIPE B5', win.buffer(), re.M))
    win.redo()
    is_('redo puts it back', re.search(r'^PIPE B5', win.buffer(), re.M))
    win.set_buffer(doc['network'])

    #==========================================================================
    print('6. PICK LIST, Ctrl+Space')
    #==========================================================================
    win.ed.insert('end', 'USE ')
    win.ed.mark_set('insert', 'end - 1 chars')
    top = win.pick_list()
    win.mw.update()
    items = list(top.winfo_children()[0].get(0, 'end')) if top else []
    is_('in a USE line: the pipe types with descriptions',
        any(re.match(r'^ASAM\s+\S', x) for x in items)
        and any(re.match(r'^BORE ', x) for x in items))
    if top and top.winfo_exists():
        top.destroy()
    win.insert_choice('S40')
    is_('picking inserts the code',
        re.search(r'^USE S40$', win.buffer(), re.M))
    win.ed.insert('end', '\nPIPE Q1 R1 R2 3 50 G')
    win.ed.mark_set('insert', 'end - 1 chars')
    top = win.pick_list()
    win.mw.update()
    items = list(top.winfo_children()[0].get(0, 'end')) if top else []
    is_('in a fitting field: the fitting codes for that pipe and size',
        any(re.match(r'^GV\s', x) for x in items)
        and any(re.match(r'^E\s', x) for x in items))
    if top and top.winfo_exists():
        top.destroy()
    win.insert_choice('GV')
    is_('a partly typed code is completed, not doubled',
        re.search(r'^PIPE Q1 R1 R2 3 50 GV$', win.buffer(), re.M))
    win.set_buffer(doc['network'])

    #==========================================================================
    print('7. VALIDATE BEFORE CALCULATE')
    #==========================================================================
    key('F5')
    is_('F5 before VALIDATE is refused, and says why',
        not win.solved
        and re.search(r'VALIDATE THE INPUTS FIRST', win.status_text()),
        win.status_text())
    win.ed.insert('end', 'PIPE Z1 H3 ZZ 3 32\nSPRINKLER S9 0\n'
                  'PIPE Q1 R1 R2 3 47\n')
    win.after_change()
    key('F4')
    vr = R.validation_rows()
    is_('F4 lists the problems in the VALIDATION tab: where, field, what, '
        'why',
        len(vr) == 3 and vr[0][0] == 'LINE %d' % n
        and vr[0][1] == 'NODE'
        and vr[0][2] == 'NODE ZZ IS USED, BUT NOT DEFINED'
        and re.search(r'DEFINED BY NODE', vr[0][3])
        and win.restabs['current'] == 'VALIDATION',
        ' | '.join(vr[0] if vr else []))
    is_('   CALCULATE stays off; the toolbar says 3 PROBLEMS',
        not win.calculate_enabled()
        and win.state_text() == '3 PROBLEMS - SEE VALIDATION',
        win.state_text())
    is_('   each fault is marked on its field in the editor',
        'fault' in tags_on('%d.12' % n)
        and 'fault' not in tags_on('%d.2' % n)
        and 'fault' in tags_on('%d.17' % (n + 2)))
    is_('   a short line has its last word marked',
        'fault' in tags_on('%d.13' % (n + 1)))
    R.go_to_fault(2)
    is_('a click on a problem selects its field in the editor',
        win.ed.get('sel.first', 'sel.last') == '47'
        and win.cursor()[0] == n + 2)
    win.set_buffer(doc['network'])
    is_('a change clears the marks and the verdict',
        not win.ed.tag_ranges('fault')
        and win.state_text() == 'NOT VALIDATED')
    v = win.validate()
    is_('a good model validates; CALCULATE comes on',
        v.get('ok') and win.calculate_enabled()
        and win.state_text() == 'VALID - READY TO CALCULATE'
        and re.search(r'NO PROBLEMS FOUND', R.validation_rows()[0][2]),
        '%s / %s' % ('ok' if v.get('ok') else
                     ' / '.join(i.get('what', '')
                                 for i in v.get('items', [])),
                     win.state_text()))
    win.ed.insert('end', ' ')
    win.after_change()
    is_('any edit turns CALCULATE off again',
        not win.calculate_enabled()
        and win.state_text() == 'NOT VALIDATED')
    win.ed.delete('end - 2 chars', 'end - 1 chars')
    win.after_change()
    win.validate()
    win.settings['options']['VEL_LIMIT'] = '8'
    PJ.settings_changed()
    is_('so does a change in the PROJECT tab',
        not win.calculate_enabled())
    win.settings['options']['VEL_LIMIT'] = ''
    PJ.settings_changed()
    win.validate()
    key('F5')
    is_('validated, F5 calculates: the REPORT and the tables fill',
        re.search(r'PIPE SCHEDULE', win.report_text(), re.I)
        and len(R.table_rows('PIPES')) == 6
        and win.state_text() == 'CALCULATED')
    is_('   the PIPES tab comes forward, the status bar says converged',
        win.restabs['current'] == 'PIPES'
        and re.search(r'CALCULATED - CONVERGED', win.status_text()),
        win.status_text())
    win.go_to_line(pl)
    win.ed.mark_set('insert', '%d.0 lineend' % pl)
    win.update_status()
    is_('on pipe M1 the status bar shows its flow, velocity and pressures',
        re.search(r'M1  Q 3576\.8 L/MIN  V 6\.87 M/S  SUP 650\.0 KPA '
                  r'-> R1 461\.0 KPA', win.status_text()),
        win.status_text())
    is_('   with the PIPE template, the current field highlighted',
        re.match(r'^PIPE NAME START END LENGTH SIZE', win.status_text())
        and win.statusbar.tag_ranges('current'))
    w = list(win.LIST['WARNINGS'].get(0, 'end'))
    is_('WARNINGS lists M1 over the velocity limit, on its line',
        any(re.match(r'^\s*%d\s+M1 - VELOCITY 6\.87 M/S' % pl, x)
            for x in w), ' '.join(w))

    #==========================================================================
    print('8. THE RESULTS TABLES')
    #==========================================================================
    heads = R.table_heads('PIPES')
    is_('PIPES: the default columns',
        heads == ['NAME', 'SNODE', 'ENODE', 'NOM', 'I.D.', 'MAT', 'C',
                  'L', 'F', 'T', 'FIT K', 'Q', 'PF', 'PS', 'VEL'],
        ' '.join(heads))
    rows = R.table_rows('PIPES')
    is_('PIPES: M1 first, as in the file',
        rows[0] == ['M1', 'SUP', 'R1', '100', '105.1', 'ASAM', '120',
                    '12.00', '19.40', '31.40', '0.00', '3576.8',
                    '144.86', '-', '6.87'],
        ' '.join(rows[0]))
    ci = {h: i for i, h in enumerate(heads)}
    vfull = [i for i, c in
             enumerate(win.TABLE['PIPES']['data']['columns'])
             if c['key'] == 'VEL'][0]
    R.sort_table('PIPES', vfull)
    vv = [float(r[ci['VEL']]) for r in R.table_rows('PIPES')]
    is_('a click on VEL sorts ascending',
        not [i for i in range(len(vv) - 1) if vv[i] > vv[i + 1]],
        ' '.join(str(x) for x in vv))
    R.sort_table('PIPES', vfull)
    vv = [float(r[ci['VEL']]) for r in R.table_rows('PIPES')]
    is_('   a second click reverses',
        not [i for i in range(len(vv) - 1) if vv[i] < vv[i + 1]],
        ' '.join(str(x) for x in vv))
    is_('   and its heading shows the direction',
        re.match(r'^\s*VEL \u25BC\n\s*M/S$', R.header_text('PIPES',
                                                            ci['VEL'])))
    # A real click in the heading row, at the middle of the Q column.
    h = win.TABLE['PIPES']['hlist']
    t = win.TABLE['PIPES']
    acc = 0
    for full, c in t['cols']:
        if c['key'] == 'Q':
            break
        acc += t['width'][full] + R.GAP
    acc += t['width'][full] // 2
    win.select_tab(win.restabs, 'PIPES')
    h.focus_force()
    win.mw.update()
    bbox = h.bbox('1.%d' % acc)
    h.event_generate('<ButtonPress-1>', x=bbox[0], y=bbox[1],
                     button=1, when='now')
    h.event_generate('<ButtonRelease-1>', x=bbox[0], y=bbox[1],
                     button=1, when='now')
    win.mw.update()
    q = [float(r[ci['Q']]) for r in R.table_rows('PIPES')]
    is_('a mouse click on the Q heading sorts on Q',
        not [i for i in range(len(q) - 1) if q[i] > q[i + 1]]
        and re.search(r'Q \u25B2', R.header_text('PIPES', ci['Q'])),
        ' '.join(str(x) for x in q))
    is_('the headings are one flat band: text in the header row, not '
        'buttons',
        not [w for w in descendants(h)
             if isinstance(w, (tk.Button, tk.Menubutton))])
    menu = R.column_menu()
    labels = [menu.entrycget(i, 'label')
              for i in range(menu.index('end') + 1)]
    is_('the column chooser lists all 21 columns, NAME fixed',
        len(labels) == 21 and labels[0] == 'PIPE NAME'
        and menu.entrycget(0, 'state') == 'disabled')
    menu.unpost()
    menu.destroy()
    win.pipe_show['RE'] = 1
    win.pipe_show['MAT'] = 0
    R.make_table('PIPES')
    heads = R.table_heads('PIPES')
    is_('turning RE on and MAT off changes the columns',
        'RE' in heads and 'MAT' not in heads)
    win.pipe_show['RE'] = 0
    win.pipe_show['MAT'] = 1
    R.make_table('PIPES')
    sup = [r for r in R.table_rows('NODES') if r[0] == 'SUP']
    is_('NODES: SUP is the WATER supply at 650.0',
        sup and sup[0][1] == 'WATER' and sup[0][3] == '650.0')
    orows = R.table_rows('OUTLETS')
    is_('OUTLETS: the three sprinklers, each PASS or FAIL',
        len(orows) == 3
        and not [r for r in orows
                 if not re.match(r'^(PASS|FAIL)$', r[-1])])

    win.set_buffer(doc['network'] + 'NODE DEAD 4.5\nPIPE D1 R2 DEAD 2 25\n')
    win.validate()
    win.calculate()
    allr = R.table_rows('PIPES')
    win.hide_pipes[0] = 1
    R.fill_table('PIPES')
    shown = [r[0] for r in R.table_rows('PIPES')]
    is_('the HIDE boxes count what they would hide: one pipe, one node',
        R.hide_count_text('pipes') == '(1)'
        and R.hide_count_text('nodes') == '(1)',
        '%s %s' % (R.hide_count_text('pipes'),
                   R.hide_count_text('nodes')))
    is_('HIDE NON-FLOWING PIPES leaves out the dead end',
        len(allr) == 7 and len(shown) == 6
        and 'D1' not in shown)
    win.hide_pipes[0] = 0
    R.fill_table('PIPES')
    alln = len(R.table_rows('NODES'))
    win.hide_nodes[0] = 1
    R.fill_table('NODES')
    sn = [r[0] for r in R.table_rows('NODES')]
    is_('HIDE INACTIVE NODES leaves out the dead node',
        'DEAD' not in sn and len(sn) == alln - 1)
    win.hide_nodes[0] = 0
    R.fill_table('NODES')

    win.set_buffer(doc['network'])
    win.validate()
    win.calculate()
    is_('with everything flowing the boxes say NONE, and are greyed',
        R.hide_count_text('pipes') == '(NONE)'
        and R.hide_count_text('nodes') == '(NONE)'
        and lc(win.checks['pipes']['label'].cget('foreground'))
        == lc(win.C['faint']))
    # The wheel goes to the pane under the pointer, not the one with the
    # focus.
    win.select_tab(win.restabs, 'NODES')
    win.set_buffer('\n'.join(
        ['NODE N%d 0' % i for i in range(1, 61)]
        + ['WATER S 0 500', 'SPRINKLER H 0 0 80']
        + ['PIPE P%d N%d N%d 1 50' % (i, i, i + 1)
           for i in range(1, 60)]
        + ['PIPE PS S N1 1 100', 'PIPE PH N60 H 1 50', '']))
    win.validate()
    win.calculate()
    win.select_tab(win.restabs, 'NODES')
    win.mw.update()
    h = win.TABLE['NODES']['hlist']
    ey0 = win.ed.yview()[0]
    hy0 = h.yview()[0]
    win.ed.focus_force()
    win.mw.update()
    win.ed.event_generate('<MouseWheel>', delta=-120, when='now',
                          x=h.winfo_rootx() + 40 - win.ed.winfo_rootx(),
                          y=h.winfo_rooty() + 60 - win.ed.winfo_rooty(),
                          rootx=h.winfo_rootx() + 40,
                          rooty=h.winfo_rooty() + 60)
    win.mw.update()
    ey1 = win.ed.yview()[0]
    hy1 = h.yview()[0]
    is_('the wheel over the NODES table scrolls the table, not the editor '
        'with the focus',
        hy1 > hy0 and ey1 == ey0,
        'table %s -> %s, editor %s -> %s' % (hy0, hy1, ey0, ey1))
    h.event_generate('<ButtonRelease-1>', x=40, y=60, when='now')
    is_('a clicked row has its blue band and no dotted anchor box',
        bool(h.tag_ranges('band')))
    is_('the results show the ordinary pointer',
        re.match(r'^(left_ptr|arrow)$', str(h.cget('cursor'))))
    win.set_buffer(doc['network'])
    win.validate()
    win.calculate()
    if shot:
        win.go_to_line(pl)
        win.mw.lift()
        win.mw.update()
        try:
            win.mw.save_as_png(shot) if hasattr(win.mw, 'save_as_png') \
                else None
            print('      screenshot not taken')
        except Exception:
            print('      screenshot not taken')
    win.ed.insert('%d.0 lineend' % pl, ' ')
    win.ed.mark_set('insert', '%d.0 lineend' % pl)
    win.update_status()
    is_('after an edit the figures are marked as from the earlier '
        'calculation',
        re.search(r'CALCULATED BEFORE THE LATEST EDITS',
                  win.status_text()), win.status_text())

    #==========================================================================
    print('9. THE PROJECT TAB')
    #==========================================================================
    win.set_buffer(doc['network'])
    win.select_tab(win.toptabs, 'PROJECT')
    win.mw.update()
    is_('the PROJECT tab shows the units as flat drop-downs',
        win.form['FLOW'].winfo_ismapped()
        and win.form['FLOW'].cget('relief') == 'flat')
    fm = widget_of(win.form['FLOW'].cget('menu'))
    lps = [i for i in range(fm.index('end') + 1)
           if re.match(r'^LPS', fm.entrycget(i, 'label'))][0]
    lpm = [i for i in range(fm.index('end') + 1)
           if re.match(r'^LPM', fm.entrycget(i, 'label'))][0]
    is_('   the default is marked in the menu',
        fm.entrycget(lpm, 'label') == 'LPM   (DEFAULT)')
    fm.invoke(lps)
    is_('choosing LPS sets the unit, marks the file changed',
        win.settings['units']['FLOW'] == 'LPS'
        and re.match(r'^LPS', win.form['FLOW'].cget('text'))
        and re.search(r'\*$', win.mw.title()))
    win.validate()
    win.calculate()
    win.go_to_line(pl)
    win.update_status()
    is_('the results follow: M1 in L/S',
        re.search(r'M1  Q 59\.6\d* L/S', win.status_text()),
        win.status_text())
    fm.invoke(lpm)
    is_('choosing LPM again: the file as it was, no *',
        not re.search(r'\*$', win.mw.title()), win.mw.title())
    win.form['JOB'].delete(0, 'end')
    win.form['JOB'].insert(0, 'job 42')
    PJ.settings_changed()
    is_('text typed in a field is kept in capitals',
        win.settings['project']['JOB'] == 'JOB 42')
    win.settings['options']['TOL_FLOW'] = 'TIGHT'
    PJ.settings_changed()
    oe = [i for i, e in enumerate(win.list_lines.get('ERRORS', []))
          if (e.get('field') or '') == 'TOL_FLOW']
    oe = oe[0] if oe else None
    is_('a bad option is listed in ERRORS',
        oe is not None
        and re.search(r'PROJECT TAB, TOL_FLOW',
                     win.LIST['ERRORS'].get(oe)))
    win.select_tab(win.toptabs, 'NETWORK')
    win.LIST['ERRORS'].selection_clear(0, 'end')
    win.LIST['ERRORS'].selection_set(oe if oe is not None else 0)
    win.go_to_list('ERRORS')
    is_('   a click on it opens the PROJECT tab at the field',
        win.toptabs['current'] == 'PROJECT')
    v = win.validate()
    is_('   VALIDATE names the PROJECT tab and the field',
        not v.get('ok')
        and R.validation_rows()[0][0] == 'PROJECT TAB'
        and R.validation_rows()[0][1] == 'TOL_FLOW')
    win.settings['options']['TOL_FLOW'] = ''
    PJ.settings_changed()

    #==========================================================================
    print('10. FILES')
    #==========================================================================
    win.open_path('examples/01_single_branch.phc')
    win.path = None
    win.ed.insert('end', '// EDITED\n')
    win.after_change()
    is_('an edit marks the title with *', re.search(r'\*$', win.mw.title()))
    win.file_save_as(os.path.join(TMP, 'saved.phc'))
    saved = slurp(os.path.join(TMP, 'saved.phc'))
    is_('SAVE AS writes the settings at the head, then the network',
        re.match(r'\AUNITS     LENGTH M\n', saved)
        and re.search(r'\nMETHOD    HW\n', saved)
        and re.search(r'\n\n// 01 - SINGLE BRANCH', saved)
        and re.search(r'// EDITED\n\Z', saved), saved[:120])
    is_('   and the title loses the *',
        win.mw.title() == 'PHCP EDITOR - SAVED.PHC', win.mw.title())
    sv = editor.solve_text(saved, os.path.join(TMP, 'saved.phc'))
    is_('   the saved file solves on its own',
        sv.get('ok') and sv.get('converged'))
    win.open_path(os.path.join(TMP, 'saved.phc'))
    is_('reopening it gives the same network and settings',
        win.buffer().startswith('// 01 - SINGLE BRANCH')
        and win.settings['options']['TOL_FLOW'] == '0.001')
    before = win.buffer()
    win.open_path('examples/02_full_network.hcx')
    is_('a .hcx is refused, the buffer kept, the reason shown',
        win.buffer() == before
        and re.search(r'THE EDITOR WORKS IN \.PHC FILES',
                      win.status_text()), win.status_text())
    win.open_path('examples/02_full_network.phc')
    win.file_report(os.path.join(TMP, 'report.pdf'))
    is_('WRITE REPORT validates, calculates and writes a PDF',
        os.path.getsize(os.path.join(TMP, 'report.pdf'))
        and slurp(os.path.join(TMP, 'report.pdf')).startswith('%PDF-'))
    win.file_report(os.path.join(TMP, 'report.txt'))
    is_('WRITE REPORT .txt writes the text report',
        re.search(r'OUTLET COMPLIANCE',
                  slurp(os.path.join(TMP, 'report.txt')), re.I))
    win.set_buffer(win.buffer() + 'PIPX\n')
    is_('WRITE REPORT on a model with problems stops at VALIDATION',
        not win.file_report(os.path.join(TMP, 'no.txt'))
        and not os.path.exists(os.path.join(TMP, 'no.txt'))
        and win.restabs['current'] == 'VALIDATION')

    #==========================================================================
    print("11. THE DATABASE TAB")
    #==========================================================================
    real = slurp('data/pipes.dat')
    win.select_tab(win.toptabs, 'DATABASE')
    win.mw.update()
    is_('a DATABASE tab: the built-in database, its path and fingerprint',
        DB.DBV['origin'].cget('text') == 'BUILT-IN'
        and re.search(r'data/pipes\.dat$', DB.DBV['path'].cget('text'))
        and re.match(r'^FINGERPRINT [0-9A-F]{12}$',
                     DB.DBV['sha'].cget('text')))
    is_("four tables: pipe types, pipe sizes, fittings, K' factors",
        DB.DBV['tabs']['names'] == ['PIPE TYPES', 'PIPE SIZES',
                                    'FITTINGS', "K' FACTORS"])
    win.select_tab(DB.DBV['tabs'], 'FITTINGS')
    is_('the fittings table lists every fitting',
        len(DB.DBV['shown_rows']) == 219)
    is_('read-only at first: the row buttons off, the fields read-only, '
        'SAVE off',
        not DB.DBV['editing'][0]
        and DB.DBV['btn']['UPDATE'].cget('state') == 'disabled'
        and DB.DBV['entries'][0].cget('state') == 'readonly'
        and DB.DBV['btn']['SAVE'].cget('state') == 'disabled')
    DB.DBV['filter'].set('long radius 50 0.9')
    DB.db_fill()
    is_('the filter narrows the table: LONG RADIUS 50 0.9 is one row',
        len(DB.DBV['shown_rows']) == 1, len(DB.DBV['shown_rows']))
    # Use a team folder of our own before any edit, so the real file is
    # safe.
    team = tempfile.mkdtemp()
    DB.db_choose_folder(team, 'yes')
    is_('CHOOSE FOLDER: an empty folder takes a copy and becomes the '
        'TEAM FOLDER',
        os.path.exists(os.path.join(team, 'pipes.dat'))
        and DB.DBV['origin'].cget('text') == 'TEAM FOLDER'
        and SET.get('DATABASE_DIR') == team)
    win.select_tab(DB.DBV['tabs'], 'FITTINGS')
    DB.db_fill()
    row = DB.DBV['shown_rows'][0]
    DB.DBV['sel'] = row
    DB.db_form()
    is_('a click on a row fills the fields',
        DB.DBV['vals'][1].get() == 'EL' and DB.DBV['vals'][3].get() == '50')
    DB.db_update()
    is_('read-only: UPDATE does nothing', not DB.DBV['db']['modified'])
    DB.DBV['editing'][0] = 1
    DB.db_editing_changed()
    is_('ticking EDIT turns the row buttons and fields on',
        DB.DBV['btn']['UPDATE'].cget('state') == 'normal'
        and DB.DBV['entries'][0].cget('state') == 'normal')
    DB.DBV['vals'][4].set('ABC')
    DB.db_update()
    is_('a length that is not a number: refused, and the reason shown in '
        'red',
        re.search(r'MUST BE A NUMBER', DB.DBV['msg'].cget('text'))
        and lc(DB.DBV['msg'].cget('foreground')) == lc(win.C['error']))
    DB.DBV['vals'][4].set('1.7')
    DB.db_update()
    is_('a good change: made, and SAVE CHANGES comes on',
        DB.DBV['db']['modified']
        and DB.DBV['btn']['SAVE'].cget('state') == 'normal')
    win.open_path(EX7)
    win.validate()
    before_sha = DB.DBV['sha'].cget('text')
    DB.db_save()
    is_('SAVE: written to the team folder, a new fingerprint, nothing '
        'pending',
        re.search(r'^FIT\|AS\|EL\|.*\|50\|1\.7$',
                  slurp(os.path.join(team, 'pipes.dat')), re.M)
        and DB.DBV['sha'].cget('text') != before_sha
        and not DB.DBV['db']['modified'], DB.DBV['msg'].cget('text'))
    is_('   and the model must be validated again: CALCULATE is off',
        not win.calculate_enabled())
    win.validate()
    win.calculate()
    flat = re.sub(r'\s+', ' ', win.report_text())
    is_("the report then names the team folder's file in full",
        re.search(re.escape(team) + r'.?pipes\.dat \(team folder\)', flat),
        flat[flat.find('database:'):flat.find('database:') + 200]
        if 'database:' in flat else flat[:200])
    DB.db_use_builtin()
    is_("USE BUILT-IN: back to the program's own database",
        DB.DBV['origin'].cget('text') == 'BUILT-IN'
        and SET.get('DATABASE_DIR') is None)
    is_('the real database was never written', slurp('data/pipes.dat')
        == real)

    #==========================================================================
    print('12. THE GRAPH TAB')
    #==========================================================================
    G = GR.GV
    model = win.full_text()
    win.select_tab(win.toptabs, 'GRAPH')
    win.mw.update()
    is_('a GRAPH tab, after PROJECT',
        win.toptabs['names'][:3] == ['NETWORK', 'PROJECT', 'GRAPH']
        and win.toptabs['current'] == 'GRAPH')
    GR.graph_refresh()
    is_('empty: the problems listed, PRINT TO PDF off, nothing drawn but '
        'a note',
        re.search(r'A, THE WATER SUPPLY, NEEDS AT LEAST TWO POINTS',
                  G['problems'].get(0))
        and G['btn']['PDF'].cget('state') == 'disabled'
        and [i for i in G['canvas'].find_all()
             if G['canvas'].type(i) == 'text'])
    GR.graph_open('examples/10_supply_graph.phg')
    win.mw.update()
    is_('OPEN GRAPH fills every field from the file',
        G['fields']['JOB'].get() == 'HC-DEMO-010'
        and G['fields']['A3Q'].get() == '3600'
        and G['fields']['D4P'].get() == '290'
        and G['fields']['DUTY2D'].get() == 'HYDRANTS - TWO AT 10 L/S',
        G['fields']['A3Q'].get())
    is_('   no problems, PRINT TO PDF on, the file named without *',
        G['check']['ok'] and G['btn']['PDF'].cget('state') == 'normal'
        and G['file'].cget('text') == '10_SUPPLY_GRAPH.PHG',
        G['file'].cget('text'))
    curves = set()
    for i in G['canvas'].find_withtag('curve'):
        curves.update(G['canvas'].gettags(i))
    is_('the preview draws A B C D E',
        sorted(c for c in curves if re.match(r'^curve[A-E]$', c))
        == ['curveA', 'curveB', 'curveC', 'curveD', 'curveE'])
    key = [G['canvas'].itemcget(i, 'text')
           for i in G['canvas'].find_withtag('key')]
    is_('   its key gives each duty against E: 2 has 797 kPa, margin 197',
        any(re.match(r'^2  2400 L/MIN AT 600 KPA - E HAS 796\.8 KPA, '
                     r'MARGIN 196\.8 KPA', x) for x in key), ' '.join(key))

    # A mistake: shaded, listed, and a click on it goes to it.
    G['fields']['A2Q'].delete(0, 'end')
    G['fields']['A2Q'].insert(0, '18OO')
    GR.graph_refresh()
    is_("a bad flow: listed with its row, its fields shaded, PRINT off",
        G['problems'].get(0)
        == "A ROW 2: FLOW '18OO' IS NOT A NUMBER"
        and lc(G['fields']['A2Q'].cget('background'))
        == lc(win.C['fault_bg'])
        and G['btn']['PDF'].cget('state') == 'disabled',
        G['problems'].get(0))
    is_('   the file name gains a *',
        G['file'].cget('text') == '10_SUPPLY_GRAPH.PHG *')
    G['problems'].selection_set(0)
    GR.graph_go_to_problem()
    win.mw.update()
    is_('   a click on it puts the cursor in the field',
        win.mw.focus_get() is G['fields']['A2Q'])
    G['fields']['A2Q'].delete(0, 'end')
    G['fields']['A2Q'].insert(0, '1800')
    G['fields']['DUTY1D'].insert('end', ' level 3')
    GR.graph_refresh()
    is_('corrected: no problems; text typed is kept in capitals',
        G['check']['ok']
        and GR.graph['duty'][0][1]
        == 'SPRINKLERS - HIGHEST HAZARD AREA LEVEL 3')

    GR.graph['units']['FLOW'] = 'LPS'
    GR.graph_refresh()
    is_("the graph's units: FLOW L/S on the tables and the preview, and "
        'the file marked changed',
        any(l.cget('text') == 'FLOW L/S' for l, _t in G['ulabels'])
        and any(G['canvas'].type(i) == 'text'
                and re.search(r'FLOW, L/S, ON',
                              G['canvas'].itemcget(i, 'text'))
                for i in G['canvas'].find_all())
        and re.search(r'\*$', G['file'].cget('text')))
    GR.graph['units']['FLOW'] = 'LPM'
    GR.graph_refresh()
    GR.graph_pdf(os.path.join(TMP, 'graph.pdf'))
    is_('PRINT TO PDF writes the sheet',
        os.path.getsize(os.path.join(TMP, 'graph.pdf'))
        and re.search(r'^%PDF-.*% PHCP-SHEET PLOT',
                      slurp(os.path.join(TMP, 'graph.pdf')), re.S))
    GR.graph_save(os.path.join(TMP, 'g.phg'))
    is_('SAVE GRAPH writes the .phg, and the * goes',
        re.search(r'^DUTY\s+1500 700 1 SPRINKLERS - HIGHEST HAZARD AREA '
                  r'LEVEL 3$', slurp(os.path.join(TMP, 'g.phg')), re.M)
        and G['file'].cget('text') == 'G.PHG')
    is_('the model is untouched by all of it', win.full_text() == model)
    win.select_tab(win.toptabs, 'NETWORK')

    #==========================================================================
    print('13. THE QUICK TOOLS TAB')
    #==========================================================================
    Q, W = TO.QT, TO.QTW
    model = win.full_text()
    win.select_tab(win.toptabs, 'QUICK TOOLS')
    win.mw.update()

    def text(tool):
        return W[tool]['result'].get('1.0', 'end - 1 chars')

    is_('a QUICK TOOLS tab: velocity, K-factor, K converter, pressure '
        'loss, each asking for its figures',
        win.toptabs['current'] == 'QUICK TOOLS'
        and re.search(r'CHOOSE A SIZE AND GIVE A FLOW', text('VEL'))
        and re.search(r'ANY TWO OF K, Q AND P', text('K'))
        and re.search(r'GIVE A K', text('KCONV'))
        and W['VEL']['problems'].cget('text') == '')
    sizes = [W['VEL']['size_menu'].entrycget(i, 'label')
             for i in range(W['VEL']['size_menu'].index('end') + 1)]
    is_("SIZE lists the type's sizes with their bores",
        re.match(r'^DN20\s+21\.6 MM$', sizes[0])
        and any(re.match(r'^DN50\s+53\.0 MM$', s) for s in sizes),
        ' '.join(sizes[:3]))
    W['VEL']['size_menu'].invoke(4)           # DN50
    W['VEL']['field']['FLOW'].insert(0, '500')
    TO.tools_update('VEL')
    is_('VELOCITY: DN50 at 500 L/min is 3.78 m/s, 53.0 mm bore',
        re.search(r'VELOCITY\s+3\.78 M/S', text('VEL'))
        and re.search(r'BORE\s+53 MM', text('VEL')), text('VEL'))
    # As the PIPE TYPE drop-down does: the type set, the size cleared.
    Q['VEL']['type'], Q['VEL']['size'] = 'BORE', ''
    TO.tools_sizes('VEL')
    win.mw.update()
    is_('   BORE: the size becomes a field for the bore in mm',
        W['VEL']['size_entry'].winfo_ismapped()
        and not W['VEL']['size_mb'].winfo_ismapped())
    W['VEL']['size_entry'].insert(0, '100')
    W['VEL']['field']['FLOW'].delete(0, 'end')
    W['VEL']['field']['FLOW'].insert(0, '1500')
    TO.tools_update('VEL')
    is_('   100 mm at 1500 L/min: 3.18 m/s',
        re.search(r'VELOCITY\s+3\.18 M/S', text('VEL')))

    W['K']['field']['Q'].insert(0, '80')
    W['K']['field']['P'].insert(0, '100')
    TO.tools_update('K')
    is_('K-FACTOR: 80 L/min at 100 kPa gives K = 8',
        re.match(r'^K =\s+8\.000 L/MIN/KPA\^0\.5', text('K'), re.M),
        text('K'))
    W['K']['field']['K'].insert(0, '8')
    TO.tools_update('K')
    is_('   three given: refused, the K field outlined red',
        re.search(r'ONLY TWO', W['K']['problems'].cget('text'))
        and lc(W['K']['field']['K'].cget('highlightbackground'))
        == lc(win.C['error']))
    W['K']['field']['Q'].delete(0, 'end')
    TO.tools_update('K')
    is_('   cleared Q: solved for it, 80 L/min',
        re.match(r'^FLOW Q =\s+80 L/MIN', text('K'), re.M)
        and W['K']['problems'].cget('text') == '')

    W['KCONV']['field']['VALUE'].insert(0, '5.6')
    TO.tools_update('KCONV')
    is_('K CONVERTER: K5.6 US is 80.731 L/min/bar^0.5 and 8.073 per root '
        'kPa',
        re.search(r'METRIC\s+80\.731 L/MIN/BAR\^0\.5', text('KCONV'))
        and re.search(r'METRIC\s+8\.073 L/MIN/KPA\^0\.5',
                      text('KCONV')),
        text('KCONV'))

    Q['LOSS']['size'] = '65'
    W['LOSS']['field']['FLOW'].insert(0, '1000')
    W['LOSS']['field']['LENGTH'].insert(0, '25')
    TO.tools_update('LOSS')
    is_('PRESSURE LOSS: DN65 at 1000 L/min, both formulas, per metre and '
        'over 25 m',
        re.search(r'LOSS, KPA/M\s+3\.4617\s+2\.79\d\d', text('LOSS'))
        and re.search(r'OVER 25 M\s+86\.543\s+69\.913', text('LOSS')),
        text('LOSS'))
    W['LOSS']['field']['C'].insert(0, 'C1OO')
    TO.tools_update('LOSS')
    is_('   a bad C: named, outlined red, no answer',
        re.search(r"C FACTOR 'C1OO' IS NOT A NUMBER",
                  W['LOSS']['problems'].cget('text'))
        and lc(W['LOSS']['field']['C'].cget('highlightbackground'))
        == lc(win.C['error'])
        and re.search(r'NO ANSWER', text('LOSS')))
    W['LOSS']['field']['C'].delete(0, 'end')
    Q['LOSS']['type'], Q['LOSS']['size'] = 'BORE', ''
    TO.tools_sizes('LOSS')
    W['LOSS']['size_entry'].insert(0, '100')
    TO.tools_update('LOSS')
    is_('   BORE with no roughness: 0.045 mm, flagged as assumed in red',
        re.search(r'ROUGHNESS ASSUMED: THE PROGRAM DEFAULT', text('LOSS'))
        and 'warn' in tuple(
            W['LOSS']['result'].tag_names(
                W['LOSS']['result'].search('ROUGHNESS ASSUMED', '1.0'))))
    # FITTINGS: the database's equivalent lengths, as for a model's
    # pipe.
    Q['FIT']['size'] = '100'
    W['FIT']['field']['SPEC'].insert(0, '1T 2E G C')
    TO.tools_update('FIT')
    is_('FITTINGS: 1T 2E G C on DN100 medium steel is 6.1 + 2 x 3.0 + '
        '0.6 + 6.7 = 19.40 m, with its source',
        re.search(r'^\s*2 x E\s+90 DEG STANDARD ELBOW\s+6\.00 M$',
                 text('FIT'), re.M)
        and re.search(r'^TOTAL\s+19\.40 M', text('FIT'), re.M)
        and re.search(r'FROM AS 2118\.1', text('FIT')), text('FIT'))
    W['FIT']['field']['SPEC'].insert('end', ' 1ZZ')
    TO.tools_update('FIT')
    is_('   a fitting the database lacks is refused, not counted as zero',
        re.search(r'ZZ', W['FIT']['problems'].cget('text'))
        and re.search(r'NO ANSWER', text('FIT')),
        W['FIT']['problems'].cget('text'))

    # UNITS: the PROJECT tab's, taken when the tab is opened.
    was = dict(win.settings['units'])
    win.settings['units'].update(FLOW='LPS', PRESSURE='BAR', LENGTH='M')
    win.select_tab(win.toptabs, 'NETWORK')
    win.select_tab(win.toptabs, 'QUICK TOOLS')
    is_('units follow the PROJECT tab: the bar and the field notes say '
        'L/S and BAR',
        re.search(r'FLOW L/S, PRESSURE BAR, LENGTH M',
                  W['units'].cget('text'))
        and any(l.cget('text') == 'L/S' for l, _t in W['notes']),
        W['units'].cget('text'))
    Q['VEL']['type'], Q['VEL']['size'] = 'ASAM', '50'
    TO.tools_sizes('VEL')
    W['VEL']['field']['FLOW'].delete(0, 'end')
    W['VEL']['field']['FLOW'].insert(0, '8.3333333')
    TO.tools_update('VEL')
    is_('   8.333 L/s in DN50 is 3.78 m/s, the flow shown in L/s and '
        'L/min',
        re.search(r'VELOCITY\s+3\.78 M/S', text('VEL'))
        and re.search(r'FLOW\s+8\.333 L/S\s+\(500\.0 L/MIN\)',
                      text('VEL')), text('VEL'))
    W['K']['field']['K'].delete(0, 'end')
    W['K']['field']['Q'].delete(0, 'end')
    W['K']['field']['Q'].insert(0, '1.3333333')
    W['K']['field']['P'].delete(0, 'end')
    W['K']['field']['P'].insert(0, '1')
    TO.tools_update('K')
    is_('   K-FACTOR in bar: 80 L/min at 100 kPa typed as 1.333 L/s and '
        '1 bar gives K 8 per root kPa',
        re.search(r'K, LPM/KPA\s+8\.000', text('K')), text('K'))
    win.settings['units'].clear()
    win.settings['units'].update(was)
    win.select_tab(win.toptabs, 'NETWORK')
    is_('the model is untouched by all of it', win.full_text() == model)

    #==========================================================================
    print('14. THE ORIFICE PLATE TAB')
    #==========================================================================
    model = win.full_text()
    win.select_tab(win.toptabs, 'ORIFICE PLATE')
    win.mw.update()

    def otext(tool):
        return OR.OPW[tool]['result'].get('1.0', 'end - 1 chars')

    is_('an ORIFICE PLATE tab: size a plate, or the loss across a bore',
        win.toptabs['current'] == 'ORIFICE PLATE'
        and re.search(r'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A DROP',
                      otext('SIZE'))
        and re.search(r'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A BORE',
                      otext('DROP')))
    OR.OP['SIZE']['size'] = '50'
    OR.orifice_sizes('SIZE')
    OR.OPW['SIZE']['field']['FLOW'].insert(0, '500')
    OR.OPW['SIZE']['field']['DROP'].insert(0, '100')
    OR.orifice_update('SIZE')
    ans = tools_mod.plate(mode='SIZE', type='ASAM', size='50', flow=500,
                          drop=100, step_default=0.5)
    bore = '%.4g' % ans['bore']
    is_('SIZE: DN50 at 500 L/min for a 100 kPa net loss shows that bore',
        ans.get('ok')
        and re.search(r'BORE\s+%s MM' % re.escape(bore), otext('SIZE'))
        and re.search(r'NET LOSS', otext('SIZE'))
        and re.search(r'0\.596\s+\(THE DEFAULT\)', otext('SIZE'))
        and OR.OPW['SIZE']['problems'].cget('text') == '',
        otext('SIZE'))
    OR.OPW['SIZE']['field']['CD'].insert(0, '1.2')
    OR.orifice_update('SIZE')
    is_('   a CD above 1 is refused and the field outlined red',
        re.search(r'NOT MORE THAN 1',
                  OR.OPW['SIZE']['problems'].cget('text'))
        and lc(OR.OPW['SIZE']['field']['CD'].cget('highlightbackground'))
        == lc(win.C['error'])
        and re.search(r'NO ANSWER', otext('SIZE')))
    OR.OPW['SIZE']['field']['CD'].delete(0, 'end')
    OR.OP['DROP']['size'] = '65'
    OR.orifice_sizes('DROP')
    OR.OPW['DROP']['field']['FLOW'].insert(0, '500')
    OR.OPW['DROP']['field']['BORE'].insert(0, '38.5')
    OR.orifice_update('DROP')
    drop = tools_mod.plate(mode='DROP', type='ASAM', size=65, flow=500,
                           bore=38.5, step_default=0.5)
    loss = '%.4g' % drop['drop']
    is_('DROP: a 38.5 mm bore in DN65 at 500 L/min shows that net loss',
        drop.get('ok')
        and re.search(r'NET LOSS\s+%s KPA' % re.escape(loss),
                      otext('DROP'))
        and re.search(r'PERMANENT-LOSS RATIO', otext('DROP')),
        otext('DROP'))
    win.select_tab(win.toptabs, 'NETWORK')
    is_('the model is untouched by the orifice plate tab',
        win.full_text() == model)

    #==========================================================================
    print('15. AN ASSUMED ROUGHNESS IS FLAGGED')
    #==========================================================================
    win.settings['method'] = 'DW'
    win.set_buffer('\n'.join(
        ['WATER W1 0 500', 'USE PE11', 'PIPE P1 W1 A 50 110', 'NODE A 0',
         'USE BORE', 'PIPE P3 A S1 10 50', 'SPRINKLER S1 0 -50 8', '']))
    PJ.settings_changed()
    win.validate()
    win.calculate()
    w = list(win.LIST['WARNINGS'].get(0, 'end'))
    is_('a Darcy-Weisbach model with a BORE pipe and no roughness: '
        'WARNINGS says it is assumed, naming P3',
        any(re.search(r'ROUGHNESS ASSUMED: 1 PIPE\(S\) TAKE 0\.045 MM'
                      r'.*P3', x) for x in w), ' '.join(w))
    is_("   the PE pipe takes the database's 0.007 mm, and is not flagged",
        not [x for x in w if 'P1' in x])

    # Auto sizing: CALCULATE writes each size after its line as a comment.
    win.settings['method'] = 'HW'
    win.set_buffer('\n'.join(
        ['WATER W1 0 500', 'USE ASAM', 'PIPE P1 W1 A 20 0', 'NODE A 0',
         'PIPE P2 A S1 6 0 T   // TO THE HEAD', 'SPRINKLER S1 0 -50 8',
         '']))
    PJ.settings_changed()
    win.validate()
    said = []
    real_message = win.message

    def message(text, bad=False):
        said.append(text)
        real_message(text, bad)

    win.message = message
    r = win.calculate()
    win.message = real_message
    b = win.buffer().split('\n')
    is_('while it calculates, the status bar says COMPUTING, with what and '
        'the seconds gone',
        any(re.match(r'^[|/\\-] COMPUTING - (CALCULATING|AUTO SIZING 2 '
                     r'PIPES - TRIAL \d OF 5 - \d+ SOLVES) - \d+ S$', x)
            for x in said), ' '.join(said))
    is_('auto sizing: CALCULATE puts //AS - <size> after each sized line, '
        'size 0 kept',
        r.get('ok')
        and re.match(r'^PIPE P1 W1 A 20 0  //AS - \d+$', b[2])
        and re.match(r'^PIPE P2 A S1 6 0 T  //AS - \d+ // TO THE HEAD$',
                     b[4]), ' / '.join([b[2], b[4]]))
    r2 = win.calculate()
    is_('   the model still counts as validated, and calculates again '
        'unchanged',
        r2.get('ok') and win.buffer() == '\n'.join(b), win.buffer())

    #==========================================================================
    print('16. DARK MODE')
    #==========================================================================
    paper = lc(win.mw.cget('background'))
    edbg = lc(win.ed.cget('background'))
    sbs = [w for w in descendants(win.mw)
           if isinstance(w, tk.Scrollbar)]
    sb = sbs[0]
    scroll = lc(sb.cget('background'))
    win.toggle_theme()
    win.mw.update()
    box = [c for c in win.checks['pipes']['frame'].winfo_children()
           if isinstance(c, tk.Canvas)][0]
    rect = box.find_all()[0]
    outline = lc(box.itemcget(rect, 'outline'))
    is_('dark mode is remembered and repaints the editor',
        win.theme == 'dark'
        and lc(win.mw.cget('background')) == lc(win.C['paper'])
        and lc(win.ed.cget('background')) == lc(win.C['paper'])
        and lc(win.ed.cget('background')) != edbg
        and lc(win.ed.cget('foreground')) == lc(win.C['ink'])
        and lc(win.gutter.cget('background')) == lc(win.C['panel'])
        and lc(win.ed.tag_cget('command', 'foreground'))
        == lc(win.C['accent'])
        and lc(win.ed.tag_cget('number', 'foreground'))
        == lc(win.C['number'])
        and lc(win.ed.tag_cget('error', 'background'))
        == lc(win.C['error_bg'])
        and lc(win.ed.tag_cget('fault', 'foreground'))
        == lc(win.C['error'])
        and lc(sb.cget('background')) == lc(win.C['scroll'])
        and lc(sb.cget('background')) != scroll
        and lc(win.LIST['ERRORS'].cget('foreground'))
        == lc(win.C['error'])
        and lc(R.vtable['canvas'].cget('background')) == lc(win.C['paper'])
        and outline == lc(win.C['faint'])
        and win.btn['THEME'].cget('text') == 'LIGHT MODE'
        and win.view_menu.entrycget(0, 'label') == 'LIGHT MODE')
    is_("the choice is written as EDITOR_THEME, not the sheet's key",
        SET.get('EDITOR_THEME') == 'DARK'
        and SET.get('SHEET_THEME') is None)
    win.select_tab(win.toptabs, 'PROJECT')
    win.mw.update()
    is_('the PROJECT tab follows the editor palette',
        lc(win.toptabs['page']['PROJECT'].cget('background'))
        == lc(win.C['paper'])
        and lc(win.form['JOB'].cget('background')) == lc(win.C['paper'])
        and lc(win.form['JOB'].cget('foreground')) == lc(win.C['ink']))
    units = widget_of(win.form['LENGTH'].cget('menu'))
    is_('a PROJECT drop-down menu follows it too',
        units and lc(units.cget('background')) == lc(win.C['paper'])
        and lc(units.cget('foreground')) == lc(win.C['ink']))
    win.select_tab(win.toptabs, 'NETWORK')
    win.toggle_theme()
    win.mw.update()
    is_('light mode puts the white editor back',
        win.theme == 'light'
        and lc(win.mw.cget('background')) == paper
        and lc(win.ed.cget('background')) == '#ffffff'
        and lc(win.ed.cget('foreground')) == '#1c1f24'
        and lc(win.ed.tag_cget('command', 'foreground')) == '#1967d2'
        and lc(sb.cget('background')) == '#c5cdd8'
        and win.btn['THEME'].cget('text') == 'DARK MODE'
        and SET.get('EDITOR_THEME') == 'LIGHT')
    # A fresh process, the way the editor is actually opened: the widgets
    # are built light and then repainted from the saved choice.
    SET.set('EDITOR_THEME', 'DARK')
    probe = os.path.join(TMP, 'boot_theme.py')
    with open(probe, 'w') as pf:
        pf.write('''import os, sys
sys.path.insert(0, %r)
from hardycross import win
from hardycross import settings as SET
win.build_window()
win.mw.update()
bg = str(win.ed.cget('background')).lower()
ok = (win.theme == 'dark' and bg == win.C['paper'].lower()
      and bg != '#ffffff'
      and win.btn['THEME'].cget('text') == 'LIGHT MODE'
      and (SET.get('SHEET_THEME') or '') == '')
print('DARK' if ok else 'NO theme=%%s bg=%%s' %% (win.theme, bg))
win.mw.destroy()
''' % REPO)
    env = dict(os.environ)
    env['PYTHONPATH'] = REPO
    boot = subprocess.run([sys.executable, probe], capture_output=True,
                          text=True, env=env, cwd=REPO)
    is_('a saved EDITOR_THEME of DARK opens the editor in dark mode',
        re.match(r'^DARK\s*$', boot.stdout + boot.stderr),
        (boot.stdout + boot.stderr).strip())

    win.mw.destroy()
    print('\n%d passed, %d failed' % (passed[0], failed[0]))
    return 1 if failed[0] else 0


if __name__ == '__main__':
    sys.exit(main())
