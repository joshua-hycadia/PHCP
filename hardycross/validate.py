#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# validate.py -- Python port of HardyCross/Validate.pm.
#
# An independent check of every completed solve: nothing here trusts the
# solver.  Every check is worked again from the final network -- the flows,
# the recovered heads and the element equations -- after every outer-loop
# adjustment has been made.  Three results kept apart (numerical, physical,
# design) and an acceptance from the three.  See Validate.pm for the whole
# rationale; the port follows it line for line.
#

import math
import re

from . import (GAMMA_W, Q_TINY, elem_hf, pipe_velocity, outlet_pressure,
               curve_eval, supply_head0, orifice_dp, fail)

GW = GAMMA_W
QT = Q_TINY

VAPOUR_GAUGE = -(101.325 - 2.34)

# ISO 5167-2 range of diameter ratio for which an orifice plate's discharge
# coefficient is established.
BETA_MIN, BETA_MAX = 0.10, 0.75

# The range of differential trip ratio that dry pipe valves in common use are
# made to (about 5:1 to 6:1, the commonest 5.5:1); 3:1 to 8:1 is the wider
# band outside which the figure is flagged for checking.
DPV_RATIO_LO, DPV_RATIO_HI = 3.0, 8.0

# THE VERIFICATION LIMITS -- what the final network must satisfy, whatever
# the solver was told (see Validate.pm).  0.1 kPa is about 10 mm of water.
ORIF_DP_TOL = 10

VERIFY_Q_REL = 1e-6
VERIFY_P     = 0.1
VERIFY_P_REL = 1e-6

EXTRAP_MAX = 1.5


# _P -- a format whose % prints as Perl's sprintf does: a number that is not
# finite is Inf, -Inf or NaN there, where Python writes inf, -inf and nan.
_CONV = re.compile(r'%(?:%|[-+ #0]*\d*(?:\.\d+)?[a-zA-Z])')

class _P(str):
    __slots__ = ()

    def __mod__(self, args):
        if not isinstance(args, tuple):
            args = (args,)
        if not any(isinstance(a, float) and not math.isfinite(a) for a in args):
            return str.__mod__(self, args)
        out, pos, i = [], 0, 0
        for m in _CONV.finditer(self):
            out.append(self[pos:m.start()])
            pos = m.end()
            spec = m.group(0)
            if spec == '%%':
                out.append('%')
                continue
            a = args[i]
            i += 1
            if isinstance(a, float) and not math.isfinite(a) and spec[-1] in 'fFgGeEs':
                s = 'NaN' if a != a else ('Inf' if a > 0 else '-Inf')
                flags = re.match(r'%([-+ #0]*)', spec).group(1)
                if s == 'Inf' and spec[-1] != 's' and ('+' in flags or ' ' in flags):
                    s = '+Inf'
                w = re.search(r'[1-9]\d*', spec.split('.')[0])
                w = int(w.group(0)) if w else 0
                out.append(s.ljust(w) if '-' in flags
                           else s.rjust(w, '0') if '0' in flags and spec[-1] != 's' else s.rjust(w))
            else:
                out.append(str.__mod__(spec, (a,)))
        out.append(self[pos:])
        return ''.join(out)


def finite(x):
    return x is not None and x == x and not math.isinf(abs(x))

def open_elems(net):
    return [e for e in net['elems'][1:] if not e.get('closed')]

def gauge(net, i):
    n = net['nodes'][i]
    return n['h'] - GW * n['z']


#==============================================================================
# validate -- the three results and the acceptance for a solved network.
#==============================================================================

def validate(net, ok, **o):
    f = []

    def add(**r):
        r.setdefault('severity', 'error')
        f.append(r)

    v = {'findings': f}

    numerical(net, ok, v, add)
    physical(net, add)
    # The demand assessment: whether the supplies' adequacy was shown.
    da = {'status': 'NOT_ASSESSED', 'basis': None, 'message': 'no demand was worked out'}
    design(net, add, assessment=da, **o)
    v['demand_assessment'] = da
    if o.get('dry'):
        dry_time_checks(net, add, o['dry'])

    err = {}
    for x in f:
        if x['severity'] == 'error':
            err[x['category']] = err.get(x['category'], 0) + 1

    def count(c, s):
        return sum(1 for x in f if x['category'] == c and x['severity'] == s)

    indet = v.get('indeterminate')
    for c in ('numerical', 'physical', 'design'):
        if c == 'numerical' and indet:
            status = 'INDETERMINATE'
        elif c != 'numerical' and indet:
            status = 'NOT_ASSESSED'
        elif err.get(c):
            status = 'FAIL'
        else:
            status = 'PASS'
        v[c] = {'status': status, 'errors': count(c, 'error'), 'warnings': count(c, 'warning')}
    v['acceptance'] = ('INDETERMINATE' if indet
                       else 'REJECTED' if (err.get('numerical') or err.get('physical'))
                       else 'NONCOMPLIANT' if err.get('design')
                       else 'ACCEPTED')
    return v

#==============================================================================
# NUMERICAL
#==============================================================================

def numerical(net, ok, v, add):
    uf, up = net['f_flow'], net['f_pres']
    o = net['opts']
    tol_flow = o.get('tol_flow')
    tol_flow = 0.05 if tol_flow is None else tol_flow
    tol_loop = o.get('tol_loop')
    tol_loop = 0.01 if tol_loop is None else tol_loop
    nn = len(net['nodes']) - 1
    el = net['elems'][1:]

    v['solver'] = {
        'method': o.get('method') or 'HW',
        'algorithm': 'sequential Hardy Cross (loop by loop), fundamental loops of a spanning tree',
        'hc_converged': 1 if (net.get('hc_converged') if net.get('hc_converged') is not None else (1 if ok else 0)) else 0,
        'outer_settled': net.get('outer_settled') or 0,
        'outer_passes': net.get('outer_passes') or 0,
        'outer_stop': net.get('outer_stop') or 'not_run',
        'iterations': net.get('iters') or 0,
        'maxiter': o.get('maxiter') if o.get('maxiter') is not None else 50000,
        'tol_flow': tol_flow / uf,
        'tol_loop': tol_loop / up,
        'diagnosis': net.get('nonconv'),
        'loops': len(net.get('loops') or []),
    }

    # Every value finite, checked first (see Validate.pm).
    bad = [e for e in el if not finite(e.get('q'))]
    badn = [i for i in range(1, nn + 1) if not finite(net['nodes'][i].get('h'))]
    # A node head that is not finite: the Perl crashes here (its map over the
    # elements is handed the node names too: "Can't use string as a HASH
    # ref", Validate.pm line 233, exit 255).  The finding it meant to make is
    # made here instead; a deliberate difference (PYTHON_PORT.md).
    if bad or badn:
        add(code='NONFINITE', category='numerical',
            item=' '.join([e['id'] for e in bad] + [net['nodes'][i]['id'] for i in badn]),
            message='flows or pressures are not finite numbers (NaN or infinity)')
        v['indeterminate'] = 1
        v['residuals'] = {}
        return

    if not v['solver']['hc_converged']:
        add(code='NOT_CONVERGED', category='numerical', item=None,
            value=v['solver']['iterations'], limit=v['solver']['maxiter'], unit='iterations',
            message=_P('the Hardy Cross iteration did not converge in %d iterations%s')
                    % (v['solver']['iterations'],
                       _P(' (%s)') % net['nonconv'] if net.get('nonconv') else ''))
        v['indeterminate'] = 1
    if v['solver']['hc_converged'] and not v['solver']['outer_settled']:
        add(code='DEVICES_UNSETTLED', category='numerical', item=None,
            value=v['solver']['outer_passes'], unit='outer passes',
            message='the device states (orifice plates, pump and supply check valves, ratio valves, '
                    'velocity pressures) had not settled when the solve stopped')
        v['indeterminate'] = 1
    unsettled = [e for e in el if e.get('nrv') and e.get('flip_limit')]
    if unsettled:
        add(code='SUPPLY_CHECK_UNRESOLVED', category='numerical',
            item=' '.join(e['id'] for e in unsettled),
            value=unsettled[0].get('nflips'), unit='switches',
            message=_P('supply check valve%s %s opened and closed on alternate solves until the switch '
                    'limit was reached and %s still not in the state %s pressures call for: the '
                    'operating state is not resolved')
                    % ('s' if len(unsettled) > 1 else '',
                       ', '.join(e['id'] for e in unsettled),
                       'are' if len(unsettled) > 1 else 'is',
                       'their' if len(unsettled) > 1 else 'its'))
        v['indeterminate'] = 1
    if net.get('degenerate'):
        add(code='DEGENERATE_LOOP', category='numerical',
            item=' '.join(str(x) for x in net['degenerate']),
            message='a loop made only of fixed-pressure elements (static supplies, fixed drops) is out '
                    'of balance and cannot be corrected: it has no flow-dependent loss')

    #------------------------------------------------------------- continuity
    acc = [0] * (nn + 1)
    for i in range(1, nn + 1):
        d = net['nodes'][i].get('demand')
        acc[i] = d if d is not None else 0
    qscale = 0
    for e in open_elems(net):
        acc[e['n1']] += e['q']
        acc[e['n2']] -= e['q']
        if abs(e['q']) > qscale:
            qscale = abs(e['q'])
    ctol = VERIFY_Q_REL * (qscale if qscale > 1 else 1)
    hscale = 0
    for i in range(1, nn + 1):
        h = abs(net['nodes'][i].get('h') or 0)
        if h > hscale:
            hscale = h
    ptol = VERIFY_P + VERIFY_P_REL * hscale
    v['verification'] = {
        'continuity': ctol / uf, 'balance': ctol / uf, 'flow_unit': net['u_flow'],
        'loop': ptol / up, 'element': ptol / up, 'pressure_unit': net['u_pres'],
        'basis': _P('continuity and balance to %g of the largest flow; loop closure and element equations to '
                 '%g kPa plus %g of the largest head; fixed by PHCP, not by the solver tolerances')
                 % (VERIFY_Q_REL, VERIFY_P, VERIFY_P_REL),
    }
    if tol_loop > VERIFY_P + 1e-12:
        add(code='SOLVER_TOLERANCE_LOOSE', category='numerical', severity='warning', item='TOL_LOOP',
            value=tol_loop / up, limit=VERIFY_P / up, unit=net['u_pres'],
            message=_P('TOL_LOOP %g %s lets the iteration stop with loops further out of balance than the '
                    'verification limit of %g; the answer is checked to the limit')
                    % (tol_loop / up, net['u_pres'], VERIFY_P / up))

    #----------------------------------------------------------- closed flow
    for e in [x for x in el if x.get('closed')]:
        q = e.get('q')
        q = 0 if q is None else q
        if abs(q) <= ctol:
            continue
        add(code='CLOSED_FLOW', category='numerical', item=e['id'], value=q / uf,
            limit=ctol / uf, unit=net['u_flow'],
            message=_P('%s is closed but carries %.4g %s: a closed element is out of the network')
                    % (e['id'], q / uf, net['u_flow']))
    cmax, cat = 0, None
    for i in range(1, nn + 1):
        if i == net['iref']:
            continue
        if abs(acc[i]) > cmax:
            cmax, cat = abs(acc[i]), net['nodes'][i]['id']
    v.setdefault('residuals', {})['continuity'] = {
        'value': cmax / uf, 'tolerance': ctol / uf,
        'unit': net['u_flow'], 'at': cat, 'pass': 1 if cmax <= ctol else 0}
    if cmax > ctol:
        add(code='CONTINUITY', category='numerical', item=cat, value=cmax / uf,
            limit=ctol / uf, unit=net['u_flow'],
            message=_P('continuity fails at node %s: %.6g %s unaccounted for')
                    % (cat, cmax / uf, net['u_flow']))

    #------------------------------------------------------- overall balance
    qin, qout = 0, 0
    for e in open_elems(net):
        if e['kind'].startswith('SUPPLY_'):
            qin += e['q']
        if e['kind'] == 'DISCHARGE':
            qout += e['q']
    for i in range(1, nn + 1):
        d = net['nodes'][i].get('demand')
        qout += d if d is not None else 0
    bal = abs(qin - qout)
    v['residuals']['balance'] = {
        'value': bal / uf, 'tolerance': ctol / uf, 'unit': net['u_flow'],
        'supply': qin / uf, 'demand': qout / uf, 'pass': 1 if bal <= ctol else 0}
    if bal > ctol:
        add(code='BALANCE', category='numerical', item=None, value=bal / uf,
            limit=ctol / uf, unit=net['u_flow'],
            message=_P('the supplies give %.4f %s and the outlets and demands take %.4f %s')
                    % (qin / uf, net['u_flow'], qout / uf, net['u_flow']))

    #------------------------------------------------------------ loop closure
    lmax, lat = 0, None
    for li in range(len(net.get('loops') or [])):
        s = 0
        for st in net['loops'][li]:
            e = net['elems'][st[0]]
            hf = elem_hf(e, e['q'], o)[0]
            s += st[1] * hf
        if abs(s) > lmax or not finite(s):
            lmax, lat = abs(s), li + 1
    v['residuals']['loop'] = {
        'value': lmax / up, 'tolerance': ptol / up, 'solver_tolerance': tol_loop / up,
        'unit': net['u_pres'], 'at': (_P('loop %d') % lat) if lat is not None else None,
        'pass': 1 if lmax <= ptol else 0}
    if lmax > ptol and not v.get('indeterminate'):
        add(code='LOOP_CLOSURE', category='numerical', item=_P('loop %d') % lat, value=lmax / up,
            limit=ptol / up, unit=net['u_pres'],
            message=_P('loop %d does not close: %.6g %s against the verification limit of %g')
                    % (lat, lmax / up, net['u_pres'], ptol / up))

    #-------------------------------------------------------- element equations
    emax, eat = 0, None
    for e in open_elems(net):
        hf = elem_hf(e, e['q'], o)[0]
        dh = net['nodes'][e['n1']]['h'] - net['nodes'][e['n2']]['h']
        r = dh - hf
        if abs(r) > emax:
            emax, eat = abs(r), e['id']
    v['residuals']['element'] = {
        'value': emax / up, 'tolerance': ptol / up, 'solver_tolerance': tol_loop / up,
        'unit': net['u_pres'], 'at': eat, 'pass': 1 if emax <= ptol else 0}
    if emax > ptol and not v.get('indeterminate'):
        add(code='ELEMENT_EQUATION', category='numerical', item=eat, value=emax / up,
            limit=ptol / up, unit=net['u_pres'],
            message=_P('element %s: the pressure across it differs from its own equation by %.6g %s, against '
                    'the verification limit of %g') % (eat, emax / up, net['u_pres'], ptol / up))

#==============================================================================
# PHYSICAL
#==============================================================================

def curve_order(c, dir_):
    for i in range(1, len(c['q'])):
        d = c['p'][i] - c['p'][i - 1]
        if dir_ * d < -1e-9:
            return c['q'][i]
    return None

def extrapolated(c, q):
    if q > c['qhi'] * (1 + 1e-9) + 1e-9:
        return 'ABOVE'
    if q < c['qlo'] * (1 - 1e-9) - 1e-9:
        return 'BELOW'
    return None

def extrapolation_limit(e, c, q, what, D, uf, fu):
    if not (c and D and c['qhi'] > 0):
        return
    aq = abs(q)
    if not aq > EXTRAP_MAX * c['qhi'] * (1 + 1e-9):
        return
    D(code='CURVE_EXTRAPOLATION_LIMIT', item=e['id'], value=aq / uf,
      limit=EXTRAP_MAX * c['qhi'] / uf, unit=fu,
      message=_P('%s %s operates at %.1f %s, more than %g times the highest flow of its curve (%.1f): a '
              'result that far beyond the published or tested performance is not supported by the data')
              % (what, e['id'], aq / uf, fu, EXTRAP_MAX, c['qhi'] / uf))

def loss_curve_checks(e, q, P, what, uf, fu, D):
    c = e.get('curve')
    if not c:
        return
    at = curve_order(c, 1)
    if at is not None:
        P(code='LOSS_CURVE_FALLING', item=e['id'], value=at / uf, unit=fu,
          message=_P('%s %s: its loss FALLS with flow at %.1f %s') % (what, e['id'], at / uf, fu))
    if any(p < 0 for p in c['p']):
        P(code='LOSS_CURVE_NEGATIVE', item=e['id'],
          message=_P('%s %s: a curve point has a negative loss') % (what, e['id']))
    x = extrapolated(c, abs(q))
    if x:
        P(code='CURVE_EXTRAPOLATED', severity='warning', item=e['id'], value=abs(q) / uf,
          limit=(c['qhi'] if x == 'ABOVE' else c['qlo']) / uf, unit=fu,
          message=_P('%s %s passes %.1f %s, %s its curve points (%.1f to %.1f): its loss there is '
                  'EXTRAPOLATED')
                  % (what, e['id'], abs(q) / uf, fu, 'beyond' if x == 'ABOVE' else 'below',
                     c['qlo'] / uf, c['qhi'] / uf))
    if (e.get('loss_source') or '') != 'USER_FIXED':
        extrapolation_limit(e, c, q, what, D, uf, fu)

def physical(net, add):
    uf, up = net['f_flow'], net['f_pres']
    fu, pu = net['u_flow'], net['u_pres']
    el = net['elems'][1:]

    def P(**r):
        r.setdefault('category', 'physical')
        add(**r)

    def add_design(**r):
        r.setdefault('category', 'design')
        add(**r)

    for e in el:
        k = e['kind']
        q = e.get('q')
        q = 0 if q is None else q
        # An element cut off with its supply is out of the network, with no
        # flow and no pressure to judge; the loss of supply itself is a
        # design finding (SUPPLY_ISOLATED).
        if e.get('isolated'):
            continue

        #------------------------------------------------------------ supplies
        if k.startswith('SUPPLY_'):
            if q < -QT:
                P(code='SUPPLY_REVERSE', item=e['id'], value=q / uf, unit=fu,
                  message=_P('water supply %s takes water IN, %.1f %s: a supply does not accept '
                          'flow from the network%s')
                          % (e['id'], -q / uf, fu,
                             ', and its check valve is open' if e.get('nrv') else ''))
            # A supply check valve, worked again from the final heads.
            if e.get('nrv') and e.get('check_closed'):
                h0 = supply_head0(e)
                h = net['nodes'][e['n2']]['h']
                push = h0 - h - e['nrv'].get('crack')
                if push > VERIFY_P:
                    P(code='SUPPLY_CHECK_INCONSISTENT', item=e['id'], value=push / up, limit=0, unit=pu,
                      message=_P('water supply %s is shut on its check valve, but its pressure exceeds the '
                              'network at its connection by %.3f %s more than the valve needs to open: '
                              'the valve would be open') % (e['id'], push / up, pu))
                continue
            if e.get('nrv') and e['nrv'].get('curve'):
                lc = e['nrv']['curve']
                if q > lc['qhi'] + QT:
                    P(code='NRV_CURVE_RANGE', item=e['id'],
                      value=q / uf, limit=lc['qhi'] / uf, unit=fu,
                      message=_P('supply check valve %s: %.1f %s exceeds the last documented '
                              'flow-loss point %.1f %s') % (e['id'], q / uf, fu, lc['qhi'] / uf, fu))
            if k == 'SUPPLY_CURVE':
                at = curve_order(e['curve'], -1)
                if at is not None:
                    P(code='SUPPLY_CURVE_RISING', item=e['id'], value=at / uf, unit=fu,
                      message=_P('water supply %s: its pressure RISES with flow at %.1f %s; a '
                              'supply curve must not rise') % (e['id'], at / uf, fu))
                if any(p < 0 for p in e['curve']['p']):
                    P(code='SUPPLY_CURVE_NEGATIVE', item=e['id'],
                      message=_P('water supply %s: a curve point has a negative pressure') % e['id'])
                x = extrapolated(e['curve'], q)
                if x:
                    P(code='CURVE_EXTRAPOLATED', severity='warning', item=e['id'],
                      value=q / uf,
                      limit=(e['curve']['qhi'] if x == 'ABOVE' else e['curve']['qlo']) / uf,
                      unit=fu,
                      message=_P('water supply %s operates at %.1f %s, %s its curve points (%.1f to '
                              '%.1f): its pressure there is EXTRAPOLATED')
                              % (e['id'], q / uf, fu, 'beyond' if x == 'ABOVE' else 'below',
                                 e['curve']['qlo'] / uf, e['curve']['qhi'] / uf))
                extrapolation_limit(e, e['curve'], q, 'water supply', add_design, uf, fu)
                pa = curve_eval(e['curve'], q)
                if pa < 0:
                    P(code='SUPPLY_EXHAUSTED', item=e['id'], value=pa / up, unit=pu,
                      message=_P('water supply %s: at %.1f %s its curve gives %.1f %s, below zero')
                              % (e['id'], q / uf, fu, pa / up, pu))
            elif (e.get('pstat') or 0) < 0:
                P(code='SUPPLY_NEGATIVE', item=e['id'],
                  message=_P('water supply %s has a negative static pressure') % e['id'])
            continue

        #--------------------------------------------------------------- pumps
        if k == 'PUMP':
            c = e['curve']
            if e.get('isolating'):
                P(code='PUMP_ISOLATING', item=e['id'], value=q / uf, unit=fu,
                  message=_P('pump %s runs backwards (%.1f %s), and closing its check valve '
                          'would isolate part of the network: the model has no valid '
                          'operating state') % (e['id'], q / uf, fu))
            elif not e.get('closed') and q < -QT:
                P(code='PUMP_REVERSE', item=e['id'], value=q / uf, unit=fu,
                  message=_P('pump %s runs backwards, %.1f %s: its check valve does not pass '
                          'reverse flow') % (e['id'], q / uf, fu))
            if e.get('flip_limit'):
                P(code='PUMP_STATE_UNRESOLVED', item=e['id'], value=e.get('nflips'), unit='switches',
                  message=_P('pump %s: its check valve opened and closed on alternate solves until '
                          'the limit was reached; its state is not resolved') % e['id'])
            if e.get('closed'):
                lift = net['nodes'][e['n2']]['h'] - net['nodes'][e['n1']]['h']
                shut = curve_eval(c, 0)
                if lift < shut - 1e-6:
                    P(code='PUMP_STATE_UNRESOLVED', item=e['id'], value=lift / up, limit=shut / up,
                      unit=pu,
                      message=_P('pump %s is shut on its check valve, but the lift across it, %.1f %s, '
                              'is below its shut-off pressure %.1f: it would deliver')
                              % (e['id'], lift / up, pu, shut / up))
                continue
            at = curve_order(c, -1)
            if at is not None:
                # A pump curve may droop: rise a little from shut-off before
                # it falls.  A droop is a warning unless the pump runs on it.
                on = q <= at + 1e-9
                P(code='PUMP_CURVE_RISING', severity='error' if on else 'warning', item=e['id'],
                  value=at / uf, unit=fu,
                  message=_P('pump %s: its curve rises with flow up to %.1f %s%s')
                          % (e['id'], at / uf, fu,
                             ', and the pump operates on that rising part - an unstable '
                             'operating point' if on else ''))
            x = extrapolated(c, q)
            if x:
                P(code='CURVE_EXTRAPOLATED', severity='warning', item=e['id'], value=q / uf,
                  limit=(c['qhi'] if x == 'ABOVE' else c['qlo']) / uf, unit=fu,
                  message=_P('pump %s operates at %.1f %s, beyond its curve points (to %.1f): its '
                          'pressure there is EXTRAPOLATED')
                          % (e['id'], q / uf, fu, c['qhi'] / uf))
            extrapolation_limit(e, c, q, 'pump', add_design, uf, fu)
            rise = curve_eval(c, q)
            if rise < 0:
                P(code='PUMP_BEYOND_RUNOUT', item=e['id'], value=rise / up, unit=pu,
                  message=_P('pump %s at %.1f %s: its curve gives %.1f %s, a pressure LOSS - the pump is '
                          'beyond its run-out') % (e['id'], q / uf, fu, rise / up, pu))
            continue
        if e.get('closed'):
            continue

        #-------------------------------------------------------------- outlets
        if k == 'DISCHARGE':
            if q < -QT:
                P(code='OUTLET_REVERSE', item=e['id'], value=q / uf, unit=fu,
                  message=_P('%s %s discharges BACKWARDS, %.1f %s: water would enter the network '
                          'through it') % ((e.get('otype') or 'outlet').lower(), e['id'], q / uf, fu))
            continue

        #------------------------------------------------------ orifice plates
        if k == 'ORIFICE_REQUIRED':
            P(code='ORIFICE_NOT_SIZED', item=e['id'],
              message=_P('orifice plate %s was never sized: the solve did not reach a converged answer') % e['id'])
            continue
        if k == 'ORIFICE':
            b = e.get('bore') or 0
            d = e.get('pipedia') or 0
            invalid = b <= 0 or (d > 0 and b >= d)
            if invalid:
                P(code='ORIFICE_BORE_INVALID', item=e['id'], value=b, limit=d, unit='mm',
                  message=_P('orifice plate %s: a bore of %.2f mm in a %.2f mm pipe is not a plate')
                          % (e['id'], b, d))
            br = e.get('bore_rounding')
            if not e.get('size_clamp') and br:
                dpt = e.get('dp_target') or 0
                P(code='ORIFICE_UNACHIEVABLE', item=e['id'], value=dpt / up, unit=pu,
                  message=_P('orifice plate %s: a drop of %.3f %s needs a bore of %.3f mm, which rounds '
                          'to %s; the nearest plate that can be made is %.2f mm, and it does not give '
                          'the duty')
                          % (e['id'], dpt / up, pu, e['bore_exact'],
                             'the full pipe bore' if br == 'DOWN_BELOW_PIPE_BORE' else 'nothing', b))
            cl = e.get('size_clamp')
            if cl:
                dpt = e.get('dp_target') or 0
                if cl == 'NO_FLOW':
                    msg = _P('orifice plate %s: there is no flow through it to size it on') % e['id']
                else:
                    msg = (_P('orifice plate %s: a drop of %.2f %s at %.1f %s cannot be produced by any '
                           'bore in this pipe (%s)')
                           % (e['id'], dpt / up, pu, (e.get('q_sized') or 0) / uf, fu,
                              'even a plate of nearly the full bore drops more'
                              if cl == 'BORE_MAX' else 'even the smallest bore drops less'))
                P(code='ORIFICE_UNACHIEVABLE', item=e['id'], value=dpt / up, unit=pu, message=msg)
            if invalid:
                continue
            if d > 0:
                beta = b / d
                if beta < BETA_MIN or beta > BETA_MAX:
                    P(code='ORIFICE_BETA_RANGE', severity='warning', item=e['id'], value=beta,
                      limit=BETA_MIN if beta < BETA_MIN else BETA_MAX, unit='beta',
                      message=_P('orifice plate %s: diameter ratio %.3f is outside %.2f to %.2f, the range '
                              'its loss model is established for (ISO 5167-2)')
                              % (e['id'], beta, BETA_MIN, BETA_MAX))
            if e.get('dp_target') is not None and e['dp_target'] > 0:
                # The plate is sized on one solve and the network solved again
                # with it; see Validate.pm for the deviation decomposition.
                dp = orifice_dp(abs(q), b, d, e.get('cd'))
                dps = orifice_dp(e.get('q_sized') if e.get('q_sized') is not None else abs(q),
                                 b, d, e.get('cd'))
                t = e['dp_target']
                e['dp_final'] = dp
                e['dev_pct'] = 100 * (dp - t) / t
                e['dev_rounding_pct'] = 100 * (dps - t) / t
                e['dev_flow_pct'] = 100 * (dp - dps) / t
                tol = net['opts'].get('orif_dp_tol')
                tol = ORIF_DP_TOL if tol is None else tol
                e['dev_tol_pct'] = tol
                P(code='ORIFICE_DEVIATION', severity='info', item=e['id'],
                  value=dp / up, limit=t / up, unit=pu,
                  message=_P('orifice plate %s: final drop %.2f %s against a target of %.2f (%+.1f %%: '
                          '%+.1f %% from rounding the bore to %.2f mm from %.3f mm, %+.1f %% from the '
                          'flow moving from %.1f to %.1f %s)')
                          % (e['id'], dp / up, pu, t / up, e['dev_pct'], e['dev_rounding_pct'],
                             b, e.get('bore_exact') if e.get('bore_exact') is not None else b,
                             e['dev_flow_pct'],
                             (e.get('q_sized') if e.get('q_sized') is not None else abs(q)) / uf,
                             abs(q) / uf, fu))
                if abs(e['dev_pct']) > tol + 1e-9 and not e.get('size_clamp') and not e.get('bore_rounding'):
                    add_design(code='ORIFICE_DUTY', item=e['id'], value=e['dev_pct'], limit=tol,
                               unit='%',
                               message=_P('orifice plate %s: its final drop, %.2f %s, is %+.1f %% from its target '
                                       'of %.2f, outside the %g %% tolerance (ORIF_DP_TOL); %s')
                                       % (e['id'], dp / up, pu, e['dev_pct'], t / up, tol,
                                          'mostly from rounding the bore: a finer ORIF_STEP is needed'
                                          if abs(e['dev_rounding_pct']) >= abs(e['dev_flow_pct'])
                                          else 'mostly from the flow moving once the plate is in'))
            continue

        #------------------------------------------------- pressure ratio valve
        if k == 'RATIO':
            pin = e.get('pin')
            pin = gauge(net, e['n1']) if pin is None else pin
            if q < -QT:
                P(code='PRA_REVERSE', item=e['id'], value=q / uf, unit=fu,
                  message=_P('pressure ratio valve %s passes water backwards, %.1f %s, which it does not '
                          'do') % (e['id'], q / uf, fu))
            if e.get('mininlet') is not None and pin < e['mininlet']:
                P(code='PRA_MIN_INLET', item=e['id'], value=pin / up, limit=e['mininlet'] / up,
                  unit=pu,
                  message=_P('pressure ratio valve %s: inlet %.1f %s is below its minimum inlet pressure '
                          '%.1f; it does not hold its ratio there')
                          % (e['id'], pin / up, pu, e['mininlet'] / up))
            if pin <= 0 and q > QT:
                P(code='PRA_NO_INLET', item=e['id'], value=pin / up, unit=pu,
                  message=_P('pressure ratio valve %s passes %.1f %s with an inlet pressure of %.1f %s')
                          % (e['id'], q / uf, fu, pin / up, pu))
            continue

        #--------------------------------------------- backflow preventers, PRV
        if k == 'BFP':
            if q < -QT:
                P(code='BFP_REVERSE', item=e['id'], value=q / uf, unit=fu,
                  message=_P('backflow preventer %s passes water backwards, %.1f %s')
                          % (e['id'], q / uf, fu))
            loss_curve_checks(e, q, P, 'loss device', uf, fu, add_design)
            continue
        if k == 'FIXED_DROP':
            if abs(q) <= QT:
                P(code='FIXED_DROP_NO_FLOW', severity='warning', item=e['id'],
                  message=_P('fixed loss %s carries no flow; a fixed loss at no flow is not defined, '
                          'and the pressures either side of it should be checked') % e['id'])
            if q < -QT:
                P(code='FIXED_DROP_REVERSE', severity='warning', item=e['id'], value=q / uf, unit=fu,
                  message=_P('fixed loss %s carries flow backwards, %.1f %s; check that the valve it '
                          'stands for passes reverse flow') % (e['id'], q / uf, fu))
            continue

        #------------------------------------------------------ dry pipe valves
        if k == 'DPV':
            dpv_checks(net, e, P, add_design)
            continue

    #--------------------------------------------------- pressures at nodes
    for i in range(1, len(net['nodes'])):
        if i == net['iref']:
            continue
        p = gauge(net, i)
        if not finite(p):
            continue
        if p < VAPOUR_GAUGE:
            P(code='BELOW_VAPOUR', item=net['nodes'][i]['id'], value=p / up,
              limit=VAPOUR_GAUGE / up, unit=pu,
              message=_P('node %s: %.1f %s gauge is below the vapour pressure of water; no such '
                      'pressure can exist') % (net['nodes'][i]['id'], p / up, pu))
        elif p < -1e-6:
            P(code='NEGATIVE_PRESSURE', severity='warning', item=net['nodes'][i]['id'],
              value=p / up, unit=pu,
              message=_P('node %s: %.1f %s, below atmospheric') % (net['nodes'][i]['id'], p / up, pu))

    #---------------------------------------- every demand reaches a supply
    connectivity(net, P)

#------------------------------------------------------------------------------
# dpv_checks -- a dry pipe valve, as the steady-state solve takes it.
#------------------------------------------------------------------------------

def dpv_checks(net, e, P, D):
    uf, up = net['f_flow'], net['f_pres']
    fu, pu = net['u_flow'], net['u_pres']
    q = e.get('q')
    q = 0 if q is None else q
    id_ = e['id']

    if q < -QT:
        P(code='DPV_REVERSE', item=id_, value=q / uf, unit=fu,
          message=_P('dry pipe valve %s passes water backwards, %.1f %s: its clapper is a check valve')
                  % (id_, q / uf, fu))
    if abs(q) <= QT:
        P(code='DPV_NO_FLOW', severity='warning', item=id_,
          message=_P('dry pipe valve %s carries no flow: the system it serves is not flowing in this calculation') % id_)

    # Connection: a valve in a pipe, with the pipe found.
    if not (e.get('host_id') is not None
            and any(x['kind'] == 'PIPE' and x['id'] == e['host_id'] for x in net['elems'][1:])):
        P(code='DPV_CONNECTION', item=id_,
          message=_P('dry pipe valve %s is not in a pipe of the model') % id_)
    # Size.
    size = e.get('size') or 0
    if not (size >= 25 and size <= 300):
        P(code='DPV_SIZE', item=id_, value=e.get('size'), unit='mm',
          message=_P('dry pipe valve %s: a nominal size of %s mm is not a valve size')
                  % (id_, e.get('size') if e.get('size') is not None else 'none'))
    if e.get('host') and e['host'].get('dia') and size > 0:
        if size < 0.6 * e['host']['dia'] or size > 1.6 * e['host']['dia']:
            P(code='DPV_SIZE_PIPE', severity='warning', item=id_, value=e.get('size'),
              limit=e['host']['dia'], unit='mm',
              message=_P('dry pipe valve %s: DN%d in a pipe of %.1f mm bore; check the valve suits its pipe')
                      % (id_, e.get('size'), e['host']['dia']))

    # Trip method: exactly one, and physically meaningful.
    m = e.get('trip_mode') or ''
    if m == 'RATIO':
        r = e.get('trip_ratio')
        if r is None or r <= 1:
            P(code='DPV_RATIO', item=id_, value=r, unit='ratio',
              message=_P('dry pipe valve %s: a differential trip ratio must be more than 1:1') % id_)
        elif r < DPV_RATIO_LO or r > DPV_RATIO_HI:
            P(code='DPV_RATIO_RANGE', severity='warning', item=id_, value=r, unit='ratio',
              message=_P('dry pipe valve %s: a differential trip ratio of %.2f:1 is outside %g:1 to %g:1; '
                      'check it against the valve data') % (id_, r, DPV_RATIO_LO, DPV_RATIO_HI))
        if e.get('trip_pressure') is not None:
            P(code='DPV_TRIP_METHOD', item=id_,
              message=_P('dry pipe valve %s: give a trip ratio OR a trip pressure, not both') % id_)
    elif m == 'TRIP':
        t = e.get('trip_pressure')
        if not (t is not None and t > 0):
            P(code='DPV_TRIP_PRESSURE', item=id_,
              value=(t / up if t is not None else None), unit=pu,
              message=_P('dry pipe valve %s: an air-side trip pressure must be more than zero') % id_)
        # Above 700 kPa of air no dry system is run.
        if t is not None and t > 700:
            P(code='DPV_TRIP_PRESSURE', item=id_, value=t / up, limit=700 / up, unit=pu,
              message=_P('dry pipe valve %s: an air-side trip pressure of %.1f %s is higher than any dry '
                      'system is run at; check the pressure unit') % (id_, t / up, pu))
        if e.get('trip_ratio') is not None:
            P(code='DPV_TRIP_METHOD', item=id_,
              message=_P('dry pipe valve %s: give a trip ratio OR a trip pressure, not both') % id_)
    else:
        P(code='DPV_TRIP_METHOD', item=id_,
          message=_P('dry pipe valve %s: the trip method must be RATIO or TRIP') % id_)
    if not ((e.get('accelerator') or '') in ('ON', 'OFF')):
        P(code='DPV_ACCELERATOR', item=id_,
          message=_P('dry pipe valve %s: the accelerator must be ON or OFF') % id_)

    # Loss data.
    basis = e.get('loss')
    basis = 'NONE' if basis is None else basis
    src = e.get('loss_source') or ''
    if basis == 'NONE':
        d = e.get('db')
        if d:
            note = d.get('note') or ''
            P(code='DPV_NO_LOSS_DATA', item=id_,
              message=_P('dry pipe valve %s: DATA_REQUIRED - the database record for the %s %s DN%s has '
                      'no usable pressure loss (neither a flow coefficient nor an equivalent length of a stated pipe)'
                      '%s.  Give the manufacturer\'s flow/loss points or an equivalent length.  No loss is assumed.')
                      % (id_, d['maker'], d['model'], d['dn'],
                         _P(': %s') % note if (len(note) and note != 'DASH') else ''))
        else:
            P(code='DPV_NO_LOSS_DATA', item=id_,
              message=_P('dry pipe valve %s: DATA_REQUIRED - it has no pressure loss data: give the '
                      'manufacturer\'s flow/loss points or an equivalent length (EQL).  No loss is assumed.') % id_)
    elif src == 'USER_FIXED':
        fl = e.get('fixed_loss') or 0
        P(code='DPV_SIMPLIFIED_LOSS', severity='warning', item=id_, value=fl / up, unit=pu,
          message=_P('dry pipe valve %s: a constant loss of %.2f %s at every flow is a SIMPLIFICATION, not '
                  'the valve\'s characteristic; it holds only near the flow it was taken at.  Give the '
                  'manufacturer\'s flow/loss points, or the valve from the database')
                  % (id_, fl / up, pu))
        if abs(q) <= QT and fl > 0:
            P(code='DPV_FIXED_NO_FLOW', item=id_, value=fl / up, unit=pu,
              message=_P('dry pipe valve %s carries no flow but is given a constant loss of %.2f %s: a '
                      'pressure difference across an open valve passing nothing is not physical')
                      % (id_, fl / up, pu))
        if fl < 0:
            P(code='LOSS_CURVE_NEGATIVE', item=id_,
              message=_P('dry pipe valve %s: a negative constant loss') % id_)
    elif basis == 'EQL':
        if not (e.get('eql') or 0) > 0:
            P(code='DPV_EQL', item=id_, value=e.get('eql'), unit='m',
              message=_P('dry pipe valve %s: an equivalent length must be more than zero') % id_)
        if not e.get('host'):
            P(code='DPV_EQL_HOST', item=id_,
              message=_P('dry pipe valve %s: the pipe it is in was not found, so its equivalent length has no bore') % id_)
    elif basis == 'CURVE':
        loss_curve_checks(e, q, P, 'dry pipe valve', uf, fu, D)
        # At no flow a tripped, open valve has no loss.
        p0 = curve_eval(e['curve'], 0)
        if p0 < -1e-9:
            P(code='DPV_LOSS_AT_ZERO', item=id_, value=p0 / up, unit=pu,
              message=_P('dry pipe valve %s: its loss curve, extended below its first point, gives %.2f %s at '
                      'no flow - a passive valve adding pressure.  Give a point at low flow')
                      % (id_, p0 / up, pu))
        elif p0 > 1e-6:
            P(code='DPV_LOSS_AT_ZERO', severity='warning', item=id_, value=p0 / up, unit=pu,
              message=_P('dry pipe valve %s: its loss curve gives %.2f %s at no flow; a tripped, open valve '
                      'has no loss when nothing flows.  Check the first point') % (id_, p0 / up, pu))
    elif basis == 'DB' and e.get('db'):
        d = e['db']
        pin = gauge(net, e['n1'])
        if d.get('pmax_kpa') is not None and pin > d['pmax_kpa'] + 1e-6:
            P(code='DPV_PRESSURE_RATING', item=id_, value=pin / up, limit=d['pmax_kpa'] / up, unit=pu,
              message=_P('dry pipe valve %s (%s %s): %.1f %s at its inlet, above its rated working pressure of '
                      '%.1f (%s)') % (id_, d['maker'], d['model'], pin / up, pu, d['pmax_kpa'] / up, d.get('source')))
        if (e.get('trip_mode') or '') == 'RATIO' and e.get('trip_ratio') is not None:
            if (d.get('trip') or '').upper() == 'LOW':
                P(code='DPV_RATIO_DB', severity='warning', item=id_, value=e['trip_ratio'], unit='ratio',
                  message=_P('dry pipe valve %s: the %s %s is a low-pressure valve, set by its air '
                          'pressure table, not a differential ratio (%s)')
                          % (id_, d['maker'], d['model'], d.get('source')))
            elif d.get('trip_ratio') is not None and abs(e['trip_ratio'] - d['trip_ratio']) > 0.25:
                P(code='DPV_RATIO_DB', severity='warning', item=id_, value=e['trip_ratio'],
                  limit=d['trip_ratio'], unit='ratio',
                  message=_P('dry pipe valve %s: a trip ratio of %.2f:1 is given; the %s %s data sheet gives '
                          'about %g:1 (%s)')
                          % (id_, e['trip_ratio'], d['maker'], d['model'], d['trip_ratio'], d.get('source')))
        if (d.get('status') or '').upper() == 'LEGACY':
            P(code='DPV_LEGACY', severity='warning', item=id_,
              message=_P('dry pipe valve %s: the %s %s is a legacy valve, no longer sold (%s)')
                      % (id_, d['maker'], d['model'], d.get('source')))
        if len(d.get('note') or '') and d['note'] != 'DASH':
            P(code='DPV_DATA_NOTE', severity='warning', item=id_,
              message=_P('dry pipe valve %s (%s %s DN%s): %s')
                      % (id_, d['maker'], d['model'], d['dn'], d['note']))
    # The pressures either side: a dry pipe valve does not add pressure.
    dp = net['nodes'][e['n1']]['h'] - net['nodes'][e['n2']]['h']
    if q > QT and dp < -1e-6:
        P(code='DPV_GAIN', item=id_, value=dp / up, unit=pu,
          message=_P('dry pipe valve %s: the pressure rises across it by %.2f %s') % (id_, -dp / up, pu))

#------------------------------------------------------------------------------
# connectivity -- every operating demand reachable from a usable supply.
#------------------------------------------------------------------------------

ONE_WAY = {'PUMP': 1, 'BFP': 1, 'RATIO': 1, 'DPV': 1}

def connectivity(net, P):
    el = [e for e in net['elems'][1:] if not e.get('closed')]
    adj = {}
    start = []
    for e in el:
        k = e['kind']
        if k.startswith('SUPPLY_'):
            p = e['pstat'] if k == 'SUPPLY_STATIC' else curve_eval(e['curve'], 0)
            if (p if p is not None else 0) >= 0:
                start.append(e['n2'])
            continue
        if k == 'DISCHARGE':
            continue
        adj.setdefault(e['n1'], []).append(e['n2'])
        if k not in ONE_WAY:
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
    demand = ([[e['id'], e['n1'], (e.get('otype') or 'outlet').lower()]
               for e in el if e['kind'] == 'DISCHARGE']
              + [[f['id'], f['n1'], 'fixed flow']
                 for f in (net.get('fixed') or []) if (f.get('qreq') or 0) > 0])
    dead = {i: 1 for i in ((net.get('supply_isolated') or {}).get('index') or [])}
    for d in demand:
        if d[1] in seen or d[1] in dead:
            continue
        P(code='DEMAND_UNCONNECTED', item=d[0],
          message=_P('%s %s at node %s cannot be reached from any water supply through the pipework '
                  'in the direction water can flow')
                  % (d[2], d[0], net['nodes'][d[1]]['id']))

#==============================================================================
# DESIGN
#==============================================================================

def design(net, add, **o):
    uf, up = net['f_flow'], net['f_pres']
    fu, pu = net['u_flow'], net['u_pres']
    opts = net['opts']

    def D(**r):
        r.setdefault('category', 'design')
        add(**r)

    el = [e for e in net['elems'][1:] if not e.get('closed')]
    what = {'SPRINKLER': 'sprinkler', 'HYDRANT': 'hydrant', 'HOSEREEL': 'hose reel'}

    # Loss of supply.
    iso = net.get('supply_isolated')
    if iso:
        out = iso.get('outlets') or []
        nodes = iso.get('nodes') or []
        supplies = iso.get('supplies') or []
        if nodes:
            D(code='SUPPLY_ISOLATED', item=' '.join(out),
              message=_P('LOSS OF SUPPLY: the check valve%s of %s %s shut and no other supply can reach '
                      'node%s %s, so %s receive%s no water')
                      % ('s' if len(supplies) > 1 else '',
                         ', '.join(supplies),
                         'are' if len(supplies) > 1 else 'is',
                         's' if len(nodes) > 1 else '',
                         ', '.join(nodes),
                         ', '.join(out) if out else 'no outlet there',
                         's' if len(out) == 1 else ''))

    # Every outlet: its flow and the pressure it discharges on.
    for e in [x for x in el if x['kind'] == 'DISCHARGE']:
        w = what.get(e.get('otype') or '', 'outlet')
        p = outlet_pressure(net, e)
        why = []
        if e['q'] < e['qreq'] - 1e-6:
            why.append(_P('flow %.2f %s against %.2f required') % (e['q'] / uf, fu, e['qreq'] / uf))
        if p < e['preq'] - 1e-6:
            why.append(_P('pressure %.2f %s against %.2f required') % (p / up, pu, e['preq'] / up))
        if why:
            D(code='OUTLET_REQUIREMENT', item=e['id'], value=(p - e['preq']) / up, limit=0,
              unit=pu, outlet_type=e.get('otype'),
              message=_P('%s %s does not meet its requirement: %s') % (w, e['id'], '; '.join(why)))
    for f in [x for x in (net.get('fixed') or []) if x.get('preq') is not None]:
        p = gauge(net, f['n1'])
        if p < f['preq'] - 1e-6:
            D(code='FIXED_FLOW_PRESSURE', item=f['id'], value=(p - f['preq']) / up, limit=0,
              unit=pu,
              message=_P('fixed flow %s: %.2f %s at its node against the %.2f it needs')
                      % (f['id'], p / up, pu, f['preq'] / up))

    # The velocity limit.
    vl = opts.get('vel_limit')
    vl = 6 if vl is None else vl
    for e in [x for x in el if x['kind'] == 'PIPE'
              and abs(pipe_velocity(x['q'], x['dia'])) > vl]:
        vel = abs(pipe_velocity(e['q'], e['dia']))
        D(code='VELOCITY_LIMIT', severity='error' if opts.get('vel_limit_set') else 'warning',
          item=e['id'], value=vel, limit=vl, unit='m/s',
          message=_P('pipe %s: %.2f m/s over the %s velocity limit of %g m/s')
                  % (e['id'], vel, 'design' if opts.get('vel_limit_set') else 'default', vl))

    # Pump duties (PUMPDUTY): the curve against the rated duty.
    if any(e['kind'] == 'PUMP' for e in el):
        from . import pumpcheck
        for p in [x for x in pumpcheck.check(net) if x.get('duty') and not x.get('ok')]:
            if not p['at_duty']['ok']:
                detail = (_P('its curve gives %.1f %s at its duty flow against a duty of %.1f')
                          % (p['at_duty']['p'] / up, pu, p['duty'][1] / up))
            else:
                detail = _P('shut-off %.1f %s is above 140 %% of its duty pressure') % (p['shutoff'] / up, pu)
            D(code='PUMP_DUTY', item=p['id'], value=p['at_duty']['p'] / up,
              limit=p['duty'][1] / up, unit=pu,
              message=_P('pump %s: %s') % (p['id'], detail))

    # The supply against the demand, with the margin the model asks for.
    need = opts.get('supply_margin')
    need = 0 if need is None else need
    da = o.get('assessment') or {}
    dm = o.get('demand')
    if dm:
        if (dm.get('status') or '') == 'UNRESOLVED':
            # The search itself failed -- not a supply found too weak.
            D(code='SUPPLY_DEMAND_UNRESOLVED', item=None,
              message=_P("the supply's adequacy could not be demonstrated: %s") % dm['reason'])
            da.clear()
            da.update(status='UNRESOLVED', basis='DEMAND POINT, one supply', message=dm['reason'])
        elif dm.get('reason'):
            # Not worked out.  Several supplies are judged on the supply
            # schedule below; otherwise this is a finding.
            import re as _re
            na = _re.match(r'^(\d+ supplies|the model has no supply|the model has no outlet with a required pressure)',
                           dm['reason'])
            if not na:
                D(code='DEMAND_NOT_FOUND', item=None,
                  message=_P('the demand point was not found: %s') % dm['reason'])
            if not na:
                da.clear()
                da.update(status='INADEQUATE', basis='DEMAND POINT, one supply', message=dm['reason'])
        elif dm['margin'] < need - 1e-6:
            D(code='SUPPLY_ADEQUACY', item=dm['supply']['id'], value=dm['margin'] / up,
              limit=need / up, unit=pu,
              message=_P('supply %s: %.1f %s available at the demand flow against %.1f needed, a margin '
                      'of %.1f %s where %.1f is required')
                      % (dm['supply']['id'], dm['p_avail'] / up, pu, dm['p_demand'] / up,
                         dm['margin'] / up, pu, need / up))
            da.clear()
            da.update(status='INADEQUATE', basis='DEMAND POINT, one supply',
                      message=_P('margin %.1f %s against %.1f required') % (dm['margin'] / up, pu, need / up))
        else:
            da.clear()
            da.update(status='DEMONSTRATED', basis='DEMAND POINT, one supply',
                      message=_P('margin %.1f %s against %.1f required') % (dm['margin'] / up, pu, need / up))
    s = o.get('supplies')
    if s:
        # The joint demand -- every supply at once, from one solve.
        j = s.get('joint')
        st = ('NOT_ASSESSED' if not j
              else j.get('status') or ('UNRESOLVED' if j.get('reason') else 'FOUND'))
        basis = _P('JOINT DEMAND on the %s basis (an assumption)') % (j.get('basis') if j and j.get('basis') else '-')
        if st == 'UNRESOLVED':
            D(code='SUPPLY_DEMAND_UNRESOLVED', item='ALL',
              message=_P("the supplies' joint adequacy could not be demonstrated: %s") % j['reason'])
            da.clear()
            da.update(status='UNRESOLVED', basis=basis, message=j['reason'])
        elif st == 'INADEQUATE':
            D(code='SUPPLY_ADEQUACY', item='ALL',
              message=_P('the supplies together cannot meet the demand: %s') % j['reason'])
            da.clear()
            da.update(status='INADEQUATE', basis=basis, message=j['reason'])
        elif st == 'NOT_LIMITING':
            da.clear()
            da.update(status='DEMONSTRATED', basis=basis, message=j['reason'])
        elif st == 'FOUND' and j['margin'] < need - 1e-6:
            D(code='SUPPLY_ADEQUACY', item='ALL', value=j['margin'] / up, limit=need / up, unit=pu,
              message=_P('the supplies together, on the %s basis, have %.1f %s %s at the joint demand '
                      'where %.1f is required')
                      % (j['basis_name'], abs(j['margin']) / up, pu,
                         'to spare' if j['margin'] >= 0 else 'too little', need / up))
            da.clear()
            da.update(status='INADEQUATE', basis=basis,
                      message=_P('margin %.1f %s against %.1f required') % (j['margin'] / up, pu, need / up))
        elif st == 'FOUND':
            da.clear()
            da.update(status='DEMONSTRATED', basis=basis,
                      message=_P('margin %.1f %s against %.1f required') % (j['margin'] / up, pu, need / up))
        for sc in (s.get('scenarios') or []):
            if not sc.get('required'):
                continue
            if sc['acceptance'] != 'ACCEPTED':
                D(code='SCENARIO', item=sc['name'],
                  message=_P('required supply scenario %s (%s): %s')
                          % (sc['name'], sc['description'], sc['acceptance']))

#------------------------------------------------------------------------------
# dry_time_checks -- what the trip time estimate finds about a dry pipe
# valve's setting.
#------------------------------------------------------------------------------

def dry_time_checks(net, add, dry):
    up = net['f_pres']
    for d in dry:
        if d.get('error'):
            add(category='physical', code='DPV_NOT_DRY', item=d['id'],
                message=_P('dry pipe valve %s: %s') % (d['id'], d['error']))
            continue
        t = d.get('trip')
        if not t:
            continue
        if (t.get('status') or '') == 'ERROR':
            add(category='physical', code='DPV_AIR_BELOW_TRIP', item=d['id'],
                value=(t.get('air_gauge') or 0) / up, limit=(t.get('trip_gauge') or 0) / up,
                unit=net['u_pres'],
                message=_P('dry pipe valve %s: %s') % (d['id'], t['reason']))
        if (t.get('status') or '') == 'ESTIMATE' and not t.get('choked'):
            add(category='physical', code='DPV_TRIP_NOT_CHOKED', severity='warning', item=d['id'],
                message=_P('dry pipe valve %s: the trip pressure, %.1f %s, is below the 1.893 atmospheres at '
                        'which flow through the orifice stops being choked; the trip time formula assumes '
                        'choked flow, and its estimate is less reliable')
                        % (d['id'], t['trip_gauge'] / up, net['u_pres']))

#------------------------------------------------------------------------------
# assess -- THE validated result of a solved network.
#------------------------------------------------------------------------------

def assess(net, ok, **o):
    want_demand = o.get('demand')
    want_demand = 1 if want_demand is None else want_demand
    a = net.get('assessment')
    if a and a['ok'] == (1 if ok else 0) and (a.get('with_demand') or not want_demand):
        return a
    from . import demand as _demand
    from . import supplies as _supplies
    dm = None
    sup = None
    if ok and want_demand:
        dm = _demand.demand_point(net)
        sup = _supplies.analyse(net, ok)
    elif len(_demand.supplies(net)) > 1:
        # The operating schedule needs no re-solve, so it is given even
        # without the demands, and for an unconverged solve -- marked so.
        sup = _supplies.analyse(net, 0)
    # The estimated trip and transit times of each dry pipe valve.
    dry = None
    if ok and any(e['kind'] == 'DPV' for e in net['elems'][1:]):
        from . import drytime as _drytime
        at_demand = dm and not dm.get('reason') and dm.get('net')
        if at_demand:
            dry = _drytime.analyse(net, dm['net'], 'demand point')
        else:
            dry = _drytime.analyse(net, net, 'operating point')
    kw = {}
    if dm:
        kw['demand'] = dm
    if sup:
        kw['supplies'] = sup
    if dry:
        kw['dry'] = dry
    v = validate(net, ok, **kw)
    a = {'ok': 1 if ok else 0, 'with_demand': 1 if (want_demand and ok) else 0,
         'demand': dm, 'supplies': sup, 'dry': dry, 'validation': v}
    net['assessment'] = a
    return a

_SAY = {
    'ACCEPTED':      'ACCEPTED - numerically valid, physically valid and compliant with the design',
    'NONCOMPLIANT':  'NONCOMPLIANT - numerically and physically valid, but the design is not met or not demonstrated',
    'REJECTED':      'REJECTED - the results are not a valid solution of the model',
    'INDETERMINATE': 'INDETERMINATE - no settled, converged solution; the results must not be used',
}

def acceptance_text(a):
    return _SAY.get(a, 'UNKNOWN')
