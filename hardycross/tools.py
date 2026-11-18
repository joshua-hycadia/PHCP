#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# tools.py -- Python port of HardyCross/Tools.pm.
#
# The calculators behind QUICK TOOLS and ORIFICE PLATE.
#
#   velocity   a pipe type and size, and a flow: the bore and the velocity
#   kfactor    any two of K, Q and P: the third, from Q = K x sqrt(P)
#   kconvert   a K-factor in one unit, in the others: US (gpm per root psi)
#              and metric (L/min per root bar, and per root kPa)
#   loss       a pipe type and size, and a flow: the friction loss by
#              Hazen-Williams and by Darcy-Weisbach, side by side
#   fittings   a pipe type and size, and fittings: their equivalent length
#              from the database, fitting by fitting
#   plate      an orifice plate: the bore that gives a net loss (as OPP
#              sizes one), or the net loss across a bore (as OFD)
#
# Each takes the fields as typed (text) and returns either the answer or the
# problems with the fields, each naming its field, so the tab only draws.
# Nothing here is part of a model; nothing here changes one.
#
# THE SAME NUMBERS AS A CALCULATION
#   Bores come from the pipe and fitting database (pipedata), as a
#   model's pipes do.  The losses are the solver's own: a one-pipe element is
#   handed to elem_hf with the program's default options -- the
#   Hazen-Williams constant 6.05e7 and exponents 1.85 and 4.87, water at
#   20 C (kinematic viscosity 1.004e-6 m2/s) -- so a pipe here loses exactly
#   what the same pipe loses in a model.  The C factor and the roughness
#   default to the pipe type's, from the database (a type with no roughness
#   published, and BORE, take 0.045 mm, the program's default).  Either can
#   be changed.
#   Darcy-Weisbach's friction factor is the solver's: an explicit solution of
#   the Colebrook equation when turbulent (Re 4000 and above), 64/Re when
#   laminar (below 2000), and a straight blend of the two between.
#
#   UNITS.  Each calculator takes units => { FLOW, PRESSURE, LENGTH, SIZE,
#   KFACTOR } -- the PROJECT tab's, with the same choices and the same factors
#   as a model (phc).  Fields are read in those units and turned
#   into L/min, kPa, m and mm for the sums; the answers come back in L/min,
#   kPa, m and mm, with show(), below, to give them in the units chosen.
#   Without units, everything is L/min, kPa, m and mm.  Velocity is m/s.  A
#   K80 head is K 8 in L/min/kPa^0.5, K 80 in L/min/bar^0.5, K 5.6 in
#   gpm/psi^0.5.
#

import math
import re

from . import parse, pipedata, phc
from .phc import unit_factor, length_metres, size_mm, UNIT_CHOICES
import hardycross

# The pipe "type" that takes a bore typed in, rather than a size looked up.
BORE = 'BORE'
EPS_DEFAULT = 0.045     # mm, as parse gives a pipe with none

def blank(v):
    # as in Perl, a number is its own text: 50 is not blank.
    return v is None or not re.search(r'\S', str(v))

#------------------------------------------------------------------------------
# Units.
#------------------------------------------------------------------------------
INTERNAL = {'FLOW': 'LPM', 'PRESSURE': 'KPA', 'LENGTH': 'M', 'SIZE': 'MM',
            'KFACTOR': 'LPM/KPA'}
KALIAS = {'US': 'GPM/PSI', 'BAR': 'LPM/BAR', 'KPA': 'LPM/KPA'}

# units_of -- a units hash completed: anything not given is the internal unit.
def units_of(u=None):
    u = u or {}
    return {q: ((str(u.get(q) or '').upper()) or INTERNAL[q]) for q in INTERNAL}

# factor -- what one of $unit is in the internal unit of $q: L/min, kPa, m, mm.
def factor(q, unit):
    if q in ('FLOW', 'PRESSURE'):
        return unit_factor(q, unit)
    if q == 'LENGTH':
        return length_metres('1', unit)
    if q == 'SIZE':
        return size_mm('1', unit)
    raise ValueError('no unit factor for %s' % q)

# kfactor_factor -- what a K of 1 in a KFACTOR unit (e.g. GPM/PSI) is in
# L/min per root kPa: the flow factor over the root of the pressure factor.
def kfactor_factor(unit):
    unit = str(unit).upper()
    unit = KALIAS.get(unit, unit)
    kq, kp = unit.split('/')
    return factor('FLOW', kq) / math.sqrt(factor('PRESSURE', kp))

# show -- an internal value (L/min, kPa, m, mm) in the unit chosen for $q.
def show(q, v, units=None):
    return v / factor(q, units_of(units)[q])

def is_num(v):
    # as in Perl, a number is its own text: 500 is a valid field value.
    return v is not None and re.match(
        r'^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*\Z', str(v)) is not None

# pipe_types -- the choices for PIPE TYPE: every type in the database, then
# BORE for a bore typed in.
def pipe_types():
    parse.ensure_db()
    return list(pipedata.pipe_types()) + [BORE]

# sizes -- the nominal sizes the database holds for a pipe type, smallest
# first, leaving out any whose bore is not given.
def sizes(type_):
    parse.ensure_db()
    if type_ == BORE:
        return []
    dn = []
    for d in range(1, 1201):
        if pipedata.bore(type_, str(d)) is not None:
            dn.append(d)
    return dn

# type_c -- the pipe type's Hazen-Williams C, from the database (120 for BORE).
def type_c(type_):
    parse.ensure_db()
    t = pipedata.pipe_type(type_) if type_ != BORE else None
    return float(t['c']) if t else 120

# type_eps -- the pipe type's roughness in mm, from the database; 0.045, the
# program's default, for BORE or a type with none published.
def type_eps(type_):
    type_ = type_ or ''
    parse.ensure_db()
    t = pipedata.pipe_type(type_) if type_ != BORE else None
    return float(t['eps']) if (t and t.get('eps') is not None) else EPS_DEFAULT

# ascii -- text for the sheet: degree sign spelt, non-ASCII dropped, capitals.
def _ascii(s):
    s = s or ''
    s = s.replace('\xb0', ' DEG')
    s = re.sub(r'[^\x20-\x7E]', '', s)
    return s.upper()

#------------------------------------------------------------------------------
# number -- a field as a number: (value) or (None, problem).  $rule:
# 'pos' above zero, 'nonneg' zero or above.
#------------------------------------------------------------------------------
def number(label, v, rule='pos'):
    if blank(v):
        return None, '%s IS NEEDED' % label
    if not is_num(v):
        return None, "%s '%s' IS NOT A NUMBER" % (label, re.sub(r'^\s+|\s+$', '', str(v)))
    n = float(v)
    if rule == 'pos' and n <= 0:
        return None, '%s MUST BE ABOVE ZERO' % label
    if n < 0:
        return None, '%s CANNOT BE NEGATIVE' % label
    return n, None

# bore_of -- (bore mm) or (None, [field, problem]) for a type and a size; for
# BORE the size field is the bore itself.
def bore_of(type_, size, u=None):
    parse.ensure_db()
    if blank(type_):
        return None, ['TYPE', 'CHOOSE A PIPE TYPE']
    if type_ == BORE:
        d, e = number('BORE', size)
        if d is None:
            return None, ['SIZE', e]
        return d * factor('SIZE', units_of(u)['SIZE']), None
    if not pipedata.pipe_type(type_):
        return None, ['TYPE', 'UNKNOWN PIPE TYPE %s' % type_]
    if blank(size):
        return None, ['SIZE', 'CHOOSE A SIZE']
    d = pipedata.bore(type_, '%g' % float(size)) if is_num(size) else None
    d = float(d) if d is not None else None
    if not d:
        return None, ['SIZE', '%s IS NOT MADE IN DN%s - CHOOSE A SIZE FROM THE LIST' % (type_, size)]
    return d, None

#------------------------------------------------------------------------------
# velocity -- { type, size, flow, units } as typed.  Returns
#   { ok: 1, bore (mm), area (m2), velocity (m/s), q }
#   { ok: 0, errors: [ [field, problem] ] }
#------------------------------------------------------------------------------
def velocity(**f):
    u = units_of(f.get('units'))
    err = []
    d, de = bore_of(f.get('type'), f.get('size'), u)
    if de:
        err.append(de)
    q, qe = number('FLOW', f.get('flow'), 'nonneg')
    if qe:
        err.append(['FLOW', qe])
    if err:
        return {'ok': 0, 'errors': err}
    q *= factor('FLOW', u['FLOW'])
    return {'ok': 1, 'bore': d, 'area': 3.14159265358979 * (d / 1000) ** 2 / 4,
            'q': q, 'velocity': hardycross.pipe_velocity(q, d)}

#------------------------------------------------------------------------------
# kfactor -- { k, q, p, unit, units } as typed: exactly two of K, Q and P
# given, the third found from Q = K x sqrt(P).  Q and P are in units' FLOW and
# PRESSURE; K in unit, a KFACTOR unit (LPM/KPA, the default; LPM/BAR, LPS/KPA,
# LPS/BAR, GPM/PSI; or KPA, BAR, US for the commonest).  Returns
#   { ok: 1, solved: 'K'|'Q'|'P', k (in unit), q (L/min), p (kPa),
#     k_kpa, k_bar, k_us, unit }
#   { ok: 0, errors: [ [field, problem] ] }
#------------------------------------------------------------------------------
def kfactor(**f):
    unit = str(f.get('unit') or 'KPA').upper()
    unit = KALIAS.get(unit, unit)
    u = units_of(f.get('units'))
    given = [x for x in ('K', 'Q', 'P') if not blank(f.get(x.lower()))]
    if len(given) < 2:
        return {'ok': 0, 'errors': [['K', 'GIVE ANY TWO OF K, Q AND P - THE THIRD IS FOUND']]}
    if len(given) > 2:
        return {'ok': 0, 'errors': [['K', 'GIVE ONLY TWO OF K, Q AND P - CLEAR THE ONE TO BE FOUND']]}
    v, err = {}, []
    label = {'K': 'K', 'Q': 'FLOW Q', 'P': 'PRESSURE P'}
    for x in given:
        n, e = number(label[x], f.get(x.lower()), 'pos' if x == 'K' else 'nonneg')
        if e:
            err.append([x, e])
        else:
            v[x] = n
    if err:
        return {'ok': 0, 'errors': err}
    # The sums in L/min, kPa and L/min per root kPa.
    kf = 1 / kfactor_factor(unit)
    k = v['K'] / kf if 'K' in v else None
    q = v['Q'] * factor('FLOW', u['FLOW']) if 'Q' in v else None
    p = v['P'] * factor('PRESSURE', u['PRESSURE']) if 'P' in v else None
    solved = next(x for x in ('K', 'Q', 'P') if x not in v)
    if solved == 'K':
        if not p > 0:
            return {'ok': 0, 'errors': [['P', 'PRESSURE P MUST BE ABOVE ZERO TO FIND K']]}
        k = q / math.sqrt(p)
    elif solved == 'Q':
        q = k * math.sqrt(p)
    else:
        p = (q / k) ** 2
    return {'ok': 1, 'solved': solved, 'k': k * kf, 'q': q, 'p': p, 'k_kpa': k,
            'k_bar': k * 10, 'k_us': k / kfactor_factor('GPM/PSI'), 'unit': unit}

#------------------------------------------------------------------------------
# kconvert -- { value, from } as typed: a K-factor in one unit, given in all
# three.  from is 'US' (US gpm per root psi), 'BAR' (L/min per root bar) or
# 'KPA' (L/min per root kPa).  K = Q / sqrt(P), so a K converts by the flow
# factor over the root of the pressure factor:
#   1 US gallon = 3.785411784 L (exact);  1 psi = 6.894757 kPa (the model's
#   unit table)
#   K(L/min/bar^0.5) = K(gpm/psi^0.5) x 3.785411784 x sqrt(100 / 6.894757)
#                    = K(US) x 14.4163...;   K per root kPa is a tenth of that.
# So a K5.6 head (US) is K80.7 metric (bar), the K80 it is sold as.  from may
# also be any KFACTOR unit (LPS/KPA, LPS/BAR ...).  Returns
#   { ok: 1, us, bar, kpa, all: { unit: K, for every KFACTOR unit }, from }
#   { ok: 0, errors: [ [field, problem] ] }
#------------------------------------------------------------------------------
def kconvert(**f):
    frm = str(f.get('from') or 'US').upper()
    k, e = number('K', f.get('value'))
    if e:
        return {'ok': 0, 'errors': [['VALUE', e]]}
    # By the model's own unit factors, so a K converts here exactly as a
    # model reads it in that unit.
    bar = k * kfactor_factor(frm) * 10
    all_ = {u: bar / 10 / kfactor_factor(u) for u in UNIT_CHOICES['KFACTOR']}
    return {'ok': 1, 'from': frm, 'us': all_['GPM/PSI'], 'bar': bar,
            'kpa': bar / 10, 'all': all_}

#------------------------------------------------------------------------------
# loss -- { type, size, flow, length, c, eps, units } as typed.  Length blank
# is one metre; C and roughness blank are the pipe type's.  Returns, in
# L/min, kPa, m and mm (show() gives them in the units chosen)
#   { ok: 1, bore, velocity, length, c, eps, eps_src (GIVEN, DATABASE, or
#     DEFAULT: 0.045 mm assumed, none given or published),
#     hw: { per_m, total },
#     dw: { per_m, total, re, f, regime },
#     diff (DW - HW, kPa), diff_pct (of HW) }
#   { ok: 0, errors: [ [field, problem] ] }
# Both losses are elem_hf on one pipe, with the program's default
# options and the method set; so they are what a model would give.
#------------------------------------------------------------------------------
def loss(**f):
    u = units_of(f.get('units'))
    err = []
    d, de = bore_of(f.get('type'), f.get('size'), u)
    if de:
        err.append(de)
    q, qe = number('FLOW', f.get('flow'), 'nonneg')
    if qe:
        err.append(['FLOW', qe])
    else:
        q *= factor('FLOW', u['FLOW'])

    def eps_published(t):
        pt = pipedata.pipe_type(t)
        return bool(pt and pt.get('eps') is not None)
    ln = 1
    if not blank(f.get('length')):
        l, le = number('LENGTH', f.get('length'))
        if le:
            err.append(['LENGTH', le])
        else:
            ln = l * factor('LENGTH', u['LENGTH'])
    c = type_c(f.get('type')) if (f.get('type') and not de) else 120
    if not blank(f.get('c')):
        v, ce = number('C FACTOR', f.get('c'))
        if ce:
            err.append(['C', ce])
        else:
            c = v
    # The roughness: as typed; else the type's, from the database; else the
    # program default, 0.045 mm -- and then said to be assumed.
    eps = type_eps(f.get('type')) if (f.get('type') and not de) else EPS_DEFAULT
    eps_src = ('DATABASE' if (f.get('type') and not de and f.get('type') != BORE
                               and eps_published(f.get('type'))) else 'DEFAULT')
    if not blank(f.get('eps')):
        v, ee = number('ROUGHNESS', f.get('eps'), 'nonneg')
        if ee:
            err.append(['EPS', ee])
        else:
            eps, eps_src = v * factor('SIZE', u['SIZE']), 'GIVEN'
    if err:
        return {'ok': 0, 'errors': err}

    pipe = {'kind': 'PIPE', 'len': ln, 'eqv': 0, 'dia': d, 'c': c, 'eps': eps}

    def hf(method):
        o = parse.new_net()['opts']
        o['method'] = method
        return hardycross.elem_hf(pipe, q, o)[0]

    hw, dw = hf('HW'), hf('DW')
    v = hardycross.pipe_velocity(q, d)
    nu = parse.new_net()['opts']['nu']
    re = v * (d / 1000) / nu
    fr = hardycross.dw_friction(re, eps, d)
    return {
        'ok': 1, 'bore': d, 'velocity': v, 'length': ln, 'c': c, 'eps': eps,
        'eps_src': eps_src, 'nu': nu,
        'hw': {'per_m': hw / ln, 'total': hw},
        'dw': {'per_m': dw / ln, 'total': dw, 're': re, 'f': fr,
               'regime': 'LAMINAR' if re < 2000 else ('TRANSITIONAL' if re < 4000 else 'TURBULENT')},
        'diff': dw - hw, 'diff_pct': (100 * (dw - hw) / hw if hw > 0 else 0),
    }

#------------------------------------------------------------------------------
# fittings -- { type, size, spec, c } as typed: fittings on a pipe, in the
# .phc fitting form (2E 1T GV, or 2E,1T,1GV), and their equivalent length,
# by pipedata.resolve -- the same look-up, source and
# corrections as a model's pipe.  C blank is the pipe type's.  Returns
#   { ok: 1, total (m), source, rows: [ { count, code, label, each, total,
#     note } ] }
#   { ok: 0, errors: [ [field, problem] ] }
# A fitting the database has no value for is an error, as in a model: never
# zero, never interpolated.
#------------------------------------------------------------------------------
def fittings(**f):
    err = []
    if (f.get('type') or '') == BORE:
        return {'ok': 0, 'errors': [['TYPE', 'FITTINGS NEED A PIPE TYPE FROM THE DATABASE, NOT BORE']]}
    d, de = bore_of(f.get('type'), f.get('size'))
    if de:
        err.append(de)
    c = None
    if not blank(f.get('c')):
        v, ce = number('C FACTOR', f.get('c'))
        if ce:
            err.append(['C', ce])
        else:
            c = v
    if blank(f.get('spec')):
        err.append(['SPEC', 'GIVE THE FITTINGS: 2E 1T GV, OR 2E,1T,1GV'])
    if err:
        return {'ok': 0, 'errors': err}
    spec = str(f['spec']).upper().strip()
    spec = re.sub(r'[\s,]+', '+', spec)
    # The editor's short forms for the three commonest valves.
    def _short(w):
        m = re.match(r'^(\d*)([GCB])\Z', w)
        return m and (m.group(1) + {'G': 'GV', 'C': 'CV', 'B': 'BV'}[m.group(2)]) or w
    spec = '+'.join(_short(w) for w in spec.split('+'))
    r = pipedata.resolve(type=f.get('type'), dn='%g' % float(f.get('size')), c=c, spec=spec)
    if r['errors']:
        return {'ok': 0, 'errors': [['SPEC', str(x).upper()] for x in r['errors']]}
    rows = [{'count': x['count'], 'code': x['code'],
             'label': _ascii(x.get('label') or x['code']),
             'each': x['each'], 'total': x['total'], 'note': x.get('note')}
            for x in r['records']]
    src = r['records'][0]['doc'] if r['records'] else ''
    return {'ok': 1, 'total': r['total'], 'rows': rows, 'source': src, 'spec': spec}

#------------------------------------------------------------------------------
# plate -- an orifice plate, worked the way a model works one.
#
#   mode => 'SIZE'   the bore that gives a net loss, as OPP sizes a plate
#   mode => 'DROP'   the net loss across a bore, as OFD
#
# Fields, as typed: type, size (the pipe, as the other calculators), flow,
# and for SIZE the drop wanted and an optional step; for DROP the plate's
# bore.  cd blank is 0.596.  It must be more than 0 and not more than 1.
# step blank is step_default millimetres, or 0.5 mm when that is not given;
# 0 means do not round.  A step above 0 rounds the way size_orifices
# rounds an OPP bore: int(bore/step + 0.5) * step, in millimetres.
#
# The net loss is orifice_dp and the bore is orifice_size,
# so a plate here is the plate a model would size or lose across.  That loss
# is the tapping differential times the ISO 5167 permanent-loss ratio, which
# is what a network needs; both are returned so the tab can say so.
#
# Returns, in L/min, kPa and mm (show() gives them in the units chosen)
#   { ok: 1, mode, q, pipedia, cd, cd_default, bore, bore_exact, step,
#     drop, drop_exact, target, beta, velocity, pipe_velocity, ratio,
#     differential, limit ('' or WIDE or TIGHT), fits }
#   { ok: 0, errors: [ [field, problem] ] }
# WIDE: a bore almost the pipe's still drops more than asked.  TIGHT: even a
# very small bore does not drop this much.  fits is false when the bore that
# would be used is not smaller than the pipe.
#------------------------------------------------------------------------------
def _plate_ratio(d, bigd, cd):
    if d <= 0 or bigd <= 0 or cd <= 0:
        return 0
    beta = d / bigd if d / bigd < 0.99999 else 0.99999
    b4 = beta ** 4
    inside = 1 - b4 * (1 - cd * cd)
    if inside < 1e-12:
        inside = 1e-12
    s = math.sqrt(inside)
    den = s + cd * beta * beta
    if den == 0:
        return 0
    r = (s - cd * beta * beta) / den
    return r if r >= 0 else 0

def plate(**f):
    mode = str(f.get('mode') or 'SIZE').upper()
    if mode != 'DROP':
        mode = 'SIZE'
    u = units_of(f.get('units'))
    err = []
    bigd, de = bore_of(f.get('type'), f.get('size'), u)
    if de:
        err.append(de)
    q, qe = number('FLOW', f.get('flow'))
    if qe:
        err.append(['FLOW', qe])
    else:
        q *= factor('FLOW', u['FLOW'])
    cd = 0.596
    cd_default = 1
    if not blank(f.get('cd')):
        c, ce = number('CD', f.get('cd'))
        if ce:
            err.append(['CD', ce])
        elif c <= 0 or c > 1:
            err.append(['CD', 'CD MUST BE MORE THAN 0 AND NOT MORE THAN 1'])
        else:
            cd, cd_default = c, 0
    target = bore_given = step = None
    if mode == 'SIZE':
        drop, dre = number('DROP', f.get('drop'))
        if dre:
            err.append(['DROP', dre])
        else:
            target = drop * factor('PRESSURE', u['PRESSURE'])
        if blank(f.get('step')):
            step = f['step_default'] if f.get('step_default') is not None else 0.5
            if step < 0:
                err.append(['STEP', 'BORE STEP MUST BE ZERO OR ABOVE'])
        else:
            s, se = number('BORE STEP', f.get('step'), 'nonneg')
            if se:
                err.append(['STEP', se])
            else:
                step = s * factor('SIZE', u['SIZE'])
    else:
        b, be = number('PLATE BORE', f.get('bore'))
        if be:
            err.append(['BORE', be])
        else:
            bore_given = b * factor('SIZE', u['SIZE'])
        if bore_given is not None and bigd is not None and bore_given >= bigd:
            err.append(['BORE', 'PLATE BORE MUST BE SMALLER THAN THE PIPE BORE'])
    if err:
        return {'ok': 0, 'errors': err}

    exact, limit = 0, ''
    if mode == 'SIZE':
        hi = 0.9995 * bigd
        lo = 0.001 * bigd
        if hardycross.orifice_dp(q, hi, bigd, cd) > target:
            limit = 'WIDE'
        elif hardycross.orifice_dp(q, lo, bigd, cd) < target:
            limit = 'TIGHT'
        exact = hardycross.orifice_size(q, target, bigd, cd)
        if exact <= 0:
            return {'ok': 0, 'errors': [['DROP', 'THE PLATE CANNOT BE SIZED FOR THIS FLOW AND DROP']]}
    else:
        exact = bore_given
    bore = exact
    if mode == 'SIZE' and step > 0:
        bore = int(bore / step + 0.5) * step
    drop = hardycross.orifice_dp(q, bore, bigd, cd)
    drop_exact = hardycross.orifice_dp(q, exact, bigd, cd) if mode == 'SIZE' else drop
    ratio = _plate_ratio(bore, bigd, cd)
    return {
        'ok': 1, 'mode': mode, 'q': q, 'pipedia': bigd, 'cd': cd,
        'cd_default': cd_default, 'bore': bore, 'bore_exact': exact,
        'step': (step if mode == 'SIZE' else 0), 'drop': drop,
        'drop_exact': drop_exact, 'target': target,
        'beta': (bore / bigd if bigd > 0 else 0),
        'velocity': hardycross.pipe_velocity(q, bore),
        'pipe_velocity': hardycross.pipe_velocity(q, bigd),
        'ratio': ratio, 'differential': (drop / ratio if ratio > 0 else 0),
        'limit': limit, 'fits': bore > 0 and bore < bigd,
    }
