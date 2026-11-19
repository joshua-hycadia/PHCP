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

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
