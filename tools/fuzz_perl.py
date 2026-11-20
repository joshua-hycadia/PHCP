#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# fuzz_perl.py -- the Python program against the last Perl release on models
# nobody wrote: each case is a good model with one to three random changes
# (a line dropped, doubled or moved, a number made zero, negative, huge,
# malformed, a token dropped or added, a word in lower case, an OPTION with
# a random value).  Most are refused, and that is the point: the comparison
# sets hold valid models only, so the messages and exit statuses of the
# refusals, and the odd models that still solve, are compared here.
#
#   git worktree add ../phcp-perl cfafeef        (PHCP 1.6.0, the last Perl)
#   python3 tools/fuzz_perl.py --perl ../phcp-perl [-n 500] [--seed 1]
#                              [--modes text,json] [--keep DIR] [-j N]
#
# A case that differs is written to --keep DIR (default: fuzz_failures/) with
# what differed, so it can be run again by hand.  A case either program takes
# more than --timeout seconds on (default 20) is left out, and counted.
# Exit status 0 when nothing differs.

import concurrent.futures
import glob
import os
import random
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import compare_perl  # noqa: E402

NUMBERS = ['0', '-1', '-0', '0.0', '1e9', '1E-9', '1e400', '-1e400', '.5', '5.', '+7', '1,5',
           '0x10', '1e', 'NAN', 'INF', '-INF', 'ABC', '1.5.2', '--3', '007', '1_000', '3/4',
           '100%', '1e3', '0.000001', '999999999', '12 34', '', '1.0000000000000002',
           '0.1', '123456789.123456789', '1e15', '1e16', '1e21', '2.5e-7']
WORDS = ['OPTION', 'NODE', 'PIPE', 'WATER', 'SPRINKLER', 'HYDRANT', 'USE', 'UNITS', 'METHOD',
         'PUMP', 'BFP', 'PRV', 'OPP', 'OFD', 'NRV', 'AREA', 'SCENARIO', 'DPV', 'DPVTRIP',
         'DPVAIR', 'TITLE', 'PROJECT', 'FIXEDFLOW', 'HREEL', 'EQV', 'PC', 'NC', 'BP', 'PRA',
         'SUPPLYGRAPH', 'PUMPDUTY', 'NRVLOSS', 'NRVMODEL', 'DPVMODEL', 'CHANGEPIPE', 'XYZZY']
OPTIONS = ['TOL_FLOW', 'TOL_LOOP', 'MAXITER', 'HWK', 'HW_CONST', 'NU', 'VELOCITY_PRESSURE',
           'VELOCITY_LIMIT', 'SUPPLY_MARGIN', 'DESIGN_AREA', 'SIZING_TRIALS', 'ORIF_DP_TOL',
           'CURVE_EXTRAPOLATION_LIMIT', 'CLOSED_FLOW', 'SIZING_VMAX', 'NOSUCH', 'HWQ', 'HWD']
UNITS = [('FLOW', ['LPM', 'LPS', 'GPM', 'M3H', 'XX']), ('PRESSURE', ['KPA', 'BAR', 'PSI', 'MH2O', 'XX']),
         ('LENGTH', ['M', 'MM', 'FT', 'XX']), ('SIZE', ['MM', 'IN', 'XX']),
         ('ELEVATION', ['M', 'FT', 'XX']), ('KFACTOR', ['LPM/KPA', 'LPM/BAR', 'GPM/PSI', 'XX'])]


def is_num(t):
    try:
        float(t)
        return True
    except ValueError:
        return False


def mutate(lines, rnd):
    lines = list(lines)
    live = [i for i, l in enumerate(lines) if l.strip() and not l.lstrip().startswith('//')]
    if not live:
        return lines
    i = rnd.choice(live)
    toks = lines[i].split()
    k = rnd.randrange(14)
    if k == 0:
        del lines[i]
    elif k == 1:
        lines.insert(i, lines[i])
    elif k == 2:
        j = rnd.choice(live)
        lines[i], lines[j] = lines[j], lines[i]
    elif k in (3, 4, 5):
        nums = [n for n, t in enumerate(toks) if n and is_num(t)]
        if nums:
            toks[rnd.choice(nums)] = rnd.choice(NUMBERS)
            lines[i] = ' '.join(toks)
    elif k == 6 and len(toks) > 1:
        del toks[rnd.randrange(1, len(toks))]
        lines[i] = ' '.join(toks)
    elif k == 7:
        toks.insert(rnd.randrange(1, len(toks) + 1), rnd.choice(NUMBERS + ['X', 'A B', '//', '"']))
        lines[i] = ' '.join(toks)
    elif k == 8:
        lines[i] = lines[i].lower() if rnd.random() < 0.5 else '\t' + lines[i].replace(' ', '\t') + '  \r'
    elif k == 9:
        toks[0] = rnd.choice(WORDS)
        lines[i] = ' '.join(toks)
    elif k == 10:
        lines.insert(rnd.choice(live), 'OPTION %s %s' % (rnd.choice(OPTIONS),
                                                          rnd.choice(NUMBERS + ['ON', 'OFF', 'YES'])))
    elif k == 11:
        q, us = rnd.choice(UNITS)
        lines.insert(0, 'UNITS %s %s' % (q, rnd.choice(us)))
    elif k == 12 and len(toks) > 2:
        a, b = rnd.randrange(1, len(toks)), rnd.randrange(1, len(toks))
        toks[a], toks[b] = toks[b], toks[a]
        lines[i] = ' '.join(toks)
    else:
        lines.insert(i, rnd.choice(['METHOD DW', 'METHOD HW', 'METHOD XX', '', '// X', 'USE BORE 0',
                                    'USE ASAM', 'USE XXXX', 'NODE', 'PIPE', 'TITLE', 'OPTION']))
    return lines


def case(args):
    perl_dir, base, seed, modes, keep = args
    rnd = random.Random(seed)
    with open(base, 'rb') as fh:
        lines = fh.read().decode('utf-8', 'surrogateescape').split('\n')
    for _ in range(rnd.randrange(1, 4)):
        lines = mutate(lines, rnd)
    tmp = tempfile.mkdtemp(prefix='phcp-fuzz-')
    path = os.path.join(tmp, 'case%d.phc' % seed)
    with open(path, 'wb') as fh:
        fh.write('\n'.join(lines).encode('utf-8', 'surrogateescape'))
    try:
        problems = compare_perl.compare(perl_dir, path, modes)
    finally:
        pass
    timed_out = any('timeout' in p for p in problems)
    if problems and not timed_out:
        os.makedirs(keep, exist_ok=True)
        out = os.path.join(keep, 'case%d.phc' % seed)
        with open(out, 'wb') as fh:
            fh.write('\n'.join(lines).encode('utf-8', 'surrogateescape'))
        with open(out + '.diff', 'w', encoding='utf-8', errors='surrogateescape') as fh:
            fh.write('base %s\n' % os.path.relpath(base, ROOT))
            fh.write('\n'.join(problems).replace(tmp, '<tmp>') + '\n')
    os.remove(path)
    os.rmdir(tmp)
    return seed, base, [p.replace(tmp, '<tmp>') for p in problems], timed_out


def main():
    args = sys.argv[1:]
    perl_dir, n, seed0, jobs = None, 200, 1, os.cpu_count() or 2
    modes, keep, timeout, bases = ['text', 'json'], os.path.join(ROOT, 'fuzz_failures'), 20, []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('--perl', '-n', '--seed', '--modes', '--keep', '-j', '--timeout', '--base'):
            v = args[i + 1]
            i += 1
            if a == '--perl':
                perl_dir = os.path.abspath(v)
            elif a == '-n':
                n = int(v)
            elif a == '--seed':
                seed0 = int(v)
            elif a == '--modes':
                modes = v.split(',')
            elif a == '--keep':
                keep = os.path.abspath(v)
            elif a == '-j':
                jobs = int(v)
            elif a == '--timeout':
                timeout = int(v)
            else:
                bases.append(os.path.abspath(v))
        else:
            sys.exit('unknown argument %s' % a)
        i += 1
    if not perl_dir or not os.path.isfile(os.path.join(perl_dir, 'phcp.pl')):
        sys.exit('--perl DIR must be a checkout of the Perl program (phcp.pl)')
    compare_perl.TIMEOUT = timeout
    if not bases:
        # Small models of every kind: the examples, the impossible models,
        # and the smallest trees and loops of each comparison set.
        bases = [f for f in sorted(glob.glob(os.path.join(ROOT, 'examples', '*.phc')))
                 if 'grid1000' not in f]
        bases += sorted(glob.glob(os.path.join(ROOT, 'tools', 'impossible', '*.phc')))
        for s in ('models', 'models_A', 'models_B'):
            for p in ('T00[1-5]', 'L00[1-3]'):
                bases += sorted(glob.glob(os.path.join(ROOT, 'comparison', s, p + '.phc')))
    rnd = random.Random(seed0)
    work = [(perl_dir, rnd.choice(bases), seed0 * 1000003 + k, modes, keep) for k in range(n)]
    bad = slow = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for seed, base, problems, timed_out in pool.map(case, work):
            if timed_out:
                slow += 1
            elif problems:
                bad += 1
                print('case%d (%s): MISMATCH' % (seed, os.path.relpath(base, ROOT)))
                for p in problems[:4]:
                    print('    %s' % p[:400])
                sys.stdout.flush()
    print('%d of %d cases differ; %d left out as slow (%s)' % (bad, n - slow, slow, ','.join(modes)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
