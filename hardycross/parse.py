#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# parse.py -- Python port of HardyCross/Parse.pm, the network builder.
#
# HardyCross.phc turns each .phc line into a row -- a section word (UNITS,
# OPTIONS, NODES, PIPES, PUMPS, SUPPLIES, DISCHARGES, DEVICES) and its
# tokens -- and parse_row below adds that row to the network.  All numeric
# values are in the units set by the UNITS rows, which come first; everything
# is converted to internal units (L/min, kPa, m, mm) on the way in.
#

import math
import re

from . import (GAMMA_W, Q_TINY, D_TINY, HWK_DEF, fail, set_unit,
               fit_curve, ModelError)
from . import pipedata

# The database is loaded once, on first use, from data/pipes.dat.  A model
# that never names a pipe type never touches it.
_db_loaded = False

def ensure_db():
    global _db_loaded
    if _db_loaded:
        return
    pipedata.load()
    _db_loaded = True

# INTENDED as AS 1074 medium, but NOT transcribed from a controlled copy of
# the standard -- the same caveat every other implementation carries.
PIPE_ID = {15: 16.1, 20: 21.7, 25: 27.3, 32: 36.0, 40: 41.9,
           50: 53.1, 65: 68.9, 80: 80.9, 100: 105.3,
           150: 155.1, 200: 207.3}

# The roughness a pipe takes, in mm, when the model gives none and the
# database publishes none for its type: commercial steel, new.
EPS_DEFAULT = 0.045

HW_CONST_BAND = 0.02
HW_C_RANGE = (40, 200)
NU_RANGE = (0.28e-6, 1.8e-6)


def roughness_defaulted(net):
    if (net['opts'].get('method') or 'HW') != 'DW':
        return []
    return [e['id'] for e in net['elems'][1:]
            if e['kind'] == 'PIPE' and (e.get('eps_src') or '') == 'DEFAULT']

def roughness_warning(net):
    ids = roughness_defaulted(net)
    if not ids:
        return []
    shown = ids[:12] + ['and %d more' % (len(ids) - 12)] if len(ids) > 12 else ids
    return [('roughness ASSUMED: %d pipe(s) take 0.045 mm, the program default, because no roughness '
             'is given for them in the model or in the database: %s.  Give it on the USE line (USE BORE <mm>, '
             'USE <type> <mm>), or for the pipe type in the database.'
             % (len(ids), ', '.join(shown)))]

_FIT_RE = re.compile(r'(FIT=\S*)')

def tokenize(line):
    # Strip the line ending FIRST (see Parse.pm), then comments, then make
    # control bytes and non-printable ASCII separators, protecting the commas
    # inside a FIT= value.
    line = re.sub(r'\r?\n$', '', line)
    line = re.sub(r'[!#].*$', '', line)
    line = re.sub(r'[^\x20-\x7E]+', ' ', line)
    line = _FIT_RE.sub(lambda m: m.group(1).replace(',', '+'), line)
    return [t for t in re.split(r'[ \t,;]+', line) if t]

_NUM_RE = re.compile(r'^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$')
_NAN_RE = re.compile(r'^[-+]?(nan|inf)', re.I)

def is_num(t):
    if t is None:
        return 0
    if _NAN_RE.match(t):
        return 0
    if not _NUM_RE.match(t):
        return 0
    # 1E999 overflows to infinity, which is as non-finite as "inf" itself.
    try:
        v = float(t)
    except ValueError:
        return 0
    return 0 if math.isinf(abs(v)) else 1

def num(t):
    t = 0 if t is None else t
    return float(t) if is_num(t) else 0

def kv(tk, key):
    for t in tk:
        if '=' not in t:
            continue
        k, v = t.split('=', 1)
        if k.upper() == key.upper():
            return num(v)
    return None

def kv_text(tk, key):
    for t in tk:
        if '=' not in t:
            continue
        k, v = t.split('=', 1)
        if k.upper() == key.upper():
            return v
    return None

def node_index(net, id):
    for i in range(1, len(net['nodes'])):
        if net['nodes'][i]['id'] == id:
            return i
    net['nodes'].append({'id': id, 'z': 0, 'demand': 0, 'h': 0,
                         'pelem': 0, 'pnode': 0, 'depth': 0, 'visited': 0})
    return len(net['nodes']) - 1

def read_curve(net, tk, frm, rising):
    v = [num(t) for t in tk[frm:] if '=' not in t]
    if len(v) < 4 or len(v) % 2:
        fail('curve needs at least two flow/pressure pairs')
    c = {'q': [], 'p': []}
    while len(v) >= 2:
        c['q'].append(v.pop(0) * net['f_flow'])
        c['p'].append(v.pop(0) * net['f_pres'])
    return fit_curve(c, rising)

def read_model(path):
    # A .phc command file is the one file type PHCP reads: any other file
    # (an old .hcx above all) is refused here, with the reason, before the
    # .phc reader sees it -- as Parse.pm's read_model does.  phc.read_model
    # does the work.
    if not re.search(r'\.phc\Z', path, re.I):
        fail('%s IS NOT A .PHC MODEL. PHCP READS .PHC FILES ONLY', path)
    from . import phc
    return phc.read_model(path)

def new_net():
    return {
        'nodes': [None, {'id': 'REF', 'z': 0, 'demand': 0, 'h': 0,
                         'pelem': 0, 'pnode': 0, 'depth': 0, 'visited': 0}],
        'elems': [None],
        'loops': [], 'iref': 1,
        'f_flow': 1, 'f_pres': 1, 'f_len': 1, 'f_dia': 1,
        'u_flow': 'LPM', 'u_pres': 'KPA', 'u_len': 'M', 'u_dia': 'MM',
        'opts': {'method': 'HW', 'hwk': HWK_DEF,
                 'hwq': 1.85, 'hwd': 4.87, 'nu': 1.004e-6,
                 'maxiter': 50000, 'tol_flow': 0.05, 'tol_loop': 0.01,
                 'orif_step': 0.5,
                 'vel_limit': 6.0, 'vel_limit_set': 0},
    }


def parse_row(net, section, tk):
    #--------------------------------------------------------------- UNITS
    if section == 'UNITS':
        set_unit(net, tk[0].upper(), (tk[1] if len(tk) > 1 else '').upper())
        return
    #------------------------------------------------------------- OPTIONS
    if section == 'OPTIONS':
        k = tk[0].upper()
        v = tk[1] if len(tk) > 1 else ''
        o = net['opts']
        if k == 'METHOD':
            v2 = v.upper()
            if v2 in ('HW', 'HAZEN', 'HAZEN-WILLIAMS'):
                o['method'] = 'HW'
            elif v2 in ('DW', 'DARCY', 'DARCY-WEISBACH'):
                o['method'] = 'DW'
            else:
                fail('METHOD must be HW or DW, not %s', v)
        elif k == 'HW_CONST':
            c = num(v)
            if not (c > 0 and abs(c / HWK_DEF - 1) <= HW_CONST_BAND):
                fail('HW_CONST %s is not the Hazen-Williams constant PHCP works in (6.05E7, for P in kPa/m, '
                     'Q in L/min and d in mm; its published forms lie within 2 %% of it).  A constant for '
                     'other units, such as 6.05E5 (bar/m) or 4.52 (US units), would change every friction loss', v)
            o['hwk'] = c
        elif k == 'SUPPLY_MARGIN':
            o['supply_margin'] = num(v) * net['f_pres']
            if o['supply_margin'] < 0:
                fail('SUPPLY_MARGIN cannot be negative')
        elif k == 'SUPPLY_SCENARIOS':
            v2 = v.upper()
            if v2 not in ('ON', 'OFF'):
                fail('SUPPLY_SCENARIOS must be ON or OFF')
            o['supply_scenarios'] = 1 if v2 == 'ON' else 0
        elif k == 'JOINT_BASIS':
            v2 = v.upper()
            if v2 not in ('DERATE', 'SCALE'):
                fail('JOINT_BASIS must be DERATE or SCALE')
            o['joint_basis'] = v2
        elif k == 'HOSE_ALLOWANCE':
            o['hose'] = num(v) * net['f_flow']
            if o['hose'] < 0:
                fail('HOSE_ALLOWANCE cannot be negative')
        elif k == 'PUMPDUTY':
            o.setdefault('pump_duty', {})[v] = [num(tk[2]) * net['f_flow'],
                                                num(tk[3]) * net['f_pres']]
        elif k == 'NU':
            o['nu'] = num(v)
            if o['nu'] <= 0:
                fail('NU must be greater than zero')
            if o['nu'] < NU_RANGE[0] or o['nu'] > NU_RANGE[1]:
                fail('NU %s m2/s is not the kinematic viscosity of water, which is %g (100 C) to %g (0 C)',
                     v, NU_RANGE[0], NU_RANGE[1])
        elif k == 'TOL_FLOW':
            o['tol_flow'] = num(v) * net['f_flow']
            if not o['tol_flow'] > 0:
                fail('TOL_FLOW must be greater than zero')
            o['tol_flow_set'] = 1
        elif k == 'TOL_LOOP':
            o['tol_loop'] = num(v) * net['f_pres']
            if not o['tol_loop'] > 0:
                fail('TOL_LOOP must be greater than zero')
            o['tol_loop_set'] = 1
        elif k == 'MAXITER':
            o['maxiter'] = int(num(v))
            if o['maxiter'] < 0:
                o['maxiter'] = 0
        elif k == 'RELAX':
            r = num(v)
            if r <= 0 or r > 2:
                fail('RELAX must be greater than 0 and at most 2')
            o['relax'] = r
        elif k == 'VEL_LIMIT':
            vl = num(v)
            if vl <= 0:
                fail('VEL_LIMIT must be greater than zero, in m/s')
            o['vel_limit'] = vl
            o['vel_limit_set'] = 1
        elif k == 'FITTING_BASIS':
            v2 = v.upper()
            if v2 not in ('CORRECTED', 'STANDARD'):
                fail('FITTING_BASIS must be CORRECTED or STANDARD')
            o['fitting_basis'] = v2
        elif k == 'ORIF_STEP':
            o['orif_step'] = num(v) * net['f_dia']
            if not o['orif_step'] > 0:
                fail('ORIF_STEP must be greater than zero')
        elif k == 'ORIF_DP_TOL':
            o['orif_dp_tol'] = num(v)
            if not o['orif_dp_tol'] > 0:
                fail('ORIF_DP_TOL must be greater than zero, a percentage')
            o['orif_dp_tol_set'] = 1
        elif k == 'VELOCITY_PRESSURE':
            v2 = v.upper()
            if v2 not in ('ON', 'OFF'):
                fail('VELOCITY_PRESSURE must be ON or OFF')
            o['vel_press'] = 1 if v2 == 'ON' else 0
        return
    #--------------------------------------------------------------- NODES
    if section == 'NODES':
        i = node_index(net, tk[0])
        if len(tk) > 1:
            net['nodes'][i]['z'] = num(tk[1]) * net['f_len']
        return
    #--------------------------------------------------------------- PIPES
    if section == 'PIPES':
        if len(tk) < 5:
            fail('PIPE needs: id n1 n2 length diameter')

        ptype = None
        for t in tk:
            m = re.match(r'^TYPE=(.*)$', t, re.I)
            if m:
                ptype = m.group(1).upper()
                break
        fitspec = None
        for t in tk:
            m = re.match(r'^FIT=(.*)$', t, re.I)
            if m:
                fitspec = m.group(1)
                break
        if ptype is not None:
            ensure_db()
            info = pipedata.pipe_type(ptype)
            if info is None:
                fail('pipe %s: unknown pipe type %s (the pipe database lists %s)',
                     tk[0], ptype, ', '.join(pipedata.pipe_types()))
            dn = int(num(tk[4]) + 0.5)
            b = pipedata.bore(ptype, dn)
            if b is None:
                fail('pipe %s: DATA_REQUIRED - DN%d is not in the database '
                     'for %s; the bore is not guessed', tk[0], dn, ptype)
            bore = float(b)
            c = kv(tk, 'C')
            if c is None and len(tk) > 5 and '=' not in tk[5]:
                c = num(tk[5])
            c_given = c is not None
            if c is None:
                c = float(info['c'])
            else:
                c = float(c)

            eqv = (kv(tk, 'EQV') or 0) * net['f_len']
            res = None
            if fitspec is not None and re.search(r'\S', fitspec):
                res = pipedata.resolve(type=ptype, dn=dn, c=c, spec=fitspec,
                                       standard_only=(net['opts'].get('fitting_basis') or '') == 'STANDARD')
                if res['errors']:
                    fail('pipe %s: %s', tk[0], '; '.join(res['errors']))
                eqv += res['total']
            eps = kv(tk, 'EPS')
            eps_src = ('GIVEN' if eps is not None else
                       'DATABASE' if info.get('eps') is not None else 'DEFAULT')
            if eps is not None:
                eps = eps * net['f_dia']
            else:
                eps = float(info['eps']) if info.get('eps') is not None else EPS_DEFAULT
            e = {
                'id': tk[0], 'kind': 'PIPE',
                'n1': node_index(net, tk[1]), 'n2': node_index(net, tk[2]),
                'len': num(tk[3]) * net['f_len'],
                'dia': bore, 'c': c, 'eqv': eqv,
                'eps': eps, 'eps_src': eps_src,
                'kfit': kv(tk, 'K') if kv(tk, 'K') is not None else 0,
                'q': 0, 'in_tree': 0,
                'ptype': ptype, 'dn': dn, 'c_given': c_given,
                'fitspec': fitspec, 'fitres': res,
            }
            if e['len'] < 0:
                fail('pipe %s has a negative length', e['id'])
            net['elems'].append(e)
            return
        if fitspec is not None and re.search(r'\S', fitspec):
            fail('pipe %s: a fitting string needs TYPE= so its table and '
                 'basis bore are known', tk[0])
        c = kv(tk, 'C')
        if c is None:
            c = num(tk[5]) if (len(tk) > 5 and '=' not in tk[5]) else 120
        e = {
            'id': tk[0], 'kind': 'PIPE',
            'n1': node_index(net, tk[1]), 'n2': node_index(net, tk[2]),
            'len': num(tk[3]) * net['f_len'],
            'dia': num(tk[4]) * net['f_dia'],
            'c': c,
            'eqv': (kv(tk, 'EQV') or 0) * net['f_len'],
            'eps': kv(tk, 'EPS') * net['f_dia'] if kv(tk, 'EPS') is not None else EPS_DEFAULT,
            'eps_src': 'GIVEN' if kv(tk, 'EPS') is not None else 'DEFAULT',
            'kfit': kv(tk, 'K') if kv(tk, 'K') is not None else 0,
            'q': 0, 'in_tree': 0,
        }
        if e['dia'] <= 0:
            fail('pipe %s has a non-positive diameter', e['id'])
        if e['len'] < 0:
            fail('pipe %s has a negative length', e['id'])
        if e['c'] <= 0:
            fail('pipe %s has a non-positive C factor', e['id'])
        if e['c'] < HW_C_RANGE[0] or e['c'] > HW_C_RANGE[1]:
            fail('pipe %s: a C factor of %g is outside %g to %g, the range of the Hazen-Williams C of any pipe',
                 e['id'], e['c'], HW_C_RANGE[0], HW_C_RANGE[1])
        net['elems'].append(e)
        return
    #--------------------------------------------------------------- PUMPS
    if section == 'PUMPS':
        net['elems'].append({
            'id': tk[0], 'kind': 'PUMP',
            'n1': node_index(net, tk[1]), 'n2': node_index(net, tk[2]),
            'curve': read_curve(net, tk, 3, 0), 'q': 0, 'in_tree': 0,
        })
        return
    #------------------------------------------------------------ SUPPLIES
    if section == 'SUPPLIES':
        n = node_index(net, tk[1])
        zk = kv(tk, 'Z')
        z = zk * net['f_len'] if zk is not None else net['nodes'][n]['z']
        if tk[2].upper() == 'STATIC':
            net['elems'].append({
                'id': tk[0], 'kind': 'SUPPLY_STATIC',
                'n1': net['iref'], 'n2': n,
                'pstat': num(tk[3]) * net['f_pres'], 'z': z,
                'q': 0, 'in_tree': 0,
            })
        else:
            net['elems'].append({
                'id': tk[0], 'kind': 'SUPPLY_CURVE',
                'n1': net['iref'], 'n2': n,
                'curve': read_curve(net, tk, 3, 0), 'z': z,
                'q': 0, 'in_tree': 0,
            })
        return
    #---------------------------------------------------------- DISCHARGES
    if section == 'DISCHARGES':
        n = node_index(net, tk[1])
        ty = tk[2].upper()
        zk = kv(tk, 'Z')
        z = zk * net['f_len'] if zk is not None else net['nodes'][n]['z']
        uf, up = net['f_flow'], net['f_pres']
        kk = kv(tk, 'K')
        if kk is not None:
            kk = kk * uf / math.sqrt(up)
        qq = kv(tk, 'Q')
        if qq is None:
            qq = kv(tk, 'MINQ')
        if qq is not None:
            qq = qq * uf
        pp = kv(tk, 'P')
        if pp is None:
            pp = kv(tk, 'MINP')
        if pp is not None:
            pp = pp * up

        if ty in ('FIXEDFLOW', 'FIXED'):
            if qq is None:
                fail('FIXEDFLOW needs Q=')
            if pp is not None and pp < 0:
                fail('FIXEDFLOW %s has a negative minimum pressure', tk[0])
            net['nodes'][n]['demand'] += qq
            net.setdefault('fixed', []).append({
                'id': tk[0], 'kind': 'FIXEDFLOW', 'n1': n,
                'qreq': qq, 'q': qq, 'preq': pp, 'z': z,
            })
            return
        given = sum(1 for x in (kk, qq, pp) if x is not None)
        if given < 2:
            fail('discharge %s needs any TWO of K, Q, P', tk[0])
        if kk is None:
            kk = qq / math.sqrt(pp) if pp > D_TINY else 0
        if qq is None:
            qq = kk * math.sqrt(pp if pp > 0 else 0)
        if pp is None:
            pp = (qq / kk) ** 2 if kk > D_TINY else 0
        if kk <= D_TINY:
            fail('discharge %s resolves to an unusable K-factor', tk[0])
        net['elems'].append({
            'id': tk[0], 'kind': 'DISCHARGE',
            'otype': ty,
            'n1': n, 'n2': net['iref'],
            'k': kk, 'qreq': qq, 'preq': pp, 'z': z,
            'q': 0, 'in_tree': 0,
        })
        return
    #------------------------------------------------------------- DEVICES
    if section == 'DEVICES':
        n1 = node_index(net, tk[1])
        n2 = node_index(net, tk[2])
        ty = tk[3].upper()
        dnk = kv(tk, 'DN')
        dn = int(dnk if dnk is not None else 0)
        pdk = kv(tk, 'PIPEDIA')
        pd = pdk * net['f_dia'] if pdk is not None else PIPE_ID.get(dn, 0)
        cd = kv(tk, 'CD')
        cd = 0.596 if cd is None else cd

        dp = (kv(tk, 'DP') or 0) * net['f_pres']
        borek = kv(tk, 'BORE')
        bore = (borek if borek is not None else 0) * net['f_dia']
        if ty == 'PRV' and dp <= 0:
            fail('PRV %s needs a positive DP=', tk[0])
        if ty == 'ORIFICE_P' and dp <= 0:
            fail('ORIFICE_P %s needs a positive DP=', tk[0])
        if ty == 'ORIFICE_D' and bore <= 0:
            fail('ORIFICE_D %s needs a positive BORE=', tk[0])
        if ty == 'ORIFICE_D' and pd > 0 and bore >= pd:
            fail('orifice %s bore is not smaller than the pipe bore', tk[0])
        if ty in ('ORIFICE_P', 'ORIFICE_D') and (cd <= 0 or cd > 1):
            fail('orifice %s CD must be more than 0 and not more than 1', tk[0])

        if ty == 'PRV':
            net['elems'].append({
                'id': tk[0], 'kind': 'FIXED_DROP', 'n1': n1, 'n2': n2,
                'dp': (kv(tk, 'DP') or 0) * net['f_pres'], 'q': 0, 'in_tree': 0,
            })
        elif ty == 'ORIFICE_P':
            if pd <= 0:
                fail('orifice %s needs DN= or PIPEDIA= for the pipe bore', tk[0])
            net['elems'].append({
                'id': tk[0], 'kind': 'ORIFICE_REQUIRED', 'n1': n1, 'n2': n2,
                'dp': (kv(tk, 'DP') or 0) * net['f_pres'],
                'dn': dn, 'pipedia': pd, 'cd': cd, 'bore': 0,
                'q': 0, 'in_tree': 0,
            })
        elif ty == 'ORIFICE_D':
            net['elems'].append({
                'id': tk[0], 'kind': 'ORIFICE', 'n1': n1, 'n2': n2,
                'bore': (kv(tk, 'BORE') or 0) * net['f_dia'],
                'pipedia': pd, 'cd': cd, 'q': 0, 'in_tree': 0,
            })
        elif ty == 'PRA':
            r = kv(tk, 'RATIO')
            r = 0 if r is None else r
            if r <= 1:
                fail('PRA %s needs RATIO= more than 1', tk[0])
            mi = kv(tk, 'MININLET')
            band = kv(tk, 'BAND')
            band = 5 if band is None else band
            if band < 0:
                fail('PRA %s: BAND= cannot be negative', tk[0])
            if band / 100 >= 1 / r:
                fail('PRA %s: a band of %g%% of the inlet pressure is more than the %g%% '
                     'a %g:1 valve passes - the bottom of the band would be no pressure at all',
                     tk[0], band, 100 / r, r)
            e = {
                'id': tk[0], 'kind': 'RATIO', 'n1': n1, 'n2': n2,
                'ratio': r, 'band': band / 100, 'dp': 0, 'q': 0, 'in_tree': 0,
            }
            if mi is not None and mi > 0:
                e['mininlet'] = mi * net['f_pres']
            net['elems'].append(e)
        elif ty == 'BFP':
            net['elems'].append({
                'id': tk[0], 'kind': 'BFP', 'n1': n1, 'n2': n2,
                'curve': read_curve(net, tk, 4, 1), 'q': 0, 'in_tree': 0,
            })
        elif ty == 'DPV':
            mode = (kv_text(tk, 'MODE') or '').upper()
            acc = (kv_text(tk, 'ACC') or '').upper()
            trip = {}
            if mode == 'RATIO':
                trip['trip_ratio'] = kv(tk, 'RATIO')
            elif mode == 'TRIP':
                trip['trip_pressure'] = kv(tk, 'TRIP') * net['f_pres']
            pts = [t for t in tk[4:] if '=' not in t]
            loss, data = 'NONE', {}
            vk = kv_text(tk, 'VALVE')
            if vk is not None:
                ensure_db()
                mk, md = (vk.split('/', 1) + [''])[:2]
                sizek = kv(tk, 'SIZE')
                v = pipedata.dry_valve(mk, md, int(sizek if sizek is not None else 0))
                if v is None:
                    fail('DPV %s: %s is not in the database in this size', tk[0], vk)
                if v.get('cv') or (v.get('eql_m') is not None and v.get('bore_mm') and v.get('c')):
                    loss = 'DB'
                    if v.get('cv'):
                        data = {'cv': v['cv']}
                    else:
                        data = {'eql': v['eql_m'], 'ref_bore': v['bore_mm'], 'ref_c': float(v['c'])}
                    data.update(db=v, db_model='%s %s' % (v['maker'], v['model']),
                                loss_source='MANUFACTURER_DB')
                else:
                    loss = 'NONE'
                    data = {'db': v, 'db_model': '%s %s' % (v['maker'], v['model']),
                            'data_status': 'DATA_REQUIRED'}
            elif kv(tk, 'EQL') is not None:
                loss, data = 'EQL', {'eql': kv(tk, 'EQL') * net['f_len'], 'loss_source': 'USER_EQL'}
            elif kv(tk, 'FIXED') is not None:
                f = kv(tk, 'FIXED') * net['f_pres']
                loss = 'CURVE'
                data = {'curve': fit_curve({'q': [0, 1e6], 'p': [f, f]}, 1),
                        'fixed_loss': f, 'loss_source': 'USER_FIXED'}
            elif pts:
                loss = 'CURVE'
                data = {'curve': read_curve(net, tk, 4, 1), 'loss_source': 'USER_CURVE'}
            data.setdefault('loss_source', 'NONE')
            data.setdefault('data_status', 'DATA_REQUIRED' if loss == 'NONE' else 'GIVEN')
            e = {
                'id': tk[0], 'kind': 'DPV', 'n1': n1, 'n2': n2,
                'size': int(kv(tk, 'SIZE') or 0), 'host_id': kv_text(tk, 'HOST'),
                'trip_mode': mode, 'accelerator': acc,
                'loss': loss, 'q': 0, 'in_tree': 0,
                'transient': {
                    'state': 'TRIPPED_OPEN',
                    'states': ['SET', 'PRESSURE_DECAY', 'TRIPPED', 'FILLING', 'WATER_DELIVERY'],
                    'air_initial': None,       # DPVAIR, kPa
                    'trip_ratio': trip.get('trip_ratio'),
                    'trip_pressure': trip.get('trip_pressure'),
                    'accelerator': acc,
                    'accelerator_model': None,
                    'trip_conditions': None,
                    'dry_volume': None,       # m3 of the dry pipework
                    'air_decay': None,
                    'valve_opening': None,
                    'water_transit': None,
                    'venting': None,
                    'delivery_time': None,    # s: NOT CALCULATED
                },
            }
            e.update(trip)
            e.update(data)
            net['elems'].append(e)
        else:
            fail('device type %s is not known', ty)
        return
