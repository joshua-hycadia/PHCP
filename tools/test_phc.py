#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_phc.py -- the .phc command language and its line checker.  Python port
# of test_phc.pl, check for check.
#
#   python3 tools/test_phc.py          every check; example 04 read, not solved
#   python3 tools/test_phc.py --full   also solve example 04 both ways (minutes)
#
# What it proves, in order:
#
#   1. EXAMPLES.  Every example solves to the pipe flows and node pressures
#      frozen in tools/baseline.
#   2. EVERY COMMAND.  A valid line reads; a line missing each field, with a
#      bad number, a KEY=value, an unknown word, or a duplicate, is refused --
#      and every refusal names its line.
#   3. ANY ORDER.  Shuffled lines solve to the same results.
#   4. UNITS.  One model in other units, and values carrying their own units,
#      is the same model.
#   5. COPIES, CHANGES AND DEVICES.  PC, NC, CHANGEPIPE, EQV, and BP, BFP,
#      PRV, OPP and OFD in a pipe, each give the network they describe.
#   6. THE LINE CHECKER.  Status, template, pick lists and proposals.
#   7. TRAPS CLOSED.  Undefined nodes, duplicate names, '#', END, KEY=value.
#   8. FIXED FLOWS.  The minimum pressure is checked and can govern.
#
# The shuffles of part 3 are the Perl's own: its drand48, seeded by srand
# 20261028, and List::Util's shuffle, reproduced below, so the same orders
# are tried.
#==============================================================================
import glob
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, parse, report, demand, pumpcheck, areas
from hardycross import is_model_error

FULL = '--full' in sys.argv[1:]
EX = os.path.join(ROOT, 'examples')
PHCP = [sys.executable, os.path.join(ROOT, 'phcp')]
_pass, _fail = 0, 0


# is -- one named check; a failure prints what was found.
def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-68s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def slurp(p):
    with open(p, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read()


def dd(x, d):
    # Perl's //: x unless it is undef.
    return d if x is None else x


def num(x):
    # Perl numification: undef is 0.
    if x is None:
        return 0.0
    if isinstance(x, (int, float)):
        return x
    m = re.match(r'\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)', x)
    return float(m.group(1)) if m else 0.0


def pstr(x):
    # A value interpolated into a Perl string: undef is empty.
    return '' if x is None else str(x)


# Perl's random numbers: drand48, as srand and rand use it, and
# List::Util::shuffle's walk down the list.
class PerlRand:
    MASK = (1 << 48) - 1

    def __init__(self, seed):
        self.x = (0x330E + ((seed & 0xffffffff) << 16)) & self.MASK

    def drand(self):
        self.x = (self.x * 0x5DEECE66D + 0xB) & self.MASK
        return self.x / float(1 << 48)

    def shuffle(self, items):
        lst = list(items)
        i = len(lst)
        while i > 1:
            sw = int(self.drand() * i)
            i -= 1
            lst[sw], lst[i] = lst[i], lst[sw]
        return lst


# read_phc -- (network, None) or (None, message) for .phc text.
def read_phc(text):
    try:
        net = phc.read_string(text)
    except Exception as e:
        return None, (e.msg if is_model_error(e) else str(e))
    return (net, None) if net else (None, '')


# refused -- .phc text must be refused on line `line`, with a message matching rx.
def refused(name, text, line, rx):
    net, err = read_phc(text)
    is_(name, not net and re.search(r'^line ' + re.escape(str(line)) + ': ', err or '') is not None
        and re.search(rx, err or '') is not None,
        'it was accepted' if net else 'got: %s' % err)


# Solved pipe flows by id, and gauge pressures by node id.
def results(net):
    q, p = {}, {}
    for e in net['elems'][1:]:
        if e['kind'] == 'PIPE':
            q[e['id']] = e['q']
    for nd in net['nodes'][1:]:
        if nd['id'] != 'REF':
            p[nd['id']] = nd['h'] - hardycross.GAMMA_W * nd['z']
    return q, p


# worst -- the largest difference over the keys of a (all must be in b).
def worst(a, b):
    w = 0
    for k in a:
        if k not in b:
            return 1e30
        d = abs(num(a[k]) - num(b[k]))
        if d > w:
            w = d
    return w


def solved(n):
    hardycross.solve_model(n)
    return n


def elems_by_id(n):
    return {e['id']: e for e in (n['elems'] if n else []) if e and e.get('id')}


# Tight tolerances, so two descriptions of one model are compared on the
# model and not on where the iteration happened to stop.
TIGHT_PHC = '\nOPTION TOL_FLOW 1E-7\nOPTION TOL_LOOP 1E-8\nOPTION MAXITER 200000\n'


def tighten_phc(t):
    return re.sub(r'^OPTION\s+(TOL_FLOW|TOL_LOOP|MAXITER)\b.*$', '', t, flags=re.M) + TIGHT_PHC


def perl_lines(t):
    # split /\n/: trailing empty fields dropped.
    f = t.split('\n')
    while f and f[-1] == '':
        f.pop()
    return f


def flat(s):
    return re.sub(r'\s+', ' ', s)


print('1. EXAMPLES - the same flows and pressures as the frozen results')
#==============================================================================
# tools/baseline/<example>.expected holds each example's solved pipe flows and
# node pressures, frozen from an independent description of the same network
# solved at tight tolerances.  The example must reproduce them.
# expected -- (flows, pressures) from a frozen results file.
def expected(path):
    q, p = {}, {}
    for l in perl_lines(slurp(path)):
        if l.startswith('#') or not re.search(r'\S', l):
            continue
        w = l.split()
        k, id_, v = (w + [None, None, None])[:3]
        (q if k == 'Q' else p)[id_] = v      # None where only the name is frozen
    return q, p


for phcpath in sorted(glob.glob(os.path.join(EX, '*.phc'))):
    base = re.sub(r'.*/', '', phcpath)
    want = re.sub(r'\.phc\Z', '.expected', os.path.join(TOOLS, 'baseline', base))
    p, err = read_phc(slurp(phcpath))
    is_('%s reads' % base, p, err)
    if not (p and os.path.exists(want)):
        continue
    qa, pa = expected(want)
    if re.search(r'grid1000', base):
        # Read, not solved, unless --full: every frozen pipe and node is there.
        qp, pp = results(p)
        missing = [k for k in qa if k not in qp] + [k for k in pa if k not in pp]
        is_('   every frozen pipe and node is in the .phc model', not missing,
            'missing: %s' % ' '.join(missing))
        if not FULL:
            continue
        ok = hardycross.solve_model(p)
        is_('   solved: it converges', ok)
        qb, pb = results(p)
        qv = {k: v for k, v in qa.items() if v is not None}
        pv = {k: v for k, v in pa.items() if v is not None}
        if qv:
            is_('   solved: worst %.1e in a pipe flow, %.1e in a node pressure (within its tolerances)'
                % (worst(qv, qb), worst(pv, pb)), worst(qv, qb) < 0.5 and worst(pv, pb) < 0.5)
        continue
    t, _ = read_phc(tighten_phc(slurp(phcpath)))
    qb, pb = results(solved(t))
    wq, wp = worst(qa, qb), worst(pa, pb)
    is_('   worst difference %.1e in a pipe flow, %.1e in a node pressure' % (wq, wp),
        wq < 1e-4 and wp < 1e-4)

#==============================================================================
print('2. EVERY COMMAND - valid, each field missing, bad numbers, refusals')
#==============================================================================
# A small model; each test line is added as line 10.
BASE = '\n'.join(['UNITS LENGTH M', 'NODE A 0', 'NODE B 0', 'NODE C 1.5',
                  'WATER W1 0 500', 'USE BORE 120', 'PIPE P1 W1 A 10 100', 'PIPE P2 A B 10 100',
                  'SPRINKLER S1 1 -50 80', ''])
L = 10
# Each command: a valid line, and the positions (from 1) of its numeric fields.
CASES = [
    ['TITLE A TEST MODEL',                 []],
    ['PROJECT JOB HYC-2026-000',           []],
    ['UNITS PRESSURE KPA',                 []],
    ['METHOD HW',                          []],
    ['OPTION TOL_FLOW 0.01',               [2]],
    ['USE ASAM 110',                       [2]],
    ['PIPE P3 B C 5 50',                   [4, 5]],
    ['PC P2 P4 B C',                       []],
    ['CHANGEPIPE P2 12 80',                [2, 3]],
    ['EQV P2 3.5',                         [2]],
    ['NODE D 2.5',                         [2]],
    ['NC C D E',                           []],
    ['WATER W2 0 600 1000 500',            [2, 3, 4, 5]],
    ['SPRINKLER S2 1.5 -50 80',            [2, 3, 4]],
    ['HYDRANT H1 1.5 600 21',              [2, 3, 4]],
    ['HREEL R1 1.5 -220 7.5',              [2, 3, 4]],
    ['FIXEDFLOW F1 C 100 150',             [3, 4]],
    ['PUMP PU1 A C 300 1000 200',          [4, 5, 6]],
    ['BP P2 300 1000 200',                 [2, 3, 4]],
    ['BFP P2 0 10 1000 30',                [2, 3, 4, 5]],
    ['PRV P2 0 50',                        [2, 3]],
    ['OPP P2 20',                          [2]],
    ['OFD P2 60',                          [2]],
    ['PRA P2 3:1 300',                     [3]],
]
for line, nums in CASES:
    word = re.match(r'^(\S+)', line).group(1)
    net, err = read_phc(BASE + line)
    is_("%s: '%s' reads" % (word, line), net, err)
    # Each fixed field missing: the line cut after fewer and fewer fields.
    spec = phc.command_spec(word)
    tk = line.split()
    nfix = len(spec['fixed'])
    for keep in range(nfix):
        cut = ' '.join(tk[:keep + 1])
        refused("   missing %s: '%s'" % (spec['fixed'][keep][0], cut), BASE + cut, L, r'NEEDS')
    # Each numeric field given a bad number (the letter O for a zero).
    for i in nums:
        b = list(tk)
        b[i] = '1O0'
        refused("   field %d '1O0' refused" % i, BASE + ' '.join(b), L, r'NOT A (NUMBER|LENGTH)')
refused('a KEY=value field is refused', BASE + 'PIPE P3 B C 5 50 C=120', L, r'BY POSITION')
refused('an unknown command', BASE + 'HEAD H9 0 50 8', L, r'UNKNOWN COMMAND HEAD')
refused('an unknown option', BASE + 'OPTION TRACE FULL', L, r'UNKNOWN OPTION')
refused('an unknown unit', BASE + 'UNITS FLOW LPH', L, r'UNKNOWN UNIT LPH FOR FLOW')
refused('an unknown units quantity', BASE + 'UNITS SPEED MS', L, r'UNKNOWN UNITS QUANTITY')
refused('an unknown pipe type', BASE + 'USE BB16 150', L, r'UNKNOWN PIPE TYPE BB16')
refused('a size not made in the pipe type, on its line',
        BASE + 'USE ASAM\nPIPE P9 B C 3 47', L + 1, r'DATA_REQUIRED - DN47')
refused('a fitting the database lacks, on its line',
        BASE + 'USE ASAM\nPIPE P9 B C 3 50 2Q', L + 1, r'CANNOT READ FITTING CODE')
refused('fittings on a USE BORE pipe', BASE + 'PIPE P9 B C 3 50 2E', L, r'FITTINGS NEED A PIPE TYPE')
refused('extra fields', BASE + 'NODE D 2.5 9', L, r'UNEXPECTED FIELD')
refused('a negative length', BASE + 'PIPE P9 B C -3 50', L, r'CANNOT BE NEGATIVE')
refused('a single BFP pair must be at flow 0', BASE + 'BFP P2 100 10', L, r'FIXED LOSS: ITS FLOW MUST BE 0')
refused('a PRA ratio must reduce', BASE + 'PRA P2 1:2', L, r'MUST BE MORE THAN 1')

print('   settings and names given twice name both lines')
refused('UNITS LENGTH twice',    BASE + 'UNITS LENGTH MM', L, r'UNITS LENGTH IS ALREADY SET ON LINE 1')
refused('METHOD twice',          'METHOD HW\n' + BASE + 'METHOD DW', L + 1, r'METHOD IS ALREADY SET ON LINE 1')
refused('OPTION twice',          'OPTION MAXITER 9\n' + BASE + 'OPTION MAXITER 8', L + 1,
        r'OPTION MAXITER IS ALREADY SET')
refused('TITLE twice',           'TITLE A\n' + BASE + 'TITLE B', L + 1, r'TITLE IS ALREADY SET')
refused('PROJECT field twice',   'PROJECT JOB 1\n' + BASE + 'PROJECT job 2', L + 1,
        r'PROJECT JOB IS ALREADY SET')
refused('a node defined twice',  BASE + 'NODE A 3', L, r'NODE A IS ALREADY DEFINED ON LINE 2')
refused('a node defined twice, by another command', BASE + 'SPRINKLER B 0 -50 80', L,
        r'NODE B IS ALREADY DEFINED ON LINE 3')
refused('a pipe name used twice', BASE + 'PIPE P1 B C 3 50', L, r'THE NAME P1 IS ALREADY USED ON LINE 7')
refused('two devices in one pipe', BASE + 'BFP P2 0 10\nPRV P2 0 5', L + 1, r'ALREADY HAS A DEVICE, BFP')

#==============================================================================
print('3. ANY ORDER - shuffled lines give the same results')
#==============================================================================
# Lines are shuffled as units; a USE line travels with the pipes after it
# (USE is positional by design), and those pipes are shuffled among themselves.
rng = PerlRand(20261028)
for phcpath in sorted(glob.glob(os.path.join(EX, '*.phc'))):
    if re.search(r'grid1000', phcpath):
        continue
    base = re.sub(r'.*/', '', phcpath)
    lines = [l for l in perl_lines(tighten_phc(slurp(phcpath)))
             if re.search(r'\S', l) and not re.match(r'^\s*//', l)]
    units, group = [], None
    for l in lines:
        if re.match(r'^USE\b', l):
            group = [l]
            units.append(group)
        elif re.match(r'^PIPE\b', l):
            group.append(l)
        else:
            units.append([l])

    def text(us):
        return '\n'.join(x for u in us for x in u)
    ref, _ = read_phc(text(units))
    rq, rp = results(solved(ref))
    for try_ in (1, 2):
        # As the Perl's map: the units shuffled first, then each USE group's
        # pipes, in the shuffled order.
        u = [[x[0]] + rng.shuffle(x[1:]) if re.match(r'^USE', x[0]) else x
             for x in rng.shuffle(units)]
        net, err = read_phc(text(u))
        if not net:
            is_('%s shuffle %d reads' % (base, try_), 0, err)
            continue
        q, p = results(solved(net))
        wq, wp = worst(rq, q), worst(rp, p)
        is_('%s shuffle %d: worst %.1e L/min, %.1e kPa' % (base, try_, wq, wp),
            wq < 1e-4 and wp < 1e-4)

#==============================================================================
print('4. UNITS - one model in other units is the same model')
#==============================================================================
if True:
    # The same network three ways.  Lengths, elevations, sizes, pressures,
    # flows and K-factors change unit; the solution must not.
    si = '\n'.join(['NODE A 0', 'NODE B 2.5', 'WATER W 0 700 2000 600', 'USE ASAM',
                    'PIPE P1 W A 20000 100 2E', 'PIPE P2 A B 15000 80 T', 'SPRINKLER S 3 -50 8',
                    'HYDRANT H 2.5 600 21', 'PIPE P3 B S 3000 40', 'PIPE P4 B H 5000 80',
                    'FIXEDFLOW F A 100 150', ''])
    other = '\n'.join(['UNITS LENGTH M', 'UNITS ELEVATION MM', 'UNITS SIZE IN', 'UNITS PRESSURE BAR',
                       'UNITS FLOW LPS', 'UNITS KFACTOR LPM/BAR',
                       'NODE A 0', 'NODE B 2500', 'WATER W 0 7 33.333333333333 6', 'USE ASAM',
                       'PIPE P1 W A 20 4 2E', 'PIPE P2 A B 15 3 T', 'SPRINKLER S 3000 -0.5 80',
                       'HYDRANT H 2500 10 210', 'PIPE P3 B S 3 1.5', 'PIPE P4 B H 5 3',
                       'FIXEDFLOW F A 1.6666666666667 1.5', ''])
    suffix = '\n'.join(['NODE A 0', "NODE B 8'2.425\"", 'WATER W 0MM 700 2000 600', 'USE ASAM',
                        'PIPE P1 W A 20M 100 2E', 'PIPE P2 A B 1500CM 80 T', 'SPRINKLER S 3000MM -50 8',
                        'HYDRANT H 2.5M 600 21', 'PIPE P3 B S 3M 40', 'PIPE P4 B H 5000 80',
                        'FIXEDFLOW F A 100 150', ''])
    a, _ = read_phc(tighten_phc(si))
    qa, pa = results(solved(a))
    b, eb = read_phc(tighten_phc(other))
    is_('the model in M, MM, IN, BAR, L/S and LPM/BAR reads', b, eb)
    if b:
        qb, pb = results(solved(b))
        is_('   same flows (worst %.1e L/min) and pressures (%.1e kPa)' % (worst(qa, qb), worst(pa, pb)),
            worst(qa, qb) < 1e-3 and worst(pa, pb) < 1e-3)
    c, ec = read_phc(tighten_phc(suffix))
    is_("values carrying units: 20M, 1500CM, 3000MM, 8'2.425\"", c, ec)
    if c:
        qc, pc = results(solved(c))
        is_('   same flows (worst %.1e) and pressures (%.1e)' % (worst(qa, qc), worst(pa, pc)),
            worst(qa, qc) < 1e-3 and worst(pa, pc) < 1e-3)
    e = elems_by_id(a)
    is_('default units: pipe length in mm (20000 is 20 m)', abs(e['P1']['len'] - 20) < 1e-9)
    is_('default units: elevation in m (NODE B 2.5)',
        [x for x in a['nodes'] if x and dd(x.get('id'), '') == 'B' and abs(x['z'] - 2.5) < 1e-9])
    is_('default K unit L/min/kPa^0.5: K 8 is 8 in L/min and kPa', abs(e['S']['k'] - 8) < 1e-9)
    ebi = elems_by_id(b)
    # The parser holds K in L/min per kPa^0.5 whatever the file's units.
    is_('K 80 in LPM/BAR is K 8 in LPM/KPA', ebi.get('S') and abs(ebi['S']['k'] - 8) < 1e-6)

#==============================================================================
print('5. COPIES, CHANGES AND DEVICES')
#==============================================================================
if True:
    m = '\n'.join(['NODE A 0', 'NODE B 0', 'NODE C 0', 'NODE D 0', 'WATER W 0 700',
                   'USE ASAM 110', 'PIPE P1 W A 10000 100 2E',
                   'PC P1 P2 A B P3 B C',            # two copies of P1
                   'CHANGEPIPE P3 5000 80 T',        # P3 changed after copying
                   'EQV P2 2500',                    # 2.5 m extra on P2
                   'SPRINKLER S1 0 -50 8', 'NC S1 S2 S3', 'PIPE P4 C S1 1000 50', 'PIPE P5 C S2 1000 50',
                   'PIPE P6 C S3 1000 50', 'PIPE P7 C D 1000 50', ''])
    net, err = read_phc(m)
    is_('copies and changes read', net, err)
    e = elems_by_id(net)
    is_('PC: P2 is P1 with new nodes (ASAM DN100, C 110, 2E)',
        e['P2']['dn'] == 100 and e['P2']['c'] == 110 and dd(e['P2'].get('fitspec'), '') == '2E')
    is_('PC then CHANGEPIPE: P3 is DN80, 5 m, T',
        e['P3']['dn'] == 80 and abs(e['P3']['len'] - 5) < 1e-9 and e['P3']['fitspec'] == 'T')
    is_('   the source P1 is unchanged', e['P1']['dn'] == 100 and abs(e['P1']['len'] - 10) < 1e-9)
    is_('EQV adds 2.5 m to P2', abs(e['P2']['eqv'] - e['P1']['eqv'] - 2.5) < 1e-9)
    is_('NC: S2 and S3 are sprinklers like S1',
        e.get('S2') and e.get('S3') and e['S3']['otype'] == 'SPRINKLER')

    for line, kind in (['BP P1 300 2000 250', 'PUMP'], ['BFP P1 0 10 2000 40', 'BFP'],
                       ['BFP P1 0 25', 'FIXED_DROP'], ['PRV P1 0 50 2000 80', 'BFP'],
                       ['OPP P1 30', 'ORIFICE_REQUIRED'], ['OFD P1 60', 'ORIFICE']):
        d, de = read_phc('%s%s\n' % (m, line))
        k = re.match(r'^(\S+)', line).group(1)
        dei = elems_by_id(d)
        el, pipe = dei.get('P1.%s' % k), dei.get('P1')
        nid = {i: d['nodes'][i]['id'] for i in range(1, len(d['nodes']))} if d else {}
        is_('%s: a %s from W to P1~, the pipe from P1~ to A' % (line, kind),
            el is not None and el['kind'] == kind and nid.get(el['n1']) == 'W'
            and nid.get(el['n2']) == 'P1~' and nid.get(pipe['n1']) == 'P1~' and nid.get(pipe['n2']) == 'A',
            de)
        # A plate sized for a drop keeps its DN (its sizing uses it); both
        # take the pipe's bore from the database.
        if el is not None and re.match(r'^O', k):
            is_("   the plate takes its pipe's database bore (ASAM DN100: 105.1 mm)"
                + (' and DN' if k == 'OPP' else ''),
                abs(el['pipedia'] - 105.1) < 1e-9 and (k != 'OPP' or el['dn'] == 100))
    d, _ = read_phc('%sBP P1 300 2000 250\n' % m)
    is_('a solve runs through a pipe with a pump in it', d and hardycross.solve_model(d))

    # A plate's CD reaches the element; the drop goes as 1/Cd^2, so a CD of
    # 0 or less, or above 1, is refused.
    oc, oce = read_phc('%sOFD P1 60 0.7826\n' % m)
    is_('OFD P1 60 0.7826: the plate carries CD 0.7826',
        oc and abs(elems_by_id(oc)['P1.OFD']['cd'] - 0.7826) < 1e-12, oce)
    #
    # The Perl's check, !$n && $e =~ /CD must be/, never matches the
    # program's message (it is in capitals, and -0.6 is refused as
    # negative); in is()'s list context the failed match is an empty list,
    # the "got: ..." text moves up into the result, and the check passes
    # without testing anything.  Here the claim is tested for real, against
    # the messages the Perl gives (CD MUST BE MORE THAN 0 AND NOT MORE THAN 1,
    # CD CANNOT BE NEGATIVE), which the Python must give too.
    for bad in ('OFD P1 60 0', 'OPP P1 30 -0.6', 'OPP P1 30 1.2'):
        n, er = read_phc('%s%s\n' % (m, bad))
        is_("'%s': refused, CD out of range" % bad,
            not n and re.search(r'CD must be|CD cannot be negative', er or '', re.I) is not None,
            'it was accepted' if n else 'got: %s' % er)

    # The pressure ratio valve, as the manufacturer's worked example: a tank
    # 153 m up gives about 1500 kPa at a 3:1 valve, and 500 kPa after it --
    # to within +/-5% of the inlet pressure, 75 kPa.  The calculation uses
    # the bottom of that band: 1500 x (1/3 - 0.05) = 425 kPa.
    t = '\n'.join(['WATER TANK 153 0', 'NODE A 0', 'NODE B 0', 'USE S40 120',
                   'PIPE P1 TANK A 200000 100', 'PIPE P2 A B 1000 100', 'FIXEDFLOW F B 100', ''])
    r, re_ = read_phc(t + 'PRA P2 3:1 300\n')
    is_('PRA P2 3:1 reads: a RATIO element in pipe P2',
        r and elems_by_id(r)['P2.PRA']['kind'] == 'RATIO', re_)
    ok = hardycross.solve_model(r)
    q, p = results(r)
    is_('   outlet = inlet x (1/3 - 0.05), the bottom of the band: %.1f in, %.1f out' % (p['A'], p['P2~']),
        ok and abs(p['P2~'] - p['A'] * (1 / 3 - 0.05)) < 0.05 and abs(p['A'] - 1499) < 2)
    rep = report.write_report(r, ok, 't.phc')
    fl = flat(rep)
    is_('   the report shows the ratio, band, inlet and outlet, and no warning',
        re.search(r'P2\.PRA\s+PRA\s+A\s+P2~.*ratio 3:1 \+/-5%, inlet 1499\.\d, outlet 424\.7 '
                  r'\(band 424\.7 to 574\.6\)', rep) is not None
        and re.search(r'No warnings\.', rep) is not None)
    is_('   it says the calculation uses the bottom of the band',
        re.search(r'uses the BOTTOM of each band, outlet = inlet x \(1/ratio - band\)', fl) is not None)
    # The top of the band, by hand: 1499.0 x (1/3 + 0.05) = 574.6 kPa.
    mo = re.search(r'(With every valve.{0,200})', fl)
    is_('   and the highest pressure with the valve at the top of its band: 574.6 kPa',
        re.search(r'TOP of its band \(P2\.PRA outlet 574\.6 kPa\), the highest pressure downstream '
                  r'is 574\.6 kPa', fl) is not None,
        mo.group(1) if mo else 'no statement')
    nom, _ = read_phc(t + 'PRA P2 3:1 300 0\n')
    hardycross.solve_model(nom)
    _, pn = results(nom)
    is_('   BAND 0: the nominal ratio exactly, outlet = inlet / 3', abs(pn['P2~'] - pn['A'] / 3) < 0.05)
    b2, _ = read_phc(t + 'PRA P2 3:1 0 2\n')
    hardycross.solve_model(b2)
    _, pb = results(b2)
    is_('   BAND 2 (and MININLET 0, no minimum): outlet = inlet x (1/3 - 0.02)',
        abs(pb['P2~'] - pb['A'] * (1 / 3 - 0.02)) < 0.05
        and elems_by_id(b2)['P2.PRA'].get('mininlet') is None)
    big, be = read_phc(t + 'PRA P2 3:1 300 40\n')
    # As the CD checks above: the Perl's pattern is in lower case, the
    # message in capitals, and the Perl check passes vacuously through the
    # empty list.  The same pattern, without regard to case, tests it.
    is_('   a band wider than the outlet pressure is refused, on its line',
        not big and re.search(r'^line 8: .*a band of 40% of the inlet pressure is more than the '
                              r'33\.3+% a 3:1 valve passes', be or '', re.I) is not None, be)
    lo, _ = read_phc(t + 'PRA P2 3:1 2000\n')
    rl = report.write_report(lo, hardycross.solve_model(lo), 't.phc')
    is_('   an inlet below the stated minimum is a warning',
        re.search(r'below its minimum\s+inlet pressure', rl) is not None)
    two, _ = read_phc(t + 'PRA P2 2:1\n')
    hardycross.solve_model(two)
    _, p2 = results(two)
    is_('   a 2:1 valve: inlet x (1/2 - 0.05)', abs(p2['P2~'] - p2['A'] * (0.5 - 0.05)) < 0.05)

#==============================================================================
print('6. THE LINE CHECKER - status, template, choices, proposals')
#==============================================================================
if True:
    ck = phc.check_line
    ctx = {'use': 'ASAM', 'nodes': ['A', 'B', 'C']}
    for case in CASES:
        word = re.match(r'^(\S+)', case[0]).group(1)
        r = ck(case[0], ctx)
        is_('%s: ok, template names the command' % word,
            r['status'] == 'ok' and r['template']['command'] == word,
            '%s %s' % (pstr(r['status']), pstr(r.get('message'))))
    r = ck('PI', ctx)
    is_("'PI' while typing: incomplete, not unknown", r['status'] == 'incomplete')
    r = ck('PIPX', ctx)
    is_("'PIPX': an error", r['status'] == 'error'
        and re.search(r'UNKNOWN COMMAND', r['message'] or '') is not None)
    r = ck('PIPE P1 A', ctx)
    is_("'PIPE P1 A': incomplete, needs END, cursor in START",
        r['status'] == 'incomplete' and re.search(r'NEEDS END', r['message'] or '') is not None
        and r['template']['fields'][r['template']['current']] == 'START')
    is_('template text', phc.template_text('PIPE')
        == 'PIPE <NAME> <START> <END> <LENGTH> <SIZE> [FITTINGS ...]', phc.template_text('PIPE'))
    is_('an alias: P is PIPE',
        dd((ck('P P1 A B 3000 50', ctx).get('template') or {}).get('command'), '') == 'PIPE')

    c = {x[0]: x[1] for x in ck('USE ', ctx)['choices']}
    is_('USE type field: the database pipe types and BORE, in capitals',
        c.get('ASAM') and c.get('S20') and c.get('BORE') and not re.search(r'[a-z]', c['ASAM']))
    c = {x[0]: x[1] for x in ck('PIPE P1 A B 3000 50 ', ctx)['choices']}
    # AS 2118.1 lists no butterfly valve, so at DN50 B (for BV) is not offered.
    is_('fitting field, ASAM DN50: database codes, short forms G and C, no B',
        c.get('E') and c.get('T') and c.get('GV') and c.get('G') and c.get('C') and not c.get('B')
        and re.search(r'SHORT FOR GV', c['G']) is not None)
    c = {x[0]: 1 for x in ck('PIPE P1 A B 3000 250 ', dict(ctx, use='S20'))['choices']}
    is_('fitting field, S20 DN250 (FM Global): B is offered', c.get('B') and c.get('BV'))
    c = {x[0]: 1 for x in ck('UNITS FLOW ', ctx)['choices']}
    is_('UNITS FLOW: the flow units', c.get('LPM') and c.get('LPS') and c.get('GPM'))
    r = ck('PIPE P1 A B 3000 47', ctx)
    is_("ASAM DN47: the parser's DATA_REQUIRED, on the line",
        r['status'] == 'error' and re.search(r'DATA_REQUIRED', r['message'] or '') is not None)
    r = ck('SPRINKLER S1 3 -50 0', ctx)
    is_('a sprinkler with K 0 (turned off) is fine', r['status'] == 'ok')
    r = ck('PIPE P1 A Z9 3000 50', ctx)
    is_('a node not yet defined is listed, not an error',
        r['status'] == 'ok' and ' '.join(r['undefined']) == 'Z9')

    def pr(l):
        return dd(ck(l, ctx).get('proposal'), '(none)')
    is_('after a pipe: next name, starting where it ended, no fittings',
        pr('PIPE 3101 2113 3101 6376 65 T') == 'PIPE 3102 3101 3102 6376 65',
        pr('PIPE 3101 2113 3101 6376 65 T'))
    is_('after a sprinkler: next name, same elevation, flow and K',
        pr('SPRINKLER 4101 47.076 81 8') == 'SPRINKLER 4102 47.076 81 8')
    is_('after a node', pr('NODE 301 27.197') == 'NODE 302 27.197')
    is_('after a fixed flow: name and node stepped', pr('FIXEDFLOW F1 N1 100 150') == 'FIXEDFLOW F2 N2 100 150')
    is_('after a setting, USE or a copy: none',
        pr('UNITS FLOW LPM') == '(none)' and pr('USE S20 120') == '(none)' and pr('NC A B') == '(none)')

#==============================================================================
print('7. TRAPS CLOSED')
#==============================================================================
refused('a node with no definition: named, at the first line using it',
        'WATER W 0 500\nUSE BORE 120\nPIPE P1 W B 1000 100\n', 3, r'NODE B IS NOT DEFINED')
refused('several undefined nodes: all named',
        'NODE A 0\nPIPE P1 A B 1000 100\nPIPE P2 B C 1000 100\n', 2,
        r'NODE B IS NOT DEFINED \(ALSO C ON LINE 3\)')
refused('a copy of an undefined pipe', BASE + 'PC P9 P10 A B', L, r'PIPE P9, COPIED AS P10, IS NOT DEFINED')
refused('a copy of an undefined node', BASE + 'NC Q1 Q2', L, r'NODE Q1, COPIED AS Q2, IS NOT DEFINED')
refused('a change to an undefined pipe', BASE + 'CHANGEPIPE P9 1 50', L, r'PIPE P9 IS NOT DEFINED')
refused("'#' in a line is refused, not taken as a comment", BASE + 'TITLE JOB #12', L, r"'#' CANNOT BE USED")
refused('END as a name', BASE + 'NODE END 0', L, r'END CANNOT BE A NAME')
refused("'~' in a name (PHCP's own names use it)", BASE + 'NODE A~ 0', L, r"'~' IS RESERVED")
if True:
    net, _ = read_phc('// a comment line\nNODE A 0 // the riser\nWATER W 0 500\nUSE BORE 120\n'
                      'PIPE P1 W A 1000 100\nsprinkler s1 0 -50 8\npipe p2 A s1 1000 50\n')
    is_('// comments anywhere; lower-case commands read the same', net)
    off, _ = read_phc('NODE A 0\nWATER W 0 500\nUSE BORE 120\nPIPE P1 W A 1000 100\nSPRINKLER S1 0 -50 0\n'
                      'PIPE P2 A S1 1000 50\nSPRINKLER S2 0 -50 8\nPIPE P3 A S2 1000 50\n')
    o = elems_by_id(off)
    is_('a sprinkler with K 0 is off: its node stays, with no outlet', off and not o.get('S1') and o.get('S2'))
    neg, _ = read_phc('NODE A 0\nWATER W 0 500\nUSE BORE 120\nPIPE P1 W A 1000 100\nSPRINKLER S1 0 81 8\n'
                      'PIPE P2 A S1 1000 50\nHYDRANT H1 0 -200 21\nPIPE P3 A H1 1000 80\n')
    e = elems_by_id(neg)
    is_('MINFLOW: 81 is a least flow of 81; -200 a least pressure of 200',
        e['S1']['qreq'] == 81 and abs(e['S1']['preq'] - (81 / 8) ** 2) < 1e-9 and e['H1']['preq'] == 200)
    try:
        m = parse.read_model(os.path.join(EX, '01_single_branch.phc'))
    except Exception:
        m = None
    is_('read_model dispatches .phc to the .phc reader', m and m.get('phc_text'))

#==============================================================================
print('8. FIXED FLOWS - the minimum pressure is checked and can govern')
#==============================================================================
if True:
    # C is 20 m above the supply, so the fixed flow there has the least
    # pressure to spare, and governs.
    m = '\n'.join(['NODE A 0', 'NODE C 20', 'WATER W 0 600', 'USE BORE 120',
                   'PIPE P1 W A 50000 100', 'SPRINKLER S 0 -50 80', 'PIPE P3 A S 1000 50',
                   'PIPE P2 A C 30000 50', ''])
    net, err = read_phc(m + 'FIXEDFLOW F C 100 250\n')
    is_('FIXEDFLOW with a minimum pressure reads', net, err)
    ok = hardycross.solve_model(net)
    f = (net.get('fixed') or [None])[0]
    is_('   kept by its own name, on its node, with its minimum', f and f['id'] == 'F' and f['preq'] == 250)
    gov = demand.governing_outlet(net)[0]
    is_('   it governs (least margin)', gov and gov['id'] == 'F', gov and gov['id'])
    dm = demand.demand_point(net)
    df = ((dm.get('net') or {}).get('fixed') or [None])[0]
    pf = demand.gauge(dm['net'], df['n1']) if df else -1
    is_('   at the demand point it has exactly its minimum (%.2f kPa)' % pf, abs(pf - 250) < 0.05)
    rep = report.write_report(net, ok, 'm.phc')
    is_('   report section 7 lists it, K fixed, PASS',
        re.search(r'^ F\s+C\s+fixed\s+100\.0\s+100\.0\s+250\.0\s+[\d.]+\s+PASS$', rep, re.M) is not None)
    bad, _ = read_phc(m + 'FIXEDFLOW F C 100 900\n')
    rb = report.write_report(bad, hardycross.solve_model(bad), 'm.phc')
    is_('a minimum above the pressure available FAILS',
        re.search(r'^ F\s+C\s+fixed.*\*\*\* FAIL$', rb, re.M) is not None)

#==============================================================================
print('ONE FILE TYPE - a .hcx file is refused, saying why')
#==============================================================================
if True:
    # A file in the old block format, written for the test: it must be refused.
    d = tempfile.mkdtemp()
    with open(os.path.join(d, 'old.hcx'), 'w') as o:
        o.write('NODES\n  N1 0\nEND\n')
    pr_ = subprocess.run(PHCP + [os.path.join(d, 'old.hcx')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out, code = pr_.stdout.decode('utf-8', 'surrogateescape'), pr_.returncode
    is_('phcp refuses a .hcx file: exit status 2, and the reason',
        code == 2 and re.search(r'IS NOT A \.PHC MODEL\. PHCP READS \.PHC FILES ONLY', out) is not None,
        'exit %d: %s' % (code, out))
    pr_ = subprocess.run(PHCP + [os.path.join(EX, '01_single_branch.phc')],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = pr_.stdout.decode('utf-8', 'surrogateescape')
    is_('   and reads the same model as .phc', pr_.returncode == 0
        and re.search(r'converged yes', out) is not None)
    os.unlink(os.path.join(d, 'old.hcx'))
    os.rmdir(d)

#==============================================================================
print('9. ROUGHNESS - as given, else the database\'s, else 0.045 mm and flagged')
#==============================================================================
if True:
    dw = '\n'.join(['UNITS LENGTH M', 'METHOD DW', 'WATER W1 0 500', 'NODE A 0', 'NODE B 0',
                    'USE PE11', 'PIPE P1 W1 A 50 110', 'USE BORE 0.01', 'PIPE P2 A B 20 100',
                    'USE BORE', 'PIPE P3 B S1 10 50', 'SPRINKLER S1 0 -50 8', ''])
    n, err = read_phc(dw)
    e = elems_by_id(n)
    is_("a PE pipe with none given: the database's 0.007 mm",
        n and e['P1']['eps'] == 0.007 and e['P1']['eps_src'] == 'DATABASE', err)
    is_('USE BORE 0.01: as given', e['P2']['eps'] == 0.01 and e['P2']['eps_src'] == 'GIVEN')
    is_('USE BORE with none: 0.045 mm, the program default',
        e['P3']['eps'] == 0.045 and e['P3']['eps_src'] == 'DEFAULT')
    w = next((x for x in (n.get('warnings') or []) if re.search(r'roughness ASSUMED', x)), None)
    is_('   and flagged: a warning naming the pipe',
        w and re.search(r'^roughness ASSUMED: 1 pipe\(s\) take 0\.045 mm.*: P3\.', w) is not None, w)
    in_ = elems_by_id(read_phc('\n'.join(['UNITS LENGTH M', 'UNITS SIZE IN', 'METHOD DW', 'WATER W1 0 500',
                                          'USE BORE 0.001', 'PIPE P1 W1 S1 10 2', 'SPRINKLER S1 0 -50 8',
                                          '']))[0])
    is_('   given in the units declared: USE BORE 0.001 with SIZE IN is 0.0254 mm',
        abs(in_['P1']['eps'] - 0.0254) < 1e-12 and in_['P1']['eps_src'] == 'GIVEN')
    hw = dw.replace('METHOD DW', 'METHOD HW', 1)
    h, _ = read_phc(hw)
    # Under HW the model is refused (USE BORE 0.01 is then a C factor of
    # 0.01), so h is undef in the Perl too, and its warnings an empty list.
    is_('under Hazen-Williams roughness is not used, so nothing is flagged',
        not [x for x in ((h or {}).get('warnings') or []) if re.search(r'roughness', x)])
    hardycross.solve_model(n)
    rep = report.write_report(n, 1, 'dw.phc')
    fl = flat(rep)
    is_("the report: BASIS says where each pipe's roughness came from",
        re.search(r'Pipe roughness Pipes: 1 as given in the model; 1 from the database for the pipe type; '
                  r'1 ASSUMED 0\.045 mm, the program default - see Warnings\.', fl) is not None)
    is_('   and the warnings list it', re.search(r'roughness ASSUMED: 1 pipe\(s\) take 0\.045 mm', fl) is not None)
    # Every example as it was: none of them leaves a roughness to the default.
    flag = []
    for x in sorted(glob.glob(os.path.join(EX, '*.phc'))):
        if re.search(r'grid1000', x):
            continue
        mm, _ = read_phc(slurp(x))
        if mm and [w for w in (mm.get('warnings') or []) if re.search(r'roughness', w)]:
            flag.append(x)
    is_('no example assumes a roughness', not flag, ' '.join(flag))

#==============================================================================
print('10. PUMPS AGAINST THEIR DUTY, AND THE HOSE ALLOWANCE')
#==============================================================================
if True:
    # A pump curve: 700 kPa at no flow, 600 at 2000 L/min, 450 at 3000.
    m = '\n'.join(['UNITS LENGTH M', 'WATER T1 0 100', 'NODE A 0',
                   'PUMP PU1 T1 A 700 2000 600 3000 450', 'PIPE P1 A B 20 150', 'NODE B 0',
                   'BP P1 300 1500 250', 'PIPE P2 B S1 10 100', 'SPRINKLER S1 0 -50 80', ''])
    n, err = read_phc(m + 'PUMPDUTY PU1 2000 600\nPUMPDUTY P1 1500 250\n')
    c = {x['id']: x for x in (pumpcheck.check(n) or [])} if n else {}
    is_('PUMPDUTY on a pump, and on a pipe with a booster (P1.BP)',
        n and c.get('PU1', {}).get('duty') and c.get('P1.BP', {}).get('duty'), err)
    is_('PU1 at its duty: 600 at 2000 L/min - PASS',
        abs(c['PU1']['at_duty']['p'] - 600) < 1e-9 and c['PU1']['at_duty']['ok'])
    is_('   shut-off 700, at most 140% of 600 = 840 - PASS',
        c['PU1']['shutoff'] == 700 and c['PU1']['shutoff_ok'])
    is_('   at 150% flow, 3000 L/min: 450, at least 65% of 600 = 390 - meets, read on the curve',
        abs(c['PU1']['over']['p'] - 450) < 1e-9 and c['PU1']['over']['ok']
        and not c['PU1']['over'].get('extrapolated'))
    is_('the booster at 150% flow is beyond its last point: EXTRAPOLATED',
        c['P1.BP']['over'].get('extrapolated'))
    is_('no warnings when every pump meets its duty',
        not [x for x in (n.get('warnings') or []) if re.match(r'^pump ', x)])
    n, _ = read_phc(m + 'PUMPDUTY PU1 2000 480\n')
    w = next((x for x in (n.get('warnings') or []) if re.match(r'^pump PU1', x)), None)
    is_('duty 480: shut-off 700 is above 140% of 480 = 672 - a warning naming the pump and the source',
        w and re.search(r'shut-off 700\.0 is above 140% of its duty pressure 480\.0 \(672\.0\) - AS 2941', w)
        is not None, w)
    n, _ = read_phc(m + 'PUMPDUTY PU1 2500 600\n')
    w = next((x for x in (n.get('warnings') or []) if re.match(r'^pump PU1', x)), None)
    is_('duty 600 at 2500 L/min: the curve gives less there - does not deliver its duty',
        w and re.search(r'does not deliver its duty', w) is not None, w)
    n, _ = read_phc(m)
    c = {x['id']: x for x in pumpcheck.check(n)}
    is_('without PUMPDUTY a pump is listed, not checked',
        not c['PU1'].get('duty') and c['PU1']['shutoff'] == 700)
    refused('PUMPDUTY of a name that is no pump', m + 'PUMPDUTY P2 100 100\n', 10, r'NO PUMP OF THAT NAME')
    refused('two duties for one pump', m + 'PUMPDUTY PU1 2000 600\nPUMPDUTY PU1 2000 600\n', 11,
            r'ALREADY HAS A DUTY, ON LINE 10')

    # The hose allowance: added at the supply to the demand flow; the demand
    # pressure, a property of the network, does not change.
    one = '\n'.join(['UNITS LENGTH M', 'WATER W1 0 900 3000 600', 'NODE A 0', 'PIPE P1 W1 A 30 100',
                     'PIPE P2 A S1 10 50', 'SPRINKLER S1 0 -100 80', ''])
    a, _ = read_phc(one)
    h, _ = read_phc(one + 'OPTION HOSE_ALLOWANCE 500\n')
    for x in (a, h):
        hardycross.solve_model(x)
    da, dh = demand.demand_point(a), demand.demand_point(h)
    is_('the demand pressure is the same with a hose allowance', abs(dh['p_demand'] - da['p_demand']) < 0.02)
    is_("   the demand flow is the system's plus 500 L/min",
        abs(dh['q_demand'] - (dh['q_system'] + 500)) < 1e-9 and abs(dh['q_system'] - da['q_demand']) < 1)
    avail = 900 - 300 * (dh['q_demand'] / 3000) ** 1.85     # straight in Q^1.85 from 0 to 3000
    is_('   available at that flow, %.2f kPa, read straight in Q^1.85; margin = available - demand' % avail,
        abs(dh['p_avail'] - avail) < 1e-6 and abs(dh['margin'] - (avail - dh['p_demand'])) < 1e-6)
    rep = report.write_report(h, 1, 'hose.phc')
    fl = flat(rep)                                           # wrapped lines read as one
    is_('   the report shows the system flow, the allowance and the demand',
        re.search(r'HOSE ALLOWANCE, added\s+500\.0 L/min', rep) is not None
        and re.search(r'SYSTEM FLOW at the demand point', rep) is not None
        and re.search(r'A hose stream allowance of 500\.0 L/min is added', fl) is not None)
    u, _ = read_phc('UNITS FLOW LPS\n' + one + 'OPTION HOSE_ALLOWANCE 8.3333333\n')
    is_("   in the model's flow unit: 8.333 L/s is 500 L/min", abs(u['opts']['hose'] - 500) < 1e-4)
    refused('a negative allowance is refused', one + 'OPTION HOSE_ALLOWANCE -5\n', 7,
            r'HOSE_ALLOWANCE CANNOT BE NEGATIVE')

#==============================================================================
print('11. DESIGN AREAS - each solved, the governing one reported')
#==============================================================================
if True:
    t = slurp(os.path.join(EX, '11_design_areas.phc'))
    all_, err = read_phc(t)
    mid = next((x for x in (all_ or {}).get('areas', []) if x['name'] == 'MIDDLE'), None)
    is_('AREA lines read: three areas, MIDDLE from two lines (4 outlets)',
        all_ and len(all_['areas']) == 3 and len(mid['outlets']) == 4, err)
    out = {x['id']: 1 for x in all_['elems'][1:] if x['kind'] == 'DISCHARGE'}
    is_('   read without DESIGN_AREA, every outlet flows', len(out) == 9)
    near, _ = read_phc(t + 'OPTION DESIGN_AREA NEAR\n')
    out = {x['id']: 1 for x in near['elems'][1:] if x['kind'] == 'DISCHARGE'}
    is_('OPTION DESIGN_AREA NEAR: A1-A4 flow, B1-B4 are shut, HR1 (in no area) flows',
        ' '.join(sorted(out)) == 'A1 A2 A3 A4 HR1')
    g, ok = areas.governing(all_, hardycross.solve_model(all_))
    r = {x['name']: x for x in (g.get('area_results') or [])}
    is_('every area solved; FAR governs, with the least margin at the supply',
        ok and len(r) == 3 and r['FAR'].get('governs') and g['design_area'] == 'FAR'
        and g['area_basis'] == 'SUPPLY'
        and not [x for x in r.values() if r['FAR']['demand']['margin'] > x['demand']['margin']])
    dm = demand.demand_point(g)
    is_("   the network returned is FAR's: its own demand point is the one listed",
        abs(dm['p_demand'] - r['FAR']['demand']['p']) < 1e-9
        and abs(dm['q_demand'] - r['FAR']['demand']['q']) < 1e-9)
    rep = report.write_report(g, ok, '11_design_areas.phc')
    fl = flat(rep)
    is_('   the report lists the areas and says FAR governs, and why',
        re.search(r'^ FAR\s+4\s+B4\b.*<- GOVERNS$', rep, re.M) is not None
        and re.search(r'This report is for area FAR, which governs: it has the least margin at the supply',
                      fl) is not None)
    forced, _ = read_phc(t + 'OPTION DESIGN_AREA NEAR\n')
    f2, ok2 = areas.governing(forced, hardycross.solve_model(forced))
    frep = report.write_report(f2, ok2, 'x.phc')
    fl = flat(frep)
    is_('OPTION DESIGN_AREA: that area only, nothing picked, and the report says so',
        f2 is forced and not f2.get('area_results')
        and re.search(r'for design area NEAR \(4 outlets\), chosen by OPTION DESIGN_AREA', fl) is not None)
    none, _ = read_phc(slurp(os.path.join(EX, '01_single_branch.phc')))
    n2 = areas.governing(none, 1)[0]
    is_('a model with no AREA is returned as it is', n2 is none and not none.get('areas'))
    m = '\n'.join(['WATER W 0 500', 'NODE J 0', 'SPRINKLER S1 0 -50 8', 'USE BORE 120',
                   'PIPE P1 W J 10 50', 'PIPE P2 J S1 5 25', ''])
    refused('an AREA naming a node not defined', m + 'AREA A S1 S9\n', 7, r'AREA A: S9 IS NOT DEFINED')
    refused('an AREA naming a node that is not an outlet', m + 'AREA A S1 J\n', 7, r'AREA A: J IS NOT AN OUTLET')
    refused('DESIGN_AREA of an area not in the model', m + 'AREA A S1\nOPTION DESIGN_AREA B\n', 8,
            r'DESIGN_AREA B: NO AREA OF THAT NAME \(A\)')
    refused('   ...or with no area at all', m + 'OPTION DESIGN_AREA B\n', 7, r'THE MODEL HAS NO AREA')

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
