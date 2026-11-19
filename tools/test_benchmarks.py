#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_benchmarks.py -- PHCP against reference values it did not compute.
# Python port of test_benchmarks.pl, check for check.
#
#   python3 tools/test_benchmarks.py
#
# hardycross.validate checks that the solved network satisfies PHCP's own
# element equations.  That shows the answer is CONSISTENT; it cannot show the
# equations are RIGHT, since the check and the solver share them.  Here every
# reference value is worked without any PHCP function: from the published
# form of each equation, written out again in this file, with its unit
# conversions done here, and -- for whole networks -- by a different method
# of solution altogether.
#
#   A. ELEMENT EQUATIONS, each against its published form
#      Hazen-Williams      the NFPA 13 US-unit form, 4.52 Q^1.85/(C^1.85
#                          d^4.87) psi/ft, converted here (independent of
#                          the 6.05 x 10^5 bar/m form PHCP uses)
#      Darcy-Weisbach      the Colebrook-White equation iterated to 1e-14 in
#                          f, and a Moody chart point
#      elevation           the conventional metre of water, 9.80665 kPa
#                          (ISO 80000-4), applied by hand
#      equivalent length   a pipe of L with EQV E against one of L + E
#      K-factor            q = K sqrt(P), the definition of K
#      orifice plate       ISO 5167-2: the differential from Q = Cd/sqrt(1 -
#                          b^4) (pi d^2/4) sqrt(2 dP / rho), the permanent
#                          loss ratio from ISO 5167-2 clause 5.4, rho 999.1
#      pump curve          P = Pc - (Pc - P1)(Q/Q1)^1.85 through two points
#      water supply curve  the same N^1.85 form a flow test is plotted on
#      dry pipe valve      a flow coefficient's own definition, dP psi =
#                          (Q gpm / Cv)^2; an equivalent length of a stated
#                          pipe and C by the US-unit Hazen-Williams form
#   B. NETWORKS, against a NODAL NEWTON solve written here.  Two of them have
#      a check valve at a supply (NRV): in the nodal solve a valve is no
#      state at all, only max(0, ...) in its supply's flow equation, so
#      whether it is shut or open comes out of the solve itself -- an
#      independent check of the outer loop that decides it in PHCP.
#      Hardy Cross balances LOOP flows; the reference below solves NODE heads
#      by Newton's method with a numerical Jacobian -- a different set of
#      unknowns, equations and iteration, sharing no code with the solver.
#      series, branched, looped, gridded, two supplies (one static, one on a
#      curve) with elevations and a fixed flow, and a pump.
#
# The closed-form case of examples/01 (Q = 80 sqrt(900 - 1.5677E-4 Q^1.85))
# is worked by bisection as well.
#
# Agreement here is evidence that PHCP solves the published equations as
# published.  It is not evidence that those equations describe any real
# installation, nor external certification of PHCP.
#==============================================================================
import math
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, validate

passed = failed = 0


def is_(name, ok, why=None):
    global passed, failed
    print('  %-72s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        passed += 1
    else:
        failed += 1


def rel(a, b):
    return abs(a - b) / (abs(b) if abs(b) > 1e-12 else 1)


# Unit conversions, written out here from their definitions.
GPM = 3.785411784          # L/min per US gpm (US gallon 3.785411784 L exactly)
IN = 25.4                  # mm per inch (exact)
FT = 0.3048                # m per foot (exact)
PSI = 6.894757293168       # kPa per psi (lbf/in2)
MH2O = 9.80665             # kPa per conventional metre of water (ISO 80000-4)


def hw_us(q_lpm, c, d_mm, l_m):
    # Hazen-Williams loss in kPa over l_m metres, by the NFPA 13 US form.
    psi_ft = 4.52 * (q_lpm / GPM) ** 1.85 / (c ** 1.85 * (d_mm / IN) ** 4.87)
    return psi_ft * PSI / FT * l_m


HEAD = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION M', 'UNITS SIZE MM', 'UNITS PRESSURE KPA',
                  'UNITS FLOW LPM', 'UNITS KFACTOR LPM/KPA', ''])
TIGHT = "OPTION TOL_FLOW 1E-7\nOPTION TOL_LOOP 1E-8\nOPTION MAXITER 200000\n"


def solve(text):
    n = phc.read_string(text)
    ok = hardycross.solve_model(n)
    return n, ok


def elem(n, id_):
    for e in n['elems'][1:]:
        if (e.get('id') if e.get('id') is not None else '') == id_:
            return e
    return None


def node(n, id_):
    for x in n['nodes'][1:]:
        if x['id'] == id_:
            return x
    return None


def gauge(n, id_):
    x = node(n, id_)
    return x['h'] - hardycross.GAMMA_W * x['z']


def colebrook(re_, rr):
    # Colebrook-White iterated to convergence.
    x = 0.02
    for _ in range(200):
        n = (-2 * math.log(rr / 3.7 + 2.51 / (re_ * math.sqrt(x))) / math.log(10)) ** -2
        if abs(n - x) < 1e-14:
            break
        x = n
    return x


def part_a():
    print("A. ELEMENT EQUATIONS")
    # Hazen-Williams: PHCP's 6.05E7 metric form against the NFPA 13 US form,
    # over flows and bores a sprinkler system uses.
    worst = 0
    for q in (50, 200, 1000, 3000, 8000):
        for d in (27.3, 53.1, 105.3, 155.1):
            e = {'kind': 'PIPE', 'len': 100, 'eqv': 0, 'dia': d, 'c': 120, 'q': q}
            hf = hardycross.elem_hf(e, q, {'method': 'HW', 'hwk': hardycross.HWK_DEF,
                                           'hwq': 1.85, 'hwd': 4.87})[0]
            r = rel(hf, hw_us(q, 120, d, 100))
            if r > worst:
                worst = r
    is_('Hazen-Williams: within 0.1 %% of the NFPA 13 US form at every flow and bore (worst %.3f %%)'
        % (100 * worst), worst < 0.001)

    # Darcy-Weisbach: Colebrook-White iterated to convergence.
    wd = 0
    for q in (100, 1000, 5000):
        for d in (53.1, 105.3):
            e = {'kind': 'PIPE', 'len': 50, 'eqv': 0, 'dia': d, 'c': 120, 'eps': 0.045, 'q': q}
            hf = hardycross.elem_hf(e, q, {'method': 'DW', 'nu': 1.004e-6})[0]
            v = (q / 60000) / (3.14159265358979 * (d / 1000) ** 2 / 4)
            re_ = v * (d / 1000) / 1.004e-6
            f = colebrook(re_, 0.045 / d)
            ref = f * (50 / (d / 1000)) * 998.2 / 1000 * v ** 2 / 2     # kPa, rho 998.2
            r = rel(hf, ref)
            if r > wd:
                wd = r
    # PHCP's DW loss is f (L/D) v^2/2 x gamma_w/g with gamma_w 9.80665, i.e. rho 1000;
    # the reference takes rho 998.2 (water at 20 C), so 0.18 % apart by design.
    is_('Darcy-Weisbach: within 0.5 %% of Colebrook-White (worst %.3f %%; 0.18 %% is rho 1000 against 998.2)'
        % (100 * wd), wd < 0.005)
    fm = colebrook(1e5, 1e-4)
    is_('  ... Colebrook at Re 1e5, e/D 1e-4 gives f = %.4f (Moody chart: 0.0185)' % fm,
        abs(fm - 0.0185) < 0.0003)
    is_("  ... PHCP's friction factor there within 0.1 % of Colebrook",
        rel(hardycross.dw_friction(1e5, 0.01, 100), colebrook(1e5, 1e-4)) < 0.001)

    # Elevation: a sprinkler 10 m up, its pressure the supply less the friction
    # (by the US form) less 10 m of water.
    n, ok = solve(HEAD + "METHOD HW\n" + TIGHT
                  + "USE BORE 120\nWATER S 0 600\nSPRINKLER H 10 -50 80\nPIPE P1 S H 30 53.1\n")
    q = elem(n, 'P1')['q']
    ref = 600 - hw_us(q, 120, 53.1, 30) - 10 * MH2O
    # To within the 0.02 % the two Hazen-Williams forms differ by on the friction.
    hfr = hw_us(q, 120, 53.1, 30)
    is_('elevation: 10 m of rise costs 98.07 kPa (%.3f against %.3f kPa)' % (gauge(n, 'H'), ref),
        abs(gauge(n, 'H') - ref) < 0.001 * hfr + 0.01)

    # Equivalent length: L 20 with EQV 15 is a pipe of 35.
    n1, _ = solve(HEAD + "METHOD HW\n" + TIGHT
                  + "USE BORE 120\nWATER S 0 600\nSPRINKLER H 0 -50 80\nPIPE P1 S H 20 53.1\nEQV P1 15\n")
    n2, _ = solve(HEAD + "METHOD HW\n" + TIGHT
                  + "USE BORE 120\nWATER S 0 600\nSPRINKLER H 0 -50 80\nPIPE P1 S H 35 53.1\n")
    is_('equivalent length: a pipe of 20 m with 15 m EQV is a pipe of 35 m',
        abs(elem(n1, 'P1')['q'] - elem(n2, 'P1')['q']) < 1e-4)

    # K-factor: q = K sqrt(P) at the solved pressure.
    is_('K-factor: the sprinkler gives K sqrt(P) at its pressure (%.4f against %.4f)'
        % (q, 80 * math.sqrt(gauge(n, 'H'))),
        abs(q - 80 * math.sqrt(gauge(n, 'H'))) < 1e-3)

    # Orifice plate, ISO 5167-2.  The differential across the tappings from
    # Q = Cd E (pi d^2 / 4) sqrt(2 dP / rho), E = 1/sqrt(1 - b^4); the
    # permanent loss, the differential times the ISO 5167-2 ratio.
    def iso(q_lpm, d, bigd, cd):
        b = d / bigd
        area = 3.14159265358979 * (d / 1000) ** 2 / 4
        qs = q_lpm / 60000
        diff = 999.1 / 2 * (qs * math.sqrt(1 - b ** 4) / (cd * area)) ** 2 / 1000     # kPa
        s = math.sqrt(1 - b ** 4 * (1 - cd ** 2))
        return diff * (s - cd * b ** 2) / (s + cd * b ** 2)
    wo = 0
    for c in ([500, 25, 53.1], [1500, 35, 53.1], [2500, 60, 105.3], [800, 15, 27.3]):
        r = rel(hardycross.orifice_dp(c[0], c[1], c[2], 0.596), iso(*c, 0.596))
        if r > wo:
            wo = r
    is_('orifice plate: within 0.1 %% of ISO 5167-2 (worst %.3f %%)' % (100 * wo), wo < 0.001)

    # Pump curve: two points, churn 400 and 300 at 2000 L/min, P = 400 -
    # 100 (Q/2000)^1.85.
    pn, pok = solve(HEAD + "METHOD HW\n" + TIGHT + "USE BORE 120\nWATER S 0 200\nNODE D 0\nSPRINKLER H 0 -50 80\n"
                    + "PUMP FP S D 400 2000 300\nPIPE P1 D H 40 105.3\n")
    qp = elem(pn, 'FP')['q']
    rise = gauge(pn, 'D') - gauge(pn, 'S')
    is_('pump: its rise at %.1f L/min is 400 - 100 (Q/2000)^1.85 (%.3f against %.3f kPa)'
        % (qp, rise, 400 - 100 * (qp / 2000) ** 1.85),
        pok and abs(rise - (400 - 100 * (qp / 2000) ** 1.85)) < 0.01)

    # Water supply curve: the N^1.85 form a flow test is plotted on.
    sn, sok = solve(HEAD + "METHOD HW\n" + TIGHT + "USE BORE 120\nWATER S 0 700 3000 500\nSPRINKLER H 0 -50 80\n"
                    + "PIPE P1 S H 40 105.3\n")
    qs = elem(sn, 'S')['q']
    is_('water supply: at %.1f L/min it gives 700 - 200 (Q/3000)^1.85 (%.3f kPa)' % (qs, gauge(sn, 'S')),
        sok and abs(gauge(sn, 'S') - (700 - 200 * (qs / 3000) ** 1.85)) < 0.01)

    # Dry pipe valve, flow coefficient: dP psi = (Q gpm / Cv)^2.
    dpv = {'kind': 'DPV', 'loss': 'DB', 'cv': 1500, 'q': 2000}
    hcv = hardycross.elem_hf(dpv, 2000, {})[0]
    is_('dry pipe valve Cv 1500 at 2000 L/min: %.4f kPa against (Q gpm / Cv)^2 psi' % hcv,
        rel(hcv, ((2000 / GPM) / 1500) ** 2 * PSI) < 1e-6)
    # ... and an equivalent length of a stated pipe and C, by the US form.
    dpe = {'kind': 'DPV', 'loss': 'DB', 'eql': 9.5, 'ref_bore': 102.3, 'ref_c': 120, 'q': 2000}
    heq = hardycross.elem_hf(dpe, 2000, {})[0]
    is_('dry pipe valve 9.5 m of 102.3 mm C 120 at 2000 L/min: %.4f kPa, within 0.1 %% of the US form' % heq,
        rel(heq, hw_us(2000, 120, 102.3, 9.5)) < 0.001)

    # The closed-form case of examples/01.
    r1 = 6.05e7 * 100 / (120 ** 1.85 * 100 ** 4.87)
    with open(os.path.join(ROOT, 'examples', '01_single_branch.phc')) as f:
        ex1 = f.read()
    m = re.search(r'SQRT\(900 - ([\d.]+E-?\d+)\*Q', ex1)
    said = m.group(1) if m else None
    is_('examples/01: its resistance is %.5g, as its comment says (%s)'
        % (r1, said if said is not None else 'none'),
        said is not None and abs(r1 - float(said)) < 5e-9)
    lo, hi = 0, 3000
    for _ in range(100):
        mid = (lo + hi) / 2
        if mid < 80 * math.sqrt(900 - r1 * mid ** 1.85):
            lo = mid
        else:
            hi = mid
    en, _ = solve(ex1)
    is_('examples/01: PHCP %.4f L/min against the closed form %.4f' % (elem(en, 'P1')['q'], lo),
        abs(elem(en, 'P1')['q'] - lo) < 0.01)


#==============================================================================
# B. NETWORKS, AGAINST A NODAL NEWTON SOLVE
#==============================================================================
# A network is given as data, written out as .phc for PHCP and solved here
# by Newton's method on the node heads, with no PHCP function.
#   nodes    [ id, z ]
#   static   [ id, z, p ]                    a static supply
#   curve    [ id, z, pc, q1, p1 ]           a supply on the N^1.85 form
#   heads    [ id, z, preq, K ]              a sprinkler
#   pipes    [ id, a, b, L, d ]              C 120
#   pumps    [ id, in, out, pc, q1, p1 ]
#   fixed    [ id, node, q ]
#   nrv      { static supply id => [ Cv, crack ] }   a check valve at it
def pstr(v):
    # Perl's interpolation of a number or string into the .phc text.
    if isinstance(v, float):
        return '%.15g' % v
    return str(v)


def phc_of(m):
    t = HEAD + "METHOD HW\n" + TIGHT + "USE BORE 120\n"
    for x in m.get('static') or []:
        t += "WATER %s %s %s\n" % tuple(pstr(v) for v in x[:3])
    for x in m.get('curve') or []:
        t += "WATER %s %s %s %s %s\n" % tuple(pstr(v) for v in x[:5])
    for x in m.get('nodes') or []:
        t += "NODE %s %s\n" % (pstr(x[0]), pstr(x[1]))
    for x in m.get('heads') or []:
        t += "SPRINKLER %s %s -%s %s\n" % (pstr(x[0]), pstr(x[1]), pstr(x[2]), pstr(x[3]))
    for x in m.get('pipes') or []:
        t += "PIPE %s\n" % ' '.join(pstr(v) for v in x)
    for x in m.get('pumps') or []:
        t += "PUMP %s\n" % ' '.join(pstr(v) for v in x)
    for x in m.get('fixed') or []:
        t += "FIXEDFLOW %s %s %s\n" % (pstr(x[0]), pstr(x[1]), pstr(x[2]))
    nrv = m.get('nrv') or {}
    for k in sorted(nrv):
        t += "NRV %s %s\n" % (k, ' '.join(pstr(v) for v in nrv[k]))
    return t


def sgn(x):
    return (x > 0) - (x < 0)


def nodal(m):
    z = {}
    fixedH = {}
    for x in (m.get('nodes') or []) + (m.get('heads') or []) + (m.get('curve') or []):
        z[x[0]] = x[1]
    # A static supply is a node of fixed head -- unless it has a check valve,
    # when its node is free and the supply feeds it through the valve.
    nrv = dict(m.get('nrv') or {})
    vhead = {}
    for x in m.get('static') or []:
        z[x[0]] = x[1]
        if nrv.get(x[0]):
            vhead[x[0]] = x[2] + MH2O * x[1]
        else:
            fixedH[x[0]] = x[2] + MH2O * x[1]
    free = sorted(k for k in z if k not in fixedH)
    ix = {k: i for i, k in enumerate(free)}

    def R(l, d):
        return 6.05e7 * l / (120 ** 1.85 * d ** 4.87)

    def flows(H):
        def h(k):
            return fixedH[k] if k in fixedH else H[ix[k]]
        q = {}
        net = {}

        def add(k, v):
            net[k] = net.get(k, 0) + v
        for p in m.get('pipes') or []:
            id_, a, b, l, d = p
            dh = h(a) - h(b)
            f = sgn(dh) * (abs(dh) / R(l, d)) ** (1 / 1.85)
            q[id_] = f
            add(a, -f)
            add(b, f)
        for p in m.get('pumps') or []:
            id_, i, o, pc, q1, p1 = p
            lift = h(o) - h(i)
            f = 0 if lift >= pc else q1 * ((pc - lift) / (pc - p1)) ** (1 / 1.85)
            q[id_] = f
            add(i, -f)
            add(o, f)
        for s in m.get('heads') or []:
            p = h(s[0]) - MH2O * s[1]
            f = s[3] * math.sqrt(p if p > 0 else 0)
            q['out:' + s[0]] = f
            add(s[0], -f)
        for c in m.get('curve') or []:
            id_, zz, pc, q1, p1 = c
            p = h(id_) - MH2O * zz
            f = 0 if p >= pc else q1 * ((pc - p) / (pc - p1)) ** (1 / 1.85)
            q[id_] = f
            add(id_, f)
        for x in m.get('fixed') or []:
            add(x[1], -x[2])
        # A supply behind a check valve: no flow until the supply's head
        # exceeds the node's by the opening pressure, then the flow at which
        # the excess is the valve's loss, dP psi = (Q gpm / Cv)^2.
        for id_ in vhead:
            cv, crack = nrv[id_]
            x = vhead[id_] - h(id_) - crack
            f = 0 if x <= 0 else 3.785411784 * cv * math.sqrt(x / 6.894757)
            q[id_] = f
            add(id_, f)
        return q, [net.get(k, 0) for k in free]

    hmax = max(list(fixedH.values()) + list(vhead.values())
               + [c[2] + MH2O * c[1] for c in (m.get('curve') or [])])
    H = [hmax - 1 - i for i in range(len(free))]

    def norm(r):
        s = 0
        for v in r:
            s += v ** 2
        return math.sqrt(s)
    _, r = flows(H)
    for _it in range(400):
        if norm(r) < 1e-10:
            break
        n = len(free)
        J = [[0] * n for _ in range(n)]
        for j in range(n):
            Hp = list(H)
            dh = 1e-7 * (abs(H[j]) if abs(H[j]) > 1 else 1)
            Hp[j] += dh
            _, rp = flows(Hp)
            for i in range(n):
                J[i][j] = (rp[i] - r[i]) / dh
        # Gaussian elimination with partial pivoting: J dx = -r.
        A = [J[i] + [-r[i]] for i in range(n)]
        for c in range(n):
            # The first row of largest pivot (the Perl's stable sort).
            p = max(range(c, n), key=lambda i: abs(A[i][c]))
            A[c], A[p] = A[p], A[c]
            for i in range(c + 1, n):
                k = A[i][c] / A[c][c]
                for col in range(c, n + 1):
                    A[i][col] -= k * A[c][col]
        dx = [0] * n
        for i in reversed(range(n)):
            s = A[i][n]
            for col in range(i + 1, n):
                s -= A[i][col] * dx[col]
            dx[i] = s / A[i][i]
        # Damped: halve the step until the residual falls.
        t = 1
        for _ in range(40):
            Hn = [H[i] + t * dx[i] for i in range(n)]
            _, rn = flows(Hn)
            if norm(rn) < norm(r) or t < 1e-9:
                H = Hn
                r = rn
                break
            t /= 2
    q, _ = flows(H)
    p = {k: (fixedH[k] if k in fixedH else H[ix[k]]) - MH2O * z[k] for k in z}
    return q, p, norm(r)


def compare(name, m):
    n, ok = solve(phc_of(m))
    q, p, res = nodal(m)
    wq, wp, at = 0, 0, ''
    for id_ in q:
        mo = re.match(r'^out:(.*)', id_)
        eid = mo.group(1) if mo else id_
        e = elem(n, eid)
        if not e:
            continue
        d = abs(e['q'] - q[id_])
        if d > wq:
            wq, at = d, id_
    for id_ in p:
        d = abs(gauge(n, id_) - p[id_])
        if d > wp:
            wp = d
    validate.validate(n, ok)
    is_('%-16s flows within 0.01 L/min, pressures within 0.01 kPa (worst %.2e, %.2e)' % (name, wq, wp),
        ok and res < 1e-6 and wq < 0.01 and wp < 0.01,
        'worst flow at %s; reference residual %s' % (at, res))
    # The same network at PHCP's DEFAULT tolerances: within the verification limit.
    text = re.sub(r'^OPTION (TOL_FLOW|TOL_LOOP|MAXITER) .*\n', '', phc_of(m), flags=re.M)
    nd, okd = solve(text)
    wd = 0
    for id_ in p:
        d = abs(gauge(nd, id_) - p[id_])
        if d > wd:
            wd = d
    is_('%-16s at the default tolerances, pressures within the 0.1 kPa limit (%.3f)' % (name, wd),
        okd and wd <= validate.VERIFY_P)


def part_b():
    print("B. NETWORKS, AGAINST A NODAL NEWTON SOLVE")
    compare('series', {'static': [['S', 0, 900]], 'heads': [['H', 0, 50, 80]],
                       'pipes': [['P1', 'S', 'H', 100, 100]]})
    compare('branched', {'static': [['S', 0, 700]], 'nodes': [['A', 0], ['B', 3]],
                         'heads': [['H1', 3, 50, 80], ['H2', 3, 50, 80], ['H3', 0, 70, 115]],
                         'pipes': [['M', 'S', 'A', 40, 105.3], ['R', 'A', 'B', 3, 53.1], ['B1', 'B', 'H1', 4, 27.3],
                                   ['B2', 'B', 'H2', 8, 27.3], ['B3', 'A', 'H3', 12, 41.9]]})
    compare('looped', {'static': [['S', 0, 700]], 'nodes': [['A', 0], ['B', 0], ['C', 0]],
                       'heads': [['H', 0, 50, 80]],
                       'pipes': [['P1', 'S', 'A', 10, 100], ['P2', 'A', 'B', 50, 50], ['P3', 'A', 'C', 20, 25],
                                 ['P4', 'C', 'B', 20, 25], ['P5', 'B', 'H', 5, 50]]})
    # A 3 x 3 grid fed at one corner, four sprinklers at the far side.
    nodes, pipes, heads = [], [], []
    for i in range(1, 4):
        for j in range(1, 4):
            nodes.append(['G%d%d' % (i, j), 4])
    for i in range(1, 4):
        for j in range(1, 4):
            if j < 3:
                pipes.append(['X%d%d' % (i, j), 'G%d%d' % (i, j), 'G%d%d' % (i, j + 1), 3.5, 36.0])
            if i < 3:
                pipes.append(['Y%d%d' % (i, j), 'G%d%d' % (i, j), 'G%d%d' % (i + 1, j), 3.0, 41.9])
    for k in range(1, 4):
        heads.append(['H%d' % k, 4, 50, 80])
        pipes.append(['D%d' % k, 'G%d3' % k, 'H%d' % k, 0.6, 27.3])
    heads.append(['H4', 4, 50, 80])
    pipes.append(['D4', 'G32', 'H4', 0.6, 27.3])
    compare('gridded', {'static': [['S', 0, 650]], 'nodes': nodes, 'heads': heads,
                        'pipes': [['F', 'S', 'G11', 25, 80.9]] + pipes})
    compare('two supplies', {'static': [['A', 0, 950]], 'curve': [['D', 4, 900, 5000, 400]],
                             'nodes': [['B', 2]],
                             'heads': [['C', 2, 50, 80], ['E', 4, 50, 115], ['F', 6, 50, 80]],
                             'pipes': [['P1', 'A', 'B', 25, 150], ['P2', 'B', 'C', 30, 100], ['P3', 'C', 'D', 22, 100],
                                       ['P4', 'D', 'B', 35, 80], ['P5', 'C', 'E', 18, 80], ['P6', 'E', 'D', 20, 65],
                                       ['P7', 'E', 'F', 15, 50]],
                             'fixed': [['F1', 'B', 400]]})
    compare('pump', {'static': [['S', 0, 200]], 'nodes': [['D', 0], ['J', 6]],
                     'heads': [['H1', 6, 50, 80], ['H2', 6, 50, 80]],
                     'pipes': [['P1', 'D', 'J', 60, 105.3], ['B1', 'J', 'H1', 6, 41.9], ['B2', 'J', 'H2', 12, 41.9]],
                     'pumps': [['FP', 'S', 'D', 600, 3000, 450]]})

    # Two static supplies, the second weak and next to the outlets, behind a
    # check valve.  At this demand it would take water in: shut.  The nodal
    # solve finds its flow zero by itself; PHCP must find the valve CLOSED and
    # the same heads.
    NRV_NET = {'static': [['S1', 0, 900], ['S2', 0, 300]], 'nodes': [['A', 0], ['B', 0]],
               'heads': [['H1', 0, 50, 80], ['H2', 0, 50, 80]],
               'pipes': [['P1', 'S1', 'A', 60, 80.9], ['P2', 'A', 'B', 20, 80.9], ['P3', 'S2', 'B', 5, 105.3],
                         ['B1', 'B', 'H1', 4, 41.9], ['B2', 'A', 'H2', 6, 41.9]],
               'nrv': {'S2': [400, 7]}}
    compare('check valve shut', NRV_NET)
    n, _ = solve(phc_of(NRV_NET))
    q = nodal(NRV_NET)[0]
    is_('check valve shut: the nodal solve gives S2 no flow, PHCP closes it',
        q['S2'] == 0 and bool(elem(n, 'S2').get('closed')), 'nodal %s' % q['S2'])
    # The same, the outlets opened up: the network falls below S2 and its
    # valve opens, passing water with its opening pressure and Cv loss.
    open_ = dict(NRV_NET, heads=[['H1', 0, 50, 600], ['H2', 0, 50, 600]])
    compare('check valve open', open_)
    n, _ = solve(phc_of(open_))
    q = nodal(open_)[0]
    is_('check valve open: both give S2 flow, PHCP has it open',
        q['S2'] > 1 and not elem(n, 'S2').get('closed') and elem(n, 'S2')['q'] > 1,
        'nodal %s' % q['S2'])


def main():
    part_a()
    part_b()
    print('\n%d passed, %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
