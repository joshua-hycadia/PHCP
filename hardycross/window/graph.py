"""graph -- the GRAPH tab of the PHCP editor: a port of
HardyCross/Window/Graph.pm.

A Q^1.85 water supply graph from figures typed in.  Independent of the
model: nothing here is read from the network or from a calculation,
and nothing here changes them.  The supply as measured (A), the loss
from the supply to the datum (B) and a pump (D) are typed as points;
the tab draws them with the supply available at the datum (C = A - B)
and with the pump (E = C + D), and up to ten duty points, each with the
pressure available to it and its margin.  PRINT TO PDF writes the
sheet; SAVE GRAPH keeps the figures in a .phg file.  Every decision --
what is wrong, where the curves go -- is hardycross.graph's; this is
drawing.

Left, the figures; right, the graph as it will print, redrawn as they
are typed, and under it what is wrong with them, if anything.  A field
at fault is shaded; a click on a problem goes to its field.

The Perl tied each field to a scalar inside $graph; here the fields
are StringVars copied into the graph dict on each key release, and
graph_load writes the values back into the vars.
"""

import tkinter as tk

from hardycross import graph as gmod
from hardycross import win

graph = gmod.new_graph()
GV = {'fields': {}, 'saved': ''}


def build_graph(page):
    bar = tk.Frame(page, background=win.C['paper'])
    bar.pack(side='top', fill='x', padx=win.px(14), pady=win.px([10, 8]))
    GV['btn'] = {}
    GV['btn']['NEW'] = win.flat_button(bar, 'NEW GRAPH', graph_new)
    GV['btn']['NEW'].pack(side='left', padx=win.px([0, 4]))
    GV['btn']['OPEN'] = win.flat_button(bar, 'OPEN GRAPH...', graph_open)
    GV['btn']['OPEN'].pack(side='left', padx=win.px(4))
    GV['btn']['SAVE'] = win.flat_button(bar, 'SAVE GRAPH...', graph_save)
    GV['btn']['SAVE'].pack(side='left', padx=win.px(4))
    tk.Frame(bar, background=win.C['line'], width=1,
             height=win.px(22)).pack(side='left', padx=win.px(10))
    GV['btn']['PDF'] = win.flat_button(bar, 'PRINT TO PDF...', graph_pdf,
                                       primary=True)
    GV['btn']['PDF'].pack(side='left', padx=win.px(4))
    GV['file'] = tk.Label(bar, text='', font=win.UI, background=win.C['paper'],
                          foreground=win.C['muted'])
    GV['file'].pack(side='left', padx=win.px(12))
    tk.Label(bar, text='INDEPENDENT OF THE MODEL - NOTHING HERE COMES FROM '
             'THE NETWORK.', font=win.UI_S_N, background=win.C['paper'],
             foreground=win.C['muted']).pack(side='right')
    win.rule(page, 'x', side='top')

    hp = win.divider(page, 'horizontal')
    left = tk.Frame(page, background=win.C['paper'])
    right = tk.Frame(page, background=win.C['paper'])

    # The figures, in a scrolling form.
    sb = win.flat_scrollbar(left, 'vertical', side='right', fill='y')
    cv = tk.Canvas(left, background=win.C['paper'], highlightthickness=0,
                   borderwidth=0)
    cv.pack(fill='both', expand=1)
    wrap = tk.Frame(cv, background=win.C['paper'])
    cv.create_window(win.px(14), win.px(10), window=wrap, anchor='nw')
    sb.configure(command=cv.yview)
    cv.configure(yscrollcommand=sb.set)

    def region(e=None):
        cv.configure(
            scrollregion=(0, 0, wrap.winfo_reqwidth() + win.px(28),
                          wrap.winfo_reqheight() + win.px(20)))

    wrap.bind('<Configure>', region)
    win.wheel_target(cv)
    GV['form'] = cv
    GV['wrap'] = wrap

    def heading(parent, text, note=None):
        h = tk.Frame(parent, background=win.C['paper'])
        h.pack(fill='x', pady=win.px([10, 0]))
        tk.Label(h, text=text, font=win.UI_B, background=win.C['paper'],
                 foreground=win.C['ink']).pack(side='left')
        if note:
            tk.Label(h, text=note, font=win.UI_S_N,
                     background=win.C['paper'],
                     foreground=win.C['muted']).pack(side='left',
                                                    padx=win.px([8, 0]))
        win.rule(parent, 'x', pady=win.px([3, 6]))

    def _sync(name):
        var = GV['vars'][name]
        if name in gmod.PROJECT:
            graph['project'][name] = var.get()
        elif name in gmod.AXIS:
            graph['axis'][name] = var.get()
        else:
            # a curve point A3Q or a duty field DUTY2Q
            for c in gmod.CURVES:
                if name.startswith(c) and name[1:-1].isdigit() \
                        and name[-1] in 'QP':
                    i = int(name[1:-1]) - 1
                    graph[c][i][0 if name[-1] == 'Q' else 1] = var.get()
                    return
            if name.startswith('DUTY'):
                import re as _re
                m = _re.match(r'DUTY(\d+)([LDQP])$', name)
                if m:
                    i = int(m.group(1)) - 1
                    j = 'LDQP'.index(m.group(2))
                    graph['duty'][i][j] = var.get()

    def field(g, name, var, width, row, col):
        # The Perl tied the entry straight into the graph's figures;
        # a write on the var is copied into them at once.
        def on_write(*_):
            if GV.get('refilling'):
                return
            _sync(name)
            graph_changed()

        var.trace_add('write', on_write)
        e = win.flat_entry(g, var, width)
        e.grid(row=row, column=col, sticky='w', pady=win.px(2),
               padx=win.px([0, 6]), ipady=win.px(2))
        GV['fields'][name] = e
        GV.setdefault('vars', {})[name] = var
        return e

    def label(g, text, row, col, head=False, span=1):
        import re as _re
        l = tk.Label(g, text=text, font=win.UI_S if head else win.UI,
                     background=win.C['paper'], foreground=win.C['muted'],
                     anchor='w')
        l.grid(row=row, column=col, sticky='w', padx=win.px([0, 10]),
               columnspan=span)
        if _re.search(r'U:', text):
            GV.setdefault('ulabels', []).append((l, text))

    def _var(get):
        return tk.StringVar(value=get() or '')

    # The sheet: project details and the axes.
    heading(wrap, 'SHEET')
    g = tk.Frame(wrap, background=win.C['paper'])
    g.pack(fill='x')
    r = 0
    for k in gmod.PROJECT:
        label(g, gmod.PROJECT_LABEL[k], r, 0)
        var = _var(lambda k=k: graph['project'].get(k))
        field(g, k, var, 30, r, 1)
        r += 1
    r = 0
    # The units: the PROJECT tab's when a graph is begun; kept with it.
    for q in ('FLOW', 'PRESSURE'):
        label(g, '%s UNIT' % q, r, 2)
        from hardycross.window.project import Setting
        dd = win.drop_down(g, Setting(graph['units'], q),
                           list(gmod.FLOW_UNITS if q == 'FLOW'
                                else gmod.PRESSURE_UNITS),
                           graph_changed)
        dd.grid(row=r, column=3, sticky='w', pady=win.px(2))
        r += 1
    for k in gmod.AXIS:
        label(g, gmod.AXIS_LABEL[k] +
              (', U:FLOW' if k == 'QMAX' else ', U:PRESSURE'), r, 2)
        var = _var(lambda k=k: graph['axis'].get(k))
        field(g, k, var, 8, r, 3)
        r += 1
    label(g, 'AXES LEFT BLANK ARE WORKED OUT FROM THE FIGURES', r, 2,
          span=2)

    # The curves: three tables side by side.
    heading(wrap, 'CURVES', 'FLOWS RISING FROM ROW TO ROW, NO GAPS')
    cf = tk.Frame(wrap, background=win.C['paper'])
    cf.pack(fill='x')
    note = {'A': 'AT LEAST TWO POINTS', 'B': 'ONE POINT: A LOSS LINE '
            'THROUGH 0', 'D': 'FROM CHURN, NO FLOW; OR NONE'}
    for c in gmod.CURVES:
        t = tk.Frame(cf, background=win.C['paper'])
        t.pack(side='left', anchor='n', padx=win.px([0, 22]))
        tk.Label(t, text='%s  %s' % (c, gmod.CURVE_NAME[c]),
                 font=win.UI_B, background=win.C['paper'],
                 foreground=win.C['ink'], anchor='w').pack(fill='x')
        tk.Label(t, text=note[c], font=win.UI_S_N,
                 background=win.C['paper'], foreground=win.C['muted'],
                 anchor='w').pack(fill='x', pady=win.px([0, 4]))
        tg = tk.Frame(t, background=win.C['paper'])
        tg.pack(anchor='w')
        label(tg, '', 0, 0, head=True)
        label(tg, 'FLOW U:FLOW', 0, 1, head=True)
        label(tg, 'PRESSURE U:PRESSURE', 0, 2, head=True)
        for i in range(gmod.ROWS):
            tk.Label(tg, text=i + 1, font=win.UI_S_N,
                     background=win.C['paper'],
                     foreground=win.C['faint']).grid(
                         row=i + 1, column=0, sticky='e',
                         padx=win.px([0, 6]))
            vq = _var(lambda c=c, i=i: graph[c][i][0])
            f = field(tg, '%s%dQ' % (c, i + 1), vq, 9, i + 1, 1)
            vp = _var(lambda c=c, i=i: graph[c][i][1])
            p = field(tg, '%s%dP' % (c, i + 1), vp, 9, i + 1, 2)
            # A problem names the row: both its fields are shaded.
            GV.setdefault('rows', {})['%s%d' % (c, i + 1)] = [f, p]

    # The duty points.
    heading(wrap, 'DUTY POINTS', 'EACH A FLOW NEEDED AT A PRESSURE; THE '
            'NUMBER IS DRAWN ON THE GRAPH')
    dg = tk.Frame(wrap, background=win.C['paper'])
    dg.pack(anchor='w')
    label(dg, 'NO', 0, 0, head=True)
    label(dg, 'DESCRIPTION', 0, 1, head=True)
    label(dg, 'FLOW U:FLOW', 0, 2, head=True)
    label(dg, 'PRESSURE U:PRESSURE', 0, 3, head=True)
    for i in range(gmod.DUTY_ROWS):
        ws = []
        for j, (nm, wd) in enumerate((('L', 5), ('D', 34), ('Q', 9),
                                     ('P', 9))):
            v = _var(lambda i=i, j=j: graph['duty'][i][j])
            ws.append(field(dg, 'DUTY%d%s' % (i + 1, nm), v, wd,
                            i + 1, j))
        GV['rows']['DUTY%d' % (i + 1)] = ws
    for k in gmod.AXIS:
        GV['rows'][k] = [GV['fields'][k]]

    # The graph, and what is wrong.
    GV['problems'] = tk.Listbox(right, font=win.MONO, height=5,
                               relief='flat', borderwidth=0,
                               highlightthickness=0,
                               background=win.C['paper'],
                               foreground=win.C['error'],
                               selectbackground=win.C['error_bg'],
                               selectforeground=win.C['error'],
                               activestyle='none')
    GV['problems'].pack(side='bottom', fill='x', padx=win.px(10),
                         pady=win.px([0, 8]))
    GV['problems'].bind('<ButtonRelease-1>',
                        lambda e: graph_go_to_problem())
    win.rule(right, 'x', side='bottom')
    GV['canvas'] = tk.Canvas(right, background=win.C['paper'],
                             highlightthickness=0, borderwidth=0)
    GV['canvas'].pack(fill='both', expand=1, padx=win.px(6),
                       pady=win.px(6))
    GV['canvas'].bind('<Configure>', lambda e: graph_draw())

    hp.add(left, width=win.px(820))
    hp.add(right)
    hp.pack(fill='both', expand=1)
    GV['saved'] = graph_text()
    graph_changed()


# graph_text -- the figures as they would be saved, to tell whether
# they changed.
def graph_text():
    f = ([graph['project'].get(k) or '' for k in gmod.PROJECT]
         + [graph['axis'].get(k) or '' for k in gmod.AXIS]
         + [graph['units'].get(k) or '' for k in ('FLOW', 'PRESSURE')])
    for c in gmod.CURVES:
        f += [v or '' for row in graph[c] for v in row]
    f += [v or '' for row in graph['duty'] for v in row]
    return '\x00'.join(f)


def graph_modified():
    return graph_text() != GV['saved']


# graph_unit_labels -- every label naming a unit, in the graph's
# units.
def graph_unit_labels():
    import re as _re
    u = gmod.units(graph)
    for l, text in GV.get('ulabels', []):
        l.configure(text=_re.sub(
            r'U:(FLOW|PRESSURE)',
            lambda m: gmod.UNIT_NAME[u[m.group(1)]].upper(), text))


# graph_changed -- after any change: capitals, a fresh check, the
# shading, the problems list and the drawing.  Run a moment after
# typing stops.
def graph_changed():
    if GV.get('job'):
        try:
            win.mw.after_cancel(GV['job'])
        except tk.TclError:
            pass
    GV['job'] = win.mw.after(200, _refresh_now)


def _refresh_now():
    GV['job'] = None
    graph_refresh()


def refresh():
    graph_refresh()


def graph_refresh():
    GV['refilling'] = True            # the refills are not the user's typing
    for k in gmod.PROJECT:
        if graph['project'].get(k):
            graph['project'][k] = graph['project'][k].upper()
        _refill_var(k)
    for i in range(gmod.DUTY_ROWS):
        for j in (0, 1):
            if graph['duty'][i][j]:
                graph['duty'][i][j] = graph['duty'][i][j].upper()
    for i in range(gmod.DUTY_ROWS):
        for j in range(4):
            _refill_duty_var(i, j)
    for c in gmod.CURVES:
        for i in range(gmod.ROWS):
            _refill_curve_var(c, i)
    for k in gmod.AXIS:
        _refill_var(k, axis=True)
    GV['refilling'] = False
    graph_unit_labels()
    chk = gmod.check(graph)
    GV['check'] = chk
    for w in GV['fields'].values():
        w.configure(background=win.C['paper'])
    GV['problems'].delete(0, 'end')
    for e in chk['errors']:
        where, msg = e[0], e[1]
        for w in GV.get('rows', {}).get(where, []):
            w.configure(background=win.C['fault_bg'])
        GV['problems'].insert('end', msg)
    if not chk['errors']:
        GV['problems'].insert('end', '')
    GV['btn']['PDF'].configure(state='normal' if chk['ok'] else 'disabled')
    graph_set_title()
    graph_draw()


def _refill_var(k, axis=False):
    if k in GV.get('vars', {}):
        if axis:
            GV['vars'][k].set(graph['axis'].get(k) or '')
        else:
            GV['vars'][k].set(graph['project'].get(k) or '')


def _refill_duty_var(i, j):
    name = 'DUTY%d%s' % (i + 1, 'LDQP'[j])
    if name in GV.get('vars', {}):
        GV['vars'][name].set(graph['duty'][i][j])


def _refill_curve_var(c, i):
    for col, nm in ((0, 'Q'), (1, 'P')):
        name = '%s%d%s' % (c, i + 1, nm)
        if name in GV.get('vars', {}):
            GV['vars'][name].set(graph[c][i][col] or '')


def graph_set_title():
    name = GV.get('path') or 'UNTITLED.PHG'
    name = name.replace('\\', '/').rsplit('/', 1)[-1]
    GV['file'].configure(text=name.upper() +
                         (' *' if graph_modified() else ''))


# graph_go_to_problem -- a click on a problem: focus the field at
# fault.
def graph_go_to_problem():
    sel = GV['problems'].curselection()
    if not sel:
        return
    errors = GV['check']['errors']
    if sel[0] >= len(errors):     # the blank line shown when nothing is wrong
        return
    e = errors[sel[0]]
    rows = GV.get('rows', {}).get(e[0]) or []
    if not rows:
        return
    w = rows[0]
    w.focus_set()
    w.selection_range(0, 'end')
    # Scroll the form to it if it is out of sight.
    GV['form'].update()
    y = w.winfo_rooty() - GV['form'].winfo_rooty()
    if y < 0 or y > GV['form'].winfo_height() - win.px(30):
        at = (w.winfo_rooty() - GV['wrap'].winfo_rooty()) \
            / (GV['wrap'].winfo_reqheight() or 1)
        GV['form'].yview_moveto(at - 0.05 if at > 0.05 else 0)


#------------------------------------------------------------------------------
# graph_draw -- the graph on the canvas, as it will print: the same
# curves, styles and letters as hardycross.graph.write_pdf, scaled to
# the pane.
#------------------------------------------------------------------------------
def graph_draw():
    c = GV.get('canvas')
    if not c:
        return
    c.delete('all')
    W, H = c.winfo_width(), c.winfo_height()
    if W < 50 or H < 50:
        return
    chk = GV.get('check')
    if not chk:
        return
    if not chk['ok']:
        c.create_text(W / 2, H / 2,
                      text='THE GRAPH IS DRAWN WHEN THE FIGURES ARE '
                           'COMPLETE - SEE BELOW',
                      font=win.UI, fill=win.C['muted'])
        return
    sr = gmod.series(chk)
    # The key goes under the plot: a line for each curve and each duty
    # point.
    names = [n for n in 'ABCDE' if sr['lines'].get(n)]
    keyh = (len(names) + len(sr['duty'])) * win.px(15) + win.px(12)
    pl, pr = win.px(56), W - win.px(16)
    pt, pb = win.px(26), H - win.px(44) - keyh
    if pb - pt < win.px(60):
        return
    pw, ph = pr - pl, pb - pt
    qmax, pmax = sr['qmax'], sr['pmax']

    def X(q):
        return pl + ((q / qmax) ** 1.85 if q > 0 else 0) * pw

    def Y(p):
        return pb - p / pmax * ph

    for p in sr['yticks']:
        if p > pmax + 1e-9:
            continue
        c.create_line(pl, Y(p), pr, Y(p), fill=win.C['line'])
        c.create_text(pl - win.px(5), Y(p), text='%g' % p, anchor='e',
                       font=win.UI_S_N, fill=win.C['muted'])
    last = -1e9
    for q in sr['xticks']:
        if q > qmax + 1e-9:
            continue
        x = X(q)
        c.create_line(x, pt, x, pb, fill=win.C['line'])
        t = '%g' % q
        if x - win.px(4) * len(t) < last + win.px(6):
            continue
        c.create_text(x, pb + win.px(4), text=t, anchor='n',
                      font=win.UI_S_N, fill=win.C['muted'])
        last = x + win.px(4) * len(t)
    fu = gmod.UNIT_NAME[sr['units']['FLOW']].upper()
    pu = gmod.UNIT_NAME[sr['units']['PRESSURE']].upper()
    c.create_text(pl - win.px(5), pt - win.px(8),
                   text='PRESSURE, %s' % pu, anchor='w', font=win.UI_S,
                   fill=win.C['ink'])
    c.create_text((pl + pr) / 2, pb + win.px(26),
                   text='FLOW, %s, ON A FLOW^1.85 SCALE' % fu,
                   font=win.UI_S, fill=win.C['ink'])
    c.create_rectangle(pl, pt, pr, pb, outline=win.C['ink'])

    # Line styles as on the sheet: A thin, B dotted, C dashed, D
    # dash-dot; the curve designed against heavy and blue, so it reads
    # first on the screen.
    dash = {'A': '', 'B': '.', 'C': '-', 'D': '-.', 'E': '-'}
    along = {'A': 0.30, 'B': 0.62, 'C': 0.46, 'D': 0.78, 'E': 0.90}
    for n in names:
        design = n == sr['design']
        # Only the part inside the plot: the curve is cut into runs of
        # points between 0 and the top of the pressure axis.
        runs = [[]]
        for pt_ in sr['lines'][n]:
            if 0 <= pt_[1] <= pmax:
                runs[-1] += [X(pt_[0]), Y(pt_[1])]
            elif runs[-1]:
                runs.append([])
        for xy in [r for r in runs if len(r) >= 4]:
            kw = {'fill': win.C['accent'] if design else win.C['ink'],
                  'width': win.px(3) if design else 1}
            if not design and dash[n]:
                kw['dash'] = dash[n]
            c.create_line(*xy, tags=('curve', 'curve%s' % n), **kw)
    for n in names:
        at = None
        for pt_ in sr['lines'][n]:
            if X(pt_[0]) >= pl + along[n] * pw:
                at = pt_
                break
        if at is None or not (0 <= at[1] <= pmax):
            continue
        x, y = X(at[0]), Y(at[1]) - win.px(8)
        c.create_rectangle(x - win.px(6), y - win.px(7),
                           x + win.px(6), y + win.px(7),
                           fill=win.C['paper'], outline='')
        c.create_text(x, y, text=n, font=win.UI_B,
                      fill=win.C['accent'] if n == sr['design']
                      else win.C['ink'])
    r_ = win.px(3)
    for cn in sorted(sr['points']):
        for p in sr['points'][cn]:
            x, y = X(p[0]), Y(p[1])
            if p[1] > pmax:
                continue
            c.create_oval(x - r_, y - r_, x + r_, y + r_,
                          outline=win.C['ink'], fill=win.C['paper'])
    for d in sr['duty']:
        if d['q'] > qmax or d['p'] > pmax:
            continue
        x, y = X(d['q']), Y(d['p'])
        bad = d['margin'] < 0
        c.create_rectangle(x - r_, y - r_, x + r_, y + r_,
                           fill=win.C['error'] if bad else win.C['ink'],
                           outline='')
        c.create_text(x + win.px(6), y - win.px(6), text=d['label'],
                      anchor='w', font=win.UI_S,
                      fill=win.C['error'] if bad else win.C['ink'],
                      tags=('duty',))
    # The key, under the plot: each curve with its line, then each
    # duty point against the curve designed against.
    ky = pb + win.px(48)
    for n in names:
        design = n == sr['design']
        kw = {'fill': win.C['accent'] if design else win.C['ink'],
              'width': win.px(3) if design else 1}
        if not design and dash[n]:
            kw['dash'] = dash[n]
        c.create_line(pl, ky, pl + win.px(26), ky, **kw)
        c.create_text(pl + win.px(34), ky, anchor='w',
                      font=win.UI_S if design else win.UI_S_N,
                      tags=('key',),
                      fill=win.C['accent'] if design else win.C['ink'],
                      text='%s  %s%s' % (
                          n, gmod.CURVE_NAME[n],
                          ' - DESIGNED AGAINST' if design else ''))
        ky += win.px(15)
    for d in sr['duty']:
        c.create_rectangle(pl + win.px(10), ky - win.px(3),
                           pl + win.px(16), ky + win.px(3),
                           fill=win.C['error'] if d['margin'] < 0
                           else win.C['ink'], outline='')
        c.create_text(pl + win.px(34), ky, anchor='w', font=win.UI_S_N,
                      tags=('key',),
                      fill=win.C['error'] if d['margin'] < 0
                      else win.C['ink'],
                      text='%s  %.4g %s AT %.4g %s - %s HAS %.4g %s, '
                           '%s %.4g %s%s' % (
                               d['label'], d['q'], fu, d['p'], pu,
                               sr['design'], d['avail'], pu,
                               'SHORT BY' if d['margin'] < 0
                               else 'MARGIN', abs(d['margin']), pu,
                               '  (%s)' % d['desc'] if d['desc'] else ''))
        ky += win.px(15)


#------------------------------------------------------------------------------
# Files: NEW GRAPH, OPEN GRAPH, SAVE GRAPH, PRINT TO PDF.
#------------------------------------------------------------------------------
def graph_ok_to_discard():
    if not graph_modified():
        return True
    from tkinter import messagebox
    return messagebox.askyesno(
        title='UNSAVED GRAPH', icon='warning', type='yesno',
        message='THE GRAPH HAS UNSAVED CHANGES.  DISCARD THEM?')


# graph_load -- put a graph's figures in the tab.  The fields are
# tied to the graph held here, so the values are copied in, not the
# graph replaced.
def graph_load(g):
    for k in gmod.PROJECT:
        graph['project'][k] = g['project'].get(k, '')
    for k in gmod.AXIS:
        graph['axis'][k] = g['axis'].get(k, '')
    u = gmod.units(g)
    for q in ('FLOW', 'PRESSURE'):
        graph['units'][q] = u[q]
    for fn in win.dd_refresh:
        fn()
    for c in gmod.CURVES:
        for i in range(gmod.ROWS):
            for j in (0, 1):
                graph[c][i][j] = g[c][i][j]
    for i in range(gmod.DUTY_ROWS):
        for j in range(4):
            graph['duty'][i][j] = g['duty'][i][j]
    graph_refresh()


def graph_new():
    if not graph_ok_to_discard():
        return
    # A new graph takes the PROJECT tab's flow and pressure units.
    g = gmod.new_graph()
    for q in ('FLOW', 'PRESSURE'):
        if win.settings['units'].get(q):
            g['units'][q] = win.settings['units'][q]
    graph_load(g)
    GV['path'] = None
    GV['saved'] = graph_text()
    graph_refresh()
    win.message('NEW GRAPH')


def graph_open(file=None):
    if not graph_ok_to_discard():
        return
    if file is None:
        from tkinter import filedialog
        file = filedialog.askopenfilename(
            filetypes=[('PHCP GRAPH', '.phg')])
        if not file:
            return
    try:
        g = gmod.read_file(file)
    except Exception as e:
        win.message('GRAPH NOT OPENED: %s' % e, True)
        return
    graph_load(g)
    GV['path'] = file
    GV['saved'] = graph_text()
    graph_refresh()
    win.message('GRAPH OPENED: %s' % file)
    return True


def graph_save(file=None):
    if file is None:
        from tkinter import filedialog
        initial = (GV.get('path') or 'GRAPH.PHG').replace('\\', '/') \
            .rsplit('/', 1)[-1]
        file = filedialog.asksaveasfilename(
            defaultextension='.phg',
            filetypes=[('PHCP GRAPH', '.phg')], initialfile=initial)
        if not file:
            return
    try:
        gmod.write_file(graph, file)
    except Exception as e:
        win.message('GRAPH NOT SAVED: %s' % e, True)
        return
    GV['path'] = file
    GV['saved'] = graph_text()
    graph_set_title()
    win.message('GRAPH SAVED: %s' % file)
    return True


def graph_pdf(file=None):
    import re as _re
    graph_refresh()
    if not GV['check']['ok']:
        win.message('THE GRAPH HAS PROBLEMS - SEE THE LIST UNDER IT',
                    True)
        return
    if GV.get('path'):
        base = _re.sub(r'\.phg\Z', '', GV['path'].replace('\\', '/')
                      .rsplit('/', 1)[-1], flags=_re.I)
    else:
        base = 'GRAPH'
    if file is None:
        from tkinter import filedialog
        file = filedialog.asksaveasfilename(
            defaultextension='.pdf', initialfile='%s_GRAPH.PDF' % base,
            filetypes=[('PDF', '.pdf')])
        if not file:
            return
    try:
        gmod.write_pdf(graph, file,
                       model=(GV['path'].replace('\\', '/')
                              .rsplit('/', 1)[-1]
                              if GV.get('path') else ''))
        ok = True
        err = None
    except OSError as e:
        ok = False
        err = win.cannot_write(e, file)
    except Exception as e:
        ok = False
        err = e
    win.message('GRAPH WRITTEN TO %s' % file if ok
                else 'GRAPH NOT WRITTEN: %s' % err, not ok)
    return ok
