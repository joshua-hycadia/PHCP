#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# phc.py -- Python port of HardyCross/Phc.pm, the .phc command language.
#
# THIS MODULE TRANSLATES; IT DOES NOT RE-IMPLEMENT.  Every command becomes the
# rows that mean the same thing -- a section word (NODES, PIPES, SUPPLIES ...)
# and its tokens -- and each row is added to the network by parse_row, the
# network builder.  Every hydraulic check and default therefore lives in one
# place.  What is done HERE is what belongs to the language.
#

import math
import os
import re

from . import fail, set_unit, fit_curve, is_model_error, ModelError
from . import pipedata
from .parse import (tokenize, num, is_num, ensure_db, new_net, parse_row,
                    roughness_warning)

#==============================================================================
# The vocabulary.
#==============================================================================

OPTIONS = ['HW_CONST', 'NU', 'TOL_FLOW', 'TOL_LOOP', 'MAXITER', 'RELAX',
           'ORIF_DP_TOL', 'VEL_LIMIT', 'FITTING_BASIS', 'ORIF_STEP',
           'HOSE_ALLOWANCE', 'DESIGN_AREA', 'SIZING_GOAL', 'SIZING_MARGIN',
           'SIZING_TRIALS', 'VELOCITY_PRESSURE', 'SUPPLY_MARGIN',
           'SUPPLY_SCENARIOS', 'JOINT_BASIS']
OPTION = {o: 1 for o in OPTIONS}
NUM_OPTION = {o: 1 for o in ['HW_CONST', 'NU', 'TOL_FLOW', 'TOL_LOOP', 'MAXITER',
                             'RELAX', 'VEL_LIMIT', 'ORIF_STEP', 'ORIF_DP_TOL',
                             'HOSE_ALLOWANCE', 'SUPPLY_MARGIN']}

UNIT_QUANTITIES = ['LENGTH', 'ELEVATION', 'SIZE', 'PRESSURE', 'FLOW', 'KFACTOR']
UNIT_CHOICES = {
    'LENGTH':    ['MM', 'CM', 'M', 'IN', 'FT'],       # pipe and equivalent lengths
    'ELEVATION': ['MM', 'CM', 'M', 'IN', 'FT'],
    'SIZE':      ['MM', 'IN'],                        # nominal sizes, bores, roughness
    'PRESSURE':  ['KPA', 'BAR', 'MPA', 'PSI', 'M'],   # M: metres head of water
    'FLOW':      ['LPM', 'LPS', 'M3H', 'GPM'],
    'KFACTOR':   ['LPM/KPA', 'LPM/BAR', 'LPS/KPA', 'LPS/BAR', 'GPM/PSI'],
}
# The office defaults (decided 28 October 2026).
UNIT_DEFAULT = {'LENGTH': 'MM', 'ELEVATION': 'M', 'SIZE': 'MM',
                'PRESSURE': 'KPA', 'FLOW': 'LPM', 'KFACTOR': 'LPM/KPA'}
UNIT_SPELLING = {'L/MIN': 'LPM', 'L/S': 'LPS', 'M3/H': 'M3H',
                'USGPM': 'GPM', 'L/MIN/KPA': 'LPM/KPA', 'L/MIN/BAR': 'LPM/BAR'}
TO_METRE = {'MM': 0.001, 'CM': 0.01, 'M': 1, 'IN': 0.0254, 'FT': 0.3048}
INCH_DN = {'0.5': 15, '0.75': 20, '1': 25, '1.25': 32, '1.5': 40,
           '2': 50, '2.5': 65, '3': 80, '3.5': 90, '4': 100,
           '5': 125, '6': 150, '8': 200, '10': 250, '12': 300,
           '14': 350, '16': 400, '18': 450, '20': 500, '24': 600}

FIT_SHORT = {'G': 'GV', 'C': 'CV', 'B': 'BV'}


# ascii -- a database string shown in the editor: degrees as DEG, anything
# else beyond ASCII dropped, in capitals.
def _ascii(s):
    s = '' if s is None else s.replace('\N{DEGREE SIGN}', ' DEG')
    return re.sub(r'[^\x20-\x7E]', '', s).upper()

CMD = {
    'TITLE':     {'kind': 'setting', 'fixed': [['TEXT', 'text']]},
    'PROJECT':   {'kind': 'setting', 'fixed': [['FIELD', 'field'], ['TEXT', 'text']]},
    'UNITS':     {'kind': 'setting', 'fixed': [['QUANTITY', 'quantity'], ['UNIT', 'unit']]},
    'METHOD':    {'kind': 'setting', 'fixed': [['HW|DW', 'method']]},
    'OPTION':    {'kind': 'setting', 'fixed': [['NAME', 'option'], ['VALUE', 'value']]},
    'USE':       {'kind': 'use', 'fixed': [['PIPETYPE', 'pipetype']],
                  'opt': [['C', 'num']]},
    'PIPE':      {'kind': 'pipe', 'fixed': [['NAME', 'new'], ['START', 'node'], ['END', 'node'],
                                            ['LENGTH', 'length'], ['SIZE', 'size']], 'rest': 'fittings'},
    'PC':        {'kind': 'pipe', 'fixed': [['SOURCE', 'pipe']], 'rest': 'copies'},
    'CHANGEPIPE': {'kind': 'pipe', 'fixed': [['PIPE', 'pipe'], ['LENGTH', 'length'],
                                             ['SIZE', 'size']], 'rest': 'fittings'},
    'EQV':       {'kind': 'pipe', 'fixed': [['PIPE', 'pipe'], ['LENGTH', 'length']]},
    'NODE':      {'kind': 'node', 'fixed': [['NAME', 'new'], ['ELEVATION', 'elev']]},
    'NC':        {'kind': 'node', 'fixed': [['SOURCE', 'node']], 'rest': 'names'},
    'WATER':     {'kind': 'node', 'fixed': [['NAME', 'new'], ['ELEVATION', 'elev'],
                                            ['STATIC', 'pressure']], 'rest': 'pairs', 'min': 0},
    'NRV':       {'kind': 'nrv', 'fixed': [['SUPPLY', 'node'], ['CV', 'num']],
                  'opt': [['CRACK', 'pressure']]},
    'NRVMODEL':  {'kind': 'nrv', 'fixed': [['SUPPLY', 'node'], ['TEXT', 'text']]},
    'NRVLOSS':   {'kind': 'nrv', 'fixed': [['SUPPLY', 'node']],
                  'rest': 'pairs', 'min': 2},
    'SPRINKLER': {'kind': 'node', 'otype': 'SPRINKLER', 'fixed': [['NAME', 'new'],
                   ['ELEVATION', 'elev'], ['MINFLOW', 'minflow'], ['K', 'kfactor']]},
    'HYDRANT':   {'kind': 'node', 'otype': 'HYDRANT', 'fixed': [['NAME', 'new'],
                   ['ELEVATION', 'elev'], ['MINFLOW', 'minflow'], ['K', 'kfactor']]},
    'HREEL':     {'kind': 'node', 'otype': 'HOSEREEL', 'fixed': [['NAME', 'new'],
                   ['ELEVATION', 'elev'], ['MINFLOW', 'minflow'], ['K', 'kfactor']]},
    'FIXEDFLOW': {'kind': 'element', 'fixed': [['NAME', 'new'], ['NODE', 'node'],
                   ['FLOW', 'flow']], 'opt': [['MINPRESSURE', 'pressure']]},
    'PUMP':      {'kind': 'element', 'fixed': [['NAME', 'new'], ['IN', 'node'], ['OUT', 'node'],
                   ['CHURN', 'pressure']], 'rest': 'pairs', 'min': 1},
    'BP':        {'kind': 'device', 'fixed': [['PIPE', 'pipe'], ['CHURN', 'pressure']],
                  'rest': 'pairs', 'min': 1},
    'BFP':       {'kind': 'device', 'fixed': [['PIPE', 'pipe']], 'rest': 'pairs', 'min': 1},
    'PRV':       {'kind': 'device', 'fixed': [['PIPE', 'pipe']], 'rest': 'pairs', 'min': 1},
    'OPP':       {'kind': 'device', 'fixed': [['PIPE', 'pipe'], ['DROP', 'pressure']],
                  'opt': [['CD', 'num']]},
    'OFD':       {'kind': 'device', 'fixed': [['PIPE', 'pipe'], ['BORE', 'size']],
                  'opt': [['CD', 'num']]},
    'PUMPDUTY':  {'kind': 'duty', 'fixed': [['PUMP', 'pipe'], ['FLOW', 'flow'], ['PRESSURE', 'pressure']]},
    'PRA':       {'kind': 'device', 'fixed': [['PIPE', 'pipe'], ['RATIO', 'ratio']],
                  'opt': [['MININLET', 'pressure'], ['BAND', 'num']]},
    'DPV':       {'kind': 'device', 'fixed': [['PIPE', 'pipe'], ['SIZE', 'size'],
                   ['RATIO|TRIP', 'tripmode'], ['SETTING', 'tripvalue'], ['ON|OFF', 'onoff']],
                  'rest': 'dpvloss'},
    'DPVMODEL':  {'kind': 'dpvdata', 'fixed': [['PIPE', 'pipe'], ['TEXT', 'text']]},
    'DPVAIR':    {'kind': 'dpvdata', 'fixed': [['PIPE', 'pipe'], ['PRESSURE', 'pressure']]},
    'DPVTRIP':   {'kind': 'dpvdata', 'fixed': [['PIPE', 'pipe'], ['ORIFICE', 'size']],
                   'opt': [['COUNT', 'num'], ['AIRTEMP', 'temp'], ['STATIC', 'pressure']]},
    'SCENARIO':  {'kind': 'scenario', 'fixed': [['NAME', 'new'], ['SUPPLY', 'node'], ['PERCENT', 'num']],
                  'rest': 'shares'},
    'SUPPLYGRAPH': {'kind': 'graph', 'fixed': [['FILE', 'text']]},
    'AREA':      {'kind': 'area', 'fixed': [['NAME', 'new']], 'rest': 'outlets'},
}
for _k in CMD:
    CMD[_k]['name'] = _k

ALIAS = {'P': 'PIPE', 'U': 'USE', 'N': 'NODE', 'W': 'WATER', 'CHP': 'CHANGEPIPE'}

COMMAND_GROUPS = [
    ['TITLE', 'PROJECT', 'UNITS', 'METHOD', 'OPTION'],
    ['USE', 'PIPE', 'PC', 'CHANGEPIPE', 'EQV'],
    ['NODE', 'NC', 'WATER', 'NRV', 'NRVMODEL', 'NRVLOSS', 'SPRINKLER', 'HYDRANT', 'HREEL', 'FIXEDFLOW'],
    ['PUMP', 'PUMPDUTY', 'BP', 'BFP', 'PRV', 'OPP', 'OFD', 'PRA', 'DPV', 'DPVMODEL', 'DPVAIR', 'DPVTRIP'],
    ['AREA', 'SUPPLYGRAPH', 'SCENARIO'],
]
COMMANDS = [c for g in COMMAND_GROUPS for c in g]

def command_spec(w):
    w = (w or '').upper()
    return CMD.get(ALIAS.get(w, w))

REST_LABEL = {'fittings': 'FITTINGS ...', 'pairs': 'FLOW PRESSURE ...',
              'copies': 'NAME START END ...', 'names': 'NAME ...', 'outlets': 'OUTLET ...',
              'dpvloss': 'FLOW LOSS ... | EQL LENGTH', 'shares': 'SUPPLY PERCENT ...'}

def template_fields(c):
    f = [fd[0] for fd in c['fixed']]
    f += [fd[0] for fd in c.get('opt', [])]
    if c.get('rest'):
        f.append(REST_LABEL[c['rest']])
    return f

def template_text(w):
    c = command_spec(w)
    if c is None:
        return ''
    nfix = len(c['fixed'])
    f = template_fields(c)
    return ' '.join([c['name']] + [('<' + f[i] + '>' if i < nfix else '[' + f[i] + ']')
                                   for i in range(len(f))])

#==============================================================================
# Values.
#==============================================================================

_LEN_U = re.compile(r'^([-+]?(?:\d+\.?\d*|\.\d+))(MM|CM|M|IN|FT)$', re.I)
_FEET = re.compile(r"^([-+]?)(\d+(?:\.\d+)?)'(?:(\d+(?:\.\d+)?)\"?)?$")
_INCH = re.compile(r'^([-+]?)(\d+(?:\.\d+)?)"$')

def length_metres(t, unit):
    # A plain number is in the quantity's unit; a number may carry its own:
    # 12M, 300MM, 2.5CM, 6IN, 10FT, 14'3", 14'3, 6', 3".
    if t is None:
        return None
    if is_num(t):
        return num(t) * TO_METRE[unit]
    m = _LEN_U.match(t)
    if m:
        return float(m.group(1)) * TO_METRE[m.group(2).upper()]
    m = _FEET.match(t)
    if m:
        mm = float(m.group(2)) * 0.3048 + (float(m.group(3)) if m.group(3) else 0) * 0.0254
        return -mm if m.group(1) == '-' else mm
    m = _INCH.match(t)
    if m:
        return (-1 if m.group(1) == '-' else 1) * float(m.group(2)) * 0.0254
    return None

def inch_sizes():
    return dict(INCH_DN)

def size_dn(t, unit):
    if not is_num(t):
        return None
    if unit == 'MM':
        return int(float(t) + 0.5)
    return INCH_DN.get('%.15g' % float(t))

def size_mm(t, unit):
    if not is_num(t):
        return None
    return float(t) if unit == 'MM' else float(t) * 25.4

_RATIO = re.compile(r'^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$')

def ratio_value(t):
    t = '' if t is None else t
    m = _RATIO.match(t)
    if m and float(m.group(2)) > 0:
        return float(m.group(1)) / float(m.group(2))
    if is_num(t):
        return float(t)
    return None

def unit_code(u):
    u = (u or '').upper()
    return UNIT_SPELLING.get(u, u)

def unit_factor(q, u):
    net = new_net()
    set_unit(net, q, u)
    return net['f_flow'] if q == 'FLOW' else net['f_pres']

def k_factor_to_model(k, units):
    kq, kp = units['KFACTOR'].split('/')
    qf = unit_factor('FLOW', kq) / unit_factor('FLOW', units['FLOW'])
    pf = unit_factor('PRESSURE', kp) / unit_factor('PRESSURE', units['PRESSURE'])
    return k * qf / math.sqrt(pf)

def fmt(x):
    # Ten significant figures, enough that the rounding never shows.
    return '%.10g' % x

def pnum(x):
    # A number as Perl stringifies it, for row text built from arithmetic.
    return '%.15g' % x

#==============================================================================
# analyse -- the syntax of one .phc line.
#==============================================================================

def strip_comment(l):
    l = '' if l is None else l
    l = re.sub(r'\r?\n$', '', l)
    l = re.sub(r'//.*', '', l, flags=re.S)
    return l

def analyse(raw, partial=False):
    code = strip_comment(raw)
    a = {'status': 'ok', 'pos': [], 'opt': [], 'rest': []}

    def bad(msg, *args):
        a.update(status='error', msg=msg % args if args else msg)
        return a

    def more(msg, *args):
        a.update(status='incomplete', msg=msg % args if args else msg)
        return a

    m = re.search(r'[!#]', code)
    if m:
        return bad("'%s' CANNOT BE USED IN A .PHC LINE; COMMENTS START WITH //", m.group(0))
    tk = tokenize(code)
    if not tk:
        a['status'] = 'blank'
        return a

    word = tk[0].upper()
    c = command_spec(word)
    if c is None:
        if partial and len(tk) == 1 and not re.search(r'\s$', code) \
                and any(x.startswith(word) for x in COMMANDS):
            return more('A COMMAND: %s', ' '.join(COMMANDS))
        return bad('UNKNOWN COMMAND %s', tk[0].upper())
    a['key'] = c['name']

    #---------------------------------------------------------- TITLE, PROJECT
    if a['key'] in ('TITLE', 'PROJECT', 'SUPPLYGRAPH', 'DPVMODEL', 'NRVMODEL'):
        t = re.sub(r'^\s*\S+\s*', '', code)
        if a['key'] == 'PROJECT':
            if len(tk) <= 1:
                return more('FIELD')
            a['pos'].append(tk[1].upper())
            if tk[1].upper() == 'END':
                return bad('END CANNOT BE A PROJECT FIELD')
            t = re.sub(r'^\S+\s*', '', t)
        if a['key'] in ('DPVMODEL', 'NRVMODEL'):
            what = 'PIPE' if a['key'] == 'DPVMODEL' else 'SUPPLY'
            if len(tk) <= 1:
                return more(what)
            err = check_field('pipe' if what == 'PIPE' else 'node', tk[1], a, what)
            if err is not None:
                return bad('%s', err)
            t = re.sub(r'^\S+\s*', '', t)
        t = re.sub(r'\s+$', '', t)
        if not len(t):
            return more('%s', c['fixed'][-1][0])
        a['text'] = t
        return a

    #---------------------------------------------------------- the fields
    f = tk[1:]
    for t in f:
        if '=' in t:
            return bad("'%s': FIELDS GO BY POSITION - THERE ARE NO KEY=VALUE OPTIONS", t)
    for fd in c['fixed']:
        if not f:
            return more('%s', fd[0])
        err = check_field(fd[1], f.pop(0), a, fd[0])
        if err is not None:
            return bad('%s', err)
    for fd in c.get('opt', []):
        if not f:
            break
        err = check_field(fd[1], f.pop(0), a, fd[0], 1)
        if err is not None:
            return bad('%s', err)
    a['rest'] = f

    #---------------------------------------------------------- what follows
    rest = c.get('rest') or ''
    if rest == 'fittings':
        for t in f:
            if not re.match(r'^\d*[A-Z][A-Z0-9]*$', t, re.I):
                return bad("'%s' IS NOT A FITTING: A CODE WITH AN OPTIONAL COUNT, SUCH AS 2E", t)
    elif rest == 'pairs':
        for t in f:
            if not is_num(t):
                return bad("'%s' IS NOT A NUMBER", t)
            if float(t) < 0:
                return bad('FLOWS AND PRESSURES CANNOT BE NEGATIVE')
        if len(f) % 2:
            return more('THE PRESSURE TO PAIR WITH FLOW %s', f[-1])
        if len(f) / 2 < (c.get('min') or 0):
            return more('FLOW PRESSURE')
    elif rest == 'copies':
        if not f:
            return more('NAME START END')
        if len(f) % 3:
            return more('%s', 'START END' if len(f) % 3 == 1 else 'END')
        for i in range(len(f)):
            err = check_field('node' if i % 3 else 'new', f[i], {'pos': [], 'opt': []},
                              'NODE' if i % 3 else 'NAME')
            if err is not None:
                return bad('%s', err)
    elif rest == 'outlets':
        if not f:
            return more('OUTLET')
        for t in f:
            err = check_field('node', t, a, 'OUTLET')
            if err is not None:
                return bad('%s', err)
    elif rest == 'names':
        if not f:
            return more('NAME')
        for t in f:
            err = check_field('new', t, {'pos': [], 'opt': []}, 'NAME')
            if err is not None:
                return bad('%s', err)
    elif rest == 'dpvloss':
        # A dry pipe valve's loss: nothing (refused when the model is
        # validated, never assumed), EQL and one length, VALVE and a make and
        # model from the database, or flow/loss pairs.
        if f and f[0].upper() == 'VALVE':
            if len(f) == 1:
                return more('THE MAKER AND MODEL, FROM THE DATABASE')
            if len(f) == 2:
                return more('THE MODEL')
            if len(f) > 3:
                return bad("UNEXPECTED FIELD '%s' AFTER THE MODEL", f[3])
            a['rest'] = ['VALVE', f[1].upper(), f[2].upper()]
        elif f and f[0].upper() == 'EQL':
            if len(f) == 1:
                return more('THE EQUIVALENT LENGTH')
            if len(f) > 2:
                return bad("UNEXPECTED FIELD '%s' AFTER THE EQUIVALENT LENGTH", f[2])
            m = length_metres(f[1], 'M')
            if m is None:
                return bad("EQL '%s' IS NOT A LENGTH", f[1])
            if m <= 0:
                return bad('AN EQUIVALENT LENGTH MUST BE MORE THAN 0')
            a['rest'] = ['EQL', f[1]]
        else:
            for t in f:
                if not is_num(t):
                    return bad("'%s' IS NOT A NUMBER: GIVE FLOW LOSS PAIRS, OR EQL AND A LENGTH", t)
                if float(t) < 0:
                    return bad('FLOWS AND LOSSES CANNOT BE NEGATIVE')
            if len(f) % 2:
                return more('THE LOSS TO PAIR WITH FLOW %s', f[-1])
    elif rest == 'shares':
        if len(f) % 2:
            return more('THE PERCENT FOR SUPPLY %s', f[-1])
        for i in range(len(f)):
            if i % 2:
                if not is_num(f[i]):
                    return bad("PERCENT '%s' IS NOT A NUMBER", f[i])
                if float(f[i]) < 0 or float(f[i]) > 100:
                    return bad('A SUPPLY RUNS AT 0 (OUT OF SERVICE) TO 100 PERCENT OF ITS PRESSURE')
            else:
                err = check_field('node', f[i], {'pos': [], 'opt': []}, 'SUPPLY')
                if err is not None:
                    return bad('%s', err)
    elif f:
        return bad("UNEXPECTED FIELD '%s'", f[0])
    return a

#------------------------------------------------------------------------------
# check_field -- one field checked for its type.  The value (normalised where
# it is a keyword) is pushed onto pos, or opt for an optional field.
#------------------------------------------------------------------------------
def check_field(type_, v, a, label, optional=0):
    def push(x):
        (a['opt'] if optional else a['pos']).append(x)
        return None
    isnum = is_num(v)
    if type_ in ('new', 'node', 'pipe'):
        if v.upper() == 'END':
            return 'END CANNOT BE A NAME'
        if type_ == 'new' and '~' in v:
            return "'~' IS RESERVED FOR NAMES PHCP MAKES ITSELF"
        return push(v)
    if type_ in ('length', 'elev'):
        m = length_metres(v, 'M')
        if m is None:
            return "%s '%s' IS NOT A LENGTH" % (label, v)
        if type_ == 'length' and m < 0:
            return '%s CANNOT BE NEGATIVE' % label
        return push(v)
    if type_ in ('size', 'num', 'pressure', 'flow', 'kfactor', 'minflow'):
        if not isnum:
            return "%s '%s' IS NOT A NUMBER" % (label, v)
        if float(v) < 0 and type_ != 'minflow':
            return '%s CANNOT BE NEGATIVE' % label
        return push(v)
    if type_ == 'ratio':
        r = ratio_value(v)
        if r is None:
            return "RATIO '%s' IS NOT A RATIO: WRITE IT 3:1 OR 1.5" % v
        if r <= 1:
            return 'A PRESSURE RATIO VALVE REDUCES PRESSURE: ITS RATIO MUST BE MORE THAN 1'
        return push(v)
    if type_ == 'tripmode':
        m = v.upper()
        if m not in ('RATIO', 'TRIP'):
            return 'THE TRIP IS SET BY RATIO (DIFFERENTIAL, WATER TO AIR) OR TRIP (AIR-SIDE TRIP PRESSURE)'
        return push(m)
    if type_ == 'tripvalue':
        if (a['pos'][-1] if a['pos'] else '') == 'RATIO':
            r = ratio_value(v)
            if r is None:
                return "RATIO '%s' IS NOT A RATIO: WRITE IT 5.5:1 OR 5.5" % v
            if r <= 1:
                return 'A DIFFERENTIAL TRIP RATIO MUST BE MORE THAN 1:1'
            return push(v)
        if not isnum:
            return "TRIP PRESSURE '%s' IS NOT A NUMBER" % v
        if float(v) <= 0:
            return 'AN AIR-SIDE TRIP PRESSURE MUST BE MORE THAN 0'
        return push(v)
    if type_ == 'temp':
        if not isnum:
            return "%s '%s' IS NOT A NUMBER" % (label, v)
        if float(v) < -50 or float(v) > 60:
            return '%s: AN AIR TEMPERATURE OF %s C IS OUTSIDE -50 TO 60 C' % (label, v)
        return push(v)
    if type_ == 'onoff':
        m = v.upper()
        if m not in ('ON', 'OFF'):
            return 'THE ACCELERATOR IS ON OR OFF'
        return push(m)
    if type_ == 'field':
        return push(v.upper())
    if type_ == 'quantity':
        q = v.upper()
        if q not in UNIT_CHOICES:
            return 'UNKNOWN UNITS QUANTITY %s (%s)' % (v, ' '.join(UNIT_QUANTITIES))
        return push(q)
    if type_ == 'unit':
        q = a['pos'][0]
        u = unit_code(v)
        if u not in UNIT_CHOICES[q]:
            return 'UNKNOWN UNIT %s FOR %s (%s)' % (v, q, ' '.join(UNIT_CHOICES[q]))
        return push(u)
    if type_ == 'method':
        m = v.upper()
        if m == 'HAZEN':
            m = 'HW'
        if m == 'DARCY':
            m = 'DW'
        if m not in ('HW', 'DW'):
            return 'METHOD IS HW (HAZEN-WILLIAMS) OR DW (DARCY-WEISBACH)'
        return push(m)
    if type_ == 'option':
        o = v.upper()
        if o == 'METHOD':
            return 'METHOD HAS A COMMAND OF ITS OWN: METHOD HW OR METHOD DW'
        if o not in OPTION:
            return 'UNKNOWN OPTION %s (%s)' % (v, ' '.join(OPTIONS))
        return push(o)
    if type_ == 'value':
        o = a['pos'][0]
        # An area's name keeps its case, as every other name does.
        if o == 'DESIGN_AREA':
            return push(v)
        if o == 'SIZING_GOAL':
            g = v.upper()
            if g not in ('SMALLEST', 'VOLUME'):
                return 'SIZING_GOAL IS SMALLEST (THE SMALLEST PIPES) OR VOLUME (THE LEAST WATER IN THE PIPES)'
            return push(g)
        if o == 'VELOCITY_PRESSURE':
            g = v.upper()
            if g not in ('ON', 'OFF'):
                return 'VELOCITY_PRESSURE IS ON (SPRINKLERS DISCHARGE ON NORMAL PRESSURE) OR OFF (TOTAL PRESSURE)'
            return push(g)
        if o == 'SUPPLY_SCENARIOS':
            g = v.upper()
            if g not in ('ON', 'OFF'):
                return 'SUPPLY_SCENARIOS IS ON (EACH SUPPLY ALONE AND EACH OUT OF SERVICE) OR OFF'
            return push(g)
        if o == 'JOINT_BASIS':
            g = v.upper()
            if g not in ('DERATE', 'SCALE'):
                return 'JOINT_BASIS IS DERATE (EVERY SUPPLY LOWERED BY ONE PRESSURE) OR SCALE (BY ONE FACTOR)'
            return push(g)
        if o == 'SIZING_TRIALS':
            if not (re.match(r'^\d+$', v) and 1 <= float(v) <= 50):
                return "SIZING_TRIALS '%s' IS A WHOLE NUMBER OF TRIALS, 1 TO 50" % v
            return push(v)
        if o == 'SIZING_MARGIN':
            m = re.match(r'^(\d+(?:\.\d+)?|\.\d+)%$', v)
            if not ((m and float(m.group(1)) < 100) or (isnum and float(v) >= 0)):
                return "SIZING_MARGIN '%s' IS A PERCENTAGE OF THE SUPPLY (10%%) OR A PRESSURE (50)" % v
            return push(v)
        if o in NUM_OPTION:
            if not isnum:
                return "%s VALUE '%s' IS NOT A NUMBER" % (o, v)
            return push(v)
        return push(v.upper())
    if type_ == 'pipetype':
        p = v.upper()
        if p != 'BORE':
            ensure_db()
            if not pipedata.pipe_type(p):
                return ('UNKNOWN PIPE TYPE %s (THE PIPE DATABASE LISTS %s; BORE FOR A PIPE GIVEN BY ITS BORE)'
                        % (v, ' '.join(pipedata.pipe_types())))
        return push(p)
    if type_ == 'text':
        return push(v)
    raise RuntimeError('check_field: unknown type %s' % type_)

#==============================================================================
# What a line names.
#==============================================================================

def nodes_used(a):
    c = command_spec(a.get('key') or '')
    if c is None:
        return []
    fixed = c['fixed']
    n = [a['pos'][i] for i in range(len(fixed)) if fixed[i][1] == 'node']
    if a.get('key') == 'AREA':
        n += a['rest']
    if a.get('key') == 'SCENARIO':
        r = a['rest']
        n += [r[i] for i in range(len(r)) if i % 2 == 0]
    if a.get('key') == 'PC':
        r = a['rest']
        n += [r[i + 1] for i in range(len(r)) if i % 3 == 0 and i + 2 <= len(r) - 1]
        n += [r[i + 2] for i in range(len(r)) if i % 3 == 0 and i + 2 <= len(r) - 1]
    return [x for x in n if x is not None]

def nodes_defined(a):
    k = a.get('key') or ''
    if k == 'NC':
        return list(a['rest'])
    c = command_spec(k)
    if c is None:
        return []
    return [a['pos'][0]] if c['kind'] == 'node' else []

def names_defined(a):
    k = a.get('key') or ''
    if k in ('PIPE', 'FIXEDFLOW', 'PUMP'):
        return [a['pos'][0]]
    if k == 'PC':
        r = a['rest']
        return [r[i] for i in range(len(r)) if i % 3 == 0]
    return []

def setting_keys(a):
    k = a.get('key') or ''
    if k == 'TITLE':
        return 'TITLE'
    if k == 'PROJECT':
        return 'PROJECT %s' % a['pos'][0]
    if k == 'UNITS':
        return 'UNITS %s' % a['pos'][0]
    if k == 'METHOD':
        return 'METHOD'
    if k == 'OPTION':
        return 'OPTION %s' % a['pos'][0]
    return None

#==============================================================================
# translate -- .phc text to the rows the network is built from.
#==============================================================================

def translate(text):
    text = '' if text is None else text
    lines = text.split('\n')

    def at(n, msg, *args):
        fail('line %d: %s', n, msg % args if args else msg)

    #---------------------------------------------------- read every line
    rows = []
    for n in range(1, len(lines) + 1):
        a = analyse(lines[n - 1])
        if a['status'] == 'blank':
            continue
        if a['status'] == 'incomplete':
            at(n, '%s NEEDS %s', a['key'], a['msg'])
        if a['status'] != 'ok':
            at(n, '%s', a['msg'])
        rows.append([n, a])
    kind = lambda a: command_spec(a['key'])['kind']

    #---------------------------------------------------- settings, file-wide
    seen = {}
    project = []
    options = []
    method = None
    design = None
    sizing = {}
    units = dict(UNIT_DEFAULT)
    for (n, a) in [r for r in rows if kind(r[1]) == 'setting']:
        k = setting_keys(a)
        if k:
            if k in seen:
                at(n, '%s IS ALREADY SET ON LINE %d', k, seen[k])
            seen[k] = n
        k = a['key']
        p = a['pos']
        if k == 'TITLE':
            project.append(['TITLE %s' % a['text'], n])
        if k == 'PROJECT':
            project.append(['%s %s' % (p[0], a['text']), n])
        if k == 'UNITS':
            units[p[0]] = p[1]
        if k == 'METHOD':
            method = [p[0], n]
        if k == 'OPTION':
            if not re.match(r'^(DESIGN_AREA|SIZING_\w+)$', p[0]):
                options.append(['%s %s' % (p[0], p[1]), n])
            if re.match(r'^SIZING_', p[0]):
                sizing[p[0]] = p[1]
            if p[0] == 'DESIGN_AREA':
                design = [p[1], n]
    dw = method is not None and method[0] == 'DW'

    #---------------------------------------------------- definitions
    node = {}
    node_order = []
    pipe = {}
    name_line = {}
    change = {}
    eqv = {}
    device = {}
    items = []
    duty = {}
    area = {}
    area_order = []
    graphs = []
    dpvdata = {}
    scenario = {}
    scenario_order = []
    nrv = {}
    use = {'type': 'BORE'}

    def define_node(name, n, d):
        if name in node:
            at(n, 'NODE %s IS ALREADY DEFINED ON LINE %d', name, node[name]['line'])
        node[name] = dict(d)
        node[name]['line'] = n
        node_order.append(name)

    def define_name(name, n):
        if name in name_line:
            at(n, 'THE NAME %s IS ALREADY USED ON LINE %d', name, name_line[name])
        name_line[name] = n

    def once(tbl, name, n, what):
        if name in tbl:
            at(n, 'PIPE %s ALREADY HAS %s, ON LINE %d', name, what, tbl[name]['line'])

    for (n, a) in [r for r in rows if kind(r[1]) != 'setting']:
        k = a['key']
        p = a['pos']
        if k == 'USE':
            use = {'type': p[0], 'c': a['opt'][0] if a['opt'] else None, 'line': n}
        elif k == 'PIPE':
            define_name(p[0], n)
            pipe[p[0]] = {'line': n, 'use': use, 'start': p[1], 'end': p[2],
                          'len': p[3], 'size': p[4], 'fits': list(a['rest'])}
            items.append(['PIPE', p[0], n])
        elif k == 'PC':
            r = list(a['rest'])
            while r:
                name, s, e = r[0], r[1], r[2]
                r = r[3:]
                define_name(name, n)
                pipe[name] = {'line': n, 'copy_of': p[0], 'start': s, 'end': e}
                items.append(['PIPE', name, n])
        elif k == 'CHANGEPIPE':
            once(change, p[0], n, 'A CHANGEPIPE')
            change[p[0]] = {'line': n, 'len': p[1], 'size': p[2], 'fits': list(a['rest'])}
        elif k == 'EQV':
            once(eqv, p[0], n, 'AN EQV')
            eqv[p[0]] = {'line': n, 'len': p[1]}
        elif k == 'NODE':
            define_node(p[0], n, {'kind': 'NODE', 'z': p[1]})
        elif k == 'WATER':
            define_node(p[0], n, {'kind': 'WATER', 'z': p[1], 'static': p[2],
                                  'pairs': list(a['rest'])})
            items.append(['SUPPLY', p[0], n])
        elif command_spec(k).get('otype'):
            define_node(p[0], n, {'kind': k, 'z': p[1], 'minflow': p[2], 'k': p[3]})
            items.append(['OUTLET', p[0], n])
        elif k == 'NC':
            for name in a['rest']:
                define_node(name, n, {'kind': 'COPY', 'source': p[0]})
                items.append(['COPY', name, n])
        elif k in ('FIXEDFLOW', 'PUMP'):
            define_name(p[0], n)
            items.append([k, p[0], n, a])
        elif k == 'SUPPLYGRAPH':
            graphs.append([a['text'], n])
        elif k == 'AREA':
            if p[0] not in area:
                area_order.append(p[0])
            if p[0] not in area:
                area[p[0]] = {'name': p[0], 'line': n, 'outlets': [], 'lines': []}
            ar = area[p[0]]
            ar['lines'].append(n)
            for o in a['rest']:
                ar['outlets'].append([o, n])
        elif k == 'PUMPDUTY':
            if p[0] in duty:
                at(n, 'PUMP %s ALREADY HAS A DUTY, ON LINE %d', p[0], duty[p[0]]['line'])
            duty[p[0]] = {'line': n, 'q': p[1], 'p': p[2]}
        elif k in ('DPVMODEL', 'DPVAIR', 'DPVTRIP'):
            slot = {'DPVMODEL': 'model', 'DPVAIR': 'air', 'DPVTRIP': 'trip'}[k]
            d = dpvdata.setdefault(p[0], {})
            if d.get(slot):
                at(n, 'PIPE %s ALREADY HAS A %s, ON LINE %d', p[0], k, d.get(slot + '_line'))
            if k == 'DPVTRIP' and len(a['opt']) > 0 and a['opt'][0] is not None \
                    and (not re.match(r'^\d+$', a['opt'][0]) or float(a['opt'][0]) < 1):
                at(n, 'DPVTRIP %s: THE NUMBER OF OPEN SPRINKLERS IS A WHOLE NUMBER, 1 OR MORE', p[0])
            if k == 'DPVTRIP' and float(p[1]) <= 0:
                at(n, 'DPVTRIP %s: THE ORIFICE MUST BE MORE THAN 0', p[0])
            if k == 'DPVMODEL':
                d[slot] = a['text']
            elif k == 'DPVAIR':
                d[slot] = p[1]
            else:
                d[slot] = {'orifice_mm': size_mm(p[1], units['SIZE']),
                           'count': a['opt'][0] if len(a['opt']) > 0 else None,
                           'temp': a['opt'][1] if len(a['opt']) > 1 else None,
                           'static': a['opt'][2] if len(a['opt']) > 2 else None}
            d[slot + '_line'] = n
        elif k in ('NRV', 'NRVMODEL', 'NRVLOSS'):
            slot = {'NRV': 'valve', 'NRVMODEL': 'model', 'NRVLOSS': 'loss'}[k]
            v = nrv.setdefault(p[0], {})
            if v.get(slot):
                at(n, 'SUPPLY %s ALREADY HAS A %s, ON LINE %d', p[0], k, v.get(slot + '_line'))
            if k == 'NRV':
                v[slot] = {'cv': p[1], 'crack': a['opt'][0] if a['opt'] else None}
            elif k == 'NRVMODEL':
                v[slot] = a['text']
            else:
                v[slot] = list(a['rest'])
            v[slot + '_line'] = n
        elif k == 'SCENARIO':
            if p[0] in scenario:
                at(n, 'SCENARIO %s IS ALREADY DEFINED ON LINE %d', p[0], scenario[p[0]]['line'])
            share = [[p[1], p[2]]]
            r = list(a['rest'])
            while r:
                share.append([r[0], r[1]])
                r = r[2:]
            scenario[p[0]] = {'name': p[0], 'line': n, 'shares': share}
            scenario_order.append(p[0])
        elif command_spec(k)['kind'] == 'device':
            if p[0] in device:
                at(n, 'PIPE %s ALREADY HAS A DEVICE, %s ON LINE %d', p[0],
                   device[p[0]]['key'], device[p[0]]['line'])
            device[p[0]] = {'line': n, 'key': k, 'a': a}
            items.append(['DEVICE', p[0], n])

    #---------------------------------------------------- resolve copies
    for name in [k for k in pipe if 'copy_of' in pipe[k]]:
        p = pipe[name]
        trail = {}
        src = p['copy_of']
        while True:
            s = pipe.get(src)
            if s is None:
                at(p['line'], 'PIPE %s, COPIED AS %s, IS NOT DEFINED', src, name)
            if src in trail:
                at(p['line'], 'PIPE %s IS COPIED FROM ITSELF', name)
            trail[src] = 1
            if 'copy_of' not in s:
                for key_ in ('use', 'len', 'size', 'fits'):
                    p[key_] = s[key_]
                p['root'] = src
                break
            src = s['copy_of']
    for name in [k for k in node if node[k]['kind'] == 'COPY']:
        c = node[name]
        trail = {}
        src = c['source']
        while True:
            s = node.get(src)
            if s is None:
                at(c['line'], 'NODE %s, COPIED AS %s, IS NOT DEFINED', src, name)
            if src in trail:
                at(c['line'], 'NODE %s IS COPIED FROM ITSELF', name)
            trail[src] = 1
            if s['kind'] != 'COPY':
                line = c['line']
                c.clear()
                c.update(s)
                c['line'] = line
                break
            src = s['source']
    # CHANGEPIPE applies after copying: a copy keeps its source's original.
    for pname in change:
        if pname not in pipe:
            at(change[pname]['line'], 'PIPE %s IS NOT DEFINED', pname)
        p = pipe[pname]
        for key_ in ('len', 'size', 'fits'):
            p[key_] = change[pname][key_]
    for tbl in (eqv, device):
        for pname in tbl:
            if pname not in pipe:
                at(tbl[pname]['line'], 'PIPE %s IS NOT DEFINED', pname)

    #---------------------------------------------------- every node defined
    first_use = {}
    used = []

    def need(name, n):
        if name in node or name in first_use:
            return
        first_use[name] = n
        used.append(name)

    for it in items:
        what, name, n = it[0], it[1], it[2]
        a = it[3] if len(it) > 3 else None
        if what == 'PIPE':
            need(pipe[name]['start'], n)
            need(pipe[name]['end'], n)
        if what == 'FIXEDFLOW':
            need(a['pos'][1], n)
        if what == 'PUMP':
            need(a['pos'][1], n)
            need(a['pos'][2], n)
    if used:
        used = sorted(used, key=lambda x: first_use[x])
        id_ = used.pop(0)
        at(first_use[id_], 'NODE %s IS NOT DEFINED%s', id_,
           (' (ALSO ' + ', '.join('%s ON LINE %d' % (x, first_use[x]) for x in used) + ')')
           if used else '')

    #---------------------------------------------------- design areas
    in_area = {}
    for name in area_order:
        once_ = {}
        ar = area[name]
        kept = []
        for (o, ln) in ar['outlets']:
            if o not in node:
                at(ln, 'AREA %s: %s IS NOT DEFINED', name, o)
            d = node[o]
            if not command_spec(d['kind']).get('otype'):
                at(ln, 'AREA %s: %s IS NOT AN OUTLET (SPRINKLER, HYDRANT OR HREEL)', name, o)
            if not once_.get(o):
                once_[o] = 1
                kept.append(o)
        ar['outlets'] = kept
        for o in kept:
            in_area[o] = 1
    open_ = {}
    if design:
        want, ln = design
        if want not in area:
            at(ln, 'DESIGN_AREA %s: NO AREA OF THAT NAME%s', want,
               (' (' + ' '.join(area_order) + ')') if area_order else ' - THE MODEL HAS NO AREA')
        open_ = {o: 1 for o in area[want]['outlets']}
    def shut(name):
        return bool(design) and name in in_area and name not in open_

    #---------------------------------------------------- dry pipe valve data
    for pname in sorted(dpvdata):
        d = dpvdata[pname]
        ln = d.get('model_line') or d.get('air_line') or d.get('trip_line')
        if not (pname in device and device[pname]['key'] == 'DPV'):
            at(ln, 'PIPE %s HAS NO DRY PIPE VALVE (DPV) FOR THIS TO DESCRIBE', pname)

    #---------------------------------------------------- supply scenarios
    def is_water(name):
        d = node.get(name)
        for _ in range(50):
            if not (d and d['kind'] == 'COPY'):
                break
            d = node.get(d['source'])
        return bool(d and d['kind'] == 'WATER')

    nsup = sum(1 for k in node if is_water(k))
    if scenario_order and nsup < 2:
        at(scenario[scenario_order[0]]['line'],
           'SCENARIO NEEDS MORE THAN ONE WATER SUPPLY: THE MODEL HAS %d', nsup)
    for name in scenario_order:
        sc = scenario[name]
        once_ = {}
        for s in sc['shares']:
            d = node.get(s[0])
            if d is None:
                at(sc['line'], 'SCENARIO %s: %s IS NOT DEFINED', name, s[0])
            src = d
            for _ in range(50):
                if not (src and src['kind'] == 'COPY'):
                    break
                src = node.get(src['source'])
                if src is None:
                    break
            if not (src and src['kind'] == 'WATER'):
                at(sc['line'], 'SCENARIO %s: %s IS NOT A WATER SUPPLY', name, s[0])
            if once_.get(s[0]):
                at(sc['line'], 'SCENARIO %s NAMES %s TWICE', name, s[0])
            once_[s[0]] = 1
            if float(s[1]) < 0 or float(s[1]) > 100:
                at(sc['line'], 'SCENARIO %s: A SUPPLY RUNS AT 0 (OUT OF SERVICE) TO 100 PERCENT OF ITS PRESSURE, '
                     'NOT %s', name, s[1])

    #---------------------------------------------------- supply check valves
    for sname in sorted(nrv):
        v = nrv[sname]
        ln = v.get('valve_line') or v.get('model_line') or v.get('loss_line')
        if sname not in node:
            at(ln, '%s IS NOT DEFINED', sname)
        if not is_water(sname):
            at(ln, '%s IS NOT A WATER SUPPLY: A CHECK VALVE (NRV) GOES AT A WATER SUPPLY', sname)
        if not v.get('valve'):
            at(ln, 'SUPPLY %s HAS NO CHECK VALVE (NRV) FOR THIS TO DESCRIBE', sname)
        if not v.get('loss'):
            continue
        if float(v['valve']['cv']) != 0:
            at(v['loss_line'], 'NRVLOSS %s REQUIRES CV 0 (DO NOT COUNT LOSSES TWICE)', sname)
        if not v.get('model'):
            at(v['loss_line'], 'NRVLOSS %s REQUIRES NRVMODEL WITH MANUFACTURER DATA SOURCE', sname)
        pairs = v['loss']
        if float(pairs[0]) != 0 or float(pairs[1]) != 0:
            at(v['loss_line'], 'NRVLOSS %s MUST BEGIN WITH FLOW 0 LOSS 0', sname)
        for i in range(2, len(pairs), 2):
            if float(pairs[i]) <= float(pairs[i - 2]):
                at(v['loss_line'], 'NRVLOSS %s: FLOWS MUST STRICTLY INCREASE', sname)
            if float(pairs[i + 1]) < float(pairs[i - 1]):
                at(v['loss_line'], 'NRVLOSS %s: LOSSES MUST NOT DECREASE WITH FLOW', sname)

    #---------------------------------------------------- auto sizing
    auto = []
    for name in sorted(pipe, key=lambda k: (pipe[k]['line'], k)):
        p = pipe[name]
        if not (is_num(p['size']) and float(p['size']) == 0):
            continue
        type_ = (p.get('use') or {}).get('type') or 'BORE'
        if type_ == 'BORE':
            at(p['line'], 'PIPE %s: SIZE 0 ASKS FOR THE PIPE TO BE SIZED, WHICH NEEDS A PIPE TYPE - PUT A USE '
                 '<PIPETYPE> LINE BEFORE IT', name)
        if name in change:
            line, field = change[name]['line'], 3
        elif 'copy_of' in p:
            line, field = pipe[p['root']]['line'], 5
        else:
            line, field = p['line'], 5
        u = next((x for x in auto if x['line'] == line), None)
        if u is None:
            from . import sizing as _sizing
            ch = _sizing.choices(type_, p['fits'], units['SIZE'])
            if not ch:
                at(line, 'PIPE %s: NO SIZE OF %s HAS ALL ITS FITTINGS IN THE DATABASE%s, SO IT CANNOT BE SIZED',
                   name, type_, ' AND A NOMINAL SIZE IN INCHES' if units['SIZE'] == 'IN' else '')
            u = {'line': line, 'field': field, 'type': type_, 'choices': ch,
                 'kind': 'CHANGEPIPE' if field == 3 else 'PIPE', 'pipes': [], 'lines': {}}
            auto.append(u)
        u['pipes'].append(name)
        if name not in change:
            u['lines'][p['line']] = 1
        u['lines'][line] = 1
        p['auto_dn'] = u['choices'][0][0]

    #---------------------------------------------------- the rows
    nodes_out = []
    def z(name):
        return fmt(length_metres(node[name]['z'], units['ELEVATION']))
    for name in node_order:
        nodes_out.append(['%s %s' % (name, z(name)), node[name]['line']])
    # A device in a pipe splits the pipe at its start.
    for pname in sorted(device, key=lambda k: device[k]['line']):
        nodes_out.append(['%s~ %s' % (pname, z(pipe[pname]['start'])), device[pname]['line']])
    elems = []
    for it in items:
        what, name, n = it[0], it[1], it[2]
        a = it[3] if len(it) > 3 else None
        d = node.get(name)
        if what == 'PIPE':
            elems.append(['PIPES', pipe_row(pipe[name], name,
                                            '%s~' % name if name in device else None,
                                            eqv.get(name), units, dw, at), n])
        elif what in ('SUPPLY', 'COPY') and d['kind'] == 'WATER':
            pairs = d['pairs']
            elems.append(['SUPPLIES',
                          ' '.join([name, name, 'CURVE', '0', d['static']] + pairs)
                          if pairs else
                          ' '.join([name, name, 'STATIC', d['static']]), n])
        elif what in ('OUTLET', 'COPY') and command_spec(d['kind']).get('otype'):
            # A K of zero turns the outlet off: the node stays, discharging
            # nothing.  So does a design area that does not include it.
            if float(d['k']) == 0:
                continue
            if shut(name):
                continue
            kk = fmt(k_factor_to_model(float(d['k']), units))
            # MINFLOW is the least flow the outlet must give; below zero it
            # is the least PRESSURE instead.
            req = ('P=' + pnum(-float(d['minflow']))) if float(d['minflow']) < 0 \
                else ('Q=%s' % d['minflow'])
            elems.append(['DISCHARGES',
                          '%s %s %s K=%s %s' % (name, name, command_spec(d['kind'])['otype'], kk, req), n])
        elif what == 'FIXEDFLOW':
            p = a['pos']
            row = ' '.join([p[0], p[1], 'FIXEDFLOW', 'Q=%s' % p[2]] +
                           (['MINP=%s' % a['opt'][0]] if a['opt'] else []))
            elems.append(['DISCHARGES', row, n])
        elif what == 'PUMP':
            p = a['pos']
            elems.append(['PUMPS', ' '.join([p[0], p[1], p[2], '0', p[3]] + a['rest']), n])
        elif what == 'DEVICE':
            elems.append(list(device_row(device[name], pipe[name], name, units, at)))

    #---------------------------------------------------- pump duties
    duty_rows = []
    pump = {it[1]: 1 for it in items if it[0] == 'PUMP'}
    for name in sorted(duty, key=lambda k: duty[k]['line']):
        d = duty[name]
        if name in pump:
            id_ = name
        elif name in device and device[name]['key'] == 'BP':
            id_ = name + '.BP'
        else:
            at(d['line'], 'PUMPDUTY %s: NO PUMP OF THAT NAME, AND NO PIPE WITH A BOOSTER (BP) IN IT', name)
            continue
        duty_rows.append(['OPTIONS', 'PUMPDUTY %s %s %s' % (id_, d['q'], d['p']), d['line']])

    #---------------------------------------------------- in order
    built = ([['PROJECT', x[0], x[1]] for x in project]
             + [['UNITS', 'FLOW %s' % units['FLOW'], seen.get('UNITS FLOW')],
                ['UNITS', 'PRESSURE %s' % units['PRESSURE'], seen.get('UNITS PRESSURE')],
                ['UNITS', 'LENGTH M', None], ['UNITS', 'DIAMETER MM', None]]
             + ([['OPTIONS', 'METHOD %s' % method[0], method[1]]] if method else [])
             + [['OPTIONS', x[0], x[1]] for x in options]
             + duty_rows
             + [['NODES', x[0], x[1]] for x in nodes_out]
             + elems)
    areas = {'list': [{'name': x, 'line': area[x]['line'], 'outlets': area[x]['outlets']}
                      for x in area_order],
             'design': design[0] if design else None, 'graphs': graphs,
             'auto': auto, 'sizing': sizing,
             'scenarios': [scenario[x] for x in scenario_order], 'dpvdata': dpvdata,
             'nrv': nrv}
    return (built, units, areas)

#------------------------------------------------------------------------------
# pipe_row -- the PIPES row for one pipe.
#------------------------------------------------------------------------------
def pipe_row(p, name, frm, eqv, units, dw, at):
    n = p['line']
    use = p.get('use') or {'type': 'BORE'}
    row = [name, frm if frm is not None else p['start'], p['end'],
           fmt(length_metres(p['len'], units['LENGTH']))]
    if use['type'] == 'BORE':
        if p['fits']:
            at(n, 'PIPE %s: FITTINGS NEED A PIPE TYPE - PUT A USE <PIPETYPE> LINE BEFORE IT, '
                 'OR GIVE THE ALLOWANCE WITH EQV', name)
        row.append(fmt(size_mm(p['size'], units['SIZE'])))
    else:
        dn = p.get('auto_dn')
        if dn is None:
            dn = size_dn(p['size'], units['SIZE'])
        if dn is None:
            at(n, 'PIPE %s: %s IS NOT A NOMINAL SIZE IN INCHES', name, p['size'])
        row.append(dn)
        row.append('TYPE=%s' % use['type'])
        fit = [fitting_code(x) for x in p['fits']]
        if fit:
            row.append('FIT=' + ','.join(fit))
    if use.get('c') is not None:
        row.append(('EPS=%s' % fmt(size_mm(use['c'], units['SIZE']))) if dw
                   else ('C=%s' % use['c']))
    if eqv:
        row.append('EQV=%s' % fmt(length_metres(eqv['len'], units['LENGTH'])))
    return ' '.join(str(x) for x in row)

def fitting_code(t):
    m = re.match(r'^(\d*)([A-Z][A-Z0-9]*)$', t.upper())
    count, code = m.group(1), m.group(2)
    return count + (FIT_SHORT.get(code, code))

#------------------------------------------------------------------------------
# device_row -- (block, row, line) for a device in a pipe.
#------------------------------------------------------------------------------
def device_row(d, p, pname, units, at):
    k, a, n = d['key'], d['a'], d['line']
    r = a['rest']
    s, x, id_ = p['start'], '%s~' % pname, '%s.%s' % (pname, k)
    if k == 'BP':
        return ('PUMPS', ' '.join([id_, s, x, '0', a['pos'][1]] + r), n)
    if k in ('BFP', 'PRV'):
        # A single pair at flow zero is a loss that does not vary with flow.
        if len(r) == 2:
            if float(r[0]) != 0:
                at(n, '%s WITH ONE FLOW/LOSS PAIR IS A FIXED LOSS: ITS FLOW MUST BE 0', k)
            if float(r[1]) <= 0:
                at(n, '%s: A FIXED LOSS MUST BE MORE THAN 0', k)
            return ('DEVICES', '%s %s %s PRV DP=%s' % (id_, s, x, r[1]), n)
        return ('DEVICES', ' '.join([id_, s, x, 'BFP'] + r), n)
    if k in ('OPP', 'OFD'):
        # The plate takes its pipe's nominal size and bore.
        dn, bore = pipe_size(p, units)
        where = ((['DN=%s' % dn] if dn is not None else []) + ['PIPEDIA=%s' % fmt(bore)])
        cd = (['CD=%s' % a['opt'][0]] if a['opt'] else [])
        if k == 'OPP':
            return ('DEVICES', ' '.join([id_, s, x, 'ORIFICE_P', 'DP=%s' % a['pos'][1]] + where + cd), n)
        return ('DEVICES', ' '.join([id_, s, x, 'ORIFICE_D',
                                     'BORE=%s' % fmt(size_mm(a['pos'][1], units['SIZE']))] + where + cd), n)
    if k == 'PRA':
        # Outlet pressure = inlet / ratio; the solver sets the drop from the
        # solved inlet pressure.
        mi = a['opt'][0] if len(a['opt']) > 0 else None
        band = a['opt'][1] if len(a['opt']) > 1 else None
        return ('DEVICES', ' '.join([id_, s, x, 'PRA', 'RATIO=%s' % fmt(ratio_value(a['pos'][1]))]
                                    + (['MININLET=%s' % mi] if mi is not None and float(mi) > 0 else [])
                                    + (['BAND=%s' % band] if band is not None else [])), n)
    if k == 'DPV':
        size, mode, set_, acc = a['pos'][1], a['pos'][2], a['pos'][3], a['pos'][4]
        dn = size_dn(size, units['SIZE'])
        if dn is None:
            at(n, 'DPV %s: %s IS NOT A NOMINAL SIZE IN INCHES', pname, size)
        row = [id_, s, x, 'DPV', 'SIZE=%s' % dn, 'MODE=%s' % mode,
               ('RATIO=%s' % fmt(ratio_value(set_))) if mode == 'RATIO' else ('TRIP=%s' % set_),
               'ACC=%s' % acc, 'HOST=%s' % pname]
        if r and r[0] == 'VALVE':
            ensure_db()
            if not pipedata.dry_valve(r[1], r[2], dn):
                have = [m for m in pipedata.dry_valve_models() if m[0] == r[1] and m[1] == r[2]]
                if have:
                    at(n, 'DPV %s: THE DATABASE HAS %s %s IN DN%s ONLY, NOT DN%d',
                       pname, r[1], r[2], ', DN'.join(have[0][2]), dn)
                else:
                    at(n, 'DPV %s: %s %s IS NOT A DRY PIPE VALVE IN THE DATABASE (%s)',
                       pname, r[1], r[2],
                       ', '.join('%s %s' % (m[0], m[1]) for m in pipedata.dry_valve_models()))
            row.append('VALVE=%s/%s' % (r[1], r[2]))
        elif r and r[0] == 'EQL':
            row.append('EQL=%s' % fmt(length_metres(r[1], units['LENGTH'])))
        elif r:
            if len(r) == 2 and float(r[0]) != 0:
                at(n, 'DPV WITH ONE FLOW/LOSS PAIR IS A FIXED LOSS: ITS FLOW MUST BE 0')
            row += (['FIXED=%s' % r[1]] if len(r) == 2 else r)
        return ('DEVICES', ' '.join(str(x) for x in row), n)
    raise RuntimeError('device_row: no translation for %s' % k)

def pipe_size(p, units):
    use = p.get('use') or {'type': 'BORE'}
    if use['type'] == 'BORE':
        return (None, size_mm(p['size'], units['SIZE']))
    dn = p.get('auto_dn')
    if dn is None:
        dn = size_dn(p['size'], units['SIZE'])
    ensure_db()
    b = pipedata.bore(use['type'], dn if dn is not None else 0)
    return (dn, float(b) if b is not None else 0)

#==============================================================================
# read_string / read_model -- a .phc model read into a network.
#==============================================================================

def read_string(text, dir_=None):
    rows, units, areas = translate(text)
    net = new_net()
    for r in rows:
        section, row, n = r[0], r[1], r[2]
        if section == 'PROJECT':
            # A cover-sheet field: the value is the rest of the line as typed.
            parts = row.split(None, 1)
            f = parts[0]
            v = parts[1] if len(parts) > 1 else ''
            v = re.sub(r'[^\x20-\x7E]', '', v)
            v = re.sub(r'\s+$', '', v)
            net.setdefault('project', {})[f.upper()] = v
            continue
        try:
            parse_row(net, section, tokenize(row))
        except ModelError as e:
            if n is not None:
                fail('line %d: %s', n, e.msg.upper())
            fail('%s', e.msg.upper())
    if len(net['nodes']) <= 2 and len(net['elems']) <= 1:
        fail('THE FILE HOLDS NO MODEL: NO NODES AND NO PIPES')
    net['source_text'] = text
    net['phc_text'] = text
    net['phc_units'] = units
    if areas['list']:
        net['areas'] = areas['list']
    net['design_area'] = areas['design']
    if areas['scenarios']:
        net['scenarios'] = areas['scenarios']
    # The make, model and set air pressure of each dry pipe valve.
    for pname, d in areas['dpvdata'].items():
        e = next((x for x in net['elems'][1:] if x['id'] == '%s.DPV' % pname), None)
        if e is None:
            continue
        if d.get('model') is not None:
            e['model'] = d['model']
        if d.get('air') is not None:
            e['transient']['air_initial'] = float(d['air']) * net['f_pres']
        t = d.get('trip')
        if t:
            e['transient']['orifice_mm'] = t['orifice_mm']
            if t.get('count') is not None:
                e['transient']['open_count'] = t['count']
            if t.get('temp') is not None:
                e['transient']['air_temp_c'] = t['temp']
            if t.get('static') is not None:
                e['transient']['static_water'] = float(t['static']) * net['f_pres']
    # The check valve of each supply that has one, on the supply itself.
    for sname, d in areas['nrv'].items():
        e = next((x for x in net['elems'][1:]
                  if x['id'] == sname and x['kind'].startswith('SUPPLY_')), None)
        if e is None:
            continue
        crack = d['valve'].get('crack')
        e['nrv'] = {'cv': float(d['valve']['cv']),
                    'crack': float(crack) * net['f_pres'] if crack is not None else 0,
                    'crack_given': 1 if crack is not None else 0,
                    'model': d.get('model'),
                    'basis': 'CURVE' if d.get('loss') else ('CV' if float(d['valve']['cv']) > 0 else 'PIPEWORK')}
        pairs = d.get('loss')
        if pairs:
            c = {'q': [], 'p': []}
            for i in range(0, len(pairs), 2):
                c['q'].append(float(pairs[i]) * net['f_flow'])
                c['p'].append(float(pairs[i + 1]) * net['f_pres'])
            e['nrv']['curve'] = fit_curve(c, 1)
    # Pipes to be sized (size 0) and how.
    if areas['auto']:
        net['auto_sizing'] = areas['auto']
    net['sizing_opts'] = areas['sizing']
    # The supply graph sheets (SUPPLYGRAPH), read from the model's folder.
    if dir_ is not None:
        net['model_dir'] = dir_
        _graph = None
        for (f, n) in areas['graphs']:
            if _graph is None:
                from . import graph as _graph
            p = f if os.path.isabs(f) else os.path.join(dir_, f)
            try:
                g = _graph.read_file(p)
                why = '; '.join(x[1] for x in _graph.check(g)['errors'])
            except Exception as e:
                g = None
                why = str(e)
            why = re.sub(r'\s+$', '', why or '')
            if len(why):
                net.setdefault('warnings', []).append(
                    'supply graph %s (line %d) is not in the report: %s' % (f, n, why))
            else:
                net.setdefault('graph_sheets', []).append(
                    {'file': f, 'path': p, 'line': n, 'graph': g})
    # An assumed roughness is flagged wherever the warnings go.
    net.setdefault('warnings', [])
    net['warnings'] += roughness_warning(net)
    from . import pumpcheck
    net['warnings'] += pumpcheck.warnings(net)
    return net

def model_text(raw):
    # The model's bytes as the Perl read them: no decoding layer, so every
    # byte comes through (a Latin-1 file is not refused), and on Windows the
    # :crlf layer's CRLF to LF, nothing else (a lone CR is kept).  The bytes
    # are carried as UTF-8 with surrogateescape, so they are written back,
    # and hashed (results.fingerprint), exactly as they were read.
    if os.name == 'nt':
        raw = raw.replace(b'\r\n', b'\n')
    return raw.decode('utf-8', 'surrogateescape')

def read_model(path):
    try:
        with open(path, 'rb') as fh:
            text = model_text(fh.read())
    except OSError:
        fail('cannot open input file %s', path)
    return read_string(text, os.path.dirname(path))

# The fitting pick lists, read once from the database file and cleared by
# reset_db_cache after it is edited: FIT => { source => { code => label } },
# KPRIME => { code => label }, and each pipe type's DNs, smallest first.
FITCODE = {}
KPCODE = {}
DNS = {}


def fitting_tables():
    if FITCODE:
        return
    ensure_db()
    try:
        fh = open(pipedata.path(), encoding='utf-8')
    except OSError:
        return
    with fh:
        for l in fh:
            l = l.rstrip('\n')
            if re.match(r'^\s*(#|$)', l):
                continue
            f = l.split('|')
            if f[0] == 'FIT':
                FITCODE.setdefault(f[1], {}).setdefault(f[2], _ascii(f[3]))
            elif f[0] == 'KPRIME':
                KPCODE.setdefault(f[1], _ascii(f[2]))
            elif f[0] == 'PIPE':
                DNS.setdefault(f[1], []).append(f[2])
    # DNS entries stay as they are written in the file; the comparisons
    # against a DN numify in the original, so compare as strings here


def reset_db_cache():
    # forget the pick lists, after the database is edited and reloaded
    FITCODE.clear()
    KPCODE.clear()
    DNS.clear()


# pipe_type_choices -- the USE pick list: every type in the database with
# its name, then BORE.
def pipe_type_choices():
    ensure_db()
    out = [[t, _ascii(pipedata.pipe_type(t)['name'])] for t in pipedata.pipe_types()]
    out.append(['BORE', 'PIPES GIVEN BY THEIR BORE, WITH NO PIPE TYPE'])
    return out


# fitting_choices -- the codes a pipe of this type can take at this DN (or
# at any of its sizes when the DN is not known yet), short forms first.
def fitting_choices(type_, dn):
    if type_ is None or type_ == 'BORE':
        return []
    fitting_tables()
    dns = DNS.get(type_) or []
    if dn is not None and str(dn) in dns:
        dns = [str(dn)]
    label = {}
    order = []
    src = {pipedata.governing_source(type_, d)['table'] for d in dns}
    for s in sorted(src):
        tbl = KPCODE if s == 'PPI' else FITCODE.get(s, {})
        for code in sorted(tbl):
            if code not in label:
                order.append(code)
            label.setdefault(code, tbl[code])
    out = []
    for s in sorted(FIT_SHORT):
        if FIT_SHORT[s] in label:
            out.append([s, 'SHORT FOR %s: %s' % (FIT_SHORT[s], label[FIT_SHORT[s]])])
    out += [[code, label[code]] for code in order]
    return out


# step_id -- the next name in a series: P7 -> P8, N09 -> N10, 4101 -> 4102.
def step_id(id_):
    id_ = id_ or ''
    m = re.match(r'^(.*?)(\d+)\Z', id_)
    if m:
        return m.group(1) + ('%0*d' % (len(m.group(2)), int(m.group(2)) + 1))
    return id_ + '2'


# propose -- the likely next line after a complete line.
#
# The same command with its names stepped.  A pipe starts where the last one
# ended, keeps its length and size, and drops its fittings.  Settings, USE and
# the copy and change commands propose nothing.
def propose(line):
    a = analyse(line)
    if a['status'] != 'ok':
        return None
    k = a['key']
    p = list(a['pos'])
    more = list(a['opt']) + list(a['rest'])
    if k == 'PIPE':
        return ' '.join(['PIPE', step_id(p[0]), p[2], step_id(p[2])] + [p[3], p[4]])
    if k in ('NODE', 'WATER', 'SPRINKLER', 'HYDRANT', 'HREEL', 'PUMP') \
            or command_spec(k)['kind'] == 'device':
        return ' '.join([k, step_id(p[0])] + p[1:] + more)
    if k == 'FIXEDFLOW':
        return ' '.join([k, step_id(p[0]), step_id(p[1])] + p[2:] + more)
    return None


# check_line -- one line, checked as it is typed.
#
#   $context  {
#     use     => 'ASAM' or 'BORE', or { type, c }: the USE in force
#     units   => { LENGTH => 'M', ... }: the file's units (defaults otherwise)
#     method  => 'HW' or 'DW'
#     options => { FITTING_BASIS => 'STANDARD' }
#     nodes   => [ names ] or { name => 1 }: the defined nodes
#     cursor  => the cursor's column (default: end of line)
#   }
#
# Returns { status, message, template => { command, text, fields, current },
# choices => [ [code, description] ], proposal, undefined => [ nodes ] }.
#
# A PIPE, outlet, PUMP or WATER line the language accepts is also built as its
# row by the network builder itself, so a DN the pipe type does not make
# or a fitting the database lacks is an error as it is typed -- by the same
# rule and in the same words as when the model is solved.
def check_line(line, ctx=None):
    ctx = ctx or {}
    line = line if line is not None else ''
    cursor = ctx.get('cursor', len(line))
    use = ctx.get('use', 'BORE')
    if not isinstance(use, dict):
        use = {'type': str(use).upper()}
    units = dict(UNIT_DEFAULT)
    units.update(ctx.get('units') or {})

    a = analyse(line, cursor >= len(strip_comment(line)))
    r = {'status': 'ok' if a['status'] == 'blank' else a['status'],
         'message': a.get('msg') or '', 'choices': [], 'proposal': None,
         'undefined': []}
    if a['status'] == 'blank':
        return r
    c = command_spec(a.get('key') or '')
    if c and a['status'] == 'incomplete':
        r['message'] = '%s NEEDS %s' % (c['name'], a['msg'])

    #---------------------------------------------- the cursor's field
    # Words before the cursor; inside or at the end of a word, that word is
    # the current one, otherwise a new one is starting.
    before = strip_comment(line)[:cursor]
    w = before.split()
    idx = len(w) - 1 if re.search(r'\S\Z', before) else len(w)   # 0 is the command
    if c:
        fields = template_fields(c)
        cur = -1 if idx <= 0 else idx - 1
        if cur > len(fields) - 1:
            cur = len(fields) - 1              # text, fittings, pairs run on
        r['template'] = {'command': c['name'], 'text': template_text(c['name']),
                         'fields': fields, 'current': cur}
        label = fields[cur] if cur >= 0 else ''
        q = str(w[1]).upper() if len(w) > 1 else ''
        if c['name'] == 'USE' and cur == 0:
            r['choices'] = pipe_type_choices()
        elif c['name'] in ('PIPE', 'CHANGEPIPE') and label == 'FITTINGS ...':
            i = 4 if c['name'] == 'PIPE' else 2
            sz = a['pos'][i] if i < len(a['pos']) else None
            r['choices'] = fitting_choices(use['type'],
                                           size_dn(sz, units['SIZE']) if sz is not None else None)
        elif c['name'] == 'UNITS' and cur == 0:
            r['choices'] = [[x, ' '.join(UNIT_CHOICES[x])] for x in UNIT_QUANTITIES]
        elif c['name'] == 'UNITS' and cur == 1 and q in UNIT_CHOICES:
            r['choices'] = [[x, 'DEFAULT' if x == UNIT_DEFAULT[q] else '']
                            for x in UNIT_CHOICES[q]]
        elif c['name'] == 'METHOD' and cur == 0:
            r['choices'] = [['HW', 'HAZEN-WILLIAMS'], ['DW', 'DARCY-WEISBACH']]
        elif c['name'] == 'OPTION' and cur == 0:
            r['choices'] = [[x, ''] for x in OPTIONS]
    else:
        r['template'] = {'command': '', 'text': '', 'fields': [], 'current': -1}
    if r['status'] != 'ok':
        return r

    #---------------------------------------------- the parser's verdict
    from . import sizing
    net = new_net()
    try:
        set_unit(net, 'FLOW', units['FLOW'])
        set_unit(net, 'PRESSURE', units['PRESSURE'])
        opts = ctx.get('options') or {}
        for k_ in sorted(x for x in opts if opts[x] is not None):
            parse_row(net, 'OPTIONS', [k_, opts[k_]])

        def at(n, msg, *args):
            fail(msg, *args)
            # the caller's line number is 0 here; the editor owns the real one
        k, p = a['key'], list(a['pos'])
        if k == 'PIPE':
            # SIZE 0: the pipe is to be sized - checked as the reader checks it.
            auto = None
            if is_num(p[4]) and float(p[4]) == 0:
                if (use.get('type') or 'BORE') == 'BORE':
                    fail('SIZE 0 ASKS FOR THE PIPE TO BE SIZED, WHICH NEEDS A PIPE TYPE - '
                                    'PUT A USE <PIPETYPE> LINE BEFORE IT')
                ch = sizing.choices(use['type'], a['rest'], units['SIZE'])
                if not ch:
                    fail('NO SIZE OF %s HAS ALL ITS FITTINGS IN THE DATABASE, '
                                    'SO IT CANNOT BE SIZED', use['type'])
                auto = ch[0][0]
            row = pipe_row({'line': 0, 'use': use, 'start': p[1], 'end': p[2],
                            'auto_dn': auto, 'len': p[3], 'size': p[4], 'fits': a['rest']},
                           p[0], None, None, units, (ctx.get('method') or '') == 'DW', at)
            parse_row(net, 'PIPES', tokenize(row))
        elif c.get('otype') and float(p[3]) != 0:
            req = ('P=' + fmt(-float(p[2]))) if float(p[2]) < 0 else ('Q=%s' % (p[2],))
            parse_row(net, 'DISCHARGES',
                           [p[0], p[0], c['otype'],
                            'K=' + fmt(k_factor_to_model(float(p[3]), units)), req])
        elif k == 'PUMP':
            parse_row(net, 'PUMPS', list(p[0:3]) + ['0', p[3]] + list(a['rest']))
        elif k == 'WATER' and a['rest']:
            parse_row(net, 'SUPPLIES', [p[0], p[0], 'CURVE', '0', p[2]] + list(a['rest']))
    except ModelError as e:
        r['status'], r['message'] = 'error', str(e.msg).upper()
        return r

    #---------------------------------------------- nodes, and what is next
    known = ctx.get('nodes')
    if known:
        k = known if isinstance(known, dict) else {x: 1 for x in known}
        r['undefined'] = [n for n in nodes_used(a) if n not in k]
    r['proposal'] = propose(line)
    return r
