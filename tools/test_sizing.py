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

    audit()

    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


#------------------------------------------------------------------------------
# audit -- the line-by-line audit of 20 November 2026 against the Perl: each
# check is of a place where sizing.py or phc.py did something other than
# Sizing.pm or Phc.pm on the same input, with what the Perl gives.  (The
# phc.py checks are here because tools/test_phc.py is the check-for-check
# port of test_phc.pl; these have no Perl counterpart to sit beside.)
#------------------------------------------------------------------------------
def audit():
    import tempfile
    import shutil
    print('8. AS THE PERL DOES IT (the audit of 20 November 2026)')
    B = lambda b: b.decode('utf-8', 'surrogateescape')      # the model's bytes, as phc reads them
    base = 'UNITS LENGTH M\nWATER N1 0.0 900\nSPRINKLER N2 0.0 -50 80\n'

    def reads(text, dir_=None):
        try:
            return phc.read_string(text, dir_), ''
        except Exception as ex:
            return None, (ex.msg if hardycross.is_model_error(ex) else str(ex))

    # sizing.py
    one = base.replace('900', '900 1000 800 2000 600') + 'USE S40\nPIPE P1 N1 N2 100.0 0 E\n'
    real = sizing.solve_model
    calls = [0, 0, None]

    def solve(net):
        calls[0] += 1
        if calls[0] == calls[1]:
            if calls[2] is None:
                return 0
            raise RuntimeError(calls[2])
        return real(net)

    def run(at, how):
        calls[0], calls[1], calls[2] = 0, at, how
        n = phc.read_string(one)
        try:
            return sizing.size(n, real(n)), ''
        except Exception as ex:
            return None, str(ex)

    sizing.solve_model = solve
    try:
        run(0, None)
        total = calls[0]
        got, e = run(total, 'boom')
        is_('a solve of the answer that dies stops the sizing with its error', got is None and e == 'boom', e)
        got, e = run(total - 1, 'boom')
        is_('   so does the solve of the demand check', got is None and e == 'boom', e)
        got, e = run(total - 1, None)
        is_('   one that does not converge there is searched again, not a crash',
            got is not None and e == '', e)
    finally:
        sizing.solve_model = real
    nb = B(b'PIPE P1\xc2\xa0A 0 //x')
    is_('a no-break space is not white space: the fields are the Perl\'s',
        sizing.set_field(nb, 3, 25) == B(b'PIPE P1 A 0 //x').replace('P1 A', B(b'P1\xc2\xa0A'))
        and sizing.set_field(nb, 2, 25) == B(b'PIPE P1\xc2\xa0A 25 //x'))
    is_('   in a comment mark, and when the marks are cleared',
        sizing.mark(B(b'PIPE P1\xc2\xa0 //x'), 25) == B(b'PIPE P1\xc2\xa0  //AS - 25 //x')
        and sizing.clear(B(b'PIPE A  //AS - 25 // x\nPIPE B //AS - 1\xc2\xa0x\n')) == 'PIPE A // x\nPIPE B\n')

    # phc.py: one line
    is_('an AREA line\'s outlets are in rest, not among its fields',
        phc.analyse('AREA A1 S1 S2')['pos'] == ['A1'] and phc.analyse('AREA A1 S1 S2')['rest'] == ['S1', 'S2'])
    is_('with no node defined yet, a line\'s nodes are all undefined',
        phc.check_line('PIPE P1 A B 1000 25', {'nodes': {}})['undefined'] == ['A', 'B']
        and phc.check_line('PIPE P1 A B 1000 25', {'nodes': []})['undefined'] == ['A', 'B'])
    is_('   and a node is known by a true value',
        phc.check_line('PIPE P1 A B 1000 25', {'nodes': {'A': 0, 'B': 2}})['undefined'] == ['A'])
    is_('a PC line names each copy\'s start and end, copy by copy',
        phc.nodes_used(phc.analyse('PC P1 P2 A B P3 C D')) == ['A', 'B', 'C', 'D'])
    is_('a line cut short names what it has',
        phc.nodes_used(phc.analyse('PIPE P1')) == [] and phc.nodes_defined(phc.analyse('NODE')) == [None]
        and phc.names_defined(phc.analyse('PIPE')) == [None])
    is_('a cursor and a USE given as nothing are the defaults',
        phc.check_line('PIPE P1 A B 1000 25', {'cursor': None, 'use': None})['status'] == 'ok')
    is_('a USE with no type offers no fittings, and is no crash',
        phc.check_line('PIPE P1 A B 1000 25 ', {'use': {'c': 120}})['choices'] == [])
    rows = []
    real_row = phc.parse_row
    phc.parse_row = lambda net, sec, tk: (rows.append(' '.join(tk)), real_row(net, sec, tk))[1]
    try:
        phc.check_line('SPRINKLER S1 0 -123.456789012345 8', {})
    finally:
        phc.parse_row = real_row
    is_('a least pressure is checked to 15 figures, as it is solved',
        rows and rows[-1] == 'S1 S1 SPRINKLER K=8 P=123.456789012345', rows)
    is_('step_id past the largest whole numbers, as Perl\'s %d prints them',
        phc.step_id('P99999999999999999999') == 'P-0000000000000000001'
        and phc.step_id('P9223372036854775807') == 'P-9223372036854775808'
        and phc.step_id('N09') == 'N10' and phc.step_id(B(b'N\xd9\xa3')) == B(b'N\xd9\xa3') + '2')
    is_('a size past them is a float, printed 1e+30',
        phc.size_dn('1e30', 'MM') == 1e30 and isinstance(phc.size_dn('1e30', 'MM'), float)
        and phc.size_dn('1e19', 'MM') == 10000000000000000000 and phc.size_dn('24.5', 'MM') == 25
        and phc.pipe_row({'line': 1, 'use': {'type': 'S40'}, 'start': 'A', 'end': 'B', 'len': '1',
                          'size': '1e30', 'fits': []}, 'P', None, None, phc.UNIT_DEFAULT, False, None)
        == 'P A B 0.001 1e+30 TYPE=S40')
    is_('only a last line ending is taken off a line',
        phc.strip_comment('abc\r\n\n') == 'abc\r\n' and phc.strip_comment('abc // x\r\n') == 'abc ')
    is_('a value ends where its text ends, not before a newline',
        phc.length_metres('5M\n', 'M') is None and phc.ratio_value('3:1\n') is None
        and phc.length_metres('5M', 'M') == 5 and phc.ratio_value('3:1') == 3)
    is_('a length in a unit that is none is 0, not a crash',
        phc.length_metres('5', 'XX') == 0 and phc.length_metres('5', 'M') == 5)
    is_('TITLE x<1C>: a control character is not white space',
        phc.analyse('TITLE x\x1c').get('text') == 'x\x1c'
        and phc.check_line('PIPE\x1cP1 A', {})['template']['current'] == 0)

    # phc.py: a model
    n, e = reads(base + B(b'TITLE\xc2\xa0Foo\nUSE BORE 120\nPIPE P1 N1 N2 100.0 100\n'))
    is_('TITLE<no-break space>Foo has no text: refused', n is None and e == 'line 4: TITLE NEEDS TEXT', e)
    dpv = base + 'USE S40 120\nPIPE P1 N1 N2 100.0 100\nDPV P1 100 RATIO 5.5 OFF EQL 3\n'
    n, e = reads(dpv + 'DPVMODEL P1 0\nDPVMODEL P1 ACME X\n')
    is_('DPVMODEL 0 is no model (0 is false in Perl): a second line is taken',
        n is not None and [x.get('model') for x in elems(n) if x['id'] == 'P1.DPV'] == ['ACME X'], e)
    n, e = reads(dpv + 'DPVMODEL P1 ACME\nDPVMODEL P1 ACME X\n')
    is_('   any other is given once', n is None and re.search(r'ALREADY HAS A DPVMODEL, ON LINE 7', e), e)
    n, e = reads(base + 'USE BORE 120\nPIPE P1 N1 N2 100.0 100\nNRV N1 0\nNRVMODEL N1 0\nNRVLOSS N1 0 0 100 5\n')
    is_('NRVMODEL 0 is none: NRVLOSS is refused for want of one',
        n is None and e == 'line 8: NRVLOSS N1 REQUIRES NRVMODEL WITH MANUFACTURER DATA SOURCE', e)
    n, e = reads(base + 'NODE N3 0\nUSE BORE 120\nPIPE 0 N1 N3 100.0 100\nPC 0 A N3 N2\n')
    is_('a copy (PC) of a pipe named 0 is refused, as the Perl dies on it',
        n is None and e == "Can't use an undefined value as an ARRAY reference", e)
    n, e = reads(dpv + B(b'DPVMODEL P1 Caf\xc3\xa9 \xe9 X\nNRV N1 0\nNRVMODEL N1 Caf\xc3\xa9\n'))
    is_('a model\'s make is carried byte for byte (UTF-8 or Latin-1)',
        n is not None and [x.get('model') for x in elems(n) if x['id'] == 'P1.DPV'] == ['Caf\xc3\xa9 \xe9 X']
        and [x['nrv']['model'] for x in elems(n) if x.get('nrv')] == ['Caf\xc3\xa9'], e)
    d = tempfile.mkdtemp()
    try:
        n, e = reads(base + B(b'USE BORE 120\nPIPE P1 N1 N2 100.0 100\nSUPPLYGRAPH ./sub/./caf\xc3\xa9.phg\n'), d)
        want = ('supply graph ./sub/./caf\xc3\xa9.phg (line 6) is not in the report: CANNOT READ %s: %s'
                % (os.path.join(d, 'sub', 'caf\xc3\xa9.phg'), os.strerror(2)))
        is_('a supply graph\'s path is tidied (File::Spec), its name byte for byte',
            n is not None and (os.sep != '/' or n['warnings'][:1] == [want]), (e, n and n['warnings']))
        m = os.path.join(d, 'folder.phc')
        os.mkdir(m)
        try:
            phc.read_model(m)
            e = ''
        except Exception as ex:
            e = ex.msg if hardycross.is_model_error(ex) else str(ex)
        is_('a folder given as the model holds no model', e == 'THE FILE HOLDS NO MODEL: NO NODES AND NO PIPES', e)
        m = os.path.join(d, 'm.phc')
        with open(m, 'w') as fh:
            fh.write(base + 'USE BORE 120\nPIPE P1 N1 N2 100.0 100\n')
        was = os.getcwd()
        os.chdir(d)
        try:
            is_('a model named without a folder is in "."', phc.read_model('m.phc')['model_dir'] == '.')
        finally:
            os.chdir(was)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    n, e = reads(base + 'USE S40 120\nPIPE P1 N1 N2 100.0 100 0100E\n')
    is_('a fitting count is named as typed (0100)',
        n is None and re.search(r"FITTING COUNT OF 0100 FOR 'E'", e), e)
    # The fitting pick lists read the database as pipedata.load does.
    d = tempfile.mkdtemp()
    was = pipedata.path()
    try:
        with open(was, 'rb') as fh:
            data = fh.read()
        with open(os.path.join(d, 'pipes.dat'), 'wb') as fh:
            fh.write(data + b'FIT|AS|ZQ\nKPRIME|ZK\nPIPE|ZP\nFIT|AS|ZR|R\xe9d|25|1\n'
                     b'PIPETYPE|0|Zero|std|range|120|0.045\nPIPE|0|20|26|0|1\nPIPE|0|25|33|27|1\n')
        pipedata.load(os.path.join(d, 'pipes.dat'))
        phc.reset_db_cache()
        # 0 is false in Perl: a bore of 0 is no size to choose, but a pipe
        # type named 0 is a type (the Perl asks whether it is defined).
        n, e = reads(base + 'USE 0\nPIPE P1 N1 N2 100.0 0\n')
        is_('a pipe type named 0 is sized; its size with a bore of 0 is left out',
            [c[0] for c in sizing.choices('0', [], 'MM')] == [25]
            and n is not None and n['auto_sizing'][0]['type'] == '0', e)
        is_('   and is one as it is typed',
            phc.check_line('PIPE P1 A B 10 0', {'use': {'type': '0'}})['status'] == 'ok')
        try:
            ch = dict(phc.fitting_choices('ASAM', 25))
            e = ''
        except Exception as ex:
            ch, e = {}, repr(ex)
        is_('the pick list reads short lines and bytes that are not UTF-8',
            ch.get('ZQ') == '' and ch.get('ZR') == 'R\\XE9D', e)
    finally:
        pipedata.load(was)
        phc.reset_db_cache()
        shutil.rmtree(d, ignore_errors=True)


if __name__ == '__main__':
    main()
