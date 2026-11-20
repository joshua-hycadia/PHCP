"""window.isometric -- the drawing window of phcp_isometric.py: a port
of HardyCross/Window/Isometric.pm and the phcp_isometric.pl driver.

A fork of the text editor, not a change to it.  hardycross.win is
loaded for the PROJECT tab, the results and the file commands, and
this module replaces the NETWORK tab with the drawing.  A pipe is two
clicks, or the length, size, fittings and C typed first and one click
for the direction.  The drawing writes the .phc that VALIDATE and
CALCULATE already run.  Positions are //ISO comments, which the
reader ignores, so the calculation is the commands.  Every decision
-- where a point sits, what a click hits, what text is written -- is
hardycross.isometric.  This module is the window.

Perl loaded phcp_editor.pl and replaced its subs in package main;
Python patches hardycross.win's module-level functions the same way
(recolour, set_buffer, go_to_line, set_title, build_window,
select_tab, apply_theme, toggle_theme), so the editor's own calls run
the drawing's versions.  The model still lives in the editor's
buffer, because the calculation is the .phc text; build_network is
run into a hidden frame, which VALIDATE, undo and the files read.
"""

import re

import tkinter as tk

from hardycross import editor
from hardycross import isometric
from hardycross import phc
from hardycross import settings as settings_mod
from hardycross import win

iso_cv = None
iso = {}

# Which captions are drawn.  The same idea as the spreadsheet's column
# chooser: the picture stays quiet until the one thing you want is
# switched on.
LABELS = ('POINTS', 'PIPES', 'LENGTH', 'SIZE', 'FITTINGS', 'ELEVATION',
          'DEVICES')

TOOLS = (
    ('SELECT', 'SELECT',
     'SELECT A POINT OR A PIPE, AND DRAG A POINT ALONG THE GRID'),
    ('NODE', 'NODE', 'CLICK THE GRID TO PLACE A POINT'),
    ('WATER', 'WATER', 'CLICK THE GRID TO PLACE A WATER SUPPLY'),
    ('SPRINKLER', 'SPRINKLER', 'CLICK THE GRID TO PLACE A SPRINKLER'),
    ('HYDRANT', 'HYDRANT', 'CLICK THE GRID TO PLACE A HYDRANT'),
    ('HREEL', 'REEL', 'CLICK THE GRID TO PLACE A HOSE REEL'),
    ('PIPE', 'PIPE',
     'CLICK A POINT, THEN THE NEXT. OR TYPE A KNOWN LENGTH: THE CLICK '
     'ONLY CHOOSES THE DIRECTION'),
    ('PUMP', 'PUMP', 'CLICK THE TWO POINTS THE PUMP JOINS'),
    ('FIXEDFLOW', 'FLOW', 'CLICK A POINT TO PUT A FIXED FLOW ON IT'),
    ('DELETE', 'DELETE', 'CLICK A POINT OR A PIPE TO REMOVE IT'),
)


def build_isometric(page):
    global iso_cv
    bar = tk.Frame(page, background=win.C['paper'])
    bar.pack(side='top', fill='x', padx=win.px(8), pady=win.px(6))
    iso['tools'] = {}
    for (kind, label, _hint) in TOOLS:
        iso['tools'][kind] = win.flat_button(
            bar, label, lambda k=kind: iso_set_tool(k))
        iso['tools'][kind].pack(side='left', padx=win.px([0, 4]))
    # What the next pipe uses, typed before the click.  A blank length
    # means the click sets the length.  A length means the click only
    # picks the axis.
    known = tk.Frame(page, background=win.C['paper'])
    known.pack(side='top', fill='x', padx=win.px(8), pady=win.px([0, 4]))
    tk.Label(known, text='KNOWN', font=win.UI_B,
             background=win.C['paper'],
             foreground=win.C['ink']).pack(side='left',
                                           padx=win.px([0, 8]))
    iso['known'] = {'LENGTH': '', 'SIZE': '', 'FITTINGS': '', 'C': ''}
    iso['known_label'] = {}
    u = win.settings.get('units') or {}
    lu = u.get('LENGTH') or 'MM'
    su = u.get('SIZE') or 'MM'
    iso_known_entry(known, 'LENGTH', 'LENGTH %s' % lu, 8)
    iso_known_entry(known, 'SIZE', 'SIZE %s' % su, 6)
    iso_known_entry(known, 'FITTINGS', 'FITTINGS', 10)
    iso_known_entry(known, 'C', 'C', 6)
    tk.Label(known,
             text='CLICK AND CLICK, OR TYPE THESE. BLANK LENGTH FOLLOWS '
                  'THE CLICK.',
             font=win.UI_S, background=win.C['paper'],
             foreground=win.C['muted'], anchor='w').pack(
                 side='left', padx=win.px(8))

    bar2 = tk.Frame(page, background=win.C['paper'])
    bar2.pack(side='top', fill='x', padx=win.px(8), pady=win.px([0, 6]))
    iso['elev_label'] = tk.Label(bar2, text='ELEVATION', font=win.UI_S,
                                 background=win.C['paper'],
                                 foreground=win.C['muted'])
    iso['elev_label'].pack(side='left')
    iso['elev'] = '0'
    ee = _tied_entry(bar2, 'elev', 8)
    ee.pack(side='left', padx=win.px([6, 12]))
    ee.bind('<Return>', lambda _e: iso_status(
        'ELEVATION SET. THE NEXT POINT IS PLACED THERE.'))
    tk.Label(bar2, text='GRID M', font=win.UI_S,
             background=win.C['paper'],
             foreground=win.C['muted']).pack(side='left')
    iso['gridvar'] = '1'
    ge = _tied_entry(bar2, 'gridvar', 6)
    ge.pack(side='left', padx=win.px([6, 12]))
    ge.bind('<Return>', lambda _e: iso_grid_apply())
    iso['btn'] = iso.get('btn') or {}
    iso['btn']['FIT'] = win.flat_button(bar2, 'FIT',
                                        lambda: iso_fit(1))
    iso['btn']['FIT'].pack(side='left', padx=win.px([0, 4]))
    iso['btn']['IN'] = win.flat_button(bar2, 'ZOOM IN',
                                       lambda: iso_zoom(1.25))
    iso['btn']['IN'].pack(side='left', padx=win.px(4))
    iso['btn']['OUT'] = win.flat_button(bar2, 'ZOOM OUT',
                                        lambda: iso_zoom(1 / 1.25))
    iso['btn']['OUT'].pack(side='left', padx=win.px(4))
    iso['lock'] = 1
    iso['btn']['LOCK'] = win.flat_button(bar2, 'LOCK', iso_set_lock)
    iso['btn']['LOCK'].pack(side='left', padx=win.px(4))
    # Dark mode is the toolbar's DARK MODE, the same button and the
    # same palette as the text editor and the spreadsheet.  The
    # drawing tools stay the things you click to place a pipe.
    iso['labels'] = {name: (1 if name in ('POINTS', 'PIPES', 'DEVICES')
                            else 0) for name in LABELS}
    labels = tk.Menubutton(bar2, text='LABELS', font=win.UI_B,
                           relief='flat', borderwidth=0,
                           highlightthickness=1,
                           highlightbackground=win.C['line'],
                           highlightcolor=win.C['accent'],
                           background=win.C['paper'],
                           foreground=win.C['ink'],
                           activebackground=win.C['hover'],
                           activeforeground=win.C['ink'],
                           padx=win.px(14), pady=win.px(5),
                           direction='below')
    labels.pack(side='left', padx=win.px(4))
    menu = tk.Menu(labels, tearoff=0)
    labels.configure(menu=menu)
    iso['label_vars'] = {}
    for name in LABELS:
        v = tk.IntVar(value=iso['labels'][name])

        def _cmd(name=name, v=v):
            iso['labels'][name] = 1 if v.get() else 0
            iso_redraw()

        menu.add_checkbutton(label=name, variable=v, command=_cmd)
        iso['label_vars'][name] = v
    iso['btn']['LABELS'] = labels
    iso['status_w'] = tk.Label(bar2, text='', font=win.UI,
                               background=win.C['paper'],
                               foreground=win.C['muted'], anchor='w')
    iso['status_w'].pack(side='left', padx=win.px(12), fill='x',
                         expand=1)
    win.rule(page, 'x', side='top')

    # The drawing, and the properties of whatever is selected, on the
    # right.  The spreadsheet kept a figure beside the grid you were
    # editing; this is that, for one pipe or one point.  No extra
    # divider: the results pane below is already one.
    body = tk.Frame(page, background=win.C['paper'])
    body.pack(fill='both', expand=1)
    iso['props'] = tk.Frame(body, background=win.C['panel'],
                           width=win.px(300))
    iso['props'].pack(side='right', fill='y')
    iso['props'].pack_propagate(0)
    win.rule(body, 'y', side='right')
    ef = tk.Frame(body, background=win.C['paper'])
    ef.pack(side='left', fill='both', expand=1)
    vsb = win.flat_scrollbar(ef, 'vertical')
    vsb.pack(side='right', fill='y')
    hsb = win.flat_scrollbar(ef, 'horizontal')
    hsb.pack(side='bottom', fill='x')
    iso_cv = tk.Canvas(ef, background=win.C['paper'],
                       highlightthickness=0, borderwidth=0,
                       confine=1, cursor=win.POINTER, takefocus=1)
    iso_cv.pack(fill='both', expand=1)
    iso_cv.configure(xscrollcommand=hsb.set, yscrollcommand=vsb.set)
    vsb.configure(command=iso_cv.yview)
    hsb.configure(command=iso_cv.xview)
    win.wheel_target(iso_cv)
    iso_cv.bind('<ButtonPress-1>', lambda e: iso_press(
        e.widget.canvasx(e.x), e.widget.canvasy(e.y)))
    iso_cv.bind('<B1-Motion>', lambda e: iso_motion(
        e.widget.canvasx(e.x), e.widget.canvasy(e.y)))
    iso_cv.bind('<ButtonRelease-1>', lambda e: iso_release(
        e.widget.canvasx(e.x), e.widget.canvasy(e.y)))
    iso_cv.bind('<Escape>', lambda _e: (
        iso.__setitem__('from', None), iso.__setitem__('drag', None),
        iso_status('CANCELLED'), iso_redraw()))
    iso_cv.bind('<Delete>', lambda _e: iso_delete_sel())

    iso['theme'] = 'LIGHT'
    iso['tool'] = 'SELECT'
    iso_set_tool('SELECT')
    iso_mark(iso['btn']['LOCK'], 1)


# _tied_entry -- Perl tied an entry straight to a scalar in %iso
# (-textvariable => \\$iso{elev}).  Tkinter ties a StringVar, so the
# shared text is kept in iso[key] and copied in and out on the way
# through.
def _tied_entry(parent, key, width):
    var = tk.StringVar(value=iso[key])
    e = win.flat_entry(parent, var, width)

    def write(*_a, key=key):
        iso[key] = var.get()

    var.trace_add('write', write)
    _TIED[key] = var
    return e


# _tie_show -- the other way: a figure the program put in iso[key] (the
# grid read from a file, a known figure trimmed) is what its field
# shows, as it was at once with the Perl's tied scalar.
_TIED = {}


def _tie_show(key, value):
    var = _TIED.get(key)
    if var is not None and var.get() != str(value):
        var.set(value)


# iso_invalidate -- the text was replaced (a file opened).  The next
# time the tab is shown it reads again and fits the new drawing.
def iso_invalidate():
    iso['source'] = None
    iso['had_fit'] = 0
    iso['sel'] = None
    iso['from'] = None
    iso['drag'] = None


def iso_key():
    u = (win.settings.get('units') if win.settings and
         win.settings.get('units') else {})
    return win.buffer() + '\0' + ','.join(
        (u.get(q) or '') for q in ('LENGTH', 'ELEVATION', 'SIZE',
                                   'PRESSURE', 'FLOW', 'KFACTOR'))


# iso_show -- read the network if it changed, and draw it.  Called
# when the tab is selected and after the text changes while it is
# showing.  It does not write: looking at the drawing never
# reformats the file.
def iso_show():
    if not (iso_cv and win.toptabs and
            (win.toptabs.get('current') or '') == 'ISOMETRIC'):
        return
    key = iso_key()
    reload = (iso.get('source') is None or iso['source'] != key or
              not iso.get('draw'))
    if reload:
        iso['draw'] = isometric.read_network(win.buffer(),
                                             win.settings['units'])
        iso['source'] = key
        iso['sel'] = None
        iso['from'] = None
        iso['gridvar'] = isometric.clean_num(iso['draw']['grid'])
        _tie_show('gridvar', iso['gridvar'])
        if not iso.get('had_fit'):
            iso_fit(1)
        iso['had_fit'] = 1
        iso_props()
    u = win.settings['units']
    eu = u.get('ELEVATION') or 'M'
    lu = u.get('LENGTH') or 'MM'
    su = u.get('SIZE') or 'MM'
    if iso.get('elev_label'):
        iso['elev_label'].configure(text='ELEVATION %s' % eu)
    if iso.get('known_label', {}).get('LENGTH'):
        iso['known_label']['LENGTH'].configure(
            text='LENGTH %s' % lu)
    if iso.get('known_label', {}).get('SIZE'):
        iso['known_label']['SIZE'].configure(text='SIZE %s' % su)
    iso_redraw()


# iso_known_entry -- one figure typed ahead of the next pipe.
def iso_known_entry(bar, key, label, width):
    iso['known_label'][key] = tk.Label(
        bar, text=label, font=win.UI_S, background=win.C['paper'],
        foreground=win.C['muted'])
    iso['known_label'][key].pack(side='left')
    var = tk.StringVar(value=iso['known'][key])
    e = win.flat_entry(bar, var, width)
    if key != 'FITTINGS':
        e.configure(justify='right')

    def write(*_a, key=key):
        iso['known'][key] = var.get()

    var.trace_add('write', write)
    _TIED['known:' + key] = var
    e.pack(side='left', padx=win.px([4, 10]))
    e.bind('<Return>', lambda _e, k=key: iso_known_apply(k))


# iso_known_apply -- Return in a known field checks it, then the
# drawing takes the next click.  The field keeps the focus when the
# figure is wrong.
def iso_known_apply(key):
    v = iso['known'].get(key)
    v = '' if v is None else v
    v = v.strip()
    iso['known'][key] = v
    _tie_show('known:' + key, v)
    err = (isometric.known_ok(iso['draw'], iso_known_args())
           if iso.get('draw') else '')
    if err:
        iso_fail(err)
        return
    if v == '':
        iso_status('LENGTH CLEARED. THE CLICK SETS THE LENGTH.'
                   if key == 'LENGTH' else
                   '%s CLEARED. THE NEXT PIPE USES THE USUAL VALUE.'
                   % key)
    elif key == 'LENGTH':
        iso_status('LENGTH %s. THE NEXT CLICK CHOOSES THE DIRECTION '
                   'ONLY.' % v)
    else:
        iso_status('%s %s. THE NEXT PIPE USES IT.' % (key, v))
    iso_focus_drawing()


# iso_known_args -- the dict add_pipe reads.  Blank fields stay blank.
def iso_known_args():
    k = iso.get('known') or {}
    out = {}
    for (key, name) in (('LENGTH', 'len'), ('SIZE', 'size'),
                        ('FITTINGS', 'fits'), ('C', 'c')):
        v = k.get(key)
        v = '' if v is None else v
        out[name] = v.strip()
    return out


def iso_set_tool(kind):
    iso['tool'] = kind
    if kind not in ('PIPE', 'PUMP'):
        iso['from'] = None
    for t in TOOLS:
        iso_mark(iso['tools'].get(t[0]), t[0] == kind)
    if iso['btn'].get('LOCK'):
        iso_mark(iso['btn']['LOCK'], iso.get('lock'))
    hint = [t[2] for t in TOOLS if t[0] == kind]
    iso_status(hint[0] if hint else '')
    if iso_cv:
        iso_cv.configure(cursor=(win.POINTER if kind == 'SELECT'
                                  else 'crosshair'))


# iso_mark -- a toolbar button drawn as on (solid blue) or off
# (paper).
def iso_mark(w, on):
    if not w:
        return
    w.configure(background=win.C['accent'] if on else win.C['paper'],
                foreground='#FFFFFF' if on else win.C['ink'],
                activebackground=(win.C['accent_dk'] if on
                                  else win.C['hover']),
                activeforeground=('#FFFFFF' if on else win.C['ink']),
                highlightbackground=(win.C['accent'] if on
                                     else win.C['line']))


# iso_set_lock -- on, pipes are drawn along the grid axes in whole
# pixels, so a run is straight and parallel to the grid.  Off, a pipe
# is the one line between its ends.
def iso_set_lock(on=None):
    iso['lock'] = (1 if on else 0) if on is not None else (
        0 if iso.get('lock') else 1)
    if iso.get('view'):
        iso['view']['lock'] = 1 if iso['lock'] else 0
    iso_mark(iso['btn'].get('LOCK'), iso['lock'])
    iso_status('LOCKED. A PIPE RUNS ALONG THE GRID, IN WHOLE PIXELS.'
               if iso['lock'] else
               'UNLOCKED. A PIPE IS THE STRAIGHT LINE BETWEEN ITS '
               'ENDS.')
    iso_redraw()


def iso_set_label(name, on):
    iso['labels'][name] = 1 if on else 0
    if name in iso.get('label_vars', {}):
        iso['label_vars'][name].set(iso['labels'][name])
    iso_redraw()


def iso_label(name):
    return 1 if iso.get('labels', {}).get(name) else 0


def iso_status(text):
    if not iso.get('status_w'):
        return
    iso['status_w'].configure(text=str(text).upper(),
                              foreground=win.C['muted'])


def iso_fail(text):
    if not iso.get('status_w'):
        return
    iso['status_w'].configure(text=str(text).upper(),
                              foreground=win.C['error'])


def iso_status_text():
    return iso['status_w'].cget('text') if iso.get('status_w') else ''


# A pipe run has to keep the keyboard focus on the drawing, or the
# next click is typed into a field instead of drawn.
def iso_focus_drawing():
    if iso_cv:
        iso_cv.focus_force()


def iso_work_iz():
    d = iso.get('draw')
    if not d:
        return 0
    m = phc.length_metres(iso.get('elev'), d['units']['ELEVATION'])
    return m / (d['grid'] or 1) if m is not None else 0


# iso_commit -- the drawing changed, so the network text changes with
# it.  One undo step in the editor.  The source key is set before the
# recolour, which would otherwise read the text straight back and fit
# again.
def iso_commit():
    if iso.get('busy'):
        return
    iso['busy'] = 1
    try:
        text = isometric.write_network(iso['draw'])
        if text != win.buffer():
            win.discard_proposal()
            win.ed.delete('1.0', 'end')
            win.ed.insert('1.0', text)
        iso['source'] = iso_key()
        win.recolour()
        win.update_actions()
        win.update_status()
        win.set_title()
        iso_redraw()
        iso_props()
    finally:
        iso['busy'] = 0


def iso_grid_apply():
    err = isometric.set_grid(iso['draw'], iso.get('gridvar'))
    if err:
        iso_fail(err)
        return
    iso_status('GRID SET. LENGTHS ALREADY ENTERED STAY UNTIL A POINT '
               'IS MOVED.')
    iso_commit()


#------------------------------------------------------------------------------
# Clicks.
#------------------------------------------------------------------------------
def iso_press(sx, sy):
    if not (iso.get('draw') and iso.get('view')):
        return
    iso_focus_drawing()
    d = iso['draw']
    hit = isometric.hit(d, sx, sy, iso['view'])
    tool = iso['tool']

    if tool == 'SELECT':
        iso['sel'] = hit
        iso['drag'] = None
        if hit and hit['kind'] == 'node':
            n = d['nodes'][hit['name']]
            iso['drag'] = {'name': hit['name'], 'ix': n['ix'],
                           'iy': n['iy'], 'iz': n['iz']}
        iso_props()
        iso_redraw()
        # The length is the first figure.  A pipe chain must not land
        # here: focusing the pane would take the next click off the
        # drawing.
        if (hit and hit['kind'] == 'pipe' and
                iso.get('entry', {}).get('LENGTH')):
            iso['entry']['LENGTH'].focus()
        iso_status('%s %s' % (hit['kind'], hit['name']) if hit
                   else 'NOTHING THERE')
        return
    if tool == 'DELETE':
        if hit:
            iso_delete_hit(hit)
        else:
            iso_fail('CLICK A POINT OR A PIPE')
        return
    if tool in ('PIPE', 'PUMP'):
        iso_link_click(sx, sy, hit)
        return
    if tool == 'FIXEDFLOW':
        if not (hit and hit['kind'] == 'node'):
            iso_fail('CLICK A POINT')
            return
        (err, name) = isometric.add_fixedflow(d, hit['name'])
        if err:
            iso_fail(err)
            return
        iso_status('%s ON %s' % (name, hit['name']))
        iso_commit()
        return
    # A point tool.  A click on a point selects it; a click on the
    # grid places one.
    if hit and hit['kind'] == 'node':
        iso['sel'] = hit
        iso_props()
        iso_redraw()
        return
    (ix, iy, _iz) = isometric.cell_at(sx, sy, iso['view'],
                                      iso_work_iz())
    (err, name) = isometric.add_node(d, tool, ix, iy, iso_work_iz(),
                                    iso.get('elev'))
    if err:
        iso_fail(err)
        return
    iso['sel'] = {'kind': 'node', 'name': name}
    iso_status('%s %s PLACED' % (tool, name))
    iso_commit()


# iso_link_click -- the first click chooses the start.  The next
# click is the end: an existing point, or an empty cell.  With no
# known length the cell is where you clicked, snapped to one axis,
# and the length is that distance.  With a known length the click
# only chooses the axis, and the end is that many steps along it.
# The end stays the start, so a run is click by click.  The drawing
# keeps the focus: the properties pane is not where the next click
# should go.
def iso_link_click(sx, sy, hit):
    d = iso['draw']
    known = iso_known_args()
    if not iso.get('from'):
        if hit and hit['kind'] == 'node':
            iso['from'] = hit['name']
        else:
            (ix, iy, _iz) = isometric.cell_at(sx, sy, iso['view'],
                                              iso_work_iz())
            (err, name) = isometric.add_node(d, 'NODE', ix, iy,
                                             iso_work_iz(),
                                             iso.get('elev'))
            if err:
                iso_fail(err)
                return
            iso['from'] = name
            iso_commit()
        iso_status(iso_from_status(known))
        iso_redraw()
        iso_focus_drawing()
        return
    if iso['tool'] == 'PIPE':
        err = isometric.known_ok(d, known)
        if err:
            iso_fail(err)
            return
    a = d['nodes'].get(iso['from'])
    if a is None:
        iso['from'] = None
        return
    if hit and hit['kind'] == 'node' and hit['name'] != iso['from']:
        # An existing point is the end.  It is not moved to suit a
        # typed length.
        b = d['nodes'][hit['name']]
        if not isometric.axis_aligned(a, b):
            iso_fail('A PIPE RUNS ALONG ONE GRID AXIS')
            return
        end = hit['name']
    else:
        (ix, iy, _iz) = isometric.cell_at(sx, sy, iso['view'],
                                         iso_work_iz())
        iz = iso_work_iz()
        ln = known.get('len') if iso['tool'] == 'PIPE' else ''
        if ln is not None and re.search(r'\S', ln):
            steps = isometric.steps_for_length(d, ln)
            # Zero is one step on the drawing so the points do not
            # stack.  The pipe still stores the typed zero.
            n = steps if (steps is not None and steps > 0) else 1
            (ix, iy, iz) = isometric.cell_along(a, ix, iy, iz, n)
        else:
            (ix, iy, iz) = isometric.snap_axis(a, ix, iy, iz)
        if (abs(ix - a['ix']) < 1e-9 and abs(iy - a['iy']) < 1e-9 and
                abs(iz - a['iz']) < 1e-6):
            iso_fail('CLICK ALONG AN AXIS')
            return
        end = isometric.node_at(d, ix, iy, iz)
        if not end:
            elev = isometric.metres_to_token(
                d, iz * (d['grid'] or 1), 'ELEVATION')
            (err, name) = isometric.add_node(d, 'NODE', ix, iy, iz,
                                            elev)
            if err:
                iso_fail(err)
                return
            end = name
    if iso['tool'] == 'PUMP':
        (err, name) = isometric.add_pump(d, iso['from'], end)
    else:
        (err, name) = isometric.add_pipe(d, iso['from'], end, known)
    if err:
        iso_fail(err)
        return
    from_ = iso['from']
    iso['from'] = end
    iso['sel'] = {'kind': 'pump' if iso['tool'] == 'PUMP' else 'pipe',
                  'name': name}
    how = (('LENGTH %s.' % known['len']
            if iso['tool'] == 'PIPE' and known.get('len') is not None
            and re.search(r'\S', known['len'])
            else 'LENGTH FROM THE CLICK.'))
    iso_status('%s FROM %s TO %s. %s CLICK THE NEXT, OR ESC.'
               % (name, from_, end, how))
    iso_commit()
    iso_focus_drawing()


def iso_from_status(known):
    ln = known.get('len')
    if (iso.get('tool') == 'PIPE' and ln is not None
            and re.search(r'\S', ln)):
        return 'FROM %s. LENGTH %s. CLICK THE DIRECTION.' % (
            iso.get('from'), ln)
    return ('FROM %s. CLICK THE NEXT POINT. THE LENGTH FOLLOWS THE '
            'CLICK.' % iso.get('from'))


def iso_motion(sx, sy):
    if not (iso.get('drag') and iso['tool'] == 'SELECT'):
        return
    n = iso['draw']['nodes'].get(iso['drag']['name'])
    if n is None:
        return
    # cell_at gives the cell and its level; the Perl took the first two
    (ix, iy) = isometric.cell_at(sx, sy, iso['view'], n['iz'])[:2]
    if iso.get('lock'):
        (ix, iy, iz) = isometric.snap_axis(iso['drag'], ix, iy, n['iz'])
        iso['ghost'] = [ix, iy, iz]
    else:
        iso['ghost'] = [ix, iy, n['iz']]
    iso_redraw()


def iso_release(_sx=None, _sy=None):
    # the binding passes where the button came up, as the Perl's did;
    # the drop is where the last motion left the ghost
    if not iso.get('drag'):
        return
    g = iso.get('ghost')
    drag = iso['drag']
    iso['drag'] = None
    iso['ghost'] = None
    if g and (g[0] != drag['ix'] or g[1] != drag['iy']):
        err = isometric.move_node(iso['draw'], drag['name'], *g)
        if err:
            iso_fail(err)
            iso_redraw()
            return
        iso_status('%s MOVED. ITS PIPES TAKE THEIR LENGTH FROM THE '
                   'GRID.' % drag['name'])
        iso_commit()
    else:
        iso_redraw()


def iso_delete_hit(hit):
    if not hit:
        return
    err = isometric.delete_item(iso['draw'], hit['kind'], hit['name'])
    if err:
        iso_fail(err)
        return
    if (iso.get('sel') and iso['sel'].get('name') == hit['name']):
        iso['sel'] = None
    if (iso.get('from') is not None and iso['from'] == hit['name']):
        iso['from'] = None
    iso_status('%s DELETED' % hit['name'])
    iso_commit()


def iso_delete_sel():
    iso_delete_hit(iso.get('sel'))


# iso_click_cell / iso_widget_at -- for the window test, a grid point
# as a click.
def iso_click_cell(ix, iy, iz=None):
    if iz is None:
        iz = iso_work_iz()
    (sx, sy) = isometric.project(ix, iy, iz, iso['view'])
    iso_press(sx, sy)


def iso_widget_at(ix, iy, iz=None):
    if iz is None:
        iz = iso_work_iz()
    (sx, sy) = isometric.project(ix, iy, iz, iso['view'])
    return ('%.0f' % (sx - iso_cv.canvasx(0)),
            '%.0f' % (sy - iso_cv.canvasy(0)))


#------------------------------------------------------------------------------
# Drawing.
#------------------------------------------------------------------------------
def iso_fit(force=False):
    if not (iso_cv and iso.get('draw')):
        return
    if force:
        iso_cv.update()
    cw = iso_cv.winfo_width()
    if cw < 40:
        cw = 900
    ch = iso_cv.winfo_height()
    if ch < 40:
        ch = 520
    ns = [iso['draw']['nodes'][name]
          for name in iso['draw']['node_order']]
    ns = [n for n in ns if n.get('ix') is not None]
    if not ns:
        iso['view'] = {'ox': cw * 0.45, 'oy': ch * 0.55, 'scale': 36,
                       'lock': 1 if iso.get('lock') else 0}
        iso_redraw()
        return
    minx = miny = maxx = maxy = None
    one = {'ox': 0, 'oy': 0, 'scale': 1}
    for n in ns:
        (x, y) = isometric.project(n['ix'], n['iy'], n['iz'], one)
        minx = x if minx is None or x < minx else minx
        miny = y if miny is None or y < miny else miny
        maxx = x if maxx is None or x > maxx else maxx
        maxy = y if maxy is None or y > maxy else maxy
    w = (maxx - minx) or 1
    h = (maxy - miny) or 1
    s = (cw - 120) / w
    sh = (ch - 120) / h
    if sh < s:
        s = sh
    # A long imported run has to fit the canvas.  A short branch is
    # kept large enough to click (the cap).  Zoom in when a step is
    # too small.
    if s < 2:
        s = 2
    if s > 48:
        s = 48
    iso['view'] = {'ox': 60 - minx * s, 'oy': 60 - miny * s,
                   'scale': s, 'lock': 1 if iso.get('lock') else 0}
    iso_redraw()


def iso_zoom(factor):
    if not iso.get('view'):
        return
    old = iso['view']['scale']
    s = old * factor
    if s < 2:
        s = 2
    if s > 80:
        s = 80
    cx = iso_cv.canvasx(iso_cv.winfo_width() / 2)
    cy = iso_cv.canvasy(iso_cv.winfo_height() / 2)
    iso['view']['ox'] = cx - (cx - iso['view']['ox']) * s / old
    iso['view']['oy'] = cy - (cy - iso['view']['oy']) * s / old
    iso['view']['scale'] = s
    iso['view']['lock'] = 1 if iso.get('lock') else 0
    iso_redraw()


def iso_redraw():
    if not (iso_cv and iso.get('draw') and iso.get('view')):
        return
    cv = iso_cv
    d = iso['draw']
    v = iso['view']
    cv.delete('all')
    iso_grid(d, v)
    for p in d['pipes']:
        iso_link(d, v, p['start'], p['end'], p['name'], 'pipe', p)
    for p in d['pumps']:
        iso_link(d, v, p['in'], p['out'], p['name'], 'pump', p)
    for name in d['node_order']:
        n = d['nodes'][name]
        if n.get('ix') is None:
            continue
        (ix, iy, iz) = (n['ix'], n['iy'], n['iz'])
        if (iso.get('ghost') and iso.get('drag') and
                iso['drag']['name'] == name):
            (ix, iy, iz) = iso['ghost']
        (x, y) = isometric.project(ix, iy, iz, v)
        sel = (iso.get('sel') and iso['sel']['kind'] == 'node' and
               iso['sel']['name'] == name)
        from_ = iso.get('from') is not None and iso['from'] == name
        iso_node_mark(x, y, n['kind'], sel or from_)
        above = []
        if iso_label('POINTS'):
            above.append(name)
        if (iso_label('ELEVATION') and n.get('elev') is not None and
                n['elev'] != ''):
            above.append(n['elev'])
        if above:
            cv.create_text(x, y - win.px(14),
                           text=' '.join(above), font=win.UI_S,
                           fill=win.C['ink'], anchor='s',
                           tags=('label', 'node:%s' % name))
        ff = [f['name'] for f in d['flows'] if f['node'] == name]
        if ff and iso_label('POINTS'):
            cv.create_text(x, y + win.px(14), text=' '.join(ff),
                           font=win.UI_S, fill=win.C['muted'],
                           anchor='n', tags=('label',))
    b = cv.bbox('all')
    if b:
        pad = win.px(40)
        cv.configure(scrollregion=(b[0] - pad, b[1] - pad,
                                   b[2] + pad, b[3] + pad))


def iso_grid(d, v):
    cv = iso_cv
    minx, maxx, miny, maxy = 0, 4, 0, 4
    for name in d['node_order']:
        n = d['nodes'][name]
        if n.get('ix') is None:
            continue
        minx = n['ix'] if n['ix'] < minx else minx
        maxx = n['ix'] if n['ix'] > maxx else maxx
        miny = n['iy'] if n['iy'] < miny else miny
        maxy = n['iy'] if n['iy'] > maxy else maxy
    minx -= 2
    maxx += 2
    miny -= 2
    maxy += 2
    span = maxx - minx
    if maxy - miny > span:
        span = maxy - miny
    step = 1
    while span / step > 24:
        step *= 2
    iz = iso_work_iz()

    def line(a, b):
        cv.create_line(a[0], a[1], b[0], b[1], fill=win.C['line'],
                       tags=('grid',))

    i = minx
    while i <= maxx:
        line(isometric.project(i, miny, iz, v),
             isometric.project(i, maxy, iz, v))
        i += step
    j = miny
    while j <= maxy:
        line(isometric.project(minx, j, iz, v),
             isometric.project(maxx, j, iz, v))
        j += step


def iso_link(d, v, a_name, b_name, name, kind, rec):
    a = d['nodes'].get(a_name)
    b = d['nodes'].get(b_name)
    if not (a and b and a.get('ix') is not None and b.get('ix')
            is not None):
        return
    (ax, ay, aiz) = (a['ix'], a['iy'], a['iz'])
    (bx, by, biz) = (b['ix'], b['iy'], b['iz'])
    if iso.get('ghost') and iso.get('drag'):
        if iso['drag']['name'] == a_name:
            (ax, ay, aiz) = iso['ghost']
        if iso['drag']['name'] == b_name:
            (bx, by, biz) = iso['ghost']
    if v.get('lock'):
        run = isometric.axis_run(ax, ay, aiz, bx, by, biz)
    else:
        run = [(ax, ay, aiz), (bx, by, biz)]
    if len(run) < 2:
        return
    xy = []
    for g in run:
        xy.extend(isometric.project(g[0], g[1], g[2], v))
    sel = (iso.get('sel') and iso['sel']['kind'] == kind and
           iso['sel']['name'] == name)
    iso_cv.create_line(
        *xy, fill=win.C['accent'] if sel else win.C['ink'],
        width=win.px(3) if sel else win.px(2),
        tags=(kind, '%s:%s' % (kind, name)), joinstyle='miter')
    caption = iso_link_caption(kind, name, rec)
    if caption == '':
        return
    (lx, ly) = iso_caption_at(xy)
    iso_cv.create_text(
        lx, ly - win.px(8), text=caption, font=win.UI_S,
        fill=win.C['accent'] if kind == 'pump' else win.C['muted'],
        anchor='s', tags=('label', '%s:%s' % (kind, name)))


# iso_link_caption -- the words on a pipe, only the ones the LABELS
# menu has on.
def iso_link_caption(kind, name, rec):
    bits = []
    if iso_label('PIPES'):
        bits.append(name)
    if kind == 'pipe' and rec:
        if (iso_label('LENGTH') and rec.get('len') is not None and
                rec['len'] != ''):
            bits.append(rec['len'])
        if (iso_label('SIZE') and rec.get('size') is not None and
                rec['size'] != ''):
            bits.append(rec['size'])
        fits = ' '.join(rec.get('fits') or [])
        if iso_label('FITTINGS') and fits != '':
            bits.append(fits)
        if iso_label('DEVICES') and rec.get('device'):
            bits.append(rec['device']['kind'])
    return ' '.join(bits)


# The caption sits on the longest leg, so an elbow does not pile the
# words on a short riser.
def iso_caption_at(xy):
    (bx, by, best) = (xy[0], xy[1], -1)
    for i in range(0, len(xy) - 2, 2):
        (x1, y1, x2, y2) = (xy[i], xy[i + 1], xy[i + 2], xy[i + 3])
        ln = (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)
        if ln > best:
            best = ln
            bx = (x1 + x2) / 2
            by = (y1 + y2) / 2
    return (bx, by)


def iso_node_mark(x, y, kind, on):
    r = win.px(6)
    cv = iso_cv
    ink = win.C['accent'] if on else win.C['ink']
    if kind == 'WATER':
        cv.create_rectangle(x - r, y - r, x + r, y + r,
                            fill=win.C['accent'],
                            outline=win.C['accent'], tags=('node',))
    elif kind == 'SPRINKLER':
        cv.create_oval(x - r, y - r, x + r, y + r, outline=ink,
                       width=win.px(2), tags=('node',))
        cv.create_line(x - r, y, x + r, y, fill=ink, tags=('node',))
        cv.create_line(x, y - r, x, y + r, fill=ink, tags=('node',))
    elif kind == 'HYDRANT':
        cv.create_polygon(x, y - r - 2, x + r + 2, y, x, y + r + 2,
                          x - r - 2, y, outline=ink,
                          fill=win.C['paper'], width=win.px(2),
                          tags=('node',))
    elif kind == 'HREEL':
        cv.create_oval(x - r, y - r, x + r, y + r, outline=ink,
                       width=win.px(2), tags=('node',))
        cv.create_oval(x - r + 3, y - r + 3, x + r - 3, y + r - 3,
                       outline=ink, tags=('node',))
    else:
        cv.create_oval(x - win.px(4), y - win.px(4),
                       x + win.px(4), y + win.px(4), fill=ink,
                       outline=ink, tags=('node',))


#------------------------------------------------------------------------------
# The fields of whatever is selected.  Return in a field writes it
# back.
#
# The right-hand pane.  Headings are quiet and carry the unit, the way
# the spreadsheet put the unit in the column heading and kept the
# figure on its own.  A figure you can type is a paper field; one the
# drawing derives (the two ends) is only shown.  Return writes the
# field.
#------------------------------------------------------------------------------
def iso_props():
    if not iso.get('props'):
        return
    f = iso['props']
    for c in f.winfo_children():
        c.destroy()
    iso['field'] = {}
    iso['entry'] = {}
    u = (win.settings.get('units') if win.settings and
         win.settings.get('units') else {})
    len_u = u.get('LENGTH') or 'M'
    el_u = u.get('ELEVATION') or 'M'
    sz_u = u.get('SIZE') or 'MM'
    pr_u = u.get('PRESSURE') or 'KPA'
    fl_u = u.get('FLOW') or 'LPM'
    head = tk.Label(f, text='PROPERTIES', font=win.UI_B,
                    background=win.C['panel'], foreground=win.C['ink'],
                    anchor='w')
    head.pack(fill='x', padx=win.px(14), pady=win.px([12, 4]))
    sel = iso.get('sel')
    if not (sel and iso.get('draw')):
        tk.Label(f,
                 text='CLICK TWO POINTS, AND THE LENGTH FOLLOWS THE '
                      'CLICK. OR TYPE A LENGTH, SIZE, FITTINGS AND C '
                      'ABOVE: THE NEXT CLICK ONLY CHOOSES THE '
                      'DIRECTION.',
                 font=win.UI, background=win.C['panel'],
                 foreground=win.C['muted'], anchor='w',
                 justify='left', wraplength=win.px(260)).pack(
                     fill='x', padx=win.px(14), pady=win.px(8))
        return
    d = iso['draw']
    rows = []
    if sel['kind'] == 'node':
        n = d['nodes'].get(sel['name'])
        if n is None:
            return
        kind = n['kind']
        rows = [('NAME', n['name']), ('ELEVATION  %s' % el_u, n['elev'],
                                       'ELEVATION', 1)]
        if n['kind'] == 'WATER':
            rows.append(('STATIC  %s' % pr_u, n.get('static'),
                         'STATIC', 1))
        if n['kind'] in ('SPRINKLER', 'HYDRANT', 'HREEL'):
            rows.append(('MIN FLOW  %s' % fl_u, n.get('minflow'),
                         'MINFLOW', 1))
            rows.append(('K', n.get('k'), 'K', 1))
    elif sel['kind'] == 'pipe':
        p = None
        for q in d['pipes']:
            if q['name'] == sel['name']:
                p = q
                break
        if p is None:
            return
        kind = 'PIPE'
        rows = [
            ('NAME', p['name']),
            ('FROM', p['start'], None, 0, 1),
            ('TO', p['end'], None, 0, 1),
            ('LENGTH  %s' % len_u, p['len'], 'LENGTH', 1),
            ('SIZE  %s' % sz_u, p['size'], 'SIZE', 1),
            ('FITTINGS', ' '.join(p.get('fits') or []),
             'FITTINGS'),
            ('EQV  %s' % len_u, p.get('eqv') if p.get('eqv') is not None
             else '', 'EQV', 1),
            ('TYPE', p.get('use_type'), 'TYPE'),
            ('C', p.get('use_c') if p.get('use_c') is not None else '',
             'C', 1),
        ]
    elif sel['kind'] == 'pump':
        p = None
        for q in d['pumps']:
            if q['name'] == sel['name']:
                p = q
                break
        if p is None:
            return
        kind = 'PUMP'
        rows = [
            ('NAME', p['name']),
            ('FROM', p['in'], None, 0, 1),
            ('TO', p['out'], None, 0, 1),
            ('CHURN  %s' % pr_u, p['churn'], 'CHURN', 1),
            ('FLOW  %s' % fl_u, p['pairs'][0], 'FLOW', 1),
            ('PRESSURE  %s' % pr_u, p['pairs'][1], 'PRESSURE', 1),
        ]
    else:
        return
    tk.Label(f, text=kind, font=win.UI_S, background=win.C['panel'],
             foreground=win.C['muted'], anchor='w').pack(
                 fill='x', padx=win.px(14), pady=win.px([2, 8]))
    for row in rows:
        # A row may stop early: the missing fields are undef, as the
        # Perl array's are.
        (label, val, key, numeric, readonly) = tuple(row) + (
            None,) * (5 - len(row))
        if key is None:
            key = label
        line = tk.Frame(f, background=win.C['panel'])
        line.pack(fill='x', padx=win.px(14), pady=win.px(3))
        tk.Label(line, text=label, font=win.UI_S,
                 background=win.C['panel'],
                 foreground=win.C['muted'], anchor='w',
                 width=16).pack(side='left')
        if val is None:
            val = ''
        if readonly:
            tk.Label(line, text=val, font=win.MONO,
                     background=win.C['hover'], foreground=win.C['ink'],
                     anchor='e', padx=win.px(6), pady=win.px(3)).pack(
                         side='right', fill='x', expand=1)
            continue
        iso['field'][key] = val
        var = tk.StringVar(value=val)

        def write(*_a, key=key):
            iso['field'][key] = var.get()

        var.trace_add('write', write)
        e = win.flat_entry(line, var, 12)
        if numeric:
            e.configure(justify='right')
        e.pack(side='right', fill='x', expand=1)
        iso['entry'][key] = e
        e.bind('<Return>', lambda _e, k=key: iso_apply_field(k))
    tk.Label(f,
             text='RETURN WRITES THE FIELD AND MOVES TO THE NEXT. A '
                  'LENGTH MOVES THE END ALONG THE PIPE.',
             font=win.UI_S, background=win.C['panel'],
             foreground=win.C['muted'], anchor='w', justify='left',
             wraplength=win.px(260)).pack(
                 fill='x', padx=win.px(14), pady=win.px([12, 8]))


def iso_apply_field(field):
    if iso.get('busy') or not iso.get('sel'):
        return
    sel = iso['sel']
    value = iso['field'].get(field)
    if sel['kind'] == 'node':
        err = isometric.set_node(iso['draw'], sel['name'], field,
                                 value)
    elif sel['kind'] == 'pump':
        err = isometric.set_pump(iso['draw'], sel['name'], field,
                                value)
    else:
        err = isometric.set_pipe(iso['draw'], sel['name'], field,
                                 value)
    if err:
        iso_fail(err)
        return
    if (field == 'NAME' and value is not None and value != ''):
        sel['name'] = value
    nxt = iso_next_field(sel['kind'], field)
    iso_status('LENGTH SET. THE END MOVED ALONG THE PIPE.'
               if (field == 'LENGTH' and sel['kind'] == 'pipe')
               else 'CHANGED')
    iso_commit()
    # The pane has just been built again.  Return walks to the next
    # figure.  A pipe run does not: the next click belongs on the
    # drawing.
    if iso.get('from'):
        iso_focus_drawing()
    elif nxt and iso.get('entry', {}).get(nxt):
        iso['entry'][nxt].focus()
        try:
            iso['entry'][nxt].selection_range(0, 'end')
        except tk.TclError:
            pass


def iso_next_field(kind, field):
    order = (['NAME', 'LENGTH', 'SIZE', 'FITTINGS', 'EQV', 'TYPE',
              'C'] if kind == 'pipe' else
             ['NAME', 'CHURN', 'FLOW', 'PRESSURE'] if kind == 'pump'
             else ['NAME', 'ELEVATION', 'STATIC', 'MINFLOW', 'K'])
    seen = False
    for name in order:
        if seen and name in iso.get('field', {}):
            return name
        if name == field:
            seen = True
    return None


# iso_set_field -- the window test types into a field the way Return
# would.
def iso_set_field(field, value):
    iso['field'][field] = value
    iso_apply_field(field)


#------------------------------------------------------------------------------
# Dark mode.  The drawing uses the editor's palettes, so a dark
# isometric window is the same blue, the same red and the same paper
# as the text editor and the spreadsheet.  apply_theme paints the
# widgets.  This paints the canvas again, because a canvas item keeps
# the ink it was given.
#------------------------------------------------------------------------------
def iso_follow_theme():
    iso['theme'] = ('DARK' if (win.theme or '') == 'dark'
                    else 'LIGHT')
    if not iso_cv:
        return
    iso_redraw()
    if iso.get('props'):
        iso_props()


# iso_apply_theme -- 'DARK' or 'LIGHT'.  The toolbar's DARK MODE
# calls toggle_theme, which comes here through apply_theme.  The
# window test calls this directly.  ISO_THEME is this window's own
# key.
def iso_apply_theme(want):
    want = ('dark' if (want or 'LIGHT').upper() == 'DARK'
            else 'light')
    win.apply_theme(want)
    try:
        settings_mod.set('ISO_THEME', win.theme.upper())
    except Exception:
        pass


#==============================================================================
# The window itself -- the editor's window with the drawing in place
# of the NETWORK tab.  The text buffer is still built, hidden,
# because VALIDATE, undo and the file all read it.
#==============================================================================
def iso_editor_window():
    win.dpi_aware()
    win.mw = tk.Tk()
    win.mw.configure(background=win.C['paper'])
    win.set_icon()
    # The screen's scale against the 96 dpi the sizes here were
    # drawn for; never below 1, so a low-resolution screen is not
    # cramped further.
    dpi = win.mw.winfo_pixels('1i')
    win.SCALE = dpi / 96 if dpi > 96 else 1
    win.pick_fonts()
    win.mw.geometry('%dx%d' % (win.px(1500), win.px(950)))
    win.mw.option_add('*Font', win.UI)
    win.mw.option_add('*Background', win.C['paper'])
    win.mw.option_add('*Menu.Relief', 'flat')
    win.mw.option_add('*Menu.activeBorderWidth', 0)
    win.mw.option_add('*Menu.activeBackground', win.C['select'])
    win.mw.option_add('*Menu.activeForeground', win.C['ink'])
    win.mw.option_add('*Menu.font', win.UI)
    win.mw.option_add('*Menu.borderWidth', 1)
    win.build_menus()
    win.build_toolbar()

    hidden = tk.Frame(win.mw, background=win.C['paper'])
    win.build_network(hidden)

    vp = win.divider(win.mw, 'vertical')
    top = tk.Frame(win.mw, background=win.C['paper'])
    bottom = tk.Frame(win.mw, background=win.C['paper'])

    def on_top_tab(n):
        if n == 'QUICK TOOLS':
            from hardycross.window import tools as _t
            _t.tools_refresh()
        elif n == 'ISOMETRIC':
            iso_show()

    win.toptabs = win.make_tabs(
        top, ['ISOMETRIC', 'PROJECT', 'GRAPH', 'QUICK TOOLS',
              'DATABASE'], on_top_tab)
    build_isometric(win.toptabs['page']['ISOMETRIC'])
    from hardycross.window import database as _db
    from hardycross.window import graph as _gr
    from hardycross.window import project as _pr
    from hardycross.window import results as _re
    from hardycross.window import tools as _to
    _pr.build_project(win.toptabs['page']['PROJECT'])
    _gr.build_graph(win.toptabs['page']['GRAPH'])
    _to.build_tools(win.toptabs['page']['QUICK TOOLS'])
    _db.build_database(win.toptabs['page']['DATABASE'])
    _re.build_results(bottom)
    vp.add(top, height=win.px(560))
    vp.add(bottom)
    vp.pack(fill='both', expand=1)

    win.bind_keys()
    win.saved_text = win.full_text()    # an empty new file is not a change
    win.set_title()
    win.update_actions()
    win.update_status()
    iso_show()
    iso_focus_drawing()
    # A palette remembered from last time, this window's own key.  The
    # widgets are built light and then repainted, the same way as the
    # editor.
    try:
        saved = (settings_mod.get('ISO_THEME') or '').lower()
    except Exception:
        saved = ''
    if saved == 'dark':
        win.apply_theme('dark')
    return win.mw


# iso_reveal_line -- a click in VALIDATION selects that pipe or point
# on the drawing.  There is no NETWORK tab to put the cursor in.
def iso_reveal_line(n):
    if not n:
        return
    if win.toptabs and 'ISOMETRIC' in win.toptabs['page']:
        win.select_tab(win.toptabs, 'ISOMETRIC')
    line = win.ed.get('%d.0' % n, '%d.0 lineend' % n)
    a = phc.analyse(line)
    if not (a and a['status'] == 'ok' and iso.get('draw')):
        return
    pos = a.get('pos') or []
    name = pos[0] if pos else None
    if name is None or name == '':
        return
    if name in iso['draw']['nodes']:
        iso['sel'] = {'kind': 'node', 'name': name}
    elif any(p['name'] == name for p in iso['draw']['pipes']):
        iso['sel'] = {'kind': 'pipe', 'name': name}
    elif any(p['name'] == name for p in iso['draw']['pumps']):
        iso['sel'] = {'kind': 'pump', 'name': name}
    else:
        return
    iso_props()
    iso_redraw()


#==============================================================================
# The fork: the editor's own functions, wrapped the way
# phcp_isometric.pl replaced them in package main.  Importing this
# module applies them; hardycross.win untouched on disk.
#==============================================================================
_recolour = win.recolour


def _recolour_wrap():
    res = _recolour()
    if (iso_cv and win.toptabs and
            (win.toptabs.get('current') or '') == 'ISOMETRIC'):
        iso_show()
    return res


win.recolour = _recolour_wrap

_set_buffer = win.set_buffer


def _set_buffer_wrap(text):
    iso_invalidate()
    return _set_buffer(text)


win.set_buffer = _set_buffer_wrap

_go_to_line = win.go_to_line


def _go_to_line_wrap(n, a=None, b=None):
    if (win.toptabs and win.toptabs.get('page') and
            'NETWORK' not in win.toptabs['page']):
        iso_reveal_line(n)
        return
    return _go_to_line(n, a, b)


win.go_to_line = _go_to_line_wrap


def _set_title_wrap():
    name = win.path or 'UNTITLED.PHC'
    name = re.sub(r'.*[/\\]', '', name)
    if win.mw:
        win.mw.title('PHCP ISOMETRIC - %s%s' % (
            name.upper(), ' *' if win.ed and win.modified() else ''))


win.set_title = _set_title_wrap
win.build_window = iso_editor_window

_select_tab = win.select_tab


def _select_tab_wrap(t, n):
    if (n == 'NETWORK' and t and t.get('page') and
            'NETWORK' not in t['page'] and 'ISOMETRIC' in t['page']):
        n = 'ISOMETRIC'
    return _select_tab(t, n)


win.select_tab = _select_tab_wrap

_apply_theme = win.apply_theme


def _apply_theme_wrap(name):
    res = _apply_theme(name)
    iso_follow_theme()
    return res


win.apply_theme = _apply_theme_wrap


def _toggle_theme_wrap():
    win.apply_theme('light' if win.theme == 'dark' else 'dark')
    try:
        settings_mod.set('ISO_THEME', win.theme.upper())
    except Exception:
        pass


win.toggle_theme = _toggle_theme_wrap
