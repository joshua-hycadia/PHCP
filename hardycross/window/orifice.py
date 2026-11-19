"""orifice -- the ORIFICE PLATE tab of the PHCP editor: a port of
HardyCross/Window/Orifice.pm.

This tab is shared by the editor window and the spreadsheet window in
the Perl; here it is part of the editor window, taking its widget
helpers from hardycross.win.

Two calculators, side by side.

  SIZE THE PLATE       a pipe, a flow and a net loss: the bore, as OPP
                       sizes one, rounded to the bore step
  DROP ACROSS A PLATE  a pipe, a flow and a bore: the net loss, as OFD

Each answers as it is typed, in the units set in the PROJECT tab.  A
blank CD is 0.596.  A blank bore step is the PROJECT tab's ORIF_STEP,
or 0.5 mm when that is blank.  Independent of the model, like QUICK
TOOLS.  Nothing here decides a bore or a loss.  That is
hardycross.tools.plate, which calls the solver's own orifice
routines, so the two windows and a model cannot size a plate
differently.
"""

import tkinter as tk

from hardycross import pipedata
from hardycross import tools
from hardycross import win
from hardycross.window.project import Setting
from hardycross.window.tools import tool_units, unit_name

OP = {'SIZE': {'type': 'ASAM', 'size': '', 'flow': '', 'drop': '',
               'cd': '', 'step': ''},
      'DROP': {'type': 'ASAM', 'size': '', 'flow': '', 'bore': '',
               'cd': ''}}
OPW = {}


def build_orifice(page):
    bar = tk.Frame(page, background=win.C['paper'])
    bar.pack(side='top', fill='x', padx=win.px(14), pady=win.px([10, 8]))
    OPW['units'] = tk.Label(bar, text='', font=win.UI_S_N,
                           background=win.C['paper'],
                           foreground=win.C['muted'], anchor='w',
                           justify='left')
    OPW['units'].pack(side='left', fill='x')
    win.rule(page, 'x', side='top')
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
    col = {m: tk.Frame(row, background=win.C['paper']) for m in
           ('SIZE', 'DROP')}
    for m in ('SIZE', 'DROP'):
        col[m].pack(side='left', fill='y', anchor='n',
                    padx=win.px([0, 36]))

    def card(mode, title, about, lines):
        c = tk.Frame(col[mode], background=win.C['paper'])
        c.pack(side='top', fill='x', anchor='n')
        tk.Label(c, text=title, font=win.UI_B, background=win.C['paper'],
                 foreground=win.C['ink'], anchor='w').pack(fill='x')
        win.rule(c, 'x', pady=win.px([4, 4]))
        tk.Label(c, text=about, font=win.UI_S_N, background=win.C['paper'],
                 foreground=win.C['muted'], anchor='w', justify='left',
                 wraplength=win.px(460)).pack(fill='x',
                                              pady=win.px([0, 8]))
        g = tk.Frame(c, background=win.C['paper'])
        g.pack(fill='x', anchor='w')
        OPW[mode] = {'problems': tk.Label(
            c, text='', font=win.UI, background=win.C['paper'],
            foreground=win.C['error'], anchor='w', justify='left',
            wraplength=win.px(460))}
        OPW[mode]['problems'].pack(fill='x', pady=win.px([8, 4]))
        # Word wrap, so a long note stays inside the card.  The figures
        # themselves are one line: the label column plus the value fit
        # the width.
        t = tk.Text(c, font=win.MONO, height=lines, width=54,
                    wrap='word', relief='flat', borderwidth=0,
                    highlightthickness=0, background=win.C['panel'],
                    foreground=win.C['ink'], padx=win.px(10),
                    pady=win.px(8), cursor=win.POINTER, takefocus=0)
        t.pack(fill='x')
        t.tag_configure('head', font=win.MONO_B)
        t.tag_configure('big', font=win.MONO_B, foreground=win.C['accent'])
        t.tag_configure('muted', foreground=win.C['muted'])
        t.tag_configure('warn', foreground=win.C['error'], font=win.MONO_B)
        OPW[mode]['result'] = t
        return g

    r = [0]

    def label(g, text):
        tk.Label(g, text=text, font=win.UI, background=win.C['paper'],
                 foreground=win.C['muted'], anchor='w').grid(
                     row=r[0], column=0, sticky='w', pady=win.px(3),
                     padx=win.px([0, 12]))

    def entry(g, mode, field, width=10, note=None):
        var = tk.StringVar(value=OP[mode].get(field.lower()) or '')

        def on_key(e, mode=mode, field=field, var=var):
            OP[mode][field.lower()] = var.get()
            orifice_update(mode)

        e = win.flat_entry(g, var, width)
        e.grid(row=r[0], column=1, sticky='w', pady=win.px(3),
               ipady=win.px(2))
        e.bind('<KeyRelease>', on_key)
        OPW[mode].setdefault('vars', {})[field] = var
        if note:
            l = tk.Label(g, text='', font=win.UI_S_N,
                         background=win.C['paper'],
                         foreground=win.C['faint'], anchor='w')
            l.grid(row=r[0], column=2, sticky='w', padx=win.px([8, 0]))
            OPW.setdefault('notes', []).append((l, note, mode, field))
        OPW[mode].setdefault('field', {})[field] = e
        r[0] += 1
        return e

    def pipe(g, mode):
        # The pipe: its type a drop-down of the database's types and
        # BORE, its size a drop-down of that type's sizes, or for BORE
        # a field for the bore.
        label(g, 'PIPE TYPE')
        t = win.drop_down(g, Setting(OP[mode], 'type'),
                          tools.pipe_types(),
                          lambda: _type_chosen(mode))
        t.grid(row=r[0], column=1, sticky='w', pady=win.px(3))
        r[0] += 1
        OPW[mode].setdefault('field', {})['TYPE'] = t
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
        var = tk.StringVar(value=OP[mode].get('size') or '')

        def on_key(e, mode=mode, var=var):
            OP[mode]['size'] = var.get()
            orifice_update(mode)

        be = win.flat_entry(f, var, 10)
        be.bind('<KeyRelease>', on_key)
        bn = tk.Label(f, text='', font=win.UI_S_N,
                      background=win.C['paper'],
                      foreground=win.C['faint'])
        OPW.setdefault('notes', []).append((bn, 'PIPE BORE, U:SIZE',
                                            mode, ''))
        OPW[mode]['size_mb'] = mb
        OPW[mode]['size_menu'] = m
        OPW[mode]['size_entry'] = be
        OPW[mode]['size_var'] = var
        OPW[mode]['size_note'] = bn
        OPW[mode].setdefault('field', {})['SIZE'] = mb
        orifice_sizes(mode)

    def _type_chosen(mode):
        OP[mode]['size'] = ''
        orifice_sizes(mode)
        orifice_update(mode)

    r[0] = 0
    g = card('SIZE', 'SIZE THE PLATE',
             'THE BORE FOR THIS NET LOSS AT THIS FLOW, AS OPP SIZES IT.  '
             'ROUNDED TO THE STEP.', 16)
    pipe(g, 'SIZE')
    label(g, 'FLOW')
    entry(g, 'SIZE', 'FLOW', 10, 'U:FLOW')
    label(g, 'DROP')
    entry(g, 'SIZE', 'DROP', 10, 'U:PRESSURE')
    label(g, 'CD')
    entry(g, 'SIZE', 'CD', 10, 'BLANK: 0.596')
    label(g, 'BORE STEP')
    entry(g, 'SIZE', 'STEP', 10, 'BLANK: PROJECT')

    r[0] = 0
    g = card('DROP', 'DROP ACROSS A PLATE',
             'THE NET LOSS ACROSS THIS BORE AT THIS FLOW, AS OFD WORKS '
             'IT OUT.', 14)
    pipe(g, 'DROP')
    label(g, 'FLOW')
    entry(g, 'DROP', 'FLOW', 10, 'U:FLOW')
    label(g, 'PLATE BORE')
    entry(g, 'DROP', 'BORE', 10, 'U:SIZE')
    label(g, 'CD')
    entry(g, 'DROP', 'CD', 10, 'BLANK: 0.596')

    orifice_refresh()


# orifice_step_default -- the bore step in millimetres when the field
# is left blank: the PROJECT tab's ORIF_STEP, in the size unit, or 0.5
# mm.
def orifice_step_default():
    u = tool_units()
    raw = win.settings['options'].get('ORIF_STEP')
    if raw is not None and str(raw).strip() and tools.is_num(raw) \
            and float(raw) > 0:
        return float(raw) * tools.factor('SIZE', u['SIZE'])
    return 0.5


# orifice_refresh -- on opening the tab.  Units and the blank bore step
# come from the PROJECT tab, and the sizes from the database as it
# stands now.
def orifice_refresh():
    if 'units' not in OPW:
        return
    import re as _re
    u = tool_units()
    OPW['units'].configure(
        text='UNITS AS IN THE PROJECT TAB: FLOW %s, PRESSURE %s, SIZE %s.'
             '  INDEPENDENT OF THE MODEL.'
        % tuple(unit_name(q, u[q])
                for q in ('FLOW', 'PRESSURE', 'SIZE')))
    step = tools.show('SIZE', orifice_step_default(), u)
    for w, t, mode, field in OPW.get('notes', []):
        if t == 'BLANK: PROJECT':
            w.configure(text='BLANK: %g %s' % (step, unit_name('SIZE',
                                                              u['SIZE'])))
        else:
            w.configure(text=_re.sub(
                r'U:(\w+)',
                lambda m: unit_name(m.group(1), u.get(m.group(1))), t))
    for fn in win.dd_refresh:
        fn()
    for mode in ('SIZE', 'DROP'):
        if OP[mode]['type'] != tools.BORE and \
                OP[mode]['size'] not in tools.sizes(OP[mode]['type']):
            OP[mode]['size'] = ''
        orifice_sizes(mode)
        orifice_update(mode)


# orifice_sizes -- the SIZE choice for a card's pipe type.
def orifice_sizes(mode):
    w = OPW.get(mode)
    if not w:
        return
    type_ = OP[mode]['type']
    try:
        if w['size_menu'].index('end') is not None:
            w['size_menu'].delete(0, 'end')
    except tk.TclError:
        pass
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

            def pick(dn=dn, mode=mode):
                OP[mode]['size'] = str(dn)
                orifice_update(mode)

            w['size_menu'].add_command(
                label='DN%-5s %8s %s' % (
                    dn,
                    ('%.3f' if su == 'IN' else '%.1f') %
                    tools.show('SIZE', float(pipedata.bore(type_, dn)),
                               {'SIZE': su}),
                    unit_name('SIZE', su)),
                command=pick)
        w['field']['SIZE'] = w['size_mb']
    orifice_show_size(mode)


def orifice_show_size(mode):
    if OP[mode]['type'] == tools.BORE:
        return
    s = OP[mode]['size']
    OPW[mode]['size_mb'].configure(
        text='%-9s %s' % ('DN%s' % s if s else 'CHOOSE', '\u25BE'))


# orifice_update -- one card worked out again.
def orifice_update(mode):
    w = OPW.get(mode)
    if not w:
        return
    orifice_show_size(mode)
    f = OP[mode]
    u = tool_units()
    for field, var in (w.get('vars') or {}).items():
        f[field.lower()] = var.get()
    res = tools.plate(**f, mode=mode, units=u,
                     step_default=orifice_step_default())

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
    watched = ('size', 'flow', 'drop', 'cd', 'step') if mode == 'SIZE' \
        else ('size', 'flow', 'bore', 'cd')
    empty = not any((f.get(k) or '').strip() for k in watched)
    if not res.get('ok'):
        if empty:
            w['problems'].configure(text='')
            t.insert('end', 'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A '
                     'DROP.' if mode == 'SIZE'
                     else 'CHOOSE A PIPE SIZE, AND GIVE A FLOW AND A '
                     'BORE.', 'muted')
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

    # The label column is wide enough for the longest name, plus a gap,
    # so a value never sits against its label.  CD and the bore step
    # come straight after the answer: they are what the bore was worked
    # from, and the results pane leaves room for about ten lines
    # before a scroll.
    def line(l, v, tag=None):
        t.insert('end', '%-24s' % l, 'muted')
        t.insert('end', '%s\n' % v, tag or ())

    line('BORE', '%.4g %s' % (sh('SIZE', res['bore']), un['SIZE']), 'big')
    if mode == 'SIZE' and abs(res['bore'] - res['bore_exact']) > 1e-6:
        line('ROUNDED FROM', '%.4g %s' % (sh('SIZE', res['bore_exact']),
                                          un['SIZE']))
    line('NET LOSS', '%.4g %s' % (sh('PRESSURE', res['drop']),
                                  un['PRESSURE']), 'big')
    if mode == 'SIZE':
        line('ASKED', '%.4g %s' % (sh('PRESSURE', res['target']),
                                   un['PRESSURE']))
    if res['cd_default']:
        line('CD', '%.3f  (THE DEFAULT)' % res['cd'])
    else:
        line('CD', '%.4g' % res['cd'])
    if mode == 'SIZE':
        line('BORE STEP', '%.4g %s' % (sh('SIZE', res['step']),
                                       un['SIZE'])
             if res['step'] > 0 else 'NOT ROUNDED')
    if u['FLOW'] == 'LPM':
        extra = '  (%.3f L/S)' % (res['q'] / 60)
    else:
        extra = '  (%.1f L/MIN)' % res['q']
    line('FLOW', '%.4g %s' % (sh('FLOW', res['q']), un['FLOW']) + extra)
    line('PIPE BORE', '%.4g %s' % (sh('SIZE', res['pipedia']),
                                   un['SIZE']))
    line('BETA, D/D', '%.3f' % res['beta'])
    line('VELOCITY IN THE BORE', '%.2f M/S' % res['velocity'])
    line('VELOCITY IN THE PIPE', '%.2f M/S' % res['pipe_velocity'])
    import re as _re
    lim = win.settings['options'].get('VEL_LIMIT')
    if not (lim and _re.match(r'^\s*[\d.]+\s*$', str(lim))
            and float(lim) > 0):
        lim = 6
    lim = float(lim)
    line('PIPE AGAINST THE LIMIT', '%.1f M/S: %s' % (
        lim, 'ABOVE IT' if res['pipe_velocity'] > lim else 'WITHIN IT'),
        'warn' if res['pipe_velocity'] > lim else None)
    line('TAPPING DIFFERENTIAL', '%.4g %s' % (
        sh('PRESSURE', res['differential']), un['PRESSURE']))
    line('PERMANENT-LOSS RATIO', '%.3f' % res['ratio'])
    t.insert('end', '\n')
    if res['limit'] == 'WIDE':
        t.insert('end', 'A BORE ALMOST AS LARGE AS THE PIPE STILL DROPS '
                 'MORE THAN ASKED.\n', 'warn')
    elif res['limit'] == 'TIGHT':
        t.insert('end', 'EVEN A VERY SMALL BORE DOES NOT DROP THIS '
                 'MUCH.\n', 'warn')
    elif not res['fits']:
        t.insert('end', 'THE ROUNDED BORE IS NOT SMALLER THAN THE '
                 'PIPE.\n', 'warn')
    elif mode == 'SIZE':
        delta = res['drop'] - res['target']
        if abs(delta) >= 0.05:
            t.insert('end', 'AT THE ROUNDED BORE THE NET LOSS IS %.4g %s '
                     '%s WHAT WAS ASKED.\n' % (
                         abs(sh('PRESSURE', delta)), un['PRESSURE'],
                         'ABOVE' if delta > 0 else 'BELOW'), 'muted')
        t.insert('end', 'THE BORE IS ROUNDED TO THE STEP, AS AN OPP '
                 'PLATE IS.\n', 'muted')
    t.insert('end', 'THE NET LOSS IS THE TAPPING DIFFERENTIAL TIMES THE '
             'ISO 5167 PERMANENT-LOSS RATIO.\n', 'muted')
    t.configure(state='disabled')
    return res
