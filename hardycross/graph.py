#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# graph.py -- Python port of HardyCross/Graph.pm.
#
# A Q^1.85 water supply graph, made by hand.
#
# WHAT THIS IS
#   The editor's GRAPH tab: a water supply graph drawn from figures typed in,
#   independent of any calculation.  It answers the question asked before a
#   network is modelled, or from another program's results: does this supply,
#   with this pump, meet these duties?
#
#   Five curves, all pressure against flow:
#     A  the water supply as measured (a flow test), at the test point
#     B  the loss from the supply to the datum the duties are stated at --
#        pipework, meter, backflow device, height; a single point is a loss
#        line through the origin, rising as flow^1.85
#     C  the supply available at the datum: A - B
#     D  a pump curve, from churn (no flow) out
#     E  the supply available at the datum with the pump: C + D
#   and up to ten DUTY points -- a flow needed at a pressure -- each compared
#   with the curve designed against (E with a pump, C without): the pressure
#   available at its flow, and the margin.
#
#   Every curve passes through the points entered and is straight between
#   them on this paper -- linear in flow^1.85 -- by the engine's own curve
#   (fit_curve and curve_eval), the same rule as a supply or pump
#   in a model.  Beyond its last point a curve continues in a straight line
#   in flow.  Pressures and flows are added and subtracted at equal flow;
#   nothing else is assumed.
#
#   UNITS.  Flow and pressure in the units the graph names (units => { FLOW,
#   PRESSURE }: the PROJECT tab's choices; L/min and kPa unless set).  A
#   Q^1.85 graph needs no conversion: scaling every flow by one factor scales
#   every Q^1.85 by another, so the curves, the straight lines between
#   points and the margins are the same in any unit -- only the names on the
#   page, and the round number the flow axis stops at, change.
#
# THE FILE
#   A graph is saved as a .phg file: plain text, one line per item, in the
#   same spirit as .phc -- a keyword and its fields:
#     PROJECT <text>   JOB <text>   DATE <text>   BY <text>
#     UNITS FLOW <unit>   UNITS PRESSURE <unit>
#     PMAX <pressure>  PSTEP <pressure>  QMAX <flow>
#     A <flow> <pressure>     (one line per point; likewise B and D)
#     DUTY <flow> <pressure> <label> <description ...>
#   Lines starting // are comments.
#
# HOW IT IS LAID OUT
#   new_graph            an empty graph: the fields the tab edits, as text
#   check                every field checked; the numbers, and what is wrong
#   series               the curves and duties worked out for drawing
#   read_file/write_file the .phg file
#   write_pdf            the graph on an A4 landscape sheet, in the report's
#                        typeface and frame (pdfout)
#

import math
import os
import re

from . import fit_curve, curve_eval, VERSION
from .report import nice_ticks

ROWS      = 8       # points per curve
DUTY_ROWS = 10      # duty points
CURVES    = ('A', 'B', 'D')
CURVE_NAME = {
    'A': 'WATER SUPPLY, AS MEASURED',
    'B': 'LOSS, SUPPLY TO DATUM',
    'C': 'AVAILABLE AT DATUM (A - B)',
    'D': 'PUMP',
    'E': 'WITH THE PUMP, AT DATUM (C + D)',
}
PROJECT = ('PROJECT', 'JOB', 'DATE', 'BY')
PROJECT_LABEL = {'PROJECT': 'PROJECT', 'JOB': 'JOB NO', 'DATE': 'DATE', 'BY': 'PREPARED BY'}
AXIS = ('PMAX', 'PSTEP', 'QMAX')
AXIS_LABEL = {'PMAX': 'PRESSURE AXIS TO', 'PSTEP': 'PRESSURE GRIDLINES EVERY',
              'QMAX': 'FLOW AXIS TO'}
FLOW_UNITS     = ('LPM', 'LPS', 'M3H', 'GPM')
PRESSURE_UNITS = ('KPA', 'BAR', 'MPA', 'PSI', 'M')
# The names on the page, and the round number a flow axis stops at.
UNIT_NAME = {'LPM': 'L/min', 'LPS': 'L/s', 'M3H': 'm3/h', 'GPM': 'gpm',
             'KPA': 'kPa', 'BAR': 'bar', 'MPA': 'MPa', 'PSI': 'psi', 'M': 'm head'}
FLOW_ROUND = {'LPM': 100, 'LPS': 2, 'M3H': 10, 'GPM': 25}

# units -- a graph's flow and pressure units, L/min and kPa unless set.
def units(g):
    u = g.get('units') or {}
    return {'FLOW': u.get('FLOW') if u.get('FLOW') in FLOW_UNITS else 'LPM',
            'PRESSURE': u.get('PRESSURE') if u.get('PRESSURE') in PRESSURE_UNITS else 'KPA'}

#------------------------------------------------------------------------------
# new_graph -- an empty graph.  Every field is text, as typed, so the tab can
# hold exactly what the user wrote, mistakes included, until it is checked.
#   project  { PROJECT, JOB, DATE, BY }
#   axis     { PMAX, PSTEP, QMAX }     blank: worked out from the figures
#   A, B, D  [ [flow, pressure] x ROWS ]
#   duty     [ [label, description, flow, pressure] x DUTY_ROWS ]
#------------------------------------------------------------------------------
def new_graph():
    g = {'project': {k: '' for k in PROJECT},
         'units': {'FLOW': 'LPM', 'PRESSURE': 'KPA'},
         'axis': {k: '' for k in AXIS},
         'duty': [['', '', '', ''] for _ in range(DUTY_ROWS)]}
    for c in CURVES:
        g[c] = [['', ''] for _ in range(ROWS)]
    return g

_NUM_RE = re.compile(r'^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\s*\Z')

def is_num(v):
    return v is not None and _NUM_RE.match(str(v)) is not None

def blank(v):
    return v is None or not re.search(r'\S', str(v))

# _num -- a field that is_num passed, as the number Perl makes of it: the
# number its ASCII figures spell from the start, 0 if there are none.  \d
# matches the figures of any script in a character string, in Perl as here,
# but only 0-9 count: a field of Arabic-Indic threes is_num, and is 0.
_NUMIFY_RE = re.compile(r'\s*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)')

def _num(v):
    if isinstance(v, (int, float)):
        return float(v)
    m = _NUMIFY_RE.match(str(v))
    return float(m.group(1)) + 0.0 if m else 0.0     # '-0' is 0, as $q + 0

#------------------------------------------------------------------------------
# check -- every field checked.  Returns
#   { ok, errors => [ [field, message] ],
#     points => { A|B|D => [ [q, p] ] },  curve => { A|B|D => fitted or None },
#     duty => [ { label, desc, q, p, row } ], axis => { PMAX, PSTEP, QMAX } }
# A field is named as the tab names it: A3 (curve A, row 3, either column),
# DUTY2, PMAX.  Each message says what is wrong and how to put it right.
#------------------------------------------------------------------------------
def check(g):
    err = []
    pts = {}
    curve = {}
    duty = []
    axis = {}

    for c in CURVES:
        rows = g[c]
        gap = None
        p = []
        for i in range(len(rows)):
            q, pr = rows[i]
            f = '%s%d' % (c, i + 1)
            if blank(q) and blank(pr):
                gap = (i + 1) if gap is None else gap
                continue
            if blank(q) or blank(pr):
                err.append((f, '%s ROW %d: FLOW AND PRESSURE ARE BOTH NEEDED' % (c, i + 1)))
                continue
            if not (is_num(q) and is_num(pr)):
                err.append((f, '%s ROW %d: %s IS NOT A NUMBER'
                            % (c, i + 1, "PRESSURE '%s'" % pr if is_num(q) else "FLOW '%s'" % q)))
                continue
            if gap is not None:
                err.append((f, '%s ROW %d: ROW %d IS EMPTY - FILL THE ROWS IN ORDER, WITH NO GAPS'
                            % (c, i + 1, gap)))
                gap = None
            if _num(q) < 0:
                err.append((f, '%s ROW %d: A FLOW CANNOT BE NEGATIVE' % (c, i + 1)))
                continue
            if _num(pr) < 0:
                err.append((f, '%s ROW %d: A PRESSURE CANNOT BE NEGATIVE' % (c, i + 1)))
                continue
            if p and _num(q) <= p[-1][0]:
                err.append((f, '%s ROW %d: FLOWS MUST RISE FROM ROW TO ROW, WITH NO FLOW TWICE'
                            % (c, i + 1)))
                continue
            p.append([_num(q), _num(pr)])
        pts[c] = p
    if len(pts['A']) < 2:
        err.append(('A1', 'A, THE WATER SUPPLY, NEEDS AT LEAST TWO POINTS'))
    if len(pts['D']) == 1:
        err.append(('D2', 'D, THE PUMP, NEEDS AT LEAST TWO POINTS - OR NONE, FOR NO PUMP'))
    if pts['D'] and pts['D'][0][0] != 0:
        err.append(('D1', 'D ROW 1: A PUMP CURVE STARTS AT CHURN - NO FLOW'))

    # The curves, by the engine's own rule.  A single loss point is a line
    # through the origin, rising as flow^1.85.
    if not [e for e in err if re.match(r'^[AD]', e[0])]:
        for c in ('A', 'D'):
            if len(pts[c]) >= 2:
                curve[c] = fit(pts[c], 0)
    if not [e for e in err if re.match(r'^B', e[0])]:
        b = list(pts['B'])
        if len(b) == 1 and b[0][0] > 0:
            b.insert(0, [0, 0])
        if len(b) >= 2:
            curve['B'] = fit(b, 1)

    for i in range(len(g['duty'])):
        label, desc, q, pr = g['duty'][i]
        f = 'DUTY%d' % (i + 1)
        if blank(label) and blank(desc) and blank(q) and blank(pr):
            continue
        if blank(q) or blank(pr):
            err.append((f, 'DUTY ROW %d: FLOW AND PRESSURE ARE BOTH NEEDED' % (i + 1)))
            continue
        if not (is_num(q) and is_num(pr)):
            err.append((f, 'DUTY ROW %d: %s IS NOT A NUMBER'
                        % (i + 1, "PRESSURE '%s'" % pr if is_num(q) else "FLOW '%s'" % q)))
            continue
        if _num(q) < 0:
            err.append((f, 'DUTY ROW %d: A FLOW CANNOT BE NEGATIVE' % (i + 1)))
            continue
        duty.append({'label': str(i + 1) if blank(label) else clean(label),
                     'desc': clean(desc or ''),
                     'q': _num(q), 'p': _num(pr), 'row': i + 1})

    for k in AXIS:
        v = g['axis'].get(k)
        if blank(v):
            continue
        if not is_num(v) or _num(v) <= 0:
            err.append((k, "%s: '%s' MUST BE A NUMBER ABOVE ZERO, OR BLANK" % (AXIS_LABEL[k], v)))
            continue
        axis[k] = _num(v)
    return {'ok': not err, 'errors': err, 'points': pts, 'curve': curve, 'duty': duty,
            'axis': axis, 'units': units(g)}

# clean -- text for the sheet: printable ASCII, capitals, single spaces.
def clean(t):
    t = (t or '').upper()
    t = re.sub(r'[^\x20-\x7E]+', ' ', t)
    t = re.sub(r'\s+', ' ', t)
    return t.strip()

# fit -- a curve through [ [q, p] ... ] by fit_curve; $rising for
# a loss, which grows with flow.
def fit(pts, rising):
    return fit_curve({'q': [p[0] for p in pts], 'p': [p[1] for p in pts]}, rising)

#------------------------------------------------------------------------------
# series -- the graph worked out for drawing, from a check that passed:
#   qmax, pmax, xticks, yticks   the axes: flow 0 .. qmax on a flow^1.85
#                                scale, pressure 0 .. pmax
#   lines  { A B C D E => [ [q, p] ... ] }   each curve sampled finely along
#                                the flow^1.85 axis (B, D and E only if given)
#   points { A B D => [ [q, p] ] }    the points as entered
#   design 'E' or 'C', the curve the duties are compared with
#   duty   [ { label, desc, q, p, avail, margin } ]
#------------------------------------------------------------------------------
def series(chk):
    cv = chk['curve']

    def ev(c, q):
        return curve_eval(cv[c], q) if cv.get(c) else 0
    at = {
        'A': lambda q: ev('A', q),
        'B': lambda q: ev('B', q),
        'C': lambda q: ev('A', q) - ev('B', q),
        'D': lambda q: ev('D', q),
        'E': lambda q: ev('A', q) - ev('B', q) + ev('D', q),
    }
    design = 'E' if cv.get('D') else 'C'

    # The flow axis: as set, or the largest flow entered rounded up to 100.
    q = [p[0] for pts in chk['points'].values() for p in pts] + [d['q'] for d in chk['duty']]
    rnd = FLOW_ROUND.get((chk.get('units') or {'FLOW': 'LPM'})['FLOW'], 100)
    qbig = max(q + [rnd])
    qmax = chk['axis'].get('QMAX')
    if qmax is None:
        qmax = rnd * math.ceil(qbig / rnd)

    names = ['A'] + (['B'] if cv.get('B') else []) + ['C'] + (['D', 'E'] if cv.get('D') else [])
    lines = {}
    for n in names:
        lines[n] = [[(qq := qmax * (k / 200) ** (1 / 1.85)), at[n](qq)] for k in range(201)]

    # The pressure axis: as set, or a tenth above the highest pressure shown,
    # to the gridline step.
    pbig = max([p[1] for n in names for p in lines[n]]
               + [d['p'] for d in chk['duty']] + [100])
    pstep = chk['axis'].get('PSTEP')
    pmax = chk['axis'].get('PMAX')
    if not pmax:
        t = nice_ticks(pbig * 1.1, 8)
        if pstep is None:
            pstep = (t[1] - t[0]) if len(t) > 1 else pbig
        pmax = pstep * math.ceil(pbig * 1.1 / pstep)
    if pstep:
        yt = [k * pstep for k in range(int(pmax / pstep + 1e-9) + 1)]
    else:
        yt = nice_ticks(pmax, 8)

    duty = []
    for d in chk['duty']:
        a = at[design](d['q'])
        duty.append(dict(d, avail=a, margin=a - d['p']))

    return {'qmax': qmax, 'pmax': pmax, 'design': design, 'lines': lines,
            'units': chk['units'],
            'points': {c: chk['points'][c] for c in CURVES if chk['points'].get(c)},
            'xticks': nice_ticks(qmax, 10), 'yticks': yt, 'duty': duty}

#------------------------------------------------------------------------------
# The .phg file.
#------------------------------------------------------------------------------
# _pstr -- a field as Perl interpolates it: text as it is, a number (a
# graph built in code, or a unit conversion) as %.15g, so 1500/60 is 25.
def _pstr(v):
    if isinstance(v, float):
        return '%.15g' % v
    return str(v)

def write_file(g, path):
    l = ['// PHCP Q^1.85 WATER SUPPLY GRAPH', '']
    for k in PROJECT:
        if not blank(g['project'].get(k)):
            l.append('%-7s %s' % (k, _pstr(g['project'][k])))
    for k in AXIS:
        if not blank(g['axis'].get(k)):
            l.append('%-7s %s' % (k, _pstr(g['axis'][k])))
    u = units(g)
    l += ['UNITS   FLOW %s' % u['FLOW'], 'UNITS   PRESSURE %s' % u['PRESSURE']]
    for c in CURVES:
        l += ['', '// %s - %s: FLOW %s, PRESSURE %s' % (c, CURVE_NAME[c], u['FLOW'], u['PRESSURE'])]
        for r in g[c]:
            if blank(r[0]) and blank(r[1]):
                continue
            l.append('%-7s %s %s' % (c, _pstr(r[0]) if not blank(r[0]) else '-',
                                     _pstr(r[1]) if not blank(r[1]) else '-'))
    l += ['', '// DUTY: FLOW, PRESSURE, LABEL, DESCRIPTION']
    for r in g['duty']:
        if all(blank(x) for x in r):
            continue
        label, desc, q, p = r
        l.append(' '.join(['DUTY   ', ('-' if blank(q) else _pstr(q)), ('-' if blank(p) else _pstr(p)),
                           ('-' if blank(label) else re.sub(r'\s+', '_', _pstr(label)))]
                          + ([] if blank(desc) else [_pstr(desc)])))
    # The bytes Perl's print writes to a handle with no encoding layer: a
    # line of characters below 256 as those bytes (an e-acute is one byte,
    # E9), a line with any character above as UTF-8.  In text mode, as the
    # Perl's '>': CRLF on Windows.
    data = b''.join(_perl_bytes(x + '\n') for x in l)
    if os.linesep != '\n':
        data = data.replace(b'\n', os.linesep.encode('ascii'))
    try:
        fh = open(path, 'wb')
    except OSError as e:
        raise ModelFileError('CANNOT WRITE %s: %s\n' % (path, e.strerror))
    with fh:
        fh.write(data)
    return 1

def _perl_bytes(t):
    try:
        return t.encode('latin-1')
    except UnicodeEncodeError:
        return t.encode('utf-8', 'surrogatepass')

# read_file -- a graph from a .phg file; dies with the line at fault.
def read_file(path):
    # Read as bytes, as the Perl does: each byte outside printable ASCII is
    # one space below, and only \n ends a line.  A file that cannot be
    # opened says so in the Perl's words.
    # Only \n ends a line (newline='\n'): a carriage return alone is a
    # character of its line, a space below, as in the Perl -- not a line end.
    # A folder opens and reads as nothing, as Perl's open and <> do.
    try:
        with open(path, encoding='latin-1', newline='\n') as fh:
            lines = fh.readlines()
    except IsADirectoryError:
        lines = []
    except OSError as e:
        raise ModelFileError('CANNOT READ %s: %s\n' % (path, e.strerror))
    g = new_graph()
    n = {'A': 0, 'B': 0, 'D': 0, 'DUTY': 0}
    for ln, l in enumerate(lines, 1):
        l = re.sub(r'\r?\n\Z', '', l)
        l = re.sub(r'[^\x20-\x7E]', ' ', l)
        if re.match(r'^\s*(//|$)', l):
            continue
        m = re.match(r'^\s*(\S+)\s*(.*?)\s*\Z', l)
        k, rest = m.group(1).upper(), m.group(2)

        def dash(v):
            return '' if (v is None or v == '-') else v
        if k in PROJECT:
            g['project'][k] = rest
            continue
        if k in AXIS:
            g['axis'][k] = rest
            continue
        if k == 'UNITS':
            parts = rest.split()
            q = parts[0].upper() if len(parts) > 0 else None
            unit = parts[1].upper() if len(parts) > 1 else None
            ok = FLOW_UNITS if q == 'FLOW' else (PRESSURE_UNITS if q == 'PRESSURE' else ())
            if not ok or unit not in ok:
                raise ModelFileError('LINE %d: UNITS TAKES FLOW (%s) OR PRESSURE (%s)\n'
                                    % (ln, ' '.join(FLOW_UNITS), ' '.join(PRESSURE_UNITS)))
            g['units'][q] = unit
            continue
        if k in CURVES:
            if n[k] >= ROWS:
                raise ModelFileError('LINE %d: MORE THAN %d POINTS ON CURVE %s\n' % (ln, ROWS, k))
            parts = rest.split()
            qq = dash(parts[0]) if len(parts) > 0 else ''
            pp = dash(parts[1]) if len(parts) > 1 else ''
            g[k][n[k]] = [qq, pp]
            n[k] += 1
            continue
        if k == 'DUTY':
            if n['DUTY'] >= DUTY_ROWS:
                raise ModelFileError('LINE %d: MORE THAN %d DUTY POINTS\n' % (ln, DUTY_ROWS))
            parts = rest.split(None, 3)
            label = dash(parts[2]).replace('_', ' ') if len(parts) > 2 else ''
            # the description stands as written: a '-' there is a '-'
            desc = parts[3] if len(parts) > 3 else ''
            qq = dash(parts[0]) if len(parts) > 0 else ''
            pp = dash(parts[1]) if len(parts) > 1 else ''
            g['duty'][n['DUTY']] = [label, desc, qq, pp]
            n['DUTY'] += 1
            continue
        raise ModelFileError('LINE %d: UNKNOWN WORD %s - A .PHG LINE STARTS WITH '
                            'PROJECT JOB DATE BY UNITS PMAX PSTEP QMAX A B D OR DUTY\n' % (ln, k))
    return g

class ModelFileError(Exception):
    pass

#------------------------------------------------------------------------------
# write_pdf -- the graph on one A4 landscape sheet: the report's frame and
# typeface; the plot on the left; on the right the key, the duty points with
# the pressure available to each and its margin, and the points entered.
#
# Black on white, so it prints and photocopies.  The curve designed against
# (E with a pump, C without) is the heavy solid line; the others are lighter
# or dashed, each named at its right-hand end.  Each element is preceded by a
# comment (% PHCP-SHEET ...) giving where it was drawn, which a PDF reader
# ignores and tools/test_graph.pl checks.
#------------------------------------------------------------------------------
def write_pdf(g, path, **meta):
    from . import pdfout
    s, sr, m = sheet(g, 1, 1, **meta)
    reg, bold = pdfout.fonts()
    m = dict(m)
    m['title'] = 'Q^1.85 water supply graph' + (' - %s' % m['title'] if len(m['title']) else '')
    pdfout.write_pages([s], path, reg, bold, **m)
    return sr

#------------------------------------------------------------------------------
# sheet -- the sheet's page content, as page $page of $npages: (stream,
# series, the frame's fields).  write_pdf makes it a file of its own; a
# model's report adds it as a page after its text (SUPPLYGRAPH).
#------------------------------------------------------------------------------
def sheet(g, page, npages, **meta):
    from . import pdfout
    chk = check(g)
    if not chk['ok']:
        raise ModelFileError('\n'.join(e[1] for e in chk['errors']) + '\n')
    sr = series(chk)
    pdfout.fonts()               # the face in use sets the character width
    geo = pdfout.geometry()
    L, cw, adv = geo['left'], geo['char_w'], geo['advance']
    R = L + geo['cols'] * cw

    def txt(x, y, t, size, b=0, al=None):
        al = al or 'l'
        w = len(t) * adv * size
        if al == 'r':
            x -= w
        elif al == 'c':
            x -= w / 2
        return 'BT /F%d %s Tf %.2f %.2f Td (%s) Tj ET\n' % (2 if b else 1, _fmt_size(size),
                                                             x, y, pdfout.esc(t))

    pj = g['project']
    m = {'header': 'PHCP  Q^1.85 WATER SUPPLY GRAPH', 'title': clean(pj.get('PROJECT')),
         'job': clean(pj.get('JOB')), 'date': clean(pj.get('DATE')),
         'designer': clean(pj.get('BY')),
         'program': (meta['program'] if meta.get('program') is not None
                     else 'PHCP %s - Python Hydraulic Calculation Program' % VERSION),
         'model': meta['model'] if meta.get('model') is not None else ''}
    s = pdfout.frame(page, npages, **m)

    # Title block.
    y = geo['top']
    s += txt(L, y, 'Q^1.85 WATER SUPPLY GRAPH' + (' - %s' % m['title'] if len(m['title']) else ''), 10, 1)
    # PREPARED BY 0 is not printed: '0' is false to the Perl's test
    s += txt(R, y, ' '.join(x for x in ('PREPARED BY %s' % m['designer']
                                        if m['designer'] not in ('', '0') else '',)
                            if len(x)), 8, 0, 'r')

    # The plot.
    pl, pr, pt, pb = L + 8 * cw, L + 84 * cw, y - 26, 92
    pw, ph = pr - pl, pt - pb
    qmax, pmax = sr['qmax'], sr['pmax']

    def X(q):
        return pl + ((q / qmax) ** 1.85 if q > 0 else 0) * pw

    def Y(p):
        return pb + p / pmax * ph

    s += '%% PHCP-SHEET PLOT %.3f %.3f %.3f %.3f %.10g %.10g\n' % (pl, pb, pw, ph, qmax, pmax)
    s += 'q 0.82 G 0.3 w\n'
    for p in sr['yticks']:
        if p > pmax + 1e-9:
            continue
        s += '%.2f %.2f m %.2f %.2f l S\n' % (pl, Y(p), pr, Y(p))
    for q in sr['xticks']:
        if q > qmax + 1e-9:
            continue
        s += '%.2f %.2f m %.2f %.2f l S\n' % (X(q), pb, X(q), pt)
    s += 'Q\n'
    for p in sr['yticks']:
        if p > pmax + 1e-9:
            continue
        s += txt(pl - 4, Y(p) - 2.4, '%g' % p, 7, 0, 'r')
    last = -1e9
    for q in sr['xticks']:
        if q > qmax + 1e-9:
            continue
        t = '%g' % q
        w = len(t) * adv * 7
        x = X(q)
        if x - w / 2 < last + 6:
            continue
        s += '%% PHCP-SHEET XTICK %s %.3f\n' % (t, x)
        s += txt(x, pb - 10, t, 7, 0, 'c')
        last = x + w / 2
    fu, pu = UNIT_NAME[sr['units']['FLOW']], UNIT_NAME[sr['units']['PRESSURE']]
    s += txt(pl - 4, pt + 6, 'PRESSURE, %s' % pu, 7, 1)
    s += txt((pl + pr) / 2, pb - 22, 'FLOW, %s, ON A FLOW^1.85 SCALE' % fu, 7, 1, 'c')
    s += '0 G 0.6 w %.2f %.2f %.2f %.2f re S\n' % (pl, pb, pw, ph)

    # Curves, clipped to the plot.  Line styles: [width, dash, grey].
    # A thin, B dotted, D dash-dot; the design curve heavy, and C dashed when
    # it is not the design curve (with a pump, E is).
    style = {'A': (0.8, '', 0), 'B': (0.8, '[1 2]', 0), 'C': (0.8, '[4 2]', 0),
             'D': (0.8, '[6 2 1 2]', 0), 'E': (0.8, '[4 2]', 0)}
    style[sr['design']] = (1.8, '', 0)
    s += 'q %.2f %.2f %.2f %.2f re W n 1 J 1 j\n' % (pl, pb, pw, ph)
    names = [n for n in ('A', 'B', 'C', 'D', 'E') if sr['lines'].get(n)]
    for n in names:
        w, d, _grey = style[n]
        pts = sr['lines'][n]
        s += '%% PHCP-SHEET LINE %s %d\n' % (n, len(pts))
        s += '%s 0 d %.2f w %.2f %.2f m\n' % (d or '[]', w, X(pts[0][0]), Y(pts[0][1]))
        for p in pts[1:]:
            s += '%.2f %.2f l\n' % (X(p[0]), Y(p[1]))
        s += 'S [] 0 d\n'
    for c in sorted(sr['points']):
        for p in sr['points'][c]:
            s += '%% PHCP-SHEET POINT %s %.3f %.3f\n' % (c, X(p[0]), Y(p[1]))
            s += '0.7 w 1 g\n' + pdfout.circle(X(p[0]), Y(p[1]), 2.2, 'B') + '0 g\n'
    s += 'Q\n'
    # Each curve named on itself, the letters staggered along the flow axis
    # so that curves meeting at one end are still told apart.
    along = {'A': 0.30, 'B': 0.62, 'C': 0.46, 'D': 0.78, 'E': 0.90}
    for n in names:
        at_ = next((p for p in sr['lines'][n] if X(p[0]) >= pl + along[n] * pw), None)
        if not at_ or not (0 <= at_[1] <= pmax):
            continue
        s += '%% PHCP-SHEET NAME %s %.3f %.3f\n' % (n, X(at_[0]), Y(at_[1]))
        s += '1 g\n' + '%.2f %.2f 7 9 re f\n' % (X(at_[0]) - 3.5, Y(at_[1]) + 1.5) + '0 g\n'
        s += txt(X(at_[0]), Y(at_[1]) + 3, n, 8, 1, 'c')
    # Duty points: a filled square, numbered.
    for d in sr['duty']:
        x, yy = X(d['q']), Y(d['p'])
        if d['q'] > qmax or d['p'] > pmax:
            continue
        s += '%% PHCP-SHEET DUTY %s %.3f %.3f\n' % (d['label'], x, yy)
        s += '0 g %.2f %.2f 5 5 re f\n' % (x - 2.5, yy - 2.5)
        s += txt(x + 4, yy + 3, d['label'], 7, 1)

    # The key.
    kx = L + 90 * cw
    ky = [pt]

    def line():
        ky[0] -= 12

    def head(t):
        s_add = txt(kx, ky[0], t, 8, 1)
        return s_add + '0.4 w %.2f %.2f m %.2f %.2f l S\n' % (kx, ky[0] - 4, R, ky[0] - 4)

    s += head('KEY')
    for n in names:
        line()
        w, d, _grey = style[n]
        s += '%s 0 d %.2f w %.2f %.2f m %.2f %.2f l S [] 0 d\n' % (d or '[]', w, kx, ky[0] + 2.5,
                                                                   kx + 20, ky[0] + 2.5)
        s += txt(kx + 26, ky[0], '%s  %s' % (n, CURVE_NAME[n]), 7, 1 if n == sr['design'] else 0)
    line()
    s += txt(kx + 26, ky[0], 'THE HEAVY LINE, %s, IS THE CURVE DESIGNED AGAINST' % sr['design'], 7)
    if sr['points']:
        line()
        s += '0.7 w 1 g\n' + pdfout.circle(kx + 10, ky[0] + 2.5, 2.2, 'B') + '0 g\n'
        s += txt(kx + 26, ky[0], 'POINTS AS ENTERED', 7)
    if sr['duty']:
        line()
        s += '0 g %.2f %.2f 5 5 re f\n' % (kx + 7.5, ky[0])
        s += txt(kx + 26, ky[0], 'DUTY POINT, NUMBERED', 7)

        # The duties against the design curve.
        line()
        line()
        s += head('DUTY POINTS - AGAINST %s' % sr['design'])
        line()
        col = (kx, kx + 64, kx + 112, kx + 160, R)
        s += txt(col[0], ky[0], 'NO', 7, 1)
        s += txt(col[1], ky[0], 'FLOW', 7, 1, 'r')
        s += txt(col[2], ky[0], 'NEEDS', 7, 1, 'r')
        s += txt(col[3], ky[0], 'HAS', 7, 1, 'r')
        s += txt(col[4], ky[0], 'MARGIN', 7, 1, 'r')
        line()
        s += txt(col[1], ky[0] + 3, fu, 6, 0, 'r')
        for i in (2, 3, 4):
            s += txt(col[i], ky[0] + 3, pu, 6, 0, 'r')
        for d in sr['duty']:
            line()
            s += '%% PHCP-SHEET ROW %s %.1f %.1f %.1f %.1f\n' % (d['label'], d['q'], d['p'],
                                                                 d['avail'], d['margin'])
            s += txt(col[0], ky[0], pdfout.fit(d['label'], 8), 7)
            s += txt(col[1], ky[0], '%.4g' % d['q'], 7, 0, 'r')
            s += txt(col[2], ky[0], '%.4g' % d['p'], 7, 0, 'r')
            s += txt(col[3], ky[0], '%.4g' % d['avail'], 7, 0, 'r')
            s += txt(col[4], ky[0], ('SHORT ' if d['margin'] < 0 else '') + '%.4g' % abs(d['margin']),
                     7, 1 if d['margin'] < 0 else 0, 'r')
            if len(d['desc']):
                ky[0] -= 9
                s += txt(col[0] + 10, ky[0], pdfout.fit(d['desc'], 44), 6)

    # The points entered, for the record.
    line()
    line()
    s += head('POINTS ENTERED, %s AT %s' % (fu, pu))
    for c in sorted(sr['points']):
        line()
        t = '%s  %s' % (c, ', '.join('%g at %g' % (p[0], p[1]) for p in sr['points'][c]))
        for part in wrap_to(t, 52):
            s += txt(kx, ky[0], part, 6.5)
            ky[0] -= 9
        ky[0] += 9
    line()
    line()
    note = ('Every curve passes through its points and is straight between them on this paper; '
            'beyond its last point it continues straight in flow. C = A - B and E = C + D, '
            'at equal flow. '
            + ('B, one point, is a loss line through the origin. '
               if g.get('B') and len([r for r in g['B'] if not blank(r[0])]) == 1 else '')
            + 'Not a calculation of a network: the figures are as entered.')
    for part in wrap_to(note, 60):
        s += txt(kx, ky[0], part, 6)
        ky[0] -= 8

    return s, sr, m

#------------------------------------------------------------------------------
# text_sheet -- the sheet as 7-bit ASCII lines, for a model's text report:
# the project, the points entered and the duty points against the curve
# designed against.  The PDF report draws the sheet itself as well.
#------------------------------------------------------------------------------
def text_sheet(g):
    chk = check(g)
    if not chk['ok']:
        return ['  %s' % e[1] for e in chk['errors']]
    sr = series(chk)
    fu, pu = UNIT_NAME[sr['units']['FLOW']], UNIT_NAME[sr['units']['PRESSURE']]
    l = []
    for k in PROJECT:
        if not blank(g['project'].get(k)):
            l.append(' %-26s %s' % (PROJECT_LABEL[k], clean(g['project'][k])))
    l += [' %-26s flow %s, pressure %s' % ('UNITS', fu, pu), '']
    l.append(' CURVES' + ' ' * 31 + 'POINTS ENTERED, FLOW AT PRESSURE')
    for c in ('A', 'B', 'C', 'D', 'E'):
        if not sr['lines'].get(c):
            continue
        if sr['points'].get(c):
            pts = ', '.join('%g at %g' % (p[0], p[1]) for p in sr['points'][c])
        else:
            pts = 'A - B, at equal flow' if c == 'C' else 'C + D, at equal flow'
        w = wrap_to(pts, 96)
        l.append(' %s  %-32s %s' % (c, CURVE_NAME[c], w.pop(0)))
        l.extend(' ' * 37 + x for x in w)
    l += ['', ' The curve designed against is %s.' % sr['design']]
    if sr['duty']:
        l += ['', ' %-8s %12s %12s %12s %14s  %s'
              % ('DUTY', 'FLOW %s' % fu, 'NEEDS %s' % pu, 'HAS %s' % pu,
                 'MARGIN %s' % pu, 'DESCRIPTION')]
        for d in sr['duty']:
            l.append(' %-8s %12.4g %12.4g %12.4g %14s  %s'
                     % (d['label'], d['q'], d['p'], d['avail'],
                        ('SHORT ' if d['margin'] < 0 else '') + '%.4g' % abs(d['margin']),
                        clean(d['desc'])))
    l.append('')
    l.extend(' ' + x for x in wrap_to(
        'Every curve passes through its points and is straight between them on '
        'Q^1.85 paper; beyond its last point it continues straight in flow.  The figures are as entered: '
        'this sheet is not a calculation of the network in this report.', 120))
    return l

# wrap_to -- text cut into lines of at most $w characters, at spaces.
def wrap_to(t, w):
    out = []
    cur = ''
    for word in t.split():
        if len(cur) + len(word) + 1 > w and len(cur):
            out.append(cur)
            cur = word
        else:
            cur = (cur + ' ' + word) if len(cur) else word
    if len(cur):
        out.append(cur)
    return out

# Perl's %s of a size that may be fractional: 6.5 prints as 6.5, 7 as 7.
def _fmt_size(size):
    return ('%g' % size)
