#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_json.py -- phcp --json, the interface other programs call.  Python
# port of test_json.pl, check for check.
#
#   python3 tools/test_json.py
#
# Runs phcp as a caller would -- a separate process, reading what it prints
# and its exit status -- and checks the JSON against the plain-text output of
# the same solve (the Q and P lines the validation harnesses use), so the two
# outputs of one program cannot disagree.  Then the failures: an input error,
# a .hcx file, a solve that does not converge; and standard input, and
# --report.  (Example 04, the 1000-pipe grid, is left out: its demand point
# re-solves it many times and takes minutes.)
#==============================================================================
import glob
import json
import math
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
PHCP = [sys.executable, os.path.join(ROOT, 'phcp')]
EX = os.path.join(ROOT, 'examples')
TMP = tempfile.mkdtemp()
_pass, _fail = 0, 0


def is_(name, ok, why=None):
    global _pass, _fail
    print('  %-66s %s' % (name, 'ok' if ok else '*** FAIL'))
    if not ok and why is not None:
        print('      %s' % why)
    if ok:
        _pass += 1
    else:
        _fail += 1


def run(stdin, *args):
    # phcp with arguments (and optional standard input): (exit, stdout),
    # standard error to the null device as the Perl's.
    p = subprocess.run(PHCP + list(args), input=stdin.encode('utf-8') if stdin is not None else None,
                       stdin=None if stdin is not None else subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode('utf-8', 'surrogateescape')


def slurp(p):
    with open(p, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read()


def true(x):
    # Perl truth: undef, '', '0' and 0 are false; a reference (a hash or a
    # list, even an empty one) is true.
    if x is None or x is False:
        return False
    if isinstance(x, (dict, list)):
        return True
    if isinstance(x, str):
        return x not in ('', '0')
    return x != 0


def num(x):
    # Perl numification of a JSON value or a captured string: undef is 0.
    if x is None:
        return 0.0
    if isinstance(x, (int, float)):
        return float(x)
    m = re.match(r'\s*([-+]?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|inf(?:inity)?|nan))',
                 x, re.I)
    return float(m.group(1)) if m else 0.0


def decode(out):
    try:
        return json.loads(out), None
    except ValueError as e:
        return None, str(e)


#==============================================================================
print('1. EVERY EXAMPLE - the JSON agrees with the plain output of the same solve')
#==============================================================================
for m in sorted(p for p in glob.glob(os.path.join(EX, '*.phc')) if 'grid1000' not in p):
    name = os.path.basename(m)
    code, out = run(None, '--json', m)
    j, err = decode(out)
    is_('%s: valid JSON, interface 2, converged, exit 0' % name,
        j is not None and num(j.get('interface')) == 2 and j.get('status') == 'converged'
        and true(j.get('converged')) and code == 0, err or 'exit %d' % code)
    jj = j or {}
    acc = jj.get('acceptance') or ''
    is_('   accepted or noncompliant (%s), validation and traceability given' % acc,
        j is not None and re.match(r'^(ACCEPTED|NONCOMPLIANT)\Z', acc) is not None
        and ((jj.get('validation') or {}).get('numerical') or {}).get('status') == 'PASS'
        and ((jj.get('validation') or {}).get('physical') or {}).get('status') == 'PASS'
        and true((jj.get('traceability') or {}).get('model_sha256')))
    if j is None:
        continue
    c2, plain = run(None, m)
    q = dict(re.findall(r'^Q (\S+) (\S+)$', plain, re.M))
    p = dict(re.findall(r'^P (\S+) (\S+)$', plain, re.M))
    bad = 0
    for x in j['pipes'] + j['elements']:
        if not abs(num(x.get('flow')) - num(q.get(x['id']))) < 1e-3:
            bad += 1
    for x in j['nodes']:
        if not abs(num(x.get('pressure')) - num(p.get(x['id']))) < 1e-3:
            bad += 1
    is_('   every flow and pressure as the plain output (%d values)'
        % (len(j['pipes']) + len(j['nodes'])), not bad)
    is_('   units named, as the model declared',
        true(j['units'].get('flow')) and true(j['units'].get('pressure'))
        and re.search(r'^# units flow (\S+) pressure (\S+)$', plain, re.M) is not None)
    v = next((x for x in j['pipes'] if num(x.get('flow')) != 0 and num(x.get('bore')) > 0), None)
    # Velocity by hand: Q / A, Q in m3/s.  The flow unit factor is the
    # ratio of the plain output's flow to... the JSON's own: both in model
    # units, so it is recomputed from L/min when the model is in L/min only.
    if v and j['units'].get('flow') == 'L/min':
        vh = abs(num(v['flow'])) / 60000 / (3.14159265358979 * (num(v['bore']) / 1000) ** 2 / 4)
        is_('   velocity of %s by hand: %.3f m/s' % (v['id'], vh),
            abs(vh - abs(num(v.get('velocity')))) < 0.002)
    text = slurp(m)
    nfix = len(re.findall(r'^FIXEDFLOW\s+\S+\s+\S+\s+\S+\s+\S+', text, re.M))
    nout = len(re.findall(r'^(SPRINKLER|HYDRANT|HREEL)\b', text, re.M))
    # ...and their copies (NC of an outlet).
    is_out = {o: 1 for o in re.findall(r'^(?:SPRINKLER|HYDRANT|HREEL)\s+(\S+)', text, re.M)}
    for rest in re.findall(r'^NC\s+(.*)$', text, re.M):
        w = rest.split()
        src, n = (w[0] if w else None), w[1:]
        if src in is_out:
            nout += len(n)
    # With design areas, the outlets of the area reported and those in no area.
    ar = re.findall(r'^AREA\s+(.*)$', text, re.M)
    if ar:
        in_, open_ = {}, {}
        for rest in ar:
            w = rest.split()
            a, o = (w[0] if w else None), w[1:]
            for x in o:
                in_[x] = 1
            if a == (j.get('design_area') if j.get('design_area') is not None else ''):
                for x in o:
                    open_[x] = 1
        nout -= len([x for x in in_ if x not in open_])
    is_('   every outlet listed (%d outlets, %d fixed flows with a minimum)' % (nout, nfix),
        len(j['outlets']) == nout + nfix)
    if j['outlets']:
        low = sorted(j['outlets'], key=lambda o: num(o.get('margin')))[0]
        is_('   the governing outlet is the one with least margin',
            (j.get('governing') or {}).get('id') == low['id'])
        is_('   the summary names it',
            len([s for s in j['summary']
                 if re.match(r'^GOVERNING OUTLET ' + re.escape(low['id']) + ':', s)]) > 0)
    uses_db = re.search(r'^USE\s+(?!BORE\b)\S+', text, re.M) is not None
    is_('   ' + ('the database used, with its fingerprint' if uses_db
                 else 'no pipe type used: no database'),
        (true(j.get('database'))
         and re.match(r'^[0-9a-f]{64}\Z', j['database'].get('sha256') or '') is not None)
        if uses_db else not true(j.get('database')))
    is_('   a demand point, or the reason there is none',
        true(j.get('demand')) or true(j.get('demand_reason')))

#==============================================================================
print('2. FAILURES - the JSON is written whatever happens')
#==============================================================================
if True:
    badm = 'WATER S 0 500\nNODE A 0\nPIPE P1 S A 10 100\nPIPX P2\nSPRINKLER H 0 -50 80\nPIPE P3 A H 3 50\n'
    code, out = run(badm, '--json', '-')
    j, _ = decode(out)
    is_('an input error: exit 2, status error',
        j is not None and code == 2 and j.get('status') == 'error', 'exit %d' % code)
    e0 = ((j or {}).get('errors') or [{}])[0]
    is_('   the error has its .phc line (4) and message',
        j is not None and num(e0.get('line')) == 4
        and re.search(r'UNKNOWN COMMAND PIPX', e0.get('message') or '') is not None, out)
    is_('   and a summary line saying so',
        j is not None and re.search(r'^NOT SOLVED: .*\(LINE 4\)$', j['summary'][0]) is not None)
    with open(os.path.join(TMP, 'old.hcx'), 'w') as old:
        old.write('NODES\n  N1 0\nEND\n')
    code, out = run(None, '--json', os.path.join(TMP, 'old.hcx'))
    j, _ = decode(out)
    is_('a .hcx file: exit 2, the reason in the JSON',
        j is not None and code == 2
        and re.search(r'IS NOT A \.PHC MODEL', j['errors'][0]['message']) is not None)
    slow = re.sub(r'^OPTION\s+MAXITER.*$', '', slurp(os.path.join(EX, '02_full_network.phc')),
                  flags=re.M)
    slow += 'OPTION MAXITER 1\n'
    code, out = run(slow, '--json', '-')
    j, _ = decode(out)
    is_('a solve that does not converge: exit 1, status not_converged',
        j is not None and code == 1 and j.get('status') == 'not_converged'
        and not true(j.get('converged')), 'exit %d' % code)
    is_('   INDETERMINATE, and the summary says not to use the results',
        j is not None and j.get('acceptance') == 'INDETERMINATE'
        and re.search(r'MUST NOT BE USED', j['summary'][0]) is not None)

#==============================================================================
print('3. STANDARD INPUT AND --report')
#==============================================================================
if True:
    m = os.path.join(EX, '07_pipe_database_demo.phc')
    c1, a = run(None, '--json', m)
    c2, b = run(slurp(m), '--json', '-')
    ja, jb = json.loads(a), json.loads(b)
    for x in (ja, jb):
        x['model'] = ''
    is_('the model from standard input gives the same results',
        c2 == 0 and json.dumps(ja, sort_keys=True) == json.dumps(jb, sort_keys=True))
    rpdf = os.path.join(TMP, 'r.pdf')
    c3, c = run(None, '--json', m, '--report', rpdf)
    pdf_ok = False
    if c3 == 0 and os.path.exists(rpdf) and os.path.getsize(rpdf) > 0:
        with open(rpdf, 'rb') as f:
            pdf_ok = f.read().startswith(b'%PDF-') and json.loads(c)['status'] == 'converged'
    is_('--report writes the PDF as well as the JSON', pdf_ok)
    # PHCPSOLVE in AutoCAD has no JSON reader: it finds the summary by
    # reading the output line by line (phcp:summary in phcp_export.lsp).
    # The same reading, here, must give exactly the summary.
    in_, lines = False, []
    for l in a.split('\n'):
        l = re.sub(r'^[ \t]+|[ \t]+$', '', l)
        if re.match(r'^"summary".*\[$', l):
            in_ = True
        elif in_ and l[:1] == ']':
            in_ = False
        elif in_:
            l = re.sub(r',+$', '', l)
            l = re.sub(r'^"+|"+$', '', l)
            lines.append(l)
    is_('the summary can be read line by line, as AutoCAD reads it',
        bool(lines) and '\n'.join(lines) == '\n'.join(ja['summary']), ' | '.join(lines))
    rtxt = os.path.join(TMP, 'r.txt')
    c4, plain = run(None, m, rtxt)
    is_('without --json, the plain output and report as before',
        c4 == 0 and re.search(r'^# converged yes', plain, re.M) is not None
        and os.path.exists(rtxt) and os.path.getsize(rtxt) > 0)

print('\n%d passed, %d failed' % (_pass, _fail))
sys.exit(1 if _fail else 0)
