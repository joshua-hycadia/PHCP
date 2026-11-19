#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_sizing.py -- auto pipe sizing (hardycross.sizing), headless.  A port
# of tools/test_sizing.pl.
#
#   python3 tools/test_sizing.py
#
#   1. READING.  SIZE 0 under a pipe type reads, at the smallest size with
#      every fitting in the database; under USE BORE it is refused; the two
#      settings are checked.
#   2. THE ANSWER PASSES.  Checked here, independently of the search: the
#      sized model re-read and its demand point found - the margin under the
#      supply is at least what was asked, as a percentage or a pressure, and
#      no sized pipe exceeds the velocity limit.
#   3. NO SMALLER WILL DO.  Each sized pipe one size smaller fails that same
#      check (SMALLEST).  VOLUME holds no more water than SMALLEST.
#   4. WHAT IS SIZED TOGETHER.  A PIPE line sizes its copies (PC) with it, and
#      the size is written after the PC line too; a CHANGEPIPE line sizes its
#      one pipe.
#   5. THE COMMENTS.  //AS - <size> after each sized line, SIZE 0 kept, a
#      comment of the user's own kept after it, an old //AS replaced; the
#      annotated model sizes the same again.
#   6. WHEN NOTHING WILL DO.  A supply too weak: the largest sizes, a warning,
#      and the report says NOT MET.
#   7. WITH DESIGN AREAS, IN INCHES, IN THE REPORT AND THE JSON.
#==============================================================================

import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, demand, sizing, areas, report, jsonout, pipedata

PASS = [0]
FAIL = [0]


def is_(name, ok, why=None):
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


def refused(name, text, rx):
    net, e = None, ''
    try:
        net = phc.read_string(text)
    except Exception as ex:
        e = ex.msg if hardycross.is_model_error(ex) else str(ex)
    is_(name, not net and re.search(rx, e), 'it was accepted' if net else 'got: %s' % e)


# sized -- the model read, solved and sized, as phcp does it.
def sized(text):
    n = phc.read_string(text)
    ok = hardycross.solve_model(n)
    n, ok = sizing.size(n, ok)
    return n, ok


def elems(n):
    return n['elems'][1:]


# check -- the independent check of a model text with sizes in it: the
# demand point's margin against what is asked, and the sized pipes' speeds.
def check(text, pipes, pct=None, fixed=None, vlim=None):
    n = phc.read_string(text)
    if not hardycross.solve_model(n):
        return {'ok': 0, 'why': 'no solve'}
    d = demand.demand_point(n)
    if d.get('margin') is None:
        return {'ok': 0, 'why': d.get('reason')}
    need = pct / 100 * d['p_avail'] if pct else (fixed if fixed is not None else 0)
    e = {(x.get('id') if x.get('id') is not None else ''): x for x in elems(n)}
    vmax = sorted((abs(hardycross.pipe_velocity(e[p]['q'], e[p]['dia'])) for p in pipes), reverse=True)[0]
    return {'ok': d['margin'] >= need - 0.01 and vmax <= (vlim if vlim is not None else 6) + 1e-6,
            'margin': d['margin'], 'need': need, 'vmax': vmax}


# with_ -- a model text with each unit at the size given (DN or index).
def with_(text, units, tok):
    l = text.split('\n')
    for i in range(len(units)):
        n = units[i]['line'] - 1
        l[n] = sizing.set_field(l[n], 3 if units[i]['kind'] == 'CHANGEPIPE' else 5, tok[i])
    return '\n'.join(l)


def slurp(p):
    with open(p) as f:
        return f.read()


# A floor: a town main, a riser and two branch lines of four K80 heads.
FLOOR = '\n'.join([
    'UNITS LENGTH M', 'UNITS KFACTOR LPM/BAR',
    'WATER TOWN 0 450 1000 380 2000 250',
    'NODE R0 0', 'NODE R1 4', 'NODE J1 4', 'NODE J2 4',
    'SPRINKLER A1 4 -100 80', 'NC A1 A2 A3 A4 B1 B2 B3 B4',
    'USE ASAM',
    'PIPE M1 TOWN R0 30 100', 'PIPE RS R0 R1 4 100 E', 'PIPE H1 R1 J1 10 80 T',
    'PIPE H2 J1 J2 40 0',
    'PIPE LA1 J1 A1 3 0 T', 'PIPE LA2 A1 A2 3 0', 'PIPE LA3 A2 A3 3 0', 'PIPE LA4 A3 A4 3 0',
    'PIPE LB1 J2 B1 3 0 T', 'PIPE LB2 B1 B2 3 0', 'PIPE LB3 B2 B3 3 0', 'PIPE LB4 B3 B4 3 0', ''])
AUTO = 'H2 LA1 LA2 LA3 LA4 LB1 LB2 LB3 LB4'.split()


def main():
    print('1. READING')
    n = phc.read_string(FLOOR)
    u = {x['pipes'][0]: x for x in (n.get('auto_sizing') or [])}
    dn = {e['id']: e for e in elems(n) if e['kind'] == 'PIPE'}
    is_('nine pipes of size 0 are to be sized', len(u) == 9 and not any(p not in u for p in AUTO))
    is_('   each read at the smallest size its type has: ASAM DN20',
        float(u['LA2']['choices'][0][0]) == 20 and abs(dn['LA2']['dia'] - float(pipedata.bore('ASAM', 20))) < 1e-9)
    is_('   a pipe with a tee starts where the tee has a value too',
        not any(pipedata.resolve(type='ASAM', dn=c[0], spec='T').get('total') is None for c in u['LA1']['choices']))
    is_('   the sizes go up to the largest ASAM has, DN150', float(u['LA2']['choices'][-1][0]) == 150)
    refused('SIZE 0 under USE BORE is refused, saying a pipe type is needed',
            'WATER W 0 500\nSPRINKLER S 0 -50 8\nUSE BORE\nPIPE P1 W S 3 0\n', r'^line 4: .*SIZE 0 .*NEEDS A PIPE TYPE')
    refused('SIZING_GOAL other than SMALLEST or VOLUME', FLOOR + 'OPTION SIZING_GOAL CHEAPEST\n',
            r'SIZING_GOAL IS SMALLEST .* OR VOLUME')
    refused('SIZING_MARGIN that is neither 10% nor a pressure', FLOOR + 'OPTION SIZING_MARGIN TEN\n',
            r"SIZING_MARGIN 'TEN' IS A PERCENTAGE")
    refused('   nor 100% or more', FLOOR + 'OPTION SIZING_MARGIN 100%\n', r'IS A PERCENTAGE')
    refused('   nor below zero', FLOOR + 'OPTION SIZING_MARGIN -5\n', r'IS A PERCENTAGE')
    refused('SIZING_TRIALS of 0', FLOOR + 'OPTION SIZING_TRIALS 0\n',
            r"SIZING_TRIALS '0' IS A WHOLE NUMBER OF TRIALS, 1 TO 50")
    refused('   or 51, or 2.5', FLOOR + 'OPTION SIZING_TRIALS 2.5\n', r'IS A WHOLE NUMBER OF TRIALS')
    c = phc.check_line('PIPE P9 A B 3 0 T', {'use': 'ASAM'})
    is_('the editor\'s line check takes SIZE 0 under a pipe type', c['status'] == 'ok', c.get('message'))

    print('2. THE ANSWER PASSES - checked at the demand point')
    res = {}
    for opt, o in [('SIZING_MARGIN 10%', {'pct': 10}), ('SIZING_MARGIN 50', {'fixed': 50}), ('', {'fixed': 0})]:
        n, ok = sized(FLOOR + (('OPTION %s\n' % opt) if len(opt) else ''))
        s = n['sizing']
        chk = check(n['source_text'], AUTO, **o)
        res[opt] = [n, s]
        is_('%s: passes, margin %.1f kPa against %.1f asked, fastest sized pipe %.2f m/s'
            % (opt if len(opt) else 'no margin', chk.get('margin') or 0, chk.get('need') or 0, chk.get('vmax') or 0),
            ok and s.get('passes') and chk['ok'], chk.get('why'))

    print('3. NO SMALLER WILL DO')
    n, s = res['SIZING_MARGIN 10%']
    u = s['units']
    dns = [x['dn'] for x in u]
    bad = []
    for i in range(len(u)):
        ch = [c[0] for c in phc.read_string(FLOOR)['auto_sizing'][i]['choices']]
        k = next((j for j in range(len(ch)) if float(ch[j]) == float(dns[i])), None)
        if not k:
            continue
        t = list(dns)
        t[i] = ch[k - 1]
        if check(with_(FLOOR, u, t), AUTO, pct=10)['ok']:
            bad.append('%s at DN%s' % (u[i]['pipes'][0], t[i]))
    is_('SMALLEST: each sized pipe one size smaller fails the check', not bad, 'still passes: %s' % ' '.join(bad))
    nv, _ = sized(FLOOR + 'OPTION SIZING_MARGIN 10%\nOPTION SIZING_GOAL VOLUME\n')

    def vol(sz):
        v = 0
        ln = {'H2': 40}
        for x in sz['units']:
            v += ln.get(x['pipes'][0], 3) * (float(pipedata.bore('ASAM', x['dn'])) / 1000) ** 2
        return v * 0.7853981634
    is_('VOLUME: %.1f L of water in the sized pipes, SMALLEST %.1f L - no more'
        % (1000 * vol(nv['sizing']), 1000 * vol(s)),
        nv['sizing'].get('passes') and vol(nv['sizing']) <= vol(s) + 1e-12
        and check(nv['source_text'], AUTO, pct=10)['ok'])

    print('3a. TRIALS')
    n, s = res['SIZING_MARGIN 10%']
    t = s['trials']
    is_('5 trials unless set: from the smallest, from the largest, then varied',
        s['ntrials'] == 5 and len(t) == 5 and t[0]['from'] == 'the smallest sizes'
        and t[1]['from'] == 'the largest sizes' and re.search(r'varied', t[2]['from']))
    chosen = next((x for x in t if x.get('best')), None)
    is_('   exactly one is chosen, and no trial that passes costs less',
        len([x for x in t if x.get('best')]) == 1
        and not any(x.get('passes') and x['objective'] < chosen['objective'] - 1e-12 for x in t))
    is_('   the sizes chosen are that trial\'s',
        ' '.join(str(x['dn']) for x in s['units']) == ' '.join(str(z) for z in chosen['sizes']))
    again, _ = sized(FLOOR + 'OPTION SIZING_MARGIN 10%\n')
    is_('the same model gives the same sizes every time',
        ' '.join(str(x['dn']) for x in again['sizing']['units']) == ' '.join(str(x['dn']) for x in s['units']))
    said = []
    n1 = phc.read_string(FLOOR + 'OPTION SIZING_TRIALS 1\n')
    o1, _ = sizing.size(n1, hardycross.solve_model(n1), progress=lambda m: said.append(m))
    is_('SIZING_TRIALS 1: one trial', len(o1['sizing']['trials']) == 1 and o1['sizing'].get('passes'))
    is_('   and the search says where it is as it goes',
        len(said) > 10 and re.search(r'^AUTO SIZING 9 PIPES - TRIAL 1 OF 1 - \d+ SOLVES\Z', said[-1]),
        said[-1] if said else None)

    # Not in the Perl suite: the solves each trial of example 12 makes, as
    # perl phcp.pl reports them (TRIAL table).  The search's order is what
    # makes them; a tie broken the other way in down() once gave 226, not
    # 242, for the trial from the largest sizes.
    n12 = phc.read_model(os.path.join(ROOT, 'examples', '12_auto_sizing.phc'))
    n12, _ = sizing.size(n12, hardycross.solve_model(n12))
    got = [x['solves'] for x in n12['sizing']['trials']]
    is_('12_auto_sizing: the solves of each trial are the Perl\'s, 844 242 196 96 208',
        got == [844, 242, 196, 96, 208], ' '.join(str(x) for x in got))

    print('4. WHAT IS SIZED TOGETHER')
    m = '\n'.join(['UNITS LENGTH M', 'WATER W 0 400', 'NODE J 0', 'USE ASAM', 'PIPE M W J 20 80',
                   'SPRINKLER S1 0 -50 8', 'NC S1 S2 S3', 'PIPE P1 J S1 6 0 T', 'PC P1 P2 J S2  P3 J S3',
                   'CHANGEPIPE P3 15 0 T E', ''])
    n, _ = sized(m)
    u = {x['line']: x for x in n['sizing']['units']}
    is_('the PIPE line sizes P1 and its unchanged copy P2 together',
        8 in u and ' '.join(u[8]['pipes']) == 'P1 P2' and ' '.join(str(z) for z in u[8]['lines']) == '8 9')
    is_('   the CHANGEPIPE line sizes P3 on its own', 10 in u and ' '.join(u[10]['pipes']) == 'P3')
    d = {e['id']: e['dia'] for e in elems(n) if e['kind'] == 'PIPE'}
    is_('   P1 and P2 come out the same size', d['P1'] == d['P2'])
    a = sizing.annotate(m, n['sizing']).split('\n')
    is_('the size is written after the PIPE, PC and CHANGEPIPE lines',
        re.search(r'//AS - \d+$', a[7]) and re.search(r'//AS - \d+$', a[8]) and re.search(r'//AS - \d+$', a[9])
        and not re.search(r'AS', a[4]))

    print('5. THE COMMENTS')
    m = '\n'.join(['WATER W 0 500', 'USE ASAM', 'PIPE P1 W A 20 0', 'NODE A 0',
                   'PIPE P2 A S 6 0 T   // TO THE HEAD', 'SPRINKLER S 0 -50 8', ''])
    n, _ = sized(m)
    a = sizing.annotate(m, n['sizing'])
    al = a.split('\n')
    mm = re.search(r'^PIPE P1 W A 20 0  //AS - (\d+)$', al[2])
    is_('//AS - <size> after the sized line, SIZE 0 kept',
        mm and float(mm.group(1)) == float(n['sizing']['units'][0]['dn']))
    is_('   the line\'s own comment kept after it', re.search(r'^PIPE P2 A S 6 0 T  //AS - \d+ // TO THE HEAD$', al[4]),
        al[4])
    is_('   lines not sized untouched', al[0] == 'WATER W 0 500' and al[3] == 'NODE A 0')
    n2, _ = sized(a)
    a2 = sizing.annotate(a, n2['sizing'])
    is_('the annotated model sizes the same, and its comments are replaced, not added to', a2 == a, a2)
    stale = re.sub(r'//AS - \d+', '//AS - 999', a)
    is_('   a stale //AS is put right', sizing.annotate(stale, n['sizing']) == a)
    is_('clear takes them off again', sizing.clear(a) == m.replace('T   // TO', 'T // TO', 1))

    print('6. WHEN NOTHING WILL DO')
    weak = FLOOR.replace('WATER TOWN 0 450 1000 380 2000 250', 'WATER TOWN 0 150 1000 60', 1)
    n, ok = sized(weak)
    s = n['sizing']
    is_('a supply too weak: not met, every sized pipe at its largest, DN150',
        not s.get('passes') and not any(float(x['dn']) != 150 for x in s['units']))
    is_('   a warning says so', any(re.search(r'^auto sizing: even the largest sizes', w) for w in n['warnings']))
    rep = report.write_report(n, ok, 'weak.phc')
    flat = re.sub(r'\s+', ' ', rep)
    is_('   and the report: NOT MET', re.search(r'NOT MET: even the largest sizes in the database', flat))

    print('7. WITH DESIGN AREAS, IN INCHES, IN THE REPORT AND THE JSON')
    m = FLOOR + 'AREA NEAR A1 A2 A3 A4\nAREA FAR B1 B2 B3 B4\nOPTION SIZING_MARGIN 10%\n'
    n, ok = sized(m)
    bad = []
    for ar in ('NEAR', 'FAR'):
        c = check(n['source_text'] + 'OPTION DESIGN_AREA %s\n' % ar, AUTO, pct=10)
        if not c['ok']:
            bad.append(ar)
    is_('with AREA lines, the sizes pass in every area', n['sizing'].get('passes') and not bad,
        'fails in %s' % ' '.join(bad))
    said = []
    g, gok = areas.governing(n, ok, progress=lambda m: said.append(m))
    is_('   and the design areas are then reported from the sized model',
        gok and g.get('area_results') and len(g['area_results']) == 2)
    is_('   each area said as it is solved', ' '.join(said) == 'DESIGN AREA NEAR - 1 OF 2 DESIGN AREA FAR - 2 OF 2',
        ' '.join(said))
    inp = re.sub(r'(?m)^UNITS LENGTH M$', 'UNITS LENGTH M\nUNITS SIZE IN', FLOOR, count=1)
    inp = re.sub(r'(?m)^(PIPE M1 TOWN R0 30) 100$', r'\1 4', inp, count=1)
    inp = re.sub(r'(?m)^(PIPE RS R0 R1 4) 100 E$', r'\1 4 E', inp, count=1)
    inp = re.sub(r'(?m)^(PIPE H1 R1 J1 10) 80 T$', r'\1 3 T', inp, count=1)
    ni, _ = sized(inp)
    inch = {v: k for k, v in phc.inch_sizes().items()}
    is_('with UNITS SIZE IN, each size is written as its inch size',
        not any(str(x['token']) != inch.get(int(float(x['dn']))) for x in ni['sizing']['units']))
    r = res['SIZING_MARGIN 10%'][0]
    rep = report.write_report(r, 1, 'floor.phc')
    is_('the report lists each sized pipe, its size and velocity, and the margin met',
        re.search(r'(?m)^ AUTO PIPE SIZING$', rep)
        and re.search(r'(?m)^ \d+\s+PIPE\s+ASAM\s+LA1\s+DN\d+\s+[\d.]+$', rep)
        and re.search(r'Met: at the demand point the supply has [\d.]+ kPa to spare, against [\d.]+ kPa asked for',
                      re.sub(r'\s+', ' ', rep)))
    j = jsonout.results(r, 1, 'floor.phc')
    is_('the JSON lists them as sized', isinstance(j.get('sized'), list) and len(j['sized']) == 9
        and j['sized'][0].get('dn'))
    plain = phc.read_string(slurp(os.path.join(ROOT, 'examples', '01_single_branch.phc')))
    is_('a model with no size 0 is not touched', not plain.get('auto_sizing') and sizing.size(plain, 1)[0] is plain)

    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
