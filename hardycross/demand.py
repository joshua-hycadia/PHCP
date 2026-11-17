#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# demand.py -- Python port of HardyCross/Demand.pm.
#
# The flow path to the governing outlet, and the demand the system places
# on its water supply.  See Demand.pm for the whole rationale; the port
# follows it line for line.
#

from . import GAMMA_W as GW, curve_eval, solve_model
from .phc import read_string


def gauge(net, i):
    n = net['nodes'][i]
    return n['h'] - GW * n['z']

# The pressure an outlet has to spare: actual minus required, kPa.
def outlet_margin(net, e):
    m = gauge(net, e['n1']) - e['preq']
    if e.get('pv'):
        m -= e['pv']
    return m

#------------------------------------------------------------------------------
# The governing outlet.
#------------------------------------------------------------------------------
def governing_outlet(net):
    best = None
    bm = None
    cand = ([e for e in net['elems'][1:] if e['kind'] == 'DISCHARGE']
            + [f for f in (net.get('fixed') or []) if f.get('preq') is not None])
    for e in cand:
        m = outlet_margin(net, e)
        if bm is None or m < bm:
            best, bm = e, m
    return best, bm

#------------------------------------------------------------------------------
# The flow path from a supply to an outlet.
#------------------------------------------------------------------------------
def flow_path(net, outlet):
    steps = []
    v = outlet['n1']
    seen = {v: 1}
    iref = net['iref']

    for _ in range(len(net['nodes'])):
        best = None
        bq = None
        for ei in range(1, len(net['elems'])):
            e = net['elems'][ei]
            if e.get('closed') or e['kind'] == 'DISCHARGE':
                continue
            # the element delivers INTO $v if flow runs toward it
            if e['n2'] == v and e['q'] > 1e-9:
                in_ = e['q']
            elif e['n1'] == v and e['q'] < -1e-9:
                in_ = -e['q']
            else:
                in_ = 0
            if not in_ > 0:
                continue
            if bq is None or in_ > bq:
                best, bq = e, in_
        if not best:
            return None, 'no inflow found at node %s' % net['nodes'][v]['id']

        frm = best['n1'] if best['n2'] == v else best['n2']
        steps.insert(0, {'elem': best, 'from': frm, 'to': v, 'q': bq})
        if frm == iref:                     # reached a supply
            break
        if frm in seen:
            return None, 'the trace revisited a node'
        seen[frm] = 1
        v = frm
    return steps, None

#------------------------------------------------------------------------------
# trial -- what one trial solve of a demand search is worth.
#------------------------------------------------------------------------------
def trial(ok, net):
    if not (ok and net):
        return {'status': 'NOT_CONVERGED', 'net': net}
    from . import validate as _validate
    v = _validate.validate(net, ok)
    bad = [x for x in v['findings']
           if x['severity'] == 'error' and x['category'] != 'design']
    codes = sorted({x['code'] for x in bad})
    if v['acceptance'] == 'INDETERMINATE':
        return {'status': 'NOT_CONVERGED', 'net': net, 'codes': codes}
    if bad:
        return {'status': 'INVALID', 'net': net, 'codes': codes, 'findings': bad}
    go, m = governing_outlet(net)
    if m is None:
        return {'status': 'NO_OUTLET', 'net': net}
    return {'status': 'PASS' if m >= 0 else 'SHORT', 'net': net, 'margin': m, 'go': go}

# trial_why -- a trial that was not PASS or SHORT, in words: what failed.
def trial_why(t):
    if not t:
        return 'no trial'
    if t['status'] == 'NOT_CONVERGED':
        return 'the solve did not converge and settle'
    if t['status'] == 'NO_OUTLET':
        return 'no outlet has a requirement'
    w = [x['message'] for x in (t.get('findings') or [])]
    if len(w) > 3:
        del w[3:]
    return '; '.join(w) or ', '.join(t.get('codes') or [])

# search_status -- FOUND when the trial just short of a search's answer was a
# valid SHORT one (or none was needed).
def search_status(tb):
    if not tb or tb['status'] == 'SHORT':
        return 'FOUND'
    return 'UNRESOLVED'

# bracket_status -- no trial passed: INADEQUATE when every one was a valid
# SHORT one, UNRESOLVED when any was not.
def bracket_status(*trials):
    if any((not t) or t['status'] != 'SHORT' for t in trials):
        return 'UNRESOLVED'
    return 'INADEQUATE'

# margin_at -- (margin, network) of a valid trial at supply pressure $p.
def margin_at(text, sid, p):
    ok, net = solve_at(text, sid, p)
    t = trial(ok, net)
    if t['status'] not in ('PASS', 'SHORT'):
        return None
    return (t['margin'], t['net'])

#------------------------------------------------------------------------------
# solve_at -- (converged, network): the model re-read from its text and solved
# with supply $sid held at pressure $p.
#------------------------------------------------------------------------------
def solve_at(text, sid, p):
    try:
        net = read_string(text)
    except Exception:
        return None, None
    sup = None
    for e in net['elems'][1:]:
        if (e.get('id') or '') == sid:
            sup = e
            break
    if not sup:
        return None, None
    # Same node, same elevation, a fixed pressure instead of a curve.
    z = sup.get('z')
    z = 0 if z is None else z
    sup.update(kind='SUPPLY_STATIC', pstat=p, z=z)
    sup.pop('curve', None)
    try:
        ok = solve_model(net)
    except Exception:
        ok = None
    return ok, net

def demand_point(net):
    sup = [e for e in net['elems'][1:] if e['kind'].startswith('SUPPLY_')]
    if not sup:
        return {'reason': 'the model has no supply'}
    if len(sup) > 1:
        return {'reason': '%d supplies: a single demand point is not defined when '
                          'supplies share the load, so each supply is reported at its operating point'
                          % len(sup)}
    s = sup[0]
    text = net.get('source_text')
    if not text:
        return {'reason': 'the model text is not available to re-solve'}
    go, _ = governing_outlet(net)
    if not go:
        return {'reason': 'the model has no outlet with a required pressure'}

    p_now = gauge(net, s['n2'])
    lo, hi = 0, p_now if p_now > 1 else 100

    def at(p):
        return trial(*solve_at(text, s['id'], p))

    # Make sure the bracket holds the answer: at $hi every outlet must be met,
    # in a valid solve.
    th = at(hi)
    seen = [th]
    for _ in range(30):
        if th['status'] == 'PASS':
            break
        hi *= 1.5
        th = at(hi)
        seen.append(th)
    if th['status'] != 'PASS':
        st = bracket_status(*seen)
        odd = next((t for t in seen if t['status'] != 'SHORT'), None)
        if st == 'INADEQUATE':
            reason = 'no supply pressure up to %.0f kPa satisfies every outlet' % hi
        else:
            reason = ('no supply pressure up to %.0f kPa gave a valid solve meeting every outlet: %s'
                      % (hi, trial_why(odd)))
        return {'status': st, 'reason': reason}
    # Bisect to 0.01 kPa.  Only a valid SHORT trial is "below the demand".
    tb = None
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        t = at(mid)
        if t['status'] == 'PASS':
            hi, th = mid, t
        else:
            lo, tb = mid, t
        if hi - lo < 0.01:
            break
    # The floor.  A supply's pressure is gauge at its connection and cannot be
    # below zero (a tank surface is at atmosphere), so 0 kPa is the lowest
    # trial.  0 kPa is tried only when it can matter: when every trial passed.
    floor = 0
    if tb is None:
        t0 = at(0)
        if t0['status'] == 'PASS':
            floor, hi, th = 1, 0, t0
        else:
            lo, tb = 0, t0
    if search_status(tb) != 'FOUND':
        return {'status': 'UNRESOLVED', 'boundary': tb['status'], 'p_boundary': lo,
                'reason': ('below %.2f kPa the trial solves are %s (%s): the pressure at which the '
                           'outlets stop being met could not be found'
                           % (hi, tb['status'], trial_why(tb)))}
    dn = th['net']
    dsup = next((e for e in dn['elems'][1:] if (e.get('id') or '') == s['id']), None)
    dgo, _ = governing_outlet(dn)
    # The demand flow: what the system draws at the demand point, plus any
    # hose allowance (OPTION HOSE_ALLOWANCE), added at the supply.
    q_sys = dsup['q']
    q_hose = net['opts'].get('hose')
    q_hose = 0 if q_hose is None else q_hose
    q_d = q_sys + q_hose

    # What the supply has at that flow.
    if s['kind'] == 'SUPPLY_STATIC':
        avail = s['pstat']
    else:
        avail = curve_eval(s['curve'], q_d)

    return {
        'status': 'FOUND',
        'at_floor': 1 if floor else 0,
        'boundary': tb['status'] if tb else None,
        'supply': s,
        'governing': dgo,
        'q_demand': q_d,
        'q_system': q_sys,
        'q_hose': q_hose,
        'p_demand': hi,
        'p_avail': avail,
        'margin': avail - hi,
        'q_oper': s['q'],
        'p_oper': p_now,
        # the whole network at the demand point, so the cover sheet can report
        # sprinkler flows and density at the design condition, not only at the
        # operating point
        'net': dn,
    }

#------------------------------------------------------------------------------
# All the supplies together.
#------------------------------------------------------------------------------

# supplies -- the supply elements of a network.
def supplies(net):
    return [e for e in net['elems'][1:] if e['kind'].startswith('SUPPLY_')]

# solve_all_at -- (converged, network): the model re-read and solved with
# every supply held at gauge pressure $p.
def solve_all_at(text, p):
    try:
        net = read_string(text)
    except Exception:
        return None, None
    for s in supplies(net):
        z = s.get('z')
        z = 0 if z is None else z
        s.update(kind='SUPPLY_STATIC', pstat=p, z=z)
        s.pop('curve', None)
    try:
        ok = solve_model(net)
    except Exception:
        ok = None
    return ok, net

# avail_of -- one supply's pressure at a flow: its static pressure, or its curve.
def avail_of(s, q):
    if s['kind'] == 'SUPPLY_STATIC':
        return s['pstat']
    return curve_eval(s['curve'], q)

# flow_at -- the flow one supply gives at gauge pressure $p: none at or above
# its pressure at no flow, and for a curve the flow where the curve reaches
# $p.  A static supply gives any flow at or below its pressure (None:
# unlimited).
def flow_at(s, p):
    if s['kind'] == 'SUPPLY_STATIC':
        return None if p <= s['pstat'] else 0
    if p >= curve_eval(s['curve'], 0):
        return 0
    lo, hi = 0, 1
    while curve_eval(s['curve'], hi) > p and hi < 1e9:
        hi *= 2
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        if curve_eval(s['curve'], mid) > p:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)

# combined_avail -- a callable giving the pressure the supplies together have
# at a total flow: the highest pressure at which the flows they give add up
# to it.
def combined_avail(*sup):
    pstats = [s['pstat'] for s in sup if s['kind'] == 'SUPPLY_STATIC']
    pstat = max(pstats) if pstats else None
    curve = [s for s in sup if s['kind'] != 'SUPPLY_STATIC']
    tops = [curve_eval(s['curve'], 0) for s in curve]
    ptop = max(tops) if tops else None

    def avail(q):
        pc = 0
        if curve:
            def summ(x):
                t = 0
                for s in curve:
                    t += flow_at(s, x)
                return t
            if summ(0) >= q:
                lo, hi = 0, ptop
                for _ in range(60):
                    mid = 0.5 * (lo + hi)
                    if summ(mid) >= q:
                        lo = mid
                    else:
                        hi = mid
                pc = lo
        if pstat is not None and pstat > pc:
            return pstat
        return pc

    return avail

#------------------------------------------------------------------------------
# combined_demand -- the required condition of several supplies.
#------------------------------------------------------------------------------
def combined_demand(net):
    sup = supplies(net)
    if not len(sup) > 1:
        return {'reason': 'fewer than two supplies'}
    text = net.get('source_text')
    if not text:
        return {'reason': 'the model text is not available to re-solve'}
    go, _ = governing_outlet(net)
    if not go:
        return {'reason': 'the model has no outlet with a required pressure'}

    def margin(p):
        ok, n = solve_all_at(text, p)
        if not ok:
            return None
        _, m = governing_outlet(n)
        return (m, n)

    # Bisect on the common pressure, as demand_point does on one supply's.
    lo, hi = 0, 100
    r = margin(hi)
    mh = r[0] if r else None
    for _ in range(30):
        if mh is not None and mh >= 0:
            break
        hi *= 1.5
        r = margin(hi)
        mh = r[0] if r else None
    if not (mh is not None and mh >= 0):
        return {'reason': 'no common supply pressure up to %.0f kPa satisfies every outlet' % hi}
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        r = margin(mid)
        m = r[0] if r else None
        if m is not None and m >= 0:
            hi = mid
        else:
            lo = mid
        if hi - lo < 0.01:
            break
    r = margin(hi)
    dn = r[1] if r else None
    dgo, _ = governing_outlet(dn)
    q_d = 0
    for s in supplies(dn):
        q_d += s['q']
    # Any hose allowance is added at the supplies, as for one supply.
    q_sys = q_d
    q_hose = net['opts'].get('hose')
    q_hose = 0 if q_hose is None else q_hose
    q_d += q_hose

    q_o, p_o, p_lo = 0, None, None
    for s in sup:
        q_o += abs(s['q'])
        g = gauge(net, s['n2'])
        if p_o is None or g > p_o:
            p_o = g
        if p_lo is None or g < p_lo:
            p_lo = g
    avail = combined_avail(*sup)
    return {
        'supply': {'id': 'ALL', 'kind': 'COMBINED'},
        'combined': 1,
        'parts': list(sup),
        'governing': dgo,
        'avail': avail,
        'p_demand': hi,
        'q_demand': q_d,
        'q_system': q_sys,
        'q_hose': q_hose,
        'p_avail': avail(q_d),
        'margin': avail(q_d) - hi,
        'q_oper': q_o,
        'p_oper': p_o,
        'one_pressure': p_o - p_lo <= 0.02 * abs(p_o),
    }
