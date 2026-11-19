#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# hardycross/__init__.py -- Python port of HardyCross.pm, the engine core.
#
# Everything is an EDGE over a virtual REF node at head zero.  Internal units
# L/min, kPa, m, mm; unit conversion happens once on input, never in the
# solver.  The port follows the Perl line for line: the same element order,
# the same reversed adjacency (unshift in Perl), the same iteration counts as
# the reference engine.  Arrays nodes/elems keep Perl's 1-based indexing with
# an unused sentinel at index 0, so element and node numbers match exactly.
#

import math

VERSION = '2.0.0'

GAMMA_W = 9.80665      # kPa per metre of water
Q_TINY  = 1.0e-6
D_TINY  = 1.0e-9
HWK_DEF = 6.05e7       # AS 2118.1 / NFPA 13 metric form, kPa/m basis

NRV_P_TINY = 1e-6      # kPa: the reopening test's margin against round-off
MAX_OUTER   = 60       # outer passes before a solve is declared unsettled
MAX_FLIP    = 8        # device state switches before the limit is enforced


# --------------------------------------------------------------------- errors
class ModelError(Exception):
    """A model error (reported to the user), not a programming error."""
    def __init__(self, msg):
        super().__init__(msg)
        self.msg = msg

def fail(fmt, *args):
    raise ModelError(fmt % args)

def is_model_error(e):
    return isinstance(e, ModelError)


# ---------------------------------------------------------------------- units
UNIT_TABLE = {
    'FLOW': {'LPM': 1, 'L/MIN': 1, 'LPS': 60, 'L/S': 60,
             'M3H': 1000 / 60, 'M3/H': 1000 / 60,
             'GPM': 3.785411784, 'USGPM': 3.785411784, 'IGPM': 4.54609},
    'PRESSURE': {'KPA': 1, 'BAR': 100, 'MPA': 1000, 'PSI': 6.894757,
                 'M': GAMMA_W, 'MH2O': GAMMA_W, 'MWC': GAMMA_W,
                 'FTH2O': GAMMA_W * 0.3048, 'FT': GAMMA_W * 0.3048},
    'LENGTH': {'M': 1, 'MM': 0.001, 'FT': 0.3048, 'IN': 0.0254},
    'DIAMETER': {'MM': 1, 'M': 1000, 'IN': 25.4},
}

def set_unit(net, quantity, name):
    alias = {'PRES': 'PRESSURE', 'LEN': 'LENGTH', 'DIA': 'DIAMETER'}
    quantity = alias.get(quantity, quantity)
    tbl = UNIT_TABLE.get(quantity)
    if tbl is None:
        fail('unknown UNITS entry %s', quantity)
    f = tbl.get(name)
    if f is None:
        fail('unknown unit %s for %s', name, quantity)
    slot  = {'FLOW': 'f_flow', 'PRESSURE': 'f_pres',
             'LENGTH': 'f_len', 'DIAMETER': 'f_dia'}[quantity]
    nslot = {'FLOW': 'u_flow', 'PRESSURE': 'u_pres',
             'LENGTH': 'u_len', 'DIAMETER': 'u_dia'}[quantity]
    net[slot] = f
    net[nslot] = name


# --------------------------------------------------------------------- curves
CURVE_N = 1.85

def fit_curve(c, rising):
    pt = sorted([[c['q'][i], c['p'][i]] for i in range(len(c['q']))],
                key=lambda z: z[0])
    if len(pt) < 2:
        fail('curve needs at least 2 points')
    for i in range(1, len(pt)):
        if abs(pt[i][0] - pt[i - 1][0]) < D_TINY:
            fail('curve points have identical flow')
    if pt[0][0] < 0:
        fail('curve flows cannot be negative')
    c['q'] = [z[0] for z in pt]
    c['p'] = [z[1] for z in pt]
    c['x'] = [z[0] ** CURVE_N for z in pt]
    c['qlo'] = c['q'][0]
    c['qhi'] = c['q'][-1]
    c['plo'] = c['p'][0]
    c['phi'] = c['p'][-1]
    c['slo'] = curve_inner_slope(c, c['qlo'])
    c['shi'] = curve_inner_slope(c, c['qhi'])
    span = (c['qhi'] - c['qlo']) if (c['qhi'] - c['qlo']) > D_TINY else D_TINY
    chord = (c['phi'] - c['plo']) / span
    if rising:
        if c['slo'] < D_TINY:
            c['slo'] = chord if chord > D_TINY else D_TINY
        if c['shi'] < D_TINY:
            c['shi'] = chord if chord > D_TINY else D_TINY
    else:
        if c['slo'] > -D_TINY:
            c['slo'] = chord if chord < -D_TINY else -D_TINY
        if c['shi'] > -D_TINY:
            c['shi'] = chord if chord < -D_TINY else -D_TINY
    return c

def curve_segment(c, q):
    n = len(c['q']) - 1
    for i in range(n - 1):
        if q <= c['q'][i + 1]:
            return i
    return n - 1

def curve_inner_slope(c, q):
    i = curve_segment(c, q)
    m = (c['p'][i + 1] - c['p'][i]) / (c['x'][i + 1] - c['x'][i])
    return m * CURVE_N * (q ** (CURVE_N - 1) if q > 0 else 0)

def curve_eval(c, q):
    if q < c['qlo']:
        return c['plo'] + c['slo'] * (q - c['qlo'])
    if q > c['qhi']:
        return c['phi'] + c['shi'] * (q - c['qhi'])
    i = curve_segment(c, q)
    x0, x1 = c['x'][i], c['x'][i + 1]
    return c['p'][i] + (c['p'][i + 1] - c['p'][i]) * (q ** CURVE_N - x0) / (x1 - x0)

def curve_slope(c, q):
    if q < c['qlo']:
        return c['slo']
    if q > c['qhi']:
        return c['shi']
    s = curve_inner_slope(c, q)
    if abs(s) < D_TINY:
        return c['slo']
    return s


# ------------------------------------------------------- element hydraulics
def pipe_velocity(q, dia):
    if dia <= D_TINY:
        return 0
    return (q / 60000) / (3.14159265358979 * (dia / 1000) ** 2 / 4)

def dw_friction(re, eps, d):
    if re < 1:
        return 0
    if re < 2000:
        return 64 / re
    rr = eps / (3.7 * d)
    lg = lambda v: math.log(v) / math.log(10)
    a = -2 * lg(rr + 12 / re)
    b = -2 * lg(rr + 2.51 * a / re)
    c = -2 * lg(rr + 2.51 * b / re)
    den = c - 2 * b + a
    if abs(den) < 1e-12:
        f = 1 / (a ** 2)
    else:
        f = 1 / ((a - (b - a) ** 2 / den) ** 2)
    if re < 4000:
        t = (re - 2000) / 2000
        f = (1 - t) * (64 / re) + t * f
    return f

def pipe_hf_dw(e, aq, o):
    ltot = e['len'] + e['eqv']
    dm = e['dia'] / 1000
    vel = pipe_velocity(aq, e['dia'])
    nu = o.get('nu') if o.get('nu') is not None else 1.004e-6
    re = vel * dm / nu
    f = dw_friction(re, e['eps'], e['dia'])
    return f * (ltot / dm) * vel ** 2 / (2 * GAMMA_W) * GAMMA_W

def orifice_dp(aq, d, bigd, cd=None):
    if cd is None:
        cd = 0.596
    if d <= D_TINY or aq <= 0:
        return 0
    beta = (d / bigd if bigd > D_TINY and d / bigd < 0.99999 else
            (0.99999 if bigd > D_TINY else 0))
    b4 = beta ** 4
    t = 1 - b4 * (1 - cd ** 2)
    s = math.sqrt(t if t > 1e-12 else 1e-12)
    cb2 = cd * beta ** 2
    r = (s - cb2) / (s + cb2)
    if r < 0:
        r = 0
    return 633.28 * (0.596 / cd) ** 2 * aq ** 2 / d ** 4 * (1 - b4) * r

def orifice_size(aq, target, bigd, cd=None):
    if aq <= Q_TINY or target <= D_TINY or bigd <= D_TINY:
        return 0
    lo, hi = 0.001 * bigd, 0.9995 * bigd
    if orifice_dp(aq, hi, bigd, cd) > target:
        return hi
    if orifice_dp(aq, lo, bigd, cd) < target:
        return lo
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if orifice_dp(aq, mid, bigd, cd) > target:
            lo = mid
        else:
            hi = mid
        if hi - lo < 1e-9 * bigd:
            break
    return 0.5 * (lo + hi)

def b3_reference_flow(dn):
    return 500 if (dn == 50 or dn == 65) else 5000

def elem_hf(e, q, o):
    aq = abs(q)
    sg = -1 if (q < 0 and aq >= Q_TINY) else 1
    k = e['kind']

    if k == 'PIPE':
        # Minor loss from fittings as a velocity-head multiplier (see the
        # WHICH METHOD THIS BELONGS TO note in HardyCross.pm: K is applied
        # under both formulas so the two engines agree).
        kfit = e.get('kfit')
        if kfit is not None and kfit > 0:
            def minor(v):
                vel = pipe_velocity(v, e['dia'])
                return kfit * vel ** 2 / (2 * GAMMA_W) * GAMMA_W
        else:
            def minor(v):
                return 0
        if (o.get('method') if o.get('method') is not None else 'HW') == 'DW':
            hf = pipe_hf_dw(e, aq, o) + minor(aq)
            dq = 1e-4 if 1e-4 > 1e-5 * aq else 1e-5 * aq
            hp = pipe_hf_dw(e, aq + dq, o) + minor(aq + dq)
            lo = aq - dq if aq - dq > 0 else 0
            hm = pipe_hf_dw(e, lo, o) + minor(lo)
            return (sg * hf, (hp - hm) / (2 * dq))
        ltot = e['len'] + e['eqv']
        hwk, nq, nd = o['hwk'], o['hwq'], o['hwd']
        friction = (hwk * ltot * aq ** nq / (e['c'] ** nq * e['dia'] ** nd)
                    if aq > 0 else 0)
        hf = friction + minor(aq)
        if kfit is not None and kfit > 0:
            dq = 1e-4 if 1e-4 > 1e-5 * aq else 1e-5 * aq
            def f(v):
                fr = (hwk * ltot * v ** nq / (e['c'] ** nq * e['dia'] ** nd)
                      if v > 0 else 0)
                return fr + minor(v)
            lo = aq - dq if aq - dq > 0 else 0
            return (sg * hf, (f(aq + dq) - f(lo)) / (2 * dq))
        if aq > Q_TINY:
            dh = nq * friction / aq
        else:
            dia = e['dia'] if e['dia'] > D_TINY else D_TINY
            dh = nq * hwk * ltot * Q_TINY ** (nq - 1) / (e['c'] ** nq * dia ** nd)
        return (sg * hf, dh)

    if k == 'PUMP':
        # A booster in line: H2 = H1 + Ppump(q), so hf is negative.
        return (-curve_eval(e['curve'], q), abs(curve_slope(e['curve'], q)))

    if k == 'SUPPLY_STATIC':
        vl, vd = check_valve_loss(e, q)
        z = e.get('z')
        z = 0 if z is None else z
        return (-(e['pstat'] + GAMMA_W * z) + vl, vd)

    if k == 'SUPPLY_CURVE':
        vl, vd = check_valve_loss(e, q)
        z = e.get('z')
        z = 0 if z is None else z
        return (-(curve_eval(e['curve'], q) + GAMMA_W * z) + vl,
                abs(curve_slope(e['curve'], q)) + vd)

    if k == 'DISCHARGE':
        kf = e['k'] if e['k'] > D_TINY else D_TINY
        dh = 2 * aq / kf ** 2
        if dh < D_TINY:
            dh = 2 * Q_TINY / kf ** 2
        z = e.get('z')
        z = 0 if z is None else z
        hf = sg * (aq / kf) ** 2 + GAMMA_W * z
        if e.get('pv'):
            hf += e['pv']
        return (hf, dh)

    if k == 'FIXED_DROP' or k == 'ORIFICE_REQUIRED' or k == 'RATIO':
        return (sg * e['dp'], 0)

    if k == 'ORIFICE':
        pd = orifice_dp(aq, e['bore'], e['pipedia'], e.get('cd'))
        dh = (2 * pd / aq if aq > Q_TINY
              else 2 * orifice_dp(Q_TINY, e['bore'], e['pipedia'], e.get('cd')) / Q_TINY)
        return (sg * pd, dh)

    if k == 'BFP':
        return (sg * curve_eval(e['curve'], aq), abs(curve_slope(e['curve'], aq)))

    if k == 'DPV':
        basis = e.get('loss')
        basis = 'NONE' if basis is None else basis
        if basis == 'CURVE':
            return (sg * curve_eval(e['curve'], aq),
                    abs(curve_slope(e['curve'], aq)))
        if basis == 'DB' and e.get('cv'):
            kq = 6.894757 / (e['cv'] * 3.785411784) ** 2
            dh = 2 * kq * (aq if aq > Q_TINY else Q_TINY)
            return (sg * kq * aq ** 2, dh)
        if basis == 'DB':
            l = e['eql']
            hf = (HWK_DEF * l * aq ** 1.85 / (e['ref_c'] ** 1.85 * e['ref_bore'] ** 4.87)
                  if aq > 0 else 0)
            dh = (1.85 * hf / aq if aq > Q_TINY
                  else 1.85 * HWK_DEF * l * Q_TINY ** 0.85
                  / (e['ref_c'] ** 1.85 * e['ref_bore'] ** 4.87))
            return (sg * hf, dh)
        if basis == 'EQL' and e.get('host'):
            if e.get('pseudo') is None:
                e['pseudo'] = {'kind': 'PIPE', 'id': e['id'] + '.EQL', 'len': e['eql'],
                               'eqv': 0, 'dia': e['host']['dia'], 'c': e['host']['c'],
                               'eps': e['host']['eps']}
            return elem_hf(e['pseudo'], q, o)
        return (0, 0)

    raise RuntimeError("internal error: no hydraulics for element kind '%s'" % k)

# check_valve_loss -- (loss kPa, d loss / dq) of an OPEN check valve at a
# supply; (0, 0) without one.  The opening term is NOT signed with the flow
# (see HardyCross.pm for why); the flow term is.
KPA_PER_LPM2 = 6.894757 / 3.785411784 ** 2

def check_valve_loss(e, q):
    v = e.get('nrv')
    if not v:
        return (0, 0)
    aq = abs(q)
    sg = -1 if (q < 0 and aq >= Q_TINY) else 1
    loss = v.get('crack')
    loss = 0 if loss is None else loss
    dh = 0
    if v.get('curve'):
        loss += sg * curve_eval(v['curve'], aq)
        dh = abs(curve_slope(v['curve'], aq))
    else:
        cv = v.get('cv')
        cv = 0 if cv is None else cv
        if cv > 0:
            kq = KPA_PER_LPM2 / cv ** 2
            loss += sg * kq * aq ** 2
            dh = 2 * kq * (aq if aq > Q_TINY else Q_TINY)
    return (loss, dh)


# ------------------------------------------------------------------ topology
def elem_rank(e):
    k = e['kind']
    if k == 'SUPPLY_STATIC' or k == 'SUPPLY_CURVE':
        return 2
    if k == 'DISCHARGE':
        return 3
    return 1

def central_root(net, adj):
    iref = net['iref']
    nn = len(adj) - 1
    start = None
    for i in range(1, nn + 1):
        if i != iref and adj[i]:
            start = i
            break
    if start is None:
        return iref

    def sweep(s):
        dist = {s: 0}
        par = {}
        q = [s]
        qi = 0
        while qi < len(q):
            v = q[qi]; qi += 1
            for (w, ei) in adj[v]:
                if w in dist:
                    continue
                if elem_rank(net['elems'][ei]) != 1:
                    continue
                dist[w] = dist[v] + 1
                par[w] = v
                q.append(w)
        best, far = -1, s
        for i in range(1, nn + 1):
            if i == iref or i not in dist:
                continue
            if dist[i] > best:
                best, far = dist[i], i
        return (far, par, dist)

    u = sweep(start)[0]
    v, par, dist = sweep(u)
    for _ in range(int(dist[v] / 2)):
        if v not in par:
            break
        v = par[v]
    return v

def build_tree(net):
    nn = len(net['nodes']) - 1
    ne = len(net['elems']) - 1
    adj = [[] for _ in range(nn + 1)]
    for ei in range(1, ne + 1):
        e = net['elems'][ei]
        # A pump shut on its check valve is REMOVED from the graph (see
        # HardyCross.pm).  unshift in Perl: each node's neighbours are
        # visited in REVERSE element order -- that is what the reference
        # C++ engine does and it decides the spanning tree on a grid.
        if e.get('closed'):
            continue
        adj[e['n1']].append((e['n2'], ei))
        adj[e['n2']].append((e['n1'], ei))
    for a in adj:
        a.reverse()
    for i in range(1, nn + 1):
        n = net['nodes'][i]
        n['visited'] = 0; n['pelem'] = 0; n['pnode'] = 0; n['depth'] = 0
    for ei in range(1, ne + 1):
        net['elems'][ei]['in_tree'] = 0

    root = central_root(net, adj)
    net['nodes'][root]['visited'] = 1

    for phase in (1, 2, 3):
        if phase == 1:
            queue = [root]
        else:
            queue = [i for i in range(1, nn + 1) if net['nodes'][i]['visited']]
        qi = 0
        while qi < len(queue):
            v = queue[qi]; qi += 1
            for (w, ei) in adj[v]:
                e = net['elems'][ei]
                if elem_rank(e) > phase or net['nodes'][w]['visited']:
                    continue
                net['nodes'][w]['visited'] = 1
                e['in_tree'] = 1
                queue.append(w)

    all_isolated = not any(i != net['iref'] and not net['nodes'][i].get('isolated')
                           for i in range(1, nn + 1))
    if not (net['nodes'][net['iref']]['visited'] or all_isolated):
        fail('the network has no supply and no discharge - nothing anchors it to datum')
    for i in range(1, nn + 1):
        if net['nodes'][i].get('isolated') or (all_isolated and i == net['iref']):
            continue
        if not net['nodes'][i]['visited']:
            fail('node %s is not connected to the rest of the network',
                 net['nodes'][i]['id'])

    # Re-root at REF: the tree path between any two nodes is unaffected.
    seen = [0] * (nn + 1)
    queue = [net['iref']]
    seen[net['iref']] = 1
    qi = 0
    while qi < len(queue):
        v = queue[qi]; qi += 1
        for (w, ei) in adj[v]:
            if not (net['elems'][ei]['in_tree'] and not seen[w]):
                continue
            seen[w] = 1
            nw = net['nodes'][w]
            nw['pelem'] = ei
            nw['pnode'] = v
            nw['depth'] = net['nodes'][v]['depth'] + 1
            queue.append(w)
    return net

def build_loops(net):
    ne = len(net['elems']) - 1
    loops = []
    for ei in range(1, ne + 1):
        e = net['elems'][ei]
        if e['in_tree'] or e.get('closed'):
            continue
        a, b = e['n1'], e['n2']
        pa, pb = [], []
        def climb(v, acc):
            n = net['nodes'][v]
            pe = net['elems'][n['pelem']]
            acc.append([n['pelem'], 1 if pe['n1'] == v else -1])
            return n['pnode']
        while net['nodes'][a]['depth'] > net['nodes'][b]['depth']:
            a = climb(a, pa)
        while net['nodes'][b]['depth'] > net['nodes'][a]['depth']:
            b = climb(b, pb)
        while a != b:
            a = climb(a, pa)
            b = climb(b, pb)
        # chord n1->n2, up from n2 to the ancestor, back down to n1
        loops.append([[ei, 1]] + pb + [[s[0], -s[1]] for s in reversed(pa)])
    net['loops'] = loops
    return net

def init_flows(net):
    nn = len(net['nodes']) - 1
    ne = len(net['elems']) - 1

    qtot = 0
    for i in range(1, nn + 1):
        qtot += net['nodes'][i]['demand']
    for ei in range(1, ne + 1):
        e = net['elems'][ei]
        if e['kind'] != 'DISCHARGE':
            continue
        seed = e['k'] * math.sqrt(e['preq'] if e['preq'] > 0 else 0)
        qtot += e['qreq'] if e['qreq'] > seed else seed
    q0 = 0.5 * qtot
    if q0 < 50:
        q0 = 50
    net['opts']['q0'] = q0

    for ei in range(1, ne + 1):
        e = net['elems'][ei]
        if e.get('closed'):
            e['q'] = 0
            continue
        if e['in_tree']:
            continue
        if e['kind'] == 'DISCHARGE':
            seed = e['qreq']
            if seed <= Q_TINY:
                seed = e['k'] * math.sqrt(e['preq'] if e['preq'] > 50 else 50)
            if seed <= Q_TINY:
                seed = q0
            e['q'] = seed
        else:
            e['q'] = q0

    acc = [0] * (nn + 1)
    for i in range(1, nn + 1):
        acc[i] = net['nodes'][i]['demand']
    for ei in range(1, ne + 1):
        e = net['elems'][ei]
        if e['in_tree'] or e.get('closed'):
            continue
        acc[e['n1']] += e['q']
        acc[e['n2']] -= e['q']
    maxd = 0
    for i in range(1, nn + 1):
        if net['nodes'][i]['depth'] > maxd:
            maxd = net['nodes'][i]['depth']
    for d in range(maxd, 0, -1):
        for v in range(1, nn + 1):
            n = net['nodes'][v]
            if n['depth'] != d or not n['pelem']:
                continue
            e = net['elems'][n['pelem']]
            s = acc[v]
            e['q'] = s if e['n2'] == v else -s
            acc[n['pnode']] += s
            acc[v] = 0
    return net

def continuity_error(net):
    nn = len(net['nodes']) - 1
    acc = [0] * (nn + 1)
    for i in range(1, nn + 1):
        acc[i] = net['nodes'][i]['demand']
    for ei in range(1, len(net['elems'])):
        e = net['elems'][ei]
        if e.get('closed'):
            continue
        acc[e['n1']] += e['q']
        acc[e['n2']] -= e['q']
    acc[net['iref']] = 0
    m = 0
    for i in range(1, nn + 1):
        if abs(acc[i]) > m:
            m = abs(acc[i])
    return m

def recover_heads(net):
    nn = len(net['nodes']) - 1
    for i in range(1, nn + 1):
        net['nodes'][i]['h'] = 0
    maxd = 0
    for i in range(1, nn + 1):
        if net['nodes'][i]['depth'] > maxd:
            maxd = net['nodes'][i]['depth']
    for d in range(1, maxd + 1):
        for v in range(1, nn + 1):
            n = net['nodes'][v]
            if n['depth'] != d or not n['pelem']:
                continue
            e = net['elems'][n['pelem']]
            hf = elem_hf(e, e['q'], net['opts'])[0]
            ph = net['nodes'][n['pnode']]['h']
            n['h'] = ph - hf if e['n1'] == n['pnode'] else ph + hf
    for i in range(1, nn + 1):
        n = net['nodes'][i]
        if n.get('isolated'):
            z = n.get('z')
            z = 0 if z is None else z
            n['h'] = GAMMA_W * z
    return net

#   dQ = -SUM(s*hf) / SUM(|dhf/dq|), applied one loop at a time.
def solve_network(net, **a):
    maxiter = a.get('maxiter') if a.get('maxiter') is not None else 50000
    tolflow = a.get('tol_flow') if a.get('tol_flow') is not None else 0.05
    tolloop = a.get('tol_loop') if a.get('tol_loop') is not None else 0.01
    q0 = net['opts'].get('q0')
    q0 = 100 if q0 is None else q0
    elems = net['elems']
    o = net['opts']

    net['converged'] = 0
    net['history'] = []
    net['degenerate'] = []
    it = 0

    while it < maxiter:
        it += 1
        maxdq, maxres = 0, 0
        degen = {}
        for li in range(len(net['loops'])):
            lp = net['loops'][li]
            sumh, sumd, qscale = 0, 0, 0
            for step in lp:
                e = elems[step[0]]
                hf, dh = elem_hf(e, e['q'], o)
                sumh += step[1] * hf
                sumd += dh
                if abs(e['q']) > qscale:
                    qscale = abs(e['q'])
            if sumd < 1e-10 and abs(sumh) > tolloop:
                degen[li] = 1
            dq = 0 if sumd < 1e-10 else -sumh / sumd
            lim = 2 * (qscale + q0)
            if abs(dq) > lim:
                dq = lim if dq > 0 else -lim
            if abs(sumh) > maxres:
                maxres = abs(sumh)
            if abs(dq) > maxdq:
                maxdq = abs(dq)
            for step in lp:
                elems[step[0]]['q'] += step[1] * dq
        net['history'].append([it, maxdq, maxres])
        net['degenerate'] = sorted(degen.keys())

        for ei in range(1, len(elems)):
            q = elems[ei]['q']
            if q != q or abs(q) > 1e15:
                net['iters'] = it
                net['nonconv'] = 'diverged'
                return 0
        if maxdq <= tolflow and maxres <= tolloop:
            # Measure every loop against the flows as they now stand before
            # declaring convergence (see HardyCross.pm).
            true = 0
            for lp in net['loops']:
                sumh = 0
                for step in lp:
                    e = elems[step[0]]
                    hf = elem_hf(e, e['q'], o)[0]
                    sumh += step[1] * hf
                if abs(sumh) > true:
                    true = abs(sumh)
            if true <= tolloop:
                net['converged'] = 1
                break
    net['iters'] = it
    net['nonconv'] = None if net['converged'] else iteration_diagnosis(net['history'])
    recover_heads(net)
    return net['converged']

def iteration_diagnosis(h):
    if not h:
        return 'no_iterations'
    n = len(h)
    if n < 20:
        return 'slow'
    w = int(n / 10)
    last = [z[1] for z in h[n - w:n]]
    prev = [z[1] for z in h[n - 2 * w:n - w]]
    def mean(xs):
        return sum(xs) / len(xs)
    ml, mp = mean(last), mean(prev)
    if ml > 1.5 * mp and last[-1] > last[0]:
        return 'diverging'
    turns = 0
    for i in range(1, len(last) - 1):
        d1 = last[i] - last[i - 1]
        d2 = last[i + 1] - last[i]
        if d1 * d2 < 0:
            turns += 1
    if len(last) - 1 > 2 and turns > 0.5 * (len(last) - 2) and ml >= 0.9 * mp:
        return 'oscillating'
    if ml >= 0.99 * mp:
        return 'stalled'
    return 'slow'

# ------------------------------------------------------------- outer loop
def size_orifices(net):
    changed = 0
    for ei in range(1, len(net['elems'])):
        e = net['elems'][ei]
        if e['kind'] != 'ORIFICE_REQUIRED':
            continue
        if e.get('isolated'):
            continue
        q = abs(e['q'])
        bore = orifice_size(q, e['dp'], e['pipedia'], e.get('cd'))
        lo, hi = 0.001 * e['pipedia'], 0.9995 * e['pipedia']
        e['dp_target'] = e['dp']
        e['q_sized'] = q
        e['bore_exact'] = bore
        if q <= Q_TINY:
            e['size_clamp'] = 'NO_FLOW'
        elif orifice_dp(q, hi, e['pipedia'], e.get('cd')) > e['dp']:
            e['size_clamp'] = 'BORE_MAX'
        elif orifice_dp(q, lo, e['pipedia'], e.get('cd')) < e['dp']:
            e['size_clamp'] = 'BORE_MIN'
        else:
            e.pop('size_clamp', None)
        step = net['opts'].get('orif_step')
        step = 0.5 if step is None else step
        if step > 0:
            r = int(bore / step + 0.5) * step
            if r >= e['pipedia'] - 1e-9:
                r = (math.ceil(e['pipedia'] / step) - 1) * step
                e['bore_rounding'] = 'DOWN_BELOW_PIPE_BORE'
            elif r <= 0:
                r = step
                e['bore_rounding'] = 'UP_TO_ONE_STEP'
            bore = r
        e['kind'] = 'ORIFICE'
        e['bore'] = bore
        changed = 1
    return changed

def pump_status(net):
    changed = 0
    closed_now = []

    for ei in range(1, len(net['elems'])):
        e = net['elems'][ei]
        if e['kind'] != 'PUMP':
            continue
        if e.get('isolated'):
            continue
        if (e.get('nflips') if e.get('nflips') is not None else 0) > MAX_FLIP:
            if not e.get('closed'):
                wrong = e['q'] < -Q_TINY
            else:
                wrong = ((net['nodes'][e['n2']]['h'] - net['nodes'][e['n1']]['h'])
                         < curve_eval(e['curve'], 0) - Q_TINY)
            if wrong and not e.get('isolating'):
                e['flip_limit'] = 1
            else:
                e.pop('flip_limit', None)
            continue

        if not e.get('closed'):
            if e['q'] < -Q_TINY:
                e['closed'] = 1
                e['q'] = 0
                e['nflips'] = e.get('nflips', 0) + 1
                changed = 1
                closed_now.append(e)
        else:
            shut = curve_eval(e['curve'], 0)
            lift = net['nodes'][e['n2']]['h'] - net['nodes'][e['n1']]['h']
            if lift < shut - Q_TINY:
                e['closed'] = 0
                e['nflips'] = e.get('nflips', 0) + 1
                changed = 1
    if not changed:
        return 0

    # Closing a pump must not isolate part of the network: revert only the
    # pumps closed on THIS pass (10 November 2026 fix), then rebuild in full.
    isolated = False
    try:
        build_tree(net)
    except ModelError:
        isolated = True
    if isolated:
        for e in closed_now:
            e['closed'] = 0
            e['isolating'] = 1
            e['nflips'] = MAX_FLIP + 1     # stop reconsidering it
        if 'warnings' not in net or net.get('warnings') is None:
            net['warnings'] = []
        net['warnings'].append(
            'closing a pump check valve would isolate part of the network, '
            'so the pump has been left open; the reverse flow reported '
            'through it is not physically possible')
        build_tree(net)
    build_loops(net)
    init_flows(net)
    return 1

def supply_head0(e):
    p = e['pstat'] if e['kind'] == 'SUPPLY_STATIC' else curve_eval(e['curve'], 0)
    z = e.get('z')
    z = 0 if z is None else z
    return p + GAMMA_W * z

def supply_status(net):
    changed = 0

    # A bounded trial reopening of an isolated supply (see HardyCross.pm).
    retry = [e for e in net['elems'][1:]
             if e.get('nrv') and e.get('isolated') and e.get('check_closed')
             and not e.get('out_of_service') and not e.get('isolation_retry')
             and supply_head0(e) - GAMMA_W * net['nodes'][e['n2']]['z']
                 > e['nrv'].get('crack') + NRV_P_TINY]
    if retry:
        clear_isolation(net)
        for e in retry:
            e['closed'] = 0; e['check_closed'] = 0; e['isolation_retry'] = 1
            e['nflips'] = e.get('nflips', 0) + 1
        isolate_unsupplied(net)
        build_tree(net)
        build_loops(net)
        init_flows(net)
        return 1
    for e in [x for x in net['elems'][1:] if x.get('nrv')]:
        if not e['kind'].startswith('SUPPLY_'):
            continue
        e.pop('flip_limit', None)
        if e.get('out_of_service') or e.get('isolated'):
            continue
        want = None
        if not e.get('closed'):
            if e['q'] < -Q_TINY:
                want = 'close'
        else:
            h = net['nodes'][e['n2']]['h']
            if supply_head0(e) - h > e['nrv'].get('crack') + NRV_P_TINY:
                want = 'open'
        if not want:
            continue
        if (e.get('nflips') if e.get('nflips') is not None else 0) > MAX_FLIP:
            e['flip_limit'] = 1
            continue
        if want == 'close':
            e['closed'] = 1; e['check_closed'] = 1; e['q'] = 0
        else:
            e['closed'] = 0; e['check_closed'] = 0
        e['nflips'] = e.get('nflips', 0) + 1
        changed = 1
    if not changed:
        return 0
    isolate_unsupplied(net)
    build_tree(net)
    build_loops(net)
    init_flows(net)
    return 1

def clear_isolation(net):
    for n in net['nodes'][1:]:
        if n.pop('isolated', None) is None:
            continue
        if 'demand_isolated' in n:
            n['demand'] = n.pop('demand_isolated')
    for e in net['elems'][1:]:
        if e.pop('isolated', None) is None:
            continue
        pre = e.pop('pre_isolation_closed', 0)
        e['closed'] = pre if pre is not None else 0
        e['q'] = 0
    for f in net.get('fixed') or []:
        if f.pop('isolated', None) is None:
            continue
        if 'pre_isolation_q' in f:
            f['q'] = f.pop('pre_isolation_q')
    net.pop('supply_isolated', None)

def isolate_unsupplied(net):
    nn = len(net['nodes']) - 1
    iref = net['iref']
    el = net['elems'][1:]
    adj = {}
    start = []
    for e in el:
        k = e['kind']
        if k.startswith('SUPPLY_'):
            if not e.get('closed'):
                start.append(e['n2'])
            continue
        if k == 'DISCHARGE' or e.get('isolated'):
            continue
        adj.setdefault(e['n1'], []).append(e['n2'])
        adj.setdefault(e['n2'], []).append(e['n1'])
    seen = {s: 1 for s in start}
    q = list(start)
    qi = 0
    while qi < len(q):
        v = q[qi]; qi += 1
        for w in adj.get(v, []):
            if w not in seen:
                seen[w] = 1
                q.append(w)
    dead = [i for i in range(1, nn + 1)
            if i != iref and i not in seen and not net['nodes'][i].get('isolated')]
    if not dead:
        return 0
    deadset = set(dead)
    if net.get('supply_isolated') is None:
        net['supply_isolated'] = {'nodes': [], 'index': [], 'supplies': [], 'outlets': []}
    iso = net['supply_isolated']
    for i in dead:
        n = net['nodes'][i]
        n['isolated'] = 1
        n['demand_isolated'] = n['demand']
        n['demand'] = 0
        iso['nodes'].append(n['id'])
        iso['index'].append(i)
    for e in el:
        if not (e['n1'] in deadset or e['n2'] in deadset):
            continue
        e['pre_isolation_closed'] = 1 if e.get('closed') else 0
        e['closed'] = 1; e['isolated'] = 1; e['q'] = 0
        if e['kind'].startswith('SUPPLY_'):
            iso['supplies'].append(e['id'])
        if e['kind'] == 'DISCHARGE':
            iso['outlets'].append(e['id'])
    for f in net.get('fixed') or []:
        if f['n1'] in deadset:
            f['pre_isolation_q'] = f['q']
            f['q'] = 0
            f['isolated'] = 1
            iso['outlets'].append(f['id'])
    return 1

def ratio_valves(net):
    tol = net['opts'].get('tol_loop')
    tol = 0.01 if tol is None else tol
    side = 1 if (net['opts'].get('pra_side') or 'LOW') == 'HIGH' else -1
    changed = 0
    for e in [x for x in net['elems'][1:] if x['kind'] == 'RATIO']:
        n = net['nodes'][e['n1']]
        pin = n['h'] - GAMMA_W * n['z']
        band = e.get('band')
        band = 0.05 if band is None else band
        out = pin * (1 / e['ratio'] + side * band)
        dp = pin - (out if out > 0 else 0) if pin > 0 else 0
        if abs(dp - e['dp']) > tol:
            e['dp'] = dp
            changed = 1
        e['pin'] = pin
    return changed

def ratio_warnings(net, settled):
    w = []
    for e in [x for x in net['elems'][1:] if x['kind'] == 'RATIO']:
        if e['q'] < -Q_TINY:
            w.append('pressure ratio valve %s: flow runs backwards through it, which a ratio '
                     'valve does not pass - the model needs another route for that water' % e['id'])
        if e.get('mininlet') is not None and (e.get('pin') or 0) < e['mininlet']:
            w.append('pressure ratio valve %s: inlet pressure %.1f kPa is below its minimum '
                     'inlet pressure of %.1f kPa; it will not hold its ratio'
                     % (e['id'], e.get('pin') or 0, e['mininlet']))
    if not settled:
        w.append('the pressure ratio valve drops had not settled when the solve stopped; '
                 'the results must be checked')
    return w

def velocity_pressures(net):
    if not net['opts'].get('vel_press'):
        return 0
    tol = net['opts'].get('tol_loop')
    tol = 0.01 if tol is None else tol
    elems = net['elems']

    feed, fq, out = {}, {}, {}
    for ei in range(1, len(elems)):
        e = elems[ei]
        if e.get('closed') or e['kind'] == 'DISCHARGE':
            continue
        if not abs(e['q']) > Q_TINY:
            continue
        if e['q'] > 0:
            to, frm = e['n2'], e['n1']
        else:
            to, frm = e['n1'], e['n2']
        out[frm] = 1
        if e['kind'] == 'PIPE' and abs(e['q']) > fq.get(to, 0):
            feed[to] = e
            fq[to] = abs(e['q'])

    changed = 0
    for e in elems[1:]:
        if e['kind'] != 'DISCHARGE' or (e.get('otype') or '').upper() != 'SPRINKLER':
            continue
        v = e['n1']
        f = feed.get(v) if out.get(v) else None
        pv = 0.5 * pipe_velocity(fq[v], f['dia']) ** 2 if f else 0
        if abs(pv - (e.get('pv') or 0)) > tol:
            changed = 1
        e['pv'] = pv
        e['pv_pipe'] = f['id'] if f else None
        e['pv_end'] = not out.get(v)
    return changed

def outlet_pressure(net, e):
    p = net['nodes'][e['n1']]['h'] - GAMMA_W * e['z']
    if e.get('pv'):
        p -= e['pv']
    return p

def link_devices(net):
    pipe = {e['id']: e for e in net['elems'][1:] if e['kind'] == 'PIPE'}
    for e in [x for x in net['elems'][1:] if x['kind'] == 'DPV']:
        if e.get('host_id') is None:
            continue
        e['host'] = pipe.get(e['host_id'])
        e.pop('pseudo', None)

def solve_model(net):
    net.pop('assessment', None)
    for e in net['elems'][1:]:
        e.pop('isolation_retry', None)
    link_devices(net)
    build_tree(net)
    build_loops(net)
    init_flows(net)
    ok = solve_network(net,
                       maxiter=net['opts'].get('maxiter'),
                       tol_flow=net['opts'].get('tol_flow'),
                       tol_loop=net['opts'].get('tol_loop'))
    # Outer loop: see HardyCross.pm for the two 10 November 2026 rules -- no
    # device is adjusted on an unconverged inner solve, and the solve succeeds
    # only if the outer loop settled.
    settled, passes, stop = 0, 0, 'pass_limit'
    for _ in range(MAX_OUTER):
        if not ok:
            stop = 'inner_not_converged'
            break
        passes += 1
        sized = size_orifices(net)
        pumped = pump_status(net)
        valved = supply_status(net)
        ratio = ratio_valves(net)
        vp = velocity_pressures(net)
        if not (sized or pumped or valved or ratio or vp):
            settled, stop = 1, 'settled'
            break
        ok = solve_network(net,
                           maxiter=net['opts'].get('maxiter'),
                           tol_flow=net['opts'].get('tol_flow'),
                           tol_loop=net['opts'].get('tol_loop'))
    net['hc_converged'] = 1 if ok else 0
    net['outer_settled'] = settled
    net['outer_passes'] = passes
    net['outer_stop'] = stop
    if any(e['kind'] == 'RATIO' for e in net['elems'][1:]):
        net.setdefault('warnings', [])
        net['warnings'] += ratio_warnings(net, settled)
    if net['opts'].get('vel_press') and not settled:
        net.setdefault('warnings', [])
        net['warnings'].append('the sprinkler velocity pressures had not settled when the solve '
                               'stopped; the results must be checked')
    if ok and not settled:
        net.setdefault('warnings', [])
        net['warnings'].append(
            'the device states (orifice plates, pump check valves, ratio valves, '
            'velocity pressures) had not settled after %d outer passes; the solve is '
            'not converged' % passes)
    return 1 if (ok and settled) else 0
