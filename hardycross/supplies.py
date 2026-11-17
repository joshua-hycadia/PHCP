#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# supplies.py -- Python port of HardyCross/Supplies.pm.
#
# Several water supplies, each on its own terms.  The question is asked
# four ways (OPERATING, CONDITIONAL, JOINT, SCENARIOS), each a full Hardy
# Cross solve (or a bisection of them) of the whole network, and each
# labelled with what it assumes.  See Supplies.pm for the whole rationale;
# the port follows it line for line.
#

from . import (Q_TINY as QT, fit_curve, curve_eval, check_valve_loss,
               solve_model, is_model_error)
from . import demand
from . import validate
from .phc import read_string

# The pressure to which every bisection here is taken, kPa: the same as the
# demand point's.
P_TOL = 0.01


def supplies(net):
    return demand.supplies(net)

# reread -- the model read again from its text, unsolved.
def reread(text):
    try:
        return read_string(text)
    except Exception:
        return None

# by_id -- a supply of a network by its id.
def by_id(net, id_):
    for s in supplies(net):
        if s['id'] == id_:
            return s
    return None

# shifted -- a supply curve with every pressure changed by $fn, refitted.
def shifted(c, fn):
    return fit_curve({'q': list(c['q']),
                      'p': [fn(p) for p in c['p']]}, 0)

# avail -- one supply's pressure at a flow, as modelled.
def avail(s, q):
    return demand.avail_of(s, q)

#------------------------------------------------------------------------------
# solve_variant -- (ok, network, margin, governing): the model re-read, changed
# by $mutate (given the fresh network), solved, and its least outlet margin.
#------------------------------------------------------------------------------
def solve_variant(text, mutate):
    net = reread(text)
    if not net:
        return (0, None, None, None)
    if mutate:
        mutate(net)
    try:
        ok = solve_model(net)
    except Exception:
        ok = None
    if not ok:
        return (0, net, None, None)
    go, m = demand.governing_outlet(net)
    return (1, net, m, go)

# trial_of -- a variant solved and classified (Demand.trial).
def trial_of(text, mutate):
    ok, net = solve_variant(text, mutate)
    return demand.trial(ok, net)

# state_of -- what a supply is doing, in one word.
def state_of(s):
    if s.get('out_of_service'):
        return 'OUT_OF_SERVICE'
    if s.get('isolated'):
        return 'ISOLATED'
    if s.get('closed'):
        return 'CLOSED'
    return 'REVERSE' if s['q'] < -QT else ('IDLE' if s['q'] <= QT else 'DELIVERING')

# valve_of -- a supply's check valve for the schedules.
def valve_of(s):
    v = s.get('nrv')
    if not v:
        return None
    loss = 0 if s.get('closed') else check_valve_loss(s, s['q'])[0]
    r = dict(v)
    r['loss'] = loss
    r['switches'] = s.get('nflips') or 0
    return r

# reverse_text -- the supplies of a trial that take water in, in words.
def reverse_text(t):
    if not (t and t.get('net')):
        return ''
    r = [s for s in supplies(t['net']) if not s.get('closed') and s['q'] < -QT]
    return ', '.join('supply %s takes %.3g L/min in' % (s['id'], -s['q']) for s in r)

#------------------------------------------------------------------------------
# operating -- each supply as the modelled network runs it.
#------------------------------------------------------------------------------
def operating(net):
    sup = supplies(net)
    qin = 0
    for s in sup:
        if s['q'] > 0:
            qin += s['q']
    rows = []
    for s in sup:
        q = s['q']
        p = demand.gauge(net, s['n2'])
        rows.append({
            'id': s['id'], 'node': net['nodes'][s['n2']]['id'],
            'z': s.get('z') if s.get('z') is not None else 0,
            'kind': 'STATIC' if s['kind'] == 'SUPPLY_STATIC' else 'CURVE',
            'flow': q, 'pressure': p,
            'supply_pressure': avail(s, q if q > 0 else 0),
            'share': 100 * q / qin if qin > 0 and q > 0 else 0,
            'status': state_of(s),
            'check_valve': valve_of(s),
            'extrapolated': 1 if s.get('curve') and validate.extrapolated(s['curve'], q) else 0,
        })
    return rows

#------------------------------------------------------------------------------
# conditional -- the least pressure supply $sid needs, the others as modelled.
#------------------------------------------------------------------------------
def conditional(net, sid):
    text = net.get('source_text')
    if not text:
        return {'id': sid, 'basis': 'CONDITIONAL', 'status': 'UNRESOLVED', 'reason': 'no model text'}
    orig = by_id(net, sid)

    def at(p):
        t = demand.trial(*demand.solve_at(text, sid, p))
        if t.get('net') and by_id(t['net'], sid):
            t['q'] = by_id(t['net'], sid)['q']
        return t

    def solved(t):
        return bool(t) and t['status'] != 'NOT_CONVERGED' and t.get('q') is not None

    def no(st, why):
        return {'id': sid, 'basis': 'CONDITIONAL', 'status': st, 'reason': why}

    # p0: the supply's flow rises with its pressure; find where it is zero.
    p_now = demand.gauge(net, orig['n2'])
    lo, hi = 0, p_now if p_now > 1 else 100
    t0 = at(0)
    p0 = 0
    if not (solved(t0) and t0['q'] >= -QT):
        th = at(hi)
        for _ in range(30):
            if solved(th) and th['q'] > 0:
                break
            hi *= 1.5
            th = at(hi)
        if not (solved(th) and th['q'] > 0):
            return no('UNRESOLVED',
                      'no pressure was found at which this supply delivers water in a converged solve')
        for _ in range(80):
            mid = 0.5 * (lo + hi)
            t = at(mid)
            if solved(t) and t['q'] > 0:
                hi = mid
            else:
                lo = mid
            if hi - lo < P_TOL:
                break
        p0 = hi
    t_p0 = at(p0)
    if t_p0['status'] == 'PASS':
        return result_of(net, sid, 'NOT_REQUIRED', p0, t_p0)

    # Bisect between p0 and a pressure that satisfies every outlet.
    lo, hi = p0, p_now if p_now > p0 else p0 + 100
    th = at(hi)
    seen = [th]
    for _ in range(30):
        if th['status'] == 'PASS':
            break
        hi *= 1.5
        th = at(hi)
        seen.append(th)
    if th['status'] != 'PASS':
        st = demand.bracket_status(*seen)
        odd = next((t for t in seen if t['status'] != 'SHORT'), None)
        if st == 'INADEQUATE':
            why = 'no pressure at this supply up to %.0f kPa satisfies every outlet' % hi
        else:
            why = ('no pressure at this supply up to %.0f kPa gave a valid solve meeting every outlet: %s'
                   % (hi, demand.trial_why(odd)))
        return no(st, why)
    tb = t_p0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        t = at(mid)
        if t['status'] == 'PASS':
            hi, th = mid, t
        else:
            lo, tb = mid, t
        if hi - lo < P_TOL:
            break
    if demand.search_status(tb) != 'FOUND':
        return no('UNRESOLVED',
                  'below %.2f kPa at this supply the trial solves are %s (%s): its minimum could not be found'
                  % (hi, tb['status'], reverse_text(tb) or demand.trial_why(tb)))
    return result_of(net, sid, 'REQUIRED', hi, th)


def result_of(net, sid, status, p, t):
    orig = by_id(net, sid)
    q = t['q'] if t['q'] > 0 else 0
    a = avail(orig, q)
    v = validate.validate(t['net'], 1)
    return {
        'id': sid, 'basis': 'CONDITIONAL', 'status': status, 'pressure': p, 'flow': q,
        'available': a, 'margin': a - p,
        'extrapolated': 1 if orig.get('curve') and validate.extrapolated(orig['curve'], q) else 0,
        'governing': t['go']['id'] if t.get('go') else None,
        'others_reverse': [s['id'] for s in supplies(t['net'])
                           if s['id'] != sid and s['q'] < -QT],
        'acceptance': v['acceptance'],
        'findings': [x['code'] for x in v['findings']
                     if x['severity'] == 'error' and x['category'] != 'design'],
    }

#------------------------------------------------------------------------------
# joint -- the simultaneous demand of every supply, on one basis.
#------------------------------------------------------------------------------
def joint(net):
    basis = net['opts'].get('joint_basis')
    basis = 'DERATE' if basis is None else basis
    text = net.get('source_text')
    if not text:
        return {'reason': 'the model text is not available to re-solve'}

    def apply(x):
        def mutate(n):
            for s in supplies(n):
                if basis == 'DERATE':
                    if s['kind'] == 'SUPPLY_STATIC':
                        s['pstat'] -= x
                    else:
                        s['curve'] = shifted(s['curve'], lambda p: p - x)
                else:
                    if s['kind'] == 'SUPPLY_STATIC':
                        s['pstat'] *= x
                    else:
                        s['curve'] = shifted(s['curve'], lambda p: p * x)
        return mutate

    def trial(x):
        return trial_of(text, apply(x))

    def passed(t):
        return bool(t) and t['status'] == 'PASS'

    def what(x):
        if basis == 'DERATE':
            return 'a derating of %.2f kPa' % x
        return 'a factor of %.4f' % x

    def no(st, why):
        return {'status': st, 'reason': why, 'basis': basis}

    # The margin falls as D rises, and rises with F.  Find a bracket
    # [pass, fail], then bisect.
    t1 = trial(0 if basis == 'DERATE' else 1)
    if basis == 'DERATE':
        pmax = 0
        for s in supplies(net):
            p = s['pstat'] if s['kind'] == 'SUPPLY_STATIC' else curve_eval(s['curve'], 0)
            if p > pmax:
                pmax = p
        if passed(t1):
            good, tg = 0, t1
            bad = pmax if pmax > 1 else 100
            tb = trial(bad)
            for _ in range(30):
                if not passed(tb):
                    break
                bad *= 1.5
                tb = trial(bad)
            if passed(tb):
                return no('NOT_LIMITING', 'the outlets are met however far the supplies are derated')
        else:
            bad, good, tb = 0, -100, t1
            seen = [t1]
            tg = trial(good)
            for _ in range(30):
                seen.append(tg)
                if passed(tg):
                    break
                good *= 1.5
                tg = trial(good)
            if not passed(tg):
                st = demand.bracket_status(*seen)
                odd = next((t for t in seen if t['status'] != 'SHORT'), None)
                if st == 'INADEQUATE':
                    why = 'raising every supply by %.0f kPa does not satisfy every outlet' % -good
                else:
                    why = ('raising every supply by up to %.0f kPa gave no valid solve meeting every '
                           'outlet: %s' % (-good, reverse_text(odd) or demand.trial_why(odd)))
                return no(st, why)
    else:
        if passed(t1):
            good, tg, bad = 1, t1, 0
        else:
            bad, good, tb = 1, 1.5, t1
            seen = [t1]
            tg = trial(good)
            for _ in range(30):
                seen.append(tg)
                if passed(tg):
                    break
                good *= 1.5
                tg = trial(good)
            if not passed(tg):
                st = demand.bracket_status(*seen)
                odd = next((t for t in seen if t['status'] != 'SHORT'), None)
                if st == 'INADEQUATE':
                    why = 'scaling every supply by %.0f does not satisfy every outlet' % good
                else:
                    why = ('scaling every supply by up to %.0f gave no valid solve meeting every outlet: %s'
                           % (good, reverse_text(odd) or demand.trial_why(odd)))
                return no(st, why)
    # Bisect.  For SCALE the step is taken in pressure: the change in factor
    # that moves the strongest supply by P_TOL.
    pref = 0
    for s in supplies(net):
        p = s['pstat'] if s['kind'] == 'SUPPLY_STATIC' else curve_eval(s['curve'], 0)
        if p > pref:
            pref = p
    tolx = P_TOL if basis == 'DERATE' else P_TOL / (pref if pref > 1 else 1)
    for _ in range(100):
        if abs(good - bad) < tolx:
            break
        mid = 0.5 * (good + bad)
        t = trial(mid)
        if passed(t):
            good, tg = mid, t
        else:
            bad, tb = mid, t
    # The boundary must be where the outlets stop being met in a valid solve.
    if demand.search_status(tb) != 'FOUND':
        return no('UNRESOLVED',
                  'beyond %s the joint demand trials are %s: %s.  On the %s basis the supplies reach that '
                  'state before the governing outlet reaches its minimum, so no valid joint demand exists '
                  'on it' % (what(good), tb['status'],
                             reverse_text(tb) or demand.trial_why(tb), basis))

    jn = tg['net']
    v = validate.validate(jn, 1)
    rows = []
    qt = 0
    mmin = None
    for s in supplies(jn):
        o = by_id(net, s['id'])
        q = s['q']
        p = s['pstat'] if s['kind'] == 'SUPPLY_STATIC' else curve_eval(s['curve'], q)
        a = avail(o, q if q > 0 else 0)
        qt += q
        if mmin is None or a - p < mmin:
            mmin = a - p
        rows.append({'id': s['id'], 'node': jn['nodes'][s['n2']]['id'],
                     'z': s.get('z') if s.get('z') is not None else 0,
                     'flow': q, 'pressure': p,
                     'node_pressure': demand.gauge(jn, s['n2']),
                     'available': a, 'margin': a - p,
                     'active': 1 if not s.get('closed') and q > QT else 0,
                     'extrapolated': 1 if o.get('curve') and validate.extrapolated(o['curve'], q) else 0,
                     'status': state_of(s), 'check_valve': valve_of(s)})
    qin = 0
    for r in rows:
        if r['flow'] > 0:
            qin += r['flow']
    for r in rows:
        r['share'] = 100 * r['flow'] / qin if qin > 0 and r['flow'] > 0 else 0
    # The supplies' flows, signed, against the network's net demand in the
    # same solve.
    dem = 0
    for e in jn['elems'][1:]:
        if e['kind'] == 'DISCHARGE' and not e.get('closed'):
            dem += e['q']
    for i in range(1, len(jn['nodes'])):
        d = jn['nodes'][i].get('demand')
        dem += d if d is not None else 0
    btol = validate.VERIFY_Q_REL * (abs(dem) if abs(dem) > 1 else 1)
    bad = [x for x in v['findings']
           if x['severity'] == 'error' and x['category'] != 'design']
    r = {'status': 'UNRESOLVED' if bad else 'FOUND',
         'basis': basis,
         'basis_name': 'uniform pressure derating' if basis == 'DERATE' else 'uniform pressure scaling',
         'assumption': ('An ASSUMPTION that defines this joint demand, not a unique physical requirement: '
                        + ('every supply\'s pressure lowered by the same amount at every flow, each keeping '
                           'its own curve and connection, until the governing outlet receives exactly its minimum'
                           if basis == 'DERATE'
                           else 'every supply\'s pressure multiplied by the same factor at every flow, each '
                                'keeping its own curve and connection, until the governing outlet receives '
                                'exactly its minimum')
                        + '.  Another basis gives another split between the supplies.'),
         'margin': good if basis == 'DERATE' else mmin,
         'governing': tg['go']['id'] if tg.get('go') else None,
         'boundary': tb['status'] if tb else None,
         'acceptance': v['acceptance'],
         'findings': [x['code'] for x in bad],
         'supplies': rows,
         'q_total': qt,
         'net_demand': dem,
         'balance': qt - dem,
         'balance_pass': 1 if abs(qt - dem) <= btol else 0,
         'net': jn}
    if bad:
        r['reason'] = 'the joint demand solve is not valid: ' + '; '.join(x['message'] for x in bad)
    if basis == 'DERATE':
        r['delta'] = good
    else:
        r['factor'] = good
    return r

#------------------------------------------------------------------------------
# scenarios -- the supply scenarios to solve.
#------------------------------------------------------------------------------
def scenario_list(net):
    ids = [s['id'] for s in supplies(net)]
    lst = []
    if net['opts'].get('supply_scenarios') is None or net['opts'].get('supply_scenarios'):
        seen = set()
        for id_ in ids:
            sh = {i: (100 if i == id_ else 0) for i in ids}
            lst.append({'name': 'ONLY-%s' % id_,
                        'description': '%s alone, every other supply out of service' % id_,
                        'required': 0, 'shares': sh})
            seen.add(','.join('%s=%d' % (i, sh[i]) for i in sorted(sh)))
        for id_ in ids:
            sh = {i: (0 if i == id_ else 100) for i in ids}
            key = ','.join('%s=%d' % (i, sh[i]) for i in sorted(sh))
            if key in seen:
                seen.add(key)
                continue
            seen.add(key)
            lst.append({'name': 'WITHOUT-%s' % id_,
                        'description': '%s out of service, the others as modelled' % id_,
                        'required': 0, 'shares': sh})
    for sc in (net.get('scenarios') or []):
        sh = {i: 100 for i in ids}
        for a, b in sc['shares']:
            sh[a] = b
        lst.append({'name': sc['name'], 'line': sc.get('line'), 'required': 1, 'shares': sh,
                    'description': ', '.join('%s out of service' % a if b == 0
                                            else '%s at %d %% of its pressure' % (a, b)
                                            for a, b in sc['shares'])})
    return lst

#------------------------------------------------------------------------------
# scenario -- one scenario solved and validated.
#------------------------------------------------------------------------------
def scenario(net, sc):
    text = net['source_text']
    n = reread(text)
    sh = sc['shares']
    for s in supplies(n):
        pc = sh.get(s['id'])
        pc = 100 if pc is None else pc
        if pc <= 0:
            s['closed'] = 1
            s['out_of_service'] = 1
            continue
        if pc >= 100:
            continue
        if s['kind'] == 'SUPPLY_STATIC':
            s['pstat'] *= pc / 100
        else:
            s['curve'] = shifted(s['curve'], lambda p: p * pc / 100)
    try:
        ok = solve_model(n)
        err = None
    except Exception as e:
        ok = None
        err = e
    if ok is None:
        if is_model_error(err):
            msg = err.msg
        else:
            msg = str(err)
        msg = msg.rstrip()
        r = dict(sc)
        r.update(acceptance='INDETERMINATE', error=msg, supplies=[])
        return r
    v = validate.validate(n, ok)
    go, m = demand.governing_outlet(n)
    r = dict(sc)
    r.update(acceptance=v['acceptance'],
             converged=1 if ok else 0,
             governing=go['id'] if go else None,
             margin=m,
             findings=[x['code'] for x in v['findings'] if x['severity'] == 'error'],
             supplies=[{'id': s['id'], 'percent': sh.get(s['id']) if sh.get(s['id']) is not None else 100,
                        'flow': 0 if s.get('closed') else s['q'],
                        'pressure': demand.gauge(n, s['n2']),
                        'status': state_of(s)}
                       for s in supplies(n)])
    return r

#------------------------------------------------------------------------------
# analyse -- the whole multiple-supply picture for a solved network.
#------------------------------------------------------------------------------
def analyse(net, ok):
    sup = supplies(net)
    if not len(sup) > 1:
        return None
    r = {'operating': operating(net)}
    sm = 0
    for row in r['operating']:
        sm += row['flow']
    dem = 0
    for e in net['elems'][1:]:
        if e['kind'] == 'DISCHARGE' and not e.get('closed'):
            dem += e['q']
    for i in range(1, len(net['nodes'])):
        d = net['nodes'][i].get('demand')
        dem += d if d is not None else 0
    r['supply_sum'], r['net_demand'], r['balance'] = sm, dem, sm - dem
    go, _ = demand.governing_outlet(net)
    r['governing'] = go['id'] if go else None
    if not (ok and net.get('source_text') and go):
        return r
    r['conditional'] = [conditional(net, s['id']) for s in sup]
    r['joint'] = joint(net)
    r['scenarios'] = [scenario(net, x) for x in scenario_list(net)]
    return r
