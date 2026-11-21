#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_validate.py -- hardycross.validate and the false positives it catches.
# A port of tools/test_validate.pl.
#
#   python3 tools/test_validate.py
#
# Every case says whether the model must be ACCEPTED, NONCOMPLIANT (valid but
# failing its design), REJECTED (converged but not a valid answer) or
# INDETERMINATE (no settled, converged solution), and why.  Five parts:
#
#   1. THE EXAMPLES.  Each is numerically and physically valid, and its
#      residuals are within tolerance.
#   2. THE DEFECTS FOUND (10 November 2026).  Each was reported converged and
#      used before; each is now refused, for the reason stated.  The model is
#      the smallest that shows it.
#   3. OUTER-LOOP CONVERGENCE.  An unconverged solve adjusts no device; a
#      solve whose device states have not settled is not converged.
#   4. INDEPENDENCE.  A network tampered with after the solve -- a flow, a
#      head, a NaN -- is caught: the checks are worked from the network, not
#      taken from the solver.
#   5. DESIGN, EXIT STATUS AND CONSISTENCY.  The design checks, the exit status
#      phcp gives for each acceptance, and the report, the JSON and the
#      editor agreeing on it.
#
# These tests check PHCP against the conditions it sets itself.  They are not
# evidence of conformance with any Standard or of external certification.
#==============================================================================

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import parse, phc, validate, jsonout, report

EX = os.path.join(ROOT, 'examples')
PASS = [0]
FAIL = [0]


def is_(name, ok, why=None):
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


HEAD = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                  'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', ''])


# solve -- (net, ok, validation) for model text (the header added).
def solve(body, bare=False):
    net = phc.read_string(('' if bare else HEAD) + body)
    ok = hardycross.solve_model(net)
    return net, ok, validate.validate(net, ok)


def codes(v):
    c = {}
    for f in v['findings']:
        if f['severity'] == 'error':
            c[f['code']] = c.get(f['code'], 0) + 1
    return c


def elem(n, id_):
    for e in n['elems'][1:]:
        if e['id'] == id_:
            return e
    return None


# pn -- a number as Perl prints it (%.15g), for the messages.
def pn(x):
    if isinstance(x, (int, float)) and not isinstance(x, bool):
        return '%.15g' % x
    return '' if x is None else str(x)


def slurp(p):
    with open(p) as f:
        return f.read()


# run -- phcp on model text: (exit, stdout and stderr).
TMP = os.path.join(ROOT, '.test_validate_tmp')
os.makedirs(TMP, exist_ok=True)


def run(text, *args):
    m = os.path.join(TMP, 'm.phc')
    with open(m, 'w') as f:
        f.write(text)
    p = subprocess.run([sys.executable, os.path.join(ROOT, 'phcp')] + list(args) + [m],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def main():
    #==========================================================================
    print('1. THE EXAMPLES')
    #==========================================================================
    # 04 (the 1000-pipe grid) is left out for time; the stress test covers
    # grids.  12 has pipes of size 0, which only make sense once sized: it is
    # solved with its sizing, as phcp does.
    for path in sorted(glob.glob(os.path.join(EX, '*.phc'))):
        if 'grid1000' in path:
            continue
        name = re.search(r'([^/\\]+)\.phc\Z', path).group(1)
        net = parse.read_model(path)
        ok = hardycross.solve_model(net)
        if net.get('auto_sizing'):
            from hardycross import sizing
            net, ok = sizing.size(net, ok)
        if net.get('areas'):
            from hardycross import areas
            net, ok = areas.governing(net, ok)
        v = validate.validate(net, ok)
        is_('%s: numerically and physically valid (%s)' % (name, v['acceptance']),
            v['numerical']['status'] == 'PASS' and v['physical']['status'] == 'PASS',
            ' '.join('%s(%s)' % (f['code'], f['item'])
                     for f in v['findings'] if f['severity'] == 'error'))
        r = v['residuals']
        is_('   residuals within tolerance (loop %s, continuity %s)'
            % (pn(r['loop']['value']), pn(r['continuity']['value'])),
            len([k for k in ('continuity', 'balance', 'loop', 'element') if r[k]['pass']]) == 4)

    #==========================================================================
    print('2. THE DEFECTS FOUND')
    #==========================================================================

    # D1.  A fixed flow at a node with no route to any supply.  The solve
    # "fed" it by running 100 L/min backwards INTO sprinkler S2, and the JSON
    # printed S2's flow as +100.
    d1 = """WATER W 0 500
NODE A 0
SPRINKLER S1 0 -50 80
NODE B 0
SPRINKLER S2 0 -50 80
FIXEDFLOW F B 100
PIPE P1 W A 10 50
PIPE P2 A S1 5 25
PIPE P3 B S2 5 25
"""
    n, ok, v = solve(d1)
    c = codes(v)
    is_('D1 demand fed through a sprinkler: REJECTED', v['acceptance'] == 'REJECTED', v['acceptance'])
    is_('   the backward discharge is found (OUTLET_REVERSE at S2)',
        c.get('OUTLET_REVERSE') and any(f['code'] == 'OUTLET_REVERSE' and f['item'] == 'S2'
                                        for f in v['findings']))
    is_('   and the demands with no supply (DEMAND_UNCONNECTED, F and S2)',
        c.get('DEMAND_UNCONNECTED', 0) == 2)
    j = jsonout.results(n, ok, 'd1', demand=0)
    s2 = [o for o in j['outlets'] if o['id'] == 'S2'][0]
    is_('   the JSON gives S2 its signed flow, -100, and FAIL', s2['flow'] < -99 and not s2['pass'],
        'flow %s' % s2['flow'])
    code, _ = run(HEAD + d1, '--json')
    is_('   phcp exits 3 (REJECTED)', code == 3, 'exit %d' % code)
    as_ = validate.assess(n, ok)
    # Every trial of the demand search is as invalid as the model (the
    # demands have no supply), so the demand is UNRESOLVED -- not a supply
    # found too weak -- and the design still fails.
    is_('   no valid supply pressure meets it: the design fails too (SUPPLY_DEMAND_UNRESOLVED)',
        codes(as_['validation']).get('SUPPLY_DEMAND_UNRESOLVED')
        and as_['validation']['design']['status'] == 'FAIL',
        ','.join(codes(as_['validation']).keys()))

    # D2.  A pump whose check valve, closing, would isolate the fixed flow it
    # feeds.  The revert zeroed the pump's flow, rebuilt the tree only, and
    # reported no change: continuity was out by 200 L/min at both ends of the
    # pump, and the solve was reported converged.
    d2 = """WATER WB 0 900
NODE B 0
NODE A 0
FIXEDFLOW F A 200
SPRINKLER S1 0 -50 80
PIPE P1 WB B 10 100
PUMP PU A B 100 500 80 1000 50
PIPE P2 B S1 10 50
"""
    n, ok, v = solve(d2)
    is_('D2 pump isolation: continuity now holds (residual within tolerance)',
        v['residuals']['continuity']['pass'],
        'continuity %s' % pn(v['residuals']['continuity']['value']))
    is_('   the pump is left open with its true flow, -200', abs(elem(n, 'PU')['q'] + 200) < 1e-6,
        pn(elem(n, 'PU')['q']))
    is_('   REJECTED: PUMP_ISOLATING', v['acceptance'] == 'REJECTED' and codes(v).get('PUMP_ISOLATING'),
        v['acceptance'])

    # A pump whose outlet is held by a second, stronger supply above what it
    # can lift to: its check valve closes and the network solves without it.
    # A valid closure is not a failure.
    n, ok, v = solve("""WATER W1 0 100
WATER W2 0 900
NODE A 0
NODE B 0
SPRINKLER S1 0 -50 80
PIPE P1 W1 A 10 100
PUMP PU A B 300 500 280 1000 200
PIPE P2 W2 B 10 100
PIPE P3 B S1 10 50
""")
    is_('a pump shut on its check valve by a stronger supply: shut, not rejected',
        elem(n, 'PU').get('closed') and v['acceptance'] in ('ACCEPTED', 'NONCOMPLIANT'), v['acceptance'])

    # D5.  A supply curve whose pressure RISES with flow: accepted and solved.
    n, ok, v = solve("""WATER W 0 300 500 400 1000 600
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
PIPE P2 A S1 5 25
""")
    is_('D5 a rising supply curve: REJECTED, SUPPLY_CURVE_RISING',
        v['acceptance'] == 'REJECTED' and codes(v).get('SUPPLY_CURVE_RISING'), v['acceptance'])

    # D6.  Two supplies, one far weaker: water runs INTO it.  Unremarked.
    n, ok, v = solve("""WATER WA 0 800
WATER WB 0 200
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 WA A 10 50
PIPE P2 WB A 10 50
PIPE P3 A S1 5 25
""")
    is_('D6 a supply taking water in: REJECTED, SUPPLY_REVERSE at WB',
        v['acceptance'] == 'REJECTED' and any(f['code'] == 'SUPPLY_REVERSE' and f['item'] == 'WB'
                                              for f in v['findings']))

    # D7.  An orifice plate asked for a drop smaller than a plate of nearly
    # the full bore gives.  The bisection returned the end of its bracket,
    # which then ROUNDED UP to the full pipe bore (50.0 mm in a 50.0 mm pipe),
    # and the plate was accepted.
    n, ok, v = solve("""WATER W 0 500
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
OPP P1 0.001
PIPE P2 A S1 5 25
""")
    op = elem(n, 'P1.OPP')
    is_('D7 an unachievable orifice duty: REJECTED, ORIFICE_UNACHIEVABLE',
        v['acceptance'] == 'REJECTED' and codes(v).get('ORIFICE_UNACHIEVABLE'), v['acceptance'])
    is_('   the rounded bore stays below the pipe bore', op['bore'] < op['pipedia'],
        '%s in %s' % (pn(op['bore']), pn(op['pipedia'])))

    # A plate that meets its duty: its final drop is stated against its
    # target.
    net = parse.read_model(os.path.join(EX, '06_orifice.phc'))
    ok = hardycross.solve_model(net)
    v = validate.validate(net, ok)
    dev = [f for f in v['findings'] if f['code'] == 'ORIFICE_DEVIATION']
    e = elem(net, dev[0]['item']) if dev else None
    is_('06 orifice: the final drop is stated against the target, and is the plate\'s own',
        bool(dev) and abs(e['dp_final'] - hardycross.orifice_dp(abs(e['q']), e['bore'], e['pipedia'],
                                                                 e.get('cd'))) < 1e-9
        and not e.get('size_clamp'))

    # A pressure ratio valve whose inlet is below its minimum.
    n, ok, v = solve("""WATER W 0 400
NODE A 0
SPRINKLER S1 0 -20 80
PIPE P1 W A 10 100
PRA P1 3:1 600
PIPE P2 A S1 5 50
""")
    is_('a ratio valve below its minimum inlet: REJECTED, PRA_MIN_INLET',
        v['acceptance'] == 'REJECTED' and codes(v).get('PRA_MIN_INLET'), v['acceptance'])

    # A ratio valve between two supplies, flow wanting to run back through
    # it.  Its drop changes sign with the flow, so there is no steady answer.
    # Before, the outer loop kept adjusting the valve on unconverged solves:
    # 60 passes of 50000 iterations, and then the demand point on top --
    # minutes, for nothing.
    t0 = time.time()
    n, ok, v = solve("""WATER WA 0 1500
WATER WB 0 1400
NODE A 0
NODE B 0
SPRINKLER S1 0 -50 80
PIPE P1 WA A 10 100
PIPE P2 A B 10 100
PRA P2 3:1
PIPE P3 WB B 10 100
PIPE P4 A S1 5 25
""")
    is_('a ratio valve with no steady state: INDETERMINATE, NOT_CONVERGED',
        v['acceptance'] == 'INDETERMINATE' and codes(v).get('NOT_CONVERGED'), v['acceptance'])
    el = int(time.time() - t0)
    is_('   the outer loop stopped on the unconverged solve',
        (n.get('outer_stop') or '') == 'inner_not_converged' and el < 60,
        '%s, %d s' % (n.get('outer_stop'), el))
    is_('   the iteration is diagnosed (%s)' % (n.get('nonconv') if n.get('nonconv') is not None else 'none'),
        n.get('nonconv') is not None)

    # A node below the vapour pressure of water: a weak supply under a high
    # head.
    n, ok, v = solve("""WATER W 0 50
NODE A 15
FIXEDFLOW F A 100
PIPE P1 W A 20 50
""")
    is_('a pressure below the vapour pressure: REJECTED, BELOW_VAPOUR',
        v['acceptance'] == 'REJECTED' and codes(v).get('BELOW_VAPOUR'), v['acceptance'])

    #==========================================================================
    print('3. OUTER-LOOP CONVERGENCE')
    #==========================================================================
    # The orifice example needs a second outer pass: the plate is sized on
    # the first solve and the network solved again with it.  Allowed only one
    # pass, the solve used to return converged regardless.
    saved = hardycross.MAX_OUTER
    hardycross.MAX_OUTER = 1
    try:
        net = parse.read_model(os.path.join(EX, '06_orifice.phc'))
        ok = hardycross.solve_model(net)
        v = validate.validate(net, ok)
    finally:
        hardycross.MAX_OUTER = saved
    is_('device states not settled: the solve is not converged', not ok and not net.get('outer_settled'),
        'ok %s settled %s' % (ok, net.get('outer_settled')))
    is_('   INDETERMINATE, DEVICES_UNSETTLED',
        v['acceptance'] == 'INDETERMINATE' and codes(v).get('DEVICES_UNSETTLED'))
    net = parse.read_model(os.path.join(EX, '06_orifice.phc'))
    ok = hardycross.solve_model(net)
    is_('   with the normal limit it settles and converges',
        ok and net.get('outer_settled') and net['outer_passes'] >= 2,
        'passes %s' % net.get('outer_passes'))
    # An unconverged inner solve sizes no plate.
    text = slurp(os.path.join(EX, '06_orifice.phc')) + '\nOPTION MAXITER 1\n'
    net = phc.read_string(text)
    ok = hardycross.solve_model(net)
    v = validate.validate(net, ok)
    unsized = [e for e in net['elems'][1:] if e['kind'] == 'ORIFICE_REQUIRED']
    is_('an unconverged solve: no plate sized on it, INDETERMINATE',
        not ok and unsized and v['acceptance'] == 'INDETERMINATE',
        'ok %s unsized %d' % (ok, len(unsized)))

    #==========================================================================
    print('4. INDEPENDENCE')
    #==========================================================================
    n, ok, v = solve("""WATER W 0 700
NODE A 0
NODE B 0
SPRINKLER S1 3 -100 80
SPRINKLER S2 3 -100 80
PIPE P1 W A 10 100
PIPE P2 A B 8 80
PIPE P3 A S1 5 50
PIPE P4 B S2 5 50
PIPE P5 S1 S2 6 50
""")
    is_('a looped network: ACCEPTED or NONCOMPLIANT', v['acceptance'] in ('ACCEPTED', 'NONCOMPLIANT'),
        v['acceptance'])
    elem(n, 'P2')['q'] += 5
    t = validate.validate(n, ok)
    is_('   a flow changed by 5 L/min after the solve: REJECTED, CONTINUITY',
        t['acceptance'] == 'REJECTED' and codes(t).get('CONTINUITY'), t['acceptance'])
    elem(n, 'P2')['q'] -= 5
    bi = [i for i in range(1, len(n['nodes'])) if n['nodes'][i]['id'] == 'B'][0]
    n['nodes'][bi]['h'] += 2
    t = validate.validate(n, ok)
    is_('   a head changed by 2 kPa: REJECTED, ELEMENT_EQUATION',
        t['acceptance'] == 'REJECTED' and codes(t).get('ELEMENT_EQUATION'), t['acceptance'])
    n['nodes'][bi]['h'] -= 2
    elem(n, 'P5')['q'] = float('nan')
    t = validate.validate(n, ok)
    is_('   a NaN flow: INDETERMINATE, NONFINITE', t['acceptance'] == 'INDETERMINATE' and codes(t).get('NONFINITE'),
        t['acceptance'])

    elem(n, 'P5')['q'] = 0.0
    # A head that is not finite.  The Perl crashes on it (a slip in its
    # list of the items); the port makes the finding the Perl meant to.
    n['nodes'][bi]['h'] = float('-inf')
    t = validate.validate(n, ok)
    is_('   a head that is not finite: INDETERMINATE, NONFINITE, the node named',
        t['acceptance'] == 'INDETERMINATE' and codes(t).get('NONFINITE')
        and 'B' in [f for f in t['findings'] if f['code'] == 'NONFINITE'][0]['item'].split(), t['acceptance'])
    n['nodes'][bi]['h'] = 0.0
    # A number that is not finite in a message is Inf, -Inf or NaN, as
    # Perl's sprintf prints it; Python's own % writes inf, -inf and nan.
    n6, ok6, v6 = solve("""WATER W 0 700
NODE A 0
SPRINKLER S1 1e308 -100 80
SPRINKLER S2 0 -100 80
PIPE P1 W A 10 100
PIPE P2 A S1 5 50
PIPE P3 A S2 5 50
""")
    m6 = [f['message'] for f in v6['findings'] if f['code'] == 'OUTLET_REQUIREMENT' and f['item'] == 'S1']
    is_('   a pressure of minus infinity in a message is -Inf, as Perl prints it',
        m6 and re.search(r'pressure -Inf KPA against 100\.00 required', m6[0]), m6)
    P = validate._P
    inf = float('inf')
    is_('   Inf, -Inf and NaN in every form of %f, %g and %s the messages use',
        P('[%.1f][%8.2f][%-8.2f][%+.1f][%g][%.3g][%s][%+.1f][%.6g][%d%%]')
        % (inf, -inf, inf, inf, -inf, inf - inf, inf, inf - inf, 1.5, 7)
        == '[Inf][    -Inf][Inf     ][+Inf][-Inf][NaN][Inf][NaN][1.5][7%]')

    #==========================================================================
    print('5. DESIGN, EXIT STATUS AND CONSISTENCY')
    #==========================================================================
    # One sprinkler well over its minimum, fed by a 50 mm pipe at some 7 m/s.
    fast = """WATER W 0 1200
NODE A 0
SPRINKLER S1 0 -50 80
PIPE P1 W A 10 50
PIPE P2 A S1 5 50
"""
    _, _, v = solve(fast)
    vl = [f for f in v['findings'] if f['code'] == 'VELOCITY_LIMIT']
    vl = vl[0] if vl else None
    is_('over the default velocity limit: a warning only', vl is not None and vl['severity'] == 'warning'
        and v['acceptance'] == 'ACCEPTED', v['acceptance'])
    _, _, v = solve(fast + 'OPTION VEL_LIMIT 6\n')
    is_('over a velocity limit the model sets: NONCOMPLIANT, VELOCITY_LIMIT',
        v['acceptance'] == 'NONCOMPLIANT' and codes(v).get('VELOCITY_LIMIT'), v['acceptance'])
    # The supply has well under 1200 kPa in hand; ask for 5000.
    net = phc.read_string(HEAD + fast + 'OPTION SUPPLY_MARGIN 5000\n')
    ok = hardycross.solve_model(net)
    as_ = validate.assess(net, ok)
    is_('a supply short of OPTION SUPPLY_MARGIN: NONCOMPLIANT, SUPPLY_ADEQUACY',
        as_['validation']['acceptance'] == 'NONCOMPLIANT' and codes(as_['validation']).get('SUPPLY_ADEQUACY'),
        as_['validation']['acceptance'])
    code, _ = run(HEAD + fast + 'OPTION SUPPLY_MARGIN 5000\n', '--json')
    is_('   phcp exits 0: a valid solution, failing its design', code == 0, 'exit %d' % code)

    text = slurp(os.path.join(EX, '01_single_branch.phc'))
    code, out = run(text, '--json')
    try:
        j, err = json.loads(out), ''
    except ValueError as ex:
        j, err = None, str(ex)
    is_('01: interface 2, ACCEPTED, exit 0',
        j and j['interface'] == 2 and j['acceptance'] == 'ACCEPTED' and code == 0,
        'exit %d %s' % (code, j['acceptance'] if j else err))
    is_('   the JSON carries the residuals and the traceability',
        j and j['validation']['residuals'].get('loop')
        and re.search(r'^[0-9a-f]{64}\Z', j['traceability']['model_sha256'] or ''))
    code, _ = run(text + '\nOPTION MAXITER 0\n', '--json')
    is_('   with no iterations allowed: exit 1 (INDETERMINATE)', code == 1, 'exit %d' % code)

    # The report, the JSON and the editor give the same acceptance, for an
    # accepted, a rejected and a noncompliant model.
    from hardycross import editor
    for what, text in [('accepted', HEAD + fast), ('rejected', HEAD + d1),
                       ('noncompliant', HEAD + fast + 'OPTION VEL_LIMIT 6\n')]:
        net = phc.read_string(text)
        ok = hardycross.solve_model(net)
        rep = report.write_report(net, ok, 'm.phc')
        j = jsonout.results(net, ok, 'm.phc')
        m = re.search(r'14\. CALCULATION ACCEPTANCE\s*\n=+\n RESULT\s+(\S+)', rep)
        racc = m.group(1) if m else None
        ed = editor.solve_text(text, None)
        eacc = validate.assess(ed['net'], ed['converged'])['validation']['acceptance']
        is_('%s: report, JSON and editor agree (%s)' % (what, j['acceptance']),
            racc is not None and racc == j['acceptance'] and eacc == j['acceptance'],
            'report %s json %s editor %s' % (racc, j['acceptance'], eacc))

    shutil.rmtree(TMP, ignore_errors=True)
    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
