"""tools -- the QUICK TOOLS tab of the PHCP editor: a port of
HardyCross/Window/Tools.pm.

Five small calculators, in three columns.

  VELOCITY        a pipe type and size, and a flow: the bore and velocity
  FITTINGS        a pipe type and size, and fittings: equivalent lengths
  K-FACTOR        any two of K, Q and P: the third
  K CONVERTER     a K-factor in any K unit, in all of them
  PRESSURE LOSS   a pipe type and size, and a flow: the friction loss by
                  Hazen-Williams and Darcy-Weisbach, side by side

Each answers as it is typed, in the units set in the PROJECT tab
(taken afresh each time the tab is opened).  Independent of the model,
like the GRAPH tab.  Every number is hardycross.tools's -- the
database's bores and the solver's own loss formulas -- so a pipe here
behaves exactly as in a model; this is drawing.

The Perl tied the entries straight into its %qt scalars; here the
fields are StringVars copied into QT on each key release, and the
drop-downs go through a Setting, a one-element list whose [0] write
reaches the dict.
"""

import tkinter as tk

from hardycross import parse, pipedata
from hardycross import phc
from hardycross import tools
from hardycross import win
from hardycross.window.project import Setting

QT = {'VEL': {'type': 'ASAM', 'size': '', 'flow': ''},
      'FIT': {'type': 'ASAM', 'size': '', 'spec': '', 'c': ''},
      'K': {'k': '', 'q': '', 'p': '', 'unit': ''},
      'KCONV': {'value': '', 'from': 'GPM/PSI'},
      'LOSS': {'type': 'ASAM', 'size': '', 'flow': '', 'length': '',
               'c': '', 'eps': ''}}
QTW = {}                         # the widgets, by tool and field


def build_tools(page):
    bar = tk.Frame(page, background=win.C['paper'])
    bar.pack(side='top', fill='x', padx=win.px(14),
             pady=win.px([10, 8]))
    QTW['units'] = tk.Label(bar, text='', font=win.UI_S_N,
                           background=win.C['paper'],
                           foreground=win.C['muted'])
    QTW['units'].pack(side='left')
    QTW['db'] = tk.Label(bar, text='', font=win.UI_S_N,
                         background=win.C['paper'],
                         foreground=win.C['muted'])
    QTW['db'].pack(side='right')
    win.rule(page, 'x', side='top')
    # The calculators scroll, as the PROJECT tab does, so none is cut
    # short on a short window or with the results pane dragged up.
    sb = win.flat_scrollbar(page, 'vertical', side='right', fill='y')
    cv = tk.Canvas(page, background=win.C['paper'], highlightthickness=0,
                   borderwidth=0)
    cv.pack(fill='both', expand=1)
    row = tk.Frame(cv, background=win.C['paper'])
    cv.create_window(win.px(14), win.px(10), window=row, anchor='nw')
    sb.configure(command=cv.yview)
    cv.configure(yscrollcommand=sb.set)

    def region(e=None):
        cv.configure(
            scrollregion=(0, 0, row.winfo_reqwidth() + win.px(28),
                          row.winfo_reqheight() + win.px(20)))

    row.bind('<Configure>', region)
    win.wheel_target(cv)
    col = {i: tk.Frame(row, background=win.C['paper']) for i in (1, 2, 3)}
    for i in (1, 2, 3):
        col[i].pack(side='left', fill='y', anchor='n',
                    padx=win.px([0, 30]))

    def card(tool, title, about, column, lines):
        c = tk.Frame(col[column], background=win.C['paper'])
        c.pack(side='top', fill='x', anchor='n', pady=win.px([0, 18]))
        tk.Label(c, text=title, font=win.UI_B, background=win.C['paper'],
                 foreground=win.C['ink'], anchor='w').pack(fill='x')
        win.rule(c, 'x', pady=win.px([4, 4]))
        tk.Label(c, text=about, font=win.UI_S_N, background=win.C['paper'],
                 foreground=win.C['muted'], anchor='w', justify='left',
                 wraplength=win.px(360)).pack(fill='x', pady=win.px([0, 8]))
        g = tk.Frame(c, background=win.C['paper'])
        g.pack(fill='x', anchor='w')
        QTW[tool] = {'problems': tk.Label(
            c, text='', font=win.UI, background=win.C['paper'],
            foreground=win.C['error'], anchor='w', justify='left',
            wraplength=win.px(360))}
        QTW[tool]['problems'].pack(fill='x', pady=win.px([8, 4]))
        t = tk.Text(c, font=win.MONO, height=lines, width=48,
                    wrap='none', relief='flat', borderwidth=0,
                    highlightthickness=0, background=win.C['panel'],
                    foreground=win.C['ink'], padx=win.px(10),
                    pady=win.px(8), cursor=win.POINTER, takefocus=0)
        t.pack(fill='x')
        t.tag_configure('head', font=win.MONO_B)
        t.tag_configure('big', font=win.MONO_B, foreground=win.C['accent'])
        t.tag_configure('muted', foreground=win.C['muted'])
        t.tag_configure('warn', foreground=win.C['error'], font=win.MONO_B)
        QTW[tool]['result'] = t
        return g

    r = [0]

    def label(g, text):
        tk.Label(g, text=text, font=win.UI, background=win.C['paper'],
                 foreground=win.C['muted'], anchor='w').grid(
                     row=r[0], column=0, sticky='w', pady=win.px(3),
                     padx=win.px([0, 12]))

    def entry(g, tool, field, width=10, note=None):
        var = tk.StringVar(value=QT[tool].get(field.lower()) or '')

        def on_key(e, tool=tool, field=field, var=var):
            QT[tool][field.lower()] = var.get()
            tools_update(tool)

        e = win.flat_entry(g, var, width)
        e.grid(row=r[0], column=1, sticky='w', pady=win.px(3),
               ipady=win.px(2))
        e.bind('<KeyRelease>', on_key)
        QTW[tool].setdefault('vars', {})[field] = var
        # A note naming a unit -- U:FLOW, U:LENGTH -- is redrawn when
        # the PROJECT tab's units change (tools_refresh).
        if note:
            l = tk.Label(g, text='', font=win.UI_S_N,
                         background=win.C['paper'],
                         foreground=win.C['faint'], anchor='w')
            l.grid(row=r[0], column=2, sticky='w', padx=win.px([8, 0]))
            QTW.setdefault('notes', []).append((l, note))
        QTW[tool].setdefault('field', {})[field] = e
        r[0] += 1
        return e

    def pipe(g, tool):
        # PIPE TYPE and SIZE: the type a drop-down of the database's
        # types and BORE; the size a drop-down of that type's sizes, or
        # for BORE a field for the bore in mm.
        label(g, 'PIPE TYPE')
        t = win.drop_down(g, Setting(QT[tool], 'type'),
                          tools.pipe_types(),
                          lambda: _type_chosen(tool))
        t.grid(row=r[0], column=1, sticky='w', pady=win.px(3))
        r[0] += 1
        QTW[tool].setdefault('field', {})['TYPE'] = t
        label(g, 'SIZE')
        f = tk.Frame(g, background=win.C['paper'])
        f.grid(row=r[0], column=1, columnspan=2, sticky='w',
               pady=win.px(3))
        r[0] += 1
        mb = tk.Menubutton(f, text='', font=win.MONO, relief='flat',
                           borderwidth=0, highlightthickness=1,
                           highlightbackground=win.C['line'],
                           background=win.C['paper'],
                           activebackground=win.C['hover'],
                           foreground=win.C['ink'], anchor='w', width=11,
                           padx=win.px(6), pady=win.px(3), indicatoron=0,
                           cursor='hand2')
        m = tk.Menu(mb, tearoff=0, font=win.MONO, relief='flat',
                    borderwidth=1, activeborderwidth=0,
                    background=win.C['paper'], foreground=win.C['ink'],
                    activebackground=win.C['select'],
                    activeforeground=win.C['ink'])
        mb.configure(menu=m)
        var = tk.StringVar(value=QT[tool].get('size') or '')

        def _size_written(*_a, tool=tool, var=var):
            # the var is the field: every write (typed, or by the program)
            # is the size, in the tool's fields.
            QT[tool]['size'] = var.get()

        var.trace_add('write', _size_written)

        def on_key(e, tool=tool):
            tools_update(tool)          # recalculated as it is typed

        be = win.flat_entry(f, var, 10)
        be.bind('<KeyRelease>', on_key)
        bn = tk.Label(f, text='', font=win.UI_S_N, background=win.C['paper'],
                      foreground=win.C['faint'])
        QTW.setdefault('notes', []).append((bn, 'BORE, U:SIZE'))
        QTW[tool]['size_mb'] = mb
        QTW[tool]['size_menu'] = m
        QTW[tool]['size_entry'] = be
        QTW[tool]['size_var'] = var
        QTW[tool]['size_note'] = bn
        QTW[tool].setdefault('field', {})['SIZE'] = mb
        tools_sizes(tool)

    def _type_chosen(tool):
        QT[tool]['size'] = ''
        tools_sizes(tool)
        tools_update(tool)

    # VELOCITY.
    g = card('VEL', 'VELOCITY',
             "THE VELOCITY IN A PIPE AT A FLOW.  THE BORE IS THE DATABASE'S "
             "FOR THE TYPE AND SIZE.", 1, 8)
    r[0] = 0
    pipe(g, 'VEL')
    label(g, 'FLOW')
    entry(g, 'VEL', 'FLOW', 10, 'U:FLOW')

    # FITTINGS.
    g = card('FIT', 'FITTINGS',
             "EQUIVALENT LENGTHS FROM THE DATABASE, AS FOR A MODEL'S PIPE: "
             "THE SAME SOURCE AND CORRECTIONS.  FITTINGS AS ON A PIPE LINE: "
             "2E 1T G (G GATE, C CHECK, B BUTTERFLY VALVE).", 1, 8)
    r[0] = 0
    pipe(g, 'FIT')
    label(g, 'FITTINGS')
    entry(g, 'FIT', 'SPEC', 24)
    label(g, 'C FACTOR')
    entry(g, 'FIT', 'C', 10, "BLANK: THE TYPE'S")

    # K-FACTOR.
    g = card('K', 'K-FACTOR',
             'Q = K x SQRT(P).  GIVE ANY TWO OF K, Q AND P; THE THIRD IS '
             'FOUND.  CLEAR A FIELD TO SOLVE FOR IT.', 2, 7)
    r[0] = 0
    label(g, 'K')
    entry(g, 'K', 'K', 10)
    label(g, 'K UNITS')
    ku = win.drop_down(g, Setting(QT['K'], 'unit'),
                       list(phc.UNIT_CHOICES['KFACTOR']),
                       lambda: tools_update('K'))
    ku.grid(row=r[0], column=1, sticky='w', pady=win.px(3))
    r[0] += 1
    QTW['K'].setdefault('field', {})['UNIT'] = ku
    tk.Label(g, text='K80 IS 8 IN LPM/KPA, 80 IN LPM/BAR, 5.6 IN GPM/PSI.',
             font=win.UI_S_N, background=win.C['paper'],
             foreground=win.C['faint'], anchor='w',
             wraplength=win.px(340), justify='left').grid(
                 row=r[0], column=0, columnspan=3, sticky='w',
                 pady=win.px([0, 4]))
    r[0] += 1
    label(g, 'FLOW Q')
    entry(g, 'K', 'Q', 10, 'U:FLOW')
    label(g, 'PRESSURE P')
    entry(g, 'K', 'P', 10, 'U:PRESSURE')

    # K CONVERTER.
    g = card('KCONV', 'K-FACTOR CONVERTER',
             'A K-FACTOR IN ANY K UNIT, IN ALL OF THEM: US (GPM PER ROOT '
             'PSI) TO METRIC, OR BACK.  K5.6 (US) IS K80 (METRIC, L/MIN '
             'PER ROOT BAR).', 2, 5)
    r[0] = 0
    label(g, 'K')
    entry(g, 'KCONV', 'VALUE', 10)
    label(g, 'GIVEN IN')
    kf = win.drop_down(g, Setting(QT['KCONV'], 'from'),
                       list(phc.UNIT_CHOICES['KFACTOR']),
                       lambda: tools_update('KCONV'))
    kf.grid(row=r[0], column=1, sticky='w', pady=win.px(3))
    r[0] += 1

    # PRESSURE LOSS.
    g = card('LOSS', 'PRESSURE LOSS',
             'THE FRICTION LOSS IN A PIPE AT A FLOW, BY HAZEN-WILLIAMS AND '
             "BY DARCY-WEISBACH, WITH THE SOLVER'S OWN FORMULAS.  BLANK: 1 "
             "M OF PIPE, AND THE TYPE'S C AND ROUGHNESS FROM THE DATABASE.",
             3, 11)
    r[0] = 0
    pipe(g, 'LOSS')
    label(g, 'FLOW')
    entry(g, 'LOSS', 'FLOW', 10, 'U:FLOW')
    label(g, 'LENGTH')
    entry(g, 'LOSS', 'LENGTH', 10, 'U:LENGTH - BLANK: 1 M')
    label(g, 'C FACTOR (HW)')
    entry(g, 'LOSS', 'C', 10)
    label(g, 'ROUGHNESS (DW)')
    entry(g, 'LOSS', 'EPS', 10, "U:SIZE - BLANK: THE TYPE'S")

    tools_refresh()


# tools_refresh -- on opening the tab: the database may have changed in
# the DATABASE tab since, so the sizes and the answers are taken from it
# afresh.
def tools_refresh():
    if 'db' not in QTW:
        return
    parse.ensure_db()
    QTW['db'].configure(text='PIPE DATA: %s' %
                        pipedata.dataset().upper())
    # The units: the PROJECT tab's, named in the bar and beside each
    # field.
    u = tool_units()
    QTW['units'].configure(
        text='UNITS AS IN THE PROJECT TAB: FLOW %s, PRESSURE %s, '
             'LENGTH %s, SIZE %s.  INDEPENDENT OF THE MODEL.'
        % tuple(unit_name(q, u[q])
                for q in ('FLOW', 'PRESSURE', 'LENGTH', 'SIZE')))
    import re as _re
    for l, note in QTW.get('notes', []):
        text = _re.sub(r'U:(\w+)',
                      lambda m: unit_name(m.group(1), u.get(m.group(1))),
                      note)
        l.configure(text=text)
    if not QT['K']['unit']:
        QT['K']['unit'] = u['KFACTOR']
    for fn in win.dd_refresh:
        fn()
    for tool in ('VEL', 'FIT', 'LOSS'):
        if QT[tool]['type'] != tools.BORE and \
                QT[tool]['size'] not in tools.sizes(QT[tool]['type']):
            QT[tool]['size'] = ''
        tools_sizes(tool)
    for tool in ('VEL', 'FIT', 'K', 'KCONV', 'LOSS'):
        tools_update(tool)


# tool_units -- the PROJECT tab's units, each unset one at its default.
def tool_units():
    return {q: (win.settings['units'].get(q) or phc.UNIT_DEFAULT[q])
            for q in ('FLOW', 'PRESSURE', 'LENGTH', 'SIZE', 'KFACTOR')}


_UNIT_NAMES = {'LPM': 'L/MIN', 'LPS': 'L/S', 'M3H': 'M3/H', 'GPM': 'GPM',
              'KPA': 'KPA', 'BAR': 'BAR', 'MPA': 'MPA', 'PSI': 'PSI'}


# unit_name -- a unit as the window shows it: L/MIN, M HEAD,
# L/MIN/KPA^0.5.
def unit_name(q, u):
    if q == 'PRESSURE':
        return 'M HEAD' if u == 'M' else _UNIT_NAMES.get(u, u)
    if q == 'KFACTOR':
        a, b = u.split('/')
        return '%s/%s^0.5' % (_UNIT_NAMES.get(a, a), _UNIT_NAMES.get(b, b))
    return _UNIT_NAMES.get(u, u)


# tools_sizes -- the SIZE choice for a tool's pipe type: a drop-down of
# the type's sizes, or for BORE a field for the bore.
def tools_sizes(tool):
    w = QTW[tool]
    type_ = QT[tool]['type']
    w['size_menu'].delete(0, 'end')
    if type_ == tools.BORE:
        w['size_mb'].pack_forget()
        w['size_entry'].pack(side='left', ipady=win.px(2))
        w['size_note'].pack(side='left', padx=win.px([8, 0]))
        w['field']['SIZE'] = w['size_entry']
    else:
        w['size_entry'].pack_forget()
        w['size_note'].pack_forget()
        w['size_mb'].pack(side='left')
        for dn in tools.sizes(type_):
            su = tool_units()['SIZE']

            def pick(dn=dn, tool=tool):
                QT[tool]['size'] = str(dn)
                tools_update(tool)

            w['size_menu'].add_command(
                label='DN%-5s %8s %s' % (
                    dn,
                    ('%.3f' if su == 'IN' else '%.1f') %
                    tools.show('SIZE', float(pipedata.bore(type_, dn)),
                               {'SIZE': su}),
                    unit_name('SIZE', su)),
                command=pick)
        w['field']['SIZE'] = w['size_mb']
    tools_show_size(tool)


def tools_show_size(tool):
    if QT[tool]['type'] == tools.BORE:
        return
    s = QT[tool]['size']
    QTW[tool]['size_mb'].configure(
        text='%-9s %s' % ('DN%s' % s if s else 'CHOOSE', '\u25BE'))


#------------------------------------------------------------------------------
# tools_update -- a calculator worked out again: its problems, each
# field at fault shaded, and its answer.
#------------------------------------------------------------------------------
def tools_update(tool):
    w = QTW.get(tool)
    if not w:
        return
    if w.get('size_mb'):
        tools_show_size(tool)
    f = QT[tool]
    u = tool_units()
    # sync any StringVars (typing) into the fields
    for field, var in (w.get('vars') or {}).items():
        f[field.lower()] = var.get()
    if tool == 'VEL':
        res = tools.velocity(**f, units=u)
    elif tool == 'FIT':
        res = tools.fittings(**f)
    elif tool == 'K':
        f2 = dict(f)
        f2['unit'] = f.get('unit') or u['KFACTOR']
        res = tools.kfactor(**f2, units=u)
    elif tool == 'KCONV':
        res = tools.kconvert(**f)
    else:
        res = tools.loss(**f, units=u)

    def sh(q, v):
        return tools.show(q, v, u)

    un = {q: unit_name(q, u[q]) for q in u}
    w['last'] = res
    for e in w.get('field', {}).values():
        try:
            e.configure(highlightbackground=win.C['line'])
        except tk.TclError:
            pass
    t = w['result']
    t.configure(state='normal')
    t.delete('1.0', 'end')
    # Before anything is typed there is nothing to complain about:
    # show what is needed, quietly, rather than a list of problems.
    empty = not any((v or '').strip() for k, v in f.items()
                    if k not in ('type', 'unit', 'from'))
    if not res.get('ok'):
        if empty:
            w['problems'].configure(text='')
            t.insert('end', 'GIVE ANY TWO OF K, Q AND P.' if tool == 'K'
                     else 'GIVE A K.' if tool == 'KCONV'
                     else 'CHOOSE A SIZE AND GIVE THE FITTINGS.'
                     if tool == 'FIT'
                     else 'CHOOSE A SIZE AND GIVE A FLOW.', 'muted')
        else:
            w['problems'].configure(
                text='\n'.join(e[1] for e in res['errors']))
            for e in res['errors']:
                fw = w.get('field', {}).get(e[0])
                if fw is None:
                    continue
                try:
                    fw.configure(highlightbackground=win.C['error'])
                except tk.TclError:
                    pass
            t.insert('end', 'NO ANSWER UNTIL THE FIELDS ARE PUT RIGHT.',
                     'muted')
        t.configure(state='disabled')
        return res
    w['problems'].configure(text='')

    def line(l, v, tag=None):
        t.insert('end', '%-18s' % l, 'muted')
        t.insert('end', '%s\n' % v, tag or ())

    if tool == 'VEL':
        line('VELOCITY', '%.2f M/S' % res['velocity'], 'big')
        t.insert('end', '\n')
        line('BORE', '%.4g %s' % (sh('SIZE', res['bore']), un['SIZE']))
        line('AREA', '%.6f M2' % res['area'])
        if u['FLOW'] == 'LPM':
            extra = '  (%.3f L/S)' % (res['q'] / 60)
        else:
            extra = '  (%.1f L/MIN)' % res['q']
        line('FLOW', '%.4g %s' % (sh('FLOW', res['q']), un['FLOW']) + extra)
        t.insert('end', '\n')
        lim = win.settings['options'].get('VEL_LIMIT')
        import re as _re
        if not (lim and _re.match(r'^\s*[\d.]+\s*$', str(lim))
                and float(lim) > 0):
            lim = 6
        lim = float(lim)
        line('AGAINST THE LIMIT', '%.1f M/S: %s' % (
            lim, 'ABOVE IT' if res['velocity'] > lim else 'WITHIN IT'),
            'head' if res['velocity'] > lim else None)
        t.insert('end', "(THE PROJECT TAB'S VELOCITY LIMIT)", 'muted')
    elif tool == 'KCONV':
        for x in ('GPM/PSI', 'LPM/BAR', 'LPM/KPA', 'LPS/BAR', 'LPS/KPA'):
            line('US' if x == 'GPM/PSI' else 'METRIC',
                 '%.3f %s' % (res['all'][x], unit_name('KFACTOR', x)),
                 None if x == res['from'] else 'big')
    elif tool == 'FIT':
        for row in res['rows']:
            t.insert('end', '%2d x %-4s %-26.26s %6.2f M\n' % (
                row['count'], row['code'], row['label'], row['total']))
        extra = '' if u['LENGTH'] == 'M' else '  (%.4g %s)' % (
            sh('LENGTH', res['total']), un['LENGTH'])
        line('TOTAL', '%.2f M' % res['total'] + extra, 'big')
        t.insert('end', 'FROM %s\n' % res['source'], 'muted')
    elif tool == 'K':
        name = {'K': 'K', 'Q': 'FLOW Q', 'P': 'PRESSURE P'}
        val = {'K': '%.3f %s' % (res['k'], unit_name('KFACTOR',
                                                     res['unit'])),
               'Q': '%.4g %s' % (sh('FLOW', res['q']), un['FLOW']),
               'P': '%.4g %s' % (sh('PRESSURE', res['p']), un['PRESSURE'])}
        line('%s =' % name[res['solved']], val[res['solved']], 'big')
        t.insert('end', '\n')
        for k in ('K', 'Q', 'P'):
            if k != res['solved']:
                line(name[k], val[k])
        t.insert('end', '\n')
        line('K, LPM/KPA', '%.3f' % res['k_kpa'])
        line('K, LPM/BAR', '%.3f' % res['k_bar'])
        line('K, GPM/PSI', '%.3f' % res['k_us'])
    else:
        t.insert('end', '%-18s%13s %13s\n' % (
            '', 'HAZEN-WILLIAMS', 'DARCY-WEISBACH'), 'head')
        t.insert('end', '%-18s' % ('LOSS, %s/M' % un['PRESSURE']), 'muted')
        t.insert('end', '%13.5g %14.5g\n' % (
            sh('PRESSURE', res['hw']['per_m']),
            sh('PRESSURE', res['dw']['per_m'])), 'big')
        if res['length'] != 1:
            t.insert('end', '%-18s' % ('OVER %g %s' % (
                sh('LENGTH', res['length']), un['LENGTH'])), 'muted')
            t.insert('end', '%13.5g %14.5g\n' % (
                sh('PRESSURE', res['hw']['total']),
                sh('PRESSURE', res['dw']['total'])), 'big')
            t.insert('end', '%-18s%13s %14s\n' % (
                '', un['PRESSURE'], un['PRESSURE']), 'muted')
        line('DW AGAINST HW', '%+.1f %%' % res['diff_pct'])
        line('BORE, VELOCITY', '%.4g %s, %.2f M/S' % (
            sh('SIZE', res['bore']), un['SIZE'], res['velocity']))
        line('C, ROUGHNESS', '%g (HW), %.4g %s (DW)' % (
            res['c'], sh('SIZE', res['eps']), un['SIZE']))
        # An assumed roughness is said so, in red: none given, none
        # published.
        if res.get('eps_src') == 'DEFAULT':
            line('', 'ROUGHNESS ASSUMED: THE PROGRAM DEFAULT', 'warn')
        line('REYNOLDS NUMBER', '%.0f, %s' % (
            res['dw']['re'], res['dw']['regime']))
        line('FRICTION FACTOR', '%.5f (DARCY)' % res['dw']['f'])
    t.configure(state='disabled')
    return res
