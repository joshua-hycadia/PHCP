#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_graph.py -- the Q^1.85 water supply graph (hardycross.graph),
# headless.  A port of tools/test_graph.pl.
#
#   python3 tools/test_graph.py
#
# What it proves, in order:
#
#   1. THE CURVES.  C = A - B and E = C + D at equal flow, each straight in
#      flow^1.85 between its points -- checked against figures worked here,
#      by a formula written out in this file, not by the engine's own code.
#      A single loss point is a line through the origin.
#   2. THE DUTIES.  Each compared with E when there is a pump, C when not.
#   3. REFUSED.  Every rule the tab enforces, each naming its row.
#   4. THE FILE.  A .phg file written and read back is the same graph; a bad
#      line is refused with its line number.
#   5. THE SHEET.  The PDF is well formed, one page, the typeface embedded;
#      the plot, the curves, the duty points and their table are where the
#      figures put them.
#   6. UNITS.  The same supply in L/s and bar.
#   7. IN A MODEL'S REPORT.  SUPPLYGRAPH adds the sheet: an appendix to the
#      text, a page after it in the PDF, numbered with the report; a graph
#      that cannot be read is a warning, and the report is still written.
#==============================================================================

import os
import re
import shutil
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import graph as G

PASS = [0]
FAIL = [0]
EX = os.path.join(ROOT, 'examples', '10_supply_graph.phg')


def is_(name, ok, why=None):
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % (why,))
    if ok:
        PASS[0] += 1
    else:
        FAIL[0] += 1


# hand -- a curve through points, straight in Q^1.85 between them: the
# pressure at q, for q within the points.  Written out here on purpose.
def hand(pts, q):
    for i in range(len(pts) - 1):
        q1, p1 = pts[i]
        q2, p2 = pts[i + 1]
        if not (q1 <= q <= q2):
            continue
        f = (q ** 1.85 - q1 ** 1.85) / (q2 ** 1.85 - q1 ** 1.85)
        return p1 + (p2 - p1) * f
    raise ValueError('flow %s is outside the points' % q)


def near(a, b, t=None):
    return abs(float(a) - float(b)) < (1e-6 if t is None else t)


# graph -- a graph from short lists, as the tab would hold it.
def graph(A=None, B=None, D=None, duty=None, **ax):
    g = G.new_graph()
    for c, p in (('A', A), ('B', B), ('D', D)):
        for i, row in enumerate(p or []):
            g[c][i] = list(row)
    for i, row in enumerate(duty or []):
        g['duty'][i] = list(row)
    for k in ('PMAX', 'PSTEP', 'QMAX'):
        if k in ax:
            g['axis'][k] = ax[k]
    return g


def raises(f):
    # (true, '') when f returns; (false, message) when it raises, as
    # eval { ...; 1 } and $@ in the Perl.
    try:
        f()
    except Exception as e:
        return False, str(e)
    return True, ''


def slurp_lines(p):
    with open(p) as f:
        return f.read()


def slurp_raw(p):
    with open(p, 'rb') as f:
        return f.read().decode('latin-1')


def pstr(v):
    if v is None:
        return ''
    if isinstance(v, float):
        return '%.15g' % v
    return str(v)


A_ = [[0, 650], [1800, 560], [3600, 400]]
B_ = [[0, 0], [1000, 40], [2000, 140], [3600, 400]]
D_ = [[0, 480], [1200, 460], [2400, 400], [3600, 290]]


def part1():
    #==========================================================================
    print('1. THE CURVES - C = A - B and E = C + D, straight in flow^1.85')
    #==========================================================================
    chk = G.check(graph(A=A_, B=B_, D=D_))
    is_('three curves, four duties of nothing: accepted', chk['ok'], '; '.join(e[1] for e in chk['errors']))
    sr = G.series(chk)
    bad = 0
    for pt in sr['lines']['C']:
        q = pt[0]
        if not near(pt[1], hand(A_, q) - hand(B_, q)):
            bad += 1
    is_('C = A - B at every sample (201 flows)', not bad and len(sr['lines']['C']) == 201)
    bad = 0
    for pt in sr['lines']['E']:
        q = pt[0]
        if not near(pt[1], hand(A_, q) - hand(B_, q) + hand(D_, q)):
            bad += 1
    is_('E = C + D at every sample', not bad)
    cs = {'A': A_, 'B': B_, 'D': D_}
    is_('every entered point is on its own curve',
        not any(not near(hand(cs[c], p[0]), p[1]) for c in ('A', 'B', 'D') for p in sr['points'][c]))
    is_('samples evenly spaced along the flow^1.85 axis',
        near(sr['lines']['A'][100][0] ** 1.85, sr['qmax'] ** 1.85 / 2, 1e-3 * sr['qmax'] ** 1.85))
    is_('the flow axis: the largest flow, rounded up to 100 (3600)', sr['qmax'] == 3600)
    is_('the design curve is E when there is a pump', sr['design'] == 'E')

    # One loss point: a line through the origin, rising as flow^1.85.
    one = G.series(G.check(graph(A=A_, B=[[2400, 120]])))
    bad = 0
    for pt in one['lines']['B']:
        if pt[0] > 2400:
            continue
        if not near(pt[1], 120 * (pt[0] / 2400) ** 1.85):
            bad += 1
    is_('one loss point: B = 120 x (Q/2400)^1.85, through the origin', not bad)
    is_('no pump: the design curve is C, and there is no D or E',
        one['design'] == 'C' and not one['lines'].get('D') and not one['lines'].get('E'))
    none = G.series(G.check(graph(A=A_)))
    is_('no loss and no pump: C is A',
        not any(not near(none['lines']['C'][i][1], none['lines']['A'][i][1]) for i in range(201)))
    ax = G.series(G.check(graph(A=A_, PMAX=900, PSTEP=150, QMAX=5000)))
    is_('axes as set: 0 to 900 kPa every 150, 0 to 5000 L/min',
        ax['pmax'] == 900 and ax['qmax'] == 5000
        and ' '.join(pstr(t) for t in ax['yticks']) == '0 150 300 450 600 750 900')


def part2():
    #==========================================================================
    print('2. THE DUTIES - each against the design curve')
    #==========================================================================
    duty = [['1', 'SPRINKLERS', 1500, 700], ['', 'HYDRANTS', 2400, 900]]
    sr = G.series(G.check(graph(A=A_, B=B_, D=D_, duty=duty)))
    d1, d2 = sr['duty'][0], sr['duty'][1]

    def e(q):
        return hand(A_, q) - hand(B_, q) + hand(D_, q)
    is_('duty 1: E at 1500 L/min is %.2f kPa, margin %.2f' % (e(1500), e(1500) - 700),
        near(d1['avail'], e(1500)) and near(d1['margin'], e(1500) - 700))
    is_('duty 2: short by %.2f kPa' % (900 - e(2400)), near(d2['margin'], e(2400) - 900) and d2['margin'] < 0)
    is_('a duty with no label takes its row number', d2['label'] == '2')
    nopump = G.series(G.check(graph(A=A_, B=B_, duty=duty)))
    is_('without a pump the duties are against C',
        near(nopump['duty'][0]['avail'], hand(A_, 1500) - hand(B_, 1500)))
    ex = G.series(G.check(G.read_file(EX)))
    e2 = hand([[0, 650], [1800, 560], [3600, 400]], 2400) - 120 + 400
    is_('example 10, duty 2: E at 2400 = 516.83 - 120 + 400 = %.2f kPa' % e2,
        near(ex['duty'][1]['avail'], e2) and near(e2, 796.84, 0.01))


def part3():
    #==========================================================================
    print('3. REFUSED - each problem named, with its row')
    #==========================================================================
    def err(name, g, field, rx):
        chk = G.check(g)
        e = next((x for x in chk['errors'] if x[0] == field), None)
        is_(name, not chk['ok'] and e and re.search(rx, e[1]),
            ('got [%s] %s' % (e[0], e[1])) if e else
            'errors: ' + '; '.join('[%s] %s' % (x[0], x[1]) for x in chk['errors']))
    err('A with one point', graph(A=[[0, 650]]), 'A1', r'AT LEAST TWO POINTS')
    err('A empty', graph(), 'A1', r'AT LEAST TWO POINTS')
    err('a flow with no pressure', graph(A=A_ + [[4000, '']]), 'A4', r'A ROW 4: FLOW AND PRESSURE ARE BOTH NEEDED')
    err('a letter O for a zero', graph(A=[[0, 650], ['18OO', 560]]), 'A2', r"FLOW '18OO' IS NOT A NUMBER")
    err('flows not rising', graph(A=[[0, 650], [1800, 560], [1800, 500]]), 'A3', r'MUST RISE')
    err('a gap in the rows', graph(A=[[0, 650], ['', ''], [1800, 560]]), 'A3', r'ROW 2 IS EMPTY')
    err('a negative flow', graph(A=[[-10, 650], [1800, 560]]), 'A1', r'CANNOT BE NEGATIVE')
    err('a pump with one point', graph(A=A_, D=[[0, 480]]), 'D2', r'AT LEAST TWO POINTS - OR NONE')
    err('a pump not starting at churn', graph(A=A_, D=[[500, 480], [1500, 400]]), 'D1', r'CHURN')
    err('a duty with no pressure', graph(A=A_, duty=[['1', 'X', 1500, '']]), 'DUTY1', r'BOTH NEEDED')
    err('an axis of zero', graph(A=A_, PMAX=0), 'PMAX', r'ABOVE ZERO, OR BLANK')
    ok = G.check(graph(A=A_, duty=[['', '', '', ''], ['', 'NOTE', 900, 300]]))
    is_('an empty duty row before a filled one is allowed', ok['ok'])


def part4(tmp):
    #==========================================================================
    print('4. THE FILE - .phg written and read back')
    #==========================================================================
    g = G.read_file(EX)
    is_('example 10 reads', g['project']['JOB'] == 'HC-DEMO-010' and g['A'][2][0] == '3600'
        and g['duty'][1][1] == 'HYDRANTS - TWO AT 10 L/S')
    G.write_file(g, os.path.join(tmp, 'a.phg'))
    back = G.read_file(os.path.join(tmp, 'a.phg'))

    def flat(x):
        v = [x['project'][k] for k in G.PROJECT] + [x['axis'][k] for k in G.AXIS]
        for c in ('A', 'B', 'D'):
            for r in x[c]:
                v += r
        for r in x['duty']:
            v += r
        return '|'.join(pstr(z) for z in v)
    is_('written and read back: the same graph', flat(g) == flat(back))
    with open(os.path.join(tmp, 'bad.phg'), 'w') as o:
        o.write('PROJECT X\nA 0 600\nPIPE 1 2\n')
    r, e = raises(lambda: G.read_file(os.path.join(tmp, 'bad.phg')))
    is_('an unknown word is refused with its line number', not r and re.search(r'^LINE 3: UNKNOWN WORD PIPE', e), e)
    with open(os.path.join(tmp, 'many.phg'), 'w') as o:
        o.write(''.join('A %d 500\n' % i for i in range(1, 10)))
    r, e = raises(lambda: G.read_file(os.path.join(tmp, 'many.phg')))
    is_('more than eight points on a curve is refused', not r and re.search(r'MORE THAN 8 POINTS', e), e)


def part5(tmp):
    #==========================================================================
    print('5. THE SHEET - the PDF')
    #==========================================================================
    g = G.read_file(EX)
    G.write_pdf(g, os.path.join(tmp, 'g.pdf'))
    P = slurp_raw(os.path.join(tmp, 'g.pdf'))
    is_('a PDF, one page', re.search(r'^%PDF-1\.4', P) and re.search(r'/Type /Pages /Kids \[\S+ 0 R\] /Count 1', P))
    sx = int(re.search(r'startxref\n(\d+)\n%%EOF\n\Z', P).group(1))
    first = int(re.search(r'^xref\n(\d+) \d+\n', P[sx:]).group(1))
    e = re.findall(r'(?m)^(\d{10}) \d{5} ([nf]) ?\r?\n', P[sx:])
    bad = 0
    for k, (off, kind) in enumerate(e):
        if kind != 'n':
            continue
        num = first + k
        tag = '%d 0 obj' % num
        if P[int(off):int(off) + len(tag)] != tag:
            bad += 1
    is_('every xref offset lands on its object', not bad)
    is_('the typeface embedded', re.search(r'/BaseFont /DejaVuSansMono /', P) and re.search(r'/FontFile2 ', P))
    ms = re.search(r'stream\n(.*?% PHCP-SHEET PLOT.*?)endstream', P, re.S)
    s = ms.group(1) if ms else ''
    mp = re.search(r'% PHCP-SHEET PLOT (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)', s)
    pl, pb, pw, ph, qmax, pmax = [float(x) for x in mp.groups()] if mp else [None] * 6
    is_('the plot is drawn, 0 to 3600 L/min and 0 to 1400 kPa', pl is not None and qmax == 3600 and pmax == 1400)
    n = dict(re.findall(r'% PHCP-SHEET LINE (\S) (\d+)', s))
    is_('curves A B C D E drawn, 201 points each',
        ' '.join('%s%s' % (k, n[k]) for k in sorted(n)) == 'A201 B201 C201 D201 E201')

    def X(q):
        return pl + (q / qmax) ** 1.85 * pw

    def Y(p):
        return pb + p / pmax * ph
    dp = [x for t in re.findall(r'% PHCP-SHEET DUTY (\S+) (\S+) (\S+)', s) for x in t]
    is_('duty 1 drawn at 1500 L/min, 700 kPa on the q^1.85 axis',
        len(dp) >= 3 and dp[0] == '1' and near(dp[1], X(1500), 0.01) and near(dp[2], Y(700), 0.01))
    is_('duty 2 drawn at 2400 L/min, 600 kPa',
        len(dp) >= 6 and dp[3] == '2' and near(dp[4], X(2400), 0.01) and near(dp[5], Y(600), 0.01))
    pt = re.findall(r'% PHCP-SHEET POINT (\S) ', s)
    is_('every point entered is marked (3 A, 1 B, 4 D)', ''.join(pt) == 'AAABDDDD', ''.join(pt))
    rows = [x for t in re.findall(r'% PHCP-SHEET ROW (\S+) (\S+) (\S+) (\S+) (\S+)', s) for x in t]
    is_('the duty table: 2400 L/min at 600, has 796.8, margin 196.8',
        ' '.join(rows[5:10]) == '2 2400.0 600.0 796.8 196.8', ' '.join(rows))
    tk = [x for t in re.findall(r'% PHCP-SHEET XTICK (\S+) (\S+)', s) for x in t]
    tb, prev = 0, None
    for k in range(0, len(tk), 2):
        if abs(float(tk[k + 1]) - X(float(tk[k]))) > 0.01:
            tb += 1
        if prev is not None and float(tk[k + 1]) - prev < 6:
            tb += 1
        prev = float(tk[k + 1])
    is_('every flow label at its place on the axis, none overlapping', tk and not tb)
    x = os.path.join(tmp, 'x.pdf')
    r, e = raises(lambda: G.write_pdf(graph(A=[[0, 600]]), x))
    is_('a graph with problems is not printed, and says why',
        not r and re.search(r'AT LEAST TWO POINTS', e) and not os.path.exists(x))


def part6(tmp):
    #==========================================================================
    print('6. UNITS - the same supply in L/s and bar')
    #==========================================================================
    # Example 10's figures in L/s and bar: flows / 60, pressures / 100.
    m = G.read_file(EX)
    g = G.read_file(EX)
    g['units'] = {'FLOW': 'LPS', 'PRESSURE': 'BAR'}

    def has(v):
        return v is not None and len(str(v)) > 0
    for c in ('A', 'B', 'D'):
        for r in g[c]:
            if has(r[0]):
                r[0] = float(r[0]) / 60
            if has(r[1]):
                r[1] = float(r[1]) / 100
    for r in g['duty']:
        if has(r[2]):
            r[2] = float(r[2]) / 60
        if has(r[3]):
            r[3] = float(r[3]) / 100
    sm = G.series(G.check(m))
    sg = G.series(G.check(g))
    off = [i for i in (0, 1) if abs(sg['duty'][i]['margin'] * 100 - sm['duty'][i]['margin']) > 1e-6]
    is_('every duty\'s margin is the same: %.2f and %.2f kPa, as %.4f and %.4f bar'
        % (sm['duty'][0]['margin'], sm['duty'][1]['margin'], sg['duty'][0]['margin'], sg['duty'][1]['margin']),
        not off and len(sg['duty']) == 2)
    is_('the flow axis stops at a round number of L/s: 60', sg['qmax'] == 60, pstr(sg['qmax']))
    G.write_file(g, os.path.join(tmp, 'u.phg'))
    back = G.read_file(os.path.join(tmp, 'u.phg'))
    is_('UNITS written to the .phg and read back', back['units']['FLOW'] == 'LPS'
        and back['units']['PRESSURE'] == 'BAR'
        and re.search(r'(?m)^UNITS\s+FLOW LPS$', slurp_lines(os.path.join(tmp, 'u.phg'))))
    G.write_pdf(g, os.path.join(tmp, 'u.pdf'))
    P = slurp_raw(os.path.join(tmp, 'u.pdf'))
    is_('the sheet names L/s and bar',
        re.search(r'\(FLOW, L/s, ON A FLOW\^1\.85 SCALE\)', P) and re.search(r'\(PRESSURE, bar\)', P))
    is_('a graph with no UNITS is L/min and kPa, as before', G.units(G.new_graph())['FLOW'] == 'LPM')
    with open(os.path.join(tmp, 'badu.phg'), 'w') as o:
        o.write('UNITS FLOW LPH\n')
    r, e = raises(lambda: G.read_file(os.path.join(tmp, 'badu.phg')))
    is_('an unknown unit is refused with its line', not r and re.search(r'^LINE 1: UNITS TAKES FLOW', e), e)


def part7():
    print('7. IN A MODEL\'S REPORT - SUPPLYGRAPH')
    from hardycross import phc, report
    d = tempfile.mkdtemp()
    try:
        shutil.copy(EX, os.path.join(d, 'town.phg'))
        model = slurp_lines(os.path.join(ROOT, 'examples', '01_single_branch.phc'))

        def write(*extra):
            p = os.path.join(d, 'm.phc')
            with open(p, 'w') as f:
                f.write(model + ''.join(extra))
            return p
        net = phc.read_model(write('SUPPLYGRAPH town.phg\n'))
        hardycross.solve_model(net)
        is_('SUPPLYGRAPH town.phg: read from the model\'s folder, no warning',
            len(net.get('graph_sheets') or []) == 1
            and not any(re.search(r'supply graph', w) for w in net.get('warnings') or []))
        rep = report.write_report(net, 1, 'm.phc')
        sr = G.series(G.check(net['graph_sheets'][0]['graph']))
        dd = {x['label']: x for x in sr['duty']}
        is_('   the text report has it as APPENDIX A, before the end',
            re.search(r'APPENDIX A\. SUPPLY GRAPH - TOWN\.PHG.*END OF CALCULATION', rep, re.S))
        is_('   with each duty against E: 1 has %.1f, margin %.1f' % (dd['1']['avail'], dd['1']['margin']),
            re.search(r'(?m)^ 1\s+1500\s+700\s+' + re.escape('%.4g' % dd['1']['avail']) + r'\s+'
                      + re.escape('%.4g' % dd['1']['margin']) + r'\s+SPRINKLERS', rep))
        is_('   and stays 7-bit ASCII', not re.search(r'[^\x0A\x20-\x7E]', rep))
        with_, without = os.path.join(d, 'with.pdf'), os.path.join(d, 'without.pdf')
        report.write_pdf_report(net, 1, os.path.join(d, 'm.phc'), with_)
        plain = phc.read_model(write(''))
        hardycross.solve_model(plain)
        report.write_pdf_report(plain, 1, os.path.join(d, 'm.phc'), without)
        pw, po = slurp_raw(with_), slurp_raw(without)
        nw = int(re.search(r'/Type /Pages .*?/Count (\d+)', pw, re.S).group(1))
        no = int(re.search(r'/Type /Pages .*?/Count (\d+)', po, re.S).group(1))
        is_('   the PDF has one page more: %d without, %d with' % (no, nw), nw == no + 1)
        streams = len(re.findall(r'PHCP-SHEET PLOT', pw))
        is_('   the sheet is drawn once, framed as the last page of the report',
            streams == 1 and ('(Page %d of %d)' % (nw, nw)) in pw and ('(Page %d of %d)' % (no, no)) in po)
        net = phc.read_model(write('SUPPLYGRAPH none.phg\n'))
        w = next((x for x in net.get('warnings') or [] if re.search(r'supply graph', x)), None)
        is_('a graph that cannot be read: a warning naming it and its line, nothing more',
            net and re.search(r'^supply graph none\.phg \(line \d+\) is not in the report: CANNOT READ', w or '')
            and not net.get('graph_sheets'), w)
        with open(os.path.join(d, 'bad.phg'), 'w') as b:
            b.write('A 0 500\nDUTY 100 200 1\n')
        net = phc.read_model(write('SUPPLYGRAPH bad.phg\n'))
        w = next((x for x in net.get('warnings') or [] if re.search(r'supply graph', x)), None)
        is_('a graph its own tab would refuse: a warning with the reason',
            re.search(r'^supply graph bad\.phg .*: \S', w or ''), w)
        net = phc.read_string(model + 'SUPPLYGRAPH town.phg\n')
        is_('read without a folder (a re-read for a re-solve): no sheets, no warning',
            not net.get('graph_sheets') and not any(re.search(r'supply graph', x) for x in net.get('warnings') or []))
        a = phc.analyse('SUPPLYGRAPH')
        is_('the line checker asks for the FILE', a['status'] == 'incomplete' and re.search(r'FILE', a['msg']))
        a = phc.analyse('SUPPLYGRAPH My Graphs/Town Main.phg')
        is_('   and keeps a file name with spaces as typed',
            a['status'] == 'ok' and a['text'] == 'My Graphs/Town Main.phg')
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    tmp = tempfile.mkdtemp()
    try:
        part1()
        part2()
        part3()
        part4(tmp)
        part5(tmp)
        part6(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    part7()
    print('\n%d passed, %d failed' % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


if __name__ == '__main__':
    main()
