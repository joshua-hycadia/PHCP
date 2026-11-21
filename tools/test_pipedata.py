#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_pipedata.py -- the pipe and fitting database and its resolver.
# Python port of test_pipedata.pl, check for check.
#
#   python3 tools/test_pipedata.py
#
# Reproduces hand-calculated values: a DN300 Schedule 20 tee, the C multiplier
# and diameter modifier at a spread of types and sizes, and every pipe K in the
# database from its own bore and C.  A wrong basis bore, exponent or source
# boundary would each show up here as a mismatch.  Also checks the rules: a
# dash is DATA_REQUIRED and never zero, CPVC and PE take no corrections, PVC-M
# is a fallback that must be flagged, and fittings that do not turn the flow
# are not counted.
#
# The database is user editable.  If an edit makes this test fail, either the
# edit is wrong or the expected value here must be re-derived by hand -- never
# just changed to match.
#==============================================================================
import os
import re
import shutil
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

from hardycross import pipedata as PD
from hardycross import parse

PD.load(os.path.join(ROOT, 'data', 'pipes.dat'))

_pass, _fail = 0, 0


def _count(ok):
    global _pass, _fail
    if ok:
        _pass += 1
    else:
        _fail += 1


def pstr(v):
    # A number as Perl prints it ("$x"): 1.000 is "1", 0.71 is "0.71".
    if isinstance(v, float):
        s = '%.15g' % v
        return s
    return str(v)


def near(name, got, want, tol):
    ok = got is not None and abs(float(got) - want) <= tol
    print('  %-58s %9s  want %-7s %s' % (
        name, '%.3f' % float(got) if got is not None else 'undef',
        pstr(want), 'ok' if ok else '*** FAIL'))
    _count(ok)


def is_(name, ok):
    print('  %-58s %s' % (name, 'ok' if ok else '*** FAIL'))
    _count(ok)


R = PD.resolve

print('HAND CHECK - DN300 Schedule 20 tee, flow turned')
r = R(type='S20', dn=300, spec='T')
# FM base 18.3 m on Schedule 40, corrected to the Schedule 20 bore:
# 18.3 x (d S20 / d S40)^4.87 = 18.3 x 1.13378 = 20.748 m.  Rounding the
# modifier to 1.134 first gives 20.752; the engine carries the exact value.
near('DN300 tee, flow turned, Schedule 20, exact', r['total'], 20.748, 0.001)
near('   its diameter modifier -> 1.134', r['records'][0]['dmult'], 1.134, 0.0005)

print('C MULTIPLIER - (C / 120)^1.85')
for c, want in ([100, 0.71], [110, 0.85], [130, 1.16], [140, 1.33], [150, 1.51]):
    x = R(type='ASAM', dn=50, c=c, spec='E')
    near('C = %s' % c, x['records'][0]['cmult'], want, 0.005)

print('DIAMETER MODIFIER - AS 2118.1 values on other pipe')
for t, dn, want in (['ASAM', 50, 1.000], ['ASAH', 20, 0.757], ['ASAH', 150, 0.966],
                    ['S40', 25, 0.888], ['S40', 65, 0.640], ['S40', 150, 0.959]):
    x = R(type=t, dn=dn, spec='E')
    near('%s DN%s' % (t, dn), x['records'][0]['dmult'], want, 0.0005)

print('DIAMETER MODIFIER - FM DS 3-0 values on other pipe')
for dn, want in ([200, 1.091], [250, 1.117], [300, 1.134], [350, 1.097],
                 [450, 1.153], [600, 1.142]):
    x = R(type='S20', dn=dn, spec='E45')
    near('S20 DN%s' % dn, x['records'][0]['dmult'], want, 0.0005)

print('PIPE K - every K reproduces from its own d and C')
kmax, kworst = 0, ''
for t in PD.pipe_types():
    c = float(PD.pipe_type(t)['c'])
    for dn in [d for d in range(15, 701) if PD.bore(t, d) is not None]:
        row = PD.pipe_row(t, dn)
        if not row:
            continue
        if row['k'] == 'DASH':
            continue
        k = 6.05e7 / (c ** 1.85 * float(row['bore']) ** 4.87)
        rel = abs(k - float(row['k'])) / float(row['k'])
        if rel > kmax:
            kmax, kworst = rel, '%s DN%s' % (t, dn)
near('worst K disagreement (%s), as a fraction' % kworst, kmax, 0, 0.006)

print('RULES')
cv = R(type='ASAM', dn=20, spec='CV')
is_('DN20 check valve (dash) -> DATA_REQUIRED, never zero',
    cv['total'] is None and cv['records'][0]['status'] == 'DATA_REQUIRED')
is_('   ...and the message names the component',
    re.search(r'CV on ASAM DN20', (cv['errors'] or [''])[0]) is not None)
se = R(type='S20', dn=350, spec='E')
is_('screwed elbow above DN300 (dash) -> DATA_REQUIRED', se['total'] is None)
ef = R(type='S20', dn=350, spec='EF')
is_('flanged elbow at DN350 resolves', ef['total'] is not None and ef['total'] > 0)
cp = R(type='CPVC', dn=25, spec='2E')
near('CPVC DN25 2E, BlazeMaster, no corrections', cp['total'], 3.0, 0.001)
is_('   CPVC carries no C or D multiplier',
    cp['records'][0]['cmult'] == 1 and cp['records'][0]['dmult'] == 1)
tr = R(type='CPVC', dn=25, spec='1TR')
is_('CPVC tee run is published but not counted',
    tr['total'] == 0 and tr['records'][0]['method'] == 'NOT_COUNTED')
pe = R(type='PE11', dn=110, spec='E')
bpe = float(PD.bore('PE11', 110))
near('PE11 DN110 90deg elbow, Le = 40 x d', pe['total'], 40 * bpe / 1000, 1e-9)
is_('   PE carries no corrections', pe['records'][0]['dmult'] == 1)
pv = R(type='PVCM16', dn=150, spec='E')
is_('PVC-M fitting is a controlled fallback -> ASSUMPTION_REQUIRED',
    pv['records'][0]['status'] == 'ASSUMPTION_REQUIRED')
hc = R(type='ASAM', dn=25, spec='1E1T')
near('compact form 1E1T, ASAM DN25 = 0.6 + 1.5', hc['total'], 2.1, 0.001)
bad = R(type='ASAM', dn=25, spec='2E,1X')
is_('an unknown code is an error, not skipped', bad['total'] is None)
so = R(type='ASAH', dn=20, spec='E', standard_only=1)
is_('Standard-alone election leaves AS 2118.1 values unmodified',
    so['records'][0]['dmult'] == 1)

print('REGRESSION')
tk = parse.tokenize('  M1 A B 12 100 TYPE=ASAM FIT=1T,2E,1GV,1CV')
fit = ([t for t in tk if t.startswith('FIT=')] or [None])[0]
is_('commas inside FIT= survive the tokeniser (was cut to the first fitting)',
    (fit or '') == 'FIT=1T+2E+1GV+1CV')
all_ = R(type='ASAM', dn=100, spec='1T+2E+1GV+1CV')
near('   and all four resolve: 6.1 + 2x3.0 + 0.6 + 6.7', all_['total'], 19.4, 0.001)

print('ROUGHNESS')
if True:
    k = {t: PD.pipe_type(t)['eps'] for t in PD.pipe_types()}
    is_('every pipe type has a roughness for Darcy-Weisbach',
        not [t for t in k if k[t] is None or float(k[t]) <= 0])
    # A database written before the roughness column: still read, roughness none.
    d = tempfile.mkdtemp()
    with open(PD.path(), 'rb') as f:
        old = f.read().decode('utf-8')
    old = re.sub(r'^(PIPETYPE\|[^\n]*)\|[^|\n]*$', r'\1', old, flags=re.M)
    with open(os.path.join(d, 'pipes.dat'), 'wb') as f:
        f.write(old.encode('utf-8'))
    was = PD.path()
    PD.load(os.path.join(d, 'pipes.dat'))
    is_('   a database without the column still loads; roughness none published',
        bool(PD.pipe_type('ASAM')) and PD.pipe_type('ASAM')['eps'] is None
        and float(PD.bore('ASAM', 50)) == 53.0)
    PD.load(was)
    shutil.rmtree(d, ignore_errors=True)

print('LINE ENDINGS')
if True:
    # The database saved with Windows line endings must read the same: a
    # DASH at the end of a line is still none published, never zero.
    d = tempfile.mkdtemp()
    with open(PD.path(), 'rb') as f:
        crlf = re.sub(r'\r?\n', '\r\n', f.read().decode('utf-8'))
    with open(os.path.join(d, 'pipes.dat'), 'wb') as f:
        f.write(crlf.encode('utf-8'))
    was = PD.path()
    PD.load(os.path.join(d, 'pipes.dat'))
    r = R(type='ASAM', dn=20, spec='CV')
    is_('CR LF file: the DN20 check valve (dash) is still DATA_REQUIRED, not zero',
        r['total'] is None)
    is_('   and every roughness still reads',
        not [t for t in PD.pipe_types() if PD.pipe_type(t)['eps'] is None])
    PD.load(was)
    shutil.rmtree(d, ignore_errors=True)

print('READ AS THE PERL READ IT (the audit of 20 November 2026)')
if True:
    # The database is user editable, and Perl took whatever a line held: a
    # short line's missing fields were undef, text where a number belongs
    # was the number it starts with or 0, a byte that is not UTF-8 was kept
    # as \xHH.  Each of these stopped the Python with a traceback; each is
    # checked here against what the Perl gives for the same file.
    import math
    import subprocess
    d = tempfile.mkdtemp()
    was = PD.path()
    with open(was, 'rb') as f:
        good = f.read()

    def db(extra, sub=None):
        path = os.path.join(d, 'pipes.dat')
        with open(path, 'wb') as f:
            f.write((sub(good) if sub else good) + extra)
        return path

    def loads(extra, sub=None):
        try:
            PD.load(db(extra, sub))
            return ''
        except BaseException as e:
            return str(e) or 'failed'

    e = loads(b'DRYVALVE|ACME\nDRYVALVE\nPIPETYPE\n|\nXX\n')
    is_('lines with fields missing still load', e == '')
    is_('   a DRYVALVE line with nothing after it is listed blank',
        e == '' and PD.dry_valve_models()[0] == ['', '', ['']])
    e = loads(b'FIT|AS|E|Elb\xe9w|25|0.8\n')
    r = R(type='ASAM', dn=25, spec='E') if e == '' else {'records': [{}]}
    is_('a byte that is not UTF-8 is kept as \\xHH, not refused',
        e == '' and r['records'][0].get('label') == 'Elb\\xE9w')
    e = loads(b'FIT|AS|E|Elbow|25|abc\nFIT|AS|T|Tee|25\nFIT|AS|EL|Long|25|1.5x\n')
    r = R(type='ASAM', dn=25, spec='E,T,EL') if e == '' else {'records': [], 'errors': None}
    is_('a length that is no number: the number it starts with, or 0',
        e == '' and r['errors'] == [] and [x['each'] for x in r['records']] == [0, 0, 1.5]
        and r['total'] == 1.5)
    e = loads(b'PIPETYPE|ZZ|Name|std|range|abc\nPIPE|ZZ|25|30|27|1\n'
              b'PIPETYPE|ZY|Name|std|range\nPIPE|ZY|25|30|27|1\n')
    is_('so is a C that is no number, or is missing',
        e == '' and [R(type=t, dn=25, spec='E')['total'] for t in ('ZZ', 'ZY')] == [0, 0])
    e = loads(b'PIPE|ASAM|abc|10|9|1\nFIT|AS|E|Elbow|abc|0.5\n')
    is_('and a nominal size that is none (size 0: AS 2118.1)',
        e == '' and R(type='ASAM', dn='abc', spec='E')['total'] == 0.5)
    e = loads(b'DRYVALVE|TYCO|DPV-1|X|9|2.2|FT|100|S40|5.5|250PSI|CURRENT|src|DASH\n')
    is_('a dry pipe valve size that is no number sorts as 0',
        e == '' and [m[2] for m in PD.dry_valve_models() if m[:2] == ['TYCO', 'DPV-1']]
        == [['X', '65', '80', '100', '150']])
    e = loads(b'', lambda t: re.sub(rb'(?m)^DATASET\|[^|]*', b'DATASET|0', t))
    is_('a DATASET named 0 is no DATASET (0 is false in Perl)',
        re.search(r'has no DATASET line -- add one naming this data and its date\n\Z', e))
    try:
        PD.load(os.path.join(d, 'none', 'pipes.dat'))
        e = ''
    except BaseException as ex:
        e = str(ex)
    is_('no database: the reason in the system\'s words, the line ended',
        e == 'cannot open the pipe and fitting database %s: %s\n'
        % (os.path.join(d, 'none', 'pipes.dat'), os.strerror(2)))
    PD.load(was)

    is_('a count is printed as typed: 0100E is a count of 0100',
        PD.parse_fittings('0100E')[1] == "fitting count of 0100 for 'E' is not plausible for "
        "one pipe (limit 99); check the string")
    is_('   and 007T is seven tees', PD.parse_fittings('007T') == ([[7, 'T']], None))
    is_('a fitting string that is the number 0 is read, and refused',
        PD.parse_fittings(0) == (None, "cannot read fitting code at '0'"))
    is_('a DN given as a float is the same DN (25.0 is 25)',
        PD.bore('S40', 25) is not None and PD.bore('S40', 25.0) == PD.bore('S40', 25)
        and R(type='S40', dn=25.0, spec='E')['total'] == R(type='S40', dn=25, spec='E')['total'])
    is_('no pipe type at all is the unknown type \'\'',
        R(type=None, dn=25, spec='E')['errors'] == ["unknown pipe type ''"])
    t = R(type='S40', dn=100, c=-120, spec='E')['total']
    is_('a negative C gives NaN, not a complex number',
        isinstance(t, float) and math.isnan(t))
    is_('a C too large to raise to a power gives infinity, not an error',
        R(type='ASAM', dn=25, c='1e300', spec='E')['total'] == float('inf'))
    if os.sep == '/':
        is_('paths are tidied as File::Spec tidies them, not resolved',
            [PD.catfile('.', './sub'), PD.catfile('a//b/', 'c//d/./e'), PD.catfile('.', '../x'),
             PD.catfile('/', 'x'), PD.catfile('/a/b', 'x.phg')]
            == ['./sub', 'a/b/c/d/e', './../x', '/x', '/a/b/x.phg'])
        old = os.environ.get('PHCP_DATABASE_DIR')
        os.environ['PHCP_DATABASE_DIR'] = './team//db/'
        is_('   the database folder of the settings too', PD.default_path() == 'team/db/pipes.dat')
        if old is None:
            del os.environ['PHCP_DATABASE_DIR']
        else:
            os.environ['PHCP_DATABASE_DIR'] = old
        # The program run through a linked folder names its database by the
        # real path, and still knows it as its own.
        link = os.path.join(d, 'link')
        os.symlink(ROOT, link)
        env = dict(os.environ)
        env.pop('PHCP_DATABASE_DIR', None)
        out = subprocess.run([sys.executable, os.path.join(link, 'phcp'), '--json',
                              os.path.join(ROOT, 'examples', '07_pipe_database_demo.phc')],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env).stdout.decode('utf-8', 'replace')
        m = re.search(r'"file" : "([^"]*)"', out)
        is_('through a linked folder, the database has its real path',
            m and m.group(1) == os.path.realpath(os.path.join(ROOT, 'data', 'pipes.dat')))
    shutil.rmtree(d, ignore_errors=True)

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
