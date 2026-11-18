"""project -- the PROJECT tab of the PHCP editor: a port of
HardyCross/Window/Project.pm.

The PROJECT tab: the title and project details, the units, the method
and the options.  Each field is tied to the settings; a change marks
the file modified and turns CALCULATE off until VALIDATE is run again.
Text is kept in capitals as it is typed.

Perl/Tk tied a scalar ref into the widget (-textvariable => \\
$settings->{title}), so the widget and the settings were one.  Tkinter
ties a StringVar, so the entries here copy the field into the settings
on each key release (uppercased, with the cursor kept where the user
put it), and load_settings writes the settings back into the vars.  The
drop-downs use a Setting, a one-element list whose [0] write goes
through to the settings dict.
"""

import tkinter as tk

from hardycross import editor
from hardycross import phc
from hardycross import win


class Setting(list):
    """A settings slot seen as a one-element list: reading [0] reads the
    slot and writing [0] writes it through to the dict."""

    def __init__(self, d, key):
        super().__init__([d.get(key) or ''])
        self.d = d
        self.key = key

    def __getitem__(self, i):
        # read live, so a settings load is seen at once
        if i == 0:
            return self.d.get(self.key) or ''
        return super().__getitem__(i)

    def __setitem__(self, i, v):
        super().__setitem__(i, v)
        self.d[self.key] = v


ENTRY_VARS = {}                   # field -> its StringVar, for load_settings
ENTRY_DIRTY = {}                 # fields whose var was written since the
                                 # last settings_changed: the var, not the
                                 # dict, is what the user changed
_REFILL = [False]                # a programmatic refill is not typing


def _mark(field):
    # a write on a field's var: the user typed there (a refill says so)
    def go(*_a):
        if not _REFILL[0]:
            ENTRY_DIRTY[field] = 1
    return go


def build_project(page):
    global project_canvas
    # The form scrolls: on a short window, or with the results pane
    # dragged up, the CALCULATION options run below the bottom edge.
    # A canvas holds the form, with the same thin scrollbar as the rest
    # of the window.
    sb = win.flat_scrollbar(page, 'vertical', side='right', fill='y')
    cv = tk.Canvas(page, background=win.C['paper'], highlightthickness=0,
                   borderwidth=0)
    cv.pack(fill='both', expand=1)
    wrap = tk.Frame(cv, background=win.C['paper'])
    cv.create_window(win.px(18), win.px(12), window=wrap, anchor='nw')
    sb.configure(command=cv.yview)
    cv.configure(yscrollcommand=sb.set)

    def region(e=None):
        cv.configure(
            scrollregion=(0, 0, wrap.winfo_reqwidth() + win.px(36),
                           wrap.winfo_reqheight() + win.px(24)))

    wrap.bind('<Configure>', region)
    win.wheel_target(cv)
    global project_canvas
    project_canvas = cv

    def column(title):
        c = tk.Frame(wrap, background=win.C['paper'])
        c.pack(side='left', fill='y', anchor='n', padx=win.px([0, 26]))
        tk.Label(c, text=title, font=win.UI_B, background=win.C['paper'],
                 foreground=win.C['ink'], anchor='w').pack(fill='x')
        win.rule(c, 'x', pady=win.px([4, 8]))
        g = tk.Frame(c, background=win.C['paper'])
        g.pack(fill='x')
        return g

    row = [0]

    def label(g, text):
        tk.Label(g, text=text, font=win.UI, background=win.C['paper'],
                 foreground=win.C['muted'], anchor='w').grid(
                     row=row[0], column=0, sticky='w', pady=win.px(3),
                     padx=win.px([0, 14]))

    def entry(g, field, var, width):
        def on_key(e):
            v = var.get()
            if v != v.upper():
                pos = e.widget.index('insert')
                var.set(v.upper())
                e.widget.icursor(pos)
            _store(field, var)
            settings_changed()

        e = win.flat_entry(g, var, width)
        e.grid(row=row[0], column=1, sticky='w', pady=win.px(3),
               ipady=win.px(3))
        e.bind('<KeyRelease>', on_key)
        win.form[field] = e
        ENTRY_VARS[field] = (var, field)
        var.trace_add('write', _mark(field))
        row[0] += 1

    def _store(field, var):
        s = win.settings
        if field == 'TITLE':
            s['title'] = var.get()
        elif field in editor.PROJECT_FIELDS:
            s['project'][field] = var.get()
        else:
            s['options'][field] = var.get()

    f = editor.PROJECT_FIELDS
    split = 9            # PROJECT ... DATE in the first column
    g = column('PROJECT DETAILS')
    row[0] = 0
    label(g, 'TITLE')
    var = tk.StringVar(value=win.settings.get('title') or '')
    entry(g, 'TITLE', var, 34)
    for k in f[0:split + 1]:
        win.settings['project'].setdefault(k, '')
        label(g, editor.project_label(k))
        var = tk.StringVar(value=win.settings['project'].get(k) or '')
        entry(g, k, var, 34)
    g = column('DESIGN BASIS')
    row[0] = 0
    for k in f[split + 1:]:
        win.settings['project'].setdefault(k, '')
        label(g, editor.project_label(k))
        var = tk.StringVar(value=win.settings['project'].get(k) or '')
        entry(g, k, var, 22)

    g = column('UNITS')
    row[0] = 0
    for q in phc.UNIT_QUANTITIES:
        label(g, editor.UNIT_LABEL[q])
        dd = win.drop_down(g, Setting(win.settings['units'], q),
                           phc.UNIT_CHOICES[q], settings_changed,
                           phc.UNIT_DEFAULT[q])
        dd.grid(row=row[0], column=1, sticky='w', pady=win.px(3))
        win.form[q] = dd
        row[0] += 1

    # CALCULATION: each option with a plain label, its .phc name small
    # and grey beside it, and a line under it saying what it does and
    # what a blank means (editor.OPTION_FORM).
    g = column('CALCULATION')
    row[0] = 0

    def help_(text):
        tk.Label(g, text=text, font=win.UI_S_N, background=win.C['paper'],
                 foreground=win.C['muted'], justify='left', anchor='w',
                 wraplength=win.px(300)).grid(
                     row=row[0], column=0, columnspan=2, sticky='w',
                     pady=win.px([0, 6]))
        row[0] += 1

    def name(text, key):
        f2 = tk.Frame(g, background=win.C['paper'])
        tk.Label(f2, text=text, font=win.UI, background=win.C['paper'],
                 foreground=win.C['ink']).pack(side='left')
        tk.Label(f2, text=key, font=win.UI_S_N, background=win.C['paper'],
                 foreground=win.C['faint']).pack(side='left',
                                                padx=win.px([6, 0]))
        f2.grid(row=row[0], column=0, sticky='w', pady=win.px([3, 0]),
                padx=win.px([0, 14]))

    name('FRICTION FORMULA', 'METHOD')
    dd = win.drop_down(g, Setting(win.settings, 'method'), ['HW', 'DW'],
                       settings_changed)
    dd.grid(row=row[0], column=1, sticky='w', pady=win.px([3, 0]))
    win.form['METHOD'] = dd
    row[0] += 1
    help_("HW HAZEN-WILLIAMS, THE SPRINKLER STANDARD'S METHOD. DW "
          "DARCY-WEISBACH, WITH ROUGHNESS IN PLACE OF C.")
    for o in editor.OPTION_FORM:
        if not isinstance(o, (list, tuple)) or len(o) < 2:
            # a subheading
            text = o if not isinstance(o, (list, tuple)) else o[0]
            tk.Label(g, text=text, font=win.UI_B,
                     background=win.C['paper'], foreground=win.C['ink'],
                     anchor='w').grid(row=row[0], column=0, columnspan=2,
                                      sticky='w', pady=win.px([12, 4]))
            row[0] += 1
            continue
        key, text, about = o[0], o[1], o[2]
        choices = o[3] if len(o) > 3 else None
        win.settings['options'].setdefault(key, '')
        name(text, key)
        if choices:
            d = win.drop_down(g, Setting(win.settings['options'], key),
                              list(choices), settings_changed)
            d.grid(row=row[0], column=1, sticky='w', pady=win.px([3, 0]))
            win.form[key] = d
        else:
            var = tk.StringVar(
                value=win.settings['options'].get(key) or '')

            def on_key(e, key=key, var=var):
                _store(key, var)
                settings_changed()

            e = win.flat_entry(g, var, 12)
            e.grid(row=row[0], column=1, sticky='w', pady=win.px([3, 0]),
                   ipady=win.px(3))
            e.bind('<KeyRelease>', on_key)
            win.form[key] = e
            ENTRY_VARS[key] = (var, key)
            var.trace_add('write', _mark(key))
        row[0] += 1
        help_(about)


# load_settings -- a newly opened file's settings into the form.  The
# Perl's tied widgets followed the settings dict; here the entry vars
# are written and the drop-downs redrawn.
def load_settings(new):
    s = win.settings
    s['title'] = new.get('title') or ''
    for k in list(s['project'].keys()):
        s['project'][k] = ''
    for k, v in (new.get('project') or {}).items():
        s['project'][k] = v
    s['extra'] = list(new.get('extra') or [])
    for q in phc.UNIT_QUANTITIES:
        s['units'][q] = new['units'][q]
    s['method'] = new.get('method') or 'HW'
    for q in phc.OPTIONS:
        s['options'][q] = (new.get('options') or {}).get(q, '')
    _REFILL[0] = True            # the refill is not the user's typing
    for field, (var, key) in ENTRY_VARS.items():
        if field == 'TITLE':
            var.set(s['title'])
        elif field in editor.PROJECT_FIELDS:
            var.set(s['project'].get(field) or '')
        else:
            var.set(s['options'].get(field) or '')
    _REFILL[0] = False
    for fn in win.dd_refresh:
        fn()
    ENTRY_DIRTY.clear()
    win.set_title()


# settings_changed -- after any change in the PROJECT tab.
def settings_changed():
    s = win.settings
    s['title'] = (s.get('title') or '').upper()
    for d in (s['project'], s['options']):
        for k in list(d.keys()):
            v = d[k]
            if isinstance(v, str):
                d[k] = v.upper()
    for field, (var, key) in ENTRY_VARS.items():
        v = var.get()
        if ENTRY_DIRTY.pop(field, None):
            # the var was written since the last time (typed, or put
            # there directly): it is what the user changed
            if field == 'TITLE':
                s['title'] = v.upper()
            elif field in editor.PROJECT_FIELDS:
                s['project'][key] = v.upper()
            else:
                s['options'][key] = v.upper()
        else:
            # nothing touched the widget: the settings are what changed
            if field == 'TITLE':
                v = s['title']
            elif field in editor.PROJECT_FIELDS:
                v = s['project'].get(key) or ''
            else:
                v = s['options'].get(key) or ''
            if var.get() != v:
                _REFILL[0] = True
                var.set(v)
                _REFILL[0] = False
        if v != v.upper():
            pos = None
            w = win.form[field]
            try:
                pos = w.index('insert')
            except Exception:
                pass
            _REFILL[0] = True
            var.set(v.upper())
            _REFILL[0] = False
            if pos is not None:
                try:
                    w.icursor(pos)
                except Exception:
                    pass
    win.set_title()
    win.update_actions()
    win.recolour()          # the units in force change what a line means
    win.update_status()
