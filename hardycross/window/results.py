"""results -- the results tabs of the PHCP editor: a port of
HardyCross/Window/Results.pm.

VALIDATION, then PIPES, NODES and OUTLETS as sortable tables, and the
REPORT.

The Perl drew its tables on Tk's HList, which Tkinter has no match for
(Treeview headings drop a newline, so the two-line headings -- name
over unit -- cannot be reproduced; a spike confirmed it).  The tables
here are Text widgets in the same monospace face: the cells are padded
to one width in characters exactly as the Perl padded them for its
cells, so the layout reads the same -- numbers line up on the right
under a right-aligned heading, names on the left.  A click on a column
heading sorts on it (placed by character position under the click); a
second click reverses; on PIPES a right click on the headings opens the
column chooser.  HIDE NON-FLOWING PIPES and HIDE INACTIVE NODES leave
out what the tables mark as inactive.  The VALIDATION table wraps its
WHAT and WHY text, so it is a grid of labels in a scrolled canvas.  The
rows themselves come from hardycross.editor.result_tables.
"""

import tkinter as tk

from hardycross import editor
from hardycross import win

vtable = None                    # the VALIDATION table
GAP = 2                          # spaces between table columns


def build_results(parent):
    global restabs
    win.restabs = win.make_tabs(
        parent, ['VALIDATION', 'PIPES', 'NODES', 'OUTLETS', 'REPORT'])
    restabs = win.restabs
    opts = restabs['bar']
    win.checks['nodes'] = win.check_box(
        opts, 'HIDE INACTIVE NODES', win.hide_nodes,
        lambda: fill_table('NODES'))
    win.checks['nodes']['frame'].pack(side='right', padx=win.px([6, 14]))
    win.checks['pipes'] = win.check_box(
        opts, 'HIDE NON-FLOWING PIPES', win.hide_pipes,
        lambda: fill_table('PIPES'))
    win.checks['pipes']['frame'].pack(side='right', padx=win.px(6))

    build_validation(restabs['page']['VALIDATION'])
    for name in ('PIPES', 'NODES', 'OUTLETS'):
        win.TABLE[name] = {'hlist': None, 'box': None, 'data': None,
                           'sort': None, 'desc': 0,
                           'page': restabs['page'][name]}
        make_table(name)
    rp = restabs['page']['REPORT']
    rsb = win.flat_scrollbar(rp, 'vertical', side='right', fill='y')
    win.report = tk.Text(rp, wrap='none', font=win.MONO,
                        background=win.C['paper'],
                        foreground=win.C['ink'],
                        selectbackground=win.C['select'],
                        selectforeground=win.C['ink'], borderwidth=0,
                        highlightthickness=0, padx=win.px(12),
                        pady=win.px(8), state='disabled',
                        cursor=win.POINTER)
    win.report.pack(fill='both', expand=1)
    win.report.configure(yscrollcommand=rsb.set)
    rsb.configure(command=win.report.yview)
    win.wheel_target(win.report)
    for c in editor.pipe_columns({'q': '', 'p': '', 'l': ''}):
        win.pipe_show[c['key']] = c['show']


#------------------------------------------------------------------------------
# The tables: a Text widget per table, its rows padded exactly as the
# Perl padded its HList cells.
#------------------------------------------------------------------------------

def hlist(page, ncol):
    # A flat, scrolled Text for a table: (the widget, its box).
    box = tk.Frame(page, background=win.C['paper'])
    box.pack(fill='both', expand=1)
    vsb = win.flat_scrollbar(box, 'vertical', side='right', fill='y')
    hsb = win.flat_scrollbar(box, 'horizontal', side='bottom', fill='x')
    h = tk.Text(box, background=win.C['paper'], foreground=win.C['ink'],
                font=win.MONO, selectbackground=win.C['select'],
                selectforeground=win.C['ink'], borderwidth=0,
                highlightthickness=0, wrap='none', cursor=win.POINTER,
                takefocus=0, padx=win.px(8), pady=win.px(3))
    h.pack(fill='both', expand=1)
    h.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
    vsb.configure(command=h.yview)
    hsb.configure(command=h.xview)
    h.tag_configure('head', background=win.C['panel'], foreground=win.C['ink'],
                    font=win.MONO_B)
    h.tag_configure('headu', background=win.C['panel'],
                    foreground=win.C['ink'])
    h.tag_configure('bad', foreground=win.C['error'], font=win.MONO_B)
    h.tag_configure('band', background=win.C['select'])
    h.configure(state='disabled')
    win.wheel_target(h)
    return h, box


def columns(name):
    # The columns of a table as shown: all of them, or for PIPES the
    # ones the chooser has on.  Each with its index in the full row.
    t = win.TABLE.get(name)
    if not t or not t.get('data'):
        return []
    d = t['data']
    c = d['columns']
    return [(i, c[i]) for i in range(len(c))
            if name != 'PIPES' or win.pipe_show.get(c[i]['key'])]


def make_table(name):
    # (re)build a table's Text for its current columns.
    t = win.TABLE[name]
    if t.get('box'):
        t['box'].destroy()
        t['box'] = None
    cols = columns(name)
    # Before a calculation, or after one that failed, there are no
    # columns: one heading says how to get some.
    if not cols:
        cols = [(0, {'head': 'NO RESULTS - VALIDATE (F4), THEN CALCULATE '
                            '(F5)', 'unit': '', 'align': 'w'})]
    h, box = hlist(t['page'], len(cols))
    t['hlist'] = h
    t['box'] = box
    t['cols'] = cols
    # Widths come from every row, shown or hidden, so a column does not
    # jump when the HIDE boxes change.
    rows = t['data']['rows'] if t.get('data') else []
    t['width'] = {}
    for full, c in cols:
        w = 2 + len(c['head'])      # room for the sort mark
        if len(c.get('unit') or '') > w:
            w = len(c['unit'])
        for r in rows:
            if len(r['cells'][full]) > w:
                w = len(r['cells'][full])
        t['width'][full] = w

    def heading_click(e):
        if not t.get('data'):
            return
        pos = h.index('@%d,%d' % (e.x, e.y))
        line, col = pos.split('.')
        if int(line) != 1:
            return
        c = header_column(name, int(col))
        if c is not None:
            sort_table(name, cols[c][0])

    def right_click(e):
        if name == 'PIPES' and t.get('data'):
            column_menu()

    def row_click(e):
        # A clicked row is shown by its pale blue band alone.
        pos = h.index('@%d,%d' % (e.x, e.y))
        line = int(pos.split('.')[0])
        if line < 3:
            return
        h.tag_remove('band', '1.0', 'end')
        h.tag_add('band', '%d.0' % line, '%d.end' % line)

    h.bind('<ButtonRelease-1>', heading_click)
    h.bind('<ButtonRelease-3>', right_click)
    h.bind('<ButtonRelease-1>', row_click, add='+')
    fill_table(name)


def fill_table(name):
    t = win.TABLE[name]
    h = t.get('hlist')
    if not h:
        return
    h.configure(state='normal')
    h.delete('1.0', 'end')
    d = t.get('data')
    if not d:
        # No results: the one heading, and nothing else.
        _put_heading(h, t, pad_heading_only=True)
        h.configure(state='disabled')
        return
    rows = d['rows']
    if t.get('sort') is not None:
        rows = editor.sort_rows(rows, t['sort'], t['desc'])
    if (name == 'PIPES' and win.hide_pipes[0]) or \
       (name == 'NODES' and win.hide_nodes[0]):
        rows = [r for r in rows if r['active']]
    _put_heading(h, t)
    for r in rows:
        parts = []
        for full, c in t['cols']:
            parts.append(pad(r['cells'][full], t['width'][full],
                             c.get('align')))
        h.insert('end', '  '.join(parts) + '\n', 'row')
    # FAIL cells in red: re-tag them now that the line is laid out.
    for ln, r in enumerate(rows):
        acc = 0
        for full, c in t['cols']:
            w = t['width'][full]
            if r['cells'][full] == 'FAIL':
                h.tag_add('bad', '%d.%d' % (ln + 3, acc),
                          '%d.%d' % (ln + 3, acc + w))
            acc += w + GAP
    h.configure(state='disabled')


def _put_heading(h, t, pad_heading_only=False):
    if pad_heading_only or not t.get('data'):
        head = t['cols'][0][1]['head'] if t.get('cols') else ''
        h.insert('end', head + '\n', 'head')
        return
    # The heading: the name over the unit, each padded to the column's
    # width, on the grey panel.
    line1 = []
    line2 = []
    for full, c in t['cols']:
        w = t['width'][full]
        mark = ''
        if t.get('sort') is not None and t['sort'] == full:
            mark = ' \u25BC' if t['desc'] else ' \u25B2'
        line1.append(pad(c['head'] + mark, w, c.get('align')))
        line2.append(pad(c.get('unit') or '', w, c.get('align')))
    h.insert('end', '  '.join(line1) + '\n', 'head')
    h.insert('end', '  '.join(line2) + '\n', 'headu')


def pad(text, w, al):
    # Text padded to w characters: on the left for a right-aligned
    # ('e') column, on the right otherwise.
    text = str(text)
    return '%*s' % (w, text) if al == 'e' else '%-*s' % (w, text)


def header_column(name, col):
    # Which column a click on the headings is in, by its character
    # position.  Returns the column's index in the shown columns.
    t = win.TABLE[name]
    acc = 0
    for i, (full, c) in enumerate(t.get('cols') or []):
        acc += t['width'][full] + GAP
        if col < acc:
            return i
    return None


def sort_table(name, col):
    # Sort on a column; the same column again reverses.
    t = win.TABLE[name]
    t['desc'] = 0 if t.get('sort') is None or t['sort'] != col \
        else (0 if t['desc'] else 1)
    t['sort'] = col
    fill_table(name)              # the heading shows the sort mark


def column_menu():
    # The pipe column chooser: every column with a tick when shown.
    # NAME is always shown.
    m = tk.Menu(win.mw, tearoff=0, background=win.C['paper'],
                foreground=win.C['ink'], font=win.UI, relief='flat',
                borderwidth=1, activeborderwidth=0,
                activebackground=win.C['select'],
                activeforeground=win.C['ink'],
                selectcolor=win.C['accent'])

    def toggle(key, var):
        def go():
            win.pipe_show[key] = var.get()
            make_table('PIPES')
        return go

    for c in editor.pipe_columns({'q': '', 'p': '', 'l': ''}):
        var = tk.IntVar(win.mw, win.pipe_show.get(c['key'], 0))
        m.add_checkbutton(label=c['desc'], variable=var,
                          state='disabled' if c.get('fixed') else 'normal',
                          command=toggle(c['key'], var))
    m.tk_popup(m.winfo_pointerx(), m.winfo_pointery())
    return m


def fill_results():
    # The three tables from the last calculation (empty without one).
    tables = editor.result_tables(win.solved['net']) if win.solved else {}
    for name in ('PIPES', 'NODES', 'OUTLETS'):
        win.TABLE[name]['data'] = tables.get(name.lower())
        make_table(name)
    hide_counts()


def hide_counts():
    # How many rows each HIDE box would hide, beside it: (2), or (NONE)
    # with the box greyed when every pipe flows or every node is active,
    # so ticking a box that has nothing to hide is not mistaken for a
    # fault.
    for key, name in (('pipes', 'PIPES'), ('nodes', 'NODES')):
        c = win.checks.get(key)
        if not c:
            continue
        d = win.TABLE[name].get('data')
        if d is None:
            n = None
        else:
            n = sum(1 for r in d['rows'] if not r['active'])
        c['count'].configure(
            text='' if n is None else ('(%d)' % n if n else '(NONE)'))
        c['label'].configure(
            foreground=win.C['faint'] if n is not None and not n
            else win.C['ink'])


def hide_count_text(key):
    return win.checks[key]['count'].cget('text')


def table_rows(name):
    # What a table shows, row by row (for the tests).
    t = win.TABLE[name]
    h = t['hlist']
    out = []
    for ln in range(3, int(h.index('end - 1 chars').split('.')[0]) + 1):
        line = h.get('%d.0' % ln, '%d.end' % ln)
        if not line.strip():
            continue
        out.append([cell.strip() for cell in
                    _split_row(line, [full for full, c in t['cols']],
                               t['width'])])
    return out


def _split_row(line, fulls, widths):
    # Split a padded row line back into its cells.
    cells = []
    pos = 0
    for full in fulls:
        cells.append(line[pos:pos + widths[full]])
        pos += widths[full] + GAP
    return cells


def header_text(name, i):
    # The text of a table's heading $i (for the tests): the name over
    # the unit, as the Perl's two-line heading read.
    t = win.TABLE[name]
    h = t['hlist']
    line1 = h.get('1.0', '1.end')
    line2 = h.get('2.0', '2.end')
    if not t.get('data'):
        return line1
    cells1 = _split_row(line1, [f for f, c in t['cols']], t['width'])
    cells2 = _split_row(line2, [f for f, c in t['cols']], t['width'])
    return '%s\n%s' % (cells1[i].strip(), cells2[i].strip())


def table_heads(name):
    # The headings of a table as shown (for the tests).
    return [c['head'] for full, c in columns(name)]


#==============================================================================
# The VALIDATION tab: what VALIDATE found.  One row per problem - WHERE
# (the line, or the PROJECT tab), FIELD, WHAT IS WRONG and WHY.  A
# click on a row goes to it: the field at fault is selected in the
# editor, or the PROJECT tab field is focused.
#
# The Perl drew this on an HList with wrapped cells; here it is a grid
# of labels in a scrolled canvas, which wraps just as well.
#==============================================================================

def build_validation(page):
    global vtable
    box = tk.Frame(page, background=win.C['paper'])
    box.pack(fill='both', expand=1)
    vsb = win.flat_scrollbar(box, 'vertical', side='right', fill='y')
    canvas = tk.Canvas(box, background=win.C['paper'], highlightthickness=0,
                       borderwidth=0)
    canvas.pack(side='left', fill='both', expand=1)
    inner = tk.Frame(canvas, background=win.C['paper'])
    win_id = canvas.create_window(0, 0, window=inner, anchor='nw')
    vsb.configure(command=canvas.yview)
    canvas.configure(yscrollcommand=vsb.set)

    def resize(e):
        canvas.itemconfigure(win_id, width=canvas.winfo_width())

    canvas.bind('<Configure>', resize)

    def scroll(e):
        inner.update_idletasks()
        canvas.configure(scrollregion=canvas.bbox('all'))

    inner.bind('<Configure>', scroll)
    win.wheel_target(canvas)
    heads = ('WHERE', 'FIELD', 'WHAT IS WRONG', 'WHY')
    for i, htxt in enumerate(heads):
        tk.Label(inner, text=htxt, font=win.UI_B, anchor='w',
                 background=win.C['panel'], foreground=win.C['ink'],
                 padx=win.px(8), pady=win.px(6)).grid(
                     row=0, column=i, sticky='nsew')
    inner.columnconfigure(2, weight=1)
    inner.columnconfigure(3, weight=1)
    vtable = {'canvas': canvas, 'inner': inner, 'rows': [], 'labels': []}
    fill_validation()


def fill_validation():
    if not vtable:
        return
    inner = vtable['inner']
    for lab in vtable['labels']:
        lab.destroy()
    vtable['labels'] = []
    vtable['rows'] = []

    def add(where, field, what, why, good=False, muted=False):
        n = len(vtable['rows'])
        vtable['rows'].append((where, field, what, why))
        fg_what = win.C['error']
        font_what = win.UI_B
        fg_why = win.C['ink']
        if good:
            fg_what = fg_why = win.C['accent']
            font_what = win.UI_B
        elif muted:
            fg_what = fg_why = win.C['muted']
            font_what = win.UI
        specs = [
            (where, win.UI, win.C['ink'], 'w', 14),
            (field, win.UI, win.C['ink'], 'w', 16),
            (what, font_what, fg_what, 'w', 380),
            (why, win.UI, fg_why, 'w', 620),
        ]
        for col, (text, font, fg, anchor, wrap) in enumerate(specs):
            lab = tk.Label(inner, text=text, font=font, anchor=anchor,
                           background=win.C['paper'], foreground=fg,
                           padx=win.px(8), pady=win.px(4),
                           wraplength=win.px(wrap), justify='left')
            lab.grid(row=n + 1, column=col, sticky='nsew')
            lab.bind('<ButtonRelease-1>',
                     lambda e, n=n: go_to_fault(n))
            vtable['labels'].append(lab)

    if not win.validation:
        add('', '', 'NOT VALIDATED YET. PRESS VALIDATE (F4) TO CHECK THE '
               'INPUTS.', '', muted=True)
        return
    if not win.validation['items']:
        add('', '', 'NO PROBLEMS FOUND. CALCULATE (F5) IS NOW AVAILABLE.',
            '', good=True)
        return
    for it in win.validation['items']:
        where = ('PROJECT TAB' if it.get('tab')
                 else 'LINE %s' % it['line'] if it.get('line') is not None
                 else 'NETWORK')
        add(where, it.get('field') or '', it.get('what') or '',
            it.get('why') or '')


def go_to_fault(row):
    # A VALIDATION row clicked: to the field at fault.
    from hardycross.window import database as _db
    if not (win.validation and row is not None and isinstance(row, int)):
        return
    if row < 0 or row >= len(win.validation['items']):
        return
    it = win.validation['items'][row]
    if it.get('tab'):
        _db.show_field(it.get('field'))
        return
    if it.get('line') is not None:
        win.go_to_line(it['line'], it.get('start'), it.get('end'))


def validation_rows():
    # The VALIDATION table as text, row by row (for the tests).
    return [list(r) for r in (vtable['rows'] if vtable else [])]


def styles(h, **o):
    # The cell styles of the Perl's HList; here the colour roles the
    # tables use, so a theme change can restyle them.
    return {}
