#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# compare_perl.py -- the Python program against the last Perl release, model
# by model.  The Perl is the specification of the port: every output of every
# model must match it byte for byte.  The one intended difference is the
# program's name ("Perl Hydraulic Calculation Program" became "Python
# Hydraulic Calculation Program") and its version (2.0.0 against 1.6.0).
# Those, the results block's CHECK hash (which covers the version), the
# time of the solve (to the minute) and the checkout's own path are the
# only things normalised away.
#
# The Perl is not in this tree any more.  Check out the last Perl release
# beside it and point this at that checkout:
#
#   git worktree add ../phcp-perl cfafeef        (PHCP 1.6.0, the last Perl)
#   python3 tools/compare_perl.py --perl ../phcp-perl
#
#   --perl DIR        the Perl checkout (required)
#   --set NAME        models, models_A, models_B, examples; repeatable
#                     (default: all four; examples/04_grid1000 only with --all)
#   --modes LIST      comma list of text,json,report,save,annotate,strict
#                     (default: text,json,report,save)
#   --every N         every Nth model of each set only (a quick sample)
#   --skip REGEX      leave out the models whose name matches (e.g. the
#                     largest grids, whose demand search is slow in Perl)
#   --all             include the stress model examples/04_grid1000
#   -j N              models run in parallel (default: the CPU count)
#   -v                show the first differing line of each mismatch
#   MODEL ...         only the models named (G001, 05_crosscheck, ...), or
#                     the paths of any .phc files
#
# Exit status 0 when nothing differs, 1 otherwise.

import concurrent.futures
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETS = {
    'models': os.path.join('comparison', 'models'),
    'models_A': os.path.join('comparison', 'models_A'),
    'models_B': os.path.join('comparison', 'models_B'),
    'examples': 'examples',
}
MODES = ('text', 'json', 'report', 'save', 'annotate', 'strict')
NAME_PERL = 'Perl Hydraulic Calculation Program'
NAME_PYTHON = 'Python Hydraulic Calculation Program'
TIMEOUT = 6 * 3600
CHECK = re.compile(r'^(//= CHECK\s+SHA256 )[0-9a-f]{64}', re.M)
STAMP = re.compile(r'\d{4}-\d\d-\d\d \d\d:\d\d(?::\d\d)? UTC')


def versions(perl_dir):
    # The Perl's version and this program's: 2.0.0 is the first Python
    # release, so the version each prints is the one other difference.
    with open(os.path.join(perl_dir, 'HardyCross.pm'), encoding='utf-8') as fh:
        perl = re.search(r"\$VERSION\s*=\s*'([^']+)'", fh.read()).group(1)
    with open(os.path.join(ROOT, 'hardycross', '__init__.py'), encoding='utf-8') as fh:
        python = re.search(r"^VERSION = '([^']+)'", fh.read(), re.M).group(1)
    return perl, python


def norm(s, perl_dir=None):
    # The program's new name and version, and the Perl checkout's own path
    # (the JSON names the pipe database it read by its full path).  The
    # results block's CHECK is a SHA-256 of the block, version line and all,
    # so it is set aside too; tools/test_results.py checks it is right.
    if s is None:
        return None
    s = s.replace(NAME_PERL, NAME_PYTHON)
    if perl_dir:
        s = s.replace(perl_dir, ROOT)
        old, new = versions(perl_dir)
        if old != new:
            v = re.escape(old)
            s = re.sub(r'(PHCP |VERSION |Calculation Program |"version" : ")' + v + r'(?![\d.])', r'\g<1>' + new, s)
    s = CHECK.sub(r'\1<check>', s)
    # The time of the solve, which the results block and the report carry
    # to the minute: two runs either side of a minute are the same answer.
    return STAMP.sub('<time>', s)


def read(path):
    try:
        with open(path, 'rb') as fh:
            return fh.read().decode('utf-8', errors='replace')
    except OSError:
        return None


def run_one(argv, cwd):
    try:
        p = subprocess.run(argv, capture_output=True, cwd=cwd, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 'timeout', '', ''
    return (p.returncode, p.stdout.decode('utf-8', errors='replace'),
            p.stderr.decode('utf-8', errors='replace'))


def outputs(prog, cwd, model, mode):
    """What one program produces for one model in one mode: a list of
    (label, text) pairs, the exit status among them."""
    model = os.path.abspath(model)
    tmp = tempfile.mkdtemp(prefix='phcp-cmp-')
    try:
        if mode == 'text':
            rc, out, err = run_one(prog + [model], cwd)
            return [('exit', str(rc)), ('stdout', out), ('stderr', err)]
        if mode == 'strict':
            rc, out, err = run_one(prog + ['--strict', model], cwd)
            return [('exit', str(rc)), ('stdout', out), ('stderr', err)]
        if mode == 'json':
            rc, out, err = run_one(prog + ['--json', model], cwd)
            return [('exit', str(rc)), ('stdout', out), ('stderr', err)]
        if mode == 'annotate':
            rc, out, err = run_one(prog + ['--annotate', model], cwd)
            return [('exit', str(rc)), ('stdout', out), ('stderr', err)]
        if mode == 'report':
            rep = os.path.join(tmp, 'report.txt')
            rc, out, err = run_one(prog + [model, rep], cwd)
            return [('exit', str(rc)), ('stdout', out), ('stderr', err),
                    ('report.txt', read(rep))]
        if mode == 'save':
            copy = os.path.join(tmp, os.path.basename(model))
            shutil.copyfile(model, copy)
            for extra in glob.glob(os.path.splitext(model)[0] + '.*'):
                if extra != model:
                    shutil.copyfile(extra, os.path.join(tmp, os.path.basename(extra)))
            rc, out, err = run_one(prog + ['--save', copy], cwd)
            return [('exit', str(rc)), ('stdout', out.replace(tmp, '<tmp>')),
                    ('stderr', err.replace(tmp, '<tmp>')), ('saved model', read(copy))]
        raise ValueError(mode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def first_diff(a, b):
    al, bl = (a or '').splitlines(), (b or '').splitlines()
    for i in range(max(len(al), len(bl))):
        x = al[i] if i < len(al) else '<missing>'
        y = bl[i] if i < len(bl) else '<missing>'
        if x != y:
            return 'line %d: perl %r, python %r' % (i + 1, x[:160], y[:160])
    return 'trailing bytes differ'


def compare(perl_dir, model, modes):
    problems = []
    for mode in modes:
        pl = outputs(['perl', 'phcp.pl'], perl_dir, model, mode)
        py = outputs([sys.executable, 'phcp'], ROOT, model, mode)
        for (label, a), (_, b) in zip(pl, py):
            a = norm(a, perl_dir)
            b = norm(b)
            if a != b:
                problems.append('%s %s: %s' % (mode, label, first_diff(a, b)))
    return problems


def main():
    args = sys.argv[1:]
    perl_dir = None
    sets, names = [], []
    modes = ['text', 'json', 'report', 'save']
    every, jobs, verbose, everything = 1, os.cpu_count() or 2, False, False
    skip = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('--perl', '--set', '--modes', '--every', '--skip', '-j'):
            if i + 1 >= len(args):
                sys.exit('%s needs a value' % a)
            v = args[i + 1]
            i += 1
            if a == '--perl':
                perl_dir = os.path.abspath(v)
            elif a == '--set':
                if v not in SETS:
                    sys.exit('unknown set %s' % v)
                sets.append(v)
            elif a == '--modes':
                modes = [m for m in v.split(',') if m]
                for m in modes:
                    if m not in MODES:
                        sys.exit('unknown mode %s' % m)
            elif a == '--skip':
                skip = re.compile(v)
            elif a == '--every':
                every = max(1, int(v))
            else:
                jobs = max(1, int(v))
        elif a == '--all':
            everything = True
        elif a == '-v':
            verbose = True
        elif a.startswith('-'):
            sys.exit('unknown option %s' % a)
        else:
            names.append(a)
        i += 1
    if not perl_dir or not os.path.isfile(os.path.join(perl_dir, 'phcp.pl')):
        sys.exit('--perl DIR must be a checkout of the Perl program (phcp.pl)')

    models = []
    for s in sets or list(SETS):
        found = sorted(glob.glob(os.path.join(ROOT, SETS[s], '*.phc')))
        if s == 'examples' and not everything:
            found = [f for f in found if '04_grid1000' not in f]
        found = found[::every]
        if skip:
            found = [f for f in found if not skip.search(os.path.splitext(os.path.basename(f))[0])]
        models.extend(found)
    if names:
        # A name is a model of the sets (G001), or a path to any .phc.
        paths = [os.path.abspath(n) for n in names if os.path.isfile(n)]
        models = paths + [m for m in models
                          if os.path.splitext(os.path.basename(m))[0] in names]
    if not models:
        sys.exit('no models')

    bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(compare, perl_dir, m, modes): m for m in models}
        for fut in concurrent.futures.as_completed(futs):
            m = os.path.relpath(futs[fut], ROOT)
            problems = fut.result()
            if problems:
                bad += 1
                print('%s: MISMATCH' % m)
                if verbose:
                    for p in problems:
                        print('    %s' % p)
            sys.stdout.flush()
    print('%d of %d models differ (%s)' % (bad, len(models), ','.join(modes)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
