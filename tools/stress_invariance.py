#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# stress_invariance.py -- stress the Python engine with tests that need no
# reference answer.  Python port of stress_invariance.pl.
#
# WHY INVARIANCE
#   A comparison against another program catches a wrong answer only where
#   the two disagree -- and a mistake both share, or a case the other program
#   cannot express, sails through.  An invariance test instead
#   asks the engine to agree WITH ITSELF: take one network, describe it a
#   different way that does not change the physics, and demand the same answer.
#   Any disagreement is a bug by construction, with no reference needed.
#
#   The transforms, and why each is a real test:
#     shuffle     list the elements in a different order.  Changes the tree,
#                 every loop, and the order corrections are applied in.
#     reverse     draw a pipe the other way round.  Its flow must flip sign
#                 and nothing else may move.  Catches any sign slip in the
#                 head-loss or derivative code.
#     datum       raise the whole site.  Gauge pressures and flows must not
#                 change; total heads must rise by exactly gamma * dz.
#     split       cut a pipe in two with a node in the middle.  Friction is
#                 linear in length, so the flows must not change.
#     rename      give every node a different name.  Catches anything keyed
#                 on a name that should not be.
#     units       express the same model in L/s, bar, mm, cm and inches.  Catches a
#                 conversion factor missing on any one quantity.
#     repeat      solve the identical text twice.  The answers must be the
#                 same bytes -- no hidden state between solves.
#
#   Every solve is also checked directly: continuity at every node, closure
#   around every loop, and no non-finite number anywhere.
#
#     python3 tools/stress_invariance.py [cases] [seed]
#
# SAME CASES AS THE PERL
#   The random numbers come from Perl's own generator (drand48) and
#   List::Util's shuffle, reproduced here, and the model text is written with
#   Perl's number formatting, so a seed gives the same networks, the same
#   transforms and the same printed results as tools/stress_invariance.pl
#   gave with that seed.
#==============================================================================
import math
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(TOOLS))

import hardycross
from hardycross import phc, pipedata


#------------------------------------------------------------------------------
# Perl's rand and List::Util's shuffle, so a seed means what it meant.
#------------------------------------------------------------------------------
class PerlRand:
    # drand48: srand(s) sets the 48-bit state to (s << 16) + 0x330E; each
    # rand steps X = (0x5DEECE66D X + 0xB) mod 2^48 and returns X / 2^48,
    # times the argument (rand 0 is rand 1, as in Perl).
    def __init__(self, seed):
        self.x = (((int(seed) & 0xFFFFFFFF) << 16) + 0x330E) & 0xFFFFFFFFFFFF

    def rand(self, n=1):
        if n == 0:
            n = 1
        self.x = (0x5DEECE66D * self.x + 0xB) & 0xFFFFFFFFFFFF
        return n * (self.x / float(1 << 48))

    def shuffle(self, lst):
        # List::Util 1.63's XS shuffle: from the end, swap each place with a
        # place at or below it.
        l = list(lst)
        i = len(l)
        while i > 1:
            sw = int(self.rand() * i)
            i -= 1
            l[sw], l[i] = l[i], l[sw]
        return l


def pstr(v):
    # A value as Perl interpolates it: text as it is, a number by %.15g.
    if v is None:
        return ''
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return '1' if v else ''
    if isinstance(v, int):
        return str(v)
    if v != v:
        return 'NaN'
    if math.isinf(v):
        return 'Inf' if v > 0 else '-Inf'
    s = '%.15g' % v
    return '0' if s == '-0' else s


def num(v):
    # A value as Perl numifies it.
    return v if isinstance(v, (int, float)) else float(v)


RNG = None
fail_by, failures = {}, []
counts = {'checks': 0, 'fails': 0}


def check(what, ok, detail):
    counts['checks'] += 1
    if ok:
        return 1
    counts['fails'] += 1
    fail_by[what] = fail_by.get(what, 0) + 1
    if len(failures) < 25:
        failures.append('%s: %s' % (what, detail))
    return 0


def rand(n=1):
    return RNG.rand(n)


#------------------------------------------------------------------------------
# A random looped network.  Grid-based so it always has real loops, with
# random extra chords, a mix of pipe sizes, two supplies (one static, one on a
# falling curve -- so there is a pseudo-loop), pressure-dependent outlets, a
# fixed-flow demand, and sometimes Darcy-Weisbach.
#
# The model is held as parts, so a transform can change one kind of line
# without parsing text back:
#   units     [quantity, unit] for each UNITS line
#   settings  the METHOD and OPTION lines
#   nodes     [command, name, elevation, fields ...]: NODE, WATER, SPRINKLER,
#             HYDRANT -- each defines its node
#   pipes     { id, a, b, len, size, c, eqv }: written as a USE BORE line (the
#             C factor, or the roughness under Darcy-Weisbach), the PIPE line
#             and an EQV line, kept together because a USE applies to the
#             pipes after it
#   fixed     [name, node, flow] for each FIXEDFLOW
# render() writes it as .phc text.
#
# The calls to rand are made in the Perl's order, element by element, so the
# stream is consumed identically.
#------------------------------------------------------------------------------
def random_model():
    r = 2 + int(rand(4))          # 2..5 rows
    c = 2 + int(rand(4))          # 2..5 cols
    dw = rand() < 0.3
    names, pipes = [], []
    for i in range(r):
        for j in range(c):
            names.append('N%d_%d' % (i, j))
    z = {}
    for n in names:
        z[n] = '%.2f' % rand(12)
    pid = [0]
    dia = [50, 65, 80, 100, 150]

    def pipe(a, b):
        pid[0] += 1
        ln = '%.2f' % (3 + rand(40))
        size = dia[int(rand(len(dia)))]
        cc = ('%.3f' % (0.01 + rand(0.2))) if dw else 100 + 10 * int(rand(5))
        eqv = ('%.2f' % rand(8)) if rand() < 0.4 else None
        pipes.append({'id': 'P%d' % pid[0], 'a': a, 'b': b, 'len': ln,
                      'size': size, 'c': cc, 'eqv': eqv})
    for i in range(r):
        for j in range(c):
            if j + 1 < c:
                pipe('N%d_%d' % (i, j), 'N%d_%d' % (i, j + 1))
            if i + 1 < r:
                pipe('N%d_%d' % (i, j), 'N%d_%d' % (i + 1, j))
    for _ in range(int(rand(3))):          # a few diagonal chords
        a = names[int(rand(len(names)))]
        b = names[int(rand(len(names)))]
        if a != b:
            pipe(a, b)
    # Each node is defined by what is at it: the two supplies, the outlets,
    # and plain junctions everywhere else.  An outlet's minimum is a pressure,
    # given as a negative MINFLOW.
    at = {}
    at[names[0]] = ['WATER', '%.0f' % (900 + rand(600))]
    w2 = ['WATER', '%.0f' % (800 + rand(400))]
    w2 += [2000, '%.0f' % (500 + rand(200))]
    w2 += [4000, '%.0f' % (200 + rand(150))]
    at[names[c - 1]] = w2
    at[names[-1]] = ['SPRINKLER', -50, '%.1f' % (60 + rand(60))]
    if len(names) > 4:
        at[names[int(len(names) / 2)]] = ['HYDRANT', -100, '%.1f' % (50 + rand(80))]
    nodes = []
    for n in names:
        f = at.get(n) or ['NODE']
        nodes.append([f[0], n, z[n]] + f[1:])
    return {
        'units': [['FLOW', 'LPM'], ['PRESSURE', 'KPA'], ['LENGTH', 'M'], ['ELEVATION', 'M'],
                  ['SIZE', 'MM'], ['KFACTOR', 'LPM/KPA']],
        'settings': ['METHOD ' + ('DW' if dw else 'HW'), 'OPTION TOL_FLOW 1E-7',
                     'OPTION TOL_LOOP 1E-8', 'OPTION MAXITER 200000'],
        'nodes': nodes,
        'pipes': pipes,
        'fixed': [['F1', names[1], '%.0f' % (100 + rand(400))]],
    }


# render -- the model as .phc text.
def render(m):
    l = (['UNITS ' + ' '.join(pstr(x) for x in u) for u in m['units']]
         + list(m['settings'])
         + [' '.join(pstr(x) for x in n) for n in m['nodes']])
    for p in m['pipes']:
        l.append('USE BORE %s' % pstr(p['c']))
        l.append('PIPE %s %s %s %s %s' % (p['id'], p['a'], p['b'], pstr(p['len']), pstr(p['size'])))
        if p['eqv'] is not None:
            l.append('EQV %s %s' % (p['id'], pstr(p['eqv'])))
    l += ['FIXEDFLOW ' + ' '.join(pstr(x) for x in f) for f in m['fixed']]
    return ''.join(x + '\n' for x in l)


# copy -- a deep copy of a model, for a transform to change.
def copy(m):
    return {'units': [list(u) for u in m['units']], 'settings': list(m['settings']),
            'nodes': [list(n) for n in m['nodes']], 'pipes': [dict(p) for p in m['pipes']],
            'fixed': [list(f) for f in m['fixed']]}


#------------------------------------------------------------------------------
def err_text(e):
    return e.msg if hardycross.is_model_error(e) else str(e)


def solve(text):
    try:
        net = phc.read_string(text)
    except Exception as e:
        return None, e
    if not net:
        return None, None
    try:
        ok = hardycross.solve_model(net)
    except Exception as e:
        return None, e
    if ok is None:
        return None, None
    return net, ok


def flows(net):
    return {e['id']: e['q'] for e in net['elems'][1:]}


def gauge(net):
    return {n['id']: n['h'] - hardycross.GAMMA_W * n['z']
            for n in net['nodes'][1:] if n['id'] != 'REF'}


# The worst disagreement between two flow maps, over the keys they share.
def worst(a, b, mp=None):
    w = 0
    for k in a:
        kb = mp(k) if mp else k
        if kb not in b:
            return 1e30
        d = abs(a[k] - b[kb])
        if d > w:
            w = d
    return w


# Direct checks on one solution, independent of any other solve.
def audit(tag, net):
    finite = 1
    for e in net['elems'][1:]:
        if e['q'] != e['q'] or abs(e['q']) > 1e12:
            finite = 0
    for n in net['nodes'][1:]:
        if n['h'] != n['h'] or abs(n['h']) > 1e12:
            finite = 0
    check('finite', finite, '%s: a NaN or runaway value in the solution' % tag)
    cont = hardycross.continuity_error(net)
    check('continuity', cont < 1e-6, '%s: continuity %.2e L/min' % (tag, cont))
    wl = 0
    for lp in net['loops']:
        s = 0
        for st in lp:
            e = net['elems'][st[0]]
            hf = hardycross.elem_hf(e, e['q'], net['opts'])[0]
            s += st[1] * hf
        if abs(s) > wl:
            wl = abs(s)
    check('loop closure', wl < 1e-4, '%s: worst loop closure %.2e kPa' % (tag, wl))


#------------------------------------------------------------------------------
# Transforms.  Each takes a model and returns the new .phc text, plus how to
# map an id across where one changes.
#------------------------------------------------------------------------------
def t_shuffle(m):
    m = copy(m)
    # Every line in a different order; a pipe keeps its USE line in front.
    for k in ('nodes', 'pipes', 'settings', 'units'):
        m[k] = RNG.shuffle(m[k])
    return render(m)


def t_reverse(m):
    m = copy(m)
    rev = {}
    for p in m['pipes']:
        if not rand() < 0.5:
            continue
        p['a'], p['b'] = p['b'], p['a']
        rev[p['id']] = 1
    return render(m), rev


def t_datum(m, dz):
    m = copy(m)
    for n in m['nodes']:
        n[2] = '%.4f' % (num(n[2]) + dz)
    return render(m)


def t_split(m):
    m = copy(m)
    p = m['pipes'][int(rand(len(m['pipes'])))]
    f = 0.2 + rand(0.6)
    # The fitting allowance stays on the first half; it is a length like any
    # other, so where it sits along the pipe cannot change the flow.
    q = dict(p)
    q.update({'id': p['id'] + 'B', 'a': 'MIDSPLIT',
              'len': '%.6f' % (num(p['len']) * (1 - f)), 'eqv': None})
    m['pipes'].append(q)
    p['b'], p['len'] = 'MIDSPLIT', '%.6f' % (num(p['len']) * f)
    m['nodes'].append(['NODE', 'MIDSPLIT', '5.0'])
    return render(m), p['id']


# rename_id -- the new name of a node (and of the supply or outlet at it).
def rename_id(k):
    return re.sub(r'\bN(\d+)_(\d+)\b', r'JX\2Y\1', k)


def t_rename(m):
    return rename_id(render(m))


def t_units(m):
    m = copy(m)
    # L/s, bar, mm lengths, cm elevations, inch bores, K in L/s per root bar:
    # every quantity in a different unit.
    qf, pf, lf, zf, sf = 1 / 60, 1 / 100, 1000, 100, 1 / 25.4
    kf = qf / math.sqrt(pf)
    m['units'] = [['FLOW', 'LPS'], ['PRESSURE', 'BAR'], ['LENGTH', 'MM'], ['ELEVATION', 'CM'],
                  ['SIZE', 'IN'], ['KFACTOR', 'LPS/BAR']]
    st = []
    for s in m['settings']:
        s = re.sub(r'TOL_FLOW (\S+)', lambda x: 'TOL_FLOW ' + pstr(float(x.group(1)) * qf), s, count=1)
        s = re.sub(r'TOL_LOOP (\S+)', lambda x: 'TOL_LOOP ' + pstr(float(x.group(1)) * pf), s, count=1)
        st.append(s)
    m['settings'] = st
    for n in m['nodes']:
        cmd, name, z, f = n[0], n[1], n[2], n[3:]
        z = num(z) * zf
        if cmd == 'WATER':
            f[0] = num(f[0]) * pf
            k = 1
            while k + 1 <= len(f) - 1:
                f[k] = num(f[k]) * qf
                f[k + 1] = num(f[k + 1]) * pf
                k += 2
        elif cmd != 'NODE':
            f[0] = num(f[0]) * (pf if num(f[0]) < 0 else qf)
            f[1] = num(f[1]) * kf
        n[:] = [cmd, name, z] + f
    for p in m['pipes']:
        p['len'] = num(p['len']) * lf
        if p['eqv'] is not None:
            p['eqv'] = num(p['eqv']) * lf
        p['size'] = num(p['size']) * sf
        if m['settings'][0] == 'METHOD DW':
            p['c'] = num(p['c']) * sf
    for f in m['fixed']:
        f[2] = num(f[2]) * qf
    return render(m)


#------------------------------------------------------------------------------
def main():
    global RNG
    args = sys.argv[1:]
    CASES = int(args[0]) if len(args) > 0 else 60
    SEED = int(args[1]) if len(args) > 1 else 20260921
    RNG = PerlRand(SEED)

    print('HARDY CROSS PYTHON ENGINE - INVARIANCE STRESS')
    print('cases %d, seed %d\n' % (CASES, SEED))

    wst = {}
    solved = notconv = 0
    for case in range(1, CASES + 1):
        base = random_model()
        n0, ok0 = solve(render(base))
        if not n0:
            check('base solve', 0, 'case %d: %s' % (case, err_text(ok0) if ok0 is not None else ''))
            continue
        if not ok0:
            notconv += 1
            continue
        solved += 1
        audit('case %d base' % case, n0)
        q0, p0 = flows(n0), gauge(n0)
        tag = 'case %d' % case

        # repeat: identical text, identical answer
        nr = solve(render(base))[0]
        wr = worst(q0, flows(nr))
        check('repeat', wr == 0, '%s: second solve differs by %.2e' % (tag, wr))
        wst['repeat'] = max(wst.get('repeat', 0), wr)

        # shuffle
        ns = solve(t_shuffle(base))[0]
        if ns:
            audit('%s shuffle' % tag, ns)
            w = worst(q0, flows(ns))
            check('shuffle', w < 1e-3, '%s: flows moved %.2e L/min' % (tag, w))
            wst['shuffle'] = max(wst.get('shuffle', 0), w)
        else:
            check('shuffle', 0, '%s: shuffled model did not solve' % tag)

        # reverse
        rtxt, rev = t_reverse(base)
        nv = solve(rtxt)[0]
        if nv:
            qv = flows(nv)
            w = 0
            for k in q0:
                want = -q0[k] if rev.get(k) else q0[k]
                w = max(w, abs(qv.get(k, 0) - want))
            check('reverse', w < 1e-3, '%s: reversed pipes off by %.2e L/min' % (tag, w))
            wst['reverse'] = max(wst.get('reverse', 0), w)
        else:
            check('reverse', 0, '%s: reversed model did not solve' % tag)

        # datum
        dz = -20 + rand(60)
        nd = solve(t_datum(base, dz))[0]
        if nd:
            wq = worst(q0, flows(nd))
            wp = worst(p0, gauge(nd))
            check('datum', wq < 1e-3 and wp < 1e-3,
                  '%s: raising the site %.1f m moved flows %.2e, pressures %.2e' % (tag, dz, wq, wp))
            wst['datum'] = max(wst.get('datum', 0), wq)
        else:
            check('datum', 0, '%s: datum-shifted model did not solve' % tag)

        # split
        stxt, sid = t_split(base)
        nsp = solve(stxt)[0]
        if nsp:
            qs = flows(nsp)
            w = 0
            for k in q0:
                w = max(w, abs(qs.get(k, 0) - q0[k]))
            w = max(w, abs(qs.get(sid + 'B', 0) - q0[sid]))   # the new half carries the same flow
            check('split', w < 1e-3, '%s: splitting %s moved flows %.2e L/min' % (tag, sid, w))
            wst['split'] = max(wst.get('split', 0), w)
        else:
            check('split', 0, '%s: split model did not solve' % tag)

        # rename
        nn = solve(t_rename(base))[0]
        if nn:
            w = worst(q0, flows(nn), rename_id)
            check('rename', w < 1e-3, '%s: renaming nodes moved flows %.2e' % (tag, w))
            wst['rename'] = max(wst.get('rename', 0), w)
        else:
            check('rename', 0, '%s: renamed model did not solve' % tag)

        # units
        nu, oku = solve(t_units(base))
        if nu:
            qu = flows(nu)        # internal L/min regardless of input units
            w = worst(q0, qu)
            pu = gauge(nu)
            wp = worst(p0, pu)
            check('units', w < 1e-2 and wp < 1e-2,
                  '%s: L/s-bar-mm-cm-in model differs by %.2e L/min, %.2e kPa' % (tag, w, wp))
            wst['units'] = max(wst.get('units', 0), w)
        else:
            check('units', 0, '%s: unit-converted model did not solve: %s'
                  % (tag, err_text(oku) if oku is not None else ''))

    #--------------------------------------------------------------------------
    # The pipe database resolver, fuzzed.  It must never return a number for
    # a fitting the database does not hold, never die on bad input, and its
    # total must always equal the sum of its records.
    #--------------------------------------------------------------------------
    print('PIPE DATABASE RESOLVER FUZZ')
    pipedata.load()
    types = pipedata.pipe_types()
    codes = (['E', 'E45', 'T', 'GV', 'CV'] * 6
             + 'EF EL GV75 GV50 GV25 CVM CVB BV AV GLV TR CPL EM1 EM3 E15 XX Q9'.split())
    # steel sizes weighted up; PE sizes and a nonsense DN kept for the refusal path
    dns = ([25, 32, 40, 50, 65, 80, 100, 150, 200, 250, 300] * 3
           + [15, 20, 125, 350, 400, 450, 500, 600, 75, 90, 110, 999])
    rn = rdash = rok = 0
    for _ in range(4000):
        type_ = types[int(rand(len(types)))]
        dn = dns[int(rand(len(dns)))]
        sep = ',' if rand() < 0.5 else ''
        parts = []
        for _ in range(1 + int(rand(4))):
            cnt = int(rand(4))
            parts.append((str(cnt) if cnt else '') + codes[int(rand(len(codes)))])
        spec = sep.join(parts)
        if rand() < 0.05:
            spec = ''.join(chr(33 + int(rand(90))) for _ in range(1 + int(rand(8))))
        try:
            r, died = pipedata.resolve(type=type_, dn=dn, spec=spec), ''
        except Exception as e:
            r, died = None, str(e)
        rn += 1
        if not check('resolver never dies', r is not None,
                     "resolve(%s, DN%d, '%s') died: %s" % (type_, dn, spec, died)):
            continue
        any_dr = [x for x in r['records'] if (x.get('status') or '') == 'DATA_REQUIRED']
        if any_dr or r['errors']:
            rdash += 1
            check('gap is never a number', r['total'] is None,
                  "resolve(%s, DN%d, '%s') returned %s despite a gap"
                  % (type_, dn, spec, pstr(r['total']) if r['total'] is not None else 'undef'))
        else:
            rok += 1
            sm = 0
            for x in r['records']:
                sm += x.get('total') or 0
            check('total = sum of records',
                  abs(sm - (r['total'] if r['total'] is not None else -1)) < 1e-9,
                  "resolve(%s, DN%d, '%s'): total %s vs sum %s"
                  % (type_, dn, spec, pstr(r['total']) if r['total'] is not None else 'undef', pstr(sm)))
            check('allowance never negative', (r['total'] or 0) >= 0,
                  "resolve(%s, DN%d, '%s') negative" % (type_, dn, spec))
    print('  %d strings: %d resolved, %d refused as DATA_REQUIRED or invalid\n' % (rn, rok, rdash))

    #--------------------------------------------------------------------------
    print('RESULTS')
    print('  %d random networks, %d converged, %d did not' % (CASES, solved, notconv))
    print('\n  worst disagreement per transform (L/min)')
    for k in sorted(wst):
        print('    %-10s %.3e' % (k, wst[k]))
    print('\n  %d checks, %d failed' % (counts['checks'], counts['fails']))
    if fail_by:
        print('\n  failures by kind')
        for k in sorted(fail_by):
            print('    %-28s %d' % (k, fail_by[k]))
        print('\n  first failures')
        for f in failures:
            print('    %s' % f)
    sys.exit(1 if counts['fails'] else 0)


if __name__ == '__main__':
    main()
