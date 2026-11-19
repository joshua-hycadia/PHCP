"""database -- the DATABASE tab of the PHCP editor: a port of
HardyCross/Window/Database.pm.

The pipe and fitting database, viewed and edited.  Read-only until EDIT
THE DATABASE is ticked, because a change reaches every calculation made
after it.  Four tables -- pipe types, pipe sizes, fittings, K' factors
-- each with a filter; a click on a row puts it in the fields below,
where it can be changed, added as a new row, or deleted.  SAVE CHANGES
checks every row and the whole file, writes it, and makes it the
database in use; the report then prints its new SHA-256.  Every
decision is hardycross.dbedit's; this is drawing.

Above the tables: where the database is -- the program's own
(BUILT-IN), a copy beside the program, or a TEAM FOLDER chosen with
CHOOSE FOLDER..., such as a folder on a network drive that every
machine in a team points at.
"""

import os
import tkinter as tk

from hardycross import dbedit, pipedata
from hardycross import parse
from hardycross import win
from hardycross.window import results as _rs

DBV = {'editing': [0], 'filter': None, 'sel': None, 'box': {},
       'kind': None, 'entries': [], 'vals': []}


def build_database(page):
    top = tk.Frame(page, background=win.C['paper'])
    top.pack(side='top', fill='x', padx=win.px(14), pady=win.px([10, 6]))
    l1 = tk.Frame(top, background=win.C['paper'])
    l1.pack(fill='x')
    DBV['origin'] = tk.Label(l1, text='', font=win.UI_B, padx=win.px(10),
                             pady=win.px(3))
    DBV['origin'].pack(side='left')
    DBV['path'] = tk.Label(l1, text='', font=win.MONO,
                           background=win.C['paper'],
                           foreground=win.C['ink'])
    DBV['path'].pack(side='left', padx=win.px(10))
    DBV['sha'] = tk.Label(l1, text='', font=win.UI_S_N,
                          background=win.C['paper'],
                          foreground=win.C['muted'])
    DBV['sha'].pack(side='left', padx=win.px(6))
    DBV['btn'] = {}
    DBV['btn']['BUILTIN'] = win.flat_button(
        l1, 'USE BUILT-IN', db_use_builtin)
    DBV['btn']['BUILTIN'].pack(side='right', padx=win.px([6, 0]))
    DBV['btn']['FOLDER'] = win.flat_button(
        l1, 'CHOOSE FOLDER...', db_choose_folder)
    DBV['btn']['FOLDER'].pack(side='right', padx=win.px(6))
    DBV['btn']['RELOAD'] = win.flat_button(l1, 'RELOAD', db_reload)
    DBV['btn']['RELOAD'].pack(side='right', padx=win.px(6))

    l2 = tk.Frame(top, background=win.C['paper'])
    l2.pack(fill='x', pady=win.px([10, 0]))
    DBV['edit_box'] = win.check_box(l2, 'EDIT THE DATABASE',
                                    DBV['editing'], db_editing_changed)
    DBV['edit_box']['frame'].pack(side='left')
    DBV['btn']['SAVE'] = win.flat_button(l2, 'SAVE CHANGES', db_save,
                                         primary=True)
    DBV['btn']['SAVE'].pack(side='left', padx=win.px([16, 4]))
    DBV['btn']['DISCARD'] = win.flat_button(l2, 'DISCARD CHANGES',
                                            lambda: db_reload(1))
    DBV['btn']['DISCARD'].pack(side='left', padx=win.px(4))
    DBV['note'] = tk.Label(l2, text='', font=win.UI_S_N,
                           background=win.C['paper'],
                           foreground=win.C['muted'], justify='left',
                           anchor='w')
    DBV['note'].pack(side='left', padx=win.px(14), fill='x')
    ff = tk.Frame(l2, background=win.C['paper'])
    ff.pack(side='right')
    tk.Label(ff, text='FILTER', font=win.UI, background=win.C['paper'],
             foreground=win.C['muted']).pack(side='left')
    DBV['filter'] = tk.StringVar()
    fe = win.flat_entry(ff, DBV['filter'], 18, ipady=win.px(3))
    fe.pack(side='left', padx=win.px([8, 0]))
    fe.bind('<KeyRelease>', lambda e: db_fill())
    win.rule(page, 'x', side='top')

    # The edit fields, under the tables.
    form = tk.Frame(page, background=win.C['panel'])
    form.pack(side='bottom', fill='x')
    win.rule(form, 'x', side='top')
    DBV['formrow'] = tk.Frame(form, background=win.C['panel'])
    DBV['formrow'].pack(fill='x', padx=win.px(14), pady=win.px([8, 4]))
    fb = tk.Frame(form, background=win.C['panel'])
    fb.pack(fill='x', padx=win.px(14), pady=win.px([0, 8]))
    DBV['btn']['UPDATE'] = win.flat_button(fb, 'UPDATE ROW', db_update)
    DBV['btn']['UPDATE'].pack(side='left', padx=win.px([0, 4]))
    DBV['btn']['ADD'] = win.flat_button(fb, 'ADD AS NEW ROW', db_add)
    DBV['btn']['ADD'].pack(side='left', padx=win.px(4))
    DBV['btn']['DELETE'] = win.flat_button(fb, 'DELETE ROW', db_delete)
    DBV['btn']['DELETE'].pack(side='left', padx=win.px(4))
    DBV['msg'] = tk.Label(fb, text='', font=win.UI_B,
                          background=win.C['panel'],
                          foreground=win.C['muted'], anchor='w',
                          justify='left')
    DBV['msg'].pack(side='left', padx=win.px(14), fill='x')

    kinds = [t[0] for t in dbedit.TABLES]
    DBV['tabs'] = win.make_tabs(
        page, [dbedit.table(k)['title'] for k in kinds],
        lambda t, kinds=kinds: _on_tab(t, kinds))
    db_reload(1)


def _on_tab(title, kinds):
    for k in kinds:
        if dbedit.table(k)['title'] == title:
            DBV['kind'] = k
    db_fill()
    db_form()


# db_open -- read the database in use into the tab; a file that cannot
# be read (a team folder off the network) is said so, and the tab
# shows nothing.
def db_open():
    try:
        parse.ensure_db()
        DBV['db'] = dbedit.open_db(pipedata.path())
        DBV['error'] = None
    except Exception as e:
        msg = getattr(e, 'msg', None) or str(e)
        DBV['error'] = ' '.join(str(msg).upper().split())
        DBV['db'] = None


# db_reload -- read the database again from its file, losing unsaved
# edits (after asking, unless quiet).
def db_reload(quiet=False):
    if not quiet and not db_ok_to_leave():
        return
    db_open()
    DBV['sel'] = None
    db_header()
    db_fill()
    db_form()
    db_state()
    db_message(DBV['error'] or '', bool(DBV['error']))


# db_header -- where the database is, its path and fingerprint.
def db_header():
    o = pipedata.origin(pipedata.path() or pipedata.default_path())
    team = o == 'TEAM FOLDER'
    DBV['origin'].configure(text=o, foreground=win.C['accent'] if team
                            else win.C['muted'],
                            background=win.C['accent_bg'] if team
                            else win.C['hover'])
    DBV['path'].configure(text=pipedata.path() or pipedata.default_path())
    sha = pipedata.sha256()
    DBV['sha'].configure(text='FINGERPRINT ' + sha[:12].upper() if sha
                         else '')


# db_state -- buttons and fields on or off for read-only or editing.
def db_state():
    ed = DBV['editing'][0] and DBV.get('db')
    mod = DBV.get('db') and DBV['db']['modified']
    for k in ('UPDATE', 'ADD', 'DELETE'):
        DBV['btn'][k].configure(state='normal' if ed else 'disabled')
    if mod and ed:
        DBV['btn']['SAVE'].configure(state='normal',
                                     background=win.C['accent'],
                                     highlightbackground=win.C['accent'])
    else:
        DBV['btn']['SAVE'].configure(state='disabled',
                                     background=win.C['panel'],
                                     highlightbackground=win.C['line'])
    DBV['btn']['DISCARD'].configure(state='normal' if mod
                                    else 'disabled')
    for e in DBV.get('entries') or []:
        e.configure(state='normal' if ed else 'readonly')
    DBV['note'].configure(text='' if not DBV.get('db')
                         else 'EDITING. CHANGES TAKE EFFECT WHEN SAVED, AND '
                              'EVERY REPORT AFTER THEM PRINTS THE NEW '
                              'FINGERPRINT.'
                         if ed else
                         'READ-ONLY. TICK EDIT THE DATABASE TO CHANGE IT.')


def db_editing_changed():
    db_state()


# db_cols -- the current table's columns.
def db_cols():
    return list(dbedit.table(DBV['kind'])['cols'])


# db_fill -- the current table, filtered: every row with a word
# beginning with each word of the filter.
def db_fill():
    kind = DBV.get('kind')
    if not kind:
        return
    if not DBV.get('tabs'):   # make_tabs selects its first tab before it returns
        return
    page = DBV['tabs']['page'][dbedit.table(kind)['title']]
    if DBV['box'].get(kind):
        DBV['box'][kind].destroy()
    cols = db_cols()
    h, box = _rs.hlist(page, len(cols))
    DBV['box'][kind] = box
    DBV['hlist'] = h
    rows = dbedit.rows(DBV['db'], kind) if DBV.get('db') else []
    widths = [len(c[0]) for c in cols]
    shown = [[dbedit.shown(v) for v in r['fields']] for r in rows]
    for r in shown:
        for i in range(len(widths)):
            l = len(r[i] or '')
            if l > widths[i]:
                widths[i] = l

    def num(i):
        return cols[i][1].startswith('int') or cols[i][1].startswith('num')

    def al(i):
        return 'e' if num(i) else 'w'

    h.configure(state='normal')
    h.delete('1.0', 'end')
    h.insert('end', '  '.join(_rs.pad(cols[i][0], widths[i], al(i))
                              for i in range(len(cols))) + '\n', 'head')
    words = [w for w in (DBV['filter'].get() or '').upper().split() if w]
    DBV['shown_rows'] = []
    for k, r in enumerate(rows):
        # Each word of the filter must begin some word of the row: "50"
        # finds DN 50, not DN 150.
        toks = []
        for v in shown[k]:
            toks += (v or '').split()
        if any(not any(t.startswith(w) for t in toks) for w in words):
            continue
        i = r['line']
        h.insert('end', '  '.join(_rs.pad(shown[k][j] or '', widths[j],
                                         al(j))
                                  for j in range(len(cols))) + '\n')
        DBV['shown_rows'].append(i)
    h.bind('<ButtonRelease-1>', _row_click)
    if DBV.get('sel') is not None and DBV['sel'] in DBV['shown_rows']:
        n = DBV['shown_rows'].index(DBV['sel']) + 1
        h.tag_add('band', '%d.0' % n, '%d.end' % n)
        h.see('%d.0' % n)
    h.configure(state='disabled')


def _row_click(e):
    h = DBV['hlist']
    n = int(h.index('@%d,%d' % (e.x, e.y)).split('.')[0])
    h.tag_remove('band', '1.0', 'end')
    if 1 <= n <= len(DBV['shown_rows']):
        h.tag_add('band', '%d.0' % n, '%d.end' % n)
        DBV['sel'] = DBV['shown_rows'][n - 1]
    db_form()


# db_form -- the edit fields for the current table, holding the
# selected row.
def db_form():
    kind = DBV.get('kind')
    if not kind:
        return
    if not DBV.get('tabs'):
        return
    for c in DBV['formrow'].winfo_children():
        c.destroy()
    cols = db_cols()
    l = None
    if DBV.get('sel') is not None and DBV.get('db'):
        if 0 <= DBV['sel'] < len(DBV['db']['lines']):
            l = DBV['db']['lines'][DBV['sel']]
    if l and (l.get('kind') or '') != kind:
        l = None
    DBV['vals'] = [tk.StringVar(value=(dbedit.shown(l['fields'][i])
                                       if l and i < len(l['fields'])
                                       else ''))
                   for i in range(len(cols))]
    DBV['entries'] = []
    for i, c in enumerate(cols):
        f = tk.Frame(DBV['formrow'], background=win.C['panel'])
        f.pack(side='left', padx=win.px([0, 10]))
        tk.Label(f, text=c[0], font=win.UI_S_N, background=win.C['panel'],
                 foreground=win.C['muted'], anchor='w').pack(fill='x')
        w = 30 if c[1] == 'text' else 9 if c[1] == 'code' else 11
        e = win.flat_entry(f, DBV['vals'][i], w, ipady=win.px(3))
        e.pack()
        e.configure(readonlybackground=win.C['panel'])
        DBV['entries'].append(e)
    db_state()


# db_message -- a line beside the row buttons: red for a problem.
def db_message(t, bad=False):
    DBV['msg'].configure(text=t, foreground=win.C['error'] if bad
                         else win.C['accent'])


def db_update():
    if not (DBV['editing'][0] and DBV.get('db')):
        return
    if DBV.get('sel') is None:
        return db_message('SELECT A ROW TO CHANGE FIRST', 1)
    err = dbedit.set_row(DBV['db'], DBV['sel'],
                         [v.get() for v in DBV['vals']])
    if err:
        return db_message(err, 1)
    db_fill()
    db_state()
    db_message('ROW CHANGED. SAVE CHANGES TO USE IT.')


def db_add():
    if not (DBV['editing'][0] and DBV.get('db')):
        return
    err, at = dbedit.add_row(DBV['db'], DBV['kind'],
                             [v.get() for v in DBV['vals']])
    if err:
        return db_message(err, 1)
    DBV['sel'] = at
    db_fill()
    db_state()
    db_message('ROW ADDED. SAVE CHANGES TO USE IT.')


def db_delete():
    if not (DBV['editing'][0] and DBV.get('db')):
        return
    if DBV.get('sel') is None:
        return db_message('SELECT A ROW TO DELETE FIRST', 1)
    err = dbedit.delete_row(DBV['db'], DBV['sel'])
    if err:
        return db_message(err, 1)
    DBV['sel'] = None
    db_fill()
    db_form()
    db_message('ROW DELETED. SAVE CHANGES TO MAKE IT FINAL.')


#------------------------------------------------------------------------------
# db_save -- check, write, and use the edited database.  A model
# validated against the old data must be validated again: CALCULATE
# goes off.
#------------------------------------------------------------------------------
def db_save():
    if not (DBV['editing'][0] and DBV.get('db')
            and DBV['db']['modified']):
        return
    from hardycross import editor
    r = dbedit.save(DBV['db'])
    if not r.get('ok'):
        p = r['problems'][0]
        where = (' (%s)' % dbedit.table(p['kind'])['title']
                 if p.get('line') is not None else '')
        if p.get('line') is not None:
            DBV['sel'] = p['line']
        db_fill()
        return db_message('NOT SAVED: %s%s' % (p['message'], where), 1)
    db_after_change()
    db_message('SAVED TO %s. VALIDATE THE MODEL AGAIN BEFORE '
               'CALCULATING.' % r['path'])


# db_after_change -- the database in use has changed: what was
# checked or calculated against the old one is out of date.
def db_after_change():
    from hardycross import editor
    editor.clear_cache()
    win.valid_text = win.validation = win.solved = None
    _rs.fill_results()
    _rs.fill_validation()
    db_header()
    db_fill()
    db_state()
    win.recolour()
    win.update_actions()


#------------------------------------------------------------------------------
# db_choose_folder / db_use_builtin -- where the database is kept, for
# this machine.  A folder with no database yet is offered a copy of the
# one in use, which is how a team starts its shared database.
#------------------------------------------------------------------------------
def db_choose_folder(dir_=None, answer=None):
    if not db_ok_to_leave():
        return
    if dir_ is None:
        from tkinter import filedialog
        dir_ = filedialog.askdirectory(
            title='FOLDER FOR THE PIPE AND FITTING DATABASE',
            mustexist=True)
    if not dir_:
        return
    copy = 0
    if not os.path.exists(os.path.join(dir_, 'pipes.dat')):
        if answer is None:
            from tkinter import messagebox
            answer = messagebox.askyesno(
                title='NO DATABASE IN THAT FOLDER', icon='question',
                message='%s HAS NO PIPES.DAT.\n\nCOPY THE DATABASE IN '
                        'USE THERE, TO START A SHARED DATABASE FOR THE '
                        'TEAM?' % dir_)
        if not answer:
            return
        copy = 1
    err = dbedit.use_folder(dir_, copy)
    if err:
        return db_message(err, 1)
    db_open()
    db_after_change()
    db_message('USING THE DATABASE IN %s ON THIS MACHINE.' % dir_)
    return True


def db_use_builtin():
    if not db_ok_to_leave():
        return
    dbedit.use_builtin()
    db_open()
    db_after_change()
    db_message('USING THE BUILT-IN DATABASE ON THIS MACHINE.')
    return True


# db_ok_to_leave -- true unless there are unsaved database edits the
# user wants to keep.
def db_ok_to_leave():
    if not (DBV.get('db') and DBV['db']['modified']):
        return True
    from tkinter import messagebox
    return messagebox.askyesno(
        title='UNSAVED DATABASE CHANGES', icon='warning',
        message='THE DATABASE HAS CHANGES THAT ARE NOT SAVED.  '
                'DISCARD THEM?')


#------------------------------------------------------------------------------
# show_field -- the PROJECT tab, with one field focused and marked.
#------------------------------------------------------------------------------
def show_field(field):
    win.select_tab(win.toptabs, 'PROJECT')
    w = win.form.get(field)
    if not w:
        return
    w.focus_set()
    w.configure(highlightbackground=win.C['error'])
    win.mw.after(
        2500, lambda: w.winfo_exists()
        and w.configure(highlightbackground=win.C['line']))
