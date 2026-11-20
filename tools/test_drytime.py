#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_drytime.py -- the ESTIMATED trip and transit times
# (hardycross.drytime).  A port of tools/test_drytime.pl.
#
#   python3 tools/test_drytime.py
#
#   1. THE FORMULA.  t = 0.0352 V / (An sqrt T0) ln(pa0/pa) against the
#      worked example of the ASPE Pipeline article it is taken from, and its
#      constant against the isothermal choked blow-down it comes from, worked
#      here from the properties of air.
#   2. A MODEL, BY HAND.  The dry volume, the trip pressure (from the ratio,
#      from TRIP, from a given static), the trip time, the path time (sum of
#      L / v), the fill time (volume / flow) and the delivery estimate, each
#      worked again here from the solved network.
#   3. WHAT IT DOES NOT DO.  It changes no flow and no acceptance; it is not
#      worked without its inputs; a valve that cannot be set is rejected; a
#      dry part reaching a supply is refused; a trip below choked flow and an
#      accelerator are flagged.
#   4. THE LANGUAGE AND THE OUTPUT.  DPVTRIP refused when wrong; the report,
#      the JSON and the results block give the same times.
#
# These are estimates.  The tests check the arithmetic and the method as
# stated; they say nothing about how close an estimate is to a real system.
#==============================================================================

import math
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, drytime, validate, report, jsonout, results

PASS = [0]
FAIL = [0]
PI = 3.14159265358979


def is_(name, ok, why=None):
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


def near(a, b, t):
    return a is not None and b is not None and abs(float(a) - float(b)) <= t


# model -- the test model; a keyword given as None leaves its line out, as
# an explicit undef does in the Perl, and one not given keeps the default.
_DEF = object()


def model(water=None, dpv=None, air=_DEF, trip=_DEF, more=None):
    lines = ['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA', 'UNITS FLOW LPM',
             'UNITS KFACTOR LPM/KPA', 'METHOD HW', 'USE BORE 120',
             water if water is not None else 'WATER W 0 700 2000 500', 'NODE A 0', 'NODE B 3',
             'SPRINKLER S1 3 -100 80', 'SPRINKLER S2 3 -100 80',
             'PIPE P12 W A 10 100', dpv if dpv is not None else 'DPV P12 100 RATIO 5.5:1 ON VALVE TYCO DPV-1']
    if air is _DEF:
        lines.append('DPVAIR P12 280')
    elif air is not None:
        lines.append(air)
    if trip is _DEF:
        lines.append('DPVTRIP P12 12.7 1 5')
    elif trip is not None:
        lines.append(trip)
    lines += ['PIPE PM A B 60 80', 'PIPE P2 B S1 5 50', 'PIPE P3 B S2 12 50'] + list(more or []) + ['']
    return '\n'.join(lines)


def solved(text):
    net = phc.read_string(text)
    ok = hardycross.solve_model(net)
    as_ = validate.assess(net, ok)
    return net, ok, as_


def elem(n, id_):
    for e in n['elems'][1:]:
        if e['id'] == id_:
            return e
    return None


def codes(v):
    return {f['code']: f['severity'] for f in v['findings']}


def refused(t):
    try:
        phc.read_string(t)
    except Exception as e:
        m = getattr(e, 'msg', None)
        return m if m is not None else str(e)
    return ''


def pn(x):
    if x is None:
        return ''
    if isinstance(x, float):
        return '%.15g' % x
    return str(x)


def main():
    #==========================================================================
    print('1. THE FORMULA')
    #==========================================================================
    # ASPE Pipeline, 19 August 2026: 800 gal, a 0.5 in. orifice, 11 F (the
    # article takes 471 R), 48.34 psia to 28.34 psia; the article gives
    # 67.94 s.
    v = 800 * 0.13368
    an = PI * (0.5 / 12) ** 2 / 4
    t = drytime.trip_time(v, an, 471, 48.34, 28.34)
    is_('the article\'s worked example: %.2f s against its 67.94 s' % t, near(t, 67.94, 0.1))
    # The constant, from an isothermal blow-down of an ideal gas through a
    # choked orifice of discharge coefficient 1: air, gamma 1.4, R 1716 ft
    # lbf/(slug R).
    g, r = 1.4, 1716
    c = 1 / (math.sqrt(g * r) * (2 / (g + 1)) ** ((g + 1) / (2 * (g - 1))))
    is_('the constant 0.0352 is the choked isothermal blow-down of air (%.5f)' % c, abs(c / 0.0352 - 1) < 0.005)
    # The same in SI: R 287.05 J/(kg K), V m3, A m2, T K.
    csi = 1 / (math.sqrt(g * 287.05) * (2 / (g + 1)) ** ((g + 1) / (2 * (g - 1))))
    tsi = csi * (v * 0.028316846592) / (an * 0.09290304 * math.sqrt(471 / 1.8)) * math.log(48.34 / 28.34)
    is_('   and worked in SI it gives the same time (%.2f s)' % tsi, abs(tsi / t - 1) < 0.005)

    #==========================================================================
    print('2. A MODEL, BY HAND')
    #==========================================================================
    net, ok, as_ = solved(model())
    d = as_['dry'][0]
    vol = 0
    for id_ in ('P12', 'PM', 'P2', 'P3'):
        vol += PI / 4 * (elem(net, id_)['dia'] / 1000) ** 2 * elem(net, id_)['len']
    is_('the dry volume is the four pipes downstream of the valve (%.4f m3)' % vol, near(d['volume'], vol, 1e-9))
    is_('   and not the pipe or supply upstream of it', d['pipes'] == 4)
    t = d['trip']
    is_('the trip pressure is the 700 kPa static / 5.5 (%.2f kPa)' % t['trip_gauge'],
        near(t['trip_gauge'], 700 / 5.5, 1e-9))
    hand = (0.0352 * (vol / 0.028316846592) / (PI / 4 * (12.7 / 25.4 / 12) ** 2 * math.sqrt((5 + 273.15) * 1.8))
            * math.log((280 + 101.325) / (700 / 5.5 + 101.325)))
    is_('the trip time, by hand from those (%.3f s)' % hand, near(t['seconds'], hand, 1e-6), pn(t['seconds']))
    is_('   it is an ESTIMATE, choked, the accelerator flagged', t['status'] == 'ESTIMATE' and t.get('choked')
        and t.get('accelerator_ignored'))

    # The transit, at the demand point's flows.
    x = d['transit']
    fn = as_['demand'].get('net')
    is_('   the transit is at the demand point\'s flows (%s)' % x['basis'], x['basis'] == 'demand point' and fn)
    tp = 0
    for id_ in ('P12', 'PM', 'P3'):
        e = elem(fn, id_)
        tp += e['len'] / abs(hardycross.pipe_velocity(e['q'], e['dia']))
    is_('the path P12 PM P3 to S2, sum of L / v by hand (%.3f s)' % tp,
        ' '.join(x['path_pipes']) == 'P12 PM P3' and x['remote'] == 'S2' and near(x['path_seconds'], tp, 1e-9))
    fill = vol / (elem(fn, 'P12.DPV')['q'] / 60000)
    is_('the fill time, volume / the valve flow by hand (%.3f s)' % fill, near(x['fill_seconds'], fill, 1e-9))
    tr = tp if tp > fill else fill
    is_('the transit is the larger, the delivery trip + transit',
        near(x['seconds'], tr, 1e-9) and near(d['delivery'], t['seconds'] + tr, 1e-9))

    _, _, a2 = solved(model(dpv='DPV P12 100 TRIP 140 ON VALVE TYCO DPV-1'))
    is_('TRIP 140: the trip pressure is the setting, 140 kPa', near(a2['dry'][0]['trip']['trip_gauge'], 140, 1e-9))
    _, _, a2 = solved(model(trip='DPVTRIP P12 12.7 2 5 600'))
    is_('a static of 600 given, two heads open: 600 / 5.5, twice the area',
        near(a2['dry'][0]['trip']['trip_gauge'], 600 / 5.5, 1e-9)
        and near(a2['dry'][0]['trip']['area'], d['trip']['area'] * 2, 1e-12)
        and a2['dry'][0]['trip'].get('static_given'))

    #==========================================================================
    print('3. WHAT IT DOES NOT DO')
    #==========================================================================
    n2, k2, a2 = solved(model(air=None, trip=None))
    same = not any(abs(elem(n2, e['id'])['q'] - e['q']) > 1e-9
                   for e in net['elems'][1:] if e['kind'] == 'PIPE')
    is_('without DPVAIR and DPVTRIP: every flow the same, the same acceptance',
        same and a2['validation']['acceptance'] == as_['validation']['acceptance'], a2['validation']['acceptance'])
    is_('   and no trip time, saying what it needs', a2['dry'][0]['trip']['status'] == 'NOT_CALCULATED'
        and re.search(r'DPVAIR.*DPVTRIP', a2['dry'][0]['trip']['reason']))
    is_('   the transit is still estimated: it needs no air data', a2['dry'][0]['transit']['status'] == 'ESTIMATE')

    _, _, a2 = solved(model(air='DPVAIR P12 100'))
    is_('set air 100 kPa below the 127 kPa trip: REJECTED, DPV_AIR_BELOW_TRIP',
        a2['validation']['acceptance'] == 'REJECTED'
        and (codes(a2['validation']).get('DPV_AIR_BELOW_TRIP') or '') == 'error',
        a2['validation']['acceptance'])
    _, _, a2 = solved(model(dpv='DPV P12 100 TRIP 40 ON VALVE TYCO DPV-1'))
    is_('a trip of 40 kPa, below choked flow: a warning, DPV_TRIP_NOT_CHOKED',
        (codes(a2['validation']).get('DPV_TRIP_NOT_CHOKED') or '') == 'warning'
        and not a2['dry'][0]['trip'].get('choked'))
    _, _, a2 = solved(model(more=['WATER W2 3 300', 'PIPE PX W2 B 20 50']))
    is_('a dry part fed by a second supply: refused, DPV_NOT_DRY',
        (codes(a2['validation']).get('DPV_NOT_DRY') or '') == 'error' and a2['dry'][0].get('error'))

    # The same, the second supply named 0.  The Perl asks whether the node
    # has a supply by the truth of the supply's name, and the name 0 is
    # false: that supply is not seen, and the estimate is made (a fault of
    # the Perl's, kept: the two programs must answer alike).
    _, _, a2 = solved(model(more=['WATER 0 3 300', 'PIPE PX 0 B 20 50']))
    is_('   a second supply named 0 is not seen, as in the Perl: no DPV_NOT_DRY',
        not codes(a2['validation']).get('DPV_NOT_DRY') and not a2['dry'][0].get('error')
        and a2['dry'][0]['transit']['status'] == 'ESTIMATE', list(codes(a2['validation'])))

    #==========================================================================
    print('4. THE LANGUAGE AND THE OUTPUT')
    #==========================================================================
    for line, want in [('DPVTRIP P12 12.7 0', 'WHOLE NUMBER'), ('DPVTRIP P12 12.7 1 70', 'OUTSIDE -50 TO 60'),
                       ('DPVTRIP P12 0', 'MORE THAN 0')]:
        e = refused(model(trip=line))
        is_('refused: %s' % line, re.search(want, e), e)
    e = refused(model(dpv='BFP P12 0 10', air=None))
    is_('refused: DPVTRIP on a pipe with no dry pipe valve', re.search(r'HAS NO DRY PIPE VALVE', e), e)

    rep = report.write_report(net, ok, 'dt.phc')

    def grab(pat):
        m = re.search(pat, rep)
        return m.group(1) if m else None
    rt = grab(r'TRIP TIME, ESTIMATE\s+([\d.]+) s')
    rx = grab(r'TRANSIT TIME, ESTIMATE\s+([\d.]+) s')
    rd = grab(r'DELIVERY TIME, ESTIMATE\s+([\d.]+) s')
    is_('the report: trip %s, transit %s, delivery %s s' % (pn(rt), pn(rx), pn(rd)),
        rd is not None and near(rt, d['trip']['seconds'], 0.05)
        and near(rx, d['transit']['seconds'], 0.05) and near(rd, d['delivery'], 0.05))
    is_('   labelled estimates, not a listed method',
        re.search(r'not a listed method', rep) and re.search(r'lower bound', rep))
    j = jsonout.results(net, ok, 'dt.phc')
    je = j['dry_pipe_valves'][0]['estimate']
    is_('the JSON: the same times, delivery_time itself still null',
        near(je['trip']['seconds'], d['trip']['seconds'], 0.05)
        and near(je['delivery_seconds'], d['delivery'], 0.05)
        and j['dry_pipe_valves'][0].get('delivery_time') is None)
    blk = results.block(net, ok, net['source_text'])
    m = re.search(r'TRIP_S ([\d.]+)', blk)
    bt = m.group(1) if m else None
    is_('the results block: TRIP_S %s' % pn(bt), near(bt, d['trip']['seconds'], 0.05))

    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
