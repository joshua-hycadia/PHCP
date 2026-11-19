#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_acceptance.py -- the false positives found in the audit of 11 November
# 2026, each refused.  Python port of test_acceptance.pl, check for check.
#
#   python3 tools/test_acceptance.py
#
# Every case was written BEFORE its correction and failed on PHCP 1.5.0 as
# released (main at f050571): each shows a calculation PHCP accepted, or a
# check it did not make.  The parts:
#
#   1. HYDRAULIC CONSTANTS AND SETTINGS: HW_CONST of zero, negative, in other
#      units or enormous; a non-finite number; tolerances and the orifice
#      step that are not positive; a C factor no pipe has.
#   2. SOLVER TOLERANCES AGAINST VERIFICATION LIMITS: a loose TOL_LOOP lets
#      the iteration stop early, but the final check is made to PHCP's own
#      limit, which no setting changes.
#   3. CLOSED DEVICES: a closed element carrying flow is caught on its own.
#   4. SEVERAL SUPPLIES: a joint demand at which a supply takes water in is
#      not a demand the design may rest on; a trial that is physically
#      invalid, or does not converge, is never taken for a supply too weak.
#   5. ORIFICE PLATES: the final drop against the target, to a stated
#      tolerance, with the deviation split into rounding and flow.
#   6. CURVES: non-finite points refused; operation far beyond the points
#      refused; extrapolation labelled.
#   7. DRY PIPE VALVES: a constant loss labelled, and refused at no flow; a
#      loss curve that is negative at no flow refused; a database valve with
#      no usable loss is DATA_REQUIRED, not a zero loss; the time estimates
#      decide nothing.
#   8. INTEGRATION: the strict exit status, JSON's "approved", the results
#      block (current, stale, tampered), and the command line, the JSON, the
#      editor and the report agreeing on every case above.
#
# These tests check PHCP against the conditions it sets itself.  They are not
# evidence of conformance with any Standard or of external certification.
#==============================================================================
import glob
import json
import os
import re
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, validate, demand, jsonout, report, results
from hardycross import is_model_error

_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-70s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def true(x):
    # Perl truth: undef, '', '0', 0 and false are false; a reference is true.
    if x is None or x is False:
        return False
    if isinstance(x, (dict, list)):
        return True
    if isinstance(x, str):
        return x not in ('', '0')
    if isinstance(x, (int, float)):
        return x != 0
    return bool(x)          # JSON::PP::true / ::false, as hardycross.jsonout's


def dd(x, d):
    # Perl's //: x unless it is undef.
    return d if x is None else x


def pstr(x):
    # A value interpolated into a Perl string: undef is empty.
    if x is None:
        return ''
    if isinstance(x, float) and x == int(x) and abs(x) < 1e15:
        return '%d' % x
    return '%s' % x


HEAD = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                  'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', ''])
# One K80 sprinkler at the end of 100 m of 100 mm pipe from a 900 kPa supply.
ONE = 'USE BORE 120\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 100 100\n'
# A looped network: two parallel paths between A and B.
LOOP = ('USE BORE 120\nWATER S 0 700\nNODE A 0\nNODE B 0\nNODE C 0\nSPRINKLER H 0 -50 80\n'
        'PIPE P1 S A 10 100\nPIPE P2 A B 50 50\nPIPE P3 A C 20 25\nPIPE P4 C B 20 25\nPIPE P5 B H 5 50\n')
# Two static supplies.  WA is strong and far; WB is weak and near the
# sprinkler.  As modelled both deliver; derated together, WB takes water in
# long before the sprinkler reaches its minimum.
TWO = ('USE BORE 120\nWATER WA 0 1000\nWATER WB 0 520\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n'
       'PIPE A1 WA J1 60 65\nPIPE B1 WB J2 5 100\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n')


# refused -- the error message if model text is refused, else None.
def refused(text):
    try:
        n = phc.read_string(text)
    except Exception as e:
        return e.msg if is_model_error(e) else str(e)
    return None if true(n) else ''


def solve(text):
    net = phc.read_string(text)
    ok = hardycross.solve_model(net)
    return net, ok


def assessed(text):
    net, ok = solve(text)
    return net, ok, validate.assess(net, ok)


def errs(v):
    c = {}
    for f in v['findings']:
        if f['severity'] == 'error':
            c[f['code']] = c.get(f['code'], 0) + 1
    return c


def warns(v):
    c = {}
    for f in v['findings']:
        if f['severity'] == 'warning':
            c[f['code']] = c.get(f['code'], 0) + 1
    return c


def elem(n, id_):
    return next((e for e in n['elems'][1:] if dd(e.get('id'), '') == id_), None)


def first_dpv(n):
    # (grep { ($_->{kind} // '') eq 'DPV' } @{ $n->{elems} })[0]
    return next((e for e in n['elems'] if e and dd(e.get('kind'), '') == 'DPV'), None) or {}


def list_(h):
    return ','.join(sorted(h)) or 'none'


TMP = os.path.join(ROOT, '.test_acceptance_tmp')
os.makedirs(TMP, exist_ok=True)


def run(text, *args):
    m = os.path.join(TMP, 'm.phc')
    with open(m, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    p = subprocess.run([sys.executable, os.path.join(ROOT, 'phcp')] + list(args) + [m],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode('utf-8', 'surrogateescape')


def decode(out):
    try:
        j = json.loads(out)
    except ValueError:
        return {}
    return j if true(j) else {}


#==============================================================================
print('1. HYDRAULIC CONSTANTS AND SETTINGS')
#==============================================================================
if True:
    # Each of these was solved and ACCEPTED: with HW_CONST 0 the pipe had no
    # friction at all (2400 L/min, 80 sqrt 900), with a negative one the
    # water GAINED pressure along it, and 6.05e5 -- the constant for bar/m --
    # cut every loss a hundredfold.
    for c in (['0', 'zero'], ['-6.05E7', 'negative'], ['6.05E5', 'the bar/m constant'],
              ['4.52', 'the US-unit constant'], ['1E30', 'enormous'],
              ['1E999', 'overflowing to infinity']):
        m = refused(HEAD + 'OPTION HW_CONST %s\n' % c[0] + ONE)
        is_('HW_CONST %s (%s) is refused' % (c[0], c[1]),
            m is not None and re.search(r'HW_CONST', m, re.I) is not None, dd(m, 'accepted'))
    for c in ('6.05E7', '6.0489E7', '6.1E7'):
        is_('HW_CONST %s (a published form, in L/min, mm, kPa/m) is accepted' % c,
            refused(HEAD + 'OPTION HW_CONST %s\n' % c + ONE) is None)
    m = dd(refused(HEAD + 'OPTION HW_CONST 6.05E5\n' + ONE), '')
    is_('the refusal names the constant PHCP expects',
        re.search(r'6\.05E7|6\.05 ?x ?10\^?7', m, re.I) is not None, m)

    for o in (['TOL_FLOW', '0'], ['TOL_FLOW', '-1'], ['TOL_LOOP', '0'], ['TOL_LOOP', '-0.01'],
              ['TOL_LOOP', '1E999'], ['ORIF_STEP', '0'], ['ORIF_STEP', '-0.5']):
        m = refused(HEAD + 'OPTION %s %s\n' % (o[0], o[1]) + ONE)
        is_('%s %s is refused' % (o[0], o[1]),
            m is not None and re.search(o[0], m, re.I) is not None, dd(m, 'accepted'))
    # NU: the kinematic viscosity of water, 0.29E-6 (100 C) to 1.79E-6 (0 C)
    # m2/s.  NU 1 -- a million times water's -- made every pipe laminar, and
    # was ACCEPTED.
    dw = HEAD.replace('METHOD HW', 'METHOD DW', 1)
    for nu in ('1', '1E-9'):
        m = refused(dw + 'OPTION NU %s\n' % nu + ONE)
        is_('NU %s (not water) is refused' % nu,
            m is not None and re.search(r'\bNU\b', m) is not None, dd(m, 'accepted'))
    m10 = refused(dw + 'OPTION NU 1.31E-6\n' + ONE)
    is_('NU 1.31E-6 (water at 10 C) is accepted', m10 is None, m10)
    # A number that overflows is not a number, wherever it is given.
    mc = refused(HEAD + 'USE BORE 120\nWATER N1 0 900 1000 1E999\nSPRINKLER N2 0 -50 80\n'
                        'PIPE P1 N1 N2 5 100\n')
    is_('a curve point of 1E999 is refused before solving', mc is not None,
        'accepted, then solved to NaN')
    # C: no pipe has a Hazen-Williams C of 5 or of 1000.
    for c in (5, 1000):
        m = refused(HEAD + 'USE BORE %d\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\n'
                           'PIPE P1 N1 N2 100 100\n' % c)
        is_('a C factor of %d is refused' % c,
            m is not None and re.search(r'\bC\b', m) is not None, dd(m, 'accepted'))
    is_('a C factor of 150 is accepted',
        refused(HEAD + 'USE BORE 150\nWATER N1 0 900\nSPRINKLER N2 0 -50 80\n'
                       'PIPE P1 N1 N2 100 100\n') is None)

#==============================================================================
print('2. SOLVER TOLERANCES AGAINST VERIFICATION LIMITS')
#==============================================================================
if True:
    n0, ok0, a0 = assessed(HEAD + LOOP)
    is_('the looped network at the default tolerances is ACCEPTED',
        a0['validation']['acceptance'] == 'ACCEPTED', a0['validation']['acceptance'])
    # Was ACCEPTED with 21.4 kPa unclosed in a loop and the flow 1.7 % out.
    n1, ok1, a1 = assessed(HEAD + 'OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n' + LOOP)
    v1 = a1['validation']
    is_('TOL_LOOP 500 kPa: the early stop is not ACCEPTED', v1['acceptance'] != 'ACCEPTED',
        v1['acceptance'])
    is_('  ... it is REJECTED for loop closure',
        v1['acceptance'] == 'REJECTED' and true(errs(v1).get('LOOP_CLOSURE')), list_(errs(v1)))
    is_('  ... the loose setting is itself reported',
        true(warns(v1).get('SOLVER_TOLERANCE_LOOSE')), list_(warns(v1)))
    r = ((v1.get('residuals') or {}).get('loop')) or {}
    is_('  ... the loop is checked against the verification limit, not TOL_LOOP',
        r.get('tolerance') is not None and r['tolerance'] <= 1.01 * validate.VERIFY_P,
        'tolerance %s' % dd(r.get('tolerance'), 'undef'))
    is_('  ... and the solver tolerance is kept apart',
        abs(dd((v1.get('solver') or {}).get('tol_loop'), 0) - 500) < 1e-9,
        pstr((v1.get('solver') or {}).get('tol_loop')))
    ver = v1.get('verification')
    is_('the verification limits are given with the validation',
        isinstance(ver, dict) and ver.get('loop') is not None and ver.get('element') is not None
        and ver.get('continuity') is not None)
    # Moderately loose -- above the limit, but the solve happens to close
    # better than asked: then the check passes on the residual itself.
    n2, ok2, a2 = assessed(HEAD + 'OPTION TOL_LOOP 0.05\n' + LOOP)
    is_('TOL_LOOP 0.05 kPa, closing within the limit: ACCEPTED, with the setting noted',
        a2['validation']['acceptance'] == 'ACCEPTED', a2['validation']['acceptance'])
    rep = report.write_report(n1, ok1, 'm.phc')
    is_('the report prints the solver tolerance and the verification limit',
        re.search(r'^ Solver tolerance\s+flow .* loop 5e\+02', rep, re.M) is not None
        and re.search(r'^ Verification limit\s+loop closure .* 0\.1 ', rep, re.M) is not None)

#==============================================================================
print('3. CLOSED DEVICES')
#==============================================================================
if True:
    n, ok = solve(HEAD + LOOP)
    e = elem(n, 'P3')
    # Closed after the solve, its flow left: the network's continuity is
    # broken, and the closed element carrying water is named on its own.
    e['closed'] = 1
    v = validate.validate(n, ok)
    is_('a closed element still carrying flow is CLOSED_FLOW', true(errs(v).get('CLOSED_FLOW')),
        list_(errs(v)))
    is_('  ... and the calculation is REJECTED', v['acceptance'] == 'REJECTED', v['acceptance'])
    # The same network untouched: nothing closed, nothing reported.
    n2, ok2 = solve(HEAD + LOOP)
    v2 = validate.validate(n2, ok2)
    is_('the untouched network is not reported for closed flow',
        not true(errs(v2).get('CLOSED_FLOW')), list_(errs(v2)))

#==============================================================================
print('4. SEVERAL SUPPLIES')
#==============================================================================
if True:
    n, ok, a = assessed(HEAD + TWO)
    v = a['validation']
    j = a['supplies'].get('joint') or {}
    # As released: ACCEPTED, with WB taking 550 L/min IN at the joint demand
    # and the joint margin of 367 kPa counted.
    is_('as modelled both supplies deliver',
        not [s for s in a['supplies']['operating'] if s['status'] != 'DELIVERING'])
    is_('the joint demand is not taken where a supply would take water in',
        dd(j.get('status'), '') == 'UNRESOLVED', 'status ' + dd(j.get('status'), 'undef'))
    is_('  ... the reason names the supply and what happens to it',
        re.search(r'WB', dd(j.get('reason'), '')) is not None, dd(j.get('reason'), 'no reason'))
    is_('  ... and the calculation is not ACCEPTED on it', v['acceptance'] != 'ACCEPTED',
        v['acceptance'])
    is_('  ... SUPPLY_DEMAND_UNRESOLVED, not a supply found inadequate',
        true(errs(v).get('SUPPLY_DEMAND_UNRESOLVED')) and not true(errs(v).get('SUPPLY_ADEQUACY')),
        list_(errs(v)))
    da = v.get('demand_assessment') or {}
    is_('the demand assessment is UNRESOLVED', dd(da.get('status'), '') == 'UNRESOLVED',
        dd(da.get('status'), 'undef'))

    # With the near supply strong enough the joint demand is found, valid.
    t2 = TWO.replace('WATER WB 0 520', 'WATER WB 0 900', 1)
    n2, ok2, a2 = assessed(HEAD + t2)
    j2 = a2['supplies'].get('joint') or {}
    is_('a valid joint demand is FOUND and ACCEPTED',
        dd(j2.get('status'), '') == 'FOUND' and j2.get('acceptance') == 'ACCEPTED',
        dd(j2.get('status'), 'undef') + ' ' + dd(j2.get('acceptance'), ''))
    is_('  ... every supply delivers at it',
        not [s for s in j2['supplies'] if s['status'] == 'REVERSE'])
    # Signed: the supplies' flows add to the network's demand, from the one solve.
    dem = 0
    for x in j2['net']['elems'][1:]:
        if x['kind'] == 'DISCHARGE':
            dem += x['q']
    is_('  ... the signed sum of the supplies equals the net demand at the joint demand',
        abs(j2['q_total'] - dem) < 1e-3 and true(j2.get('balance_pass')),
        '%g against %g' % (j2['q_total'], dem))
    is_('  ... every supply row carries its active state and its extrapolation',
        not [s for s in j2['supplies']
             if s.get('active') is None or s.get('extrapolated') is None])
    da2 = a2['validation'].get('demand_assessment') or {}
    is_('the demand assessment is DEMONSTRATED', dd(da2.get('status'), '') == 'DEMONSTRATED',
        dd(da2.get('status'), 'undef'))
    is_('  ... and names its basis as an assumption',
        re.search(r'DERATE', dd(da2.get('basis'), '')) is not None
        and re.search(r'assum', dd(j2.get('assumption'), ''), re.I) is not None,
        dd(j2.get('assumption'), ''))

    # A trial classifier: every trial is PASS, SHORT, INVALID or NOT_CONVERGED.
    tn, tok = solve(HEAD + TWO)
    t = demand.trial(tok, tn)
    is_('a converged valid trial is PASS or SHORT',
        re.search(r'^(PASS|SHORT)\Z', dd(t.get('status'), '')) is not None, pstr(t.get('status')))
    t3 = demand.trial(0, tn)
    is_('a trial that did not converge is NOT_CONVERGED, not SHORT',
        dd(t3.get('status'), '') == 'NOT_CONVERGED', pstr(t3.get('status')))
    elem(tn, 'WB')['q'] = -50
    t4 = demand.trial(tok, tn)
    is_('a trial with a supply taking water in is INVALID',
        dd(t4.get('status'), '') == 'INVALID' and 'SUPPLY_REVERSE' in (t4.get('codes') or []),
        pstr(t4.get('status')))

    # One supply: trials that fail to converge are not "too weak".  Every
    # trial below 600 kPa is made to fail to converge; the true demand point
    # is far below that.  As released the bisection walked down into them,
    # took each as "supply too weak", and returned 600 kPa as the demand.
    #
    # The Perl replaces HardyCross::solve_model for the whole program (local
    # *HardyCross::solve_model).  The Python modules bind the name on import,
    # so it is replaced in every hardycross module that holds it, and put
    # back after, the same reach.
    real = hardycross.solve_model

    def fake(nn, *args, **kw):
        s = next((x for x in nn['elems'][1:]
                  if x['kind'] == 'SUPPLY_STATIC' and x['id'] == 'N1'), None)
        r = real(nn, *args, **kw)
        return 0 if s is not None and 100 < dd(s.get('pstat'), 0) < 600 else r
    patched = [mod for name, mod in list(sys.modules.items())
               if (name == 'hardycross' or name.startswith('hardycross.'))
               and getattr(mod, 'solve_model', None) is real]
    for mod in patched:
        mod.solve_model = fake
    try:
        on, ook = solve(HEAD + ONE)
        dm = demand.demand_point(on)
        is_('one supply: non-converging trials give UNRESOLVED, not a demand',
            dd(dm.get('status'), '') == 'UNRESOLVED',
            dd(dm.get('status'), 'undef') + ' '
            + pstr(dd(dm.get('p_demand'), dd(dm.get('reason'), ''))))
        vv = validate.validate(on, ook, demand=dm)
        is_('  ... and the design is not ACCEPTED',
            vv['acceptance'] != 'ACCEPTED' and true(errs(vv).get('SUPPLY_DEMAND_UNRESOLVED')),
            list_(errs(vv)))
    finally:
        for mod in patched:
            mod.solve_model = real
    on, ook, oa = assessed(HEAD + ONE)
    odm = oa.get('demand') or {}
    is_('one supply, nothing interfering: the demand point is FOUND',
        dd(odm.get('status'), '') == 'FOUND', dd(odm.get('status'), 'undef'))
    is_('  ... its supply flow is signed, from the solve',
        odm.get('q_system') is not None and odm['q_system'] > 0)

    # The conditional minimum of each supply: a status that says why.
    cs = {c['id']: c for c in (a2['supplies'].get('conditional') or [])}
    is_('a conditional result has a status from REQUIRED, NOT_REQUIRED, INADEQUATE, UNRESOLVED',
        not [c for c in cs.values()
             if not re.search(r'^(REQUIRED|NOT_REQUIRED|INADEQUATE|UNRESOLVED)\Z',
                              dd(c.get('status'), ''))],
        ','.join(pstr(c.get('status')) for c in cs.values()))
    is_('  ... and is marked conditional, not simultaneous',
        not [c for c in cs.values() if dd(c.get('basis'), '') != 'CONDITIONAL'])

#==============================================================================
print('5. ORIFICE PLATES')
#==============================================================================
OR = ('WATER SRC 0 1000\nNODE J1 0\nNODE A 0\nHYDRANT A2 0 400 28.28427125\n'
      'USE BORE 120\nPIPE M1 SRC J1 20 100\nPIPE P1 J1 A 12 50\nUSE ASAM\nPIPE OP1 A A2 0 50\n'
      'OPP OP1 150\n')
if True:
    n, ok, a = assessed(HEAD + 'OPTION ORIF_STEP 0.5\n' + OR)
    e = elem(n, 'OP1.OPP')
    is_('the plate on a 0.5 mm step meets its duty within the tolerance',
        not true(errs(a['validation']).get('ORIFICE_DUTY')), list_(errs(a['validation'])))
    is_('  ... the final drop, target, deviation and its two causes are kept',
        all(e.get(k) is not None for k in
            ('dp_final', 'dp_target', 'dev_pct', 'dev_rounding_pct', 'dev_flow_pct')))
    is_('  ... the two causes add up to the deviation',
        abs(dd(e.get('dev_rounding_pct'), 0) + dd(e.get('dev_flow_pct'), 0)
            - dd(e.get('dev_pct'), 1e9)) < 0.05,
        '%s + %s against %s' % tuple(pstr(dd(e.get(k), 'undef'))
                                     for k in ('dev_rounding_pct', 'dev_flow_pct', 'dev_pct')))
    # A coarse step: the nearest plate that can be made is far from the duty.
    n2, ok2, a2 = assessed(HEAD + 'OPTION ORIF_STEP 6\n' + OR)
    e2 = elem(n2, 'OP1.OPP')
    is_('a 6 mm step: the plate misses its duty by more than the tolerance and fails',
        true(errs(a2['validation']).get('ORIFICE_DUTY')),
        '%s, deviation %s %%' % (list_(errs(a2['validation'])), pstr(dd(e2.get('dev_pct'), 'undef'))))
    is_('  ... as a design failure: NONCOMPLIANT', a2['validation']['acceptance'] == 'NONCOMPLIANT',
        a2['validation']['acceptance'])
    n3, ok3, a3 = assessed(HEAD + 'OPTION ORIF_STEP 6\nOPTION ORIF_DP_TOL 60\n' + OR)
    is_('the tolerance is a setting (ORIF_DP_TOL), printed in the report',
        not true(errs(a3['validation']).get('ORIFICE_DUTY'))
        and re.search(r'ORIF_DP_TOL|DUTY TOLERANCE', report.write_report(n3, ok3, 'm.phc'),
                      re.I) is not None)
    is_('ORIF_DP_TOL must be positive', refused(HEAD + 'OPTION ORIF_DP_TOL 0\n' + OR) is not None)

#==============================================================================
print('6. CURVES')
#==============================================================================
if True:
    # A supply curve run at three times its last point.
    m = 'USE BORE 120\nWATER N1 0 900 300 850\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 10 100\n'
    n, ok, a = assessed(HEAD + m)
    v = a['validation']
    q = elem(n, 'N1')['q']
    is_('a supply run far beyond its curve is CURVE_EXTRAPOLATION_LIMIT',
        true(errs(v).get('CURVE_EXTRAPOLATION_LIMIT')),
        '%s at %.0f L/min against a last point of 300' % (list_(errs(v)), q))
    is_('  ... and the calculation is not ACCEPTED', v['acceptance'] != 'ACCEPTED', v['acceptance'])
    m2 = 'USE BORE 120\nWATER N1 0 900 2000 850\nSPRINKLER N2 0 -50 80\nPIPE P1 N1 N2 10 100\n'
    n2, ok2, a2 = assessed(HEAD + m2)
    is_('a little beyond the points: a warning that it is EXTRAPOLATED, no failure',
        true(warns(a2['validation']).get('CURVE_EXTRAPOLATED'))
        and not true(errs(a2['validation']).get('CURVE_EXTRAPOLATION_LIMIT')),
        list_(warns(a2['validation'])))
    j = jsonout.results(n2, ok2, 'm')
    sj = next((x for x in j['elements'] if x['id'] == 'N1'), None)
    is_('  ... and the JSON marks the operating point extrapolated',
        sj is not None and true(sj.get('extrapolated')))

#==============================================================================
print('7. DRY PIPE VALVES')
#==============================================================================
if True:
    D = ('USE BORE 120\nWATER W 0 700\nNODE A 0\nNODE B 0\nSPRINKLER S 0 -50 80\n'
         'PIPE P1 W A 5 100\nPIPE P12 A B 5 100\nPIPE P2 B S 5 50\n')
    n, ok, a = assessed(HEAD + D + 'DPV P12 100 RATIO 5.5:1 OFF 0 20\n')
    v = a['validation']
    e = first_dpv(n)
    is_('a DPV with one flow/loss pair (a constant loss) is labelled a simplified loss',
        true(warns(v).get('DPV_SIMPLIFIED_LOSS')) and dd(e.get('loss_source'), '') == 'USER_FIXED',
        list_(warns(v)) + ' ' + dd(e.get('loss_source'), 'undef'))
    # The same valve with no flow: a constant loss with nothing flowing is a
    # pressure difference no valve can hold open.
    n2, ok2, a2 = assessed(HEAD + 'USE BORE 120\nWATER W 0 700\nNODE A 0\nSPRINKLER S 0 -50 80\n'
                           'NODE X 0\nPIPE P1 W A 5 100\nPIPE P12 A X 5 100\nPIPE P2 A S 5 50\n'
                           'DPV P12 100 RATIO 5.5:1 OFF 0 20\n')
    is_('  ... with no flow through it, the constant loss is refused',
        true(errs(a2['validation']).get('DPV_FIXED_NO_FLOW')), list_(errs(a2['validation'])))
    n3, ok3, a3 = assessed(HEAD + D + 'DPV P12 100 RATIO 5.5:1 OFF 1000 20 2000 50\n')
    is_('a loss curve that is negative at no flow is refused',
        true(errs(a3['validation']).get('DPV_LOSS_AT_ZERO')), list_(errs(a3['validation'])))
    n4, ok4, a4 = assessed(HEAD + D + 'DPV P12 100 RATIO 5.5:1 OFF 0 0 1000 20 2000 70\n')
    is_('a loss curve through zero is labelled a user curve, and passes',
        not true(errs(a4['validation']).get('DPV_LOSS_AT_ZERO'))
        and dd(first_dpv(n4).get('loss_source'), '') == 'USER_CURVE')
    # Victaulic 756 has no usable loss in the database: as released the model
    # was refused at reading.  It is now a valve with DATA_REQUIRED.
    vt = HEAD + D + 'DPV P12 100 RATIO 5.5:1 OFF VALVE VICTAULIC 756\n'
    msg = refused(vt)
    if msg is not None:
        is_('a database valve with no usable loss reads, as DATA_REQUIRED', 0, msg)
    else:
        n5, ok5, a5 = assessed(vt)
        is_('a database valve with no usable loss reads, as DATA_REQUIRED',
            true(errs(a5['validation']).get('DPV_NO_LOSS_DATA'))
            and dd(first_dpv(n5).get('data_status'), '') == 'DATA_REQUIRED',
            list_(errs(a5['validation'])))
        is_('  ... REJECTED: no loss is assumed', a5['validation']['acceptance'] == 'REJECTED',
            a5['validation']['acceptance'])
        j5 = jsonout.results(n5, ok5, 'm')
        is_('  ... and the JSON says DATA_REQUIRED',
            dd(((j5.get('dry_pipe_valves') or [{}])[0]).get('data_status'), '') == 'DATA_REQUIRED')
    # The estimates decide nothing: with and without DPVTRIP the acceptance is the same.
    base = HEAD + D + 'DPV P12 100 RATIO 5.5:1 OFF VALVE TYCO DPV-1\nDPVAIR P12 280\n'
    _, _, b1 = assessed(base)
    n6, ok6, b2 = assessed(base + 'DPVTRIP P12 12.7 1 5\n')
    is_('the trip and transit estimates change no acceptance',
        b1['validation']['acceptance'] == b2['validation']['acceptance'],
        '%s / %s' % (b1['validation']['acceptance'], b2['validation']['acceptance']))
    j6 = jsonout.results(n6, ok6, 'm')
    dpv0 = (j6.get('dry_pipe_valves') or [{}])[0]
    est = dd(dpv0.get('estimate'), {})
    is_('  ... the JSON marks them as estimates, not verified, not a delivery time calculation',
        est.get('verified') is not None and not true(est['verified'])
        and re.search(r'ESTIMATE', dd(est.get('basis'), '')) is not None
        and not true(dpv0.get('delivery_time_calculated')))

#==============================================================================
print('8. INTEGRATION')
#==============================================================================
if True:
    nc = HEAD + 'USE BORE 120\nWATER N1 0 300\nSPRINKLER N2 0 -250 80\nPIPE P1 N1 N2 100 100\n'
    x, out = run(nc, '--json')
    j = decode(out)
    is_('a NONCOMPLIANT design: exit 0 by default, as before', x == 0, 'exit %d' % x)
    is_('  ... "approved" is false', 'approved' in j and not true(j['approved']),
        pstr(dd(j.get('approved'), 'missing')))
    xs, _ = run(nc, '--json', '--strict')
    is_('  ... with --strict, exit 4', xs == 4, 'exit %d' % xs)
    xa, _ = run(HEAD + ONE, '--json', '--strict')
    is_('an ACCEPTED design: exit 0 with --strict', xa == 0, 'exit %d' % xa)
    xr, _ = run(HEAD + 'OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n' + LOOP, '--strict')
    is_('a REJECTED calculation: exit 3 with --strict', xr == 3, 'exit %d' % xr)
    xu, ou = run(HEAD + TWO, '--json')
    ju = decode(ou)
    is_('the two-supply case: the JSON gives the demand assessment',
        dd((ju.get('demand_assessment') or {}).get('status'), '') == 'UNRESOLVED')
    is_('  ... and the assumptions it rests on',
        isinstance(ju.get('assumptions'), dict)
        and dd(ju['assumptions'].get('joint_basis'), '') == 'DERATE')
    is_('  ... and the verification limits',
        isinstance((ju.get('validation') or {}).get('verification'), dict))

    # Results block: current, stale, tampered.
    n, ok = solve(HEAD + ONE)
    text = results.with_results(HEAD + ONE, n, ok)
    is_('a fresh results block is CURRENT', results.status(text) == 'CURRENT', results.status(text))
    edited = text.replace('PIPE P1 N1 N2 100 100', 'PIPE P1 N1 N2 120 100', 1)
    is_('the model edited: STALE', results.status(edited) == 'STALE', results.status(edited))
    forged2 = re.sub(r'(//= PIPE\s+P1 .*? FLOW )(\d+)',
                     lambda mo: mo.group(1) + str(int(mo.group(2)) + 100), text, count=1)
    is_('  ... (the test did edit a result)', forged2 != text)
    is_('a result edited by hand: TAMPERED', results.status(forged2) == 'TAMPERED',
        results.status(forged2))
    is_('no block: NONE', results.status(HEAD + ONE) == 'NONE')
    is_('the block records the program and the database it came from',
        re.search(r'^//= PROGRAM\s+PHCP VERSION \S+', text, re.M) is not None
        and re.search(r'^//= DATABASE\s+.*SHA256', text, re.M) is not None)
    rn, rok = solve(HEAD + 'OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n' + LOOP)
    rt = results.with_results(HEAD + 'OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n' + LOOP, rn, rok)
    is_("a REJECTED calculation's block says so in its first line, not for design use",
        re.search(r'^//== PHCP RESULTS.*REJECTED.*NOT FOR DESIGN USE', rt, re.M) is not None)
    at = rt.find(results.BEGIN)
    tail = rt[at:] if at >= 0 else rt[-1:]
    is_('every line of the block is a comment the model reader ignores',
        not [l for l in tail.split('\n') if re.search(r'\S', l) and not l.startswith('//')])

    # The command line, the JSON, the editor's check and the report agree.
    for c in (['loose tolerance', HEAD + 'OPTION TOL_LOOP 500\nOPTION TOL_FLOW 500\n' + LOOP],
              ['joint unresolved', HEAD + TWO],
              ['coarse orifice step', HEAD + 'OPTION ORIF_STEP 6\nWATER SRC 0 1000\nNODE J1 0\nNODE A 0\n'
                                     'HYDRANT A2 0 400 28.28427125\nUSE BORE 120\nPIPE M1 SRC J1 20 100\n'
                                     'PIPE P1 J1 A 12 50\nUSE ASAM\nPIPE OP1 A A2 0 50\nOPP OP1 150\n']):
        nn, ok = solve(c[1])
        acc = validate.assess(nn, ok)['validation']['acceptance']
        x, o = run(c[1], '--json')
        jj = decode(o)
        rep = report.write_report(nn, ok, 'm.phc')
        is_('%s: the CLI JSON, the report and the assessment agree (%s)' % (c[0], acc),
            dd(jj.get('acceptance'), '') == acc
            and re.search(r'CALCULATION ACCEPTANCE[^\n]*\n(?:[^\n]*\n){0,6}[^\n]*\b' + acc + r'\b',
                          rep) is not None,
            'json %s' % pstr(jj.get('acceptance')))
        block = results.with_results(c[1], nn, ok)
        is_('%s: the results block agrees' % c[0],
            re.search(r'^//= RESULT\s+ACCEPTANCE ' + acc + r'\b', block, re.M) is not None)

for f in glob.glob(os.path.join(TMP, '*')):
    os.unlink(f)
os.rmdir(TMP)
print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
