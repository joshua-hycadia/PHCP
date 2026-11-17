#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# pipedata.py -- Python port of HardyCross/PipeData.pm.
#
# Pipe dimensions and fitting allowances, read from data/pipes.dat.  THE ONE
# RULE THAT MATTERS MOST (see PipeData.pm): a dash, a blank, an unsupported DN
# or a missing product size is never converted to zero, never interpolated and
# never replaced by a neighbouring value -- it comes back as DATA_REQUIRED.
# Values are kept as the strings the file holds and numified only where the
# Perl numifies them, so 'DASH' stays a word and not a 0.
#

import hashlib
import os
import re
import sys

from . import settings

APPROVED            = 'APPROVED'
ASSUMPTION_REQUIRED = 'ASSUMPTION_REQUIRED'
DATA_REQUIRED       = 'DATA_REQUIRED'
PROJECT_SPECIFIC    = 'PROJECT_SPECIFIC'
PROHIBITED          = 'PROHIBITED'

# Fittings published but not counted: a coupling does not turn the flow, and
# neither does the straight-through run of a tee.
NOT_COUNTED = {'CPL': 1, 'TR': 1}

MAX_COUNT = 99   # see PipeData.pm: an office convention, not a standard

_PIPETYPE = {}
_PIPE = {}
_FIT = {}
_KPRIME = {}
_DRYVALVE = {}
_DATASET = None
_ISSUED = None
_PATH = None
_SHA256 = None

def _prog_dir():
    # The directory of the program that started us, as $0 / PAR_PROGNAME in
    # Perl.  phcp.py sets this from its own path at startup; the tests use it
    # so the database they see is the one beside the program under test.
    return getattr(sys, 'phcp_program_dir', None) or os.path.dirname(os.path.abspath(sys.argv[0]))

def _module_dir():
    return os.path.dirname(os.path.abspath(__file__))

def user_path():
    prog = os.environ.get('PAR_PROGNAME') or sys.argv[0]
    return os.path.join(os.path.dirname(os.path.abspath(prog)), 'data', 'pipes.dat')

def default_path():
    d = settings.database_dir()
    if d is not None:
        return os.path.join(d, 'pipes.dat')
    name = 'pipes.dat'
    try_ = [user_path(),
            os.path.join(os.path.dirname(_module_dir()), 'data', name)]
    if os.environ.get('PAR_TEMP'):
        try_.append(os.path.join(os.environ['PAR_TEMP'], 'inc', 'lib', 'data', name))
    for p in try_:
        if os.path.isfile(p) and os.access(p, os.R_OK):
            return os.path.abspath(p)
    return try_[1]

def origin(path=None):
    p = os.path.abspath(path if path is not None else (_PATH or default_path()))
    d = settings.database_dir()
    if d is not None and p == os.path.abspath(os.path.join(d, 'pipes.dat')):
        return 'TEAM FOLDER'
    src = os.path.abspath(os.path.join(os.path.dirname(_module_dir()), 'data', 'pipes.dat'))
    if p == src or (os.environ.get('PAR_TEMP') and p.startswith(os.environ['PAR_TEMP'])):
        return 'BUILT-IN'
    def collapse(x):
        return re.sub(r'[^/\\]+[/\\]\.\.[/\\]', '', x)
    if collapse(p) == collapse(src):
        return 'BUILT-IN'
    return 'BESIDE THE PROGRAM'

def load(path=None):
    global _PIPETYPE, _PIPE, _FIT, _KPRIME, _DRYVALVE, _DATASET, _ISSUED, _PATH, _SHA256
    path = path if path is not None else default_path()
    try:
        with open(path, 'rb') as raw:
            data = raw.read()
    except OSError as e:
        extra = ''
        if settings.database_dir() is not None:
            extra = (' (the database folder set in the PHCP settings, '
                     + settings.file() + ')')
        raise SystemError('cannot open the pipe and fitting database %s: %s%s'
                          % (path, e, extra))
    _PIPETYPE = {}; _PIPE = {}; _FIT = {}; _KPRIME = {}; _DRYVALVE = {}
    _DATASET = None; _ISSUED = None
    _SHA256 = hashlib.sha256(data).hexdigest()
    _PATH = path
    text = data.decode('utf-8')
    for l in text.split('\n'):
        l = re.sub(r'\r$', '', l)
        if re.match(r'^\s*(#|$)', l):
            continue
        f = l.split('|')
        kind = f.pop(0)
        if kind == 'DATASET':
            _DATASET = f[0] if len(f) > 0 else None
            _ISSUED = f[1] if len(f) > 1 else None
        elif kind == 'PIPETYPE':
            code, name, std, rng, c, eps = (f + [None] * 6)[:6]
            if eps is not None and (eps == 'DASH' or
                    not re.match(r'^\s*(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*$', eps)):
                eps = None
            _PIPETYPE[code] = {'name': name, 'std': std, 'range': rng, 'c': c, 'eps': eps}
        elif kind == 'PIPE':
            code, dn, od, bore, k = (f + [None] * 5)[:5]
            _PIPE.setdefault(code, {})[dn] = {'od': od, 'bore': bore, 'k': k}
        elif kind == 'FIT':
            src, code, label, dn, le = (f + [None] * 5)[:5]
            _FIT.setdefault(src, {}).setdefault(code, {})[dn] = {'label': label, 'le': le}
            _FIT[src][code]['_label'] = label
        elif kind == 'KPRIME':
            code, label, kp, use = (f + [None] * 4)[:4]
            _KPRIME[code] = {'label': label, 'kp': kp, 'use': use}
        elif kind == 'DRYVALVE':
            (maker, model, dn, inch, eql, unit, c, ref, trip, pmax,
             status, source, note) = (f + [None] * 13)[:13]
            _DRYVALVE.setdefault(maker.upper(), {}).setdefault(model.upper(), {})[dn] = {
                'maker': maker.upper(), 'model': model.upper(), 'dn': dn, 'inch': inch,
                'eql': eql, 'eql_unit': (unit or '').upper(), 'c': c, 'ref': ref, 'trip': trip,
                'pmax': pmax, 'status': status, 'source': source, 'note': note or ''}
    if not _DATASET:
        raise SystemError('database %s has no DATASET line -- add one naming '
                          'this data and its date' % path)
    return 1

def dataset():   return _DATASET or ''
def issued():    return _ISSUED or ''
def path():      return _PATH or ''
def sha256():    return _SHA256 or ''
def pipe_type(code): return _PIPETYPE.get(code)
def pipe_types(): return sorted(_PIPETYPE)

def bore(type_, dn):
    r = _PIPE.get(type_, {}).get(dn)
    if r is None:
        return None
    return None if r['bore'] == 'DASH' else r['bore']

def pipe_row(type_, dn):
    return _PIPE.get(type_, {}).get(dn)

# ---------------------------------------------------------------- dry valves
def dry_valve(maker, model, dn):
    r = (_DRYVALVE.get((maker or '').upper(), {})
              .get((model or '').upper(), {})
              .get(dn))
    if r is None:
        return None
    v = dict(r)
    num = re.compile(r'^\s*(\d+\.?\d*|\.\d+)\s*$')
    if r['eql_unit'] == 'CV':
        m = num.match(r['eql'] or '')
        v['cv'] = float(m.group(1)) if m else None
    else:
        m = num.match(r['eql'] or '')
        v['eql_m'] = (float(m.group(1)) * (0.3048 if r['eql_unit'] == 'FT' else 1.0)
                      if m else None)
    m = re.match(r'^(\d+\.?\d*)IN$', r['ref'] or '', re.I)
    if m:
        v['bore_mm'] = float(m.group(1)) * 25.4
    elif (r['ref'] or '').upper() == 'S40':
        v['bore_mm'] = bore('S40', dn)
    else:
        v['bore_mm'] = None
    m = num.match(r['trip'] or '')
    v['trip_ratio'] = float(m.group(1)) if m else None
    v['pmax_kpa'] = None
    m = re.match(r'^(\d+\.?\d*)PSI$', r['pmax'] or '', re.I)
    if m:
        v['pmax_kpa'] = float(m.group(1)) * 6.894757
    else:
        m = re.match(r'^(\d+\.?\d*)KPA$', r['pmax'] or '', re.I)
        if m:
            v['pmax_kpa'] = float(m.group(1))
    return v

def dry_valve_models():
    out = []
    for mk in sorted(_DRYVALVE):
        for md in sorted(_DRYVALVE[mk]):
            out.append([mk, md, sorted(_DRYVALVE[mk][md], key=lambda x: float(x))])
    return out

# ------------------------------------------------------------- which source
def governing_source(type_, dn):
    if type_ == 'CPVC':
        return {'method': 'EQUIVALENT_LENGTH', 'class': 'A3', 'table': 'CPVC',
                'doc': 'TYCO/BlazeMaster IH-1900 rev. 04/2019 Table F2',
                'corrections': 0, 'status': APPROVED}
    if type_.startswith('PE'):
        return {'method': 'LE_OVER_D', 'class': 'B', 'table': 'PPI',
                'doc': 'PPI Handbook of PE Pipe 2nd ed. Ch. 6 Eq. 2-9, Table 2-2',
                'corrections': 0, 'status': APPROVED}
    dn = float(dn)
    fallback = type_ == 'PVCM16'
    tno = 'AS' if dn <= 150 else 'FM'
    if tno == 'AS':
        basis, doc, cls = 'ASAM', 'AS 2118.1:2017 Table 14.11.1', 'A1'
    else:
        basis, doc, cls = 'S40', 'FM Global DS 3-0 (March 2010) Table 12(a)', 'A2'
    return {
        'method': 'EQUIVALENT_LENGTH_FALLBACK' if fallback else 'EQUIVALENT_LENGTH',
        'class': 'C' if fallback else cls,
        'table': tno,
        'doc': doc,
        'basis_type': basis,
        'corrections': 1,
        'status': ASSUMPTION_REQUIRED if fallback else APPROVED,
    }

# ------------------------------------------------------- fitting strings
_FIT_RE = re.compile(
    r'^(\d*)(E45M[12]|E60M[12]|E30M[12]|E15M1|EM[123]|GV(?:75|50|25)?|CV[MB]?'
    r'|E45|E15|EL|EF|GLV|CPL|TR|BV|AV|E|T)')

def parse_fittings(spec):
    spec = re.sub(r'\s+', '', spec or '')
    if not len(spec):
        return ([], None)
    items = []
    rest = spec.upper()
    while len(rest):
        rest = re.sub(r'^[,+]+', '', rest)
        if not len(rest):
            break
        m = _FIT_RE.match(rest)
        if m:
            n = m.group(1) if m.group(1) != '' else '1'
            code = m.group(2)
            rest = rest[m.end():]
            n = int(n)
            if n == 0:
                return (None, "fitting count of zero in '%s' - a count of zero "
                              "is not a fitting; check the string" % code)
            if n > MAX_COUNT:
                return (None, "fitting count of %d for '%s' is not plausible for "
                              "one pipe (limit %d); check the string" % (n, code, MAX_COUNT))
            items.append([n, code])
        else:
            return (None, "cannot read fitting code at '%s'" % rest)
    return (items, None)

def resolve(**a):
    type_ = a.get('type'); dn = a.get('dn'); c = a.get('c'); spec = a.get('spec')
    out = {'total': 0, 'records': [], 'errors': []}
    items, err = parse_fittings(spec)
    if err:
        out['errors'].append(err); out['total'] = None; return out
    if not items:
        return out
    if type_ not in _PIPETYPE:
        out['errors'].append("unknown pipe type '%s'" % type_)
        out['total'] = None
        return out
    b = bore(type_, dn)
    if b is None:
        out['errors'].append('DATA_REQUIRED: DN%s is not in the database for pipe type %s'
                             % (dn, type_))
        out['total'] = None
        return out
    bore_f = float(b)
    if c is None:
        c = _PIPETYPE[type_]['c']
    c = float(c)
    src = governing_source(type_, dn)
    for n, code in items:
        r = {'count': n, 'code': code, 'type': type_, 'dn': dn,
             'bore': b, 'c': c, 'class': src['class'],
             'doc': src['doc'], 'method': src['method'],
             'status': src['status'], 'dataset': _DATASET}
        if code in NOT_COUNTED:
            if src['table'] == 'PPI':
                label = (_KPRIME.get(code) or {}).get('label')
            else:
                label = _FIT.get(src['table'], {}).get(code, {}).get('_label')
            r.update({'label': label if label is not None else code,
                      'base': 0, 'cmult': 1, 'dmult': 1, 'each': 0, 'total': 0,
                      'method': 'NOT_COUNTED',
                      'note': 'does not turn the flow - not counted'})
            out['records'].append(r)
            continue
        if src['method'] == 'LE_OVER_D':
            kp = _KPRIME.get(code)
            if kp is None:
                out['errors'].append("DATA_REQUIRED: no PPI K' for fitting %s on %s DN%s"
                                     % (code, type_, dn))
                out['total'] = None
                r['status'] = DATA_REQUIRED
                out['records'].append(r)
                continue
            each = float(kp['kp']) * bore_f / 1000
            r.update({'label': kp['label'], 'base': float(kp['kp']), 'cmult': 1, 'dmult': 1,
                      'each': each, 'total': n * each,
                      'note': "Le = K'd = %s x %.4f m" % (kp['kp'], bore_f / 1000)})
            if out['total'] is not None:
                out['total'] += n * each
            out['records'].append(r)
            continue
        row = _FIT.get(src['table'], {}).get(code)
        cell = row.get(dn) if row else None
        if row is None or cell is None or cell['le'] == 'DASH':
            if row is None:
                why = "%s has no '%s' fitting" % (src['doc'], code)
            elif cell is None:
                why = '%s has no DN%s value' % (src['doc'], dn)
            else:
                why = '%s publishes no value (dash) at DN%s' % (src['doc'], dn)
            hint = ''
            if code == 'E' and src['table'] == 'FM':
                hint = (' - E is the screwed elbow; use EF for a flanged, grooved or'
                        ' medium-sweep elbow')
            out['errors'].append('DATA_REQUIRED: %s on %s DN%s - %s; not zero, not interpolated%s'
                                 % (code, type_, dn, why, hint))
            out['total'] = None
            r['status'] = DATA_REQUIRED
            r['label'] = row['_label'] if row else code
            out['records'].append(r)
            continue
        cm, dm, basis_bore = 1, 1, None
        if src['corrections']:
            cm = (c / 120) ** 1.85
            bb = bore(src['basis_type'], dn)
            if bb is None:
                out['errors'].append('DATA_REQUIRED: no %s basis bore at DN%s '
                                     'for the diameter modifier' % (src['basis_type'], dn))
                out['total'] = None
                r['status'] = DATA_REQUIRED
                out['records'].append(r)
                continue
            basis_bore = float(bb)
            dm = 1 if a.get('standard_only') else (bore_f / basis_bore) ** 4.87
        each = float(cell['le']) * cm * dm
        r.update({'label': cell['label'], 'base': float(cell['le']),
                  'basis_type': src['basis_type'], 'basis_bore': basis_bore,
                  'basis_c': 120, 'cmult': cm, 'dmult': dm,
                  'each': each, 'total': n * each})
        if src['corrections'] and a.get('standard_only'):
            r['note'] = 'diameter modifier NOT applied - Standard-alone election'
        if out['total'] is not None:
            out['total'] += n * each
        out['records'].append(r)
    return out
