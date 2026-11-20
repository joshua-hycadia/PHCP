"""sheetwindow -- the PHCP spreadsheet window: a port of phcp_sheet.pl.

A second way in to the same engine.  phcp_editor is the text editor and
is not changed by this program: the two do not share a window, and a
file saved here is ordinary .phc, which the engine and the editor
already read.

    +------------------------------------------------------------------+
    | NEW OPEN SAVE | VALIDATE  CALCULATE | WRITE REPORT    [ status ] |
    +------------------------------------------------------------------+
    | SYSTEM | NODES | SUPPLIES | PRESSURE DEVICES | PROJECT | GRAPH   |
    |        | QUICK TOOLS | ORIFICE PLATE | DATABASE                |
    |  ROW | PIPE | FROM NODE | TO NODE | LENGTH | TYPE | DIAM | ...    |
    |   1  |  1   | 2         | 101     | 7000   | S20  | 100  | 2E T   |
    +------------------------------------------------------------------+
    | VALIDATION | PIPES | NODES | OUTLETS | REPORT                     |
    +------------------------------------------------------------------+

SYSTEM is the pipes, one row each.  NODES is filled from the node
numbers typed there, in the order they first appear.  A blank node type
is a node; the word is not written in the cell.  SUPPLY on a node adds
a row to SUPPLIES.  A pressure-device type adds a row to that
device's table, and each device has only the columns it needs.

PIPE TYPE, PIPE DIAM and NODE TYPE are lists.  The pipe types and the
nominal sizes come from the database.  BORE, and a type the database
does not know, leave the diameter as a cell to type in.  EDIT inserts,
deletes and clears rows, copies a cell downwards, and finds and
replaces.  VIEW switches the whole window between the light palette
and a dark one.

PROJECT, GRAPH, QUICK TOOLS, ORIFICE PLATE and DATABASE are the same
tabs as the editor: they live in hardycross/window/ and decide nothing
for themselves.  The decisions for the grids are hardycross.sheet,
which has no Tk in it.  VALIDATE and CALCULATE call hardycross.editor,
the same checks and the same solve the text editor uses.

The flat buttons, tabs and colours below belong to this window: a
white sheet, a grey band for the toolbar and the column headings, a
shadow under the bar, and a stripe on alternate rows.  Inter and
JetBrains Mono are used when the machine has them, the same faces and
the same palette as the text editor.  This module does not open the
editor.

Perl's phcp_sheet.pl keeps its own palette and its own widget helpers,
and HardyCross/Window/Project.pm &c. are package main there too, so
the two windows in Perl each had a private copy of a flat button.  In
Python the shared tabs read hardycross.win's palette and helpers, so
this window takes them from there too and sets win.C and win.mw
before the tabs are built; the sheet's own state -- the grids, the
find box, the undo stacks -- is held here as module globals, as in
Perl.  hardycross.win.SHEET_THEME, not EDITOR_THEME, is the palette
this window remembers.
"""

import os
import re
import sys
import time
import copy
import tkinter as tk
from tkinter import filedialog, messagebox

from hardycross import editor
from hardycross import sheet as sheetmod
from hardycross import win
from hardycross import settings as _settings
from hardycross.window import database as _database
from hardycross.window import graph as _graph
from hardycross.window import orifice as _orifice
from hardycross.window import project as _project
from hardycross.window import results as _results
from hardycross.window import tools as _tools


#==============================================================================
# The window's state.  One sheet window per process.
#==============================================================================
# $settings is the PROJECT tab's hash.  The sheet holds that same hash, so a
# unit changed on the PROJECT tab is the unit the file is written with.
settings = editor.new_settings()
sheet = sheetmod.new_sheet(settings)

toptabs = None
restabs = None
devtabs = None
report = None
mw = None
view_menu = None
pill = None
hint = None
statusbar = None
vtable = None
btn = {}
form = {}
checks = {}
table = {}
dbv = {}
gv = {}
pipe_show = {}
grids = {}
hide_pipes = [0]
hide_nodes = [0]
project_canvas = None
path = None
solved = None
validation = None
valid_text = None
saved_text = ''
undo_stack = []
redo_stack = []
restoring = False        # true while undo or redo is putting a snapshot back
fault_marks = []         # entries whose outline is red after VALIDATE
BLANKS = 8               # empty SYSTEM rows under the last pipe, to type into
system_pad = BLANKS      # grows when Enter is pressed on the last of those rows
find_what = ''
find_with = ''
find_case = False
find_all = False
find_pos = None
find_box = None
recall = {}

# The wheel's target.  A little object rather than the grid frame, because
# the frame has no yview of its own: the grid is moved by place.
class PhcScroller:
    def __init__(self, g):
        self.g = g

    def yview(self, how, *n):
        if (how or '') != 'scroll':
            return
        grid_scroll(self.g, 'y', 'scroll', n[0], 'units')


#==============================================================================
# The window.
#==============================================================================
def build_window():
    win.dpi_aware()
    global mw, toptabs, restabs, report, vtable, pill, hint, statusbar
    win.mw = tk.Tk()
    mw = win.mw
    mw.configure(background=win.C['paper'])
    win.set_icon()
    dpi = mw.winfo_pixels('1i')
    win.SCALE = dpi / 96 if dpi > 96 else 1
    win.pick_fonts()
    mw.geometry('%dx%d' % (win.px(1500), win.px(950)))
    mw.option_add('*Font', win.UI)
    mw.option_add('*Background', win.C['paper'])
    mw.option_add('*Menu.Relief', 'flat')
    mw.option_add('*Menu.activeBorderWidth', 0)
    mw.option_add('*Menu.activeBackground', win.C['select'])
    mw.option_add('*Menu.activeForeground', win.C['ink'])
    mw.option_add('*Menu.font', win.UI)
    mw.option_add('*Menu.borderWidth', 1)
    # The PROJECT tab's fields and drop-downs are tied to the settings they
    # are built on: they must be this sheet's from the start (Perl's
    # $settings, which $sheet was made from), or a unit or a method chosen
    # there would change a dictionary nobody reads.
    win.settings = sheet['settings']
    build_menus()
    build_toolbar()

    vp = win.divider(mw, 'vertical')
    top = tk.Frame(mw, background=win.C['paper'])
    bottom = tk.Frame(mw, background=win.C['paper'])
    global toptabs, restabs, devtabs

    def on_select(n):
        if n == 'QUICK TOOLS':
            _tools.tools_refresh()
        if n == 'ORIFICE PLATE':
            _orifice.orifice_refresh()

    toptabs = win.make_tabs(
        top, ['SYSTEM', 'NODES', 'SUPPLIES', 'PRESSURE DEVICES',
              'PROJECT', 'GRAPH', 'QUICK TOOLS', 'ORIFICE PLATE', 'DATABASE'],
        on_select)
    build_system(toptabs['page']['SYSTEM'])
    build_nodes(toptabs['page']['NODES'])
    build_supplies(toptabs['page']['SUPPLIES'])
    build_devices(toptabs['page']['PRESSURE DEVICES'])
    _project.build_project(toptabs['page']['PROJECT'])
    _graph.build_graph(toptabs['page']['GRAPH'])
    _tools.build_tools(toptabs['page']['QUICK TOOLS'])
    _orifice.build_orifice(toptabs['page']['ORIFICE PLATE'])
    _database.build_database(toptabs['page']['DATABASE'])
    build_results(bottom)
    vp.add(top, height=win.px(560))
    vp.add(bottom)
    vp.pack(fill='both', expand=1)

    foot = tk.Frame(mw, background=win.C['panel'])
    foot.pack(side='bottom', fill='x')
    tk.Frame(foot, background=win.C['shadow'], height=1).pack(
        side='top', fill='x')
    global hint, statusbar
    hint = tk.Label(foot, text='', font=win.UI, background=win.C['panel'],
                    foreground=win.C['muted'], anchor='w', justify='left',
                    wraplength=win.px(1100))
    hint.pack(fill='x', padx=win.px(16), pady=win.px([6, 0]))
    statusbar = tk.Label(foot, text='', font=win.UI,
                         background=win.C['panel'], foreground=win.C['ink'],
                         anchor='w', justify='left')
    statusbar.pack(fill='x', padx=win.px(16), pady=win.px([1, 8]))

    bind_keys()
    refresh_all()
    global saved_text
    saved_text = full_text()
    # The shared tabs (the results tables, the report) read win's state, so
    # the sheet's is published there before they are painted again.
    _publish()
    set_title()
    update_actions()
    update_status()
    # A palette remembered from last time.  The widgets are built light and
    # then repainted, so the shared tabs take the dark colours too.
    saved = ''
    try:
        saved = (_settings.get('SHEET_THEME') or '').lower()
    except Exception:
        pass
    if saved == 'dark':
        apply_theme('dark')
    return mw


def _publish():
    """The sheet's state, into hardycross.win's, which the shared tabs --
    the results tables, the report text, the PROJECT form -- read as their
    own.  Perl's package main was the same hash for both windows; in Python
    the sheet keeps its own module globals and copies them across here."""
    win.mw = mw
    win.toptabs = toptabs
    win.restabs = restabs
    win.report = report
    win.vtable = vtable
    win.path = path
    win.settings = sheet['settings']
    win.solved = solved
    win.validation = validation
    win.valid_text = valid_text
    win.go_to_line = go_to_line
    win.recolour = _shared_recolour
    win.update_actions = _shared_update_actions
    # a click on a VALIDATION row is the sheet's: to the cell, not to a line
    _results.go_to_fault = go_to_fault
    win.update_status = update_status
    win.set_title = set_title
    win.message = message
    win.full_text = full_text


# The shared tabs change the state they share: the DATABASE tab, when the
# database in use changes, clears what was validated and calculated
# (db_after_change), then asks for the grids and the toolbar to be drawn
# again.  In Perl those were this window's own variables.  Here they are
# hardycross.win's, so what the shared tab left there is taken back before
# anything is drawn from it.  _publish keeps win's copy level with this
# module's at every change made here, so this never brings back an old one.
def _pull():
    global solved, validation, valid_text
    solved, validation, valid_text = win.solved, win.validation, win.valid_text


def _shared_recolour():
    _pull()
    return recolour()


def _shared_update_actions():
    _pull()
    return update_actions()


# select_tab -- this window's: a tab that is not there is left alone.
def select_tab(t, n):
    if not t or n not in t['page']:
        return
    win.select_tab(t, n)


def build_menus():
    bar = tk.Menu(mw, tearoff=0, relief='flat', borderwidth=0,
                 font=win.UI, background=win.C['paper'],
                 foreground=win.C['ink'])
    mw.configure(menu=bar)
    file_ = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='FILE', menu=file_)
    file_.add_command(label='NEW', accelerator='CTRL+N',
                      command=lambda: file_new())
    file_.add_command(label='OPEN...', accelerator='CTRL+O',
                      command=lambda: file_open())
    file_.add_command(label='SAVE', accelerator='CTRL+S',
                      command=lambda: file_save())
    file_.add_command(label='SAVE AS...', command=lambda: file_save_as())
    file_.add_separator()
    file_.add_command(label='PROJECT AND UNITS',
                      command=lambda: win.select_tab(toptabs, 'PROJECT'))
    file_.add_separator()
    file_.add_command(label='WRITE REPORT...', accelerator='CTRL+R',
                      command=lambda: file_report())
    file_.add_separator()
    file_.add_command(label='QUIT', accelerator='CTRL+Q',
                      command=lambda: file_quit())
    edit = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='EDIT', menu=edit)
    edit.add_command(label='UNDO', accelerator='CTRL+Z',
                     command=lambda: edit_undo())
    edit.add_command(label='REDO', accelerator='CTRL+Y',
                     command=lambda: edit_redo())
    edit.add_separator()
    edit.add_command(label='INSERT ROW', accelerator='CTRL+INS',
                     command=lambda: edit_insert_row())
    edit.add_command(label='DELETE ROW', accelerator='CTRL+DEL',
                     command=lambda: edit_delete_row())
    edit.add_command(label='CLEAR ROW', command=lambda: edit_clear_row())
    edit.add_command(label='FILL DOWN', accelerator='CTRL+D',
                     command=lambda: edit_fill_down())
    edit.add_separator()
    edit.add_command(label='FIND...', accelerator='CTRL+F',
                     command=lambda: open_find(0))
    edit.add_command(label='REPLACE...', accelerator='CTRL+H',
                     command=lambda: open_find(1))
    # cascade() here returns the entry, not the menu, so the menu is made on
    # its own and the label of DARK MODE can be changed when the palette is.
    global view_menu
    view_menu = tk.Menu(bar, tearoff=0, font=win.UI, relief='flat',
                        borderwidth=0, background=win.C['paper'],
                        foreground=win.C['ink'],
                        activebackground=win.C['select'],
                        activeforeground=win.C['ink'])
    bar.add_cascade(label='VIEW', menu=view_menu)
    view_menu.add_command(label='DARK MODE', command=lambda: toggle_theme())
    model = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='MODEL', menu=model)
    model.add_command(label='VALIDATE', accelerator='F4',
                      command=lambda: validate())
    model.add_command(label='CALCULATE', accelerator='F5',
                      command=lambda: calculate())


def build_toolbar():
    global pill
    tb = tk.Frame(mw, background=win.C['panel'])
    tb.pack(side='top', fill='x')
    ins = tk.Frame(tb, background=win.C['panel'])
    ins.pack(fill='x', padx=win.px(14), pady=win.px(8))

    def sep():
        tk.Frame(ins, background=win.C['line'], width=1,
                 height=win.px(22)).pack(side='left', padx=win.px(10))

    btn['NEW'] = win.flat_button(ins, 'NEW', lambda: file_new())
    btn['NEW'].pack(side='left', padx=win.px([0, 4]))
    btn['OPEN'] = win.flat_button(ins, 'OPEN', lambda: file_open())
    btn['OPEN'].pack(side='left', padx=win.px(4))
    btn['SAVE'] = win.flat_button(ins, 'SAVE', lambda: file_save())
    btn['SAVE'].pack(side='left', padx=win.px(4))
    sep()
    btn['VALIDATE'] = win.flat_button(ins, 'VALIDATE  F4', lambda: validate())
    btn['VALIDATE'].pack(side='left', padx=win.px(4))
    btn['CALCULATE'] = win.flat_button(ins, 'CALCULATE  F5',
                                       lambda: calculate(), primary=True)
    btn['CALCULATE'].pack(side='left', padx=win.px(4))
    sep()
    btn['REPORT'] = win.flat_button(ins, 'WRITE REPORT',
                                    lambda: file_report())
    btn['REPORT'].pack(side='left', padx=win.px(4))
    global pill
    pill = tk.Label(ins, text='', font=win.UI_B, padx=win.px(12),
                    pady=win.px(4))
    pill.pack(side='right')
    btn['THEME'] = win.flat_button(ins, 'DARK MODE', lambda: toggle_theme())
    btn['THEME'].pack(side='right', padx=win.px([0, 8]))
    # A soft edge, not a hard rule: the bar sits a step above the sheet.
    tk.Frame(mw, background=win.C['shadow'], height=1).pack(
        side='top', fill='x')


def bind_keys():
    mw.bind('<F4>', lambda e: validate())
    mw.bind('<F5>', lambda e: calculate())
    mw.bind('<Control-n>', lambda e: file_new())
    mw.bind('<Control-o>', lambda e: file_open())
    mw.bind('<Control-s>', lambda e: file_save())
    mw.bind('<Control-r>', lambda e: file_report())
    mw.bind('<Control-q>', lambda e: file_quit())
    mw.bind('<Control-z>', lambda e: edit_undo())
    mw.bind('<Control-y>', lambda e: edit_redo())
    mw.bind('<Control-d>', lambda e: edit_fill_down())
    mw.bind('<Control-f>', lambda e: open_find(0))
    mw.bind('<Control-h>', lambda e: open_find(1))
    mw.bind('<Control-Insert>', lambda e: edit_insert_row())
    mw.bind('<Control-Delete>', lambda e: edit_delete_row())
    mw.protocol('WM_DELETE_WINDOW', lambda: file_quit())
    win.bind_wheel()


# A one-line description above each grid, so the tab says where its rows
# come from.  The grids themselves scroll under it.
def blurb(page, text):
    f = tk.Frame(page, background=win.C['paper'])
    f.pack(side='top', fill='x', padx=win.px(16), pady=win.px([10, 6]))
    tk.Label(f, text=text, font=win.UI, background=win.C['paper'],
             foreground=win.C['muted'], anchor='w', justify='left',
             wraplength=win.px(1100)).pack(fill='x')
    return f


def build_system(page):
    blurb(page, "Each row is a pipe.  Pipe type, and the diameter of a "
                "database type, are lists.  Drag a cell's bottom-right corner "
                "to copy it down.  Edit inserts, deletes, clears, and finds.")
    grids['SYSTEM'] = build_grid(page, 'SYSTEM')


def build_nodes(page):
    blurb(page, 'Filled from the System tab, in the order the node numbers '
                'first appear.  A blank type is a node, and the word is not '
                'written in the cell.')
    grids['NODES'] = build_grid(page, 'NODES')


def build_supplies(page):
    blurb(page, "A row appears when a node's type is Supply.  The elevation "
                "stays on the Nodes tab.")
    grids['SUPPLIES'] = build_grid(page, 'SUPPLIES')


def build_devices(page):
    blurb(page, "A row appears when a node's type is that device.  A device "
                "already in a file is listed too.  Each table has only the "
                "columns that device needs.")
    global devtabs
    devtabs = win.make_tabs(page, list(sheetmod.DEVICE_TYPES))
    for type_ in sheetmod.DEVICE_TYPES:
        grids['DEV:' + type_] = build_grid(devtabs['page'][type_],
                                           'DEV:' + type_)


#------------------------------------------------------------------------------
# One grid: a header that stays put while the body scrolls down, and scrolls
# sideways with the body.  Row numbers are the first column, as on a sheet.
#
# The cells are placed in a frame, not drawn in a canvas.  A window embedded
# in a canvas does not take the keyboard in this Tk, so a click could not
# put the cursor in a cell.  A frame that is only moved (place) scrolls the
# same way and the cells focus normally.
#------------------------------------------------------------------------------
def build_grid(parent, id_):
    g = {'id': id_, 'cell': {}, 'ox': 0, 'oy': 0}
    box = tk.Frame(parent, background=win.C['paper'])
    box.pack(fill='both', expand=1)
    g['vsb'] = win.flat_scrollbar(box, 'vertical')
    g['vsb'].pack(side='right', fill='y')
    col = tk.Frame(box, background=win.C['paper'])
    col.pack(fill='both', expand=1)
    g['hclip'] = tk.Frame(col, background=win.C['panel'],
                          height=win.px(42))
    g['hclip'].pack(side='top', fill='x')
    g['hclip'].pack_propagate(0)
    g['hframe'] = tk.Frame(g['hclip'], background=win.C['panel'])
    tk.Frame(col, background=win.C['line'], height=1).pack(
        side='top', fill='x')
    g['hframe'].place(x=0, y=0, anchor='nw')
    g['hsb'] = win.flat_scrollbar(col, 'horizontal')
    g['hsb'].pack(side='bottom', fill='x')
    g['clip'] = tk.Frame(col, background=win.C['paper'])
    g['clip'].pack(fill='both', expand=1)
    g['frame'] = tk.Frame(g['clip'], background=win.C['paper'])
    g['frame'].place(x=0, y=0, anchor='nw')
    g['vsb'].configure(command=lambda *a: grid_scroll(g, 'y', *a))
    g['hsb'].configure(command=lambda *a: grid_scroll(g, 'x', *a))
    g['clip'].bind('<Configure>', lambda e: grid_place(g))

    def hframe_config(e):
        h = g['hframe'].winfo_reqheight()
        if h and h != (g['hclip'].cget('height') or 0):
            g['hclip'].configure(height=h)

    g['hframe'].bind('<Configure>', hframe_config)
    wheel = PhcScroller(g)
    win.wheel_target(g['clip'], wheel)
    win.wheel_target(g['hclip'], wheel)
    return g


# grid_scroll -- the scrollbar's command.  'moveto' is a fraction of the
# grid; 'scroll' is a step, a page when the bar asks for one.
def grid_scroll(g, axis, how, a, b=None):
    if axis == 'x':
        view, full = g['clip'].winfo_width(), g['frame'].winfo_reqwidth()
    else:
        view, full = g['clip'].winfo_height(), g['frame'].winfo_reqheight()
    view = view or 1
    full = full or 1
    mx = full - view
    if mx < 0:
        mx = 0
    off = g['ox'] if axis == 'x' else g['oy']
    if how == 'moveto':
        off = float(a) * full
    elif how == 'scroll':
        step = int(view * 0.9) if (b is not None and b == 'pages') \
            else win.px(18)
        off += float(a) * step
    if off < 0:
        off = 0
    if off > mx:
        off = mx
    if axis == 'x':
        g['ox'] = off
    else:
        g['oy'] = off
    grid_place(g)


# grid_wheel -- the wheel, in rows.  PhcScroller calls this.
def grid_wheel(g, units):
    grid_scroll(g, 'y', 'scroll', units, 'units')


# grid_place -- put the grid at the current offset and tell the scrollbars
# how much of it is showing.
def grid_place(g):
    if g.get('placing'):
        return
    g['placing'] = 1
    try:
        vw = g['clip'].winfo_width() or 1
        vh = g['clip'].winfo_height() or 1
        fw = g['frame'].winfo_reqwidth() or 1
        fh = g['frame'].winfo_reqheight() or 1
        maxx = max(0, fw - vw)
        maxy = max(0, fh - vh)
        g['ox'] = min(max(g['ox'], 0), maxx)
        g['oy'] = min(max(g['oy'], 0), maxy)
        g['frame'].place(x=-g['ox'], y=-g['oy'], anchor='nw')
        g['hframe'].place(x=-g['ox'], y=0, anchor='nw')
        g['hsb'].set(g['ox'] / fw if fw else 0,
                     (g['ox'] + vw) / fw if fw else 1)
        g['vsb'].set(g['oy'] / fh if fh else 0,
                     (g['oy'] + vh) / fh if fh else 1)
    finally:
        g['placing'] = 0


# The columns and the rows each grid shows.  The column list is the model's,
# so the heading and the field written to the file are the same thing.
def grid_spec(id_):
    # A tuple of columns, then how many rows.
    if id_ == 'SYSTEM':
        return (sheetmod.system_columns(sheet), system_row_count())
    if id_ == 'NODES':
        ids = sheetmod.node_rows(sheet)
        return (sheetmod.node_columns(sheet), len(ids))
    if id_ == 'SUPPLIES':
        ids = sheetmod.supply_rows(sheet)
        return (sheetmod.supply_columns(sheet), len(ids))
    m = re.match(r'^DEV:(.+)', id_)
    if m:
        rows = sheetmod.device_rows(sheet, m.group(1))
        return (sheetmod.device_columns(sheet, m.group(1)), len(rows))
    return ([], 0)


def system_row_count():
    last = len(sheet['pipes']) - 1
    while last >= 0 and sheetmod.pipe_is_blank(sheet['pipes'][last]):
        last = last - 1
    pad = system_pad
    if pad < BLANKS:
        pad = BLANKS
    n = last + 1 + pad
    return pad if n < pad else n


# grid_signature -- columns and row identity.  A new node, or a new pair of
# curve columns, changes it and the grid is built again.  Typing in a cell
# that is already there does not.
def grid_signature(id_):
    cols, n = grid_spec(id_)
    if id_ == 'NODES':
        ids = sheetmod.node_rows(sheet)
    elif id_ == 'SUPPLIES':
        ids = sheetmod.supply_rows(sheet)
    else:
        m = re.match(r'^DEV:(.+)', id_)
        if m:
            ids = ['%s|%s|%s' % (d.get('name') or '', d.get('node') or '',
                                 d.get('pipe') or '')
                   for d in sheetmod.device_rows(sheet, m.group(1))]
        else:
            ids = list(range(n))
    # The heading carries the unit, so a change of units on the PROJECT tab
    # builds the grid again.  On SYSTEM the diameter cell is a list or a
    # typed cell according to the type that row inherits, so that is part
    # of the signature too: changing the type rebuilds that cell's choices.
    units = ','.join(sheet['settings']['units'].get(q) or ''
                     for q in ('LENGTH', 'SIZE', 'ELEVATION', 'FLOW',
                               'PRESSURE', 'KFACTOR'))
    shape = ['%s:%s' % (c['key'], c['head']) for c in cols]
    diam = []
    if id_ == 'SYSTEM':
        for r in range(n):
            t = sheetmod.effective_type(sheet, r)
            diam.append('%s:%s' % (t, 'L' if sheetmod.diam_choices(sheet, t)
                                   else 'E'))
    ids = [str(x) for x in ids]
    diam = [str(x) for x in diam]
    return '\n'.join([units] + shape + ['---'] + ids + ['==='] + diam)


def refresh_all():
    if not grids.get('SYSTEM'):
        return
    # A node type of PRV with no row yet gains one before the tables paint.
    sheetmod.reconcile(sheet)
    for id_ in (['SYSTEM', 'NODES', 'SUPPLIES'] +
                ['DEV:' + t for t in sheetmod.DEVICE_TYPES]):
        refresh_grid(id_)
    if validation is not None and validation.get('text') is not None:
        try:
            if validation['text'] == full_text():
                mark_faults()
        except Exception:
            pass


def refresh_others(except_):
    for id_ in (['SYSTEM', 'NODES', 'SUPPLIES'] +
                ['DEV:' + t for t in sheetmod.DEVICE_TYPES]):
        if id_ == except_:
            continue
        refresh_grid(id_)


# refresh_grid -- paint one grid.  Rebuild when the rows or the columns
# changed; otherwise write the values into the cells, leaving the cell the
# user is typing in alone.
def refresh_grid(id_):
    g = grids.get(id_)
    if not g:
        return
    if g.get('building'):
        return   # a cell destroyed by a rebuild must not rebuild again
    sig = grid_signature(id_)
    if not g.get('sig') or g['sig'] != sig:
        g['building'] = 1
        try:
            g['sig'] = sig
            rebuild_grid(g)
        finally:
            g['building'] = 0
        return
    cols, n = grid_spec(id_)
    for r in range(n):
        for col in cols:
            w = g['cell'].get(r, {}).get(col['key'])
            if w is None:
                continue
            val = cell_get(id_, r, col['key'])
            # A list and a read-only cell show their text.  An entry the user
            # is typing in is left alone, so a refresh does not move the
            # cursor.
            if not isinstance(w, tk.Entry):
                w.configure(text=val)
                continue
            # The Perl reads `elsif ($mw->focus && $w eq $mw->focus) { next }`.
            # $mw->focus is not a question: it GIVES the main window the
            # keyboard focus, and returns nothing, so no cell is ever passed
            # over, and a grid refreshed in place takes the focus off
            # whatever cell had it.  That is what the window does (after an
            # undo, a fill, a replace, and a FROM or TO node typed while
            # another grid has rows), so it is done here too.
            _perl_mw_focus()
            if w.get() != val:
                w.delete(0, 'end')
                w.insert(0, val)


def _perl_mw_focus():
    try:
        mw.focus_set()
    except tk.TclError:
        pass


def rebuild_grid(g):
    id_ = g['id']
    for c in list(g['frame'].winfo_children()):
        c.destroy()
    for c in list(g['hframe'].winfo_children()):
        c.destroy()
    g['cell'] = {}
    g['rownum'] = {}
    g['ro'] = {}
    g['hover'] = None
    cols, n = grid_spec(id_)
    # Bold headings are wider than the same letters in the cell face.  The
    # column is the wider of the heading and the cell's character width,
    # plus the padding, so a heading such as PIPE DIAM is not clipped.
    cw = mw.tk.call('font', 'measure', win.MONO, '0') or 8

    def col_px(col):
        head_w = mw.tk.call('font', 'measure', win.MONO_B, col['head']) or 0
        body_w = cw * (col.get('width') or 1)
        return max(head_w, body_w) + win.px(22)

    c = 0

    def head(text, pxw):
        nonlocal c
        l = tk.Label(g['hframe'], text=text, font=win.MONO_B,
                     background=win.C['panel'], foreground=win.C['ink'],
                     anchor='w', padx=win.px(6), pady=win.px(8))
        l.grid(row=0, column=c, sticky='ew')
        g['hframe'].grid_columnconfigure(c, minsize=pxw)
        g['frame'].grid_columnconfigure(c, minsize=pxw)
        c = c + 1

    row_w = mw.tk.call('font', 'measure', win.MONO_B, 'ROW') or 0
    num_w = mw.tk.call('font', 'measure', win.MONO, '9999') or 0
    head('ROW', max(row_w, num_w) + win.px(22))
    for col in cols:
        head(col['head'], col_px(col))

    for r in range(n):
        bg = win.C['curline'] if r % 2 else win.C['paper']
        num = tk.Label(g['frame'], text=r + 1, font=win.MONO,
                       background=win.C['panel'], foreground=win.C['muted'],
                       anchor='e', width=4, padx=win.px(6),
                       pady=win.px(3))
        num.grid(row=r, column=0, sticky='nsew')
        g['rownum'][r] = num
        bind_row_hover(num, g, r)
        cc = 1
        for col in cols:
            w = make_cell(g, r, col, bg)
            w.grid(row=r, column=cc, sticky='nsew')
            g['cell'].setdefault(r, {})[col['key']] = w
            cc = cc + 1
    grid_place(g)


# row_base_bg -- the colour a cell has when the pointer is not on its row.
# Read-only cells and the row number sit on the grey band.  The rest stripe.
def row_base_bg(g, r, key):
    if key is None or g['ro'].get(r, {}).get(key):
        return win.C['panel']
    return win.C['curline'] if r % 2 else win.C['paper']


# paint_row -- shade a whole row, or put its own colours back.  A fault's
# red outline is a highlight colour, so this does not touch it.  A fill drag
# and a rebuild leave the row alone: those are already painting it.
def paint_row(g, r, on):
    if g is None or r is None:
        return
    if g.get('building') or g.get('drag'):
        return
    num = g['rownum'].get(r)
    if num is not None and num.winfo_exists():
        num.configure(background=win.C['hover'] if on else win.C['panel'])
    cells = g['cell'].get(r)
    if not cells:
        return
    for key, w in cells.items():
        if w is None or not w.winfo_exists():
            continue
        try:
            w.configure(background=win.C['hover'] if on
                        else row_base_bg(g, r, key))
        except tk.TclError:
            pass


# pointer_in_row -- true when the pointer's y is still inside this row.
# Moving from one cell to the next in the same row must not flash the stripe
# back on between the Leave and the Enter.
def pointer_in_row(g, r):
    if g is None or r is None:
        return False
    num = g['rownum'].get(r)
    if num is None:
        return False
    if not num.winfo_exists():
        return False
    try:
        y = g['frame'].winfo_pointery()
        y0 = num.winfo_rooty()
        h = num.winfo_height()
    except tk.TclError:
        return False
    return bool(h and y >= y0 and y < y0 + h)


# row_menu_open -- a list on this row is posted, so the pointer has left the
# cell for the menu and the row should stay shaded.
def row_menu_open(g, r):
    for c in list(g['cell'].get(r, {}).values()):
        try:
            menu = getattr(c, 'phcp_menu', None)
            try:
                menu = c.cget('menu') or menu
            except tk.TclError:
                pass
        except (tk.TclError, AttributeError):
            menu = getattr(c, 'phcp_menu', None)
        if menu is None:
            continue
        try:
            if menu.winfo_ismapped():
                return True
        except tk.TclError:
            continue
    return False


def clear_row_hover(g, r):
    if g.get('building') or g.get('drag'):
        return
    if pointer_in_row(g, r) or row_menu_open(g, r):
        return
    paint_row(g, r, False)
    if g.get('hover') is not None and g['hover'] == r:
        g['hover'] = None


# bind_row_hover -- shade the row under the pointer.  Leave waits until the
# pointer has actually gone, so crossing a cell border inside the row does
# not flicker.
def bind_row_hover(w, g, r):
    def enter(_e):
        if g.get('drag') or g.get('building'):
            return
        if g.get('hover') is not None and g['hover'] != r:
            paint_row(g, g['hover'], False)
        g['hover'] = r
        paint_row(g, r, True)

    def leave(_e):
        if g.get('drag') or g.get('building'):
            return
        mw.after_idle(lambda: clear_row_hover(g, r))

    w.bind('<Enter>', enter)
    w.bind('<Leave>', leave)


# make_cell -- one cell.  A row number's row is r.  Read-only cells are the
# node number and, on a device, the node it was taken from: those come from
# somewhere else and are not typed over.  A list (node type, pipe type, and
# a diameter the database knows sizes for) is an entry that completes as it
# is typed.  Several matches: the one last entered in this column, or else
# the nearest row that already has one.  Tab keeps it and moves to the next
# cell.  Down walks the other matches.  Anything else is typed.
def make_cell(g, r, col, bg):
    id_ = g['id']
    val = cell_get(id_, r, col['key'])
    choices = lookup_choices(id_, r, col)
    if choices:
        fg = win.C['number'] if col.get('kind') == 'diam' else win.C['ink']
        e = tk.Entry(g['frame'], font=win.MONO, width=col['width'],
                     relief='flat', borderwidth=0, highlightthickness=1,
                     highlightbackground=win.C['line'],
                     highlightcolor=win.C['accent'], background=bg,
                     foreground=fg, insertbackground=win.C['ink'],
                     selectbackground=win.C['select'],
                     selectforeground=win.C['ink'], takefocus=1)
        e.insert(0, val)
        e.phcp_choices = choices
        e.phcp_id = id_
        e.phcp_r = r
        e.phcp_key = col['key']
        e.phcp_kind = col.get('kind')
        e.phcp_menu = lookup_menu_for(e, id_, r, col, choices)
        e.phcp_pop = lookup_menu_for(e, id_, r, col, [])
        skip = ('Tab', 'ISO_Left_Tab', 'Return', 'KP_Enter', 'Up', 'Down',
                'Left', 'Right', 'Escape', 'Prior', 'Next', 'Home', 'End')

        def key_release(ev):
            if g.get('building') or getattr(e, 'phcp_busy', False):
                return
            ks = getattr(ev, 'keysym', '') or ''
            if ks in skip:
                return
            lookup_type(e)

        e.bind('<KeyRelease>', key_release)

        # Backspace over a suggested tail deletes the last character the
        # user typed, not only the suggestion, then completion runs again.
        def backspace(_ev):
            if not completion_selected(e):
                return
            prefix = typed_prefix(e)
            np = prefix[:-1] if len(prefix) else ''
            e.phcp_busy = True
            e.delete(0, 'end')
            e.insert(0, np)
            e.phcp_busy = False
            return 'break'

        e.bind('<BackSpace>', backspace)

        def escape(_ev):
            orig = getattr(e, 'phcp_orig', '')
            if orig is None:
                orig = ''
            e.phcp_busy = True
            e.delete(0, 'end')
            e.insert(0, orig)
            e.icursor('end')
            if e.selection_present():
                e.selection_clear()
            e.phcp_busy = False
            commit_value(id_, r, col['key'], orig, True)
            lookup_unpost(e)
            return 'break'

        e.bind('<Escape>', escape)

        def right(_ev):
            if not completion_selected(e):
                return
            e.selection_clear()
            e.icursor('end')
            lookup_unpost(e)
            return 'break'

        e.bind('<Right>', right)
        e.bind('<Alt-Down>', lambda _ev: (lookup_post(e, e.phcp_menu),
                                          'break')[1])
        grid_id = g['id']

        def focus_out(_ev):
            mw.after_idle(lambda: _focus_out_job(e, grid_id))

        e.bind('<FocusOut>', focus_out)
        bind_sheet_cell(e, g, r, col)
        # FocusIn was bound for the hint.  A list cell also remembers the
        # value to restore on Escape, and says how completion works.
        e.bind('<FocusIn>', lambda _ev: (
            show_hint(col['hint'] + '  TYPE TO COMPLETE. TAB KEEPS IT AND '
                         'MOVES ON. DOWN WALKS THE OTHER MATCHES. ALT+DOWN, '
                         'OR THE RIGHT EDGE, OPENS THE LIST.'),
            setattr(e, 'phcp_orig', cell_get(id_, r, col['key']))))
        bind_row_hover(e, g, r)
        return e
    if col.get('ro'):
        g['ro'].setdefault(r, {})[col['key']] = 1
        l = tk.Label(g['frame'], text=val, font=win.MONO,
                     background=win.C['panel'], foreground=win.C['ink'],
                     anchor='w', width=col['width'], padx=win.px(6),
                     pady=win.px(3), highlightthickness=1,
                     highlightbackground=win.C['line'])
        bind_row_hover(l, g, r)
        return l
    e = tk.Entry(g['frame'], font=win.MONO, width=col['width'],
                 relief='flat', borderwidth=0, highlightthickness=1,
                 highlightbackground=win.C['line'],
                 highlightcolor=win.C['accent'], background=bg,
                 foreground=win.C['number'], insertbackground=win.C['ink'],
                 selectbackground=win.C['select'],
                 selectforeground=win.C['ink'], takefocus=1)
    e.insert(0, val)
    # A rebuild destroys this entry.  Its KeyRelease must not write the
    # empty string back over the value the model already has.
    e.bind('<KeyRelease>', lambda _ev: (
        None if g.get('building')
        else commit_value(id_, r, col['key'], e.get())))
    e.bind('<FocusOut>', lambda _ev: grow_if_needed(id_))
    bind_sheet_cell(e, g, r, col)
    bind_row_hover(e, g, r)
    return e


# lookup_choices -- the menu for a list cell, each entry [value, label].
# An empty return is a cell that is typed, not chosen.  PIPE DIAM is a list
# only when the row's type (its own, or the one it inherits) has nominal
# sizes.  A value already in the cell that is not on the list is offered
# too, so opening a file does not hide what it said.
def lookup_choices(id_, r, col):
    kind = col.get('kind') or ''
    if kind == '':
        return []
    if kind == 'type':
        ch = list(sheetmod.TYPE_CHOICES)
    elif kind == 'pipetype':
        ch = [[v, v] for v in sheetmod.pipe_type_choices()]
    elif kind == 'diam':
        type_ = sheetmod.effective_type(sheet, r)
        sz = sheetmod.diam_choices(sheet, type_)
        if not sz:
            return []
        ch = [[v, ('0   (SIZE THE PIPE)' if v == '0' else v)] for v in sz]
    else:
        return []
    cur = cell_get(id_, r, col['key'])
    if len(cur) and not any(choice_is(c[0], cur) for c in ch):
        ch = [[cur, cur]] + ch
    return ch


# choice_display -- what the cell shows for a choice.  A blank node is the
# words "A NODE" while it is being completed, and empty once it is kept.
# A size of 0 is shown as 0; the menu's "(SIZE THE PIPE)" stays in the list.
def choice_display(ch):
    if not len(ch[0] or ''):
        return ch[1]
    return ch[0]


# choice_hits -- the choices whose text starts with what has been typed.
# Matching ignores case.  A blank node matches its menu words.  A size
# matches its number, not the note beside 0.
def choice_hits(prefix, choices):
    if prefix is None or prefix == '' or not choices:
        return []
    p = prefix.upper()
    hit = []
    for ch in choices:
        disp = choice_display(ch).upper()
        val = (ch[0] or '').upper()
        if not len(ch[0] or ''):
            if disp.startswith(p):
                hit.append(ch)
        else:
            if val.startswith(p) or disp.startswith(p):
                hit.append(ch)
    return hit


# typed_prefix -- the characters the user has typed.  A suggested tail is
# selected through to the end of the cell, and is not part of the prefix.
def typed_prefix(e):
    text = e.get()
    if not completion_selected(e):
        return text
    return text[:e.index('sel.first')]


def completion_selected(e):
    if e is None:
        return False
    try:
        if not e.selection_present():
            return False
        text = e.get()
    except tk.TclError:
        return False
    try:
        b = e.index('sel.last')
        a = e.index('sel.first')
    except tk.TclError:
        return False
    return b == len(text) and a < b


# lookup_menu_for -- a flat menu of choices.  Picking one writes that value.
# An empty choice list is the menu filled in later with the matches so far.
def lookup_menu_for(e, id_, r, col, choices):
    m = tk.Menu(e, tearoff=0, font=win.MONO, relief='flat',
               borderwidth=1, activeborderwidth=0,
               background=win.C['paper'], foreground=win.C['ink'],
               activebackground=win.C['select'],
               activeforeground=win.C['ink'])
    if choices:
        lookup_fill_menu(m, e, id_, r, col, choices)

    def unmap(_ev):
        g = grids.get(id_)
        mw.after_idle(lambda: _menu_unmap_job(g, r, e))

    m.bind('<Unmap>', unmap)
    return m


def _menu_unmap_job(g, r, e):
    if g is not None:
        clear_row_hover(g, r)
    if e.winfo_exists():
        lookup_maybe_finish(e)


def lookup_fill_menu(m, e, id_, r, col, choices):
    m.delete(0, 'end')
    try:
        m.unpost()
    except tk.TclError:
        pass
    for ch in choices:
        value, label = ch[0], ch[1]

        def pick(_v=value):
            if not e.winfo_exists():
                return
            e.phcp_busy = True
            e.delete(0, 'end')
            e.insert(0, value if len(value) else '')
            e.icursor('end')
            if e.selection_present():
                e.selection_clear()
            e.phcp_busy = False
            # A picked row is the whole value, so the grids that depend on
            # it are painted.  Typing, by contrast, waits until the cell is
            # left, so the entry is not rebuilt under the cursor.
            commit_value(id_, r, col['key'], value)
            recall_choice(id_, col['key'], value)
            lookup_unpost(e)

        m.add_command(label=label, command=pick)


# lookup_type -- after a key, fill one match and list the others.  An exact
# word wins.  Otherwise the value last kept in this column, and after that
# the nearest row that already has one, so a run of the same pipe does not
# start again at the first code in the list.  The suggested tail is
# selected, so the next character replaces it.
def lookup_type(e):
    if e is None:
        return
    if not getattr(e, 'phcp_choices', None):
        return
    prefix = typed_prefix(e)
    if not len(prefix or ''):
        lookup_unpost(e)
        commit_value(e.phcp_id, e.phcp_r, e.phcp_key, '', True)
        return
    hit = choice_hits(prefix, e.phcp_choices)
    if not hit:
        lookup_unpost(e)
        commit_value(e.phcp_id, e.phcp_r, e.phcp_key, e.get(), True)
        return
    i = best_hit_index(e, prefix, hit)
    apply_completion(e, prefix, choice_display(hit[i]))
    commit_value(e.phcp_id, e.phcp_r, e.phcp_key, hit[i][0], True)
    if len(hit) > 1:
        lookup_fill_menu(e.phcp_pop, e, e.phcp_id, e.phcp_r,
                        {'key': e.phcp_key}, hit)
        lookup_post(e, e.phcp_pop, i)
    else:
        lookup_unpost(e)


# apply_completion -- show $display, with the characters after the prefix
# selected.  phcp_busy stops this rewrite from being read as another key.
def apply_completion(e, prefix, display):
    e.phcp_busy = True
    e.delete(0, 'end')
    e.insert(0, display)
    n = len(prefix or '')
    if n < len(display) and display[:n].upper() == (prefix or '').upper():
        e.selection_range(n, 'end')
        e.icursor(n)
    else:
        if e.selection_present():
            e.selection_clear()
        e.icursor('end')
    e.phcp_busy = False


def lookup_post(e, m, active=None):
    if e is None or m is None:
        return
    if not e.winfo_exists() or not m.winfo_exists():
        return
    lookup_unpost(e)
    x = e.winfo_rootx()
    y = e.winfo_rooty() + (e.winfo_height() or 0)
    try:
        m.post(x, y)
        if active is not None and active >= 0:
            m.activate(active)
    except tk.TclError:
        return
    e.phcp_open = m


def lookup_unpost(e):
    if e is None:
        return
    for m in (getattr(e, 'phcp_pop', None),
              getattr(e, 'phcp_menu', None),
              getattr(e, 'phcp_open', None)):
        if m is None:
            continue
        try:
            m.unpost()
        except tk.TclError:
            pass
    e.phcp_open = None


# lookup_shown_value -- the stored value for whatever the cell is showing.
# "A NODE" is stored as a blank.  Text that matches nothing is kept as typed.
def lookup_shown_value(e):
    try:
        shown = e.get()
    except tk.TclError:
        return ''
    for ch in (getattr(e, 'phcp_choices', None) or []):
        if choice_display(ch) == shown or (len(ch[0]) and
                                           choice_is(ch[0], shown)):
            return ch[0]
    return shown


# lookup_accept -- keep the match on show and close the list.  The tail is
# no longer selected.  The value is remembered, so the next cell of this
# kind offers it first.
def lookup_accept(e):
    if e is None:
        return
    if not getattr(e, 'phcp_choices', None) or not e.winfo_exists():
        return
    if e.selection_present():
        e.selection_clear()
        e.icursor('end')
    val = lookup_shown_value(e)
    commit_value(e.phcp_id, e.phcp_r, e.phcp_key, val, True)
    recall_choice(e.phcp_id, e.phcp_key, val)
    lookup_unpost(e)


# The last value kept in a list column, by grid and column.  A letter of a
# completion does not count: only a value the user kept.
def recall_choice(id_, key, val):
    if val is None or not len(val):
        return
    recall['%s\0%s' % (id_, key)] = val


# nearest_hit -- of the matches, the one in the nearest other row.  A row
# whose value does not fit what was typed is skipped, so AS under an S40
# pipe still finds the ASAM above it.  Rows above come first.
def nearest_hit(e, hit):
    id_, r, key = e.phcp_id, e.phcp_r, e.phcp_key
    cols, n = grid_spec(id_)
    if not n:
        return None
    for dist in range(1, n):
        for rr in (r - dist, r + dist):
            if rr < 0 or rr >= n:
                continue
            v = cell_get(id_, rr, key)
            if v is None or not len(v):
                continue
            for i in range(len(hit)):
                if choice_is(hit[i][0], v) or choice_display(hit[i]) == v:
                    return i
    return None


# best_hit_index -- which of the prefix matches to fill in.  The word they
# typed, then the value last kept in this column, then the nearest row that
# fits the prefix.
def best_hit_index(e, prefix, hit):
    if not hit:
        return 0
    for i in range(len(hit)):
        disp = choice_display(hit[i])
        if disp.upper() == prefix.upper() or \
                (len(hit[i][0]) and hit[i][0].upper() == prefix.upper()):
            return i
    last = recall.get(e.phcp_id + '\0' + e.phcp_key)
    if last is not None and len(last):
        for i in range(len(hit)):
            if choice_is(hit[i][0], last) or choice_display(hit[i]) == last:
                return i
    near = nearest_hit(e, hit)
    if near is not None:
        return near
    return 0


# lookup_cycle -- Down and Up through the matches for the current prefix.
def lookup_cycle(e, direction):
    if e is None or not getattr(e, 'phcp_choices', None):
        return False
    if not completion_selected(e):
        return False
    hit = choice_hits(typed_prefix(e), e.phcp_choices)
    if len(hit) <= 1:
        return False
    shown = e.get()
    i = 0
    for k in range(len(hit)):
        if choice_display(hit[k]) == shown or \
                (len(hit[k][0]) and choice_is(hit[k][0], shown)):
            i = k
            break
    i = (i + direction) % len(hit)
    prefix = typed_prefix(e)
    apply_completion(e, prefix, choice_display(hit[i]))
    commit_value(e.phcp_id, e.phcp_r, e.phcp_key, hit[i][0], True)
    lookup_fill_menu(e.phcp_pop, e, e.phcp_id, e.phcp_r,
                    {'key': e.phcp_key}, hit)
    lookup_post(e, e.phcp_pop, i)
    return True


# lookup_tab -- Tab in a list cell.  The match on show is kept, and the
# cursor leaves for the next cell.  Down walks the other matches.  A pipe
# type or a node type can change other cells, so that paint waits until
# this binding has returned, and the move happens after it.
def lookup_tab(w, g, r, col, direction):
    if w is None or not getattr(w, 'phcp_choices', None):
        return False
    lookup_accept(w)
    kind = col.get('kind') or ''
    if kind in ('pipetype', 'type'):
        grid, row, key = g, r, col['key']

        def job():
            lookup_finish(grid['id'], row, key)
            move_focus(grid, row, key, 0, direction)

        mw.after_idle(job)
        return True
    return False


# lookup_step -- Up and Down walk the matches while a suggestion is showing.
# Once the value is kept they move to the next row, as on the rest of the
# sheet.
def lookup_step(e, direction):
    if e is None or not getattr(e, 'phcp_choices', None):
        return False
    return lookup_cycle(e, direction)


# lookup_maybe_finish -- paint a finished type once the cursor has left the
# cell and its list is closed.  Closing the list to redraw the matches does
# not count: the cursor is still in the cell, or the list is open again.
def lookup_maybe_finish(e):
    if e is None:
        return
    kind = getattr(e, 'phcp_kind', None)
    if not kind or kind not in ('pipetype', 'type'):
        return
    f = None
    try:
        f = mw.focus_get()
    except tk.TclError:
        pass
    if e.winfo_exists() and f is not None and f is e:
        return
    m = getattr(e, 'phcp_open', None)
    if m is not None:
        try:
            if m.winfo_ismapped():
                return
        except tk.TclError:
            pass
    lookup_finish(e.phcp_id, e.phcp_r, e.phcp_key)


# lookup_finish -- paint what a pipe type or a node type changes.  Not done
# on each letter, or the entry would be destroyed while it was being typed.
def lookup_finish(id_, r, key):
    global restoring
    if restoring:
        return
    if id_ == 'NODES' and key == 'type':
        sheetmod.reconcile(sheet)
        refresh_grid('NODES')
        refresh_others('NODES')
    elif id_ == 'SYSTEM' and key == 'type':
        refresh_grid('SYSTEM')


# choice_is -- the cell already says this choice.  100 and 100.0 are the
# same size, so the list does not offer both.
_NUM = re.compile(r'^[-+]?(?:\d+\.?\d*|\.\d+)$')


def choice_is(a, b):
    if a is not None and b is not None and a == b:
        return True
    if a is None or b is None or a == '' or b == '':
        return False
    if not _NUM.match(a) or not _NUM.match(b):
        return False
    return float(a) == float(b)


# bind_sheet_cell -- keys and the fill corner, on an entry and on a list.
# Tab and Return move as on a sheet.  The bottom-right corner of the cell is
# the fill handle: drag it across rows and those rows take this cell's value.
# A click anywhere else is the cell's own (the cursor, or the menu).
def bind_sheet_cell(w, g, r, col):
    id_ = g['id']
    hint_text = (col['hint'] +
                 '  DRAG THE BOTTOM-RIGHT CORNER DOWN TO COPY THIS CELL.')
    w.bind('<FocusIn>', lambda _e: show_hint(hint_text))

    def tab(_e):
        if lookup_tab(w, g, r, col, 1):
            return 'break'
        move_focus(g, r, col['key'], 0, 1)
        return 'break'

    def shift_tab(_e):
        if lookup_tab(w, g, r, col, -1):
            return 'break'
        move_focus(g, r, col['key'], 0, -1)
        return 'break'

    w.bind('<Tab>', tab)
    w.bind('<Shift-Tab>', shift_tab)

    # Enter may add a row, which rebuilds this grid and frees the cell the
    # key went to.  That waits until the binding has returned.  While a
    # suggestion is still selected, Enter keeps it and moves across, the
    # same as Tab: confirming a pipe type must not drop onto the next row
    # before the diameter is typed.  Enter with the value already kept
    # moves down.
    def enter(_e):
        across = bool(getattr(w, 'phcp_choices', None)) and \
            completion_selected(w)
        if getattr(w, 'phcp_choices', None):
            lookup_accept(w)
        grid, row, colkey = g, r, col['key']
        kind = col.get('kind')
        go = across

        def job():
            if kind and kind in ('pipetype', 'type'):
                lookup_finish(grid['id'], row, colkey)
            if go:
                move_focus(grid, row, colkey, 0, 1)
            else:
                enter_down(grid, row, colkey)

        mw.after_idle(job)
        return 'break'

    w.bind('<Return>', enter)

    def down(_e):
        if lookup_step(w, 1):
            return 'break'
        if getattr(w, 'phcp_choices', None):
            lookup_unpost(w)
        move_focus(g, r, col['key'], 1, 0)
        return 'break'

    def up(_e):
        if lookup_step(w, -1):
            return 'break'
        if getattr(w, 'phcp_choices', None):
            lookup_unpost(w)
        move_focus(g, r, col['key'], -1, 0)
        return 'break'

    w.bind('<Down>', down)
    w.bind('<Up>', up)
    w.bind('<Control-z>', lambda _e: (edit_undo(), 'break')[1])
    w.bind('<Control-y>', lambda _e: (edit_redo(), 'break')[1])
    # These rebuild the grid, which destroys this cell.  That has to wait
    # until the key binding has returned, or Tk is left in the cell it freed.
    w.bind('<Control-d>', lambda _e: (mw.after_idle(edit_fill_down),
                                      'break')[1])
    w.bind('<Control-f>', lambda _e: (open_find(0), 'break')[1])
    w.bind('<Control-h>', lambda _e: (open_find(1), 'break')[1])
    w.bind('<Control-Insert>', lambda _e: (mw.after_idle(edit_insert_row),
                                           'break')[1])
    w.bind('<Control-Delete>', lambda _e: (mw.after_idle(edit_delete_row),
                                           'break')[1])

    def motion(ev):
        if g.get('drag'):
            return
        if ev is None:
            return
        x, y = ev.x, ev.y
        corner = in_fill_corner(w, x, y)
        edge = in_menu_edge(w, x, y)
        idle = 'xterm' if isinstance(w, tk.Entry) else 'hand2'
        w.configure(cursor='crosshair' if corner
                    else ('hand2' if edge else idle))

    w.bind('<Motion>', motion)

    def press(ev):
        if ev is None:
            return
        if in_menu_edge(w, ev.x, ev.y):
            lookup_post(w, w.phcp_menu)
            return 'break'
        if not in_fill_corner(w, ev.x, ev.y):
            return
        g['drag'] = {'key': col['key'], 'row': r, 'over': r, 'saved': []}
        w.grab_set()
        return 'break'

    w.bind('<ButtonPress-1>', press)

    def b1_motion(ev):
        d = g.get('drag')
        if not d:
            return
        y = w.winfo_pointery()
        cols, n = grid_spec(id_)
        over = d['row']
        for rr in range(n):
            c = g['cell'].get(rr, {}).get(col['key'])
            if c is None:
                continue
            y0 = c.winfo_rooty()
            if y < y0:
                over = rr
                break
            over = rr
        if over != d['over']:
            d['over'] = over
            paint_fill(g)
        return 'break'

    w.bind('<B1-Motion>', b1_motion)

    def release(_ev):
        d = g.get('drag')
        if not d:
            return
        g['drag'] = None
        try:
            w.grab_release()
        except tk.TclError:
            pass
        restore_fill(d)
        if d['row'] != d['over']:
            # Same as a key that rebuilds the grid: the cell under the
            # pointer is still this binding's widget, so the copy waits a
            # turn.
            mw.after_idle(lambda: fill_range(id_, d['row'], d['over'],
                                            d['key']))
        return 'break'

    w.bind('<ButtonRelease-1>', release)


def _focus_out_job(e, grid_id):
    if not e.winfo_exists():
        return
    try:
        f = mw.focus_get()
    except tk.TclError:
        f = None
    if f is not None and f is e:
        return
    # The match list takes the pointer, not this edit.  Painting waits
    # until the list has gone and the cursor has left.
    m = getattr(e, 'phcp_open', None)
    if m is not None:
        try:
            if m.winfo_ismapped():
                return
        except tk.TclError:
            pass
    lookup_unpost(e)
    lookup_maybe_finish(e)
    grow_if_needed(grid_id)


# in_fill_corner -- true when the pointer is in the cell's bottom-right
# corner, the fill handle.  A cell that has not been drawn yet has no size.
# in_menu_edge -- the right edge of a list cell opens the whole list.
# The bottom-right corner stays the fill handle, so the two do not overlap.
def in_menu_edge(w, x, y):
    if w is None or not getattr(w, 'phcp_menu', None):
        return False
    if in_fill_corner(w, x, y):
        return False
    wd = w.winfo_width() or 0
    return bool(wd and x >= wd - win.px(18))


def in_fill_corner(w, x, y):
    wd = w.winfo_width() or 0
    ht = w.winfo_height() or 0
    return bool(wd and ht and x >= wd - win.px(10) and y >= ht - win.px(10))


# paint_fill / restore_fill -- the rows the fill will cover, outlined while
# the corner is dragged.  The outline they had (including a fault's red) is
# put back when the drag moves on or ends.
def paint_fill(g):
    d = g.get('drag')
    if not d:
        return
    restore_fill(d)
    lo = min(d['row'], d['over'])
    hi = max(d['row'], d['over'])
    for r in range(lo, hi + 1):
        c = g['cell'].get(r, {}).get(d['key'])
        if c is None:
            continue
        try:
            old = c.cget('highlightbackground')
            d['saved'].append([c, old])
            c.configure(highlightbackground=win.C['accent'],
                        highlightthickness=2)
        except tk.TclError:
            continue


def restore_fill(d):
    if not d:
        return
    for s in (d.get('saved') or []):
        c, old = s
        if c.winfo_exists():
            try:
                c.configure(highlightbackground=old, highlightthickness=1)
            except tk.TclError:
                pass
    d['saved'] = []


# cell_get / cell_set -- the text in one cell, from the model.  Curve points
# are q1, p1, l1 and so on; they live in the pair list two to a point.
def cell_get(id_, r, key):
    if id_ == 'SYSTEM':
        if r >= len(sheet['pipes']):
            return ''
        p = sheet['pipes'][r]
        if p is None:
            return ''
        return p.get(key, '')
    if id_ == 'NODES':
        ids = sheetmod.node_rows(sheet)
        if r >= len(ids):
            return ''
        nid = ids[r]
        if key == 'node':
            return nid
        t = sheet['nodes'][nid].get('type', '')
        if key == 'type' and not len(sheetmod.normal_type(t)):
            return ''
        return sheet['nodes'][nid].get(key, '')
    if id_ == 'SUPPLIES':
        ids = sheetmod.supply_rows(sheet)
        if r >= len(ids):
            return ''
        nid = ids[r]
        if key == 'node':
            return nid
        n = sheet['nodes'][nid]
        m = re.match(r'^([qp])(\d+)$', key)
        if m:
            return pair_get(n.get('pairs'), key)
        return n.get(key, '')
    m = re.match(r'^DEV:(.+)', id_)
    if m:
        rows = sheetmod.device_rows(sheet, m.group(1))
        if r >= len(rows):
            return ''
        d = rows[r]
        if d is None:
            return ''
        if key == 'node':
            return d.get('node', '')
        if key == 'duty_p':
            return d.get('duty_p', '')
        if re.match(r'^[qpl]\d+$', key):
            return pair_get(d.get('pairs'), key)
        return d.get(key, '')
    return ''


def pair_index(key):
    m = re.match(r'^([qpl])(\d+)$', key)
    if not m:
        return None
    return (int(m.group(2)) - 1) * 2 + (0 if m.group(1) == 'q' else 1)


def pair_get(pairs, key):
    i = pair_index(key)
    if i is None:
        return ''
    pairs = pairs or []
    return pairs[i] if i < len(pairs) else ''


def pair_put(pairs, key, val):
    i = pair_index(key)
    if i is None:
        return
    while len(pairs) <= i:
        pairs.append('')
    pairs[i] = val
    while pairs and not len(sheetmod.trim(pairs[-1])):
        pairs.pop()


# commit_value -- the cell has a new value.  Remember the grids first, so
# undo returns to what was there before this key.  A FROM NODE, TO NODE or
# NODE TYPE change rebuilds the grids that are filled from it.
def commit_value(id_, r, key, val, quiet=False):
    global restoring
    if restoring:
        return
    old = cell_get(id_, r, key)
    if val == old:
        return
    remember()
    cell_set(id_, r, key, val)
    # Quiet is a letter of a completion.  The cell stays as it is until the
    # edit is finished; painting now would destroy it.
    if not quiet:
        if id_ == 'SYSTEM' and key in ('from', 'to'):
            sheetmod.reconcile(sheet)
            refresh_others('SYSTEM')
        elif id_ == 'NODES' and key == 'type':
            sheetmod.reconcile(sheet)
            # The same rows, so this writes the chosen type into the cell
            # and does not rebuild it.  The device tables are the ones
            # rebuilt.
            refresh_grid('NODES')
            refresh_others('NODES')
        elif id_ == 'SYSTEM' and key == 'type':
            # The list's command is still running.  Rebuilding the grid now
            # would destroy that menu under the callback, so it is painted
            # once the callback has returned.  The diameter cell may change
            # from a list to a typed bore, or the other way.
            if mw is not None:
                mw.after_idle(lambda: refresh_grid('SYSTEM'))
    sheet_changed()


def cell_set(id_, r, key, val):
    val = sheetmod.trim(val)
    if id_ == 'SYSTEM':
        for i in range(r + 1):
            while len(sheet['pipes']) <= i:
                sheet['pipes'].append(sheetmod.empty_pipe())
        sheet['pipes'][r][key] = val
        return
    if id_ == 'NODES':
        ids = sheetmod.node_rows(sheet)
        if r >= len(ids):
            return
        nid = ids[r]
        sheet['nodes'][nid][key] = (sheetmod.normal_type(val)
                                    if key == 'type' else val)
        return
    if id_ == 'SUPPLIES':
        ids = sheetmod.supply_rows(sheet)
        if r >= len(ids):
            return
        nid = ids[r]
        n = sheet['nodes'][nid]
        if re.match(r'^[qp]\d+$', key):
            pair_put(n.setdefault('pairs', []), key, val)
        else:
            n[key] = val
        return
    m = re.match(r'^DEV:(.+)', id_)
    if m:
        rows = sheetmod.device_rows(sheet, m.group(1))
        if r >= len(rows):
            return
        d = rows[r]
        if key == 'duty_p':
            d['duty_p'] = val
        elif re.match(r'^[qpl]\d+$', key):
            pair_put(d.setdefault('pairs', []), key, val)
        else:
            d[key] = val


# grow_if_needed -- leaving a cell on the last blank SYSTEM row, or filling
# the last curve point, adds the next row or the next pair.  Done on the way
# out so the cell being typed in is not destroyed under the cursor.
def grow_if_needed(id_):
    g = grids.get(id_)
    if not g:
        return
    sig = grid_signature(id_)
    if g.get('sig') and g['sig'] == sig:
        return
    refresh_grid(id_)


# enter_down -- Return.  On any row but the last, move down the same column.
# On the last SYSTEM row, add one more row and go to its first cell, the
# pipe number.  Nodes, supplies and devices are filled from the pipes, so
# Return there does not invent a row of their own.
def enter_down(g, r, key):
    if g is None:
        return
    cols, n = grid_spec(g['id'])
    if g['id'] == 'SYSTEM' and n is not None and r == n - 1:
        global system_pad
        system_pad = system_pad + 1
        refresh_grid('SYSTEM')
        cols, n2 = grid_spec('SYSTEM')
        nr = n2 - 1
        w = g['cell'].get(nr, {}).get('pipe')
        if w is not None and w.winfo_exists():
            w.focus_force()
            reveal_row(g, nr)
        return
    move_focus(g, r, key, 1, 0)


# reveal_row -- scroll so this row is inside the grid.  A row Enter has just
# added sits under the one that was at the bottom.
def reveal_row(g, r):
    num = g['rownum'].get(r)
    if num is None or not num.winfo_exists():
        return
    if mw is not None:
        mw.update_idletasks()
    try:
        y = num.winfo_y()
        h = num.winfo_height() or win.px(24)
        vh = g['clip'].winfo_height() or 1
    except tk.TclError:
        return
    if y < g['oy']:
        g['oy'] = y
    elif y + h > g['oy'] + vh:
        g['oy'] = y + h - vh
        if g['oy'] < 0:
            g['oy'] = 0
    grid_place(g)


# move_focus -- Tab and Return, as on a sheet: Tab across, Return down.
def move_focus(g, r, key, dr, dc):
    cols, n = grid_spec(g['id'])
    keys = [c['key'] for c in cols if not c.get('ro')]
    if key not in keys:
        return
    i = keys.index(key)
    nr, ni = r + dr, i + dc
    if ni >= len(keys):
        ni = 0
        nr = nr + 1
    if ni < 0:
        ni = len(keys) - 1
        nr = nr - 1
    if nr < 0:
        return
    cols, n = grid_spec(g['id'])
    if nr >= n and g['id'] == 'SYSTEM':
        for i2 in range(nr + 1):
            while len(sheet['pipes']) <= i2:
                sheet['pipes'].append(sheetmod.empty_pipe())
        refresh_grid('SYSTEM')
        cols, n = grid_spec('SYSTEM')
    if nr >= n or nr < 0:
        return
    w = g['cell'].get(nr, {}).get(keys[ni])
    if w is None:
        return
    w.focus()
    if isinstance(w, tk.Entry):
        w.icursor('end')


def show_hint(text=''):
    if hint is not None:
        hint.configure(text=text or '')


#==============================================================================
# Rows, fill, find and replace.
#
# SYSTEM is the only grid a row can be inserted into or deleted from.  The
# nodes, the supplies and the devices are filled from it, so a row there is
# not a thing of its own.  Clearing a row blanks the cells that can be typed,
# on whichever grid has the focus, and leaves a node that a pipe still names.
# Filling copies one cell down the rows the corner was dragged over.  One
# snapshot covers the whole gesture, so undo puts every cell back.
#==============================================================================

# focused_cell -- the grid, the row and the column of the cell that has the
# keyboard, or nothing when focus is on a button or the find box.
def focused_cell():
    try:
        w = mw.focus_get()
    except tk.TclError:
        w = None
    if w is None:
        return None
    for id_ in (['SYSTEM', 'NODES', 'SUPPLIES'] +
                ['DEV:' + t for t in sheetmod.DEVICE_TYPES]):
        g = grids.get(id_)
        if not g:
            continue
        for r, cells in list(g['cell'].items()):
            for k, c in list(cells.items()):
                if c is None:
                    continue
                if c is w:
                    return (id_, int(r), k)
    return None


# after_structural -- the grids that are filled from the pipes and the node
# types, painted again after a change that can add or drop a row.
def after_structural():
    sheetmod.reconcile(sheet)
    refresh_all()
    sheet_changed()


def edit_insert_row():
    cell = focused_cell()
    if cell is None or cell[0] != 'SYSTEM':
        message('INSERT A ROW ON THE SYSTEM TAB. THE OTHER TABS ARE '
                'FILLED FROM IT.')
        return
    id_, r, key = cell
    n = len(sheet['pipes'])
    at = n if r > n else r
    remember()
    sheet['pipes'].insert(at, sheetmod.empty_pipe())
    after_structural()
    w = grids['SYSTEM']['cell'].get(at, {}).get('pipe')
    if w is not None:
        w.focus_force()


def edit_delete_row():
    cell = focused_cell()
    if cell is None or cell[0] != 'SYSTEM':
        message('DELETE A ROW ON THE SYSTEM TAB. THE OTHER TABS ARE '
                'FILLED FROM IT.')
        return
    id_, r, key = cell
    if r > len(sheet['pipes']) - 1:
        return
    remember()
    del sheet['pipes'][r]
    after_structural()
    focus = r
    if focus > len(sheet['pipes']) - 1:
        focus = len(sheet['pipes']) - 1
    if focus < 0:
        focus = 0
    w = grids['SYSTEM']['cell'].get(focus, {}).get('pipe')
    if w is not None:
        w.focus_force()


def edit_clear_row():
    cell = focused_cell()
    if cell is None:
        message('CLICK A ROW FIRST.')
        return
    id_, r, key = cell
    cols, n = grid_spec(id_)
    keys = [c['key'] for c in cols if not c.get('ro')]
    if not any(len(cell_get(id_, r, k)) for k in keys):
        return
    remember()
    for k in keys:
        cell_set(id_, r, k, '')
    after_structural()


# fill_range -- copy the cell at src down, or up, through dst, in one
# column.  The source cell is the one the drag started on.  On SYSTEM the
# rows in between are created if the drag went past the last pipe.
def fill_range(id_, src, dst, key):
    if src is None or dst is None or src == dst:
        return
    cols, n = grid_spec(id_)
    col = None
    for c in cols:
        if c['key'] == key:
            col = c
            break
    if col is None or col.get('ro'):
        return
    lo, hi = min(src, dst), max(src, dst)
    if id_ == 'SYSTEM':
        for i in range(hi + 1):
            while len(sheet['pipes']) <= i:
                sheet['pipes'].append(sheetmod.empty_pipe())
    else:
        if src < 0 or src >= n:
            return
        if hi >= n:
            hi = n - 1
        if lo < 0:
            lo = 0
    rows = [r for r in range(lo, hi + 1) if r != src]
    if not rows:
        return
    val = cell_get(id_, src, key)
    remember()
    for r in rows:
        cell_set(id_, r, key, val)
    after_structural()


# edit_fill_down -- CTRL+D.  The focused cell copied into the row under it.
# A drag of the corner covers more than one row; this is the one-row step.
def edit_fill_down():
    cell = focused_cell()
    if cell is None:
        return
    id_, r, key = cell
    fill_range(id_, r, r + 1, key)


#------------------------------------------------------------------------------
# Find and replace, across the grid on screen or across every grid.  Read-only
# cells (the node number a pipe already named) are not searched and not
# written.  Replace all is one undo.
#------------------------------------------------------------------------------
def current_grid_id():
    tab = toptabs.get('current') if toptabs else None
    if tab == 'NODES':
        return 'NODES'
    if tab == 'SUPPLIES':
        return 'SUPPLIES'
    if tab == 'PRESSURE DEVICES':
        d = devtabs.get('current') if devtabs else None
        if d:
            return 'DEV:' + d
    return 'SYSTEM'


def each_find_cell(code):
    ids = (['SYSTEM', 'NODES', 'SUPPLIES'] +
           ['DEV:' + t for t in sheetmod.DEVICE_TYPES]) if find_all \
        else [current_grid_id()]
    for id_ in ids:
        cols, n = grid_spec(id_)
        for r in range(n):
            for col in cols:
                if col.get('ro'):
                    continue
                code(id_, r, col['key'])


def find_hit(text):
    text = text or ''
    if not len(find_what):
        return False
    if find_case:
        return find_what in text
    return find_what.upper() in text.upper()


# replaced -- $text with every match of the find text swapped for the
# replacement.  The replacement is taken literally: a $ in it is a dollar.
def replaced(text):
    text = text or ''
    if not len(find_what):
        return text
    with_ = find_with or ''
    if find_case:
        return text.replace(find_what, with_)
    # Case-insensitive, as Perl's /i: match the letters either way.
    pat = re.compile(re.escape(find_what), re.I)
    return pat.sub(lambda m: with_, text)


def reveal_cell(id_, r, key):
    tab = 'PRESSURE DEVICES' if id_.startswith('DEV:') else id_
    if toptabs and tab in toptabs['page']:
        win.select_tab(toptabs, tab)
    m = re.match(r'^DEV:(.+)', id_)
    if m and devtabs:
        select_tab(devtabs, m.group(1))
    g = grids.get(id_)
    w = g and g['cell'].get(r, {}).get(key)
    if w is None:
        return
    w.focus_force()
    if isinstance(w, tk.Entry):
        t = w.get()
        at = (t.find(find_what) if find_case
              else t.upper().find(find_what.upper()))
        if at >= 0:
            w.selection_range(at, at + len(find_what))
        else:
            w.selection_range(0, 'end')


def find_next():
    global find_pos
    if not len(find_what):
        return False
    cells = []
    each_find_cell(lambda id_, r, k: cells.append([id_, r, k]))
    if not cells:
        return False
    start = 0
    if find_pos is not None:
        for i in range(len(cells)):
            if '\t'.join(str(x) for x in cells[i]) == find_pos:
                start = i + 1
                break
    for k in range(len(cells)):
        id_, r, key = cells[(start + k) % len(cells)]
        if not find_hit(cell_get(id_, r, key)):
            continue
        find_pos = '%s\t%s\t%s' % (id_, r, key)
        reveal_cell(id_, r, key)
        message('FOUND')
        return True
    message('NOT FOUND')
    return False


def replace_current():
    global find_pos
    if find_pos is None:
        return find_next()
    id_, r, key = (find_pos.split('\t') + ['', '', ''])[:3]
    r = int(r)
    old = cell_get(id_, r, key)
    if not find_hit(old):
        return find_next()
    new = replaced(old)
    if new != old:
        remember()
        cell_set(id_, r, key, new)
        after_structural()
        reveal_cell(id_, r, key)
    message('REPLACED')
    return True


def replace_all():
    global find_pos
    if not len(find_what):
        return 0
    jobs = []

    def scan(id_, r, key):
        old = cell_get(id_, r, key)
        new = replaced(old)
        if new != old:
            jobs.append((id_, r, key, new))

    each_find_cell(scan)
    if not jobs:
        message('NOT FOUND')
        return 0
    remember()
    for id_, r, key, new in jobs:
        cell_set(id_, r, key, new)
    after_structural()
    n = len(jobs)
    message('%d REPLACED' % n)
    return n


# open_find -- the find box.  $replace selects the replacement field; FIND
# and REPLACE open the same box.  A second call raises the one already open.
def open_find(replace=False):
    global find_box, find_what, find_with, find_case, find_all, find_pos
    if find_box is not None and find_box.winfo_exists():
        find_box.deiconify()
        find_box.lift()
        find_box.focus_set()
        return find_box
    d = tk.Toplevel(mw, background=win.C['paper'])
    d.title('FIND AND REPLACE')
    find_box = d

    def close():
        global find_box
        find_box = None
        d.destroy()

    d.protocol('WM_DELETE_WINDOW', close)
    body = tk.Frame(d, background=win.C['paper'])
    body.pack(fill='both', expand=1, padx=win.px(16), pady=win.px(14))

    def row(label, get, set_):
        f = tk.Frame(body, background=win.C['paper'])
        f.pack(fill='x', pady=win.px(3))
        tk.Label(f, text=label, font=win.UI, background=win.C['paper'],
                 foreground=win.C['muted'], width=12, anchor='w'
                 ).pack(side='left')
        e = win.flat_entry(f, get, 28)
        e.pack(side='left', fill='x', expand=1, ipady=win.px(3))
        e.bind('<KeyRelease>', lambda _e: _set_find_pos(None))
        return e

    def _set_find_pos(v):
        global find_pos
        find_pos = None

    fe = row('FIND', lambda: find_what, None)
    re_ = row('REPLACE', lambda: find_with, None)

    # Perl tied these entries straight to the scalars.  Tkinter's Entry
    # takes a textvariable, so the shared text is kept in the module's
    # globals and copied in and out on the way through.
    fe_text = tk.StringVar(value=find_what)
    re_text = tk.StringVar(value=find_with)
    fe.configure(textvariable=fe_text)
    re_.configure(textvariable=re_text)

    def fe_write(*_a):
        global find_what
        find_what = fe_text.get()

    def re_write(*_a):
        global find_with
        find_with = re_text.get()

    fe_text.trace_add('write', fe_write)
    re_text.trace_add('write', re_write)

    opts = tk.Frame(body, background=win.C['paper'])
    opts.pack(fill='x', pady=win.px([8, 4]))
    case_var = [1 if find_case else 0]
    all_var = [1 if find_all else 0]

    def case_cmd():
        global find_case
        find_case = bool(case_var[0])
        _set_find_pos(None)

    def all_cmd():
        global find_all
        find_all = bool(all_var[0])
        _set_find_pos(None)

    case = win.check_box(opts, 'MATCH CASE', case_var, case_cmd)
    case['frame'].pack(side='left', padx=win.px([0, 16]))
    all_ = win.check_box(opts, 'ALL GRIDS', all_var, all_cmd)
    all_['frame'].pack(side='left')
    btns = tk.Frame(body, background=win.C['paper'])
    btns.pack(fill='x', pady=win.px([10, 0]))
    win.flat_button(btns, 'FIND NEXT', lambda: find_next()).pack(
        side='left', padx=win.px([0, 4]))
    win.flat_button(btns, 'REPLACE', lambda: replace_current()).pack(
        side='left', padx=win.px(4))
    win.flat_button(btns, 'REPLACE ALL', lambda: replace_all(),
                    primary=True).pack(side='left', padx=win.px(4))
    win.flat_button(btns, 'CLOSE', close).pack(side='right')
    fe.bind('<Return>', lambda _e: (find_next(), 'break')[1])
    re_.bind('<Return>', lambda _e: (replace_current(), 'break')[1])
    d.bind('<Escape>', lambda _e: close())
    (re_ if replace else fe).focus_set()
    return d


#==============================================================================
# Dark mode.  The shared tabs read win.C when they build a widget, and an
# HList keeps the colours in its cell styles, so both have to be painted
# again.  White text on a blue button is not the paper colour: a foreground
# of white is left white, and a background of white becomes the dark paper.
#==============================================================================

# toggle_theme -- the menu and the toolbar.  The choice is written to this
# machine's settings, the same small file as the database folder, so the
# next time the sheet opens it is as it was left.  The text editor keeps
# its own key, EDITOR_THEME, and does not read this one.
def toggle_theme():
    apply_theme('light' if win.theme == 'dark' else 'dark')
    try:
        _settings.set('SHEET_THEME', win.theme.upper())
    except Exception:
        pass


# apply_theme -- put the named palette on screen.  'light' or 'dark'.
def apply_theme(name):
    name = 'dark' if name == 'dark' else 'light'
    if name == win.theme and mw:
        return
    frm = win.THEME_DARK if win.theme == 'dark' else win.THEME_LIGHT
    to = win.THEME_DARK if name == 'dark' else win.THEME_LIGHT
    mp = {}
    for k in list(frm):
        a = frm[k].upper()
        if a != to[k].upper():
            mp[a] = to[k]
    win.C.clear()
    win.C.update(to)
    win.theme = name
    if not mw:
        return
    paint_theme(mp, mw)
    bar = None
    try:
        bar = mw.cget('menu')
    except tk.TclError:
        bar = None
    if isinstance(bar, str):
        try:
            bar = mw.nametowidget(bar)
        except tk.TclError:
            bar = None
    if bar is not None:
        paint_theme(mp, bar)
    for draw in list(win.theme_draws):
        try:
            draw()
        except Exception:
            pass
    try:
        if _graph.GV.get('canvas'):
            _graph.graph_draw()
    except Exception:
        pass
    try:
        if restabs:
            _results.fill_results()
    except Exception:
        pass
    restyle_validation()
    try:
        if _database.DBV.get('path'):
            _database.db_header()
    except Exception:
        pass
    try:
        if _database.DBV.get('tabs'):
            _database.db_fill()
    except Exception:
        pass
    try:
        if _database.DBV.get('formrow'):
            _database.db_form()
    except Exception:
        pass
    if btn.get('THEME'):
        btn['THEME'].configure(text='LIGHT MODE' if win.theme == 'dark'
                               else 'DARK MODE')
    if view_menu is not None:
        try:
            view_menu.entryconfigure(
                0, label='LIGHT MODE' if win.theme == 'dark' else 'DARK MODE',
                background=win.C['paper'], foreground=win.C['ink'],
                activebackground=win.C['select'],
                activeforeground=win.C['ink'])
        except tk.TclError:
            pass
    mw.option_add('*Background', win.C['paper'])
    mw.option_add('*Foreground', win.C['ink'])
    mw.option_add('*Menu.background', win.C['paper'])
    mw.option_add('*Menu.foreground', win.C['ink'])
    mw.option_add('*Menu.activeBackground', win.C['select'])
    mw.option_add('*Menu.activeForeground', win.C['ink'])
    update_actions()
    if validation is not None:
        mark_faults()


# paint_theme -- one widget, its children, and the menus hanging off it.
# A colour that belongs to the palette being left is swapped for the same
# role in the palette being entered.  Anything else (white text on a blue
# button, a system colour) is left.
def paint_theme(mp, w, seen=None):
    if seen is None:
        seen = {}
    if w is None or not w.winfo_exists():
        return
    try:
        pathname = str(w.winfo_name())
        if w is not mw:
            pathname = w.winfo_pathname(w.winfo_id())
    except tk.TclError:
        return
    if pathname in seen:
        return
    seen[pathname] = 1
    opts = ('background', 'foreground', 'activebackground',
            'activeforeground', 'highlightbackground', 'highlightcolor',
            'insertbackground', 'selectbackground', 'selectforeground',
            'disabledforeground', 'troughcolor', 'readonlybackground')
    fg = ('foreground', 'activeforeground', 'selectforeground',
          'disabledforeground', 'insertbackground', 'highlightcolor')
    for opt in opts:
        try:
            v = w.cget(opt)
        except tk.TclError:
            continue
        if v is None or not len(str(v)):
            continue
        try:
            hexv = str(v).upper()
        except Exception:
            continue
        # White as a foreground is the text on a blue button, and the tick
        # in a check box.  White as a background is the paper.
        if hexv == '#FFFFFF' and opt in fg:
            continue
        n = mp.get(hexv)
        if n is None:
            continue
        try:
            w.configure(**{opt: n})
        except tk.TclError:
            continue
    if isinstance(w, tk.Menu):
        try:
            w.configure(background=win.C['paper'],
                        foreground=win.C['ink'],
                        activebackground=win.C['select'],
                        activeforeground=win.C['ink'])
        except tk.TclError:
            pass
        try:
            end = w.index('end')
        except tk.TclError:
            end = None
        if end is not None and end != 'none':
            for i in range(end + 1):
                try:
                    if w.type(i) == 'separator':
                        continue
                except tk.TclError:
                    pass
                try:
                    w.entryconfigure(i, background=win.C['paper'],
                                     foreground=win.C['ink'],
                                     activebackground=win.C['select'],
                                     activeforeground=win.C['ink'])
                except tk.TclError:
                    pass
                try:
                    sub = w.entrycget(i, '-menu')
                except tk.TclError:
                    sub = None
                if sub:
                    try:
                        sub = mw.nametowidget(str(sub))
                    except tk.TclError:
                        sub = None
                    if sub is not None:
                        paint_theme(mp, sub, seen)
    if isinstance(w, tk.Canvas):
        try:
            ids = w.find_all()
        except tk.TclError:
            ids = []
        for i in ids:
            for opt in ('fill', 'outline'):
                try:
                    v = w.itemcget(i, opt)
                except tk.TclError:
                    continue
                if v is None or not len(v) or v == 'black':
                    continue
                if str(v).upper() == '#FFFFFF':
                    continue
                n = mp.get(str(v).upper())
                if n is None:
                    continue
                try:
                    w.itemconfigure(i, **{opt: n})
                except tk.TclError:
                    continue
    if isinstance(w, tk.Text):
        try:
            tags = w.tag_names()
        except tk.TclError:
            tags = []
        for tag in tags:
            if tag == 'sel':
                continue
            for opt in ('foreground', 'background'):
                try:
                    v = w.tag_cget(tag, opt)
                except tk.TclError:
                    continue
                if v is None or not len(v):
                    continue
                if str(v).upper() == '#FFFFFF':
                    continue
                n = mp.get(str(v).upper())
                if n is None:
                    continue
                try:
                    w.tag_configure(tag, **{opt: n})
                except tk.TclError:
                    continue
    for c in list(w.winfo_children()):
        paint_theme(mp, c, seen)


# restyle_validation -- the VALIDATION table keeps its cell styles from when
# it was built.  New styles, then the rows again, so a fault reads in the
# palette now on screen.  The result tables are rebuilt by fill_results.
def restyle_validation():
    # The VALIDATION table keeps the colours it was built with: its rows
    # are built again in the palette now on screen.
    if not _results.vtable:
        return
    fill_validation()


#==============================================================================
# Undo.  Each change snapshots the grids first.  The PROJECT tab is not part
# of it: that tab's fields are the settings, and undo there is the editor's
# habit of leaving them to the form.
#==============================================================================
def snapshot():
    return copy.deepcopy({
        'pipes': sheet['pipes'], 'nodes': sheet['nodes'],
        'devices': sheet['devices'], 'notes': sheet['notes'],
        'extras': sheet['extras'], 'seq': sheet['seq']})


def remember():
    global restoring
    if restoring:
        return
    undo_stack.append(snapshot())
    if len(undo_stack) > 40:
        del undo_stack[0:len(undo_stack) - 40]
    del redo_stack[:]


def restore_snap(s):
    global restoring
    if s is None:
        return
    restoring = True
    for k in ('pipes', 'nodes', 'devices', 'notes', 'extras', 'seq'):
        sheet[k] = copy.deepcopy(s[k])
    restoring = False
    refresh_all()
    sheet_changed()


def edit_undo():
    if not undo_stack:
        return
    redo_stack.append(snapshot())
    restore_snap(undo_stack.pop())


def edit_redo():
    if not redo_stack:
        return
    undo_stack.append(snapshot())
    restore_snap(redo_stack.pop())


#==============================================================================
# VALIDATE and CALCULATE.  Both go through hardycross.editor, so the sheet
# cannot call a model good that the solve would refuse, and it cannot solve
# a different way.
#==============================================================================
def full_text():
    return sheetmod.to_text(sheet)


def document():
    full_text()
    return {'settings': sheet['settings'], 'network': sheet['network']}


# The results tab's click handler knows a text line and a PROJECT field.
# A sheet fault is a cell, so this program handles the click itself.
def go_to_fault(row):
    if validation is None or row is None:
        return
    try:
        row = int(row)
    except (TypeError, ValueError):
        return
    if not validation['items'] or row >= len(validation['items']):
        return
    it = validation['items'][row]
    if it is None:
        return
    if it.get('tab') and it['tab'] == 'PROJECT':
        return _database.show_field(it.get('field'))
    loc = it.get('loc') or sheetmod.locate(sheet, it)
    if loc:
        go_to_cell(loc)


def go_to_line(line, start=None, end=None):
    if line is None:
        return
    loc = sheet['map'].get(line) or sheetmod.locate(sheet, {'line': line})
    if loc:
        go_to_cell(loc)


def go_to_cell(loc):
    if loc is None:
        return
    if (loc.get('tab') or '') == 'PROJECT' and loc.get('field'):
        return _database.show_field(loc['field'])
    tab = loc.get('tab')
    if not tab:
        return
    if toptabs and tab in toptabs['page']:
        win.select_tab(toptabs, tab)
    if tab == 'PRESSURE DEVICES' and loc.get('device'):
        select_tab(devtabs, loc['device'])
        tab = 'DEV:' + loc['device']
    g = grids.get(tab)
    if g is None:
        return
    w = g['cell'].get(loc.get('row'), {}).get(loc.get('col'))
    if w is None:
        return
    # focusForce, not focus: a cell drawn in a canvas does not take the
    # ordinary focus.
    w.focus_force()
    try:
        if w.cget('highlightbackground') is not None:
            w.configure(highlightbackground=win.C['error'])
    except tk.TclError:
        pass


def clear_faults():
    for w in list(fault_marks):
        if w.winfo_exists():
            try:
                w.configure(highlightbackground=win.C['line'])
            except tk.TclError:
                pass
    del fault_marks[:]


def mark_faults():
    clear_faults()
    if validation is None:
        return
    for it in validation['items']:
        loc = it.get('loc') or sheetmod.locate(sheet, it)
        if loc is None:
            continue
        tab = loc.get('tab')
        if not tab:
            continue
        if tab == 'PRESSURE DEVICES' and loc.get('device'):
            tab = 'DEV:' + loc['device']
        g = grids.get(tab)
        if g is None:
            continue
        w = g['cell'].get(loc.get('row'), {}).get(loc.get('col'))
        if w is None:
            continue
        try:
            w.cget('highlightbackground')
        except tk.TclError:
            continue
        try:
            w.configure(highlightbackground=win.C['error'],
                        highlightthickness=1)
            fault_marks.append(w)
        except tk.TclError:
            continue


def validate():
    global validation, valid_text, solved
    full = full_text()
    v = editor.validate(document())
    v['items'] = list(v.get('items') or [])
    v['items'].extend(sheetmod.problems(sheet))
    v['ok'] = 0 if v['items'] else 1
    validation = dict(v)
    validation['text'] = full
    valid_text = full if v['ok'] else None
    if not v['ok']:
        solved = None
    _publish()                 # the VALIDATION table is drawn from this
    fill_validation()
    if restabs:
        win.select_tab(restabs, 'VALIDATION')
    mark_faults()
    update_actions()
    n = len(v['items'])
    message('VALID - NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE'
            if v['ok']
            else ('%d PROBLEM%s FOUND - SEE VALIDATION BELOW; CLICK ONE TO '
                  'GO TO IT' % (n, '' if n == 1 else 'S')),
            not v['ok'])
    return v


def calculate():
    global solved, valid_text
    full = full_text()
    if valid_text is None or valid_text != full:
        message('VALIDATE THE INPUTS FIRST (F4): CALCULATE RUNS ONLY ON A '
                'MODEL THAT HAS PASSED VALIDATION', True)
        return {'ok': 0, 'not_validated': 1}
    t0 = int(time.time())      # whole seconds, as Perl's time
    turn = [0]
    shown = [0.0]

    def progress(what):
        now = time.time()
        if now - shown[0] < 0.15:
            return
        shown[0] = now
        bar = ('|', '/', '-', '\\')[turn[0] % 4]
        message('%s COMPUTING - %s - %d S' % (bar, what,
                                              int(time.time()) - t0))
        mw.update()
        turn[0] = turn[0] + 1

    _busy()
    try:
        progress('CALCULATING')
        r = editor.doc_solve(document(), path, progress=progress)
    finally:
        _unbusy()
    if not r or not r.get('ok'):
        solved = None
        _publish()
        fill_results()
        fill_report('THE MODEL WAS NOT CALCULATED\n\n%s\n'
                    % (r.get('error') if r else ''))
        update_actions()
        message(r.get('error', ''), True)
        return r
    # Auto sizing writes each chosen size after its pipe as a comment.  Read
    # the network back so those comments sit on the pipe rows.  Comments do
    # not change the model, so it is still the one that passed VALIDATE.
    if r.get('network') is not None and r['network'] != sheet['network']:
        text = editor.join_file(sheet['settings'], r['network'])[0]
        got = sheetmod.read_text(text)
        for k in ('pipes', 'nodes', 'devices', 'notes', 'extras', 'seq'):
            sheet[k] = got[k]
        refresh_all()
        full = full_text()
        valid_text = full
    solved = {'net': r['net'], 'converged': r['converged'], 'text': full}
    _publish()
    fill_results()
    fill_report(r['report'])
    win.select_tab(restabs, 'PIPES')
    update_actions()
    message('CALCULATED - CONVERGED' if r['converged']
           else 'CALCULATED - DID NOT CONVERGE: THE RESULTS MUST NOT BE USED',
           not r['converged'])
    return r


# Perl/Tk's $mw->Busy(-recurse => 1) and Unbusy: the watch pointer, and
# keys and clicks swallowed while the calculation runs (hardycross.win).
def _busy():
    win._busy()


def _unbusy():
    win._unbusy()


def fill_report(text):
    if report is None:
        return
    report.configure(state='normal')
    report.delete('1.0', 'end')
    report.insert('1.0', text)
    report.configure(state='disabled')


# recolour / update_status / update_actions / set_title -- the names the
# PROJECT tab and the DATABASE tab call.  In the editor, recolour paints the
# command lines; here the units in the column headings are what a setting
# changes, so the grids are painted again.
def recolour():
    refresh_all()


def update_status():
    if statusbar is None:
        return
    np = len([p for p in sheet['pipes']
              if not sheetmod.pipe_is_blank(p) and
              len(sheetmod.trim(p.get('pipe') or ''))])
    nn = len(sheetmod.node_rows(sheet))
    ns = len(sheetmod.supply_rows(sheet))
    nd = 0
    for t in sheetmod.DEVICE_TYPES:
        nd = nd + len(sheetmod.device_rows(sheet, t))
    statusbar.configure(text='%d PIPE%s, %d NODE%s, %d SUPPL%s, '
                             '%d PRESSURE DEVICE%s' %
                             (np, '' if np == 1 else 'S',
                              nn, '' if nn == 1 else 'S',
                              ns, 'Y' if ns == 1 else 'IES',
                              nd, '' if nd == 1 else 'S'))


def sheet_changed():
    clear_faults()
    set_title()
    update_actions()
    update_status()


def update_actions():
    if btn.get('CALCULATE') is None:
        return
    full = ''
    try:
        full = full_text()
    except Exception:
        pass
    valid = valid_text is not None and valid_text == full
    if valid:
        btn['CALCULATE'].configure(state='normal',
                                   background=win.C['accent'],
                                   highlightbackground=win.C['accent'])
    else:
        btn['CALCULATE'].configure(state='disabled',
                                   background=win.C['paper'],
                                   highlightbackground=win.C['line'])
    if solved is not None and solved['text'] == full:
        if solved['converged']:
            text, fg, bg = 'CALCULATED', win.C['accent'], win.C['accent_bg']
        else:
            text, fg, bg = 'DID NOT CONVERGE', win.C['error'], \
                win.C['error_bg']
    elif valid:
        text, fg, bg = 'VALID - READY TO CALCULATE', win.C['accent'], \
            win.C['accent_bg']
    elif validation is not None and validation.get('text') == full:
        n = len(validation['items'])
        text, fg, bg = ('%d PROBLEM%s - SEE VALIDATION'
                        % (n, '' if n == 1 else 'S'),
                        win.C['error'], win.C['error_bg'])
    else:
        text, fg, bg = 'NOT VALIDATED', win.C['muted'], win.C['hover']
    pill.configure(text=text, foreground=fg, background=bg)


def set_title():
    if mw is None:
        return
    name = path or 'UNTITLED.PHC'
    name = re.sub(r'.*[/\\]', '', name)
    star = ''
    try:
        if saved_text != '' and full_text() != saved_text:
            star = ' *'
    except Exception:
        pass
    mw.title('PHCP SHEET - ' + name.upper() + star)


def message(text, bad=False):
    if statusbar is None:
        return
    statusbar.configure(text=(text or '').upper(),
                        foreground=win.C['error'] if bad else win.C['ink'])


def calculate_enabled():
    return btn.get('CALCULATE') is not None and \
        btn['CALCULATE'].cget('state') == 'normal'


def state_text():
    return pill.cget('text') if pill is not None else ''


#==============================================================================
# Files.  .phc only, the one file type the engine reads.
#==============================================================================
def modified():
    return full_text() != saved_text


def ok_to_discard():
    if not _database.db_ok_to_leave():
        return False
    if not _graph.graph_ok_to_discard():
        return False
    if not modified():
        return True
    a = messagebox.askyesno(
        'UNSAVED CHANGES',
        'THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?',
        icon='warning', parent=mw)
    return bool(a)


def adopt(got):
    global validation, valid_text, solved, saved_text, system_pad
    _project.load_settings(got['settings'])
    for k in ('pipes', 'nodes', 'devices', 'notes', 'extras', 'seq'):
        sheet[k] = got[k]
    del undo_stack[:]
    del redo_stack[:]
    system_pad = BLANKS
    validation = None
    valid_text = None
    solved = None
    _publish()                 # the results and VALIDATION are drawn from these
    refresh_all()
    if restabs:
        fill_results()
    if vtable:
        fill_validation()
    saved_text = full_text()
    sheet_changed()


def file_new():
    if not ok_to_discard():
        return
    global path
    path = None
    adopt(sheetmod.new_sheet())
    win.select_tab(toptabs, 'SYSTEM')


def file_open(f=None):
    global path
    if not ok_to_discard():
        return
    if f is None:
        f = filedialog.askopenfilename(
            parent=mw,
            filetypes=[('PHCP MODEL', '.phc'), ('ALL FILES', '*')])
    if f is None or not len(f):
        return
    open_path(f)


def open_path(f):
    global path
    try:
        r = editor.load_file(f)
    except Exception as e:
        message(str(getattr(e, 'msg', e)), True)
        return
    if r is None:
        return
    try:
        got = sheetmod.read_text(r['text'])
    except Exception as e:
        message(str(getattr(e, 'msg', e)), True)
        return
    path = r['path']
    win.path = path
    adopt(got)
    win.select_tab(toptabs, 'SYSTEM')
    message('OPENED %s' % path)
    return r


def file_save():
    if path is None:
        return file_save_as()
    write_file(path)


def file_save_as(f=None):
    global path
    if f is None:
        f = filedialog.asksaveasfilename(
            parent=mw, defaultextension='.phc',
            initialfile=re.sub(r'.*[/\\]', '', path or 'UNTITLED.PHC'),
            filetypes=[('PHCP MODEL', '.phc')])
    if f is None or not len(f):
        return
    if write_file(f):
        path = f
        win.path = path
    set_title()


def write_file(f):
    text = full_text()
    if not text.endswith('\n'):
        text = text + '\n'
    try:
        # Text mode, as the Perl's open '>': CRLF on Windows, LF elsewhere.
        with open(f, 'w', encoding=editor.file_encoding(text), errors='surrogateescape') as fh:
            fh.write(text)
    except OSError as e:
        # Perl's $!: the reason alone, without errno or the path again
        message('CANNOT WRITE %s: %s' % (f, e.strerror or e), True)
        return False
    global saved_text
    saved_text = full_text()
    message('SAVED %s' % f)
    set_title()
    return True


def file_report(out=None):
    if solved is None or solved['text'] != full_text():
        if not validate().get('ok'):
            return
        r = calculate()
        if not r or not r.get('ok'):
            return
    if out is None:
        base = re.sub(r'\.phc\Z', '', re.sub(r'.*[/\\]', '',
                                             path or 'UNTITLED.PHC'),
                      flags=re.I)
        out = filedialog.asksaveasfilename(
            parent=mw, defaultextension='.pdf',
            initialfile=base + '_REPORT.PDF',
            filetypes=[('PDF REPORT', '.pdf'), ('TEXT REPORT', '.txt')])
    if out is None or not len(out):
        return
    err = ''
    try:
        ok = bool(editor.write_report_file(solved['net'], solved['converged'],
                                           path or 'UNTITLED.PHC', out))
    except OSError as e:
        ok = False
        err = win.cannot_write(e, out)
    except Exception as e:
        ok = False
        err = str(getattr(e, 'msg', e))
    if ok:
        message('REPORT WRITTEN TO %s' % out)
    else:
        message('REPORT NOT WRITTEN: %s' % err, True)
    return ok


def file_quit():
    if not ok_to_discard():
        return
    mw.destroy()


# grid_cell -- one cell's widget, for the window test.
def grid_cell(id_, r, key):
    g = grids.get(id_)
    if not g:
        return None
    return g['cell'].get(r, {}).get(key)


def grid_text(id_, r, key):
    w = grid_cell(id_, r, key)
    if w is None:
        return ''
    if isinstance(w, tk.Entry):
        return w.get()
    return w.cget('text')


#==============================================================================
# The results tabs.  These are the editor's own tables, taking the same
# vtable/report globals, so the click on a validation row goes through the
# sheet's go_to_fault rather than the editor's line handler.
#==============================================================================
def build_results(page):
    global restabs, vtable, report
    _results.build_results(page)
    # The results module keeps its own module-level state (vtable, restabs,
    # report); the sheet publishes it into hardycross.win's so the rest of
    # the window -- the shared tabs and apply_theme -- sees the same tables.
    restabs = _results.restabs
    vtable = _results.vtable
    report = win.report


def fill_validation():
    _results.fill_validation()
    global vtable
    vtable = _results.vtable


def fill_results():
    _results.fill_results()


def main(argv=None):
    argv = list(sys.argv[1:]) if argv is None else list(argv)
    build_window()
    if argv:
        open_path(argv[0])
    mw.mainloop()


# btn_text -- the toolbar's VIEW button label, for the window test.
def btn_text():
    return btn['THEME'].cget('text') if btn.get('THEME') else ''
