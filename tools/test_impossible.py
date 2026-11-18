#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_impossible.py -- models that must NOT be accepted, run through the
# program a user runs.  Python port of test_impossible.pl.
#
#   python3 tools/test_impossible.py                through phcp
#   python3 tools/test_impossible.py phcp.exe       through the built program
#
# Every model in tools/impossible/ states, on a line "// EXPECT: <exit>
# <acceptance>", what phcp --json --strict must do with it: the exit status
# and the acceptance in the JSON.  Each holds a condition that cannot be a
# valid, compliant design -- most of them were accepted before 11 November
# 2026.  valid_control.phc is the one that must be ACCEPTED, so that a
# program refusing everything cannot pass.
#==============================================================================
import glob
import json
import os
import re
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)


def main():
    exe = sys.argv[1] if len(sys.argv) > 1 else None
    cmd = [exe] if exe else [sys.executable, os.path.join(ROOT, 'phcp')]
    passed = failed = 0

    def is_(name, ok, why=None):
        nonlocal passed, failed
        print('  %-60s %s' % (name, 'ok' if ok else '*** FAIL'))
        if not ok and why is not None:
            print('      %s' % why)
        if ok:
            passed += 1
        else:
            failed += 1

    d = os.path.join(TOOLS, 'impossible')
    models = sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, '*.phc')))
    if not models:
        sys.exit('no models in %s' % d)
    for m in models:
        path = os.path.join(d, m)
        with open(path) as f:
            text = f.read()
        mo = re.search(r'^// EXPECT: (\d+) (\w+)', text, re.M)
        if not mo:
            sys.exit('%s: no EXPECT line' % m)
        want_x, want_a = int(mo.group(1)), mo.group(2)
        p = subprocess.run(cmd + ['--json', '--strict', path],
                           capture_output=True, text=True)
        x = p.returncode
        jm = re.search(r'(\{.*\})', p.stdout + p.stderr, re.S)
        j = {}
        if jm:
            try:
                j = json.loads(jm.group(1))
            except ValueError:
                pass
        acc = j.get('acceptance', 'none')
        is_('%-26s exit %d, %s' % (m, want_x, want_a),
            x == want_x and acc == want_a, 'exit %d, %s' % (x, acc))
        if want_a != 'ERROR':
            is_('%-26s %s' % (m, 'approved' if want_a == 'ACCEPTED' else 'not approved'),
                ((j.get('approved', 0) and True) == (want_a == 'ACCEPTED')))
    print()
    print('%d passed, %d failed' % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
