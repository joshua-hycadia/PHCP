#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# results.py -- Python port of HardyCross/Results.pm.
#
# The results of a calculation saved back into the model file, as a block of
# comments at its end.  See Results.pm for the rationale; the port follows
# it line for line.
#

import hashlib
import re
import time

from . import VERSION, GAMMA_W as GW, elem_hf, pipe_velocity, outlet_pressure
from . import demand, pipedata
from .validate import assess

BEGIN = '//== PHCP RESULTS'
END = '//== END PHCP RESULTS'

#------------------------------------------------------------------------------
# strip -- the model text with any results block removed, and the blank
# lines before it.
#------------------------------------------------------------------------------
_STRIP_MID = re.compile(
    r'(\n)\n*^' + re.escape(BEGIN) + r'[^\n]*\n.*?^' + re.escape(END) + r'[^\n]*(?:\n|\Z)',
    re.M | re.S)
_STRIP_ALL = re.compile(
    r'\A' + re.escape(BEGIN) + r'[^\n]*\n.*?^' + re.escape(END) + r'[^\n]*(?:\n|\Z)',
    re.M | re.S)

def strip(text):
    text = text or ''
    new = _STRIP_MID.sub(r'\1', text, count=1)
    if new != text:
        return new
    return _STRIP_ALL.sub('', text, count=1)

# fingerprint -- the SHA-256 of the model without its results block.
# The Perl hashes the model's bytes.  Text read by the command line carries
# them as UTF-8 with surrogateescape (the default here); text from a window
# carries one byte per character and is written as editor.file_encoding
# says, so a window passes that encoding and the hash is of the bytes saved.
def fingerprint(text, encoding=None):
    return hashlib.sha256(strip(text).encode(encoding or 'utf-8', 'surrogateescape')).hexdigest()

# Perl's \s: the ASCII white space, and for the database's text (which the
# Perl decodes) the Unicode spaces too -- but not the separators \x1c to
# \x1f, which Python's \s takes in.
_WS = r'[ \t\n\r\f\v\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]'

def _word(s):
    s = '-' if s is None else s
    s = re.sub(_WS + '+', '_', s)
    s = re.sub(r'[^\x21-\x7e]', '', s)
    return s or '-'

# _perl -- a formatted number as Perl's sprintf spells one that is not
# finite: Inf, -Inf, NaN, where Python's % writes inf and nan.
def _perl(s):
    return s.replace('inf', 'Inf').replace('nan', 'NaN') if ('inf' in s or 'nan' in s) else s

def _num(v, d):
    return '-' if v is None else _perl('%.*f' % (d, v))

#------------------------------------------------------------------------------
# block -- the results block for a solved network, as text ending in "\n".
#------------------------------------------------------------------------------
def block(net, ok, text, encoding=None):
    from . import supplies as _supplies
    a = assess(net, ok)
    va = a['validation']
    uf, up = net['f_flow'], net['f_pres']
    l = []

    def rec(w, *fields):
        # A number is joined as Perl stringifies it, %.15g: a tolerance of
        # 1.0 is "1", and 0.06 / 60 is "0.001".
        l.append('//= %-8s %s' % (w, ' '.join('-' if f is None else
                                               _perl('%.15g' % f) if isinstance(f, float) else str(f)
                                               for f in fields)))

    t = time.gmtime()
    l.append('%s - PHCP %s, %04d-%02d-%02d %02d:%02d UTC, %s%s.  Replaced on every solve: edit the model '
             'above, not these lines.'
             % (BEGIN, VERSION, t[0], t[1], t[2], t[3], t[4],
                va['acceptance'], '' if va['acceptance'] == 'ACCEPTED' else ', NOT FOR DESIGN USE'))
    da = (va.get('demand_assessment') or {}).get('status') or 'NOT_ASSESSED'
    rec('RESULT', 'ACCEPTANCE', va['acceptance'], 'NUMERICAL', va['numerical']['status'],
        'PHYSICAL', va['physical']['status'], 'DESIGN', va['design']['status'],
        'DEMAND', da, 'APPROVED', 'YES' if va['acceptance'] == 'ACCEPTED' else 'NO')
    rec('PROGRAM', 'PHCP', 'VERSION', VERSION)
    rec('MODEL', 'SHA256', fingerprint(text if text is not None else (net.get('source_text') or ''), encoding))
    if pipedata.path():
        rec('DATABASE', 'NAME', _word(pipedata.dataset()), 'ISSUED', _word(pipedata.issued()),
            'SHA256', pipedata.sha256())
    rec('UNITS', 'FLOW', net['u_flow'], 'PRESSURE', net['u_pres'],
        'LENGTH', 'M', 'SIZE', 'MM', 'VELOCITY', 'M/S')
    s = va['solver']
    rec('SOLVER', 'METHOD', s['method'], 'ITERATIONS', s['iterations'],
        'CONVERGED', 'YES' if s['hc_converged'] else 'NO',
        'SETTLED', 'YES' if s['outer_settled'] else 'NO',
        'TOL_FLOW', s['tol_flow'], 'TOL_LOOP', s['tol_loop'],
        *(('VERIFY_LOOP', _perl('%.3e' % va['verification']['loop'])) if va.get('verification') else ()))
    for k in ('continuity', 'balance', 'loop', 'element'):
        r = (va.get('residuals') or {}).get(k)
        if not r:
            continue
        rec('RESIDUAL', k.upper(), _perl('%.3e' % r['value']), 'TOL', _perl('%.3e' % r['tolerance']),
            'PASS', 'YES' if r['pass'] else 'NO')
    el = net['elems'][1:]
    nid = lambda i: net['nodes'][i]['id']
    # + 0.0: a loss of nothing against the flow is -1 * 0, which Perl works
    # as integers and prints 0.0000; Python's float gives -0.0, "-0.0000".
    for e in [x for x in el if x['kind'] == 'PIPE']:
        hf = elem_hf(e, e['q'], net['opts'])[0] + 0.0
        rec('PIPE', e['id'], 'FROM', nid(e['n1']), 'TO', nid(e['n2']),
            'FLOW', _num(e['q'] / uf, 4),
            'VELOCITY', _num(pipe_velocity(e['q'], e['dia']), 3),
            'LOSS', _num(hf / up, 4))
    for i in range(1, len(net['nodes'])):
        n = net['nodes'][i]
        if n['id'] == 'REF':
            continue
        rec('NODE', n['id'], 'ELEVATION', _num(n['z'], 3),
            'PRESSURE', _num((n['h'] - GW * n['z']) / up, 4))
    for e in [x for x in el if x['kind'] == 'DISCHARGE']:
        p = outlet_pressure(net, e)
        passed = e['q'] >= e['qreq'] - 1e-6 and p >= e['preq'] - 1e-6
        rec('OUTLET', e['id'], 'TYPE', e['otype'],
            'FLOW', _num(e['q'] / uf, 4), 'REQ_FLOW', _num(e['qreq'] / uf, 4),
            'PRESSURE', _num(p / up, 4), 'REQ_PRESSURE', _num(e['preq'] / up, 4),
            'MARGIN', _num((p - e['preq']) / up, 4), 'PASS', 'YES' if passed else 'NO')
    for f in [x for x in (net.get('fixed') or []) if x.get('preq') is not None]:
        p = demand.gauge(net, f['n1'])
        rec('OUTLET', f['id'], 'TYPE', 'FIXEDFLOW',
            'FLOW', _num(f['q'] / uf, 4), 'REQ_FLOW', _num(f['qreq'] / uf, 4),
            'PRESSURE', _num(p / up, 4), 'REQ_PRESSURE', _num(f['preq'] / up, 4),
            'MARGIN', _num((p - f['preq']) / up, 4),
            'PASS', 'YES' if p >= f['preq'] - 1e-6 else 'NO')
    for e in [x for x in el if x['kind'].startswith('SUPPLY_')]:
        state = _supplies.state_of(e)
        rec('SUPPLY', e['id'], 'NODE', nid(e['n2']), 'FLOW', _num(e['q'] / uf, 4),
            'PRESSURE', _num(demand.gauge(net, e['n2']) / up, 4), 'STATUS', state)
        # Persist the settled check-valve state with the results.
        v = _supplies.valve_of(e)
        if not v:
            continue
        basis = v.get('basis')
        if basis is None:
            basis = 'CV' if (v.get('cv') or 0) > 0 else 'PIPEWORK'
        rec('CHECKVALVE', e['id'], 'NODE', nid(e['n2']), 'STATE', state,
            'FLOW', _num((0 if e.get('closed') else e['q']) / uf, 4),
            'PRESSURE', _num(demand.gauge(net, e['n2']) / up, 4),
            'LOSS', '-' if e.get('closed') else _num(v['loss'] / up, 4),
            'BASIS', basis, 'CV', _num(v.get('cv'), 3), 'CRACK', _num(v['crack'] / up, 4),
            'CRACK_GIVEN', 'YES' if v.get('crack_given') else 'NO',
            'MODEL', _word(v.get('model')), 'SWITCHES', v.get('switches'))
    # The ESTIMATED dry system times (DryTime), seconds.
    dry = {d['id']: d for d in (a.get('dry') or [])}

    def est(id_):
        d = dry.get(id_)
        if not d:
            return ()
        if d.get('error'):
            return ('ESTIMATE', 'NO')
        return ('TRIP_S', _num(d['trip'].get('seconds'), 1),
                'TRANSIT_S', _num(d['transit'].get('seconds'), 1),
                'DELIVERY_S', _num(d.get('delivery'), 1),
                'ESTIMATE', 'YES')

    for e in [x for x in el if not re.match(r'^(PIPE|DISCHARGE|SUPPLY_)', x['kind'])]:
        hf = 0 if e.get('closed') else elem_hf(e, e['q'], net['opts'])[0] + 0.0
        extra = ()
        if e['kind'] == 'DPV':
            extra = ('MODEL', _word(e['db_model'] if e.get('db_model') is not None else e.get('model')),
                     'BASIS', e.get('loss')) + est(e['id'])
        elif e['kind'] == 'ORIFICE':
            extra = ('BORE', _num(e.get('bore'), 2))
        rec('DEVICE', e['id'], 'KIND', e['kind'], 'FLOW', _num(e['q'] / uf, 4),
            'LOSS', _num(hf / up, 4), 'STATE', 'CLOSED' if e.get('closed') else 'OPEN', *extra)
    go, gm = demand.governing_outlet(net)
    if go:
        rec('GOVERNS', go['id'], 'MARGIN', _num(gm / up, 4))
    dm = a.get('demand')
    if dm:
        if dm.get('reason'):
            rec('DEMAND', 'STATUS', dm.get('status') or 'NOT_FOUND', 'NONE', _word(dm['reason']))
        else:
            rec('DEMAND', dm['supply']['id'], 'FLOW', _num(dm['q_demand'] / uf, 4),
                'PRESSURE', _num(dm['p_demand'] / up, 4),
                'AVAILABLE', _num(dm['p_avail'] / up, 4),
                'MARGIN', _num(dm['margin'] / up, 4),
                'MEETS', 'YES' if dm['margin'] >= 0 else 'NO')
    sp = a.get('supplies')
    if sp:
        for c in (sp.get('conditional') or []):
            rec('CONDMIN', c['id'], 'STATUS', c['status'],
                'FLOW', _num(c.get('flow') / uf if c.get('flow') is not None else None, 4),
                'PRESSURE', _num(c.get('pressure') / up if c.get('pressure') is not None else None, 4))
        j = sp.get('joint')
        if j:
            rec('JOINT', 'STATUS', j.get('status') or '-', 'BASIS', j.get('basis') or '-',
                'ASSUMPTION', 'YES')
            if (j.get('status') or '') == 'FOUND':
                if j['basis'] == 'DERATE':
                    tail = ('DERATE', _num(j['delta'] / up, 4))
                else:
                    tail = ('FACTOR', _num(j.get('factor'), 6))
                rec('JOINT', 'BASIS', j['basis'], *tail,
                    'MARGIN', _num(j['margin'] / up, 4), 'GOVERNS', j.get('governing'))
                for r in j['supplies']:
                    rec('JOINT', r['id'], 'FLOW', _num(r['flow'] / uf, 4),
                        'PRESSURE', _num(r['pressure'] / up, 4))
        for sc in (sp.get('scenarios') or []):
            rec('SCENARIO', _word(sc['name']), 'RESULT', sc['acceptance'],
                'REQUIRED', 'YES' if sc.get('required') else 'NO',
                'MARGIN', _num(sc['margin'] / up if sc.get('margin') is not None else None, 4))
    for f in [x for x in va['findings'] if x['severity'] != 'info']:
        m = re.sub(r'[^\x20-\x7e]', '', f['message'])
        l.append('//= %-8s %s %s %s %s' % ('FINDING', f['severity'].upper(),
                                            f['category'].upper(), f['code'], m))
    # The block's own fingerprint: every record above.
    l.append('//= %-8s SHA256 %s' % ('CHECK', hashlib.sha256('\n'.join(l[1:]).encode('utf-8', 'surrogateescape')).hexdigest()))
    l.append(END)
    return '\n'.join(l) + '\n'

#------------------------------------------------------------------------------
# status -- whether a .phc's results block belongs to it.
#------------------------------------------------------------------------------
_STATUS_RE = re.compile(r'^' + re.escape(BEGIN) + r'[^\n]*\n(.*?)^' + re.escape(END),
                        re.M | re.S)
_CHECK_RE = re.compile(r'^//= CHECK\s+SHA256 ([0-9a-f]{64})\s*$', re.A)
_MODEL_RE = re.compile(r'^//= MODEL\s+SHA256 ([0-9a-f]{64})', re.A)
_CHECK_LINE = re.compile(r'^//= CHECK\s', re.A)

def status(text):
    text = (text or '').replace('\r\n', '\n')
    m = _STATUS_RE.search(text)
    if not m:
        return 'NONE'
    lines = [ln for ln in m.group(1).split('\n') if ln.startswith('//= ')]
    # The first CHECK record is the one compared, as the Perl's list
    # assignment takes the first match; every CHECK line is left out of
    # what it covers.
    check = None
    for ln in lines:
        cm = _CHECK_RE.match(ln)
        if cm:
            check = cm.group(1)
            break
    recs = [ln for ln in lines if not _CHECK_LINE.match(ln)]
    if not (check and check == hashlib.sha256('\n'.join(recs).encode('utf-8', 'surrogateescape')).hexdigest()):
        return 'TAMPERED'
    model = None
    for ln in recs:
        mm = _MODEL_RE.match(ln)
        if mm:
            model = mm.group(1)
            break
    if not model:
        return 'TAMPERED'
    return 'CURRENT' if model == fingerprint(text) else 'STALE'

#------------------------------------------------------------------------------
# with_results -- the model text with its results block, fresh, at the end.
#------------------------------------------------------------------------------
def with_results(text, net, ok, encoding=None):
    model = strip(text)
    if model and not model.endswith('\n'):
        model += '\n'
    return model + '\n' + block(net, ok, model, encoding)

#------------------------------------------------------------------------------
# read_block -- the records of a results block.
#------------------------------------------------------------------------------
def read_block(text):
    text = text or ''
    m = _STATUS_RE.search(text)
    if not m:
        return None
    # split ' ' of the file's bytes: the ASCII white space alone.
    return [[w for w in re.split(r'[ \t\n\r\f\v]+', ln[3:]) if w != '']
            for ln in m.group(1).split('\n') if ln.startswith('//= ')]
