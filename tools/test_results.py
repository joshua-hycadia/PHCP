#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_results.py -- the results saved back into the .phc (hardycross.results).
# Python port of test_results.pl, check for check.
#
#   python3 tools/test_results.py
#
#   1. THE BLOCK.  phcp --save writes one results block at the end of the
#      model; saving again replaces it; the model above it is byte for byte
#      what it was.
#   2. IT CHANGES NOTHING.  The model with its block solves to exactly the
#      same flows and pressures as without; the editor does not show it.
#   3. IT IS THE SOLVE.  Every pipe flow, node pressure and the acceptance in
#      the block are the solve's, read back with read_block; the fingerprint
#      matches the model, and stops matching when the model is edited.
#==============================================================================
import glob
import os
import re
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, ROOT)

import hardycross
from hardycross import phc, results, validate, editor

EX = os.path.join(ROOT, 'examples')
TMP = os.path.join(ROOT, '.test_results_tmp')
os.makedirs(TMP, exist_ok=True)
PHCP = [sys.executable, os.path.join(ROOT, 'phcp')]
_pass, _fail = 0, 0


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
    # As the Perl's slurp: the text with CR-LF read as LF.
    with open(p, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read().replace('\r\n', '\n')


def save(m):
    # phcp --save, its standard output kept out of the way; the exit status.
    with open(os.path.join(TMP, 'out.txt'), 'w') as out:
        return subprocess.run(PHCP + ['--save', m], stdout=out).returncode


def plain(p):
    # The plain solve's output, without the "# " lines (the timestamp and
    # the like) that differ between two runs.
    o = subprocess.run(PHCP + [p], stdout=subprocess.PIPE, text=True).stdout
    return re.sub(r'^# .*\n', '', o, flags=re.M)


def pairs(lst):
    # A Perl hash built from a flat key/value list.
    return dict(zip(lst[0::2], lst[1::2]))


print('1. THE BLOCK')
for ex in ('01_single_branch', '06_orifice', '09_parallel_pumps'):
    orig = slurp(os.path.join(EX, ex + '.phc'))
    m = os.path.join(TMP, ex + '.phc')
    with open(m, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(orig)
    code = save(m)
    once = slurp(m)
    n = len(re.findall(r'^' + re.escape(results.BEGIN), once, re.M))
    is_('%s: --save writes one block at the end (exit %d)' % (ex, code),
        n == 1 and re.search(r'^' + re.escape(results.END) + r'\n\Z', once, re.M) is not None)
    is_('   the model above it is exactly as it was', results.strip(once) == orig)
    save(m)
    twice = slurp(m)
    n = len(re.findall(r'^' + re.escape(results.BEGIN), twice, re.M))
    is_('   saving again replaces it: still one, the model unchanged',
        n == 1 and results.strip(twice) == orig)

    if ex == '01_single_branch':
        print('2. IT CHANGES NOTHING (%s)' % ex)
    is_('   solved with its block: the same flows and pressures',
        plain(m) == plain(os.path.join(EX, ex + '.phc')))
    is_('   the editor opens it without the block', editor.load_file(m)['text'] == orig)

    net = phc.read_string(twice)
    ok = hardycross.solve_model(net)
    rows = results.read_block(twice)
    pipe = {r[1]: pairs(r[2:]) for r in rows if r[0] == 'PIPE'}
    node = {r[1]: pairs(r[2:]) for r in rows if r[0] == 'NODE'}
    res = [pairs(r[1:]) for r in rows if r[0] == 'RESULT'][0]
    model = [pairs(r[1:]) for r in rows if r[0] == 'MODEL'][0]
    bad = 0
    for e in [e for e in net['elems'][1:] if e['kind'] == 'PIPE']:
        if not (e['id'] in pipe
                and abs(float(pipe[e['id']]['FLOW']) - e['q'] / net['f_flow']) < 1e-4):
            bad += 1
    for i in range(1, len(net['nodes'])):
        nd = net['nodes'][i]
        if nd['id'] == 'REF':
            continue
        p = (nd['h'] - hardycross.GAMMA_W * nd['z']) / net['f_pres']
        if not (nd['id'] in node and abs(float(node[nd['id']]['PRESSURE']) - p) < 1e-4):
            bad += 1
    is_("   every pipe flow and node pressure in it is the solve's",
        not bad and len(pipe) > 0, '%d differ' % bad)
    is_("   its acceptance is the solve's (%s)" % res['ACCEPTANCE'],
        res['ACCEPTANCE'] == validate.validate(net, ok)['acceptance'])
    is_("   its fingerprint is the model's", model['SHA256'] == results.fingerprint(twice))
    is_('   and an edited model no longer matches it',
        model['SHA256'] != results.fingerprint(results.strip(twice) + '// EDITED\n'))

with open(os.path.join(EX, '01_single_branch.phc'), 'rb') as fin:
    code = subprocess.run(PHCP + ['--save', '-'], stdin=fin,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
is_('--save with the model on standard input is refused', code != 0)

# What the port got wrong where the examples do not go, each as the Perl
# 1.6.0 does it on the same input.
m = os.path.join(TMP, 'tol.phc')
with open(m, 'w', newline='\n') as f:
    f.write(re.sub(r'TOL_LOOP \S+', 'TOL_LOOP 2',
                   re.sub(r'TOL_FLOW \S+', 'TOL_FLOW 1', slurp(os.path.join(EX, '01_single_branch.phc')))))
save(m)
saved = slurp(m)
is_('a tolerance of 1 is written 1, as Perl prints a number, not 1.0',
    re.search(r'^//= SOLVER .* TOL_FLOW 1 TOL_LOOP 2 VERIFY_LOOP ', saved, re.M) is not None)
check = re.search(r'^//= CHECK +SHA256 [0-9a-f]{64}$', saved, re.M).group(0)
forged = '//= CHECK    SHA256 ' + '0' * 64
is_('of two CHECK records the first is the one compared',
    results.status(saved.replace(check, check + '\n' + forged)) == 'CURRENT'
    and results.status(saved.replace(check, forged + '\n' + check)) == 'TAMPERED')
is_('a CHECK line of any spacing is left out of what the check covers',
    results.status(saved.replace(check, check + '\n//= CHECK\tX')) == 'CURRENT')
is_('a block edited to a byte that is not UTF-8 is TAMPERED, not an error',
    results.status(saved.replace('//= PROGRAM  PHCP', '//= PROGRAM  PH\udce9CP')) == 'TAMPERED')
is_('a figure that is not finite is written Inf, -Inf or NaN',
    [results._num(x, 4) for x in (float('inf'), float('-inf'), float('nan'), None, -0.0)]
    == ['Inf', '-Inf', 'NaN', '-', '-0.0000'])
is_('read_block splits a record at ASCII white space alone',
    results.read_block(saved.replace('//= PROGRAM  PHCP', '//= PROGRAM  PH\x1fCP\xa0Z'))[1]
    == ['PROGRAM', 'PH\x1fCP\xa0Z', 'VERSION', hardycross.VERSION])

for f in glob.glob(os.path.join(TMP, '*')):
    os.unlink(f)
os.rmdir(TMP)
# Port audit: a window reads a model one byte to a character and saves it
# so; the fingerprint it writes is of those bytes, the one the command line
# works out for the saved file -- for a Latin-1 model and a UTF-8 one.
for enc in ('latin-1', 'utf-8'):
    raw = ('TITLE caf\u00e9\n' + 'NODE A 0\n').encode(enc)
    os.makedirs(TMP, exist_ok=True)
    p = os.path.join(TMP, 'accent_%s.phc' % enc)
    with open(p, 'wb') as f:
        f.write(raw)
    t = editor.load_file(p)['text']
    is_('the window\'s fingerprint of a %s model is the command line\'s' % enc,
        t.encode(editor.file_encoding(t)) == raw
        and results.fingerprint(t, editor.file_encoding(t)) == results.fingerprint(phc.model_text(raw)))
    os.remove(p)
os.rmdir(TMP)

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
