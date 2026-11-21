#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# dbedit.py -- Python port of HardyCross/DbEdit.pm.
#
# Editing the pipe and fitting database, without a window.
#
# The editor's DATABASE tab shows data/pipes.dat as four tables -- pipe types,
# pipe sizes, fittings and K' factors -- and lets a user change, add and
# delete rows.  Every decision about that is made here, so it can be tested
# headless (the window only draws.
#
# What it guarantees:
#   - The file is edited in place, line by line.  Comments, blank lines and
#     the order of the records are kept; an unchanged database saves to the
#     same bytes.
#   - The window shows text in capitals and 7-bit ASCII, as the rest of the
#     program does ("90 DEG STANDARD ELBOW" for "90° standard elbow").  A
#     field the user did not change keeps its original text, degree sign and
#     case included: an edit replaces only what was edited.
#   - Nothing is saved that the program could not use.  Every row is checked
#     -- the right number of fields, numbers where numbers belong (or DASH,
#     "none published"), a pipe size only for a pipe type that exists, no two
#     rows for the same thing -- and the whole file is then read by
#     pipedata.load, the reader the solver uses, before it
#     replaces the old one.
#   - Saving dates the DATASET line, which the report prints, and the report
#     prints the new file's SHA-256: every calculation after an edit says
#     which data it used.
#
# Where it saves (save_path): back to the file it was opened from -- the team
# folder's, or the source folder's -- except the copy packed inside an .exe,
# which cannot be written; that goes to data/pipes.dat beside the program
# (pipedata.user_path), which then wins over the packed one.
#
# A shared database on a network drive can be edited by two people at once.
# The file's SHA-256 is noted when it is opened; if the file on disk no longer
# has it when saving, someone else has saved in between, and the save is
# refused rather than overwrite their change.
#

import hashlib
import os
import re
import time

from . import pipedata, settings, phc
import hardycross

#------------------------------------------------------------------------------
# The four tables: their record kind, title, and columns.  A column is
# [ heading, type ]: text, code (capitals and digits, no spaces), int (a
# positive whole number), num (a positive number), or num0 (a number that may
# be DASH, "none published").  The order is the order of the fields in the
# file.
#------------------------------------------------------------------------------
TABLES = (
    ('PIPETYPE', 'PIPE TYPES',
     (('CODE', 'code'), ('NAME', 'text'), ('STANDARD', 'text'), ('SIZE RANGE', 'text'),
      ('C FACTOR', 'num'), ('ROUGHNESS MM', 'num0'))),
    ('PIPE', 'PIPE SIZES',
     (('PIPE TYPE', 'code'), ('DN', 'int'), ('OD MM', 'num0'), ('BORE MM', 'num0'),
      ('K', 'num0'))),
    ('FIT', 'FITTINGS',
     (('SOURCE', 'code'), ('CODE', 'code'), ('FITTING', 'text'), ('DN', 'int'),
      ('EQV LENGTH M', 'num0'))),
    ('KPRIME', "K' FACTORS",
     (('CODE', 'code'), ('COMPONENT', 'text'), ("K'", 'num'), ('OFFICE USE', 'text'))),
)
TABLE = {t[0]: {'kind': t[0], 'title': t[1], 'cols': t[2]} for t in TABLES}

def table(kind):
    return TABLE.get(kind)

# The window's form of a field: capitals, 7-bit ASCII.
def shown(t):
    return _ascii(t or '')

def _ascii(s):
    s = s.replace('\xb0', ' DEG')
    s = re.sub(r'[^\x20-\x7E]', '', s)
    return s.upper()

# _num -- a field as the number Perl makes of it where it compares it: the
# number its ASCII figures spell from the start, 0 if there are none.  \d
# matches the figures of any script in the file's text, in Perl as here, but
# only 0-9 count: a DN of Arabic-Indic threes is 0, and refused.
_NUMIFY_RE = re.compile(r'\s*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)')

def _num(v):
    m = _NUMIFY_RE.match(str(v))
    return float(m.group(1)) if m else 0.0

# _field -- a row's field, '' where the row is too short to have it (a
# record cut short in the file), as Perl's undef joins and compares.
def _field(f, i):
    return f[i] if i < len(f) and f[i] is not None else ''

# _err -- the system's reason for a failed open or rename, as Perl's $!.
def _err(e):
    return (e.strerror or str(e)).upper()

#------------------------------------------------------------------------------
# open_db -- the database file as a list of lines.  Each line is
#   { text }                         a comment or blank, kept as it is
#   { text, kind, fields: [..] }     a record
# Returns { path, lines, modified: 0 }.
#------------------------------------------------------------------------------
def open_db(path=None):
    path = path or pipedata.default_path()
    try:
        with open(path, 'rb') as fh:
            raw = fh.read()
    except OSError as e:
        hardycross.fail('CANNOT OPEN THE DATABASE %s: %s', path, _err(e))
    sha = hashlib.sha256(raw).hexdigest()
    # utf8::decode leaves a file that is not UTF-8 as its bytes (a Latin-1
    # file opens, each byte a character), where bytes.decode would refuse it.
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        text = raw.decode('latin-1')
    crlf = '\r\n' in text
    text = text.replace('\r\n', '\n')
    lines = []
    # Perl's split gives no lines at all for an empty file, not one empty line
    for l in (text.split('\n') if text != '' else []):
        # A stray carriage return, from a file with mixed line endings, is
        # not part of the last field: '41.1\r' is not a number.
        l = re.sub(r'\r+\Z', '', l)
        if re.match(r'^\s*(#|$)', l):
            lines.append({'text': l})
            continue
        parts = l.split('|')
        kind, f = parts[0], parts[1:]
        # A pipe type from a database written before ROUGHNESS MM was added:
        # shown as DASH, none published, and written so if the row is edited.
        if kind == 'PIPETYPE' and len(f) == 5:
            f.append('DASH')
        lines.append({'text': l, 'kind': kind, 'fields': f})
    if lines and lines[-1]['text'] == '' and text.endswith('\n'):
        lines.pop()
    # A file that does not end in a newline is written back without one, and
    # can be saved over like any other.  (The Perl cannot: its hash is built
    # from a list in which the failed match  $text =~ /\n\z/  is no element,
    # so the pairs shift, sha256 is never set, and SAVE over the file opened
    # is refused as "saved by someone else".  A defect, not copied: see
    # PYTHON_PORT.md.)
    return {'path': path, 'lines': lines, 'modified': 0, 'crlf': crlf,
            'trailing_nl': 1 if (text.endswith('\n') or text == '') else 0, 'sha256': sha}

# rows -- a table's records: [ { line: index, fields: [...] } ].
def rows(db, kind):
    l = db['lines']
    return [{'line': i, 'fields': l[i]['fields']}
            for i in range(len(l))
            if (l[i].get('kind') or '') == kind]

#------------------------------------------------------------------------------
# merge -- the fields to store for a row edited in the window: a field whose
# shown form is unchanged keeps its original text (degree sign, case), any
# other takes the new text, trimmed.
#------------------------------------------------------------------------------
def merge(old, new):
    return [(old[i] if (i < len(old) and old[i] is not None
                         and shown(old[i]) == n)
             else n)
            for i, n in enumerate(n.strip() if n else '' for n in new)]

#------------------------------------------------------------------------------
# check_row -- what is wrong with a row of table $kind, or None.  With $db
# and the row's own line ($line, None for a new row), checks the row against
# the rest: a pipe size needs its pipe type, and no two rows describe the same
# thing.
#------------------------------------------------------------------------------
def check_row(db, kind, f, line=None):
    t = TABLE.get(kind)
    if not t:
        return 'UNKNOWN TABLE %s' % (kind if kind is not None else '')
    c = t['cols']
    if len(f) != len(c):
        return '%s TAKES %d FIELDS, NOT %d' % (t['title'], len(c), len(f))
    for i, (head, typ) in enumerate(c):
        v = f[i] if i < len(f) and f[i] is not None else ''
        if '|' in v:
            return '%s: THE CHARACTER | SEPARATES FIELDS AND CANNOT BE USED' % head
        if v == '' and head != 'OFFICE USE':
            return '%s IS NEEDED' % head
        if typ == 'code':
            if not re.match(r'^[A-Z0-9_]+\Z', v):
                return "%s '%s' MUST BE CAPITALS AND DIGITS, WITHOUT SPACES" % (head, v)
        elif typ == 'int':
            if not (re.match(r'^\d+\Z', v) and _num(v) > 0):
                return "%s '%s' MUST BE A WHOLE NUMBER ABOVE ZERO" % (head, v)
        elif typ in ('num', 'num0'):
            if typ == 'num0' and v == 'DASH':
                continue
            if not (re.match(r'^(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\Z', v) and _num(v) > 0):
                return ("%s '%s' MUST BE A NUMBER ABOVE ZERO" % (head, v)
                       + (', OR DASH IF NONE IS PUBLISHED' if typ == 'num0' else ''))
    if (kind == 'PIPE' and f[2] != 'DASH' and f[3] != 'DASH'
            and _num(f[3]) >= _num(f[2])):
        return 'BORE MM %s MUST BE LESS THAN OD MM %s' % (f[3], f[2])
    if not db:
        return None
    # Against the rest of the file.
    key = {'PIPETYPE': (0,), 'PIPE': (0, 1), 'FIT': (0, 1, 3), 'KPRIME': (0,)}
    k = '|'.join(f[i] for i in key[kind])
    for r in rows(db, kind):
        if line is not None and r['line'] == line:
            continue
        if '|'.join(_field(r['fields'], i) for i in key[kind]) == k:
            return 'THERE IS ALREADY A ROW FOR %s' % ' '.join(f[i] for i in key[kind])
    if kind == 'PIPE' and not any(_field(r['fields'], 0) == f[0] for r in rows(db, 'PIPETYPE')):
        return 'PIPE TYPE %s IS NOT IN PIPE TYPES: ADD IT THERE FIRST' % f[0]
    return None

#------------------------------------------------------------------------------
# set_row / add_row / delete_row -- edits.  Each checks first and returns the
# problem, or None when the edit was made.
#------------------------------------------------------------------------------
def set_row(db, line, new):
    # a negative line counts from the end, as a Perl array index does
    if line >= len(db['lines']) or line < -len(db['lines']):
        return 'NO SUCH ROW'
    l = db['lines'][line]
    f = merge(l.get('fields') or [], new)
    err = check_row(db, l.get('kind'), f, line)
    if err:
        return err
    if '\x00'.join(f) == '\x00'.join(l['fields']):
        return None
    l['fields'] = f
    l['text'] = '|'.join([l['kind']] + list(f))
    db['modified'] = 1
    return None

# add_row -- a new record, placed after the last of its kind (or at the end).
# Returns (problem, line); line is where it went.
def add_row(db, kind, new):
    f = merge([], new)
    err = check_row(db, kind, f)
    if err:
        return err, None
    r = rows(db, kind)
    at = (r[-1]['line'] + 1) if r else len(db['lines'])
    db['lines'].insert(at, {'text': '|'.join([kind] + list(f)), 'kind': kind, 'fields': f})
    db['modified'] = 1
    return None, at

def delete_row(db, line):
    if line >= len(db['lines']) or line < -len(db['lines']):
        return 'NO SUCH ROW'
    l = db['lines'][line]
    if l.get('kind') not in TABLE:
        return 'NOT A ROW OF A TABLE'
    if l['kind'] == 'PIPETYPE':
        code = _field(l['fields'], 0)
        n = len([r for r in rows(db, 'PIPE') if _field(r['fields'], 0) == code])
        if n:
            return 'PIPE TYPE %s STILL HAS %d PIPE SIZES: DELETE THOSE FIRST' % (code, n)
    del db['lines'][line]
    db['modified'] = 1
    return None

#------------------------------------------------------------------------------
# check_all -- every row checked: [ { kind, line, message } ].  The window
# runs this before saving; nothing is saved while it finds anything.
#------------------------------------------------------------------------------
def check_all(db):
    p = []
    for t in TABLES:
        for r in rows(db, t[0]):
            err = check_row(db, t[0], r['fields'], r['line'])
            if err:
                p.append({'kind': t[0], 'line': r['line'], 'message': err})
    return p

#------------------------------------------------------------------------------
# use_folder -- point this machine at a folder for the database (a team's
# shared folder).  If the folder has no pipes.dat yet and $copy is true, the
# database in use is copied there first, so a team can start its shared
# database from this one.  Returns None, or the problem.
#
# use_builtin -- go back to the program's own database.
#
# Either way the database is loaded again from its new place, and the pick
# lists that remember the old one are cleared.
#------------------------------------------------------------------------------
def use_folder(dir_, copy=False):
    if not os.path.isdir(dir_):
        return 'THE FOLDER %s DOES NOT EXIST OR CANNOT BE REACHED' % dir_
    target = os.path.join(dir_, 'pipes.dat')
    if not os.path.exists(target):
        if not copy:
            return 'THE FOLDER %s HAS NO PIPES.DAT' % dir_
        frm = pipedata.path() or pipedata.default_path()
        try:
            with open(frm, 'rb') as fin:
                b = fin.read()
            with open(target, 'wb') as fout:
                fout.write(b)
        except OSError as e:
            return 'CANNOT READ %s' % frm if e.filename == frm else 'CANNOT WRITE %s: %s' % (target, _err(e))
    try:
        pipedata.load(target)
    except Exception as e:
        pipedata.load()
        return 'THE DATABASE IN THAT FOLDER CANNOT BE USED: %s' % _exc_msg(e).upper()
    settings.set('DATABASE_DIR', dir_)
    phc.reset_db_cache()
    return None

def use_builtin():
    settings.set('DATABASE_DIR', None)
    pipedata.load(pipedata.default_path())
    phc.reset_db_cache()
    return None

def _exc_msg(e):
    if hasattr(e, 'msg'):
        return e.msg
    # Not a model error: in the Perl a die with its text, which ends in a
    # newline -- and the newline is part of the problem reported.
    m = str(e.args[0]) if getattr(e, 'args', None) else str(e)
    return m if m.endswith('\n') else m + '\n'

# today -- the date as the DATASET line writes it: 28 October 2026.
def today(ts=None):
    t = time.localtime(ts if ts is not None else time.time())
    m = ('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
         'September', 'October', 'November', 'December')
    return '%d %s %d' % (t.tm_mday, m[t.tm_mon - 1], t.tm_year)

#------------------------------------------------------------------------------
# text -- the file's text.  When the database has been changed the DATASET
# line takes today's date, so a report printed after the change says so.
#------------------------------------------------------------------------------
def text(db, date=None):
    if db['modified']:
        for l in db['lines']:
            if (l.get('kind') or '') != 'DATASET':
                continue
            # a DATASET line cut short gets its date all the same
            while len(l['fields']) < 2:
                l['fields'].append('')
            l['fields'][1] = date if date is not None else today()
            l['text'] = '|'.join(['DATASET'] + list(l['fields']))
    nl = '\r\n' if db['crlf'] else '\n'
    t = nl.join(l['text'] for l in db['lines'])
    if db['trailing_nl']:
        t += nl
    return t

#------------------------------------------------------------------------------
# save -- check everything, write the file, and make it the database in use.
#
# The new text is written to a temporary file beside the target and read by
# pipedata.load first; only when that succeeds does it replace the
# target.  Then the database is loaded from its new place, and the pick
# lists and line checks that remember it are cleared.
#
# Returns { ok, path, sha256, problems: [...] }.
#------------------------------------------------------------------------------
# save_path -- where an edited database is written.
def save_path(db):
    par = os.environ.get('PAR_TEMP')
    if par and os.path.abspath(db['path']).startswith(par):
        return pipedata.user_path()
    return db['path']

# changed_on_disk -- true when the file has been saved by someone else since
# it was opened here.
def changed_on_disk(db):
    try:
        with open(db['path'], 'rb') as fh:
            raw = fh.read()
    except OSError:
        return False
    return hashlib.sha256(raw).hexdigest() != db.get('sha256')

def save(db, path=None, date=None):
    path = path or save_path(db)
    p = check_all(db)
    if p:
        return {'ok': 0, 'problems': p}
    if path == db['path'] and changed_on_disk(db):
        return {'ok': 0, 'problems': [{'message':
            'THE DATABASE WAS SAVED BY SOMEONE ELSE AFTER YOU OPENED IT. '
            'NOTHING WAS SAVED: RELOAD IT, AND MAKE YOUR CHANGE AGAIN.'}]}
    b = text(db, date).encode('utf-8')
    # File::Basename's dirname: a file named with no folder is in '.'
    d = os.path.dirname(path) or '.'
    if not os.path.isdir(d):
        os.makedirs(d)
    tmp = path + '.new'
    try:
        with open(tmp, 'wb') as fh:
            fh.write(b)
    except OSError as e:
        hardycross.fail('CANNOT WRITE %s: %s', tmp, _err(e))
    try:
        pipedata.load(tmp)
    except Exception as e:
        os.unlink(tmp)
        if os.access(db['path'], os.R_OK):
            pipedata.load(db['path'])
        return {'ok': 0, 'problems': [{'message': _exc_msg(e).upper()}]}
    # Perl's rename replaces an existing file on Windows too; os.rename
    # does not there, os.replace does.
    try:
        os.replace(tmp, path)
    except OSError as e:
        hardycross.fail('CANNOT REPLACE %s: %s', path, _err(e))
    pipedata.load(path)
    phc.reset_db_cache()
    db['path'] = path
    db['modified'] = 0
    db['sha256'] = pipedata.sha256()
    return {'ok': 1, 'path': path, 'sha256': pipedata.sha256()}
