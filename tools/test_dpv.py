#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_dpv.py -- the dry pipe valve, DPV.  Python port of test_dpv.pl, check
# for check.
#
#   python3 tools/test_dpv.py
#
#   1. THE LANGUAGE.  RATIO and TRIP, ON and OFF, the loss as points, one
#      fixed loss, or EQL and a length; DPVMODEL and DPVAIR; and every bad
#      line refused on its line.
#   2. THE HYDRAULICS, BY HAND.  The loss across the valve against the
#      Hazen-Williams formula for its equivalent length, worked here without
#      the engine; against its loss points; and a fixed loss.  The trip
#      setting and the accelerator change no number.
#   3. VALIDATION.  No loss data, water backwards through the valve, an
#      unusual trip ratio, an unlikely trip pressure.
#   4. THE OUTPUT.  Section 13 of the report and the JSON: the configuration,
#      the steady-state flow and loss, and no delivery time - which is not
#      calculated and is never implied.
#
# The valve is solved tripped and fully open.  Nothing here tests a trip or
# delivery time: there is no transient calculation to test.
#==============================================================================
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import jsonout, phc, report, validate

GW = hardycross.GAMMA_W
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


def pn(x):
    # Perl's numeric value of a field, for the Perl suite's == comparisons
    # (a field may hold the number as the text written).
    if x is None:
        return 0
    return float(x) if isinstance(x, str) else x


def perl_split_lines(text):
    # Perl's split /\n/: trailing empty fields are dropped.
    parts = text.split('\n')
    while parts and parts[-1] == '':
        parts.pop()
    return parts


def model(dpv, pres=None, water=None, more=None):
    return '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM',
                      'UNITS PRESSURE ' + (pres if pres is not None else 'KPA'),
                      'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', 'METHOD HW',
                      'USE BORE 120',
                      water if water is not None else 'WATER W 0 700 2000 500',
                      'NODE A 0', 'SPRINKLER S1 3 -100 80', 'SPRINKLER S2 3 -100 80',
                      'PIPE P12 W A 10 100', dpv] + list(more or [])
                     + ['PIPE P2 A S1 5 50', 'PIPE P3 A S2 8 50', ''])


def solve(text):
    net = phc.read_string(text)
    ok = hardycross.solve_model(net)
    return net, ok, validate.validate(net, ok)


def dpv(n):
    return next((e for e in n['elems'][1:] if e['kind'] == 'DPV'), None)


def refused(text):
    try:
        phc.read_string(text)
        return ''
    except Exception as e:      # any error, as the Perl's eval catches any die
        return e.msg if hardycross.is_model_error(e) else str(e)


def loss(n, e):
    return n['nodes'][e['n1']]['h'] - n['nodes'][e['n2']]['h']


def codes(v):
    c = {}
    for f in v['findings']:
        c[f['code']] = f['severity']
    return c


def truth(x):
    # Perl truth of a JSON value: JSON::PP's false is false.
    if isinstance(x, jsonout._Bool):
        return x.v
    return bool(x)


def dflt(x):
    return '' if x is None else x


def part1():
    print("1. THE LANGUAGE")
    n, _, _ = solve(model('DPV P12 100 RATIO 5.5:1 ON 1000 15 3000 40',
                          more=['DPVMODEL P12 MAKER X MODEL 100', 'DPVAIR P12 280']))
    e = dpv(n)
    is_('RATIO 5.5:1 ON with loss points: read', e and e.get('trip_mode') == 'RATIO' and pn(e.get('trip_ratio')) == 5.5
        and e.get('accelerator') == 'ON' and e.get('loss') == 'CURVE' and pn(e.get('size')) == 100)
    is_('   the valve is P12.DPV, in pipe P12', e['id'] == 'P12.DPV' and e.get('host_id') == 'P12')
    is_('   DPVMODEL kept as typed', dflt(e.get('model')) == 'MAKER X MODEL 100')
    tr = e.get('transient') or {}
    is_('   DPVAIR kept for the transient model, in kPa', near(tr.get('air_initial'), 280, 1e-9))
    is_('   the transient record reserves every field, delivery time undefined',
        tr.get('state') == 'TRIPPED_OPEN' and tr.get('delivery_time') is None
        and 'dry_volume' in tr and 'venting' in tr
        and ' '.join(tr['states']) == 'SET PRESSURE_DECAY TRIPPED FILLING WATER_DELIVERY')

    n, _, _ = solve(model('DPV P12 100 TRIP 1.4 OFF EQL 6.1', pres='BAR', water='WATER W 0 7 2000 5'))
    e = dpv(n)
    is_('TRIP 1.4 in bar is 140 kPa; accelerator OFF; EQL', near(e.get('trip_pressure'), 140, 1e-9)
        and e.get('accelerator') == 'OFF' and e.get('loss') == 'EQL' and near(e.get('eql'), 6.1, 1e-12))

    t = model('DPV P12 4 RATIO 6 ON 0 20').replace('UNITS SIZE MM', 'UNITS SIZE IN', 1)
    t = re.sub(r'PIPE (\S+) (\S+) (\S+) (\S+) (\d+)',
               lambda m: 'PIPE %s %s %s %s ' % m.group(1, 2, 3, 4) + '%.15g' % (int(m.group(5)) / 25), t)
    n, _, _ = solve(t)
    e = dpv(n)
    is_('a size in inches: 4 is DN100; one pair at flow 0 is a fixed loss',
        e and pn(e.get('size')) == 100 and near(e.get('fixed_loss'), 20, 1e-9))

    for line, want in (['DPV P12 100 RATIO 1 ON', 'MORE THAN 1:1'],
                       ['DPV P12 100 RATIO X ON', 'IS NOT A RATIO'],
                       ['DPV P12 100 TRIP 0 ON', 'MORE THAN 0'],
                       ['DPV P12 100 PRESSURE 140 ON', 'RATIO .* OR TRIP'],
                       ['DPV P12 100 RATIO 5.5 MAYBE', 'ON OR OFF'],
                       ['DPV P12 100 RATIO 5.5 ON EQL', 'NEEDS THE EQUIVALENT LENGTH'],
                       ['DPV P12 100 RATIO 5.5 ON EQL 0', 'MORE THAN 0'],
                       ['DPV P12 100 RATIO 5.5 ON 1000', 'NEEDS THE LOSS TO PAIR'],
                       ['DPV P12 100 RATIO 5.5 ON 100 5', 'ITS FLOW MUST BE 0'],
                       ['DPV P12 100 RATIO 5.5 ON 0 5 X', 'IS NOT A NUMBER']):
        e = refused(model(line))
        is_('refused: %s' % line, re.search(want, e), e)

    e = refused(model('BFP P12 0 10', more=['DPVMODEL P12 X']))
    is_('refused: DPVMODEL on a pipe with no dry pipe valve', re.search(r'HAS NO DRY PIPE VALVE', e), e)
    e = refused(model('DPV P12 100 RATIO 5.5 ON EQL 6', more=['BFP P12 0 10']))
    is_('refused: a second device in the same pipe', re.search(r'ALREADY HAS A DEVICE', e), e)


def part2():
    print("2. THE HYDRAULICS, BY HAND")
    # Hazen-Williams, AS 2118.1 metric form: p = 6.05e7 L Q^1.85 / (C^1.85 d^4.87)
    # kPa, Q in L/min, d in mm.  The valve's 6.1 m of 100 mm pipe at C 120.
    n, ok, v = solve(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1'))
    e = dpv(n)
    hand = 6.05e7 * 6.1 * e['q'] ** 1.85 / (120 ** 1.85 * 100 ** 4.87)
    is_('EQL: the loss across the valve is the HW loss of 6.1 m (%.4f against %.4f kPa)' % (loss(n, e), hand),
        ok and near(loss(n, e), hand, 1e-6))
    is_('   ACCEPTED (%s), the DPV checks pass' % v['acceptance'], v['acceptance'] == 'ACCEPTED'
        and not [f for f in v['findings'] if re.search(r'^DPV', f['code']) and f['severity'] == 'error'])

    # Loss points 1000 L/min at 15 kPa and 3000 at 40, straight in Q^1.85
    # between them, as every curve in PHCP is read.
    n, ok, _ = solve(model('DPV P12 100 RATIO 5.5:1 ON 1000 15 3000 40'))
    e = dpv(n)
    x = (e['q'] ** 1.85 - 1000 ** 1.85) / (3000 ** 1.85 - 1000 ** 1.85)
    hand = 15 + 25 * x
    is_('CURVE: the loss is read off its points (%.4f against %.4f kPa)' % (loss(n, e), hand),
        ok and e['q'] > 1000 and e['q'] < 3000 and near(loss(n, e), hand, 1e-6))

    n, ok, _ = solve(model('DPV P12 100 RATIO 5.5:1 ON 0 20'))
    e = dpv(n)
    is_('a fixed loss of 20 kPa (%.4f)' % loss(n, e), ok and near(loss(n, e), 20, 1e-6))

    a, _, _ = solve(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1'))
    b, _, _ = solve(model('DPV P12 100 RATIO 6:1 OFF EQL 6.1'))
    c, _, _ = solve(model('DPV P12 100 TRIP 140 ON EQL 6.1'))
    is_('the trip setting and the accelerator change no flow',
        near(dpv(a)['q'], dpv(b)['q'], 1e-9) and near(dpv(a)['q'], dpv(c)['q'], 1e-9))
    t = model('DPV P12 100 RATIO 5.5 ON EQL 6.1').replace('PIPE P12 W A 10 100', 'PIPE P12 W A 16.1 100', 1)
    p, _, _ = solve('\n'.join(l for l in perl_split_lines(t) if not re.search(r'^DPV', l)))
    q12 = next((x for x in p['elems'][1:] if x.get('id') == 'P12'), None)
    is_('   EQL 6.1 m solves as the same pipe 6.1 m longer', near(dpv(a)['q'], q12['q'], 1e-4),
        '%s %s' % (dpv(a)['q'], q12['q']))


def part3():
    print("3. VALIDATION")
    n, ok, v = solve(model('DPV P12 100 RATIO 5.5:1 ON'))
    is_('no loss data: REJECTED, DPV_NO_LOSS_DATA (no loss is assumed)',
        v['acceptance'] == 'REJECTED' and codes(v).get('DPV_NO_LOSS_DATA'), v['acceptance'])
    n, ok, v = solve(model('DPV P12 100 RATIO 12:1 ON EQL 6.1'))
    is_('a ratio of 12:1: a warning to check it, not a failure',
        dflt(codes(v).get('DPV_RATIO_RANGE')) == 'warning' and v['acceptance'] == 'ACCEPTED', v['acceptance'])
    n, ok, v = solve(model('DPV P12 100 TRIP 900 ON EQL 6.1'))
    is_('an air trip pressure of 900 kPa: REJECTED, DPV_TRIP_PRESSURE',
        v['acceptance'] == 'REJECTED' and codes(v).get('DPV_TRIP_PRESSURE'), v['acceptance'])
    n, ok, v = solve(model('DPV P12 15 RATIO 5.5 ON EQL 6.1'))
    is_('DN15 is not a dry pipe valve: REJECTED, DPV_SIZE', v['acceptance'] == 'REJECTED' and codes(v).get('DPV_SIZE'))
    # A stronger supply downstream drives water back through the valve.
    n, ok, v = solve(model('DPV P12 100 RATIO 5.5 ON EQL 6.1', more=['WATER W2 0 900', 'PIPE P9 W2 A 5 100']))
    is_('water backwards through the valve: REJECTED, DPV_REVERSE',
        dpv(n)['q'] < 0 and v['acceptance'] == 'REJECTED' and codes(v).get('DPV_REVERSE'), dpv(n)['q'])


def part3a():
    print("3a. VALVES FROM THE DATABASE")
    # Each against a figure printed on its data sheet: the loss at a flow.
    for mk, md, dn, gpm, psi, src in (['TYCO', 'DPV-1', 100, 600, 1.25, 'TFP1020 Graph A'],
                                      ['VIKING', 'VXR', 100, 1000, 7.59, 'chart F_110325'],
                                      ['VIKING', 'F-1', 150, 1750, 4.85, 'chart F_061909'],
                                      ['VIKING', 'VXR', 65, 400, 7.92, 'chart F_110525']):
        n, _, _ = solve(model('DPV P12 %s RATIO 6 ON VALVE %s %s' % (dn, mk, md), water='WATER W 0 1000'))
        e = dpv(n)
        hf = hardycross.elem_hf(e, gpm * 3.785411784, n['opts'])[0]
        is_('%s %s DN%d: %.3f psi at %d gpm against %.2f printed (%s)' % (mk, md, dn, hf / 6.894757, gpm, psi, src),
            abs(hf / 6.894757 - psi) <= 0.01 * psi + 0.005)
    n, ok, v = solve(model('DPV P12 100 RATIO 5.5 ON VALVE TYCO DPV-1'))
    is_('TYCO DPV-1 DN100 in a model: %s, its loss across the valve' % v['acceptance'],
        v['acceptance'] == 'ACCEPTED'
        and near(loss(n, dpv(n)), hardycross.elem_hf(dpv(n), dpv(n)['q'], n['opts'])[0], 1e-9))
    v = solve(model('DPV P12 80 RATIO 5.5 ON VALVE TYCO DPV-1'))[2]
    is_("TYCO DPV-1 DN80: the data sheet's own conflict is a warning (DPV_DATA_NOTE)",
        dflt(codes(v).get('DPV_DATA_NOTE')) == 'warning')
    v = solve(model('DPV P12 100 RATIO 5.5 ON VALVE RELIABLE DDX-LP'))[2]
    is_('a low-pressure valve given a ratio: a warning (DPV_RATIO_DB)', dflt(codes(v).get('DPV_RATIO_DB')) == 'warning')
    v = solve(model('DPV P12 100 RATIO 3 ON VALVE VIKING F-1'))[2]
    is_("a ratio far from the data sheet's: a warning (DPV_RATIO_DB)", dflt(codes(v).get('DPV_RATIO_DB')) == 'warning')
    v = solve(model('DPV P12 100 RATIO 6 ON VALVE RELIABLE D'))[2]
    is_('a legacy valve: a warning (DPV_LEGACY)', dflt(codes(v).get('DPV_LEGACY')) == 'warning')
    v = solve(model('DPV P12 100 RATIO 6 ON VALVE VIKING F-1', water='WATER W 0 1600'))[2]
    is_('above its rated working pressure (175 psi): REJECTED, DPV_PRESSURE_RATING',
        v['acceptance'] == 'REJECTED' and dflt(codes(v).get('DPV_PRESSURE_RATING')) == 'error', v['acceptance'])

    # Victaulic: a flow coefficient, dP psi = (Q gpm / Cv)^2, Cv 350 for
    # the 768N DN100 (31.80).
    nv, kv, vv = solve(model('DPV P12 100 RATIO 6 ON VALVE VICTAULIC 768N'))
    gpm = dpv(nv)['q'] / 3.785411784
    is_('VICTAULIC 768N DN100: the loss is (Q/Cv)^2 at its flow (%.4f kPa)' % loss(nv, dpv(nv)),
        near(loss(nv, dpv(nv)), (gpm / 350) ** 2 * 6.894757, 1e-6))
    rv = report.write_report(nv, kv, 'v.phc')
    is_('   the report gives the Cv and its source',
        re.search(r'flow\s+coefficient Cv 350', rv) and re.search(r'31\.80', rv))
    # The 756's sheet gives no usable loss.  It used to be refused at
    # reading; it now reads as DATA_REQUIRED and the calculation is
    # REJECTED with the reason (test_acceptance.pl, part 7).
    n756 = phc.read_string(model('DPV P12 100 RATIO 6 ON VALVE VICTAULIC 756'))
    k756 = hardycross.solve_model(n756)
    v756 = validate.validate(n756, k756)
    f756 = next((f for f in v756['findings'] if f['code'] == 'DPV_NO_LOSS_DATA'), None)
    is_('the 756, whose sheet gives no usable loss: DATA_REQUIRED and REJECTED, with the reason',
        v756['acceptance'] == 'REJECTED' and f756
        and re.search(r'DATA_REQUIRED.*no usable pressure loss.*no Cv', f756['message'], re.I),
        f756['message'] if f756 else 'no finding')
    e = refused(model('DPV P12 100 RATIO 6 ON VALVE ACME X1'))
    is_('refused: a valve not in the database, the ones that are listed',
        re.search(r'IS NOT A DRY PIPE VALVE IN THE DATABASE \(.*TYCO DPV-1', e), e)
    e = refused(model('DPV P12 200 RATIO 6 ON VALVE VIKING F-1'))
    is_('refused: a size the valve does not come in, the sizes it does',
        re.search(r'IN DN80, DN100, DN150 ONLY, NOT DN200', e), e)
    net = phc.read_string(model('DPV P12 100 RATIO 5.5 ON VALVE TYCO DPV-1'))
    k = hardycross.solve_model(net)
    rep = report.write_report(net, k, 'dpv.phc')
    is_('the report names the database valve, its basis and its source',
        re.search(r'the pipe and fitting database: TYCO DPV-1 DN100, 8\.9 ft of Schedule 40 pipe', rep)
        and re.search(r'TFP1020', rep))


def part4():
    print("4. THE OUTPUT")
    net = phc.read_string(model('DPV P12 100 RATIO 5.5:1 ON EQL 6.1', more=['DPVMODEL P12 MAKER X']))
    ok = hardycross.solve_model(net)
    rep = report.write_report(net, ok, 'dpv.phc')
    is_('the report has Section 13, DRY PIPE VALVES', re.search(r'13\. DRY PIPE VALVES', rep))
    is_('   the trip, the accelerator, the model and the loss basis',
        re.search(r'differential ratio 5\.50:1', rep) and re.search(r'Accelerator\s+ON', rep)
        and re.search(r'MAKER X', rep) and re.search(r'equivalent length 6\.10 m of pipe P12', rep))
    words = r'\s+'.join(re.escape(w) for w in
                        'The trip, transit and delivery times given below are ESTIMATES'.split())
    is_('   and says no delivery time is calculated', re.search(words, rep))
    j = jsonout.results(net, ok, 'dpv.phc', demand=0)
    d = (j.get('dry_pipe_valves') or [None])[0]
    hf = hardycross.elem_hf(dpv(net), dpv(net)['q'], net['opts'])[0]
    is_('the JSON lists the valve: ratio, accelerator, flow and loss',
        d and d.get('trip_method') == 'RATIO' and pn(d.get('trip_ratio')) == 5.5 and d.get('accelerator') == 'ON'
        and near(d.get('flow'), dpv(net)['q'], 1e-3) and near(d.get('loss'), hf, 1e-3)
        and d.get('validation') == 'PASS')
    is_('   delivery time null, and marked not calculated', d.get('delivery_time') is None
        and not truth(d.get('delivery_time_calculated')))
    is_('   the steady-state assumption is in the traceability',
        len([x for x in j['traceability']['assumptions'] if re.search(r'dry pipe valve tripped and fully open', x)]))


def main():
    part1()
    part2()
    part3()
    part3a()
    part4()
    print('\n%d passed, %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
