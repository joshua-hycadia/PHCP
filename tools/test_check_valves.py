#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_check_valves.py -- non-return (check) valves at water supplies, and the
# defects found in the audit of 11 November 2026 (second stage).  Python port
# of test_check_valves.pl, check for check.
#
#   python3 tools/test_check_valves.py
#
# Every case was written BEFORE the code it tests and failed on main at
# 1e196b8 (PHCP 1.5.0 with the acceptance hardening of PR 47).  The parts:
#
#   1. DEFECTS.  A gravity tank -- a supply at 0 kPa gauge, high above the
#      outlets, the reference manual's own example -- was REJECTED as "not
#      reachable from any supply", and its demand point came out a hair ABOVE
#      zero, so the supply failed its adequacy check by -0.0 kPa.
#   2. THE NRV COMMAND.  What it accepts and what it refuses.
#   3. NO CHANGE WHERE NONE IS DUE.  A check valve with no loss on a supply
#      that delivers leaves every flow and pressure exactly as before.
#   4. CLOSING.  A supply that would take water in closes, carries nothing,
#      and the rest of the network is solved without it -- to the same answer
#      as the model with that supply deleted.
#   5. REOPENING.  A closed supply whose pressure would now drive water in
#      opens again; one that cannot settle is not taken as settled.
#   6. ISOLATION.  A single supply whose valve closes leaves the outlets with
#      no water: that is LOSS OF SUPPLY (NONCOMPLIANT, SUPPLY_ISOLATED), not a
#      numerical failure and not a pass.  Part of a network isolated the same
#      way is reported for that part only.
#   7. CHANGING DEMAND.  A weak supply closed at a small demand opens at a
#      large one.
#   8. DEMAND SEARCHES.  The joint demand, the conditional minima and the
#      scenarios run with the valves operating: a supply shut on its valve is
#      not a supply found too weak, and not an invalid trial.
#   9. THE VALVE'S LOSS.  Its opening pressure and its Cv loss, checked from
#      the solved heads against the data-sheet definition worked here.
#  10. REPORTING.  The JSON and the report give each supply's valve, state,
#      flow, pressure and loss, and agree with each other on acceptance.
#  11. EQUIVALENT DESCRIPTIONS.  Renamed nodes, reordered lines, pipes drawn
#      the other way and other units give the same answer.
#
# These tests check PHCP against the conditions it sets itself.  They are not
# evidence of conformance with any Standard or of external certification.
#==============================================================================
import json
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import demand, jsonout, phc, report, validate

passed = failed = 0


def is_(name, ok, why=None):
    global passed, failed
    print('  %-70s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        passed += 1
    else:
        failed += 1


def near(a, b, t):
    return a is not None and b is not None and abs(a - b) <= t


def num(x):
    # Perl's numeric value of a possibly undefined field.
    return 0 if x is None else x


HEAD = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                  'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120', ''])
# WA is strong and far, WB weak and next to the sprinkler: as modelled
# without a check valve, WB takes water in (tools/impossible/supply_takes_water_in.phc).
TWO = ("WATER WA 0 1000\nWATER WB 0 520\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n"
       "PIPE A1 WA J1 40 65\nPIPE B1 WB J2 5 100\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n")
# The same network with WB deleted (its pipe B1 too): what the valve closing
# must reproduce.
ONLY_A = ("WATER WA 0 1000\nNODE J1 0\nNODE J2 0\nSPRINKLER S1 0 -100 80\n"
          "PIPE A1 WA J1 40 65\nPIPE J12 J1 J2 5 100\nPIPE R1 J2 S1 5 50\n")


def refused(text):
    try:
        phc.read_string(text)
    except Exception as e:      # any error, as the Perl's eval catches any die
        return e.msg if hardycross.is_model_error(e) else str(e)
    return None


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


def elem(n, id_):
    for e in n['elems'][1:]:
        if (e.get('id') if e.get('id') is not None else '') == id_:
            return e
    return None


def node(n, id_):
    for x in n['nodes'][1:]:
        if (x.get('id') if x.get('id') is not None else '') == id_:
            return x
    return None


def gauge(n, id_):
    x = node(n, id_)
    return x['h'] - hardycross.GAMMA_W * x['z']


def lst(h):
    return ','.join(sorted(h)) or 'none'


def dflt(x):
    return '' if x is None else x


def part1():
    print("1. DEFECTS")
    # A tank 30 m above the outlets, open to air: 0 kPa gauge at its surface,
    # 294 kPa of head at the sprinkler's level before losses.
    TANK = "WATER TANK 30 0\nNODE J1 0\nSPRINKLER S1 0 60 80\nPIPE A1 TANK J1 10 100\nPIPE R1 J1 S1 5 65\n"
    n, ok, as_ = assessed(HEAD + TANK)
    v = as_['validation']
    is_('gravity tank at 0 kPa: not reported unreachable', not errs(v).get('DEMAND_UNCONNECTED'), lst(errs(v)))
    is_('gravity tank at 0 kPa: ACCEPTED (it delivers 60 L/min with head to spare)',
        v['acceptance'] == 'ACCEPTED', '%s: %s' % (v['acceptance'], lst(errs(v))))
    dm = as_['demand']
    is_('gravity tank: demand point FOUND at 0 kPa gauge (met by its elevation alone)',
        dflt(dm.get('status')) == 'FOUND' and near(dm.get('p_demand'), 0, 1e-12), 'p_demand %s' % dm.get('p_demand'))
    is_('gravity tank: margin not negative', dm.get('margin') is not None and dm['margin'] >= 0,
        'margin %s' % dm.get('margin'))
    is_('gravity tank: demand point says it is met at zero gauge pressure', 1 if dm.get('at_floor') else 0)
    # A supply that really gives nothing is still not a supply: a static
    # supply at 0 kPa at the outlets' own level cannot move water.
    n2, ok2, as2 = assessed(HEAD + "WATER W 0 0\nSPRINKLER S1 0 60 80\nPIPE A1 W S1 10 100\n")
    is_('a supply at 0 kPa on the level delivers nothing: not ACCEPTED',
        as2['validation']['acceptance'] != 'ACCEPTED', as2['validation']['acceptance'])

    # The floor trial is made only when every other trial passed.  Tried
    # first on every model, behind a backflow preventer and a pressure
    # reducing valve a 0 kPa supply cannot drive the network, and that trial
    # ran the Hardy Cross iteration to its limit: the round 2 device
    # benchmark ran 26 times slower (comparison/RERUN_2026-11-11.md).  So
    # count the searches' trials at 0 kPa on such a model: there must be none.
    zero = []
    real = demand.solve_at

    def spy(*a):
        if a[2] < 0.005:
            zero.append(a[2])
        return real(*a)
    demand.solve_at = spy
    try:
        n3, ok3, as3 = assessed(HEAD + "WATER W 0 500\nNODE J 0\nNODE K 0\nSPRINKLER S1 0 80 50\n"
                                + "PIPE P1 W J 10 100\nBFP P1 0 40 1000 60 2000 100\nPIPE P2 J K 10 100\n"
                                + "PRV P2 0 80\nPIPE P3 K S1 5 50\n")
    finally:
        demand.solve_at = real
    dm3 = as3['demand']
    is_('behind a BFP and a PRV: demand point FOUND, well above 0 kPa',
        dflt(dm3.get('status')) == 'FOUND' and dm3['p_demand'] > 100 and not dm3.get('at_floor'),
        '%s at %s' % (dm3.get('status') if dm3.get('status') is not None else '-',
                      dm3.get('p_demand') if dm3.get('p_demand') is not None else '-'))
    is_('behind a BFP and a PRV: no search tries a 0 kPa supply it does not need', not zero,
        '%d trials at 0 kPa' % len(zero))


def part2():
    print("2. THE NRV COMMAND")
    is_('NRV on a water supply reads', not refused(HEAD + TWO + "NRV WB 0\n"), refused(HEAD + TWO + "NRV WB 0\n"))
    is_('NRV with a Cv and an opening pressure reads', not refused(HEAD + TWO + "NRV WB 600 7\n"))
    is_('NRV on a node that is not a supply is refused', refused(HEAD + TWO + "NRV J1 0\n") is not None)
    is_('NRV on an undefined name is refused', refused(HEAD + TWO + "NRV NOPE 0\n") is not None)
    is_('NRV with a negative Cv is refused', refused(HEAD + TWO + "NRV WB -5\n") is not None)
    is_('NRV with a negative opening pressure is refused', refused(HEAD + TWO + "NRV WB 0 -1\n") is not None)
    is_('NRV twice on one supply is refused', refused(HEAD + TWO + "NRV WB 0\nNRV WB 0\n") is not None)
    is_('NRVMODEL without an NRV is refused', refused(HEAD + TWO + "NRVMODEL WB SOME VALVE\n") is not None)
    is_('NRVMODEL with an NRV reads', not refused(HEAD + TWO + "NRV WB 600\nNRVMODEL WB ACME 100 MM SWING CHECK\n"))
    n = phc.read_string(HEAD + TWO + "NRV WB 600 7\nNRVMODEL WB ACME SWING\n")
    wb = elem(n, 'WB')
    is_('the supply carries its valve: Cv, opening pressure, make and model',
        bool(wb.get('nrv')) and num(wb['nrv'].get('cv')) == 600 and near(wb['nrv'].get('crack'), 7, 1e-12)
        and wb['nrv'].get('model') == 'ACME SWING')
    is_('a supply with no NRV line has no valve', not elem(n, 'WA').get('nrv'))
    # In other pressure units the opening pressure is converted like any other.
    bar = (HEAD + TWO).replace('UNITS PRESSURE KPA', 'UNITS PRESSURE BAR', 1)
    bar = bar.replace('WATER WA 0 1000', 'WATER WA 0 10', 1)
    bar = bar.replace('WATER WB 0 520', 'WATER WB 0 5.2', 1)
    nb = phc.read_string(bar + "NRV WB 600 0.07\n")
    is_('an opening pressure in bar is converted to kPa', near(elem(nb, 'WB')['nrv'].get('crack'), 7, 1e-9),
        elem(nb, 'WB')['nrv'].get('crack'))


def part3():
    print("3. NO CHANGE WHERE NONE IS DUE")
    # Both supplies deliver here (WB is strong); a lossless valve must change
    # nothing at all.
    both = TWO.replace('WATER WB 0 520', 'WATER WB 0 900', 1)
    a, _ = solve(HEAD + both)
    b, okb = solve(HEAD + both + "NRV WA 0\nNRV WB 0\n")
    same = 1
    for id_ in ('WA', 'WB', 'A1', 'B1', 'J12', 'R1', 'S1'):
        if not near(elem(a, id_).get('q'), elem(b, id_).get('q'), 1e-12):
            same = 0
    is_('lossless valves on delivering supplies: every flow identical', same and okb)
    is_('lossless valves on delivering supplies: every pressure identical',
        near(gauge(a, 'S1'), gauge(b, 'S1'), 1e-12) and near(gauge(a, 'J2'), gauge(b, 'J2'), 1e-12))
    is_('neither valve closed', not elem(b, 'WA').get('closed') and not elem(b, 'WB').get('closed'))


def part4():
    print("4. CLOSING")
    w, okw, asw = assessed(HEAD + TWO)
    is_('without a valve, WB takes water in and the calculation is REJECTED',
        asw['validation']['acceptance'] == 'REJECTED' and errs(asw['validation']).get('SUPPLY_REVERSE'))

    n, ok, as_ = assessed(HEAD + TWO + "NRV WB 0\n")
    v = as_['validation']
    wb = elem(n, 'WB')
    is_('with a valve, WB closes', wb.get('closed') and wb.get('check_closed'))
    is_('the closed valve carries exactly nothing', num(wb.get('q')) == 0)
    is_('no reverse supply flow is reported', not errs(v).get('SUPPLY_REVERSE'))
    is_('the solve converges and settles', ok and n.get('outer_settled'))
    is_('the calculation is ACCEPTED: WA alone meets the sprinkler',
        v['acceptance'] == 'ACCEPTED', '%s: %s' % (v['acceptance'], lst(errs(v))))
    # Independent: the network with WB deleted.
    r, _ = solve(HEAD + ONLY_A)
    same = 1
    for id_ in ('WA', 'A1', 'J12', 'R1', 'S1'):
        if not near(elem(n, id_).get('q'), elem(r, id_).get('q'), 1e-9):
            same = 0
    is_('every flow equals the model with WB deleted', same)
    is_('every pressure equals the model with WB deleted',
        near(gauge(n, 'S1'), gauge(r, 'S1'), 1e-9) and near(gauge(n, 'J2'), gauge(r, 'J2'), 1e-9))
    # Closed is consistent: WB's pressure could not open it against J2.
    is_('closed state consistent: J2 is above what WB could give', gauge(n, 'J2') >= 520 - 1e-9, gauge(n, 'J2'))
    # A valve on the strong supply as well changes nothing more.
    n2, ok2, as2 = assessed(HEAD + TWO + "NRV WA 0\nNRV WB 0\n")
    is_('valves on both supplies: same answer, WA open, WB closed',
        not elem(n2, 'WA').get('closed') and elem(n2, 'WB').get('closed')
        and near(elem(n2, 'S1').get('q'), elem(n, 'S1').get('q'), 1e-9))


def part5():
    print("5. REOPENING")
    # Both supplies have valves here: raised, WB would otherwise push water
    # into WA, which is a supply taking water in, and REJECTED.
    n, ok = solve(HEAD + TWO + "NRV WA 0\nNRV WB 0\n")
    wb = elem(n, 'WB')
    is_('WB closed at 520 kPa', wb.get('closed'))
    # Raise WB well above the network at J2 and solve again from the closed state.
    wb['pstat'] = 2000
    ok2 = hardycross.solve_model(n)
    v = validate.validate(n, ok2)
    is_('raised to 2000 kPa, WB reopens', not wb.get('closed'))
    is_('reopened, WB delivers', num(wb.get('q')) > 1, wb.get('q'))
    is_('reopened, the solve is valid', v['acceptance'] == 'ACCEPTED' or v['acceptance'] == 'NONCOMPLIANT',
        v['acceptance'])
    # The same, from a fresh read: the same answer whichever state it began in.
    hi = TWO.replace('WATER WB 0 520', 'WATER WB 0 2000', 1)
    f, _ = solve(HEAD + hi + "NRV WA 0\nNRV WB 0\n")
    is_('the reopened answer equals a fresh solve', near(elem(f, 'WB').get('q'), wb.get('q'), 1e-6))

    # A valve that keeps changing state is not taken as settled.  The switch
    # count is set past its limit on a valve whose state is wrong, which is
    # what an oscillating valve reaches.
    m, _ = solve(HEAD + TWO + "NRV WA 0\nNRV WB 0\n")
    mb = elem(m, 'WB')
    mb['pstat'] = 2000
    mb['nflips'] = 99
    ok3 = hardycross.solve_model(m)
    v3 = validate.validate(m, ok3)
    is_('an unsettled valve: marked at its switch limit', mb.get('flip_limit'))
    is_('an unsettled valve: INDETERMINATE, not ACCEPTED', v3['acceptance'] == 'INDETERMINATE', v3['acceptance'])
    is_('an unsettled valve: SUPPLY_CHECK_UNRESOLVED', errs(v3).get('SUPPLY_CHECK_UNRESOLVED'), lst(errs(v3)))
    # A valve at its limit but already in the right state is settled.
    s, _ = solve(HEAD + TWO + "NRV WB 0\n")
    elem(s, 'WB')['nflips'] = 99
    ok4 = hardycross.solve_model(s)
    v4 = validate.validate(s, ok4)
    is_('a valve at its limit in the right state is settled',
        not errs(v4).get('SUPPLY_CHECK_UNRESOLVED') and v4['acceptance'] == 'ACCEPTED',
        '%s: %s' % (v4['acceptance'], lst(errs(v4))))


def part6():
    print("6. ISOLATION")
    # One supply at 50 kPa, the sprinkler 10 m above it (98 kPa of lift).
    LIFT = "WATER W 0 50\nNODE J1 0\nSPRINKLER S1 10 60 80\nPIPE A1 W J1 10 100\nPIPE R1 J1 S1 10 65\n"
    w, okw, asw = assessed(HEAD + LIFT)
    is_('without a valve: water runs backwards, REJECTED', asw['validation']['acceptance'] == 'REJECTED',
        asw['validation']['acceptance'])
    n, ok, as_ = assessed(HEAD + LIFT + "NRV W 0\n")
    v = as_['validation']
    e = errs(v)
    is_('with a valve: the valve closes', elem(n, 'W').get('closed'))
    is_('loss of supply is reported: SUPPLY_ISOLATED', e.get('SUPPLY_ISOLATED'), lst(e))
    is_('loss of supply is NONCOMPLIANT, not ACCEPTED', v['acceptance'] == 'NONCOMPLIANT',
        '%s: %s' % (v['acceptance'], lst(e)))
    is_('loss of supply is not a numerical failure', v['numerical']['status'] == 'PASS', v['numerical']['status'])
    is_('loss of supply is not a physical failure', v['physical']['status'] == 'PASS', lst(e))
    is_('no valve was held open to keep the network connected', not elem(n, 'W').get('isolating'))
    zero = 1
    for x in n['elems'][1:]:
        if not x.get('kind') or abs(num(x.get('q'))) > 0:
            zero = 0
    is_('every flow is zero: no water is manufactured', zero)
    is_('no pressure is reported at the isolated nodes',
        near(gauge(n, 'S1'), 0, 1e-9) and near(gauge(n, 'J1'), 0, 1e-9))
    si = n.get('supply_isolated')
    is_('the network records which nodes lost their supply',
        bool(si) and ','.join(sorted(si['nodes'])) == 'J1,S1,W',
        ','.join(sorted(si['nodes'])) if si else 'none')
    dm = as_['demand']
    is_('the demand search does not call the isolated supply a numerical failure',
        dflt(dm.get('status')) != 'UNRESOLVED' or not re.search(r'converge', dflt(dm.get('reason'))),
        dm.get('reason'))

    # Two separate networks, each with its own supply; only the second loses it.
    PART = ("WATER WA 0 600\nNODE A1N 0\nSPRINKLER SA 0 60 80\nPIPE PA WA A1N 10 100\nPIPE RA A1N SA 5 65\n"
            "WATER WB 0 50\nNODE B1N 0\nSPRINKLER SB 10 60 80\nPIPE PB WB B1N 10 100\nPIPE RB B1N SB 10 65\n")
    p, okp, asp = assessed(HEAD + PART + "NRV WA 0\nNRV WB 0\n")
    vp = asp['validation']
    is_('part isolated: WA stays open, WB closes', not elem(p, 'WA').get('closed') and elem(p, 'WB').get('closed'))
    is_('part isolated: SUPPLY_ISOLATED names the sprinkler that lost its supply',
        1 if [f for f in vp['findings']
              if f['code'] == 'SUPPLY_ISOLATED' and re.search(r'\bSB\b', dflt(f.get('item')))] else 0)
    is_('part isolated: NONCOMPLIANT', vp['acceptance'] == 'NONCOMPLIANT',
        '%s: %s' % (vp['acceptance'], lst(errs(vp))))
    sa, _ = solve(HEAD + "WATER WA 0 600\nNODE A1N 0\nSPRINKLER SA 0 60 80\nPIPE PA WA A1N 10 100\nPIPE RA A1N SA 5 65\n")
    is_('part isolated: the supplied part solves as it does on its own',
        near(elem(p, 'SA').get('q'), elem(sa, 'SA').get('q'), 1e-9) and near(gauge(p, 'SA'), gauge(sa, 'SA'), 1e-9))


def part7():
    print("7. CHANGING DEMAND")
    # WA strong and far, WB 520 kPa beside the outlet.  At a small demand the
    # network at J2 stands above 520 and WB stays shut; at a large one it falls
    # below and WB opens.
    def mk(k):
        t = TWO.replace('SPRINKLER S1 0 -100 80', 'SPRINKLER S1 0 -100 %s' % k, 1)
        return HEAD + t + "NRV WB 0\n"
    lo, _ = solve(mk(40))
    hi, okh = solve(mk(400))
    is_('small demand: WB shut', elem(lo, 'WB').get('closed'))
    is_('large demand: WB open and delivering', not elem(hi, 'WB').get('closed') and num(elem(hi, 'WB').get('q')) > 1,
        elem(hi, 'WB').get('q'))
    is_('large demand: J2 below WB, as an open valve needs', gauge(hi, 'J2') < 520)
    v = validate.validate(hi, okh)
    is_('large demand: valid', v['numerical']['status'] == 'PASS' and v['physical']['status'] == 'PASS',
        lst(errs(v)))


def part8():
    print("8. DEMAND SEARCHES")
    w, okw, asw = assessed(HEAD + TWO)
    jw = (asw.get('supplies') or {}).get('joint') or {}
    is_('without a valve the joint demand is UNRESOLVED (WB takes water in)',
        dflt(jw.get('status')) == 'UNRESOLVED', jw.get('status'))
    n, ok, as_ = assessed(HEAD + TWO + "NRV WB 0\n")
    sup = as_.get('supplies') or {}
    j = sup.get('joint') or {}
    is_('with a valve the joint demand is FOUND', dflt(j.get('status')) == 'FOUND', j.get('reason'))
    rb = next((x for x in (j.get('supplies') or []) if x['id'] == 'WB'), None)
    is_('joint demand: WB shut on its valve, no flow, not active',
        rb and num(rb.get('flow')) == 0 and not rb.get('active') and dflt(rb.get('status')) == 'CLOSED',
        rb.get('status') if rb else 'no row')
    is_('joint demand: the signed supplies balance the net demand', j.get('balance_pass'))
    cb = next((x for x in (sup.get('conditional') or []) if x['id'] == 'WB'), None)
    is_('conditional: WB NOT_REQUIRED (WA alone meets the outlet)', cb and cb['status'] == 'NOT_REQUIRED',
        '%s %s' % (cb['status'], dflt(cb.get('reason'))) if cb else 'none')
    ca = next((x for x in (sup.get('conditional') or []) if x['id'] == 'WA'), None)
    # WB at 520 kPa beside the sprinkler meets it alone, so WA is not needed:
    # found on valid trials.
    is_('conditional: WA NOT_REQUIRED (WB alone meets the outlet), on valid trials',
        ca and ca['status'] == 'NOT_REQUIRED' and not (ca.get('findings') or []),
        '%s %s' % (ca['status'], dflt(ca.get('reason'))) if ca else 'none')
    is_('demand assessment DEMONSTRATED', as_['validation']['demand_assessment']['status'] == 'DEMONSTRATED',
        as_['validation']['demand_assessment']['status'])
    is_('the whole calculation ACCEPTED', as_['validation']['acceptance'] == 'ACCEPTED',
        '%s: %s' % (as_['validation']['acceptance'], lst(errs(as_['validation']))))
    sc = list(sup.get('scenarios') or [])
    # (Worked out as in the Perl suite, though no check reads them.)
    wb_out = next((x for x in sc if re.search(r'WB', dflt(x.get('name')))
                   and re.search(r'OUT|WITHOUT', dflt(x.get('name')), re.I)), None)
    is_('scenarios run with the valve: no scenario REJECTED for reverse flow',
        not [x for x in sc if [f for f in (x.get('findings') or []) if f == 'SUPPLY_REVERSE']])
    wb_row = [r for x in sc if not [s for s in x['supplies'] if s['status'] == 'OUT_OF_SERVICE']
              for r in x['supplies'] if r['id'] == 'WB']
    del wb_out, wb_row
    is_('scenarios: a supply shut on its valve is reported CLOSED, not REVERSE',
        not [s for x in sc for s in x['supplies'] if s['status'] == 'REVERSE'])

    # A single supply with a valve: its demand point is found as without one.
    ONE = "WATER W 0 900\nNODE J 0\nSPRINKLER S1 0 -50 80\nPIPE P1 W J 100 100\nPIPE P2 J S1 5 50\n"
    a1, o1, s1 = assessed(HEAD + ONE)
    b1, o2, s2 = assessed(HEAD + ONE + "NRV W 0\n")
    is_('one supply: demand point unchanged by a lossless valve',
        near(s1['demand'].get('p_demand'), s2['demand'].get('p_demand'), 1e-9),
        '%s vs %s' % (s1['demand'].get('p_demand'), s2['demand'].get('p_demand')))
    # With a loss the supply needs more pressure, by the valve's loss at the demand flow.
    c1, o3, s3 = assessed(HEAD + ONE + "NRV W 300 10\n")
    q = s3['demand']['q_system']
    loss = 10 + 6.894757 * (q / 3.785411784 / 300) ** 2
    is_('one supply: a valve with a loss raises the demand by that loss (within the 0.01 kPa search)',
        near(s3['demand']['p_demand'] - s1['demand']['p_demand'], loss, 0.05),
        '%.3f vs %.3f' % (s3['demand']['p_demand'] - s1['demand']['p_demand'], loss))


def part9():
    print("9. THE VALVE'S LOSS")
    # Both deliver (WB 900); WB's valve has Cv 300 and opens at 10 kPa.  Its
    # loss is the data-sheet definition dP psi = (Q gpm / Cv)^2, plus the
    # opening pressure, worked here from the solved flow.
    both = TWO.replace('WATER WB 0 520', 'WATER WB 0 900', 1)
    n, ok = solve(HEAD + both + "NRV WB 300 10\n")
    wb = elem(n, 'WB')
    q = wb['q']
    want = 10 + 6.894757 * (q / 3.785411784 / 300) ** 2
    got = 900 - gauge(n, 'WB')
    # To the loop tolerance: WB's node is reached through the spanning tree,
    # and a chord closes its loop to TOL_LOOP (0.01 kPa), not to round-off.
    is_('open valve: supply pressure less node pressure = opening + Cv loss', near(got, want, 0.01),
        '%.6f vs %.6f at %.3f L/min' % (got, want, q))
    v = validate.validate(n, ok)
    is_('open valve with a loss: valid', v['numerical']['status'] == 'PASS' and v['physical']['status'] == 'PASS',
        lst(errs(v)))

    # An opening pressure larger than the supply's advantage keeps it shut.
    # WB 520 against J2: with WA at 1000 and the outlet at K 400, WB opens with
    # no opening pressure; at 300 kPa opening pressure it cannot.
    t = TWO.replace('SPRINKLER S1 0 -100 80', 'SPRINKLER S1 0 -100 400', 1)
    o, _ = solve(HEAD + t + "NRV WB 0\n")
    c, okc = solve(HEAD + t + "NRV WB 0 300\n")
    is_('no opening pressure: WB opens at the large demand', not elem(o, 'WB').get('closed'))
    is_('300 kPa opening pressure: WB stays shut', elem(c, 'WB').get('closed'))
    is_('shut on its opening pressure: consistent (520 - J2 below 300)', 520 - gauge(c, 'J2') <= 300 + 1e-6,
        520 - gauge(c, 'J2'))
    vc = validate.validate(c, okc)
    is_('shut on its opening pressure: no unresolved valve', not errs(vc).get('SUPPLY_CHECK_UNRESOLVED'),
        lst(errs(vc)))


def part10():
    print("10. REPORTING")
    text = HEAD + TWO + "NRV WB 300 7\nNRVMODEL WB ACME 100 SWING\n"
    n, ok = solve(text)
    j = json.loads(jsonout.encode(jsonout.results(n, ok, "m.phc")))
    cv = {x['supply']: x for x in (j.get('supply_check_valves') or [])}
    is_('JSON: every supply listed under supply_check_valves', cv.get('WA') and cv.get('WB'))
    is_('JSON: WA has no valve', cv.get('WA') and not cv['WA'].get('installed') and cv['WA'].get('state') == 'NONE')
    is_('JSON: WB valve installed, CLOSED, no flow',
        cv.get('WB') and cv['WB'].get('installed') and cv['WB'].get('state') == 'CLOSED'
        and num(cv['WB'].get('flow')) == 0)
    is_('JSON: WB Cv, opening pressure, make and model',
        cv.get('WB') and num(cv['WB'].get('cv')) == 300 and num(cv['WB'].get('opening_pressure')) == 7
        and cv['WB'].get('model') == 'ACME 100 SWING')
    is_('JSON: acceptance ACCEPTED', j['acceptance'] == 'ACCEPTED', j['acceptance'])
    r = report.write_report(n, ok, "m.phc")
    is_('report: lists the supply check valves', re.search(r'SUPPLY CHECK VALVES', r))
    is_('report: WB shown CLOSED with its make and model',
        re.search(r'WB\s.*CLOSED', r) and re.search(r'ACME 100 SWING', r))
    is_('report: acceptance agrees with the JSON', re.search(r'ACCEPTED - numerically valid', r))

    m, okm = solve(HEAD + "WATER W 0 50\nNODE J1 0\nSPRINKLER S1 10 60 80\nPIPE A1 W J1 10 100\n"
                   + "PIPE R1 J1 S1 10 65\nNRV W 0\n")
    jm = json.loads(jsonout.encode(jsonout.results(m, okm, "m.phc")))
    rows = jm['supply_check_valves']
    w = rows[0] if rows else None
    is_('JSON: an isolated supply is ISOLATED', w and w.get('state') == 'ISOLATED', w.get('state') if w else 'none')
    is_('JSON: isolated: NONCOMPLIANT and not approved', jm['acceptance'] == 'NONCOMPLIANT' and not jm.get('approved'))
    rm = report.write_report(m, okm, "m.phc")
    is_('report: an isolated supply says LOSS OF SUPPLY', re.search(r'LOSS OF SUPPLY', rm))


def part11():
    print("11. EQUIVALENT DESCRIPTIONS")
    base = HEAD + TWO + "NRV WB 300 7\n"
    b, _ = solve(base)
    ref = {i: elem(b, i)['q'] for i in ('WA', 'WB', 'A1', 'J12', 'R1', 'S1')}

    def cmp(name, text, map_, flip=None):
        flip = flip or {}
        n, ok = solve(text)
        same = 1 if ok else 0
        for id_ in ref:
            e = elem(n, map_.get(id_, id_))
            if not e:
                same = 0
                continue
            q = -e['q'] if flip.get(id_) else e['q']
            if not near(q, ref[id_], 1e-6 * (1 + abs(ref[id_]))):
                same = 0
        is_(name, same)
    # Nodes renamed.
    ren = re.sub(r'\bJ1\b', 'X9', base)
    ren = re.sub(r'\bJ2\b', 'AA', ren)
    cmp('nodes renamed: same flows', ren, {})
    # Lines in another order.
    l = TWO.rstrip('\n').split('\n')
    cmp('lines reordered: same flows', HEAD + '\n'.join(reversed(l)) + "\nNRV WB 300 7\n", {})
    # A pipe drawn the other way: its flow changes sign, nothing else.
    rev = base.replace('PIPE J12 J1 J2 5 100', 'PIPE J12 J2 J1 5 100', 1)
    cmp('a pipe drawn the other way: same flows, that one negated', rev, {}, {'J12': 1})
    # Pressures in bar and flows in m3/h: the same water.
    si = base.replace('UNITS PRESSURE KPA', 'UNITS PRESSURE BAR', 1)
    si = si.replace('WATER WA 0 1000', 'WATER WA 0 10', 1)
    si = si.replace('WATER WB 0 520', 'WATER WB 0 5.2', 1)
    si = si.replace('NRV WB 300 7', 'NRV WB 300 0.07', 1)
    # K 80 L/min/kPa^0.5 x sqrt(100 kPa/bar) = K 800 L/min/bar^0.5
    si = si.replace('SPRINKLER S1 0 -100 80', 'SPRINKLER S1 0 -1 800', 1)
    si = si.replace('UNITS KFACTOR LPM/KPA', 'UNITS KFACTOR LPM/BAR', 1)
    sn, sok = solve(si)
    wbq = elem(sn, 'WB')['q'] if elem(sn, 'WB') else None
    is_('pressures in bar: the same state (WB shut) and the same outlet flow',
        elem(sn, 'WB') and elem(sn, 'WB').get('closed') and near(elem(sn, 'S1')['q'], ref['S1'], 1e-6 * ref['S1']),
        wbq if wbq is not None else 'no WB')


def main():
    part1()
    part2()
    part3()
    part4()
    part5()
    part6()
    part7()
    part8()
    part9()
    part10()
    part11()
    print('\n%d passed, %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
