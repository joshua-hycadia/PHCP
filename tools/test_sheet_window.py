#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers
# this source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sheet_window.py -- the spreadsheet WINDOW, built and driven
# headlessly: a port of tools/test_sheet_window.pl.
#
#   python3 tools/test_sheet_window.py
#
# Needs tkinter and an X display.  With no display it re-runs itself
# under xvfb-run, a virtual display, if that is installed; with neither
# it says SKIPPED and exits 0, so the suite can run on a machine
# without either -- the README says plainly whether the window has
# been run.
#
# The same idea as test_editor_window.py: no mouse, the widgets are
# asked directly.  What is checked is that the four network tabs are
# grids, that typing a pipe fills the nodes tab, that a node type of
# PRV adds that device's row, and that VALIDATE and CALCULATE are the
# editor's, so the answer is the engine's.
#==============================================================================
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)


def main():
    argv = sys.argv[1:]

    #--------------------------------------------------------- a display
    if not os.environ.get('DISPLAY'):
        if (not os.environ.get('PHCP_UNDER_XVFB')
                and shutil.which('xvfb-run')):
            os.environ['PHCP_UNDER_XVFB'] = '1'
            os.execvp('xvfb-run',
                      ['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
                       sys.executable, os.path.abspath(__file__)] + argv)
        print('SKIPPED: no X display and no xvfb-run - the spreadsheet '
              'window was not run')
        return 0
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print('SKIPPED: tkinter is not installed - the spreadsheet '
              'window was not run')
        return 0

    # Load the sheet without starting its event loop: importing the
    # module builds nothing until build_window() is called.
    os.chdir(REPO)
    # A settings file of this run's own, so the DATABASE tab never
    # reads or writes a real one.
    settings_dir = tempfile.mkdtemp()
    os.environ['PHCP_SETTINGS'] = os.path.join(settings_dir,
                                               'settings.ini')
    os.environ.pop('PHCP_DATABASE_DIR', None)

    import tkinter as tk

    from hardycross import settings as SET
    from hardycross import sheet as sheetmod
    from hardycross import tools as tools_mod
    from hardycross import win
    from hardycross.window import database as DB
    from hardycross.window import orifice as OR
    from hardycross import sheetwindow as SW
    from hardycross.window import results as _results

    passed = [0]
    failed = [0]

    def is_(name, ok, why=None):
        print('  %-64s %s' % (name, 'ok' if ok else '*** FAIL'))
        if not ok and why is not None:
            print('      %s' % why)
        (passed if ok else failed)[0] += 1

    mw = SW.build_window()
    mw.update_idletasks()
    mw.update()
    is_('the window is a spreadsheet, not the text editor',
        bool(re.match(r'^PHCP SHEET', mw.title())))

    tabs = list(SW.toptabs['names'])
    is_('the network is four grids, then the editor\'s other tabs',
        ' '.join(tabs) == ('SYSTEM NODES SUPPLIES PRESSURE DEVICES '
                           'PROJECT GRAPH QUICK TOOLS ORIFICE PLATE '
                           'DATABASE'), ' '.join(tabs))
    is_('the results tabs are the editor\'s',
        ' '.join(SW.restabs['names'])
        == 'VALIDATION PIPES NODES OUTLETS REPORT')
    is_('each pressure device has its own table',
        ' '.join(SW.devtabs['names'])
        == 'PUMP BP BFP PRV OPP OFD PRA')
    is_('a new sheet starts not validated, and calculate is off',
        SW.state_text() == 'NOT VALIDATED' and not SW.calculate_enabled())
    is_('the system grid has a row to type in, and a pipe column',
        SW.grid_cell('SYSTEM', 0, 'pipe') is not None
        and SW.grid_cell('SYSTEM', 0, 'fittings') is not None)

    # Type a pipe the way a keystroke does: the entry holds the text, and
    # the KeyRelease binding is what writes it into the model.  A list
    # (pipe type, a nominal diameter, node type) has no entry: choosing is
    # commit_value, which is what the menu's command calls.
    def type_cell(id_, r, key, text):
        w = SW.grid_cell(id_, r, key)
        if w is None:
            return
        if not isinstance(w, tk.Entry):
            SW.commit_value(id_, r, key, text)
            mw.update()   # a pipe-type change rebuilds the diameter cell
            return
        w.focus_force()
        w.delete(0, 'end')
        w.insert(0, text)
        w.event_generate('<KeyRelease>', keysym='a', when='now')
        # A completed pipe type or node type paints the cells that follow
        # it once the entry is left.  Choosing the whole value does that
        # here.
        if getattr(w, 'phcp_choices', None):
            SW.lookup_finish(id_, r, key)
        mw.update()

    def menu_labels(w):
        if w is None:
            return []
        m = None
        try:
            m = w.cget('-menu')
        except tk.TclError:
            m = None
        if m is None:
            m = getattr(w, 'phcp_menu', None)
        if m is None:
            return []
        m = win.nametowidget(m) if isinstance(m, str) else m
        try:
            end = m.index('end')
        except tk.TclError:
            return []
        if end is None or end == 'none':
            return []
        return [str(m.entrycget(i, 'label')) for i in range(end + 1)]

    type_cell('SYSTEM', 0, 'pipe', 'P1')
    type_cell('SYSTEM', 0, 'from', 'A')
    type_cell('SYSTEM', 0, 'to', 'B')
    type_cell('SYSTEM', 0, 'length', '10')
    is_('pipe type is a list',
        isinstance(SW.grid_cell('SYSTEM', 0, 'type'), tk.Entry)
        and getattr(SW.grid_cell('SYSTEM', 0, 'type'), 'phcp_menu', None))
    types = menu_labels(SW.grid_cell('SYSTEM', 0, 'type'))
    is_('the pipe type list is the database, and BORE',
        'ASAM' in types and 'BORE' in types)
    type_cell('SYSTEM', 0, 'type', 'ASAM')
    is_('a database type makes the diameter a list',
        isinstance(SW.grid_cell('SYSTEM', 0, 'diam'), tk.Entry)
        and getattr(SW.grid_cell('SYSTEM', 0, 'diam'), 'phcp_menu', None))
    diams = menu_labels(SW.grid_cell('SYSTEM', 0, 'diam'))
    is_('that list has 0, so the pipe can be sized, and the nominal size',
        '0   (SIZE THE PIPE)' in diams and '100' in diams)
    type_cell('SYSTEM', 0, 'diam', '100')
    type_cell('SYSTEM', 0, 'fittings', '2E T GV')
    mw.update()

    nodes = sheetmod.node_rows(SW.sheet)
    is_("typing the pipe's ends fills the nodes tab, in that order",
        ' '.join(nodes) == 'A B', ' '.join(nodes))
    is_('the node number is shown and is not an entry',
        SW.grid_text('NODES', 0, 'node') == 'A'
        and not isinstance(SW.grid_cell('NODES', 0, 'node'), tk.Entry))
    is_("a new node's type is blank", SW.grid_text('NODES', 0, 'type') == '')
    is_('node type is a list, the same kind of cell as the pipe type',
        isinstance(SW.grid_cell('NODES', 0, 'type'), tk.Entry)
        and getattr(SW.grid_cell('NODES', 0, 'type'), 'phcp_menu', None)
        and getattr(SW.grid_cell('SYSTEM', 0, 'type'), 'phcp_menu', None))

    # Choosing PRV is the menu's command: commit_value is what that
    # command calls.
    SW.commit_value('NODES', 1, 'type', 'PRV')
    mw.update()
    prv = sheetmod.device_rows(SW.sheet, 'PRV')
    is_('PRV on a node adds one row to the PRV table',
        len(prv) == 1 and prv[0]['node'] == 'B')
    is_('that row is on the pressure-devices grid, on the pipe that '
        'arrives there',
        SW.grid_text('DEV:PRV', 0, 'node') == 'B'
        and SW.grid_text('DEV:PRV', 0, 'pipe') == 'P1')
    # The device page has to be showing, or Tk does not deliver the key
    # to it.
    win.select_tab(SW.toptabs, 'PRESSURE DEVICES')
    win.select_tab(SW.devtabs, 'PRV')
    mw.update()
    type_cell('DEV:PRV', 0, 'q1', '0')
    type_cell('DEV:PRV', 0, 'l1', '40')
    SW.commit_value('NODES', 1, 'type', '')
    mw.update()
    is_('clearing the type takes the row off the table',
        not sheetmod.device_rows(SW.sheet, 'PRV'))
    SW.commit_value('NODES', 1, 'type', 'PRV')
    mw.update()
    is_('choosing it again brings the loss back',
        SW.grid_text('DEV:PRV', 0, 'l1') == '40',
        'cell=[%s]' % SW.grid_text('DEV:PRV', 0, 'l1'))

    win.select_tab(SW.toptabs, 'NODES')
    mw.update()
    type_cell('NODES', 0, 'elev', '0')
    type_cell('NODES', 1, 'elev', '3')
    SW.commit_value('NODES', 0, 'type', 'SUPPLY')
    win.select_tab(SW.toptabs, 'SUPPLIES')
    mw.update()
    type_cell('SUPPLIES', 0, 'static', '800')
    type_cell('SUPPLIES', 0, 'static', '850')
    is_('SUPPLY adds the supplies row, and the elevation stays on the '
        'node',
        SW.grid_text('SUPPLIES', 0, 'node') == 'A'
        and SW.grid_text('SUPPLIES', 0, 'static') == '850'
        and SW.grid_text('NODES', 0, 'elev') == '0')

    # The last edit replaced 800 with 850.  Undo returns to 800; redo to
    # 850.
    SW.edit_undo()
    mw.update()
    is_('undo puts the last cell back',
        SW.grid_text('SUPPLIES', 0, 'static') == '800',
        'static=[%s]' % SW.grid_text('SUPPLIES', 0, 'static'))
    SW.edit_redo()
    mw.update()
    is_('redo puts the typed value back',
        SW.grid_text('SUPPLIES', 0, 'static') == '850',
        'static=[%s]' % SW.grid_text('SUPPLIES', 0, 'static'))

    v = SW.validate()
    is_('the typed model validates', v['ok'],
        '; '.join(i.get('what') or '' for i in v['items']))
    is_('calculate turns on once it is valid',
        SW.calculate_enabled()
        and SW.state_text() == 'VALID - READY TO CALCULATE')
    r = SW.calculate()
    is_('calculate runs the engine and converges',
        bool(r) and r.get('ok') and r.get('converged'))

    def table_rows(name):
        return _results.table_rows(name)

    is_('the pipe table has the pipe',
        any('P1' in str(x[0]) for x in table_rows('PIPES')))

    # Completion.  The model is replaced by the file opened next, so this
    # edit does not have to be undone.  With nothing remembered, AS takes
    # the first type.  Tab keeps it and moves to the next cell.  It does
    # not walk the list.
    win.select_tab(SW.toptabs, 'SYSTEM')
    mw.update()
    SW.recall.clear()
    ptype = SW.grid_cell('SYSTEM', 0, 'type')
    ptype.focus_force()
    ptype.delete(0, 'end')
    ptype.insert(0, 'AS')
    ptype.event_generate('<KeyRelease>', keysym='s', when='now')
    mw.update()
    as_ = ptype.get()
    is_('typing AS completes the first pipe type', as_ == 'ASAH', as_)
    is_('the rest of that match is selected',
        ptype.selection_present()
        and ptype.index('sel.first') == 2)
    ptype.event_generate('<Tab>', when='now')
    mw.update()
    is_('tab keeps the pipe type and moves to the next cell',
        SW.grid_text('SYSTEM', 0, 'type') == 'ASAH'
        and mw.focus_get() is not None
        and mw.focus_get() is SW.grid_cell('SYSTEM', 0, 'c'),
        'type=%s focus=%s' % (
            SW.grid_text('SYSTEM', 0, 'type'),
            (mw.focus_get().winfo_name()
             if mw.focus_get() is not None else 'none')))
    # The type just kept is what a later row offers.  Down still walks
    # the others.
    prow = SW.grid_cell('SYSTEM', 1, 'type')
    prow.focus_force()
    mw.update()   # the focus change paints before the next key
    prow.delete(0, 'end')
    prow.insert(0, 'AS')
    prow.event_generate('<KeyRelease>', keysym='s', when='now')
    mw.update()
    is_('the next row completes AS to the type last kept',
        prow.get() == 'ASAH', prow.get())
    prow.event_generate('<Down>', when='now')
    mw.update()
    is_('down walks to the other pipe type', prow.get() == 'ASAM', prow.get())
    # A neighbour wins when nothing has been kept yet.  Row 0 is set to
    # ASAM without remembering it, so row 2, whose nearest type is that
    # ASAM, follows it.
    SW.recall.clear()
    SW.commit_value('SYSTEM', 0, 'type', 'ASAM')
    SW.lookup_finish('SYSTEM', 0, 'type')
    mw.update()
    prow2 = SW.grid_cell('SYSTEM', 2, 'type')
    prow2.focus_force()
    mw.update()
    prow2.delete(0, 'end')
    prow2.insert(0, 'AS')
    prow2.event_generate('<KeyRelease>', keysym='s', when='now')
    mw.update()
    is_('a row completes AS to the type in the nearest row',
        prow2.get() == 'ASAM', prow2.get())
    # Diameter.  10 takes 100.  Once 100 is kept, typing 1 on the next
    # row takes 100, not the first size that starts with 1.
    type_cell('SYSTEM', 0, 'type', 'ASAM')
    diam = SW.grid_cell('SYSTEM', 0, 'diam')
    diam.focus_force()
    diam.delete(0, 'end')
    diam.insert(0, '10')
    diam.event_generate('<KeyRelease>', keysym='0', when='now')
    mw.update()
    is_('typing 10 completes the diameter', diam.get() == '100', diam.get())
    diam.event_generate('<Tab>', when='now')
    mw.update()
    diam2 = SW.grid_cell('SYSTEM', 1, 'diam')
    diam2.focus_force()
    mw.update()
    diam2.delete(0, 'end')
    diam2.insert(0, '1')
    diam2.event_generate('<KeyRelease>', keysym='1', when='now')
    mw.update()
    is_('typing 1 completes to the diameter last kept',
        diam2.get() == '100', diam2.get())
    win.select_tab(SW.toptabs, 'NODES')
    mw.update()
    SW.recall.clear()
    SW.commit_value('NODES', 0, 'type', 'SUPPLY')
    SW.lookup_finish('NODES', 0, 'type')
    mw.update()
    nt = SW.grid_cell('NODES', 1, 'type')
    nt.focus_force()
    mw.update()
    nt.delete(0, 'end')
    nt.insert(0, 'S')
    nt.event_generate('<KeyRelease>', keysym='s', when='now')
    mw.update()
    is_('typing S completes to the node type last in the column',
        nt.get() == 'SUPPLY', nt.get())
    nt.delete(0, 'end')
    nt.insert(0, 'SP')
    nt.event_generate('<KeyRelease>', keysym='p', when='now')
    mw.update()
    is_('typing SP completes the node type',
        nt.get() == 'SPRINKLER', nt.get())

    # A file the editor already opens, through the sheet.
    SW.open_path(os.path.join(REPO, 'examples', '01_single_branch.phc'))
    mw.update()
    is_('opening a .phc file fills the system grid from it',
        SW.grid_text('SYSTEM', 0, 'pipe') == 'P1'
        and SW.grid_text('SYSTEM', 0, 'from') == 'N1'
        and SW.grid_text('SYSTEM', 0, 'diam') == '100.0')
    is_('a bore is typed, and its pipe type stays a list',
        isinstance(SW.grid_cell('SYSTEM', 0, 'diam'), tk.Entry)
        and not getattr(SW.grid_cell('SYSTEM', 0, 'diam'), 'phcp_menu', None)
        and getattr(SW.grid_cell('SYSTEM', 0, 'type'), 'phcp_menu', None)
        and SW.grid_text('SYSTEM', 0, 'type') == 'BORE')
    is_('the supply and the sprinkler land on the nodes tab',
        SW.grid_text('NODES', 0, 'type') == 'SUPPLY'
        and SW.grid_text('NODES', 1, 'type') == 'SPRINKLER')
    is_("the sprinkler's minimum pressure is in MIN P",
        SW.grid_text('NODES', 1, 'min_p') == '50')
    v = SW.validate()
    is_('the opened file validates', v['ok'],
        '; '.join(i.get('what') or '' for i in v['items']))
    r = SW.calculate()
    is_('and calculates', bool(r) and r.get('ok') and r.get('converged'))

    # A fault goes to the cell.  A bad diameter may not be the first
    # problem the reader lists (a pipe it cannot read also leaves a node
    # unconnected), so the click is the row that names the size.
    win.select_tab(SW.toptabs, 'SYSTEM')
    mw.update()
    type_cell('SYSTEM', 0, 'diam', 'not-a-size')
    v = SW.validate()
    is_('a bad diameter is a problem', not v['ok'])
    fi = 0
    for i, item in enumerate(v['items']):
        if 'NOT A NUMBER' in (item.get('what') or ''):
            fi = i
            break
    SW.go_to_fault(fi)
    mw.update()
    focused = mw.focus_get()
    is_('clicking it selects the system tab and the diameter cell',
        SW.toptabs['current'] == 'SYSTEM'
        and focused is not None
        and focused is SW.grid_cell('SYSTEM', 0, 'diam'),
        'tab=%s focus=%s whats=%s' % (
            SW.toptabs.get('current'),
            (focused.winfo_name() if focused is not None else 'none'),
            ' | '.join(i.get('what') or '' for i in v['items'])))

    # Rows, fill, find, and the dark palette.  Done on the opened file,
    # then undone, so each check starts from that file.
    win.select_tab(SW.toptabs, 'SYSTEM')
    mw.update()
    SW.grid_cell('SYSTEM', 0, 'from').focus_force()
    mw.update()
    SW.enter_down(SW.grids['SYSTEM'], 0, 'from')
    mw.update()
    down = mw.focus_get()
    is_('enter on a row that is not last moves down that column',
        down is not None and down is SW.grid_cell('SYSTEM', 1, 'from'))
    cols, rows_before = SW.grid_spec('SYSTEM')
    last = rows_before - 1
    SW.grid_cell('SYSTEM', last, 'length').focus_force()
    mw.update()
    SW.enter_down(SW.grids['SYSTEM'], last, 'length')
    mw.update()
    cols, rows_after = SW.grid_spec('SYSTEM')
    grown = mw.focus_get()
    is_('enter on the last system row adds a row and moves to its pipe '
        'cell',
        rows_after == rows_before + 1
        and grown is not None
        and grown is SW.grid_cell('SYSTEM', rows_after - 1, 'pipe'),
        'rows %s -> %s' % (rows_before, rows_after))
    SW.system_pad = SW.BLANKS
    SW.refresh_grid('SYSTEM')
    mw.update()

    SW.grid_cell('SYSTEM', 0, 'pipe').focus_force()
    mw.update()
    SW.edit_insert_row()
    mw.update()
    is_('insert row puts an empty pipe above the one that had the focus',
        SW.grid_text('SYSTEM', 0, 'pipe') == ''
        and SW.grid_text('SYSTEM', 1, 'pipe') == 'P1')
    SW.grid_cell('SYSTEM', 0, 'length').focus_force()
    mw.update()
    SW.edit_delete_row()
    mw.update()
    is_('delete row removes that pipe and the one below moves up',
        SW.grid_text('SYSTEM', 0, 'pipe') == 'P1')

    ln = SW.grid_text('SYSTEM', 0, 'length')
    SW.fill_range('SYSTEM', 0, 2, 'length')
    mw.update()
    is_('filling down copies the cell through the rows dragged over',
        SW.grid_text('SYSTEM', 1, 'length') == ln
        and SW.grid_text('SYSTEM', 2, 'length') == ln, ln)
    SW.edit_undo()
    mw.update()
    is_('undo takes the filled rows back',
        SW.grid_text('SYSTEM', 1, 'length') == ''
        and SW.grid_text('SYSTEM', 0, 'length') == ln)

    SW.grid_cell('SYSTEM', 0, 'pipe').focus_force()
    mw.update()
    SW.edit_fill_down()
    mw.update()
    is_('fill down copies the focused cell into the next row',
        SW.grid_text('SYSTEM', 1, 'pipe') == 'P1')
    SW.edit_undo()
    mw.update()

    SW.grid_cell('SYSTEM', 0, 'from').focus_force()
    mw.update()
    SW.edit_clear_row()
    mw.update()
    is_('clear row blanks the cells that can be typed',
        SW.grid_text('SYSTEM', 0, 'pipe') == ''
        and SW.grid_text('SYSTEM', 0, 'from') == ''
        and SW.grid_text('SYSTEM', 0, 'length') == '')
    SW.edit_undo()
    mw.update()
    is_('undo puts the cleared row back',
        SW.grid_text('SYSTEM', 0, 'pipe') == 'P1'
        and SW.grid_text('SYSTEM', 0, 'from') == 'N1')

    SW.find_what = 'N1'
    SW.find_with = 'N9'
    SW.find_case = False
    SW.find_all = False
    SW.find_pos = None
    win.select_tab(SW.toptabs, 'SYSTEM')
    is_('find lands on the cell that contains the text',
        SW.find_next() and SW.grid_text('SYSTEM', 0, 'from') == 'N1')
    mw.update()
    found = mw.focus_get()
    is_('and that cell is the one selected',
        found is not None
        and found is SW.grid_cell('SYSTEM', 0, 'from'),
        'focus=%s cell=%s' % (
            (found.winfo_name() if found is not None else 'none'),
            (SW.grid_cell('SYSTEM', 0, 'from').winfo_name()
             if SW.grid_cell('SYSTEM', 0, 'from') is not None else 'none')))
    SW.replace_current()
    mw.update()
    is_('replace writes the new text into that cell',
        SW.grid_text('SYSTEM', 0, 'from') == 'N9',
        'from=%s find_pos=%s' % (SW.grid_text('SYSTEM', 0, 'from'),
                                 SW.find_pos))
    SW.edit_undo()
    mw.update()

    SW.find_what = 'N'
    SW.find_with = 'Z'
    SW.find_pos = None
    nrep = SW.replace_all()
    mw.update()
    is_('replace all on this grid rewrites each match, and is one undo',
        nrep >= 2
        and SW.grid_text('SYSTEM', 0, 'from').startswith('Z')
        and SW.grid_text('SYSTEM', 0, 'to').startswith('Z'))
    SW.edit_undo()
    mw.update()
    is_('that undo puts both cells back',
        SW.grid_text('SYSTEM', 0, 'from') == 'N1'
        and SW.grid_text('SYSTEM', 0, 'to') == 'N2')

    SW.open_find(1)
    mw.update()
    is_('find and replace opens a box',
        SW.find_box is not None and SW.find_box.winfo_exists())
    if SW.find_box is not None:
        SW.find_box.destroy()
    SW.find_box = None

    win.select_tab(SW.toptabs, 'ORIFICE PLATE')
    mw.update()
    OR.OP['SIZE']['size'] = '50'
    OR.orifice_sizes('SIZE')
    OR.OPW['SIZE']['field']['FLOW'].insert(0, '500')
    OR.OPW['SIZE']['field']['DROP'].insert(0, '100')
    OR.orifice_update('SIZE')
    plate = tools_mod.plate(mode='SIZE', type='ASAM', size=50, flow=500,
                            drop=100, step_default=0.5)
    shown = OR.OPW['SIZE']['result'].get('1.0', 'end - 1 chars')
    bore = '%.4g' % plate['bore']
    is_("the orifice plate tab sizes a plate the way the editor's tab "
        'does',
        SW.toptabs['current'] == 'ORIFICE PLATE'
        and plate.get('ok')
        and ('BORE' in shown and bore + ' MM' in shown)
        and 'NET LOSS' in shown, shown)
    win.select_tab(SW.toptabs, 'SYSTEM')
    mw.update()

    paper = str(mw.cget('background'))
    head = str(SW.grids['SYSTEM']['hclip'].cget('background'))
    SW.toggle_theme()
    mw.update()
    is_('dark mode is remembered and repaints the window',
        win.theme == 'dark'
        and str(mw.cget('background')) == win.C['paper']
        and str(mw.cget('background')) != paper
        and str(SW.grids['SYSTEM']['hclip'].cget('background'))
        == win.C['panel']
        and str(SW.grids['SYSTEM']['hclip'].cget('background')) != head
        and SW.btn_text() == 'LIGHT MODE')
    is_("the choice is written to this machine's settings",
        (SET.get('SHEET_THEME') or '') == 'DARK')
    SW.toggle_theme()
    mw.update()
    is_('light mode puts the white window back',
        win.theme == 'light'
        and str(mw.cget('background')) == paper
        and str(SW.grids['SYSTEM']['hclip'].cget('background')) == head)

    #======================================================================
    print('AS THE PERL WINDOW DOES IT (the line-by-line audit)')
    #======================================================================
    from tkinter import filedialog
    from hardycross.window import database as _database
    from hardycross.window import project as _project
    tmpd = tempfile.mkdtemp()

    def state():
        return '%s / %s' % (int(bool(SW.calculate_enabled())),
                            SW.state_text())

    # VALIDATION lists what VALIDATE found, and a click goes to the cell.
    bad = os.path.join(tmpd, 'bad.phc')
    with open(bad, 'w') as fh:
        fh.write('WATER W1 0 500\nNODE N1 0\nSPRINKLER S1 0 60 8\n'
                 'PIPE P1 W1 N1 5000 25\nPIPE P2 N1 S9 3000 25\n')
    SW.open_path(bad)
    v = SW.validate()
    mw.update()
    rows = _results.validation_rows()
    is_('a failed VALIDATE lists every problem in the VALIDATION tab',
        not v['ok'] and len(rows) == len(v['items']) == 3
        and rows[2][0] == 'LINE 6'
        and rows[2][2] == 'NODE S9 IS USED, BUT NOT DEFINED',
        str(rows)[:300])
    win.select_tab(SW.toptabs, 'DATABASE')
    _results.vtable['labels'][8].event_generate('<ButtonRelease-1>',
                                              when='now')
    mw.update()
    is_('a click on a problem goes to its cell on the sheet',
        SW.toptabs['current'] == 'SYSTEM'
        and mw.focus_get() is SW.grid_cell('SYSTEM', 1, 'pipe'),
        SW.toptabs['current'])
    items = SW.validation['items']
    SW.validation['items'] = [{'tab': 'PROJECT', 'field': 'TITLE',
                               'what': 'X', 'why': 'Y'}] + items
    win.select_tab(SW.toptabs, 'SYSTEM')
    SW.go_to_fault(0)
    mw.update()
    is_('   and one in the settings goes to its PROJECT field',
        SW.toptabs['current'] == 'PROJECT', SW.toptabs['current'])
    SW.validation['items'] = items

    # What the shared tabs change is this window's state too.
    SW.open_path(os.path.join(REPO, 'examples', '01_single_branch.phc'))
    SW.validate()
    was = state()
    _database.db_after_change()
    is_('a change of database turns CALCULATE off until validated again',
        was == '1 / VALID - READY TO CALCULATE'
        and state() == '0 / NOT VALIDATED' and SW.valid_text is None,
        '%s -> %s' % (was, state()))
    SW.validate()
    _project.ENTRY_VARS['TITLE'][0].set('A NEW TITLE')
    _project.settings_changed()
    is_('so does a change in the PROJECT tab',
        state() == '0 / NOT VALIDATED' and mw.title().endswith(' *'),
        '%s %s' % (state(), mw.title()))
    SW.validate()
    r = SW.calculate()
    had = len(_results.table_rows('PIPES'))
    real_ok = SW.ok_to_discard
    SW.ok_to_discard = lambda: True      # no dialog in a test
    try:
        SW.file_new()
    finally:
        SW.ok_to_discard = real_ok
    is_('NEW empties the results of the model before it',
        r.get('ok') and had > 0 and len(_results.table_rows('PIPES')) == 0
        and _results.validation_rows()[0][2].startswith('NOT VALIDATED YET')
        and state() == '0 / NOT VALIDATED',
        '%s %s' % (had, len(_results.table_rows('PIPES'))))

    # The PROJECT tab's drop-downs are this sheet's settings.
    SW.open_path(os.path.join(REPO, 'examples', '01_single_branch.phc'))
    mw.update()
    mb = win.form['LENGTH']
    mb.nametowidget(mb.cget('menu')).invoke(1)          # CM
    mb = win.form['METHOD']
    mb.nametowidget(mb.cget('menu')).invoke(1)          # DW
    mw.update()
    heads = [c['head'] for c in SW.grid_spec('SYSTEM')[0]]
    is_('a unit and a method chosen in PROJECT are the sheet\'s',
        SW.sheet['settings']['units']['LENGTH'] == 'CM'
        and SW.sheet['settings']['method'] == 'DW'
        and 'LENGTH (CM)' in heads
        and re.search(r'^UNITS\s+LENGTH CM$', SW.full_text(), re.M)
        and re.search(r'^METHOD\s+DW$', SW.full_text(), re.M)
        and mw.title().endswith(' *'),
        '%s %s' % (SW.sheet['settings']['units'].get('LENGTH'), heads[:4]))

    # Messages and the report's name.
    SW.write_file('/nonexistent/dir/x.phc')
    is_('a file that cannot be written says why, and only why',
        SW.statusbar.cget('text') == 'CANNOT WRITE /NONEXISTENT/DIR/X.PHC: '
                                     'NO SUCH FILE OR DIRECTORY',
        SW.statusbar.cget('text'))
    SW.open_path(os.path.join(REPO, 'examples', '01_single_branch.phc'))
    asked = {}
    real_save = filedialog.asksaveasfilename

    def fake_save(**kw):
        asked.update(kw)
        return os.path.join(tmpd, 'asked.txt')

    SW.path = os.path.join(tmpd, 'MODEL.PHC')
    filedialog.asksaveasfilename = fake_save
    try:
        wrote = SW.file_report()
    finally:
        filedialog.asksaveasfilename = real_save
    is_('WRITE REPORT offers MODEL_REPORT.PDF for MODEL.PHC',
        wrote and asked.get('initialfile') == 'MODEL_REPORT.PDF',
        '%r %r' % (wrote, asked.get('initialfile')))

    # A grid refreshed in place leaves the focus in the cell being typed in.
    # (The Perl takes it away: its `$mw->focus && ...` in refresh_grid is
    # not a question.  A defect there, deliberately not copied.)
    SW.saved_text = SW.full_text()
    SW.open_path(os.path.join(REPO, 'examples', '02_full_network.phc'))
    mw.update()
    c = SW.grid_cell('SYSTEM', 0, 'from')
    c.focus_force()
    mw.update()
    c.icursor('end')
    c.event_generate('<KeyPress>', keysym='x', when='now')
    c.event_generate('<KeyRelease>', keysym='x', when='now')
    mw.update()
    is_('a FROM node typed while SUPPLIES has rows: the focus stays in the '
        'cell',
        SW.sheet['pipes'][0]['from'].endswith('x') and mw.focus_get() is c,
        '%r %s' % (SW.sheet['pipes'][0]['from'], mw.focus_get()))
    c = SW.grid_cell('SYSTEM', 1, 'length')
    c.focus_force()
    mw.update()
    c.icursor('end')
    c.event_generate('<KeyPress>', keysym='7', when='now')
    c.event_generate('<KeyRelease>', keysym='7', when='now')
    mw.update()
    typed = c.get()
    kept = mw.focus_get() is c
    SW.edit_undo()
    mw.update()
    is_('undo puts the cell being typed in back as well',
        kept and typed.endswith('7') and not c.get().endswith('7')
        and c.get() == SW.sheet['pipes'][1]['length']
        and mw.focus_get() is c, '%r %r' % (typed, c.get()))
    SW.saved_text = SW.full_text()

    mw.destroy()
    print('\n%d passed, %d failed' % (passed[0], failed[0]))
    return 1 if failed[0] else 0


if __name__ == '__main__':
    sys.exit(main())
