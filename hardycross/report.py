#
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# report.py -- Python port of HardyCross/Report.pm (in progress).
#
# The calculation report, in monospace ASCII.  The full report writer is
# ported stage by stage; the unit helpers (sym and the decimal-place
# tables) are here from the first, because the JSON output prints them.
#

# The model file uses upper-case unit CODES (KPA, LPM).  A certified report
# uses SI SYMBOLS: "KPA" is not a unit, "kPa" is, and the case carries
# meaning (mPa and MPa differ by nine orders of magnitude).
SYM = {'KPA': 'kPa', 'BAR': 'bar', 'MPA': 'MPa', 'PSI': 'psi', 'M': 'm',
       'MH2O': 'm H2O', 'MWC': 'm H2O', 'FTH2O': 'ft H2O', 'FT': 'ft',
       'LPM': 'L/min', 'L/MIN': 'L/min', 'LPS': 'L/s', 'L/S': 'L/s',
       'M3H': 'm3/h', 'M3/H': 'm3/h', 'GPM': 'US gpm', 'USGPM': 'US gpm',
       'IGPM': 'Imp gpm', 'MM': 'mm', 'IN': 'in'}

def sym(u):
    u = u or ''
    return SYM.get(u.upper(), u)

# Decimal places per unit, chosen so every printed value resolves 0.1 kPa
# and 0.1 L/min or better.
PDP = {'KPA': 1, 'BAR': 3, 'MPA': 4, 'PSI': 2, 'M': 2, 'MH2O': 2, 'MWC': 2,
       'FTH2O': 2, 'FT': 2}
QDP = {'LPM': 1, 'L/MIN': 1, 'LPS': 3, 'L/S': 3, 'M3H': 3, 'M3/H': 3,
       'GPM': 2, 'USGPM': 2, 'IGPM': 2}

def pdp(u):
    return PDP.get((u or '').upper(), 2)

def qdp(u):
    return QDP.get((u or '').upper(), 2)
