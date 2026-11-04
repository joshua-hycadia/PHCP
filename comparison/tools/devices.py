"""Round 2: the round-1 networks with fittings (suite A) and devices (suite B).

The networks are the round-1 models, unchanged.  Each pipe's role is read from
the topology, and the fittings that role implies are turned into one
equivalent length from AS 2118.1:2017 Table 14.11.1 (C = 120, AS 1074 Medium
basis, so no correction applies).  Every program is given that same length.

  feed (supply -> riser base)      gate valve + alarm valve (swing) + 2 elbows
  riser                            1 elbow
  loop crossover (main -> main)    2 elbows
  range take-off (main -> range)   1 tee, flow turned
  grid range end (range -> main)   1 tee, flow turned
  drop (range -> head)             1 tee, flow turned (DN25)

Suite B adds, in three different pipes (one device to a pipe):

  BFP      in the feed: loss = a + b (Q/Qr)^2, given as 8 points, Qr about the design flow
  PRV      in the riser: a fixed drop, 50 - 150 kPa
  orifice  in the first DN50 - DN100 main pipe after the riser: a fixed bore, d/D
           0.55 - 0.75.  The AS 2118.1 Appendix C Cd (0.61 at 0.5, 0.71 at 0.55, 0.86
           at 0.74, 0.95 at 0.8, linear between) is recorded and used by the programs
           that apply that method; PHCP uses its own default (Cd 0.596 with the
           ISO 5167 recovery ratio), by the maintainer's decision.

The device values come from their own random stream (seed + 7), so the
networks and fittings are the same in both suites.
"""

from __future__ import annotations

import copy
import random

from models import BORE, P_MIN, Q_MIN, all_models

EL = {  # AS 2118.1:2017 Table 14.11.1, metres, C = 120
    "E": {25: 0.6, 32: 0.9, 40: 1.2, 50: 1.5, 65: 1.8, 80: 2.1, 100: 3.0, 150: 4.3},
    "T": {25: 1.5, 32: 1.8, 40: 2.4, 50: 3.0, 65: 3.7, 80: 4.6, 100: 6.1, 150: 9.1},
    "GV": {25: 0.3, 32: 0.3, 40: 0.3, 50: 0.3, 65: 0.3, 80: 0.3, 100: 0.6, 150: 0.9},
    "CV": {25: 1.5, 32: 2.1, 40: 2.7, 50: 3.4, 65: 4.3, 80: 4.9, 100: 6.7, 150: 9.8},
}
ROLE_FITTINGS = {"feed": {"GV": 1, "CV": 1, "E": 2}, "riser": {"E": 1}, "crossover": {"E": 2},
                 "takeoff": {"T": 1}, "range_end": {"T": 1}, "drop": {"T": 1}}

CD_TABLE = [(0.5, 0.61), (0.55, 0.71), (0.74, 0.86), (0.8, 0.95)]


def orifice_cd(beta: float) -> float:
    for (b0, c0), (b1, c1) in zip(CD_TABLE, CD_TABLE[1:]):
        if b0 <= beta <= b1:
            return c0 + (c1 - c0) * (beta - b0) / (b1 - b0)
    raise ValueError(f"d/D {beta} outside 0.5 - 0.8")


def roles(m: dict) -> dict:
    nodes = {n["id"]: n for n in m["nodes"]}
    heads = {n["id"] for n in m["nodes"] if n["kind"] == "head"}
    range_pts = {p["from"] for p in m["pipes"] if p["to"] in heads}
    out = {}
    for p in m["pipes"]:
        a, b = nodes[p["from"]], nodes[p["to"]]
        if p["from"] == 1:
            r = "feed"
        elif a["z"] != b["z"] and p["to"] not in heads:
            r = "riser"
        elif p["to"] in heads:
            r = "drop"
        elif p["from"] not in range_pts and p["to"] in range_pts:
            r = "takeoff"
        elif p["from"] in range_pts and p["to"] not in range_pts:
            r = "range_end"
        elif p["from"] not in range_pts and p["to"] not in range_pts and a["y"] == b["y"] and a["x"] != b["x"]:
            r = "crossover"
        else:
            r = "run"
        out[p["id"]] = r
    return out


def suite_a(m: dict) -> dict:
    m = copy.deepcopy(m)
    rl = roles(m)
    for p in m["pipes"]:
        f = ROLE_FITTINGS.get(rl[p["id"]], {})
        p["role"] = rl[p["id"]]
        p["fittings"] = f
        p["eq_m"] = round(sum(n * EL[c][p["dn"]] for c, n in f.items()), 3)
    m["schema"] = "phcp.benchmark.model/2"
    m["suite"] = "A"
    m["basis"]["fittings"] = "equivalent lengths from AS 2118.1 Table 14.11.1, the same length to every program"
    return m


def suite_b(m: dict) -> dict:
    m = suite_a(m)
    m["suite"] = "B"
    rng = random.Random(m["seed"] + 7)
    by_role = {}
    for p in m["pipes"]:
        by_role.setdefault(p["role"], []).append(p)
    feed, riser = by_role["feed"][0], by_role["riser"][0]
    # the orifice goes in the first main pipe of DN50 - DN100 downstream of the riser: AU Calc
    # Program takes a fixed-size plate only in a 50 - 200 mm pipe and refuses DN150 here
    nxt = {}
    for p in m["pipes"]:
        nxt.setdefault(p["from"], []).append(p)
    orif, queue = None, [riser["to"]]
    for n in queue:
        for p in nxt.get(n, []):
            if p["role"] in ("run", "crossover") and 50 <= p["dn"] <= 100 and not p.get("device"):
                orif = orif or p
            queue.append(p["to"])
        if orif:
            break
    # no DN50 - DN100 main (the biggest grids): any DN50 - DN100 pipe, else the main after the
    # riser in DN150, which AU Calc Program refuses - recorded as its limit, not worked round
    orif = orif or next((p for p in m["pipes"] if 50 <= p["dn"] <= 100 and not p.get("device")), None) \
        or next(p for p in m["pipes"] if p["from"] == riser["to"])
    qr = m["counts"]["heads"] * Q_MIN * 1.15
    a, b = round(rng.uniform(30, 50), 1), round(rng.uniform(30, 60), 1)
    pts = [(round(qr * f, 1), round(a + b * f * f, 2)) for f in (0, .25, .5, .75, 1, 1.25, 1.5, 2.0)]
    feed["device"] = {"type": "BFP", "curve": pts, "law": f"{a} + {b} (Q/{qr:.1f})^2 kPa"}
    riser["device"] = {"type": "PRV", "drop_kpa": round(rng.uniform(50, 150), 1)}
    beta = round(rng.uniform(0.55, 0.75), 3)
    bore = round(beta * orif["bore_mm"], 2)
    orif["device"] = {"type": "ORIFICE", "bore_mm": bore, "beta": round(bore / orif["bore_mm"], 4),
                      "cd": round(orifice_cd(bore / orif["bore_mm"]), 4)}
    m["basis"]["devices"] = ("BFP loss curve in the feed (8 points, linear between), fixed-drop PRV in the riser, "
                             "fixed-bore orifice plate after the riser with the AS 2118.1 App C Cd")
    return m


if __name__ == "__main__":
    import json
    import sys
    from pathlib import Path
    from models import phc_text
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    for s, fn in (("A", suite_a), ("B", suite_b)):
        out = root / f"models_{s}"
        out.mkdir(parents=True, exist_ok=True)
        n = 0
        for m in all_models():
            mm = fn(m)
            (out / f"{mm['id']}.json").write_text(json.dumps(mm, indent=1), encoding="utf-8")
            (out / f"{mm['id']}.phc").write_text(phc_text(mm), encoding="ascii")
            n += 1
        print(s, n, "models ->", out)
