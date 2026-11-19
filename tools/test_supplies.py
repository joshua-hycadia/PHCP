#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_supplies.py -- several water supplies (hardycross.supplies).  Python
# port of test_supplies.pl, check for check.
#
#   python3 tools/test_supplies.py
#
#   1. OPERATING.  Each supply's own flow and pressure; their signed sum
#      against the net demand; a supply taking water in is named.
#   2. ONE SUPPLY.  The conditional and the joint demand of a model with one
#      supply are its demand point (hardycross.demand), found independently.
#   3. CONDITIONAL.  At each supply's conditional minimum the governing outlet
#      receives its minimum, the others as modelled, and half a kPa less is
#      not enough.  A supply the others can do without is NOT REQUIRED.
#   4. JOINT.  One solve: re-solved at the derating found, the governing
#      margin is zero, the flows add up, and every supply has the same margin
#      on the DERATE basis; on SCALE every pressure is the same fraction of
#      what the supply gives.  The joint contribution is not the conditional
#      minimum.
#   5. SCENARIOS.  Each supply alone and each out of service, and the SCENARIO
#      lines: each solved and validated on its own; a SCENARIO line that is not
#      ACCEPTED fails the design.  The language refuses a bad SCENARIO.
#   6. REPORT AND JSON.  Section 12 and the JSON supplies block, the same
#      numbers.
#
# These tests check PHCP against the conditions it sets itself; they are not
# evidence of external certification.
#==============================================================================
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import demand, jsonout, phc, report, supplies, validate

EX = os.path.join(ROOT, 'examples')
passed = failed = 0


def is_(name, ok, why=None):
    global passed, failed
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        passed += 1
    else:
        failed += 1


def near(a, b, t):
    return a is not None and b is not None and abs(a - b) <= t


HEAD = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                  'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', ''])
# Two supplies of different strength, at different elevations and places,
# feeding two sprinklers and a hydrant.
TWO = HEAD + """WATER WA 0 700 1500 550 3000 300
WATER WB 2 450 1000 380 2000 200
NODE J1 0
NODE J2 1
SPRINKLER S1 4 -100 80
SPRINKLER S2 4 -100 80
HYDRANT H1 1 -350 65
PIPE A1 WA J1 30 150
PIPE B1 WB J2 60 100
PIPE J12 J1 J2 50 100
PIPE R1 J2 S1 10 50
PIPE R2 J2 S2 15 50
PIPE HY J1 H1 20 100
"""


def solved(text):
    n = phc.read_string(text)
    ok = hardycross.solve_model(n)
    return n, ok


def sup(n, id_):
    return next((s for s in demand.supplies(n) if s['id'] == id_), None)


def slurp(path):
    with open(path) as f:
        return f.read()


def refusal_msg(text):
    # '' when the text reads, else the model error's message (the Perl's
    # eval { ...; 1 } ? '' : $@->{msg}).
    try:
        phc.read_string(text)
        return ''
    except hardycross.ModelError as e:
        return e.msg


def main():
    net, ok = solved(TWO)
    r = supplies.analyse(net, ok)

    print("1. OPERATING")
    is_('two supplies: solved and ACCEPTED', ok and validate.validate(net, ok)['acceptance'] == 'ACCEPTED')
    is_('the signed sum of the supplies is the net demand (%.3g L/min apart)' % r['balance'],
        abs(r['balance']) < 1e-6)
    op = {o['id']: o for o in r['operating']}
    is_('each supply has its own flow, unequal', abs(op['WA']['flow'] - op['WB']['flow']) > 100,
        '%s %s' % (op['WA']['flow'], op['WB']['flow']))
    is_('each supply has its own pressure, unequal', abs(op['WA']['pressure'] - op['WB']['pressure']) > 10)
    is_('   and each is on its own curve at its own flow',
        near(op['WA']['pressure'], hardycross.curve_eval(sup(net, 'WA')['curve'], op['WA']['flow']), 0.02)
        and near(op['WB']['pressure'], hardycross.curve_eval(sup(net, 'WB')['curve'], op['WB']['flow']), 0.02))
    is_('the shares add to 100 %', near(op['WA']['share'] + op['WB']['share'], 100, 1e-9))
    n, k = solved(HEAD + "WATER WA 0 800\nWATER WB 0 200\nNODE A 0\nSPRINKLER S1 0 -50 80\n"
                  + "PIPE P1 WA A 10 50\nPIPE P2 WB A 10 50\nPIPE P3 A S1 5 25\n")
    o = supplies.operating(n)
    wb = next((x for x in o if x['id'] == 'WB'), None)
    is_('a supply taking water in is REVERSE, its flow negative', wb['status'] == 'REVERSE' and wb['flow'] < 0)

    print("2. ONE SUPPLY")
    n, k = solved(slurp(os.path.join(EX, '01_single_branch.phc')))
    dm = demand.demand_point(n)
    c = supplies.conditional(n, dm['supply']['id'])
    j = supplies.joint(n)
    is_('the conditional minimum is the demand point (%.2f against %.2f kPa)' % (c['pressure'], dm['p_demand']),
        near(c['pressure'], dm['p_demand'], 0.05))
    js = j['supplies'][0]
    is_('the joint demand is the demand point (%.2f against %.2f kPa)' % (js['pressure'], dm['p_demand']),
        near(js['pressure'], dm['p_demand'], 0.05) and near(js['flow'], dm['q_system'], 0.001 * dm['q_system']))
    is_("   and its margin is the demand point's", near(j.get('margin'), dm.get('margin'), 0.05),
        '%s %s' % (j.get('margin'), dm.get('margin')))

    print("3. CONDITIONAL")
    for c in r['conditional']:
        is_('%s: REQUIRED, ACCEPTED' % c['id'], c['status'] == 'REQUIRED' and c.get('acceptance') == 'ACCEPTED',
            '%s %s' % (c['status'], c.get('acceptance')))
        k1, n1 = demand.solve_at(net['source_text'], c['id'], c['pressure'])
        m1 = demand.governing_outlet(n1)[1]
        k2, n2 = demand.solve_at(net['source_text'], c['id'], c['pressure'] - 0.5)
        m2 = demand.governing_outlet(n2)[1]
        is_('   at %.2f kPa the governing margin is zero (%.4f), 0.5 kPa less fails' % (c['pressure'], m1),
            k1 and m1 >= 0 and m1 < 0.05 and m2 < 0)
        is_('   the other supply as modelled (its curve), not reversed', not c['others_reverse'])
    n, k = solved(slurp(os.path.join(EX, '09_parallel_pumps.phc')))
    c = supplies.conditional(n, 'PA')
    is_('09: PA is NOT REQUIRED - the other two meet every outlet without it', c['status'] == 'NOT_REQUIRED')

    print("4. JOINT")
    j = r['joint']
    is_("DERATE: found, ACCEPTED, D = " + '%.2f kPa' % (j.get('delta') if j.get('delta') is not None else 0),
        not j.get('reason') and j.get('acceptance') == 'ACCEPTED' and j.get('delta') is not None)
    n = phc.read_string(TWO)
    for s in demand.supplies(n):
        s['curve'] = supplies.shifted(s['curve'], lambda p: p - j['delta'])
    k = hardycross.solve_model(n)
    m = demand.governing_outlet(n)[1]
    is_('   one solve: re-solved at D the governing margin is zero (%.4f kPa)' % m, k and m >= 0 and m < 0.05)
    qt = 0
    for s in demand.supplies(n):
        qt += s['q']
    is_('   its flows are the joint flows, and add to the total',
        near(qt, j['q_total'], 1e-6)
        and not [x for x in j['supplies'] if not near(x['flow'], sup(n, x['id'])['q'], 1e-6)])
    is_('   every supply has the same margin, D',
        not [x for x in j['supplies'] if not near(x.get('margin'), j['delta'], 1e-6)])
    is_('   each supply at its own pressure, not one common pressure',
        abs(j['supplies'][0]['pressure'] - j['supplies'][1]['pressure']) > 10)
    cond = {x['id']: x for x in r['conditional']}
    is_('   the joint contribution is not the conditional minimum',
        not [x for x in j['supplies'] if near(x['flow'], cond[x['id']].get('flow'), 1)])
    n, k = solved(TWO + "OPTION JOINT_BASIS SCALE\n")
    js = supplies.joint(n)
    is_('SCALE: found, F = %.4f' % (js.get('factor') if js.get('factor') is not None else 0),
        not js.get('reason') and js.get('factor') is not None)
    is_("   every supply's pressure is F times what it gives at its flow",
        not [x for x in js['supplies'] if not near(x['pressure'], js['factor'] * x['available'], 0.01)])

    print("5. SCENARIOS")
    sc = {x['name']: x for x in r['scenarios']}
    is_('each supply alone and each out of service (ONLY-WA, ONLY-WB)', sc.get('ONLY-WA') and sc.get('ONLY-WB'))
    is_('   with two supplies, WITHOUT-WA is ONLY-WB and is not repeated', not sc.get('WITHOUT-WA'))
    is_('   a supply out of service gives nothing',
        not [s for x in sc.values() for s in x['supplies'] if s['status'] == 'OUT_OF_SERVICE' and s['flow'] != 0])
    is_('   each is validated on its own', not [x for x in sc.values() if not x.get('acceptance')])
    n, k = solved(TWO + "SCENARIO WEAKA WA 70\n")
    as_ = validate.assess(n, k)
    w = next((x for x in as_['supplies']['scenarios'] if x['name'] == 'WEAKA'), None)
    is_('SCENARIO WEAKA (WA at 70 %%): solved, %s' % w['acceptance'], w and w.get('required'))
    wa = next((x for x in w['supplies'] if x['id'] == 'WA'), None)
    is_('   WA at 70 % of its pressure', float(wa['percent']) == 70)     # Perl's numeric ==
    is_('   not ACCEPTED, so the design fails on it (SCENARIO)', w['acceptance'] != 'ACCEPTED'
        and [f for f in as_['validation']['findings'] if f['code'] == 'SCENARIO' and f.get('item') == 'WEAKA'])
    n2, k2 = solved(TWO + "OPTION SUPPLY_SCENARIOS OFF\nSCENARIO NOB WB 0\n")
    r2 = supplies.analyse(n2, k2)
    is_('OPTION SUPPLY_SCENARIOS OFF: only the SCENARIO lines', len(r2['scenarios']) == 1
        and r2['scenarios'][0]['name'] == 'NOB')
    for line, want in (['SCENARIO X WC 0', 'NOT DEFINED'], ['SCENARIO X J1 0', 'NOT A WATER SUPPLY'],
                       ['SCENARIO X WA 120', r'0 \(OUT OF SERVICE\) TO 100'], ['SCENARIO X WA 50 WA 20', 'TWICE']):
        e = refusal_msg(TWO + line + "\n")
        is_('refused: %s' % line, re.search(want, e), e)
    # With one supply there is nothing for a scenario to share out, and the
    # line would otherwise be read and never solved.
    one = HEAD + "WATER W 0 500\nNODE A 0\nSPRINKLER S1 0 -50 80\nPIPE P1 W A 10 50\nPIPE P2 A S1 5 25\n"
    e = refusal_msg(one + "SCENARIO LOW W 80\n")
    is_('refused: a SCENARIO in a model with one supply', re.search(r'MORE THAN ONE WATER SUPPLY', e), e)

    print("6. REPORT AND JSON")
    rep = report.write_report(net, ok, 'two.phc')
    is_('the report has Section 12, MULTIPLE WATER SUPPLIES', re.search(r'12\. MULTIPLE WATER SUPPLIES', rep))
    is_('   operating, conditional, joint and scenarios', re.search(r'A\. OPERATING', rep)
        and re.search(r'B\. CONDITIONAL', rep) and re.search(r'C\. JOINT DEMAND', rep)
        and re.search(r'D\. SUPPLY SCENARIOS', rep))
    is_('   saying the conditional minima are not added', re.search(r'they are not\s+added', rep))
    jj = jsonout.results(net, ok, 'two.phc')
    is_('the JSON has the supplies block, with the same derating',
        jj.get('supplies') and near(jj['supplies']['joint'].get('derating'), j['delta'], 1e-3))
    is_('   and the same conditional minima',
        not [c for c in jj['supplies']['conditional']
             if not near(c.get('required_pressure'), cond[c['id']].get('pressure'), 1e-3)])

    print('\n%d passed, %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
