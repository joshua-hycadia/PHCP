#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
#==============================================================================
# test_report_checks.py -- does the report's arithmetic close ON THE PAGE?
# Python port of test_report_checks.pl, check for check.
#
# The report promises that every figure can be reproduced by hand from others
# printed beside it, and tells the reader which check to make.  This test takes
# that promise literally: it reads the printed report as TEXT -- never the
# solver's internal numbers -- and does the arithmetic a checker would do with
# a calculator.  A check that only closes to full machine precision, and
# misses once the figures are rounded for print, fails here.
#
# It exists because one did: a loss-per-metre column printed to four decimals
# was ample in kPa/m and lost two significant figures in bar/m, so PF/M x T
# missed PF by 2 % in any model written in bar.
#
#   python3 tools/test_report_checks.py [model.phc ...]
#==============================================================================
import glob
import math
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)

models = sys.argv[1:] if len(sys.argv) > 1 else sorted(glob.glob(os.path.join(ROOT, 'examples', '*.phc')))
models = [m for m in models if 'grid1000' not in m]          # large; adds nothing here
checks, fails = 0, 0
bad = []


def num(s):
    # Perl numification of a printed figure: its leading number, else 0
    # (a '-' in a column reads as 0, as it does in the Perl).
    if isinstance(s, (int, float)):
        return float(s)
    m = re.match(r'\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)', s or '')
    return float(m.group(1)) if m else 0.0


def true(s):
    # Perl truth of a captured string: undef, '' and '0' are false.
    return s is not None and s != '' and s != '0'


# The tolerance a checker would accept: the rounding of every printed figure
# that went into the sum, plus one unit in the last place of the result.
def ulp(s):
    m = re.search(r'\.(\d+)', str(s))
    return 10 ** -len(m.group(1)) if m else 1


def close_to(what, got, want, tol):
    global checks, fails
    checks += 1
    if abs(got - want) <= tol:
        return 1
    fails += 1
    if len(bad) < 20:
        bad.append('%s: worked %.6g, printed %.6g, allowed %.2g' % (what, got, want, tol))
    return 0


# run -- phcp on a model, quietly, by this Python and without a shell, so it
# runs the same on Windows (no /dev/null, no #! line there).
def run(*args):
    subprocess.run([sys.executable, os.path.join(ROOT, 'phcp')] + list(args),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def first(L, rx):
    # The first capture of rx over all the lines, or None.
    for x in L:
        m = re.search(rx, x)
        if m:
            return m.group(1)
    return None


tmpfiles = []
for m in models:
    fd, rep = tempfile.mkstemp(suffix='.txt')
    os.close(fd)
    tmpfiles.append(rep)
    run(m, rep)
    if not os.path.getsize(rep):                 # never a silent pass
        fails += 1
        bad.append('%s: no report written' % m)
        continue
    # As the Perl's open '<': text mode, so CRLF is read as LF on Windows.
    with open(rep, 'rb') as fh:
        b = fh.read()
    if os.name == 'nt':
        b = b.replace(b'\r\n', b'\n')
    L = b.decode('utf-8', 'surrogateescape').splitlines(True)
    name = re.sub(r'.*/', '', m)

    sec = ''
    for li in range(len(L)):
        l = L[li]
        mo = re.match(r'^ (\d+)\. [A-Z]', l)
        if mo:
            sec = mo.group(1)

        # PIPE SCHEDULE, NFPA four-line blocks:
        #   TL = L + F,  Pf = FRI-LOSS x TL,  Pt END = Pt BEG - Pe - Pf,  Pn = Pt BEG - Pv
        mo = re.search(r'\bL=\s*([\d.]+).*\bPt\s+(-?[\d.]+)\s+Pt\s+(-?[\d.]+)\s*$', l) \
            if sec == '6' else None
        if mo:
            len_, ptb = mo.group(1), mo.group(2)
            at = li          # by position: two identical lines cannot be confused
            l2, l3, l4 = [L[k] if k < len(L) else '' for k in (at + 1, at + 2, at + 3)]
            x = re.search(r'^\s(\S+)', l2)
            pipe = x.group(1) if x else ''
            x = re.search(r'F=\s*(-?[\d.]+)\s+C=.*\bPe\s+(-?[\d.]+)\s+Pv\s+(-?[\d.]+)', l2)
            ftg, pe, pv = x.groups() if x else (None, None, None)
            # A pipe of no length prints '-' for FRI-LOSS (there is no length
            # to divide by); its Pf must then be zero, which is the check made.
            x = re.search(r'TL=\s*([\d.]+)\s+([\d.]+|-)\s+Pf\s+(-?[\d.]+)\s+Pn\s+(-?[\d.]+)', l3)
            tl, frl, pf, pn = x.groups() if x else (None, None, None, None)
            if frl is not None and frl == '-' and tl is not None and num(tl) == 0:
                frl = 0
            x = re.search(r'\bPt\s+(-?[\d.]+)\s*$', l4)
            pte = x.group(1) if x else None
            if ftg is not None and tl is not None and pte is not None:
                close_to('%s pipe %s TL = L + F' % (name, pipe), num(len_) + num(ftg), num(tl),
                         ulp(len_) + ulp(ftg) + ulp(tl))
                close_to('%s pipe %s Pf = FRI-LOSS x TL' % (name, pipe), num(frl) * num(tl),
                         abs(num(pf)),
                         num(frl) * ulp(tl) / 2 + num(tl) * ulp(frl) / 2 + ulp(pf))
                close_to('%s pipe %s Pt END = Pt BEG - Pe - Pf' % (name, pipe),
                         num(ptb) - num(pe) - num(pf), num(pte),
                         ulp(ptb) + ulp(pe) + ulp(pf) + ulp(pte))
                close_to('%s pipe %s Pn = Pt - Pv' % (name, pipe), num(ptb) - num(pv), num(pn),
                         ulp(ptb) + ulp(pv) + ulp(pn))
            else:
                close_to("%s pipe block after '%s' parsed" % (name, l[:30]), 0, 1, 0)

        # COVER SHEET (before Section 1):
        #   cushion = available - demand,  computed density = lowest flow / area
        mo = re.search(r'^\s+Pressure cushion\s+(-?[\d.]+)', l) if sec == '' else None
        if mo:
            cush = mo.group(1)
            av = first(L, r'available at the demand flow\s+(-?[\d.]+)')
            dr = first(L, r'Demand pressure required\s+(-?[\d.]+)')
            if av is not None and dr is not None:
                close_to('%s cover cushion = available - demand' % name, num(av) - num(dr),
                         num(cush), ulp(av) + ulp(dr) + ulp(cush))
        mo = re.search(r'^\s+Computed density .*?mm/min\s+(\S+)\s+(\S+)', l) if sec == '' else None
        if mo:
            dens = [mo.group(1), mo.group(2)]
            aps = first(L, r'Area per sprinkler\s+:\s+([\d.]+)')
            lowline = next((x for x in L if re.search(r'^\s+Lowest sprinkler flow', x)), None)
            low = re.findall(r'([\d.]+) \(', lowline) if lowline is not None else []
            for k in (0, 1):
                if not (k < len(low) and re.search(r'^[\d.]+$', dens[k]) and true(aps)):
                    continue
                a = num(aps)
                close_to('%s cover computed density column %d' % (name, k + 1),
                         num(low[k]) / a, num(dens[k]),
                         ulp(low[k]) / a + num(low[k]) * ulp(aps) / a ** 2 + ulp(dens[k]))

        # FLOW PATH:  P TO = P FROM - PF - PE,  PF = PF/M x T,  P TO = P SOLVED
        if sec == '8' and re.search(r'^\s+\d+\s+\S+', l):
            f = l.split()
            if len(f) != 15:
                continue
            t, pfm, pf, pe, pfr, pto, psol = [f[k] for k in (6, 7, 9, 10, 11, 12, 13)]
            close_to('%s path step %s P TO = P FROM - PF - PE' % (name, f[0]),
                     num(pfr) - num(pf) - num(pe), num(pto),
                     ulp(pfr) + ulp(pf) + ulp(pe) + ulp(pto))
            if re.search(r'^-?[\d.]+$', psol):
                close_to('%s path step %s P TO = P SOLVED' % (name, f[0]), num(pto), num(psol),
                         ulp(pto) + ulp(psol))
            if re.search(r'^[\d.]+$', t) and re.search(r'^[\d.]+$', pfm):
                close_to('%s path step %s PF = PF/M x T' % (name, f[0]), num(pfm) * num(t),
                         num(pf),
                         abs(num(pfm)) * ulp(t) / 2 + num(t) * ulp(pfm) / 2 + ulp(pf))

        # OUTLET COMPLIANCE:  ACT Q = K x sqrt(ACT P)
        if sec == '7' and re.search(r'^ \S+\s+\S+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+-?[\d.]+'
                                    r'\s+(PASS|\*\*\*)', l):
            f = l.split()
            k, aq, ap = num(f[2]), f[4], f[6]
            close_to('%s outlet %s Q = K sqrt(P)' % (name, f[0]), k * math.sqrt(num(ap)), num(aq),
                     k * ulp(ap) / (2 * math.sqrt(num(ap))) + math.sqrt(num(ap)) * ulp(f[2]) / 2
                     + ulp(aq))

        # OUTLET COMPLIANCE, fixed flows:  ACT Q = REQ Q (the flow is set), and
        # PASS exactly when ACT P >= REQ P.
        mo = re.search(r'^ (\S+)\s+\S+\s+fixed\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(-?[\d.]+)'
                       r'\s+(PASS|\*\*\* FAIL)', l) if sec == '7' else None
        if mo:
            id_, rq, aq, rp, ap, res = mo.groups()
            close_to('%s fixed flow %s ACT Q = REQ Q' % (name, id_), num(aq), num(rq), ulp(aq))
            close_to('%s fixed flow %s result agrees with ACT P against REQ P' % (name, id_),
                     0 if (num(ap) >= num(rp)) == (res == 'PASS') else 1, 0, 0)

        # NODE SCHEDULE:  PRESSURE + ELEV HEAD = TOTAL HEAD
        if sec == '5' and re.search(r'^ \S+\s+-?[\d.]+\s+-?[\d.]+\s+-?[\d.]+\s+-?[\d.]+\s+', l):
            f = l.split()
            eh, p, th = f[2], f[3], f[4]
            close_to('%s node %s PRESSURE + ELEV HEAD = TOTAL HEAD' % (name, f[0]),
                     num(p) + num(eh), num(th), ulp(p) + ulp(eh) + ulp(th))

for t in tmpfiles:
    try:
        os.unlink(t)
    except OSError:
        pass
print('report hand-checks: %d checked across %d models, %d failed' % (checks, len(models), fails))
for b in bad:
    print('  %s' % b)
sys.exit(1 if fails else 0)
