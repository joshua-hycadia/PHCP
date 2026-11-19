#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_curves.py -- supply, pump and loss-device curves, and the orifice
# plate's discharge coefficient.  A port of tools/test_curves.pl.
#
#   python3 tools/test_curves.py
#
# A curve must pass EXACTLY through every point entered, be linear in Q^1.85
# between points, continue in a straight line beyond them, and never offer the
# loop correction a zero slope to divide by.  Each is checked here against
# figures worked by hand, independently of the engine's own code.
#==============================================================================

import math
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import demand

PASS = [0]
FAIL = [0]


def is_(name, ok, why=None):
    print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


def curve(rising, *qp):
    c = {'q': list(qp[0::2]), 'p': list(qp[1::2])}
    return hardycross.fit_curve(c, rising)


E = hardycross.curve_eval
S = hardycross.curve_slope


# refused -- true when the call raises a model error, as eval { ...; 1 }
# returning false with is_model_error($@) does in the Perl.
def refused(f):
    try:
        f()
    except Exception as e:
        return hardycross.is_model_error(e)
    return False


def main():
    print('1. EVERY POINT REPRODUCED EXACTLY')
    # Three points: the old least-squares quadratic missed all three.
    c = curve(0, 0, 1000, 3000, 700, 6000, 300)
    is_('town main (0,1000) (3000,700) (6000,300): through every point',
        abs(E(c, 0) - 1000) < 1e-9 and abs(E(c, 3000) - 700) < 1e-9 and abs(E(c, 6000) - 300) < 1e-9)
    p = curve(0, 0, 850, 2500, 800, 4000, 600, 5000, 380)
    is_('pump, four points: through every point',
        not any(abs(E(p, a) - b) > 1e-9 for a, b in [(0, 850), (2500, 800), (4000, 600), (5000, 380)]))
    u = curve(0, 4000, 600, 0, 850, 2500, 800)
    is_('points given out of order are sorted', abs(E(u, 2500) - 800) < 1e-9 and abs(E(u, 0) - 850) < 1e-9)

    print('2. LINEAR IN Q^1.85 BETWEEN POINTS')
    # A supply of static 1100 kPa and 1035 kPa residual at 7570 L/min.  By
    # hand, P(Q) = 1100 - 65 (Q / 7570)^1.85.  At 5000 L/min:
    #   (5000/7570)^1.85 = 0.66050^1.85 = 0.46427;  1100 - 65 x 0.46427 = 1069.82.
    c = curve(0, 0, 1100, 7570, 1035)
    hand = 1100 - 65 * (5000 / 7570) ** 1.85
    is_('static + one residual: P(5000) = %.2f kPa, as worked by hand' % E(c, 5000),
        abs(E(c, 5000) - hand) < 1e-9 and abs(hand - 1069.82) < 0.005)
    # Between the second and third points of a three-point curve:
    #   x = Q^1.85;  P = 700 + (300 - 700) (x(4500) - x(3000)) / (x(6000) - x(3000))
    t = curve(0, 0, 1000, 3000, 700, 6000, 300)

    def x(q):
        return q ** 1.85
    h2 = 700 + (300 - 700) * (x(4500) - x(3000)) / (x(6000) - x(3000))
    is_('three-point curve, P(4500) = %.2f kPa, the second segment' % E(t, 4500),
        abs(E(t, 4500) - h2) < 1e-9)
    is_('it is not the straight line between the points (that would be 500)', abs(E(t, 4500) - 500) > 5)
    # The slope matches a numerical derivative of the curve itself.
    d = (E(t, 4501) - E(t, 4499)) / 2
    is_('slope at 4500: %.5f kPa per L/min, as the curve itself' % S(t, 4500), abs(S(t, 4500) - d) < 1e-6)

    print('3. BEYOND THE POINTS, AND NO ZERO SLOPE')
    c = curve(0, 0, 1100, 7570, 1035)
    s = S(c, 7570)
    is_('beyond the last point: a straight line at the end slope',
        abs(E(c, 9570) - (1035 + 2000 * s)) < 1e-9 and s < 0)
    is_('at zero flow the Q^1.85 scale is flat; the slope offered is not zero',
        S(c, 0) < 0 and S(c, 1e-9) < 0)
    is_('reverse flow through a supply: a straight line, finite', abs(E(c, -100) - (1100 - 100 * S(c, -1))) < 1e-6)
    b = curve(1, 0, 0, 1000, 25, 2000, 55, 3000, 95)
    is_('a loss curve (backflow preventer): rising, through its points, slope positive',
        abs(E(b, 2000) - 55) < 1e-9 and S(b, 0) > 0 and S(b, 3500) > 0)

    print('4. REFUSED')
    is_('two points at the same flow are refused', refused(lambda: curve(0, 100, 900, 100, 800)))
    is_('one point is refused', refused(lambda: curve(0, 0, 900)))
    is_('a negative flow is refused', refused(lambda: curve(0, -100, 900, 1000, 800)))

    print('5. SUPPLIES COMBINED - FLOWS ADDED AT EQUAL PRESSURE')
    # Two supply curves, worked by hand.  A: 900 kPa at no flow, 600 at 3000.
    # B: 850 at no flow, 520 at 2400.  Each is straight in Q^1.85 between, so
    # at pressure p, A gives 3000 x ((900-p)/300)^(1/1.85) and B gives
    # 2400 x ((850-p)/330)^(1/1.85).
    A = {'kind': 'SUPPLY_CURVE', 'curve': curve(0, 0, 900, 3000, 600)}
    B = {'kind': 'SUPPLY_CURVE', 'curve': curve(0, 0, 850, 2400, 520)}

    def qa(p):
        return 3000 * ((900 - p) / 300) ** (1 / 1.85)

    def qb(p):
        return 2400 * ((850 - p) / 330) ** (1 / 1.85)
    c = demand.combined_avail(A, B)
    bad = 0
    for p in (610, 650, 700, 800, 849):      # within both curves' entered points
        q = qa(p) + qb(p)
        if abs(c(q) - p) > 1e-6:
            bad += 1
    is_('two curves: at each pressure the combined flow is their sum', not bad)
    is_('above the lower curve\'s shut-off, only the higher gives water',
        abs(c(qa(870)) - 870) < 1e-6)
    is_('three identical curves: three times the flow at the same pressure',
        abs(demand.combined_avail(A, A, A)(3 * qa(700)) - 700) < 1e-6)
    # A static supply gives any flow at its pressure, so the combined curve
    # never falls below it; above it, the curve gives the flow.
    T = {'kind': 'SUPPLY_STATIC', 'pstat': 700}
    ct = demand.combined_avail(A, T)
    is_('with a static supply: never below the static pressure',
        abs(ct(1e6) - 700) < 1e-9 and abs(ct(qa(800)) - 800) < 1e-6)

    print('6. ORIFICE PLATES - THE DISCHARGE COEFFICIENT')
    # The plate's net loss is the differential across it times the ISO 5167
    # permanent-loss ratio R:
    #   differential = (224.954 / Cd^2) (Q^2/d^4) (1 - b^4)   kPa, L/min, mm
    #   R            = [s - Cd b^2]/[s + Cd b^2],  s = sqrt(1 - b^4(1-Cd^2))
    # 224.954 = 633.28 x 0.596^2, the constant PHCP has always used at its
    # default Cd.  R is worked here by hand, so dividing it out leaves the
    # differential, which at fixed bore and beta must go as 1/Cd^2.
    dp = hardycross.orifice_dp
    q, d, bigd = 500, 38.5, 60              # beta 0.642
    b4 = (d / bigd) ** 4

    def R(cd):
        s = math.sqrt(1 - b4 * (1 - cd ** 2))
        return (s - cd * b4 ** 0.5) / (s + cd * b4 ** 0.5)

    def diff(cd):
        return dp(q, d, bigd, cd) / R(cd)
    ref = diff(0.596) * 0.596 ** 2
    bad = 0
    for cd in (0.55, 0.596, 0.61, 0.7, 0.7826, 0.9):
        if abs(diff(cd) * cd ** 2 / ref - 1) > 1e-12:
            bad += 1
    is_('differential x Cd^2 is the same for every Cd (bore, beta fixed)', not bad)
    is_('Cd 0.7826 vs 0.596: differential in the ratio (0.596/0.7826)^2',
        abs(diff(0.7826) / diff(0.596) - (0.596 / 0.7826) ** 2) < 1e-12)
    # At the default the drop is exactly what it was before the main term
    # took Cd: 633.28 (Q^2/d^4)(1-b^4) R.
    old = 633.28 * q ** 2 / d ** 4 * (1 - b4) * R(0.596)
    is_('default Cd 0.596: the drop is unchanged',
        abs(dp(q, d, bigd, 0.596) / old - 1) < 1e-12,
        '%.6f against %.6f kPa' % (dp(q, d, bigd, 0.596), old))
    # The constant is rho/2 (1/60000)^2 (4/pi)^2 1e12 at about 999.1 kg/m3;
    # at 998.2 kg/m3 it would be 224.75 - within 0.1%.
    pi = 4 * math.atan2(1, 1)
    k998 = 998.2 / 2 * (4 / pi) ** 2 / 3.6e9 * 1e12 / 1000
    is_('the constant is within 0.1% of the 998.2 kg/m3 value (224.75)',
        abs(ref / (q ** 2 / d ** 4 * (1 - b4)) / k998 - 1) < 1e-3)
    # OPP sizes with the same Cd: the bore found gives the drop asked for,
    # and a higher Cd needs a smaller bore for the same drop.
    b596, b783 = [hardycross.orifice_size(q, 150, bigd, cd) for cd in (0.596, 0.7826)]
    is_('OPP: the bore sized at Cd 0.7826 gives the drop asked for',
        abs(dp(q, b783, bigd, 0.7826) - 150) < 1e-6,
        'bore %.4f mm gives %.6f kPa' % (b783, dp(q, b783, bigd, 0.7826)))
    is_('OPP: a higher Cd needs a smaller bore for the same drop', b783 < b596,
        '%.3f mm at 0.7826, %.3f mm at 0.596' % (b783, b596))

    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
