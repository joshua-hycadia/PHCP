#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_dbedit.py -- editing the pipe and fitting database, and choosing where
# it is kept, without Tk (hardycross.dbedit, hardycross.settings).  Python
# port of test_dbedit.pl, check for check.
#
#   python3 tools/test_dbedit.py
#
# Works on copies in a temporary folder, with its own settings file
# (PHCP_SETTINGS), so the real database and a user's real settings are never
# read or written.
#==============================================================================
import os
import re
import shutil
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

TMP = tempfile.mkdtemp()
# Set before the modules are used, as the Perl sets them before require.
os.environ['PHCP_SETTINGS'] = os.path.join(TMP, 'settings.ini')
os.environ.pop('PHCP_DATABASE_DIR', None)

from hardycross import dbedit as DB
from hardycross import pipedata as PD
from hardycross import settings as ST
from hardycross import editor

_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def slurp(p):
    # The raw bytes, as '<:raw' gives the Perl.
    with open(p, 'rb') as f:
        return f.read()


def slurp_text(p):
    return slurp(p).decode('utf-8')


REAL = os.path.join(ROOT, 'data', 'pipes.dat')
ORIG = slurp(REAL)


def count(pat, b):
    return len(re.findall(pat, b, re.M))


#==============================================================================
print('1. READING - four tables, the file kept as it is')
#==============================================================================
shutil.copyfile(REAL, os.path.join(TMP, 'a.dat'))
db = DB.open_db(os.path.join(TMP, 'a.dat'))
n = {t[0]: len(DB.rows(db, t[0])) for t in DB.TABLES}
is_("the four tables: 8 pipe types, 101 sizes, 219 fittings, 19 K' factors",
    n['PIPETYPE'] == 8 and n['PIPE'] == 101 and n['FIT'] == 219 and n['KPRIME'] == 19,
    ' '.join('%s %s' % (k, n[k]) for k in sorted(n)))
is_('an unchanged database writes back to the same bytes',
    DB.text(db).encode('utf-8') == ORIG)
is_('the window shows capitals and ASCII: 90 DEG STANDARD ELBOW',
    DB.shown('90\xb0 standard elbow') == '90 DEG STANDARD ELBOW')

#==============================================================================
print('2. EDITING - change, add, delete; what was not edited keeps its text')
#==============================================================================
if True:
    e = [r for r in DB.rows(db, 'FIT')
         if r['fields'][1] == 'E' and r['fields'][3] == '50' and r['fields'][0] == 'AS'][0]
    shown = [DB.shown(x) for x in e['fields']]
    shown[4] = '1.6'
    err = DB.set_row(db, e['line'], shown)
    is_('a length changed from the window',
        not err and db['lines'][e['line']]['fields'][4] == '1.6', err)
    is_('   the fitting name, not edited, keeps its degree sign and case',
        db['lines'][e['line']]['text'] == 'FIT|AS|E|90\xb0 standard elbow|50|1.6',
        db['lines'][e['line']]['text'])
    is_('   and the file is marked changed', db['modified'])
    err = DB.set_row(db, e['line'], shown[0:4] + ['LOTS'])
    is_('a length that is not a number is refused, saying why',
        re.search(r"EQV LENGTH M 'LOTS' MUST BE A NUMBER", err or ''), err)
    err = DB.set_row(db, e['line'], shown[0:4] + ['DASH'])
    is_('DASH, none published, is accepted for a length', not err, err)
    e2, at = DB.add_row(db, 'PIPE', ['ASAM', '200', '219.1', '206.5', '5e-08'])
    nxt = db['lines'][at + 1] if at + 1 < len(db['lines']) else {}
    is_('a new pipe size is added after the last of its kind',
        not e2 and db['lines'][at]['text'] == 'PIPE|ASAM|200|219.1|206.5|5e-08'
        and (db['lines'][at - 1].get('kind') or '') == 'PIPE'
        and (nxt.get('kind') or '') != 'PIPE', e2)
    e2 = DB.add_row(db, 'PIPE', ['ASAM', '200', '219.1', '206.5', '5e-08'])[0]
    is_('the same size again is refused', re.search(r'ALREADY A ROW FOR ASAM 200', e2 or ''), e2)
    e2 = DB.add_row(db, 'PIPE', ['NOPE', '50', '60', '50', '1e-5'])[0]
    is_('a size for a pipe type that does not exist is refused',
        re.search(r'PIPE TYPE NOPE IS NOT IN PIPE TYPES', e2 or ''), e2)
    e2 = DB.add_row(db, 'PIPE', ['ASAM', '225', '200', '210', '1e-8'])[0]
    is_('a bore larger than its OD is refused',
        re.search(r'BORE MM 210 MUST BE LESS THAN OD MM 200', e2 or ''), e2)
    e2 = DB.add_row(db, 'KPRIME', ['x y', 'A', '5', ''])[0]
    is_('a code with lower case or spaces is refused', re.search(r'CAPITALS AND DIGITS', e2 or ''), e2)
    e2 = DB.add_row(db, 'KPRIME', ['ZZ', 'A|B', '5', ''])[0]
    is_('a | in a field is refused', re.search(r'SEPARATES FIELDS', e2 or ''), e2)
    pt = [r for r in DB.rows(db, 'PIPETYPE') if r['fields'][0] == 'ASAM'][0]
    d = DB.delete_row(db, pt['line'])
    is_('a pipe type with sizes cannot be deleted', re.search(r'STILL HAS 12 PIPE SIZES', d or ''), d)
    kp = [r for r in DB.rows(db, 'KPRIME') if r['fields'][0] == 'TR'][0]
    is_("a K' factor row can be deleted", not DB.delete_row(db, kp['line'])
        and not [r for r in DB.rows(db, 'KPRIME') if r['fields'][0] == 'TR'])
    ah = [r for r in DB.rows(db, 'PIPE')
          if r['fields'][0] == 'ASAH' and r['fields'][1] == '150'][0]
    is_('a pipe size can be deleted', not DB.delete_row(db, ah['line']))
    is_('every row still passes', not DB.check_all(db))

#==============================================================================
print('3. SAVING - checked, dated, loaded, fingerprinted')
#==============================================================================
if True:
    a = os.path.join(TMP, 'a.dat')
    r = DB.save(db, a, '1 November 2026')
    is_('the edited database saves', r['ok'],
        ' / '.join(p['message'] for p in (r.get('problems') or [])))
    t = slurp(a)
    is_('   the DATASET line takes the date of the change',
        re.search(rb'^DATASET\|Hycadia pipe and fitting database\|1 November 2026\r?$', t, re.M))
    is_('   it is the database in use now, with the new fingerprint',
        PD.path() == a and PD.sha256() == r['sha256']
        and float(PD.bore('ASAM', 200)) == 206.5)
    is_('   the deleted row is gone from the loaded data too (a reload starts clean)',
        PD.bore('ASAH', 150) is None and PD.bore('ASAH', 125) is not None)
    is_('   comments and blank lines are all still there',
        count(rb'^#', t) == count(rb'^#', ORIG) and count(rb'^$', t) == count(rb'^$', ORIG))
    is_('   and nothing was left behind (no .new file)', not os.path.exists(a + '.new'))

    d2 = DB.open_db(a)
    other = DB.open_db(a)
    e = DB.rows(other, 'KPRIME')[0]
    DB.set_row(other, e['line'], [DB.shown(x) for x in e['fields'][0:2]] + ['41', ''])
    DB.save(other, a)
    f = DB.rows(d2, 'KPRIME')[0]
    DB.set_row(d2, f['line'], [DB.shown(x) for x in f['fields'][0:2]] + ['42', ''])
    r = DB.save(d2, a)
    is_('two people at once: the second save is refused, not lost over the first',
        not r['ok'] and re.search(r'SAVED BY SOMEONE ELSE', r['problems'][0]['message'])
        and re.search(rb'\|41\|', slurp(a)))

#==============================================================================
print('4. WHERE THE DATABASE IS - a team folder, else the built-in one')
#==============================================================================
if True:
    DB.use_builtin()
    is_('with no folder set, the built-in database is used',
        ST.database_dir() is None and PD.origin() == 'BUILT-IN')
    team = os.path.join(TMP, 'team')
    os.mkdir(team)
    err = DB.use_folder(team, 0)
    is_('an empty folder is refused unless the database is to be copied there',
        re.search(r'HAS NO PIPES.DAT', err or ''), err)
    err = DB.use_folder(team, 1)
    is_('choosing it with copy: this database is copied there and used',
        not err and os.path.exists(os.path.join(team, 'pipes.dat'))
        and slurp(os.path.join(team, 'pipes.dat')) == ORIG
        and PD.origin() == 'TEAM FOLDER', err)
    is_('   the choice is kept in the settings file',
        ST.get('DATABASE_DIR') == team
        and re.search(r'^DATABASE_DIR=' + re.escape(team) + r'\r?$',
                      slurp_text(os.environ['PHCP_SETTINGS']), re.M))   # CR LF on Windows
    is_('   and the next load, anywhere in the program, uses it',
        PD.default_path() == os.path.join(team, 'pipes.dat'))
    ed = DB.open_db()
    is_('   editing it saves back to the team folder',
        DB.save_path(ed) == os.path.join(team, 'pipes.dat'))
    r = editor.solve_text(slurp_text(os.path.join(ROOT, 'examples', '07_pipe_database_demo.phc')), None)
    flat = re.sub(r'\s+', ' ', r.get('report') or '')
    i = flat.find('database:')
    is_("   a report names the team folder's file in full, and says it is the team's",
        re.search(re.escape(team) + r'.?pipes\.dat \(team folder\), SHA-256 [0-9a-f]{64}', flat),
        flat[i:i + 200] if i >= 0 else flat[-1:][:200])
    os.unlink(os.path.join(team, 'pipes.dat'))
    try:
        PD.load()
        ok, msg = True, ''
    except Exception as ex:
        ok, msg = False, str(ex)
    is_('if the team folder cannot be read, loading stops and says where - no quiet fallback',
        not ok and re.search(r'cannot open the pipe and fitting database .*team.*the database '
                             r'folder set in the PHCP settings', msg, re.S), msg)
    err = DB.use_folder(os.path.join(TMP, 'nowhere'), 1)
    is_('a folder that does not exist is refused', re.search(r'DOES NOT EXIST', err or ''), err)
    os.environ['PHCP_DATABASE_DIR'] = os.path.join(TMP, 'env')
    is_('PHCP_DATABASE_DIR, if set, wins over the settings file',
        ST.database_dir() == os.path.join(TMP, 'env'))
    del os.environ['PHCP_DATABASE_DIR']
    DB.use_builtin()
    is_('USE BUILT-IN clears the setting and goes back', ST.database_dir() is None
        and PD.origin() == 'BUILT-IN')

print('5. ROUGHNESS - a column of PIPE TYPES')
if True:
    c = [x[0] for x in DB.table('PIPETYPE')['cols']]
    is_('PIPE TYPES has ROUGHNESS MM after C FACTOR', ' '.join(c[4:6]) == 'C FACTOR ROUGHNESS MM')
    d = DB.open_db(REAL)
    pe = ([r for r in DB.rows(d, 'PIPETYPE') if r['fields'][0] == 'PE11'] or [None])[0]
    is_('   PE11 reads 0.007 mm', pe and pe['fields'][5] == '0.007')
    shown = [DB.shown(x) for x in pe['fields']]
    shown[5] = '0'
    e0 = DB.set_row(d, pe['line'], shown)
    is_('   a roughness of 0 is refused',
        re.search(r"ROUGHNESS MM '0' MUST BE A NUMBER ABOVE ZERO, OR DASH", e0 or ''))
    shown[5] = '0.015'
    is_('   0.015 is accepted', DB.set_row(d, pe['line'], shown) is None and d['modified'])
    # A database from before the column: its pipe types read with DASH.
    old = re.sub(r'^(PIPETYPE\|[^\n]*)\|[^|\n]*$', r'\1', slurp_text(REAL), flags=re.M)
    with open(os.path.join(TMP, 'old.dat'), 'w', newline='', encoding='utf-8') as o:
        o.write(old)
    od = DB.open_db(os.path.join(TMP, 'old.dat'))
    p = DB.check_all(od)
    is_('   an older database without it opens: roughness DASH, nothing to put right, nothing changed',
        not p and not od['modified']
        and [r for r in DB.rows(od, 'PIPETYPE') if r['fields'][0] == 'ASAM'][0]['fields'][5] == 'DASH',
        '; '.join(x['message'] for x in p))
is_('the real database was never touched', slurp(REAL) == ORIG)

shutil.rmtree(TMP, ignore_errors=True)
print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
