#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# sizing.py -- Python port of HardyCross/Sizing.pm.
#
# Auto pipe sizing: a PIPE (or CHANGEPIPE) line with SIZE 0 asks for the
# sizes to be chosen from the database, to a stated goal (SMALLEST or
# VOLUME), against supplies reduced by a stated margin, with the velocity
# limit held.  A search of several trials; see Sizing.pm for the whole
# rationale.  The port follows it line for line, including the fixed
# pseudo-random sequence, so the same model always gives the same sizes.
#

import math
import re

from . import (pipe_velocity, fit_curve, curve_eval, solve_model)
from . import pipedata
from .phc import read_string, fitting_code, inch_sizes
from .parse import ensure_db
from .report import sym

VEL_WEIGHT = 50      # kPa of shortfall counted per m/s over the limit
MAX_STEPS  = 2000    # a ceiling on the search, never reached in practice
SWAP_MAX   = 40      # the swap pass is skipped for more pipes than this
TRIALS     = 5       # trials unless OPTION SIZING_TRIALS says otherwise

PI = 4 * math.atan2(1, 1)


#------------------------------------------------------------------------------
# choices -- the sizes a pipe of $type with fittings $fits may be.
#------------------------------------------------------------------------------
def choices(type_, fits, unit):
    ensure_db()
    inch = {v: k for k, v in inch_sizes().items()}
    spec = ','.join(fitting_code(f) for f in (fits or []))
    out = []
    for dn in range(1, 1201):
        if not pipedata.pipe_row(type_, dn):
            continue
        bore = pipedata.bore(type_, dn)
        if not bore:
            continue
        if len(spec):
            r = pipedata.resolve(type=type_, dn=dn, spec=spec)
            if r.get('total') is None:
                continue
        tok = inch.get(dn) if (unit or 'MM') == 'IN' else dn
        if tok is not None:
            # bore as a number: the database holds it as text ('53.0'), and
            # the sums below use it as one (Perl numified it silently).
            out.append([dn, tok, float(bore)])
    return out

#------------------------------------------------------------------------------
# margin_of -- the SIZING_MARGIN setting as { kind => 'PERCENT', f } or
# { kind => 'FIXED', p } (p in kPa), with the text the report prints.
#------------------------------------------------------------------------------
def margin_of(v, net):
    if v is None or not len(v):
        return {'kind': 'FIXED', 'p': 0, 'text': 'none (SIZING_MARGIN not set)'}
    m = re.match(r'^([\d.]+)%\Z', v)
    if m:
        return {'kind': 'PERCENT', 'f': float(m.group(1)) / 100,
                'text': '%s%% of the supply pressure' % m.group(1)}
    return {'kind': 'FIXED', 'p': float(v) * net['f_pres'],
            'text': '%s %s below the supply' % (v, sym(net['u_pres']))}

# reduce -- every supply in a network lowered by the margin (plus $extra
# kPa): what the sized network must still satisfy.
def reduce(net, m, extra):
    sup = [e for e in net['elems'][1:] if e['kind'].startswith('SUPPLY_')]
    hose = (net['opts'].get('hose') or 0) if len(sup) == 1 else 0

    def g(p):
        p = p * (1 - m['f']) if m['kind'] == 'PERCENT' else p - m['p']
        return p - extra

    for s in sup:
        if s['kind'] == 'SUPPLY_STATIC':
            s['pstat'] = g(s['pstat'])
            continue
        c = s['curve']
        q = [0] + [x for x in (y - hose for y in c['q']) if x > 1e-9]
        if len(q) < 2:
            q.append(q[-1] + (c['qhi'] or 1))
        seen = set()
        qq = []
        for x in q:
            key = '%.9g' % x
            if key in seen:
                continue
            seen.add(key)
            qq.append(x)
        s['curve'] = fit_curve({'q': qq,
                               'p': [g(curve_eval(c, x + hose)) for x in qq]}, 0)

#------------------------------------------------------------------------------
# size -- ($net, $ok) of the model with its size-0 pipes sized.
#------------------------------------------------------------------------------
def size(net, ok, **arg):
    units = net.get('auto_sizing')
    if not units:
        return net, ok
    from . import demand
    text = net['source_text']
    lines = text.split('\n')
    o = net.get('sizing_opts') or {}
    goal = o.get('SIZING_GOAL') or 'SMALLEST'
    ntrials = o.get('SIZING_TRIALS')
    ntrials = TRIALS if ntrials is None else ntrials
    # OPTION SIZING_TRIALS is kept as its text (the report prints it as
    # given, as the Perl does); the search counts with its number, as the
    # Perl's 1 .. $ntrials and %d numify it.
    nt = int(ntrials)
    progress = arg.get('progress')
    trial = 0
    m = margin_of(o.get('SIZING_MARGIN'), net)
    vlim = net['opts'].get('vel_limit')
    vlim = 6 if vlim is None else vlim
    lens = {e['id']: e['len'] for e in net['elems'][1:] if e['kind'] == 'PIPE'}
    for u in units:
        u['length'] = 0
        for p in u['pipes']:
            u['length'] += lens.get(p) or 0
    if net.get('areas') and net.get('design_area') is None:
        cases = [a['name'] for a in net['areas']]
    else:
        cases = [None]
    dir_ = net.get('model_dir')
    solves = 0

    # The model text with each unit at the size chosen by $idx.
    def sized(idx):
        l = list(lines)
        for i in range(len(units)):
            u = units[i]
            l[u['line'] - 1] = set_field(l[u['line'] - 1], u['field'],
                                          u['choices'][idx[i]][1])
        return '\n'.join(l)

    # How far the network is from passing with the supplies reduced: 0 when
    # it passes; the solve's velocities of each unit for the search.
    extra = 0

    def assess(idx):
        nonlocal solves
        t = sized(idx)
        if not t.endswith('\n'):
            t += '\n'
        if progress:
            progress('AUTO SIZING %d PIPE%s - TRIAL %d OF %d - %d SOLVES'
                     % (len(units), '' if len(units) == 1 else 'S',
                        trial or 1, nt, solves))
        short = 0
        vel = [None] * len(units)
        for case in cases:
            case_text = t + ('OPTION DESIGN_AREA %s\n' % case if case is not None else '')
            # The outlets: with every supply reduced by the margin.
            try:
                n = read_string(case_text, dir_)
            except Exception:
                return {'short': 1e12}
            reduce(n, m, extra)
            solves += 1
            try:
                c = solve_model(n)
            except Exception:
                c = None
            if not c:
                return {'short': 1e9}
            _, mg = demand.governing_outlet(n)
            if mg is not None and mg < 0:
                short += -mg
            # The velocities: at the operating point, with the supply as it
            # is - the most water the pipes carry.
            try:
                f = read_string(case_text, dir_)
            except Exception:
                return {'short': 1e12}
            solves += 1
            # As the Perl's eval { solve_model($f) } or return: a solve
            # that does not converge fails the trial, as one that dies.
            try:
                cf = solve_model(f)
            except Exception:
                cf = None
            if not cf:
                return {'short': 1e9}
            emap = {e.get('id') or '': e for e in f['elems'][1:]}
            for i in range(len(units)):
                for p in units[i]['pipes']:
                    e = emap.get(p)
                    if not e:
                        continue
                    v = abs(pipe_velocity(e['q'], e['dia']))
                    if vel[i] is None or v > vel[i]:
                        vel[i] = v
                    if v > vlim + 1e-9:
                        short += VEL_WEIGHT * (v - vlim)
        return {'short': short, 'vel': vel}

    def volume(u, k):
        return u['length'] * PI / 4 * (u['choices'][k][2] / 1000) ** 2

    def cost(i, frm, to):
        if goal == 'VOLUME':
            return abs(volume(units[i], to) - volume(units[i], frm)) or 1e-12
        return 1

    # What is made least: the pipes' size, length-weighted (SMALLEST), or
    # the water they hold (VOLUME).
    def objective(idx):
        sum_ = 0
        for i in range(len(units)):
            d = units[i]['choices'][idx[i]][2] / 1000
            sum_ += units[i]['length'] * (PI / 4 * d * d if goal == 'VOLUME' else d)
        return sum_

    def passes_at(idx):
        return assess(idx)['short'] <= 1e-6

    def top(i):
        return len(units[i]['choices']) - 1

    # up -- one size at a time, the step doing most good for its cost,
    # until the network passes.
    def up(idx):
        now = assess(idx)
        steps = 0
        while now['short'] > 1e-6 and steps < MAX_STEPS:
            steps += 1
            best = None
            bscore = None
            bres = None
            for i in range(len(units)):
                if idx[i] >= top(i):
                    continue
                t = list(idx)
                t[i] += 1
                r = assess(t)
                score = (now['short'] - r['short']) / cost(i, idx[i], t[i])
                if bscore is None or score > bscore:
                    best, bscore, bres = i, score, r
            if best is None:
                break
            # No step helps (the network does not solve yet, say): enlarge
            # the fastest pipe.
            if bscore <= 0:
                open_ = [i for i in range(len(units)) if idx[i] < top(i)]
                # A failed assessment has no velocities: all count as 0.
                vel = now.get('vel') or [None] * len(units)
                best = sorted(open_, key=lambda b: -(vel[b] or 0))[0]
                t = list(idx)
                t[best] += 1
                bres = assess(t)
            idx[best] += 1
            now = bres
        return now['short'] <= 1e-6

    # down -- each pipe one size smaller, the biggest saving first, kept
    # while the network still passes, until none can be.
    def down(idx):
        changed = True
        while changed:
            changed = False
            # The biggest saving first, and among equal savings the largest
            # DN first (the Perl sorts both descending, numerically).
            order = sorted([i for i in range(len(units)) if idx[i] > 0],
                           key=lambda b: (-cost(b, idx[b], idx[b] - 1),
                                          -float(units[b]['choices'][idx[b]][0])))
            for i in order:
                t = list(idx)
                t[i] -= 1
                if passes_at(t):
                    idx[:] = t
                    changed = 1

    # swap -- one pipe a size up and another a size down, kept when it
    # still passes and costs less.
    def swap(idx):
        if len(units) > SWAP_MAX:
            return
        better = True
        while better:
            better = False
            done = False
            for i in range(len(units)):
                if idx[i] >= top(i):
                    continue
                for j in [x for x in range(len(units)) if x != i and idx[x] > 0]:
                    t = list(idx)
                    t[i] += 1
                    t[j] -= 1
                    if not objective(t) < objective(idx) - 1e-12:
                        continue
                    if passes_at(t):
                        idx[:] = t
                        better = True
                        done = True
                        break
                if done:
                    break

    # A fixed sequence of "random" numbers, so the same model always gives
    # the same sizes.
    seed = 20261101

    def rand():
        nonlocal seed
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648

    idx = None
    trials = None
    passes = None
    dmargin = None
    required = None
    for _round in range(1, 7):
        trials = []
        best = None
        bobj = None
        for k in range(1, nt + 1):
            trial = k
            before = solves
            if k == 1:
                t = [0] * len(units)
                frm = 'the smallest sizes'
            elif k == 2:
                t = [top(i) for i in range(len(units))]
                frm = 'the largest sizes'
            else:
                # From the best so far, with about a third of the pipes
                # moved a size or two up and a third a size down.
                if not best:
                    break
                t = list(best)
                for i in range(len(t)):
                    r = rand()
                    if r < 1 / 3:
                        t[i] += 1 + int(rand() * 2)
                    if r > 2 / 3:
                        t[i] -= 1
                    if t[i] < 0:
                        t[i] = 0
                    if t[i] > top(i):
                        t[i] = top(i)
                frm = 'the best so far, varied'
            okk = up(t)
            if okk:
                down(t)
                swap(t)
            obj = objective(t)
            trials.append({'trial': k, 'from': frm, 'passes': 1 if okk else 0,
                           'objective': obj, 'solves': solves - before,
                           'sizes': [units[i]['choices'][t[i]][0] for i in range(len(t))]})
            if okk and (bobj is None or obj < bobj - 1e-12):
                best, bobj = list(t), obj
            # The largest sizes do not pass: no trial can.
            if k == 2 and not okk and not best:
                break
        if not best:                    # nothing passes: the largest sizes
            idx = [top(i) for i in range(len(units))]
            passes = 0
            break
        idx = list(best)
        # The first trial to reach the best is the one chosen; any other
        # reaching it too is marked SAME.
        marked = False
        for tr in trials:
            if not (tr['passes'] and abs(tr['objective'] - bobj) < 1e-12):
                continue
            tr['same' if marked else 'best'] = 1
            marked = True

        # The check that counts: with one supply, the demand point itself.
        passes, dmargin, required = 1, None, None
        t = sized(idx)
        for case in cases:
            n = read_string(t + ('' if t.endswith('\n') else '\n')
                            + ('OPTION DESIGN_AREA %s\n' % case if case is not None else ''),
                            dir_)
            try:
                c = solve_model(n)
            except Exception:
                c = None
            if not c:
                passes = 0
                continue
            d = demand.demand_point(n)
            if d.get('margin') is None:
                continue
            need = m['f'] * d['p_avail'] if m['kind'] == 'PERCENT' else m['p']
            gap = d['margin'] - need
            if dmargin is None or gap < dmargin - required:
                dmargin, required = d['margin'], need
            if gap < -0.01:
                passes = 0
        if passes:
            break
        # Short at the demand point: ask for that much more and search again.
        extra += (required - dmargin) + 0.5
    if passes is None:
        passes = 0

    # The answer, solved and reported as any model.
    t = sized(idx)
    out = read_string(t, dir_)
    try:
        c = solve_model(out)
    except Exception:
        c = None
    emap = {e.get('id') or '': e for e in out['elems'][1:]}
    res = []
    for i in range(len(units)):
        u = units[i]
        vs = sorted((abs(pipe_velocity(e['q'], e['dia']))
                     for e in (emap.get(p) for p in u['pipes']) if e), reverse=True)
        v = vs[0] if vs else None
        res.append({'line': u['line'], 'kind': u['kind'], 'pipes': list(u['pipes']),
                    'type': u['type'], 'lines': sorted(u['lines']),
                    'dn': u['choices'][idx[i]][0], 'token': u['choices'][idx[i]][1],
                    'velocity': v})
    out['sizing'] = {'units': res, 'goal': goal, 'margin': m['text'], 'passes': passes,
                     'trials': trials, 'ntrials': ntrials,
                     'demand_margin': dmargin, 'required': required, 'solves': solves,
                     'vel_limit': vlim, 'text': text}
    out.setdefault('warnings', [])
    if not passes:
        out['warnings'].append('auto sizing: even the largest sizes in the database do not meet the demand with '
                               'the margin asked for (%s); the pipes are left at those sizes' % m['text'])
    out['converged'] = c
    return out, c

#------------------------------------------------------------------------------
# set_field -- a .phc line with its $n-th field (0 = the command) replaced,
# spacing and comment kept.
#------------------------------------------------------------------------------
def set_field(line, n, value):
    m = re.match(r'^(.*?)((?://.*)?)\Z', line, re.S)
    code, rest = m.group(1), m.group(2)
    i = -1

    def repl(mm):
        nonlocal i
        i += 1
        return str(value) if i == n else mm.group(1)

    return re.sub(r'(\S+)', repl, code) + rest

#------------------------------------------------------------------------------
# annotate -- the user's own .phc text with each sized pipe's size written as
# a comment after its line: //AS - 25.
#------------------------------------------------------------------------------
def annotate(text, sizing, offset=0):
    l = text.split('\n')
    tok = {}
    for u in (sizing.get('units') or []):
        for n in u['lines']:
            tok[n - (offset or 0)] = u['token']
    for n in tok:
        if n < 1 or n > len(l):
            continue
        l[n - 1] = mark(l[n - 1], tok[n])
    return '\n'.join(l)

# mark -- one line with //AS - <size> after its fields.
def mark(line, tok):
    m = re.match(r'^(.*?)\s*((?://.*)?)\Z', line, re.S)
    code, comment = m.group(1), m.group(2)
    comment = re.sub(r'^//AS - \S+\s*', '', comment)
    return '%s  //AS - %s%s' % (code, tok, (' ' + comment) if len(comment) else '')

# clear -- the //AS comments taken off again (a pipe no longer sized).
def clear(text):
    text = re.sub(r'[ \t]*//AS - \S+[ \t]*(//)', r' \1', text, flags=re.M)
    text = re.sub(r'[ \t]*//AS - \S+[ \t]*$', '', text, flags=re.M)
    return text
