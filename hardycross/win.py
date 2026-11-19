"""win -- the PHCP editor window: a port of phcp_editor.pl.

This module holds the frame of the window and the NETWORK tab: colours
and fonts, the dark palette, widget helpers (flat buttons, tabs, check
boxes, drop-downs), build_window, colouring, line numbers, the lists,
the status bar, the command strip, proposals, the pick list, VALIDATE
and CALCULATE (F4, F5), the files and the theme.  Each other tab is a
module of its own in hardycross/window/, sharing this module's globals
and helpers (``from hardycross import win``).

THIS MODULE IS ONLY THE WINDOW.  Every decision -- is this line good,
what is the next line likely to be, what goes in a pick list or a
table, what is wrong and why -- is made by hardycross.editor, which
has no Tk in it and is tested headless by tools/test_editor.py.  What
is here is drawing, keys and files.  tools/test_editor_window.py
drives this window under a virtual display; it imports this module
without starting the event loop and calls the handlers directly.

Perl/Tk's TextUndo records every insert and delete; the grey proposal
was put in and taken out with plain Tk::Text insert and delete, which
TextUndo does not record.  Tkinter's Text has no unrecorded insert --
``configure(undo=False)`` clears the whole undo stack -- so the
proposal insert is recorded behind an explicit separator, which makes
it one undo item on its own: discarding is one ``edit_undo()`` (the
redo it leaves is cleared by the next recorded edit, so a discarded
proposal never comes back), and accepting is that undo followed by a
recorded insert of the text, so Ctrl+Z removes an accepted line like
any other.
"""

import os
import sys
import time
import tkinter as tk
from tkinter import filedialog, messagebox

from hardycross import editor
from hardycross import phc
from hardycross import results as _results_mod
from hardycross import settings as _settings

#==============================================================================
# Colours.
#
# The same flat palette as the spreadsheet and the isometric drawing:
# white paper, a grey band for the toolbar and the headings, one blue,
# and a soft shadow under a bar.  Blue marks a command word, the
# current field, the active tab and CALCULATE; red marks what is wrong.
# Every colour is named once here.  Dark mode is the same roles,
# darker.  C is the palette on screen.  EDITOR_THEME remembers the
# choice.  The spreadsheet uses SHEET_THEME and the isometric drawing
# uses ISO_THEME, so the three windows do not follow each other.
#==============================================================================
THEME_LIGHT = {
    'paper': '#FFFFFF',      # editor, tables, form fields
    'panel': '#F4F6F9',      # toolbar, status bar, headings, line numbers
    'line': '#E2E6EE',       # hairlines and field outlines
    'hover': '#E8F0FA',      # a button or a row under the pointer
    'ink': '#1C1F24',        # text
    'muted': '#5C6570',      # labels, inactive tabs, comments
    'faint': '#8A929E',      # line numbers, disabled text
    'accent': '#1967D2',     # the highlight blue
    'accent_dk': '#1558B0',  # the highlight blue, pressed
    'accent_bg': '#E8F0FE',  # a pale blue behind a highlight
    'select': '#D3E3FD',     # selection
    'curline': '#EEF2F7',    # the cursor's line
    'number': '#185ABC',     # numbers in the editor
    'error': '#C5221F',      # what is wrong
    'error_bg': '#FCE8E6',   # behind a line in error
    'fault_bg': '#F6D4D2',   # behind the field validation found at fault
    'warn': '#8A5A00',       # a warning
    'proposal': '#9AA0A6',   # the greyed proposed line
    'sash': '#E4E7EB',       # the dividers between panes
    'scroll': '#C5CDD8',     # the scrollbar thumb
    'scroll_on': '#A8B2C0',   # the scrollbar thumb under the pointer
    'shadow': '#D5DBE3',     # the soft edge under a bar
}
THEME_DARK = {
    'paper': '#1F232B',
    'panel': '#282D37',
    'line': '#3A4150',
    'hover': '#323846',
    'ink': '#E8EAED',
    'muted': '#A8B0BD',
    'faint': '#7C8594',
    'accent': '#3D7AEC',
    'accent_dk': '#2F64C4',
    'accent_bg': '#1A2C4C',
    'select': '#2C4468',
    'curline': '#252A33',
    'number': '#A8C7FF',
    'error': '#FF8A80',
    'error_bg': '#3E2628',
    'fault_bg': '#4A3032',
    'warn': '#E7B15A',
    'proposal': '#8E97A6',
    'sash': '#2A303A',
    'scroll': '#555E6E',
    'scroll_on': '#6A7486',
    'shadow': '#14171C',
}
theme = 'light'
C = dict(THEME_LIGHT)
# Closures that redraw a canvas from C (the check boxes).  apply_theme
# calls them after the palette has changed, so the tick is drawn again.
theme_draws = []
view_menu = None            # the VIEW menu, so its label can follow the palette

# The ordinary pointer.  X11's "arrow" points up and to the right, so it
# is left_ptr there; Windows calls the same pointer "arrow".
POINTER = 'arrow' if sys.platform == 'win32' else 'left_ptr'

# Fonts are chosen when the window is built, the same way the
# spreadsheet chooses them: Inter for the chrome and JetBrains Mono for
# the model, when the machine has them.  Otherwise Segoe UI and
# Consolas on Windows, DejaVu on a plain Linux install.
MONO = MONO_B = MONO_I = UI = UI_B = UI_S = UI_S_N = None


def pick_fonts():
    global MONO, MONO_B, MONO_I, UI, UI_B, UI_S, UI_S_N
    have = set(f.lower() for f in mw.tk.call('font', 'families'))

    def first_of(cands, fallback):
        for c in cands:
            if c.lower() in have:
                return c
        return fallback

    mono = first_of(['JetBrains Mono', 'Cascadia Mono', 'Consolas',
                    'Roboto Mono', 'Source Code Pro', 'DejaVu Sans Mono',
                    'Liberation Mono', 'Menlo', 'Courier New'], 'Courier')
    ui = first_of(['Inter', 'Segoe UI', 'Roboto', 'Source Sans 3',
                   'Noto Sans', 'Cantarell', 'Liberation Sans',
                   'DejaVu Sans', 'Helvetica Neue', 'Arial'], 'Helvetica')
    MONO = (mono, 10)
    MONO_B = (mono, 10, 'bold')
    MONO_I = (mono, 10, 'italic')
    UI = (ui, 10)
    UI_B = (ui, 10, 'bold')
    UI_S = (ui, 9, 'bold')
    UI_S_N = (ui, 9)


#==============================================================================
# Crisp on a high-resolution screen.
#
# Windows draws a program that has not declared itself DPI-aware at 96
# dpi and then stretches the bitmap -- at 150 % scaling everything
# comes out soft.  Tk does not declare it, so dpi_aware does, before
# the first window is made.  Tk then measures the real resolution:
# fonts, given in points, come out at the right size and sharp.
# Sizes given in pixels -- padding, the divider and scrollbar widths,
# the window itself -- are passed through px(), which multiplies them
# by the screen's scale (1.5 at 150 %), so the layout keeps its
# proportions.
#==============================================================================
SCALE = 1


def px(v):
    if isinstance(v, (list, tuple)):
        return [px(x) for x in v]
    return int(v * SCALE + 0.5)


def dpi_aware():
    if sys.platform != 'win32':
        return
    try:
        import ctypes
        try:
            shcore = ctypes.windll.shcore
            shcore.SetProcessDpiAwareness(1)
        except Exception:
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass


# The window's state.  One editor window per process, so plain module
# globals, each named for what it holds.
mw = None
ed = None
gutter = None
report = None
statusbar = None
strip = None
pill = None
vtable = None                    # the VALIDATION table (results tab)
LIST = {}                        # ERRORS, WARNINGS, NODES: listbox
list_lines = {}                  #   the entries behind them
list_head = {}                   #   their headings
TABLE = {}                       # PIPES, NODES, OUTLETS: results tables
toptabs = None                   # NETWORK / PROJECT / GRAPH / QUICK TOOLS /
restabs = None                   #   ORIFICE PLATE / DATABASE; the results tabs
btn = {}                         # toolbar buttons
form = {}                        # PROJECT tab fields (window.project)
checks = {}                      # HIDE boxes (window.results)
pipe_show = {}                   # the pipe columns shown, by key
# one-element lists: check_box flips them in place (the Perl shared
# scalars between the window and the results tab)
hide_pipes = [0]
hide_nodes = [0]
path = None                      # the file being edited, or None
settings = editor.new_settings()  # what the PROJECT tab holds
solved = None                    # { net, converged, text } from the last calculation
validation = None                # { ok, items, text } from the last VALIDATE
valid_text = None                # the whole text as it last passed VALIDATE
saved_text = ''                  # the whole text as last opened or saved
recolour_job = None              # the pending delayed re-check
prop = {'active': 0}             # the proposal on show, if any
notice = None                    # [ text, bad, where ]: a message that stays
gutter_lines = 0                 # how many numbers the gutter holds


class _After:
    """mw.after's id, with a cancel -- the test cancels the delayed
    re-check so it can flush synchronously."""

    def __init__(self, id_):
        self.id = id_

    def cancel(self):
        try:
            mw.after_cancel(self.id)
        except tk.TclError:
            pass


#==============================================================================
# Widget helpers.  Tk draws bevels by default; each helper sets a flat
# relief, no border, and a one-pixel outline in the rule colour where
# one is wanted.
#==============================================================================

def rule(parent, fill, **pack):
    # A one-pixel line, horizontal ('x') or vertical ('y').
    if fill == 'x':
        f = tk.Frame(parent, background=C['line'], height=1)
    else:
        f = tk.Frame(parent, background=C['line'], width=1)
    kw = {'fill': fill, 'side': 'top'}
    kw.update(pack)
    f.pack(**kw)
    return f


def flat_button(parent, text, cmd, primary=False):
    # A flat button.  The primary one (CALCULATE) is solid blue.  A
    # filled button has no second edge: the outline is the same blue as
    # the face.  The others sit on the grey bar as a white chip with a
    # hairline, the same chips as the spreadsheet's toolbar.
    return tk.Button(
        parent, text=text, command=cmd, font=UI_B, relief='flat',
        borderwidth=0, highlightthickness=1,
        highlightbackground=C['accent'] if primary else C['line'],
        highlightcolor=C['accent'],
        background=C['accent'] if primary else C['paper'],
        foreground='#FFFFFF' if primary else C['ink'],
        activebackground=C['accent_dk'] if primary else C['hover'],
        activeforeground='#FFFFFF' if primary else C['ink'],
        disabledforeground=C['faint'], padx=px(16), pady=px(6),
        cursor='hand2')


#------------------------------------------------------------------------------
# make_tabs -- a row of flat tabs over a set of pages.  The active tab is
# in ink with a blue bar under it; the others are grey.  Returns
# { bar, page => { name => frame }, current, ... }; the bar has room on
# its right for the caller to pack more into.
#------------------------------------------------------------------------------
def make_tabs(parent, names, on_select=None):
    t = {'names': list(names), 'page': {}, 'label': {}, 'on_select': on_select}
    t['bar'] = tk.Frame(parent, background=C['paper'])
    t['bar'].pack(side='top', fill='x')
    rule(parent, 'x', side='top')
    body = tk.Frame(parent, background=C['paper'])
    body.pack(side='top', fill='both', expand=1)
    for n in names:
        f = tk.Frame(t['bar'], background=C['paper'])
        f.pack(side='left')
        l = tk.Label(f, text=n, font=UI_B, background=C['paper'],
                     foreground=C['muted'], padx=px(14), pady=px(8),
                     cursor='hand2')
        l.pack(side='top')
        u = tk.Frame(f, height=px(3), background=C['paper'])
        u.pack(side='top', fill='x')
        t['label'][n] = (l, u)
        l.bind('<ButtonRelease-1>', lambda e, n=n: select_tab(t, n))
        l.bind('<Enter>', lambda e, l=l: l.configure(foreground=C['ink']))
        l.bind('<Leave>', lambda e, l=l, n=n, t=t: l.configure(
            foreground=C['ink'] if t.get('current') == n else C['muted']))
        t['page'][n] = tk.Frame(body, background=C['paper'])
    select_tab(t, names[0])
    return t


def select_tab(t, n):
    if t.get('current'):
        t['page'][t['current']].pack_forget()
    t['current'] = n
    t['page'][n].pack(fill='both', expand=1)
    for m in t['names']:
        l, u = t['label'][m]
        l.configure(foreground=C['ink'] if m == n else C['muted'])
        u.configure(background=C['accent'] if m == n else C['paper'])
    if t.get('on_select'):
        t['on_select'](n)


#------------------------------------------------------------------------------
# check_box -- a flat check box drawn on a canvas: an outlined square,
# filled blue with a white tick when on.  (Tk's own indicator is
# bevelled.)  var is a one-element list the caller keeps.
#------------------------------------------------------------------------------
def check_box(parent, text, var, cmd=None):
    f = tk.Frame(parent, background=C['paper'], cursor='hand2')
    b = px(14)
    c = tk.Canvas(f, width=b, height=b, background=C['paper'],
                  highlightthickness=0, borderwidth=0)
    c.pack(side='left', padx=px([0, 6]))
    l = tk.Label(f, text=text, font=UI, background=C['paper'],
                 foreground=C['ink'])
    l.pack(side='left')
    n = tk.Label(f, text='', font=UI, background=C['paper'],
                 foreground=C['muted'])
    n.pack(side='left', padx=px([4, 0]))

    def draw():
        c.delete('all')
        if var[0]:
            c.create_rectangle(1, 1, b - 1, b - 1, fill=C['accent'],
                               outline=C['accent'])
            c.create_line(*px([4, 7, 6, 10, 11, 4]), fill='#FFFFFF',
                          width=px(2))
        else:
            c.create_rectangle(1, 1, b - 1, b - 1, fill=C['paper'],
                               outline=C['faint'])

    def flip(e=None):
        var[0] = 0 if var[0] else 1
        draw()
        if cmd:
            cmd()

    for w in (f, c, l, n):
        w.bind('<ButtonRelease-1>', flip)
    theme_draws.append(draw)
    draw()
    return {'frame': f, 'draw': draw, 'label': l, 'count': n}


# drop_down -- a flat choice: the value, a small arrow, and a plain
# menu.  The default, if given, is marked in the menu.  var is a
# one-element list; dd_refresh holds the redraws for load_settings.
dd_refresh = []


def drop_down(parent, var, choices, cmd, default=None):
    def show():
        v = var[0] or ''
        return '%-9s %s' % (v if v else 'DEFAULT', '\u25BE')

    mb = tk.Menubutton(parent, text=show(), font=MONO, relief='flat',
                       borderwidth=0, highlightthickness=1,
                       highlightbackground=C['line'], background=C['paper'],
                       activebackground=C['hover'], foreground=C['ink'],
                       anchor='w', width=11, padx=px(6), pady=px(3),
                       indicatoron=0, cursor='hand2')
    m = tk.Menu(mb, tearoff=0, font=MONO, relief='flat', borderwidth=1,
                activeborderwidth=0, background=C['paper'],
                foreground=C['ink'], activebackground=C['select'],
                activeforeground=C['ink'])

    def choose(v):
        var[0] = v
        mb.configure(text=show())
        if cmd:
            cmd()

    for v in choices:
        label = 'DEFAULT' if v == '' else v
        if default is not None and v == default:
            label += '   (DEFAULT)'
        m.add_command(label=label, command=lambda v=v: choose(v))
    mb.configure(menu=m)
    dd_refresh.append(lambda: mb.configure(text=show()))
    return mb


# flat_entry -- a one-line text field with a one-pixel outline, blue
# when focused.
def flat_entry(parent, var, width=30, **pack):
    e = tk.Entry(parent, textvariable=var, font=MONO, width=width,
                 relief='flat', borderwidth=0, highlightthickness=1,
                 highlightbackground=C['line'], highlightcolor=C['accent'],
                 background=C['paper'], foreground=C['ink'],
                 insertbackground=C['ink'], selectbackground=C['select'],
                 selectforeground=C['ink'])
    if pack:
        e.pack(**pack)
    return e


# divider -- a pane divider the user can drag: a 6-pixel light grey
# band (a one-pixel line could not be grabbed), the resize pointer
# over it, and the panes redrawn live while it moves.
def divider(parent, orient):
    return tk.PanedWindow(parent, orient=orient, background=C['sash'],
                          sashwidth=px(6), sashpad=0, borderwidth=0,
                          showhandle=0, handlesize=0, sashrelief='flat',
                          opaqueresize=1,
                          sashcursor='sb_v_double_arrow' if orient == 'vertical'
                          else 'sb_h_double_arrow')


# flat_scrollbar -- a thin grey scrollbar with no bevels.
def flat_scrollbar(parent, orient, **pack):
    s = tk.Scrollbar(parent, orient=orient, relief='flat', borderwidth=0,
                     elementborderwidth=0, width=px(11),
                     troughcolor=C['panel'], background=C['scroll'],
                     activebackground=C['scroll_on'], highlightthickness=0)
    if pack:
        s.pack(**pack)
    return s


#==============================================================================
# set_icon -- the PHCP icon on the window and the taskbar, in place of
# Tk's.
#
# A blue tile with a two-loop pipe network and a red sprinkler at the
# far node.  The blue is the editor's accent and the sprinkler is the
# error red.  Each size in the icon is drawn for that size, so both
# loops are still there at 16.  The same picture is data/phcp.ico,
# which build_windows.bat gives the .exe files.
#==============================================================================
ICON_PNG = {
    16: (
         'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAnklEQVR42mNkqN/PIvFCuIWR'
         'gSGdgYFBgIE48OE/A8PMFxJva2CayxlIAwKMDAzlEi+EGZigNpMFGBkY0lmQnf1shi5RGqUy'
         'LsNdwsRAIWDCZQOSLRh8ggZQ7IIRZgCjZPql/6SmA+S0wEKqjceUFSCW3X3AIJVxmYGFgYHh'
         'Ayw14oprPC78wPKfgWEmsZlJKuMyw7O7D+BsiF4KszMAfKA10dIzwHIAAAAASUVORK5CYII='
    ),
    32: (
         'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACI0lEQVR42u2XzWsTURTFf28y'
         '9oOosS3BRArqRgQTCKUFs2nptla6Uimhi3ZjsIYu/APEfYMWIQQjiBWX0oKhW6EoVhBJtSRL'
         'HYQk5ZlgF7EhHx0XJalNGknsJHGRszycmXPevRfeu4IS7r9R7ckBL+DRwSWgBwOhQ1ZABHiZ'
         'sKWCPBgvAAgA650tm1osvgYxTEugfyyYTNdlwJEU+yfvf98684MQCVvaXSp7i80BxLA9OeBV'
         '0PHQLuh4VF3gEhX8vcmzLExYURVhiE9hT2dpTeIPbx/2F7iUo6bdSHMAVREsTFirmwA9Sq0P'
         'jEatfyq0GWo9onPeL1VcPOhsWPNfVqAToBOgE6AToBOgaQHGr5yq4hZnBjF3K41fRv9i/nz+'
         'PJlYlHgoRO6HpG90jOnZOS5au7j16CuFPb3+APXcapWaTCzK1s0bFH9lANh595ZMLIrb/5Cp'
         'EQuvPvxsbgviT0Nl8xLk6gpZTWNyyPL3GSiV5zjIS1mTP91rOgigQ7ZStLQmjx3izOhYFXei'
         'rx+z08mmtlvellShE0Fw9U+hP7xd9YJtBIszg0zPzpGJRZGrK2Xzy8En5JUuXqyn9h+lOhFh'
         'v/35LvDYyP6buxWW5y/gvmQmq2nkpOSk00le6cL37DvhTzslqa9pq5mqCKZGLFwbsmDpNbGp'
         '7bK8nuKbzB1azdq+nCoAMuBIJmxpN+ADNo4aTCPWc2AD8CVsabcMOJIAvwHmU8oCxrBsIgAA'
         'AABJRU5ErkJggg=='
    ),
    48: (
         'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAACsUlEQVR42u2aQUhUURSG/3Pf'
         'oBMajGQOMxBoCE2E4UCLkbTGTYSg7czdNIgO1MJ2LrRWuWgXRNC4mVQUc1ctCjdONWKLwFDE'
         'WQQJwujDwBclKPjuaZEzoM6MNjXOu/D+5T3vvvd/vHPOXdxDyCJ3ZDEomENMHCCQDyUUg5PE'
         '9EkSjejRhvjBOO03Pl8rWIuBEIQVxYhLMsN61L9yCMDT+6UZJN4AcMHaMsCyfW24MZEBcEfm'
         'awW0eQXMZyAkTL8e9a8IABCsxRQyDwCuPc8gd2QxKMAzUFAS1CoEcwiKSjCHBBMFVAVgooCD'
         'wHn7fGdTFYa6vKgoFydmbGtHYmAyham5zbzPEdh3pKuTNg8AFeUCQ13e46XRcV5WCh33uwKK'
         'S3kARyGbbj/5ho/JX1ljLb5KvLxf91/2FO0P5DKSL1bIHrsGbAAbwAawAWwAG8AGsAFsABvA'
         'BlAWwOd1qgHQ3+HOuj49WJ8z9k8ALb7Kv47lWu/vcKOvrQZsmlgfG8VyTzeWe7qxPjYKjSX6'
         '2mryQpAnssD5zKaeNxT9D7BpYjkcgjGb2LfuutqMi7ERmCRw49FXJFPb1kwhfWL8kHkAMGYT'
         '0CfG4RCEzqYq69aA8eH9kbFL55yFAWztSLXb6MBkqugQrmvXj4wtrW4XVsTF7vPTg/XQWBZc'
         'xFrllbtdBFSXAuD7z12UaYTAhdOo7riFsjPVgBA4VXce3lAYtQ8egjQNT99u4NXnH4e7FyhJ'
         'nt6FGAh3Sn2Q3bt5Fg6x79oau5Lx7N0GHr/Wc/RfvLDMJZ/P60RnU1Wm2yytbmNqbjNr2qQl'
         'Qa0EAJ7ehRnL3s7nPP0QXxu+3CoAQJIZBmAoZN/Y8/ynjepR/wpYtisCYYBle3peInMOrA03'
         'JiRMPxhxK6eNhOlPz0kAB6ZV0lJp3OY3sKYL96Ys/JwAAAAASUVORK5CYII='
    ),
}

_icon_photos = []               # keep a reference: Tk needs the photo alive


def set_icon():
    import base64
    if sys.platform == 'win32':
        ico = icon_file()
        if ico:
            for args in (('-default', ico), (ico,)):
                try:
                    mw.iconbitmap(*args)
                    return
                except tk.TclError:
                    pass
    for size in sorted(ICON_PNG, reverse=True):
        try:
            img = tk.PhotoImage(master=mw, format='png',
                                data=base64.b64decode(ICON_PNG[size]))
            _icon_photos.append(img)
        except tk.TclError:
            continue
    if _icon_photos:
        try:
            mw.iconphoto('-default', *_icon_photos)
        except tk.TclError:
            pass


def icon_file():
    # data/phcp.ico beside the script, or unpacked beside a packaged
    # .exe.  None if neither exists.
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cands = [os.path.join(here, 'data', 'phcp.ico')]
    # A PyInstaller build unpacks its bundled files to sys._MEIPASS.
    meipass = getattr(sys, '_MEIPASS', None)
    if meipass:
        cands.append(os.path.join(meipass, 'data', 'phcp.ico'))
    par = os.environ.get('PAR_TEMP')
    if par:
        cands.append(os.path.join(par, 'inc', 'lib', 'data', 'phcp.ico'))
    for p in cands:
        if os.path.isfile(p):
            return p
    return None


#==============================================================================
# build_window -- create every widget.  Returns the main window.
#==============================================================================
def build_window():
    global mw, toptabs, restabs, SCALE, saved_text, valid_text
    dpi_aware()
    mw = tk.Tk()
    mw.configure(background=C['paper'])
    set_icon()
    # The screen's scale against the 96 dpi the sizes here were drawn
    # for; never below 1, so a low-resolution screen is not cramped
    # further.
    dpi = mw.winfo_fpixels('1i')
    SCALE = dpi / 96 if dpi > 96 else 1
    pick_fonts()
    mw.geometry('%dx%d' % (px(1500), px(950)))
    mw.option_add('*Font', UI)
    mw.option_add('*Background', C['paper'])
    mw.option_add('*Menu.Relief', 'flat')
    mw.option_add('*Menu.activeBorderWidth', 0)
    mw.option_add('*Menu.activeBackground', C['select'])
    mw.option_add('*Menu.activeForeground', C['ink'])
    mw.option_add('*Menu.font', UI)
    mw.option_add('*Menu.borderWidth', 1)
    build_menus()
    build_toolbar()

    # The divider between the work above and the results below can be
    # moved.
    vp = divider(mw, 'vertical')
    top = tk.Frame(mw, background=C['paper'])
    bottom = tk.Frame(mw, background=C['paper'])

    def on_top_tab(n):
        if n == 'QUICK TOOLS':
            from hardycross.window import tools as _t
            _t.tools_refresh()
        elif n == 'ORIFICE PLATE':
            from hardycross.window import orifice as _o
            _o.orifice_refresh()

    toptabs = make_tabs(top, ['NETWORK', 'PROJECT', 'GRAPH', 'QUICK TOOLS',
                              'ORIFICE PLATE', 'DATABASE'], on_top_tab)
    build_network(toptabs['page']['NETWORK'])
    from hardycross.window import database as _db
    from hardycross.window import graph as _gr
    from hardycross.window import orifice as _or
    from hardycross.window import project as _pr
    from hardycross.window import results as _re
    from hardycross.window import tools as _to
    _pr.build_project(toptabs['page']['PROJECT'])
    _gr.build_graph(toptabs['page']['GRAPH'])
    _to.build_tools(toptabs['page']['QUICK TOOLS'])
    _or.build_orifice(toptabs['page']['ORIFICE PLATE'])
    _db.build_database(toptabs['page']['DATABASE'])
    _re.build_results(bottom)
    vp.add(top, height=px(560))
    vp.add(bottom)
    vp.pack(fill='both', expand=1)

    bind_keys()
    saved_text = full_text()      # an empty new file is not a change
    set_title()
    update_actions()
    update_status()
    # A palette remembered from last time.  The widgets are built in
    # the light colours and then repainted, so the shared tabs take
    # the dark colours too.
    try:
        saved = (_settings.get('EDITOR_THEME') or '').lower()
    except Exception:
        saved = ''
    if saved == 'dark':
        apply_theme('dark')
    ed.focus_set()
    return mw


def build_menus():
    global view_menu
    bar = tk.Menu(mw, type='menubar', relief='flat', borderwidth=0,
                  font=UI, background=C['paper'], foreground=C['ink'])
    mw.configure(menu=bar)
    file_m = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='FILE', menu=file_m)
    file_m.add_command(label='NEW', accelerator='CTRL+N', command=file_new)
    file_m.add_command(label='OPEN...', accelerator='CTRL+O', command=file_open)
    file_m.add_command(label='SAVE', accelerator='CTRL+S', command=file_save)
    file_m.add_command(label='SAVE AS...', command=file_save_as)
    file_m.add_separator()
    file_m.add_command(label='PROJECT AND UNITS',
                       command=lambda: select_tab(toptabs, 'PROJECT'))
    file_m.add_separator()
    file_m.add_command(label='WRITE REPORT...', accelerator='CTRL+R',
                       command=file_report)
    file_m.add_separator()
    file_m.add_command(label='QUIT', accelerator='CTRL+Q', command=file_quit)
    edit_m = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='EDIT', menu=edit_m)
    edit_m.add_command(label='UNDO', accelerator='CTRL+Z', command=undo)
    edit_m.add_command(label='REDO', accelerator='CTRL+Y', command=redo)
    edit_m.add_separator()
    edit_m.add_command(label='PICK LIST', accelerator='CTRL+SPACE',
                       command=pick_list)
    # The menu is made on its own so the label of DARK MODE can be
    # changed when the palette is.
    view_menu = tk.Menu(bar, tearoff=0, font=UI, relief='flat',
                        borderwidth=0, background=C['paper'],
                        foreground=C['ink'], activebackground=C['select'],
                        activeforeground=C['ink'])
    bar.add_cascade(label='VIEW', menu=view_menu)
    view_menu.add_command(label='DARK MODE', command=toggle_theme)
    model_m = tk.Menu(bar, tearoff=0)
    bar.add_cascade(label='MODEL', menu=model_m)
    model_m.add_command(label='VALIDATE', accelerator='F4', command=validate)
    model_m.add_command(label='CALCULATE', accelerator='F5', command=calculate)


# build_toolbar -- the file buttons, VALIDATE and CALCULATE, WRITE
# REPORT, DARK MODE, and on the right the model's state: not validated,
# problems, valid, calculated.
def build_toolbar():
    global pill
    tb = tk.Frame(mw, background=C['panel'])
    tb.pack(side='top', fill='x')
    inner = tk.Frame(tb, background=C['panel'])
    inner.pack(fill='x', padx=px(14), pady=px(8))

    def sep():
        tk.Frame(inner, background=C['line'], width=1, height=px(22))\
            .pack(side='left', padx=px(10))

    btn['NEW'] = flat_button(inner, 'NEW', file_new)
    btn['NEW'].pack(side='left', padx=px([0, 4]))
    btn['OPEN'] = flat_button(inner, 'OPEN', file_open)
    btn['OPEN'].pack(side='left', padx=px(4))
    btn['SAVE'] = flat_button(inner, 'SAVE', file_save)
    btn['SAVE'].pack(side='left', padx=px(4))
    sep()
    btn['VALIDATE'] = flat_button(inner, 'VALIDATE  F4', validate)
    btn['VALIDATE'].pack(side='left', padx=px(4))
    btn['CALCULATE'] = flat_button(inner, 'CALCULATE  F5', calculate,
                                   primary=True)
    btn['CALCULATE'].pack(side='left', padx=px(4))
    sep()
    btn['REPORT'] = flat_button(inner, 'WRITE REPORT', file_report)
    btn['REPORT'].pack(side='left', padx=px(4))
    pill = tk.Label(inner, text='', font=UI_B, padx=px(12), pady=px(4))
    pill.pack(side='right')
    btn['THEME'] = flat_button(inner, 'DARK MODE', toggle_theme)
    btn['THEME'].pack(side='right', padx=px([0, 8]))
    # A soft edge, not a hard rule: the bar sits a step above the page,
    # as it does on the spreadsheet.
    tk.Frame(mw, background=C['shadow'], height=1).pack(side='top', fill='x')


#------------------------------------------------------------------------------
# build_network -- the NETWORK tab: the command strip across the top,
# the editor with its line numbers and status bar, the three lists on
# the right.
#------------------------------------------------------------------------------
def build_network(page):
    global ed, gutter, statusbar, strip
    build_strip(page)
    hp = divider(page, 'horizontal')
    left = tk.Frame(page, background=C['paper'])
    right = tk.Frame(page, background=C['paper'])

    # The status bar, under the editor.
    sb = tk.Frame(left, background=C['panel'])
    sb.pack(side='bottom', fill='x')
    tk.Frame(sb, background=C['shadow'], height=1).pack(side='top', fill='x')
    statusbar = tk.Text(sb, height=1, wrap='none', font=MONO,
                        background=C['panel'], foreground=C['ink'],
                        borderwidth=0, highlightthickness=0, padx=px(14),
                        pady=px(6), state='disabled', cursor=POINTER,
                        takefocus=0)
    statusbar.pack(fill='x')

    # The editor: line numbers, text, scrollbars.  The gutter is a
    # second Text in the same font, scrolled with the editor, so its
    # numbers stay level with the lines however the editor is
    # scrolled.
    ef = tk.Frame(left, background=C['paper'])
    ef.pack(fill='both', expand=1)
    vsb = flat_scrollbar(ef, 'vertical', side='right', fill='y')
    hsb = flat_scrollbar(ef, 'horizontal', side='bottom', fill='x')
    gutter = tk.Text(ef, width=5, wrap='none', font=MONO,
                     background=C['panel'], foreground=C['faint'],
                     borderwidth=0, highlightthickness=0, padx=px(6),
                     pady=px(6), state='disabled', cursor=POINTER,
                     takefocus=0, spacing1=1, spacing3=1)
    gutter.pack(side='left', fill='y')

    def gutter_click(e):
        n = int(gutter.index('current').split('.')[0])
        go_to_line(n)

    gutter.bind('<ButtonRelease-1>', gutter_click)
    rule(ef, 'y', side='left')
    # TextUndo in Perl/Tk; Tkinter's Text with undo=True records every
    # insert and delete and undoes them one at a time (see the module
    # docstring for the proposal scheme).
    ed = tk.Text(ef, wrap='none', font=MONO, undo=True,
                  background=C['paper'], foreground=C['ink'],
                  insertbackground=C['ink'], insertwidth=px(2),
                  selectbackground=C['select'], selectforeground=C['ink'],
                  borderwidth=0, highlightthickness=0, padx=px(10),
                  pady=px(6), spacing1=1, spacing3=1, exportselection=1)
    ed.pack(side='left', fill='both', expand=1)

    def yscroll(first, last):
        vsb.set(first, last)
        gutter.yview_moveto(float(first))

    ed.configure(yscrollcommand=yscroll, xscrollcommand=hsb.set)
    vsb.configure(command=ed.yview)
    hsb.configure(command=ed.xview)
    wheel_target(ed)
    wheel_target(gutter, ed)      # the wheel over the numbers scrolls the editor

    # Syntax colours.  Blue for command words and keywords, black bold
    # for a name being defined, dark blue for numbers, grey italic for
    # comments.  Behind a line in error, a pale red; behind the exact
    # field validation found at fault, a deeper red with the text
    # underlined.  The same tags are set again when the palette
    # changes.
    style_editor_tags()
    ed.tag_lower('curline')
    ed.tag_raise('error')
    ed.tag_raise('fault')
    ed.tag_raise('proposal')
    ed.tag_raise('sel')

    # The three lists.
    for name in ('ERRORS', 'WARNINGS', 'NODES'):
        f = tk.Frame(right, background=C['paper'])
        f.pack(fill='both', expand=1)
        list_head[name] = tk.Label(f, text=name, font=UI_S, anchor='w',
                                   background=C['panel'],
                                   foreground=C['muted'], padx=px(14),
                                   pady=px(8))
        list_head[name].pack(side='top', fill='x')
        LIST[name] = tk.Listbox(f, height=5, font=MONO,
                                background=C['paper'],
                                foreground=C['error'] if name == 'ERRORS'
                                else C['warn'] if name == 'WARNINGS'
                                else C['ink'],
                                selectbackground=C['select'],
                                selectforeground=C['ink'], relief='flat',
                                borderwidth=0, highlightthickness=0,
                                activestyle='none', cursor=POINTER)
        LIST[name].pack(fill='both', expand=1, padx=px([14, 4]),
                        pady=px([0, 6]))
        wheel_target(LIST[name])
        if name != 'NODES':
            rule(f, 'x', side='bottom')
        list_lines[name] = []
        LIST[name].bind('<ButtonRelease-1>',
                        lambda e, n=name: go_to_list(n))
    hp.add(left, width=px(1000))
    hp.add(right)
    hp.pack(fill='both', expand=1)


#------------------------------------------------------------------------------
# bind_keys -- the editor's own keys.
#
# Our bindings go on a tag placed FIRST in the text widget's bindtags,
# so they run before the Text class bindings and can stop them
# ('break') -- Enter must not insert its newline before the proposal
# is dealt with, for one.
#------------------------------------------------------------------------------
def bind_keys():
    t = text_widget()
    t.bindtags(('PhcEditor',) + t.bindtags())

    def ret(e):
        on_return()
        return 'break'

    def tab(e):
        return 'break' if on_tab() else None

    def on_key(e):
        sym = e.keysym or ''
        if sym.startswith(('Shift', 'Control', 'Alt', 'Meta', 'Super',
                            'Caps_Lock', 'Return', 'Tab')):
            return None
        discard_proposal()
        return None

    def b1(e):
        discard_proposal()
        return None

    def b3(e):
        return 'break'              # no bevelled pop-up menu

    def release(e):
        after_change()
        return None

    def button_release(e):
        update_status()
        return None

    def cspace(e):
        pick_list()
        return 'break'

    def cz(e):
        undo()
        return 'break'

    def cy(e):
        redo()
        return 'break'

    mw.bind_class('PhcEditor', '<Return>', ret)
    mw.bind_class('PhcEditor', '<Tab>', tab)
    mw.bind_class('PhcEditor', '<KeyPress>', on_key)
    mw.bind_class('PhcEditor', '<ButtonPress>', b1)
    mw.bind_class('PhcEditor', '<ButtonPress-3>', b3)
    mw.bind_class('PhcEditor', '<KeyRelease>', release)
    mw.bind_class('PhcEditor', '<ButtonRelease>', button_release)
    mw.bind_class('PhcEditor', '<Control-space>', cspace)
    mw.bind_class('PhcEditor', '<Control-z>', cz)
    mw.bind_class('PhcEditor', '<Control-y>', cy)
    mw.bind('<F4>', lambda e: validate())
    mw.bind('<F5>', lambda e: calculate())
    mw.bind('<Control-n>', lambda e: file_new())
    mw.bind('<Control-o>', lambda e: file_open())
    mw.bind('<Control-s>', lambda e: file_save())
    mw.bind('<Control-r>', lambda e: file_report())
    mw.bind('<Control-q>', lambda e: file_quit())
    mw.protocol('WM_DELETE_WINDOW', file_quit)
    bind_wheel()


#------------------------------------------------------------------------------
# The mouse wheel scrolls what is under the pointer.
#
# Windows sends wheel events to the widget with the keyboard focus, so
# with the cursor in the editor the wheel over the results table
# scrolled the editor and the table could not be scrolled at all.
# Every scrollable pane is registered here (wheel_target puts a
# 'PhcWheel' tag first in its bindtags); a wheel event, wherever it is
# delivered, is passed to the registered pane under the pointer, and
# goes no further.  The same binding on the main window catches the
# wheel when the focus is in a field of the PROJECT tab.  On Linux the
# wheel arrives as buttons 4 and 5.
#------------------------------------------------------------------------------
WHEEL = {}


def wheel_target(w, target=None):
    WHEEL[w._w] = target or w
    w.bindtags(('PhcWheel',) + tuple(t for t in w.bindtags()
                                    if t != 'PhcWheel'))


def route_wheel(units, X, Y):
    # lines to scroll; the pointer on the screen
    w = None
    try:
        w = mw.winfo_containing(X, Y)
    except tk.TclError:
        w = None
    while w is not None and w is not mw and w._w not in WHEEL:
        try:
            w = mw.nametowidget(w.winfo_parent())
        except tk.TclError:
            break
    if w is None or w._w not in WHEEL:
        return None
    WHEEL[w._w].yview_scroll(units, 'units')
    return 'break'


def bind_wheel():
    def wheel(e):
        d = e.delta
        if d > 0:
            units = -3 * (int(d / 120) or 1)
        else:
            units = 3 * (int(-d / 120) or 1)
        return route_wheel(units, e.x_root, e.y_root)

    def b4(e):
        return route_wheel(-3, e.x_root, e.y_root)

    def b5(e):
        return route_wheel(3, e.x_root, e.y_root)

    for tag in ('PhcWheel',):
        mw.bind_class(tag, '<MouseWheel>', wheel)
        mw.bind_class(tag, '<Button-4>', b4)
        mw.bind_class(tag, '<Button-5>', b5)
    mw.bind('<MouseWheel>', wheel)
    mw.bind('<Button-4>', b4)
    mw.bind('<Button-5>', b5)


# text_widget -- the Text where keys arrive (the editor itself).
def text_widget():
    return ed


#==============================================================================
# Buffer helpers.
#==============================================================================

# buffer -- the network text, without a proposal that is only on offer.
def buffer():
    t = ed.get('1.0', 'end - 1 chars')
    if not prop['active']:
        return t
    return ed.get('1.0', 'pstart') + ed.get('pend', 'end - 1 chars')


# doc -- the document: the PROJECT tab's settings and the editor's
# network.
def doc():
    return {'settings': settings, 'network': buffer()}


# full_text -- the whole .phc file the document makes.
def full_text():
    return editor.join_file(settings, buffer())[0]


# replace_lines -- the network text changed line by line where it
# differs, keeping the cursor, the view and the undo history of the
# rest.
def replace_lines(new):
    discard_proposal()
    old = buffer().split('\n')
    nl = new.split('\n')
    if len(old) != len(nl):
        set_buffer(new)
        return
    for i in range(len(nl)):
        if old[i] == nl[i]:
            continue
        n = i + 1
        ed.delete('%d.0' % n, '%d.end' % n)
        ed.insert('%d.0' % n, nl[i])


# set_buffer -- replace the network text, as when a file is opened.
def set_buffer(text):
    global saved_text, solved, validation, valid_text, gutter_lines
    discard_proposal()
    ed.delete('1.0', 'end')
    ed.insert('1.0', text)
    ed.edit_reset()               # undo does not reach back past an open
    saved_text = full_text()
    ed.mark_set('insert', '1.0')
    solved = validation = valid_text = None
    from hardycross.window import results as _re
    _re.fill_results()
    _re.fill_validation()
    recolour()
    update_actions()
    update_status()


# cursor -- (line, column) of the insertion point.
def cursor():
    line, col = ed.index('insert').split('.')
    return int(line), int(col)


# go_to_line -- put the cursor at line $n, show it; select columns $a
# to $b if given, otherwise the whole line.
def go_to_line(n, a=None, b=None):
    if not n:
        return
    select_tab(toptabs, 'NETWORK')
    ed.tag_remove('sel', '1.0', 'end')
    if a is not None:
        ed.mark_set('insert', '%d.%s' % (n, a))
        ed.tag_add('sel', '%d.%s' % (n, a), '%d.%s' % (n, b))
    else:
        ed.mark_set('insert', '%d.0' % n)
        ed.tag_add('sel', '%d.0' % n, '%d.0 lineend' % n)
    ed.see('insert')
    ed.focus_set()
    update_status()


# go_to_list -- a click in ERRORS, WARNINGS or NODES: to the line, or
# for a setting to its field in the PROJECT tab.
def go_to_list(name):
    sel = LIST[name].curselection()
    if not sel:
        return
    e = list_lines[name][sel[0]]
    if not e:
        return
    if e.get('field'):
        from hardycross.window import database as _db
        _db.show_field(e['field'])
        return
    if e.get('line'):
        go_to_line(e['line'])


#==============================================================================
# Colouring, line numbers, the three lists, the status bar.
#==============================================================================

# after_change -- after a key: the status bar at once, the full
# re-check shortly after typing pauses.
def after_change(ev=None):
    global recolour_job
    update_status()
    if recolour_job:
        recolour_job.cancel()
        recolour_job = None
    recolour_job = _After(mw.after(250, _recolour_now))
    set_title()
    update_actions()


def _recolour_now():
    global recolour_job
    recolour_job = None
    recolour()


# recolour -- re-check every line; colour it, number it, and refill the
# lists.
def recolour():
    global validation
    text = buffer()
    line = cursor()[0]
    res = editor.doc_check(doc(), editing=line)
    l = text.split('\n')
    for tag in ('command', 'keyword', 'name', 'ref', 'number', 'comment',
                'error'):
        ed.tag_remove(tag, '1.0', 'end')
    bad = []
    for i in range(1, len(l) + 1):
        for a, b, tag in editor.colour_spans(l[i - 1]):
            ed.tag_add(tag, '%d.%d' % (i, a), '%d.%d' % (i, b))
        st = (res['lines'][i] or {}).get('status', 'ok') \
            if i < len(res['lines']) else 'ok'
        # An incomplete line is still being typed while the cursor is
        # on it; anywhere else it is as wrong as an error.
        if st == 'error' or (st == 'incomplete' and i != line):
            ed.tag_add('error', '%d.0' % i, '%d.0 lineend + 1 chars' % i)
            bad.append(i)
    # Validation marks belong to the text they were found in.
    if not (validation and validation['text'] == full_text()):
        ed.tag_remove('fault', '1.0', 'end')
    refresh_gutter(bad)

    # Warnings belong to the last calculation; they are shown until the
    # next.
    d = editor.doc_diagnostics(doc(),
                               solved['net'] if solved else None,
                               editing=line)
    for name in ('ERRORS', 'WARNINGS', 'NODES'):
        lb = LIST[name]
        e = d[name.lower()]
        lb.delete(0, 'end')
        list_lines[name] = []
        for p in e:
            if p.get('line') is not None:
                lb.insert('end', '%5d  %s' % (p['line'], p['message']))
            else:
                lb.insert('end', '       %s' % p['message'])
            list_lines[name].append(p)
        list_head[name].configure(
            text='%s  %d' % (name, len(e)) if e else name,
            foreground=C['muted'] if not e
            else C['error'] if name == 'ERRORS'
            else C['warn'] if name == 'WARNINGS' else C['ink'])
    return res


# refresh_gutter -- the line numbers: one per line, the cursor's in
# black, lines in error in red.
def refresh_gutter(bad=None):
    global gutter_lines
    bad = bad or []
    n = int(ed.index('end - 1 chars').split('.')[0])
    cur = cursor()[0]
    gutter.configure(state='normal')
    if n != gutter_lines:
        gutter.delete('1.0', 'end')
        gutter.insert('1.0', '\n'.join(str(i) for i in range(1, n + 1)),
                     'num')
        gutter_lines = n
    for tag in ('cur', 'bad'):
        gutter.tag_remove(tag, '1.0', 'end')
    for i in bad:
        gutter.tag_add('bad', '%d.0' % i, '%d.0 lineend' % i)
    gutter.tag_add('cur', '%d.0' % cur, '%d.0 lineend' % cur)
    gutter.configure(state='disabled')
    gutter.yview_moveto(ed.yview()[0])


# gutter_numbers -- the numbers the gutter shows (for the tests).
def gutter_numbers():
    return [x for x in
            gutter.get('1.0', 'end - 1 chars').split('\n') if x != '']


# update_status -- the status bar for the cursor's line: the command's
# field template with the field the cursor is in highlighted, then the
# line's message if it has one, or after a calculation the element's
# results.
def update_status():
    global notice
    text = buffer()
    n, col = cursor()
    ed.tag_remove('curline', '1.0', 'end')
    ed.tag_add('curline', '%d.0' % n, '%d.0 lineend + 1 chars' % n)
    if gutter:
        refresh_gutter([int(str(r).split('.')[0])
                        for r in gutter.tag_ranges('bad')])
    # A message (calculated, saved ...) stays until something changes;
    # otherwise the key release that follows F5 would wipe it at once.
    if notice:
        if notice[2] == where(text):
            return
        notice = None
    st = editor.doc_status(doc(), n, col)
    statusbar.configure(state='normal')
    statusbar.delete('1.0', 'end')
    t = st.get('template')
    if t and t.get('command'):
        statusbar.insert('end', t['command'] + ' ', 'muted')
        for i, fld in enumerate(t['fields']):
            statusbar.insert('end', fld,
                             'current' if i == t['current'] else 'muted')
            statusbar.insert('end', ' ')
    extra = None
    if st['status'] != 'ok' and st.get('message'):
        extra = [st['message'], 'bad']
    elif solved:
        l = text.split('\n')
        r = editor.results_at(solved['net'], l[n - 1])
        if r is not None and full_text() != solved['text']:
            r += '   (CALCULATED BEFORE THE LATEST EDITS)'
        if r is not None:
            extra = [r]
    if extra:
        statusbar.insert('end', '   |   ', 'muted')
        statusbar.insert('end', extra[0], (extra[1],) if len(extra) > 1
                         and extra[1] else ())
    statusbar.configure(state='disabled')
    return st


def _pairs(flat):
    return list(zip(flat[0::2], flat[1::2]))


# status_text -- what the status bar shows, as plain text (for the
# tests).
def status_text():
    s = statusbar.get('1.0', 'end - 1 chars')
    return s.rstrip()


# where -- the document and cursor as one string: a message stays while
# this is unchanged.
def where(text=None):
    text = buffer() if text is None else text
    return '\x00'.join((ed.index('insert'), text, full_text()))


# message -- a message in the status bar, kept until the text or
# cursor moves.
def message(text, bad=False):
    global notice
    notice = [text, bad, where()]
    statusbar.configure(state='normal')
    statusbar.delete('1.0', 'end')
    statusbar.insert('end', text.upper(), ('bad',) if bad else ('good',))
    statusbar.configure(state='disabled')


#------------------------------------------------------------------------------
# update_actions -- CALCULATE on or off, and the state shown on the
# right of the toolbar.  CALCULATE is on only while the whole file is
# exactly as it was when it last passed VALIDATE; any edit, to the
# network or in the PROJECT tab, turns it off until VALIDATE is run
# again.
#------------------------------------------------------------------------------
def update_actions():
    if 'CALCULATE' not in btn:
        return
    full = full_text()
    valid = valid_text is not None and valid_text == full
    if valid:
        btn['CALCULATE'].configure(state='normal',
                                   background=C['accent'],
                                   highlightbackground=C['accent'])
    else:
        btn['CALCULATE'].configure(state='disabled',
                                   background=C['panel'],
                                   highlightbackground=C['line'])
    if solved and solved['text'] == full:
        if solved['converged']:
            text, fg, bg = 'CALCULATED', C['accent'], C['accent_bg']
        else:
            text, fg, bg = 'DID NOT CONVERGE', C['error'], C['error_bg']
    elif valid:
        text, fg, bg = 'VALID - READY TO CALCULATE', C['accent'], C['accent_bg']
    elif validation and validation['text'] == full:
        n = len(validation['items'])
        text = '%d PROBLEM%s - SEE VALIDATION' % (n, '' if n == 1 else 'S')
        fg, bg = C['error'], C['error_bg']
    else:
        text, fg, bg = 'NOT VALIDATED', C['muted'], C['hover']
    pill.configure(text=text, foreground=fg, background=bg)


# calculate_enabled / state_text -- for the tests.
def calculate_enabled():
    return btn['CALCULATE'].cget('state') == 'normal'


def state_text():
    return pill.cget('text')


#==============================================================================
# The command strip: the network commands, in their groups.  A click
# starts a line with that command, on the current line if it is empty
# or a new one below it.  The settings commands are not here: they are
# the PROJECT tab.
#==============================================================================
def build_strip(parent):
    global strip
    # The commands sit on the same grey band as the toolbar, edge to
    # edge, with a soft edge under them.  A command is blue; the
    # pointer washes it pale blue.
    band = tk.Frame(parent, background=C['panel'])
    band.pack(side='top', fill='x')
    strip = tk.Frame(band, background=C['panel'])
    strip.pack(fill='x', padx=px(8), pady=px(6))
    groups = phc.COMMAND_GROUPS[1:]
    first = True
    for group in groups:
        if not first:
            tk.Frame(strip, background=C['line'], width=1,
                     height=px(16)).pack(side='left', padx=px(8))
        first = False
        for cmd in group:
            l = tk.Label(strip, text=cmd, font=MONO_B, background=C['panel'],
                         foreground=C['accent'], padx=px(6), pady=px(3),
                         cursor='hand2')
            l.pack(side='left')
            l.bind('<Enter>', lambda e, l=l: l.configure(
                background=C['accent_bg']))
            l.bind('<Leave>', lambda e, l=l: l.configure(
                background=C['panel']))
            l.bind('<ButtonRelease-1>',
                   lambda e, c=cmd: start_command(c))
    tk.Frame(parent, background=C['shadow'], height=1).pack(side='top',
                                                             fill='x')


# start_command -- begin a line with a command, ready for its first
# field.
def start_command(cmd):
    discard_proposal()
    select_tab(toptabs, 'NETWORK')
    if ed.get('insert linestart', 'insert lineend').strip():
        ed.mark_set('insert', 'insert lineend')
        ed.insert('insert', '\n')
    ed.delete('insert linestart', 'insert lineend')
    ed.insert('insert', '%-9s ' % cmd)
    ed.see('insert')
    ed.focus_set()
    after_change()


# strip_commands -- the commands on the strip, in order (for the
# tests).
def strip_commands():
    return [w.cget('text') for w in strip.winfo_children()
            if isinstance(w, tk.Label)]


#==============================================================================
# Proposals.
#
# After Enter the likely next line is shown greyed at the cursor.
# Enter or Tab accepts it (Enter also starts the next line, and
# offers the one after, so holding Enter lays down a run of pipes);
# any other key discards it and then does what it normally does.  The
# proposal sits between the marks pstart and pend, tagged 'proposal';
# buffer() leaves it out until it is accepted.
#
# In Perl/Tk the grey text went in and out with plain Tk::Text insert
# and delete, which TextUndo does not record: a proposal that was only
# offered must not come back as real text on Ctrl+Z.  Tkinter has no
# unrecorded insert, so it is recorded behind an explicit separator,
# making it one undo item on its own; discard is one edit_undo() (the
# redo it leaves is cleared by the next recorded edit), and accept is
# that undo followed by a recorded insert, so undo removes an accepted
# line like any other.
#==============================================================================
def on_return():
    if prop['active']:
        accept_proposal()
    ed.insert('insert', '\n')
    ed.see('insert')
    offer_proposal()
    after_change()


# on_tab -- accept a proposal; otherwise let Tab insert itself.  True
# when it handled the key.
def on_tab():
    if not prop['active']:
        return False
    accept_proposal()
    after_change()
    return True


def offer_proposal():
    if prop['active']:
        return
    n = cursor()[0]
    p = editor.proposal(buffer(), n - 1)
    if p is None:
        return
    # Only on an empty line: never push grey text into the middle of a
    # line.
    if ed.get('insert linestart', 'insert lineend').strip():
        return
    ed.edit_separator()           # the proposal is its own undo item
    ed.mark_set('pstart', 'insert')
    ed.mark_gravity('pstart', 'left')
    ed.insert('insert', p, 'proposal')
    ed.mark_set('pend', 'insert')
    ed.mark_gravity('pend', 'right')
    ed.mark_set('insert', 'pstart')
    prop['active'] = 1


def accept_proposal():
    if not prop['active']:
        return
    p = ed.get('pstart', 'pend')
    at = ed.index('pstart')
    discard_proposal()
    ed.insert(at, p)              # recorded: undo removes the accepted line
    ed.mark_set('insert', '%s + %d chars' % (at, len(p)))


def discard_proposal():
    if not prop['active']:
        return
    try:
        ed.edit_undo()            # the proposal insert, alone
    except tk.TclError:
        pass
    prop['active'] = 0


#==============================================================================
# Pick list, Ctrl+Space.
#
# In a USE type or a pipe's fittings: a list of the choices with their
# descriptions.  Arrows move, Enter or a double-click inserts over any
# part already typed, Escape closes.
#==============================================================================
def pick_list():
    discard_proposal()
    n, col = cursor()
    ch = editor.doc_choices(doc(), n, col)
    if not ch:
        message('NO PICK LIST HERE: CTRL+SPACE WORKS IN A USE TYPE OR '
                'A PIPE FITTING')
        return
    top = tk.Toplevel(mw, background=C['line'])
    top.overrideredirect(1)
    top.transient(mw)
    lb = tk.Listbox(top, height=14, width=64, font=MONO,
                    background=C['paper'], foreground=C['ink'],
                    selectbackground=C['select'],
                    selectforeground=C['ink'], activestyle='none',
                    relief='flat', borderwidth=0, highlightthickness=0)
    lb.pack(fill='both', expand=1, padx=px(1), pady=px(1))
    for c in ch:
        lb.insert('end', '%-9s %s' % (c[0], c[1]))
    lb.selection_set(0)
    lb.activate(0)

    def choose(e=None):
        sel = lb.curselection()
        top.destroy()
        if sel:
            insert_choice(ch[sel[0]][0])

    def escape(e=None):
        top.destroy()
        ed.focus_set()

    def focus_out(e=None):
        if top.winfo_exists():
            top.destroy()

    lb.bind('<Return>', choose)
    lb.bind('<Double-ButtonRelease-1>', choose)
    lb.bind('<Escape>', escape)
    lb.bind('<FocusOut>', focus_out)
    bb = ed.bbox('insert')
    if bb:
        top.geometry('+%d+%d' % (ed.winfo_rootx() + bb[0],
                                 ed.winfo_rooty() + bb[1] + bb[3] + 2))
    lb.focus_set()
    return top


# insert_choice -- a picked code at the cursor, replacing the part of
# the word already typed before it ("G" + GV gives "GV", not "GGV").
def insert_choice(code):
    start = ed.index('insert')
    before = ed.get('insert linestart', 'insert')
    m = re_search(r'(\S+)\Z', before)
    if m and code.upper().startswith(m.group(1).upper()):
        start = ed.index('insert - %d chars' % len(m.group(1)))
    ed.delete(start, 'insert')
    ed.insert('insert', code)
    ed.focus_set()
    after_change()


def re_search(pat, text):
    import re as _re
    return _re.search(pat, text)


#==============================================================================
# VALIDATE (F4) and CALCULATE (F5).
#==============================================================================

#------------------------------------------------------------------------------
# validate -- check everything, list what is wrong, mark it in the
# editor.  When nothing is wrong the text is remembered, and CALCULATE
# is available until the text changes.
#------------------------------------------------------------------------------
def validate():
    global validation, valid_text
    discard_proposal()
    full = full_text()
    v = editor.validate(doc())
    validation = dict(v)
    validation['text'] = full
    valid_text = full if v['ok'] else None
    ed.tag_remove('fault', '1.0', 'end')
    for it in v['items']:
        if it.get('line') is None:
            continue
        # A line that stops short is at fault just past its end, where
        # nothing can be seen; its last word is marked instead.
        a, b = it.get('start'), it.get('end')
        line_text = ed.get('%d.0' % it['line'], '%d.0 lineend' % it['line'])
        if a >= len(line_text):
            m = re_search(r'(\S+)\s*\Z', line_text)
            if m:
                a, b = m.start(1), m.end(1)
            else:
                a, b = 0, len(line_text)
        ed.tag_add('fault', '%d.%d' % (it['line'], a),
                   '%d.%d' % (it['line'], b))
    from hardycross.window import results as _re
    _re.fill_validation()
    select_tab(restabs, 'VALIDATION')
    recolour()
    update_actions()
    n = len(v['items'])
    if v['ok']:
        message('VALID - NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE')
    else:
        message('%d PROBLEM%s FOUND - SEE VALIDATION BELOW; CLICK ONE TO '
                'GO TO IT' % (n, '' if n == 1 else 'S'), True)
    return v


#------------------------------------------------------------------------------
# calculate -- solve the model.  Refused unless the text is exactly
# what last passed VALIDATE.
#------------------------------------------------------------------------------
def calculate():
    global solved, valid_text
    discard_proposal()
    full = full_text()
    if valid_text is None or valid_text != full:
        message('VALIDATE THE INPUTS FIRST (F4): CALCULATE RUNS ONLY ON '
                'A MODEL THAT HAS PASSED VALIDATION', True)
        return {'ok': 0, 'not_validated': 1}
    # A calculation can take a while (auto sizing, design areas): the
    # status bar says what is being worked on, with a turning mark and
    # the seconds gone, so the window is plainly working and not
    # stuck.
    from hardycross.window import results as _re
    t0 = time.time()
    state = {'turn': 0, 'shown': 0.0}

    def progress(what):
        now = time.time()
        if now - state['shown'] < 0.15:
            return
        state['shown'] = now
        mark = ('|', '/', '-', '\\')[state['turn'] % 4]
        message('%s COMPUTING - %s - %d S' %
                (mark, what, int(time.time() - t0)))
        state['turn'] += 1
        mw.update()

    _busy()
    progress('CALCULATING')
    try:
        r = editor.doc_solve(doc(), path, progress=progress)
    except Exception as e:            # a solver crash, not a model error
        _unbusy()
        raise
    _unbusy()
    if not r.get('ok'):
        solved = None
        _re.fill_results()
        fill_report('THE MODEL WAS NOT CALCULATED\n\n%s\n' % r['error'])
        if r.get('line'):
            go_to_line(r['line'])
        recolour()
        update_actions()
        message(r['error'], True)
        return r
    # Auto sizing: each sized pipe's size goes in as a comment after
    # its line, //AS - 25.  A comment changes nothing in the model, so
    # the text is still the one that passed VALIDATE.
    if r.get('network') is not None and r['network'] != buffer():
        replace_lines(r['network'])
        full = full_text()
        valid_text = full
    solved = {'net': r['net'], 'converged': r['converged'], 'text': full}
    _re.fill_results()
    fill_report(r['report'])
    select_tab(restabs, 'PIPES')
    recolour()          # the WARNINGS list is the calculation's
    update_actions()
    message('CALCULATED - CONVERGED' if r['converged'] else
            'CALCULATED - DID NOT CONVERGE: THE RESULTS MUST NOT BE USED',
            not r['converged'])
    return r


def _busy():
    mw.configure(cursor='watch')
    mw.update_idletasks()


def _unbusy():
    mw.configure(cursor='')


def fill_report(text):
    report.configure(state='normal')
    report.delete('1.0', 'end')
    report.insert('1.0', text)
    report.configure(state='disabled')


def report_text():
    return report.get('1.0', 'end - 1 chars')


#==============================================================================
# Files.
#==============================================================================

# set_title -- the file name, and * when there are unsaved changes.
def set_title():
    global path
    name = path or 'UNTITLED.PHC'
    name = name.replace('\\', '/').rsplit('/', 1)[-1]
    mw.title('PHCP EDITOR - %s%s' %
             (name.upper(), ' *' if ed and modified() else ''))


# modified -- whether the file differs from what was last opened or
# saved.
def modified():
    return full_text() != saved_text


# ok_to_discard -- true if nothing is unsaved, or the user agrees to
# lose it.
def ok_to_discard():
    from hardycross.window import database as _db
    from hardycross.window import graph as _gr
    if not _db.db_ok_to_leave():
        return False
    if not _gr.graph_ok_to_discard():
        return False
    if not modified():
        return True
    return messagebox.askyesno(
        title='UNSAVED CHANGES', icon='warning', type='yesno',
        message='THE MODEL HAS UNSAVED CHANGES.  DISCARD THEM?')


def file_new():
    global path
    if not ok_to_discard():
        return
    path = None
    from hardycross.window import project as _pr
    _pr.load_settings(editor.new_settings())
    set_buffer('')
    set_title()


def file_open(f=None):
    if not ok_to_discard():
        return
    if f is None:
        f = filedialog.askopenfilename(
            filetypes=[('PHCP MODEL', '.phc'), ('ALL FILES', '*')])
        if not f:
            return
    open_path(f)


# open_path -- load a .phc file: its settings into the PROJECT tab,
# its network into the editor.
def open_path(f):
    global path
    from hardycross import ModelError, is_model_error
    try:
        r = editor.load_file(f)
    except ModelError as e:
        message(e.msg if hasattr(e, 'msg') else str(e), True)
        return
    except Exception as e:
        message(str(e), True)
        return
    d = editor.split_file(r['text'])
    path = r['path']
    from hardycross.window import project as _pr
    _pr.load_settings(d['settings'])
    set_buffer(d['network'])
    select_tab(toptabs, 'NETWORK')
    set_title()
    return r


def file_save():
    if path is None:
        file_save_as()
        return
    write_buffer(path)


def file_save_as(f=None):
    global path
    if f is None:
        initial = (path or 'UNTITLED.PHC').replace('\\', '/').rsplit('/', 1)[-1]
        f = filedialog.asksaveasfilename(
            defaultextension='.phc', initialfile=initial,
            filetypes=[('PHCP MODEL', '.phc')])
        if not f:
            return
    if write_buffer(f):
        path = f
    set_title()


# write_buffer -- save the whole file, settings and network, ending
# with a newline.
def write_buffer(f):
    global saved_text
    text = full_text()
    if not text.endswith('\n'):
        text += '\n'
    # The results of the last calculation go at the end of the file,
    # as comments (hardycross.results) -- but only when that
    # calculation was of exactly this text.  Results of an earlier
    # version are not saved.
    if solved and solved['text'] == full_text():
        text = _results_mod.with_results(text, solved['net'],
                                         solved['converged'])
    try:
        # Text mode, as the Perl's open '>': CRLF on Windows, LF elsewhere.
        with open(f, 'w', encoding='utf-8', errors='surrogateescape') as fh:
            fh.write(text)
    except OSError as e:
        message('CANNOT WRITE %s: %s' % (f, e), True)
        return False
    saved_text = full_text()
    message('SAVED %s' % f)
    set_title()
    return True


# file_report -- validate and calculate if the last calculation is not
# of this text, then write the report as .pdf or .txt by the extension
# chosen.
def file_report(out=None):
    if not (solved and solved['text'] == full_text()):
        if not validate()['ok']:
            return None
        r = calculate()
        if not r.get('ok'):
            return None
    if out is None:
        base = (path or 'UNTITLED.PHC').replace('\\', '/').rsplit('/', 1)[-1]
        out = filedialog.asksaveasfilename(
            defaultextension='.pdf',
            initialfile=re_sub(r'\.phc\Z', '', base, flags=re.I) + '_REPORT.PDF',
            filetypes=[('PDF REPORT', '.pdf'), ('TEXT REPORT', '.txt')])
        if not out:
            return None
    from hardycross import ModelError
    try:
        editor.write_report_file(solved['net'], solved['converged'],
                                 path or 'UNTITLED.PHC', out)
        ok = True
        err = None
    except ModelError as e:
        ok = False
        err = e.msg if hasattr(e, 'msg') else str(e)
    except Exception as e:
        ok = False
        err = str(e)
    message('REPORT WRITTEN TO %s' % out if ok
            else 'REPORT NOT WRITTEN: %s' % err, not ok)
    return ok


def file_quit():
    if not ok_to_discard():
        return
    mw.destroy()


# undo / redo -- one recorded edit at a time.  Tkinter complains on
# an empty record; that is not an error worth showing, so it is
# caught.
def undo():
    discard_proposal()
    try:
        ed.edit_undo()
    except tk.TclError:
        pass
    after_change()


def redo():
    discard_proposal()
    try:
        ed.edit_redo()
    except tk.TclError:
        pass
    after_change()


def re_sub(pat, rep, text, flags=0):
    import re as _re
    return _re.sub(pat, rep, text, flags=flags)


#==============================================================================
# Dark mode.  The shared tabs read C when they build a widget, and a
# table keeps the colours in its cell styles, so both have to be
# painted again.  White text on a blue button is not the paper colour:
# a foreground of white is left white, and a background of white
# becomes the dark paper.
#==============================================================================

# style_editor_tags -- the syntax colours, the gutter and the status
# bar, from the palette now in C.  Called when the editor is built and
# again when the palette changes.
def style_editor_tags():
    if not (ed and gutter and statusbar):
        return
    statusbar.tag_configure('current', foreground=C['accent'],
                            font=MONO_B, underline=1)
    statusbar.tag_configure('muted', foreground=C['muted'])
    statusbar.tag_configure('bad', foreground=C['error'], font=MONO_B)
    statusbar.tag_configure('good', foreground=C['accent'], font=MONO_B)
    gutter.tag_configure('num', justify='right')
    gutter.tag_configure('cur', foreground=C['ink'], font=MONO_B)
    gutter.tag_configure('bad', foreground=C['error'], font=MONO_B)
    ed.tag_configure('curline', background=C['curline'])
    ed.tag_configure('command', foreground=C['accent'], font=MONO_B)
    ed.tag_configure('keyword', foreground=C['accent'])
    ed.tag_configure('name', foreground=C['ink'], font=MONO_B)
    ed.tag_configure('ref', foreground=C['ink'])
    ed.tag_configure('number', foreground=C['number'])
    ed.tag_configure('comment', foreground=C['muted'], font=MONO_I)
    ed.tag_configure('error', background=C['error_bg'])
    ed.tag_configure('fault', background=C['fault_bg'],
                      foreground=C['error'], underline=1)
    ed.tag_configure('proposal', foreground=C['proposal'], font=MONO_I)


# toggle_theme -- the VIEW menu and the toolbar.  The choice is
# written to this machine's settings, the same small file as the
# database folder, so the next time the editor opens it is as it was
# left.  EDITOR_THEME is this window's key.  The spreadsheet reads
# SHEET_THEME and not this one.
def toggle_theme():
    apply_theme('light' if theme == 'dark' else 'dark')
    try:
        _settings.set('EDITOR_THEME', theme.upper())
    except Exception:
        pass


# apply_theme -- put the named palette on screen.  'light' or 'dark'.
def apply_theme(name):
    global theme, C
    name = 'dark' if name and name == 'dark' else 'light'
    if name == theme and mw:
        return
    fro = THEME_DARK if theme == 'dark' else THEME_LIGHT
    to = THEME_DARK if name == 'dark' else THEME_LIGHT
    a_map = {fro[k].upper(): to[k] for k in fro
             if fro[k].upper() != to[k].upper()}
    C = dict(to)
    theme = name
    if not mw:
        return
    paint_theme(a_map, mw)
    try:
        bar = mw.cget('menu')
        if bar:
            paint_theme(a_map, bar)
    except tk.TclError:
        pass
    style_editor_tags()
    for name_ in ('ERRORS', 'WARNINGS', 'NODES'):
        if name_ in LIST and LIST[name_].winfo_exists():
            LIST[name_].configure(
                background=C['paper'],
                foreground=C['error'] if name_ == 'ERRORS'
                else C['warn'] if name_ == 'WARNINGS' else C['ink'],
                selectbackground=C['select'], selectforeground=C['ink'])
    for draw in theme_draws:
        try:
            draw()
        except Exception:
            pass
    from hardycross.window import results as _re
    from hardycross.window import graph as _gr
    from hardycross.window import database as _db
    if _gr.GV.get('canvas'):
        try:
            _gr.graph_draw()
        except Exception:
            pass
    if restabs:
        try:
            _re.fill_results()
        except Exception:
            pass
    restyle_validation()
    if _db.DBV.get('path'):
        try:
            _db.db_header()
        except Exception:
            pass
    if _db.DBV.get('tabs'):
        try:
            _db.db_fill()
        except Exception:
            pass
    if _db.DBV.get('formrow'):
        try:
            _db.db_form()
        except Exception:
            pass
    if _db.DBV.get('btn'):
        try:
            _db.db_state()
        except Exception:
            pass
    if ed:
        recolour()
    if 'THEME' in btn:
        btn['THEME'].configure(text='LIGHT MODE' if theme == 'dark'
                               else 'DARK MODE')
    if view_menu:
        view_menu.entryconfigure(
            0, label='LIGHT MODE' if theme == 'dark' else 'DARK MODE',
            background=C['paper'], foreground=C['ink'],
            activebackground=C['select'], activeforeground=C['ink'])
    mw.option_add('*Background', C['paper'])
    mw.option_add('*Foreground', C['ink'])
    mw.option_add('*Menu.background', C['paper'])
    mw.option_add('*Menu.foreground', C['ink'])
    mw.option_add('*Menu.activeBackground', C['select'])
    mw.option_add('*Menu.activeForeground', C['ink'])
    update_actions()


# paint_theme -- one widget, its children, and the menus hanging off
# it.  A colour that belongs to the palette being left is swapped for
# the same role in the palette being entered.  Anything else (white
# text on a blue button, a system colour) is left.
def _as_widget(w):
    # A menu hangs off a menubar entry as its path name, a plain string.
    # Perl Tk blessed paths into widgets; Python needs nametowidget.
    if isinstance(w, str):
        try:
            return mw.nametowidget(w)
        except tk.TclError:
            return None
    return w


def paint_theme(a_map, w, seen=None):
    if seen is None:
        seen = set()
    w = _as_widget(w)
    if w is None or not w.winfo_exists():
        return
    path_ = w._w
    if path_ in seen:
        return
    seen.add(path_)
    opts = ('background', 'foreground', 'activebackground',
            'activeforeground', 'highlightbackground', 'highlightcolor',
            'insertbackground', 'selectbackground', 'selectforeground',
            'disabledforeground', 'troughcolor', 'readonlybackground')
    fg = {'foreground', 'activeforeground', 'selectforeground',
          'disabledforeground', 'insertbackground', 'highlightcolor'}
    for opt in opts:
        try:
            v = w.cget(opt)
        except tk.TclError:
            continue
        if v is None or not v:
            continue
        hexv = str(v).upper()
        # White as a foreground is the text on a blue button, and the
        # tick in a check box.  White as a background is the paper.
        if hexv == '#FFFFFF' and opt in fg:
            continue
        n = a_map.get(hexv)
        if n is None:
            continue
        try:
            w.configure(**{opt: n})
        except tk.TclError:
            pass
    if isinstance(w, tk.Menu):
        try:
            w.configure(background=C['paper'], foreground=C['ink'],
                        activebackground=C['select'],
                        activeforeground=C['ink'])
        except tk.TclError:
            pass
        try:
            end = w.index('end')
        except tk.TclError:
            end = None
        if end is not None:
            for i in range(end + 1):
                if w.type(i) == 'separator':
                    continue
                try:
                    w.entryconfigure(i, background=C['paper'],
                                     foreground=C['ink'],
                                     activebackground=C['select'],
                                     activeforeground=C['ink'])
                except tk.TclError:
                    pass
                try:
                    sub = w.entrycget(i, 'menu')
                except tk.TclError:
                    sub = None
                if sub:
                    paint_theme(a_map, sub, seen)
    if isinstance(w, tk.Menubutton):
        try:
            sub = w.cget('menu')
        except tk.TclError:
            sub = None
        if sub:
            paint_theme(a_map, sub, seen)
    if isinstance(w, tk.Canvas):
        for id_ in w.find_all():
            for opt in ('fill', 'outline'):
                try:
                    v = w.itemcget(id_, opt)
                except tk.TclError:
                    continue
                if v is None or not v or str(v) == 'black':
                    continue
                if str(v).upper() == '#FFFFFF':
                    continue
                n = a_map.get(str(v).upper())
                if n is None:
                    continue
                try:
                    w.itemconfigure(id_, **{opt: n})
                except tk.TclError:
                    pass
    if isinstance(w, tk.Text):
        for tag in w.tag_names():
            if tag == 'sel':
                continue
            for opt in ('foreground', 'background'):
                try:
                    v = w.tag_cget(tag, opt)
                except tk.TclError:
                    continue
                if v is None or not v:
                    continue
                if str(v).upper() == '#FFFFFF':
                    continue
                n = a_map.get(str(v).upper())
                if n is None:
                    continue
                try:
                    w.tag_configure(tag, **{opt: n})
                except tk.TclError:
                    pass
    for child in w.winfo_children():
        paint_theme(a_map, child, seen)


# restyle_validation -- the VALIDATION table keeps the colours it was
# built with.  The rows are built again, so a fault reads in the
# palette now on screen.  The result tables are rebuilt by
# fill_results.
def restyle_validation():
    from hardycross.window import results as _re
    if not _re.vtable:
        return
    _re.fill_validation()


#==============================================================================
# Start.  Run as a program, build the window and enter the event loop.
# The driver phcp_editor.py calls main(); importing this module alone
# (as tools/test_editor_window.py does) starts nothing.
#==============================================================================
def main(file=None):
    build_window()
    if file is not None:
        open_path(file)
    mw.mainloop()
