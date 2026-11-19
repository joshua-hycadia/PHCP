#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_velocity_pressure.py -- OPTION VELOCITY_PRESSURE, AS 2118.1 Cl 14.15.
# A port of tools/test_velocity_pressure.pl.
#
#   python3 tools/test_velocity_pressure.py           # the checks
#   python3 tools/test_velocity_pressure.py --freeze  # write the OFF fingerprint
#
# Four parts:
#   1. A HAND CHECK.  A three-head range worked from the end head back to the
#      supply the way a checker does it with a calculator -- end head on total
#      pressure, each in-line head on Pn = Pt - Pv with Pv from the pipe
#      feeding it, found by trial -- written here without the engine.  The
#      supply pressure that gives is put into a model, solved with the option
#      ON, and must give back the same flows.
#   2. OFF CHANGES NOTHING.  Every example solves to exactly the same flows and
#      pressures with no option, with OPTION VELOCITY_PRESSURE OFF, and as
#      frozen from the solver before the option existed
#      (tools/baseline/velocity_pressure_off.txt, written by --freeze on that
#      solver).  No outlet carries a velocity pressure.
#   3. ON AGAINST OFF on the examples: ON converges; every in-line sprinkler
#      meets q = K sqrt(Pt - Pv) with Pv = 0.5 v^2 of its feed pipe; end
#      sprinklers, hydrants and hose reels stay on Pt; and the table of total
#      sprinkler flow, ON against OFF, is printed for the pull request.
#   4. THE LANGUAGE AND THE OUTPUT.  A bad value is refused on its line; the
#      report, the editor's outlet table and the JSON state the basis.
#
# Example 04 (the 1000-pipe grid) is left out: one solve of it takes some 37
# minutes, and 02, 07 and 11 already have loops and in-line heads.
#==============================================================================

import glob
import math
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc

FREEZE = '--freeze' in sys.argv[1:]
EX = os.path.join(ROOT, 'examples')
FROZEN = os.path.join(TOOLS, 'baseline', 'velocity_pressure_off.txt')
GW = hardycross.GAMMA_W
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


def slurp(p):
    with open(p) as f:
        return f.read()


def read_phc(text):
    try:
        return phc.read_string(text), None
    except Exception as e:
        return None, (e.msg if hardycross.is_model_error(e) else str(e))


def elems(n):
    return n['elems'][1:]


def pipe_q(n):
    return {e['id']: e['q'] for e in elems(n) if e['kind'] == 'PIPE'}


def node_p(n):
    return {x['id']: x['h'] - GW * x['z'] for x in n['nodes'][1:] if x['id'] != 'REF'}


def base(m):
    return os.path.basename(m)


EXAMPLES = [m for m in sorted(glob.glob(os.path.join(EX, '*.phc'))) if 'grid1000' not in m]


def freeze():
    #--------------------------------------------------------------------------
    # --freeze: every example's solved flows and pressures, to 12 significant
    # figures.  Run on the solver BEFORE the option, so part 2 compares with
    # it.
    #--------------------------------------------------------------------------
    with open(FROZEN, 'w') as o:
        o.write('# Solved pipe flows (Q, L/min) and node gauge pressures (P, kPa) of every example\n'
                '# frozen from the solver before OPTION VELOCITY_PRESSURE existed (example 04 is not included).\n'
                '# With the option OFF, or not given, every example must still give these.\n')
        for m in EXAMPLES:
            b = base(m)
            n, _ = read_phc(slurp(m))
            hardycross.solve_model(n)
            q = pipe_q(n)
            p = node_p(n)
            for k in sorted(q):
                o.write('Q %s %s %.12g\n' % (b, k, q[k]))
            for k in sorted(p):
                o.write('P %s %s %.12g\n' % (b, k, p[k]))
    print('wrote %s' % FROZEN)
    sys.exit(0)


def part1():
    #==========================================================================
    print('1. HAND CHECK - three heads on one range, worked from the end head')
    #==========================================================================
    # The range: supply A, then H3, H2, H1 along it, each pipe 3.0 m, all at
    # datum, C = 120, no fittings.  P1 A-H3 is 36.0 mm bore; P2 H3-H2 and P3
    # H2-H1 are 27.0 mm.  K8.0 heads (L/min/kPa^0.5).  H1 is the end head.
    K, C, L = 8.0, 120, 3.0

    # AS 2118.1 Hazen-Williams, kPa: 6.05e7 L Q^1.85 / (C^1.85 d^4.87).
    def hw(q, d):
        return 6.05e7 * L * q ** 1.85 / (C ** 1.85 * d ** 4.87)

    # Pv = rho v^2 / 2 in kPa, v in m/s from L/min and mm.
    def pv(q, d):
        v = (q / 60000) / (3.14159265358979 * (d / 1000) ** 2 / 4)
        return 0.5 * v ** 2

    # An in-line head: q = K sqrt(Pt - Pv), Pv from the pipe feeding it,
    # which carries q itself plus everything beyond -- so found by trial.
    def inline(pt, beyond, d):
        q = K * math.sqrt(pt)
        for _ in range(200):
            q = K * math.sqrt(pt - pv(q + beyond, d))
        return q, pv(q + beyond, d)

    pt1 = 100                                   # end head, chosen
    q1 = K * math.sqrt(pt1)                     # on total pressure
    pt2 = pt1 + hw(q1, 27.0)
    q2, pv2 = inline(pt2, q1, 27.0)             # fed by P2
    pt3 = pt2 + hw(q1 + q2, 27.0)
    q3, pv3 = inline(pt3, q1 + q2, 36.0)        # fed by P1
    qt = q1 + q2 + q3
    pa = pt3 + hw(qt, 36.0)
    print('      by hand: q1 %.3f (Pt %.3f)  q2 %.3f (Pt %.3f Pv %.3f)  q3 %.3f (Pt %.3f Pv %.3f)  supply %.3f kPa'
          % (q1, pt1, q2, pt2, pv2, q3, pt3, pv3, pa))

    model = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                       'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW',
                       'OPTION TOL_FLOW 1E-7', 'OPTION TOL_LOOP 1E-8', 'OPTION MAXITER 200000',
                       'WATER A 0 %.10f' % pa,
                       'SPRINKLER H3 0 50 8.0', 'SPRINKLER H2 0 50 8.0', 'SPRINKLER H1 0 50 8.0',
                       'USE BORE 120', 'PIPE P1 A H3 3.0 36.0', 'PIPE P2 H3 H2 3.0 27.0',
                       'PIPE P3 H2 H1 3.0 27.0', ''])

    on, err = read_phc(model + '\nOPTION VELOCITY_PRESSURE ON\n')
    is_('the hand-check model reads', on, err)
    if on:
        is_('   solved with the option ON, it converges', hardycross.solve_model(on))
        e = {x['id']: x for x in elems(on)}
        q = pipe_q(on)
        d = 0
        for a, b in [(q['P3'], q1), (q['P2'], q1 + q2), (q['P1'], qt),
                     (abs(e['H1']['q']), q1), (abs(e['H2']['q']), q2), (abs(e['H3']['q']), q3)]:
            if abs(a - b) > d:
                d = abs(a - b)
        is_('   every flow agrees with the hand calculation, worst %.1e L/min' % d, d < 1e-3)
        is_('   H1, the end head: on total pressure, no Pv', not e['H1'].get('pv') and e['H1'].get('pv_end'))
        h2pv = e['H2'].get('pv')
        h2pv = 0 if h2pv is None else h2pv
        is_('   H2: Pv %.4f from pipe P2, as by hand (%.4f)' % (h2pv, pv2),
            abs(h2pv - pv2) < 1e-4 and (e['H2'].get('pv_pipe') or '') == 'P2')
        h3pv = e['H3'].get('pv')
        h3pv = 0 if h3pv is None else h3pv
        is_('   H3: Pv %.4f from pipe P1, as by hand (%.4f)' % (h3pv, pv3),
            abs(h3pv - pv3) < 1e-4 and (e['H3'].get('pv_pipe') or '') == 'P1')
        is_('   outlet_pressure of an in-line head is Pt - Pv',
            abs(hardycross.outlet_pressure(on, e['H2']) - (pt2 - pv2)) < 1e-4)
    # The same supply with the option OFF: every head on Pt, so each flows
    # more, and the total is larger.
    off, _ = read_phc(model)
    if off:
        hardycross.solve_model(off)
        q = pipe_q(off)
        print('      OFF at the same supply: total %.3f L/min against %.3f ON (+%.2f %%)'
              % (q['P1'], qt, 100 * (q['P1'] / qt - 1)))
        is_('   OFF at the same supply: more water, since no head is on Pn', q['P1'] > qt + 1)


def part2():
    #==========================================================================
    print('\n2. OFF CHANGES NOTHING - every example as before the option existed')
    #==========================================================================
    frozen = {}
    for line in slurp(FROZEN).split('\n'):
        if line.startswith('#') or not re.search(r'\S', line):
            continue
        k, b, id_, v = line.split()[:4]
        frozen.setdefault(b, {})['%s %s' % (k, id_)] = v
    for m in EXAMPLES:
        b = base(m)
        text = slurp(m)
        a, _ = read_phc(text)
        o, _ = read_phc(text + '\nOPTION VELOCITY_PRESSURE OFF\n')
        for x in (a, o):
            hardycross.solve_model(x)
        qa, qo, pa, po = pipe_q(a), pipe_q(o), node_p(a), node_p(o)
        # Bit for bit: the same solver path, run twice in one process.
        same = (not any(qa[k] != qo.get(k) for k in qa) and not any(pa[k] != po.get(k) for k in pa)
                and a['iters'] == o['iters'])
        is_('%s: no option and OPTION VELOCITY_PRESSURE OFF are identical' % b, same)
        is_('   no outlet carries a velocity pressure', not any('pv' in e for e in elems(a) + elems(o)))
        # Against the solver before the option: 12 significant figures, so a
        # last-bit difference in a maths library elsewhere cannot fail it.
        f = frozen.get(b)
        if not f:
            is_('   frozen results present for %s' % b, 0)
            continue
        worst, missing = 0, 0
        for key in f:
            k, id_ = key.split()
            now = qa.get(id_) if k == 'Q' else pa.get(id_)
            if now is None:
                missing += 1
                continue
            fv = float(f[key])
            rel = abs(now - fv) / (abs(fv) if abs(fv) > 1 else 1)
            if rel > worst:
                worst = rel
        is_('   as frozen before the option: worst relative difference %.1e' % worst,
            not missing and worst < 1e-10, ('%d frozen ids not in the model' % missing) if missing else None)


def part3():
    #==========================================================================
    print('\n3. ON AGAINST OFF on the examples')
    #==========================================================================
    table = []

    def total(n):
        return sum(abs(e['q']) for e in elems(n)
                   if e['kind'] == 'DISCHARGE' and e['otype'] == 'SPRINKLER')

    for m in EXAMPLES:
        b = base(m)
        text = slurp(m)
        off, _ = read_phc(text)
        on, _ = read_phc(text + '\nOPTION VELOCITY_PRESSURE ON\n')
        okf = hardycross.solve_model(off)
        ok = hardycross.solve_model(on)
        is_('%s: ON converges' % b, not okf or ok)
        spk = [e for e in elems(on) if e['kind'] == 'DISCHARGE' and e['otype'] == 'SPRINKLER']
        oth = [e for e in elems(on) if e['kind'] == 'DISCHARGE' and e['otype'] != 'SPRINKLER']
        # The rule, checked against the solved network rather than the
        # engine's own bookkeeping: each sprinkler's feed pipe found again
        # here, and its discharge worked on Pt - 0.5 v^2.
        bad, inl = 0, 0
        tol = on['opts'].get('tol_loop')
        tol = 0.01 if tol is None else tol
        for s in spk:
            feed, fq, out = None, 0, 0
            for e in elems(on):
                if e.get('closed') or e['kind'] == 'DISCHARGE' or abs(e['q']) <= 1e-6:
                    continue
                to, frm = (e['n2'], e['n1']) if e['q'] > 0 else (e['n1'], e['n2'])
                if frm == s['n1']:
                    out = 1
                if to == s['n1'] and e['kind'] == 'PIPE' and abs(e['q']) > fq:
                    feed, fq = e, abs(e['q'])
            v = hardycross.pipe_velocity(fq, feed['dia']) if feed and out else 0
            pv = 0.5 * v ** 2
            if pv > 0:
                inl += 1
            pt = on['nodes'][s['n1']]['h'] - GW * s['z']
            want = s['k'] * math.sqrt(pt - pv if pt - pv > 0 else 0)
            # Pv is held from the last pass, so the flow it gives agrees to
            # within what the loop tolerance allows.
            spv = s.get('pv')
            spv = 0 if spv is None else spv
            if abs(abs(s['q']) - want) > 0.05 + s['k'] * tol or abs(spv - pv) > 2 * tol:
                bad += 1
        is_('   %d sprinkler(s), %d in-line: each q = K sqrt(Pt - Pv), end heads on Pt' % (len(spk), inl),
            not bad)
        is_('   hydrants and hose reels: no velocity pressure', not any(e.get('pv') for e in oth))
        if spk:
            table.append([b, len(spk), inl, total(off), total(on)])
    print('\n      EXAMPLE                        HEADS  IN-LINE   SPRINKLER FLOW OFF    ON      CHANGE')
    for r in table:
        print('      %-30s %5d  %7d   %18.1f %9.1f  %+7.2f %%' % (r[0], r[1], r[2], r[3], r[4],
                                                                 100 * (r[4] / r[3] - 1)))
    print('      (L/min at the operating point, each example\'s own supply.)')


def part4():
    #==========================================================================
    print('\n4. THE LANGUAGE AND THE OUTPUT')
    #==========================================================================
    n, err = read_phc('WATER W 0 500\nSPRINKLER S1 0 -50 8\nUSE BORE 120\nPIPE P1 W S1 10 25\n'
                      'OPTION VELOCITY_PRESSURE MAYBE\n')
    is_('OPTION VELOCITY_PRESSURE MAYBE is refused on its line',
        not n and re.search(r'^line 5: .*VELOCITY_PRESSURE IS ON .* OR OFF', err or ''), err)
    l, _ = read_phc('WATER W 0 500\nSPRINKLER S1 0 -50 8\nUSE BORE 120\nPIPE P1 W S1 10 25\n'
                    'OPTION VELOCITY_PRESSURE on\n')
    is_('   lower case is read the same', l and l['opts'].get('vel_press'))
    is_('   it is in the option list the editor offers', 'VELOCITY_PRESSURE' in phc.OPTIONS)

    from hardycross import report, jsonout
    text = slurp(os.path.join(EX, '07_pipe_database_demo.phc'))
    for name, t, want in [('OFF', text, 0), ('ON', text + '\nOPTION VELOCITY_PRESSURE ON\n', 1)]:
        net, _ = read_phc(t)
        net['source_text'] = t
        ok = hardycross.solve_model(net)
        rep = report.write_report(net, ok, '07.phc')
        is_('report, %s: the cover sheet states the basis' % name,
            re.search(r'Velocity pressure\s+: ' + re.escape('INCLUDED, Cl 14.15' if want else 'NOT INCLUDED'),
                      rep))
        is_('   Section 1 states the outlet discharge basis',
            re.search(r'Outlet discharge\s+q = K x sqrt\(%s\)' % ('Pn' if want else 'Pt'), rep))
        is_('   the flow path notes state it',
            (re.search(r'Discharge [\d.]+ L/min = K [\d.]+ x sqrt\(Pn ', rep)
             or re.search(r'VELOCITY_PRESSURE ON\); this outlet', rep)) if want
            else re.search(r'Discharge basis: total pressure; velocity pressure not included', rep))
        is_('   the election is in Section 4 only when it is made',
            bool(re.search(r'ELECTION: velocity pressures included', rep)) == bool(want))
        j = jsonout.results(net, ok, '07.phc', demand=0)
        is_('   JSON: velocity_pressure is ' + ('true' if want else 'false'),
            bool(j['velocity_pressure']) == bool(want))
        bad = len([o for o in j['outlets'] if o['k'] is not None
                   and (abs(o['discharge_pressure'] - (o['pressure'] - o['velocity_pressure'])) > 2e-4
                        or abs(o['margin'] - (o['discharge_pressure'] - o['required_pressure'])) > 2e-4)])
        is_('   JSON: discharge_pressure = pressure - velocity_pressure; margin on it', not bad)
        is_('   JSON: some outlet has a velocity pressure only when ON',
            bool([o for o in j['outlets'] if (o.get('velocity_pressure') or 0) > 0]) == bool(want))


def main():
    if FREEZE:
        freeze()
    part1()
    part2()
    part3()
    part4()
    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
