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
print('6. AS THE PERL - where the port and the Perl could differ')
# Each of these was a difference between the port and the Perl 1.6.0, found
# by reading the two side by side and run on both; what is asserted is what
# the Perl gives.
if True:
    import hardycross
    import hashlib

    def put(name, data):
        p = os.path.join(TMP, name)
        with open(p, 'wb') as o:
            o.write(data)
        return p

    def died(code):
        try:
            code()
        except hardycross.ModelError as e:
            return e.msg
        return None

    e = died(lambda: DB.open_db(os.path.join(TMP, 'nonesuch.dat')))
    is_('a database that is not there: the reason alone, in capitals',
        e == 'CANNOT OPEN THE DATABASE %s: NO SUCH FILE OR DIRECTORY' % os.path.join(TMP, 'nonesuch.dat'), e)
    os.mkdir(os.path.join(TMP, 'isdir.dat.new'))
    d = DB.open_db(REAL)
    e = died(lambda: DB.save(d, os.path.join(TMP, 'isdir.dat')))
    is_('   likewise a file that cannot be written',
        e is not None and re.match(r'CANNOT WRITE %s: [A-Z ]+\Z' % re.escape(os.path.join(TMP, 'isdir.dat.new')), e), e)
    PD.load(REAL)

    d = DB.open_db(put('l1.dat', b'# caf\xe9\nKPRIME|X|caf\xe9 \xb0|1.5|\n'))
    f = DB.rows(d, 'KPRIME')[0]['fields']
    is_('a file that is not UTF-8 opens, each byte a character',
        f[1] == 'caf\xe9 \xb0' and DB.shown(f[1]) == 'CAF  DEG'
        and DB.text(d).encode('utf-8') == b'# caf\xc3\xa9\nKPRIME|X|caf\xc3\xa9 \xc2\xb0|1.5|\n', f)

    d = DB.open_db(put('e.dat', b''))
    err, at = DB.add_row(d, 'PIPETYPE', ['X', 'n', 's', 'r', '120', 'DASH'])
    is_('an empty file has no lines: the first row added is line 0',
        err is None and at == 0 and len(d['lines']) == 1 and DB.text(d, 'D') == 'PIPETYPE|X|n|s|r|120|DASH\n',
        (err, at, DB.text(d, 'D')))

    d = DB.open_db(put('ar.dat', ('PIPETYPE|T|n|s|r|120|DASH\nPIPE|T|\u0663|60|5\u0663|DASH\n'
                                  'PIPE|T|1\u0663|6\u0660|53|DASH\nKPRIME|K|c|\u0663|\n').encode('utf-8')))
    is_('figures that are not 0-9 count for nothing: a DN of Arabic-Indic 3 is 0, and refused',
        ['%d: %s' % (p['line'], p['message']) for p in DB.check_all(d)]
        == ["1: DN '\u0663' MUST BE A WHOLE NUMBER ABOVE ZERO", '2: BORE MM 53 MUST BE LESS THAN OD MM 6\u0660',
            "3: K' '\u0663' MUST BE A NUMBER ABOVE ZERO"], DB.check_all(d))

    d = DB.open_db(put('sh.dat', b'PIPETYPE\nPIPETYPE|T|n|s|r|120|DASH\nPIPE|T\nPIPE\nPIPE|T|50|60|53|DASH\n'
                                 b'FIT|S\nFIT|S|E|elbow|50|1.5\nKPRIME\nDATASET\n'))
    p = DB.check_all(d)
    is_('rows cut short in the file are each named, and the whole rows beside them still checked',
        ['%d: %s' % (x['line'], x['message']) for x in p]
        == ['0: PIPE TYPES TAKES 6 FIELDS, NOT 0', '2: PIPE SIZES TAKES 5 FIELDS, NOT 1',
            '3: PIPE SIZES TAKES 5 FIELDS, NOT 0', '5: FITTINGS TAKES 5 FIELDS, NOT 1',
            "7: K' FACTORS TAKES 4 FIELDS, NOT 0"], p)
    is_('   a pipe type is still counted against them',
        DB.delete_row(d, 1) == 'PIPE TYPE T STILL HAS 2 PIPE SIZES: DELETE THOSE FIRST')
    d['modified'] = 1
    is_('   and a DATASET line cut short takes its date', DB.text(d, 'D').endswith('KPRIME\nDATASET||D\n'), DB.text(d, 'D')[-30:])

    d = DB.open_db(put('n.dat', b'# c\nKPRIME|A|x|1|\nKPRIME|B|y|2|\n'))
    r = [DB.set_row(d, -1, ['B', 'z', '3', '']), DB.set_row(d, -1, ['C', 'z', '3', '']),
         DB.set_row(d, -4, ['C', 'z', '3', '']), DB.set_row(d, 3, ['C', 'z', '3', '']),
         DB.delete_row(d, -2), DB.delete_row(d, -9), DB.delete_row(d, 0)]
    is_('a line counted from the end is that line, as a Perl index is',
        r == ['THERE IS ALREADY A ROW FOR B', None, 'NO SUCH ROW', 'NO SUCH ROW', None, 'NO SUCH ROW',
              'NOT A ROW OF A TABLE'] and DB.text(d) == '# c\nKPRIME|C|z|3|\n', (r, DB.text(d)))

    d = DB.open_db(put('dt.dat', b'DATASET|n|old\r\nKPRIME|A|x|1|\r\n'))
    d['modified'] = 1
    is_("a date given as '' is the date written", DB.text(d, '') == 'DATASET|n|\r\nKPRIME|A|x|1|\r\n', DB.text(d, ''))

    # save to a file named with no folder: it is in the folder we are in
    here = os.getcwd()
    os.mkdir(os.path.join(TMP, 'sv'))
    shutil.copy(REAL, os.path.join(TMP, 'sv', 'pipes.dat'))
    os.chdir(os.path.join(TMP, 'sv'))
    try:
        d = DB.open_db('pipes.dat')
        r0 = DB.rows(d, 'KPRIME')[0]
        f = list(r0['fields'])
        f[1] = 'CHANGED'
        e = DB.set_row(d, r0['line'], f)
        s = DB.save(d, None, '1 January 2030')
        is_('a database named with no folder is saved where it is',
            e is None and s['ok'] and s['path'] == 'pipes.dat' and not os.path.exists('pipes.dat.new')
            and s['sha256'] == hashlib.sha256(slurp('pipes.dat')).hexdigest(), s)

        # A file with no newline at its end is written back as it was, and
        # can be saved over.  (The Perl cannot save over it: a slip in
        # open_db loses the fingerprint.  A defect there, deliberately not
        # copied.)
        with open('nonl.dat', 'wb') as o:
            o.write(ORIG.rstrip(b'\r\n'))
        d = DB.open_db('nonl.dat')
        is_('a file with no newline at its end: unchanged, it writes back to the same bytes',
            DB.text(d).encode('utf-8') == ORIG.rstrip(b'\r\n')
            and d.get('sha256') == hashlib.sha256(ORIG.rstrip(b'\r\n')).hexdigest())
        r0 = DB.rows(d, 'KPRIME')[0]
        f = list(r0['fields'])
        f[1] = 'CHANGED'
        DB.set_row(d, r0['line'], f)
        s = DB.save(d, None, 'D')
        s2 = DB.save(d, None, 'D')
        is_('   it is saved over, and saved again', s['ok'] and s['path'] == 'nonl.dat' and s2['ok'], (s, s2))

        # a database that will not load: the problem as the Perl words it
        d = DB.open_db('pipes.dat')
        d['modified'] = 1
        d['lines'][:] = [l for l in d['lines'] if l.get('kind') != 'DATASET']
        s = DB.save(d, 'bad2.dat')
        is_('a database that will not load is not saved: the reason in capitals, ending as the Perl ends it',
            not s['ok'] and s['problems'][0]['message']
            == 'DATABASE BAD2.DAT.NEW HAS NO DATASET LINE -- ADD ONE NAMING THIS DATA AND ITS DATE\n'
            and not os.path.exists('bad2.dat.new') and not os.path.exists('bad2.dat'), s)
    finally:
        os.chdir(here)
        PD.load(REAL)

is_('the real database was never touched', slurp(REAL) == ORIG)

shutil.rmtree(TMP, ignore_errors=True)
print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
