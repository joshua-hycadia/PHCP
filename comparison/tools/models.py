"""Benchmark model generator: 100 trees, 100 looped-main systems, 100 grids.

Every model is written on one neutral basis so each engine is given the same
problem:

  * Hazen-Williams, C = 120 on every pipe;
  * explicit AS 1074 Medium bores (8 sizes, DN25-DN150), no fittings;
  * every sprinkler K8.0 (L/min/kPa^0.5), minimum 50 kPa at every head;
  * every head on a 0.3 m DN25 drop below its range point;
  * one supply node at elevation 0, solved in requirement mode (the supply
    pressure at which the governing head has exactly 50 kPa).

The generator is deterministic: model i of family f uses seed SEED + 1000*f + i.
"""

from __future__ import annotations

import json
import math
import random
from pathlib import Path

SEED = 20261104
C_FACTOR = 120.0
K_FACTOR = 8.0            # L/min/kPa^0.5
P_MIN = 50.0              # kPa
Q_MIN = K_FACTOR * math.sqrt(P_MIN)

# AS 1074 Medium bores, mm (PHCP pipe database, type ASAM)
BORE = {25: 27.3, 32: 36.0, 40: 41.9, 50: 53.0, 65: 68.7, 80: 80.7, 100: 105.1, 150: 155.4}

FAMILIES = ("tree", "loop", "grid")
DROP_M = 0.3              # every head hangs on a 0.3 m DN25 drop below its range point


def range_dn(heads_downstream: int) -> int:
    for n, dn in ((2, 25), (3, 32), (5, 40), (10, 50)):
        if heads_downstream <= n:
            return dn
    return 65


def main_dn(heads: float) -> int:
    for n, dn in ((10, 50), (20, 65), (40, 80), (100, 100)):
        if heads <= n:
            return dn
    return 150


def grid_range_dn(heads_per_range: int) -> int:
    return 25 if heads_per_range <= 6 else 32 if heads_per_range <= 10 else 40


class Builder:
    def __init__(self):
        self.nodes, self.pipes = [], []
        self.drop_of = {}

    def node(self, kind, x, y, z):
        if kind == "head":
            j = self.node("junction", x, y, z)
            h = self.node("head_", x, y, z - DROP_M)
            self.pipe(j, h, 25, DROP_M)
            self.drop_of[j] = h
            return j
        if kind == "head_":
            kind = "head"
        nid = len(self.nodes) + 1
        self.nodes.append({"id": nid, "kind": kind, "x": round(x, 3), "y": round(y, 3), "z": round(z, 3)})
        return nid

    def pipe(self, a, b, dn, length=None):
        na, nb = self.nodes[a - 1], self.nodes[b - 1]
        if length is None:
            length = math.dist((na["x"], na["y"], na["z"]), (nb["x"], nb["y"], nb["z"]))
        self.pipes.append({"id": len(self.pipes) + 1, "from": a, "to": b, "dn": dn,
                           "bore_mm": BORE[dn], "length_m": round(length, 3)})


def _feed(b: Builder, rng, z, total_heads, feed_dn):
    """Supply node 1 at elevation 0, a horizontal feed, then the riser."""
    s = b.node("supply", 0, 0, 0)
    lf = round(rng.uniform(5, 60), 1)
    base = b.node("junction", -lf, 0, 0)
    b.pipe(s, base, feed_dn, lf)
    top = b.node("junction", -lf, 0, z)
    b.pipe(base, top, feed_dn, z)
    return top, lf


def tree(i: int, rng: random.Random) -> dict:
    b = Builder()
    nr = rng.randint(1, 12)
    centre = rng.random() < 0.5
    nh = rng.randint(1, 8) if centre else rng.randint(2, 16)
    sh, sr = round(rng.uniform(2.5, 4.0), 2), round(rng.uniform(2.5, 4.0), 2)
    z = round(rng.uniform(3, 12), 1)
    per_range = nh * (2 if centre else 1)
    heads = nr * per_range
    top, lf = _feed(b, rng, z, heads, main_dn(heads))
    x0 = -lf
    prev = top
    mains = []
    for j in range(nr):
        m = b.node("junction", x0, 1 + j * sr, z)
        b.pipe(prev, m, main_dn((nr - j) * per_range))
        mains.append(m)
        prev = m
    for j, m in enumerate(mains):
        sides = (1, -1) if centre else (1,)
        for sgn in sides:
            last = m
            for k in range(nh):
                h = b.node("head", x0 + sgn * (sh / 2 + k * sh), 1 + j * sr, z)
                b.pipe(last, h, range_dn(nh - k))
                last = h
    return dict(params=dict(ranges=nr, heads_per_range=per_range, centre_fed=centre, head_spacing_m=sh,
                            range_spacing_m=sr, elevation_m=z, feed_m=lf), builder=b)


def loop(i: int, rng: random.Random) -> dict:
    """A looped main: two cross mains joined at both ends; ranges dead-end off
    alternate mains, so the loop carries real circulating flow."""
    b = Builder()
    nr = rng.randint(2, 14)
    nh = rng.randint(2, 14)
    sh, sr = round(rng.uniform(2.5, 4.0), 2), round(rng.uniform(2.5, 4.0), 2)
    z = round(rng.uniform(3, 12), 1)
    heads = nr * nh
    top, lf = _feed(b, rng, z, heads, main_dn(heads))
    x0 = -lf
    w = (nh + 1) * sh
    dn = main_dn(heads / 2)
    a = [b.node("junction", x0, 1 + j * sr, z) for j in range(nr)]
    c = [b.node("junction", x0 + w, 1 + j * sr, z) for j in range(nr)]
    b.pipe(top, a[0], main_dn(heads))
    for j in range(nr - 1):
        b.pipe(a[j], a[j + 1], dn)
    b.pipe(a[0], c[0], dn)
    b.pipe(a[-1], c[-1], dn)
    for j in range(nr - 1):
        b.pipe(c[j], c[j + 1], dn)
    for j in range(nr):
        start, sgn = (a[j], 1) if j % 2 == 0 else (c[j], -1)
        xs = x0 if sgn == 1 else x0 + w
        last = start
        for k in range(nh):
            h = b.node("head", xs + sgn * (sh / 2 + k * sh), 1 + j * sr + 0.3, z)
            b.pipe(last, h, range_dn(nh - k))
            last = h
    return dict(params=dict(ranges=nr, heads_per_range=nh, head_spacing_m=sh, range_spacing_m=sr,
                            elevation_m=z, feed_m=lf), builder=b)


def grid(i: int, rng: random.Random) -> dict:
    """Ranges joined at both ends to two cross mains."""
    b = Builder()
    nr = rng.randint(2, 16)
    nh = rng.randint(3, 16)
    sh, sr = round(rng.uniform(2.5, 4.0), 2), round(rng.uniform(2.5, 4.0), 2)
    z = round(rng.uniform(3, 12), 1)
    heads = nr * nh
    top, lf = _feed(b, rng, z, heads, main_dn(heads))
    x0 = -lf
    w = nh * sh
    dn = main_dn(heads / 2)
    rdn = grid_range_dn(nh)
    a = [b.node("junction", x0, 1 + j * sr, z) for j in range(nr)]
    c = [b.node("junction", x0 + w, 1 + j * sr, z) for j in range(nr)]
    feed_at = 0 if rng.random() < 0.5 else nr // 2
    b.pipe(top, a[feed_at], main_dn(heads))
    for j in range(nr - 1):
        b.pipe(a[j], a[j + 1], dn)
    for j in range(nr - 1):
        b.pipe(c[j], c[j + 1], dn)
    for j in range(nr):
        last = a[j]
        for k in range(nh):
            h = b.node("head", x0 + sh / 2 + k * sh, 1 + j * sr, z)
            b.pipe(last, h, rdn)
            last = h
        b.pipe(last, c[j], rdn)
    return dict(params=dict(ranges=nr, heads_per_range=nh, head_spacing_m=sh, range_spacing_m=sr,
                            elevation_m=z, feed_m=lf, feed_at_range=feed_at), builder=b)


def build(family: str, i: int) -> dict:
    fi = FAMILIES.index(family)
    rng = random.Random(SEED + 1000 * fi + i)
    g = {"tree": tree, "loop": loop, "grid": grid}[family](i, rng)
    b = g["builder"]
    heads = sum(1 for n in b.nodes if n["kind"] == "head")
    loops = len(b.pipes) - len(b.nodes) + 1
    return {
        "schema": "phcp.benchmark.model/1",
        "id": f"{family[0].upper()}{i + 1:03d}",
        "family": family,
        "seed": SEED + 1000 * fi + i,
        "params": g["params"],
        "basis": {"method": "Hazen-Williams", "c_factor": C_FACTOR, "k_factor_lpm_kpa05": K_FACTOR,
                  "min_head_pressure_kpa": P_MIN, "fittings": "none", "bores": "AS 1074 Medium, explicit"},
        "counts": {"heads": heads, "nodes": len(b.nodes), "pipes": len(b.pipes), "loops": loops},
        "nodes": b.nodes,
        "pipes": b.pipes,
    }


def phc_text(m: dict) -> str:
    """The model in PHCP's .phc language. The supply is a fixed head well above
    the requirement; PHCP reports the demand point (the supply pressure at which
    the governing head has exactly P_MIN), which is the benchmarked figure."""
    z = max(n["z"] for n in m["nodes"])
    static = 3 * (P_MIN + z * 9.80665 + 50)
    L = [f"TITLE     PHCP BENCHMARK {m['id']} ({m['family']}, {m['counts']['heads']} heads)",
         "UNITS     LENGTH M", "UNITS     ELEVATION M", "UNITS     SIZE MM", "UNITS     PRESSURE KPA",
         "UNITS     FLOW LPM", "UNITS     KFACTOR LPM/KPA", "METHOD    HW", ""]
    for n in m["nodes"]:
        if n["kind"] == "supply":
            L.append(f"WATER     N{n['id']} {n['z']} {static:.1f}")
        elif n["kind"] == "head":
            L.append(f"SPRINKLER N{n['id']} {n['z']} -{P_MIN:g} {K_FACTOR:g}")
        else:
            L.append(f"NODE      N{n['id']} {n['z']}")
    L += ["", f"USE       BORE {C_FACTOR:g}"]
    for p in m["pipes"]:
        L.append(f"PIPE      P{p['id']} N{p['from']} N{p['to']} {p['length_m']} {p['bore_mm']}")
    return "\n".join(L) + "\n"


def all_models():
    for f in FAMILIES:
        for i in range(100):
            yield build(f, i)


if __name__ == "__main__":
    import sys
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "models")
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for m in all_models():
        (out / f"{m['id']}.json").write_text(json.dumps(m, indent=1), encoding="utf-8")
        (out / f"{m['id']}.phc").write_text(phc_text(m), encoding="ascii")
        rows.append((m["id"], m["family"], m["counts"]["heads"], m["counts"]["pipes"], m["counts"]["loops"]))
    for f in FAMILIES:
        h = [r[2] for r in rows if r[1] == f]
        print(f"{f}: {len(h)} models, heads {min(h)}-{max(h)}, median {sorted(h)[len(h) // 2]}")
