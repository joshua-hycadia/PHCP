#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_tools.py -- the QUICK TOOLS calculators (hardycross.tools), headless.
# Python port of test_tools.pl, check for check.
#
#   python3 tools/test_tools.py
#
# Every answer is checked against a formula written out in this file, not
# against the engine's own code:
#
#   1. VELOCITY.       v = Q / A, with the database's bore.
#   2. K-FACTOR.       Q = K sqrt(P), each of the three solved for; K per root
#                      bar is ten times K per root kPa.
#   3. K CONVERTER.    US gpm/psi^0.5 to L/min/bar^0.5 by the exact gallon and
#                      psi; a K5.6 head is the K80 it is sold as.
#   4. PRESSURE LOSS.  Hazen-Williams 6.05e7 Q^1.85 / (C^1.85 d^4.87) kPa/m;
#                      Darcy-Weisbach against the Colebrook equation solved
#                      here by iteration, 64/Re when laminar and the blend
#                      of the two in the transitional zone; length, C and
#                      roughness each followed, each type's own roughness
#                      from the database.
#   5. REFUSED.        Each problem names its field.
#==============================================================================
import math
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

from hardycross import tools as T
from hardycross import pipedata as PD

_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def rel(a, b):
    return abs(a - b) / (abs(b) if abs(b) > 1e-12 else 1)


PI = 4 * math.atan2(1, 1)


def bore(t, dn):
    # The database's bore as a number (the Perl numifies its text).
    b = PD.bore(t, dn)
    return float(b) if b is not None else None


# A refusal: not ok, and a problem on the field named, matching re.
def refused(name, r, field, rx):
    e = ([x for x in (r.get('errors') or []) if x[0] == field] or [None])[0]
    is_(name, not r['ok'] and e is not None and re.search(rx, e[1]) is not None,
        'it was accepted' if r['ok']
        else '; '.join('[%s] %s' % (x[0], x[1]) for x in r['errors']))


#==============================================================================
print('1. VELOCITY - v = Q / A')
#==============================================================================
if True:
    types = [t for t in T.pipe_types() if t != 'BORE']
    is_("the pipe types are the database's, then BORE",
        len(types) >= 5 and T.pipe_types()[-1] == 'BORE', ' '.join(T.pipe_types()))
    bad = 0
    for type_ in types:
        for dn in T.sizes(type_):
            d = bore(type_, dn)
            r = T.velocity(type=type_, size=dn, flow=1000)
            if not (r['ok'] and r['bore'] == d
                    and rel(r['velocity'], (1000 / 60000) / (PI * (d / 1000) ** 2 / 4)) < 1e-12):
                bad += 1
    is_('every type and size: the database bore, and v = Q / A', not bad)
    r = T.velocity(type='ASAM', size=50, flow=500)
    is_('DN50 medium steel at 500 L/min: 53.0 mm bore, %.3f m/s' % r['velocity'],
        r['bore'] == 53.0 and rel(r['velocity'], 3.7773) < 1e-4)
    r = T.velocity(type='BORE', size='100', flow='1500')
    is_('BORE: the bore typed in, 100 mm at 1500 L/min is 3.183 m/s',
        r['ok'] and rel(r['velocity'], 3.18310) < 1e-5)
    r = T.velocity(type='ASAM', size=50, flow=0)
    is_('no flow, no velocity', r['ok'] and r['velocity'] == 0)

#==============================================================================
print('2. K-FACTOR - Q = K sqrt(P)')
#==============================================================================
if True:
    r = T.kfactor(k=8, p=100)
    is_('K 8 (per root kPa) at 100 kPa: Q = 80 L/min',
        r['ok'] and r['solved'] == 'Q' and rel(r['q'], 80) < 1e-12)
    r = T.kfactor(q=80, p=100)
    is_('80 L/min at 100 kPa: K = 8 per root kPa, 80 per root bar',
        r['ok'] and r['solved'] == 'K' and rel(r['k'], 8) < 1e-12 and rel(r['k_bar'], 80) < 1e-12)
    r = T.kfactor(k=8, q=120)
    is_('K 8 at 120 L/min: P = (120/8)^2 = 225 kPa',
        r['ok'] and r['solved'] == 'P' and rel(r['p'], 225) < 1e-12)
    r = T.kfactor(k=80, p=150, unit='BAR')
    is_('K 80 per root bar at 150 kPa (1.5 bar): Q = 80 sqrt(1.5) = %.3f' % (80 * math.sqrt(1.5)),
        r['ok'] and rel(r['q'], 80 * math.sqrt(1.5)) < 1e-12 and rel(r['k_kpa'], 8) < 1e-12)
    r = T.kfactor(q=97.98, p=150, unit='BAR')
    is_('K found in the unit chosen: per root bar',
        r['ok'] and rel(r['k'], 97.98 / math.sqrt(1.5)) < 1e-12)
    refused('one value is not enough', T.kfactor(k=8), 'K', r'ANY TWO')
    refused('three values: one must be cleared', T.kfactor(k=8, q=80, p=100), 'K', r'ONLY TWO')
    refused('K from no pressure is refused', T.kfactor(q=80, p=0), 'P', r'ABOVE ZERO TO FIND K')
    refused('a K of zero is refused', T.kfactor(k=0, p=100), 'K', r'ABOVE ZERO')
    refused('a letter O for a zero', T.kfactor(k=8, p='1O0'), 'P', r"'1O0' IS NOT A NUMBER")

#==============================================================================
print('3. K CONVERTER - US gpm/psi^0.5 and metric L/min/bar^0.5, L/min/kPa^0.5')
#==============================================================================
if True:
    # 1 US gal = 3.785411784 L; 1 psi = 6.894757293 kPa (the model's table
    # rounds it to 6.894757, so these agree to 1e-7).
    f = 3.785411784 / math.sqrt(0.06894757293168)
    r = T.kconvert(value=5.6, **{'from': 'US'})
    is_('K5.6 (US) is K%.2f metric per root bar - the K80 it is sold as' % (5.6 * f),
        r['ok'] and rel(r['bar'], 5.6 * f) < 1e-7 and abs(r['bar'] - 80.7) < 0.05
        and rel(r['kpa'], r['bar'] / 10) < 1e-12)
    r = T.kconvert(value=80, **{'from': 'BAR'})
    is_('K80 metric is K%.3f US' % (80 / f),
        r['ok'] and rel(r['us'], 80 / f) < 1e-7 and rel(r['kpa'], 8) < 1e-12)
    r = T.kconvert(value=8, **{'from': 'KPA'})
    is_('K8 per root kPa is K80 per root bar', r['ok'] and rel(r['bar'], 80) < 1e-12)
    r = T.kconvert(value=11.2, **{'from': 'US'})
    back = T.kconvert(value=r['bar'], **{'from': 'BAR'})
    is_('US to metric and back gives the same K', rel(back['us'], 11.2) < 1e-12)
    refused('a K that is not a number', T.kconvert(value='K80', **{'from': 'BAR'}),
            'VALUE', r'NOT A NUMBER')

#==============================================================================
print('4. PRESSURE LOSS - Hazen-Williams and Darcy-Weisbach')
#==============================================================================
# Colebrook, solved here by fixed-point iteration: an independent check of the
# engine's explicit approximation.  Laminar below Re 2000; between 2000 and
# 4000, the transitional zone, the solver blends linearly from 64/Re to the
# turbulent value, and so does this.


def colebrook(re_, eps, d):
    if re_ < 2000:
        return 64 / re_
    x = 0.02 ** -0.5
    for _ in range(100):
        x = -2 * math.log(eps / (3.7 * d) + 2.51 * x / re_) / math.log(10)
    f = 1 / x ** 2
    if re_ < 4000:
        t = (re_ - 2000) / 2000
        f = (1 - t) * 64 / re_ + t * f
    return f


if True:
    def hw(q, c, d):
        return 6.05e7 * q ** 1.85 / (c ** 1.85 * d ** 4.87)

    def dw(q, eps, d):
        v = (q / 60000) / (PI * (d / 1000) ** 2 / 4)
        re_ = v * (d / 1000) / 1.004e-6
        return colebrook(re_, eps, d) / (d / 1000) * 1000 * v ** 2 / 2 / 1000   # kPa/m: f/D rho v^2/2

    r = T.loss(type='ASAM', size=50, flow=500)
    is_('HW, DN50 at 500 L/min, C 120: %.4f kPa/m' % hw(500, 120, 53.0),
        r['ok'] and rel(r['hw']['per_m'], hw(500, 120, 53.0)) < 1e-12 and r['c'] == 120
        and r['length'] == 1)
    is_('DW, 0.045 mm: %.4f kPa/m, within 0.5 %% of Colebrook' % dw(500, 0.045, 53.0),
        rel(r['dw']['per_m'], dw(500, 0.045, 53.0)) < 0.005, '%.5f' % r['dw']['per_m'])
    is_('   turbulent, Re = vD/nu', r['dw']['regime'] == 'TURBULENT'
        and rel(r['dw']['re'], r['velocity'] * 0.053 / 1.004e-6) < 1e-12)
    bad = 0
    for type_ in [t for t in T.pipe_types() if t != 'BORE']:
        for dn in T.sizes(type_):
            d = bore(type_, dn)
            c = float(PD.pipe_type(type_)['c'])
            k = float(PD.pipe_type(type_)['eps'])
            for q in (100, 1000, 5000):
                x = T.loss(type=type_, size=dn, flow=q)
                if not (rel(x['hw']['per_m'], hw(q, c, d)) < 1e-12
                        and x['eps'] == k and rel(x['dw']['per_m'], dw(q, k, d)) < 0.01):
                    bad += 1
    is_("every type and size at 100, 1000 and 5000 L/min, the type's C and roughness: HW exact, DW within 1 %",
        not bad)
    r = T.loss(type='S40', size=600, flow=100)
    is_('transitional (S40 DN600 at 100 L/min, Re %.0f): the blend, within 1 %%' % r['dw']['re'],
        r['dw']['regime'] == 'TRANSITIONAL'
        and rel(r['dw']['f'], colebrook(r['dw']['re'], 0.045, r['bore'])) < 0.01)
    l = T.loss(type='ASAM', size=65, flow=1000, length=25)
    one = T.loss(type='ASAM', size=65, flow=1000)
    is_('over 25 m: 25 times the loss per metre, both formulas',
        rel(l['hw']['total'], 25 * one['hw']['per_m']) < 1e-12
        and rel(l['dw']['total'], 25 * one['dw']['per_m']) < 1e-12)
    k = {t: PD.pipe_type(t)['eps'] for t in
         ('ASAM', 'ASAH', 'S20', 'S40', 'CPVC', 'PE11', 'PE9', 'PVCM16')}
    is_('each pipe type has its roughness: steel 0.045, CPVC 0.003, PE100 0.007, PVC-M 0.003 mm',
        ' '.join('%s=%s' % (t, k[t]) for t in sorted(k))
        == 'ASAH=0.045 ASAM=0.045 CPVC=0.003 PE11=0.007 PE9=0.007 PVCM16=0.003 S20=0.045 S40=0.045',
        ' '.join('%s=%s' % (t, k[t] if k[t] is not None else 'undef') for t in sorted(k)))
    r = T.loss(type='BORE', size=50, flow=500)
    is_("BORE takes the program's default roughness, 0.045 mm, and says it is assumed",
        r['eps'] == 0.045 and r['eps_src'] == 'DEFAULT')
    r = T.loss(type='BORE', size=50, flow=500, eps='0.0015')
    is_('   a roughness typed in is as given', r['eps_src'] == 'GIVEN')
    r = T.loss(type='PE11', size=110, flow=1000)
    is_("the roughness is the pipe type's: 0.007 mm for PE100, from the database",
        r['eps'] == 0.007 and r['eps_src'] == 'DATABASE')
    is_("the C factor is the pipe type's: 150 for PE",
        r['c'] == 150 and rel(r['hw']['per_m'], hw(1000, 150, bore('PE11', 110))) < 1e-12)
    r = T.loss(type='ASAM', size=50, flow=500, c=100, eps='0.0015')
    is_('C and roughness as typed', r['c'] == 100 and r['eps'] == 0.0015
        and rel(r['hw']['per_m'], hw(500, 100, 53.0)) < 1e-12
        and rel(r['dw']['per_m'], dw(500, 0.0015, 53.0)) < 0.005)
    r = T.loss(type='BORE', size=2, flow=0.05)
    v = (0.05 / 60000) / (PI * 0.002 ** 2 / 4)
    is_('laminar (Re %.0f): f = 64/Re' % (v * 0.002 / 1.004e-6),
        r['dw']['regime'] == 'LAMINAR' and rel(r['dw']['f'], 64 / (v * 0.002 / 1.004e-6)) < 1e-12)
    is_('   and DW against HW is DW - HW, as a percentage of HW',
        rel(one['diff_pct'], 100 * (one['dw']['per_m'] - one['hw']['per_m']) / one['hw']['per_m']) < 1e-12)

#==============================================================================
print('6. UNITS - read in the units chosen, the sums in L/min, kPa, m and mm')
#==============================================================================
if True:
    r = T.velocity(type='ASAM', size=50, flow=500 / 60, units={'FLOW': 'LPS'})
    is_('500 L/min typed as 8.333 L/s: the same 3.777 m/s',
        rel(r['velocity'], 3.7773) < 1e-4 and rel(r['q'], 500) < 1e-12)
    r = T.velocity(type='BORE', size=4, flow=1500, units={'SIZE': 'IN'})
    is_('a bore of 4 in is 101.6 mm', rel(r['bore'], 101.6) < 1e-12)
    base = T.loss(type='ASAM', size=65, flow=1000, length=25)
    r = T.loss(type='ASAM', size=65, flow=16.6666667, length=25000,
               units={'FLOW': 'LPS', 'LENGTH': 'MM'})
    is_('loss: 1000 L/min over 25 m, typed as L/s and mm, is the same',
        rel(r['hw']['total'], base['hw']['total']) < 1e-6 and rel(r['length'], 25) < 1e-12)
    is_('   and shown in bar: a hundredth of the kPa',
        rel(T.show('PRESSURE', r['hw']['total'], {'PRESSURE': 'BAR'}), base['hw']['total'] / 100) < 1e-6)
    r = T.loss(type='ASAM', size=50, flow=500, eps='0.0059055', units={'SIZE': 'IN'})
    is_('a roughness in the SIZE unit: 0.0059055 in is 0.15 mm', rel(r['eps'], 0.15) < 1e-4)
    r = T.kfactor(k=5.6, p=7, unit='GPM/PSI', units={'FLOW': 'GPM', 'PRESSURE': 'PSI'})
    is_('K 5.6 (US) at 7 psi: %.3f gpm = 5.6 sqrt(7)' % (5.6 * math.sqrt(7)),
        rel(T.show('FLOW', r['q'], {'FLOW': 'GPM'}), 5.6 * math.sqrt(7)) < 1e-9)
    r = T.kconvert(value=1.346, **{'from': 'LPS/BAR'})
    is_('K 1.346 L/s per root bar is 80.76 L/min per root bar', rel(r['bar'], 80.76) < 1e-12)
    r = T.kconvert(value=80, **{'from': 'LPM/BAR'})
    is_('every K unit given: 80 LPM/BAR is 8 LPM/KPA, 1.333 LPS/BAR, 0.1333 LPS/KPA, 5.549 GPM/PSI',
        rel(r['all']['LPM/KPA'], 8) < 1e-12 and rel(r['all']['LPS/BAR'], 80 / 60) < 1e-12
        and rel(r['all']['LPS/KPA'], 8 / 60) < 1e-12
        and rel(r['all']['GPM/PSI'], 80 / (3.785411784 / math.sqrt(0.06894757293168))) < 1e-7)

#==============================================================================
print('7. FITTINGS - equivalent lengths, as for a model\'s pipe')
#==============================================================================
if True:
    r = T.fittings(type='ASAM', size=100, spec='1T 2E G C')
    is_('1T 2E G C on DN100 medium steel: 6.1 + 2 x 3.0 + 0.6 + 6.7 = 19.4 m',
        r['ok'] and abs(r['total'] - 19.4) < 1e-9 and len(r['rows']) == 4,
        '; '.join(x[1] for x in (r.get('errors') or [])))
    m = PD.resolve(type='ASAM', dn=100, spec='1T+2E+1GV+1CV')
    is_("   the same as a model's pipe with those fittings", abs(r['total'] - m['total']) < 1e-12)
    is_('   2E,1T and 2E 1T are the same',
        abs(T.fittings(type='ASAM', size=50, spec='2E,1T')['total']
            - T.fittings(type='ASAM', size=50, spec='2E 1T')['total']) < 1e-12)
    r = T.fittings(type='ASAM', size=100, spec='1T', c=150)
    is_('a C other than 120 corrects the length: (150/120)^1.85',
        abs(r['total'] - 6.1 * (150 / 120) ** 1.85) < 1e-9, r['total'])
    refused('a fitting the database lacks is refused, not zero',
            T.fittings(type='ASAM', size=100, spec='1ZZ'), 'SPEC', r'ZZ')
    refused('BORE has no fittings', T.fittings(type='BORE', size=100, spec='1E'), 'TYPE', r'NOT BORE')
    refused('no fittings given', T.fittings(type='ASAM', size=100, spec=''), 'SPEC', r'GIVE THE FITTINGS')

#==============================================================================
print('5. REFUSED - each problem names its field')
#==============================================================================
if True:
    refused('no size chosen', T.velocity(type='ASAM', size='', flow=100), 'SIZE', r'CHOOSE A SIZE')
    refused('a size the type is not made in', T.velocity(type='ASAM', size=300, flow=100),
            'SIZE', r'ASAM IS NOT MADE IN DN300')
    refused('an unknown pipe type', T.loss(type='XX9', size=50, flow=100), 'TYPE', r'UNKNOWN PIPE TYPE XX9')
    refused('no flow', T.loss(type='ASAM', size=50, flow=''), 'FLOW', r'FLOW IS NEEDED')
    refused('a negative flow', T.velocity(type='ASAM', size=50, flow=-5), 'FLOW', r'CANNOT BE NEGATIVE')
    refused('a bore of zero', T.velocity(type='BORE', size=0, flow=100), 'SIZE', r'BORE MUST BE ABOVE ZERO')
    refused('a length of zero', T.loss(type='ASAM', size=50, flow=100, length=0), 'LENGTH', r'ABOVE ZERO')
    refused('a C that is not a number', T.loss(type='ASAM', size=50, flow=100, c='C120'), 'C', r'NOT A NUMBER')
    refused('a negative roughness', T.loss(type='ASAM', size=50, flow=100, eps=-1), 'EPS', r'CANNOT BE NEGATIVE')

#==============================================================================
print('8. ORIFICE PLATE - the same sum as OPP and OFD')
#==============================================================================
if True:
    # Written out here, not taken from the engine: the net loss is the
    # tapping differential times the ISO 5167 permanent-loss ratio.
    #   differential = 633.28 (0.596/Cd)^2 (Q^2/d^4) (1-b^4)    kPa, L/min, mm
    #   R = [s - Cd b^2] / [s + Cd b^2],  s = sqrt(1 - b^4 (1 - Cd^2))
    # OPP finds d by bisection because the loss falls as the bore grows, then
    # rounds to the step by int(d/step + 0.5) * step.
    def hand_dp(q, d, bigd, cd=None):
        cd = 0.596 if cd is None else cd
        if d <= 0 or q <= 0:
            return 0
        beta = d / bigd if d / bigd < 0.99999 else 0.99999
        b4 = beta ** 4
        inside = 1 - b4 * (1 - cd ** 2)
        if inside < 1e-12:
            inside = 1e-12
        s = math.sqrt(inside)
        den = s + cd * beta ** 2
        rr = 0 if den == 0 else (s - cd * beta ** 2) / den
        if rr < 0:
            rr = 0
        return 633.28 * (0.596 / cd) ** 2 * q ** 2 / d ** 4 * (1 - b4) * rr

    def hand_size(q, target, bigd, cd):
        if q <= 1e-6 or target <= 1e-9 or bigd <= 1e-9:
            return 0
        lo, hi = 0.001 * bigd, 0.9995 * bigd
        if hand_dp(q, hi, bigd, cd) > target:
            return hi
        if hand_dp(q, lo, bigd, cd) < target:
            return lo
        for _ in range(200):
            mid = 0.5 * (lo + hi)
            if hand_dp(q, mid, bigd, cd) > target:
                lo = mid
            else:
                hi = mid
            if hi - lo < 1e-9 * bigd:
                break
        return 0.5 * (lo + hi)

    def round_(b, step):
        return int(b / step + 0.5) * step if step > 0 else b

    q, D, drop, cd = 500, 60, 150, 0.7826
    exact = hand_size(q, drop, D, cd)
    bore_ = round_(exact, 0.5)
    r = T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=cd)
    is_('SIZE: the bore before rounding is the bisection, and 0.5 mm is the default step',
        r['ok'] and abs(r['bore_exact'] - exact) < 1e-6 and abs(r['bore'] - bore_) < 1e-9
        and r['step'] == 0.5,
        ('exact %s bore %s' % (r['bore_exact'], r['bore'])) if r['ok'] else r['errors'][0][1])
    is_('   the net loss at that bore is the formula, and the unrounded bore meets the drop',
        abs(r['drop'] - hand_dp(q, bore_, D, cd)) < 1e-6 and abs(r['drop_exact'] - drop) < 1e-4)
    is_('   the ratio times the tapping differential is the net loss',
        r['ratio'] > 0 and abs(r['differential'] * r['ratio'] - r['drop']) < 1e-6
        and abs(r['beta'] - bore_ / D) < 1e-9)
    plain = T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop)
    named = T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=0.596)
    is_('a blank CD is 0.596', plain['cd_default'] and abs(plain['bore'] - named['bore']) < 1e-9
        and not named['cd_default'])
    hi = T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=cd)
    is_('a higher CD needs a smaller bore for the same drop', hi['bore_exact'] < plain['bore_exact'])
    is_('step 0 does not round',
        abs(T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=cd, step=0)['bore']
            - exact) < 1e-6)
    is_('a step of 1 mm rounds the way an OPP plate does',
        abs(T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=cd, step_default=1)['bore']
            - round_(exact, 1)) < 1e-9)
    dn = bore('ASAM', 50)
    r = T.plate(mode='SIZE', type='ASAM', size=50, flow=500, drop=100)
    is_("ASAM DN50: the pipe bore is the database's", r['ok'] and r['pipedia'] == dn, r.get('pipedia'))
    uu = T.plate(mode='SIZE', type='BORE', size=D / 25.4, flow=q / 60, drop=drop / 100,
                 cd=cd, units={'FLOW': 'LPS', 'PRESSURE': 'BAR', 'SIZE': 'IN'})
    is_('the same plate typed in L/s, bar and inches',
        uu['ok'] and abs(uu['bore'] - bore_) < 1e-6 and abs(uu['q'] - q) < 1e-6
        and abs(uu['target'] - drop) < 1e-6)
    mn = hand_dp(q, 0.9995 * D, D, 0.596)
    is_('a drop smaller than the largest bore can give is said so',
        T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=mn / 2)['limit'] == 'WIDE')
    mx = hand_dp(q, 0.001 * D, D, 0.596)
    is_('a drop larger than a very small bore gives is said so',
        T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=mx * 2)['limit'] == 'TIGHT')
    ofd = T.plate(mode='DROP', type='BORE', size=D, flow=q, bore=38.5, cd=0.596)
    is_("DROP: 38.5 mm in a 60 mm pipe at 500 L/min is the formula's net loss",
        ofd['ok'] and abs(ofd['drop'] - hand_dp(q, 38.5, D, 0.596)) < 1e-6
        and abs(ofd['velocity'] - (q / 60000) / (PI * (38.5 / 1000) ** 2 / 4)) < 1e-9)
    is_('CD 1 is allowed', T.plate(mode='DROP', type='BORE', size=D, flow=q, bore=30, cd=1)['ok'])
    refused('CD above 1', T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=1.2),
            'CD', r'NOT MORE THAN 1')
    # The Perl suite matches qr/MORE THAN 0/ here, but the Perl program
    # answers "CD MUST BE ABOVE ZERO" (number() refuses a 0 before the
    # range check), and its check passed only because a failed match in
    # is()'s argument list is an empty list, which shifts the why text into
    # the ok slot.  Both programs refuse a CD of 0 on the CD field with the
    # same words; this asserts those words.
    refused('CD of 0', T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, cd=0),
            'CD', r'CD MUST BE ABOVE ZERO')
    refused('a plate bore as large as the pipe',
            T.plate(mode='DROP', type='BORE', size=D, flow=q, bore=D),
            'BORE', r'SMALLER THAN THE PIPE')
    refused('SIZE with no drop', T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=''),
            'DROP', r'DROP IS NEEDED')
    refused('a negative bore step',
            T.plate(mode='SIZE', type='BORE', size=D, flow=q, drop=drop, step=-1),
            'STEP', r'CANNOT BE NEGATIVE')

print('9. AS THE PERL - where the port and the Perl could differ')
# Each of these was a difference between the port and the Perl 1.6.0, found
# by reading the two side by side and run on both; what is asserted is what
# the Perl gives.
if True:
    TY = T.pipe_types()[0]
    DN = T.sizes(TY)[2]
    r = T.velocity(type=TY, size='%d.0000001' % DN, flow=100)
    is_('a size is looked up by its own figures: DN%d.0000001 is not DN%d' % (DN, DN),
        not r['ok'] and r['errors'][0] == ['SIZE', '%s IS NOT MADE IN DN%d.0000001 - CHOOSE A SIZE FROM THE LIST' % (TY, DN)], r)
    r1, r2 = T.velocity(type=TY, size='0%d.0' % DN, flow=100), T.velocity(type=TY, size=DN, flow=100)
    is_('   and 0%d.0 is DN%d' % (DN, DN), r1['ok'] and r1 == r2, r1)
    r = T.fittings(type=TY, size=DN, spec='2E,')
    is_("a comma after the last fitting is not another fitting: '2E,' is 2E",
        r['ok'] and r['spec'] == '2E' and len(r['rows']) == 1, r)
    r = T.fittings(type=TY, size=DN, spec=' 2e , t ,, ')
    is_("   ' 2e , t ,, ' is 2E+T", r['ok'] and r['spec'] == '2E+T' and len(r['rows']) == 2, r)
    r = T.fittings(type=TY, size=DN, spec=',')
    is_("   and ',' alone is no fittings at all", r['ok'] and r['spec'] == '' and r['rows'] == [] and r['total'] == 0, r)

    def died(code):
        try:
            code()
        except Exception as e:      # noqa: BLE001 - the message is the check
            return getattr(e, 'msg', None) or str(e)
        return None
    is_('a K unit that is no unit is refused by name',
        died(lambda: T.kconvert(value=5.6, **{'from': 'XYZ'})) == 'unknown unit XYZ for FLOW')
    is_('   an empty one too: it is not taken for US or KPA',
        died(lambda: T.kconvert(value=5.6, **{'from': ''})) == 'unknown unit  for FLOW'
        and died(lambda: T.kfactor(k=8, p=100, unit='')) == 'unknown unit  for FLOW')
    is_('   a flow unit alone has no pressure unit',
        died(lambda: T.kconvert(value=5.6, **{'from': 'LPM'})) == 'unknown unit  for PRESSURE')
    r = T.kconvert(value=5.6, **{'from': 'lpm/bar/x'})
    is_('   and only the first two parts of one are read', r['ok'] and rel(r['bar'], 5.6) < 1e-12, r)
    is_("a unit of '0' is no unit: the internal one", T.units_of({'FLOW': '0', 'PRESSURE': 'psi'})
        == {'FLOW': 'LPM', 'PRESSURE': 'PSI', 'LENGTH': 'M', 'SIZE': 'MM', 'KFACTOR': 'LPM/KPA'})
    is_('show of a quantity with no unit says so', died(lambda: T.show('VOLUME', 1)) == 'no unit factor for VOLUME')
    r = T.plate(type=TY, size=DN, flow=500, drop=100, step_default='0.25')
    is_('a default bore step given as text (a setting) is the number it spells',
        r['ok'] and r['step'] == 0.25 and rel(r['bore'] / 0.25, round(r['bore'] / 0.25)) < 1e-12, r)
    r = T.plate(type=TY, size=DN, flow=500, drop=100, step_default='-1')
    is_('   and a negative one is refused', not r['ok'] and r['errors'] == [['STEP', 'BORE STEP MUST BE ZERO OR ABOVE']], r)
    n, e = T.number('X', '-0', 'nonneg')
    is_("-0 is 0, not minus zero: a flow of -0 gives a velocity of 0.00, not -0.00",
        e is None and '%.2f' % n == '0.00' and '%.2f' % T.velocity(type='BORE', size=50, flow='-0')['velocity'] == '0.00', n)
    n, e = T.number('X', '\u0663', 'nonneg')
    is_('figures that are not 0-9 count for nothing: Arabic-Indic 3 is 0', e is None and n == 0, (n, e))
    n, e = T.number('X', '\u0663')
    is_('   so where zero is refused, it is', n is None and e == 'X MUST BE ABOVE ZERO', (n, e))

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
