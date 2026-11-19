#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# jsonout.py -- Python port of HardyCross/Json.pm.
#
# The results as JSON, for another program to read.  Interface 2: see the
# head of Json.pm for the whole field list.  The encoder matches Perl's
# JSON::PP canonical-pretty-ascii output byte for byte, so callers that
# parse the text line by line (AutoLISP) see the same lines.
#

import re

from . import (VERSION, GAMMA_W as GW, elem_hf, pipe_velocity,
               outlet_pressure, is_model_error)
from . import demand, pipedata
from . import supplies as _supplies
from .validate import (assess, extrapolated, ORIF_DP_TOL, EXTRAP_MAX)
from .report import sym

INTERFACE = 2

# exit_code -- the exit status for a solve, from its acceptance.  phcp
# uses it with and without --json, so the two agree.
_EXIT = {'ACCEPTED': 0, 'NONCOMPLIANT': 0, 'INDETERMINATE': 1, 'ERROR': 2,
         'REJECTED': 3}

def exit_code(acc, strict=False):
    acc = acc or 'INDETERMINATE'
    if strict and acc == 'NONCOMPLIANT':
        return 4
    return _EXIT.get(acc, 1)

# An element's kind in the language's own words.
KIND = {'PUMP': 'PUMP', 'BFP': 'LOSS CURVE', 'FIXED_DROP': 'FIXED DROP',
        'ORIFICE': 'ORIFICE PLATE', 'ORIFICE_REQUIRED': 'ORIFICE PLATE',
        'RATIO': 'PRA'}

def r4(v):
    return None if v is None else 0 + float('%.4f' % v)

def r3(v):
    return None if v is None else 0 + float('%.3f' % v)

# _numify -- the Perl's numification, 0 + $v, for values that reach JSON
# as text: a database DN or Cv is read from pipes.dat as a string and
# must print as a number, '100' as 100 and not "100".  (_num, further
# down, stringifies a number for the JSON writer.)
def _numify(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, (int, float)):
        return v
    try:
        return int(str(v).strip())
    except ValueError:
        return float(v)

# units -- the unit of each quantity, as the report prints it.
def units(net):
    return {'flow': sym(net['u_flow']), 'pressure': sym(net['u_pres']),
            'length': 'm', 'elevation': 'm', 'size': 'mm', 'velocity': 'm/s'}

#------------------------------------------------------------------------------
# results -- the JSON object (a dict) for a solved network.
#------------------------------------------------------------------------------
def results(net, ok, model, **o):
    uf, up = net['f_flow'], net['f_pres']
    node = lambda i: net['nodes'][i]
    el = net['elems'][1:]

    pipes, elems, nodes, outlets = [], [], [], []

    def extrap(e):
        if not (e.get('curve') and (e.get('loss_source') or '') != 'USER_FIXED'):
            return None
        return TRUE if extrapolated(e['curve'], abs(e['q'])) else FALSE

    for e in el:
        if e['kind'] == 'PIPE':
            hf = elem_hf(e, e['q'], net['opts'])[0]
            pipes.append({'id': e['id'], 'from': node(e['n1'])['id'],
                          'to': node(e['n2'])['id'],
                          'flow': r4(e['q'] / uf),
                          'velocity': r3(pipe_velocity(e['q'], e['dia'])),
                          'friction_loss': r4(hf / up), 'length': r4(e['len']),
                          'equivalent_length': r4(e['eqv']), 'bore': r4(e['dia']),
                          'nominal': e.get('dn')})
        elif e['kind'].startswith('SUPPLY_'):
            # A supply joins its node to the solver's datum (REF), which is
            # nothing to a caller: it is reported by its node alone.
            elems.append({'id': e['id'], 'kind': 'WATER', 'from': None,
                          'to': node(e['n2'])['id'], 'flow': r4(e['q'] / uf),
                          'extrapolated': extrap(e)})
        elif e['kind'] != 'DISCHARGE':
            # A device in a pipe is "<pipe>.<command>".
            m = re.search(r'\.([A-Z]+)\Z', e['id'])
            elems.append({'id': e['id'], 'kind': m.group(1) if m else KIND.get(e['kind'], e['kind']),
                          'from': node(e['n1'])['id'], 'to': node(e['n2'])['id'],
                          'flow': r4(e['q'] / uf), 'extrapolated': extrap(e)})
    for i in range(1, len(net['nodes'])):
        n = node(i)
        if n['id'] == 'REF':
            continue
        nodes.append({'id': n['id'], 'elevation': r4(n['z']),
                      'pressure': r4(demand.gauge(net, i) / up)})
    fail = []
    for e in [x for x in el if x['kind'] == 'DISCHARGE']:
        p = (node(e['n1'])['h'] - GW * e['z']) / up
        pd = outlet_pressure(net, e) / up
        passed = e['q'] >= e['qreq'] - 1e-6 and pd >= e['preq'] / up - 1e-6
        outlets.append({'id': e['id'], 'node': node(e['n1'])['id'],
                       'type': 'HREEL' if e['otype'] == 'HOSEREEL' else e['otype'],
                       'k': r4(e['k']),
                       'required_flow': r4(e['qreq'] / uf), 'flow': r4(e['q'] / uf),
                       'required_pressure': r4(e['preq'] / up), 'pressure': r4(p),
                       'velocity_pressure': r4((e.get('pv') or 0) / up),
                       'discharge_pressure': r4(pd),
                       'margin': r4(pd - e['preq'] / up),
                       'pass': TRUE if passed else FALSE})
        if not passed:
            fail.append(outlets[-1])
    for f in [x for x in (net.get('fixed') or []) if x.get('preq') is not None]:
        p = (node(f['n1'])['h'] - GW * f['z']) / up
        passed = p >= f['preq'] / up - 1e-6
        outlets.append({'id': f['id'], 'node': node(f['n1'])['id'], 'type': 'FIXEDFLOW',
                       'k': None,
                       'required_flow': r4(f['qreq'] / uf), 'flow': r4(f['q'] / uf),
                       'required_pressure': r4(f['preq'] / up), 'pressure': r4(p),
                       'margin': r4(p - f['preq'] / up),
                       'pass': TRUE if passed else FALSE})
        if not passed:
            fail.append(outlets[-1])

    go, gm = demand.governing_outlet(net)
    j = {
        'interface': INTERFACE, 'program': 'PHCP %s' % VERSION, 'model': model,
        'status': 'converged' if ok else 'not_converged',
        'converged': TRUE if ok else FALSE,
        'iterations': net.get('iters') or 0,
        'units': units(net),
        'velocity_pressure': TRUE if net['opts'].get('vel_press') else FALSE,
        'database': ({'name': pipedata.dataset(), 'issued': pipedata.issued(),
                      'file': pipedata.path(), 'sha256': pipedata.sha256()}
                     if pipedata.path() else None),
        'pipes': pipes, 'elements': elems, 'nodes': nodes, 'outlets': outlets,
        'governing': {'id': go['id'], 'margin': r4(gm / up)} if go else None,
        'warnings': list(net.get('warnings') or []), 'errors': [],
        'design_area': net.get('design_area'),
        'sized': ([{'line': u['line'], 'pipes': u['pipes'], 'type': u['type'],
                    'dn': u['dn'], 'size': u['token'],
                    'velocity': (None if u.get('velocity') is None
                                else 0 + float('%.3f' % u['velocity']))}
                   for u in net['sizing']['units']]
                  if net.get('sizing') else None),
        'areas': ([{'name': a['name'], 'outlets': a['outlets'],
                    'governing': a['governing'],
                    'margin': (None if a.get('margin') is None else r4(a['margin'] / up)),
                    'demand_flow': (None if not a.get('demand') else r4(a['demand']['q'] / uf)),
                    'demand_pressure': (None if not a.get('demand') else r4(a['demand']['p'] / up)),
                    'supply_margin': (None if not a.get('demand') else r4(a['demand']['margin'] / up)),
                    'converged': TRUE if a.get('ok') else FALSE,
                    'governs': TRUE if a.get('governs') else FALSE}
                   for a in net['area_results']]
                  if net.get('area_results') else None),
    }
    u = j['units']

    # The validation: the same result the report prints.
    as_ = assess(net, ok, demand=o.get('demand', 1))
    va = as_['validation']
    j['acceptance'] = va['acceptance']
    j['approved'] = TRUE if va['acceptance'] == 'ACCEPTED' else FALSE
    j['demand_assessment'] = dict(va.get('demand_assessment') or {'status': 'NOT_ASSESSED'})
    j['validation'] = {
        'numerical': va['numerical'], 'physical': va['physical'], 'design': va['design'],
        'residuals': {k: {'value': 0 + float('%.6e' % r['value']),
                          'tolerance': 0 + float('%.6e' % r['tolerance']),
                          **({'solver_tolerance': 0 + float('%.6e' % r['solver_tolerance'])} if r.get('solver_tolerance') is not None else {}),
                          'unit': sym(r['unit']), 'at': r.get('at'),
                          'pass': TRUE if r['pass'] else FALSE}
                      for k, r in (va.get('residuals') or {}).items() if r},
        'solver': {**va['solver'],
                   'hc_converged': TRUE if va['solver']['hc_converged'] else FALSE,
                   'outer_settled': TRUE if va['solver']['outer_settled'] else FALSE},
        'verification': ({**va['verification'],
                          'flow_unit': sym(va['verification']['flow_unit']),
                          'pressure_unit': sym(va['verification']['pressure_unit'])}
                         if va.get('verification') else None),
        'findings': [{k: f[k] for k in ('code', 'category', 'severity', 'item', 'value',
                                        'limit', 'unit', 'message', 'outlet_type')
                      if f.get(k) is not None}
                     for f in va['findings']],
    }
    j['validation_errors'] = ['%s: %s' % (f['code'], f['message'])
                              for f in va['findings'] if f['severity'] == 'error']
    if as_.get('supplies'):
        j['supplies'] = supplies_json(net, as_['supplies'])
    j['supply_check_valves'] = check_valves_json(net)
    j['dry_pipe_valves'] = dpv_json(net, va, as_.get('dry'))
    j['traceability'] = traceability(net, va)
    j['assumptions'] = assumptions(net)

    if (o.get('demand', 1)) and ok:
        dm = as_.get('demand')
        if dm and dm.get('reason'):
            j['demand'] = None
            j['demand_reason'] = dm['reason']
        elif dm:
            j['demand'] = {'supply': dm['supply']['id'], 'flow': r4(dm['q_demand'] / uf),
                           'pressure': r4(dm['p_demand'] / up),
                           'available': r4(dm['p_avail'] / up),
                           'margin': r4(dm['margin'] / up),
                           'meets': TRUE if dm['margin'] >= 0 else FALSE}
    else:
        j['demand'] = None
        j['demand_reason'] = 'not asked for' if ok else 'the solve did not converge'

    # The summary: what a caller shows a user in a few lines.
    s = []
    from .validate import acceptance_text
    s.append('CALCULATION ' + acceptance_text(va['acceptance']).upper())
    if va['acceptance'] != 'ACCEPTED':
        s.append('NOT AN APPROVED DESIGN')
    s.append('CONVERGED IN %d ITERATIONS' % j['iterations'] if ok
             else 'DID NOT CONVERGE - THE RESULTS MUST NOT BE USED')
    s += [('MANDATORY: %s - %s' % (f['code'], f['message'])).upper()
          for f in va['findings']
          if f['severity'] == 'error' and f['category'] != 'design']
    if j.get('areas'):
        s.append('DESIGN AREA %s GOVERNS, OF %d AREAS SOLVED' % (j['design_area'], len(j['areas'])))
    elif j.get('design_area') is not None:
        s.append('DESIGN AREA %s, CHOSEN BY OPTION DESIGN_AREA' % j['design_area'])
    if net['opts'].get('vel_press'):
        s.append('VELOCITY PRESSURE INCLUDED: IN-LINE SPRINKLERS DISCHARGE ON NORMAL PRESSURE (AS 2118.1 CL 14.15)')
    if go:
        g = next((x for x in outlets if x['id'] == go['id']), None)
        if g:
            s.append('GOVERNING OUTLET %s: %.1f %s AGAINST %.1f REQUIRED, MARGIN %.1f %s'
                     % (go['id'],
                        g['discharge_pressure'] if g['discharge_pressure'] is not None else g['pressure'],
                        u['pressure'].upper(), g['required_pressure'], g['margin'],
                        u['pressure'].upper()))
    for f in fail:
        s.append('FAIL: %s AT %s %.1f %s AGAINST %.1f REQUIRED'
                 % (f['type'], f['id'],
                    f['discharge_pressure'] if f['discharge_pressure'] is not None else f['pressure'],
                    u['pressure'].upper(), f['required_pressure']))
    if outlets:
        s.append(('%d OUTLET%s FAIL' % (len(fail), '' if len(fail) == 1 else 'S'))
                 if fail else 'EVERY OUTLET PASSES')
    d = j.get('demand')
    if d:
        s.append('SUPPLY %s %s THE DEMAND: %.1f %s AVAILABLE AT %.1f %s, %.1f NEEDED'
                 % (d['supply'], 'MEETS' if d['meets'] is TRUE else 'DOES NOT MEET',
                    d['available'], u['pressure'].upper(),
                    d['flow'], u['flow'].upper(), d['pressure']))
    nw = len(j['warnings'])
    nv = sum(1 for p in pipes if abs(p['velocity']) > (net['opts'].get('vel_limit') if net['opts'].get('vel_limit') is not None else 6))
    if nv:
        s.append('%d PIPE%s OVER THE VELOCITY LIMIT' % (nv, '' if nv == 1 else 'S'))
    if nw:
        s.append('%d WARNING%s - SEE THE REPORT' % (nw, '' if nw == 1 else 'S'))
    j['summary'] = s
    return j

#------------------------------------------------------------------------------
# check_valves_json -- every water supply's check valve (NRV).
#------------------------------------------------------------------------------
def check_valves_json(net):
    uf, up = net['f_flow'], net['f_pres']
    out = []
    for s in demand.supplies(net):
        v = _supplies.valve_of(s)
        q = 0 if s.get('closed') else s['q']
        out.append({
            'supply': s['id'], 'node': net['nodes'][s['n2']]['id'],
            'installed': TRUE if v else FALSE,
            'state': _supplies.state_of(s) if v else 'NONE',
            'flow': r4(q / uf),
            'pressure': r4(demand.gauge(net, s['n2']) / up),
            'supply_pressure': r4(demand.avail_of(s, q if q > 0 else 0) / up),
            'loss': (r4(v['loss'] / up) if (v and not s.get('closed')) else None),
            'cv': (_numify(v['cv']) if v else None),
            'loss_basis': v.get('basis') if v else None,
            'loss_curve_max_flow': (r4(v['curve']['qhi'] / uf) if (v and v.get('curve')) else None),
            'opening_pressure': (r4(v['crack'] / up) if v else None),
            'opening_pressure_given': (TRUE if v and v.get('crack_given') else (FALSE if v else None)),
            'model': v.get('model') if v else None,
            'switches': (_numify(v['switches']) if v else None),
        })
    return out

#------------------------------------------------------------------------------
# supplies_json -- the multiple-supply schedule, in the model's units.
#------------------------------------------------------------------------------
def supplies_json(net, s):
    uf, up = net['f_flow'], net['f_pres']
    Q = lambda v: (r4(v / uf) if v is not None else None)
    P = lambda v: (r4(v / up) if v is not None else None)
    j = {
        'operating': [{'id': r['id'], 'node': r['node'], 'elevation': r4(r['z']),
                       'type': r['kind'], 'flow': Q(r['flow']), 'pressure': P(r['pressure']),
                       'supply_pressure': P(r['supply_pressure']),
                       'share_percent': r4(r['share']), 'status': r['status'],
                       'extrapolated': TRUE if r['extrapolated'] else FALSE}
                      for r in s['operating']],
        'supply_sum': Q(s['supply_sum']), 'net_demand': Q(s['net_demand']),
        'balance': 0 + float('%.6e' % (s['balance'] / uf)),
        'governing': s.get('governing'),
    }
    if s.get('conditional'):
        j['conditional'] = [{'id': c['id'], 'status': c['status'], 'reason': c.get('reason'),
                             'basis': 'the other supplies as modelled',
                             'required_flow': Q(c.get('flow')),
                             'required_pressure': P(c.get('pressure')),
                             'available_pressure': P(c.get('available')),
                             'margin': P(c.get('margin')),
                             'governing': c.get('governing'),
                             'acceptance': c.get('acceptance'),
                             'others_reverse': c.get('others_reverse')}
                            for c in s['conditional']]
    jd = s.get('joint')
    if jd:
        if jd.get('reason'):
            j['joint'] = {'reason': jd['reason']}
        else:
            j['joint'] = {'basis': jd['basis'], 'assumption': jd['assumption'],
                          ('derating' if jd['basis'] == 'DERATE' else 'factor'):
                              (P(jd['delta']) if jd['basis'] == 'DERATE' else r4(jd['factor'])),
                          'margin': P(jd['margin']), 'governing': jd.get('governing'),
                          'acceptance': jd.get('acceptance'),
                          'total_flow': Q(jd['q_total']),
                          'supplies': [{'id': r['id'], 'flow': Q(r['flow']),
                                        'pressure': P(r['pressure']),
                                        'available_pressure': P(r['available']),
                                        'margin': P(r['margin']),
                                        'share_percent': r4(r['share']),
                                        'status': r['status']} for r in jd['supplies']]}
    if s.get('scenarios'):
        j['scenarios'] = [{'name': sc['name'], 'description': sc['description'],
                           'required': TRUE if sc.get('required') else FALSE,
                           'line': sc.get('line'),
                           'definition': {k: _numify(v) for k, v in sc['shares'].items()},
                           'acceptance': sc.get('acceptance'),
                           'governing': sc.get('governing'), 'margin': P(sc.get('margin')),
                           'findings': sc.get('findings') or [], 'error': sc.get('error'),
                           'supplies': [{'id': r['id'], 'percent': _numify(r['percent']),
                                         'flow': Q(r['flow']), 'pressure': P(r['pressure']),
                                         'status': r['status']} for r in sc['supplies']]}
                          for sc in s['scenarios']]
    return j

#------------------------------------------------------------------------------
# dpv_json -- each dry pipe valve.
#------------------------------------------------------------------------------
def dpv_json(net, va, dry):
    uf, up = net['f_flow'], net['f_pres']
    dry = dry or []
    drymap = {d['id']: d for d in dry}
    r1 = lambda v: (None if v is None else 0 + float('%.1f' % v))
    out = []
    for e in [x for x in net['elems'][1:] if x['kind'] == 'DPV']:
        d = drymap.get(e['id'])
        if not d:
            est = None
        elif d.get('error'):
            est = {'error': d['error']}
        else:
            tr = d['trip']
            tt = d['transit']
            est = {
                'basis': 'ESTIMATE - not a water delivery time calculation by a listed method; accelerator not modelled',
                'verified': FALSE,
                'decides_acceptance': FALSE,
                'limitations': [
                    'trip: isothermal choked blow-down of the dry volume through the open orifices, Cd 1',
                    'transit: the water front at the steady-state velocities, the air ahead of it ignored - a lower bound',
                    'accelerators, valve opening time and trapped air are not modelled'],
                'dry_volume_m3': r4(d['volume']),
                'trip': {'status': tr.get('status'), 'reason': tr.get('reason'),
                         'seconds': r1(tr.get('seconds')),
                         'formula': 't = 0.0352 V/(An sqrt T0) ln(pa0/pa), FM Global, SFPE Handbook',
                         'trip_pressure': (r4(tr['trip_gauge'] / up) if tr.get('trip_gauge') is not None else None),
                         'static_water': (r4(tr['static'] / up) if tr.get('static') is not None else None),
                         'orifice_mm': r4(tr.get('orifice_mm')), 'open': tr.get('open_count'),
                         'air_temperature_c': r4(tr.get('air_temp_c')),
                         'choked': (None if tr.get('choked') is None else (TRUE if tr['choked'] else FALSE))},
                'transit': {'status': tt.get('status'), 'reason': tt.get('reason'),
                            'seconds': r1(tt.get('seconds')),
                            'path_seconds': r1(tt.get('path_seconds')),
                            'fill_seconds': r1(tt.get('fill_seconds')),
                            'remote_outlet': tt.get('remote'),
                            'path': tt.get('path_pipes'),
                            'path_length': r4(tt.get('path_length')),
                            'flows': tt.get('basis')},
                'delivery_seconds': r1(d.get('delivery')),
            }
        hf = elem_hf(e, e['q'], net['opts'])[0]
        err = [f['code'] for f in va['findings']
               if (f.get('item') or '') == e['id'] and f['severity'] == 'error']
        db = e.get('db')
        out.append({
            'id': e['id'], 'pipe': e.get('host_id'),
            'from': net['nodes'][e['n1']]['id'], 'to': net['nodes'][e['n2']]['id'],
            'nominal_size': e.get('size'), 'model': e.get('model'),
            'trip_method': e.get('trip_mode'), 'trip_ratio': r4(e.get('trip_ratio')),
            'trip_pressure': (r4(e['trip_pressure'] / up) if e.get('trip_pressure') is not None else None),
            'accelerator': e.get('accelerator'),
            'loss_basis': e.get('loss'), 'equivalent_length': r4(e.get('eql')),
            'loss_source': e.get('loss_source'), 'data_status': e.get('data_status'),
            'database_valve': ({'maker': db['maker'], 'model': db['model'], 'dn': _numify(db['dn']),
                                'reference_bore': r4(e.get('ref_bore')),
                                'reference_c': (None if e.get('ref_c') is None else _numify(e['ref_c'])),
                                'cv': (None if e.get('cv') is None else _numify(e['cv'])),
                                'published_trip': db.get('trip'),
                                'rated_pressure': db.get('pmax'),
                                'status': db.get('status'), 'source': db.get('source')}
                               if db else None),
            'flow': r4(e['q'] / uf), 'loss': r4(hf / up),
            'state': 'TRIPPED_OPEN',
            'initial_air_pressure': (r4(e['transient']['air_initial'] / up)
                                    if e.get('transient', {}).get('air_initial') is not None else None),
            'delivery_time': None, 'delivery_time_calculated': FALSE, 'estimate': est,
            'validation': 'FAIL' if err else 'PASS', 'findings': err,
        })
    return out

#------------------------------------------------------------------------------
# traceability -- what produced these results.
#------------------------------------------------------------------------------
def traceability(net, va):
    text = net.get('source_text')
    assume = []
    el = net['elems'][1:]
    if any(e['kind'] == 'DPV' for e in el):
        assume.append('every dry pipe valve tripped and fully open (steady state); no delivery time calculated')
    if len(demand.supplies(net)) > 1:
        assume.append('joint demand of the supplies on the %s basis'
                      % ('uniform pressure derating'
                         if (net['opts'].get('joint_basis') or 'DERATE') == 'DERATE'
                         else 'uniform pressure scaling'))
    if any(e['kind'] == 'RATIO' for e in el):
        assume.append('pressure ratio valves at the bottom of their band')
    if net['opts'].get('vel_press'):
        assume.append('velocity pressure included at in-line sprinklers (AS 2118.1 Cl 14.15)')
    if any(f['code'] == 'CURVE_EXTRAPOLATED' for f in va['findings']):
        assume.append('supply, pump and loss curves extrapolated linearly beyond their last point')
    from . import results as _results
    return {
        'program': 'PHCP %s' % VERSION, 'version': VERSION,
        'model_sha256': (_results.fingerprint(text) if text is not None else None),
        'database': ({'name': pipedata.dataset(), 'sha256': pipedata.sha256()}
                     if pipedata.path() else None),
        'method': 'Darcy-Weisbach' if va['solver']['method'] == 'DW' else 'Hazen-Williams',
        'algorithm': va['solver']['algorithm'],
        'tolerances': {'flow': va['solver']['tol_flow'], 'loop': va['solver']['tol_loop'],
                       'maxiter': va['solver']['maxiter']},
        'assumptions': assume,
        'scenarios': [{'name': sc['name'], 'line': sc.get('line'),
                        'shares': {a: _numify(b) for a, b in sc['shares']}}
                       for sc in (net.get('scenarios') or [])],
    }

#------------------------------------------------------------------------------
# assumptions -- the settings and assumptions the result rests on, as data.
#------------------------------------------------------------------------------
def assumptions(net):
    o = net['opts']
    multi = len(demand.supplies(net)) > 1
    return {
        'friction_method': ('DARCY-WEISBACH' if (o.get('method') or 'HW') == 'DW'
                            else 'HAZEN-WILLIAMS'),
        'hw_constant': (None if (o.get('method') or 'HW') == 'DW' else 0 + o['hwk']),
        'fitting_basis': o.get('fitting_basis') or 'CORRECTED',
        'velocity_pressure': TRUE if o.get('vel_press') else FALSE,
        'joint_basis': ((o.get('joint_basis') or 'DERATE') if multi else None),
        'joint_basis_is_assumption': (TRUE if multi else None),
        'supply_margin': r4((o.get('supply_margin') or 0) / net['f_pres']),
        'orifice_duty_tolerance_percent': 0 + (o.get('orif_dp_tol') if o.get('orif_dp_tol') is not None else ORIF_DP_TOL),
        'curve_extrapolation_limit': 0 + EXTRAP_MAX,
        'solver_tolerances': {'flow': r4(o['tol_flow'] / net['f_flow']),
                              'loop': r4(o['tol_loop'] / net['f_pres'])},
        'dry_pipe_valves': ('tripped and fully open (steady state)'
                           if any(e['kind'] == 'DPV' for e in net['elems'][1:]) else None),
    }

#------------------------------------------------------------------------------
# error_result -- the JSON object when the model could not be read or solved.
#------------------------------------------------------------------------------
def error_result(e, model):
    msg = e.msg if is_model_error(e) else str(e)
    msg = msg.rstrip()
    line = None
    m = re.match(r'^line (\d+): ', msg, re.I)
    if m:
        line = 0 + int(m.group(1))
        msg = msg[m.end():]
    return {'interface': INTERFACE, 'program': 'PHCP %s' % VERSION, 'model': model,
            'status': 'error', 'acceptance': 'ERROR', 'converged': FALSE,
            'errors': [{'line': line, 'message': msg.upper()}],
            'summary': ['NOT SOLVED: %s%s' % (msg.upper(),
                                              (' (LINE %d)' % line) if line is not None else '')]}

#------------------------------------------------------------------------------
# The encoder: JSON::PP's canonical-pretty-ascii output, byte for byte.
#------------------------------------------------------------------------------
class _Bool:
    __slots__ = ('v',)
    def __init__(self, v):
        self.v = v
    # JSON::PP::true and ::false overload bool: a caller testing a result's
    # 'pass' (if (!$o->{pass})) sees the truth value, not a defined object.
    def __bool__(self):
        return bool(self.v)

    # JSON::PP::true and ::false are overloaded to be true and false in a
    # boolean test, so a caller reading results() sees false as false.
    def __bool__(self):
        return bool(self.v)

TRUE = _Bool(True)
FALSE = _Bool(False)

_ESC = {'"': '\\"', '\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t',
        '\b': '\\b', '\f': '\\f'}

def _str(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch in _ESC:
            out.append(_ESC[ch])
        elif o < 0x20 or o >= 0x7f:
            if o > 0xffff:
                # surrogate pair, as \uXXXX\uXXXX
                o -= 0x10000
                out.append('\\u%04x\\u%04x' % (0xd800 + (o >> 10), 0xdc00 + (o & 0x3ff)))
            else:
                out.append('\\u%04x' % o)
        else:
            out.append(ch)
    return '"' + ''.join(out) + '"'

def _num(x):
    # Perl's number stringification: %.15g.
    if isinstance(x, bool):
        return 'true' if x else 'false'
    if isinstance(x, int):
        return str(x)
    return '%.15g' % x

def _enc(v, ind):
    pad = '   ' * ind
    if v is None:
        return 'null'
    if isinstance(v, _Bool):
        return 'true' if v.v else 'false'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return _num(v)
    if isinstance(v, str):
        return _str(v)
    if isinstance(v, dict):
        if not v:
            return '{}'
        ks = sorted(v.keys())
        items = ['%s%s : %s' % (pad + '   ', _str(k), _enc(v[k], ind + 1)) for k in ks]
        return '{\n' + ',\n'.join(items) + '\n' + pad + '}'
    if isinstance(v, (list, tuple)):
        if not v:
            return '[]'
        items = ['%s%s' % (pad + '   ', _enc(x, ind + 1)) for x in v]
        return '[\n' + ',\n'.join(items) + '\n' + pad + ']'
    raise TypeError('cannot encode %r' % (v,))

def encode(obj):
    return _enc(obj, 0) + '\n'
