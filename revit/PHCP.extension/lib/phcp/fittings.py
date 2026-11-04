# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# Revit families to PHCP fitting codes.
#
# A fitting in Revit is a family between pipes.  PHCP does not model the
# family: it adds the family's equivalent length to a pipe, as a code from
# the pipe and fitting database (E, T, GV, ...).  The map is how a family
# name becomes that code.  Rules the project stores are tried first; the
# built-in rules below cover a family that has not been mapped.
#
# The codes and the compact fitting-string reader follow the engine
# (HardyCross::PipeData::parse_fittings and the short forms G, C, B).  A code
# that is not in that list is refused here, so the model is not written only
# for the engine to reject it.

import re

# Longest first, so E45 is not read as E, and GV75 is not read as GV.
# The same set the engine's fitting reader accepts.
_CODES = (
    "E45M1", "E45M2", "E60M1", "E60M2", "E30M1", "E30M2", "E15M1",
    "EM1", "EM2", "EM3",
    "GV75", "GV50", "GV25", "GV",
    "CVM", "CVB", "CV",
    "E45", "E15", "EL", "EF", "GLV", "CPL", "TR", "BV", "AV", "E", "T",
)
_CODE_RE = re.compile(r"^(\d*)(" + "|".join(_CODES) + r")")
_SHORT = {"G": "GV", "C": "CV", "B": "BV"}
KNOWN_CODES = _CODES + tuple(_SHORT)


def canonical_code(code):
    """A code as the database spells it, or None if it is not one."""
    if code is None:
        return None
    c = str(code).strip().upper()
    c = _SHORT.get(c, c)
    return c if c in _CODES else None


def parse_rules(text):
    """Project fitting-map text to [(pattern, code), ...].

    One rule a line: the family text to find, then the code, separated by
    '=', '|' or a run of spaces.  Blank lines and lines starting with '#'
    are skipped.  A bad line raises ValueError naming it, so a map is not
    half-applied.
    """
    rules = []
    for n, raw in enumerate((text or "").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            pattern, _, code = line.partition("=")
        elif "|" in line:
            pattern, _, code = line.partition("|")
        else:
            bits = line.split()
            if len(bits) < 2:
                raise ValueError("line %d: a rule needs a family pattern and a fitting code" % n)
            pattern, code = " ".join(bits[:-1]), bits[-1]
        pattern, code = pattern.strip(), canonical_code(code)
        if not pattern:
            raise ValueError("line %d: the family pattern is blank" % n)
        if not code:
            raise ValueError("line %d: '%s' is not a fitting code" % (n, raw.strip()))
        rules.append((pattern, code))
    return rules


def format_rules(rules):
    """Rules back to the text stored on the project."""
    return "\n".join("%s = %s" % (p, c) for p, c in rules)


def parse_fitting_string(spec):
    """'2E,1T' or '1E1T' to [(count, code), ...] or raise ValueError.

    The same reading as the engine: commas and spaces are separators, and a
    compact string is split on the longest code.  A count of zero, or a code
    that is not there, is an error.
    """
    rest = re.sub(r"\s+", "", spec or "").upper()
    if not rest:
        return []
    items = []
    while rest:
        rest = rest.lstrip(",+")
        if not rest:
            break
        m = _CODE_RE.match(rest)
        if not m:
            # A short form at the start of what remains: 2G, C, B.
            sm = re.match(r"^(\d*)([GCB])(?![A-Z0-9])", rest)
            if not sm:
                raise ValueError("cannot read fitting code at '%s'" % rest)
            count = int(sm.group(1) or "1")
            code = _SHORT[sm.group(2)]
            rest = rest[sm.end():]
        else:
            count = int(m.group(1) or "1")
            code = m.group(2)
            rest = rest[m.end():]
        if count == 0:
            raise ValueError("a count of zero is not a fitting")
        if count > 99:
            raise ValueError("a count of %d is not plausible on one pipe" % count)
        items.append((count, code))
    return items


def format_fittings(items):
    """[(count, code), ...] to the fields written after a PIPE size.

    A count of 1 is left off, as the language allows.  Order is kept, and
    identical neighbours are merged.
    """
    merged = []
    for count, code in items:
        if merged and merged[-1][1] == code:
            merged[-1] = (merged[-1][0] + count, code)
        else:
            merged.append((count, code))
    return " ".join(code if count == 1 else "%d%s" % (count, code) for count, code in merged)


def _has(name, *words):
    n = (name or "").lower()
    return all(w in n for w in words)


def builtin_code(family, part, angle, pipe_types):
    """The code for a family no project rule claimed.

    part is the Revit part type in words: Elbow, Tee, Cross, Wye, Valve,
    Coupling, Transition, Union, Cap, Flange, or "".  angle is degrees or
    None.  pipe_types is the set of PHCP types of the pipes at the fitting:
    a coupling is counted only on CPVC, which is the table that has one.

    None means the family is not given an equivalent length.  A cap is
    handled by the walk (it closes an end); it is not a fitting loss.
    """
    name = family or ""
    part = (part or "").strip().lower()
    types = {str(t or "").upper() for t in (pipe_types or [])}

    if part == "cap" or part == "endcap" or _has(name, "cap"):
        return None
    if "gate" in name.lower() and re.search(r"25\s*%|25\s*percent|quarter\s*open", name, re.I):
        return "GV25"
    if "gate" in name.lower() and re.search(r"50\s*%|50\s*percent|half\s*open", name, re.I):
        return "GV50"
    if "gate" in name.lower() and re.search(r"75\s*%|75\s*percent", name, re.I):
        return "GV75"

    if part == "elbow" or _has(name, "elbow"):
        if _has(name, "long"):
            return "EL"
        if _has(name, "45") or (angle is not None and abs(angle - 45.0) <= 10.0):
            return "E45"
        if _has(name, "flange") or _has(name, "sweep"):
            return "EF"
        return "E"
    if part in ("tee", "wye", "cross") or _has(name, "tee") or _has(name, "wye"):
        return "T"
    if "butterfly" in name.lower() and ("check" in name.lower() or "alarm" in name.lower()):
        return "CVB"
    if "mushroom" in name.lower():
        return "CVM"
    if "check" in name.lower() or "alarm" in name.lower():
        return "CV"
    if "butterfly" in name.lower():
        return "BV"
    if "globe" in name.lower():
        return "GLV"
    if "angle" in name.lower() and ("valve" in name.lower() or part == "valve"):
        return "AV"
    if "gate" in name.lower():
        return "GV"
    if part == "coupling" or _has(name, "coupling"):
        # The steel tables have no coupling.  Counting one there would be a
        # code the size does not have.  CPVC does.
        return "CPL" if "CPVC" in types else None
    return None


def map_fitting(family, part, angle, rules, pipe_types=None):
    """The code to use, project rules first, then the built-in rules.

    A project rule matches when its pattern is found in the family name,
    ignoring case.  The first rule that matches wins, so the list is the
    priority.  An explicit code already chosen by the user is not passed
    through here.
    """
    name = family or ""
    folded = name.lower()
    for pattern, code in rules or []:
        if pattern.lower() in folded:
            return code
    return builtin_code(family, part, angle, pipe_types)
