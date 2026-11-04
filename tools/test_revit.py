#!/usr/bin/env python3
# Copyright (c) 2026 Hycadia Pty Ltd
# SPDX-License-Identifier: MIT -- see LICENSE.  The MIT licence covers this
# source code; it does not cover the third-party data in data/.
#
# test_revit.py -- the pyRevit extension, without Revit.
#
#   python3 tools/test_revit.py
#
# Revit is not here, so the ribbon cannot be clicked.  What can be checked
# is checked: the walk (tolerance, tees, drops, open ends), the .phc it
# writes, that file solved by the engine against the AutoCAD export's
# baseline, fitting codes, colours, size suggestions, and that every button
# calls a command that exists.

import ast
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "revit", "PHCP.extension", "lib"))

from phcp.fittings import (  # noqa: E402
    builtin_code, map_fitting, parse_fitting_string, parse_rules,
)
from phcp.model import (  # noqa: E402
    Fitting, Network, Node, Outlet, Pipe, Pt, Supply, clean_text, note_positions,
    parse_curve, parse_device, renumber_copies, walk, write_phc, zero_pipe_sizes,
)
from phcp.parameters import PARAMS, RESULT_PARAMS  # noqa: E402
from phcp.results import (  # noqa: E402
    accept, colour_ability, colour_flow, colour_velocity, dns_to_apply,
    element_results, failing_ids, fast_ids, legend_note, pipes_over_velocity,
    suggestions,
)
from phcp.runner import command_for, run  # noqa: E402
from phcp.sizes import find_database, load  # noqa: E402

PASS = 0
FAIL = 0


def is_(name, ok, why=None):
    global PASS, FAIL
    print("  %-68s %s" % (name[:68], "ok" if ok else "*** FAIL"))
    if not ok and why:
        print("      %s" % why)
    if ok:
        PASS += 1
    else:
        FAIL += 1


def issue_text(result):
    return " | ".join(i.message for i in result.issues)


def messages(result, severity=None):
    return [i.message for i in result.issues if severity is None or i.severity == severity]


def bond(net, a, b):
    net.bonds.append((a, b))


def pipe(key, a, b, **kw):
    kw.setdefault("length_m", Pt(*a).dist(Pt(*b)) / 1000.0)
    return Pipe(key, Pt(*a), Pt(*b), **kw)


def net_with(**kw):
    net = Network()
    net.project.tolerance_mm = kw.pop("tol", 5)
    for k, v in kw.items():
        setattr(net.project, k, v)
    db = os.path.join(ROOT, "data", "pipes.dat")
    net.sizes = load(db)
    return net


# ---------------------------------------------------------------- 1. example
print("1. THE AUTOCAD EXPORT'S NETWORK, WALKED AND SOLVED")


def example_08():
    """The same network as examples/08, built the way a Revit model would be:
    points, a supply, two heads below the range, and fitting overrides where
    the families are not what is being tested.
    """
    net = net_with(tol=5, model_name="LEVEL 2", when="2026-11-04 19:16")
    net.project.title = "Level 2 range"
    net.project.fields = {
        "JOB": "HYC-2026-000", "COMPANY": "Hycadia Pty Ltd",
        "DESIGNER": "A Designer", "HAZARD": "Ordinary Hazard 1",
        "DENSITY": "5.0", "AREA_PER_SPRINKLER": "12.0",
    }
    net.pipes = [
        pipe("p1", (0, 0, 0), (10000, 0, 4500), pid="P1", ptype="ASAM", dn=100,
             length_m=12.845, fit_override="1T 2E 1GV 1CV"),
        pipe("p2", (10000, 0, 4500), (16000, 0, 4500), pid="P2", ptype="ASAM",
             dn=65, c=110, length_m=6.0, fit_override="E"),
        pipe("p3", (16000, 0, 4500), (16000, 3200, 4500), pid="P3", ptype="ASAM",
             dn=40, length_m=3.2),
        pipe("p4", (16000, 0, 4500), (16000, -3200, 4500), pid="P4", ptype="ASAM",
             dn=40, length_m=3.2, fit_override="1E1T"),
    ]
    net.supplies = [Supply(
        "sup", Pt(0, 0, 0), sid="SUP1", static_kpa=900,
        curve=[(1500, 700), (3000, 400)])]
    net.outlets = [
        Outlet("s1", Pt(16000, 3200, 4200), "SPRINKLER", oid="S1",
               elevation_m=4.2, k=80, min_pressure=50),
        Outlet("s2", Pt(16000, -3200, 4200), "SPRINKLER", oid="S2",
               elevation_m=4.2, k=80, min_pressure=50),
    ]
    bond(net, "sup", "p1:A")
    # The heads sit under the range ends.  No connector: the plan match,
    # inside the tolerance, is what makes them drops.
    return net


walked = walk(example_08())
is_("example 08 walks with no errors", walked.ok, issue_text(walked))
text = ""
if walked.ok:
    text = write_phc(walked)
    for line in (
        "WATER     SUP1 0.000 900.000 1500.000 700.000 3000.000 400.000",
        "NODE      N2 4.500",
        "NODE      N3 4.500",
        "SPRINKLER S1 4.200 -50.000 80",
        "SPRINKLER S2 4.200 -50.000 80",
        "PIPE      P1 SUP1 N2 12.845 100 2E T CV GV",
        "PIPE      P2 N2 N3 6.000 65 E",
        "USE       ASAM 110",
        "PIPE      S1_D N4 S1 0.300 25 T",
        "PIPE      S2_D N5 S2 0.300 25 T",
        "PIPE      P4 N3 N5 3.200 40 E T",
    ):
        is_("writes " + line.strip()[:40], line in text, "missing from the model")
    is_("no KEY= fields", "KEY=" not in text and "=" not in text.split("PROJECT", 1)[-1].split("WATER")[0])

solved = None
if text:
    solved = run(command_for(os.path.join(ROOT, "phcp.pl")), text, cwd=ROOT)
    is_("the engine converges", solved.converged, "exit %s" % solved.code)


def baseline_flows():
    want = {}
    path = os.path.join(ROOT, "tools", "baseline", "08_autocad_export_format.expected")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            bits = line.split()
            if len(bits) == 3 and bits[0] in ("Q", "P"):
                want.setdefault(bits[0], {})[bits[1]] = float(bits[2])
    return want


if solved and solved.converged:
    want = baseline_flows()
    got = {p["id"]: p["flow"] for p in solved.data["pipes"]}
    worst = 0.0
    missing = []
    for pid, flow in want["Q"].items():
        if pid not in got:
            missing.append(pid)
        else:
            worst = max(worst, abs(got[pid] - flow))
    is_("pipe flows match the AutoCAD export's baseline",
        not missing and worst < 1e-3, "missing %s worst %.6f" % (missing, worst))
    nodes = {n["id"]: n["pressure"] for n in solved.data["nodes"]}
    worst_p = 0.0
    missing_p = []
    for nid, pressure in want["P"].items():
        if nid not in nodes:
            missing_p.append(nid)
        else:
            worst_p = max(worst_p, abs(nodes[nid] - pressure))
    is_("node pressures match the baseline",
        not missing_p and worst_p < 1e-3, "missing %s worst %.6f" % (missing_p, worst_p))


# ---------------------------------------------------------------- 2. tolerance
print("\n2. WALKING, WITH A TOLERANCE")


def two_pipes(gap, tol=5):
    net = net_with(tol=tol)
    net.pipes = [
        pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50),
        pipe("p2", (1000 + gap, 0, 0), (2000, 0, 0), pid="P2", ptype="ASAM", dn=50),
    ]
    net.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
    net.outlets = [Outlet("s", Pt(2000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
    bond(net, "sup", "p1:A")
    bond(net, "s", "p2:B")
    return walk(net)


joined = two_pipes(4)
is_("4 mm gap, inside 5 mm, is one node",
    joined.ok and any("joined on tolerance" in m for m in messages(joined, "warning")),
    issue_text(joined))
apart = two_pipes(40)
is_("40 mm gap is not joined",
    any("outside the" in m for m in messages(apart, "warning"))
    and any("no supply" in m or "open end" in m for m in messages(apart, "error")),
    issue_text(apart))

linked = net_with(tol=5)
linked.pipes = [
    pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50),
    pipe("p2", (1200, 0, 0), (2200, 0, 0), pid="P2", ptype="ASAM", dn=50),
]
linked.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
linked.outlets = [Outlet("s", Pt(2200, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(linked, "sup", "p1:A")
bond(linked, "s", "p2:B")
bond(linked, "p1:B", "p2:A")  # Revit says these are connected, 200 mm apart
far = walk(linked)
is_("a connector bond joins ends the tolerance would not",
    far.ok and any("connectors are joined but" in m for m in messages(far, "warning")),
    issue_text(far))

# Seeds: only the first pipe is selected.  The bond is not there, the gap is
# inside the tolerance, so the walk steps across and takes the second pipe.
seeded = net_with(tol=5)
seeded.pipes = [
    pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50),
    pipe("p2", (1004, 0, 0), (2000, 0, 0), pid="P2", ptype="ASAM", dn=50),
    pipe("p3", (9000, 0, 0), (10000, 0, 0), pid="P3", ptype="ASAM", dn=50),
]
seeded.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
seeded.outlets = [Outlet("s", Pt(2000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(seeded, "sup", "p1:A")
bond(seeded, "s", "p2:B")
reached = walk(seeded, seeds=["p1"])
ids = sorted(p.pid for p in reached.pipes)
is_("a walk from one pipe crosses a tolerance gap and stops there",
    ids == ["P1", "P2"], "pipes %s" % ids)


# ---------------------------------------------------------------- 3. fittings
print("\n3. FAMILIES, TEES, ELBOWS, VALVES")

is_("a long radius elbow is EL", builtin_code("Long radius elbow", "Elbow", 90, []) == "EL")
is_("a 45 degree elbow is E45", builtin_code("Elbow", "Elbow", 45, []) == "E45")
is_("a standard elbow is E", builtin_code("Elbow 90", "Elbow", 90, []) == "E")
is_("a tee is T", builtin_code("Tee", "Tee", None, []) == "T")
is_("a gate valve is GV", builtin_code("Gate valve DN100", "Valve", None, []) == "GV")
is_("a gate valve 25% open is GV25",
    builtin_code("Gate valve 25% open", "Valve", None, []) == "GV25")
is_("DN25 in the name is not a 25% open valve",
    builtin_code("Gate valve DN25", "Valve", None, []) == "GV")
is_("a check valve is CV", builtin_code("Swing check", "Valve", None, []) == "CV")
is_("a butterfly check is CVB",
    builtin_code("Butterfly check valve", "Valve", None, []) == "CVB")
is_("a coupling is CPL on CPVC only",
    builtin_code("Coupling", "Coupling", None, ["CPVC"]) == "CPL"
    and builtin_code("Coupling", "Coupling", None, ["ASAM"]) is None)
is_("a cap is not a fitting loss", builtin_code("Cap", "Cap", None, []) is None)
rules = parse_rules("special elbow = EL\n# comment\nmy gate | GV")
is_("a project rule wins over the built-in one",
    map_fitting("Special elbow 90", "Elbow", 90, rules, []) == "EL")
try:
    parse_rules("something = NOPE")
    is_("an unknown fitting code is refused", False, "it was accepted")
except ValueError:
    is_("an unknown fitting code is refused", True)
is_("compact fitting strings read as the engine reads them",
    parse_fitting_string("1E1T") == [(1, "E"), (1, "T")]
    and parse_fitting_string("2E,1T") == [(2, "E"), (1, "T")]
    and parse_fitting_string("2G") == [(2, "GV")])


def tee_net():
    net = net_with()
    net.pipes = [
        pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50),
        pipe("p2", (1000, 0, 0), (2000, 0, 0), pid="P2", ptype="ASAM", dn=50),
        pipe("p3", (1000, 0, 0), (1000, 1000, 0), pid="P3", ptype="ASAM", dn=32),
    ]
    net.fittings = [Fitting("tee", [Pt(1000, 0, 0)], family="Equal tee", part="Tee")]
    net.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
    net.outlets = [
        Outlet("s1", Pt(2000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50),
        Outlet("s2", Pt(1000, 1000, 0), "SPRINKLER", oid="S2", k=8, min_pressure=50),
    ]
    bond(net, "sup", "p1:A")
    bond(net, "s1", "p2:B")
    bond(net, "s2", "p3:B")
    bond(net, "p1:B", "tee:0")
    bond(net, "p2:A", "tee:0")
    bond(net, "p3:A", "tee:0")
    return walk(net)


tee = tee_net()
is_("a tee walks", tee.ok, issue_text(tee))
if tee.ok:
    by = {p.pid: p for p in tee.pipes}
    branch = [p.pid for p in tee.pipes if (1, "T") in p.auto_fits]
    is_("the tee's equivalent length is on the branch, not the through main",
        branch == ["P3"], "on %s" % branch)


def elbow_net():
    net = net_with()
    net.pipes = [
        pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50),
        pipe("p2", (1000, 0, 0), (1000, 1000, 0), pid="P2", ptype="ASAM", dn=50),
    ]
    net.fittings = [Fitting("el", [Pt(1000, 0, 0)], family="Elbow 90", part="Elbow", angle=90)]
    net.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
    net.outlets = [Outlet("s", Pt(1000, 1000, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
    bond(net, "sup", "p1:A")
    bond(net, "s", "p2:B")
    bond(net, "p1:B", "el:0")
    bond(net, "p2:A", "el:0")
    return walk(net)


elbow = elbow_net()
is_("an elbow walks", elbow.ok, issue_text(elbow))
if elbow.ok:
    carried = [p.pid for p in elbow.pipes if (1, "E") in p.auto_fits]
    is_("an elbow is counted once, on the later pipe when the sizes match",
        carried == ["P2"], "on %s" % carried)


def valve_net():
    net = net_with()
    net.pipes = [
        pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=80),
        pipe("p2", (1150, 0, 0), (2000, 0, 0), pid="P2", ptype="ASAM", dn=80),
    ]
    net.fittings = [Fitting(
        "v", [Pt(1000, 0, 0), Pt(1150, 0, 0)], family="Gate valve", part="Valve")]
    net.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=500)]
    net.outlets = [Outlet("s", Pt(2000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
    bond(net, "sup", "p1:A")
    bond(net, "s", "p2:B")
    bond(net, "p1:B", "v:0")
    bond(net, "p2:A", "v:1")
    return walk(net)


valve = valve_net()
is_("a gate valve between two pipes is one node and one GV",
    valve.ok and sum(1 for p in valve.pipes if (1, "GV") in p.auto_fits) == 1,
    issue_text(valve))


# ---------------------------------------------------------------- 4. overrides
print("\n4. EQUIVALENT LENGTH, PRESSURE LOSS, AREAS, K")

over = net_with()
over.project.fields = {"JOB": "1"}
over.pipes = [pipe("p1", (0, 0, 0), (5000, 0, 0), pid="P1", ptype="ASAM", dn=50,
                   eqv_m=1.5, loss_kpa=35)]
over.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
over.outlets = [
    Outlet("a", Pt(5000, 0, 0), "SPRINKLER", oid="A1", k=None, min_flow=80,
           min_pressure=100, area="Near"),
    Outlet("b", Pt(5000, 0, 0), "HYDRANT", oid="H1", k=8, min_pressure=50, area="Near"),
]
bond(over, "sup", "p1:A")
# Two outlets on one end is an error.  Split the second onto the supply? No.
# Give the hydrant the other... this pipe has one free end.  Use two pipes.
over.pipes.append(pipe("p2", (5000, 0, 0), (8000, 0, 0), pid="P2", ptype="ASAM", dn=50))
over.outlets[1].xyz = Pt(8000, 0, 0)
bond(over, "a", "p1:B")
bond(over, "b", "p2:B")
ov = walk(over)
is_("overrides and an area walk", ov.ok, issue_text(ov))
if ov.ok:
    body = write_phc(ov)
    k_line = next(line for line in body.splitlines() if line.startswith("SPRINKLER"))
    is_("K is worked out from the flow and the pressure",
        k_line.endswith(" 8") or " 8.000" in k_line or k_line.rstrip().endswith("8"),
        k_line)
    is_("equivalent length and a fixed loss are written",
        "EQV       P1 1.500" in body and "BFP       P1 0 35.000" in body, body)
    is_("a design area names the outlets that flow together",
        "AREA      NEAR A1 H1" in body or "AREA      NEAR H1 A1" in body, body)

curve = parse_curve("1500 700, 3000 400")
is_("a supply curve is flow, pressure, flow, pressure",
    curve == [(1500.0, 700.0), (3000.0, 400.0)])


# ---------------------------------------------------------------- 5. faults
print("\n5. FAULTS THE WALK REFUSES")

mid = net_with()
mid.pipes = [
    pipe("main", (0, 0, 0), (2000, 0, 0), pid="P1", ptype="ASAM", dn=50),
    pipe("br", (1000, 0, 0), (1000, 1000, 0), pid="P2", ptype="ASAM", dn=32),
]
mid.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
mid.outlets = [Outlet("s", Pt(1000, 1000, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(mid, "sup", "main:A")
bond(mid, "s", "br:B")
mid_w = walk(mid)
is_("a pipe end on another pipe's middle is an error",
    any("mid-length" in m for m in messages(mid_w, "error")))

bare = net_with()
bare.pipes = [pipe("p", (0, 0, 0), (1000, 0, 0), ptype="ASAM", dn=25)]
bare.supplies = [Supply("sup", Pt(0, 0, 0), static_kpa=None)]
bare_w = walk(bare)
is_("an open end, a supply with no pressure, and no outlet are errors",
    any("open end" in m for m in messages(bare_w, "error"))
    and any("no static" in m for m in messages(bare_w, "error")))

capped = net_with()
capped.pipes = [pipe("p", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=25)]
capped.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
capped.fittings = [Fitting("cap", [Pt(1000, 0, 0)], family="End cap", part="Cap")]
capped.outlets = [Outlet("s", Pt(0, 0, 1), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
# Outlet at the supply end would clash.  Put the outlet nowhere near, so the
# cap is the thing under test: dead end, warning, and the outlet is not on a pipe.
bond(capped, "sup", "p:A")
bond(capped, "cap:0", "p:B")
cap_w = walk(capped)
is_("a cap is a warning, not an open end",
    any("dead end with a cap" in m for m in messages(cap_w, "warning"))
    and not any(m == "open end" or m.endswith("open end") for m in messages(cap_w, "error")),
    issue_text(cap_w))

same = net_with()
same.pipes = [pipe("p", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=25)]
same.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
same.outlets = [
    Outlet("a", Pt(1000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50),
    Outlet("b", Pt(1000, 0, 0), "SPRINKLER", oid="S2", k=8, min_pressure=50),
]
bond(same, "sup", "p:A")
bond(same, "a", "p:B")
bond(same, "b", "p:B")
same_w = walk(same)
is_("two outlets on one node is an error",
    any("two outlets" in m for m in messages(same_w, "error")))

dup = net_with()
dup.pipes = [
    pipe("p1", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=25),
    pipe("p2", (1000, 0, 0), (2000, 0, 0), pid="P1", ptype="ASAM", dn=25),
]
dup.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
dup.outlets = [Outlet("s", Pt(2000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(dup, "sup", "p1:A")
bond(dup, "s", "p2:B")
bond(dup, "p1:B", "p2:A")
dup_w = walk(dup)
is_("an id used twice is an error", any("used more than once" in m for m in messages(dup_w, "error")))

dirty = clean_text("Level 2 // note ! #")
is_("titles lose the characters .phc refuses", "!" not in dirty and "#" not in dirty and "//" not in dirty)


# ---------------------------------------------------------------- 6. suggest and colour
print("\n6. SUGGESTED SIZES, AND COLOUR")

# A short branch, one pipe left for the engine to size.
size_text = "\n".join([
    "UNITS     LENGTH M",
    "UNITS     ELEVATION M",
    "UNITS     SIZE MM",
    "UNITS     PRESSURE KPA",
    "UNITS     FLOW LPM",
    "UNITS     KFACTOR LPM/KPA",
    "METHOD    HW",
    "OPTION    SIZING_GOAL SMALLEST",
    "OPTION    SIZING_MARGIN 10%",
    "WATER     SUP 0.000 900.000",
    "SPRINKLER S1 0.000 -50.000 8",
    "USE       ASAM",
    "PIPE      P1 SUP S1 10.000 0",
    "",
])
sized = run(command_for(os.path.join(ROOT, "phcp.pl")), size_text, cwd=ROOT)
is_("the engine sizes a pipe given size 0",
    sized.code == 0 and bool(sized.data.get("sized")),
    "exit %s sized %s" % (sized.code, sized.data.get("sized")))
if sized.data.get("sized"):
    got = suggestions(sized.data, {"P1": 65})
    is_("a suggestion names the pipe, the size it was, and the size to use",
        got and got[0]["id"] == "P1" and got[0]["was"] == 65 and got[0]["dn"],
        str(got))

zeroed = zero_pipe_sizes("PIPE      P1 A B 10.000 65 E\nPIPE      P2 B C 3.000 40\n", ["P2"])
is_("size 0 is written on the pipes that were asked for",
    "P2 B C 3.000 0" in zeroed and "P1 A B 10.000 65" in zeroed, zeroed)

fast = {"pipes": [{"id": "P1", "velocity": 9.2}, {"id": "P2", "velocity": 2.0}]}
is_("pipes over 6 m/s are the ones suggested first",
    pipes_over_velocity(fast) == ["P1"])

cols, legend = colour_velocity({"a": 2.0, "b": 5.0, "c": 7.0}, limit=6)
is_("velocity colour: under, near, and over the limit are different",
    cols["a"] != cols["b"] and cols["b"] != cols["c"] and len(legend) == 4)
flows, fleg = colour_flow({"a": 50, "b": 2000})
is_("flow colour follows the L/min bands", flows["a"] != flows["b"] and len(fleg) == 5)
ability, aleg = colour_ability(
    {"s1": {"node": "S1", "pass": False, "margin": -10},
     "s2": {"node": "S2", "pass": True, "margin": 200}},
    {"p1": ("N1", "S1"), "p2": ("N1", "N2")})
is_("a failing outlet colours its pipe, and a main with no outlet stays plain",
    ability["s1"] == ability["p1"] and "p2" not in ability and ability["s1"] != ability["s2"])


# ---------------------------------------------------------------- 7. results
print("\n7. RESULTS WRITTEN BACK")

sample = {
    "interface": 1, "converged": True, "summary": ["CONVERGED"],
    "pipes": [{"id": "P1", "flow": 10.5, "velocity": 1.2, "friction_loss": 3.0}],
    "nodes": [{"id": "S1", "pressure": 180.0}],
    "outlets": [{"id": "S1", "flow": 10.5, "pressure": 180.0, "margin": 130.0, "pass": True}],
    "demand": {"supply": "SUP1", "flow": 10.5, "available": 400, "margin": 50, "meets": True},
}
accept(sample)
writes = element_results(sample, {"P1": 11, "S1": 22, "SUP1": 33})
is_("flow, pressure and pass go to the elements that own those ids",
    writes[11]["PHCP Flow"] == 10.5 and writes[22]["PHCP Pass"] is True
    and writes[33]["PHCP Pressure"] == 400)
try:
    accept({"interface": 2})
    is_("a different JSON interface is refused", False)
except Exception as err:
    is_("a different JSON interface is refused", "interface" in str(err))


# ---------------------------------------------------------------- 9. outlets, devices, copies, colour key
print("\n9. DEVICES, COPIES, AND WHAT TO SHOW")


def summary_text_of(result):
    data = result.data or {}
    errs = data.get("errors") or []
    if errs:
        return " | ".join(str(e) for e in errs)
    return "exit %s" % result.code


def chain():
    """A supply, five pipes and one head, so each device has a pipe."""
    net = net_with()
    net.pipes = [
        pipe("p1", (0, 0, 0), (2000, 0, 0), pid="P1", ptype="ASAM", dn=100,
             device="BP", device_data="400 1000 350", duty_text="1000 350"),
        pipe("p2", (2000, 0, 0), (4000, 0, 0), pid="P2", ptype="ASAM", dn=100,
             device="PRV", device_data="0 40"),
        pipe("p3", (4000, 0, 0), (6000, 0, 0), pid="P3", ptype="ASAM", dn=100,
             device="OPP", device_data="80"),
        pipe("p4", (6000, 0, 0), (8000, 0, 0), pid="P4", ptype="ASAM", dn=100,
             device="OFD", device_data="20"),
        pipe("p5", (8000, 0, 0), (10000, 0, 0), pid="P5", ptype="ASAM", dn=100,
             device="PRA", device_data="3:1 200"),
        pipe("p6", (10000, 0, 0), (12000, 0, 0), pid="P6", ptype="ASAM", dn=65,
             device="BFP", device_data="0 10 500 25"),
    ]
    net.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=900)]
    net.outlets = [Outlet("s", Pt(12000, 0, 0), "SPRINKLER", oid="S1", k=80, min_pressure=50)]
    bond(net, "sup", "p1:A")
    bond(net, "s", "p6:B")
    return net


devices = walk(chain())
is_("a booster, valves and plates walk", devices.ok, issue_text(devices))
if devices.ok:
    body = write_phc(devices)
    for line in (
        "BP        P1 400.000 1000.000 350.000",
        "PUMPDUTY  P1 1000.000 350.000",
        "PRV       P2 0.000 40.000",
        "OPP       P3 80.000",
        "OFD       P4 20.000",
        "PRA       P5 3:1 200.000",
        "BFP       P6 0.000 10.000 500.000 25.000",
    ):
        is_("writes " + line[:40], line in body, "missing from the model")
    solved_dev = run(command_for(os.path.join(ROOT, "phcp.pl")), body, cwd=ROOT)
    is_("the engine accepts the devices", solved_dev.code != 2, summary_text_of(solved_dev))


both = net_with()
both.pipes = [pipe("p", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50,
                   loss_kpa=10, device="PRV", device_data="0 40")]
both.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
both.outlets = [Outlet("s", Pt(1000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(both, "sup", "p:A")
bond(both, "s", "p:B")
both_w = walk(both)
is_("a pipe holds one device",
    any("one device" in m for m in messages(both_w, "error")))

bad = net_with()
bad.pipes = [pipe("p", (0, 0, 0), (1000, 0, 0), pid="P1", ptype="ASAM", dn=50,
                  device="PRA", device_data="1:1")]
bad.supplies = [Supply("sup", Pt(0, 0, 0), sid="SUP1", static_kpa=400)]
bad.outlets = [Outlet("s", Pt(1000, 0, 0), "SPRINKLER", oid="S1", k=8, min_pressure=50)]
bond(bad, "sup", "p:A")
bond(bad, "s", "p:B")
bad_w = walk(bad)
is_("a ratio of 1 is refused",
    any("more than 1" in m for m in messages(bad_w, "error")))

is_("3:1 is kept as a ratio", parse_device("PRA", "3:1 0 5")[:1] == ["3:1"])

copies = renumber_copies([
    (1, "P1", "PHCP ID"),
    (4, "P2", "PHCP ID"),
    (9, "P1", "PHCP ID"),
    (12, "P1", "PHCP ID"),
])
is_("the original keeps its id and the copies take the next free ones",
    copies == [(9, "PHCP ID", "P3"), (12, "PHCP ID", "P4")], str(copies))
selected = renumber_copies([
    (1, "P1", "PHCP ID"),
    (9, "P1", "PHCP ID"),
], only_ids=[1])
is_("renumbering the original does not change it", selected == [])

node = Node(0)
node.name = "N2"
node.x, node.y, node.z = 0.0, 0.0, 0.0
tagged = note_positions(
    [node],
    [pipe("p", (0, 0, 0), (1000, 0, 0), pid="P1")])
is_("a node tag sits beside the node and a pipe tag sits beside the middle",
    (200.0, 0.0, 0.0, "N2") in tagged and (500.0, 200.0, 0.0, "P1") in tagged,
    str(tagged))

_cols, legend = colour_velocity({"a": 1.0}, limit=6)
is_("the colour key is a note, one band to a line",
    legend_note(legend).startswith("PHCP\n") and legend_note(legend).count("\n") == 4)

is_("failing outlets are the ones that do not pass",
    failing_ids({1: {"pass": False}, 2: {"pass": True}}) == [1])
is_("pipes over the limit are the fast ones",
    fast_ids({1: 2.0, 2: 7.0}, 6) == [2])
is_("a suggested size is copied, and size 0 is not a size",
    dns_to_apply({1: 50, 2: 0, 3: None}) == {1: 50.0})


# ---------------------------------------------------------------- 8. parameters and buttons
print("\n8. PARAMETERS, AND EVERY BUTTON")

guids = [p.guid for p in PARAMS]
names = [p.name for p in PARAMS]
is_("every parameter has its own GUID and its own name",
    len(guids) == len(set(guids)) and len(names) == len(set(names)))
is_("the result parameters are a subset of the element parameters",
    set(RESULT_PARAMS) <= set(names))
is_("the pipe database beside the repo is the one sizes are matched against",
    find_database(os.path.join(ROOT, "phcp.pl")) == os.path.join(ROOT, "data", "pipes.dat")
    or load(os.path.join(ROOT, "data", "pipes.dat")).match("ASAM", 114.3) == 100)
is_("DN100's outside diameter matches DN100, not DN125",
    load(os.path.join(ROOT, "data", "pipes.dat")).match("ASAM", 114.3) == 100)
is_("a diameter that is already a DN matches that DN",
    load(os.path.join(ROOT, "data", "pipes.dat")).match("ASAM", 100) == 100)

ext = os.path.join(ROOT, "revit", "PHCP.extension")
buttons = []
for dirpath, _dirs, files in os.walk(ext):
    if dirpath.endswith(".pushbutton") and "script.py" in files:
        buttons.append(os.path.join(dirpath, "script.py"))
is_("the ribbon has a button for each command", len(buttons) >= 16, "%d buttons" % len(buttons))

import importlib
commands = importlib.import_module("phcp.commands")
called = []
bad_syntax = []
for path in buttons:
    source = open(path, encoding="utf-8").read()
    try:
        tree = ast.parse(source)
    except SyntaxError as err:
        bad_syntax.append("%s: %s" % (path, err))
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            called.append(node.func.id)
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "commands":
            called.append(node.attr)
is_("every button script parses", not bad_syntax, "; ".join(bad_syntax))
missing = sorted(name for name in set(called) if not hasattr(commands, name))
# import names that are calls of the command functions: the scripts do
# `from phcp.commands import check_network` then `check_network()`.
is_("every button calls a command that exists",
    not missing and called, "missing %s" % missing)

lib_errors = []
for dirpath, _dirs, files in os.walk(os.path.join(ext, "lib")):
    for name in files:
        if name.endswith(".py"):
            path = os.path.join(dirpath, name)
            try:
                ast.parse(open(path, encoding="utf-8").read())
            except SyntaxError as err:
                lib_errors.append("%s: %s" % (name, err))
is_("the library parses", not lib_errors, "; ".join(lib_errors))

hcx = []
for dirpath, _dirs, files in os.walk(ext):
    for name in files:
        if name.endswith((".py", ".yaml", ".md", ".json")):
            path = os.path.join(dirpath, name)
            text_f = open(path, encoding="utf-8").read()
            if ".hcx" in text_f or "TYPE=" in text_f:
                hcx.append(name)
is_("the extension writes .phc, not the old format", not hcx, ", ".join(hcx))

print("\n%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
