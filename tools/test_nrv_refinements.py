#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.
#
# test_nrv_refinements.py -- Python port of test_nrv_refinements.pl, check
# for check.
#
# These are targeted regressions for documented supply valve loss curves,
# re-evaluation after isolation, pump switch caps, and portable saved results.
# No manufacturer performance figure is asserted by the example data.
import json
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import jsonout, phc, results, validate

passed = failed = 0


def check(name, good, why=None):
    global passed, failed
    print('  %-72s %s' % (name, 'ok' if good else '*** FAIL'))
    if not good and why is not None:
        print('    %s' % why)
    if good:
        passed += 1
    else:
        failed += 1


def approx(a, b, t):
    return a is not None and b is not None and abs(a - b) <= t


def elem(net, id_):
    for e in net['elems'][1:]:
        if e.get('id') == id_:
            return e
    return None


def refusal(text):
    try:
        phc.read_string(text)
    except Exception as e:      # any error, as the Perl's eval catches any die
        return e.msg if hardycross.is_model_error(e) else str(e)
    return None


def solve(text):
    net = phc.read_string(text)
    ok = hardycross.solve_model(net)
    return net, ok, validate.assess(net, ok)


U = "UNITS FLOW LPM\nUNITS PRESSURE KPA\nUNITS LENGTH M\n"
S = U + "USE BORE 120\nWATER W 0 800\nSPRINKLER S 0 60 10\nPIPE P W S 10 100\n"
DATA = "NRV W 0 7\nNRVMODEL W EXAMPLE MODEL DATA SHEET REVISION\nNRVLOSS W 0 0 500 5 1000 18\n"


def main():
    print("1. MANUFACTURER LOSS DATA")
    check('sourced non-return valve loss curve parses', not refusal(S + DATA))
    bad = [
        ['missing NRV', "NRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5\n"],
        ['unidentified data source', "NRV W 0\nNRVLOSS W 0 0 500 5\n"],
        ['double-counted Cv', "NRV W 900\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5\n"],
        ['nonzero zero-flow loss', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 2 500 5\n"],
        ['duplicate flow', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 5 500 9\n"],
        ['decreasing loss', "NRV W 0\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 500 12 1000 5\n"],
    ]
    for b in bad:
        check('invalid NRVLOSS rejected: %s' % b[0], refusal(S + b[1]) is not None)
    n, ok, a = solve(S + DATA)
    v = elem(n, 'W')
    check('curve basis is retained on supply', v['nrv'].get('basis') == 'CURVE')
    check('published 500 L/min point is reproduced including cracking pressure',
          approx(hardycross.check_valve_loss(v, 500)[0], 12, 1e-9))
    check('published 1000 L/min point is reproduced including cracking pressure',
          approx(hardycross.check_valve_loss(v, 1000)[0], 25, 1e-9))
    js = json.loads(jsonout.encode(jsonout.results(n, ok, 'model.phc')))
    check('JSON reports manufacturer curve basis and range',
          js['supply_check_valves'][0].get('loss_basis') == 'CURVE'
          and js['supply_check_valves'][0].get('loss_curve_max_flow') == 1000)
    short = DATA.replace('1000 18', '100 2', 1)     # (unused, as in the Perl)
    del short
    outside, outside_ok, outside_a = solve(S + "NRV W 0 7\nNRVMODEL W EXAMPLE\nNRVLOSS W 0 0 100 2\n")
    check('operating beyond published loss curve cannot be accepted',
          outside_a['validation']['acceptance'] != 'ACCEPTED')
    check('curve range issue is explicitly identified',
          len([f for f in outside_a['validation']['findings'] if f['code'] == 'NRV_CURVE_RANGE']) > 0)

    print("2. PERSISTED VALVE RESULTS")
    saved = results.with_results(S + DATA, n, ok)
    recs = results.read_block(saved)
    valve = next((r for r in recs if r[0] == 'CHECKVALVE' and r[1] == 'W'), None)
    check('saved PHC includes check valve record', valve)
    check('saved PHC includes curve, model and final state',
          valve and re.search(r'BASIS CURVE', ' '.join(valve))
          and re.search(r'MODEL EXAMPLE_MODEL_DATA_SHEET_REVISION', ' '.join(valve))
          and re.search(r'STATE DELIVERING', ' '.join(valve)))
    check('saved PHC record checksum is current', results.status(saved) == 'CURRENT')

    print("3. ISOLATED SUPPLY RE-EVALUATION")
    LIFT = (U + "USE BORE 120\nWATER W 0 50\nNODE J 0\nSPRINKLER S 10 60 80\nPIPE P W J 10 100\n"
            "PIPE R J S 10 65\nNRV W 0\n")
    iso, iso_ok, _ = solve(LIFT)
    check('weak supply initially isolated', elem(iso, 'W').get('isolated') and elem(iso, 'W').get('closed'))
    elem(iso, 'W')['pstat'] = 600    # New external supply condition on same model.
    new_ok = hardycross.solve_model(iso)
    new_validation = validate.validate(iso, new_ok)
    check('isolated supply is reconsidered and can reopen after pressure recovers',
          new_ok and not elem(iso, 'W').get('closed') and not elem(iso, 'W').get('isolated'),
          new_validation['acceptance'])
    check('recovered supply delivers positive flow and its outlet is reconnected',
          elem(iso, 'W')['q'] > 0 and not elem(iso, 'S').get('isolated'))
    check('recovered solution passes mandatory validation',
          new_validation['acceptance'] == 'ACCEPTED' or new_validation['acceptance'] == 'NONCOMPLIANT',
          new_validation['acceptance'])

    print("4. PUMP SWITCHING STATE")
    # Two supplies, one behind a pump (churn 300 kPa on a 700 kPa supply, so at
    # most 1000 kPa on its outlet).  With W2 at 900 kPa the pump can beat it and
    # must run, on its curve; with W2 at 1100 kPa it cannot, and its check valve
    # must shut.  The closed one is the reference for the switch-limit checks.
    PUMP = (U + "USE BORE 120\nWATER W1 0 700\nWATER W2 0 %d\nNODE A 0\nNODE B 0\nSPRINKLER S1 0 -50 80\n"
            "PIPE P1 W1 A 10 100\nPUMP PU A B 300 500 280 1000 200\nPIPE P2 W2 B 10 100\nPIPE P3 B S1 10 50\n")
    runnet, _, _ = solve(PUMP % 900)
    run = elem(runnet, 'PU')
    boost = runnet['nodes'][run['n2']]['h'] - runnet['nodes'][run['n1']]['h']
    curve = hardycross.curve_eval(run['curve'], run['q'])
    check('a pump that can beat the other supply runs forward, on its curve',
          not run.get('closed') and run['q'] > 0 and abs(boost - curve) < 0.01,
          "closed %d, q %.2f, boost %.3f against the curve's %.3f"
          % (run.get('closed') or 0, run['q'], boost, curve))
    pumpnet, pumpok, _ = solve(PUMP % 1100)
    pu = elem(pumpnet, 'PU')
    check("a pump that cannot reach the other supply's pressure settles closed", pu.get('closed') and pumpok)
    pu['nflips'] = 99
    hardycross.solve_model(pumpnet)
    check('settled pump at flip limit is not spuriously unresolved',
          not (pu.get('flip_limit') or 0))
    pu['q'] = -5
    pu['closed'] = 0
    pu['nflips'] = 99
    hardycross.pump_status(pumpnet)
    check('pump at flip limit in impossible open reverse-flow state is flagged',
          pu.get('flip_limit') or 0)

    print('%d passed; %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
