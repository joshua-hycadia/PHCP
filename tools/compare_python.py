#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# compare_python.py -- the Python port against the Perl original, model by
# model, on the frozen comparison set (comparison/models): the text output
# (the Q and P lines), the --json output, and the exit status of each.
# The port is right when every byte matches; anything else is a bug in the
# port, in the harness, or a real disagreement to be run down.
#
#   tools/compare_python.py                  all models, text and JSON
#   tools/compare_python.py G001 G007        the models named
#   tools/compare_python.py --text-only      the text output only
#   tools/compare_python.py --json-only      the JSON output only
#   tools/compare_python.py -v               show the first diff of each

import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return p.returncode, p.stdout, p.stderr


def compare(models, json_too=True, verbose=False):
    bad = 0
    for m in models:
        path = os.path.join('comparison', 'models', m + '.phc')
        rc_p, out_p, err_p = run(['perl', 'phcp.pl', path])
        rc_y, out_y, err_y = run(['python3', 'phcp.py', path])
        ok = True
        if rc_p != rc_y:
            ok = False
            if verbose:
                print('%s: exit status perl %d, python %d' % (m, rc_p, rc_y))
        if out_p != out_y:
            ok = False
            if verbose:
                pl, yl = out_p.splitlines(), out_y.splitlines()
                for i in range(max(len(pl), len(yl))):
                    a = pl[i] if i < len(pl) else '<missing>'
                    b = yl[i] if i < len(yl) else '<missing>'
                    if a != b:
                        print('%s: text line %d: perl %r, python %r' % (m, i + 1, a, b))
                        break
        if json_too:
            jr_p, jout_p, jerr_p = run(['perl', 'phcp.pl', '--json', path])
            jr_y, jout_y, jerr_y = run(['python3', 'phcp.py', '--json', path])
            if jr_p != jr_y or jout_p != jout_y:
                ok = False
                if verbose:
                    pl, yl = jout_p.splitlines(), jout_y.splitlines()
                    for i in range(max(len(pl), len(yl))):
                        a = pl[i] if i < len(pl) else '<missing>'
                        b = yl[i] if i < len(yl) else '<missing>'
                        if a != b:
                            print('%s: json line %d: perl %r, python %r' % (m, i + 1, a, b))
                            break
                    if jr_p != jr_y:
                        print('%s: json exit status perl %d, python %d' % (m, jr_p, jr_y))
        if not ok:
            bad += 1
            print('%s: MISMATCH' % m)
    return bad


def main():
    args = sys.argv[1:]
    json_too = True
    verbose = False
    models = []
    for a in args:
        if a == '--text-only':
            json_too = False
        elif a == '--json-only':
            pass
        elif a == '-v':
            verbose = True
        else:
            models.append(a)
    if not models:
        models = sorted(os.path.basename(p)[:-4]
                       for p in glob.glob(os.path.join(ROOT, 'comparison', 'models', '*.phc')))
    bad = compare(models, json_too=json_too, verbose=verbose)
    print('%d of %d models differ' % (bad, len(models)))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
