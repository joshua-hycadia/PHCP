#!/usr/bin/env python3
#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Stress the pipe database resolver: every pipe type x every tabulated DN x every
# fitting code, then random and hostile fitting strings.  Python port of
# stress_resolver.pl.
#
#   python3 tools/stress_resolver.py
#
# The property that matters most: a
# fitting the data cannot support must come back as DATA_REQUIRED with a
# message.  It must NEVER come back as a quiet zero, a negative, a NaN or an
# undefined total without an error attached.
#
# The random strings come from Perl's own generator (drand48, which Perl has
# used on every platform since 5.20), seeded as the Perl seeds it, so the two
# programs test the same 20000 strings and print the same counts.
import math
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(TOOLS))

from hardycross import pipedata as PD


class PerlRand:
    # Perl's srand / rand: drand48.  srand(s) sets the 48-bit state to
    # (s << 16) + 0x330E; each rand steps X = (0x5DEECE66D X + 0xB) mod 2^48
    # and returns X / 2^48, times the argument.
    def __init__(self, seed):
        self.x = (((seed & 0xFFFFFFFF) << 16) + 0x330E) & 0xFFFFFFFFFFFF

    def rand(self, n=1):
        self.x = (0x5DEECE66D * self.x + 0xB) & 0xFFFFFFFFFFFF
        return n * (self.x / float(1 << 48))


def main():
    PD.load()
    R = PD.resolve

    codes = ('E EF EL E45 T GV GV75 GV50 GV25 CV CVM CVB BV AV GLV CPL TR '
             'E15 EM1 EM2 EM3 E45M1 E45M2 E60M1 E60M2 E30M1 E30M2 E15M1').split()
    tally, bad = {}, []
    cases = [0]

    def classify(r, what):
        cases[0] += 1
        t = r['total']
        if t is None:
            # undefined total is only legitimate WITH an error explaining it
            if not r['errors']:
                bad.append('%s: undefined total with no error' % what)
                return
            tally['DATA_REQUIRED'] = tally.get('DATA_REQUIRED', 0) + 1
            return
        if t != t or math.isinf(t):
            bad.append('%s: non-finite total %s' % (what, t))
            return
        if t < 0:
            bad.append('%s: negative total %s' % (what, t))
            return
        for rec in r['records']:
            # A zero or absurd COUNT is as silent as a zero length -- the first
            # version of this check missed "0E" because it only looked at length.
            if rec['count'] < 1 or rec['count'] > 99:
                bad.append('%s: accepted a count of %s' % (what, rec['count']))
                return
            if (rec.get('method') or '') == 'NOT_COUNTED':
                continue
            # a counted fitting with zero length is exactly the silent zero
            # Clause 6.10 forbids
            if rec.get('each') is not None and rec['each'] == 0:
                bad.append('%s: counted fitting %s resolved to ZERO' % (what, rec['code']))
                return
        k = 'NOT_COUNTED' if t == 0 else 'RESOLVED'
        tally[k] = tally.get(k, 0) + 1

    print('EXHAUSTIVE SWEEP')
    for type_ in PD.pipe_types():
        for dn in range(15, 701):
            if PD.bore(type_, dn) is None:
                continue
            for code in codes:
                classify(R(type=type_, dn=dn, spec=code), '%s DN%d %s' % (type_, dn, code))
                classify(R(type=type_, dn=dn, spec=code, standard_only=1),
                         '%s DN%d %s (standard-only)' % (type_, dn, code))
    print('  %d cases: %d resolved, %d not counted, %d DATA_REQUIRED'
          % (cases[0], tally.get('RESOLVED', 0), tally.get('NOT_COUNTED', 0),
             tally.get('DATA_REQUIRED', 0)))

    print('SIZES THAT DO NOT EXIST')
    before = len(bad)
    for dn in (0, 1, 17, 99, 101, 149, 151, 199, 201, 999, -50):
        r = R(type='ASAM', dn=dn, spec='2E')
        if r['total'] is not None:
            bad.append('ASAM DN%d resolved when it is not tabulated' % dn)
    print('  %s' % ('every untabulated DN refused' if len(bad) == before else 'FAILURES'))

    print('RANDOM AND HOSTILE STRINGS')
    rng = PerlRand(20260921)
    hostile = ['', ',', ',,,', '0E', '00E', '1000000E', '-2E', '2.5E', 'E E E',
               '2e,1t', '2E;1T', '2E 1T', 'E' * 500, '1E' * 200, '2EX', 'X', '2',
               '2E–1T', '2E\t1T', '999999999999999999999E', '1E+1T',
               '+++', '2E++1T', ' 2E , 1T ']
    alpha = codes + ['X', 'Q', 'Z', ',', '+', '0', '1', '2', '9', '.', '-', 'E1']
    for _ in range(20000):
        # 1 .. 1 + int rand 12, then one rand @alpha per piece, in that order.
        n = 1 + int(rng.rand(12))
        hostile.append(''.join(alpha[int(rng.rand(len(alpha)))] for _ in range(n)))
    ok = rej = 0
    for s in hostile:
        try:
            r = R(type='ASAM', dn=50, spec=s)
        except Exception as e:
            bad.append("string '%s' crashed: %s" % (s[:40], e))
            continue
        classify(r, "string '%s'" % s[:40])
        if r['total'] is not None:
            ok += 1
        else:
            rej += 1
    print('  %d strings: %d accepted, %d rejected with a reason, no crashes'
          % (len(hostile), ok, rej))

    print()
    if bad:
        print('%d PROBLEMS' % len(bad))
        print('\n'.join('  %s' % b for b in bad[:20]))
    else:
        print('0 problems')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
