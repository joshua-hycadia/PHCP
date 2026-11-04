# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Nominal sizes from the pipe and fitting database.
#
# Revit reports a diameter that might be the nominal size, the outside
# diameter or the bore, depending on the pipe segment.  Matching it to a DN
# has to use the same file the engine will solve with.  Only the DN, OD and
# bore columns are read, and only to pick a nominal size; the equivalent
# lengths stay in the engine.
#
# If the file cannot be read, the designation lists below are names only
# (DN100, not an outside diameter).  A diameter is then accepted when it is
# within 2 mm of one of those names, and a figure like 114.3 is left for the
# designer to set as a DN rather than quietly called 125.

import os

# Designations, not dimensions.  Used only when pipes.dat cannot be read,
# and only as names a stated DN is checked against.
DESIGNATIONS = {
    "ASAM": [20, 25, 32, 40, 50, 65, 80, 90, 100, 125, 150],
    "ASAH": [20, 25, 32, 40, 50, 65, 80, 90, 100, 125, 150],
    "S20": [200, 250, 300, 350, 400, 450, 500, 600],
    "S40": [25, 32, 40, 50, 65, 80, 100, 125, 150, 200, 250, 300, 350, 400, 450, 500, 600],
    "CPVC": [20, 25, 32, 40, 50, 65, 80],
    "PE11": [63, 75, 90, 110, 125, 140, 160, 180, 200, 225, 250, 280, 315, 355, 400, 450, 500, 560, 630],
    "PE9": [63, 75, 90, 110, 125, 140, 160, 180, 200, 225, 250, 280, 315, 355, 400, 450, 500, 560, 630],
    "PVCM16": [100, 125, 150, 200, 225, 250, 300, 375, 450],
}

# How close a Revit diameter must be to a DN, an OD or a bore to be that size.
MATCH_MM = 2.0


class SizeTable(object):
    """type -> [(dn, od_mm or None, bore_mm or None)], DN ascending."""

    def __init__(self, rows, source):
        self.rows = rows
        self.source = source

    def types(self):
        return sorted(self.rows)

    def has_type(self, code):
        return str(code or "").upper() in self.rows

    def dns(self, code):
        return [dn for dn, _od, _bore in self.rows.get(str(code or "").upper(), [])]

    def match(self, code, diameter_mm, tol=MATCH_MM):
        """The DN whose DN, OD or bore is within tol of diameter_mm, or None.

        The closest of those wins.  A tie prefers the DN column over the OD
        over the bore, because a designer who modelled DN100 means DN100.
        """
        best = None
        for dn, od, bore in self.rows.get(str(code or "").upper(), []):
            for rank, value in enumerate((float(dn), od, bore)):
                if value is None:
                    continue
                gap = abs(float(diameter_mm) - float(value))
                if gap <= tol and (best is None or gap < best[0] or (gap == best[0] and rank < best[1])):
                    best = (gap, rank, dn)
        return None if best is None else best[2]

    def next_up(self, code, dn):
        """The next designation larger than dn for this type, or None."""
        larger = [d for d in self.dns(code) if d > dn]
        return larger[0] if larger else None


def load(path):
    """Read PIPE rows from a pipes.dat.  Raises if the file cannot be read."""
    rows = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or not line.startswith("PIPE|"):
                continue
            bits = line.split("|")
            if len(bits) < 5:
                continue
            code, dn, od, bore = bits[1].strip().upper(), bits[2], bits[3], bits[4]
            try:
                dn_n = int(float(dn))
                od_n = float(od)
                bore_n = float(bore)
            except ValueError:
                continue
            rows.setdefault(code, []).append((dn_n, od_n, bore_n))
    for code in rows:
        rows[code].sort(key=lambda r: r[0])
    if not rows:
        raise ValueError("%s has no PIPE rows" % path)
    return SizeTable(rows, path)


def designations():
    """A table of DN names only, for when the database file is not there."""
    rows = {code: [(dn, None, None) for dn in dns] for code, dns in DESIGNATIONS.items()}
    return SizeTable(rows, None)


def find_database(exe=None, env=None):
    """The pipes.dat to match sizes against, or None.

    The team folder (PHCP_DATABASE_DIR) wins, then a copy beside the engine,
    which is where an office database lives.  The copy packed inside the
    engine is not a file this can read; the engine still uses it to solve.
    """
    env = os.environ.get("PHCP_DATABASE_DIR") if env is None else env
    candidates = []
    if env:
        candidates.append(os.path.join(env, "pipes.dat"))
    if exe:
        here = os.path.dirname(os.path.abspath(exe))
        candidates.append(os.path.join(here, "data", "pipes.dat"))
        candidates.append(os.path.join(here, "pipes.dat"))
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return None
