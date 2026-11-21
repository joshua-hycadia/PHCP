#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# drytime.py -- Python port of HardyCross/DryTime.pm.
#
# The estimated trip and transit times of a dry pipe valve: the air-side
# trip time from the published trip formula, and the water transit along
# the flow path, on a solved network.  Estimates decide nothing.  See
# DryTime.pm for the rationale.
#

import math

from . import GAMMA_W, pipe_velocity, curve_eval

C_TRIP = 0.0352           # the published constant (US units)
P_ATM  = 101.325          # kPa, standard atmosphere
CHOKE  = 1.893            # critical pressure ratio of air, gamma 1.4
FT3 = 0.028316846592      # m3 in a ft3
FT2 = 0.09290304          # m2 in a ft2
PSI = 6.894757            # kPa in a psi
PI  = 3.14159265358979

#------------------------------------------------------------------------------
# trip_time -- the formula itself, in its own units.
#------------------------------------------------------------------------------
def trip_time(v_ft3, an_ft2, t_r, pa0, pa):
    return C_TRIP * v_ft3 / (an_ft2 * math.sqrt(t_r)) * math.log(pa0 / pa)

#------------------------------------------------------------------------------
# dry_part -- the pipework downstream of a dry pipe valve.
#------------------------------------------------------------------------------
def dry_part(net, dpv):
    el = [e for e in net['elems'][1:] if not e.get('closed')]
    adj = {}
    supply_node = {}
    for e in el:
        if e is dpv:
            continue
        if e['kind'].startswith('SUPPLY_'):
            supply_node[e['n2']] = e['id']
            continue
        if e['kind'] == 'DISCHARGE':
            continue
        adj.setdefault(e['n1'], []).append((e['n2'], e))
        adj.setdefault(e['n2'], []).append((e['n1'], e))
    seen = {dpv['n2']: 1}
    q = [dpv['n2']]
    pipe = {}
    while q:
        v = q.pop(0)
        # Perl truth of the supply's id: a supply named 0 is not seen here.
        if supply_node.get(v) not in (None, '', '0'):
            return {'error': 'the pipework downstream of the valve reaches water supply %s: it is not a '
                             'dry system' % supply_node[v]}
        if v == dpv['n1']:
            return {'error': 'the pipework downstream of the valve leads back to its inlet: it is not a '
                             'dry system'}
        for w, e in adj.get(v, []):
            if e['kind'] == 'PIPE':
                pipe[e['id']] = e
            if w not in seen:
                seen[w] = 1
                q.append(w)
    vol = 0
    for e in pipe.values():
        vol += PI / 4 * (e['dia'] / 1000) ** 2 * e['len']
    outlets = [e for e in el if e['kind'] == 'DISCHARGE' and e['n1'] in seen]
    return {'pipes': list(pipe.values()), 'outlets': outlets, 'volume': vol, 'nodes': seen}

#------------------------------------------------------------------------------
# path_time -- (seconds, [pipe ids], metres) along the flow path from the
# valve's outlet to an outlet.
#------------------------------------------------------------------------------
def path_time(net, dpv, outlet):
    el = [e for e in net['elems'][1:]
          if not e.get('closed') and e['kind'] != 'DISCHARGE']
    t, ln = 0, 0
    ids = []
    v = outlet['n1']
    seen = {v: 1}
    for _ in range(len(net['nodes'])):
        if v == dpv['n2']:
            return (t, list(reversed(ids)), ln)
        best = None
        bq = None
        for e in el:
            if e['kind'].startswith('SUPPLY_'):
                continue
            if e['n2'] == v and e['q'] > 1e-9:
                in_ = e['q']
            elif e['n1'] == v and e['q'] < -1e-9:
                in_ = -e['q']
            else:
                in_ = 0
            if in_ > 0 and (bq is None or in_ > bq):
                best, bq = e, in_
        if not best:
            return None
        if best['kind'] == 'PIPE':
            vel = abs(pipe_velocity(bq, best['dia']))
            if not vel > 0:
                return None
            t += best['len'] / vel
            ln += best['len']
            ids.append(best['id'])
        frm = best['n1'] if best['n2'] == v else best['n2']
        if frm in seen:
            return None
        seen[frm] = 1
        v = frm
    return None

#------------------------------------------------------------------------------
# static_at -- the static water pressure at a node, kPa gauge, with no water
# flowing: the highest of the supplies' no-flow pressures, each corrected
# for its elevation above the node.  Pumps are not included.
#------------------------------------------------------------------------------
def static_at(net, i):
    z = net['nodes'][i].get('z')
    z = 0 if z is None else z
    best = None
    for s in [e for e in net['elems'][1:]
              if e['kind'].startswith('SUPPLY_') and not e.get('closed')]:
        p0 = s['pstat'] if s['kind'] == 'SUPPLY_STATIC' else curve_eval(s['curve'], 0)
        sz = s.get('z')
        sz = 0 if sz is None else sz
        p = p0 + GAMMA_W * (sz - z)
        if best is None or p > best:
            best = p
    return best

#------------------------------------------------------------------------------
# analyse -- the estimates for every dry pipe valve of a solved network.
#------------------------------------------------------------------------------
def analyse(net, flows, basis):
    if flows is None:
        flows = net
    if basis is None:
        basis = 'operating point'
    out = []
    for e in [x for x in net['elems'][1:] if x['kind'] == 'DPV']:
        tr = e.get('transient') or {}
        r = {'id': e['id']}
        out.append(r)
        dry = dry_part(net, e)
        if dry.get('error'):
            r['error'] = dry['error']
            continue
        r['volume'] = dry['volume']
        r['pipes'] = len(dry['pipes'])

        #---------------------------------------------------------- trip
        t = r['trip'] = {}
        need = []
        if tr.get('air_initial') is None:
            need.append('the set air pressure (DPVAIR)')
        if not tr.get('orifice_mm'):
            need.append('the open sprinkler orifice (DPVTRIP)')
        if need:
            t['status'] = 'NOT_CALCULATED'
            t['reason'] = 'needs ' + ' and '.join(need)
        else:
            static = tr.get('static_water')
            static = static_at(net, e['n1']) if static is None else static
            t['static'] = static
            t['static_given'] = 1 if tr.get('static_water') is not None else 0
            if (e.get('trip_mode') or '') == 'TRIP':
                ptrip = e.get('trip_pressure')
            elif (e.get('trip_ratio') is not None and e['trip_ratio'] > 0
                  and static is not None):
                ptrip = static / e['trip_ratio']
            else:
                ptrip = None
            n = tr.get('open_count')
            n = 1 if n is None else n
            an = n * PI / 4 * (tr['orifice_mm'] / 1000) ** 2
            tk = (tr.get('air_temp_c') if tr.get('air_temp_c') is not None else 20) + 273.15
            t['trip_gauge'] = ptrip
            t['air_gauge'] = tr['air_initial']
            t['open_count'] = n
            t['orifice_mm'] = tr['orifice_mm']
            t['area'] = an
            t['air_temp_c'] = tk - 273.15
            if ptrip is None:
                t['status'] = 'NOT_CALCULATED'
                t['reason'] = ('no trip pressure: no supply to take the static water pressure from')
            elif tr['air_initial'] <= ptrip:
                t['status'] = 'ERROR'
                t['reason'] = ('the set air pressure, %.1f kPa, is not above the trip pressure, %.1f kPa: '
                               'the valve would not stay set' % (tr['air_initial'], ptrip))
            else:
                pa0 = (tr['air_initial'] + P_ATM) / PSI
                pa = (ptrip + P_ATM) / PSI
                t['seconds'] = trip_time(dry['volume'] / FT3, an / FT2, tk * 1.8, pa0, pa)
                t['status'] = 'ESTIMATE'
                t['choked'] = 1 if (ptrip + P_ATM) / P_ATM >= CHOKE else 0
                t['accelerator_ignored'] = 1 if (e.get('accelerator') or '') == 'ON' else 0

        #------------------------------------------------------- transit
        x = r['transit'] = {'basis': basis}
        fdpv = next((y for y in flows['elems'][1:] if y['id'] == e['id']), None)
        if fdpv:
            fdry = dry_part(flows, fdpv)
        else:
            fdry = {'error': 'the valve is not in the network of that solve'}
        if fdry.get('error') or not fdry['outlets']:
            x['status'] = 'NOT_CALCULATED'
            x['reason'] = fdry.get('error') or 'no outlet downstream of the valve'
        else:
            from . import demand
            # The most remote outlet: the one with least pressure to spare.
            remote = sorted(fdry['outlets'],
                            key=lambda a: demand.outlet_margin(flows, a))[0]
            res = path_time(flows, fdpv, remote)
            qv = fdpv['q']
            x['remote'] = remote['id']
            x['flow'] = qv
            if res is not None:
                x['path_seconds'], x['path_pipes'], x['path_length'] = res
            x['fill_seconds'] = fdry['volume'] / (qv / 60000) if qv > 1e-9 else None
            c = [v for v in (x.get('path_seconds'), x.get('fill_seconds')) if v is not None]
            if c:
                x['seconds'] = sorted(c, reverse=True)[0]
                x['status'] = 'ESTIMATE'
            else:
                x['status'] = 'NOT_CALCULATED'
                x['reason'] = 'no flow through the valve'
        if t.get('seconds') is not None and x.get('seconds') is not None:
            r['delivery'] = t['seconds'] + x['seconds']
    return out
